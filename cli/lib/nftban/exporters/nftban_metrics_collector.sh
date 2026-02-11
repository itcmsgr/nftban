#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_metrics_collector"
# meta:type="exporter"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Central metrics collector - collect once, export to any backend"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
#
# ARCHITECTURE:
#   This collector runs periodically and stores metrics in JSON format.
#   Backend exporters (Zabbix, Prometheus, InfluxDB) read from these files.
#
# OUTPUT FILES:
#   /var/cache/nftban/metrics/dynamic.json    - Updated every run (1m)
#   /var/cache/nftban/metrics/inventory.json  - Updated hourly
#   /var/cache/nftban/metrics/combined.json   - Both merged (for convenience)
#
# USAGE:
#   ./nftban_metrics_collector.sh              # Normal run
#   ./nftban_metrics_collector.sh --force      # Force inventory update
#   ./nftban_metrics_collector.sh --stdout     # Output to stdout instead of file
#
# =============================================================================

set -Eeuo pipefail

# Bootstrap paths
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_RUN_DIR:=/run/nftban}"
: "${NFTBAN_LOG_DIR:=/var/log/nftban}"
: "${NFTBAN_CACHE_DIR:=/var/cache/nftban}"

# Load config
[[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR}/nftban.conf"
[[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf.local" ]] && source "${NFTBAN_CONFIG_DIR}/nftban.conf.local" 2>/dev/null || true

# Source distro config for distribution-specific paths
# shellcheck source=/dev/null
[[ -f "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh" ]] && source "${NFTBAN_LIB_DIR}/lib/nftban_distro_config.sh"

# =============================================================================
# CONFIGURATION
# =============================================================================

METRICS_DIR="${NFTBAN_CACHE_DIR}/metrics"
DYNAMIC_FILE="${METRICS_DIR}/dynamic.json"
INVENTORY_FILE="${METRICS_DIR}/inventory.json"
COMBINED_FILE="${METRICS_DIR}/combined.json"
INVENTORY_INTERVAL=3600  # 1 hour
INVENTORY_STAMP="${METRICS_DIR}/.inventory_stamp"

# Service name from central config
DAEMON_SERVICE="${NFTBAN_SERVICE_DAEMON:-nftband.service}"

# Runtime options
FORCE_INVENTORY=false
OUTPUT_STDOUT=false
VERBOSE=false

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() { [[ "$VERBOSE" == "true" ]] && echo "[INFO] $*" >&2 || true; }
log_error() { echo "[ERROR] $*" >&2; }

init_metrics_dir() {
    mkdir -p "$METRICS_DIR" 2>/dev/null || true
    chmod 755 "$METRICS_DIR" 2>/dev/null || true
}

should_collect_inventory() {
    [[ "$FORCE_INVENTORY" == "true" ]] && return 0
    [[ ! -f "$INVENTORY_STAMP" ]] && return 0

    local last_run now age
    last_run=$(cat "$INVENTORY_STAMP" 2>/dev/null || echo "0")
    now=$(date +%s)
    age=$((now - last_run))

    [[ $age -ge $INVENTORY_INTERVAL ]]
}

update_inventory_stamp() {
    date +%s > "$INVENTORY_STAMP"
}

# =============================================================================
# METRIC COLLECTION FUNCTIONS
# =============================================================================

collect_daemon_metrics() {
    local status=0 uptime=0 pid=0 mode="unknown" version="unknown"

    # Version
    if [[ -n "${NFTBAN_VERSION:-}" ]]; then
        version="${NFTBAN_VERSION}"
    elif [[ -f "${NFTBAN_LIB_DIR}/VERSION" ]]; then
        version=$(cat "${NFTBAN_LIB_DIR}/VERSION" 2>/dev/null | tr -d '[:space:]')
    fi

    # Status
    if systemctl is-active "$DAEMON_SERVICE" &>/dev/null; then
        status=1

        # Uptime
        local start_time
        start_time=$(systemctl show "$DAEMON_SERVICE" -p ActiveEnterTimestamp --value 2>/dev/null || echo "")
        if [[ -n "$start_time" ]]; then
            local start_epoch now_epoch
            start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            uptime=$((now_epoch - start_epoch))
        fi

        # PID
        pid=$(systemctl show "$DAEMON_SERVICE" -p MainPID --value 2>/dev/null || echo "0")
    fi

    # Mode
    [[ -f "${NFTBAN_RUN_DIR}/mode" ]] && mode=$(cat "${NFTBAN_RUN_DIR}/mode" 2>/dev/null || echo "normal")
    [[ -z "$mode" ]] && mode="normal"

    cat <<EOF
{
  "daemon": {
    "status": $status,
    "version": "$version",
    "uptime": $uptime,
    "pid": $pid,
    "mode": "$mode"
  }
}
EOF
}

collect_ban_metrics() {
    local active=0 bans_24h=0 bans_1h=0 rate=0 total=0 permanent=0 whitelist=0

    # Active bans from nftables
    if command -v nft &>/dev/null; then
        local ipv4 ipv6
        ipv4=$(nft -j list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
        ipv6=$(nft -j list set ${NFTBAN_TABLE_IPV6} blacklist_ipv6 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
        active=$((ipv4 + ipv6))

        # Whitelist
        local wl4 wl6
        wl4=$(nft -j list set ${NFTBAN_TABLE_IPV4} whitelist_ipv4 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
        wl6=$(nft -j list set ${NFTBAN_TABLE_IPV6} whitelist_ipv6 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
        whitelist=$((wl4 + wl6))
    fi

    # Time-based stats from log
    local bans_log="${NFTBAN_LOG_DIR}/bans.log"
    if [[ -f "$bans_log" ]]; then
        local now bans_5m
        now=$(date +%s)
        bans_24h=$(awk -F'|' -v cutoff="$((now - 86400))" '$1 ~ /^[0-9]+$/ && $1 >= cutoff { count++ } END { print count+0 }' "$bans_log" 2>/dev/null || echo "0")
        bans_1h=$(awk -F'|' -v cutoff="$((now - 3600))" '$1 ~ /^[0-9]+$/ && $1 >= cutoff { count++ } END { print count+0 }' "$bans_log" 2>/dev/null || echo "0")
        bans_5m=$(awk -F'|' -v cutoff="$((now - 300))" '$1 ~ /^[0-9]+$/ && $1 >= cutoff { count++ } END { print count+0 }' "$bans_log" 2>/dev/null || echo "0")
        rate=$(echo "scale=2; $bans_5m / 5" | bc 2>/dev/null || echo "0")
        total=$(wc -l < "$bans_log" 2>/dev/null || echo "0")
    fi

    # Permanent bans
    [[ -f "${NFTBAN_CONFIG_DIR}/permanent.list" ]] && { permanent=$(grep -cE "^[0-9]" "${NFTBAN_CONFIG_DIR}/permanent.list" 2>/dev/null) || permanent=0; }

    cat <<EOF
{
  "bans": {
    "active": $active,
    "bans_24h": $bans_24h,
    "bans_1h": $bans_1h,
    "rate": $rate,
    "total": $total,
    "permanent": $permanent,
    "whitelist": $whitelist
  }
}
EOF
}

collect_memory_metrics() {
    local rss=0 fds=0 threads=0 goroutines=0

    local pid
    pid=$(systemctl show "$DAEMON_SERVICE" -p MainPID --value 2>/dev/null || echo "0")

    if [[ "$pid" != "0" ]] && [[ -d "/proc/$pid" ]]; then
        rss=$(awk '/VmRSS/ {print $2 * 1024}' "/proc/$pid/status" 2>/dev/null || echo "0")
        fds=$(ls -1 "/proc/$pid/fd" 2>/dev/null | wc -l) || fds=0
        threads=$(awk '/Threads/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")
    fi

    cat <<EOF
{
  "memory": {
    "rss": $rss,
    "fds": $fds,
    "threads": $threads,
    "goroutines": $goroutines
  }
}
EOF
}

collect_health_metrics() {
    local status=0 passed=0 failed=0
    local health_file="${NFTBAN_RUN_DIR}/health.status"

    if [[ -f "$health_file" ]]; then
        local healthy
        passed=$(jq -r '.passed // 0' "$health_file" 2>/dev/null || echo "0")
        failed=$(jq -r '.failed // 0' "$health_file" 2>/dev/null || echo "0")
        healthy=$(jq -r '.healthy // false' "$health_file" 2>/dev/null || echo "false")
        [[ "$healthy" == "true" ]] && status=1
    fi

    cat <<EOF
{
  "health": {
    "status": $status,
    "passed": $passed,
    "failed": $failed
  }
}
EOF
}

collect_module_metrics() {
    local enabled=0 active=0 failed=0

    for module in login portscan ddos feeds geoban suricata rbl botscan; do
        if [[ -f "${NFTBAN_CONFIG_DIR}/modules/${module}.conf" ]]; then
            ((enabled++))
            if systemctl is-active "nftban-${module}.timer" &>/dev/null 2>&1 || \
               systemctl is-active "nftban-${module}.service" &>/dev/null 2>&1; then
                ((active++))
            elif systemctl is-failed "nftban-${module}.service" &>/dev/null 2>&1; then
                ((failed++))
            fi
        fi
    done

    cat <<EOF
{
  "modules": {
    "enabled": $enabled,
    "active": $active,
    "failed": $failed
  }
}
EOF
}

collect_module_status_metrics() {
    # Per-module running status (1=up, 0=down)
    local suricata=0 loginmon=0 portscan=0 ddos=0 feeds=0 geoban=0 watchdog=0

    # suricata: Check if suricata.service is active OR if nftban has suricata module enabled
    if systemctl is-active "suricata.service" &>/dev/null || \
       [[ -f "${NFTBAN_CONFIG_DIR}/modules/suricata.conf" ]] && \
       systemctl is-active "nftban-suricata.timer" &>/dev/null; then
        suricata=1
    fi

    # loginmon: Check /run/nftban/loginmon.pid OR nftban-login.timer active
    if systemctl is-active "nftban-login.timer" &>/dev/null || \
       [[ -f "${NFTBAN_RUN_DIR}/loginmon.pid" ]]; then
        loginmon=1
    fi

    # portscan: Check /run/nftban/portscan.pid OR nftban-portscan.timer active
    if systemctl is-active "nftban-portscan.timer" &>/dev/null || \
       [[ -f "${NFTBAN_RUN_DIR}/portscan.pid" ]]; then
        portscan=1
    fi

    # ddos: Check /run/nftban/ddos.pid OR nftban-ddos.timer active
    if systemctl is-active "nftban-ddos.timer" &>/dev/null || \
       [[ -f "${NFTBAN_RUN_DIR}/ddos.pid" ]]; then
        ddos=1
    fi

    # feeds: Check nftban-feeds.timer active
    if systemctl is-active "nftban-feeds.timer" &>/dev/null; then
        feeds=1
    fi

    # geoban: Check /etc/nftban/modules/geoban.conf exists and enabled
    if [[ -f "${NFTBAN_CONFIG_DIR}/modules/geoban.conf" ]]; then
        # Check if enabled in config (NFTBAN_GEOBAN_ENABLED or similar)
        local geoban_enabled
        geoban_enabled=$(grep -E "^(NFTBAN_GEOBAN_ENABLED|ENABLED)=" "${NFTBAN_CONFIG_DIR}/modules/geoban.conf" 2>/dev/null | tail -1 | cut -d= -f2 | tr -d '"' || echo "")
        if [[ "$geoban_enabled" == "true" ]] || [[ "$geoban_enabled" == "1" ]] || [[ "$geoban_enabled" == "yes" ]]; then
            geoban=1
        fi
    fi

    # watchdog: Check /run/nftban/watchdog.pid exists OR nftband is in watchdog mode
    if [[ -f "${NFTBAN_RUN_DIR}/watchdog.pid" ]]; then
        watchdog=1
    elif [[ -f "${NFTBAN_RUN_DIR}/mode" ]]; then
        local mode
        mode=$(cat "${NFTBAN_RUN_DIR}/mode" 2>/dev/null || echo "")
        [[ "$mode" == "watchdog" ]] && watchdog=1
    fi

    cat <<EOF
{
  "module_status": {
    "suricata": $suricata,
    "loginmon": $loginmon,
    "portscan": $portscan,
    "ddos": $ddos,
    "feeds": $feeds,
    "geoban": $geoban,
    "watchdog": $watchdog
  }
}
EOF
}

collect_feed_health_metrics() {
    local total=0 active=0 stale=0 errors=0 last_sync=0
    local feeds_json=""
    local now
    now=$(date +%s)
    local stale_threshold=$((24 * 3600))  # 24 hours default

    # Collect all feed names and state files first
    local -a feed_names=()
    local -a state_files=()
    for conf in "${NFTBAN_CONFIG_DIR}/feeds"/*.conf; do
        [[ -f "$conf" ]] || continue
        local feed_name
        feed_name=$(basename "$conf" .conf)
        feed_names+=("$feed_name")
        state_files+=("/var/lib/nftban/feeds/${feed_name}.state")
        ((total++))
    done

    # Batch read all state files - extract both values in single jq call per file
    # Store results in associative arrays to avoid jq-per-iteration
    declare -A feed_sync_map feed_ips_map
    for i in "${!feed_names[@]}"; do
        local fname="${feed_names[$i]}"
        local sfile="${state_files[$i]}"
        if [[ -f "$sfile" ]]; then
            # Single jq call extracts both values at once using @tsv
            local state_values
            state_values=$(jq -r '[(.last_sync // 0), (.ips_loaded // 0)] | @tsv' "$sfile" 2>/dev/null || echo "0	0")
            IFS=$'\t' read -r feed_sync_map["$fname"] feed_ips_map["$fname"] <<< "$state_values"
        else
            feed_sync_map["$fname"]=0
            feed_ips_map["$fname"]=0
        fi
    done

    # Calculate active/stale counts and find max sync time
    for fname in "${feed_names[@]}"; do
        local feed_sync="${feed_sync_map[$fname]:-0}"
        [[ "$feed_sync" -gt "$last_sync" ]] && last_sync="$feed_sync"

        local feed_age=$((now - feed_sync))
        if [[ "$feed_sync" -gt 0 ]] && [[ "$feed_age" -lt "$stale_threshold" ]]; then
            ((active++))
        elif [[ "$feed_sync" -gt 0 ]]; then
            ((stale++))
        fi
    done

    # Count per-feed errors efficiently using single awk pass
    local feeds_log="${NFTBAN_LOG_DIR:-/var/log/nftban}/feeds.log"
    local cutoff=$((now - 86400))
    declare -A feed_errors_map

    if [[ -f "$feeds_log" ]] && [[ ${#feed_names[@]} -gt 0 ]]; then
        # Build pattern for all feed names
        local feed_pattern
        feed_pattern=$(printf '%s|' "${feed_names[@]}")
        feed_pattern="${feed_pattern%|}"  # Remove trailing |

        # Single awk pass counts errors for all feeds
        local error_counts
        error_counts=$(awk -F'|' -v cutoff="$cutoff" -v feeds="$feed_pattern" '
            BEGIN { split(feeds, f_arr, "|"); for (i in f_arr) feed_names[f_arr[i]] = 0 }
            $1 ~ /^[0-9]+$/ && $1 >= cutoff && /(ERROR|FAIL)/ {
                for (fn in feed_names) {
                    if (index($0, fn) > 0) feed_names[fn]++
                }
            }
            END {
                for (fn in feed_names) printf "%s:%d\n", fn, feed_names[fn]
            }
        ' "$feeds_log" 2>/dev/null || echo "")

        # Parse error counts into associative array
        while IFS=: read -r fname ferr; do
            [[ -n "$fname" ]] && feed_errors_map["$fname"]="$ferr"
        done <<< "$error_counts"
    fi

    # Build final per-feed JSON
    for fname in "${feed_names[@]}"; do
        local feed_sync="${feed_sync_map[$fname]:-0}"
        local feed_ips="${feed_ips_map[$fname]:-0}"
        local feed_errors="${feed_errors_map[$fname]:-0}"
        local feed_active=0

        local feed_age=$((now - feed_sync))
        if [[ "$feed_sync" -gt 0 ]] && [[ "$feed_age" -lt "$stale_threshold" ]]; then
            feed_active=1
        fi

        [[ -n "$feeds_json" ]] && feeds_json+=","
        feeds_json+="\"$fname\": {\"active\": $feed_active, \"last_sync\": $feed_sync, \"ips_loaded\": $feed_ips, \"errors\": $feed_errors}"
    done

    # Count total errors from log in last 24h (single awk pass)
    if [[ -f "$feeds_log" ]]; then
        errors=$(awk -v cutoff="$cutoff" '
            $1 ~ /^[0-9]+$/ && $1 >= cutoff && /(ERROR|FAIL)/ { count++ }
            END { print count+0 }
        ' "$feeds_log" 2>/dev/null || echo "0")
    fi

    cat <<EOF
{
  "feed_health": {
    "total_feeds": $total,
    "active_feeds": $active,
    "stale_feeds": $stale,
    "sync_errors_24h": $errors,
    "last_sync_timestamp": $last_sync,
    "feeds": {${feeds_json}}
  }
}
EOF
}

collect_suricata_metrics() {
    # Skip collection if Suricata integration is not enabled
    if [[ "${NFTBAN_SURICATA_ENABLED:-false}" != "true" ]]; then
        cat <<EOF
{
  "suricata": {
    "enabled": false
  }
}
EOF
        return 0
    fi

    local up=0 alerts_total=0 rules_total=0 rules_filtered=0 bans_total=0
    local eve_errors=0 last_alert=0 rule_profile="unknown"
    local sev1=0 sev2=0 sev3=0 sev4=0
    # shellcheck disable=SC2034  # categories reserved for future category breakdown
    declare -A categories

    # Performance metrics (for capacity planning and lessons learned)
    local memory_rss_mb=0 capture_kernel_packets=0 capture_kernel_drops=0
    local flow_memuse=0 tcp_memuse=0 memcap_pressure=0
    local ring_size=0 tpacket_version="unknown" capture_threads=0
    local uptime_seconds=0 decoder_bytes=0

    # Additional health/capacity metrics
    local decoder_pkts=0 decoder_invalid=0 flow_total=0 tcp_sessions=0
    local tcp_ssn_memcap_drop=0 tcp_segment_memcap_drop=0 flow_memcap_drops=0
    local flow_emerg_mode_entered=0 tcp_reassembly_gap=0
    local system_memory_available_mb=0 system_cpu_cores=0

    # Check if Suricata is running
    if systemctl is-active suricata.service &>/dev/null; then
        up=1

        # Collect performance metrics only when running
        # Memory RSS (MB)
        memory_rss_mb=$(ps aux 2>/dev/null | awk '/[S]uricata-Main/ {sum+=$6} END {printf "%.0f", sum/1024}') || memory_rss_mb=0
        [[ -z "$memory_rss_mb" || "$memory_rss_mb" == "0" ]] && \
            memory_rss_mb=$(ps aux 2>/dev/null | awk '/[s]uricata/ && !/grep/ {sum+=$6} END {printf "%.0f", sum/1024}') || memory_rss_mb=0

        # Capture threads (worker threads)
        capture_threads=$(ps -eLf 2>/dev/null | grep -c '[S]uricata.*W#') || capture_threads=0
        [[ "$capture_threads" -eq 0 ]] && capture_threads=$(nproc 2>/dev/null || echo 1)
    fi

    # EVE JSON parsing (last 10000 lines for performance)
    local eve_log="/var/log/suricata/eve.json"
    if [[ -f "$eve_log" ]]; then
        # Count alerts and group by severity
        local stats
        stats=$(tail -10000 "$eve_log" 2>/dev/null | jq -r '
            select(.event_type == "alert") | .alert.severity
        ' 2>/dev/null | sort | uniq -c || echo "")

        alerts_total=$(echo "$stats" | awk '{sum+=$1} END{print sum+0}')
        sev1=$(echo "$stats" | awk '$2==1 {print $1+0}')
        sev2=$(echo "$stats" | awk '$2==2 {print $1+0}')
        sev3=$(echo "$stats" | awk '$2==3 {print $1+0}')
        sev4=$(echo "$stats" | awk '$2==4 {print $1+0}')

        # Ensure severity values are not empty
        : "${sev1:=0}"
        : "${sev2:=0}"
        : "${sev3:=0}"
        : "${sev4:=0}"

        # Get alerts by category
        local cat_stats
        cat_stats=$(tail -10000 "$eve_log" 2>/dev/null | jq -r '
            select(.event_type == "alert") | .alert.category // "unknown"
        ' 2>/dev/null | sort | uniq -c | sort -rn | head -20 || echo "")

        # Build category JSON
        local category_json=""
        while read -r count cat; do
            [[ -z "$count" ]] && continue
            # Sanitize category name (replace spaces with underscores, lowercase)
            local safe_cat
            safe_cat=$(echo "$cat" | tr ' ' '_' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9_')
            [[ -z "$safe_cat" ]] && safe_cat="unknown"
            [[ -n "$category_json" ]] && category_json+=","
            category_json+="\"$safe_cat\": $count"
        done <<< "$cat_stats"
        [[ -z "$category_json" ]] && category_json=""

        # Last alert timestamp
        local last_ts
        last_ts=$(tail -1000 "$eve_log" 2>/dev/null | jq -r '
            select(.event_type == "alert") | .timestamp
        ' 2>/dev/null | tail -1)
        if [[ -n "$last_ts" ]]; then
            last_alert=$(date -d "$last_ts" +%s 2>/dev/null || echo "0")
        fi
    fi

    # Bans from suricata
    local bans_log="${NFTBAN_LOG_DIR}/bans.log"
    if [[ -f "$bans_log" ]]; then
        bans_total=$(grep -ci "suricata" "$bans_log" 2>/dev/null) || bans_total=0
    fi

    # Rule profile from config
    local suricata_conf="${NFTBAN_CONFIG_DIR}/modules/suricata.conf"
    if [[ -f "$suricata_conf" ]]; then
        rule_profile=$(grep -E "^NFTBAN_SURICATA_PROFILE=" "$suricata_conf" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "standard")
        [[ -z "$rule_profile" ]] && rule_profile="standard"

        # Get rules_filtered from config if available
        local filtered_count
        filtered_count=$(grep -E "^NFTBAN_SURICATA_RULES_FILTERED=" "$suricata_conf" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "0")
        [[ -n "$filtered_count" ]] && rules_filtered="$filtered_count"
    fi

    # Rules count (approximate from rules directory)
    local rules_dir="${DISTRO_PATHS[suricata_rules_dir]}"
    if [[ -d "$rules_dir" ]]; then
        rules_total=$(grep -rh "^alert\|^drop\|^reject" "$rules_dir"/*.rules 2>/dev/null | wc -l) || rules_total=0
    fi

    # EVE parse errors from nftban suricata log
    local suricata_log="${NFTBAN_LOG_DIR}/suricata.log"
    if [[ -f "$suricata_log" ]]; then
        eve_errors=$(grep -ci "parse.*error\|invalid.*json\|malformed" "$suricata_log" 2>/dev/null) || eve_errors=0
    fi

    # Performance metrics from stats.log (only if running)
    if [[ "$up" -eq 1 ]]; then
        local stats_log="/var/log/suricata/stats.log"
        # Find latest stats.log (may be rotated)
        if [[ ! -s "$stats_log" ]]; then
            stats_log=$(ls -t /var/log/suricata/stats.log* 2>/dev/null | head -1)
        fi

        if [[ -f "$stats_log" && -s "$stats_log" ]]; then
            # Get last stats block (tail -100 covers one full interval)
            local stats_block
            stats_block=$(tail -100 "$stats_log" 2>/dev/null)

            # Extract key metrics from last stats block
            capture_kernel_packets=$(echo "$stats_block" | awk '/capture.kernel_packets.*Total/ {v=$NF} END {print v+0}')
            capture_kernel_drops=$(echo "$stats_block" | awk '/capture.kernel_drops.*Total/ {v=$NF} END {print v+0}')
            decoder_bytes=$(echo "$stats_block" | awk '/decoder.bytes.*Total/ {v=$NF} END {print v+0}')
            decoder_pkts=$(echo "$stats_block" | awk '/decoder.pkts.*Total/ {v=$NF} END {print v+0}')
            decoder_invalid=$(echo "$stats_block" | awk '/decoder.invalid.*Total/ {v=$NF} END {print v+0}')
            flow_memuse=$(echo "$stats_block" | awk '/flow.memuse.*Total/ {v=$NF} END {print v+0}')
            flow_total=$(echo "$stats_block" | awk '/flow.total.*Total/ {v=$NF} END {print v+0}')
            tcp_memuse=$(echo "$stats_block" | awk '/tcp.memuse.*Total/ {v=$NF} END {print v+0}')
            tcp_sessions=$(echo "$stats_block" | awk '/tcp.sessions.*Total/ {v=$NF} END {print v+0}')
            tcp_reassembly_gap=$(echo "$stats_block" | awk '/tcp.reassembly_gap.*Total/ {v=$NF} END {print v+0}')
            memcap_pressure=$(echo "$stats_block" | awk '/memcap_pressure[^_].*Total/ {v=$NF} END {print v+0}')

            # Critical capacity drop indicators
            tcp_ssn_memcap_drop=$(echo "$stats_block" | awk '/tcp.ssn_memcap_drop.*Total/ {v=$NF} END {print v+0}')
            tcp_segment_memcap_drop=$(echo "$stats_block" | awk '/tcp.segment_memcap_drop.*Total/ {v=$NF} END {print v+0}')
            flow_memcap_drops=$(echo "$stats_block" | awk '/flow.memcap.*Total/ {v=$NF} END {print v+0}')
            flow_emerg_mode_entered=$(echo "$stats_block" | awk '/flow.emerg_mode_entered.*Total/ {v=$NF} END {print v+0}')

            # Parse uptime from stats header (format: uptime: 0d, 00h 03m 39s)
            local uptime_str
            uptime_str=$(echo "$stats_block" | grep -oP 'uptime: \K[^)]+' | tail -1)
            if [[ -n "$uptime_str" ]]; then
                local days hours mins secs
                days=$(echo "$uptime_str" | grep -oP '\d+(?=d)' || echo 0)
                hours=$(echo "$uptime_str" | grep -oP '\d+(?=h)' || echo 0)
                mins=$(echo "$uptime_str" | grep -oP '\d+(?=m)' || echo 0)
                secs=$(echo "$uptime_str" | grep -oP '\d+(?=s)' || echo 0)
                uptime_seconds=$(( (days*86400) + (hours*3600) + (mins*60) + secs ))
            fi
        fi

        # Ring size and tpacket version from suricata.yaml
        local suricata_yaml="/etc/suricata/suricata.yaml"
        if [[ -f "$suricata_yaml" ]]; then
            ring_size=$(grep -E '^\s+ring-size:' "$suricata_yaml" 2>/dev/null | head -1 | awk '{print $2}' | tr -cd '0-9')
            [[ -z "$ring_size" ]] && ring_size=0

            if grep -qE '^\s+tpacket-v3:\s*yes' "$suricata_yaml" 2>/dev/null; then
                tpacket_version="v3"
            else
                tpacket_version="v2"
            fi
        fi

        # System context metrics (for capacity planning)
        system_cpu_cores=$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
        system_memory_available_mb=$(awk '/MemAvailable/ {printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null || echo 0)
    fi

    cat <<EOF
{
  "suricata": {
    "enabled": true,
    "up": $up,
    "alerts_total": $alerts_total,
    "alerts_by_severity": {
      "1": ${sev1:-0},
      "2": ${sev2:-0},
      "3": ${sev3:-0},
      "4": ${sev4:-0}
    },
    "alerts_by_category": {${category_json}},
    "rules_total": $rules_total,
    "rules_filtered": $rules_filtered,
    "bans_total": $bans_total,
    "eve_parse_errors": $eve_errors,
    "last_alert_timestamp": $last_alert,
    "rule_profile": "$rule_profile",
    "performance": {
      "memory_rss_mb": ${memory_rss_mb:-0},
      "capture_kernel_packets": ${capture_kernel_packets:-0},
      "capture_kernel_drops": ${capture_kernel_drops:-0},
      "decoder_pkts": ${decoder_pkts:-0},
      "decoder_bytes": ${decoder_bytes:-0},
      "decoder_invalid": ${decoder_invalid:-0},
      "flow_total": ${flow_total:-0},
      "flow_memuse": ${flow_memuse:-0},
      "tcp_sessions": ${tcp_sessions:-0},
      "tcp_memuse": ${tcp_memuse:-0},
      "tcp_reassembly_gap": ${tcp_reassembly_gap:-0},
      "memcap_pressure": ${memcap_pressure:-0},
      "ring_size": ${ring_size:-0},
      "tpacket_version": "$tpacket_version",
      "capture_threads": ${capture_threads:-0},
      "uptime_seconds": ${uptime_seconds:-0}
    },
    "capacity_drops": {
      "tcp_ssn_memcap_drop": ${tcp_ssn_memcap_drop:-0},
      "tcp_segment_memcap_drop": ${tcp_segment_memcap_drop:-0},
      "flow_memcap_drops": ${flow_memcap_drops:-0},
      "flow_emerg_mode_entered": ${flow_emerg_mode_entered:-0}
    },
    "system": {
      "cpu_cores": ${system_cpu_cores:-0},
      "memory_available_mb": ${system_memory_available_mb:-0}
    }
  }
}
EOF
}

collect_eventbus_metrics() {
    local events_total=0 events_dropped=0 queue_size=0 handlers=7
    local ban=0 unban=0 login_fail=0 ddos=0 portscan=0 suricata=0 feed_sync=0

    local stats_file="${NFTBAN_RUN_DIR}/stats.json"
    local bans_log="${NFTBAN_LOG_DIR}/bans.log"

    # Try daemon stats first
    if [[ -f "$stats_file" ]]; then
        events_total=$(jq -r '.eventbus.events_total // 0' "$stats_file" 2>/dev/null || echo "0")
        events_dropped=$(jq -r '.eventbus.dropped // 0' "$stats_file" 2>/dev/null || echo "0")
        queue_size=$(jq -r '.eventbus.queue_size // 0' "$stats_file" 2>/dev/null || echo "0")
    fi

    # Count events by type from bans.log
    if [[ -f "$bans_log" ]]; then
        # Format: TIMESTAMP|SOURCE|IP|COUNTRY|ACTION
        ban=$(grep -c "|BAN$\||BAN|" "$bans_log" 2>/dev/null) || ban=0
        unban=$(grep -c "|UNBAN$\||UNBAN|" "$bans_log" 2>/dev/null) || unban=0
        login_fail=$(grep -ci "loginmon\|login\|ssh\|auth" "$bans_log" 2>/dev/null) || login_fail=0
        ddos=$(grep -ci "ddos" "$bans_log" 2>/dev/null) || ddos=0
        portscan=$(grep -ci "portscan\|scan" "$bans_log" 2>/dev/null) || portscan=0
        suricata=$(grep -ci "suricata" "$bans_log" 2>/dev/null) || suricata=0
        feed_sync=$(grep -ci "feed" "$bans_log" 2>/dev/null) || feed_sync=0

        # Estimate total if not from stats
        [[ "$events_total" -eq 0 ]] && events_total=$((ban + unban))
    fi

    # Count active handlers (modules)
    handlers=0
    for module in login portscan ddos feeds geoban suricata watchdog; do
        if systemctl is-active "nftban-${module}.timer" &>/dev/null 2>&1 || \
           systemctl is-active "nftban-${module}.service" &>/dev/null 2>&1 || \
           [[ -f "${NFTBAN_RUN_DIR}/${module}.pid" ]]; then
            ((handlers++))
        fi
    done

    cat <<EOF
{
  "eventbus": {
    "events_total": $events_total,
    "events_by_type": {
      "ban": $ban,
      "unban": $unban,
      "login_fail": $login_fail,
      "ddos_detected": $ddos,
      "portscan_detected": $portscan,
      "suricata_alert": $suricata,
      "feed_sync": $feed_sync
    },
    "events_dropped": $events_dropped,
    "queue_size": $queue_size,
    "handlers_total": $handlers
  }
}
EOF
}

collect_nftables_perf_metrics() {
    local apply_latency=0 apply_errors=0 rules_total=0 sets_total=0 commands_total=0
    # shellcheck disable=SC2034  # filter_rules, nat_rules reserved for extended rule counting
    local nftban_rules=0 filter_rules=0 nat_rules=0
    local bl_ipv4=0 bl_ipv6=0 wl_ipv4=0 wl_ipv6=0

    local stats_file="${NFTBAN_RUN_DIR}/stats.json"

    # Get latency/errors from daemon stats
    if [[ -f "$stats_file" ]]; then
        apply_latency=$(jq -r '.nftables.apply_latency_ms // 0' "$stats_file" 2>/dev/null || echo "0")
        apply_errors=$(jq -r '.nftables.apply_errors // 0' "$stats_file" 2>/dev/null || echo "0")
        commands_total=$(jq -r '.nftables.commands_total // 0' "$stats_file" 2>/dev/null || echo "0")
    fi

    # Count rules by table using nft
    if command -v nft &>/dev/null; then
        # Total rules (approximate - count lines with rule-like content)
        rules_total=$(nft list ruleset 2>/dev/null | grep -cE "^\s+(accept|drop|reject|counter|jump|goto|return)") || rules_total=0

        # Rules in nftban table
        nftban_rules=$(nft list table ${NFTBAN_TABLE_IPV4} 2>/dev/null | grep -cE "^\s+(accept|drop|reject|counter|jump|goto|return)") || nftban_rules=0

        # Sets count
        sets_total=$(nft list sets 2>/dev/null | grep -c "^\\s*set ") || sets_total=0

        # Set elements - use JSON output for accuracy
        bl_ipv4=$(nft -j list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
        bl_ipv6=$(nft -j list set ${NFTBAN_TABLE_IPV6} blacklist_ipv6 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
        wl_ipv4=$(nft -j list set ${NFTBAN_TABLE_IPV4} whitelist_ipv4 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
        wl_ipv6=$(nft -j list set ${NFTBAN_TABLE_IPV6} whitelist_ipv6 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
    fi

    cat <<EOF
{
  "nftables_perf": {
    "apply_latency_ms": $apply_latency,
    "apply_errors_total": $apply_errors,
    "rules_total": $rules_total,
    "rules_by_table": {
      "nftban": $nftban_rules
    },
    "sets_total": $sets_total,
    "set_elements": {
      "blacklist_ipv4": $bl_ipv4,
      "blacklist_ipv6": $bl_ipv6,
      "whitelist_ipv4": $wl_ipv4,
      "whitelist_ipv6": $wl_ipv6
    },
    "commands_total": $commands_total
  }
}
EOF
}

collect_ban_details_metrics() {
    local bans_by_source_manual=0 bans_by_source_feeds=0 bans_by_source_loginmon=0
    local bans_by_source_portscan=0 bans_by_source_ddos=0 bans_by_source_suricata=0 bans_by_source_geoban=0
    local escalations_total=0 persistent_total=0 recidivist_total=0
    local ban_failures=0 unban_failures=0

    local bans_log="${NFTBAN_LOG_DIR}/bans.log"
    local permanent_file="${NFTBAN_CONFIG_DIR}/permanent.list"

    if [[ -f "$bans_log" ]]; then
        # Count bans by source (SOURCE is typically column 2 or 3)
        bans_by_source_manual=$(grep -ci "|manual|" "$bans_log" 2>/dev/null) || bans_by_source_manual=0
        bans_by_source_feeds=$(grep -ci "|feed" "$bans_log" 2>/dev/null) || bans_by_source_feeds=0
        bans_by_source_loginmon=$(grep -ciE "|login|ssh|auth" "$bans_log" 2>/dev/null) || bans_by_source_loginmon=0
        bans_by_source_portscan=$(grep -ci "|portscan\||scan|" "$bans_log" 2>/dev/null) || bans_by_source_portscan=0
        bans_by_source_ddos=$(grep -ci "|ddos|" "$bans_log" 2>/dev/null) || bans_by_source_ddos=0
        bans_by_source_suricata=$(grep -ci "|suricata|" "$bans_log" 2>/dev/null) || bans_by_source_suricata=0
        bans_by_source_geoban=$(grep -ci "|geoban\||geo|" "$bans_log" 2>/dev/null) || bans_by_source_geoban=0

        # Count recidivists (IPs that appear multiple times)
        recidivist_total=$(awk -F'|' '{print $3}' "$bans_log" 2>/dev/null | sort | uniq -d | wc -l) || recidivist_total=0
    fi

    # Persistent/permanent bans
    if [[ -f "$permanent_file" ]]; then
        persistent_total=$(grep -cE "^[0-9]" "$permanent_file" 2>/dev/null) || persistent_total=0
    fi

    # Escalations from escalation log if exists
    local escalation_log="${NFTBAN_LOG_DIR}/escalations.log"
    if [[ -f "$escalation_log" ]]; then
        escalations_total=$(wc -l < "$escalation_log" 2>/dev/null || echo "0")
    fi

    cat <<EOF
{
  "ban_details": {
    "bans_by_source": {
      "manual": $bans_by_source_manual,
      "feeds": $bans_by_source_feeds,
      "loginmon": $bans_by_source_loginmon,
      "portscan": $bans_by_source_portscan,
      "ddos": $bans_by_source_ddos,
      "suricata": $bans_by_source_suricata,
      "geoban": $bans_by_source_geoban
    },
    "escalations_total": $escalations_total,
    "persistent_offenders_total": $persistent_total,
    "recidivist_ips_total": $recidivist_total,
    "ban_failures_total": $ban_failures,
    "unban_failures_total": $unban_failures
  }
}
EOF
}

collect_nftables_metrics() {
    local sets=0 elements=0 rules=0 packets_ipv4=0 packets_ipv6=0

    if command -v nft &>/dev/null && nft list table ${NFTBAN_TABLE_IPV4} &>/dev/null 2>&1; then
        sets=$(nft list sets ${NFTBAN_TABLE_IPV4} 2>/dev/null | grep -c "set ") || sets=0
        local sets6
        sets6=$(nft list sets ${NFTBAN_TABLE_IPV6} 2>/dev/null | grep -c "set ") || sets6=0
        sets=$((sets + sets6))

        for set_name in blacklist_ipv4 whitelist_ipv4; do
            local count
            count=$(nft -j list set ${NFTBAN_TABLE_IPV4} "$set_name" 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
            elements=$((elements + count))
        done
        for set_name in blacklist_ipv6 whitelist_ipv6; do
            local count
            count=$(nft -j list set ${NFTBAN_TABLE_IPV6} "$set_name" 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
            elements=$((elements + count))
        done

        rules=$(nft list table ${NFTBAN_TABLE_IPV4} 2>/dev/null | grep -cE "^\s+(accept|drop|reject|return|jump|goto)") || rules=0

        packets_ipv4=$(nft -j list chain ${NFTBAN_TABLE_IPV4} input 2>/dev/null | jq -r '[.nftables[]?.rule?.expr[]? | select(.counter) | .counter.packets] | add // 0' 2>/dev/null || echo "0")
        packets_ipv6=$(nft -j list chain ${NFTBAN_TABLE_IPV6} input6 2>/dev/null | jq -r '[.nftables[]?.rule?.expr[]? | select(.counter) | .counter.packets] | add // 0' 2>/dev/null || echo "0")
    fi

    cat <<EOF
{
  "nftables": {
    "sets": $sets,
    "elements": $elements,
    "rules": $rules,
    "packets_blocked_ipv4": $packets_ipv4,
    "packets_blocked_ipv6": $packets_ipv6
  }
}
EOF
}

collect_analytics_metrics() {
    local unique_ips_24h=0 recidivism_rate=0 top_attackers=0
    local mode_transitions=0 alerts_active_info=0 alerts_active_warn=0 alerts_active_crit=0
    # shellcheck disable=SC2034  # geoban_blocks reserved for geoban analytics
    local geoban_blocks=0 geoban_db_age=0

    local bans_log="${NFTBAN_LOG_DIR}/bans.log"
    local stats_file="${NFTBAN_RUN_DIR}/stats.json"

    # Find GeoIP database (DBIP or GeoLite2)
    local geoip_db=""
    for path in "/var/lib/nftban/geoip/dbip-country-lite.mmdb" \
                "/var/lib/nftban/geoip/GeoLite2-Country.mmdb" \
                "/usr/share/GeoIP/dbip-country-lite.mmdb" \
                "/usr/share/GeoIP/GeoLite2-Country.mmdb"; do
        [[ -f "$path" ]] && { geoip_db="$path"; break; }
    done

    # Unique IPs in last 24h
    if [[ -f "$bans_log" ]]; then
        local now cutoff
        now=$(date +%s)
        cutoff=$((now - 86400))
        unique_ips_24h=$(awk -F'|' -v cutoff="$cutoff" '$1 ~ /^[0-9]+$/ && $1 >= cutoff {print $3}' "$bans_log" 2>/dev/null | sort -u | wc -l) || unique_ips_24h=0

        # Recidivism rate (IPs banned >1 time / total unique IPs * 100)
        local total_unique repeat_ips
        total_unique=$(awk -F'|' '{print $3}' "$bans_log" 2>/dev/null | sort -u | wc -l) || total_unique=1
        repeat_ips=$(awk -F'|' '{print $3}' "$bans_log" 2>/dev/null | sort | uniq -d | wc -l) || repeat_ips=0
        [[ "$total_unique" -gt 0 ]] && recidivism_rate=$(echo "scale=2; $repeat_ips / $total_unique * 100" | bc 2>/dev/null || echo "0")

        # Top attackers (IPs with >5 bans)
        top_attackers=$(awk -F'|' '{print $3}' "$bans_log" 2>/dev/null | sort | uniq -c | awk '$1 > 5' | wc -l) || top_attackers=0
    fi

    # Watchdog mode transitions from stats
    if [[ -f "$stats_file" ]]; then
        mode_transitions=$(jq -r '.watchdog.mode_transitions // 0' "$stats_file" 2>/dev/null || echo "0")
        alerts_active_info=$(jq -r '.alerts.active.info // 0' "$stats_file" 2>/dev/null || echo "0")
        alerts_active_warn=$(jq -r '.alerts.active.warning // 0' "$stats_file" 2>/dev/null || echo "0")
        alerts_active_crit=$(jq -r '.alerts.active.critical // 0' "$stats_file" 2>/dev/null || echo "0")
    fi

    # GeoIP database age
    if [[ -f "$geoip_db" ]]; then
        local db_mtime
        db_mtime=$(stat -c %Y "$geoip_db" 2>/dev/null || echo "0")
        geoban_db_age=$(($(date +%s) - db_mtime))
    fi

    cat <<EOF
{
  "analytics": {
    "unique_ips_24h": $unique_ips_24h,
    "recidivism_rate": $recidivism_rate,
    "top_attackers_total": $top_attackers,
    "watchdog_mode_transitions_total": $mode_transitions,
    "alerts_active": {
      "info": $alerts_active_info,
      "warning": $alerts_active_warn,
      "critical": $alerts_active_crit
    },
    "geoban_database_age_seconds": $geoban_db_age
  }
}
EOF
}

collect_feeds_metrics() {
    local enabled=0 loaded=0 failed=0 ips_total=0

    if [[ -d "${NFTBAN_CONFIG_DIR}/feeds" ]]; then
        for feed_file in "${NFTBAN_CONFIG_DIR}/feeds"/*.conf; do
            [[ -f "$feed_file" ]] || continue
            ((enabled++))

            local feed_name feed_data count
            feed_name=$(basename "$feed_file" .conf)
            feed_data="${NFTBAN_CACHE_DIR}/feeds/${feed_name}.list"

            if [[ -f "$feed_data" ]]; then
                ((loaded++))
                count=$(wc -l < "$feed_data" 2>/dev/null || echo "0")
                ips_total=$((ips_total + count))
            else
                ((failed++))
            fi
        done
    fi

    cat <<EOF
{
  "feeds": {
    "enabled": $enabled,
    "loaded": $loaded,
    "failed": $failed,
    "ips_total": $ips_total
  }
}
EOF
}

collect_network_metrics() {
    # Network bandwidth and connection metrics
    local interfaces_json="[]"
    local connections_active=0 connections_established=0 connections_time_wait=0 connections_close_wait=0

    # Per-interface stats
    local iface_array=""
    for iface_path in /sys/class/net/*; do
        [[ -d "$iface_path" ]] || continue
        local iface
        iface=$(basename "$iface_path")
        [[ "$iface" == "lo" ]] && continue
        local rx_bytes tx_bytes rx_packets tx_packets
        rx_bytes=$(cat /sys/class/net/$iface/statistics/rx_bytes 2>/dev/null || echo "0")
        tx_bytes=$(cat /sys/class/net/$iface/statistics/tx_bytes 2>/dev/null || echo "0")
        rx_packets=$(cat /sys/class/net/$iface/statistics/rx_packets 2>/dev/null || echo "0")
        tx_packets=$(cat /sys/class/net/$iface/statistics/tx_packets 2>/dev/null || echo "0")

        [[ -n "$iface_array" ]] && iface_array+=","
        iface_array+="{\"name\":\"$iface\",\"rx_bytes\":$rx_bytes,\"tx_bytes\":$tx_bytes,\"rx_packets\":$rx_packets,\"tx_packets\":$tx_packets}"
    done
    interfaces_json="[$iface_array]"

    # Connection stats from ss/netstat
    if command -v ss &>/dev/null; then
        connections_active=$(ss -s 2>/dev/null | awk '/^TCP:/{print $2}' || echo "0")
        connections_established=$(ss -t state established 2>/dev/null | wc -l) || connections_established=0
        connections_time_wait=$(ss -t state time-wait 2>/dev/null | wc -l) || connections_time_wait=0
        connections_close_wait=$(ss -t state close-wait 2>/dev/null | wc -l) || connections_close_wait=0
    fi

    cat <<EOF
{
  "network": {
    "interfaces": $interfaces_json,
    "connections": {
      "active": $connections_active,
      "established": $connections_established,
      "time_wait": $connections_time_wait,
      "close_wait": $connections_close_wait
    }
  }
}
EOF
}

collect_watchdog_metrics() {
    # Get comprehensive metrics from nftban watchdog commands
    local daemon_json="" system_json=""

    # Try to get daemon stats via IPC (nftban watchdog stats --json)
    if command -v nftban &>/dev/null; then
        daemon_json=$(nftban watchdog stats --json 2>/dev/null | grep -A100 "^{" | head -50)
        system_json=$(nftban watchdog check --json 2>/dev/null | grep -A100 "^{" | head -30)
    fi

    # Default values
    local goroutines=0 heap_mb=0 alloc_mb=0 sys_mb=0 gc_cycles=0 gc_pause_ms=0
    local bans_total=0 unbans_total=0 events_total=0 bans_per_min=0
    local ipc_requests=0 ipc_latency_ms=0 ipc_errors=0
    local wd_status=0 wd_mode="unknown" wd_cpu_score=0 wd_mem_score=0 wd_io_score=0
    local daemon_mode="unknown" server_region="unknown"
    local load_1m=0 load_5m=0 load_15m=0
    local mem_used_pct=0 mem_available_mb=0
    local iowait_pct=0 disk_used_pct=0

    # Parse daemon stats with single jq call (extracts all 19 values at once)
    # Previously: 19 separate jq calls = 19 process spawns
    # Now: 1 jq call with @tsv output
    if [[ -n "$daemon_json" ]] && echo "$daemon_json" | jq -e . &>/dev/null; then
        local daemon_values
        daemon_values=$(echo "$daemon_json" | jq -r '
            [
                (.runtime.goroutines // 0),
                (.runtime.memory_heap_mb // 0),
                (.runtime.memory_alloc_mb // 0),
                (.runtime.memory_sys_mb // 0),
                (.runtime.gc_cycles // 0),
                (.runtime.gc_pause_ms // 0),
                (.throughput.bans_total // 0),
                (.throughput.unbans_total // 0),
                (.throughput.events_total // 0),
                (.throughput.bans_per_min // 0),
                (.ipc.requests_total // 0),
                (.ipc.avg_latency_ms // 0),
                (.ipc.errors_total // 0),
                (.watchdog.status // 0),
                (.watchdog.mode // "unknown"),
                (.watchdog.cpu_score // 0),
                (.watchdog.mem_score // 0),
                (.watchdog.io_score // 0),
                (.daemon.mode // "unknown"),
                (.server.region // "unknown")
            ] | @tsv
        ' 2>/dev/null)

        if [[ -n "$daemon_values" ]]; then
            IFS=$'\t' read -r goroutines heap_mb alloc_mb sys_mb gc_cycles gc_pause_ms \
                bans_total unbans_total events_total bans_per_min \
                ipc_requests ipc_latency_ms ipc_errors \
                wd_status wd_mode wd_cpu_score wd_mem_score wd_io_score \
                daemon_mode server_region <<< "$daemon_values"
        fi
    fi

    # Parse system check with single jq call (extracts all 7 values at once)
    # Previously: 7 separate jq calls = 7 process spawns
    # Now: 1 jq call with @tsv output
    if [[ -n "$system_json" ]] && echo "$system_json" | jq -e . &>/dev/null; then
        local system_values
        system_values=$(echo "$system_json" | jq -r '
            [
                (.load["1m"] // 0),
                (.load["5m"] // 0),
                (.load["15m"] // 0),
                (.memory.used_percent // 0),
                (.memory.available_mb // 0),
                (.iowait.percent // 0),
                (.disk.used_percent // 0)
            ] | @tsv
        ' 2>/dev/null)

        if [[ -n "$system_values" ]]; then
            IFS=$'\t' read -r load_1m load_5m load_15m mem_used_pct mem_available_mb iowait_pct disk_used_pct <<< "$system_values"
        fi
    else
        # Fallback to /proc if watchdog not available
        [[ -f /proc/loadavg ]] && read -r load_1m load_5m load_15m _ < /proc/loadavg
    fi

    cat <<EOF
{
  "runtime": {
    "goroutines": $goroutines,
    "heap_mb": $heap_mb,
    "alloc_mb": $alloc_mb,
    "sys_mb": $sys_mb,
    "gc_cycles": $gc_cycles,
    "gc_pause_ms": $gc_pause_ms
  },
  "throughput": {
    "bans_total": $bans_total,
    "unbans_total": $unbans_total,
    "events_total": $events_total,
    "bans_per_min": $bans_per_min
  },
  "ipc": {
    "requests_total": $ipc_requests,
    "avg_latency_ms": $ipc_latency_ms,
    "errors_total": $ipc_errors
  },
  "watchdog": {
    "status": $wd_status,
    "mode": "$wd_mode",
    "cpu_score": $wd_cpu_score,
    "mem_score": $wd_mem_score,
    "io_score": $wd_io_score
  },
  "daemon_mode": "$daemon_mode",
  "server_region": "$server_region",
  "system": {
    "load_1m": $load_1m,
    "load_5m": $load_5m,
    "load_15m": $load_15m,
    "mem_used_percent": $mem_used_pct,
    "mem_available_mb": $mem_available_mb,
    "iowait_percent": $iowait_pct,
    "disk_used_percent": $disk_used_pct
  }
}
EOF
}

collect_geoip_metrics() {
    local database_age=0 countries_blocked=0

    # Find GeoIP database (DBIP or GeoLite2)
    local db_path=""
    for path in "/var/lib/nftban/geoip/dbip-country-lite.mmdb" \
                "/var/lib/nftban/geoip/GeoLite2-Country.mmdb" \
                "/usr/share/GeoIP/dbip-country-lite.mmdb" \
                "/usr/share/GeoIP/GeoLite2-Country.mmdb" \
                "${NFTBAN_LIB_DIR}/data/dbip-country-lite.mmdb" \
                "${NFTBAN_LIB_DIR}/data/GeoLite2-Country.mmdb"; do
        [[ -f "$path" ]] && { db_path="$path"; break; }
    done

    if [[ -n "$db_path" ]]; then
        local db_mtime now
        db_mtime=$(stat -c %Y "$db_path" 2>/dev/null || echo "0")
        now=$(date +%s)
        database_age=$(( (now - db_mtime) / 86400 ))

        if [[ -f "${NFTBAN_CONFIG_DIR}/modules/geoban.conf" ]]; then
            source "${NFTBAN_CONFIG_DIR}/modules/geoban.conf" 2>/dev/null || true
            countries_blocked=$(echo "${NFTBAN_GEOBAN_COUNTRIES:-}" | wc -w 2>/dev/null || echo "0")
        fi
    fi

    cat <<EOF
{
  "geoip": {
    "database_age": $database_age,
    "countries_blocked": $countries_blocked
  }
}
EOF
}

collect_kernel_metrics() {
    # Kernel/conntrack metrics for network stack health monitoring
    local conntrack_entries=0 conntrack_max=0 conntrack_utilization=0
    local softnet_drops=0 softnet_backlog=0

    # Conntrack entries (current count)
    if [[ -f /proc/sys/net/netfilter/nf_conntrack_count ]]; then
        conntrack_entries=$(cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null || echo "0")
    fi

    # Conntrack max (configured limit)
    if [[ -f /proc/sys/net/netfilter/nf_conntrack_max ]]; then
        conntrack_max=$(cat /proc/sys/net/netfilter/nf_conntrack_max 2>/dev/null || echo "0")
    fi

    # Calculate utilization percentage
    if [[ "$conntrack_max" -gt 0 ]]; then
        conntrack_utilization=$(awk "BEGIN {printf \"%.2f\", ($conntrack_entries / $conntrack_max) * 100}")
    fi

    # Softnet stats from /proc/net/softnet_stat
    # Format: column 1=processed, column 2=dropped, column 3=time_squeeze (backlog)
    # Values are hex, one line per CPU
    if [[ -f /proc/net/softnet_stat ]]; then
        softnet_drops=$(awk '{sum += strtonum("0x"$2)} END {print sum+0}' /proc/net/softnet_stat 2>/dev/null || echo "0")
        softnet_backlog=$(awk '{sum += strtonum("0x"$3)} END {print sum+0}' /proc/net/softnet_stat 2>/dev/null || echo "0")
    fi

    cat <<EOF
{
  "kernel": {
    "conntrack_entries": $conntrack_entries,
    "conntrack_max": $conntrack_max,
    "conntrack_utilization": $conntrack_utilization,
    "softnet_drops": $softnet_drops,
    "softnet_backlog": $softnet_backlog
  }
}
EOF
}

# =============================================================================
# INVENTORY COLLECTION (Static data - collected hourly)
# =============================================================================

collect_server_inventory() {
    local hostname fqdn os os_release kernel arch
    local cpu_cores cpu_model memory_total
    local primary_ip ipv6 mac_address subnet_mask gateway
    local interfaces networks timezone virtualization cloud_provider

    # Basic info
    hostname=$(hostname -s 2>/dev/null || hostname)
    fqdn=$(hostname -f 2>/dev/null || hostname)

    # OS info
    if [[ -f /etc/os-release ]]; then
        source /etc/os-release
        os="${ID:-unknown}"
        os_release="${PRETTY_NAME:-unknown}"
    fi
    kernel=$(uname -r)
    arch=$(uname -m)

    # CPU
    cpu_cores=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")
    cpu_model=$(grep "model name" /proc/cpuinfo 2>/dev/null | head -1 | cut -d: -f2 | xargs || echo "unknown")

    # Memory
    memory_total=$(awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo "0")

    # Network
    local primary_iface
    primary_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || echo "127.0.0.1")
    primary_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}' || echo "eth0")
    ipv6=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2; exit}' | cut -d'/' -f1 || echo "")
    mac_address=$(ip link show "$primary_iface" 2>/dev/null | awk '/ether/{print $2}' || echo "")
    gateway=$(ip route show default 2>/dev/null | awk '{print $3; exit}' || echo "")

    # Subnet mask
    local cidr
    cidr=$(ip -4 addr show "$primary_iface" 2>/dev/null | awk '/inet/{print $2}' | cut -d'/' -f2 | head -1)
    case "$cidr" in
        8)  subnet_mask="255.0.0.0" ;;
        16) subnet_mask="255.255.0.0" ;;
        24) subnet_mask="255.255.255.0" ;;
        *)  subnet_mask="/${cidr:-32}" ;;
    esac

    # Interfaces
    interfaces=$(ip -j link show 2>/dev/null | jq -c '[.[].ifname]' 2>/dev/null || echo '[]')
    networks=$(ip -j addr show 2>/dev/null | jq -c '[.[] | select(.ifname != "lo") | {iface: .ifname, mac: .address, ips: [.addr_info[]? | select(.family == "inet" or .family == "inet6") | {ip: .local, prefix: .prefixlen, family: .family}]}]' 2>/dev/null || echo '[]')

    # System
    timezone=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "UTC")

    # Virtualization
    virtualization="none"
    if grep -q "^flags.*hypervisor" /proc/cpuinfo 2>/dev/null; then
        virtualization="vm"
        grep -qi "kvm" /sys/class/dmi/id/product_name 2>/dev/null && virtualization="kvm"
        grep -qi "vmware" /sys/class/dmi/id/sys_vendor 2>/dev/null && virtualization="vmware"
    fi
    [[ -f /.dockerenv ]] && virtualization="docker"

    # Cloud provider
    cloud_provider="none"
    curl -s -m 1 http://169.254.169.254/latest/meta-data/ &>/dev/null && cloud_provider="aws"
    curl -s -m 1 -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/ &>/dev/null && cloud_provider="gcp"

    # Public IP (with timeout)
    local public_ip=""
    public_ip=$(curl -4 -s -m 2 https://api.ipify.org 2>/dev/null || echo "")
    [[ ! "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && public_ip=""

    # Boot time & uptime
    local boot_time server_uptime
    boot_time=$(awk '{print int(systime() - $1)}' /proc/uptime 2>/dev/null | xargs -I{} date -d "@{}" +%s 2>/dev/null || echo "0")
    boot_time=$(( $(date +%s) - $(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0") ))
    server_uptime=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")

    cat <<EOF
{
  "server": {
    "hostname": "$hostname",
    "fqdn": "$fqdn",
    "os": "$os",
    "os_release": "$os_release",
    "kernel": "$kernel",
    "arch": "$arch",
    "cpu_cores": $cpu_cores,
    "cpu_model": "$cpu_model",
    "memory_total": $memory_total,
    "primary_ip": "$primary_ip",
    "ipv6": "$ipv6",
    "mac_address": "$mac_address",
    "subnet_mask": "$subnet_mask",
    "gateway": "$gateway",
    "public_ip": "$public_ip",
    "interfaces": $interfaces,
    "networks": $networks,
    "timezone": "$timezone",
    "virtualization": "$virtualization",
    "cloud_provider": "$cloud_provider",
    "boot_time": $boot_time,
    "uptime": $server_uptime
  }
}
EOF
}

# =============================================================================
# MAIN COLLECTION & OUTPUT
# =============================================================================

collect_dynamic_metrics() {
    # Collect all dynamic metrics and merge into single JSON
    local timestamp daemon bans memory health modules module_status feed_health suricata eventbus nftables_perf ban_details nftables analytics feeds network watchdog geoip kernel
    timestamp=$(date +%s)

    daemon=$(collect_daemon_metrics)
    bans=$(collect_ban_metrics)
    memory=$(collect_memory_metrics)
    health=$(collect_health_metrics)
    modules=$(collect_module_metrics)
    module_status=$(collect_module_status_metrics)
    feed_health=$(collect_feed_health_metrics)
    suricata=$(collect_suricata_metrics)
    eventbus=$(collect_eventbus_metrics)
    nftables_perf=$(collect_nftables_perf_metrics)
    ban_details=$(collect_ban_details_metrics)
    nftables=$(collect_nftables_metrics)
    analytics=$(collect_analytics_metrics)
    feeds=$(collect_feeds_metrics)
    network=$(collect_network_metrics)
    watchdog=$(collect_watchdog_metrics)
    geoip=$(collect_geoip_metrics)
    kernel=$(collect_kernel_metrics)

    # Merge all JSON objects
    echo "$daemon $bans $memory $health $modules $module_status $feed_health $suricata $eventbus $nftables_perf $ban_details $nftables $analytics $feeds $network $watchdog $geoip $kernel" | \
        jq -s 'add | . + {"timestamp": '"$timestamp"', "type": "dynamic"}'
}

collect_inventory_metrics() {
    local timestamp server
    timestamp=$(date +%s)
    server=$(collect_server_inventory)

    echo "$server" | jq '. + {"timestamp": '"$timestamp"', "type": "inventory"}'
}

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --force)    FORCE_INVENTORY=true; shift ;;
            --stdout)   OUTPUT_STDOUT=true; shift ;;
            --verbose)  VERBOSE=true; shift ;;
            --help|-h)
                echo "NFTBan Central Metrics Collector"
                echo ""
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --force    Force inventory collection (bypass hourly limit)"
                echo "  --stdout   Output to stdout instead of files"
                echo "  --verbose  Show progress messages"
                echo ""
                echo "Output files:"
                echo "  ${DYNAMIC_FILE}    - Dynamic metrics (every run)"
                echo "  ${INVENTORY_FILE}  - Inventory metrics (hourly)"
                echo "  ${COMBINED_FILE}   - Combined (for convenience)"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    init_metrics_dir

    # Collect dynamic metrics (always)
    log_info "Collecting dynamic metrics..."
    local dynamic_json
    dynamic_json=$(collect_dynamic_metrics)

    # Collect inventory (hourly)
    local inventory_json=""
    if should_collect_inventory; then
        log_info "Collecting inventory metrics..."
        inventory_json=$(collect_inventory_metrics)
        update_inventory_stamp
    else
        log_info "Using cached inventory (< ${INVENTORY_INTERVAL}s old)"
        [[ -f "$INVENTORY_FILE" ]] && inventory_json=$(cat "$INVENTORY_FILE")
    fi

    # Output
    if [[ "$OUTPUT_STDOUT" == "true" ]]; then
        # Merge and output to stdout
        if [[ -n "$inventory_json" ]]; then
            echo "$dynamic_json" "$inventory_json" | jq -s 'add'
        else
            echo "$dynamic_json"
        fi
    else
        # Write to files
        echo "$dynamic_json" > "$DYNAMIC_FILE"
        [[ -n "$inventory_json" ]] && echo "$inventory_json" > "$INVENTORY_FILE"

        # Create combined file
        if [[ -f "$INVENTORY_FILE" ]]; then
            jq -s 'add' "$DYNAMIC_FILE" "$INVENTORY_FILE" > "$COMBINED_FILE"
        else
            cp "$DYNAMIC_FILE" "$COMBINED_FILE"
        fi

        log_info "Metrics written to $METRICS_DIR/"
    fi
}

main "$@"
