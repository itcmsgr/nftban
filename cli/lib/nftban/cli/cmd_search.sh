#!/usr/bin/env bash
# shellcheck disable=SC1083  # Braces in nftables syntax are literal, not bash
# =============================================================================
# NFTBan - Search CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Search for IP/Port across all ban lists, feeds, filters, and whitelists
#
# meta:name="cmd_search"
# meta:type="cli"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-11-05"
#
# meta:description="Search for IP in all nftables sets and threat feeds with GeoIP country lookup and GeoBan status"
# meta:input="IP address or CIDR"
# meta:output="Search results with GeoIP country and GeoBan status"
# meta:depends="bash,nft"
#
# meta:inventory.files=""
# meta:inventory.binaries="nft,nftban-core"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/geoban.d/*.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nft read access"
# =============================================================================


# =============================================================================
# CONFIGURATION
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi
readonly NFTBAN_FEEDS_DIR="${NFTBAN_FEEDS_DIR:-/var/lib/nftban/feeds}"

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi

# Load NFT schema (single source of truth for table/set names)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || return 1
fi

# Load required core modules
if [[ ! $(type -t nftban_render_banner) == "function" ]]; then
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
    fi
fi

# =============================================================================
# GEOIP FUNCTIONS
# =============================================================================

# GeoIP lookup for an IP address
# Returns: "CC|Country Name" or empty if lookup fails
_geoip_lookup() {
    local ip="$1"
    local result=""

    # Use nftban-core geoip lookup command (JSON format for parsing)
    local nftban_core_bin="${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}"

    # Fallback: try to find nftban-core in PATH
    if [[ ! -x "$nftban_core_bin" ]]; then
        nftban_core_bin=$(command -v nftban-core 2>/dev/null || echo "")
    fi

    if [[ -z "$nftban_core_bin" || ! -x "$nftban_core_bin" ]]; then
        # GeoIP binary not available
        echo ""
        return 1
    fi

    # Get JSON output and parse country code and name
    local json_output
    json_output=$("$nftban_core_bin" geoip lookup "$ip" --json 2>/dev/null) || {
        echo ""
        return 1
    }

    # Parse JSON to extract country_code and country_name
    if command -v jq &>/dev/null; then
        local cc cn
        cc=$(echo "$json_output" | jq -r '.country_code // ""' 2>/dev/null)
        cn=$(echo "$json_output" | jq -r '.country_name // ""' 2>/dev/null)
        if [[ -n "$cc" && "$cc" != "Unknown" && "$cc" != "null" ]]; then
            echo "${cc}|${cn}"
            return 0
        fi
    else
        # Fallback: basic parsing without jq
        # JSON format: {"ip":"...","country_code":"DE","country_name":"Germany",...}
        local cc cn
        cc=$(echo "$json_output" | grep -oP '"country_code"\s*:\s*"\K[^"]+' | head -1)
        cn=$(echo "$json_output" | grep -oP '"country_name"\s*:\s*"\K[^"]+' | head -1)
        if [[ -n "$cc" && "$cc" != "Unknown" ]]; then
            echo "${cc}|${cn}"
            return 0
        fi
    fi

    echo ""
    return 1
}

# Check if a country is banned via geoban
# Returns: 0 if banned, 1 if not banned
_is_country_banned() {
    local country_code="$1"
    local geoban_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/geoban.d"

    # Check for 50-ban-<CC>.conf file
    local ban_file="${geoban_dir}/50-ban-${country_code}.conf"

    if [[ -f "$ban_file" ]]; then
        return 0  # Country is banned
    fi

    return 1  # Country is not banned
}

# Check if GeoIP database is available
_geoip_available() {
    local nftban_core_bin="${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}"

    # Fallback: try to find nftban-core in PATH
    if [[ ! -x "$nftban_core_bin" ]]; then
        nftban_core_bin=$(command -v nftban-core 2>/dev/null || echo "")
    fi

    if [[ -z "$nftban_core_bin" || ! -x "$nftban_core_bin" ]]; then
        return 1
    fi

    # Quick test with a known IP (Google DNS)
    "$nftban_core_bin" geoip lookup 8.8.8.8 --json &>/dev/null
    return $?
}

# =============================================================================
# SEARCH FUNCTIONS
# =============================================================================

# Search in nftables sets
_search_nftables() {
    local ip="$1"
    local found_in=()

    # Determine IP version and table family
    local table_family
    local ip_suffix
    if [[ "$ip" == *:* ]]; then
        table_family="ip6"
        ip_suffix="ipv6"
    else
        table_family="ip"
        ip_suffix="ipv4"
    fi

    # Search in ip/ip6 nftban tables
    # v1.33.0: Check hash set (manual O(1)) first, then interval set (feeds)
    local all_sets=("whitelist_${ip_suffix}" "blacklist_manual_${ip_suffix}" "blacklist_${ip_suffix}")
    for set in "${all_sets[@]}"; do
        # Temporarily disable errexit and ERR trap for this check
        # Save current trap, disable it, then restore
        # v1.19.0: Replaced eval "$old_trap" with safe subshell pattern (R16)
        local result
        result=$(
            set +e
            timeout 10 nft get element "${table_family}" nftban "$set" "{ $ip }" &>/dev/null
            echo $?
        ) || true

        if [[ $result -eq 0 ]]; then
            # Normalize set names for display (remove _ipv4/_ipv6 suffix)
            local display_set="${set//_ipv4/}"
            display_set="${display_set//_ipv6/}"
            # v1.33.0: blacklist_manual → blacklist (manual)
            if [[ "$display_set" == "blacklist_manual" ]]; then
                display_set="blacklist"
                found_in+=("nftban:${display_set}:manual")
            else
                found_in+=("nftban:${display_set}")
            fi
        fi
    done

    if [[ ${#found_in[@]} -gt 0 ]]; then
        echo "FOUND"
        printf '%s\n' "${found_in[@]}"
        return 0
    else
        echo "NOT_FOUND"
        return 1
    fi
}

# Search in feed files (exact match)
_search_feeds() {
    local ip="$1"
    local found_feeds=()

    if [[ ! -d "$NFTBAN_FEEDS_DIR" ]]; then
        return 1
    fi

    for feed_file in "$NFTBAN_FEEDS_DIR"/*.txt; do
        if [[ ! -f "$feed_file" ]]; then
            continue
        fi

        if grep -q "^${ip}$" "$feed_file" 2>/dev/null; then
            local feed_name
            feed_name=$(basename "$feed_file" .txt)
            found_feeds+=("$feed_name")
        fi
    done

    if [[ ${#found_feeds[@]} -gt 0 ]]; then
        printf '%s\n' "${found_feeds[@]}"
        return 0
    else
        return 1
    fi
}

# =============================================================================
# CIDR CONTAINMENT FUNCTIONS
# =============================================================================

# Convert IPv4 address to integer for comparison
# Args: $1 = IP address (e.g., "192.168.1.1")
# Returns: Integer representation via echo
_ipv4_to_int() {
    local ip="$1"
    local a b c d
    IFS='.' read -r a b c d <<< "$ip"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

# Check if an IPv4 address is contained within a CIDR
# Args: $1 = IP to check, $2 = CIDR (e.g., "10.0.0.0/8")
# Returns: 0 if IP is in CIDR, 1 otherwise
_ipv4_in_cidr() {
    local ip="$1"
    local cidr="$2"

    # Extract network and prefix length
    local network="${cidr%/*}"
    local prefix="${cidr#*/}"

    # Validate prefix
    if [[ ! "$prefix" =~ ^[0-9]+$ ]] || [[ "$prefix" -lt 0 ]] || [[ "$prefix" -gt 32 ]]; then
        return 1
    fi

    # Convert to integers
    local ip_int network_int mask
    ip_int=$(_ipv4_to_int "$ip")
    network_int=$(_ipv4_to_int "$network")

    # Calculate mask (all 1s for prefix bits, then 0s)
    if [[ "$prefix" -eq 0 ]]; then
        mask=0
    else
        mask=$(( (0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF ))
    fi

    # Check if IP is in network range
    if [[ $(( ip_int & mask )) -eq $(( network_int & mask )) ]]; then
        return 0
    fi
    return 1
}

# Check if an IPv6 address is contained within a CIDR
# This is a simplified check - for full IPv6 support, use nftban-core
# Args: $1 = IP to check, $2 = CIDR
# Returns: 0 if IP is in CIDR, 1 otherwise
_ipv6_in_cidr() {
    local ip="$1"
    local cidr="$2"
    local result

    # For IPv6, we rely on nftban-core or Python if available
    # Bash integer arithmetic can't handle 128-bit addresses

    # Try Python (commonly available)
    if command -v python3 &>/dev/null; then
        # Use python3 to check CIDR containment
        # Output "1" for match, "0" for no match (avoids exit code issues with strict mode)
        result=$(python3 -c "
import ipaddress
try:
    ip = ipaddress.ip_address('$ip')
    net = ipaddress.ip_network('$cidr', strict=False)
    print('1' if ip in net else '0')
except:
    print('0')
" 2>/dev/null) || result="0"

        if [[ "$result" == "1" ]]; then
            return 0
        fi
        return 1
    fi

    # Fallback: no IPv6 CIDR support without python/nftban-core
    return 1
}

# Check if an IP is contained within a CIDR (auto-detects IPv4/IPv6)
# Args: $1 = IP to check, $2 = CIDR
# Returns: 0 if IP is in CIDR, 1 otherwise
_ip_in_cidr() {
    local ip="$1"
    local cidr="$2"

    # Detect IP version
    if [[ "$ip" == *:* ]]; then
        # IPv6
        _ipv6_in_cidr "$ip" "$cidr"
    else
        # IPv4
        _ipv4_in_cidr "$ip" "$cidr"
    fi
}

# Search feeds for CIDR containment (IP within a CIDR range in feeds)
# Args: $1 = IP address to search for
# Output: Feed names and matching CIDRs (one per line: "feed_name:cidr")
# Returns: 0 if found in any feed CIDR, 1 otherwise
# Uses nftban-core for fast CIDR matching (Go binary) instead of slow bash loop
_search_feeds_cidr() {
    local ip="$1"

    if [[ ! -d "$NFTBAN_FEEDS_DIR" ]]; then
        return 1
    fi

    # Use nftban-core check for fast CIDR matching (Go binary with efficient IP library)
    local nftban_core_bin="${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}"
    if [[ ! -x "$nftban_core_bin" ]]; then
        nftban_core_bin=$(command -v nftban-core 2>/dev/null || echo "")
    fi

    if [[ -x "$nftban_core_bin" ]]; then
        # nftban-core check returns feed info if IP is in a CIDR
        local check_output
        check_output=$("$nftban_core_bin" check "$ip" 2>/dev/null) || true

        # Parse output for feed matches
        if echo "$check_output" | grep -q "Found in feeds\|🔴.*feeds"; then
            # Extract feed name from output if available
            local feed_match
            feed_match=$(echo "$check_output" | grep -oP '(?<=feed: )\S+|(?<=Feed: )\S+' | head -1)
            if [[ -n "$feed_match" ]]; then
                echo "${feed_match}:CIDR"
            else
                echo "feeds:CIDR"
            fi
            return 0
        fi
        return 1
    fi

    # Fallback: No nftban-core available, skip slow CIDR scan
    # (this avoids 30+ second delays on large feed files)
    return 1
}

# Note: fail2ban search removed in v1.0 (replaced by Suricata IDS and built-in login monitoring)

# Get ban details (source, time, etc.)
_get_ban_details() {
    local ip="$1"
    local table="$2"
    local set="$3"

    # Try to get element with timeout info
    timeout 10s nft list set "$table" "$set" | grep "$ip" || echo "No details available"
}

# Search for port in nftables and config files
_search_port() {
    local port="$1"
    local found_in=()

    # Search in nftables tcp_ports_in/tcp_ports_out sets (v2.1 directional schema)
    # Note: Both IPv4 and IPv6 tables have directional port sets, check both
    if timeout 10s nft list set ${NFTBAN_TABLE_IPV4} tcp_ports_in 2>/dev/null | grep -qw "$port" || \
       timeout 10s nft list set ${NFTBAN_TABLE_IPV6} tcp_ports_in 2>/dev/null | grep -qw "$port"; then
        found_in+=("nftables:tcp_ports_in")
    fi
    if timeout 10s nft list set ${NFTBAN_TABLE_IPV4} tcp_ports_out 2>/dev/null | grep -qw "$port" || \
       timeout 10s nft list set ${NFTBAN_TABLE_IPV6} tcp_ports_out 2>/dev/null | grep -qw "$port"; then
        found_in+=("nftables:tcp_ports_out")
    fi

    # Search in nftables udp_ports_in/udp_ports_out sets (v2.1 directional schema)
    if timeout 10s nft list set ${NFTBAN_TABLE_IPV4} udp_ports_in 2>/dev/null | grep -qw "$port" || \
       timeout 10s nft list set ${NFTBAN_TABLE_IPV6} udp_ports_in 2>/dev/null | grep -qw "$port"; then
        found_in+=("nftables:udp_ports_in")
    fi
    if timeout 10s nft list set ${NFTBAN_TABLE_IPV4} udp_ports_out 2>/dev/null | grep -qw "$port" || \
       timeout 10s nft list set ${NFTBAN_TABLE_IPV6} udp_ports_out 2>/dev/null | grep -qw "$port"; then
        found_in+=("nftables:udp_ports_out")
    fi

    # Search in config files
    if [[ -d "${NFTBAN_CONFIG_DIR}/ports.d" ]]; then
        while IFS= read -r file; do
            if grep -qE "^${port}\|" "$file" 2>/dev/null; then
                local proto
                proto=$(grep -E "^${port}\|" "$file" | cut -d'|' -f2 | head -1)
                local proto_name="unknown"
                case "$proto" in
                    T) proto_name="TCP" ;;
                    U) proto_name="UDP" ;;
                    B) proto_name="TCP+UDP" ;;
                esac
                found_in+=("config:$(basename "$file"):$proto_name")
            fi
        done < <(find "${NFTBAN_CONFIG_DIR}/ports.d" -type f -name "*.conf" 2>/dev/null)
    fi

    if [[ ${#found_in[@]} -gt 0 ]]; then
        echo "FOUND"
        printf '%s\n' "${found_in[@]}"
        return 0
    else
        echo "NOT_FOUND"
        return 1
    fi
}

# =============================================================================
# DISPLAY FUNCTIONS
# =============================================================================

_display_results() {
    local ip="$1"
    local nft_result="$2"
    local feeds_result="$3"
    local geoip_result="${4:-}"
    local country_banned="${5:-false}"
    local cidr_result="${6:-}"

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  IP Search Results: $ip"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Display GeoIP information if available
    if [[ -n "$geoip_result" ]]; then
        local country_code="${geoip_result%%|*}"
        local country_name="${geoip_result#*|}"

        echo "GeoIP Information:"
        echo "───────────────────────────────────────────────────────────────"
        echo "  Country: $country_code ($country_name)"
        if [[ "$country_banned" == "true" ]]; then
            echo "  ⚠ GEOBAN: Country $country_code is BANNED"
        fi
        echo ""
    fi

    # Parse nftables results
    if [[ "$nft_result" == "FOUND"* ]]; then
        # Skip first line (FOUND) to get set locations
        local found_sets
        found_sets=$(echo "$nft_result" | tail -n +2)

        # Determine if IP is only in whitelist (not banned)
        local is_whitelisted_only="true"
        while IFS= read -r loc; do
            local loc_set="${loc##*:}"
            [[ "$loc_set" != "whitelist" ]] && is_whitelisted_only="false"
        done <<< "$found_sets"

        # v1.59.1 BUG-7: Guard display echo against SIGPIPE/broken pipe under set -e
        if [[ "$is_whitelisted_only" == "true" ]]; then
            echo "✓ STATUS: WHITELISTED" || true
        else
            echo "✗ STATUS: BANNED" || true
        fi
        echo ""
        echo "Found in nftables sets:"
        echo "───────────────────────────────────────────────────────────────"

        while IFS= read -r location; do
            local table="${location%%:*}"
            local set="${location##*:}"

            case "$set" in
                whitelist)
                    echo "  ✓ WHITELISTED in $table"
                    echo "    → Priority: HIGHEST (cannot be banned)"
                    ;;
                temp_ban)
                    echo "  ✓ TEMP BAN in $table"
                    echo "    → Auto-expires (timeout active)"
                    echo "    → Details: No details available"
                    ;;
                blacklist:manual)
                    echo "  ✓ BLACKLISTED in $table (hash set — manual/auto-detect)"
                    # Check if it has a timeout (temporary ban)
                    local manual_ban_info manual_set_name manual_timeout_str manual_expires_str
                    manual_set_name="blacklist_manual_ipv4"
                    [[ "$ip" == *:* ]] && manual_set_name="blacklist_manual_ipv6"
                    manual_ban_info=$(timeout 10s nft list set "$table" "$manual_set_name" 2>/dev/null | grep -F "$ip" | head -1) || true
                    if [[ "$manual_ban_info" == *"timeout"* ]]; then
                        manual_timeout_str=$(echo "$manual_ban_info" | grep -oE 'timeout [0-9]+[smhd]' | head -1) || true
                        manual_expires_str=$(echo "$manual_ban_info" | grep -oE 'expires [0-9]+[smhd]+[0-9]*[smhd]*' | head -1) || true
                        echo "    → Type: Temporary ban ($manual_timeout_str)"
                        [[ -n "$manual_expires_str" ]] && echo "    → Expires in: ${manual_expires_str#expires }"
                    else
                        echo "    → Type: Permanent ban"
                    fi
                    ;;
                blacklist)
                    echo "  ✓ BLACKLISTED in $table (interval set — feeds/geoban)"
                    # Check if it has a timeout (temporary ban)
                    local ban_info set_name timeout_str expires_str
                    set_name="blacklist_ipv4"
                    [[ "$ip" == *:* ]] && set_name="blacklist_ipv6"
                    ban_info=$(timeout 10s nft list set "$table" "$set_name" 2>/dev/null | grep -F "$ip" | head -1) || true
                    if [[ "$ban_info" == *"timeout"* ]]; then
                        # Extract timeout info: "timeout 1h expires 55m30s123ms,"
                        timeout_str=$(echo "$ban_info" | grep -oE 'timeout [0-9]+[smhd]' | head -1) || true
                        expires_str=$(echo "$ban_info" | grep -oE 'expires [0-9]+[smhd]+[0-9]*[smhd]*' | head -1) || true
                        echo "    → Type: Temporary ban ($timeout_str)"
                        [[ -n "$expires_str" ]] && echo "    → Expires in: ${expires_str#expires }"
                    else
                        echo "    → Type: Permanent ban"
                    fi
                    ;;
                user_blacklist)
                    echo "  ✓ USER BLACKLIST in $table"
                    echo "    → Type: Manual permanent ban"
                    ;;
                system_blacklist)
                    echo "  ✓ SYSTEM BLACKLIST in $table"
                    echo "    → Type: Automatic permanent ban"
                    ;;
                feeds)
                    echo "  ✓ THREAT FEEDS in $table"
                    echo "    → Source: Threat intelligence"
                    ;;
            esac
        done <<< "$found_sets"

        echo ""
    else
        echo "✓ STATUS: NOT BANNED"
        echo ""
        echo "Not found in nftables sets:"
        echo "───────────────────────────────────────────────────────────────"
        echo "  ✗ whitelist"
        echo "  ✗ temp_ban"
        echo "  ✗ user_blacklist"
        echo "  ✗ system_blacklist"
        echo "  ✗ feeds"
        echo ""
    fi

    # Show feed matches (exact IP match)
    if [[ -n "$feeds_result" ]]; then
        echo "Found in threat feeds (exact match):"
        echo "───────────────────────────────────────────────────────────────"
        while IFS= read -r feed; do
            echo "  ✓ $feed"
        done <<< "$feeds_result"
        echo ""
    fi

    # Show CIDR containment matches
    if [[ -n "$cidr_result" ]]; then
        echo "Found in threat feed CIDR ranges (containment match):"
        echo "───────────────────────────────────────────────────────────────"
        while IFS= read -r match; do
            local feed_name="${match%%:*}"
            local cidr="${match#*:}"
            echo "  ✓ $feed_name → $cidr (IP $ip is within this range)"
        done <<< "$cidr_result"
        echo ""
    fi

    # v1.191 8B inc6B1 — read-only BotGuard TEMPORARY decision-cache section. The durable
    # nft/kernel state above remains the source of truth; this block is clearly separated and
    # labeled TEMPORARY, is non-mutating, and degrades to "unavailable" (never implies safe).
    if ! declare -f nftban_botguard_explain_render >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        [[ -f "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" ]] && source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true
        # shellcheck source=/dev/null
        [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_botguard_explain.sh" ]] && source "${NFTBAN_LIB_DIR}/lib/nftban_botguard_explain.sh" 2>/dev/null || true
    fi
    if declare -f nftban_botguard_explain_render >/dev/null 2>&1; then
        echo ""
        nftban_botguard_explain_render "$ip"
        echo ""
    fi

    echo "═══════════════════════════════════════════════════════════════"
}

# =============================================================================
# ACTION SUGGESTIONS (replaced interactive menu in v1.0.18)
# =============================================================================

_suggest_actions() {
    # Suggest commands instead of interactive menu
    # This is simpler, faster, and follows Unix philosophy
    local ip="$1"
    local is_banned="$2"

    # V127 UX-2 item 3.2: if the searched IP is well-known public infrastructure
    # (Cloudflare/Google/Quad9/OpenDNS DNS resolver), prepend an advisory note to
    # the Quick Actions block so the operator sees the same warning here as they
    # would on `nftban ban` (cmd_ban.sh UX-2 item 1.7). The advisory is purely
    # informational on this surface — `nftban search` does not mutate anything.
    # (Scope: AUDIT_190_LIFECYCLE/V127_FULL_UX_CORRECTION_UMBRELLA_SCOPE.md UX-2 item 3.2)
    local _wk_search_descr=""
    if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_well_known.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/lib/nftban_well_known.sh" 2>/dev/null || true
        if declare -f nftban_is_well_known_infra_ip >/dev/null 2>&1; then
            _wk_search_descr=$(nftban_is_well_known_infra_ip "$ip" 2>/dev/null) || _wk_search_descr=""
        fi
    fi

    echo ""
    if [[ -n "$_wk_search_descr" ]]; then
        echo "⚠️  Advisory: ${ip} is well-known public infrastructure"
        echo "───────────────────────────────────────────────────────────────"
        echo "  ${_wk_search_descr}"
        echo ""
        echo "  Banning this address typically disrupts legitimate traffic for"
        echo "  the protected network without providing a security benefit."
        echo "  If you intend to ban it anyway, nftban ban will require an"
        echo "  explicit --yes override:"
        echo "    nftban ban ${ip} --yes"
        echo ""
    fi
    echo "💡 Quick Actions:"
    echo "───────────────────────────────────────────────────────────────"

    if [[ "$is_banned" == "true" ]]; then
        echo "  Remove ban:"
        echo "    nftban unban $ip"
        echo ""
        echo "  Move to whitelist (permanent protection):"
        echo "    nftban whitelist add $ip"
    else
        echo "  Ban temporarily (1 hour):"
        echo "    nftban ban $ip --timeout 3600"
        echo ""
        echo "  Ban permanently:"
        echo "    nftban ban $ip"
        echo ""
        echo "  Add to whitelist (permanent protection):"
        echo "    nftban whitelist add $ip"
    fi

    echo ""
}

# =============================================================================
# HELP TEXT
# =============================================================================

_nftban_search_help() {
    nftban_banner "search"

    cat <<'HELP'

USAGE:
    nftban search <ip|port> [--no-interactive]

DESCRIPTION:
    Search for an IP address or port number across all NFTBan components:

    IP Search:
    - GeoIP country lookup (shows country code and name)
    - GeoBan status (shows if country is banned)
    - nftables sets (whitelist, temp_ban, user_blacklist, system_blacklist, feeds)
    - Threat intelligence feeds (exact IP match)
    - CIDR containment (checks if IP falls within any CIDR range in feeds)

    Port Search:
    - nftables port sets (tcp_ports_in/out, udp_ports_in/out, ssh_ports)
    - Port configuration files (${NFTBAN_CONFIG_DIR}/ports.d/*.conf)

    If IP/port is found, shows location and details.
    If IP is not found, offers interactive options to ban or whitelist.

OPTIONS:
    --no-interactive    Show results only, no interactive menu
    --json              Output in JSON format (includes GeoIP data)

EXAMPLES:
    # Search for IP (shows country + ban status)
    nftban search 192.0.2.100

    # Search IPv6
    nftban search 2001:db8::1

    # Search CIDR (checks if any IP in range is banned)
    nftban search 192.0.2.0/24

    # Search for port
    nftban search 8080

    # Non-interactive (scripts)
    nftban search 192.0.2.100 --no-interactive

    # JSON output (includes GeoIP data)
    nftban search 192.0.2.100 --json

OUTPUT:
    IP: 203.0.113.1
    Country: DE (Germany)
    Status: FOUND IN FEEDS
    Feeds: tor-exit-nodes, firehol_level1

NOTES:
    - GeoIP lookup shows country code and name for single IPs
    - GeoBan check shows if the IP's country is banned
    - Searches all nftables sets (whitelist, blacklist)
    - Searches downloaded threat feeds for exact IP matches
    - Performs CIDR containment check (e.g., 0.0.0.0 found in 0.0.0.0/8)
    - Searches port whitelist sets and config files
    - Shows ban priority and type
    - Shows expiry time for temp bans
    - GeoIP requires nftban-core binary and GeoIP database
    - CIDR containment: IPv4 is native bash; IPv6 requires python3

HELP
}

# =============================================================================
# MAIN COMMAND
# =============================================================================

nftban_cmd_search() {
    local query=""
    local interactive=true
    local json_mode=false

    # Parse all arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                json_mode=true
                interactive=false
                shift
                ;;
            --no-interactive)
                interactive=false
                shift
                ;;
            help|--help|-h)
                _nftban_search_help
                return 0
                ;;
            *)
                if [[ -z "$query" ]]; then
                    query="$1"
                fi
                shift
                ;;
        esac
    done

    # Check if query is empty
    if [[ -z "$query" ]]; then
        _nftban_search_help
        return 0
    fi

    # Show banner (skip for JSON output)
    if [[ "$json_mode" != "true" ]]; then
        if [[ $(type -t nftban_banner) == "function" ]]; then
            nftban_banner
        fi
        echo ""
    fi

    # Detect if query is port number or IP address
    if [[ "$query" =~ ^[0-9]+$ ]] && [[ "$query" -ge 1 ]] && [[ "$query" -le 65535 ]]; then
        # It's a port number
        echo ""
        echo "═══════════════════════════════════════════════════════════════"
        echo "  Port Search Results: $query"
        echo "═══════════════════════════════════════════════════════════════"
        echo ""

        local port_result
        port_result=$(_search_port "$query")

        if [[ "$port_result" == "FOUND"* ]]; then
            echo "✓ STATUS: WHITELISTED (port is allowed)"
            echo ""
            echo "Found in:"
            echo "───────────────────────────────────────────────────────────────"

            # Skip first line (FOUND)
            local found_locations
            found_locations=$(echo "$port_result" | tail -n +2)

            while IFS= read -r location; do
                if [[ "$location" == nftables:* ]]; then
                    local set="${location##*:}"
                    echo "  ✓ nftables set: $set (active in firewall)"
                elif [[ "$location" == config:* ]]; then
                    local file
                    file=$(echo "$location" | cut -d':' -f2)
                    local proto
                    proto=$(echo "$location" | cut -d':' -f3)
                    echo "  ✓ config file: $file (protocol: $proto)"
                fi
            done <<< "$found_locations"

            echo ""
            echo "═══════════════════════════════════════════════════════════════"
        else
            echo "X STATUS: NOT WHITELISTED (port is blocked by default)"
            echo ""
            echo "Not found in:"
            echo "-------------------------------------------------------------------"
            echo "  X nftables tcp_ports_in/tcp_ports_out sets"
            echo "  X nftables udp_ports_in/udp_ports_out sets"
            echo "  X nftables ssh_ports set (SSH brute-force rate-limit)"
            echo "  X ${NFTBAN_CONFIG_DIR}/ports.d/*.conf"
            echo ""
            echo "To whitelist this port, use:"
            echo "  nftban port add $query tcp     # For TCP"
            echo "  nftban port add $query udp     # For UDP"
            echo "  nftban port add $query both    # For both"
            echo ""
            echo "═══════════════════════════════════════════════════════════════"
        fi

        return 0
    fi

    # It's an IP address - continue with IP search
    local ip="$query"

    # Validate IP (basic check)
    if [[ ! "$ip" =~ ^[0-9a-fA-F:.\/]+$ ]]; then
        echo "ERROR: Invalid IP address or port: $ip" >&2
        return 1
    fi

    # Perform searches (these functions return 1 when IP not found, which is expected)
    local nft_result=""
    nft_result=$(_search_nftables "$ip" 2>/dev/null) || true
    local feeds_result=""
    feeds_result=$(_search_feeds "$ip" 2>/dev/null) || true

    # CIDR containment search (only for single IPs, not CIDRs)
    local cidr_result=""
    if [[ "$ip" != */* ]]; then
        cidr_result=$(_search_feeds_cidr "$ip" 2>/dev/null) || true
    fi

    # Perform GeoIP lookup (handle case where database is not installed)
    local geoip_result=""
    local country_banned="false"
    local country_code=""

    # Only do GeoIP lookup for single IPs, not CIDRs
    if [[ "$ip" != *"/"* ]]; then
        geoip_result=$(_geoip_lookup "$ip" 2>/dev/null) || true

        # If we got a country code, check if it's banned
        if [[ -n "$geoip_result" ]]; then
            country_code="${geoip_result%%|*}"
            if [[ -n "$country_code" ]] && _is_country_banned "$country_code"; then
                country_banned="true"
            fi
        fi
    fi

    # JSON output mode
    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local found="false"
        local -a locations=()

        # Parse nftables results
        if [[ "$nft_result" == "FOUND"* ]]; then
            found="true"
            while IFS= read -r location; do
                [[ -z "$location" ]] && continue
                locations+=("$location")
            done <<< "$(echo "$nft_result" | tail -n +2)"
        fi

        # Parse feeds results (exact match)
        if [[ -n "$feeds_result" ]]; then
            found="true"
            while IFS= read -r feed; do
                [[ -z "$feed" ]] && continue
                locations+=("feed:$feed")
            done <<< "$feeds_result"
        fi

        # Parse CIDR containment results
        if [[ -n "$cidr_result" ]]; then
            found="true"
            while IFS= read -r match; do
                [[ -z "$match" ]] && continue
                locations+=("cidr:$match")
            done <<< "$cidr_result"
        fi

        # Build locations JSON array
        local locations_json="["
        local first=true
        for loc in "${locations[@]}"; do
            [[ "$first" == "false" ]] && locations_json+=","
            locations_json+="\"$loc\""
            first=false
        done
        locations_json+="]"

        # Build GeoIP JSON fields
        local geoip_cc=""
        local geoip_cn=""
        local geoip_banned="false"
        if [[ -n "$geoip_result" ]]; then
            geoip_cc="${geoip_result%%|*}"
            geoip_cn="${geoip_result#*|}"
            geoip_banned="$country_banned"
        fi

        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg ip "$ip" \
                --arg found "$found" \
                --argjson locations "$locations_json" \
                --arg country_code "$geoip_cc" \
                --arg country_name "$geoip_cn" \
                --arg country_banned "$geoip_banned" \
                '{ip: $ip, found: ($found == "true"), locations: $locations, count: ($locations | length), geoip: {country_code: $country_code, country_name: $country_name, country_banned: ($country_banned == "true")}}')
        else
            local found_bool="false"
            [[ "$found" == "true" ]] && found_bool="true"
            local banned_bool="false"
            [[ "$geoip_banned" == "true" ]] && banned_bool="true"
            data="{\"ip\":\"$ip\",\"found\":$found_bool,\"locations\":$locations_json,\"count\":${#locations[@]},\"geoip\":{\"country_code\":\"$geoip_cc\",\"country_name\":\"$geoip_cn\",\"country_banned\":$banned_bool}}"
        fi
        json_output "true" "$data"
        return 0
    fi

    # Display results (human-readable)
    _display_results "$ip" "$nft_result" "$feeds_result" "$geoip_result" "$country_banned" "$cidr_result"

    # Show suggested actions (unless --no-interactive flag used)
    if [[ "$interactive" == "true" ]]; then
        local is_banned="false"
        if [[ "$nft_result" == "FOUND"* ]]; then
            # Check if found in non-whitelist sets (actual ban)
            local _found_sets_check
            _found_sets_check=$(echo "$nft_result" | tail -n +2)
            while IFS= read -r _loc; do
                local _loc_set="${_loc##*:}"
                [[ "$_loc_set" != "whitelist" ]] && is_banned="true"
            done <<< "$_found_sets_check"
        fi

        _suggest_actions "$ip" "$is_banned"
    fi

    # Exit marker for testing validation
    command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "search"

    return 0
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_cmd_search

# =============================================================================
# DIRECT EXECUTION SUPPORT
# =============================================================================

# If sourced directly (not via main CLI), run command
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    nftban_cmd_search "$@"
fi
