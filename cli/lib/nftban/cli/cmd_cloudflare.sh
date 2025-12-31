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

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh"
fi
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=/dev/null
    source "$JSON_HELPER"
fi
# NFTBan v1.0.0 - Cloudflare CLI Handler
# =============================================================================

# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI handler for cloudflare commands
#
# meta:name=cmd_cloudflare
# meta:type=cli
# meta:header=Cloudflare CLI Handler
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=CLI command handler for Cloudflare IP whitelist management
# meta:input=User commands (update, status, enable, disable)
# meta:output=Calls nftban_cloudflare core module functions
#
# **Inventory & Requirements**
# meta:depends=bash,nftban_cloudflare.sh
#
# meta:created_date=2025-11-05
# meta:updated_date=2025-11-24
# =============================================================================


IFS=$'\n\t'

# =============================================================================

# CLOUDFLARE COMMAND HANDLER
# =============================================================================


nftban_cmd_cloudflare() {
    local action="${1:-status}"
    local json_mode=false

    # Check for --json flag
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode=true && break  # shellcheck disable=SC2034  # Reserved for JSON output
    done
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

