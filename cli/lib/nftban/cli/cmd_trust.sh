#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.1.0 - Trust CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: CLI handler for trusted provider IP range management
#
# meta:name="cmd_trust"
# meta:type="cli"
# meta:header="Trust CLI Handler"
# meta:version="1.1.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="CLI handler for trusted provider IP whitelist management"
# meta:input="User commands (list, enable, disable, update, status)"
# meta:output="Manages trusted provider IP ranges (Cloudflare, AWS, Google, etc.)"
# meta:depends="bash,curl,nftban_trust.sh"
# meta:created_date="2026-01-15"
#
# meta:inventory.files="nftban_trust.sh,nftban_output.sh,strict.sh,version.sh"
# meta:inventory.binaries="curl"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_CONFIG_DIR"
# meta:inventory.config_files="conf.d/trust.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network="outbound:https (provider APIs)"
# meta:inventory.privileges="root"
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

IFS=$'\n\t'

# =============================================================================
# TRUST COMMAND HANDLER
# =============================================================================

nftban_cmd_trust() {
    local action="${1:-status}"
    local provider="${2:-}"

    # Check for --json flag and export for submodules
    for arg in "$@"; do
        if [[ "$arg" == "--json" || "$arg" == "-j" ]]; then
            export NFTBAN_JSON="true"
        fi
    done

    # Load core trust module
    if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_trust.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/core/nftban_trust.sh"
    else
        echo "ERROR: Trust module not found" >&2
        exit 1
    fi

    # Check root for state-changing operations
    case "$action" in
        enable|disable|update|load)
            if [[ "$EUID" -ne 0 ]]; then
                echo "ERROR: This command requires root privileges" >&2
                echo "Please run with sudo: sudo nftban trust $action $provider" >&2
                exit 1
            fi
            ;;
    esac

    case "$action" in
        list)
            nftban_trust_list
            ;;
        enable)
            if [[ -z "$provider" ]]; then
                echo "ERROR: Provider name required" >&2
                echo "Usage: nftban trust enable <PROVIDER>" >&2
                echo ""
                echo "Available providers:"
                nftban_trust_list_providers
                exit 1
            fi
            nftban_trust_enable "$provider"
            ;;
        disable)
            if [[ -z "$provider" ]]; then
                echo "ERROR: Provider name required" >&2
                echo "Usage: nftban trust disable <PROVIDER>" >&2
                exit 1
            fi
            nftban_trust_disable "$provider"
            ;;
        update)
            if [[ -n "$provider" ]]; then
                nftban_trust_update "$provider"
            else
                nftban_trust_update_all
            fi
            ;;
        load)
            nftban_trust_load
            ;;
        status)
            if [[ -n "$provider" ]]; then
                nftban_trust_status "$provider"
            else
                nftban_trust_status_all
            fi
            ;;
        help|--help|-h)
            _nftban_trust_help
            ;;
        *)
            echo "ERROR: Unknown trust action: $action" >&2
            echo ""
            _nftban_trust_help
            exit 1
            ;;
    esac
}

# =============================================================================
# HELP TEXT
# =============================================================================

_nftban_trust_help() {
    # Load output module for standard banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh"
        nftban_banner
    fi

    cat <<'HELP'

USAGE:
    nftban trust <command> [provider] [--json]

OPTIONS:
    --json, -j      Output in JSON format (machine-readable)

COMMANDS:
    list                List all available trusted providers
                        Shows enabled/disabled status for each

    enable <PROVIDER>   Enable a trusted provider
                        - Downloads provider IP ranges
                        - Adds to system whitelist
                        - Applies to nftables

    disable <PROVIDER>  Disable a trusted provider
                        - Removes from whitelist
                        - Removes from nftables

    update [PROVIDER]   Update IP ranges
                        - If PROVIDER specified, updates only that provider
                        - If omitted, updates all enabled providers

    load                Reload all enabled providers from disk
                        - Re-applies whitelist without downloading

    status [PROVIDER]   Show status
                        - If PROVIDER specified, shows detailed status
                        - If omitted, shows summary of all providers

    help                Show this help message

SUPPORTED PROVIDERS:
    CLOUDFLARE          Cloudflare CDN/Proxy IP ranges
    AWS                 Amazon Web Services IP ranges
    GOOGLE              Google Cloud Platform IP ranges
    AZURE               Microsoft Azure IP ranges
    DIGITALOCEAN        DigitalOcean IP ranges
    FASTLY              Fastly CDN IP ranges
    AKAMAI              Akamai CDN IP ranges

EXAMPLES:
    # List all providers
    nftban trust list

    # Enable Cloudflare
    sudo nftban trust enable CLOUDFLARE

    # Enable AWS
    sudo nftban trust enable AWS

    # Check status
    nftban trust status

    # Update all enabled providers
    sudo nftban trust update

    # Update only Cloudflare
    sudo nftban trust update CLOUDFLARE

    # Disable Google Cloud
    sudo nftban trust disable GOOGLE

CONFIGURATION:
    Config file: /etc/nftban/conf.d/trust.conf
    User overrides: /etc/nftban/nftban.conf.local

    Key settings:
      TRUST_CLOUDFLARE_ENABLED="true|false"
      TRUST_AWS_ENABLED="true|false"
      TRUST_AUTO_UPDATE="true|false"

WHY USE TRUSTED PROVIDERS?
    If you use CDN/cloud services:
    - Traffic comes from provider IPs, not real client IPs
    - Need to whitelist them to avoid blocking legitimate traffic
    - Providers update their IP ranges periodically
    - Auto-update keeps your whitelist current

FILES:
    Cache: /var/cache/nftban/trust/
    Whitelist: /etc/nftban/whitelist.d/30-trust-*.conf
    Logs: /var/log/nftban/trust.log

NOTES:
    - Auto-update checks for new ranges daily (configurable)
    - Provider IPs change occasionally
    - IPv4 and IPv6 support (where available)
    - Cloudflare is also accessible via: nftban cloudflare

For more information:
    https://docs.nftban.com/modules/trust

HELP
}

# =============================================================================
# EXPORT FUNCTION
# =============================================================================

export -f nftban_cmd_trust
export -f _nftban_trust_help

# =============================================================================
# END OF CLI HANDLER
# =============================================================================
