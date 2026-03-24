#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_alert_throttle" meta:type="lib" meta:version="1.39.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Unified alert throttling to prevent alert storms"
# meta:inventory.files="/var/lib/nftban/state"
# meta:inventory.binaries=""
# meta:inventory.env_vars="NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_ALERT_THROTTLE_LOADED:-}" ]] && return 0
declare -g _NFTBAN_ALERT_THROTTLE_LOADED=1

# =============================================================================
# CONFIGURATION DEFAULTS
# =============================================================================

# Default throttle period in seconds (1 hour)
: "${NFTBAN_ALERT_THROTTLE_SECONDS:=3600}"

# Default state directory
: "${NFTBAN_DATA_DIR:=/var/lib/nftban}"

# =============================================================================
# CORE FUNCTION
# =============================================================================

# nftban_should_alert - Check if an alert should be sent (throttle check)
#
# Arguments:
#   $1 - alert_key: Unique identifier for the alert type (e.g., "health_nft_stale", "watchdog_load")
#   $2 - throttle_seconds: Optional. Seconds to throttle between alerts (default: 3600)
#   $3 - state_dir: Optional. Directory for state files (default: /var/lib/nftban/state)
#
# Returns:
#   0 - Should send alert (not throttled or first occurrence)
#   1 - Alert is throttled (sent recently within throttle window)
#
# State File:
#   ${state_dir}/alert_throttle_${alert_key}.state
#   Contains single line with Unix timestamp of last alert
#
# Example:
#   if nftban_should_alert "health_nft_binary" 3600; then
#       send_alert "NFT binary missing"
#   fi
#
nftban_should_alert() {
    local alert_key="${1:?alert_key required}"
    local throttle_seconds="${2:-${NFTBAN_ALERT_THROTTLE_SECONDS:-3600}}"
    local state_dir="${3:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/state}"

    # Sanitize alert_key for filesystem safety (replace non-alphanumeric with _)
    local safe_key
    safe_key="${alert_key//[^a-zA-Z0-9_-]/_}"

    local state_file="${state_dir}/alert_throttle_${safe_key}.state"

    # Ensure state directory exists
    if [[ ! -d "$state_dir" ]]; then
        mkdir -p "$state_dir" 2>/dev/null || return 0  # Allow alert on mkdir failure
    fi

    local current_time
    current_time=$(date +%s)

    # Check if we have a previous alert timestamp
    if [[ -f "$state_file" ]]; then
        local last_alert_time
        last_alert_time=$(cat "$state_file" 2>/dev/null || echo 0)

        # Validate timestamp is numeric
        if [[ "$last_alert_time" =~ ^[0-9]+$ ]]; then
            local time_since_last_alert
            time_since_last_alert=$((current_time - last_alert_time))

            if [[ $time_since_last_alert -lt $throttle_seconds ]]; then
                return 1  # Throttled
            fi
        fi
    fi

    # Update throttle timestamp
    echo "$current_time" > "$state_file" 2>/dev/null || true

    return 0  # Should alert
}

# nftban_clear_alert_throttle - Clear throttle state for an alert
#
# Arguments:
#   $1 - alert_key: Unique identifier for the alert type
#   $2 - state_dir: Optional. Directory for state files (default: /var/lib/nftban/state)
#
# Returns:
#   0 - Always succeeds
#
nftban_clear_alert_throttle() {
    local alert_key="${1:?alert_key required}"
    local state_dir="${2:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/state}"

    local safe_key
    safe_key="${alert_key//[^a-zA-Z0-9_-]/_}"

    local state_file="${state_dir}/alert_throttle_${safe_key}.state"

    rm -f "$state_file" 2>/dev/null || true
    return 0
}

# nftban_get_alert_last_time - Get the last alert timestamp
#
# Arguments:
#   $1 - alert_key: Unique identifier for the alert type
#   $2 - state_dir: Optional. Directory for state files (default: /var/lib/nftban/state)
#
# Outputs:
#   Unix timestamp of last alert, or 0 if never alerted
#
nftban_get_alert_last_time() {
    local alert_key="${1:?alert_key required}"
    local state_dir="${2:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/state}"

    local safe_key
    safe_key="${alert_key//[^a-zA-Z0-9_-]/_}"

    local state_file="${state_dir}/alert_throttle_${safe_key}.state"

    if [[ -f "$state_file" ]]; then
        local timestamp
        timestamp=$(cat "$state_file" 2>/dev/null || echo 0)
        if [[ "$timestamp" =~ ^[0-9]+$ ]]; then
            echo "$timestamp"
            return 0
        fi
    fi

    echo "0"
    return 0
}
