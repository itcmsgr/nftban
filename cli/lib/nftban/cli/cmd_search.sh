#!/usr/bin/env bash
# shellcheck disable=SC1083  # Braces in nftables syntax are literal, not bash
# =============================================================================
# NFTBan v1.0.0 - Search CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Search for IP/Port across all ban lists, feeds, jails, and whitelists
#
# meta:name=cmd_search
# meta:type=cli
# meta:header=IP Search CLI
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Search for IP in all nftables sets and threat feeds with interactive options
# meta:input=IP address or CIDR
# meta:output=Search results and interactive menu
#
# **Inventory & Requirements**
# meta:depends=bash
#
# meta:created_date=2025-11-05
# meta:updated_date=2025-11-24
# =============================================================================


# =============================================================================
# CONFIGURATION
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh"
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh"
fi
readonly NFTBAN_FEEDS_DIR="${NFTBAN_FEEDS_DIR:-/var/lib/nftban/feeds}"

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER"
fi

# Load NFT schema (single source of truth for table/set names)
# shellcheck source=/usr/lib/nftban/lib/nft_schema.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh"
fi

# Load required core modules
if [[ ! $(type -t nftban_render_banner) == "function" ]]; then
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
    fi
fi

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

    # Search in ip/ip6 nftban tables (v0.7.3 dual table architecture)
    # Sets: whitelist, blacklist (blacklist contains both permanent + temporary bans)
    # Note: feeds, geoban, and temp bans are ALL consolidated into blacklist by nftban-core
    local all_sets=("whitelist_${ip_suffix}" "blacklist_${ip_suffix}")
    for set in "${all_sets[@]}"; do
        # Temporarily disable errexit and ERR trap for this check
        # Save current trap, disable it, then restore
        local old_trap
        old_trap=$(trap -p ERR)
        trap - ERR
        set +e
        # Add timeout to prevent hanging on large sets
        timeout 2 nft get element "${table_family}" nftban "$set" { "$ip" } &>/dev/null
        local result=$?
        set -e
        eval "$old_trap"

        if [[ $result -eq 0 ]]; then
            # Normalize set names for display (remove _ipv4/_ipv6 suffix)
            local display_set="${set//_ipv4/}"
            display_set="${display_set//_ipv6/}"
            found_in+=("nftban:${display_set}")
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

# Search in feed files
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

# Note: fail2ban search removed in v1.0 (replaced by Suricata IDS and built-in login monitoring)

# Get ban details (source, time, etc.)
_get_ban_details() {
    local ip="$1"
    local table="$2"
    local set="$3"

    # Try to get element with timeout info
    nft list set "$table" "$set" | grep "$ip" || echo "No details available"
}

# Search for port in nftables and config files
_search_port() {
    local port="$1"
    local found_in=()

    # Search in nftables tcp_ports set (v0.7.3: ip nftban + ip6 nftban tables)
    # Note: Both IPv4 and IPv6 tables have tcp_ports sets, check both
    if nft list set ${NFTBAN_TABLE_IPV4} tcp_ports 2>/dev/null | grep -qw "$port" || \
       nft list set ${NFTBAN_TABLE_IPV6} tcp_ports 2>/dev/null | grep -qw "$port"; then
        found_in+=("nftables:tcp_ports")
    fi

    # Search in nftables udp_ports set (v0.7.3: ip nftban + ip6 nftban tables)
    if nft list set ${NFTBAN_TABLE_IPV4} udp_ports 2>/dev/null | grep -qw "$port" || \
       nft list set ${NFTBAN_TABLE_IPV6} udp_ports 2>/dev/null | grep -qw "$port"; then
        found_in+=("nftables:udp_ports")
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

    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  IP Search Results: $ip"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Parse nftables results
    if [[ "$nft_result" == "FOUND"* ]]; then
        echo "✗ STATUS: BANNED"
        echo ""
        echo "Found in nftables sets:"
        echo "───────────────────────────────────────────────────────────────"

        # Skip first line (FOUND)
        local found_sets
        found_sets=$(echo "$nft_result" | tail -n +2)

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
                blacklist)
                    echo "  ✓ BLACKLISTED in $table"
                    # Check if it has a timeout (temporary ban)
                    local ban_info set_name timeout_str expires_str
                    set_name="blacklist_ipv4"
                    [[ "$ip" == *:* ]] && set_name="blacklist_ipv6"
                    ban_info=$(nft list set "$table" "$set_name" 2>/dev/null | grep -F "$ip" | head -1) || true
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

    # Show feed matches
    if [[ -n "$feeds_result" ]]; then
        echo "Found in threat feeds:"
        echo "───────────────────────────────────────────────────────────────"
        while IFS= read -r feed; do
            echo "  ✓ $feed"
        done <<< "$feeds_result"
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

    echo ""
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
    - nftables sets (whitelist, temp_ban, user_blacklist, system_blacklist, feeds)
    - Threat intelligence feeds
    - Fail2Ban jails

    Port Search:
    - nftables port sets (tcp_ports, udp_ports)
    - Port configuration files (${NFTBAN_CONFIG_DIR}/ports.d/*.conf)

    If IP/port is found, shows location and details.
    If IP is not found, offers interactive options to ban or whitelist.

OPTIONS:
    --no-interactive    Show results only, no interactive menu

EXAMPLES:
    # Search for IP
    nftban search 192.0.2.100

    # Search IPv6
    nftban search 2001:db8::1

    # Search CIDR (checks if any IP in range is banned)
    nftban search 192.0.2.0/24

    # Search for port
    nftban search 8080

    # Non-interactive (scripts)
    nftban search 192.0.2.100 --no-interactive

NOTES:
    - Searches all 3 nftables tables (runtime, v4, v6)
    - Searches all 5 sets per table
    - Searches downloaded threat feeds
    - Searches active Fail2Ban jails
    - Searches port whitelist sets and config files
    - Shows ban priority and type
    - Shows expiry time for temp bans

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
            echo "✗ STATUS: NOT WHITELISTED (port is blocked by default)"
            echo ""
            echo "Not found in:"
            echo "───────────────────────────────────────────────────────────────"
            echo "  ✗ nftables tcp_ports set"
            echo "  ✗ nftables udp_ports set"
            echo "  ✗ ${NFTBAN_CONFIG_DIR}/ports.d/*.conf"
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
        echo "ERROR: Invalid IP address or port: $ip"
        return 1
    fi

    # Perform searches (these functions return 1 when IP not found, which is expected)
    local nft_result=""
    nft_result=$(_search_nftables "$ip" 2>/dev/null) || true
    local feeds_result=""
    feeds_result=$(_search_feeds "$ip" 2>/dev/null) || true

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

        # Parse feeds results
        if [[ -n "$feeds_result" ]] && [[ "$feeds_result" == "FOUND"* ]]; then
            while IFS= read -r feed; do
                [[ -z "$feed" ]] && continue
                locations+=("feed:$feed")
            done <<< "$(echo "$feeds_result" | tail -n +2)"
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

        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg ip "$ip" \
                --arg found "$found" \
                --argjson locations "$locations_json" \
                '{ip: $ip, found: ($found == "true"), locations: $locations, count: ($locations | length)}')
        else
            local found_bool="false"
            [[ "$found" == "true" ]] && found_bool="true"
            data="{\"ip\":\"$ip\",\"found\":$found_bool,\"locations\":$locations_json,\"count\":${#locations[@]}}"
        fi
        json_output "true" "$data"
        return 0
    fi

    # Display results (human-readable)
    _display_results "$ip" "$nft_result" "$feeds_result"

    # Show suggested actions (unless --no-interactive flag used)
    if [[ "$interactive" == "true" ]]; then
        local is_banned="false"
        [[ "$nft_result" == "FOUND"* ]] && is_banned="true"

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
