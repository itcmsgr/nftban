#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.20 - Feeds CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Beautiful numbered menu interface for threat feeds
#
# meta:name=cmd_feeds
# meta:type=cli
# meta:header=Feeds CLI
# meta:version=0.32.20
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Interactive selection menu for threat intelligence feeds
# meta:input=User selection (numbers, ranges, categories, "all")
# meta:output=Beautiful categorized feed listing and status
#
# **Inventory & Requirements**
# meta:depends=bash,nftban_feeds.sh,nftban_output.sh
#
# meta:created_date=2025-11-05
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"

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
    echo "║         NFTBan v0.32.6 - Threat Feeds Selection                  ║"
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
    local unique_feeds=($(printf '%s\n' "${feeds_to_enable[@]}" | sort -u))

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
    echo "View logs with: tail -f /var/log/nftban/feeds.log"
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
    echo "║        NFTBan v0.32.6 - Available Threat Feeds                   ║"
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
            local status_text="disabled"

            if [[ "$enabled" == "true" ]]; then
                status_icon="[✓]"
                local feed_file="/var/lib/nftban/feeds/${feed}.txt"
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
    echo "  nftban feeds enable-cat <cat>   Enable category (ssh, web, etc)"
    echo "  nftban feeds update              Update all enabled feeds"
    echo "  nftban feeds status              Detailed status"
    echo ""
}

# Show detailed status
nftban_feeds_status() {
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
            local feed_file="/var/lib/nftban/feeds/${feed}.txt"
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
    echo "Log file: /var/log/nftban/feeds.log"
    echo "Storage: /var/lib/nftban/feeds/"
    echo ""
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_feeds() {
    local action="${1:-list}"
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
            nftban_feeds_list
            ;;
        enable)
            # Check CAP_NET_ADMIN capability for nftables modifications
            if declare -F nftban_require_net_admin_or_exit >/dev/null 2>&1; then
                nftban_require_net_admin_or_exit
            fi
            if [[ $# -lt 1 ]]; then
                echo "ERROR: Usage: nftban feeds enable <feed_name>" >&2
                exit 1
            fi
            nftban_feeds_enable "$1"
            ;;
        disable)
            # Check CAP_NET_ADMIN capability for nftables modifications
            if declare -F nftban_require_net_admin_or_exit >/dev/null 2>&1; then
                nftban_require_net_admin_or_exit
            fi
            if [[ $# -lt 1 ]]; then
                echo "ERROR: Usage: nftban feeds disable <feed_name>" >&2
                exit 1
            fi
            nftban_feeds_disable "$1"
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
            echo "✅ Enabled $enabled_count feed(s) in category '$1'"
            if [[ $failed_count -gt 0 ]]; then
                echo "⚠️  $failed_count feed(s) failed (check /var/log/nftban/feeds.log)"
            fi
            echo ""
            echo "⏳ Feeds downloading in background..."
            echo ""
            echo "Next steps:"
            echo "  • Check status: nftban feeds status"
            echo "  • View progress: tail -f /var/log/nftban/feeds.log"
            ;;
        update)
            # Check CAP_NET_ADMIN capability for nftables modifications
            if declare -F nftban_require_net_admin_or_exit >/dev/null 2>&1; then
                nftban_require_net_admin_or_exit
            fi
            if [[ $# -ge 1 ]]; then
                echo "⏳ Updating feed: $1"
                if nftban_feeds_update_single "$1"; then
                    echo "✓ Feed updated successfully"
                else
                    echo "✗ Feed update failed (check /var/log/nftban/feeds.log)"
                    exit 1
                fi
            else
                nftban_feeds_update_all
            fi
            ;;
        status)
            nftban_feeds_status
            ;;
        help)
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
# HELP TEXT
# =============================================================================

_nftban_feeds_help() {
    # Source output module for banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
        nftban_banner
    fi

    cat <<'HELP'

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
    tail -f /var/log/nftban/feeds.log

NOTES:
    • ALL feeds are DISABLED by default for safety
    • Use 'select' for easy numbered selection interface
    • Feeds are updated automatically if FEEDS_AUTO_UPDATE=true
    • Each feed has dedicated log at /var/log/nftban/feeds.log

HELP
}

# Export function
export -f nftban_cmd_feeds
