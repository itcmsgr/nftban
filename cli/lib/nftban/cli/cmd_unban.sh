#!/usr/bin/env bash
# =============================================================================
# NFTBan - Unban Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Unban IP addresses using nftban-core
#
# meta:name="cmd_unban"
# meta:type="cli"
# meta:header="Unban Command"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Unban IP addresses using nftban-core"
# meta:inventory.files=""
# meta:inventory.binaries="nftban-core"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
#
# meta:created_date="2025-11-24"
# meta:updated_date="2025-11-26"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${CMD_UNBAN_LOADED:-}" ]] && return 0

# Load common CLI helpers (provides cmd_init, cmd_error, cmd_require_binary, etc.)
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/cmd_common.sh" || return 1

# Initialize CLI environment (loads config, sets paths, enables strict mode)
cmd_init

readonly CMD_UNBAN_LOADED=1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_unban() {
    # Unban an IP address using nftban-core
    # Usage: nftban unban <ip> [--json]

    local ip=""
    local compact_mode="false"
    local json_mode

    # Check for help first
    cmd_wants_help "$@" && { nftban_cmd_unban_usage; return 0; }

    # Detect JSON mode and load helper
    json_mode=$(cmd_is_json_mode "$@")
    cmd_load_helpers json

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                shift
                ;;
            --compact|-q)
                # v1.39.0 P3-34: Compact output
                compact_mode="true"
                shift
                ;;
            --yes|-y)
                # v1.59.0 UX-1: Accept --yes for scripting consistency with nftban ban
                shift
                ;;
            -*)
                cmd_error "Unknown option: $1" "$json_mode" nftban_cmd_unban_usage
                return 1
                ;;
            *)
                if [[ -z "$ip" ]]; then
                    ip="$1"
                    shift
                else
                    cmd_error "Multiple IP addresses not supported" "$json_mode"
                    return 1
                fi
                ;;
        esac
    done

    # Validate required arguments
    cmd_require_arg "$ip" "IP address" "$json_mode" nftban_cmd_unban_usage || return 1
    cmd_validate_ip "$ip" "$json_mode" nftban_cmd_unban_usage || return 1

    # Check if nftban-core exists (required for unban command)
    local NFTBAN_CORE
    NFTBAN_CORE=$(cmd_get_core_binary)
    cmd_require_binary "$NFTBAN_CORE" "nftban-core" "$json_mode" || return 1

    # Call nftban-core unban
    local output exit_code
    output=$("$NFTBAN_CORE" unban "$ip" 2>&1)
    exit_code=$?

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
    elif [[ "$compact_mode" == "true" ]]; then
        # v1.39.0 P3-34: Show only essential lines
        if [[ $exit_code -eq 0 ]]; then
            echo "$output" | grep -E "^✅|UNBANNED|removed|not found|not banned" || echo "Unbanned: $ip"
        else
            echo "$output" | grep -E "^Error|^failed|invalid" || echo "Failed: $ip"
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
  --compact, -q       Compact output (essential info only)
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
