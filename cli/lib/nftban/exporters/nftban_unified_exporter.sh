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
# meta:inventory.config_files="/etc/nftban/nftban.conf,/etc/nftban/conf.d/zabbix.conf,/etc/nftban/conf.d/connectors.conf"
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
readonly NFTBAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
readonly NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
readonly NFTBAN_RUN_DIR="${NFTBAN_RUN_DIR:-/run/nftban}"
readonly NFTBAN_LOG_DIR="${NFTBAN_LOG_DIR:-/var/log/nftban}"
readonly NFTBAN_CACHE_DIR="${NFTBAN_CACHE_DIR:-/var/cache/nftban}"

# Metrics cache file (collected once, used by all exporters)
readonly METRICS_CACHE="${NFTBAN_RUN_DIR}/metrics.cache"
readonly METRICS_LOCK="${NFTBAN_RUN_DIR}/exporter.lock"

# Load config
[[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR}/nftban.conf"

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
# LOCKING: Prevent concurrent runs
# =============================================================================
acquire_lock() {
    local lock_fd=200

    # Create lock file
    mkdir -p "$(dirname "$METRICS_LOCK")"
    eval "exec $lock_fd>$METRICS_LOCK"

    # Try to acquire lock (non-blocking)
    if ! flock -n $lock_fd; then
        log_warn "Another exporter instance is running, skipping"
        exit 0
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
log_debug() { [[ "${NFTBAN_DEBUG:-false}" == "true" ]] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] [DEBUG] $*"; }

# =============================================================================
# METRIC COLLECTION (Single collection for all targets)
# =============================================================================
collect_all_metrics() {
    log_debug "Collecting metrics..."

    local metrics=""
    local timestamp
    timestamp=$(date +%s)

    # --- Daemon Metrics ---
    local version pid status uptime mode
    version=$(cat "${NFTBAN_CONFIG_DIR}/../VERSION" 2>/dev/null | head -1 || echo "unknown")

    if systemctl is-active nftban.service &>/dev/null; then
        status=1
        pid=$(cat "${NFTBAN_RUN_DIR}/nftban.pid" 2>/dev/null || echo "0")
        local start_time
        start_time=$(systemctl show nftban.service -p ActiveEnterTimestamp --value 2>/dev/null || echo "")
        if [[ -n "$start_time" ]]; then
            local start_epoch
            start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo "$timestamp")
            uptime=$((timestamp - start_epoch))
        else
            uptime=0
        fi
    else
        status=0
        pid=0
        uptime=0
    fi
    local mode
    mode=$(cat "${NFTBAN_RUN_DIR}/mode" 2>/dev/null || echo "normal")

    metrics+="nftban_status $status $timestamp\n"
    metrics+="nftban_version_info{version=\"$version\"} 1 $timestamp\n"
    metrics+="nftban_mode_info{mode=\"$mode\"} 1 $timestamp\n"
    metrics+="nftban_uptime_seconds $uptime $timestamp\n"
    metrics+="nftban_pid $pid $timestamp\n"

    # --- Ban Metrics (fast nftables JSON API) ---
    local active_v4=0 active_v6=0
    if command -v nft &>/dev/null; then
        active_v4=$(nft -j list set inet nftban blacklist_ipv4 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
        active_v6=$(nft -j list set inet nftban blacklist_ipv6 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
    fi
    local active_total=$((active_v4 + active_v6))

    metrics+="nftban_active_bans_total $active_total $timestamp\n"
    metrics+="nftban_active_bans{family=\"ipv4\"} $active_v4 $timestamp\n"
    metrics+="nftban_active_bans{family=\"ipv6\"} $active_v6 $timestamp\n"

    # --- Time-based ban stats (from log) ---
    local bans_log="${NFTBAN_LOG_DIR}/bans.log"
    if [[ -f "$bans_log" ]]; then
        # Single awk pass for all time windows (efficient)
        local stats
        stats=$(awk -F'|' -v now="$timestamp" '
            $1 ~ /^[0-9]+$/ {
                age = now - $1
                if (age <= 3600)   h1++
                if (age <= 86400)  h24++
                if (age <= 300)    m5++
                total++
            }
            END {
                printf "%d %d %d %d\n", h1+0, h24+0, m5+0, total+0
            }
        ' "$bans_log" 2>/dev/null || echo "0 0 0 0")

        read -r bans_1h bans_24h bans_5m bans_total <<< "$stats"
        local rate
        rate=$(echo "scale=2; $bans_5m / 5" | bc 2>/dev/null || echo "0")

        metrics+="nftban_bans_1h $bans_1h $timestamp\n"
        metrics+="nftban_bans_24h $bans_24h $timestamp\n"
        metrics+="nftban_bans_total $bans_total $timestamp\n"
        metrics+="nftban_ban_rate_per_minute $rate $timestamp\n"
    fi

    # --- Memory Metrics ---
    if [[ -n "$pid" ]] && [[ "$pid" != "0" ]] && [[ -d "/proc/$pid" ]]; then
        local rss fds threads
        rss=$(awk '/VmRSS/ {print $2 * 1024}' "/proc/$pid/status" 2>/dev/null || echo "0")
        fds=$(ls -1 "/proc/$pid/fd" 2>/dev/null | wc -l || echo "0")
        threads=$(awk '/Threads/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")

        metrics+="nftban_memory_rss_bytes $rss $timestamp\n"
        metrics+="nftban_open_fds $fds $timestamp\n"
        metrics+="nftban_threads $threads $timestamp\n"
    fi

    # --- Module Metrics ---
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

    # --- nftables Metrics ---
    if command -v nft &>/dev/null; then
        local sets_count elements_total
        sets_count=$(nft list sets inet nftban 2>/dev/null | grep -c "set " || echo "0")
        elements_total=0
        for set_name in blacklist_ipv4 blacklist_ipv6 whitelist_ipv4 whitelist_ipv6; do
            local count
            count=$(nft -j list set inet nftban "$set_name" 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
            elements_total=$((elements_total + count))
        done

        metrics+="nftban_nft_sets_total $sets_count $timestamp\n"
        metrics+="nftban_nft_elements_total $elements_total $timestamp\n"
    fi

    # --- Feeds Metrics ---
    local feeds_enabled=0 feeds_loaded=0 feeds_failed=0 feeds_ips=0
    if [[ -d "${NFTBAN_CONFIG_DIR}/feeds" ]]; then
        for feed_file in "${NFTBAN_CONFIG_DIR}/feeds"/*.conf; do
            [[ -f "$feed_file" ]] || continue
            ((feeds_enabled++))
            local feed_name feed_data
            feed_name=$(basename "$feed_file" .conf)
            feed_data="${NFTBAN_CACHE_DIR}/feeds/${feed_name}.list"
            if [[ -f "$feed_data" ]]; then
                ((feeds_loaded++))
                feeds_ips=$((feeds_ips + $(wc -l < "$feed_data" 2>/dev/null || echo "0")))
            else
                ((feeds_failed++))
            fi
        done
    fi

    metrics+="nftban_feeds_enabled $feeds_enabled $timestamp\n"
    metrics+="nftban_feeds_loaded $feeds_loaded $timestamp\n"
    metrics+="nftban_feeds_failed $feeds_failed $timestamp\n"
    metrics+="nftban_feeds_ips_total $feeds_ips $timestamp\n"

    # --- Watchdog Metrics ---
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
        metrics+="nftban_watchdog_status 1 $timestamp\n"
    else
        metrics+="nftban_watchdog_status 0 $timestamp\n"
    fi

    # --- Server Info ---
    local load1 load5 load15 cpu_cores
    if [[ -f /proc/loadavg ]]; then
        read -r load1 load5 load15 _ < /proc/loadavg
        metrics+="nftban_server_load1 $load1 $timestamp\n"
        metrics+="nftban_server_load5 $load5 $timestamp\n"
        metrics+="nftban_server_load15 $load15 $timestamp\n"
    fi
    cpu_cores=$(nproc 2>/dev/null || echo "1")
    metrics+="nftban_server_cpu_cores $cpu_cores $timestamp\n"

    # Cache metrics
    mkdir -p "$(dirname "$METRICS_CACHE")"
    echo -e "$metrics" > "$METRICS_CACHE"

    log_debug "Collected $(echo -e "$metrics" | wc -l) metrics"
}

# =============================================================================
# EXPORT: Prometheus (node_exporter textfile)
# =============================================================================
export_prometheus() {
    local enabled="${NFTBAN_METRICS_ENABLED:-false}"
    [[ "$enabled" != "true" ]] && return 0

    local textfile_dir="/var/lib/node_exporter/textfile_collector"
    local output_file="${textfile_dir}/nftban.prom"

    if [[ ! -d "$textfile_dir" ]]; then
        log_warn "Prometheus textfile directory not found: $textfile_dir"
        return 1
    fi

    # Convert to Prometheus format (remove timestamp for textfile collector)
    awk '{
        # Format: metric_name value timestamp -> metric_name value
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

    if ! command -v zabbix_sender &>/dev/null; then
        log_warn "Zabbix: zabbix_sender not installed"
        return 1
    fi

    # Create zabbix_sender input file
    local tmp_file
    tmp_file=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" RETURN

    # Convert format: metric timestamp -> hostname key value
    awk -v host="$hostname" '{
        if (NF >= 2) {
            key = $1
            gsub(/_/, ".", key)  # nftban_status -> nftban.status
            gsub(/{.*}/, "", key)  # Remove labels for Zabbix
            printf "%s %s %s\n", host, key, $2
        }
    }' "$METRICS_CACHE" > "$tmp_file"

    # Send to Zabbix
    local result
    result=$(zabbix_sender -z "$server" -p "$port" -i "$tmp_file" 2>&1) || true

    if echo "$result" | grep -q "failed: 0"; then
        log_info "Zabbix: all metrics sent to $server:$port"
    else
        log_warn "Zabbix: some metrics failed - $result"
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
            key = $1
            gsub(/{.*}/, "", key)  # Remove labels
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
    local start_time
    start_time=$(date +%s%N)

    # Acquire lock to prevent concurrent runs
    acquire_lock

    # Apply hostname-based jitter (only on first boot, not every run)
    if [[ "${NFTBAN_APPLY_JITTER:-false}" == "true" ]]; then
        local jitter
        jitter=$(calculate_host_jitter 30)
        log_debug "Applying hostname-based jitter: ${jitter}s"
        sleep "$jitter"
    fi

    log_info "NFTBan Unified Exporter v${SCRIPT_VERSION} starting"

    # Step 1: Collect all metrics ONCE
    collect_all_metrics

    # Step 2: Export to all configured targets
    local export_count=0

    export_prometheus && ((export_count++)) || true
    export_zabbix && ((export_count++)) || true
    export_connectors && ((export_count++)) || true

    # Calculate duration
    local end_time duration_ms
    end_time=$(date +%s%N)
    duration_ms=$(( (end_time - start_time) / 1000000 ))

    log_info "Completed: $export_count export targets in ${duration_ms}ms"
}

# Run
main "$@"
