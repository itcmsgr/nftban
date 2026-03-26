#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Check Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Check if IP or port is allowed/blocked in nftables
#
# meta:name="cmd_check"
# meta:type="cli"
# meta:header="Check Command"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Check if specific IP address or port is allowed or blocked"
# meta:inventory.files=""
# meta:inventory.binaries="nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# meta:created_date="2025-11-14"
# meta:updated_date="2025-11-24"
# =============================================================================

# Strict mode
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${CMD_CHECK_LOADED:-}" ]] && return 0
readonly CMD_CHECK_LOADED=1

# Source core validator
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"

# Load strict mode library
# shellcheck source=/usr/lib/nftban/lib/strict.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
else
    # Fallback to manual strict mode
    set -Eeuo pipefail
fi

# Load version library
# shellcheck source=/usr/lib/nftban/lib/version.sh
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi
source "${NFTBAN_LIB_DIR}/core/nftban_validator.sh" || return 1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_check() {
    # Check if IP or port is allowed/blocked
    # Usage: nftban check <ip|port> [--json]

    local value=""
    local json_output=false

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                json_output=true
                shift
                ;;
            -h|--help|help)
                nftban_cmd_check_help
                return 0
                ;;
            -*)
                echo "ERROR: Unknown option: $1" >&2
                nftban_cmd_check_help
                return 1
                ;;
            *)
                if [[ -z "$value" ]]; then
                    value="$1"
                else
                    echo "ERROR: Only one value can be checked at a time" >&2
                    nftban_cmd_check_help
                    return 1
                fi
                shift
                ;;
        esac
    done

    # Validate value provided
    if [[ -z "$value" ]]; then
        echo "ERROR: No IP address or port specified" >&2
        nftban_cmd_check_help
        return 1
    fi

    # Show banner (skip for JSON output)
    if [[ "$json_output" != "true" ]]; then
        if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
            if [[ $(type -t nftban_banner) == "function" ]]; then
                nftban_banner
            fi
        fi
        echo ""
    fi

    # Run check
    check_ip_or_port "$value" "$json_output"
}

nftban_cmd_check_help() {
    cat << 'EOF'
Usage: nftban check <ip|port> [OPTIONS]

Check if an IP address or port is allowed or blocked in the firewall.

ARGUMENTS:
  <ip|port>       IP address (e.g., 203.0.113.50) or port number (e.g., 3940)

OPTIONS:
  --json          Output results in JSON format
  -h, --help      Show this help message

DESCRIPTION:
  This command traces an IP address or port through the nftables ruleset
  and determines if it is allowed or blocked. It shows:

  - Current status (allowed/blocked/unknown)
  - Which table/chain/set matched
  - Processing path through the firewall
  - Available actions (block, allow, whitelist, etc.)

  The check follows the actual nftables priority order:
    1. ip/ip6 nftban whitelist (highest priority - full access)
    2. ip/ip6 nftban blacklist (permanent + temporary with timeout)
    3. Default deny policy

EXAMPLES:
  # Check if IP is allowed
  nftban check 203.0.113.50

  # Check if port is open
  nftban check 3940

  # JSON output for scripting
  nftban check 192.0.2.122 --json

OUTPUT:
  Human-readable format shows:
    - Type (IPv4 address or TCP port)
    - Status (✅ ALLOWED or ❌ BLOCKED)
    - Matched table, chain, and set
    - Full processing path
    - Available actions

  JSON format provides machine-readable data for GUI/scripts.

EXIT STATUS:
  0  Check completed successfully
  1  Error (invalid value, nft command failed, etc.)

SEE ALSO:
  nftban validate           Validate entire nftables structure
  nftban stats              Show firewall statistics
  nftban ban <ip>           Add IP to blacklist
  nftban unban <ip>         Remove IP from blacklist
  nftban whitelist <ip>     Add IP to whitelist
EOF
}

# =============================================================================
# EXPORTS
# =============================================================================

# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "check"

export -f nftban_cmd_check
# Exit marker for testing validation
command -v nftban_cmd_exit >/dev/null 2>&1 && nftban_cmd_exit "check"

export -f nftban_cmd_check_help
