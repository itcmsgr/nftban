#!/usr/bin/env bash

# =============================================================================
# NFTBan CLI - Cloudflare Command
# Version: 1.0.1
# Location: lib/cli/cmd_cloudflare.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dependencies: nftban_cloudflare_module.sh
# Description: Cloudflare IP whitelisting management with IPv4/IPv6 control
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
        enable-ipv4)
            nftban_check_root || exit 1
            nftban_cloudflare_enable_ipv4
            ;;
        disable-ipv4)
            nftban_check_root || exit 1
            nftban_cloudflare_disable_ipv4
            ;;
        enable-ipv6)
            nftban_check_root || exit 1
            nftban_cloudflare_enable_ipv6
            ;;
        disable-ipv6)
            nftban_check_root || exit 1
            nftban_cloudflare_disable_ipv6
            ;;
        update)
            nftban_check_root || exit 1
            nftban_cloudflare_update_whitelist
            ;;
        init)
            nftban_check_root || exit 1
            nftban_cloudflare_init
            ;;
        help|--help|-h)
            cat <<'EOF'

═══════════════════════════════════════════════════════════
  Cloudflare IP Whitelisting Integration
═══════════════════════════════════════════════════════════

DESCRIPTION:
  Automatically whitelist Cloudflare IP ranges to allow proper CDN
  traffic. IPs are added to both nftables (memory/volatile) and
  persistent whitelist file for reboot survival.

USAGE:
  nftban cloudflare <action>

ACTIONS:
  status              Show current Cloudflare status and IP counts
  enable              Enable both IPv4 and IPv6 whitelisting
  disable             Disable and remove all Cloudflare IPs
  enable-ipv4         Enable IPv4 only
  disable-ipv4        Disable IPv4 only (keeps IPv6)
  enable-ipv6         Enable IPv6 only
  disable-ipv6        Disable IPv6 only (keeps IPv4)
  update              Update IP ranges from Cloudflare
  init                Initialize Cloudflare integration (alias for enable)
  help                Show this help message

HOW IT WORKS:
  1. Downloads latest IP ranges from Cloudflare
  2. Writes to: /etc/nftban/config/whitelist-cloudflare.conf (PERSISTENT)
  3. Adds to nftables whitelist set (MEMORY - immediate, not delayed!)
  4. On reboot: Whitelist file is loaded to restore IPs

IP RANGES:
  - IPv4: ~14 ranges from https://www.cloudflare.com/ips-v4
  - IPv6: ~6 ranges from https://www.cloudflare.com/ips-v6
  - Updated automatically when enabled

FILES:
  Config:      /etc/nftban/nftban.conf (CLOUDFLARE_ENABLED=true/false)
  Whitelist:   /etc/nftban/config/whitelist-cloudflare.conf (persistent)
  IPv4 Cache:  /etc/nftban/cache/cloudflare-ipv4.txt (volatile)
  IPv6 Cache:  /etc/nftban/cache/cloudflare-ipv6.txt (volatile)
  Logs:        /var/log/nftban/cloudflare.log

EXAMPLES:
  # Enable Cloudflare (both IPv4 and IPv6)
  sudo nftban cloudflare enable

  # Check status
  nftban cloudflare status

  # Enable only IPv4
  sudo nftban cloudflare enable-ipv4

  # Disable only IPv6
  sudo nftban cloudflare disable-ipv6

  # Update IP ranges
  sudo nftban cloudflare update

  # Disable everything
  sudo nftban cloudflare disable

NOTES:
  - IPs appear in nftables IMMEDIATELY (no delay)
  - Cache files removed on disable, re-downloaded on enable
  - Whitelist file persists across reboots
  - IPv4/IPv6 can be managed independently

For more info: https://developers.cloudflare.com/fundamentals/get-started/cloudflare-ip-addresses/

EOF
            ;;
        *)
            nftban_log_error "Unknown cloudflare action: $action"
            echo ""
            echo "Available actions:"
            echo "  status              Show Cloudflare whitelist status"
            echo "  enable              Enable Cloudflare IP whitelisting (IPv4 + IPv6)"
            echo "  disable             Disable Cloudflare IP whitelisting"
            echo "  enable-ipv4         Enable IPv4 only"
            echo "  disable-ipv4        Disable IPv4 only"
            echo "  enable-ipv6         Enable IPv6 only"
            echo "  disable-ipv6        Disable IPv6 only"
            echo "  update              Update Cloudflare IP ranges"
            echo "  init                Initialize Cloudflare whitelist"
            echo "  help                Show detailed help"
            echo ""
            echo "Examples:"
            echo "  nftban cloudflare help"
            echo "  nftban cloudflare status"
            echo "  sudo nftban cloudflare enable"
            echo "  sudo nftban cloudflare enable-ipv4"
            echo "  sudo nftban cloudflare update"
            echo ""
            exit 1
            ;;
    esac
}

# Export function
export -f cmd_cloudflare
