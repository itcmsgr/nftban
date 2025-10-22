#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Cloudflare Command
# Version: 1.0.0
# Location: lib/cli/cmd_cloudflare.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_cloudflare_module.sh
# Description: Cloudflare IP whitelisting management
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# CLOUDFLARE COMMAND HANDLER
# =============================================================================

cmd_cloudflare() {
    local action="${1:-status}"
    shift || true

    case "$action" in
        status)
            nftban_cloudflare_status
            ;;
        enable)
            nftban_check_root || exit 1
            nftban_cloudflare_enable
            ;;
        disable)
            nftban_check_root || exit 1
            nftban_cloudflare_disable
            ;;
        update)
            nftban_check_root || exit 1
            nftban_cloudflare_update_whitelist
            ;;
        init)
            nftban_check_root || exit 1
            nftban_cloudflare_init
            ;;
        *)
            nftban_log_error "Unknown cloudflare action: $action"
            echo ""
            echo "Available actions:"
            echo "  status              Show Cloudflare whitelist status"
            echo "  enable              Enable Cloudflare IP whitelisting"
            echo "  disable             Disable Cloudflare IP whitelisting"
            echo "  update              Update Cloudflare IP list"
            echo "  init                Initialize Cloudflare whitelist"
            echo ""
            echo "Examples:"
            echo "  nftban cloudflare status"
            echo "  sudo nftban cloudflare init"
            echo "  sudo nftban cloudflare enable"
            echo "  sudo nftban cloudflare update"
            echo "  sudo nftban cloudflare disable"
            echo ""
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_cloudflare
