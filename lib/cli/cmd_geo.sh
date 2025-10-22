#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - GEO-Blocking Command
# Version: 1.0.0
# Location: lib/cli/cmd_geo.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_geo_module.sh
# Description: GEO-blocking management
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# GEO-BLOCKING COMMAND HANDLER
# =============================================================================

cmd_geo() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        status)
            nftban_geo_status
            ;;
        enable)
            nftban_check_root || exit 1
            nftban_geo_enable
            ;;
        disable)
            nftban_check_root || exit 1
            nftban_geo_disable
            ;;
        help)
            nftban_geo_help
            ;;
        block)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban geo block <COUNTRY> [reason]"; exit 1; }
            nftban_geo_block_country "$1" "both"
            ;;
        unblock)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban geo unblock <COUNTRY>"; exit 1; }
            nftban_geo_unblock_country "$1" "both"
            ;;
        list)
            nftban_geo_list_blocked
            ;;
        check)
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban geo check <IP>"; exit 1; }
            nftban_geo_check_ip "$1"
            ;;
        reload|sync)
            nftban_check_root || exit 1
            nftban_geo_sync_blacklist
            ;;
        update)
            nftban_check_root || exit 1
            nftban_geo_update_database "${1:-ALL}"
            ;;
        init)
            nftban_check_root || exit 1
            nftban_geo_init
            ;;
        *)
            nftban_log_error "Unknown geo action: $action"
            echo ""
            echo "Available actions:"
            echo "  status                Show GEO-blocking status"
            echo "  enable                Enable GEO-blocking"
            echo "  disable               Disable GEO-blocking"
            echo "  help                  Show comprehensive help"
            echo "  block <COUNTRY>       Block a country (e.g., CN, RU)"
            echo "  unblock <COUNTRY>     Unblock a country"
            echo "  list                  List all blocked countries"
            echo "  check <IP>            Check if IP is GEO-blocked"
            echo "  reload                Reload blacklist to nftables"
            echo "  update [COUNTRY]      Update GeoIP database"
            echo "  init                  Initialize GEO-blocking system"
            echo ""
            echo "Examples:"
            echo "  nftban geo status"
            echo "  nftban geo help"
            echo "  nftban geo block CN"
            echo "  nftban geo unblock RU"
            echo "  nftban geo list"
            echo "  nftban geo check 1.2.3.4"
            echo "  nftban geo update ALL"
            echo ""
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_geo
