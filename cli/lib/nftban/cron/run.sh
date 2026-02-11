#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Periodic Maintenance Runner
# =============================================================================
# meta:name="cron_run"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Automated periodic maintenance tasks including feed updates and GeoIP database refresh"
# meta:inventory.files=""
# meta:inventory.binaries="bash,date,systemctl"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

# Configuration
readonly GEOIP_UPDATE_DAY="0"  # Sunday (0=Sunday, 1=Monday, etc.)
readonly GEOIP_UPDATE_HOUR="2" # 2 AM
readonly GEOIP_LOCKFILE="${NFTBAN_DATA_DIR}/.geoip_updated_this_week"

# =============================================================================
# Weekly GeoIP Update (Sundays at 2 AM)
# =============================================================================

_should_update_geoip() {
    # SC2155: Declare and assign separately
    local current_day
    current_day=$(date +%u)  # 1=Monday, 7=Sunday
    local current_hour
    current_hour=$(date +%H)

    # Convert Sunday from 7 to 0 for easier comparison
    [[ "$current_day" == "7" ]] && current_day="0"

    # Check if it's the right day and hour
    if [[ "$current_day" == "$GEOIP_UPDATE_DAY" ]] && [[ "$current_hour" == "$GEOIP_UPDATE_HOUR" ]]; then
        # Check if already updated this week
        if [[ -f "$GEOIP_LOCKFILE" ]]; then
            local lockfile_age=$(( ($(date +%s) - $(stat -c %Y "$GEOIP_LOCKFILE")) / 86400 ))
            if [[ $lockfile_age -lt 6 ]]; then
                return 1  # Already updated this week
            fi
        fi
        return 0  # Time to update
    fi
    return 1  # Not the right time
}

_update_geoip() {
    # Check if GeoIP is enabled
    if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/geoip.conf" ]]; then
        source "${NFTBAN_CONFIG_DIR}/conf.d/geoip.conf"
        if [[ "${GEOIP_AUTO_UPDATE:-false}" == "true" ]] && [[ -n "${MAXMIND_LICENSE_KEY:-}" ]]; then
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] Weekly GeoIP update started"
            if "${NFTBAN_LIB_DIR}/core/nftban_geoip_download.sh" download >/dev/null 2>&1; then
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] GeoIP update completed"
                touch "$GEOIP_LOCKFILE"
            else
                echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] GeoIP update failed"
            fi
        fi
    fi
}

# =============================================================================
# Main Execution
# =============================================================================

# Run GeoIP update if it's time
if _should_update_geoip; then
    _update_geoip
fi

# Add other periodic tasks here:
# - Feed updates (if enabled)
# - Log rotation checks
# - Database cleanup
# - Statistics aggregation

exit 0
