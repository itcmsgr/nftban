#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Feeds Command
# Version: 1.0.0
# Location: lib/cli/cmd_feeds.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_feeds_lib.sh
# Description: Threat intelligence feeds management
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# FEEDS COMMAND HANDLER
# =============================================================================

cmd_feeds() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        init)
            nftban_check_root || exit 1
            nftban_feeds_init
            ;;
        list)
            nftban_feeds_list
            ;;
        enable)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban feeds enable <provider_id>"; exit 1; }
            nftban_feeds_enable "$1"
            ;;
        disable)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban feeds disable <provider_id>"; exit 1; }
            nftban_feeds_disable "$1"
            ;;
        update)
            nftban_check_root || exit 1
            nftban_feeds_update "${1:-}"
            ;;
        status)
            nftban_feeds_status
            ;;
        set-interval)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban feeds set-interval <interval>"; exit 1; }
            nftban_feeds_set_interval "$1"
            ;;
        timer-install)
            nftban_check_root || exit 1
            nftban_feeds_timer_install
            ;;
        timer-remove)
            nftban_check_root || exit 1
            nftban_feeds_timer_remove
            ;;
        memory)
            nftban_feeds_memory_status
            ;;
        *)
            nftban_log_error "Unknown feeds action: $action"
            echo ""
            echo "Available actions:"
            echo "  init              Initialize feeds system"
            echo "  list              List feed providers"
            echo "  enable <id>       Enable provider"
            echo "  disable <id>      Disable provider"
            echo "  update [id]       Update feeds (all or specific)"
            echo "  status            Show feeds status"
            echo "  set-interval <i>  Set update interval"
            echo "  timer-install     Install systemd timer"
            echo "  timer-remove      Remove systemd timer"
            echo "  memory            Show memory usage"
            echo ""
            echo "Examples:"
            echo "  sudo nftban feeds init"
            echo "  nftban feeds list"
            echo "  sudo nftban feeds enable spamhaus"
            echo "  sudo nftban feeds update"
            echo "  sudo nftban feeds timer-install"
            echo ""
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_feeds
