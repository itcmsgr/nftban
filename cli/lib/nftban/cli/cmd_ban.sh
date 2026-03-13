#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Ban Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Ban IP addresses using nftban-core
#
# meta:name="cmd_ban"
# meta:type="cli"
# meta:header="Ban Command"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Ban IP addresses permanently using nftban-core"
# meta:input="IP address, optional reason"
# meta:output="Ban confirmation or error message"
# meta:depends="bash,nftban-core"
# meta:created_date="2025-11-24"
# meta:updated_date="2026-02-07"
# meta:inventory.files=""
# meta:inventory.binaries="nftban-core"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# =============================================================================
set -Eeuo pipefail

# Prevent double-loading
[[ -n "${CMD_BAN_LOADED:-}" ]] && return 0

# Load common CLI helpers (provides cmd_init, cmd_error, cmd_require_binary, etc.)
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/cmd_common.sh" || return 1

# Load timestamp utilities (nftban_timestamp_unix, nftban_timestamp, etc.)
# shellcheck source=/dev/null
if [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" ]]; then
    source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" || return 1
fi

# Initialize CLI environment (loads config, sets paths, enables strict mode)
cmd_init

readonly CMD_BAN_LOADED=1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_ban() {
    # Ban an IP address using nftban-core
    # Usage: nftban ban <ip> [--reason "REASON"] [--timeout SECONDS] [--source SOURCE] [--json]

    local ip=""
    local reason=""
    local timeout=""
    local ban_source=""
    local json_mode

    # Check for help first
    cmd_wants_help "$@" && { nftban_cmd_ban_usage; return 0; }

    # Detect JSON mode and load helper
    json_mode=$(cmd_is_json_mode "$@")
    cmd_load_helpers json

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                shift
                ;;
            --reason)
                reason="$2"
                shift 2
                ;;
            --timeout)
                timeout="$2"
                shift 2
                ;;
            --source)
                ban_source="$2"
                shift 2
                ;;
            -*)
                cmd_error "Unknown option: $1" "$json_mode" nftban_cmd_ban_usage
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
    cmd_require_arg "$ip" "IP address" "$json_mode" nftban_cmd_ban_usage || return 1
    cmd_validate_ip "$ip" "$json_mode" nftban_cmd_ban_usage || return 1

    # v1.18.8: Check if IP is whitelisted - warn user before banning
    local whitelist_set
    if [[ "$ip" =~ : ]]; then
        whitelist_set="ip6 nftban whitelist_ipv6"
    else
        whitelist_set="ip nftban whitelist_ipv4"
    fi

    # Check whitelist conflict
    if nft get element ${whitelist_set} "{ $ip }" &>/dev/null; then
        if [[ "$json_mode" == "true" ]]; then
            json_output "false" '{}' "Cannot ban whitelisted IP: $ip. Remove from whitelist first with: nftban whitelist remove $ip"
            return 1
        else
            echo "WARNING: IP $ip is currently whitelisted!" >&2
            echo "To ban this IP, first remove it from the whitelist:" >&2
            echo "  nftban whitelist remove $ip" >&2
            echo "Then retry the ban command." >&2
            return 1
        fi
    fi

    # Check if nftban-core exists (required for ban command)
    local NFTBAN_CORE
    NFTBAN_CORE=$(cmd_get_core_binary)
    cmd_require_binary "$NFTBAN_CORE" "nftban-core" "$json_mode" || return 1

    # Build command arguments
    local cmd_args=("$ip")
    [[ -n "$reason" ]] && cmd_args+=(--reason "$reason")
    [[ -n "$timeout" ]] && cmd_args+=(--timeout "$timeout")
    [[ -n "$ban_source" ]] && cmd_args+=(--source "$ban_source")

    # Call nftban-core ban (Go binary handles logging to bans.log)
    local output exit_code
    output=$("$NFTBAN_CORE" ban "${cmd_args[@]}" 2>&1)
    exit_code=$?

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        if [[ $exit_code -eq 0 ]]; then
            local data
            if command -v jq &>/dev/null; then
                data=$(jq -n \
                    --arg ip "$ip" \
                    --arg reason "$reason" \
                    --arg timeout "$timeout" \
                    --arg ban_source "$ban_source" \
                    '{ip: $ip, reason: $reason, timeout: (if $timeout == "" then null else ($timeout | tonumber) end), source: (if $ban_source == "" then "manual" else $ban_source end)}')
            else
                local timeout_val="null"
                [[ -n "$timeout" ]] && timeout_val="$timeout"
                local source_val="manual"
                [[ -n "$ban_source" ]] && source_val="$ban_source"
                data="{\"ip\":\"$ip\",\"reason\":\"$reason\",\"timeout\":$timeout_val,\"source\":\"$source_val\"}"
            fi
            json_output "true" "$data"
        else
            json_output "false" '{}' "Failed to ban IP: $output"
        fi
    else
        echo "$output"
    fi

    return $exit_code
}

# =============================================================================
# USAGE
# =============================================================================

nftban_cmd_ban_usage() {
    cat <<EOF
Usage: nftban ban <ip> [OPTIONS]

Ban an IP address.

Arguments:
  <ip>                  IP address to ban (IPv4 or IPv6)

Options:
  --reason "TEXT"       Ban reason (optional, stored as comment)
  --timeout SECONDS     Temporary ban duration (omit for permanent)
  --source SOURCE       Ban source (e.g., login, portscan, ddos, manual)
  --help, -h            Show this help message

Examples:
  nftban ban 192.168.1.100
  nftban ban 192.168.1.100 --reason "Brute force attack"
  nftban ban 192.168.1.100 --timeout 3600 --reason "SSH brute-force"
  nftban ban 192.168.1.100 --timeout 86400 --source login --reason "Failed logins"
  nftban ban 2001:db8::1

Notes:
  - Whitelisted IPs cannot be banned
  - Without --timeout, ban is permanent until manually removed
  - With --timeout, ban auto-expires after specified seconds
  - IP is added to ${NFTBAN_CONFIG_DIR}/blacklist.d/99-manual.conf
  - Changes are synced to nftables immediately

See also:
  nftban unban <ip>     Remove IP ban
  nftban search <ip>    Check IP status
  nftban list           List all banned IPs

EOF
}

# Export function
export -f nftban_cmd_ban
export -f nftban_cmd_ban_usage
