#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_unified_exporter_helpers"
# meta:type="exporter"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Helpers: cleanup, collection groups, jitter, locking, logging, detection"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_UNIFIED_EXPORTER_HELPERS_LOADED:-}" ]] && return 0
_UNIFIED_EXPORTER_HELPERS_LOADED="true"

# =============================================================================
# CLEANUP TRAP - Prevent orphaned temp files on interruption
# =============================================================================
# This ensures .tmp files are cleaned up if script is killed mid-write
cleanup_temp_files() {
    local textfile_dir="${NFTBAN_PROMETHEUS_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
    local prom_file="${textfile_dir}/${NFTBAN_PROMETHEUS_OUTPUT_FILE:-nftban.prom}"
    local json_cache="${NFTBAN_CACHE_DIR}/metrics/combined.json"
    local gui_cache_dir="${NFTBAN_JSON_CACHE_DIR:-/var/cache/nftban/metrics}"

    rm -f "${prom_file}".tmp "${prom_file}".?????? 2>/dev/null || true
    rm -f "${json_cache}.tmp" 2>/dev/null || true
    rm -f "${BANDWIDTH_STATE}.tmp" 2>/dev/null || true
    rm -f "${METRICS_CACHE}.tmp" 2>/dev/null || true

    # Clean up GUI cache temp files
    rm -f "${gui_cache_dir}/traffic_history.json.tmp" 2>/dev/null || true
    rm -f "${gui_cache_dir}/traffic_history.json.tmp.raw" 2>/dev/null || true
    rm -f "${gui_cache_dir}/dropped_by_country.json.tmp" 2>/dev/null || true
    rm -f "${gui_cache_dir}/dropped_by_country.json.tmp.raw" 2>/dev/null || true
    rm -f "${gui_cache_dir}/dropped_by_port.json.tmp" 2>/dev/null || true
    rm -f "${gui_cache_dir}/dropped_by_port.json.tmp.raw" 2>/dev/null || true

    # Also clean up any orphaned .prom.* files older than 1 hour
    find "$textfile_dir" -maxdepth 1 -name "nftban.prom.*" -mmin +60 -delete 2>/dev/null || true
}

# =============================================================================
# COLLECTION GROUPS
# =============================================================================
# Live metrics:      Every run (60s) - daemon, bans, memory, nftables, connections
# Extended metrics:  Every EXTENDED_MULT runs (5min) - module_status, feed_health, watchdog
# Inventory metrics: Every INVENTORY_MULT runs (1hr) - kernel, geoip, server_info
# =============================================================================

# Get current run count (creates file if missing)
get_run_count() {
    if [[ -f "$RUN_COUNT_FILE" ]]; then
        local count
        count=$(cat "$RUN_COUNT_FILE" 2>/dev/null || echo "0")
        echo "${count:-0}"
    else
        mkdir -p "$(dirname "$RUN_COUNT_FILE")"
        echo "0" > "$RUN_COUNT_FILE"
        echo "0"
    fi
}

# Increment run count and return new value
increment_run_count() {
    local count
    count=$(get_run_count)
    count=$((count + 1))
    echo "$count" > "$RUN_COUNT_FILE"
    echo "$count"
}

# Determine which collection groups to run based on run count
# Returns space-separated list: "live extended inventory" or "live" or "live extended"
determine_collection_groups() {
    local run_count="$1"
    local extended_mult="${NFTBAN_COLLECT_EXTENDED_MULT:-5}"
    local inventory_mult="${NFTBAN_COLLECT_INVENTORY_MULT:-60}"

    local groups="live"

    # Extended: every EXTENDED_MULT runs (default: 5 = every 5 mins)
    if [[ $((run_count % extended_mult)) -eq 0 ]]; then
        groups+=" extended"
    fi

    # Inventory: every INVENTORY_MULT runs (default: 60 = every hour)
    if [[ $((run_count % inventory_mult)) -eq 0 ]]; then
        groups+=" inventory"
    fi

    echo "$groups"
}

# =============================================================================
# SMART JITTER: Hostname-based deterministic delay
# =============================================================================
# Instead of random jitter that changes every run, use hostname hash
# This ensures:
# - Same host always has same offset (predictable)
# - Different hosts have different offsets (distributed)
# - No coordination needed between hosts
# =============================================================================
calculate_host_jitter() {
    local max_jitter="${1:-30}"  # Max jitter in seconds
    local hostname_hash

    # Create deterministic hash from hostname
    hostname_hash=$(hostname | md5sum | cut -c1-8)

    # Convert hex to decimal and modulo by max_jitter
    local decimal_hash=$((16#$hostname_hash))
    local jitter=$((decimal_hash % max_jitter))

    echo "$jitter"
}

# =============================================================================
# LOCKING: Prevent concurrent runs with timeout
# =============================================================================
acquire_lock() {
    local lock_fd=200
    local lock_timeout="${NFTBAN_COLLECT_LOCK_TIMEOUT:-10}"

    # Create lock file directory
    mkdir -p "$(dirname "$METRICS_LOCK")"

    # FIX v1.17.0: Ensure lock file is writable by current user
    # If lock file exists but we can't write to it, remove and recreate
    if [[ -f "$METRICS_LOCK" ]] && [[ ! -w "$METRICS_LOCK" ]]; then
        rm -f "$METRICS_LOCK" 2>/dev/null || {
            log_error "Cannot remove stale lock file: $METRICS_LOCK (permission denied)"
            log_error "Fix: sudo rm -f $METRICS_LOCK && sudo chown nftban:nftban $(dirname $METRICS_LOCK)"
            exit 1
        }
    fi
    touch "$METRICS_LOCK" 2>/dev/null || {
        log_error "Cannot create lock file: $METRICS_LOCK (permission denied)"
        exit 1
    }

    # Read current lock holder PID BEFORE exec truncates the file
    local prev_pid
    prev_pid="$(cat "$METRICS_LOCK" 2>/dev/null || true)"
    [[ -z "$prev_pid" ]] && prev_pid="unknown"

    # v1.19.0: Remove eval — use exec with explicit fd (R16)
    exec 200>"$METRICS_LOCK"

    # Try to acquire lock with timeout (blocking)
    # This prevents silent metrics gaps when concurrent runs overlap
    if ! timeout $lock_timeout flock 200 2>/dev/null; then
        log_error "Lock acquisition timed out after ${lock_timeout}s (concurrent exporter still running?)"
        log_error "Previous PID: $prev_pid"

        # Export stale metrics from cache if available (better than nothing)
        if [[ "${NFTBAN_COLLECT_USE_STALE_CACHE:-true}" == "true" ]] && [[ -f "$METRICS_CACHE" ]]; then
            local cache_age stale_max_age
            stale_max_age="${NFTBAN_COLLECT_STALE_MAX_AGE:-300}"
            cache_age=$(($(date +%s) - $(stat -c %Y "$METRICS_CACHE" 2>/dev/null || echo 0)))
            if [[ $cache_age -lt $stale_max_age ]]; then
                log_warn "Using cached metrics (age: ${cache_age}s) to prevent monitoring gap"
                # Exports will use existing cache
                return 0
            fi
        fi

        log_error "No recent cache available - metrics collection skipped"
        exit 1  # Exit with error code so systemd logs failure
    fi

    # Write PID to lock file
    echo $$ >&$lock_fd
}

# =============================================================================
# LOGGING
# =============================================================================
log_info()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [INFO] $*"; }
log_warn()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [WARN] $*" >&2; }
log_error() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [ERROR] $*" >&2; }
log_debug() { [[ "${NFTBAN_DEBUG:-false}" == "true" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*" || true; }

# =============================================================================
# COMPONENT AUTO-DETECTION
# =============================================================================
# Determines which components should have metrics collected based on:
# 1. NFTBAN_COLLECT_* config setting (auto/enabled/disabled)
# 2. Actual component availability (for "auto" mode)
# =============================================================================
should_collect_component() {
    local component="$1"
    local setting_var="NFTBAN_COLLECT_${component^^}"
    local setting="${!setting_var:-auto}"

    # Explicit enabled/disabled
    [[ "$setting" == "enabled" ]] && return 0
    [[ "$setting" == "disabled" ]] && return 1

    # Auto-detection mode
    case "$component" in
        suricata)
            # Suricata: binary exists AND module config exists
            [[ -x "/usr/bin/suricata" ]] && \
            [[ -f "${NFTBAN_CONFIG_DIR}/modules/suricata.conf" ]] && return 0
            ;;
        feeds)
            # Feeds: check for feed data files (primary) or config files
            local feed_count=0
            # Check data dir first (actual feed lists)
            if [[ -d "${NFTBAN_DATA_DIR}/feeds" ]]; then
                feed_count=$(find "${NFTBAN_DATA_DIR}/feeds" -name "*.txt" -o -name "*.list" 2>/dev/null | wc -l)
            fi
            # Fallback to cache dir
            if [[ $feed_count -eq 0 ]] && [[ -d "${NFTBAN_CACHE_DIR}/feeds" ]]; then
                feed_count=$(find "${NFTBAN_CACHE_DIR}/feeds" -name "*.txt" -o -name "*.list" 2>/dev/null | wc -l)
            fi
            [[ $feed_count -gt 0 ]] && return 0
            ;;
        geoip)
            # GeoIP: module enabled AND database exists (DBIP or GeoLite2)
            # BUG-006 FIX: Corrected path from modules/geoban.conf to conf.d/geoban/main.conf
            if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/geoban/main.conf" ]]; then
                [[ -f "${NFTBAN_CACHE_DIR}/geoip/dbip-country-lite.mmdb" ]] && return 0
                [[ -f "${NFTBAN_CACHE_DIR}/geoip/GeoLite2-Country.mmdb" ]] && return 0
            fi
            ;;
        watchdog)
            # Watchdog: status file exists (watchdog is running)
            [[ -f "${NFTBAN_RUN_DIR}/watchdog.status" ]] && return 0
            ;;
        portscan)
            # Portscan: module config exists
            [[ -f "${NFTBAN_CONFIG_DIR}/modules/portscan.conf" ]] && return 0
            ;;
        eventbus)
            # EventBus: daemon running (check PID file)
            [[ -f "${NFTBAN_RUN_DIR}/nftband.pid" ]] && return 0
            ;;
        kernel)
            # Kernel metrics: always available on Linux
            [[ -f "/proc/net/nf_conntrack" ]] || [[ -f "/proc/sys/net/netfilter/nf_conntrack_count" ]] && return 0
            ;;
        network)
            # Network metrics: always available
            return 0
            ;;
    esac

    # Default: don't collect if auto-detection fails
    [[ "${NFTBAN_COLLECT_LOG_DETECTION:-false}" == "true" ]] && \
        log_debug "Component '$component' not detected (setting: $setting)"
    return 1
}

# =============================================================================
# BANDWIDTH METRICS FUNCTIONS
# =============================================================================

# Get interface statistics from /proc/net/dev
# /proc/net/dev columns (after interface name):
# RX: bytes packets errs drop fifo frame compressed multicast
# TX: bytes packets errs drop fifo colls carrier compressed
get_interface_stats() {
    local interface=$1
    local stats
    stats=$(grep -E "^\s*${interface}:" /proc/net/dev 2>/dev/null || echo "")
    [[ -z "$stats" ]] && return 1
    stats=$(echo "$stats" | sed 's/^[^:]*://' | tr -s ' ')
    local rx_bytes rx_packets rx_errs rx_drop tx_bytes tx_packets tx_errs tx_drop
    rx_bytes=$(echo "$stats" | awk '{print $1}')
    rx_packets=$(echo "$stats" | awk '{print $2}')
    rx_errs=$(echo "$stats" | awk '{print $3}')
    rx_drop=$(echo "$stats" | awk '{print $4}')
    tx_bytes=$(echo "$stats" | awk '{print $9}')
    tx_packets=$(echo "$stats" | awk '{print $10}')
    tx_errs=$(echo "$stats" | awk '{print $11}')
    tx_drop=$(echo "$stats" | awk '{print $12}')
    echo "${rx_bytes} ${rx_packets} ${rx_errs} ${rx_drop} ${tx_bytes} ${tx_packets} ${tx_errs} ${tx_drop}"
}

# Calculate bandwidth in Mbps from byte deltas
calculate_mbps() {
    local bytes_delta=$1 time_delta=$2
    [[ $time_delta -eq 0 ]] && { echo "0"; return; }
    awk -v bd="$bytes_delta" -v td="$time_delta" 'BEGIN {printf "%.2f", (bd / td) * 8 / 1000000}'
}

# Get connection statistics using ss
get_connection_stats() {
    local state=$1
    command -v ss &>/dev/null || { echo "0"; return; }
    local count
    case "$state" in
        active)      count=$(ss -tan 2>/dev/null | grep -cE "ESTAB|SYN-SENT|SYN-RECV|FIN-WAIT|CLOSE-WAIT|TIME-WAIT" || true) ;;
        established) count=$(ss -tan 2>/dev/null | grep -c "ESTAB" || true) ;;
        time_wait)   count=$(ss -tan 2>/dev/null | grep -c "TIME-WAIT" || true) ;;
        close_wait)  count=$(ss -tan 2>/dev/null | grep -c "CLOSE-WAIT" || true) ;;
        *) count=0 ;;
    esac
    echo "${count:-0}"
}

# Update peak bandwidth values (5-minute window)
update_bandwidth_peaks() {
    local rx_mbps=$1 tx_mbps=$2 current_ts=$3
    [[ ! -f "$BANDWIDTH_PEAKS" ]] && echo "0 0 $current_ts" > "$BANDWIDTH_PEAKS"
    local peak_data peak_rx peak_tx peak_ts
    peak_data=$(cat "$BANDWIDTH_PEAKS" 2>/dev/null || echo "0 0 0")
    read -r peak_rx peak_tx peak_ts <<< "$peak_data"
    if [[ $(( current_ts - peak_ts )) -gt $PEAK_WINDOW ]]; then
        peak_rx=$rx_mbps; peak_tx=$tx_mbps; peak_ts=$current_ts
    else
        [[ $(echo "$rx_mbps > $peak_rx" | bc -l 2>/dev/null || echo 0) -eq 1 ]] && peak_rx=$rx_mbps
        [[ $(echo "$tx_mbps > $peak_tx" | bc -l 2>/dev/null || echo 0) -eq 1 ]] && peak_tx=$tx_mbps
    fi
    echo "$peak_rx $peak_tx $peak_ts" > "$BANDWIDTH_PEAKS"
    echo "$peak_rx $peak_tx"
}
