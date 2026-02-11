#!/usr/bin/env bash
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

# Load JSON helper for --json support
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh"
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load prerequisite checker
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_prereq.sh"
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh"
fi

# Load timestamp library for date formatting
# shellcheck source=/usr/lib/nftban/lib/nftban_timestamp.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh"
fi

# Load file utilities library for file age/freshness checks
# shellcheck source=/usr/lib/nftban/lib/nftban_file_utils.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/nftban_file_utils.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/nftban_file_utils.sh"
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER"
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
# meta:version="1.7.0"
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
        source "${NFTBAN_LIB_DIR}/core/nftban_security.sh"
    fi
fi

# Load feeds core module
if [[ ! $(type -t nftban_feeds_discover_all) == "function" ]]; then
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_feeds.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_feeds.sh"
    else
        echo "ERROR: nftban_feeds.sh not found" >&2
        exit 1
    fi
fi

# =============================================================================

# BEAUTIFUL SELECTION MENU
# =============================================================================


# Interactive selection menu with numbers
nftban_feeds_select() {
    # Source output module for banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
        nftban_banner
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║         NFTBan v1.0.0 - Threat Feeds Selection                  ║"
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
nftban_feeds_list() {
    # Source output module for banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
        nftban_banner
    fi

    echo ""
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║        NFTBan v1.0.0 - Available Threat Feeds                   ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""

    # Show stats
    local stats
    stats=$(nftban_feeds_get_stats)
    echo "📊 Status: $stats"
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
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
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
                exit 1
            fi
            nftban_feeds_enable_json "$1" "$json_mode"
            ;;
        disable)
            # Check CAP_NET_ADMIN capability for nftables modifications
            if declare -F nftban_require_net_admin_or_exit >/dev/null 2>&1; then
                nftban_require_net_admin_or_exit
            fi
            # Parse --clean flag
            local clean_mode=false
            local feed_name=""
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --clean) clean_mode=true ;;
                    --json) ;; # already handled
                    -*) echo "Unknown option: $1" >&2; exit 1 ;;
                    *) feed_name="$1" ;;
                esac
                shift
            done
            if [[ -z "$feed_name" ]]; then
                if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
                    json_output "false" '{}' "Usage: nftban feeds disable <feed_name> [--clean]"
                else
                    echo "ERROR: Usage: nftban feeds disable <feed_name> [--clean]" >&2
                    echo "       --clean: Also remove feed IPs from blacklist" >&2
                fi
                exit 1
            fi
            nftban_feeds_disable_json "$feed_name" "$json_mode"
            # If --clean, also flush the feed IPs from blacklist
            if [[ "$clean_mode" == "true" ]]; then
                echo ""
                echo "Removing feed IPs from blacklist (--clean)..."
                # Source the flush command and call feeds flush
                if [[ -f "${NFTBAN_LIB_DIR}/cli/cmd_flush.sh" ]]; then
                    source "${NFTBAN_LIB_DIR}/cli/cmd_flush.sh"
                    _flush_feeds true false  # skip_confirm=true, dry_run=false
                else
                    echo "WARN: cmd_flush.sh not found, cannot clean IPs" >&2
                fi
            fi
            ;;
        enable-cat|enable-category)
            # Check CAP_NET_ADMIN capability for nftables modifications
            if declare -F nftban_require_net_admin_or_exit >/dev/null 2>&1; then
                nftban_require_net_admin_or_exit
            fi
            if [[ $# -lt 1 ]]; then
                echo "ERROR: Usage: nftban feeds enable-category <category>" >&2
                exit 1
            fi
            local cat_feeds
            cat_feeds=$(nftban_feeds_get_by_category "$1")

            if [[ -z "$cat_feeds" ]]; then
                echo "⚠️  No feeds found in category: $1"
                echo ""
                echo "Available categories: protection, ssh, web, email, anonymity"
                echo ""
                echo "Run 'nftban feeds list' to see all feeds by category"
                exit 1
            fi

            echo "⏳ Enabling all feeds in category: $1"
            echo ""
            local enabled_count=0
            local failed_count=0

            for feed in $cat_feeds; do
                echo "  • Enabling $feed..."
                if nftban_feeds_enable "$feed" "true"; then  # Use quiet mode for batch
                    echo "    ✅ $feed enabled"
                    ((enabled_count++))
                else
                    echo "    ❌ $feed failed"
                    ((failed_count++))
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
        help|-h|--help)
            _nftban_feeds_help
            ;;
        *)
            echo "ERROR: Unknown feeds action: $action" >&2
            _nftban_feeds_help
            exit 1
            ;;
    esac
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
        else
            json_output "false" '{}' "Failed to enable feed: $feed"
            return 1
        fi
    else
        # Human-readable mode
        nftban_feeds_enable "$feed"
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
        else
            json_output "false" '{}' "Failed to disable feed: $feed"
            return 1
        fi
    else
        # Human-readable mode
        nftban_feeds_disable "$feed"
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
                exit 1
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
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
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

NOTES:
    • ALL feeds are DISABLED by default for safety
    • Use 'select' for easy numbered selection interface
    • Feeds are updated automatically if FEEDS_AUTO_UPDATE=true
    • Each feed has dedicated log at ${NFTBAN_LOG_DIR:-/var/log/nftban}/feeds.log

HELP
}

# Export function
# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "feeds"

export -f nftban_cmd_feeds
