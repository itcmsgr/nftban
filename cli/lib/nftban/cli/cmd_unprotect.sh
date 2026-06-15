#!/usr/bin/env bash
# =============================================================================
# NFTBan - Unprotect Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_unprotect"
# meta:type="cli"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-01-31"
# meta:description="Remove protection from permanent bans to allow auto-eviction"
# meta:input="IP address to unprotect"
# meta:output="Unprotection confirmation or error message"
# meta:depends="bash,nftban-core,socat"
# meta:platform="linux"
# meta:inventory.files=""
# meta:inventory.binaries="socat,jq"
# meta:inventory.env_vars="NFTBAN_SOCKET"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"

# Prevent double-loading
[[ -n "${CMD_UNPROTECT_LOADED:-}" ]] && return 0

# Load common CLI helpers
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/cmd_common.sh" || return 1

# Initialize CLI environment (loads strict mode)
cmd_init

# Fallback strict mode if cmd_init didn't set it
set -Eeuo pipefail

readonly CMD_UNPROTECT_LOADED=1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_unprotect() {
    # Remove protection from a permanent ban (allow auto-eviction)
    # Usage: nftban unprotect <ip> [--json]

    local ip=""
    local json_mode

    # Check for help first
    cmd_wants_help "$@" && { nftban_cmd_unprotect_usage; return 0; }

    # Detect JSON mode and load helper
    json_mode=$(cmd_is_json_mode "$@")
    cmd_load_helpers json

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                shift
                ;;
            -*)
                cmd_error "Unknown option: $1" "$json_mode" nftban_cmd_unprotect_usage
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
    cmd_require_arg "$ip" "IP address" "$json_mode" nftban_cmd_unprotect_usage || return 1

    # Build IPC request
    local request response exit_code
    request=$(cat <<EOF
{"method":"unprotect_ban","params":{"ip":"$ip"}}
EOF
)

    # Send to daemon via socket
    local socket_path="${NFTBAN_SOCKET:-/run/nftban/nftband.sock}"
    if [[ ! -S "$socket_path" ]]; then
        cmd_error "Daemon not running (socket not found: $socket_path)" "$json_mode"
        return 1
    fi

    response=$(echo "$request" | socat - UNIX-CONNECT:"$socket_path" 2>/dev/null)
    exit_code=$?

    if [[ $exit_code -ne 0 ]] || [[ -z "$response" ]]; then
        cmd_error "Failed to communicate with daemon" "$json_mode"
        return 1
    fi

    # Parse response
    local success error
    if command -v jq &>/dev/null; then
        success=$(echo "$response" | jq -r '.success // false')
        error=$(echo "$response" | jq -r '.error // empty')
    else
        # Simple parsing without jq
        if [[ "$response" == *'"success":true'* ]]; then
            success="true"
        else
            success="false"
            error="${response#*\"error\":\"}"
            error="${error%%\"*}"
        fi
    fi

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        if [[ "$success" == "true" ]]; then
            json_output "true" "{\"ip\":\"$ip\",\"protected\":false}"
        else
            json_output "false" '{}' "Failed to unprotect IP: $error"
        fi
    else
        if [[ "$success" == "true" ]]; then
            echo "IP $ip protection removed (can now be auto-evicted after 30 days)"
        else
            echo "ERROR: $error" >&2
            return 1
        fi
    fi

    return 0
}

# =============================================================================
# USAGE
# =============================================================================

nftban_cmd_unprotect_usage() {
    cat <<EOF
Usage: nftban unprotect <ip> [OPTIONS]

Remove protection from a permanent ban, allowing automatic eviction.

After removing protection, the IP will be eligible for cleanup if:
- It has been banned for more than 30 days
- Memory pressure requires eviction of old bans

Arguments:
  <ip>                  IP address to unprotect

Options:
  --json                Output in JSON format
  --help, -h            Show this help message

Examples:
  nftban unprotect 192.168.1.100
  nftban unprotect 2001:db8::1 --json

Notes:
  - This does NOT unban the IP, only removes eviction protection
  - Use 'nftban unban' to actually remove the ban
  - Unprotected bans older than 30 days may be cleaned up

See also:
  nftban protect <ip>     Mark a ban as protected
  nftban unban <ip>       Remove the ban entirely
  nftban cleanup          Evict old unprotected bans

EOF
}

# Export function
export -f nftban_cmd_unprotect
export -f nftban_cmd_unprotect_usage
