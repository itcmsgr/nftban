#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="validation" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Validates and sanitizes all user inputs to prevent injection attacks"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# Guard: Prevent double-loading
[[ -n "${NFTBAN_VALIDATION_LOADED:-}" ]] && return 0

# =============================================================================
# IP ADDRESS VALIDATION
# =============================================================================

nftban_validate_ipv4() {
    # Validate IPv4 address
    # Args: $1 = IP address
    # Returns: 0 if valid, 1 if invalid

    local ip="$1"

    # Check format: 4 octets separated by dots
    if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 1
    fi

    # Check each octet is 0-255
    local IFS='.'
    # shellcheck disable=SC2206  # Word splitting intentional with IFS='.'
    local -a octets=($ip)
    for octet in "${octets[@]}"; do
        # Remove leading zeros for arithmetic comparison
        octet=$((10#$octet))
        if [[ $octet -lt 0 || $octet -gt 255 ]]; then
            return 1
        fi
    done

    return 0
}

nftban_validate_ipv6() {
    # Validate IPv6 address
    # Args: $1 = IP address
    # Returns: 0 if valid, 1 if invalid

    local ip="$1"

    # Basic IPv6 format check (simplified)
    # Full: 8 groups of 4 hex digits separated by colons
    # Compressed: allows :: for consecutive zeros
    if [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]] || \
       [[ "$ip" =~ ^::([0-9a-fA-F]{0,4}:){0,6}[0-9a-fA-F]{0,4}$ ]] || \
       [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){1,6}:([0-9a-fA-F]{0,4}:){0,5}[0-9a-fA-F]{0,4}$ ]]; then
        return 0
    fi

    return 1
}

nftban_validate_ip() {
    # Validate any IP address (IPv4 or IPv6)
    # Args: $1 = IP address
    # Returns: 0 if valid, 1 if invalid

    local ip="$1"

    nftban_validate_ipv4 "$ip" || nftban_validate_ipv6 "$ip"
}

nftban_validate_cidr() {
    # Validate CIDR notation (IP/prefix)
    # Args: $1 = CIDR (e.g., "192.168.1.0/24")
    # Returns: 0 if valid, 1 if invalid

    local cidr="$1"

    # Split IP and prefix
    if [[ ! "$cidr" =~ ^(.+)/([0-9]+)$ ]]; then
        return 1
    fi

    local ip="${BASH_REMATCH[1]}"
    local prefix="${BASH_REMATCH[2]}"

    # Validate IP part
    if ! nftban_validate_ip "$ip"; then
        return 1
    fi

    # Validate prefix
    if nftban_validate_ipv4 "$ip"; then
        # IPv4: prefix must be 0-32
        [[ $prefix -ge 0 && $prefix -le 32 ]]
    else
        # IPv6: prefix must be 0-128
        [[ $prefix -ge 0 && $prefix -le 128 ]]
    fi
}

# =============================================================================
# PORT VALIDATION
# =============================================================================

nftban_validate_port() {
    # Validate port number
    # Args: $1 = port number
    # Returns: 0 if valid, 1 if invalid

    local port="$1"

    # Must be numeric
    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        return 1
    fi

    # Must be 1-65535
    [[ $port -ge 1 && $port -le 65535 ]]
}

nftban_validate_port_range() {
    # Validate port range (e.g., "80-443")
    # Args: $1 = port range
    # Returns: 0 if valid, 1 if invalid

    local range="$1"

    # Check format
    if [[ ! "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        return 1
    fi

    local start="${BASH_REMATCH[1]}"
    local end="${BASH_REMATCH[2]}"

    # Validate both ports
    nftban_validate_port "$start" || return 1
    nftban_validate_port "$end" || return 1

    # Start must be <= end
    [[ $start -le $end ]]
}

# =============================================================================
# PROTOCOL VALIDATION
# =============================================================================

nftban_validate_protocol() {
    # Validate network protocol
    # Args: $1 = protocol (tcp, udp, icmp, etc.)
    # Returns: 0 if valid, 1 if invalid

    local proto="$1"

    case "${proto,,}" in
        tcp|udp|icmp|icmpv6|esp|ah|sctp|gre|all)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# =============================================================================
# TIME DURATION VALIDATION
# =============================================================================

nftban_validate_duration() {
    # Validate time duration (e.g., "1h", "30m", "2d")
    # Args: $1 = duration string
    # Returns: 0 if valid, 1 if invalid

    local duration="$1"

    # Format: number followed by s/m/h/d/w
    if [[ "$duration" =~ ^([0-9]+)([smhdw])$ ]]; then
        local num="${BASH_REMATCH[1]}"
        local unit="${BASH_REMATCH[2]}"

        # Check reasonable limits
        case "$unit" in
            s) [[ $num -le 86400 ]] ;;     # Max 1 day in seconds
            m) [[ $num -le 1440 ]] ;;      # Max 1 day in minutes
            h) [[ $num -le 720 ]] ;;       # Max 30 days in hours
            d) [[ $num -le 365 ]] ;;       # Max 1 year in days
            w) [[ $num -le 52 ]] ;;        # Max 1 year in weeks
            *) return 1 ;;
        esac
    else
        return 1
    fi
}

# =============================================================================
# PATH VALIDATION
# =============================================================================

nftban_validate_path() {
    # Validate file path (prevent path traversal)
    # Args: $1 = path, $2 = allowed base path (optional)
    # Returns: 0 if valid, 1 if invalid

    local path="$1"
    local base="${2:-}"

    # Reject null bytes (check if string contains actual null byte)
    if [[ "${#path}" -ne "$(printf '%s' "$path" | wc -c)" ]]; then
        return 1
    fi

    # Reject path traversal attempts
    if [[ "$path" =~ \.\./|\.\.\\ ]]; then
        return 1
    fi

    # If base path provided, ensure path is within it
    if [[ -n "$base" ]]; then
        local real_path
        real_path=$(realpath -m "$path" 2>/dev/null) || return 1
        local real_base
        real_base=$(realpath -m "$base" 2>/dev/null) || return 1

        # Path must start with base
        [[ "$real_path" == "$real_base"* ]]
    fi

    return 0
}

nftban_validate_filename() {
    # Validate filename (no path components, no special chars)
    # Args: $1 = filename
    # Returns: 0 if valid, 1 if invalid

    local filename="$1"

    # Must not be empty
    [[ -n "$filename" ]] || return 1

    # Must not contain path separators or null bytes
    [[ ! "$filename" =~ [/\\$'\0'] ]] || return 1

    # Must not be . or ..
    [[ "$filename" != "." && "$filename" != ".." ]] || return 1

    # Should only contain safe characters: alphanumeric, dash, underscore, dot
    [[ "$filename" =~ ^[a-zA-Z0-9._-]+$ ]]
}

# =============================================================================
# STRING SANITIZATION
# =============================================================================

nftban_sanitize_shell() {
    # Sanitize string for safe shell usage (prevent command injection)
    # Args: $1 = input string
    # Output: Sanitized string to stdout

    local input="$1"

    # Escape shell metacharacters
    printf '%s' "$input" | sed 's/[`$"\\]/\\&/g'
}

nftban_sanitize_sql() {
    # Sanitize string for SQL (prevent SQL injection)
    # Args: $1 = input string
    # Output: Sanitized string to stdout

    local input="$1"

    # Escape single quotes (double them)
    printf '%s' "$input" | sed "s/'/''/g"
}

nftban_sanitize_html() {
    # Sanitize string for HTML output (prevent XSS)
    # Args: $1 = input string
    # Output: HTML-escaped string to stdout

    local input="$1"

    # Escape HTML special characters
    printf '%s' "$input" | \
        sed 's/&/\&amp;/g' | \
        sed 's/</\&lt;/g' | \
        sed 's/>/\&gt;/g' | \
        sed 's/"/\&quot;/g' | \
        sed "s/'/\&#39;/g"
}

nftban_sanitize_log() {
    # Sanitize string for log files (prevent log injection)
    # Args: $1 = input string
    # Output: Sanitized string to stdout

    local input="$1"

    # Remove control characters and newlines
    printf '%s' "$input" | tr -d '\000-\037\177'
}

# =============================================================================
# COUNTRY CODE VALIDATION
# =============================================================================

nftban_validate_country_code() {
    # Validate ISO 3166-1 alpha-2 country code
    # Args: $1 = country code (e.g., "US", "GB")
    # Returns: 0 if valid format, 1 if invalid

    local code="$1"

    # Must be exactly 2 uppercase letters
    [[ "$code" =~ ^[A-Z]{2}$ ]]
}

# =============================================================================
# INTEGER VALIDATION
# =============================================================================

nftban_validate_integer() {
    # Validate integer within range
    # Args: $1 = value, $2 = min (optional), $3 = max (optional)
    # Returns: 0 if valid, 1 if invalid

    local value="$1"
    local min="${2:-}"
    local max="${3:-}"

    # Must be numeric
    if [[ ! "$value" =~ ^-?[0-9]+$ ]]; then
        return 1
    fi

    # Check min
    if [[ -n "$min" ]] && [[ $value -lt $min ]]; then
        return 1
    fi

    # Check max
    if [[ -n "$max" ]] && [[ $value -gt $max ]]; then
        return 1
    fi

    return 0
}

# =============================================================================
# BOOLEAN VALIDATION
# =============================================================================

nftban_validate_boolean() {
    # Validate boolean value
    # Args: $1 = value
    # Returns: 0 if valid, 1 if invalid

    local value="${1,,}"  # lowercase

    case "$value" in
        true|false|yes|no|1|0|on|off|enabled|disabled)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# =============================================================================
# COMPOSITE VALIDATION
# =============================================================================

nftban_validate_ban_target() {
    # Validate ban target (IP, CIDR, or country code)
    # Args: $1 = target
    # Returns: 0 if valid, 1 if invalid

    local target="$1"

    # Try IP
    nftban_validate_ip "$target" && return 0

    # Try CIDR
    nftban_validate_cidr "$target" && return 0

    # Try country code
    nftban_validate_country_code "$target" && return 0

    return 1
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_validate_ipv4
export -f nftban_validate_ipv6
export -f nftban_validate_ip
export -f nftban_validate_cidr
export -f nftban_validate_port
export -f nftban_validate_port_range
export -f nftban_validate_protocol
export -f nftban_validate_duration
export -f nftban_validate_path
export -f nftban_validate_filename
export -f nftban_sanitize_shell
export -f nftban_sanitize_sql
export -f nftban_sanitize_html
export -f nftban_sanitize_log
export -f nftban_validate_country_code
export -f nftban_validate_integer
export -f nftban_validate_boolean
export -f nftban_validate_ban_target

# =============================================================================
# MARK AS LOADED
# =============================================================================

readonly NFTBAN_VALIDATION_LOADED=1
export NFTBAN_VALIDATION_LOADED

# =============================================================================
# MODULE LOADED SUCCESSFULLY
# =============================================================================

# Silent - no output on load
true
