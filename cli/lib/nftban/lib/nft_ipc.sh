#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nft_ipc" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="IPC client library for nftband daemon communication"
# meta:inventory.files="/usr/lib/nftban/lib/nft_ipc.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_DAEMON_SOCKET,NFTBAN_IPC_TIMEOUT,NFTBAN_EMERGENCY_MODE"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network="/run/nftban/nftband.sock"
# meta:inventory.privileges="nftban"

set -Eeuo pipefail

# Socket path for daemon communication
NFTBAN_DAEMON_SOCKET="${NFTBAN_DAEMON_SOCKET:-/run/nftban/nftband.sock}"

# Timeout in seconds
NFTBAN_IPC_TIMEOUT="${NFTBAN_IPC_TIMEOUT:-30}"

# Emergency mode - allows direct nft calls when daemon is unavailable
# ONLY for disaster recovery, NOT normal operation
NFTBAN_EMERGENCY_MODE="${NFTBAN_EMERGENCY_MODE:-0}"

# =============================================================================
# CORE IPC FUNCTIONS
# =============================================================================

# Check if socat is available
_nft_ipc_check_socat() {
    if ! command -v socat &>/dev/null; then
        echo "ERROR: socat is required for IPC communication" >&2
        echo "Install with: dnf install socat  OR  apt install socat" >&2
        return 1
    fi
    return 0
}

# Check if daemon is running
nft_ipc_is_daemon_running() {
    [[ -S "$NFTBAN_DAEMON_SOCKET" ]] || return 1
    local resp
    resp=$(nft_ipc_request "ping" 2>/dev/null)
    [[ "$resp" == *'"success":true'* ]]
}

# Send a raw request to the daemon
# Usage: nft_ipc_request <method> [json_params]
# Returns: JSON response
nft_ipc_request() {
    local method="$1"
    local params="${2:-{}}"

    _nft_ipc_check_socat || return 1

    if [[ ! -S "$NFTBAN_DAEMON_SOCKET" ]]; then
        echo '{"success":false,"error":"daemon socket not found"}'
        return 1
    fi

    local request
    request=$(jq -nc --arg method "$method" --argjson params "$params" \
        '{method: $method, params: $params}')

    local response
    response=$(echo "$request" | timeout "$NFTBAN_IPC_TIMEOUT" socat - "UNIX-CONNECT:$NFTBAN_DAEMON_SOCKET" 2>/dev/null)

    if [[ -z "$response" ]]; then
        echo '{"success":false,"error":"daemon not responding"}'
        return 1
    fi

    echo "$response"
}

# Parse success field from response
# Usage: if nft_ipc_success "$response"; then ...
nft_ipc_success() {
    local response="$1"
    [[ "$response" == *'"success":true'* ]]
}

# Parse error message from response
# Usage: error=$(nft_ipc_error "$response")
nft_ipc_error() {
    local response="$1"
    echo "$response" | grep -oP '"error":"[^"]*"' | sed 's/"error":"//;s/"$//' || echo "unknown error"
}

# =============================================================================
# HIGH-LEVEL API FUNCTIONS
# =============================================================================

# Ban an IP address
# Usage: nft_ipc_ban <ip> [timeout_seconds] [reason] [source]
nft_ipc_ban() {
    local ip="$1"
    local timeout="${2:-0}"
    local reason="${3:-}"
    local source="${4:-cli}"

    [[ -z "$ip" ]] && { echo "ERROR: IP required" >&2; return 1; }

    local params
    params=$(jq -nc --arg ip "$ip" --argjson timeout "$timeout" \
        --arg reason "$reason" --arg source "$source" \
        '{ip: $ip, timeout: $timeout, reason: $reason, source: $source}')

    local response
    response=$(nft_ipc_request "ban" "$params")

    if nft_ipc_success "$response"; then
        return 0
    else
        echo "ERROR: $(nft_ipc_error "$response")" >&2
        return 1
    fi
}

# Unban an IP address
# Usage: nft_ipc_unban <ip>
nft_ipc_unban() {
    local ip="$1"

    [[ -z "$ip" ]] && { echo "ERROR: IP required" >&2; return 1; }

    local response
    response=$(nft_ipc_request "unban" "$(jq -nc --arg ip "$ip" '{ip: $ip}')")

    if nft_ipc_success "$response"; then
        return 0
    else
        echo "ERROR: $(nft_ipc_error "$response")" >&2
        return 1
    fi
}

# Add element to a set
# Usage: nft_ipc_add_element <table> <set> <element> [timeout_seconds]
nft_ipc_add_element() {
    local table="$1"
    local set="$2"
    local element="$3"
    local timeout="${4:-0}"

    [[ -z "$table" || -z "$set" || -z "$element" ]] && {
        echo "ERROR: table, set, and element required" >&2
        return 1
    }

    local params
    params=$(jq -nc --arg table "$table" --arg set "$set" \
        --arg element "$element" --argjson timeout "$timeout" \
        '{table: $table, set: $set, element: $element, timeout: $timeout}')

    local response
    response=$(nft_ipc_request "add_element" "$params")

    if nft_ipc_success "$response"; then
        return 0
    else
        echo "ERROR: $(nft_ipc_error "$response")" >&2
        return 1
    fi
}

# Delete element from a set
# Usage: nft_ipc_delete_element <table> <set> <element>
nft_ipc_delete_element() {
    local table="$1"
    local set="$2"
    local element="$3"

    [[ -z "$table" || -z "$set" || -z "$element" ]] && {
        echo "ERROR: table, set, and element required" >&2
        return 1
    }

    local params
    params=$(jq -nc --arg table "$table" --arg set "$set" --arg element "$element" \
        '{table: $table, set: $set, element: $element}')

    local response
    response=$(nft_ipc_request "delete_element" "$params")

    if nft_ipc_success "$response"; then
        return 0
    else
        echo "ERROR: $(nft_ipc_error "$response")" >&2
        return 1
    fi
}

# Flush all elements from a set
# Usage: nft_ipc_flush_set <table> <set>
nft_ipc_flush_set() {
    local table="$1"
    local set="$2"

    [[ -z "$table" || -z "$set" ]] && {
        echo "ERROR: table and set required" >&2
        return 1
    }

    local params
    params=$(jq -nc --arg table "$table" --arg set "$set" \
        '{table: $table, set: $set}')

    local response
    response=$(nft_ipc_request "flush_set" "$params")

    if nft_ipc_success "$response"; then
        return 0
    else
        echo "ERROR: $(nft_ipc_error "$response")" >&2
        return 1
    fi
}

# Apply ruleset from file
# Usage: nft_ipc_apply_ruleset <file_path> [check_only=0]
nft_ipc_apply_ruleset() {
    local file_path="$1"
    local check_only="${2:-0}"

    [[ -z "$file_path" ]] && { echo "ERROR: file path required" >&2; return 1; }
    [[ ! -f "$file_path" ]] && { echo "ERROR: file not found: $file_path" >&2; return 1; }

    local check_bool="false"
    [[ "$check_only" == "1" ]] && check_bool="true"

    local params
    params=$(jq -nc --arg file "$file_path" --argjson check "$check_bool" \
        '{file: $file, check: $check}')

    local response
    response=$(nft_ipc_request "apply_ruleset" "$params")

    if nft_ipc_success "$response"; then
        return 0
    else
        echo "ERROR: $(nft_ipc_error "$response")" >&2
        return 1
    fi
}

# Check if IP is banned
# Usage: nft_ipc_check <ip>
# Returns: 0 if banned, 1 if not banned
nft_ipc_check() {
    local ip="$1"

    [[ -z "$ip" ]] && { echo "ERROR: IP required" >&2; return 1; }

    local response
    response=$(nft_ipc_request "check" "$(jq -nc --arg ip "$ip" '{ip: $ip}')")

    if nft_ipc_success "$response"; then
        if [[ "$response" == *'"banned":true'* ]]; then
            return 0
        else
            return 1
        fi
    else
        echo "ERROR: $(nft_ipc_error "$response")" >&2
        return 2
    fi
}

# Get daemon status
# Usage: status=$(nft_ipc_status)
nft_ipc_status() {
    nft_ipc_request "status"
}

# =============================================================================
# EMERGENCY MODE FALLBACK
# =============================================================================
# These functions are ONLY for disaster recovery when daemon is unavailable.
# Normal operation MUST use IPC functions above.

_nft_emergency_warning() {
    echo "WARNING: EMERGENCY MODE - Direct nft access (daemon unavailable)" >&2
    logger -t nftban "EMERGENCY MODE: Direct nft call - daemon unavailable"
}

# Emergency ban - direct nft call
# ONLY USE WHEN DAEMON IS UNAVAILABLE
nft_emergency_ban() {
    [[ "$NFTBAN_EMERGENCY_MODE" != "1" ]] && {
        echo "ERROR: Emergency mode not enabled. Set NFTBAN_EMERGENCY_MODE=1" >&2
        return 1
    }
    _nft_emergency_warning

    local ip="$1"
    local timeout="${2:-0}"

    # Determine IP version
    if [[ "$ip" == *:* ]]; then
        local table="ip6 nftban"
        local set="blacklist_ipv6"
    else
        local table="ip nftban"
        local set="blacklist_ipv4"
    fi

    local element
    if [[ "$timeout" -gt 0 ]]; then
        element="{ $ip timeout ${timeout}s }"
    else
        element="{ $ip }"
    fi

    nft add element "$table" "$set" "$element"
}

# Emergency unban - direct nft call
nft_emergency_unban() {
    [[ "$NFTBAN_EMERGENCY_MODE" != "1" ]] && {
        echo "ERROR: Emergency mode not enabled. Set NFTBAN_EMERGENCY_MODE=1" >&2
        return 1
    }
    _nft_emergency_warning

    local ip="$1"

    if [[ "$ip" == *:* ]]; then
        nft delete element ip6 nftban blacklist_ipv6 "{ $ip }" 2>/dev/null
    else
        nft delete element ip nftban blacklist_ipv4 "{ $ip }" 2>/dev/null
    fi
}

# =============================================================================
# SMART WRAPPER - Auto-fallback to emergency mode
# =============================================================================

# Smart ban - tries IPC first, falls back to emergency mode if enabled
# Usage: nft_smart_ban <ip> [timeout] [reason] [source]
nft_smart_ban() {
    if nft_ipc_is_daemon_running; then
        nft_ipc_ban "$@"
    elif [[ "$NFTBAN_EMERGENCY_MODE" == "1" ]]; then
        nft_emergency_ban "$1" "${2:-0}"
    else
        echo "ERROR: Daemon not running and emergency mode not enabled" >&2
        echo "Start daemon: systemctl start nftband" >&2
        echo "Or enable emergency mode: export NFTBAN_EMERGENCY_MODE=1" >&2
        return 1
    fi
}

# Smart unban - tries IPC first, falls back to emergency mode if enabled
nft_smart_unban() {
    if nft_ipc_is_daemon_running; then
        nft_ipc_unban "$@"
    elif [[ "$NFTBAN_EMERGENCY_MODE" == "1" ]]; then
        nft_emergency_unban "$1"
    else
        echo "ERROR: Daemon not running and emergency mode not enabled" >&2
        return 1
    fi
}

# =============================================================================
# SINGLE POINT OF TRUTH - Generic element operations
# =============================================================================
# ALL nftables add/delete element operations MUST go through these functions.
# This ensures consistent IPC-first with fallback behavior across all modules.

# Smart add element - tries IPC first, falls back to direct nft
# Usage: nft_smart_add_element <table> <set> <element> [timeout_seconds]
# Example: nft_smart_add_element "ip nftban" "blacklist_ipv4" "1.2.3.4" 3600
nft_smart_add_element() {
    local table="$1"
    local set="$2"
    local element="$3"
    local timeout="${4:-0}"

    [[ -z "$table" || -z "$set" || -z "$element" ]] && {
        echo "ERROR: table, set, and element required" >&2
        return 1
    }

    # Try IPC first (netlink-based, ~50x faster)
    if nft_ipc_is_daemon_running 2>/dev/null; then
        if nft_ipc_add_element "$table" "$set" "$element" "$timeout" 2>/dev/null; then
            return 0
        fi
    fi

    # Fallback to direct nft command
    local element_str="{ $element }"
    [[ "$timeout" -gt 0 ]] && element_str="{ $element timeout ${timeout}s }"
    nft add element $table $set "$element_str" 2>/dev/null
}

# Smart delete element - tries IPC first, falls back to direct nft
# Usage: nft_smart_delete_element <table> <set> <element>
# Example: nft_smart_delete_element "ip nftban" "blacklist_ipv4" "1.2.3.4"
nft_smart_delete_element() {
    local table="$1"
    local set="$2"
    local element="$3"

    [[ -z "$table" || -z "$set" || -z "$element" ]] && {
        echo "ERROR: table, set, and element required" >&2
        return 1
    }

    # Try IPC first (netlink-based, ~50x faster)
    if nft_ipc_is_daemon_running 2>/dev/null; then
        if nft_ipc_delete_element "$table" "$set" "$element" 2>/dev/null; then
            return 0
        fi
    fi

    # Fallback to direct nft command
    nft delete element $table $set "{ $element }" 2>/dev/null
}

# Smart apply ruleset - tries IPC first, falls back to direct nft -f
# Usage: nft_smart_apply_ruleset <file_path>
# Example: nft_smart_apply_ruleset "/tmp/rules.nft"
nft_smart_apply_ruleset() {
    local file_path="$1"

    [[ -z "$file_path" ]] && { echo "ERROR: file path required" >&2; return 1; }
    [[ ! -f "$file_path" ]] && { echo "ERROR: file not found: $file_path" >&2; return 1; }

    # Try IPC first (goes through daemon's serialized writer)
    if nft_ipc_is_daemon_running 2>/dev/null; then
        if nft_ipc_apply_ruleset "$file_path" 2>/dev/null; then
            return 0
        fi
    fi

    # Fallback to direct nft -f
    nft -f "$file_path" 2>/dev/null
}

# =============================================================================
# EXPORTS
# =============================================================================

export NFTBAN_DAEMON_SOCKET
export NFTBAN_IPC_TIMEOUT
export NFTBAN_EMERGENCY_MODE

export -f nft_ipc_is_daemon_running
export -f nft_ipc_request
export -f nft_ipc_success
export -f nft_ipc_error
export -f nft_ipc_ban
export -f nft_ipc_unban
export -f nft_ipc_add_element
export -f nft_ipc_delete_element
export -f nft_ipc_flush_set
export -f nft_ipc_apply_ruleset
export -f nft_ipc_check
export -f nft_ipc_status
export -f nft_smart_ban
export -f nft_smart_unban
export -f nft_smart_add_element
export -f nft_smart_delete_element
export -f nft_smart_apply_ruleset

# =============================================================================
# STANDALONE EXECUTION (for testing)
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        ping)
            if nft_ipc_is_daemon_running; then
                echo "Daemon is running"
                exit 0
            else
                echo "Daemon is NOT running"
                exit 1
            fi
            ;;
        status)
            nft_ipc_status
            ;;
        ban)
            nft_ipc_ban "${2:-}" "${3:-0}" "${4:-}" "${5:-cli}"
            ;;
        unban)
            nft_ipc_unban "${2:-}"
            ;;
        *)
            echo "Usage: $0 {ping|status|ban <ip> [timeout] [reason] [source]|unban <ip>}"
            exit 1
            ;;
    esac
fi
