#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Ban Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Ban IP addresses using nftban-core
#
# meta:name=cmd_ban
# meta:type=cli
# meta:header=Ban Command
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Ban IP addresses permanently using nftban-core
# meta:input=IP address, optional reason
# meta:output=Ban confirmation or error message
#
# **Inventory & Requirements**
# meta:depends=bash,nftban-core
#
# meta:created_date=2025-11-24
# meta:updated_date=2025-11-26
# =============================================================================

set -Eeuo pipefail

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"
readonly NFTBAN_CORE="${NFTBAN_LIB_DIR}/bin/nftban-core"

# Prevent double-loading
[[ -n "${CMD_BAN_LOADED:-}" ]] && return 0
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
    local source=""
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
                nftban_cmd_ban_usage
                return 0
                ;;
            --json)
                json_mode=true
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
                source="$2"
                shift 2
                ;;
            -*)
                if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
                    json_output "false" '{}' "Unknown option: $1"
                else
                    echo "ERROR: Unknown option: $1" >&2
                    nftban_cmd_ban_usage
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
            nftban_cmd_ban_usage
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

    # Build command arguments
    local cmd_args=("$ip")
    [[ -n "$reason" ]] && cmd_args+=(--reason "$reason")
    [[ -n "$timeout" ]] && cmd_args+=(--timeout "$timeout")
    [[ -n "$source" ]] && cmd_args+=(--source "$source")

    # Call nftban-core ban (Go binary handles logging to bans.log)
    local output
    output=$("$NFTBAN_CORE" ban "${cmd_args[@]}" 2>&1)
    local exit_code=$?

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        if [[ $exit_code -eq 0 ]]; then
            local data
            if command -v jq &>/dev/null; then
                data=$(jq -n \
                    --arg ip "$ip" \
                    --arg reason "$reason" \
                    --arg timeout "$timeout" \
                    --arg source "$source" \
                    '{ip: $ip, reason: $reason, timeout: (if $timeout == "" then null else ($timeout | tonumber) end), source: (if $source == "" then "manual" else $source end)}')
            else
                local timeout_val="null"
                [[ -n "$timeout" ]] && timeout_val="$timeout"
                local source_val="manual"
                [[ -n "$source" ]] && source_val="$source"
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
