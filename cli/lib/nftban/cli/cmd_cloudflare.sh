#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.1.0 - Cloudflare CLI Handler (Wrapper)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Backward-compatible wrapper for cloudflare commands
#          Now delegates to trust module (nftban trust ... CLOUDFLARE)
#
# meta:name="cmd_cloudflare"
# meta:type="cli"
# meta:header="Cloudflare CLI Handler (Wrapper)"
# meta:version="1.1.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:deprecated="true"
# meta:replacement="cmd_trust.sh"
#
# meta:description="Backward-compatible wrapper - delegates to trust module"
# meta:input="User commands (update, status, enable, disable)"
# meta:output="Calls trust module with CLOUDFLARE provider"
# meta:depends="bash,nftban_trust.sh"
# meta:created_date="2025-11-05"
# meta:updated_date="2026-01-15"
#
# meta:inventory.files="nftban_trust.sh,nftban_output.sh,strict.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="conf.d/trust.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root (for enable/disable/update)"
# =============================================================================

# Source central config for canonical paths
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh"
else
    set -Eeuo pipefail
fi

IFS=$'\n\t'

# =============================================================================
# CLOUDFLARE COMMAND HANDLER (WRAPPER)
# =============================================================================
# This is now a thin wrapper around the trust module.
# nftban cloudflare <action> -> nftban trust <action> CLOUDFLARE
# =============================================================================

nftban_cmd_cloudflare() {
    local action="${1:-status}"
    shift || true

    # Load trust module
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_trust.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/core/nftban_trust.sh"
    else
        echo "ERROR: Trust module not found" >&2
        echo "Please ensure nftban is properly installed" >&2
        exit 1
    fi

    # Check root for state-changing operations
    case "$action" in
        enable|disable|update|download)
            if [[ "$EUID" -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                echo "Please run with sudo: sudo nftban cloudflare $action" >&2
                exit 1
            fi
            ;;
    esac

    # Map cloudflare actions to trust module
    case "$action" in
        enable)
            nftban_trust_enable "CLOUDFLARE"
            ;;
        disable)
            nftban_trust_disable "CLOUDFLARE"
            ;;
        update)
            nftban_trust_update "CLOUDFLARE"
            ;;
        status)
            nftban_trust_status "CLOUDFLARE"
            ;;
        download)
            # Download only (no apply) - special case for testing
            echo "[*] Downloading Cloudflare IP ranges..."
            nftban_trust_init
            if _trust_download_provider "CLOUDFLARE"; then
                echo "[OK] IP ranges downloaded to cache"
                echo "    Run 'nftban cloudflare update' to apply"
            else
                echo "[X] Download failed"
                return 1
            fi
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
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
        nftban_banner 2>/dev/null || true
    fi

    cat <<'HELP'

USAGE:
    nftban cloudflare <command>

NOTE:
    This command is now part of the unified Trust module.
    You can also use: nftban trust <command> CLOUDFLARE

COMMANDS:
    enable          Enable Cloudflare integration
                    - Downloads Cloudflare IP ranges
                    - Adds to system whitelist
                    - Applies to nftables

    disable         Disable Cloudflare integration
                    - Removes from whitelist
                    - Removes from nftables

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
    Config file: /etc/nftban/conf.d/trust.conf
    User overrides: /etc/nftban/nftban.conf.local

    Key settings:
      TRUST_CLOUDFLARE_ENABLED="true|false"

FILES:
    Cache: /var/cache/nftban/trust/
    Whitelist: /etc/nftban/whitelist.d/30-trust-cloudflare.conf
    Logs: /var/log/nftban/trust.log

SEE ALSO:
    nftban trust list           - List all trusted providers
    nftban trust status         - Status of all providers
    nftban trust enable AWS     - Enable other providers

For more information:
    https://docs.nftban.com/modules/trust
    https://www.cloudflare.com/ips/

HELP
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_cmd_cloudflare
export -f _nftban_cloudflare_help

# =============================================================================
# END OF CLI HANDLER
# =============================================================================
