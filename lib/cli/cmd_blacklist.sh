#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Blacklist Command
# Version: 1.0.0
# Location: lib/cli/cmd_blacklist.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_blacklist_module.sh
# Description: Blacklist IP management
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# BLACKLIST COMMAND HANDLER
# =============================================================================

cmd_blacklist() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        ban)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban blacklist ban <IP> [timeout] [reason]"; exit 1; }
            nftban_blacklist_ban_ip "$1" "${3:-Manual ban}" "${2:-3600}"
            ;;
        unban)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban blacklist unban <IP>"; exit 1; }
            nftban_blacklist_unban_ip "$1" || true
            ;;
        permanent|perm)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban blacklist permanent <IP> [reason]"; exit 1; }
            nftban_blacklist_add_permanent "$1" "${2:-Permanent ban}"
            ;;
        remove-permanent|rmperm)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban blacklist remove-permanent <IP>"; exit 1; }
            nftban_blacklist_remove_permanent "$1" || true
            ;;
        list)
            nftban_blacklist_list_permanent
            ;;
        stats)
            nftban_blacklist_show_recent_stats
            ;;
        top)
            nftban_blacklist_get_top_ips "${1:-10}"
            ;;
        sync)
            nftban_check_root || exit 1
            nftban_blacklist_sync_to_nftables
            ;;
        *)
            nftban_log_error "Unknown blacklist action: $action"
            echo ""
            echo "Available actions:"
            echo "  ban <IP> [timeout] [reason]  Temporarily ban IP"
            echo "  unban <IP>                    Unban IP"
            echo "  permanent <IP> [reason]       Permanently ban IP"
            echo "  remove-permanent <IP>         Remove permanent ban"
            echo "  list                          Show permanent bans"
            echo "  stats                         Show ban statistics"
            echo "  top [N]                       Show top N banned IPs"
            echo "  sync                          Sync blacklist to nftables"
            echo ""
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_blacklist
