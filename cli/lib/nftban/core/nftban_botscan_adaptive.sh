#!/usr/bin/env bash
# =============================================================================
# NFTBan - BotScan smart-adaptive controller (v1.207) — pressure/backlog/health
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_botscan_adaptive"
# meta:type="core"
# meta:header="BotScan smart-adaptive control loop"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-26"
# meta:description="v1.207 BotScan smart-adaptive controller. Pure-shell control loop that REUSES existing signals (watchdog pressure trend /var/lib/nftban/watchdog/trend_hourly.json + live /proc/loadavg + BotScan forward-cursor proc-offsets backlog) to derive a deterministic pressure_state (NORMAL/ELEVATED/HIGH/CRITICAL), backlog_state (DRAINING/STABLE/GROWING/STARVED) and scan_mode (FULL/PREFILTERED/FAIR_SHARE/SURVIVAL) that MODULATE the existing prefilter/budget/rotation; an additive run-state/counters file (botscan/runstate.json) + a health model that NEVER reports 0-clean when input was not scanned (disabled!=clean, blind!=clean, throttled visible); and a RECORDING-DISCIPLINE guard (a disabled+never-run module emits NO scan counters/noise). Reads existing CPU/RAM/load trend — does NOT create a duplicate host-vitals store. No nft schema change; no daemon."
# meta:input="watchdog trend_hourly.json, /proc/loadavg, BotScan proc-offsets, BOTSCAN_ENABLED"
# meta:output="botscan/runstate.json (additive); pressure_state/scan_mode/health_state strings"
# meta:depends="nftban_botscan.sh,nftban_watchdog.sh"
# meta:inventory.files="/var/lib/nftban/botscan/runstate.json"
# meta:inventory.binaries="awk,jq"
# meta:inventory.env_vars="BOTSCAN_ENABLED,BOTSCAN_SCAN_BUDGET_SECS,NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units="none"
# meta:inventory.network="none"
# meta:inventory.privileges="root:read-metrics"
# =============================================================================
set -Eeuo pipefail
# IFS intentionally NOT set globally (codebase convention; avoids ifs-tampering).
# Every field-splitting read sets IFS locally per-read (e.g. `IFS=' ' read ...`).
[[ -n "${NFTBAN_BOTSCAN_ADAPTIVE_LOADED:-}" ]] && return 0
readonly NFTBAN_BOTSCAN_ADAPTIVE_LOADED=1

: "${NFTBAN_DATA_DIR:=/var/lib/nftban}"
readonly _BS_RUNSTATE="${NFTBAN_DATA_DIR}/botscan/runstate.json"
readonly _BS_OFFSET_DIR="${NFTBAN_DATA_DIR}/botscan/proc-offsets"
readonly _BS_WATCHDOG_TREND="${NFTBAN_DATA_DIR}/watchdog/trend_hourly.json"
# v1.208 — durable BotScan pressure/mode trend (append-only, bounded). REUSES the
# watchdog trend for host load/mem/iowait; this file holds only BotScan's own
# per-run decision + the cheap load_ratio. NO duplicate host-vitals store.
readonly _BS_TREND="${NFTBAN_DATA_DIR}/botscan/trend.jsonl"
: "${BOTSCAN_TREND_RETENTION:=500}"   # keep last N records (bounded)

# --- cheap live load ratio (load1 / nproc) ----------------------------------
nftban_botscan_load_ratio() {
    local load1 _ rest ncpu
    if ! IFS=' ' read -r load1 _ rest < /proc/loadavg 2>/dev/null; then echo "0"; return 0; fi
    ncpu=$(nproc 2>/dev/null || echo 1); [[ "$ncpu" -ge 1 ]] || ncpu=1
    awk -v l="$load1" -v c="$ncpu" 'BEGIN{ if(c<1)c=1; printf "%.2f", l/c }'
}

# --- smoothed pressure inputs from the EXISTING watchdog trend (no new store) -
# Echoes "load5 mem_pct iowait_pct" (best-effort; "0 0 0" if trend absent).
nftban_botscan_watchdog_pressure() {
    if [[ -f "$_BS_WATCHDOG_TREND" ]] && command -v jq &>/dev/null; then
        jq -r '(.samples // []) | (last // {}) | "\(.load_5m // 0) \(.mem_percent // 0) \(.iowait_percent // 0)"' \
            "$_BS_WATCHDOG_TREND" 2>/dev/null || echo "0 0 0"
    else
        echo "0 0 0"
    fi
}

# --- per-vhost backlog from the EXISTING forward cursor (file_size - offset) --
# Args: log files. Echoes "backlog_bytes vhosts_behind".
nftban_botscan_backlog() {
    local bytes=0 behind=0 f base off sz
    for f in "$@"; do
        [[ -f "$f" ]] || continue
        sz=$(stat -c %s "$f" 2>/dev/null || echo 0)
        base=$(printf '%s' "$f" | tr '/' '_')
        off=0
        [[ -r "$_BS_OFFSET_DIR/$base" ]] && IFS= read -r off < "$_BS_OFFSET_DIR/$base" 2>/dev/null
        [[ "$off" =~ ^[0-9]+$ ]] || off=0
        if [[ "$sz" -gt "$off" ]]; then bytes=$(( bytes + sz - off )); behind=$(( behind + 1 )); fi
    done
    echo "$bytes $behind"
}

# --- deterministic pressure_state ------------------------------------------
# Args: load_ratio runtime_ratio budget_hit_recent(0/1) mem_pct iowait_pct
nftban_botscan_pressure_state() {
    local lr="${1:-0}" rr="${2:-0}" bh="${3:-0}" mem="${4:-0}" io="${5:-0}"
    awk -v lr="$lr" -v rr="$rr" -v bh="$bh" -v mem="$mem" -v io="$io" 'BEGIN{
        st="NORMAL"
        if (lr>=1.0 || rr>=0.5 || mem>=80 || io>=20) st="ELEVATED"
        if (lr>=2.0 || rr>=0.7 || mem>=90 || io>=35) st="HIGH"
        if (lr>=4.0 || rr>=0.9 || bh==1)             st="CRITICAL"
        print st
    }'
}

# --- backlog_state ----------------------------------------------------------
# Args: backlog_bytes prev_backlog_bytes
nftban_botscan_backlog_state() {
    local now="${1:-0}" prev="${2:-0}"
    [[ "$now" =~ ^[0-9]+$ ]] || now=0; [[ "$prev" =~ ^[0-9]+$ ]] || prev=0
    if   [[ "$now" -eq 0 ]]; then echo "DRAINING"
    elif [[ "$now" -gt $(( prev + prev/4 + 1 )) ]]; then echo "GROWING"
    elif [[ "$now" -lt $(( prev - prev/4 )) ]]; then echo "DRAINING"
    elif [[ "$now" -gt 67108864 ]]; then echo "STARVED"   # >64MiB behind = starved
    else echo "STABLE"; fi
}

# --- scan_mode from pressure + backlog --------------------------------------
nftban_botscan_select_mode() {
    local pressure="${1:-NORMAL}" backlog="${2:-STABLE}"
    case "$pressure" in
        CRITICAL) echo "SURVIVAL" ;;
        HIGH)     echo "FAIR_SHARE" ;;
        ELEVATED) [[ "$backlog" == "STARVED" || "$backlog" == "GROWING" ]] && echo "FAIR_SHARE" || echo "PREFILTERED" ;;
        *)        [[ "$backlog" == "STARVED" ]] && echo "FAIR_SHARE" || echo "FULL" ;;
    esac
}

# --- health_state (INVARIANT: 0-clean only if input was actually scanned) ----
# Args: enabled(true/false) lines_scanned bots_found budget_hit backlog_state has_input(0/1) error(0/1)
nftban_botscan_health_state() {
    local en="${1:-true}" scanned="${2:-0}" bots="${3:-0}" bh="${4:-0}" bl="${5:-STABLE}" hasin="${6:-0}" err="${7:-0}"
    [[ "$err" == "1" ]] && { echo "ERROR_RUNTIME_FAILURE"; return; }
    [[ "$en" != "true" ]] && { echo "DISABLED_BY_CONFIG"; return; }      # disabled != clean
    [[ "$bh" == "1" ]] && { echo "DEGRADED_BUDGET_HIT"; return; }
    [[ "$bl" == "GROWING" || "$bl" == "STARVED" ]] && { echo "DEGRADED_BACKLOG_GROWING"; return; }
    if [[ "${scanned:-0}" -eq 0 ]]; then
        # zero scanned: blind if there WAS input, throttled is caller-set; NEVER clean
        [[ "$hasin" == "1" ]] && { echo "DEGRADED_INPUT_BLIND"; return; }
        echo "DEGRADED_INPUT_BLIND"; return
    fi
    [[ "${bots:-0}" -gt 0 ]] && { echo "OK_SCANNED_BOTS_FOUND"; return; }
    echo "OK_SCANNED_NO_BOTS"
}

# --- RECORDING DISCIPLINE: should we record this run at all? -----------------
# Returns 0 (record) only if BotScan is enabled OR a meaningful prior run-state
# exists. A disabled+never-run module records nothing (no counters/noise).
nftban_botscan_should_record() {
    [[ "${BOTSCAN_ENABLED:-true}" == "true" ]] && return 0
    [[ -f "$_BS_RUNSTATE" ]] && return 0   # previously ran → preserve/mark disabled
    return 1                                # disabled + never ran → no record
}

# --- write additive run-state/counters (schema-free) ------------------------
# Reads prior counters to accumulate *_total. Honors recording discipline.
nftban_botscan_record_runstate() {
    # k=v pairs on argv: ts dur lines_seen lines_scanned lines_prefiltered
    #   lines_skipped_pressure backlog_bytes backlog_lines vhosts_scanned
    #   vhosts_deferred signals bans already_banned_skipped pressure_state
    #   scan_mode backlog_state health_state disabled_reason
    local -A v=(); local kv
    for kv in "$@"; do v["${kv%%=*}"]="${kv#*=}"; done
    if ! nftban_botscan_should_record; then return 0; fi
    mkdir -p "${_BS_RUNSTATE%/*}" 2>/dev/null || true
    # accumulate totals from prior file
    local p_bh=0 p_seen=0 p_scan=0 p_pf=0 p_skip=0 p_sig=0 p_ban=0 p_abs=0
    if [[ -f "$_BS_RUNSTATE" ]] && command -v jq &>/dev/null; then
        IFS=' ' read -r p_bh p_seen p_scan p_pf p_skip p_sig p_ban p_abs < <(
            jq -r '"\(.budget_hit_total//0) \(.lines_seen_total//0) \(.lines_scanned_total//0) \(.lines_prefiltered_total//0) \(.lines_skipped_pressure_total//0) \(.signals_emitted_total//0) \(.bans_emitted_total//0) \(.already_banned_skipped_total//0)"' "$_BS_RUNSTATE" 2>/dev/null) || true
    fi
    local en="${BOTSCAN_ENABLED:-true}"
    cat > "${_BS_RUNSTATE}.tmp" <<EOF
{
  "enabled": ${en/true/true},
  "last_run_ts": ${v[ts]:-0},
  "last_duration_sec": ${v[dur]:-0},
  "budget_hit_total": $(( p_bh + ${v[budget_hit]:-0} )),
  "lines_seen_total": $(( p_seen + ${v[lines_seen]:-0} )),
  "lines_scanned_total": $(( p_scan + ${v[lines_scanned]:-0} )),
  "lines_prefiltered_total": $(( p_pf + ${v[lines_prefiltered]:-0} )),
  "lines_skipped_pressure_total": $(( p_skip + ${v[lines_skipped_pressure]:-0} )),
  "backlog_bytes": ${v[backlog_bytes]:-0},
  "backlog_lines": ${v[backlog_lines]:-0},
  "vhosts_scanned": ${v[vhosts_scanned]:-0},
  "vhosts_deferred": ${v[vhosts_deferred]:-0},
  "signals_emitted_total": $(( p_sig + ${v[signals]:-0} )),
  "bans_emitted_total": $(( p_ban + ${v[bans]:-0} )),
  "already_banned_skipped_total": $(( p_abs + ${v[already_banned_skipped]:-0} )),
  "last_budget_hit": ${v[budget_hit]:-0},
  "pressure_state": "${v[pressure_state]:-NORMAL}",
  "scan_mode": "${v[scan_mode]:-FULL}",
  "backlog_state": "${v[backlog_state]:-STABLE}",
  "health_state": "${v[health_state]:-OK_SCANNED_NO_BOTS}",
  "disabled_reason": "${v[disabled_reason]:-}"
}
EOF
    mv -f "${_BS_RUNSTATE}.tmp" "$_BS_RUNSTATE" 2>/dev/null || rm -f "${_BS_RUNSTATE}.tmp"
    # v1.208 — append one durable trend record (gated by should_record above).
    nftban_botscan_trend_append v
    return 0
}

# --- v1.208 durable trend append (append-only, bounded, dedupe-aware) --------
# Args: name of the assoc array `v` populated in record_runstate (passed by name).
nftban_botscan_trend_append() {
    local -n _v="$1" 2>/dev/null || return 0
    local hs="${_v[health_state]:-OK_SCANNED_NO_BOTS}"
    mkdir -p "${_BS_TREND%/*}" 2>/dev/null || true
    # Dedupe consecutive identical ZERO-PROGRESS records. A no-web host (no logs →
    # NO_INPUT_DISCOVERED) or an empty-log host (logs found, 0 scanned →
    # DEGRADED_INPUT_BLIND) re-emits the same state every cycle — do NOT fill the
    # trend with identical no-progress lines. Any record that scanned > 0 lines is
    # always recorded (real signal); a state CHANGE is always recorded.
    local _scanned="${_v[lines_scanned]:-0}"
    if [[ "${_scanned:-0}" -eq 0 && -s "$_BS_TREND" ]]; then
        local _last; _last=$(tail -1 "$_BS_TREND" 2>/dev/null)
        [[ "$_last" == *"\"health_state\":\"$hs\""* ]] && return 0
    fi
    local _host; _host=$(hostname -s 2>/dev/null || echo unknown)
    local rec
    rec=$(printf '{"ts":%s,"host":"%s","source":"botscan","health_state":"%s","pressure_state":"%s","scan_mode":"%s","backlog_state":"%s","last_duration_sec":%s,"budget_hit":%s,"lines_scanned":%s,"bans_emitted":%s,"vhosts_scanned":%s,"vhosts_deferred":%s,"backlog_bytes":%s,"load_ratio":"%s"}' \
        "${_v[ts]:-0}" "$_host" "$hs" "${_v[pressure_state]:-NORMAL}" "${_v[scan_mode]:-FULL}" "${_v[backlog_state]:-STABLE}" \
        "${_v[dur]:-0}" "${_v[budget_hit]:-0}" "${_v[lines_scanned]:-0}" "${_v[bans]:-0}" \
        "${_v[vhosts_scanned]:-0}" "${_v[vhosts_deferred]:-0}" "${_v[backlog_bytes]:-0}" "${_v[load_ratio]:-0}")
    # atomic append under flock (processor is single-instance, but guard anyway)
    {
        flock -w 2 9 2>/dev/null || true
        printf '%s\n' "$rec" >> "$_BS_TREND"
        # bounded retention: trim to last N
        local _n; _n=$(wc -l < "$_BS_TREND" 2>/dev/null || echo 0)
        if [[ "${_n:-0}" -gt "${BOTSCAN_TREND_RETENTION:-500}" ]]; then
            tail -n "${BOTSCAN_TREND_RETENTION:-500}" "$_BS_TREND" > "${_BS_TREND}.tmp" 2>/dev/null \
                && mv -f "${_BS_TREND}.tmp" "$_BS_TREND" 2>/dev/null || rm -f "${_BS_TREND}.tmp"
        fi
    } 9>>"$_BS_TREND" 2>/dev/null || true
    return 0
}

# --- v1.208 trend history summary (answers the operator questions) ----------
nftban_botscan_history() {
    if [[ ! -s "$_BS_TREND" ]]; then echo "No BotScan trend history yet ($_BS_TREND absent/empty)."; return 0; fi
    command -v jq >/dev/null 2>&1 || { echo "(jq unavailable — raw tail:)"; tail -10 "$_BS_TREND"; return 0; }
    local total; total=$(wc -l < "$_BS_TREND" 2>/dev/null)
    echo "BotScan trend history — $total records ($_BS_TREND)"
    echo "─────────────────────────────────────────"
    echo "  Scan modes:"
    jq -r '.scan_mode' "$_BS_TREND" 2>/dev/null | sort | uniq -c | awk '{printf "    %-12s %s\n", $2, $1}'
    echo "  Health states:"
    jq -r '.health_state' "$_BS_TREND" 2>/dev/null | sort | uniq -c | awk '{printf "    %-26s %s\n", $2, $1}'
    local bh; bh=$(jq -r 'select(.budget_hit==1)|.host' "$_BS_TREND" 2>/dev/null | sort | uniq -c | awk '{printf "%s(%s) ", $2, $1}')
    echo "  Budget-hit by host: ${bh:-none}"
    local grow; grow=$(jq -r 'select(.backlog_state=="GROWING")|.host' "$_BS_TREND" 2>/dev/null | sort -u | tr '\n' ' ')
    echo "  Backlog GROWING (any record): ${grow:-none}"
    echo "  Last OK scan:       $(jq -rc 'select(.health_state|startswith("OK_"))|"\(.ts) \(.host) \(.scan_mode) scanned=\(.lines_scanned)"' "$_BS_TREND" 2>/dev/null | tail -1 || echo none)"
    echo "  Last DEGRADED scan: $(jq -rc 'select(.health_state|startswith("DEGRADED_"))|"\(.ts) \(.host) \(.health_state) backlog=\(.backlog_state)"' "$_BS_TREND" 2>/dev/null | tail -1 || echo none)"
    return 0
}

# --- one-line operator advisory from the run-state --------------------------
nftban_botscan_advisory() {
    [[ "${BOTSCAN_ENABLED:-true}" != "true" ]] && { echo "BotScan: DISABLED (by config) — not scanning; not 'clean'."; return; }
    [[ -f "$_BS_RUNSTATE" ]] && command -v jq &>/dev/null || { echo "BotScan: no run recorded yet."; return; }
    local hs mode pr scan bans dur bl
    IFS=' ' read -r hs mode pr scan bans dur bl < <(jq -r '"\(.health_state) \(.scan_mode) \(.pressure_state) \(.lines_scanned_total) \(.bans_emitted_total) \(.last_duration_sec) \(.backlog_state)"' "$_BS_RUNSTATE" 2>/dev/null)
    case "$hs" in
        OK_SCANNED_*)              echo "BotScan: OK — mode=$mode, scanned ${scan} lines, ${bans} bans, backlog ${bl,,}." ;;
        WARN_PARTIAL_PROGRESS|DEGRADED_PRESSURE_THROTTLED) echo "BotScan: WARN — $hs (mode=$mode, pressure=$pr); coverage reduced but VISIBLE (not clean)." ;;
        DEGRADED_*)                echo "BotScan: DEGRADED — $hs (mode=$mode, pressure=$pr); NOT clean." ;;
        DISABLED_BY_CONFIG)        echo "BotScan: DISABLED (by config)." ;;
        NO_INPUT_DISCOVERED)       echo "BotScan: NO INPUT — no web access logs found on this host (not scanning; not 'clean'). Informational on a non-web host." ;;
        *)                         echo "BotScan: $hs (mode=$mode)." ;;
    esac
    [[ "$pr" == "HIGH" || "$pr" == "CRITICAL" ]] && echo "Host pressure: $pr — primary load may be the web/db stack; consider web-layer mitigation."
}
