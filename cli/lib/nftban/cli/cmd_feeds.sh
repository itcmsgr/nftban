#!/usr/bin/env bash
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load prerequisite checker
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh" || return 1
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi

# Load timestamp library for date formatting
# shellcheck source=/usr/lib/nftban/lib/nftban_timestamp.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" || return 1
fi

# Load file utilities library for file age/freshness checks
# shellcheck source=/usr/lib/nftban/lib/nftban_file_utils.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_file_utils.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_file_utils.sh" || return 1
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER" || return 1
fi
# NFTBan v1.7.0 - Feeds CLI Handler
# =============================================================================
#
# SPDX-License-Identifier: MPL-2.0
# Purpose: Beautiful numbered menu interface for threat feeds
#
# meta:name="cmd_feeds"
# meta:type="cli"
# meta:header="Feeds CLI"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Interactive selection menu for threat intelligence feeds"
# meta:input="User selection (numbers, ranges, categories, all)"
# meta:output="Beautiful categorized feed listing and status"
# meta:depends="bash,nftban_feeds.sh,nftban_output.sh"
#
# meta:inventory.files=""
# meta:inventory.binaries="curl,nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/feeds.conf"
# meta:inventory.systemd_units="nftban-core-feeds.timer"
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2026-01-28"
# =============================================================================



# =============================================================================

# CONFIGURATION
# =============================================================================

# Load security helper for capability checks
if [[  ! $(type -t nftban_has_net_admin) == "function" ]]; then
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_security.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_security.sh" || return 1
    fi
fi

# Load feeds core module
if [[ ! $(type -t nftban_feeds_discover_all) == "function" ]]; then
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_feeds.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_feeds.sh" || return 1
    else
        echo "ERROR: nftban_feeds.sh not found" >&2
        return 1
    fi
fi

# =============================================================================

# BEAUTIFUL SELECTION MENU
# =============================================================================


# Interactive selection menu with numbers
nftban_feeds_select() {
    # Source output module for banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        nftban_banner
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║         NFTBan v${NFTBAN_VERSION:-1.0.0} - Threat Feeds Selection                  ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    # Discover all feeds and build menu
    local all_feeds
    all_feeds=$(nftban_feeds_discover_all)

    # Build array for numbered selection
    declare -a feed_array=()
    local feed_num=0

    # Get all categories
    local categories
    categories=$(nftban_feeds_get_categories)

    # Display by category
    for category in $categories; do
        echo "┌──────────────────────────────────────────────────────────────────┐"
        printf "│ Category: %-55s │\n" "${category}"
        echo "└──────────────────────────────────────────────────────────────────┘"

        local category_feeds
        category_feeds=$(nftban_feeds_get_by_category "$category")

        for feed in $category_feeds; do
            feed_num=$((feed_num + 1))

            # Store feed name for later selection
            feed_array[$feed_num]="$feed"

            local enabled
            enabled=$(nftban_feeds_get_property "$feed" "ENABLED")
            local description
            description=$(nftban_feeds_get_property "$feed" "DESCRIPTION")
            local size
            size=$(nftban_feeds_get_property "$feed" "SIZE")
            local interval
            interval=$(nftban_feeds_get_property "$feed" "INTERVAL")

            local status_icon="[✗]"
            [[ "$enabled" == "true" ]] && status_icon="[✓]"

            printf "%3d. %-4s %-25s %-12s (%s)\n" "$feed_num" "$status_icon" "${feed:0:25}" "${size:-~? IPs}" "${interval:-DAILY}"
            printf "      └─ %s\n" "$description"
            echo ""
        done
    done

    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    echo "SELECTION OPTIONS:"
    echo "  • Enter number(s):  1 3 6        (enable feeds 1, 3, and 6)"
    echo "  • Range:            1-5          (enable feeds 1 through 5)"
    echo "  • Category:         ssh          (enable all SSH feeds)"
    echo "  • Multiple:         1,3,ssh      (enable 1, 3, and all SSH)"
    echo "  • All:              all          (enable ALL feeds)"
    echo "  • Quit:             q            (exit without changes)"
    echo ""

    # Show current status
    local stats
    stats=$(nftban_feeds_get_stats)
    echo "Current status: $stats"
    echo ""

    # Read user selection
    echo -n "Select feeds to enable: "
    read -r selection

    # Handle quit
    if [[ "$selection" == "q" ]] || [[ "$selection" == "Q" ]]; then
        echo "Exited without changes."
        return 0
    fi

    # Process selection
    local feeds_to_enable=()

    # Handle "all"
    if [[ "$selection" == "all" ]]; then
        feeds_to_enable=("${feed_array[@]}")
    # Handle category
    elif [[ "$selection" =~ ^(protection|ssh|web|email)$ ]]; then
        local cat_feeds
        cat_feeds=$(nftban_feeds_get_by_category "$selection")
        for feed in $cat_feeds; do
            feeds_to_enable+=("$feed")
        done
    else
        # Parse numbers, ranges, and comma-separated
        # Split by comma first
        IFS=',' read -ra parts <<< "$selection"

        for part in "${parts[@]}"; do
            part=$(echo "$part" | xargs)  # trim whitespace

            # Check if category
            if [[ "$part" =~ ^(protection|ssh|web|email)$ ]]; then
                local cat_feeds
                cat_feeds=$(nftban_feeds_get_by_category "$part")
                for feed in $cat_feeds; do
                    feeds_to_enable+=("$feed")
                done
            # Check if range (e.g., 1-5)
            elif [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
                local start="${BASH_REMATCH[1]}"
                local end="${BASH_REMATCH[2]}"

                for ((i=start; i<=end; i++)); do
                    if [[ -n "${feed_array[$i]:-}" ]]; then
                        feeds_to_enable+=("${feed_array[$i]}")
                    fi
                done
            # Single number
            elif [[ "$part" =~ ^[0-9]+$ ]]; then
                if [[ -n "${feed_array[$part]:-}" ]]; then
                    feeds_to_enable+=("${feed_array[$part]}")
                fi
            fi
        done
    fi

    # Deduplicate
    local unique_feeds=()
    mapfile -t unique_feeds < <(printf '%s\n' "${feeds_to_enable[@]}" | sort -u)

    if [[ ${#unique_feeds[@]} -eq 0 ]]; then
        echo "No feeds selected."
        return 0
    fi

    echo ""
    echo "Enabling ${#unique_feeds[@]} feed(s)..."
    echo ""

    for feed in "${unique_feeds[@]}"; do
        echo "→ Enabling: $feed"
        nftban_feeds_enable "$feed"
    done

    echo ""
    echo "✅ Done! Feeds enabled and updated."
    echo ""
    echo "View status with: nftban feeds list"
    echo "View logs with: tail -f ${NFTBAN_LOG_DIR:-/var/log/nftban}/feeds.log"
}

# List feeds with beautiful formatting
# v1.59.0 UX-2: Added --json support
nftban_feeds_list() {
    # Check for --json flag
    local _feeds_json_mode="false"
    local _arg
    for _arg in "$@"; do
        [[ "$_arg" == "--json" ]] && _feeds_json_mode="true"
    done

    if [[ "$_feeds_json_mode" == "true" ]]; then
        # JSON output: array of feed objects
        local _json='{"feeds":['
        local _first=true
        local _categories
        _categories=$(nftban_feeds_get_categories 2>/dev/null) || true
        for _cat in $_categories; do
            local _cat_feeds
            _cat_feeds=$(nftban_feeds_get_by_category "$_cat" 2>/dev/null) || true
            for _feed in $_cat_feeds; do
                local _enabled _desc _interval _count=0
                _enabled=$(nftban_feeds_get_property "$_feed" "ENABLED" 2>/dev/null) || true
                _desc=$(nftban_feeds_get_property "$_feed" "DESCRIPTION" 2>/dev/null) || true
                _interval=$(nftban_feeds_get_property "$_feed" "INTERVAL" 2>/dev/null) || true
                if [[ "$_enabled" == "true" ]]; then
                    local _feed_lower="${_feed,,}"
                    local _feed_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds/${_feed_lower}.txt"
                    [[ -f "$_feed_file" ]] && _count=$(wc -l < "$_feed_file")
                fi
                [[ "$_first" == "true" ]] && _first=false || _json+=","
                # Escape description for JSON
                _desc="${_desc//\\/\\\\}"
                _desc="${_desc//\"/\\\"}"
                _json+="{\"name\":\"$_feed\",\"category\":\"$_cat\",\"enabled\":$_enabled,\"description\":\"$_desc\",\"interval\":\"${_interval:-DAILY}\",\"ips\":$_count}"
            done
        done
        _json+=']}'
        echo "$_json"
        return 0
    fi

    # Source output module for banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        nftban_banner
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║        NFTBan v${NFTBAN_VERSION:-1.0.0} - Available Threat Feeds                   ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    # Show stats
    local stats
    stats=$(nftban_feeds_get_stats)
    echo "Status: $stats"
    echo ""

    # Get all categories
    local categories
    categories=$(nftban_feeds_get_categories)

    # Display by category
    for category in $categories; do
        local cat_display
        case "$category" in
            protection) cat_display="Protection" ;;
            ssh) cat_display="SSH" ;;
            web) cat_display="Web" ;;
            email) cat_display="Email" ;;
            *) cat_display="$category" ;;
        esac

        echo "┌─ $cat_display ─────────────────────────────────────────────────────┐"

        local category_feeds
        category_feeds=$(nftban_feeds_get_by_category "$category")

        for feed in $category_feeds; do
            local enabled
            enabled=$(nftban_feeds_get_property "$feed" "ENABLED")
            local description
            description=$(nftban_feeds_get_property "$feed" "DESCRIPTION")
            local interval
            interval=$(nftban_feeds_get_property "$feed" "INTERVAL")

            local status_icon="[✗]"
            local status_text="0 IPs (off)"

            if [[ "$enabled" == "true" ]]; then
                status_icon="[✓]"
                local feed_lower="${feed,,}"  # Convert to lowercase
                local feed_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds/${feed_lower}.txt"
                if [[ -f "$feed_file" ]]; then
                    local count
                    count=$(wc -l < "$feed_file")
                    status_text="$count IPs"
                else
                    status_text="enabled"
                fi
            fi

            printf "│ %-4s %-25s %-15s %-10s │\n" "$status_icon" "${feed:0:25}" "$status_text" "${interval:-DAILY}"
        done

        echo "└──────────────────────────────────────────────────────────────────┘"
        echo ""
    done

    echo "Commands:"
    echo "  nftban feeds select             Interactive selection menu"
    echo "  nftban feeds enable <feed>      Enable specific feed"
    echo "  nftban feeds disable <feed>     Disable specific feed"
    echo "  nftban feeds update              Update all enabled feeds"
    echo "  nftban feeds status              Detailed status"
    echo ""
}

# JSON-aware wrapper for feeds status
nftban_feeds_status_json() {
    local json_mode="${1:-false}"

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        # Get all feeds
        local all_feeds
        all_feeds=$(nftban_feeds_discover_all 2>/dev/null || echo "")

        # Build enabled feeds list
        local -a enabled_feeds=()
        local enabled_count=0
        local total_count=0
        local total_ips=0

        for feed in $all_feeds; do
            total_count=$((total_count + 1))
            local enabled
            enabled=$(nftban_feeds_get_property "$feed" "ENABLED" 2>/dev/null || echo "false")

            if [[ "$enabled" == "true" ]]; then
                enabled_count=$((enabled_count + 1))
                local feed_lower="${feed,,}"  # Convert to lowercase
                local feed_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds/${feed_lower}.txt"
                local count=0
                local mtime=""

                if [[ -f "$feed_file" ]]; then
                    count=$(wc -l < "$feed_file" 2>/dev/null || echo "0")
                    # Use library function with fallback
                    if declare -f nftban_file_mtime >/dev/null 2>&1; then
                        local mtime_unix
                        mtime_unix=$(nftban_file_mtime "$feed_file")
                        mtime=$(date -d "@${mtime_unix}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || \
                                date -r "${mtime_unix}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
                    else
                        mtime=$(date -r "$feed_file" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
                    fi
                    total_ips=$((total_ips + count))
                fi

                enabled_feeds+=("{\"name\":\"$feed\",\"enabled\":true,\"ip_count\":$count,\"last_update\":\"$mtime\"}")
            fi
        done

        # Build JSON array
        local feeds_json="["
        local first=true
        for feed_json in "${enabled_feeds[@]}"; do
            [[ "$first" == "false" ]] && feeds_json+=","
            feeds_json+="$feed_json"
            first=false
        done
        feeds_json+="]"

        # Build response
        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg enabled_count "$enabled_count" \
                --arg total_count "$total_count" \
                --arg total_ips "$total_ips" \
                --argjson feeds "$feeds_json" \
                '{
                    summary: {
                        enabled_count: ($enabled_count | tonumber),
                        total_count: ($total_count | tonumber),
                        total_ips: ($total_ips | tonumber)
                    },
                    enabled_feeds: $feeds
                }')
        else
            data="{\"summary\":{\"enabled_count\":$enabled_count,\"total_count\":$total_count,\"total_ips\":$total_ips},\"enabled_feeds\":$feeds_json}"
        fi

        json_output "true" "$data"
        return 0
    fi

    # Human-readable mode
    nftban_feeds_status
}

# Show detailed status
nftban_feeds_status() {
    # Source output module for banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        nftban_banner
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════════════"
    echo " NFTBan Threat Feeds Status"
    echo "═══════════════════════════════════════════════════════════════════"
    echo ""

    # Overall stats
    local stats
    stats=$(nftban_feeds_get_stats)
    echo "Status: $stats"
    echo ""

    # Enabled feeds detail
    echo "Enabled Feeds:"
    local all_feeds
    all_feeds=$(nftban_feeds_discover_all)

    local found_enabled=false
    for feed in $all_feeds; do
        local enabled
        enabled=$(nftban_feeds_get_property "$feed" "ENABLED")

        if [[ "$enabled" == "true" ]]; then
            found_enabled=true
            # Convert to lowercase for filename (files are saved as lowercase)
            local feed_lowercase
            feed_lowercase=$(echo "$feed" | tr '[:upper:]' '[:lower:]')
            local feed_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds/${feed_lowercase}.txt"
            if [[ -f "$feed_file" ]]; then
                local count
                count=$(wc -l < "$feed_file")
                local mtime
                mtime=$(date -r "$feed_file" '+%Y-%m-%d %H:%M:%S')
                printf "  • %-30s %8s IPs  (Updated: %s)\n" "$feed" "$count" "$mtime"
            else
                printf "  • %-30s %s\n" "$feed" "not yet downloaded"
            fi
        fi
    done

    if [[ "$found_enabled" == "false" ]]; then
        echo "  (none enabled yet)"
    fi

    echo ""
    echo "Log file: ${NFTBAN_LOG_DIR:-/var/log/nftban}/feeds.log"
    echo "Storage: ${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds/"
    echo ""
}

# =============================================================================

# MAIN COMMAND HANDLER
# =============================================================================


nftban_cmd_feeds() {
    local action="${1:-list}"
    local json_mode=false

    # Check for --json flag in arguments
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break
    done

    shift || true

    case "$action" in
        select)
            # Check CAP_NET_ADMIN capability for nftables modifications
            if declare -F nftban_require_net_admin_or_exit >/dev/null 2>&1; then
                nftban_require_net_admin_or_exit
            fi
            nftban_feeds_select
            ;;
        list)
            nftban_feeds_list "$@"
            ;;
        enable)
            # Check CAP_NET_ADMIN capability for nftables modifications
            if declare -F nftban_require_net_admin_or_exit >/dev/null 2>&1; then
                nftban_require_net_admin_or_exit
            fi
            if [[ $# -lt 1 ]] || [[ "${1}" == "--json" ]]; then
                if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
                    json_output "false" '{}' "Usage: nftban feeds enable <feed_name>"
                else
                    echo "ERROR: Usage: nftban feeds enable <feed_name>" >&2
                fi
                return 1
            fi
            nftban_feeds_enable_json "$1" "$json_mode"
            ;;
        disable)
            # Check CAP_NET_ADMIN capability for nftables modifications
            if declare -F nftban_require_net_admin_or_exit >/dev/null 2>&1; then
                nftban_require_net_admin_or_exit
            fi
            # Parse feed name (v1.18.1: --clean is now default behavior)
            local feed_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --clean) ;; # v1.18.1: now default, kept for backwards compat
                    --json) ;; # already handled
                    -*) echo "Unknown option: $1" >&2; return 1 ;;
                    *) feed_name="$1" ;;
                esac
                shift
            done
            if [[ -z "$feed_name" ]]; then
                if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
                    json_output "false" '{}' "Usage: nftban feeds disable <feed_name>"
                else
                    echo "ERROR: Usage: nftban feeds disable <feed_name>" >&2
                fi
                return 1
            fi
            # v1.18.1: nftban_feeds_disable now handles cache cleanup + IPC flush automatically
            nftban_feeds_disable_json "$feed_name" "$json_mode"
            ;;
        enable-cat|enable-category)
            # Check CAP_NET_ADMIN capability for nftables modifications
            if declare -F nftban_require_net_admin_or_exit >/dev/null 2>&1; then
                nftban_require_net_admin_or_exit
            fi
            if [[ $# -lt 1 ]]; then
                echo "ERROR: Usage: nftban feeds enable-category <category>" >&2
                return 1
            fi
            local cat_feeds
            cat_feeds=$(nftban_feeds_get_by_category "$1")

            if [[ -z "$cat_feeds" ]]; then
                echo "⚠️  No feeds found in category: $1"
                echo ""
                echo "Available categories: protection, ssh, web, email, anonymity"
                echo ""
                echo "Run 'nftban feeds list' to see all feeds by category"
                return 1
            fi

            echo "⏳ Enabling all feeds in category: $1"
            echo ""
            local enabled_count=0
            local failed_count=0

            for feed in $cat_feeds; do
                echo "  • Enabling $feed..."
                if nftban_feeds_enable "$feed" "true"; then  # Use quiet mode for batch
                    echo "    ✅ $feed enabled"
                    # v1.19.20 FIX
                    ((enabled_count++)) || true
                else
                    echo "    ❌ $feed failed"
                    # v1.19.20 FIX
                    ((failed_count++)) || true
                fi
            done

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            if [[ $failed_count -eq 0 ]]; then
                echo "✅ Successfully enabled and downloaded $enabled_count feed(s) in category '$1'"
            else
                echo "✅ Enabled $enabled_count feed(s), ❌ Failed $failed_count feed(s)"
                echo "⚠️  Check errors in: ${NFTBAN_LOG_DIR:-/var/log/nftban}/feeds.log"
            fi
            echo ""
            echo "Check status: nftban feeds status"
            echo ""
            ;;
        update)
            # Check CAP_NET_ADMIN capability for nftables modifications
            if declare -F nftban_require_net_admin_or_exit >/dev/null 2>&1; then
                nftban_require_net_admin_or_exit
            fi
            # Use Go binary for feeds update (dynamic, central architecture)
            if [[ -x "${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}" ]]; then
                "${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR}/bin/nftban-core}" feeds update
            else
                # Fallback to bash implementation
                nftban_feeds_update_json "$json_mode" "$@"
            fi
            ;;
        status)
            nftban_feeds_status_json "$json_mode"
            ;;
        config)
            nftban_feeds_config "$json_mode"
            ;;
        stats)
            nftban_feeds_stats "$json_mode"
            ;;
        test)
            nftban_feeds_test "$json_mode" "$@"
            ;;
        help|-h|--help)
            _nftban_feeds_help
            ;;
        *)
            echo "ERROR: Unknown feeds action: $action" >&2
            _nftban_feeds_help
            return 1
            ;;
    esac
}

# =============================================================================
# CONFIG, STATS, TEST COMMANDS
# =============================================================================

# Config command - show feeds configuration
nftban_feeds_config() {
    local json_mode="${1:-false}"
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/feeds.conf"
    local config_local="${config_file}.local"

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --arg config_file "$config_file" \
                --arg config_local "$config_local" \
                --arg local_exists "$([[ -f "$config_local" ]] && echo "true" || echo "false")" \
                --arg auto_update "${FEEDS_AUTO_UPDATE:-true}" \
                --arg storage_dir "${NFTBAN_FEEDS_STORAGE_DIR:-/var/lib/nftban/feeds}" \
                --arg cache_dir "${NFTBAN_FEEDS_CACHE_DIR:-/var/cache/nftban/feeds}" \
                '{
                    config_file: $config_file,
                    config_local: $config_local,
                    local_exists: ($local_exists == "true"),
                    settings: {
                        auto_update: ($auto_update == "true"),
                        storage_dir: $storage_dir,
                        cache_dir: $cache_dir
                    }
                }')
        else
            data="{\"config_file\":\"$config_file\"}"
        fi
        json_output "true" "$data"
        return 0
    fi

    echo "Feeds Configuration"
    echo "==================="
    echo ""
    echo "  Config File:    $config_file"
    echo "  Override File:  $config_local"
    if [[ -f "$config_local" ]]; then
        echo "  Status:         [Override Active]"
    else
        echo "  Status:         [Using defaults]"
    fi
    echo ""
    echo "Settings:"
    echo "  Auto-Update:    ${FEEDS_AUTO_UPDATE:-true}"
    echo "  Storage Dir:    ${NFTBAN_FEEDS_STORAGE_DIR:-/var/lib/nftban/feeds}"
    echo "  Cache Dir:      ${NFTBAN_FEEDS_CACHE_DIR:-/var/cache/nftban/feeds}"
    echo "  Log File:       ${NFTBAN_FEEDS_LOG:-/var/log/nftban/feeds.log}"
    echo ""
    echo "To override settings, create/edit: $config_local"
}

# Stats command - show feeds statistics
nftban_feeds_stats() {
    local json_mode="${1:-false}"

    # Count enabled feeds and total IPs
    local total_feeds=0
    local enabled_count=0
    local total_ips=0

    local all_feeds
    all_feeds=$(nftban_feeds_discover_all 2>/dev/null || echo "")

    for feed in $all_feeds; do
        ((total_feeds++)) || true
        local enabled
        enabled=$(nftban_feeds_get_property "$feed" "ENABLED" 2>/dev/null || echo "false")
        if [[ "$enabled" == "true" ]]; then
            ((enabled_count++)) || true
            local feed_lower="${feed,,}"
            local feed_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds/${feed_lower}.txt"
            if [[ -f "$feed_file" ]]; then
                local count
                count=$(wc -l < "$feed_file" 2>/dev/null || echo "0")
                total_ips=$((total_ips + count))
            fi
        fi
    done

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        local data
        if command -v jq &>/dev/null; then
            data=$(jq -n \
                --argjson total_feeds "$total_feeds" \
                --argjson enabled_count "$enabled_count" \
                --argjson total_ips "$total_ips" \
                '{
                    stats: {
                        total_feeds: $total_feeds,
                        enabled_feeds: $enabled_count,
                        total_ips: $total_ips
                    }
                }')
        else
            data="{\"stats\":{\"total_feeds\":$total_feeds,\"enabled_feeds\":$enabled_count,\"total_ips\":$total_ips}}"
        fi
        json_output "true" "$data"
        return 0
    fi

    echo "Feeds Statistics"
    echo "================"
    echo ""
    echo "  Total Feeds:    $total_feeds"
    echo "  Enabled Feeds:  $enabled_count"
    echo "  Total IPs:      $total_ips"
    echo ""
}

# Test command - test feed connectivity and configuration
nftban_feeds_test() {
    local json_mode="${1:-false}"
    # shellcheck disable=SC2034  # Reserved for future single-feed test filtering
    local test_feed="${2:-}"

    echo "Feeds Module Test"
    echo "================="
    echo ""

    local errors=0

    # Test 1: Check config file
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/feeds.conf"
    if [[ -f "$config_file" ]]; then
        echo "  [PASS] Config file exists: $config_file"
    else
        echo "  [FAIL] Config file missing: $config_file"
        ((errors++)) || true
    fi

    # Test 2: Check storage directory
    local storage_dir="${NFTBAN_FEEDS_STORAGE_DIR:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds}"
    if [[ -d "$storage_dir" ]]; then
        echo "  [PASS] Storage directory exists: $storage_dir"
    else
        echo "  [FAIL] Storage directory missing: $storage_dir"
        ((errors++)) || true
    fi

    # Test 3: Check curl availability
    if command -v curl &>/dev/null; then
        echo "  [PASS] curl is available"
    else
        echo "  [FAIL] curl not found (required for feed downloads)"
        ((errors++)) || true
    fi

    # Test 4: Check network connectivity (test common feed URL)
    if curl -s --max-time 5 --head "https://www.spamhaus.org" &>/dev/null; then
        echo "  [PASS] Network connectivity OK"
    else
        echo "  [WARN] Cannot reach spamhaus.org (network issue?)"
    fi

    echo ""
    if [[ $errors -eq 0 ]]; then
        echo "All tests passed!"
        return 0
    else
        echo "Tests completed with $errors error(s)"
        return 1
    fi
}

# =============================================================================
# JSON-AWARE WRAPPER FUNCTIONS
# =============================================================================

# JSON-aware wrapper for feeds enable
nftban_feeds_enable_json() {
    local feed="$1"
    local json_mode="${2:-false}"

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        # Call the real enable function and capture result
        if nftban_feeds_enable "$feed" "true" 2>/dev/null; then
            local feed_lower="${feed,,}"  # Convert to lowercase
            local feed_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds/${feed_lower}.txt"
            local count=0
            [[ -f "$feed_file" ]] && count=$(wc -l < "$feed_file" 2>/dev/null || echo "0")

            local data
            data=$(json_build_object "feed" "$feed" "enabled" "true" "ip_count" "$count")
            json_output "true" "$data"
            return 0
        else
            json_output "false" '{}' "Failed to enable feed: $feed"
            return 1
        fi
    else
        # Human-readable mode - propagate return code
        nftban_feeds_enable "$feed"
        return $?
    fi
}

# JSON-aware wrapper for feeds disable
nftban_feeds_disable_json() {
    local feed="$1"
    local json_mode="${2:-false}"

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        # Call the real disable function
        if nftban_feeds_disable "$feed" 2>/dev/null; then
            local data
            data=$(json_build_object "feed" "$feed" "enabled" "false")
            json_output "true" "$data"
            return 0
        else
            json_output "false" '{}' "Failed to disable feed: $feed"
            return 1
        fi
    else
        # Human-readable mode - propagate return code
        nftban_feeds_disable "$feed"
        return $?
    fi
}

# JSON-aware wrapper for feeds update
nftban_feeds_update_json() {
    local json_mode="${1:-false}"
    shift || true

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        if [[ $# -ge 1 ]] && [[ "$1" != "--json" ]]; then
            # Update specific feed
            local feed="$1"
            if nftban_feeds_update_single "$feed" 2>/dev/null; then
                local feed_lower="${feed,,}"  # Convert to lowercase
                local feed_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds/${feed_lower}.txt"
                local count=0
                local mtime=""

                if [[ -f "$feed_file" ]]; then
                    count=$(wc -l < "$feed_file" 2>/dev/null || echo "0")
                    mtime=$(date -r "$feed_file" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
                fi

                local data
                if command -v jq &>/dev/null; then
                    data=$(jq -n \
                        --arg feed "$feed" \
                        --arg count "$count" \
                        --arg mtime "$mtime" \
                        '{feed: $feed, ip_count: ($count | tonumber), last_update: $mtime}')
                else
                    data="{\"feed\":\"$feed\",\"ip_count\":$count,\"last_update\":\"$mtime\"}"
                fi

                json_output "true" "$data"
            else
                json_output "false" '{}' "Failed to update feed: $feed"
                return 1
            fi
        else
            # Update all feeds
            json_output "false" '{}' "Update all feeds not yet supported in JSON mode. Specify a feed name."
            return 1
        fi
    else
        # Human-readable mode
        if [[ $# -ge 1 ]] && [[ "$1" != "--json" ]]; then
            echo "⏳ Updating feed: $1"
            if nftban_feeds_update_single "$1"; then
                echo "✓ Feed updated successfully"
            else
                echo "✗ Feed update failed (check ${NFTBAN_LOG_DIR:-/var/log/nftban}/feeds.log)"
                return 1
            fi
        else
            nftban_feeds_update_all
        fi
    fi
}

# =============================================================================

# HELP TEXT
# =============================================================================


_nftban_feeds_help() {
    # Source output module for banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
        nftban_banner
    fi

    cat <<HELP

USAGE:
    nftban feeds <command> [options]

COMMANDS:
    select              Interactive numbered menu (recommended!)
    list                List all feeds with status
    enable <feed>       Enable specific feed
    disable <feed>      Disable specific feed
    enable-cat <cat>    Enable all feeds in category
    update [feed]       Update feeds (all or specific)
    status              Show detailed status

    help                Show this help message

CATEGORIES:
    protection          General security & protection feeds
    ssh                 SSH attack protection
    web                 Web server attack protection
    email               Mail server & spam protection

EXAMPLES:
    # Interactive selection menu (RECOMMENDED!)
    sudo nftban feeds select

    # List all available feeds
    nftban feeds list

    # Enable specific feed
    sudo nftban feeds enable SPAMHAUS_DROP

    # Enable all SSH protection feeds
    sudo nftban feeds enable-category ssh

    # Update all enabled feeds
    sudo nftban feeds update

    # Check status
    nftban feeds status

    # View logs
    tail -f ${NFTBAN_LOG_DIR:-/var/log/nftban}/feeds.log

FILE LOCATIONS:
    ┌──────────────┬───────────────────────────────┬──────────────────────────┐
    │ Purpose      │ Path                          │ Variable                 │
    ├──────────────┼───────────────────────────────┼──────────────────────────┤
    │ Parsed feeds │ /var/lib/nftban/feeds/        │ NFTBAN_FEEDS_STORAGE_DIR │
    │ Cache/temp   │ /var/cache/nftban/feeds/      │ NFTBAN_FEEDS_CACHE_DIR   │
    │ Config       │ /etc/nftban/conf.d/feeds.conf │ NFTBAN_FEEDS_CONFIG      │
    │ Log          │ ${NFTBAN_LOG_DIR}/feeds.log     │ NFTBAN_FEEDS_LOG         │
    └──────────────┴───────────────────────────────┴──────────────────────────┘

NOTES:
    • ALL feeds are DISABLED by default for safety
    • Use 'select' for easy numbered selection interface
    • Feeds are updated automatically if FEEDS_AUTO_UPDATE=true

HELP
}

# Export function
# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "feeds"

export -f nftban_cmd_feeds
export -f nftban_feeds_config
export -f nftban_feeds_stats
export -f nftban_feeds_test
export -f nftban_feeds_disable_json
export -f nftban_feeds_enable_json
export -f _nftban_feeds_help
export -f nftban_feeds_list
export -f nftban_feeds_select
export -f nftban_feeds_status
export -f nftban_feeds_status_json
export -f nftban_feeds_update_json
