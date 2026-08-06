#!/usr/bin/env bash
# =============================================================================
# NFTBan - shared whitelist member readers (v1.228.5)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="whitelist_members"
# meta:type="lib"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-06"
# meta:description="Canonical whitelist member readers, MOVED here from cmd_whitelist.sh so the operator verify path and the runtime rebuild/reconcile path consume ONE implementation. Previously these were private to cmd_whitelist.sh, and cmd_firewall.sh reimplemented expected-vs-live comparison with its own comm -23 plus a second EXPIRES_AT parser. That duplicate was not merely redundant, it was WRONG: nft coalesces adjacent CIDRs into intervals, so a string comparison reports false drift for identical coverage (192.0.2.0/25 + 192.0.2.128/25 vs 192.0.2.0-192.0.2.255). Range-aware comparison is owned by the Go oracle 'nftban-core whitelist-coverage' (cmd/nftban-core/main.go:168); these readers only ASSEMBLE its inputs. Expiry semantics live here and nowhere else: future=active, expired=excluded, missing=durable/always-required, MALFORMED=fail open and treat as ACTIVE."
# meta:inventory.files="/etc/nftban/whitelist.d/*.conf"
# meta:inventory.binaries="nft,date,awk,grep"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="/etc/nftban/whitelist.d"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="reads nft sets"
# =============================================================================

# Guard against double-sourcing: both cmd_whitelist.sh and cmd_firewall.sh source this.
[[ -n "${_NFTBAN_WHITELIST_MEMBERS_LOADED:-}" ]] && return 0
_NFTBAN_WHITELIST_MEMBERS_LOADED=1

_NFTBAN_WHITELIST_CONF_DIR="/etc/nftban/whitelist.d"

_nftban_wl_read_kernel_set() {
    local table="$1" set_name="$2" raw tok
    # shellcheck disable=SC2086
    raw=$(timeout 10s nft list set ${table} ${set_name} 2>/dev/null) || return 1
    # Empty/absent elements block is a valid (empty) set, not an error.
    [[ "$raw" == *"elements"* ]] || return 0
    printf '%s\n' "$raw" \
        | tr '\n' ' ' \
        | sed -n 's/.*elements = { *\([^}]*\).*/\1/p' \
        | tr ',' '\n' \
        | while IFS= read -r tok || [[ -n "$tok" ]]; do
            [[ -z "${tok//[[:space:]]/}" ]] && continue
            local k; k="$(_nftban_wl_norm_key "$tok")"
            [[ -n "$k" ]] && printf '%s\n' "$k"
          done
    return 0
}

_nftban_wl_read_baseline() {
    local fam="$1" f line before_hash ip
    [[ -d "$_NFTBAN_WHITELIST_CONF_DIR" ]] || return 0
    for f in "$_NFTBAN_WHITELIST_CONF_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            local trimmed="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$trimmed" ]] && continue
            [[ "${trimmed:0:1}" == "#" ]] && continue
            # Durable baseline = NO EXPIRES_AT marker (session/TTL entries excluded).
            [[ "$line" == *EXPIRES_AT=* ]] && continue
            before_hash="${line%%#*}"
            # shellcheck disable=SC2086
            ip=$(printf '%s' $before_hash | awk '{print $1}')
            [[ -z "$ip" ]] && continue
            if [[ "$fam" == "6" && "$ip" == *:* ]]; then
                printf '%s\n' "${ip,,}"
            elif [[ "$fam" == "4" && "$ip" != *:* ]]; then
                printf '%s\n' "${ip,,}"
            fi
        done < "$f"
    done
}

_nftban_wl_read_sessions() {
    local fam="$1" f line before_hash ip expires_at expires_unix now_unix
    now_unix=$(date -u +%s 2>/dev/null) || now_unix=0
    [[ -d "$_NFTBAN_WHITELIST_CONF_DIR" ]] || return 0
    for f in "$_NFTBAN_WHITELIST_CONF_DIR"/*.conf; do
        [[ -e "$f" ]] || continue
        while IFS= read -r line || [[ -n "$line" ]]; do
            local trimmed="${line#"${line%%[![:space:]]*}"}"
            [[ -z "$trimmed" ]] && continue
            [[ "${trimmed:0:1}" == "#" ]] && continue
            [[ "$line" == *EXPIRES_AT=* ]] || continue
            expires_at=$(printf '%s' "$line" | grep -oE 'EXPIRES_AT=[^ ]+' | head -1 | cut -d= -f2)
            [[ -z "$expires_at" ]] && continue
            # v1.228.5 FAIL-OPEN: an UNPARSEABLE EXPIRES_AT must NOT drop the member from the
            # expected set. Dropping it manufactures false convergence (the runtime path stops
            # requiring a real whitelist member) and, on the operator surface, flags that member
            # as IN-KERNEL-NOT-IN-BASELINE "possible injection" purely because a comment failed
            # to parse. Malformed => treat as an ACTIVE session and emit it.
            if ! expires_unix=$(date -u -d "$expires_at" +%s 2>/dev/null); then
                printf 'whitelist: malformed EXPIRES_AT=%s in %s — treating entry as ACTIVE\n' \
                    "$expires_at" "$f" >&2
                expires_unix=""
            fi
            [[ -n "$expires_unix" && "$expires_unix" -le "$now_unix" ]] && continue   # expired => not a current session
            before_hash="${line%%#*}"
            # shellcheck disable=SC2086
            ip=$(printf '%s' $before_hash | awk '{print $1}')
            [[ -z "$ip" ]] && continue
            if [[ "$fam" == "6" && "$ip" == *:* ]]; then
                printf '%s\n' "${ip,,}"
            elif [[ "$fam" == "4" && "$ip" != *:* ]]; then
                printf '%s\n' "${ip,,}"
            fi
        done < "$f"
    done
}

_nftban_wl_json_arr() {
    local first=1 x; printf '['
    for x in "$@"; do [[ $first -eq 1 ]] && first=0 || printf ','; printf '"%s"' "$x"; done
    printf ']'
}
