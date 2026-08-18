#!/usr/bin/env bash
# =============================================================================
# NFTBan - Portscan Trusted-Monitoring-Flow Exclusion
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_portscan_trusted_flow"
# meta:type="core"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-15"
# meta:description="Suppresses portscan EVENT GENERATION only for an exactly-declared, within-rate trusted monitoring flow tuple (source CIDR + protocol + destination port + optional destination selector + rate bound). Shell-emit suppression: a matched, within-rate flow is dropped before event emission and before the spool/classifier — the Go classifier, firewall, ban authority, whitelist, RBL, and BotScan are untouched. Any dimension mismatch OR an over-rate matching flow generates the normal event (abnormal behavior stays visible). Config /etc/nftban/conf.d/portscan/trusted-flows.conf is parsed never sourced/evaled, ships empty (opt-in, per-host). No 0.0.0.0/0 or ::/0, no wildcard source/proto/port/rate, no port ranges. Per-rule suppression + over-rate counters exposed; suppression is never silent. 0 Go; daemon byte-identical; schema 1.84.0."
# meta:inventory.files="/etc/nftban/conf.d/portscan/trusted-flows.conf,/var/lib/nftban/portscan-trusted-flow.state"
# meta:inventory.binaries="bash,flock,date"
# meta:inventory.env_vars="NFTBAN_PORTSCAN_CONFIG_DIR,NFTBAN_STATE_DIR,NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE"
# meta:inventory.config_files="/etc/nftban/conf.d/portscan/trusted-flows.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail

: "${NFTBAN_PORTSCAN_CONFIG_DIR:=${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/portscan}"
: "${NFTBAN_STATE_DIR:=/var/lib/nftban}"
: "${NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE:=${NFTBAN_PORTSCAN_CONFIG_DIR}/trusted-flows.conf}"
_PTF_STATE_FILE="${NFTBAN_PTF_STATE_FILE:-${NFTBAN_STATE_DIR}/portscan-trusted-flow.state}"
_PTF_RATE_WINDOW_SECS=60          # events_per_minute → fixed 60s window
_PTF_SUPPORTED_PROTOS=" tcp udp " # explicitly supported protocols only

# Parsed rule table (rebuilt per load; parallel arrays)
_PTF_LOADED=0
declare -a _PTF_SRC _PTF_PROTO _PTF_PORT _PTF_DST _PTF_RATE _PTF_KEY
_PTF_PARSE_ERRORS=0
_PTF_DECLARATIONS=0

# --------------------------------------------------------------------------
# CIDR containment (self-contained; mirrors the tested nftban_emulate logic)
# --------------------------------------------------------------------------
_ptf_ip_to_int() { local a b c d; IFS='.' read -r a b c d <<< "$1"; echo $(( (a<<24)+(b<<16)+(c<<8)+d )); }

_ptf_v4_in_cidr() { # ip cidr
    local ip="$1" cidr="$2" net prefix mask ipi neti
    if [[ "$cidr" != *"/"* ]]; then [[ "$ip" == "$cidr" ]]; return; fi
    net="${cidr%/*}"; prefix="${cidr#*/}"
    ipi=$(_ptf_ip_to_int "$ip"); neti=$(_ptf_ip_to_int "$net")
    if [[ "$prefix" -eq 0 ]]; then mask=0; else mask=$(( 0xFFFFFFFF << (32-prefix) )); fi
    [[ $(( ipi & mask )) -eq $(( neti & mask )) ]]
}

_ptf_v6_expand() { # ip -> 32 lowercase hex nibbles
    local ip="$1" expanded="" left right lg=0 rg=0 missing zeros="" g i
    if [[ "$ip" == *"::"* ]]; then
        left="${ip%%::*}"; right="${ip#*::}"
        if [[ -n "$left" ]]; then lg=$(echo "$left" | tr -cd ':' | wc -c); lg=$((lg+1)); fi
        if [[ -n "$right" ]]; then rg=$(echo "$right" | tr -cd ':' | wc -c); rg=$((rg+1)); fi
        missing=$((8-lg-rg))
        for ((i=0;i<missing;i++)); do zeros="${zeros}0000"; done
        if [[ -n "$left" ]]; then IFS=':' read -ra _g <<< "$left"; for g in "${_g[@]}"; do printf -v g "%04s" "$g"; expanded="${expanded}${g// /0}"; done; fi
        expanded="${expanded}${zeros}"
        if [[ -n "$right" ]]; then IFS=':' read -ra _g <<< "$right"; for g in "${_g[@]}"; do printf -v g "%04s" "$g"; expanded="${expanded}${g// /0}"; done; fi
    else
        IFS=':' read -ra _g <<< "$ip"; for g in "${_g[@]}"; do printf -v g "%04s" "$g"; expanded="${expanded}${g// /0}"; done
    fi
    echo "${expanded,,}"
}

_ptf_hex_to_bin() {
    local hex="$1" bin="" i
    for ((i=0;i<${#hex};i++)); do case "${hex:$i:1}" in
        0) bin+="0000";; 1) bin+="0001";; 2) bin+="0010";; 3) bin+="0011";; 4) bin+="0100";; 5) bin+="0101";;
        6) bin+="0110";; 7) bin+="0111";; 8) bin+="1000";; 9) bin+="1001";; a|A) bin+="1010";; b|B) bin+="1011";;
        c|C) bin+="1100";; d|D) bin+="1101";; e|E) bin+="1110";; f|F) bin+="1111";; esac; done
    echo "$bin"
}

_ptf_v6_in_cidr() { # ip cidr
    local ip="$1" cidr="$2" net prefix iph neth ipb netb
    if [[ "$cidr" != *"/"* ]]; then [[ "$(_ptf_v6_expand "$ip")" == "$(_ptf_v6_expand "$cidr")" ]]; return; fi
    net="${cidr%/*}"; prefix="${cidr#*/}"
    iph="$(_ptf_v6_expand "$ip")"; neth="$(_ptf_v6_expand "$net")"
    [[ "$prefix" -eq 0 ]] && return 0
    if [[ "$prefix" -eq 128 ]]; then [[ "$iph" == "$neth" ]]; return; fi
    ipb="$(_ptf_hex_to_bin "$iph")"; netb="$(_ptf_hex_to_bin "$neth")"
    [[ "${ipb:0:$prefix}" == "${netb:0:$prefix}" ]]
}

_ptf_ip_in_cidr() { # ip cidr  -> 0 if ip within cidr
    local ip="$1" cidr="$2"
    if [[ "$ip" == *:* ]]; then
        [[ "$cidr" == *:* ]] || return 1; _ptf_v6_in_cidr "$ip" "$cidr"
    else
        [[ "$cidr" == *:* ]] && return 1; _ptf_v4_in_cidr "$ip" "$cidr"
    fi
}

# --------------------------------------------------------------------------
# Validation helpers
# --------------------------------------------------------------------------
_ptf_is_ipv4() { [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local o; IFS='.' read -ra _o <<< "$1"; for o in "${_o[@]}"; do (( o>=0 && o<=255 )) || return 1; done; }
_ptf_is_ipv6() { [[ "$1" =~ ^[0-9A-Fa-f:]+$ && "$1" == *:* ]]; }
_ptf_is_ipv4_cidr() { [[ "$1" == */* ]] || return 1; local n="${1%/*}" p="${1#*/}"; _ptf_is_ipv4 "$n" && [[ "$p" =~ ^[0-9]+$ ]] && (( p>=1 && p<=32 )); }
_ptf_is_ipv6_cidr() { [[ "$1" == */* ]] || return 1; local n="${1%/*}" p="${1#*/}"; _ptf_is_ipv6 "$n" && [[ "$p" =~ ^[0-9]+$ ]] && (( p>=1 && p<=128 )); }

# Reject any shell metacharacter / control content (defence-in-depth; parsed, never eval'd)
_ptf_field_safe() { [[ ! "$1" =~ [\$\`\;\|\<\>\\\(\)\{\}\&\!\*\ \	] || "$1" == "*" ]]; }

# --------------------------------------------------------------------------
# Load + validate the trusted-flows config into the rule table.
# Row format: source_cidr|protocol|destination_port|destination_selector|rate_limit
# Returns 0 always (fail-safe: bad rows are skipped and counted, valid rows apply).
# --------------------------------------------------------------------------
nftban_portscan_trusted_flow_load() {
    _PTF_SRC=(); _PTF_PROTO=(); _PTF_PORT=(); _PTF_DST=(); _PTF_RATE=(); _PTF_KEY=()
    _PTF_PARSE_ERRORS=0; _PTF_DECLARATIONS=0; _PTF_LOADED=1
    # Belt-and-braces reap of temps orphaned by a process that died before the rename.
    # ⛔ WIRED HERE ON PURPOSE. An unreferenced reaper is the P1-6 defect class (a
    # correct prune that nothing ever invokes). load() is guarded by _PTF_LOADED, so
    # this runs ONCE PER PROCESS — never on the per-event hot path — and it is reached
    # because suppress() lazily calls load() on the first event it handles.
    _ptf_reap_orphan_temps
    local f="$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE"
    [[ -f "$f" ]] || { _ptf_state_set declarations 0; _ptf_state_set parse_errors 0; return 0; }

    local line lineno=0 src proto port dst rate key extra
    local -A seen_tuple=()
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno+1))
        line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        # exactly 5 columns (extra columns rejected)
        IFS='|' read -r src proto port dst rate extra <<< "$line"
        if [[ -n "$extra" || -z "$src" || -z "$proto" || -z "$port" || -z "$dst" || -z "$rate" ]]; then
            _ptf_perr "$lineno" "expected exactly 5 columns"; continue
        fi
        # per-field metachar safety
        if ! _ptf_field_safe "$src" || ! _ptf_field_safe "$proto" || ! _ptf_field_safe "$port" \
           || ! _ptf_field_safe "$dst" || ! _ptf_field_safe "$rate"; then
            _ptf_perr "$lineno" "unsafe characters"; continue
        fi
        # source: valid v4/v6 CIDR (a bare IP is treated as /32 or /128); NEVER 0.0.0.0/0 or ::/0
        if [[ "$src" == "0.0.0.0/0" || "$src" == "::/0" || "$src" == "*" ]]; then _ptf_perr "$lineno" "wildcard/any source forbidden"; continue; fi
        if _ptf_is_ipv4 "$src"; then src="${src}/32"; elif _ptf_is_ipv6 "$src"; then src="${src}/128"; fi
        if ! _ptf_is_ipv4_cidr "$src" && ! _ptf_is_ipv6_cidr "$src"; then _ptf_perr "$lineno" "invalid source CIDR"; continue; fi
        # protocol: explicitly supported only (no wildcard)
        proto="${proto,,}"
        if [[ "$_PTF_SUPPORTED_PROTOS" != *" $proto "* ]]; then _ptf_perr "$lineno" "unsupported/unspecified protocol"; continue; fi
        # destination port: single 1-65535 (no ranges, no 0, no all-port)
        if [[ ! "$port" =~ ^[0-9]+$ ]] || (( port<1 || port>65535 )); then _ptf_perr "$lineno" "invalid destination port (single 1-65535; no ranges/0/all)"; continue; fi
        # destination selector: * or a valid IP (interface selectors unsupported this release)
        # destination selector: * | bare IP | single-host CIDR (/32 or /128 → normalised to the IP)
        if [[ "$dst" != "*" ]]; then
            case "$dst" in
                */32)  _ptf_is_ipv4 "${dst%/32}"  && dst="${dst%/32}" ;;
                */128) _ptf_is_ipv6 "${dst%/128}" && dst="${dst%/128}" ;;
            esac
            if ! _ptf_is_ipv4 "$dst" && ! _ptf_is_ipv6 "$dst"; then _ptf_perr "$lineno" "destination selector must be * , a valid IP, or a /32|/128 single host"; continue; fi
        fi
        # rate: mandatory N/min, N>=1 (no 0, negative, missing, or unbounded)
        if [[ ! "$rate" =~ ^[1-9][0-9]*/min$ ]]; then _ptf_perr "$lineno" "rate must be a positive integer with /min suffix"; continue; fi
        key="${src}_${proto}_${port}_${dst}"
        # duplicate + overlapping/ambiguous rejection
        if [[ -n "${seen_tuple[$key]:-}" ]]; then _ptf_perr "$lineno" "duplicate tuple"; continue; fi
        local ov="${src}_${proto}_${port}"
        if [[ -n "${seen_tuple[ov:$ov]:-}" ]]; then _ptf_perr "$lineno" "overlapping/ambiguous rule for same source+proto+port (differing destination)"; continue; fi
        seen_tuple[$key]=1; seen_tuple[ov:$ov]=1
        _PTF_SRC+=("$src"); _PTF_PROTO+=("$proto"); _PTF_PORT+=("$port"); _PTF_DST+=("$dst")
        _PTF_RATE+=("${rate%/min}"); _PTF_KEY+=("$key")
        _PTF_DECLARATIONS=$((_PTF_DECLARATIONS+1))
    done < "$f"
    _ptf_state_set declarations "$_PTF_DECLARATIONS"
    _ptf_state_set parse_errors "$_PTF_PARSE_ERRORS"
    return 0
}

_ptf_perr() { _PTF_PARSE_ERRORS=$((_PTF_PARSE_ERRORS+1))
    printf 'nftban: portscan trusted-flows: line %s: %s (%s)\n' "$1" "$2" "$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE" >&2; }

# --------------------------------------------------------------------------
# Persistent state (counters + per-rule rate window). flock-guarded k=v store.
# --------------------------------------------------------------------------
_ptf_state_lock() { exec {_ptf_lockfd}>>"${_PTF_STATE_FILE}.lock" 2>/dev/null || return 1; flock -w 2 "$_ptf_lockfd" 2>/dev/null || return 1; }
_ptf_state_unlock() { [[ -n "${_ptf_lockfd:-}" ]] && exec {_ptf_lockfd}>&- 2>/dev/null; _ptf_lockfd=""; }
# NOTE: rule keys contain regex metacharacters (/ : * .) — use awk EXACT string
# comparison, never grep regex, for get/set.
_ptf_state_get() { [[ -f "$_PTF_STATE_FILE" ]] || { echo ""; return; }
    awk -F= -v k="$1" '$1==k{sub(/^[^=]*=/,"");print;exit}' "$_PTF_STATE_FILE" 2>/dev/null; }
# ⛔ THIS RUNS ON A PER-EVENT HOT PATH (reached from portscan_classic.sh per candidate
# event), so a leak here is unbounded in COUNT, not just in size.
#
# The previous form removed the temp only when `mv` FAILED. Death between mktemp and mv
# — signal, shell exit, host restart — left the temp behind forever, and this module
# writes into the DATA-DIR ROOT rather than a state/ subdirectory, so the orphans landed
# next to durable product state.
#
# Fix (a): the trap-guarded atomic write already used by nftban_file_ops.sh:47-50 — the
# temp is removed on ANY exit path, and the trap is cleared once the rename has
# succeeded so the now-canonical file is never touched.
_ptf_state_set() { # key value  (atomic replace)
    mkdir -p "$(dirname "$_PTF_STATE_FILE")" 2>/dev/null || return 0
    local tmp; tmp="$(mktemp "${_PTF_STATE_FILE}.XXXXXX" 2>/dev/null)" || return 0
    # RETURN scope, not EXIT: this is a library function on a hot path — an EXIT trap
    # here would fire at shell teardown and would clobber an unrelated later handler.
    trap 'rm -f -- "$tmp" 2>/dev/null' RETURN
    { [[ -f "$_PTF_STATE_FILE" ]] && awk -F= -v k="$1" '$1!=k' "$_PTF_STATE_FILE" 2>/dev/null; echo "$1=$2"; } > "$tmp" 2>/dev/null
    if mv -f "$tmp" "$_PTF_STATE_FILE" 2>/dev/null; then
        # renamed away: nothing left to remove, and the trap must NOT delete the
        # canonical file that now occupies the destination.
        tmp=""
        trap - RETURN
    fi
}

# Fix (b), belt-and-braces: reap orphans left by a process that died before the rename.
#
# ⛔ CLEANUP OWNERSHIP IS PROVEN, NOT ASSUMED:
#   CREATION  only _ptf_state_set creates "${_PTF_STATE_FILE}.XXXXXX". The panel modules
#             use the same TEMPLATE SHAPE but a different basename (enabled.conf) in a
#             different directory, so they are outside this namespace.
#   BOUND     the pattern is the exact basename plus exactly six suffix characters.
#             "${_PTF_STATE_FILE}.lock" has a FOUR-character suffix and cannot match.
#             The canonical state file has no suffix and cannot match.
#   ⛔ A directory-wide glob is NOT used. This module's state dir defaults to the
#     data-dir ROOT, where a broad "state.*" sweep would reach unrelated product state.
# ⛔ A KNOWN FILENAME PATTERN IS NOT PROOF OF OWNERSHIP — hence the constraints above.
_ptf_reap_orphan_temps() {
    local dir base
    dir="$(dirname "$_PTF_STATE_FILE")" || return 0
    base="$(basename "$_PTF_STATE_FILE")" || return 0
    [[ -d "$dir" ]] || return 0
    # -mmin +60 mirrors the existing reaper prior art in
    # nftban_unified_exporter_helpers.sh:54. The age floor keeps a live writer's
    # in-flight temp out of scope; it is not the safety mechanism on its own.
    find "$dir" -maxdepth 1 -type f -name "${base}.??????" -mmin +60 -delete 2>/dev/null || true
}
_ptf_state_incr() { local cur; cur="$(_ptf_state_get "$1")"; [[ "$cur" =~ ^[0-9]+$ ]] || cur=0; _ptf_state_set "$1" "$((cur + ${2:-1}))"; }

# Fixed 60s window per rule key. Echoes OK (record + within bound) or OVER.
_ptf_rate_check() { # key bound
    local key="$1" bound="$2" now win start count
    now=$(date +%s 2>/dev/null) || now=0
    win="$(_ptf_state_get "win_${key}")"
    start="${win%%:*}"; count="${win##*:}"
    [[ "$start" =~ ^[0-9]+$ ]] || start=0; [[ "$count" =~ ^[0-9]+$ ]] || count=0
    if (( now - start >= _PTF_RATE_WINDOW_SECS )); then start=$now; count=0; fi
    if (( count < bound )); then
        _ptf_state_set "win_${key}" "${start}:$((count+1))"; echo OK
    else
        _ptf_state_set "win_${key}" "${start}:${count}"; echo OVER
    fi
}

# --------------------------------------------------------------------------
# HOT PATH: return 0 (suppress) iff src∈CIDR ∧ proto= ∧ dport= ∧ dst(*|=) ∧ within-rate.
# Over-rate or any mismatch → return 1 (event generated by the normal detector).
# --------------------------------------------------------------------------
nftban_portscan_trusted_flow_suppress() { # src dst dport proto
    [[ "$_PTF_LOADED" -eq 1 ]] || nftban_portscan_trusted_flow_load
    (( _PTF_DECLARATIONS == 0 )) && return 1
    local src="$1" dst="$2" dport="$3" proto="${4,,}" i n
    n=${#_PTF_KEY[@]}
    for ((i=0;i<n;i++)); do
        [[ "$proto" == "${_PTF_PROTO[$i]}" ]] || continue
        [[ "$dport" == "${_PTF_PORT[$i]}" ]] || continue
        # destination match: * (any) or IP-equivalence — notation-robust (the runtime
        # dst arrives from the kernel log in EXPANDED IPv6 form, a config may be compressed).
        if [[ "${_PTF_DST[$i]}" != "*" ]]; then _ptf_ip_in_cidr "$dst" "${_PTF_DST[$i]}" || continue; fi
        _ptf_ip_in_cidr "$src" "${_PTF_SRC[$i]}" || continue
        # matched tuple — apply rate bound
        if [[ "$(_ptf_rate_check "${_PTF_KEY[$i]}" "${_PTF_RATE[$i]}")" == "OK" ]]; then
            _ptf_state_incr trusted_flow_suppressed_total
            _ptf_state_incr "suppressed_by_rule.${_PTF_KEY[$i]}"
            return 0   # suppress: no event, no spool entry
        else
            _ptf_state_incr trusted_flow_over_rate_total
            return 1   # over-rate: stays visible
        fi
    done
    return 1
}

# --------------------------------------------------------------------------
# Diagnostics / status render (never silent). Echoes human-readable summary.
# --------------------------------------------------------------------------
nftban_portscan_trusted_flow_render() {
    nftban_portscan_trusted_flow_load
    echo "  Trusted-flow exclusion (portscan EVENT GENERATION only — firewall & ban authority unchanged):"
    local decl="${_PTF_DECLARATIONS:-0}" perr="${_PTF_PARSE_ERRORS:-0}"
    local sup ovr; sup="$(_ptf_state_get trusted_flow_suppressed_total)"; ovr="$(_ptf_state_get trusted_flow_over_rate_total)"
    printf '    trusted_flow_declarations:   %s\n' "$decl"
    printf '    trusted_flow_parse_errors:   %s\n' "$perr"
    printf '    trusted_flow_suppressed_total: %s\n' "${sup:-0}"
    printf '    trusted_flow_over_rate_total:  %s  (matched tuples above the rate bound — kept VISIBLE)\n' "${ovr:-0}"
    if (( decl == 0 )); then
        printf '    (no declarations — nothing suppressed; default is empty/opt-in)\n'
        return 0
    fi
    local i
    for ((i=0;i<${#_PTF_KEY[@]};i++)); do
        printf '    rule: %s|%s|%s|%s|%s/min  suppressed=%s\n' \
            "${_PTF_SRC[$i]}" "${_PTF_PROTO[$i]}" "${_PTF_PORT[$i]}" "${_PTF_DST[$i]}" "${_PTF_RATE[$i]}" \
            "$(_ptf_state_get "suppressed_by_rule.${_PTF_KEY[$i]}" | grep -E '^[0-9]+$' || echo 0)"
    done
}

# CLI/diagnostic validation entry — returns rc 0 if config valid (or absent), 1 if any parse error.
nftban_portscan_trusted_flow_validate() {
    nftban_portscan_trusted_flow_load
    if (( _PTF_PARSE_ERRORS > 0 )); then
        printf '❌ %s parse error(s) in %s — those rows are ignored (fail-safe: not suppressed).\n' "$_PTF_PARSE_ERRORS" "$NFTBAN_PORTSCAN_TRUSTED_FLOWS_FILE" >&2
        return 1
    fi
    printf '✅ trusted-flows config valid — %s declaration(s).\n' "$_PTF_DECLARATIONS"
    return 0
}

export -f _ptf_ip_to_int _ptf_v4_in_cidr _ptf_v6_expand _ptf_hex_to_bin _ptf_v6_in_cidr _ptf_ip_in_cidr 2>/dev/null || true
export -f _ptf_is_ipv4 _ptf_is_ipv6 _ptf_is_ipv4_cidr _ptf_is_ipv6_cidr _ptf_field_safe _ptf_perr 2>/dev/null || true
# _ptf_reap_orphan_temps must be exported alongside these: nftban_portscan_trusted_flow_load
# is itself exported, and it calls the reaper. Without this, load() running in a
# subshell that inherits only the exported set would invoke an undefined command.
export -f _ptf_state_get _ptf_state_set _ptf_state_incr _ptf_rate_check _ptf_reap_orphan_temps 2>/dev/null || true
export -f nftban_portscan_trusted_flow_load nftban_portscan_trusted_flow_suppress 2>/dev/null || true
export -f nftban_portscan_trusted_flow_render nftban_portscan_trusted_flow_validate 2>/dev/null || true
