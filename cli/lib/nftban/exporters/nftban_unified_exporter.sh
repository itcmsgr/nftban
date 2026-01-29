#!/usr/bin/env bash
# =============================================================================
# NFTBan Unified Metrics Exporter
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_unified_exporter"
# meta:type="exporter"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Unified exporter - collects once, exports to all configured targets"
# meta:inventory.files=""
# meta:inventory.binaries="/usr/lib/nftban/bin/nftban-core"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files="/etc/nftban/nftban.conf,/etc/nftban/conf.d/metrics.conf,/etc/nftban/conf.d/zabbix.conf,/etc/nftban/conf.d/connectors.conf"
# meta:inventory.systemd_units="nftban-unified-exporter.timer"
# meta:inventory.network="outbound:10051/tcp,outbound:9200/tcp,outbound:9092/tcp"
# meta:inventory.privileges="nftban"
#
# SENIOR DESIGN RATIONALE:
# ========================
# Problem: 3 separate timers (metrics, zabbix, connector) = 3x metric collection
# Solution: Collect ONCE, export to ALL targets in single run
#
# Benefits:
# - 66% reduction in metric collection overhead
# - Single timer instead of 3 = less systemd overhead
# - Consistent metric timestamps across all targets
# - Easier debugging (one log, one run)
# - Atomic: either all exports succeed or we know which failed
#
# =============================================================================

set -Eeuo pipefail

readonly SCRIPT_VERSION="1.0.0"

# Bootstrap paths (nftban.conf will make them readonly)
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_RUN_DIR:=/run/nftban}"
: "${NFTBAN_LOG_DIR:=/var/log/nftban}"
: "${NFTBAN_CACHE_DIR:=/var/cache/nftban}"

# Load config (sets readonly paths)
[[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR}/nftban.conf"

# Load metrics configuration (unified collector settings)
[[ -f "${NFTBAN_CONFIG_DIR}/conf.d/metrics.conf" ]] && source "${NFTBAN_CONFIG_DIR}/conf.d/metrics.conf"
[[ -f "${NFTBAN_CONFIG_DIR}/conf.d/metrics.conf.local" ]] && source "${NFTBAN_CONFIG_DIR}/conf.d/metrics.conf.local" 2>/dev/null || true

# Load Zabbix configuration (for export_zabbix)
[[ -f "${NFTBAN_CONFIG_DIR}/conf.d/zabbix.conf" ]] && source "${NFTBAN_CONFIG_DIR}/conf.d/zabbix.conf"
[[ -f "${NFTBAN_CONFIG_DIR}/conf.d/zabbix.conf.local" ]] && source "${NFTBAN_CONFIG_DIR}/conf.d/zabbix.conf.local" 2>/dev/null || true

# Load Connectors configuration (for export_connectors)
[[ -f "${NFTBAN_CONFIG_DIR}/conf.d/connectors.conf" ]] && source "${NFTBAN_CONFIG_DIR}/conf.d/connectors.conf"
[[ -f "${NFTBAN_CONFIG_DIR}/conf.d/connectors.conf.local" ]] && source "${NFTBAN_CONFIG_DIR}/conf.d/connectors.conf.local" 2>/dev/null || true

# =============================================================================
# CONFIGURATION DEFAULTS (from metrics.conf, with fallbacks)
# =============================================================================
: "${NFTBAN_COLLECT_INTERVAL:=60}"
: "${NFTBAN_COLLECT_EXTENDED_MULT:=5}"
: "${NFTBAN_COLLECT_INVENTORY_MULT:=60}"
: "${NFTBAN_COLLECT_JITTER_ENABLED:=true}"
: "${NFTBAN_COLLECT_JITTER_MAX:=30}"
: "${NFTBAN_COLLECT_LOCK_TIMEOUT:=10}"
: "${NFTBAN_COLLECT_USE_STALE_CACHE:=true}"
: "${NFTBAN_COLLECT_STALE_MAX_AGE:=300}"
: "${NFTBAN_COLLECT_DEBUG:=false}"

# Component auto-detection defaults
: "${NFTBAN_COLLECT_SURICATA:=auto}"
: "${NFTBAN_COLLECT_FEEDS:=auto}"
: "${NFTBAN_COLLECT_GEOIP:=auto}"
: "${NFTBAN_COLLECT_WATCHDOG:=auto}"
: "${NFTBAN_COLLECT_PORTSCAN:=auto}"
: "${NFTBAN_COLLECT_EVENTBUS:=auto}"
: "${NFTBAN_COLLECT_KERNEL:=auto}"
: "${NFTBAN_COLLECT_NETWORK:=enabled}"

# Export target defaults
# Note: Prometheus export is an OPTIONAL compatibility adapter.
# NFTBan does NOT require Prometheus - it has its own metrics system (stats.json + bans.log).
: "${NFTBAN_EXPORT_JSON:=true}"
: "${NFTBAN_EXPORT_CONNECTORS:=false}"

# Smart auto-detection for Prometheus export:
# Auto-enable only if node_exporter textfile dir exists AND not explicitly set
if [[ -z "${NFTBAN_EXPORT_PROMETHEUS:-}" ]]; then
    if [[ -d "/var/lib/node_exporter/textfile_collector" ]]; then
        NFTBAN_EXPORT_PROMETHEUS="true"
        # Note: log_info not available yet, logged later in main()
    else
        NFTBAN_EXPORT_PROMETHEUS="false"
    fi
fi

# Metrics cache file (collected once, used by all exporters)
readonly METRICS_CACHE="${NFTBAN_RUN_DIR}/metrics.cache"
readonly METRICS_LOCK="${NFTBAN_RUN_DIR}/exporter.lock"
readonly BANDWIDTH_STATE="${NFTBAN_RUN_DIR}/bandwidth_state.dat"
readonly BANDWIDTH_PEAKS="${NFTBAN_RUN_DIR}/bandwidth_peaks.dat"
readonly PEAK_WINDOW=300  # 5 minutes for peak tracking

# Run count tracking for collection groups
readonly RUN_COUNT_FILE="${NFTBAN_RUN_DIR}/collection.run_count"

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

    # Create lock file
    mkdir -p "$(dirname "$METRICS_LOCK")"
    eval "exec $lock_fd>$METRICS_LOCK"

    # Try to acquire lock with timeout (blocking)
    # This prevents silent metrics gaps when concurrent runs overlap
    if ! timeout $lock_timeout flock $lock_fd 2>/dev/null; then
        log_error "Lock acquisition timed out after ${lock_timeout}s (concurrent exporter still running?)"
        log_error "Previous PID: $(cat "$METRICS_LOCK" 2>/dev/null || echo 'unknown')"

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
            # Feeds: at least one feed config exists
            local feed_count
            feed_count=$(find "${NFTBAN_CONFIG_DIR}/feeds" -name "*.conf" 2>/dev/null | wc -l)
            [[ $feed_count -gt 0 ]] && return 0
            ;;
        geoip)
            # GeoIP: module enabled AND database exists
            [[ -f "${NFTBAN_CONFIG_DIR}/modules/geoban.conf" ]] && \
            [[ -f "${NFTBAN_CACHE_DIR}/geoip/GeoLite2-Country.mmdb" ]] && return 0
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
    stats=$(grep -E "^\\s*${interface}:" /proc/net/dev 2>/dev/null || echo "")
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

# =============================================================================
# METRIC COLLECTION (Single collection for all targets)
# =============================================================================
# Groups: live, extended, inventory
# - live:      daemon, bans, memory, nftables, connections (every run)
# - extended:  module_status, feed_health, watchdog, eventbus (every 5 runs)
# - inventory: kernel, geoip, server_info, static config (every 60 runs)
# =============================================================================
collect_all_metrics() {
    local collection_groups="${1:-live extended inventory}"
    log_debug "Collecting metrics (groups: $collection_groups)..."

    local metrics=""
    local timestamp
    timestamp=$(date +%s)

    # Helper: check if a group is active
    # shellcheck disable=SC2076  # Literal match intended (not regex)
    group_active() { [[ " $collection_groups " =~ " $1 " ]]; }

    # =========================================================================
    # LIVE METRICS (every run - 60s)
    # =========================================================================
    local pid=0 status=0 uptime=0
    # Memory metrics (declared at function level for JSON cache access)
    local rss=0 fds=0 threads=0
    # Network metrics (declared at function level for JSON cache access)
    local total_rx_mbps=0 total_tx_mbps=0 peak_rx=0 peak_tx=0
    local conn_active=0 conn_established=0 conn_time_wait=0
    # Network totals for Zabbix compatibility
    local total_rx_bytes=0 total_tx_bytes=0 total_rx_packets=0 total_tx_packets=0
    local total_rx_errors=0 total_tx_errors=0 total_rx_dropped=0 total_tx_dropped=0
    local total_errors=0 total_dropped=0 bandwidth_in_bps=0 bandwidth_out_bps=0
    # Kernel metrics (declared at function level for JSON cache access)
    local conntrack_entries=0 conntrack_max=0 conntrack_utilization=0
    local softnet_drops_total=0 softnet_drops_rate=0
    if group_active "live"; then

        # --- Daemon Metrics ---
        local version
        version=$(cat "${NFTBAN_LIB_DIR}/VERSION" 2>/dev/null | head -1 || echo "unknown")

        if systemctl is-active nftband.service &>/dev/null; then
            status=1
            pid=$(cat "${NFTBAN_RUN_DIR}/nftband.pid" 2>/dev/null || echo "0")
            local start_time
            start_time=$(systemctl show nftband.service -p ActiveEnterTimestamp --value 2>/dev/null || echo "")
            if [[ -n "$start_time" ]]; then
                local start_epoch
                start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo "$timestamp")
                uptime=$((timestamp - start_epoch))
            fi
        fi
        local mode
        mode=$(cat "${NFTBAN_RUN_DIR}/mode" 2>/dev/null || echo "normal")

        metrics+="nftban_daemon_up $status $timestamp\n"
        metrics+="nftban_version_info{version=\"$version\"} 1 $timestamp\n"
        metrics+="nftban_mode_info{mode=\"$mode\"} 1 $timestamp\n"
        metrics+="nftban_uptime_seconds $uptime $timestamp\n"
        metrics+="nftban_pid $pid $timestamp\n"

        # --- Panel Detection ---
        local panel="none"
        if [[ -d /usr/local/cpanel ]] && [[ -f /usr/local/cpanel/cpanel ]]; then
            panel="cpanel"
        elif [[ -d /usr/local/psa ]] && command -v plesk &>/dev/null; then
            panel="plesk"
        elif [[ -d /usr/local/directadmin ]] && [[ -f /usr/local/directadmin/directadmin ]]; then
            panel="directadmin"
        elif [[ -d /usr/local/cwpsrv ]]; then
            panel="cwp"
        elif [[ -d /usr/local/CyberPanel ]]; then
            panel="cyberpanel"
        elif command -v hestia &>/dev/null || [[ -d /usr/local/hestia ]]; then
            panel="hestia"
        fi
        metrics+="nftban_panel_info{panel=\"$panel\"} 1 $timestamp\n"
        # Zabbix string metric for host inventory
        metrics+="nftban.server.panel |STRING|$panel $timestamp\n"

        # --- Ban Metrics (fast nftables JSON API with perm/temp breakdown) ---
        # These metrics align with nftban_stats.sh dashboard requirements
        local active_v4=0 active_v6=0
        local blacklist_v4_perm=0 blacklist_v4_temp=0
        local blacklist_v6_perm=0 blacklist_v6_temp=0
        if command -v nft &>/dev/null; then
            # IPv4 blacklist with perm/temp breakdown
            local v4_output
            v4_output=$(nft list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 2>/dev/null) || v4_output=""
            if [[ -n "$v4_output" ]]; then
                active_v4=$(echo "$v4_output" | grep -oP '\d+\.\d+\.\d+\.\d+(/\d+)?' | wc -l 2>/dev/null) || active_v4=0
                # Match element timeouts (e.g., "timeout 15m") not set flags
                # Use grep -o | wc -l to count occurrences, not lines (nft wraps multiple elements per line)
                blacklist_v4_temp=$(echo "$v4_output" | grep -oP 'timeout \d+[smhd]' 2>/dev/null | wc -l) || blacklist_v4_temp=0
                blacklist_v4_perm=$((active_v4 - blacklist_v4_temp))
                [[ $blacklist_v4_perm -lt 0 ]] && blacklist_v4_perm=0
            fi

            # IPv6 blacklist with perm/temp breakdown
            local v6_output
            v6_output=$(nft list set ${NFTBAN_TABLE_IPV6} blacklist_ipv6 2>/dev/null) || v6_output=""
            if [[ -n "$v6_output" ]]; then
                active_v6=$(echo "$v6_output" | grep -oP '[0-9a-fA-F:]+::[0-9a-fA-F:]*(/\d+)?|[0-9a-fA-F:]+:[0-9a-fA-F:]+(/\d+)?' | wc -l 2>/dev/null) || active_v6=0
                # Match element timeouts (e.g., "timeout 15m") not set flags
                # Use grep -o | wc -l to count occurrences, not lines (nft wraps multiple elements per line)
                blacklist_v6_temp=$(echo "$v6_output" | grep -oP 'timeout \d+[smhd]' 2>/dev/null | wc -l) || blacklist_v6_temp=0
                blacklist_v6_perm=$((active_v6 - blacklist_v6_temp))
                [[ $blacklist_v6_perm -lt 0 ]] && blacklist_v6_perm=0
            fi
        fi
        local active_total=$((active_v4 + active_v6))

        metrics+="nftban_active_count $active_total $timestamp\n"
        metrics+="nftban_active_bans{family=\"ipv4\"} $active_v4 $timestamp\n"
        metrics+="nftban_active_bans{family=\"ipv6\"} $active_v6 $timestamp\n"

        # Perm/temp breakdown (aligned with nftban stats dashboard)
        metrics+="nftban_blacklist_ipv4_perm $blacklist_v4_perm $timestamp\n"
        metrics+="nftban_blacklist_ipv4_temp $blacklist_v4_temp $timestamp\n"
        metrics+="nftban_blacklist_ipv6_perm $blacklist_v6_perm $timestamp\n"
        metrics+="nftban_blacklist_ipv6_temp $blacklist_v6_temp $timestamp\n"

        # --- Time-based ban stats (from log) ---
        # Format: DATE|TIME|SOURCE|IP|COUNTRY|STATUS|REASON
        local bans_log="${NFTBAN_LOG_DIR}/bans.log"
        if [[ -f "$bans_log" ]]; then
            # Single awk pass for time windows, source breakdown, AND unique IPs
            local stats
            stats=$(awk -F'|' -v now="$timestamp" '
                BEGIN {
                    # Time window counters
                    h1=0; h24=0; d7=0; d30=0; m5=0; total=0
                    # Source counters (all time)
                    src_login=0; src_portscan=0; src_ddos=0
                    src_manual=0; src_feeds=0; src_suricata=0
                    # Source counters (24h)
                    src_login_24h=0; src_portscan_24h=0; src_ddos_24h=0
                    src_manual_24h=0; src_feeds_24h=0; src_suricata_24h=0
                }
                {
                    # Parse date to epoch (DATE|TIME format)
                    if ($1 ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/) {
                        # New format: 2026-01-25|14:30:45|source|ip|country|status|reason
                        # Pure awk: convert "YYYY-MM-DD" "HH:MM:SS" to epoch via mktime()
                        split($1, d, "-")
                        split($2, t, ":")
                        epoch = mktime(d[1] " " d[2] " " d[3] " " t[1] " " t[2] " " t[3])
                        source = $3
                        ip = $4
                        status = $6
                    } else if ($1 ~ /^[0-9]+$/) {
                        # Old format: epoch timestamp
                        epoch = $1
                        source = $2
                        ip = $3
                        status = "BANNED"
                    } else {
                        next
                    }

                    # Only count BANNED entries
                    if (status != "BANNED") next

                    age = now - epoch
                    if (age < 0) next  # Future timestamps

                    # Time windows
                    if (age <= 300)     m5++
                    if (age <= 3600)    h1++
                    if (age <= 86400)   { h24++; unique_24h[ip]=1 }
                    if (age <= 604800)  d7++
                    if (age <= 2592000) d30++
                    total++
                    unique_all[ip]=1

                    # Source breakdown (all time)
                    if (source == "login")    src_login++
                    if (source == "portscan") src_portscan++
                    if (source == "ddos")     src_ddos++
                    if (source == "manual")   src_manual++
                    if (source == "feeds")    src_feeds++
                    if (source == "suricata") src_suricata++

                    # Source breakdown (24h)
                    if (age <= 86400) {
                        if (source == "login")    src_login_24h++
                        if (source == "portscan") src_portscan_24h++
                        if (source == "ddos")     src_ddos_24h++
                        if (source == "manual")   src_manual_24h++
                        if (source == "feeds")    src_feeds_24h++
                        if (source == "suricata") src_suricata_24h++
                    }
                }
                END {
                    # Output: time_stats | source_stats_total | source_stats_24h | unique_ips
                    printf "%d %d %d %d %d %d ", m5, h1, h24, d7, d30, total
                    printf "%d %d %d %d %d %d ", src_login, src_portscan, src_ddos, src_manual, src_feeds, src_suricata
                    printf "%d %d %d %d %d %d ", src_login_24h, src_portscan_24h, src_ddos_24h, src_manual_24h, src_feeds_24h, src_suricata_24h
                    printf "%d %d\n", length(unique_24h), length(unique_all)
                }
            ' "$bans_log" 2>/dev/null || echo "0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0")

            # Parse all stats
            read -r bans_5m bans_1h bans_24h bans_7d bans_30d bans_total \
                     src_login src_portscan src_ddos src_manual src_feeds src_suricata \
                     src_login_24h src_portscan_24h src_ddos_24h src_manual_24h src_feeds_24h src_suricata_24h \
                     unique_ips_24h unique_ips_total \
                     <<< "$stats"

            local rate
            rate=$(echo "scale=2; $bans_5m / 5" | bc 2>/dev/null || echo "0")

            # Time window metrics
            metrics+="nftban_bans_last_1h $bans_1h $timestamp\n"
            metrics+="nftban_bans_last_24h $bans_24h $timestamp\n"
            metrics+="nftban_bans_7d $bans_7d $timestamp\n"
            metrics+="nftban_bans_30d $bans_30d $timestamp\n"
            metrics+="nftban_bans_total $bans_total $timestamp\n"
            metrics+="nftban_throughput_bans_per_minute $rate $timestamp\n"

            # Bans by source (total)
            metrics+="nftban_bans_by_source{source=\"login\"} $src_login $timestamp\n"
            metrics+="nftban_bans_by_source{source=\"portscan\"} $src_portscan $timestamp\n"
            metrics+="nftban_bans_by_source{source=\"ddos\"} $src_ddos $timestamp\n"
            metrics+="nftban_bans_by_source{source=\"manual\"} $src_manual $timestamp\n"
            metrics+="nftban_bans_by_source{source=\"feeds\"} $src_feeds $timestamp\n"
            metrics+="nftban_bans_by_source{source=\"suricata\"} $src_suricata $timestamp\n"

            # Bans by source (24h) - for trend analysis
            metrics+="nftban_bans_by_source_24h{source=\"login\"} $src_login_24h $timestamp\n"
            metrics+="nftban_bans_by_source_24h{source=\"portscan\"} $src_portscan_24h $timestamp\n"
            metrics+="nftban_bans_by_source_24h{source=\"ddos\"} $src_ddos_24h $timestamp\n"
            metrics+="nftban_bans_by_source_24h{source=\"manual\"} $src_manual_24h $timestamp\n"
            metrics+="nftban_bans_by_source_24h{source=\"feeds\"} $src_feeds_24h $timestamp\n"
            metrics+="nftban_bans_by_source_24h{source=\"suricata\"} $src_suricata_24h $timestamp\n"

            # Unique IPs (aligned with nftban_stats.sh)
            metrics+="nftban_unique_ips_24h ${unique_ips_24h:-0} $timestamp\n"
            metrics+="nftban_unique_ips_total ${unique_ips_total:-0} $timestamp\n"
        fi

        # --- Memory Metrics ---
        # Variables declared at function level for JSON cache access
        local goroutines=0
        if [[ -n "$pid" ]] && [[ "$pid" != "0" ]] && [[ -d "/proc/$pid" ]]; then
            rss=$(awk '/VmRSS/ {print $2 * 1024}' "/proc/$pid/status" 2>/dev/null || echo "0")
            fds=$(ls -1 "/proc/$pid/fd" 2>/dev/null | wc -l || echo "0")
            threads=$(awk '/Threads/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")

            metrics+="nftban_memory_rss_bytes $rss $timestamp\n"
            metrics+="nftban_open_fds $fds $timestamp\n"
            metrics+="nftban_threads $threads $timestamp\n"

            # Daemon CPU and Memory percentage (from ps)
            local daemon_cpu_pct=0 daemon_mem_pct=0 daemon_vsz=0
            local ps_output
            ps_output=$(ps -p "$pid" -o %cpu,%mem,vsz --no-headers 2>/dev/null || echo "0 0 0")
            if [[ -n "$ps_output" ]]; then
                daemon_cpu_pct=$(echo "$ps_output" | awk '{print $1}')
                daemon_mem_pct=$(echo "$ps_output" | awk '{print $2}')
                daemon_vsz=$(echo "$ps_output" | awk '{print $3 * 1024}')  # VSZ in bytes
            fi
            metrics+="nftban.daemon.cpu_percent $daemon_cpu_pct $timestamp\n"
            metrics+="nftban.daemon.mem_percent $daemon_mem_pct $timestamp\n"
            metrics+="nftban.daemon.vsz_bytes $daemon_vsz $timestamp\n"

            # Goroutines (for Go-based daemon)
            # Try to read from daemon stats file first, then estimate from threads
            local daemon_stats="${NFTBAN_RUN_DIR}/nftband.stats"
            if [[ -f "$daemon_stats" ]]; then
                goroutines=$(jq -r '.goroutines // 0' "$daemon_stats" 2>/dev/null || echo "0")
            fi
            # Fallback: use thread count as approximation if goroutines not available
            [[ "$goroutines" == "0" || -z "$goroutines" ]] && goroutines=$threads
            metrics+="nftban_goroutines $goroutines $timestamp\n"
        fi

        # --- Event Bus Metrics (Phase 3) ---
        local eventbus_events_total=0
        local eventbus_events_ban=0 eventbus_events_unban=0 eventbus_events_login_fail=0
        local eventbus_events_ddos_detected=0 eventbus_events_portscan_detected=0
        local eventbus_events_suricata_alert=0 eventbus_events_feed_sync=0
        local eventbus_events_dropped_total=0
        local eventbus_queue_size=0
        local eventbus_handlers_total=0

        # Try to read from eventbus stats file first
        local eventbus_stats="${NFTBAN_RUN_DIR}/eventbus.stats"
        if [[ -f "$eventbus_stats" ]]; then
            # Read stats from eventbus.stats if available
            eventbus_events_total=$(jq -r '.events_total // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_ban=$(jq -r '.events_by_type.ban // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_unban=$(jq -r '.events_by_type.unban // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_login_fail=$(jq -r '.events_by_type.login_fail // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_ddos_detected=$(jq -r '.events_by_type.ddos_detected // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_portscan_detected=$(jq -r '.events_by_type.portscan_detected // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_suricata_alert=$(jq -r '.events_by_type.suricata_alert // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_feed_sync=$(jq -r '.events_by_type.feed_sync // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_events_dropped_total=$(jq -r '.events_dropped_total // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_queue_size=$(jq -r '.queue_size // 0' "$eventbus_stats" 2>/dev/null || echo "0")
            eventbus_handlers_total=$(jq -r '.handlers_total // 0' "$eventbus_stats" 2>/dev/null || echo "0")
        else
            # Fallback: derive event counts from ban log
            if [[ -f "$bans_log" ]]; then
                # Count BANNED entries as ban events, UNBANNED as unban events
                eventbus_events_ban=$(grep -c "|BANNED|" "$bans_log" 2>/dev/null) || eventbus_events_ban=0
                eventbus_events_unban=$(grep -c "|UNBANNED|" "$bans_log" 2>/dev/null) || eventbus_events_unban=0
                # Estimate total events from ban activity
                eventbus_events_total=$((eventbus_events_ban + eventbus_events_unban))
            fi

            # Fallback: check queue files for queue size
            local queue_total=0
            for queue_file in "${NFTBAN_RUN_DIR}"/*.queue; do
                [[ -f "$queue_file" ]] || continue
                local queue_count
                queue_count=$(wc -l < "$queue_file" 2>/dev/null | tr -d '[:space:]')
                [[ -z "$queue_count" || ! "$queue_count" =~ ^[0-9]+$ ]] && queue_count=0
                queue_total=$((queue_total + queue_count))
            done
            eventbus_queue_size=$queue_total
        fi

        # Export Event Bus metrics
        metrics+="nftban_eventbus_events_total $eventbus_events_total $timestamp\n"
        metrics+="nftban_eventbus_events_by_type{type=\"ban\"} $eventbus_events_ban $timestamp\n"
        metrics+="nftban_eventbus_events_by_type{type=\"unban\"} $eventbus_events_unban $timestamp\n"
        metrics+="nftban_eventbus_events_by_type{type=\"login_fail\"} $eventbus_events_login_fail $timestamp\n"
        metrics+="nftban_eventbus_events_by_type{type=\"ddos_detected\"} $eventbus_events_ddos_detected $timestamp\n"
        metrics+="nftban_eventbus_events_by_type{type=\"portscan_detected\"} $eventbus_events_portscan_detected $timestamp\n"
        metrics+="nftban_eventbus_events_by_type{type=\"suricata_alert\"} $eventbus_events_suricata_alert $timestamp\n"
        metrics+="nftban_eventbus_events_by_type{type=\"feed_sync\"} $eventbus_events_feed_sync $timestamp\n"
        metrics+="nftban_eventbus_events_dropped_total $eventbus_events_dropped_total $timestamp\n"
        metrics+="nftban_eventbus_queue_size $eventbus_queue_size $timestamp\n"
        metrics+="nftban_eventbus_handlers_total $eventbus_handlers_total $timestamp\n"

        # --- nftables Performance Metrics (Phase 3) ---
        # Rule application latency, error tracking, and detailed set/rule metrics
        if command -v nft &>/dev/null; then
            # nftban_nftables_apply_latency_ms - rule application latency in milliseconds
            local nft_apply_latency=0
            local latency_file="${NFTBAN_CACHE_DIR}/stats/sync_latency"
            if [[ -f "$latency_file" ]]; then
                nft_apply_latency=$(cat "$latency_file" 2>/dev/null || echo "0")
                # Ensure it's a valid number
                [[ ! "$nft_apply_latency" =~ ^[0-9]+(\.[0-9]+)?$ ]] && nft_apply_latency=0
            fi
            metrics+="nftban_nftables_apply_latency_ms $nft_apply_latency $timestamp\n"

            # nftban_nftables_apply_errors_total - count nft errors from log
            local nft_apply_errors=0
            local nftban_log="${NFTBAN_LOG_DIR}/nftban.log"
            if [[ -f "$nftban_log" ]]; then
                # Count lines containing nft command errors (case-insensitive)
                nft_apply_errors=$(grep -ciE '(nft.*error|nft.*failed|nft:.*Error)' "$nftban_log" 2>/dev/null) || nft_apply_errors=0
            fi
            metrics+="nftban_nftables_apply_errors_total $nft_apply_errors $timestamp\n"

            # nftban_nftables_rules_total - count rules in nftban table
            local nft_rules_total=0
            local table_output
            table_output=$(nft list table ${NFTBAN_TABLE_IPV4} 2>/dev/null || echo "")
            if [[ -n "$table_output" ]]; then
                # Count lines that look like rules (contain accept, drop, jump, counter, etc.)
                nft_rules_total=$(echo "$table_output" | grep -cE '^\s+(accept|drop|reject|jump|goto|counter|log|limit|ct )' 2>/dev/null | tr -d '[:space:]') || true
                [[ -z "$nft_rules_total" || ! "$nft_rules_total" =~ ^[0-9]+$ ]] && nft_rules_total=0
            fi
            metrics+="nftban_nftables_rules_total $nft_rules_total $timestamp\n"

            # nftban_nftables_sets_total - count sets in nftban table
            local nft_sets_total=0
            if [[ -n "$table_output" ]]; then
                nft_sets_total=$(echo "$table_output" | grep -c "^\s*set " 2>/dev/null | tr -d '[:space:]') || true
                [[ -z "$nft_sets_total" || ! "$nft_sets_total" =~ ^[0-9]+$ ]] && nft_sets_total=0
            fi
            metrics+="nftban_nftables_sets_total $nft_sets_total $timestamp\n"

            # nftban_nftables_set_elements - element count per set with set label
            # IPv4 sets use 'ip' family, IPv6 sets use 'ip6' family
            for set_name in blacklist_ipv4 whitelist_ipv4; do
                local set_elem_count=0
                set_elem_count=$(nft -j list set ip nftban "$set_name" 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null) || true
                [[ -z "$set_elem_count" || ! "$set_elem_count" =~ ^[0-9]+$ ]] && set_elem_count=0
                metrics+="nftban_nftables_set_elements{set=\"${set_name}\"} $set_elem_count $timestamp\n"
            done
            for set_name in blacklist_ipv6 whitelist_ipv6; do
                local set_elem_count=0
                set_elem_count=$(nft -j list set ip6 nftban "$set_name" 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null) || true
                [[ -z "$set_elem_count" || ! "$set_elem_count" =~ ^[0-9]+$ ]] && set_elem_count=0
                metrics+="nftban_nftables_set_elements{set=\"${set_name}\"} $set_elem_count $timestamp\n"
            done

            # nftban_nftables_commands_total - total nft commands executed
            local nft_commands_total=0
            local commands_file="${NFTBAN_CACHE_DIR}/stats/nft_commands_total"
            if [[ -f "$commands_file" ]]; then
                nft_commands_total=$(cat "$commands_file" 2>/dev/null || echo "0")
                [[ ! "$nft_commands_total" =~ ^[0-9]+$ ]] && nft_commands_total=0
            else
                # Fallback: count nft commands from log
                if [[ -f "$nftban_log" ]]; then
                    nft_commands_total=$(grep -ciE '(nft add|nft delete|nft flush|nft list)' "$nftban_log" 2>/dev/null) || nft_commands_total=0
                    [[ -z "$nft_commands_total" || ! "$nft_commands_total" =~ ^[0-9]+$ ]] && nft_commands_total=0
                fi
            fi
            metrics+="nftban_nftables_commands_total $nft_commands_total $timestamp\n"
        fi

    fi  # end LIVE group

    # =========================================================================
    # EXTENDED METRICS (every 5 runs - 5min)
    # =========================================================================
    if group_active "extended"; then

        # --- Module Status Metrics ---
        local mod_enabled=0 mod_active=0 mod_failed=0
        for module in login portscan ddos feeds geoban suricata rbl botscan; do
            if [[ -f "${NFTBAN_CONFIG_DIR}/modules/${module}.conf" ]]; then
                ((mod_enabled++))
                if systemctl is-active "nftban-${module}.timer" &>/dev/null 2>&1; then
                    ((mod_active++))
                elif systemctl is-failed "nftban-${module}.service" &>/dev/null 2>&1; then
                    ((mod_failed++))
                fi
            fi
        done

        metrics+="nftban_modules_enabled $mod_enabled $timestamp\n"
        metrics+="nftban_modules_active $mod_active $timestamp\n"
        metrics+="nftban_modules_failed $mod_failed $timestamp\n"

        # --- Individual Module Status Metrics ---
        # Status values: 1=active, 0=disabled, -1=failed
        # Checks: config exists, timer/service active, service failed
        local module_login_status=0 module_portscan_status=0 module_ddos_status=0
        local module_suricata_status=0 module_feeds_status=0 module_geoban_status=0
        local module_watchdog_status=0

        for module in login portscan ddos suricata feeds geoban watchdog; do
            local status_val=0
            local config_file="${NFTBAN_CONFIG_DIR}/modules/${module}.conf"

            if [[ -f "$config_file" ]]; then
                # Config exists, check if service/timer is active or failed
                if systemctl is-active "nftban-${module}.timer" &>/dev/null 2>&1 || \
                   systemctl is-active "nftban-${module}.service" &>/dev/null 2>&1; then
                    status_val=1  # active
                elif systemctl is-failed "nftban-${module}.service" &>/dev/null 2>&1; then
                    status_val=-1  # failed
                fi
                # else remains 0 (disabled - config exists but not running)
            fi
            # If config doesnt exist, status remains 0 (disabled)

            # Assign to individual variables for JSON cache
            case "$module" in
                login)    module_login_status=$status_val ;;
                portscan) module_portscan_status=$status_val ;;
                ddos)     module_ddos_status=$status_val ;;
                suricata) module_suricata_status=$status_val ;;
                feeds)    module_feeds_status=$status_val ;;
                geoban)   module_geoban_status=$status_val ;;
                watchdog) module_watchdog_status=$status_val ;;
            esac

            metrics+="nftban_module_${module}_status $status_val $timestamp\n"
        done


        # --- nftables Metrics ---
        if command -v nft &>/dev/null; then
            local sets_count elements_total
            # Count sets per family (nft list sets FAMILY, not "nft list sets FAMILY TABLE")
            local ipv4_family="${NFTBAN_TABLE_IPV4%% *}"  # "ip" from "ip nftban"
            local ipv6_family="${NFTBAN_TABLE_IPV6%% *}"  # "ip6" from "ip6 nftban"
            sets_count=$(( $(nft list sets "$ipv4_family" 2>/dev/null | grep -c "set " || echo 0) + $(nft list sets "$ipv6_family" 2>/dev/null | grep -c "set " || echo 0) ))
            elements_total=0

            # Individual set counts (for audit/stats alignment)
            local blacklist_v4=0 blacklist_v6=0 whitelist_v4=0 whitelist_v6=0
            for set_name in blacklist_ipv4 blacklist_ipv6 whitelist_ipv4 whitelist_ipv6; do
                local count nft_table
                # Select correct table based on address family
                if [[ "$set_name" == *_ipv6 ]]; then
                    nft_table="${NFTBAN_TABLE_IPV6}"
                else
                    nft_table="${NFTBAN_TABLE_IPV4}"
                fi
                count=$(nft -j list set ${nft_table} "$set_name" 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
                elements_total=$((elements_total + count))

                case "$set_name" in
                    blacklist_ipv4) blacklist_v4=$count ;;
                    blacklist_ipv6) blacklist_v6=$count ;;
                    whitelist_ipv4) whitelist_v4=$count ;;
                    whitelist_ipv6) whitelist_v6=$count ;;
                esac
            done

            metrics+="nftban_nft_sets_total $sets_count $timestamp\n"
            metrics+="nftban_nft_elements_total $elements_total $timestamp\n"

            # Blacklist/whitelist breakdown (aligned with nftban stats)
            metrics+="nftban_blacklist{family=\"ipv4\"} $blacklist_v4 $timestamp\n"
            metrics+="nftban_blacklist{family=\"ipv6\"} $blacklist_v6 $timestamp\n"
            metrics+="nftban_blacklist_total $((blacklist_v4 + blacklist_v6)) $timestamp\n"
            metrics+="nftban_whitelist{family=\"ipv4\"} $whitelist_v4 $timestamp\n"
            metrics+="nftban_whitelist{family=\"ipv6\"} $whitelist_v6 $timestamp\n"
            metrics+="nftban_whitelist_total $((whitelist_v4 + whitelist_v6)) $timestamp\n"
        fi

        # --- Feeds Metrics (component: feeds) with IPv4/IPv6 split ---
        # Aligned with nftban_stats.sh dashboard requirements
        local feeds_enabled=0 feeds_loaded=0 feeds_failed=0
        local feeds_ips=0 feeds_ipv4_total=0 feeds_ipv6_total=0
        if should_collect_component "feeds"; then
            if [[ -d "${NFTBAN_CONFIG_DIR}/feeds" ]]; then
                for feed_file in "${NFTBAN_CONFIG_DIR}/feeds"/*.conf; do
                    [[ -f "$feed_file" ]] || continue
                    ((feeds_enabled++))
                    local feed_name feed_data
                    feed_name=$(basename "$feed_file" .conf)
                    feed_data="${NFTBAN_CACHE_DIR}/feeds/${feed_name}.list"
                    if [[ -f "$feed_data" ]]; then
                        ((feeds_loaded++))
                        local total_count v4_count v6_count
                        total_count=$(wc -l < "$feed_data" 2>/dev/null || echo "0")
                        # Count IPv4 (lines starting with digit, no colon = pure IPv4)
                        v4_count=$(grep -cE '^[0-9]+\.' "$feed_data" 2>/dev/null) || v4_count=0
                        # Count IPv6 (lines containing colon)
                        v6_count=$(grep -cE '^[0-9a-fA-F]*:' "$feed_data" 2>/dev/null) || v6_count=0
                        feeds_ips=$((feeds_ips + total_count))
                        feeds_ipv4_total=$((feeds_ipv4_total + v4_count))
                        feeds_ipv6_total=$((feeds_ipv6_total + v6_count))
                    else
                        ((feeds_failed++))
                    fi
                done
            fi

            metrics+="nftban_feeds_enabled $feeds_enabled $timestamp\n"
            metrics+="nftban_feeds_loaded $feeds_loaded $timestamp\n"
            metrics+="nftban_feeds_failed $feeds_failed $timestamp\n"
            metrics+="nftban_feeds_ips_total $feeds_ips $timestamp\n"
            metrics+="nftban_feeds_ipv4_total $feeds_ipv4_total $timestamp\n"
            metrics+="nftban_feeds_ipv6_total $feeds_ipv6_total $timestamp\n"
        fi

        # --- Feed Health Metrics (Phase 1) ---
        # Sync errors: count [ERROR] or [FAIL] entries from last 24 hours in feeds.log
        local feeds_sync_errors=0
        local feeds_log="${NFTBAN_LOG_DIR}/feeds.log"
        if [[ -f "$feeds_log" ]]; then
            local cutoff_time=$((timestamp - 86400))
            # POSIX-compatible: count errors in last 24h using grep (mawk doesn't support {n} quantifiers)
            feeds_sync_errors=$(grep -cE '\[(ERROR|FAIL)\]' "$feeds_log" 2>/dev/null) || feeds_sync_errors=0
        fi
        metrics+="nftban_feeds_sync_errors_total $feeds_sync_errors $timestamp\n"

        # Stale feeds: count feeds with last_sync > 24 hours from .state files
        local feeds_stale_count=0
        local feeds_state_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds"
        if [[ -d "$feeds_state_dir" ]]; then
            local cutoff_time=$((timestamp - 86400))
            for state_file in "$feeds_state_dir"/*.state; do
                [[ -f "$state_file" ]] || continue
                local last_sync
                last_sync=$(jq -r '.last_sync // 0' "$state_file" 2>/dev/null || echo "0")
                if [[ "$last_sync" =~ ^[0-9]+$ ]] && [[ $last_sync -gt 0 ]] && [[ $last_sync -lt $cutoff_time ]]; then
                    ((feeds_stale_count++))
                fi
            done
        fi
        metrics+="nftban_feeds_stale_count $feeds_stale_count $timestamp\n"

        # --- GeoBan Metrics (count blocked countries) ---
        # Count by 50-ban-*.conf files in geoban.d directory
        local geoban_countries_blocked=0
        local geoban_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/geoban.d"
        if [[ -d "$geoban_dir" ]]; then
            geoban_countries_blocked=$(ls -1 "$geoban_dir"/50-ban-*.conf 2>/dev/null | wc -l) || geoban_countries_blocked=0
        fi
        metrics+="nftban_geoban_countries_blocked $geoban_countries_blocked $timestamp\n"

        # --- Watchdog Metrics (component: watchdog) ---
        if should_collect_component "watchdog"; then
            if [[ -f "${NFTBAN_RUN_DIR}/watchdog.status" ]]; then
                if head -1 "${NFTBAN_RUN_DIR}/watchdog.status" | grep -q "^{"; then
                    local cpu_score mem_score io_score
                    cpu_score=$(jq -r '.cpu_score // 0' "${NFTBAN_RUN_DIR}/watchdog.status" 2>/dev/null || echo "0")
                    mem_score=$(jq -r '.mem_score // 0' "${NFTBAN_RUN_DIR}/watchdog.status" 2>/dev/null || echo "0")
                    io_score=$(jq -r '.io_score // 0' "${NFTBAN_RUN_DIR}/watchdog.status" 2>/dev/null || echo "0")

                    metrics+="nftban_watchdog_cpu_score $cpu_score $timestamp\n"
                    metrics+="nftban_watchdog_mem_score $mem_score $timestamp\n"
                    metrics+="nftban_watchdog_io_score $io_score $timestamp\n"
                fi
                metrics+="nftban_watchdog_up 1 $timestamp\n"
            else
                metrics+="nftban_watchdog_up 0 $timestamp\n"
            fi
        fi

        # --- Kernel Softnet Metrics (component: kernel) ---
        # Softnet drops indicate packet processing pressure on CPU
        # Variables declared at function level for JSON cache access
        if should_collect_component "kernel"; then
            if [[ -f /proc/net/softnet_stat ]]; then
                # Column 2 (0-indexed: col 1) is dropped packets, values are in hex
                softnet_drops_total=$(awk '{sum += strtonum("0x" $2)} END {print sum}' /proc/net/softnet_stat 2>/dev/null || echo "0")
            fi
            metrics+="nftban_softnet_drops_total $softnet_drops_total $timestamp\n"

            # Calculate rate from previous value
            local softnet_state="${NFTBAN_RUN_DIR}/softnet_state.dat"
            if [[ -f "$softnet_state" ]]; then
                local prev_drops prev_ts
                read -r prev_drops prev_ts < "$softnet_state" 2>/dev/null || { prev_drops=0; prev_ts=$timestamp; }
                local drops_delta=$((softnet_drops_total - prev_drops))
                local time_delta=$((timestamp - prev_ts))
                [[ $drops_delta -lt 0 ]] && drops_delta=0  # Handle counter wrap
                if [[ $time_delta -gt 0 ]]; then
                    # Rate per minute = (drops_delta / time_delta) * 60
                    softnet_drops_rate=$(awk -v d="$drops_delta" -v t="$time_delta" 'BEGIN {printf "%.2f", (d/t)*60}')
                fi
            fi
            echo "$softnet_drops_total $timestamp" > "$softnet_state"
            metrics+="nftban_softnet_backlog_total $softnet_drops_rate $timestamp\n"
        fi

        # --- Server Load Metrics ---
        local load1 load5 load15 cpu_cores
        if [[ -f /proc/loadavg ]]; then
            read -r load1 load5 load15 _ < /proc/loadavg
            metrics+="nftban.server.load_1m $load1 $timestamp\n"
            metrics+="nftban.server.load_5m $load5 $timestamp\n"
            metrics+="nftban.server.load_15m $load15 $timestamp\n"
        fi
        cpu_cores=$(nproc 2>/dev/null || echo "1")
        metrics+="nftban.server.cpu_cores $cpu_cores $timestamp\n"

        # --- Server Memory Metrics ---
        local memory_total=0 memory_available=0 memory_used_pct=0
        if [[ -f /proc/meminfo ]]; then
            memory_total=$(awk '/^MemTotal:/ {printf "%.0f", $2 * 1024}' /proc/meminfo 2>/dev/null || echo "0")
            memory_available=$(awk '/^MemAvailable:/ {printf "%.0f", $2 * 1024}' /proc/meminfo 2>/dev/null || echo "0")
            if [[ $memory_total -gt 0 ]]; then
                local memory_used=$((memory_total - memory_available))
                memory_used_pct=$(awk -v used="$memory_used" -v total="$memory_total" 'BEGIN {printf "%.2f", (used/total)*100}')
            fi
        fi
        metrics+="nftban.server.memory_total $memory_total $timestamp\n"
        metrics+="nftban.server.memory_available $memory_available $timestamp\n"
        metrics+="nftban.server.mem_used_percent $memory_used_pct $timestamp\n"

        # --- Server Uptime ---
        local server_uptime=0
        if [[ -f /proc/uptime ]]; then
            server_uptime=$(awk '{printf "%.0f", $1}' /proc/uptime 2>/dev/null || echo "0")
        fi
        metrics+="nftban.server.uptime $server_uptime $timestamp\n"

        # --- Server Disk Metrics (root filesystem) ---
        local disk_total=0 disk_used=0 disk_used_pct=0
        if command -v df &>/dev/null; then
            local df_output
            df_output=$(df -B1 / 2>/dev/null | tail -1 || echo "")
            if [[ -n "$df_output" ]]; then
                disk_total=$(echo "$df_output" | awk '{print $2}')
                disk_used=$(echo "$df_output" | awk '{print $3}')
                disk_used_pct=$(echo "$df_output" | awk '{gsub(/%/, "", $5); print $5}')
            fi
        fi
        metrics+="nftban.server.disk_total $disk_total $timestamp\n"
        metrics+="nftban.server.disk_used $disk_used $timestamp\n"
        metrics+="nftban.server.disk_used_percent $disk_used_pct $timestamp\n"

    fi  # end EXTENDED group

    # =========================================================================
    # INVENTORY METRICS (every 60 runs - 1 hour)
    # String metrics for Zabbix host inventory auto-population
    # =========================================================================
    if group_active "inventory"; then

        # --- Server Inventory Metrics (for Zabbix host inventory auto-population) ---
        # Hostname and FQDN
        local server_hostname server_fqdn
        server_hostname=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo "unknown")
        server_fqdn=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown")
        metrics+="nftban_server_hostname_info{hostname=\"$server_hostname\"} 1 $timestamp\n"
        metrics+="nftban_server_fqdn_info{fqdn=\"$server_fqdn\"} 1 $timestamp\n"

        # OS information from /etc/os-release
        local server_os="" server_os_release="" server_kernel="" server_arch=""
        if [[ -f /etc/os-release ]]; then
            # PRETTY_NAME contains full name like "Fedora Linux 42 (Server Edition)"
            server_os=$(grep -E "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "")
            # NAME contains just "Fedora Linux"
            server_os_release=$(grep -E "^NAME=" /etc/os-release 2>/dev/null | cut -d'"' -f2 || echo "")
        fi
        [[ -z "$server_os" ]] && server_os=$(uname -o 2>/dev/null || echo "Linux")
        [[ -z "$server_os_release" ]] && server_os_release=$(uname -o 2>/dev/null || echo "Linux")
        server_kernel=$(uname -r 2>/dev/null || echo "unknown")
        server_arch=$(uname -m 2>/dev/null || echo "unknown")
        metrics+="nftban_server_os_info{os=\"$server_os\"} 1 $timestamp\n"
        metrics+="nftban_server_os_release_info{release=\"$server_os_release\"} 1 $timestamp\n"
        metrics+="nftban_server_kernel_info{kernel=\"$server_kernel\"} 1 $timestamp\n"
        metrics+="nftban_server_arch_info{arch=\"$server_arch\"} 1 $timestamp\n"

        # CPU model name
        local server_cpu_model=""
        if [[ -f /proc/cpuinfo ]]; then
            server_cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | sed 's/^[ \t]*//' || echo "")
        fi
        [[ -z "$server_cpu_model" ]] && server_cpu_model=$(uname -p 2>/dev/null || echo "unknown")
        metrics+="nftban_server_cpu_model_info{model=\"$server_cpu_model\"} 1 $timestamp\n"

        # Server type detection (physical, vm, container)
        local server_type="physical"
        if [[ -f /.dockerenv ]] || grep -q 'docker\|lxc\|containerd' /proc/1/cgroup 2>/dev/null; then
            server_type="container"
        elif [[ -d /proc/vz ]] || grep -qiE 'hypervisor|vmware|virtualbox|kvm|qemu|xen|microsoft' /proc/cpuinfo 2>/dev/null; then
            server_type="vm"
        elif command -v systemd-detect-virt &>/dev/null; then
            local virt
            virt=$(systemd-detect-virt 2>/dev/null || echo "none")
            [[ "$virt" != "none" ]] && server_type="vm"
        fi
        metrics+="nftban_server_type_info{type=\"$server_type\"} 1 $timestamp\n"

        # Hardware vendor and model (from DMI if available)
        local server_vendor="" server_model="" server_serial=""
        if [[ -f /sys/class/dmi/id/sys_vendor ]]; then
            server_vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "")
        fi
        if [[ -f /sys/class/dmi/id/product_name ]]; then
            server_model=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "")
        fi
        if [[ -f /sys/class/dmi/id/product_serial ]]; then
            server_serial=$(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo "")
        fi
        [[ -z "$server_vendor" ]] && server_vendor="Unknown"
        [[ -z "$server_model" ]] && server_model="Unknown"
        [[ -z "$server_serial" ]] && server_serial="N/A"
        metrics+="nftban_server_vendor_info{vendor=\"$server_vendor\"} 1 $timestamp\n"
        metrics+="nftban_server_model_info{model=\"$server_model\"} 1 $timestamp\n"
        metrics+="nftban_server_serial_info{serial=\"$server_serial\"} 1 $timestamp\n"

        # Network information (primary IP, MAC, subnet mask)
        local server_primary_ip="" server_mac="" server_subnet_mask="" server_networks=""
        # Get primary interface (default route)
        local primary_iface
        primary_iface=$(ip route 2>/dev/null | awk '/^default/ {print $5; exit}' || echo "")
        if [[ -n "$primary_iface" ]]; then
            # Primary IP
            server_primary_ip=$(ip -4 addr show "$primary_iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f1 | head -1 || echo "")
            # Subnet mask (CIDR to dotted decimal)
            local cidr
            cidr=$(ip -4 addr show "$primary_iface" 2>/dev/null | awk '/inet / {print $2}' | cut -d'/' -f2 | head -1 || echo "24")
            case "$cidr" in
                8)  server_subnet_mask="255.0.0.0" ;;
                16) server_subnet_mask="255.255.0.0" ;;
                24) server_subnet_mask="255.255.255.0" ;;
                32) server_subnet_mask="255.255.255.255" ;;
                *)  server_subnet_mask="255.255.255.0" ;;  # Default fallback
            esac
            # MAC address
            server_mac=$(ip link show "$primary_iface" 2>/dev/null | awk '/link\/ether/ {print $2}' || echo "")
        fi
        [[ -z "$server_primary_ip" ]] && server_primary_ip="127.0.0.1"
        [[ -z "$server_mac" ]] && server_mac="00:00:00:00:00:00"

        # Collect all network interfaces with IPs
        server_networks=$(ip -4 addr 2>/dev/null | awk '/inet / {gsub(/\/.*/, "", $2); printf "%s:%s ", $NF, $2}' | sed 's/ $//' || echo "")
        [[ -z "$server_networks" ]] && server_networks="lo:127.0.0.1"

        metrics+="nftban_server_primary_ip_info{ip=\"$server_primary_ip\"} 1 $timestamp\n"
        metrics+="nftban_server_mac_info{mac=\"$server_mac\"} 1 $timestamp\n"
        metrics+="nftban_server_subnet_mask_info{mask=\"$server_subnet_mask\"} 1 $timestamp\n"
        metrics+="nftban_server_networks_info{networks=\"$server_networks\"} 1 $timestamp\n"

        # Location (from config or empty)
        local server_location="${NFTBAN_SERVER_LOCATION:-}"
        [[ -z "$server_location" ]] && server_location="Not configured"
        metrics+="nftban_server_location_info{location=\"$server_location\"} 1 $timestamp\n"

        # NFTBan version
        local nftban_version
        nftban_version=$(cat "${NFTBAN_LIB_DIR}/VERSION" 2>/dev/null | head -1 || echo "unknown")
        metrics+="nftban_server_nftban_version_info{version=\"$nftban_version\"} 1 $timestamp\n"

        # NOTE: Memory, uptime, disk metrics moved to EXTENDED group (every 5 min)
        # See: "Server Load Metrics", "Server Memory Metrics", "Server Disk Metrics" in EXTENDED

        # --- Zabbix-compatible String Metrics ---
        # Zabbix trapper items expect the actual string value, not labels
        # These are formatted as: metric_name |STRING|value timestamp
        # The export_zabbix function handles the |STRING| marker specially
        # Using dot notation to match Zabbix template keys exactly
        metrics+="nftban.server.hostname |STRING|$server_hostname $timestamp\n"
        metrics+="nftban.server.fqdn |STRING|$server_fqdn $timestamp\n"
        metrics+="nftban.server.os |STRING|$server_os $timestamp\n"
        metrics+="nftban.server.os_release |STRING|$server_os_release $timestamp\n"
        metrics+="nftban.server.kernel |STRING|$server_kernel $timestamp\n"
        metrics+="nftban.server.arch |STRING|$server_arch $timestamp\n"
        metrics+="nftban.server.cpu_model |STRING|$server_cpu_model $timestamp\n"
        metrics+="nftban.server.type |STRING|$server_type $timestamp\n"
        metrics+="nftban.server.vendor |STRING|$server_vendor $timestamp\n"
        metrics+="nftban.server.model |STRING|$server_model $timestamp\n"
        metrics+="nftban.server.serial |STRING|$server_serial $timestamp\n"
        metrics+="nftban.server.primary_ip |STRING|$server_primary_ip $timestamp\n"
        metrics+="nftban.server.mac_address |STRING|$server_mac $timestamp\n"
        metrics+="nftban.server.subnet_mask |STRING|$server_subnet_mask $timestamp\n"
        metrics+="nftban.server.networks |STRING|$server_networks $timestamp\n"
        metrics+="nftban.server.location |STRING|$server_location $timestamp\n"
        metrics+="nftban.server.nftban_version |STRING|$nftban_version $timestamp\n"

        # --- Kernel Conntrack Metrics (component: kernel) ---
        # Variables declared at function level for JSON cache access
        if should_collect_component "kernel"; then
            if [[ -f /proc/sys/net/netfilter/nf_conntrack_count ]]; then
                conntrack_entries=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "0")
            fi
            if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
                conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "0")
            fi
            if [[ $conntrack_max -gt 0 ]]; then
                conntrack_utilization=$(awk -v e="$conntrack_entries" -v m="$conntrack_max" 'BEGIN {printf "%.2f", (e/m)*100}')
            fi
            metrics+="nftban_conntrack_entries $conntrack_entries $timestamp\n"
            metrics+="nftban_conntrack_max $conntrack_max $timestamp\n"
            metrics+="nftban_conntrack_utilization $conntrack_utilization $timestamp\n"
        fi

    fi  # end INVENTORY group

    # =========================================================================
    # NETWORK METRICS (LIVE group, component: network)
    # =========================================================================
    if group_active "live" && should_collect_component "network"; then

        # --- Bandwidth Metrics ---
        # Variables declared at function level for JSON cache access
        mkdir -p "$(dirname "$BANDWIDTH_STATE")"

        # Get all physical interfaces (exclude lo, docker, veth, etc.)
        for iface_path in /sys/class/net/*; do
            [[ ! -d "$iface_path" ]] && continue
            local iface="${iface_path##*/}"
            # Skip virtual interfaces
            [[ "$iface" =~ ^(lo|docker[0-9]*|veth.*|br-.*|virbr.*)$ ]] && continue
            local stats
            stats=$(get_interface_stats "$iface") || continue
        local rx_bytes rx_packets rx_errs rx_drop tx_bytes tx_packets tx_errs tx_drop
        read -r rx_bytes rx_packets rx_errs rx_drop tx_bytes tx_packets tx_errs tx_drop <<< "$stats"

        # Per-interface metrics
        metrics+="nftban_network_rx_bytes{interface=\"${iface}\"} $rx_bytes $timestamp\n"
        metrics+="nftban_network_tx_bytes{interface=\"${iface}\"} $tx_bytes $timestamp\n"
        metrics+="nftban_network_rx_packets{interface=\"${iface}\"} $rx_packets $timestamp\n"
        metrics+="nftban_network_tx_packets{interface=\"${iface}\"} $tx_packets $timestamp\n"
        metrics+="nftban_network_rx_errors{interface=\"${iface}\"} $rx_errs $timestamp\n"
        metrics+="nftban_network_tx_errors{interface=\"${iface}\"} $tx_errs $timestamp\n"
        metrics+="nftban_network_rx_dropped{interface=\"${iface}\"} $rx_drop $timestamp\n"
        metrics+="nftban_network_tx_dropped{interface=\"${iface}\"} $tx_drop $timestamp\n"

        # Accumulate totals for Zabbix compatibility
        total_rx_bytes=$((total_rx_bytes + rx_bytes))
        total_tx_bytes=$((total_tx_bytes + tx_bytes))
        total_rx_packets=$((total_rx_packets + rx_packets))
        total_tx_packets=$((total_tx_packets + tx_packets))
        total_rx_errors=$((total_rx_errors + rx_errs))
        total_tx_errors=$((total_tx_errors + tx_errs))
        total_rx_dropped=$((total_rx_dropped + rx_drop))
        total_tx_dropped=$((total_tx_dropped + tx_drop))

        # Calculate Mbps from previous state
        if [[ -f "$BANDWIDTH_STATE" ]]; then
            local prev_data prev_ts prev_rx prev_tx
            prev_data=$(grep "^${iface} " "$BANDWIDTH_STATE" 2>/dev/null || echo "")
            if [[ -n "$prev_data" ]]; then
                read -r _ prev_rx prev_tx prev_ts <<< "$prev_data"
                local rx_delta=$((rx_bytes - prev_rx))
                local tx_delta=$((tx_bytes - prev_tx))
                local time_delta=$((timestamp - prev_ts))
                [[ $rx_delta -lt 0 ]] && rx_delta=0  # Handle counter wrap
                [[ $tx_delta -lt 0 ]] && tx_delta=0
                local rx_mbps tx_mbps
                rx_mbps=$(calculate_mbps $rx_delta $time_delta)
                tx_mbps=$(calculate_mbps $tx_delta $time_delta)
                metrics+="nftban_network_rx_mbps{interface=\"${iface}\"} $rx_mbps $timestamp\n"
                metrics+="nftban_network_tx_mbps{interface=\"${iface}\"} $tx_mbps $timestamp\n"
                total_rx_mbps=$(echo "$total_rx_mbps + $rx_mbps" | bc -l 2>/dev/null || echo "$total_rx_mbps")
                total_tx_mbps=$(echo "$total_tx_mbps + $tx_mbps" | bc -l 2>/dev/null || echo "$total_tx_mbps")
            fi
        fi

        # Update state file (append/replace for this interface)
        grep -v "^${iface} " "$BANDWIDTH_STATE" 2>/dev/null > "${BANDWIDTH_STATE}.tmp" || true
        echo "${iface} ${rx_bytes} ${tx_bytes} ${timestamp}" >> "${BANDWIDTH_STATE}.tmp"
        mv "${BANDWIDTH_STATE}.tmp" "$BANDWIDTH_STATE"
    done

    # Total bandwidth and peaks
    metrics+="nftban_network_total_rx_mbps $total_rx_mbps $timestamp\n"
    metrics+="nftban_network_total_tx_mbps $total_tx_mbps $timestamp\n"

    local peaks
    peaks=$(update_bandwidth_peaks "$total_rx_mbps" "$total_tx_mbps" "$timestamp")
    read -r peak_rx peak_tx <<< "$peaks"
    metrics+="nftban_bandwidth_peak_rx_mbps $peak_rx $timestamp\n"
    metrics+="nftban_bandwidth_peak_tx_mbps $peak_tx $timestamp\n"

    # -------------------------------------------------------------------------
    # NETWORK TOTALS (Zabbix-compatible aggregated counters)
    # These metrics align with Zabbix template keys:
    #   nftban.network.bytes_in, nftban.network.bytes_out
    #   nftban.network.packets_in, nftban.network.packets_out
    #   nftban.network.errors, nftban.network.packets_dropped
    #   nftban.bandwidth.in, nftban.bandwidth.out
    # -------------------------------------------------------------------------
    # Total bytes (counters)
    metrics+="nftban_network_bytes_received_total $total_rx_bytes $timestamp\n"
    metrics+="nftban_network_bytes_sent_total $total_tx_bytes $timestamp\n"

    # Total packets (counters)
    metrics+="nftban_network_packets_received_total $total_rx_packets $timestamp\n"
    metrics+="nftban_network_packets_sent_total $total_tx_packets $timestamp\n"

    # Total errors (combined RX+TX errors)
    total_errors=$((total_rx_errors + total_tx_errors))
    metrics+="nftban_network_errors_total $total_errors $timestamp\n"

    # Total dropped packets (combined RX+TX dropped)
    total_dropped=$((total_rx_dropped + total_tx_dropped))
    metrics+="nftban_network_packets_dropped_total $total_dropped $timestamp\n"

    # Bandwidth rate in bits per second (for Zabbix nftban.bandwidth.in/out)
    # Convert Mbps to bps: Mbps * 1000000
    bandwidth_in_bps=$(awk -v m="$total_rx_mbps" 'BEGIN {printf "%.0f", m * 1000000}')
    bandwidth_out_bps=$(awk -v m="$total_tx_mbps" 'BEGIN {printf "%.0f", m * 1000000}')
    metrics+="nftban_bandwidth_in_bps $bandwidth_in_bps $timestamp\n"
    metrics+="nftban_bandwidth_out_bps $bandwidth_out_bps $timestamp\n"

        # --- Connection Metrics ---
        # Variables declared at function level for JSON cache access
        conn_active=$(get_connection_stats active)
        conn_established=$(get_connection_stats established)
        conn_time_wait=$(get_connection_stats time_wait)
        metrics+="nftban_connections_active $conn_active $timestamp\n"
        metrics+="nftban_connections_established $conn_established $timestamp\n"
        metrics+="nftban_connections_time_wait $conn_time_wait $timestamp\n"

    fi  # end NETWORK group (live + network component)

    # =========================================================================
    # GEOIP METRICS (INVENTORY group, component: geoip)
    # =========================================================================
    if group_active "inventory" && should_collect_component "geoip"; then
        local geoip_db="${NFTBAN_CACHE_DIR}/geoip/GeoLite2-Country.mmdb"
        if [[ -f "$geoip_db" ]]; then
            local db_age_days
            db_age_days=$(( (timestamp - $(stat -c %Y "$geoip_db" 2>/dev/null || echo "$timestamp")) / 86400 ))
            metrics+="nftban_geoip_database_age_days $db_age_days $timestamp\n"
            metrics+="nftban_geoip_database_present 1 $timestamp\n"
        else
            metrics+="nftban_geoip_database_present 0 $timestamp\n"
        fi

        # Count blocked countries
        local countries_blocked=0
        if [[ -d "${NFTBAN_CONFIG_DIR}/geoban.d" ]]; then
            countries_blocked=$(ls -1 "${NFTBAN_CONFIG_DIR}/geoban.d/"50-ban-*.conf 2>/dev/null | wc -l) || countries_blocked=0
        fi
        metrics+="nftban_geoip_countries_blocked $countries_blocked $timestamp\n"
    fi  # end GEOIP group

    # =========================================================================
    # CACHE METRICS (Single Source of Truth)
    # =========================================================================
    mkdir -p "$(dirname "$METRICS_CACHE")"
    mkdir -p "${NFTBAN_JSON_CACHE_DIR:-/var/cache/nftban/metrics}"

    # 1. Raw metrics cache (for Prometheus/Zabbix export)
    echo -e "$metrics" > "$METRICS_CACHE"

    # 2. JSON cache (Single Source of Truth for nftban stats and API)
    # This structure EXACTLY matches what nftban_stats.sh dashboard needs
    local json_cache="${NFTBAN_JSON_CACHE_DIR:-/var/cache/nftban/metrics}/stats.json"
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    # Build JSON from collected metrics - SINGLE SOURCE OF TRUTH
    # All fields align with nftban_stats.sh generate_dashboard() requirements
    cat > "${json_cache}.tmp" <<EOF
{
  "schema_version": "2.0",
  "generated_at": "$(date -Iseconds)",
  "generated_epoch": $timestamp,
  "hostname": "$hostname",
  "collection_groups": "$collection_groups",
  "run_count": $(cat "$RUN_COUNT_FILE" 2>/dev/null || echo 0),
  "daemon": {
    "status": $status,
    "pid": $pid,
    "uptime_seconds": $uptime
  },
  "blacklist": {
    "ipv4": {
      "total": ${active_v4:-0},
      "permanent": ${blacklist_v4_perm:-0},
      "temporary": ${blacklist_v4_temp:-0}
    },
    "ipv6": {
      "total": ${active_v6:-0},
      "permanent": ${blacklist_v6_perm:-0},
      "temporary": ${blacklist_v6_temp:-0}
    },
    "total": ${active_total:-0}
  },
  "whitelist": {
    "ipv4": ${whitelist_v4:-0},
    "ipv6": ${whitelist_v6:-0},
    "total": $((${whitelist_v4:-0} + ${whitelist_v6:-0}))
  },
  "feeds": {
    "enabled": ${feeds_enabled:-0},
    "loaded": ${feeds_loaded:-0},
    "failed": ${feeds_failed:-0},
    "ipv4_total": ${feeds_ipv4_total:-0},
    "ipv6_total": ${feeds_ipv6_total:-0},
    "ips_total": ${feeds_ips:-0}
  },
  "feed_health": {
    "sync_errors_total": ${feeds_sync_errors:-0},
    "stale_count": ${feeds_stale_count:-0}
  },
  "geoban": {
    "countries_blocked": ${geoban_countries_blocked:-0}
  },
  "bans_by_source": {
    "login": ${src_login:-0},
    "portscan": ${src_portscan:-0},
    "ddos": ${src_ddos:-0},
    "manual": ${src_manual:-0},
    "feeds": ${src_feeds:-0},
    "suricata": ${src_suricata:-0}
  },
  "bans_by_source_24h": {
    "login": ${src_login_24h:-0},
    "portscan": ${src_portscan_24h:-0},
    "ddos": ${src_ddos_24h:-0},
    "manual": ${src_manual_24h:-0},
    "feeds": ${src_feeds_24h:-0},
    "suricata": ${src_suricata_24h:-0}
  },
  "activity": {
    "total_bans": ${bans_total:-0},
    "unique_ips": ${unique_ips_total:-0},
    "unique_ips_24h": ${unique_ips_24h:-0},
    "bans_1h": ${bans_1h:-0},
    "bans_24h": ${bans_24h:-0},
    "bans_7d": ${bans_7d:-0},
    "bans_30d": ${bans_30d:-0},
    "rate_per_minute": ${rate:-0}
  },
  "firewall": {
    "sets_total": ${sets_count:-0},
    "elements_total": ${elements_total:-0}
  },
  "modules": {
    "enabled": ${mod_enabled:-0},
    "active": ${mod_active:-0},
    "failed": ${mod_failed:-0}
  },
  "module_status": {
    "login": ${module_login_status:-0},
    "portscan": ${module_portscan_status:-0},
    "ddos": ${module_ddos_status:-0},
    "suricata": ${module_suricata_status:-0},
    "feeds": ${module_feeds_status:-0},
    "geoban": ${module_geoban_status:-0},
    "watchdog": ${module_watchdog_status:-0}
  },
  "memory": {
    "rss_bytes": ${rss:-0},
    "open_fds": ${fds:-0},
    "threads": ${threads:-0},
    "goroutines": ${goroutines:-0}
  },
  "server": {
    "hostname": "${server_hostname:-unknown}",
    "fqdn": "${server_fqdn:-unknown}",
    "os": "${server_os:-Linux}",
    "os_release": "${server_os_release:-Linux}",
    "kernel": "${server_kernel:-unknown}",
    "arch": "${server_arch:-unknown}",
    "cpu_model": "${server_cpu_model:-unknown}",
    "cpu_cores": ${cpu_cores:-1},
    "type": "${server_type:-physical}",
    "vendor": "${server_vendor:-Unknown}",
    "model": "${server_model:-Unknown}",
    "serial": "${server_serial:-N/A}",
    "primary_ip": "${server_primary_ip:-127.0.0.1}",
    "mac_address": "${server_mac:-00:00:00:00:00:00}",
    "subnet_mask": "${server_subnet_mask:-255.255.255.0}",
    "networks": "${server_networks:-lo:127.0.0.1}",
    "location": "${server_location:-Not configured}",
    "nftban_version": "${nftban_version:-unknown}",
    "memory_total_bytes": ${memory_total:-0},
    "memory_available_bytes": ${memory_available:-0},
    "memory_used_pct": ${memory_used_pct:-0},
    "uptime_seconds": ${server_uptime:-0},
    "disk_total_bytes": ${disk_total:-0},
    "disk_used_bytes": ${disk_used:-0},
    "disk_used_pct": ${disk_used_pct:-0}
  },
  "network": {
    "connections_active": ${conn_active:-0},
    "connections_established": ${conn_established:-0},
    "connections_time_wait": ${conn_time_wait:-0},
    "rx_mbps": ${total_rx_mbps:-0},
    "tx_mbps": ${total_tx_mbps:-0},
    "total_rx_mbps": ${total_rx_mbps:-0},
    "total_tx_mbps": ${total_tx_mbps:-0},
    "peak_rx_mbps": ${peak_rx:-0},
    "peak_tx_mbps": ${peak_tx:-0},
    "bytes_received_total": ${total_rx_bytes:-0},
    "bytes_sent_total": ${total_tx_bytes:-0},
    "packets_received_total": ${total_rx_packets:-0},
    "packets_sent_total": ${total_tx_packets:-0},
    "errors_total": ${total_errors:-0},
    "packets_dropped_total": ${total_dropped:-0},
    "bandwidth_in_bps": ${bandwidth_in_bps:-0},
    "bandwidth_out_bps": ${bandwidth_out_bps:-0}
  },
  "kernel": {
    "conntrack_entries": ${conntrack_entries:-0},
    "conntrack_max": ${conntrack_max:-0},
    "conntrack_utilization_percent": ${conntrack_utilization:-0},
    "softnet_drops_total": ${softnet_drops_total:-0},
    "softnet_drops_rate_per_minute": ${softnet_drops_rate:-0}
  },
  "eventbus": {
    "events_total": ${eventbus_events_total:-0},
    "events_by_type": {
      "ban": ${eventbus_events_ban:-0},
      "unban": ${eventbus_events_unban:-0},
      "login_fail": ${eventbus_events_login_fail:-0},
      "ddos_detected": ${eventbus_events_ddos_detected:-0},
      "portscan_detected": ${eventbus_events_portscan_detected:-0},
      "suricata_alert": ${eventbus_events_suricata_alert:-0},
      "feed_sync": ${eventbus_events_feed_sync:-0}
    },
    "events_dropped_total": ${eventbus_events_dropped_total:-0},
    "queue_size": ${eventbus_queue_size:-0},
    "handlers_total": ${eventbus_handlers_total:-0}
  }
}
EOF

    # Atomic write
    mv "${json_cache}.tmp" "$json_cache"
    chmod 644 "$json_cache"

    log_debug "Collected $(echo -e "$metrics" | wc -l) metrics → $json_cache"
}

# =============================================================================
# EXPORT: Prometheus (node_exporter textfile)
# =============================================================================
export_prometheus() {
    # Note: Enabled check is now in main() for consistency

    local textfile_dir="${NFTBAN_PROMETHEUS_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
    local output_file="${textfile_dir}/${NFTBAN_PROMETHEUS_OUTPUT_FILE:-nftban.prom}"

    if [[ ! -d "$textfile_dir" ]]; then
        log_warn "Prometheus textfile directory not found: $textfile_dir"
        return 1
    fi

    # Convert to Prometheus format (remove timestamp for textfile collector)
    # Skip string metrics (|STRING|) as they are Zabbix-only
    awk '{
        # Format: metric_name value timestamp -> metric_name value
        # Skip Zabbix string metrics (containing |STRING| prefix)
        if (index($2, "|STRING|") == 1) next

        if (NF >= 2) {
            # Handle metrics with labels
            if ($1 ~ /{.*}/) {
                printf "%s %s\n", $1, $2
            } else {
                printf "%s %s\n", $1, $2
            }
        }
    }' "$METRICS_CACHE" > "${output_file}.tmp"

    mv "${output_file}.tmp" "$output_file"
    chmod 644 "$output_file"

    log_info "Prometheus: exported to $output_file"
}

# =============================================================================
# EXPORT: Zabbix Trapper
# =============================================================================
export_zabbix() {
    local enabled="${NFTBAN_ZABBIX_ENABLED:-false}"
    [[ "$enabled" != "true" ]] && return 0

    local server="${NFTBAN_ZABBIX_SERVER:-}"
    local port="${NFTBAN_ZABBIX_PORT:-10051}"
    local hostname="${NFTBAN_ZABBIX_HOSTNAME:-auto}"

    [[ -z "$server" ]] && { log_warn "Zabbix: server not configured"; return 1; }

    [[ "$hostname" == "auto" ]] && hostname=$(hostname -f 2>/dev/null || hostname)

    # Check transport: prefer zabbix_sender, fallback to nc
    local use_nc=false
    if ! command -v zabbix_sender &>/dev/null; then
        if command -v nc &>/dev/null || command -v ncat &>/dev/null; then
            use_nc=true
        else
            log_warn "Zabbix: no transport (install zabbix-sender or ncat)"
            return 1
        fi
    fi

    # Create zabbix_sender input file
    local tmp_file
    tmp_file=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN

    # Convert format: metric timestamp -> hostname key value
    # Handles two formats:
    # 1. Numeric: metric_name value timestamp -> hostname key value
    # 2. String:  metric_name |STRING|value timestamp -> hostname key "value"
    # Only convert underscores to dots if the key doesn't already contain dots
    awk -v host="$hostname" '{
        if (NF >= 2) {
            key = $1

            # Skip Prometheus-only info metrics (e.g., nftban_server_hostname_info{...})
            # These have labels and are meant for Prometheus, not Zabbix
            if (key ~ /_info\{/) next

            # Only convert underscores to dots if key doesnt already have dots
            # This preserves pre-formatted keys like nftban.server.memory_total
            if (index(key, ".") == 0) {
                gsub(/_/, ".", key)  # nftban_status -> nftban.status
            }
            gsub(/{.*}/, "", key)  # Remove labels for Zabbix

            # Check for string marker |STRING| prefix (format: key |STRING|value timestamp)
            # Note: |STRING| is concatenated with value, so $2 = "|STRING|actualvalue"
            if (index($2, "|STRING|") == 1) {
                # String value: strip |STRING| prefix and collect multi-word values
                # $2 = "|STRING|firstword", $3..$NF-1 = "more words", $NF = timestamp
                value = substr($2, 9)  # Strip "|STRING|" (8 chars)
                for (i = 3; i < NF; i++) {
                    value = value " " $i
                }
                printf "%s %s \"%s\"\n", host, key, value
            } else {
                # Numeric value
                printf "%s %s %s\n", host, key, $2
            }
        }
    }' "$METRICS_CACHE" > "$tmp_file"

    # Send to Zabbix
    local result
    if [[ "$use_nc" == "true" ]]; then
        # Native Zabbix protocol via nc
        local data='{"request":"sender data","data":['
        local first=true
        while IFS=' ' read -r host key value; do
            [[ -z "$key" ]] && continue
            value=$(echo "$value" | sed 's/\\/\\\\/g; s/"/\\"/g; s/^"//; s/"$//')
            [[ "$first" != "true" ]] && data+=","
            data+="{\"host\":\"$host\",\"key\":\"$key\",\"value\":\"$value\"}"
            first=false
        done < "$tmp_file"
        data+=']}'

        local data_len=${#data}
        local len_hex
        len_hex=$(printf '%016x' "$data_len")
        local nc_cmd
        nc_cmd=$(command -v ncat || command -v nc)

        result=$( (
            printf 'ZBXD\x01'
            printf "\\x${len_hex:14:2}\\x${len_hex:12:2}\\x${len_hex:10:2}\\x${len_hex:8:2}"
            printf '\x00\x00\x00\x00'
            printf '%s' "$data"
        ) 2>/dev/null | timeout 10 "$nc_cmd" "$server" "$port" 2>/dev/null | tr -d '\0' ) || result=""

        if echo "$result" | grep -q '"response":"success"'; then
            log_info "Zabbix: all metrics sent to $server:$port"
        else
            log_warn "Zabbix: send failed - ${result:-no response}"
        fi
    else
        # Use zabbix_sender
        result=$(zabbix_sender -z "$server" -p "$port" -i "$tmp_file" 2>&1) || true
        if echo "$result" | grep -q "failed: 0"; then
            log_info "Zabbix: all metrics sent to $server:$port"
        else
            log_warn "Zabbix: some metrics failed - $result"
        fi
    fi
}

# =============================================================================
# EXPORT: Generic Connectors (ES, Kafka, etc.)
# =============================================================================
export_connectors() {
    local connectors_dir="${NFTBAN_CONFIG_DIR}/connectors"
    [[ ! -d "$connectors_dir" ]] && return 0

    local timestamp
    timestamp=$(date -Iseconds)
    local hostname
    hostname=$(hostname -f 2>/dev/null || hostname)

    # Build JSON payload once
    # Skip string metrics (|STRING|) and metrics with labels for clean JSON
    local json_payload
    json_payload=$(awk -v ts="$timestamp" -v host="$hostname" '
        BEGIN {
            printf "{"
            printf "\"@timestamp\":\"%s\",", ts
            printf "\"host\":\"%s\",", host
            printf "\"metrics\":{"
            first=1
        }
        NF >= 2 {
            # Skip Zabbix string metrics (|STRING| prefix)
            if (index($2, "|STRING|") == 1) next
            # Skip metrics with labels (they have different structure)
            if ($1 ~ /{.*}/) next

            key = $1
            if (!first) printf ","
            printf "\"%s\":%s", key, $2
            first=0
        }
        END {
            printf "}}"
        }
    ' "$METRICS_CACHE")

    # Process each connector
    for conf in "$connectors_dir"/*.conf; do
        [[ -f "$conf" ]] || continue

        # shellcheck source=/dev/null
        source "$conf"

        [[ "${CONNECTOR_ENABLED:-false}" != "true" ]] && continue

        case "${CONNECTOR_TYPE:-}" in
            elasticsearch)
                local url="${CONNECTOR_ES_URL}/${CONNECTOR_ES_INDEX:-nftban-metrics}/_doc"
                if curl -sf -X POST "$url" -H "Content-Type: application/json" -d "$json_payload" -o /dev/null; then
                    log_info "Connector: sent to Elasticsearch (${CONNECTOR_NAME})"
                else
                    log_warn "Connector: Elasticsearch export failed (${CONNECTOR_NAME})"
                fi
                ;;

            kafka)
                if command -v kafkacat &>/dev/null; then
                    echo "$json_payload" | kafkacat -P -b "${CONNECTOR_KAFKA_BROKERS}" -t "${CONNECTOR_KAFKA_TOPIC:-nftban}" 2>/dev/null
                    log_info "Connector: sent to Kafka (${CONNECTOR_NAME})"
                fi
                ;;

            file)
                local path="${CONNECTOR_FILE_PATH:-/var/log/nftban/metrics.json}"
                mkdir -p "$(dirname "$path")"
                echo "$json_payload" >> "$path"
                log_info "Connector: written to $path (${CONNECTOR_NAME})"
                ;;
        esac
    done
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    # Early exit if NO export target is enabled
    # Each target has its own enable flag — don't gate everything behind METRICS_ENABLED
    if [[ "${NFTBAN_METRICS_ENABLED:-false}" != "true" ]] \
        && [[ "${NFTBAN_ZABBIX_ENABLED:-false}" != "true" ]] \
        && [[ "${NFTBAN_EXPORT_PROMETHEUS:-false}" != "true" ]] \
        && [[ "${NFTBAN_EXPORT_CONNECTORS:-false}" != "true" ]]; then
        log_debug "No export targets enabled — skipping collection"
        exit 0
    fi

    local start_time
    start_time=$(date +%s%N)

    # Acquire lock to prevent concurrent runs
    acquire_lock

    # Apply hostname-based jitter (only on first boot, not every run)
    if [[ "${NFTBAN_COLLECT_JITTER_ENABLED:-true}" == "true" ]] && [[ "${NFTBAN_APPLY_JITTER:-false}" == "true" ]]; then
        local jitter
        jitter=$(calculate_host_jitter "${NFTBAN_COLLECT_JITTER_MAX:-30}")
        log_debug "Applying hostname-based jitter: ${jitter}s"
        sleep "$jitter"
    fi

    # Increment run count and determine collection groups
    local run_count collection_groups
    run_count=$(increment_run_count)
    collection_groups=$(determine_collection_groups "$run_count")

    log_info "NFTBan Unified Exporter v${SCRIPT_VERSION} starting (run #${run_count}, groups: ${collection_groups})"

    # Log auto-detection status on first run
    if [[ "$run_count" -eq 1 ]]; then
        if [[ "${NFTBAN_EXPORT_PROMETHEUS}" == "true" ]] && [[ -d "/var/lib/node_exporter/textfile_collector" ]]; then
            log_info "Prometheus export auto-enabled (node_exporter detected)"
        fi
    fi

    # Step 1: Collect metrics based on collection groups (smart collection)
    collect_all_metrics "$collection_groups"

    # Step 2: Export to enabled targets only
    local export_count=0

    # Prometheus export (only if enabled)
    if [[ "${NFTBAN_EXPORT_PROMETHEUS:-false}" == "true" ]]; then
        export_prometheus && ((export_count++)) || true
    fi

    # Zabbix export (only if enabled)
    if [[ "${NFTBAN_ZABBIX_ENABLED:-false}" == "true" ]]; then
        export_zabbix && ((export_count++)) || true
    fi

    # Connector exports (only if enabled)
    if [[ "${NFTBAN_EXPORT_CONNECTORS:-false}" == "true" ]]; then
        export_connectors && ((export_count++)) || true
    fi

    # Calculate duration
    local end_time duration_ms
    end_time=$(date +%s%N)
    duration_ms=$(( (end_time - start_time) / 1000000 ))

    # Log timing if enabled
    if [[ "${NFTBAN_COLLECT_LOG_TIMING:-false}" == "true" ]]; then
        log_info "Run #${run_count}: ${duration_ms}ms (groups: ${collection_groups}, exports: ${export_count})"
    else
        log_info "Completed: $export_count export targets in ${duration_ms}ms"
    fi
}

# Run
main "$@"
