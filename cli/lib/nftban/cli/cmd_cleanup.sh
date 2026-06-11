#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Cleanup Command
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="cmd_cleanup"
# meta:type="cli"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-01-31"
# meta:description="Manage and evict old permanent bans to free memory"
# meta:input="Options for dry-run or execute mode"
# meta:output="List of evicted IPs or dry-run report"
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
[[ -n "${CMD_CLEANUP_LOADED:-}" ]] && return 0

# Load common CLI helpers
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/cmd_common.sh" || return 1

# Initialize CLI environment (loads strict mode)
cmd_init

# Fallback strict mode if cmd_init didn't set it
set -Eeuo pipefail

readonly CMD_CLEANUP_LOADED=1

# =============================================================================
# COMMAND HANDLER
# =============================================================================

nftban_cmd_cleanup() {
    # Manage and evict old permanent bans
    # Usage: nftban cleanup [--dry-run|--execute|--stats] [--count N] [--json]

    local mode="dry-run"  # Default to safe mode
    local count=100
    local json_mode

    # Check for help first
    cmd_wants_help "$@" && { nftban_cmd_cleanup_usage; return 0; }

    # Detect JSON mode and load helper
    json_mode=$(cmd_is_json_mode "$@")
    cmd_load_helpers json

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --json)
                shift
                ;;
            --dry-run)
                mode="dry-run"
                shift
                ;;
            --execute)
                mode="execute"
                shift
                ;;
            --stats)
                mode="stats"
                shift
                ;;
            --count)
                count="$2"
                shift 2
                ;;
            -*)
                cmd_error "Unknown option: $1" "$json_mode" nftban_cmd_cleanup_usage
                return 1
                ;;
            *)
                cmd_error "Unexpected argument: $1" "$json_mode" nftban_cmd_cleanup_usage
                return 1
                ;;
        esac
    done

    local socket_path="${NFTBAN_SOCKET:-/run/nftban/nftband.sock}"
    if [[ ! -S "$socket_path" ]]; then
        cmd_error "Daemon not running (socket not found: $socket_path)" "$json_mode"
        return 1
    fi

    case "$mode" in
        stats)
            _cleanup_stats "$socket_path" "$json_mode"
            ;;
        dry-run)
            _cleanup_dry_run "$socket_path" "$count" "$json_mode"
            ;;
        execute)
            _cleanup_execute "$socket_path" "$count" "$json_mode"
            ;;
    esac
}

_cleanup_stats() {
    local socket_path="$1"
    local json_mode="$2"

    local request='{"method":"permanent_ban_stats","params":{}}'
    local response

    response=$(echo "$request" | socat - UNIX-CONNECT:"$socket_path" 2>/dev/null)

    if [[ -z "$response" ]]; then
        cmd_error "Failed to communicate with daemon" "$json_mode"
        return 1
    fi

    local success total protected evictable
    if command -v jq &>/dev/null; then
        success=$(echo "$response" | jq -r '.success // false')
        total=$(echo "$response" | jq -r '.data.total // 0')
        protected=$(echo "$response" | jq -r '.data.protected // 0')
        evictable=$(echo "$response" | jq -r '.data.evictable // 0')
    else
        if [[ "$response" == *'"success":true'* ]]; then
            success="true"
            total=$(echo "$response" | grep -oP '"total":\K\d+' || echo "0")
            protected=$(echo "$response" | grep -oP '"protected":\K\d+' || echo "0")
            evictable=$(echo "$response" | grep -oP '"evictable":\K\d+' || echo "0")
        else
            success="false"
        fi
    fi

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        if [[ "$success" == "true" ]]; then
            json_output "true" "{\"total\":$total,\"protected\":$protected,\"evictable\":$evictable}"
        else
            json_output "false" '{}' "Failed to get stats"
        fi
    else
        if [[ "$success" == "true" ]]; then
            echo "Permanent Ban Statistics:"
            echo "  Total tracked:     $total"
            echo "  Protected:         $protected (never evict)"
            echo "  Evictable (>30d):  $evictable"
        else
            echo "ERROR: Failed to get statistics" >&2
            return 1
        fi
    fi
}

_cleanup_dry_run() {
    local socket_path="$1"
    local count="$2"
    local json_mode="$3"

    local request="{\"method\":\"get_evictable_bans\",\"params\":{\"count\":$count}}"
    local response

    response=$(echo "$request" | socat - UNIX-CONNECT:"$socket_path" 2>/dev/null)

    if [[ -z "$response" ]]; then
        cmd_error "Failed to communicate with daemon" "$json_mode"
        return 1
    fi

    local success ips_json
    if command -v jq &>/dev/null; then
        success=$(echo "$response" | jq -r '.success // false')
        ips_json=$(echo "$response" | jq -r '.data.ips // []')
    else
        if [[ "$response" == *'"success":true'* ]]; then
            success="true"
            ips_json="$response"
        else
            success="false"
        fi
    fi

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        if [[ "$success" == "true" ]]; then
            json_output "true" "{\"mode\":\"dry-run\",\"ips\":$ips_json}"
        else
            json_output "false" '{}' "Failed to get evictable bans"
        fi
    else
        if [[ "$success" == "true" ]]; then
            echo "=== DRY RUN - No changes made ==="
            echo ""
            echo "IPs eligible for eviction (>30 days old, unprotected):"
            echo ""

            if command -v jq &>/dev/null; then
                local ip_count
                # 2>/dev/null + strip/default so empty/invalid `$ips_json` can't crash
                # the `[[ "$ip_count" -eq 0 ]]` arith below.
                ip_count=$(echo "$ips_json" | jq -r 'length' 2>/dev/null || true)
                ip_count=${ip_count//[^0-9]/}; ip_count=${ip_count:-0}
                if [[ "$ip_count" -eq 0 ]]; then
                    echo "  (none)"
                else
                    echo "$ips_json" | jq -r '.[]' | while read -r ip; do
                        echo "  - $ip"
                    done
                fi
                echo ""
                echo "Total: $ip_count IPs would be evicted"
            else
                echo "  (use jq for detailed output)"
            fi
            echo ""
            echo "To actually evict these IPs, run: nftban cleanup --execute"
        else
            echo "ERROR: Failed to get evictable bans" >&2
            return 1
        fi
    fi
}

_cleanup_execute() {
    local socket_path="$1"
    local count="$2"
    local json_mode="$3"

    # Confirm with user (unless in JSON mode which is assumed to be scripted)
    if [[ "$json_mode" != "true" ]]; then
        echo "WARNING: This will permanently remove old bans from nftables."
        echo ""
        read -r -p "Are you sure you want to proceed? [y/N] " confirm
        if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
            echo "Aborted."
            return 0
        fi
        echo ""
    fi

    local request="{\"method\":\"evict_old_bans\",\"params\":{\"count\":$count}}"
    local response

    response=$(echo "$request" | socat - UNIX-CONNECT:"$socket_path" 2>/dev/null)

    if [[ -z "$response" ]]; then
        cmd_error "Failed to communicate with daemon" "$json_mode"
        return 1
    fi

    local success evicted_count
    if command -v jq &>/dev/null; then
        success=$(echo "$response" | jq -r '.success // false')
        evicted_count=$(echo "$response" | jq -r '.data.evicted_count // 0')
    else
        if [[ "$response" == *'"success":true'* ]]; then
            success="true"
            evicted_count=$(echo "$response" | grep -oP '"evicted_count":\K\d+' || echo "0")
        else
            success="false"
        fi
    fi

    if [[ "$json_mode" == "true" ]] && declare -f json_output >/dev/null 2>&1; then
        if [[ "$success" == "true" ]]; then
            json_output "true" "{\"mode\":\"execute\",\"evicted_count\":$evicted_count}"
        else
            json_output "false" '{}' "Failed to evict bans"
        fi
    else
        if [[ "$success" == "true" ]]; then
            echo "Cleanup complete!"
            echo "  Evicted: $evicted_count IPs"
            echo ""
            echo "Memory freed. Run 'nftban cleanup --stats' to see current state."
        else
            echo "ERROR: Failed to evict bans" >&2
            return 1
        fi
    fi
}

# =============================================================================
# USAGE
# =============================================================================

nftban_cmd_cleanup_usage() {
    cat <<EOF
Usage: nftban cleanup [OPTIONS]

Manage and evict old permanent bans to free memory.

This command helps prevent memory exhaustion by removing permanent bans
that are older than 30 days and not marked as protected.

Options:
  --dry-run             Show what would be evicted (default, safe mode)
  --execute             Actually evict old bans (requires confirmation)
  --stats               Show permanent ban statistics
  --count N             Maximum number of IPs to process (default: 100)
  --json                Output in JSON format
  --help, -h            Show this help message

Examples:
  nftban cleanup --stats
  nftban cleanup --dry-run
  nftban cleanup --execute
  nftban cleanup --execute --count 50

Eviction Criteria:
  - Ban must be permanent (no timeout)
  - Ban must be older than 30 days
  - Ban must NOT be marked as protected

Memory Pressure:
  The daemon automatically skips geoban/feeds loading under memory pressure.
  Use 'nftban cleanup --execute' to free memory by removing old bans.

See also:
  nftban protect <ip>     Mark a ban as protected (never evict)
  nftban unprotect <ip>   Remove protection from a ban
  nftban health           Check system health including memory

EOF
}

# Export function
export -f nftban_cmd_cleanup
export -f nftban_cmd_cleanup_usage
