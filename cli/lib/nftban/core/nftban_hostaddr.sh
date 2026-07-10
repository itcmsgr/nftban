#!/usr/bin/env bash
# =============================================================================
# NFTBan - Host Address Inventory Authority (neutral, read-only)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_hostaddr"
# meta:type="core"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Single authority for local host/self-IP discovery + classification. DISCOVER ONCE, CLASSIFY ONCE, PROJECT PER CONSUMER. Read-only: no nft/whitelist/RBL/network writes."
# meta:input="Local network interface addresses (ip -o addr show)"
# meta:output="Classified TSV/JSON inventory + per-consumer projections"
# meta:depends="ip,sort"
# meta:platform="linux"
# meta:inventory.files=""
# meta:inventory.binaries="ip,sort"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
#
# CONTRACT (v1.220.0 — locked by OPEN_COMMON_HOST_ADDRESS_INVENTORY_AUTHORITY_AUDIT.md §10):
#   Invariant: DISCOVER ONCE - CLASSIFY ONCE - PROJECT PER CONSUMER.
#   - Discovery: `ip -o addr show` only. NO external/public-IP network fallback.
#   - Read-only: no nft ops, no whitelist writes, no RBL state/cache writes, no side effects.
#   - Full compressed IPv6 preserved verbatim; NO colon-delimited address+metadata encoding.
#   - Deterministic ordering; deduplicated by normalized address.
#   Canonical record (TSV, internal + `nftban_hostaddr_inventory` output):
#       address<TAB>family<TAB>scope<TAB>iface<TAB>state<TAB>source
#   Projections:
#       nftban_hostaddr_project_rbl        -> public routable self IPv4+IPv6, full addresses
#       nftban_hostaddr_project_whitelist  -> never-ban/server-identity set (parity with legacy discovery)
#       nftban_hostaddr_project_status     -> byte-for-byte == project_rbl (the exact scheduled-check input)
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_HOSTADDR_LOADED:-}" ]] && return 0
readonly _NFTBAN_HOSTADDR_LOADED=1

# =============================================================================
# CLASSIFICATION (pure; address string in, scope word out)
# =============================================================================
# scope in: loopback | private | ula | link-local | cgnat | documentation |
#           multicast | unspecified | reserved | public
nftban_hostaddr_scope() {
    local a="$1"
    if [[ "$a" == *:* ]]; then
        # ---- IPv6 ----
        local lc="${a,,}"
        [[ "$lc" == "::1" ]] && { echo loopback; return; }
        [[ "$lc" == "::" ]]  && { echo unspecified; return; }
        # IPv4-mapped (::ffff:a.b.c.d) is normalized to IPv4 before this point;
        # any remaining mapped form is treated by its textual class below.
        case "$lc" in
            fe8*|fe9*|fea*|feb*) echo link-local; return ;;   # fe80::/10
            fc*|fd*)             echo ula; return ;;          # fc00::/7
            ff*)                 echo multicast; return ;;    # ff00::/8
            2001:db8:*|2001:0db8:*) echo documentation; return ;;  # 2001:db8::/32
        esac
        echo public; return
    fi
    # ---- IPv4 ----
    case "$a" in
        127.*)                 echo loopback; return ;;      # 127.0.0.0/8
        0.0.0.0)               echo unspecified; return ;;
        169.254.*)             echo link-local; return ;;    # 169.254.0.0/16
        10.*|192.168.*)        echo private; return ;;
        172.1[6-9].*|172.2[0-9].*|172.3[01].*) echo private; return ;;  # 172.16/12
        100.6[4-9].*|100.[7-9][0-9].*|100.1[01][0-9].*|100.12[0-7].*) echo cgnat; return ;;  # 100.64/10
        192.0.2.*|198.51.100.*|203.0.113.*) echo documentation; return ;;
        22[4-9].*|23[0-9].*)   echo multicast; return ;;     # 224.0.0.0/4
        24[0-9].*|25[0-5].*)   echo reserved; return ;;      # 240.0.0.0/4
    esac
    echo public
}

# Convenience: is this address public routable (RBL-eligible by scope alone)?
nftban_hostaddr_is_public() {
    [[ "$(nftban_hostaddr_scope "$1")" == "public" ]]
}

# =============================================================================
# SCAN (internal) — one line per address, 7 TSV fields incl. iface up-state.
#   address\tfamily\tscope\tiface\tstate\tsource\tup
# Public API strips the 7th (up) field; projections use it.
# =============================================================================
_nftban_hostaddr_scan() {
    # SAFE, not tampering: RESTORES the default whitespace IFS in a local scope so a
    # strict-mode caller's IFS=$'\n\t' cannot break `set -- $line` word-splitting.
    # nosemgrep: bash.lang.security.ifs-tampering.ifs-tampering
    local IFS=$' \t\n'   # safe under a strict-mode caller (IFS=$'\n\t')
    command -v ip >/dev/null 2>&1 || return 0

    # Set of operational/up interfaces (names only; strip @ suffix like eth0@if2)
    local up_ifaces=" "
    local _l _n
    while IFS= read -r _l; do
        _n="${_l#*: }"; _n="${_n%%:*}"; _n="${_n%%@*}"
        [[ -n "$_n" ]] && up_ifaces+="$_n "
    done < <(ip -o link show up 2>/dev/null)

    while IFS= read -r _l; do
        [[ -z "$_l" ]] && continue
        # shellcheck disable=SC2086  # deliberate word-split on the `ip -o` line
        set -- $_l
        # $1=<idx:> $2=<iface> $3=<inet|inet6> $4=<addr/plen>
        [[ $# -ge 4 ]] || continue
        local iface="$2" fam3="$3" addrp="$4" family address
        case "$fam3" in
            inet)  family=ipv4 ;;
            inet6) family=ipv6 ;;
            *) continue ;;
        esac
        iface="${iface%%@*}"
        address="${addrp%%/*}"
        # Normalize IPv4-mapped IPv6 (::ffff:1.2.3.4) -> IPv4 consistently.
        if [[ "$family" == "ipv6" && "$address" == ::ffff:*.*.*.* ]]; then
            address="${address##*:}"; family=ipv4
        fi
        local scope; scope="$(nftban_hostaddr_scope "$address")"
        # Address state from flags on the same line.
        local state=preferred
        case " $_l " in
            *" tentative "*|*" dadfailed "*) state=tentative ;;
            *" deprecated "*)                state=deprecated ;;
        esac
        if [[ "$state" == "preferred" ]]; then
            case " $_l " in *" temporary "*|*" mngtmpaddr "*) state=temporary ;; esac
        fi
        local up=no
        [[ "$up_ifaces" == *" $iface "* ]] && up=yes
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$address" "$family" "$scope" "$iface" "$state" "interface" "$up"
    done < <(ip -o addr show 2>/dev/null)
}

# =============================================================================
# PUBLIC INVENTORY — classified, deduped, deterministic. TSV or JSON.
# =============================================================================
nftban_hostaddr_inventory() {
    local json=0
    [[ "${1:-}" == "--json" ]] && json=1

    # Dedup by full record (address+family+scope+iface+state), deterministic sort.
    local rows; rows="$(_nftban_hostaddr_scan | cut -f1-6 | sort -u)"

    if [[ $json -eq 0 ]]; then
        [[ -n "$rows" ]] && printf '%s\n' "$rows"
        return 0
    fi

    # JSON: array of objects, same fields + ordering semantics.
    # nosemgrep: bash.lang.security.ifs-tampering.ifs-tampering
    local IFS=$'\n' first=1 a f s i st so
    printf '['
    while IFS=$'\t' read -r a f s i st so; do
        [[ -z "$a" ]] && continue
        [[ $first -eq 1 ]] || printf ','
        first=0
        printf '{"address":"%s","family":"%s","scope":"%s","iface":"%s","state":"%s","source":"%s"}' \
            "$a" "$f" "$s" "$i" "$st" "$so"
    done <<< "$rows"
    printf ']\n'
}

# =============================================================================
# PROJECTIONS (consumer policy — thin filters over the neutral scan)
# =============================================================================

# RBL: public routable self IPv4+IPv6 only; exclude loopback/private/ULA/CGNAT/
# link-local/multicast/unspecified/reserved/documentation + tentative/deprecated/
# temporary + down-interface. Full addresses, one per line, deduped, no tags.
nftban_hostaddr_project_rbl() {
    # nosemgrep: bash.lang.security.ifs-tampering.ifs-tampering
    local IFS=$' \t\n'
    _nftban_hostaddr_scan | awk -F'\t' '
        $3=="public" && $5=="preferred" && $7=="yes" { print $1 }
    ' | sort -u
}

# Status: exactly the RBL scheduled-check input (no separate discoverer).
nftban_hostaddr_project_status() {
    nftban_hostaddr_project_rbl
}

# Whitelist: never-ban / server-identity set. Parity with the legacy
# `nftban_get_interface_ips` contract: every interface address EXCEPT loopback
# (private/ULA/link-local/temporary/down included — never-ban is intentionally
# broad). Loopback + session are added by the whitelist consumer, not here.
nftban_hostaddr_project_whitelist() {
    # nosemgrep: bash.lang.security.ifs-tampering.ifs-tampering
    local IFS=$' \t\n'
    _nftban_hostaddr_scan | awk -F'\t' '
        $3!="loopback" { print $1 }
    ' | sort -u
}

# =============================================================================
# EXPORTS
# =============================================================================
export -f nftban_hostaddr_scope
export -f nftban_hostaddr_is_public
export -f _nftban_hostaddr_scan
export -f nftban_hostaddr_inventory
export -f nftban_hostaddr_project_rbl
export -f nftban_hostaddr_project_status
export -f nftban_hostaddr_project_whitelist
