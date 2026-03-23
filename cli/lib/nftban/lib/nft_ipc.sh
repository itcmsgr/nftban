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

# Double-load prevention
[[ -n "${_NFTBAN_NFT_IPC_LOADED:-}" ]] && return 0 2>/dev/null || true
readonly _NFTBAN_NFT_IPC_LOADED=1

# Socket path for daemon communication
NFTBAN_DAEMON_SOCKET="${NFTBAN_DAEMON_SOCKET:-/run/nftban/nftband.sock}"

# Timeout in seconds
NFTBAN_IPC_TIMEOUT="${NFTBAN_IPC_TIMEOUT:-30}"

# Emergency mode - allows direct nft calls when daemon is unavailable
# ONLY for disaster recovery, NOT normal operation
NFTBAN_EMERGENCY_MODE="${NFTBAN_EMERGENCY_MODE:-0}"

# =============================================================================
# SECURITY: IP VALIDATION (Defense-in-Depth)
# =============================================================================
# v1.19.27: Local validation function to prevent command injection
# Even if caller validated, we validate again before constructing nft commands

# Validate IPv4 address (strict: only digits and dots, 4 octets 0-255)
_nft_ipc_validate_ipv4() {
    local ip="$1"
    # Must match exactly: 4 groups of 1-3 digits separated by dots
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    # Check each octet is 0-255
    local IFS='.'
    # shellcheck disable=SC2206
    local -a octets=($ip)
    for octet in "${octets[@]}"; do
        ((10#$octet >= 0 && 10#$octet <= 255)) || return 1
    done
    return 0
}

# Validate IPv6 address (allows standard formats including ::)
_nft_ipc_validate_ipv6() {
    local ip="$1"
    # Only allow hex digits and colons (prevents injection chars like $`;\)
    [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]] || return 1
    # Must have at least one colon
    [[ "$ip" == *:* ]] || return 1
    # Cannot have more than 7 colons (8 groups max)
    local colon_count="${ip//[^:]}"
    [[ ${#colon_count} -le 7 ]] || return 1
    return 0
}

# Validate CIDR notation
_nft_ipc_validate_cidr() {
    local cidr="$1"
    [[ "$cidr" =~ ^(.+)/([0-9]+)$ ]] || return 1
    local ip="${BASH_REMATCH[1]}"
    local prefix="${BASH_REMATCH[2]}"
    # Validate IP part
    if [[ "$ip" == *:* ]]; then
        _nft_ipc_validate_ipv6 "$ip" || return 1
        ((prefix >= 0 && prefix <= 128)) || return 1
    else
        _nft_ipc_validate_ipv4 "$ip" || return 1
        ((prefix >= 0 && prefix <= 32)) || return 1
    fi
    return 0
}

# Main validation entry point - validates IP or CIDR
_nft_ipc_validate_ip() {
    local ip="$1"
    [[ -z "$ip" ]] && return 1
    # Try IP first, then CIDR
    _nft_ipc_validate_ipv4 "$ip" && return 0
    _nft_ipc_validate_ipv6 "$ip" && return 0
    _nft_ipc_validate_cidr "$ip" && return 0
    return 1
}

# =============================================================================
# CORE IPC FUNCTIONS
# =============================================================================

# Check if socat is available
# v1.38.0: Lightweight JSON error response (no jq dependency)
_nft_ipc_json_error() {
    local msg="$1"
    # Escape quotes in message for valid JSON
    msg="${msg//\"/\\\"}"
    echo "{\"success\":false,\"error\":\"${msg}\"}"
}

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
    local params="${2-}"
    [[ -z "$params" ]] && params="{}"

    _nft_ipc_check_socat || return 1

    if [[ ! -S "$NFTBAN_DAEMON_SOCKET" ]]; then
        _nft_ipc_json_error "daemon socket not found"
        return 1
    fi

    # Validate params is valid JSON before using with --argjson
    # If params is empty or invalid, default to empty object
    if [[ -z "$params" ]] || ! echo "$params" | jq -e . >/dev/null 2>&1; then
        params="{}"
    fi

    local request
    request=$(jq -nc --arg method "$method" --argjson params "$params" \
        '{method: $method, params: $params}' 2>/dev/null)

    # Validate request was built successfully
    if [[ -z "$request" ]]; then
        _nft_ipc_json_error "failed to build request JSON"
        return 1
    fi

    local response
    response=$(echo "$request" | timeout "$NFTBAN_IPC_TIMEOUT" socat - "UNIX-CONNECT:$NFTBAN_DAEMON_SOCKET" 2>/dev/null)

    if [[ -z "$response" ]]; then
        _nft_ipc_json_error "daemon not responding"
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

    # Ensure timeout is a valid number for --argjson
    if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
        timeout=0
    fi

    # v1.19.20 FIX: Remove insecure manual JSON escaping fallback - jq is required
    local params
    params=$(jq -nc --arg ip "$ip" --argjson timeout "$timeout" \
        --arg reason "$reason" --arg source "$source" \
        '{ip: $ip, timeout: $timeout, reason: $reason, source: $source}' 2>/dev/null) || {
        echo "ERROR: jq failed to build JSON params" >&2
        return 1
    }

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

    # Ensure timeout is a valid number for --argjson
    if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
        timeout=0
    fi

    # v1.19.20 FIX: Remove insecure manual JSON escaping fallback - jq is required
    local params
    params=$(jq -nc --arg table "$table" --arg set "$set" \
        --arg element "$element" --argjson timeout "$timeout" \
        '{table: $table, set: $set, element: $element, timeout: $timeout}' 2>/dev/null) || {
        echo "ERROR: jq failed to build JSON params" >&2
        return 1
    }

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

    # Ensure check_bool is always a valid JSON boolean literal
    local check_bool="false"
    [[ "$check_only" == "1" ]] && check_bool="true"

    # v1.19.20 FIX: Remove insecure manual JSON escaping fallback - jq is required
    local params
    params=$(jq -nc --arg file "$file_path" --argjson check "$check_bool" \
        '{file: $file, check: $check}' 2>/dev/null) || {
        echo "ERROR: jq failed to build JSON params" >&2
        return 1
    }

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
# CONFIG RELOAD (v1.13.12)
# =============================================================================

# Request config reload from daemon
# Returns: JSON with {success, data: {reloaded, config_hash, reloaded_at}}
# Usage: response=$(nft_ipc_reload)
nft_ipc_reload() {
    nft_ipc_request "reload" "{}"
}

# Get config hash from daemon status
# Returns: config hash string or empty if not available
# Usage: hash=$(nft_ipc_config_hash)
nft_ipc_config_hash() {
    local response
    response=$(nft_ipc_status 2>/dev/null) || return 1
    echo "$response" | jq -r '.data.config_hash // empty' 2>/dev/null
}

# Check if daemon supports config reload (has config_hash in status)
# Returns: 0 if supports, 1 if not
# Usage: if nft_ipc_supports_reload; then ...
nft_ipc_supports_reload() {
    local hash
    hash=$(nft_ipc_config_hash 2>/dev/null)
    [[ -n "$hash" ]]
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

    local ip="$1"
    local timeout="${2:-0}"

    # v1.19.27 SECURITY: Validate IP before constructing nft command (defense-in-depth)
    # Prevents command injection even if caller failed to validate
    if ! _nft_ipc_validate_ip "$ip"; then
        echo "ERROR: Invalid IP address format: $ip" >&2
        return 1
    fi

    _nft_emergency_warning

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

    # C7 fix: $table contains space (e.g. "ip nftban"), must not be quoted as single arg
    # shellcheck disable=SC2086
    nft add element $table "$set" "$element"
}

# Emergency unban - direct nft call
# v1.18.0: Tries all ban sets (blacklist, auto, manual) to find the IP
nft_emergency_unban() {
    [[ "$NFTBAN_EMERGENCY_MODE" != "1" ]] && {
        echo "ERROR: Emergency mode not enabled. Set NFTBAN_EMERGENCY_MODE=1" >&2
        return 1
    }

    local ip="$1"

    # v1.19.27 SECURITY: Validate IP before constructing nft command (defense-in-depth)
    if ! _nft_ipc_validate_ip "$ip"; then
        echo "ERROR: Invalid IP address format: $ip" >&2
        return 1
    fi

    _nft_emergency_warning

    local removed=0

    # v2.1: All bans are in unified blacklist set (no separate auto/manual sets)
    if [[ "$ip" == *:* ]]; then
        # IPv6 - unified blacklist
        nft delete element ip6 nftban blacklist_ipv6 "{ $ip }" 2>/dev/null && ((removed++)) || true
    else
        # IPv4 - unified blacklist
        nft delete element ip nftban blacklist_ipv4 "{ $ip }" 2>/dev/null && ((removed++)) || true
    fi

    [[ $removed -gt 0 ]] && return 0 || return 1
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
# v1.1 ASYNC IPC FUNCTIONS (Source-Aware)
# =============================================================================

# Replace entire set with elements from file (async, for feeds/geoban)
# Usage: nft_ipc_replace_set <set_name> <elements_file> [source]
# Note: Daemon reads file directly (file-based protocol for large payloads)
nft_ipc_replace_set() {
    local set_name="$1"
    local elements_file="$2"
    local source="${3:-unknown}"

    # Validate file exists
    if [[ ! -f "$elements_file" ]]; then
        _nft_ipc_json_error "file not found"
        return 1
    fi

    # Send file path (daemon reads directly)
    local params
    params=$(jq -nc \
        --arg set "$set_name" \
        --arg file "$elements_file" \
        --arg source "$source" \
        '{set: $set, file: $file, source: $source, delete_file: true}')

    nft_ipc_request "replace_set" "$params"
}

# Flush all elements from a source (async)
# Usage: nft_ipc_flush_source <source>
nft_ipc_flush_source() {
    local source="$1"

    [[ -z "$source" ]] && { echo "ERROR: source required" >&2; return 1; }

    local params
    params=$(jq -nc --arg source "$source" '{source: $source}')

    nft_ipc_request "flush_source" "$params"
}

# Unban from specific source's sets
# Usage: nft_ipc_unban_source <ip> <source>
nft_ipc_unban_source() {
    local ip="$1"
    local source="$2"

    [[ -z "$ip" ]] && { echo "ERROR: IP required" >&2; return 1; }
    [[ -z "$source" ]] && { echo "ERROR: source required" >&2; return 1; }

    local params
    params=$(jq -nc --arg ip "$ip" --arg source "$source" '{ip: $ip, source: $source}')

    nft_ipc_request "unban" "$params"
}

# Unban from ALL sets where IP exists (async)
# Usage: nft_ipc_unban_any <ip>
nft_ipc_unban_any() {
    local ip="$1"

    [[ -z "$ip" ]] && { echo "ERROR: IP required" >&2; return 1; }

    local params
    params=$(jq -nc --arg ip "$ip" '{ip: $ip, any: true}')

    nft_ipc_request "unban" "$params"
}

# Get queue status (sync)
# Usage: nft_ipc_queue_status
nft_ipc_queue_status() {
    nft_ipc_request "status" "{}"
}

# Load ports from ports.d into nftables sets
# Usage: nft_ipc_load_ports
# This reloads all ports from /etc/nftban/ports.d/*.conf into directional port sets
nft_ipc_load_ports() {
    local response
    response=$(nft_ipc_request "load_ports" "{}")

    if nft_ipc_success "$response"; then
        return 0
    else
        echo "ERROR: $(nft_ipc_error "$response")" >&2
        return 1
    fi
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

# v1.1 async functions
export -f nft_ipc_replace_set
export -f nft_ipc_flush_source
export -f nft_ipc_unban_source
export -f nft_ipc_unban_any
export -f nft_ipc_queue_status

# v1.13.12 config reload
export -f nft_ipc_reload
export -f nft_ipc_config_hash
export -f nft_ipc_supports_reload

# v1.15.0 port management
export -f nft_ipc_load_ports

# Add port(s) atomically to nftables
# Usage: nft_ipc_add_port PORT PROTOCOL DIRECTION
#   PORT: port number (1-65535)
#   PROTOCOL: tcp, udp, or both
#   DIRECTION: in, out, or both
nft_ipc_add_port() {
    local port="${1:-}"
    local protocol="${2:-tcp}"
    local direction="${3:-in}"

    [[ -z "$port" ]] && return 1

    local json
    json=$(printf '{"port":%d,"protocol":"%s","direction":"%s"}' "$port" "$protocol" "$direction")

    local response
    response=$(nft_ipc_request "add_port_element" "$json")
    nft_ipc_success "$response"
}

# Delete port(s) atomically from nftables
# Usage: nft_ipc_delete_port PORT PROTOCOL DIRECTION
nft_ipc_delete_port() {
    local port="${1:-}"
    local protocol="${2:-tcp}"
    local direction="${3:-in}"

    [[ -z "$port" ]] && return 1

    local json
    json=$(printf '{"port":%d,"protocol":"%s","direction":"%s"}' "$port" "$protocol" "$direction")

    local response
    response=$(nft_ipc_request "delete_port_element" "$json")
    nft_ipc_success "$response"
}

export -f nft_ipc_add_port
export -f nft_ipc_delete_port

# =============================================================================
# v1.19.0: IPC-OR-EMERGENCY GATE (R20 + Task 23)
# =============================================================================
# Returns: 0=IPC available, 1=emergency direct, 2=error (no daemon, no gate)
# Called by cmd_whitelist.sh and cmd_flush.sh before any nft operations

nftban_ipc_check_or_emergency() {
    local emergency_gate="/run/nftban/.emergency_unlock"

    # 1. Check if daemon is running (preferred path)
    if nft_ipc_is_daemon_running; then
        return 0
    fi

    # 2. Check emergency unlock gate file
    if [[ -f "$emergency_gate" ]]; then
        echo "WARNING: Daemon not running. Using emergency direct access." >&2
        logger -t nftban "EMERGENCY GATE: Direct nft access via $emergency_gate"
        export NFTBAN_EMERGENCY_MODE=1
        return 1
    fi

    # 3. No daemon, no emergency gate — fail
    echo "ERROR: nftband daemon is not running. Start with: systemctl start nftband" >&2
    echo "       For emergency access: touch $emergency_gate" >&2
    return 2
}

# v1.19.0 emergency gate (exported after definition)
export -f nftban_ipc_check_or_emergency

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
