#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Whitelist Command
# Version: 1.0.0
# Location: lib/cli/cmd_whitelist.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_whitelist_module.sh
# Description: Whitelist IP management
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# WHITELIST COMMAND HANDLER
# =============================================================================

cmd_whitelist() {
    local action="${1:-list}"
    shift || true

    case "$action" in
        add)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban whitelist add <IP> [reason]"; exit 1; }
            nftban_whitelist_add_ip "$1" "${2:-Manual addition}"
            ;;
        remove|delete|del)
            nftban_check_root || exit 1
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban whitelist remove <IP>"; exit 1; }
            nftban_whitelist_remove_ip "$1"
            ;;
        list|show)
            nftban_whitelist_list
            ;;
        check)
            [[ $# -lt 1 ]] && { nftban_log_error "Usage: nftban whitelist check <IP>"; exit 1; }
            if nftban_whitelist_check_ip "$1"; then
                nftban_log_success "IP $1 is whitelisted"
            else
                nftban_log_info "IP $1 is NOT whitelisted"
            fi
            ;;
        sync)
            nftban_check_root || exit 1
            nftban_whitelist_sync_to_nftables
            ;;
        protect-me)
            nftban_check_root || exit 1
            nftban_whitelist_protect_current_user
            ;;
        protect-server|add-system)
            nftban_check_root || exit 1
            nftban_whitelist_add_server_ips
            ;;
        stats)
            nftban_whitelist_get_stats
            ;;
        verify)
            nftban_whitelist_verify
            ;;
        *)
            nftban_log_error "Unknown whitelist action: $action"
            echo ""
            echo "Available actions:"
            echo "  add <IP> [reason]   Add IP to whitelist"
            echo "  remove <IP>         Remove IP from whitelist"
            echo "  list                Show all whitelisted IPs"
            echo "  check <IP>          Check if IP is whitelisted"
            echo "  sync                Sync whitelist to nftables"
            echo "  protect-me          Add your current IP to whitelist"
            echo "  protect-server      Auto-protect all server IPs"
            echo "  stats               Show whitelist statistics"
            echo "  verify              Verify whitelist integrity"
            echo ""
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_whitelist
