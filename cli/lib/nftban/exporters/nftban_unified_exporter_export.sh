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

    # Check transport: require nc or ncat for Zabbix trapper protocol
    if ! command -v nc &>/dev/null && ! command -v ncat &>/dev/null; then
        log_warn "Zabbix: no transport (install nc or ncat)"
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
    result=$(timeout 10 "$nc_cmd" "$server" "$port" < "$zabbix_pkt" 2>/dev/null | tr -d '\0') || result=""
    rm -f "$zabbix_pkt"

    if echo "$result" | grep -q '"response":"success"'; then
        log_info "Zabbix: all metrics sent to $server:$port"
    else
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
                log_info "Connector: written to $path (${CONNECTOR_NAME})"
                ;;
        esac
    done
}
