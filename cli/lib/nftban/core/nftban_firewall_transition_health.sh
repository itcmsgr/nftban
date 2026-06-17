#!/usr/bin/env bash
# shellcheck disable=SC1090  # Dynamic config paths, cannot follow
# =============================================================================
# NFTBan - Firewall Transition Health (harm-keyed observability)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Harm-keyed health signals for nftables firewall transitions
#          (rebuild/reload/refresh). Detects SERVICE-PORT, mgmt-FLOOR,
#          TABLE-ABSENT-while-COMMITTED, and BLACKLIST-EMPTY harm — NOT
#          rebuild cadence. Closes the v1.192.1 observability gap behind the
#          service-port-set atomicity fix (D-V192-RESIDUAL-REBUILD-DROP).
#
# meta:name="nftban_firewall_transition_health"
# meta:type="lib"
# meta:header="Firewall Transition Health"
# meta:version="1.192.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Harm-keyed firewall transition health counters + read-only probe"
# meta:depends="nftban_health.sh"
# meta:inventory.files="/var/lib/nftban/state/firewall_transition_health.json"
# meta:inventory.binaries="nft,nftban-core"
# meta:inventory.env_vars="NFTBAN_STATE_DIR,NFTBAN_LIB_DIR,FTH_STATE_FILE,FTH_NFT,FTH_CORE,FTH_SKIP_GATHER"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# meta:created_date="2026-06-17"
# =============================================================================

set -Eeuo pipefail

# Health status codes — define fallbacks so this lib is usable from the firewall
# path (where nftban_health.sh may not be sourced). `:=` only assigns when unset,
# so it never conflicts with nftban_health.sh's readonly declarations.
: "${HEALTH_OK:=0}"
: "${HEALTH_WARNING:=1}"
: "${HEALTH_ERROR:=2}"
: "${HEALTH_CRITICAL:=3}"

# Overridable inputs (tests stub these).
: "${FTH_STATE_FILE:=${NFTBAN_STATE_DIR:-/var/lib/nftban/state}/firewall_transition_health.json}"
: "${FTH_NFT:=nft}"
: "${FTH_CORE:=${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core}"
: "${FTH_INSTALL_STATE:=${NFTBAN_STATE_DIR:-/var/lib/nftban/state}/install_state}"
: "${FTH_RECOVERY_MARKER:=${NFTBAN_STATE_DIR:-/var/lib/nftban/state}/rebuild_recovery.json}"

# -----------------------------------------------------------------------------
# PURE helpers (no I/O — unit-testable)
# -----------------------------------------------------------------------------

# _fth_norm: normalize a port list (stdin) to sorted-unique CSV.
_fth_norm() {
    tr -cd '0-9,\n ' | tr ',\n ' '\n\n\n' | grep -E '^[0-9]+$' | sort -n -u | paste -sd,
}

# _fth_missing <effective_csv> <live_csv>: echo space-separated ports present in
# effective but absent from live (a service-port breach is any non-empty result).
_fth_missing() {
    local eff live p out=""
    eff=$(printf '%s' "${1:-}" | _fth_norm)
    live=",$(printf '%s' "${2:-}" | _fth_norm),"
    local IFS=,
    for p in $eff; do
        [[ -z "$p" ]] && continue
        case "$live" in *",$p,"*) ;; *) out+="$p " ;; esac
    done
    echo "${out% }"
}

# _fth_classify <svc> <floor> <table_absent> <bl_empty> <non_atomic>: map harm
# counts to a health status code. Cadence is NEVER an input here.
_fth_classify() {
    local svc="${1:-0}" floor="${2:-0}" tbl="${3:-0}" bl="${4:-0}" na="${5:-0}"
    if (( floor > 0 || tbl > 0 || bl > 0 )); then echo "$HEALTH_CRITICAL"; return; fi
    if (( svc > 0 || na > 0 )); then echo "$HEALTH_ERROR"; return; fi
    echo "$HEALTH_OK"
}

# _fth_json_get <key> <default>: read a numeric/string field from the state JSON.
_fth_json_get() {
    # NB: ${2-0} (no colon) so an explicitly-passed empty default ("") is
    # preserved — string fields (anomaly_at/reason) must be able to read back "".
    local key="$1" def="${2-0}"
    [[ -r "$FTH_STATE_FILE" ]] || { echo "$def"; return; }
    local v
    if command -v jq >/dev/null 2>&1; then
        # NB: do NOT use `// empty` — jq treats boolean false as empty, which
        # would lose last_rebuild_atomic=false. Use has() to distinguish.
        v=$(jq -r --arg k "$key" 'if has($k) then .[$k] else empty end' "$FTH_STATE_FILE" 2>/dev/null)
    else
        v=$(sed -n "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"\\?\\([^\",}]*\\)\"\\?.*/\\1/p" "$FTH_STATE_FILE" 2>/dev/null | head -1)
    fi
    [[ -n "$v" ]] && echo "$v" || echo "$def"
}

# -----------------------------------------------------------------------------
# Gather live + effective + floor + table state into FTH_* globals.
# Sets: FTH_EFF_{TCPIN,TCPOUT,UDPIN,UDPOUT}, FTH_LIVE_<set>_<4|6>,
#       FTH_FLOOR_4, FTH_FLOOR_6 (Y/N), FTH_TABLE_PRESENT (Y/N),
#       FTH_COMMITTED (Y/N), FTH_IN_RECOVERY (Y/N).
# Tests may set FTH_SKIP_GATHER=1 and pre-populate these vars instead.
# -----------------------------------------------------------------------------
_fth_ssh_ports() {
    # Best-effort SSH port authority for render-effective (lockout guard input).
    local fn
    for fn in nftban_detect_ssh_ports nftban_detect_ssh_primary_port; do
        if declare -f "$fn" >/dev/null 2>&1; then
            local out; out=$("$fn" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
            [[ -n "$out" ]] && { echo "$out"; return; }
        fi
    done
    # Fallback to the durable ports.d SSH file.
    local sf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/ports.d/00-ssh.conf"
    [[ -r "$sf" ]] && grep -oE '^[0-9]+' "$sf" 2>/dev/null | tr '\n' ',' | sed 's/,$//'
}

_fth_live_set() { # <family ip|ip6> <setname>  (collapse newlines: nft wraps long lists)
    "$FTH_NFT" list set "$1" nftban "$2" 2>/dev/null | tr '\n' ' ' \
        | grep -oE 'elements = \{[^}]*\}' | _fth_norm
}

_fth_floor_present() { # <family ip|ip6> -> Y/N
    local c; c=$("$FTH_NFT" list chain "$1" nftban input 2>/dev/null)
    if printf '%s' "$c" | grep -q 'iif "lo"' \
        && printf '%s' "$c" | grep -q 'established,related' \
        && printf '%s' "$c" | grep -q 'ssh_ports'; then echo Y; else echo N; fi
}

# shellcheck disable=SC2034  # FTH_EFF_*/FTH_LIVE_* are consumed via INDIRECT
# expansion (${!eff}/${!live}) in _fth_compute_breaches — ShellCheck cannot see
# that use and reports them as unused. Suppression scoped to this function only.
_fth_gather() {
    local ssh_csv eff
    ssh_csv=$(_fth_ssh_ports)
    if [[ -n "$ssh_csv" ]]; then
        eff=$(NFTBAN_EFFECTIVE_SSH_PORTS="$ssh_csv" "$FTH_CORE" ports render-effective 2>/dev/null || true)
    else
        eff=""
    fi
    FTH_EFF_TCPIN=$(sed -n 's/^NFTBAN_SVC_TCP_IN=//p'  <<<"$eff")
    FTH_EFF_TCPOUT=$(sed -n 's/^NFTBAN_SVC_TCP_OUT=//p' <<<"$eff")
    FTH_EFF_UDPIN=$(sed -n 's/^NFTBAN_SVC_UDP_IN=//p'  <<<"$eff")
    FTH_EFF_UDPOUT=$(sed -n 's/^NFTBAN_SVC_UDP_OUT=//p' <<<"$eff")

    FTH_LIVE_TCPIN_4=$(_fth_live_set ip  tcp_ports_in)
    FTH_LIVE_TCPIN_6=$(_fth_live_set ip6 tcp_ports_in)
    FTH_LIVE_TCPOUT_4=$(_fth_live_set ip  tcp_ports_out)
    FTH_LIVE_TCPOUT_6=$(_fth_live_set ip6 tcp_ports_out)
    FTH_LIVE_UDPIN_4=$(_fth_live_set ip  udp_ports_in)
    FTH_LIVE_UDPIN_6=$(_fth_live_set ip6 udp_ports_in)
    FTH_LIVE_UDPOUT_4=$(_fth_live_set ip  udp_ports_out)
    FTH_LIVE_UDPOUT_6=$(_fth_live_set ip6 udp_ports_out)

    FTH_FLOOR_4=$(_fth_floor_present ip)
    FTH_FLOOR_6=$(_fth_floor_present ip6)

    if "$FTH_NFT" list table ip nftban >/dev/null 2>&1 && "$FTH_NFT" list table ip6 nftban >/dev/null 2>&1; then
        FTH_TABLE_PRESENT=Y
    else
        FTH_TABLE_PRESENT=N
    fi

    # COMMITTED = install_state declares NFTBan the active authority.
    FTH_COMMITTED=N
    if [[ -r "$FTH_INSTALL_STATE" ]] && grep -qE '^AUTHORITY=(EXCLUSIVE|UPDATE)$' "$FTH_INSTALL_STATE" 2>/dev/null; then
        FTH_COMMITTED=Y
    fi
    # In an active recovery window the table may legitimately be mid-restore.
    FTH_IN_RECOVERY=N
    [[ -f "$FTH_RECOVERY_MARKER" ]] && FTH_IN_RECOVERY=Y
}

# -----------------------------------------------------------------------------
# Compute breach counts from FTH_* globals (no nft/core calls — testable by
# pre-setting the globals). Sets: FTH_B_SVC, FTH_B_FLOOR, FTH_B_TABLE and
# FTH_REASON (human-readable, set/family/port identified).
# -----------------------------------------------------------------------------
_fth_compute_breaches() {
    FTH_B_SVC=0; FTH_B_FLOOR=0; FTH_B_TABLE=0; FTH_REASON=""
    local reasons=() miss set fam eff live human famlabel
    for set in TCPIN TCPOUT UDPIN UDPOUT; do
        eff="FTH_EFF_${set}"
        case "$set" in
            TCPIN)  human="tcp_ports_in" ;; TCPOUT) human="tcp_ports_out" ;;
            UDPIN)  human="udp_ports_in" ;; UDPOUT) human="udp_ports_out" ;;
        esac
        for fam in 4 6; do
            live="FTH_LIVE_${set}_${fam}"
            miss=$(_fth_missing "${!eff:-}" "${!live:-}")
            if [[ -n "$miss" ]]; then
                FTH_B_SVC=$((FTH_B_SVC + 1))
                [[ "$fam" == 4 ]] && famlabel="ip" || famlabel="ip6"
                reasons+=("${human} ${famlabel}: missing ${miss// /,}")
            fi
        done
    done
    # Floor breach (either family missing lo/established/ssh).
    if [[ "${FTH_FLOOR_4:-Y}" == N ]]; then FTH_B_FLOOR=$((FTH_B_FLOOR+1)); reasons+=("mgmt floor absent (ip)"); fi
    if [[ "${FTH_FLOOR_6:-Y}" == N ]]; then FTH_B_FLOOR=$((FTH_B_FLOOR+1)); reasons+=("mgmt floor absent (ip6)"); fi
    # Table absent while COMMITTED (exempt during an active recovery window).
    if [[ "${FTH_TABLE_PRESENT:-Y}" == N && "${FTH_COMMITTED:-N}" == Y && "${FTH_IN_RECOVERY:-N}" == N ]]; then
        FTH_B_TABLE=$((FTH_B_TABLE+1)); reasons+=("nftban table absent while install_state COMMITTED")
    fi
    FTH_REASON=$(IFS='; '; echo "${reasons[*]}")
}

# -----------------------------------------------------------------------------
# Persist: atomic write of the state JSON.
# -----------------------------------------------------------------------------
_fth_write_json() { # <svc> <floor> <tbl> <bl> <na> <atomic Y/N> <trigger> <dur_ms> <anomaly_at> <reason>
    local svc=$1 floor=$2 tbl=$3 bl=$4 na=$5 atomic=$6 trig=$7 dur=$8 at=$9 reason=${10}
    local atomic_bool=true; [[ "$atomic" == N ]] && atomic_bool=false
    local dir; dir=$(dirname "$FTH_STATE_FILE")
    mkdir -p "$dir" 2>/dev/null || true
    local tmp="${FTH_STATE_FILE}.tmp.$$"
    # Escape reason for JSON (quotes/backslashes).
    local esc=${reason//\\/\\\\}; esc=${esc//\"/\\\"}
    printf '{\n  "schema": "fth-1",\n  "service_port_breach_count": %d,\n  "floor_breach_count": %d,\n  "table_absent_while_committed_count": %d,\n  "blacklist_empty_during_refresh_count": %d,\n  "non_atomic_rebuild_count": %d,\n  "last_rebuild_atomic": %s,\n  "last_trigger": "%s",\n  "last_duration_ms": %d,\n  "last_transition_anomaly_at": "%s",\n  "last_transition_anomaly_reason": "%s"\n}\n' \
        "$svc" "$floor" "$tbl" "$bl" "$na" "$atomic_bool" "$trig" "$dur" "$at" "$esc" > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 1; }
    chmod 644 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$FTH_STATE_FILE" 2>/dev/null || { rm -f "$tmp"; return 1; }
    return 0
}

# -----------------------------------------------------------------------------
# fth_record_transition <trigger> <duration_ms> [atomic Y/N]
# Called by the firewall rebuild/reload path AFTER apply. Probes the live state
# and increments harm counters (cumulative) for anything wrong "during or
# immediately after" the transition. Never increments on cadence.
# -----------------------------------------------------------------------------
fth_record_transition() {
    local trigger="${1:-rebuild}" dur="${2:-0}" atomic="${3:-Y}"
    [[ "$dur" =~ ^[0-9]+$ ]] || dur=0
    [[ "${FTH_SKIP_GATHER:-}" == "1" ]] || _fth_gather
    _fth_compute_breaches

    local svc floor tbl bl na
    svc=$(_fth_json_get service_port_breach_count 0)
    floor=$(_fth_json_get floor_breach_count 0)
    tbl=$(_fth_json_get table_absent_while_committed_count 0)
    bl=$(_fth_json_get blacklist_empty_during_refresh_count 0)
    na=$(_fth_json_get non_atomic_rebuild_count 0)
    [[ "$svc" =~ ^[0-9]+$ ]] || svc=0; [[ "$floor" =~ ^[0-9]+$ ]] || floor=0
    [[ "$tbl" =~ ^[0-9]+$ ]] || tbl=0;  [[ "$bl" =~ ^[0-9]+$ ]] || bl=0
    [[ "$na" =~ ^[0-9]+$ ]] || na=0

    local at; at=$(_fth_json_get last_transition_anomaly_at "")
    local reason; reason=$(_fth_json_get last_transition_anomaly_reason "")
    local anomaly=0
    if (( FTH_B_SVC > 0 ));   then svc=$((svc + FTH_B_SVC));   anomaly=1; fi
    if (( FTH_B_FLOOR > 0 )); then floor=$((floor + FTH_B_FLOOR)); anomaly=1; fi
    if (( FTH_B_TABLE > 0 )); then
        tbl=$((tbl + FTH_B_TABLE)); na=$((na + 1)); anomaly=1   # table-absent-mid-commit = harmful non-atomic
        atomic=N
    fi
    if (( anomaly == 1 )); then
        at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
        reason="$FTH_REASON"
    fi
    _fth_write_json "$svc" "$floor" "$tbl" "$bl" "$na" "$atomic" "$trigger" "$dur" "$at" "$reason"
}

# fth_note_blacklist_empty <count_before>: callable by a refresh path that
# observed the shared blacklist unexpectedly empty while elements existed before.
# Increments blacklist_empty_during_refresh_count (CRITICAL). Not wired into the
# atomic Go feed/geoban refresh (v1.192.0 F-FEED/F-GEO); provided for any shell
# refresh path + completeness of the harm model.
fth_note_blacklist_empty() {
    local before="${1:-0}"
    [[ "$before" =~ ^[0-9]+$ && "$before" -gt 0 ]] || return 0
    local svc floor tbl bl na
    svc=$(_fth_json_get service_port_breach_count 0); floor=$(_fth_json_get floor_breach_count 0)
    tbl=$(_fth_json_get table_absent_while_committed_count 0); bl=$(_fth_json_get blacklist_empty_during_refresh_count 0)
    na=$(_fth_json_get non_atomic_rebuild_count 0)
    for v in svc floor tbl bl na; do [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "$v" 0; done
    bl=$((bl + 1))
    local at; at=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "")
    _fth_write_json "$svc" "$floor" "$tbl" "$bl" "$na" Y refresh 0 "$at" "blacklist unexpectedly empty during refresh (had $before)"
}

# -----------------------------------------------------------------------------
# fth_eval_health: READ-ONLY. Combine persisted counters + a fresh probe and
# echo "STATUS_CODE|reason". Used by the health check + status surfaces.
# -----------------------------------------------------------------------------
fth_eval_health() {
    local svc floor tbl bl na
    svc=$(_fth_json_get service_port_breach_count 0); floor=$(_fth_json_get floor_breach_count 0)
    tbl=$(_fth_json_get table_absent_while_committed_count 0); bl=$(_fth_json_get blacklist_empty_during_refresh_count 0)
    na=$(_fth_json_get non_atomic_rebuild_count 0)
    for v in svc floor tbl bl na; do [[ "${!v}" =~ ^[0-9]+$ ]] || printf -v "$v" 0; done

    # Fresh read-only probe (detects current drift even without a transition).
    [[ "${FTH_SKIP_GATHER:-}" == "1" ]] || _fth_gather
    _fth_compute_breaches
    # Classify on presence of EITHER persisted harm OR a current live breach.
    local f_svc=$(( svc + FTH_B_SVC )) f_floor=$(( floor + FTH_B_FLOOR )) f_tbl=$(( tbl + FTH_B_TABLE ))
    local code; code=$(_fth_classify "$f_svc" "$f_floor" "$f_tbl" "$bl" "$na")
    local reason=""
    if [[ "$code" != "$HEALTH_OK" ]]; then
        local parts=()
        # Display the OFFICIAL persisted counters (not summed with the probe).
        (( floor > 0 )) && parts+=("floor_breach=$floor")
        (( tbl   > 0 )) && parts+=("table_absent_while_committed=$tbl")
        (( bl    > 0 )) && parts+=("blacklist_empty_during_refresh=$bl")
        (( svc   > 0 )) && parts+=("service_port_breach=$svc")
        (( na    > 0 )) && parts+=("non_atomic_rebuild=$na")
        # Current live probe findings (set/family/port), if any.
        [[ -n "$FTH_REASON" ]] && parts+=("current: $FTH_REASON")
        reason=$(IFS='; '; echo "${parts[*]}")
    fi
    echo "${code}|${reason}"
}
