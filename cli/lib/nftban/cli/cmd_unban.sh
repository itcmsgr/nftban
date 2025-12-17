#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Unban Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Unban IP addresses using nftban-core
#
# meta:name=cmd_unban
# meta:type=cli
# meta:header=Unban Command
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Unban IP addresses using nftban-core
# meta:input=IP address
# meta:output=Unban confirmation or error message
#
# **Inventory & Requirements**
# meta:depends=bash,nftban-core
#
# meta:created_date=2025-11-24
# meta:updated_date=2025-11-26
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"
readonly NFTBAN_CORE="${NFTBAN_LIB_DIR}/bin/nftban-core"

# Prevent double-loading
[[ -n "${CMD_UNBAN_LOADED:-}" ]] && return 0
readonly CMD_UNBAN_LOADED=1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_unban() {
    # Unban an IP address using nftban-core
    # Usage: nftban unban <ip> [--json]

    local ip=""
    local json_mode=false

    # Parse arguments first to detect JSON mode
    local args=("$@")
    for arg in "${args[@]}"; do
        [[ "$arg" == "--json" ]] && json_mode=true
    done

    # NOTE: No banner here - nftban-core displays its own banner
    # This avoids duplicate banners when delegating to the Go binary

    # Load JSON helper
    if [[ -f "${NFTBAN_LIB_DIR}/helpers/json_output.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR}/helpers/json_output.sh"
    fi

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            help|--help|-h)
                nftban_cmd_unban_usage
                return 0
                ;;
            --json)
                json_mode=true
                shift
                ;;
            -*)
                if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
                    json_output "false" '{}' "Unknown option: $1"
                else
                    echo "ERROR: Unknown option: $1" >&2
                    nftban_cmd_unban_usage
                fi
                return 1
                ;;
            *)
                if [[ -z "$ip" ]]; then
                    ip="$1"
                    shift
                else
                    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
                        json_output "false" '{}' "Multiple IP addresses not supported"
                    else
                        echo "ERROR: Multiple IP addresses not supported" >&2
                    fi
                    return 1
                fi
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$ip" ]]; then
        if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
            json_output "false" '{}' "IP address is required"
        else
            echo "ERROR: IP address is required" >&2
            echo "" >&2
            nftban_cmd_unban_usage
        fi
        return 1
    fi

    # Check if nftban-core exists
    if [[ ! -x "$NFTBAN_CORE" ]]; then
        if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
            json_output "false" '{}' "nftban-core not found"
        else
            echo "ERROR: nftban-core not found at $NFTBAN_CORE" >&2
        fi
        return 1
    fi

    # Call nftban-core unban
    local output
    output=$("$NFTBAN_CORE" unban "$ip" 2>&1)
    local exit_code=$?

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        if [[ $exit_code -eq 0 ]]; then
            local data
            if command -v jq &>/dev/null; then
                data=$(jq -n --arg ip "$ip" '{ip: $ip}')
            else
                data="{\"ip\":\"$ip\"}"
            fi
            json_output "true" "$data"
        else
            json_output "false" '{}' "Failed to unban IP: $output"
        fi
    else
        echo "$output"
    fi

    return $exit_code
}

# =============================================================================
# USAGE
# =============================================================================

nftban_cmd_unban_usage() {
    cat <<EOF
Usage: nftban unban <ip>

Remove an IP address ban.

Arguments:
  <ip>                IP address to unban (IPv4 or IPv6)

Options:
  --help, -h          Show this help message

Examples:
  nftban unban 192.168.1.100
  nftban unban 2001:db8::1

Notes:
  - IP is removed from ${NFTBAN_CONFIG_DIR}/blacklist.d/*.conf
  - Changes are synced to nftables immediately
  - If IP is not banned, nothing happens (not an error)

See also:
  nftban ban <ip>      Ban an IP address
  nftban search <ip>   Check IP status
  nftban list          List all banned IPs

EOF
}

# Export function
export -f nftban_cmd_unban
export -f nftban_cmd_unban_usage
