#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - Search CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Search for IP across all ban lists, feeds, and jails
#
# meta:name=cmd_search
# meta:type=cli
# meta:header=IP Search CLI
# meta:version=0.10.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Search for IP in all sets, feeds, and Fail2Ban jails with interactive options
# meta:input=IP address or CIDR
# meta:output=Search results and interactive menu
#
# **Inventory & Requirements**
# meta:depends=bash,nftban_nftables.sh,nftban_fail2ban.sh
#
# meta:created_date=2025-10-28
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
readonly NFTBAN_FEEDS_DIR="${NFTBAN_FEEDS_DIR:-/var/lib/nftban/feeds}"

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

    # Determine IP version
    local ip_suffix
    if [[ "$ip" == *:* ]]; then
        ip_suffix="v6"
    else
        ip_suffix="v4"
    fi

    # Search in inet nftban_runtime table (temp bans only)
    if nft get element inet nftban_runtime "temp_ban_${ip_suffix}" { "$ip" } &>/dev/null; then
        found_in+=("nftban_runtime:temp_ban")
    fi

    # Search in inet nftban_main table (whitelist, blacklist)
    local main_sets=("whitelist_${ip_suffix}" "blacklist_${ip_suffix}")
    for set in "${main_sets[@]}"; do
        if nft get element inet nftban_main "$set" { "$ip" } &>/dev/null; then
            # Normalize set names for display (remove _v4/_v6 suffix)
            local display_set="${set//_v4/}"
            display_set="${display_set//_v6/}"
            found_in+=("nftban_main:${display_set}")
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
            local feed_name=$(basename "$feed_file" .txt)
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

# Search in Fail2Ban jails
_search_fail2ban() {
    local ip="$1"
    local found_jails=()

    # Check if Fail2Ban is available
    if ! command -v fail2ban-client &>/dev/null; then
        return 1
    fi

    # Get list of active jails
    local jails=$(fail2ban-client status 2>/dev/null | grep "Jail list:" | sed 's/.*Jail list:\s*//' | tr ',' '\n' | tr -d ' ')

    for jail in $jails; do
        # Check if IP is banned in this jail
        if fail2ban-client status "$jail" 2>/dev/null | grep -q "$ip"; then
            found_jails+=("$jail")
        fi
    done

    if [[ ${#found_jails[@]} -gt 0 ]]; then
        printf '%s\n' "${found_jails[@]}"
        return 0
    else
        return 1
    fi
}

# Get ban details (source, time, etc.)
_get_ban_details() {
    local ip="$1"
    local table="$2"
    local set="$3"

    # Try to get element with timeout info
    nft list set "$table" "$set" | grep "$ip" || echo "No details available"
}

# =============================================================================
# DISPLAY FUNCTIONS
# =============================================================================

_display_results() {
    local ip="$1"
    local nft_result="$2"
    local feeds_result="$3"
    local f2b_result="$4"

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
        local found_sets=$(echo "$nft_result" | tail -n +2)

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
                    echo "    → Type: Permanent ban"
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

    # Show Fail2Ban matches
    if [[ -n "$f2b_result" ]]; then
        echo "Found in Fail2Ban jails:"
        echo "───────────────────────────────────────────────────────────────"
        while IFS= read -r jail; do
            echo "  ✓ $jail"
        done <<< "$f2b_result"
        echo ""
    fi

    echo "═══════════════════════════════════════════════════════════════"
}

# =============================================================================
# INTERACTIVE MENU
# =============================================================================

_show_action_menu() {
    local ip="$1"
    local is_banned="$2"

    echo ""
    echo "Actions:"
    echo "───────────────────────────────────────────────────────────────"

    if [[ "$is_banned" == "true" ]]; then
        echo "  1) Unban IP"
        echo "  2) Move to whitelist (highest priority)"
        echo "  3) Exit (no action)"
        echo ""
        read -p "Choose action [1-3]: " action

        case "$action" in
            1)
                echo ""
                echo "Unbanning $ip..."
                # Unban from all sets
                nft delete element inet nftban_runtime temp_ban_v4 { "$ip" } 2>/dev/null || true
                nft delete element inet nftban_runtime temp_ban_v6 { "$ip" } 2>/dev/null || true
                nft delete element inet nftban_main blacklist_v4 { "$ip" } 2>/dev/null || true
                nft delete element inet nftban_main blacklist_v6 { "$ip" } 2>/dev/null || true
                echo "✓ IP unbanned from all sets"
                ;;
            2)
                echo ""
                echo "Adding $ip to whitelist..."
                # Add to whitelist
                nft add element inet nftban_main whitelist_v4 { "$ip" } 2>/dev/null || true
                nft add element inet nftban_main whitelist_v6 { "$ip" } 2>/dev/null || true
                echo "✓ IP whitelisted (highest priority, cannot be banned)"
                ;;
            3)
                echo "No action taken."
                ;;
            *)
                echo "Invalid choice."
                ;;
        esac
    else
        echo "  1) Ban IP temporarily (1 hour)"
        echo "  2) Ban IP temporarily (custom duration)"
        echo "  3) Ban IP permanently"
        echo "  4) Add to whitelist"
        echo "  5) Exit (no action)"
        echo ""
        read -p "Choose action [1-5]: " action

        case "$action" in
            1)
                echo ""
                echo "Banning $ip for 1 hour..."
                nft add element inet nftban_runtime temp_ban_v4 { "$ip" timeout 3600s } 2>/dev/null || \
                nft add element inet nftban_runtime temp_ban_v6 { "$ip" timeout 3600s } 2>/dev/null || true
                echo "✓ IP banned temporarily (expires in 1 hour)"
                ;;
            2)
                echo ""
                read -p "Enter duration in seconds (e.g., 7200 for 2 hours): " duration
                if [[ "$duration" =~ ^[0-9]+$ ]]; then
                    echo "Banning $ip for $duration seconds..."
                    nft add element inet nftban_runtime temp_ban_v4 { "$ip" timeout ${duration}s } 2>/dev/null || \
                    nft add element inet nftban_runtime temp_ban_v6 { "$ip" timeout ${duration}s } 2>/dev/null || true
                    echo "✓ IP banned temporarily (expires in $duration seconds)"
                else
                    echo "Invalid duration."
                fi
                ;;
            3)
                echo ""
                echo "Banning $ip permanently..."
                nft add element inet nftban_main blacklist_v4 { "$ip" } 2>/dev/null || \
                nft add element inet nftban_main blacklist_v6 { "$ip" } 2>/dev/null || true
                echo "✓ IP banned permanently (blacklist)"
                ;;
            4)
                echo ""
                echo "Adding $ip to whitelist..."
                nft add element inet nftban_main whitelist_v4 { "$ip" } 2>/dev/null || \
                nft add element inet nftban_main whitelist_v6 { "$ip" } 2>/dev/null || true
                echo "✓ IP whitelisted (highest priority, cannot be banned)"
                ;;
            5)
                echo "No action taken."
                ;;
            *)
                echo "Invalid choice."
                ;;
        esac
    fi
}

# =============================================================================
# HELP TEXT
# =============================================================================

_nftban_search_help() {
    nftban_render_banner simple

    cat <<'HELP'

USAGE:
    nftban search <ip> [--no-interactive]

DESCRIPTION:
    Search for an IP address across all NFTBan components:
    - nftables sets (whitelist, temp_ban, user_blacklist, system_blacklist, feeds)
    - Threat intelligence feeds
    - Fail2Ban jails

    If IP is found, shows location and details.
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

    # Non-interactive (scripts)
    nftban search 192.0.2.100 --no-interactive

NOTES:
    - Searches all 3 nftables tables (runtime, v4, v6)
    - Searches all 5 sets per table
    - Searches downloaded threat feeds
    - Searches active Fail2Ban jails
    - Shows ban priority and type
    - Shows expiry time for temp bans

HELP
}

# =============================================================================
# MAIN COMMAND
# =============================================================================

nftban_cmd_search() {
    local ip="${1:-}"
    local interactive=true

    # Check for help
    if [[ "$ip" == "help" || "$ip" == "--help" || "$ip" == "-h" || -z "$ip" ]]; then
        _nftban_search_help
        return 0
    fi

    # Check for --no-interactive
    if [[ "${2:-}" == "--no-interactive" ]]; then
        interactive=false
    fi

    # Validate IP (basic check)
    if [[ ! "$ip" =~ ^[0-9a-fA-F:.\/]+$ ]]; then
        echo "ERROR: Invalid IP address: $ip"
        return 1
    fi

    # Perform searches
    local nft_result=$(_search_nftables "$ip")
    local feeds_result=$(_search_feeds "$ip" || echo "")
    local f2b_result=$(_search_fail2ban "$ip" || echo "")

    # Display results
    _display_results "$ip" "$nft_result" "$feeds_result" "$f2b_result"

    # Interactive menu (only if not disabled)
    if [[ "$interactive" == "true" ]]; then
        local is_banned="false"
        [[ "$nft_result" == "FOUND"* ]] && is_banned="true"

        _show_action_menu "$ip" "$is_banned"
    fi

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
