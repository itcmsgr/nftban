#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_unified_exporter_export"
# meta:type="exporter"
# meta:version="1.0.0"
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
    mkdir -p "$state_dir"
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

    for target in prometheus zabbix portal elasticsearch kafka file; do
        local attempts="${EXPORT_ATTEMPTS["$target"]:-0}"
        local successes="${EXPORT_SUCCESSES["$target"]:-0}"
        local failures="${EXPORT_FAILURES["$target"]:-0}"
        local last_success="${EXPORT_LAST_SUCCESS["$target"]:-0}"
        local duration="${EXPORT_DURATIONS["$target"]:-0}"

        # Only emit metrics for targets that have been attempted
        if [[ $attempts -gt 0 ]]; then
            metrics+="nftban_export_attempts_total{target=\"$target\"} $attempts $timestamp\n"
            metrics+="nftban_export_success_total{target=\"$target\"} $successes $timestamp\n"
            metrics+="nftban_export_failures_total{target=\"$target\"} $failures $timestamp\n"
            metrics+="nftban_export_last_success_timestamp{target=\"$target\"} $last_success $timestamp\n"
            metrics+="nftban_export_duration_ms{target=\"$target\"} $duration $timestamp\n"
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
export_prometheus() {
    record_export_start "prometheus"

    local textfile_dir="${NFTBAN_PROMETHEUS_TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
    local output_file="${textfile_dir}/${NFTBAN_PROMETHEUS_OUTPUT_FILE:-nftban.prom}"

    if [[ ! -d "$textfile_dir" ]]; then
        log_warn "Prometheus textfile directory not found: $textfile_dir"
        record_export_result "prometheus" "false" "directory_not_found"
        return 1
    fi

    # Convert to Prometheus format (remove timestamp for textfile collector)
    # Skip string metrics (|STRING|) as they are Zabbix-only
    # Use mktemp in same directory for atomic rename on same filesystem
    local tmp_prom
    tmp_prom=$(mktemp "${output_file}.XXXXXX") || {
        record_export_result "prometheus" "false" "mktemp_failed"
        return 1
    }

    if ! awk '{
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
    }' "$METRICS_CACHE" > "$tmp_prom"; then
        rm -f "$tmp_prom" 2>/dev/null
        record_export_result "prometheus" "false" "awk_failed"
        return 1
    fi

    chmod 644 "$tmp_prom"
    mv -f "$tmp_prom" "$output_file"

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
                local path="${CONNECTOR_FILE_PATH:-${NFTBAN_LOG_DIR:-/var/log/nftban}/metrics.json}"
                mkdir -p "$(dirname "$path")"
                echo "$json_payload" >> "$path"
                record_export_result "file" "true"
                log_info "Connector: written to $path (${CONNECTOR_NAME})"
                ;;
        esac
    done
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

    # Send to portal with real ACK
    local response http_code
    response=$(curl -sf -X POST "$portal_url" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $api_key" \
        -H "X-NFTBan-Host-Key: $host_key" \
        --max-time "$timeout" \
        -w "\n%{http_code}" \
        -d "$payload" 2>/dev/null) || response=""

    http_code=$(echo "$response" | tail -1)

    if [[ "$http_code" =~ ^2[0-9][0-9]$ ]]; then
        record_export_result "portal" "true"
        log_info "Portal: exported to $portal_url (HTTP $http_code)"
    else
        record_export_result "portal" "false" "http_$http_code"
        log_warn "Portal: export failed - HTTP ${http_code:-timeout}"
    fi
}
