#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_timestamp" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Centralized timestamp generation for all NFTBan components"
# meta:inventory.files=""
# meta:inventory.binaries="date"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail
#   echo "$(nftban_timestamp_file)"      # 20251204_143045
#   echo "$(nftban_timestamp_relative 300)" # 5 minutes ago
#
# meta:created_date="2026-02-07"
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# GUARD: Prevent double-loading
# =============================================================================

[[ -n "${_NFTBAN_TIMESTAMP_LOADED:-}" ]] && return 0

# =============================================================================
# TIMESTAMP FUNCTIONS
# =============================================================================

# nftban_timestamp - Returns ISO 8601 format timestamp (UTC)
# Output: 2025-12-04T14:30:45Z
# Pure function: no side effects, no global state
nftban_timestamp() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# nftban_timestamp_unix - Returns Unix epoch seconds
# Output: 1733322645
# Pure function: no side effects, no global state
nftban_timestamp_unix() {
    date '+%s'
}

# nftban_timestamp_log - Returns log-friendly format with brackets
# Output: [2025-12-04 14:30:45]
# Pure function: no side effects, no global state
nftban_timestamp_log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')]"
}

# nftban_timestamp_file - Returns filename-safe format
# Output: 20251204_143045
# Pure function: no side effects, no global state
nftban_timestamp_file() {
    date '+%Y%m%d_%H%M%S'
}

# nftban_timestamp_relative - Converts seconds to human-readable relative time
# Args: $1 = seconds (positive = past, negative = future)
# Output: "5 minutes ago", "2 hours ago", "just now", etc.
# Pure function: no side effects, no global state
nftban_timestamp_relative() {
    local seconds="${1:-0}"
    local abs_seconds
    local suffix="ago"

    # Handle negative values (future)
    if (( seconds < 0 )); then
        abs_seconds=$(( -seconds ))
        suffix="from now"
    else
        abs_seconds="$seconds"
    fi

    # Handle zero or very small values
    if (( abs_seconds < 5 )); then
        echo "just now"
        return 0
    fi

    # Calculate time units
    local minutes=$(( abs_seconds / 60 ))
    local hours=$(( abs_seconds / 3600 ))
    local days=$(( abs_seconds / 86400 ))
    local weeks=$(( abs_seconds / 604800 ))
    local months=$(( abs_seconds / 2592000 ))  # ~30 days
    local years=$(( abs_seconds / 31536000 ))  # ~365 days

    # Return the most appropriate unit
    if (( years > 0 )); then
        if (( years == 1 )); then
            echo "1 year ${suffix}"
        else
            echo "${years} years ${suffix}"
        fi
    elif (( months > 0 )); then
        if (( months == 1 )); then
            echo "1 month ${suffix}"
        else
            echo "${months} months ${suffix}"
        fi
    elif (( weeks > 0 )); then
        if (( weeks == 1 )); then
            echo "1 week ${suffix}"
        else
            echo "${weeks} weeks ${suffix}"
        fi
    elif (( days > 0 )); then
        if (( days == 1 )); then
            echo "1 day ${suffix}"
        else
            echo "${days} days ${suffix}"
        fi
    elif (( hours > 0 )); then
        if (( hours == 1 )); then
            echo "1 hour ${suffix}"
        else
            echo "${hours} hours ${suffix}"
        fi
    elif (( minutes > 0 )); then
        if (( minutes == 1 )); then
            echo "1 minute ${suffix}"
        else
            echo "${minutes} minutes ${suffix}"
        fi
    else
        echo "${abs_seconds} seconds ${suffix}"
    fi
}

# =============================================================================
# ADDITIONAL UTILITY FUNCTIONS
# =============================================================================

# nftban_timestamp_local - Returns local time ISO 8601 format with timezone
# Output: 2025-12-04T14:30:45+00:00
# Pure function: no side effects, no global state
nftban_timestamp_local() {
    date '+%Y-%m-%dT%H:%M:%S%:z'
}

# nftban_timestamp_date - Returns just the date portion
# Output: 2025-12-04
# Pure function: no side effects, no global state
nftban_timestamp_date() {
    date '+%Y-%m-%d'
}

# nftban_timestamp_time - Returns just the time portion
# Output: 14:30:45
# Pure function: no side effects, no global state
nftban_timestamp_time() {
    date '+%H:%M:%S'
}

# nftban_timestamp_age - Returns seconds since a given Unix timestamp
# Args: $1 = Unix timestamp to compare against
# Output: number of seconds elapsed
# Pure function: no side effects, no global state
nftban_timestamp_age() {
    local timestamp="${1:-0}"
    local now
    now=$(date '+%s')
    echo $(( now - timestamp ))
}

# nftban_timestamp_from_unix - Converts Unix timestamp to ISO 8601 format
# Args: $1 = Unix timestamp
# Output: 2025-12-04T14:30:45Z
# Pure function: no side effects, no global state
nftban_timestamp_from_unix() {
    local timestamp="${1:-0}"
    date -u -d "@${timestamp}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
        date -u -r "${timestamp}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || \
        echo "invalid"
}

# nftban_timestamp_to_unix - Converts ISO 8601 timestamp to Unix epoch
# Args: $1 = ISO 8601 timestamp (e.g., 2025-12-04T14:30:45Z)
# Output: Unix epoch seconds
# Pure function: no side effects, no global state
nftban_timestamp_to_unix() {
    local iso_timestamp="${1:-}"
    if [[ -z "$iso_timestamp" ]]; then
        echo "0"
        return 1
    fi
    # GNU date syntax (Linux)
    date -d "${iso_timestamp}" '+%s' 2>/dev/null || \
        # BSD date syntax (macOS) - try parsing
        date -j -f "%Y-%m-%dT%H:%M:%SZ" "${iso_timestamp}" '+%s' 2>/dev/null || \
        echo "0"
}

# nftban_timestamp_compare - Compare two Unix timestamps
# Args: $1 = first timestamp, $2 = second timestamp
# Output: -1 if first < second, 0 if equal, 1 if first > second
# Pure function: no side effects, no global state
nftban_timestamp_compare() {
    local ts1="${1:-0}"
    local ts2="${2:-0}"

    if (( ts1 < ts2 )); then
        echo "-1"
    elif (( ts1 > ts2 )); then
        echo "1"
    else
        echo "0"
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_timestamp
export -f nftban_timestamp_unix
export -f nftban_timestamp_log
export -f nftban_timestamp_file
export -f nftban_timestamp_relative
export -f nftban_timestamp_local
export -f nftban_timestamp_date
export -f nftban_timestamp_time
export -f nftban_timestamp_age
export -f nftban_timestamp_from_unix
export -f nftban_timestamp_to_unix
export -f nftban_timestamp_compare

# =============================================================================
# MARK AS LOADED
# =============================================================================

readonly _NFTBAN_TIMESTAMP_LOADED=1
export _NFTBAN_TIMESTAMP_LOADED

# =============================================================================
# MODULE LOADED SUCCESSFULLY
# =============================================================================

# Silent - no output on load
true
