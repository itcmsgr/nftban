#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="capability_management_access" meta:type="lib" meta:version="1.229.12" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="B03 adapter: observe whether management-access protection is capable, degraded, incapable or unknown"
# meta:inventory.files="/etc/nftban/whitelist.d/*.conf"
# meta:inventory.binaries=""
# meta:inventory.env_vars="SSH_CLIENT,SSH_CONNECTION"
# meta:inventory.config_files="/etc/nftban/whitelist.d/*.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

[[ -n "${_NFTBAN_CAP_MGMT_ACCESS_LOADED:-}" ]] && return 0
_NFTBAN_CAP_MGMT_ACCESS_LOADED=1

# v1.229.12 P0-2: bounded non-whitespace predicate. This adapter tests
# `nft list set` and `nft -a list chain` output for emptiness, and both are
# ruleset-sized — exactly the input class where ${var//[[:space:]]/} costs
# seconds. shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/shell_predicates.sh" 2>/dev/null || true

# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/capability.sh" 2>/dev/null || true

# =============================================================================
# B03 ADAPTER — MANAGEMENT-ACCESS PROTECTION
# =============================================================================
# CAPABILITY SCOPE IS `management-access protection`, NOT `firewall health`.
#
#   management address known
#     -> durable whitelist authority contains it   (/etc/nftban/whitelist.d/*.conf)
#     -> effective projection contains it          (whitelist_ipv4 / whitelist_ipv6)
#     -> whitelist ACCEPT rule exists
#     -> ACCEPT precedes the managed DROP
#     -> CAPABLE
#
# ⛔ THIS ADAPTER OBSERVES ONLY. It does not decide where the management address
# should come from, does not populate the whitelist, and repairs nothing.
#   P12-E05 owns durability and correction.
#   This adapter owns truthful capability observation.
#
# ⛔ CAPABLE_IDLE / CAPABLE_ACTIVE DO NOT APPLY HERE. This is DECLARATIVE
# protection, not an event stream: there is no "activity" whose absence could be
# mistaken for a fault. A capability model can share one truth discipline
# without forcing identical lifecycle semantics on every subsystem.
#
# ⛔ PRIVACY: the address is resolved at runtime and never written to a file by
# this library. Callers must not log it into tracked artefacts.
# =============================================================================

# nftban_capability_management_access [address]
# Emits: <CAPABILITY> <detail>
nftban_capability_management_access() {
    local addr="${1:-}"

    # --- the address itself. Unknown address => UNKNOWN capability, never a pass.
    if [[ -z "$addr" ]]; then
        if declare -f nftban_ssh_active_admin_ip >/dev/null 2>&1; then
            addr=$(nftban_ssh_active_admin_ip 2>/dev/null || true)
        elif [[ -n "${SSH_CLIENT:-}" ]]; then addr="${SSH_CLIENT%% *}"
        elif [[ -n "${SSH_CONNECTION:-}" ]]; then addr="${SSH_CONNECTION%% *}"
        fi
    fi
    [[ -z "$addr" ]] && { printf 'UNKNOWN no management address could be resolved'; return 0; }

    local fam="ipv4" wlset="whitelist_ipv4" table="${NFTBAN_TABLE_IPV4:-ip nftban}"
    if [[ "$addr" == *:* ]]; then
        fam="ipv6"; wlset="whitelist_ipv6"; table="${NFTBAN_TABLE_IPV6:-ip6 nftban}"
    fi

    # --- durable authority ----------------------------------------------------
    # ⛔ A MATCH IN A FILE IS NOT A DURABLE DECLARATION. `00-session.conf` holds
    # TIME-BOUNDED operator-session grants carrying `# EXPIRES_AT=<RFC3339>`, and
    # the whitelist loader SKIPS EXPIRED ENTRIES AT LOAD TIME. The file persists
    # long after its entries stop counting, so grepping filenames would report an
    # expired grant as durable protection — which is how this adapter first
    # mis-classified a host whose projection was in fact CORRECT.
    #
    # A line is a durable declaration only if it is not commented out and either
    # carries no EXPIRES_AT (an unbounded entry) or one still in the future.
    local wl_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/whitelist.d"
    local durable="unknown" durable_in="" expired_in=""
    if [[ -d "$wl_dir" ]]; then
        local files; files=$(find "$wl_dir" -maxdepth 1 -name '*.conf' -readable 2>/dev/null)
        if [[ -n "$files" ]]; then
            durable="no"
            local f line exp now base
            now=$(date -u +%s 2>/dev/null || echo 0)
            for f in $files; do
                base=$(basename "$f")
                while IFS= read -r line; do
                    [[ "$line" =~ ^[[:space:]]*# ]] && continue
                    [[ "$line" == *"$addr"* ]] || continue
                    exp=$(printf '%s' "$line" | grep -oE 'EXPIRES_AT=[^[:space:]]+' | head -1 | cut -d= -f2)
                    if [[ -z "$exp" ]]; then
                        durable="yes"; durable_in+="$base "
                    else
                        local ets; ets=$(date -u -d "$exp" +%s 2>/dev/null || echo 0)
                        if [[ "$ets" -gt "$now" ]]; then durable="yes"; durable_in+="$base "
                        else expired_in+="$base "; fi
                    fi
                done < "$f"
            done
        fi
    fi

    # --- effective projection -------------------------------------------------
    # ⛔ An unreadable set is UNKNOWN, never "absent". Absence of proof of
    # membership is not proof of absence of membership.
    local projected="unknown" raw
    if raw=$(nft list set ${table} "$wlset" 2>/dev/null); then
        if nftban_has_non_whitespace "$raw"; then
            printf '%s' "$raw" | grep -qF "$addr" && projected="yes" || projected="no"
        fi
    fi

    # --- rule order: ACCEPT must precede the managed DROP ---------------------
    local order="unknown" chain
    if chain=$(nft -a list chain ${table} input 2>/dev/null); then
        if nftban_has_non_whitespace "$chain"; then
            local a d
            a=$(printf '%s' "$chain" | grep -n "@${wlset}" | grep -m1 accept | cut -d: -f1)
            d=$(printf '%s' "$chain" | grep -nE "@blacklist[a-z_]*${fam#ip}" | grep -m1 drop | cut -d: -f1)
            if [[ -n "$a" && -n "$d" ]]; then
                [[ "$a" -lt "$d" ]] && order="yes" || order="no"
            fi
        fi
    fi

    # --- classify -------------------------------------------------------------
    # Ordered so that an unreadable input can never render as protected.
    if [[ "$durable" == "unknown" || "$projected" == "unknown" ]]; then
        printf 'UNKNOWN management address %s: durable=%s projected=%s (evidence unreadable — NOT a pass)' \
            "$fam" "$durable" "$projected"
    elif [[ "$durable" == "no" && "$projected" == "no" ]]; then
        if [[ -n "$expired_in" ]]; then
            printf 'INCAPABLE management address has only an EXPIRED session grant (%s) and is absent from the %s projection — no durable declaration exists' \
                "${expired_in% }" "$wlset"
        else
            printf 'INCAPABLE management address is absent from BOTH the durable authority and the %s projection' "$wlset"
        fi
    elif [[ "$durable" == "yes" && "$projected" == "no" ]]; then
        # The live dns4 shape: declared but never projected.
        printf 'DEGRADED management address is declared durably (%s) but is ABSENT from the %s projection' \
            "${durable_in% }" "$wlset"
    elif [[ "$order" == "no" ]]; then
        printf 'DEGRADED management address is projected but the whitelist ACCEPT does NOT precede the managed DROP'
    elif [[ "$order" == "unknown" ]]; then
        printf 'UNKNOWN management address projected, but rule order could not be established'
    elif [[ "$durable" == "no" && "$projected" == "yes" ]]; then
        # Protected right now, but nothing guarantees it survives a rebuild.
        printf 'DEGRADED management address is in the %s projection but NOT durably declared — a rebuild may drop it' "$wlset"
    else
        printf 'CAPABLE management address durable (%s), projected in %s, ACCEPT precedes DROP' \
            "${durable_in% }" "$wlset"
    fi
    return 0
}

export -f nftban_capability_management_access 2>/dev/null || true
