#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Protect Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_protect"
# meta:type="cli"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-01-31"
# meta:description="Mark permanent bans as protected from automatic eviction"
# meta:input="IP address to protect"
# meta:output="Protection confirmation or error message"
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
[[ -n "${CMD_PROTECT_LOADED:-}" ]] && return 0

# Load common CLI helpers
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/cmd_common.sh"

# Initialize CLI environment (loads strict mode)
cmd_init

# Fallback strict mode if cmd_init didn't set it
set -Eeuo pipefail

readonly CMD_PROTECT_LOADED=1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_protect() {
    # Mark a permanent ban as protected (never auto-evict)
    # Usage: nftban protect <ip> [--json]

    local ip=""
    local json_mode

    # Check for help first
    cmd_wants_help "$@" && { nftban_cmd_protect_usage; return 0; }

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
                cmd_error "Unknown option: $1" "$json_mode" nftban_cmd_protect_usage
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
    cmd_require_arg "$ip" "IP address" "$json_mode" nftban_cmd_protect_usage || return 1

    # Build IPC request
    local request response exit_code
    # v1.19.20 FIX: Use jq for JSON building to prevent injection
    request=$(jq -n --arg ip "$ip" '{"method":"protect_ban","params":{"ip":$ip}}')

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
            # v1.19.20 FIX: Use jq for JSON building to prevent injection
            json_output "true" "$(jq -n --arg ip "$ip" '{ip:$ip,protected:true}')"
        else
            json_output "false" '{}' "Failed to protect IP: $error"
        fi
    else
        if [[ "$success" == "true" ]]; then
            echo "IP $ip marked as protected (will never be auto-evicted)"
        else
            echo "Error: $error" >&2
            return 1
        fi
    fi

    return 0
}

# =============================================================================
# USAGE
# =============================================================================

nftban_cmd_protect_usage() {
    cat <<EOF
Usage: nftban protect <ip> [OPTIONS]

Mark a permanent ban as protected from automatic eviction.

Protected IPs will NEVER be automatically removed by the cleanup command,
even if they are older than the age threshold.

Arguments:
  <ip>                  IP address to protect (must be permanently banned)

Options:
  --json                Output in JSON format
  --help, -h            Show this help message

Examples:
  nftban protect 192.168.1.100
  nftban protect 2001:db8::1 --json

Notes:
  - Only permanent bans can be protected
  - Use 'nftban unprotect' to remove protection
  - Protected bans are tracked in /var/lib/nftban/state/permanent_bans.json

See also:
  nftban unprotect <ip>   Remove protection from a ban
  nftban cleanup          Evict old unprotected bans

EOF
}

# Export function
export -f nftban_cmd_protect
export -f nftban_cmd_protect_usage
