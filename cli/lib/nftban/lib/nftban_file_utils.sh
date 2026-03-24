#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_file_utils" meta:type="lib" meta:version="1.39.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Centralized file age, freshness, and staleness checking utilities"
# meta:inventory.files="/usr/lib/nftban/lib/nftban_file_utils.sh"
# meta:inventory.binaries="stat,date"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# USAGE:
#   source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh"
#
#   # Get file age in seconds
#   age=$(nftban_file_age "/path/to/file")
#
#   # Check if file is fresh (within threshold)
#   if nftban_file_is_fresh "/path/to/file" 300; then
#       echo "File is fresh (less than 5 minutes old)"
#   fi
#
#   # Check if file is stale (older than threshold)
#   if nftban_file_is_stale "/path/to/file" 600; then
#       echo "File is stale (more than 10 minutes old)"
#   fi
#
#   # Get modification timestamp
#   mtime=$(nftban_file_mtime "/path/to/file")
#
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_FILE_UTILS_LOADED:-}" ]] && return 0
_NFTBAN_FILE_UTILS_LOADED=1

# =============================================================================
# FILE AGE FUNCTIONS
# =============================================================================

nftban_file_mtime() {
    # Get file modification time as Unix timestamp
    # Usage: nftban_file_mtime "/path/to/file"
    # Returns: Unix timestamp (seconds since epoch), or 0 if file doesn't exist
    # Exit code: 0=success, 1=file not found
    #
    # Examples:
    #   mtime=$(nftban_file_mtime "/var/log/nftban/bans.log")
    #   echo "Last modified: $(date -d @$mtime)"

    local filepath="$1"

    if [[ ! -e "$filepath" ]]; then
        echo "0"
        return 1
    fi

    # Try GNU stat first (-c format), then BSD stat (-f format)
    local mtime
    mtime=$(stat -c %Y "$filepath" 2>/dev/null || stat -f %m "$filepath" 2>/dev/null || echo 0)
    echo "$mtime"
    return 0
}

nftban_file_age() {
    # Get file age in seconds since last modification
    # Usage: nftban_file_age "/path/to/file"
    # Returns: Age in seconds, or 0 if file doesn't exist
    # Exit code: 0=success, 1=file not found
    #
    # Examples:
    #   age=$(nftban_file_age "/var/cache/nftban/stats.json")
    #   echo "File is ${age} seconds old"

    local filepath="$1"

    if [[ ! -e "$filepath" ]]; then
        echo "0"
        return 1
    fi

    local mtime current_time
    mtime=$(nftban_file_mtime "$filepath")
    current_time=$(date +%s)

    echo $(( current_time - mtime ))
    return 0
}

nftban_file_is_fresh() {
    # Check if file was modified within the specified threshold
    # Usage: nftban_file_is_fresh "/path/to/file" [max_age_seconds]
    # Arguments:
    #   $1 - File path to check
    #   $2 - Maximum age in seconds (default: 120)
    # Returns:
    #   0 - File exists and is fresh (age < max_age)
    #   1 - File is stale (age >= max_age)
    #   2 - File does not exist
    #
    # Examples:
    #   # Check if cache is fresh (less than 5 minutes old)
    #   if nftban_file_is_fresh "/var/cache/nftban/metrics.json" 300; then
    #       echo "Cache is fresh"
    #   fi

    local filepath="$1"
    local max_age="${2:-120}"

    if [[ ! -e "$filepath" ]]; then
        return 2
    fi

    local age
    age=$(nftban_file_age "$filepath")

    if [[ $age -lt $max_age ]]; then
        return 0  # Fresh
    else
        return 1  # Stale
    fi
}

nftban_file_is_stale() {
    # Check if file is older than the specified threshold (inverse of is_fresh)
    # Usage: nftban_file_is_stale "/path/to/file" [min_age_seconds]
    # Arguments:
    #   $1 - File path to check
    #   $2 - Minimum age to be considered stale in seconds (default: 120)
    # Returns:
    #   0 - File is stale (age >= min_age)
    #   1 - File is fresh (age < min_age)
    #   2 - File does not exist
    #
    # Examples:
    #   # Check if EVE log is stale (no updates in 10 minutes)
    #   if nftban_file_is_stale "/var/log/suricata/eve.json" 600; then
    #       echo "WARNING: Suricata EVE log appears stale"
    #   fi

    local filepath="$1"
    local min_age="${2:-120}"

    if [[ ! -e "$filepath" ]]; then
        return 2
    fi

    local age
    age=$(nftban_file_age "$filepath")

    if [[ $age -ge $min_age ]]; then
        return 0  # Stale
    else
        return 1  # Fresh
    fi
}

# =============================================================================
# EXTENDED FILE UTILITIES
# =============================================================================

nftban_file_age_human() {
    # Get file age in human-readable format
    # Usage: nftban_file_age_human "/path/to/file"
    # Returns: Human-readable age string (e.g., "5m 30s", "2h 15m", "3d 4h")
    # Exit code: 0=success, 1=file not found
    #
    # Examples:
    #   echo "Cache age: $(nftban_file_age_human /var/cache/nftban/stats.json)"

    local filepath="$1"

    if [[ ! -e "$filepath" ]]; then
        echo "N/A"
        return 1
    fi

    local age
    age=$(nftban_file_age "$filepath")

    local days hours minutes seconds
    days=$((age / 86400))
    hours=$(( (age % 86400) / 3600 ))
    minutes=$(( (age % 3600) / 60 ))
    seconds=$((age % 60))

    if [[ $days -gt 0 ]]; then
        echo "${days}d ${hours}h"
    elif [[ $hours -gt 0 ]]; then
        echo "${hours}h ${minutes}m"
    elif [[ $minutes -gt 0 ]]; then
        echo "${minutes}m ${seconds}s"
    else
        echo "${seconds}s"
    fi
    return 0
}

nftban_file_freshness_status() {
    # Get file freshness status with configurable thresholds
    # Usage: nftban_file_freshness_status "/path/to/file" [fresh_threshold] [warn_threshold]
    # Arguments:
    #   $1 - File path to check
    #   $2 - Fresh threshold in seconds (default: 120)
    #   $3 - Warning threshold in seconds (default: 300)
    # Returns: "fresh", "warning", "stale", or "missing"
    # Exit code: 0=fresh, 1=warning, 2=stale, 3=missing
    #
    # Examples:
    #   status=$(nftban_file_freshness_status "/var/cache/nftban/metrics.json" 120 300)
    #   case $status in
    #       fresh)   echo "OK" ;;
    #       warning) echo "Getting old" ;;
    #       stale)   echo "Needs refresh" ;;
    #       missing) echo "File not found" ;;
    #   esac

    local filepath="$1"
    local fresh_threshold="${2:-120}"
    local warn_threshold="${3:-300}"

    if [[ ! -e "$filepath" ]]; then
        echo "missing"
        return 3
    fi

    local age
    age=$(nftban_file_age "$filepath")

    if [[ $age -lt $fresh_threshold ]]; then
        echo "fresh"
        return 0
    elif [[ $age -lt $warn_threshold ]]; then
        echo "warning"
        return 1
    else
        echo "stale"
        return 2
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_file_mtime
export -f nftban_file_age
export -f nftban_file_is_fresh
export -f nftban_file_is_stale
export -f nftban_file_age_human
export -f nftban_file_freshness_status
