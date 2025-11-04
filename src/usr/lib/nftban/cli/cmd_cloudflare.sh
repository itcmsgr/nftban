#!/usr/bin/env bash
# =============================================================================
# NFTBan CLI - Cloudflare Command Handler
# Part of NFTBan v0.10.0 - FHS-Compliant Architecture
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI handler for cloudflare commands
#
# meta:name=cmd_cloudflare
# meta:type=cli
# meta:header=Cloudflare CLI Handler
# meta:version=0.30.0
# meta:depends=nftban_cloudflare.sh
#
# meta:created_date=2025-10-28
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# =============================================================================
# CLOUDFLARE COMMAND HANDLER
# =============================================================================

nftban_cmd_cloudflare() {
    local action="${1:-status}"
    shift || true

    # Load core cloudflare module
    if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_cloudflare.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_cloudflare.sh"
    else
        echo "ERROR: Cloudflare module not found" >&2
        exit 1
    fi

    # Check root for state-changing operations
    case "$action" in
        enable|disable|update)
            if [[ "$EUID" -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                echo "Please run with sudo: sudo nftban cloudflare $action" >&2
                exit 1
            fi
            ;;
    esac

    case "$action" in
        enable)
            nftban_cloudflare_enable
            ;;
        disable)
            nftban_cloudflare_disable
            ;;
        update)
            nftban_cloudflare_update
            ;;
        status)
            nftban_cloudflare_status
            ;;
        download)
            # Just download, don't apply
            if [[ "$EUID" -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                exit 1
            fi
            nftban_cloudflare_init
            nftban_cloudflare_download_ips
            echo "✅ IP ranges downloaded to cache"
            echo "   Run 'nftban cloudflare update' to apply"
            ;;
        help|--help|-h)
            _nftban_cloudflare_help
            ;;
        *)
            echo "ERROR: Unknown cloudflare action: $action" >&2
            echo ""
            _nftban_cloudflare_help
            exit 1
            ;;
    esac
}

# =============================================================================
# HELP TEXT
# =============================================================================

_nftban_cloudflare_help() {
    # Load output module for standard banner
    source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"

    # Show standard banner
    nftban_banner

    cat <<'HELP'

USAGE:
    nftban cloudflare <command>

COMMANDS:
    enable          Enable Cloudflare integration
                    - Downloads Cloudflare IP ranges
                    - Adds to system whitelist
                    - Applies to nftables
                    - Enables auto-update (if configured)

    disable         Disable Cloudflare integration
                    - Removes from whitelist
                    - Removes from nftables
                    - Clears cache files

    update          Update Cloudflare IP ranges
                    - Downloads latest ranges
                    - Updates whitelist
                    - Reloads nftables

    status          Show Cloudflare integration status
                    - Configuration
                    - Cache status
                    - Recent activity

    download        Download IP ranges (without applying)
                    - Useful for testing

    help            Show this help message

EXAMPLES:
    # Enable Cloudflare integration
    sudo nftban cloudflare enable

    # Check status
    nftban cloudflare status

    # Update IP ranges
    sudo nftban cloudflare update

    # Disable integration
    sudo nftban cloudflare disable

CONFIGURATION:
    Config file: /etc/nftban/conf.d/cloudflare.conf
    User overrides: /etc/nftban/nftban.conf.local

    Key settings:
      CLOUDFLARE_ENABLED="true|false"
      CLOUDFLARE_IPV4_ENABLED="true|false"
      CLOUDFLARE_IPV6_ENABLED="true|false"
      CLOUDFLARE_AUTO_UPDATE="true|false"

      FAIL2BAN_CLOUDFLARE_IP_WHITELIST_IPV4="true|false"
      FAIL2BAN_CLOUDFLARE_IP_WHITELIST_IPV6="true|false"

WHY USE CLOUDFLARE INTEGRATION?
    If you use Cloudflare as a CDN/proxy:
    ✓ All traffic comes from Cloudflare IPs
    ✓ Need to whitelist them to see real client IPs
    ✓ Prevents blocking legitimate Cloudflare traffic
    ✓ Essential for proper logging and security

FILES:
    Cache: /var/cache/nftban/cloudflare/
    Whitelist: /etc/nftban/whitelist.d/20-cloudflare.conf
    Logs: /var/log/nftban/cloudflare.log

NOTES:
    - Auto-update checks for new ranges daily (configurable)
    - Cloudflare IPs change occasionally
    - Integration with Fail2ban (if enabled)
    - IPv6 support (if your server supports it)

For more information:
    https://docs.nftban.com/modules/cloudflare
    https://www.cloudflare.com/ips/

HELP
}

# =============================================================================
# EXPORT FUNCTION
# =============================================================================

export -f nftban_cmd_cloudflare
export -f _nftban_cloudflare_help

# =============================================================================
# END OF CLI HANDLER
# =============================================================================
