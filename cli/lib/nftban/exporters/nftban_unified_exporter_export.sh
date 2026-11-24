#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="nftban_unified_exporter_export"
# meta:type="exporter"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Export functions: Prometheus, Zabbix, Generic Connectors"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_UNIFIED_EXPORTER_EXPORT_LOADED:-}" ]] && return 0
_UNIFIED_EXPORTER_EXPORT_LOADED="true"

# =============================================================================
# PHASE 1 RECONCILIATION METRICS (Export Tracking)
# Tracks: attempts, successes, failures, duration per target
# =============================================================================
declare -A EXPORT_ATTEMPTS EXPORT_SUCCESSES EXPORT_FAILURES EXPORT_DURATIONS EXPORT_LAST_SUCCESS

# Initialize export tracking counters from persistent state
_init_export_tracking() {
    local state_file="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/stats/export_tracking.dat"
    if [[ -f "$state_file" ]]; then
        while IFS='=' read -r key value; do
            case "$key" in
                attempts_*) EXPORT_ATTEMPTS["${key#attempts_}"]="$value" ;;
                success_*) EXPORT_SUCCESSES["${key#success_}"]="$value" ;;
                failures_*) EXPORT_FAILURES["${key#failures_}"]="$value" ;;
                last_success_*) EXPORT_LAST_SUCCESS["${key#last_success_}"]="$value" ;;
            esac
        done < "$state_file"
    fi
}

# Save export tracking state
_save_export_tracking() {
    local state_dir="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/stats"
    mkdir -p "$state_dir" || return 1
    local state_file="$state_dir/export_tracking.dat"
    {
        for target in "${!EXPORT_ATTEMPTS[@]}"; do
            echo "attempts_${target}=${EXPORT_ATTEMPTS[$target]}"
        done
        for target in "${!EXPORT_SUCCESSES[@]}"; do
            echo "success_${target}=${EXPORT_SUCCESSES[$target]}"
        done
        for target in "${!EXPORT_FAILURES[@]}"; do
            echo "failures_${target}=${EXPORT_FAILURES[$target]}"
        done
        for target in "${!EXPORT_LAST_SUCCESS[@]}"; do
            echo "last_success_${target}=${EXPORT_LAST_SUCCESS[$target]}"
        done
    } > "$state_file"
}

# Record export attempt (call before export)
record_export_start() {
    local target="$1"
    EXPORT_ATTEMPTS["$target"]=$((${EXPORT_ATTEMPTS["$target"]:-0} + 1))
    EXPORT_START_TIME=$(date +%s%3N 2>/dev/null || echo "0")
}

# Record export result (call after export)
record_export_result() {
    local target="$1"
    local success="$2"  # true/false
    local reason="${3:-}"

    local end_time
    end_time=$(date +%s%3N 2>/dev/null || echo "0")
    local duration_ms=0
    if [[ -n "${EXPORT_START_TIME:-}" ]] && [[ "$end_time" != "0" ]]; then
        duration_ms=$((end_time - EXPORT_START_TIME))
    fi
    EXPORT_DURATIONS["$target"]="$duration_ms"

    if [[ "$success" == "true" ]]; then
        EXPORT_SUCCESSES["$target"]=$((${EXPORT_SUCCESSES["$target"]:-0} + 1))
        EXPORT_LAST_SUCCESS["$target"]=$(date +%s)
    else
        EXPORT_FAILURES["$target"]=$((${EXPORT_FAILURES["$target"]:-0} + 1))
        # Log failure reason for debugging
        [[ -n "$reason" ]] && log_debug "Export $target failed: $reason"
    fi
}

# Write Phase 1 reconciliation metrics to cache
write_reconciliation_metrics() {
    local timestamp
    timestamp=$(date +%s)
    local metrics=""

    for target in prometheus zabbix portal elasticsearch kafka file syslog webhook; do
        local attempts="${EXPORT_ATTEMPTS["$target"]:-0}"
        local successes="${EXPORT_SUCCESSES["$target"]:-0}"
        local failures="${EXPORT_FAILURES["$target"]:-0}"
        local last_success="${EXPORT_LAST_SUCCESS["$target"]:-0}"
        local duration="${EXPORT_DURATIONS["$target"]:-0}"

        # Only emit metrics for targets that have been attempted
        if [[ $attempts -gt 0 ]]; then
            metrics+="nftban_export_attempts_total{target=\"$target\"} $attempts\n"
            metrics+="nftban_export_success_total{target=\"$target\"} $successes\n"
            metrics+="nftban_export_failures_total{target=\"$target\"} $failures\n"
            metrics+="nftban_export_last_success_timestamp{target=\"$target\"} $last_success\n"
            metrics+="nftban_export_duration_ms{target=\"$target\"} $duration\n"
        fi
    done

    # Append to metrics cache if it exists
    if [[ -n "$metrics" ]] && [[ -n "${METRICS_CACHE:-}" ]]; then
        printf '%b' "$metrics" >> "$METRICS_CACHE"
    fi
}

# =============================================================================
# EXPORT: Prometheus (node_exporter textfile)
# =============================================================================
# BUG-002 FIX: Use flock to prevent concurrent writers to nftban.prom
# Multiple writers (unified exporter, standalone prometheus exporter, Go collector)
# could race and corrupt the file. flock ensures mutual exclusion.
export_prometheus() {
    record_export_start "prometheus"

    local textfile_dir="${NFTBAN_PROMETHEUS_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
    local output_file="${textfile_dir}/${NFTBAN_PROMETHEUS_OUTPUT_FILE:-nftban.prom}"
    local lock_file="${output_file}.lock"

    if [[ ! -d "$textfile_dir" ]]; then
        log_warn "Prometheus textfile directory not found: $textfile_dir"
        record_export_result "prometheus" "false" "directory_not_found"
        return 1
    fi

    # Acquire exclusive lock (BUG-002 fix: prevent concurrent writers)
    exec 200>"$lock_file"
    if ! flock -w 5 200; then
        log_warn "Prometheus: could not acquire lock (another writer active)"
        record_export_result "prometheus" "false" "lock_failed"
        return 1
    fi

    # Convert to Prometheus format (remove timestamp for textfile collector)
    # Skip string metrics (|STRING|) as they are Zabbix-only
    # Use mktemp in same directory for atomic rename on same filesystem
    # BUG-015 FIX: Add HELP/TYPE annotations for OpenMetrics compliance
    local tmp_prom
    tmp_prom=$(mktemp "${output_file}.XXXXXX") || {
        exec 200>&-  # Release lock
        record_export_result "prometheus" "false" "mktemp_failed"
        return 1
    }

    # Write HELP/TYPE header annotations (OpenMetrics compliance)
    cat >> "$tmp_prom" << 'PROM_HEADER'
# HELP nftban_daemon_up NFTBan daemon status (1=running, 0=stopped)
# TYPE nftban_daemon_up gauge
# HELP nftban_uptime_seconds NFTBan daemon uptime in seconds
# TYPE nftban_uptime_seconds gauge
# HELP nftban_active_count Total number of active bans (IPv4+IPv6)
# TYPE nftban_active_count gauge
# HELP nftban_active_bans Number of active bans by address family
# TYPE nftban_active_bans gauge
# HELP nftban_blocks_total Total blocked IPs (Zabbix compatibility)
# TYPE nftban_blocks_total gauge
# HELP nftban_whitelist_total Total whitelisted entries
# TYPE nftban_whitelist_total gauge
# HELP nftban_feeds_enabled Number of enabled threat feeds
# TYPE nftban_feeds_enabled gauge
# HELP nftban_feeds_loaded Number of successfully loaded feeds
# TYPE nftban_feeds_loaded gauge
# HELP nftban_proc_rss_bytes Daemon RSS memory in bytes
# TYPE nftban_proc_rss_bytes gauge
# HELP nftban_export_attempts_total Number of export attempts by target
# TYPE nftban_export_attempts_total counter
# HELP nftban_export_success_total Number of successful exports by target
# TYPE nftban_export_success_total counter
# HELP nftban_export_failures_total Number of failed exports by target
# TYPE nftban_export_failures_total counter
# HELP nftban_botguard_set_count Number of IPs in each botguard category
# TYPE nftban_botguard_set_count gauge
# HELP nftban_botguard_total_tracked Total IPs tracked by botguard
# TYPE nftban_botguard_total_tracked gauge
# HELP nftban_module_botguard_status Botguard module status (1=active, 0=disabled, -1=failed)
# TYPE nftban_module_botguard_status gauge
PROM_HEADER

    if ! awk '{
        # Format: metric_name value timestamp -> metric_name value
        # Skip Zabbix string metrics (containing |STRING| prefix)
        if (index($2, "|STRING|") == 1) next

        # Skip dot-notation metrics (Zabbix format, invalid Prometheus names)
        # Valid Prometheus: [a-zA-Z_:][a-zA-Z0-9_:]*
        if (index($1, ".") > 0) next

        if (NF >= 2) {
            # Handle metrics with labels
            if ($1 ~ /{.*}/) {
                printf "%s %s\n", $1, $2
            } else {
                printf "%s %s\n", $1, $2
            }
        }
    }' "$METRICS_CACHE" >> "$tmp_prom"; then
        rm -f "$tmp_prom" 2>/dev/null
        exec 200>&-  # Release lock
        record_export_result "prometheus" "false" "awk_failed"
        return 1
    fi

    chmod 644 "$tmp_prom"
    mv -f "$tmp_prom" "$output_file"

    # Release lock (fd 200)
    exec 200>&-

    record_export_result "prometheus" "true"
    log_info "Prometheus: exported to $output_file"
}

# =============================================================================
# EXPORT: Zabbix Trapper
# =============================================================================
export_zabbix() {
    local enabled="${NFTBAN_ZABBIX_ENABLED:-false}"
    [[ "$enabled" != "true" ]] && return 0

    record_export_start "zabbix"

    local server="${NFTBAN_ZABBIX_SERVER:-}"
    local port="${NFTBAN_ZABBIX_PORT:-10051}"
    local hostname="${NFTBAN_ZABBIX_HOSTNAME:-auto}"
    local timeout="${NFTBAN_ZABBIX_TIMEOUT:-10}"

    if [[ -z "$server" ]]; then
        log_warn "Zabbix: server not configured"
        record_export_result "zabbix" "false" "server_not_configured"
        return 1
    fi

    [[ "$hostname" == "auto" ]] && hostname=$(hostname -f 2>/dev/null || hostname)

    # Check transport: require nc or ncat for Zabbix trapper protocol
    if ! command -v nc &>/dev/null && ! command -v ncat &>/dev/null; then
        log_warn "Zabbix: no transport (install nc or ncat)"
        record_export_result "zabbix" "false" "no_transport"
        return 1
    fi

    # Create zabbix_sender input file
    local tmp_file
    tmp_file=$(mktemp)
    # $tmp_file must expand at set-time, not trap execution-time
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
                # $2 = "|STRING|firstword", $3..$NF = "more words".
                #
                # ⛔ THERE IS NO TRAILING TIMESTAMP. Commit 5d245017 (v1.229.11,
                # "textfile exposition must carry no client-side timestamps") removed it
                # from the collector rows, but this loop kept the bound `i < NF` that
                # reserved the last field for one. With no timestamp to skip, that
                # silently DROPPED THE FINAL WORD of every multi-word STRING metric:
                #     "Ubuntu 24.04.1 LTS" -> "Ubuntu 24.04.1"
                #     "Not configured"     -> "Not"
                # nftban.version.info is a single token, which is why it went unnoticed;
                # 17 template inventory_link entries populate Zabbix HOST INVENTORY from
                # these items, so the truncation was operator-visible. Guarded by
                # tests/zabbix_string_truncation_v1229_13_test.sh.
                value = substr($2, 9)  # Strip "|STRING|" (8 chars)
                for (i = 3; i <= NF; i++) {
                    value = value " " $i
                }
                printf "%s %s \"%s\"\n", host, key, value
            } else {
                # Numeric value
                printf "%s %s %s\n", host, key, $2
            }
        }
    }' "$METRICS_CACHE" > "$tmp_file"

    # Send to Zabbix via native trapper protocol (nc)
    local data='{"request":"sender data","data":['
    local first=true
    while IFS=' ' read -r host key value; do
        [[ -z "$key" ]] && continue
        # Strip outer quotes first (from string values), then escape for JSON
        value="${value#\"}"   # Remove leading quote
        value="${value%\"}"   # Remove trailing quote
        value=$(printf '%s' "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')
        [[ "$first" != "true" ]] && data+=","
        data+="{\"host\":\"$host\",\"key\":\"$key\",\"value\":\"$value\"}"
        first=false
    done < "$tmp_file"
    data+=']}'

    local data_len=${#data}
    local nc_cmd
    nc_cmd=$(command -v ncat || command -v nc)

    # Write ZBXD protocol packet to temp file (more reliable than piping)
    local zabbix_pkt
    zabbix_pkt=$(mktemp)

    # ZBXD protocol: header (5 bytes) + length (8 bytes LE) + data
    printf 'ZBXD\x01' > "$zabbix_pkt"
    # Length as 8-byte little-endian (only first 4 bytes used for practical sizes)
    printf "\\x$(printf '%02x' $((data_len & 0xFF)))" >> "$zabbix_pkt"
    printf "\\x$(printf '%02x' $(((data_len >> 8) & 0xFF)))" >> "$zabbix_pkt"
    printf "\\x$(printf '%02x' $(((data_len >> 16) & 0xFF)))" >> "$zabbix_pkt"
    printf "\\x$(printf '%02x' $(((data_len >> 24) & 0xFF)))" >> "$zabbix_pkt"
    printf '\x00\x00\x00\x00' >> "$zabbix_pkt"
    printf '%s' "$data" >> "$zabbix_pkt"

    # Send via nc from file (avoids pipeline buffer issues)
    local result
    result=$(timeout "$timeout" "$nc_cmd" "$server" "$port" < "$zabbix_pkt" 2>/dev/null | tr -d '\0') || result=""
    rm -f "$zabbix_pkt"

    if echo "$result" | grep -q '"response":"success"'; then
        record_export_result "zabbix" "true"
        log_info "Zabbix: all metrics sent to $server:$port"
    else
        record_export_result "zabbix" "false" "${result:-no_response}"
        log_warn "Zabbix: send failed - ${result:-no response}"
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

    # Process each connector.
    # v1.238 (owner GO 2026-11-23: count delivery only after the destination's acknowledgement;
    # show skipped, failed and unverified outcomes). Each connector's result is recorded under its
    # type; the function fails if any enabled connector did not deliver.
    local any_failed=0 conf
    for conf in "$connectors_dir"/*.conf; do
        [[ -f "$conf" ]] || continue
        # No value may leak from the previous connector (e.g. another connector's credentials).
        unset CONNECTOR_NAME CONNECTOR_TYPE CONNECTOR_ENABLED CONNECTOR_ES_URL CONNECTOR_ES_INDEX \
              CONNECTOR_ES_USER CONNECTOR_ES_PASS CONNECTOR_KAFKA_BROKERS CONNECTOR_KAFKA_TOPIC \
              CONNECTOR_FILE_PATH

        if [[ ! -r "$conf" ]]; then
            # Before v1.238 `connector add` wrote root:root 0640: the exporter (nftban) could not
            # read it, the error went to stderr only and the cycle still counted as an export.
            log_warn "Connector: $(basename "$conf") is not readable by $(id -un) — not exported. Fix: chgrp nftban '$conf' (mode 0640)"
            record_export_start "file"; record_export_result "file" "false" "connector_unreadable"
            any_failed=1
            continue
        fi
        # shellcheck source=/dev/null
        if ! source "$conf"; then
            log_warn "Connector: $(basename "$conf") could not be loaded — not exported"
            any_failed=1
            continue
        fi

        [[ "${CONNECTOR_ENABLED:-false}" != "true" ]] && continue

        case "${CONNECTOR_TYPE:-}" in
            elasticsearch)
                record_export_start "elasticsearch"
                local url="${CONNECTOR_ES_URL}/${CONNECTOR_ES_INDEX:-nftban-metrics}/_doc"
                # Configured credentials are always used (same netrc mechanism as `connector push`,
                # never on the command line); a user without a password is a configuration error.
                local netrc_file="" es_host
                if [[ -n "${CONNECTOR_ES_USER:-}" ]]; then
                    if [[ -z "${CONNECTOR_ES_PASS:-}" ]]; then
                        log_warn "Connector: Elasticsearch (${CONNECTOR_NAME}) has CONNECTOR_ES_USER but no CONNECTOR_ES_PASS — not sent"
                        record_export_result "elasticsearch" "false" "credentials_incomplete"
                        any_failed=1
                        continue
                    fi
                    netrc_file=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/nftban-es-netrc.XXXXXX") || {
                        record_export_result "elasticsearch" "false" "mktemp_failed"; any_failed=1; continue; }
                    es_host=$(echo "$url" | sed -E 's|https?://([^/:]+).*|\1|')
                    printf 'machine %s login %s password %s\n' "$es_host" "$CONNECTOR_ES_USER" "$CONNECTOR_ES_PASS" > "$netrc_file"
                fi
                local es_rc=0 auth_args=()
                [[ -n "$netrc_file" ]] && auth_args=(--netrc-file "$netrc_file")
                printf '%s' "$json_payload" | curl -sf -X POST "$url" -H "Content-Type: application/json" \
                    "${auth_args[@]}" -d @- -o /dev/null || es_rc=$?
                [[ -n "$netrc_file" ]] && rm -f "$netrc_file"
                if [[ $es_rc -eq 0 ]]; then
                    # curl -f: only a 2xx reply (document indexed) counts as delivered.
                    record_export_result "elasticsearch" "true"
                    log_info "Connector: sent to Elasticsearch (${CONNECTOR_NAME})"
                else
                    record_export_result "elasticsearch" "false" "curl_rc_${es_rc}"
                    log_warn "Connector: Elasticsearch export failed (${CONNECTOR_NAME}, curl rc=${es_rc}; 22 = HTTP error such as 401)"
                    any_failed=1
                fi
                ;;

            kafka)
                record_export_start "kafka"
                if ! command -v kafkacat &>/dev/null; then
                    log_warn "Connector: Kafka (${CONNECTOR_NAME}) skipped — kafkacat is not installed"
                    record_export_result "kafka" "false" "kafkacat_missing"
                    any_failed=1
                elif echo "$json_payload" | kafkacat -P -b "${CONNECTOR_KAFKA_BROKERS}" -t "${CONNECTOR_KAFKA_TOPIC:-nftban}" 2>/dev/null; then
                    record_export_result "kafka" "true"
                    log_info "Connector: sent to Kafka (${CONNECTOR_NAME})"
                else
                    record_export_result "kafka" "false" "kafkacat_failed"
                    log_warn "Connector: Kafka export failed (${CONNECTOR_NAME})"
                    any_failed=1
                fi
                ;;

            file)
                record_export_start "file"
                local path="${CONNECTOR_FILE_PATH:-${NFTBAN_LOG_DIR:-/var/log/nftban}/metrics.json}"
                if mkdir -p "$(dirname "$path")" && echo "$json_payload" >> "$path"; then
                    record_export_result "file" "true"
                    log_info "Connector: written to $path (${CONNECTOR_NAME})"
                else
                    record_export_result "file" "false" "write_failed"
                    log_warn "Connector: could not write $path (${CONNECTOR_NAME})"
                    any_failed=1
                fi
                ;;

            syslog|webhook)
                # Not implemented in the periodic exporter (only `nftban connector push` sends these
                # types); reported instead of silently skipped. Proposal: shared delivery, v1.239+.
                record_export_start "${CONNECTOR_TYPE}"
                record_export_result "${CONNECTOR_TYPE}" "false" "not_supported_by_timer"
                log_warn "Connector: ${CONNECTOR_TYPE} (${CONNECTOR_NAME}) is not sent by the periodic exporter (only by 'nftban connector push')"
                any_failed=1
                ;;

            *)
                log_warn "Connector: ${CONNECTOR_NAME:-$(basename "$conf")} has unknown type '${CONNECTOR_TYPE:-}' — not exported"
                any_failed=1
                ;;
        esac
    done
    return $any_failed
}

# =============================================================================
# EXPORT: Portal (pro.nftban.com)
# Real ACK: HTTP 2xx response with confirmation
# =============================================================================
export_portal() {
    local enabled="${NFTBAN_PORTAL_ENABLED:-false}"
    [[ "$enabled" != "true" ]] && return 0

    record_export_start "portal"

    local portal_url="${NFTBAN_PORTAL_URL:-https://pro.nftban.com/api/v1/ingest}"
    local api_key="${NFTBAN_PORTAL_API_KEY:-}"
    local timeout="${NFTBAN_PORTAL_TIMEOUT:-30}"

    if [[ -z "$api_key" ]]; then
        log_warn "Portal: API key not configured"
        record_export_result "portal" "false" "api_key_missing"
        return 1
    fi

    # Generate host_key: prefer machine-id, fallback to SHA256(mac + hostname)
    local host_key=""
    if [[ -f /etc/machine-id ]]; then
        host_key=$(cat /etc/machine-id 2>/dev/null | tr -d '[:space:]')
    fi
    if [[ -z "$host_key" ]]; then
        local hostname mac
        hostname=$(hostname -f 2>/dev/null || hostname)
        mac=$(ip link show 2>/dev/null | awk '/link\/ether/ {print $2; exit}' || echo "00:00:00:00:00:00")
        host_key=$(echo -n "${mac}${hostname}" | sha256sum | cut -d' ' -f1)
    fi

    local timestamp hostname fqdn primary_ip
    timestamp=$(date -Iseconds)
    hostname=$(hostname -s 2>/dev/null || hostname)
    fqdn=$(hostname -f 2>/dev/null || hostname)
    primary_ip=$(ip route get 1 2>/dev/null | awk '{print $7; exit}' || echo "127.0.0.1")

    # Build inventory JSON from collected metrics
    local inventory_json
    inventory_json=$(cat <<EOF
{
    "mac_address": "$(ip link show 2>/dev/null | awk '/link\/ether/ {print $2; exit}' || echo "")",
    "cpu_cores": $(nproc 2>/dev/null || echo 1),
    "cpu_model": "$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d':' -f2 | sed 's/^[ \t]*//' || echo "unknown")",
    "memory_total_bytes": $(awk '/^MemTotal:/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo 0),
    "disk_total_bytes": $(df -B1 / 2>/dev/null | tail -1 | awk '{print $2}' || echo 0),
    "server_type": "$(systemd-detect-virt 2>/dev/null | grep -q none && echo physical || echo vm)",
    "vendor": "$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo "Unknown")",
    "model": "$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo "Unknown")",
    "serial_number": "$(cat /sys/class/dmi/id/product_serial 2>/dev/null || echo "N/A")",
    "os_name": "$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 || uname -o)",
    "os_release": "$(grep -E '^NAME=' /etc/os-release 2>/dev/null | cut -d'"' -f2 || uname -o)",
    "kernel_version": "$(uname -r)",
    "arch": "$(uname -m)",
    "nftban_version": "$(cat "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/VERSION" 2>/dev/null | head -1 || echo "unknown")",
    "panel": "${NFTBAN_PANEL:-none}",
    "networks": $(ip -4 -j addr 2>/dev/null | jq -c '[.[] | select(.operstate=="UP") | {(.ifname): .addr_info[0].local}] | add // {}' 2>/dev/null || echo '{}'),
    "subnet_mask": "$(ip -4 addr show 2>/dev/null | awk '/inet / {print $2}' | head -1 | cut -d'/' -f2 | xargs -I{} sh -c 'case {} in 8) echo 255.0.0.0;; 16) echo 255.255.0.0;; 24) echo 255.255.255.0;; *) echo 255.255.255.0;; esac' 2>/dev/null || echo "255.255.255.0")",
    "location": "${NFTBAN_SERVER_LOCATION:-}"
}
EOF
)

    # Build metrics array from cache (skip string metrics)
    local metrics_json
    metrics_json=$(awk 'BEGIN { printf "[" }
        NR > 1 { printf "," }
        {
            if (index($2, "|STRING|") == 1) next
            gsub(/{|}/, "", $1)
            gsub(/"/, "\\\"", $1)
            printf "{\"name\":\"%s\",\"value\":%s,\"ts\":%s}", $1, $2, $3
        }
        END { printf "]" }
    ' "$METRICS_CACHE" 2>/dev/null || echo "[]")

    # Build module status array
    local modules_json="[]"
    for module in login portscan ddos suricata feeds geoban watchdog; do
        local status_val=0
        local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/modules/${module}.conf"
        if [[ -f "$config_file" ]]; then
            if systemctl is-active "nftban-${module}.timer" &>/dev/null 2>&1 || \
               systemctl is-active "nftban-${module}.service" &>/dev/null 2>&1; then
                status_val=1
            elif systemctl is-failed "nftban-${module}.service" &>/dev/null 2>&1; then
                status_val=-1
            fi
        fi
        modules_json=$(echo "$modules_json" | jq --arg m "$module" --argjson s "$status_val" \
            '. + [{"name": $m, "status": $s}]' 2>/dev/null || echo "$modules_json")
    done

    # Build full payload
    local payload
    payload=$(cat <<EOF
{
    "host_key": "$host_key",
    "hostname": "$hostname",
    "fqdn": "$fqdn",
    "primary_ip": "$primary_ip",
    "timestamp": "$timestamp",
    "inventory": $inventory_json,
    "modules": $modules_json,
    "metrics": $metrics_json
}
EOF
)

    # Send to portal with real ACK.
    # v1.238 OBS-PORTAL-API-KEY-IN-ARGV (owner GO 2026-11-23): the API key and host key travel in a
    # 0600 header file (curl -H @file) and the payload on stdin (-d @-), never on the command line
    # (/proc/<pid>/cmdline is readable by every local user); the key is never sent over plain http.
    if [[ "$portal_url" != https://* ]]; then
        log_warn "Portal: NFTBAN_PORTAL_URL must use https:// (the API key is not sent over plain http)"
        record_export_result "portal" "false" "insecure_url"
        return 1
    fi
    local response http_code hdr_file
    hdr_file=$(mktemp "${NFTBAN_RUN_DIR:-/run/nftban}/portal_hdr.XXXXXX") || {
        record_export_result "portal" "false" "mktemp_failed"
        return 1
    }
    printf 'Content-Type: application/json\nAuthorization: Bearer %s\nX-NFTBan-Host-Key: %s\n' \
        "$api_key" "$host_key" > "$hdr_file"
    response=$(printf '%s' "$payload" | curl -sf --proto '=https' -X POST "$portal_url" \
        -H @"$hdr_file" \
        --max-time "$timeout" \
        -w "\n%{http_code}" \
        -d @- 2>/dev/null) || response=""
    rm -f "$hdr_file"

    http_code=$(echo "$response" | tail -1)

    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        record_export_result "portal" "true"
        log_info "Portal: exported to $portal_url (HTTP $http_code)"
    else
        record_export_result "portal" "false" "http_$http_code"
        log_warn "Portal: export failed - HTTP ${http_code:-timeout}"
    fi
}
