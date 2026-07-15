#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_botguard_explain" meta:type="lib" meta:version="1.191.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Read-only shell client for the BotGuard decision-cache explain_ip daemon verb (v1.191 8B inc6B1)"
# meta:inventory.files="/usr/lib/nftban/lib/nftban_botguard_explain.sh"
# meta:inventory.binaries="socat,jq"
# meta:inventory.env_vars="NFTBAN_DAEMON_SOCKET,NFTBAN_BOTGUARD_EXPLAIN_TIMEOUT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network="/run/nftban/nftband.sock"
# meta:inventory.privileges="nftban"

# Double-load prevention
[[ -n "${_NFTBAN_BOTGUARD_EXPLAIN_LOADED:-}" ]] && return 0 2>/dev/null || true
readonly _NFTBAN_BOTGUARD_EXPLAIN_LOADED=1

set -Eeuo pipefail

# v1.191 8B inc6B1 — READ-ONLY shell client for the daemon's explain_ip verb. Every function
# here is non-mutating: it queries the daemon's temporary BotGuard decision cache and never
# bans/greys/whitelists/blacklists, never adds/transitions/refreshes a cache entry, and never
# writes any on-disk or shell-side cache. All failures (daemon down, socket missing, socat/jq
# missing, unknown method, malformed JSON, cache unavailable) DEGRADE to a bounded
# "cache: unavailable" result and return 0 — they must never abort the calling command.

# Short query budget (seconds) — kept well under the default IPC timeout so an unhealthy
# daemon cannot stall an interactive read-only command.
NFTBAN_BOTGUARD_EXPLAIN_TIMEOUT="${NFTBAN_BOTGUARD_EXPLAIN_TIMEOUT:-2}"

# The bounded fallback returned on ANY failure. Note: cache_available=false and NO durable
# claim — absence/failure must never be read as "safe" or "not banned".
_nftban_botguard_explain_unavailable_json() {
    printf '%s' '{"cache_available":false,"present":false,"temporary":true,"state":"unavailable","durable_authority":"not_evaluated","source":"botguard_decision_cache","note":"cache: unavailable"}'
}

# nftban_botguard_explain_json <ip>
# Echoes the daemon's explain `data` object as JSON on success, or the bounded unavailable
# JSON on any failure. ALWAYS returns 0 (never aborts the caller). READ-ONLY.
nftban_botguard_explain_json() {
    local ip="${1:-}"
    if [[ -z "$ip" ]]; then
        _nftban_botguard_explain_unavailable_json; return 0
    fi
    # jq is required to parse the response safely; degrade if absent.
    if ! command -v jq >/dev/null 2>&1; then
        _nftban_botguard_explain_unavailable_json; return 0
    fi
    # The IPC helper must be available (sourced from nft_ipc.sh); degrade if not.
    if ! declare -f nft_ipc_request >/dev/null 2>&1; then
        _nftban_botguard_explain_unavailable_json; return 0
    fi

    local resp
    resp=$(NFTBAN_IPC_TIMEOUT="$NFTBAN_BOTGUARD_EXPLAIN_TIMEOUT" \
        nft_ipc_request "explain_ip" "{\"ip\":\"${ip}\"}" 2>/dev/null) || {
        _nftban_botguard_explain_unavailable_json; return 0
    }
    if [[ -z "$resp" ]]; then
        _nftban_botguard_explain_unavailable_json; return 0
    fi
    # Must be valid JSON AND a successful response.
    if ! printf '%s' "$resp" | jq -e '.success == true' >/dev/null 2>&1; then
        _nftban_botguard_explain_unavailable_json; return 0
    fi
    local data
    data=$(printf '%s' "$resp" | jq -ec '.data' 2>/dev/null) || {
        _nftban_botguard_explain_unavailable_json; return 0
    }
    if [[ -z "$data" || "$data" == "null" ]]; then
        _nftban_botguard_explain_unavailable_json; return 0
    fi
    printf '%s' "$data"
    return 0
}

# _nftban_botguard_explain_field <json> <jq_path> [default]
_nftban_botguard_explain_field() {
    local json="$1" path="$2" def="${3:-}"
    local v
    v=$(printf '%s' "$json" | jq -r "$path // empty" 2>/dev/null) || v=""
    [[ -z "$v" ]] && v="$def"
    printf '%s' "$v"
}

# nftban_botguard_explain_render <ip>
# Prints a clearly-labeled, separated TEMPORARY cache block (for `search` and `debug botguard`).
# READ-ONLY. Always returns 0; degrades to an explicit "unavailable" line on failure and never
# implies the IP is safe/not-banned.
nftban_botguard_explain_render() {
    local ip="${1:-}"
    local data avail present
    data=$(nftban_botguard_explain_json "$ip")
    avail=$(_nftban_botguard_explain_field "$data" '.cache_available' "false")

    echo "BotGuard decision-cache — CACHE ONLY — not currently enforced (not durable nft/kernel state; the kernel-set verdict above is authoritative):"
    echo "───────────────────────────────────────────────────────────────"
    if [[ "$avail" != "true" ]]; then
        echo "  BotGuard temporary cache: unavailable"
        echo "  (cache failure does NOT imply this IP is safe or not banned;"
        echo "   durable nft/kernel state is the source of truth)"
        return 0
    fi

    present=$(_nftban_botguard_explain_field "$data" '.present' "false")
    if [[ "$present" != "true" ]]; then
        echo "  State: unknown (no temporary BotGuard cache entry)"
        echo "  (absence is NOT proof of not-banned; see durable nft/kernel state)"
        return 0
    fi

    local state cls fam reason ev ttl first last expires
    state=$(_nftban_botguard_explain_field "$data" '.state' "unknown")
    cls=$(_nftban_botguard_explain_field "$data" '.request_class' "-")
    fam=$(_nftban_botguard_explain_field "$data" '.family' "-")
    reason=$(_nftban_botguard_explain_field "$data" '.reason' "-")
    ev=$(_nftban_botguard_explain_field "$data" '.evidence_summary' "-")
    ttl=$(_nftban_botguard_explain_field "$data" '.ttl_remaining_ms' "0")
    first=$(_nftban_botguard_explain_field "$data" '.first_seen' "")
    last=$(_nftban_botguard_explain_field "$data" '.last_seen' "")
    expires=$(_nftban_botguard_explain_field "$data" '.expires_at' "")

    echo "  State:             ${state} (temporary)"
    echo "  Request class:     ${cls}"
    echo "  Family:            ${fam}"
    echo "  Reason:            ${reason}"
    echo "  Evidence:          ${ev}"
    echo "  TTL remaining:     ${ttl} ms"
    [[ -n "$first" ]] && echo "  First seen:        ${first}"
    [[ -n "$last" ]] && echo "  Last seen:         ${last}"
    [[ -n "$expires" ]] && echo "  Expires at:        ${expires}"
    echo "  Durable authority: not_evaluated (durable whitelist/blacklist is separate)"
    return 0
}

# nftban_botguard_explain_emulate_note <ip>
# Prints a read-only "what BotGuard WOULD do" note for `emulate`, derived from the temporary
# cache state. Non-mutating; never changes the durable would-ban decision. Always returns 0.
nftban_botguard_explain_emulate_note() {
    local ip="${1:-}"
    local data avail present state
    data=$(nftban_botguard_explain_json "$ip")
    avail=$(_nftban_botguard_explain_field "$data" '.cache_available' "false")

    echo "BotGuard decision-cache — CACHE ONLY — not currently enforced (read-only; does NOT change the kernel-authoritative verdict above):"
    echo "───────────────────────────────────────────────────────────────"
    if [[ "$avail" != "true" ]]; then
        echo "  BotGuard temporary cache: unavailable (durable decision above is unaffected)"
        return 0
    fi
    present=$(_nftban_botguard_explain_field "$data" '.present' "false")
    if [[ "$present" != "true" ]]; then
        echo "  No temporary BotGuard cache entry for this IP (state: unknown)"
        return 0
    fi
    state=$(_nftban_botguard_explain_field "$data" '.state' "unknown")
    case "$state" in
        legit_temporarily)
            echo "  Would SUPPRESS a browser-like BotGuard batch signal (no ban from class/rate)" ;;
        ambiguous)
            echo "  Would DEFER (ambiguous/mixed — needs stronger dynamic/scanner/login evidence)" ;;
        blocked_temporarily)
            echo "  Would PRESERVE dynamic_abuse/login_api/scanner enforcement (temporary block active)" ;;
        candidate|checking)
            echo "  Under interim evaluation (candidate/checking) — no rate-ban without dynamic evidence" ;;
        *)
            echo "  Temporary state: ${state}" ;;
    esac
    return 0
}

# nftban_botguard_explain_subsystem_status
# Bounded, AGGREGATE read-only probe of the explain/cache subsystem (NO per-IP data). Echoes
# one of: "available" | "unavailable" | "helper_missing". Uses an RFC5737 documentation
# sentinel IP — the daemon ExplainIP is a read-only Peek, so a sentinel query only ever returns
# present=false and never mutates. Always returns 0.
nftban_botguard_explain_subsystem_status() {
    if ! declare -f nft_ipc_request >/dev/null 2>&1; then
        echo "helper_missing"; return 0
    fi
    local data avail
    data=$(nftban_botguard_explain_json "192.0.2.0")   # RFC5737 TEST-NET-1 sentinel
    avail=$(_nftban_botguard_explain_field "$data" '.cache_available' "false")
    if [[ "$avail" == "true" ]]; then
        echo "available"
    else
        echo "unavailable"
    fi
    return 0
}

# nftban_botguard_explain_diag_aggregate
# Bounded, sanitized AGGREGATE diagnostic block for `nftban support` (NO full-cache dump, NO
# per-IP listing). Read-only; degrade-safe; always returns 0.
nftban_botguard_explain_diag_aggregate() {
    local status
    status=$(nftban_botguard_explain_subsystem_status)
    echo "BotGuard temporary decision-cache diagnostics (TEMPORARY, read-only; NOT durable authority):"
    case "$status" in
        available)
            echo "  explain_ip query path: available" ;;
        helper_missing)
            echo "  explain client: not loaded (durable nft-set checks remain authoritative)" ;;
        *)
            echo "  explain_ip query path: unavailable (durable nft-set checks remain authoritative)" ;;
    esac
    echo "  Durable authority: not_evaluated by the temporary cache"
    echo "  Scope: aggregate only — no full-cache dump, no IP list (per-IP: nftban debug botguard <ip>)"
    return 0
}

# nftban_botguard_health_cache_diag <enabled>
# Emits a bounded health diagnostic line for the TEMPORARY cache. Prefixes the line with a
# WARN/INFO token so callers can map severity. When BotGuard is DISABLED it omits entirely
# (prints nothing) — cache-unavailable is never a warning while disabled. When ENABLED: INFO if
# the explain path is available, WARN otherwise. NEVER per-IP, NEVER a durable-authority claim,
# NEVER implies unprotected. Always returns 0.
nftban_botguard_health_cache_diag() {
    local enabled="${1:-false}"
    [[ "$enabled" == "true" ]] || return 0   # disabled → omit (no WARN)
    local status
    status=$(nftban_botguard_explain_subsystem_status 2>/dev/null || echo "unavailable")
    if [[ "$status" == "available" ]]; then
        echo "INFO: BotGuard temporary decision-cache diagnostics: explain_ip path available (TEMPORARY, read-only; not durable authority)"
    else
        echo "WARN: BotGuard temporary cache diagnostics unavailable; durable nft-set checks remain authoritative (TEMPORARY read-only diagnostic; does NOT imply unprotected)"
    fi
    return 0
}

export -f nftban_botguard_explain_subsystem_status 2>/dev/null || true
export -f nftban_botguard_explain_diag_aggregate 2>/dev/null || true
export -f nftban_botguard_health_cache_diag 2>/dev/null || true
export -f nftban_botguard_explain_json 2>/dev/null || true
export -f nftban_botguard_explain_render 2>/dev/null || true
export -f nftban_botguard_explain_emulate_note 2>/dev/null || true
export -f _nftban_botguard_explain_field 2>/dev/null || true
export -f _nftban_botguard_explain_unavailable_json 2>/dev/null || true
