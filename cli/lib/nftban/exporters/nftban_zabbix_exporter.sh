#!/usr/bin/env bash
# =============================================================================
# NFTBan Zabbix Exporter v2 (Uses Central Collector)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_zabbix_exporter_v2"
# meta:type="exporter"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:version="2.0.0"
# meta:created_date="2026-01-24"
# meta:description="Zabbix exporter - reads from central collector, formats and sends"
# meta:inventory.files="/var/cache/nftban/metrics/"
# meta:inventory.binaries="jq"
# meta:inventory.env_vars="NFTBAN_ZABBIX_SERVER,NFTBAN_ZABBIX_PORT"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftban-zabbix-exporter.timer"
# meta:inventory.network="10051/tcp"
# meta:inventory.privileges="root"
# =============================================================================
#
# ARCHITECTURE:
#   This exporter reads from the central metrics collector output and
#   converts to Zabbix trapper format, then sends to Zabbix server.
#
#   Central Collector → JSON → This Script → Zabbix Protocol → Zabbix Server
#
# DEPENDENCIES:
#   - nftban_metrics_collector.sh (must run first or be called)
#   - jq (for JSON parsing)
#   - nc or zabbix_sender (for sending)
#
# =============================================================================

set -Eeuo pipefail

# Bootstrap paths
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_CACHE_DIR:=/var/cache/nftban}"

# Load config
[[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR}/nftban.conf"
[[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf.local" ]] && source "${NFTBAN_CONFIG_DIR}/nftban.conf.local" 2>/dev/null || true

# =============================================================================
# CONFIGURATION
# =============================================================================

ZABBIX_ENABLED="${NFTBAN_ZABBIX_ENABLED:-false}"
ZABBIX_SERVER="${NFTBAN_ZABBIX_SERVER:-}"
ZABBIX_PORT="${NFTBAN_ZABBIX_PORT:-10051}"
ZABBIX_HOSTNAME="${NFTBAN_ZABBIX_HOSTNAME:-auto}"
[[ "$ZABBIX_HOSTNAME" == "auto" ]] && ZABBIX_HOSTNAME=$(hostname -f 2>/dev/null || hostname)

# Central collector paths
METRICS_DIR="${NFTBAN_CACHE_DIR}/metrics"
COMBINED_FILE="${METRICS_DIR}/combined.json"
COLLECTOR_SCRIPT="${NFTBAN_LIB_DIR}/exporters/nftban_metrics_collector.sh"

# Runtime
VERBOSE=false
DRY_RUN=false
FORCE_COLLECT=false

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() { [[ "$VERBOSE" == "true" ]] && echo "[INFO] $*" >&2 || true; }
log_error() { echo "[ERROR] $*" >&2; }

# =============================================================================
# JSON TO ZABBIX CONVERSION
# =============================================================================

json_to_zabbix_metrics() {
    # Convert central collector JSON to Zabbix key-value pairs
    local json="$1"
    local metrics=""

    # Daemon metrics
    metrics+="nftban.status $(echo "$json" | jq -r '.daemon.status // 0')\n"
    metrics+="nftban.version $(echo "$json" | jq -r '.daemon.version // "unknown"')\n"
    metrics+="nftban.uptime $(echo "$json" | jq -r '.daemon.uptime // 0')\n"
    metrics+="nftban.pid $(echo "$json" | jq -r '.daemon.pid // 0')\n"
    metrics+="nftban.mode $(echo "$json" | jq -r '.daemon.mode // "unknown"')\n"

    # Ban metrics
    metrics+="nftban.active.count $(echo "$json" | jq -r '.bans.active // 0')\n"
    metrics+="nftban.bans.24h $(echo "$json" | jq -r '.bans.bans_24h // 0')\n"
    metrics+="nftban.bans.1h $(echo "$json" | jq -r '.bans.bans_1h // 0')\n"
    metrics+="nftban.bans.rate $(echo "$json" | jq -r '.bans.rate // 0')\n"
    metrics+="nftban.bans.total $(echo "$json" | jq -r '.bans.total // 0')\n"
    metrics+="nftban.permanent.count $(echo "$json" | jq -r '.bans.permanent // 0')\n"
    metrics+="nftban.whitelist.count $(echo "$json" | jq -r '.bans.whitelist // 0')\n"

    # Memory metrics
    metrics+="nftban.memory.rss $(echo "$json" | jq -r '.memory.rss // 0')\n"
    metrics+="nftban.fds.open $(echo "$json" | jq -r '.memory.fds // 0')\n"
    metrics+="nftban.threads $(echo "$json" | jq -r '.memory.threads // 0')\n"
    metrics+="nftban.goroutines $(echo "$json" | jq -r '.runtime.goroutines // 0')\n"

    # Runtime metrics (from watchdog)
    metrics+="nftban.runtime.heap_mb $(echo "$json" | jq -r '.runtime.heap_mb // 0')\n"
    metrics+="nftban.runtime.gc_cycles $(echo "$json" | jq -r '.runtime.gc_cycles // 0')\n"
    metrics+="nftban.runtime.gc_pause_ms $(echo "$json" | jq -r '.runtime.gc_pause_ms // 0')\n"

    # Throughput metrics
    metrics+="nftban.throughput.bans_total $(echo "$json" | jq -r '.throughput.bans_total // 0')\n"
    metrics+="nftban.throughput.unbans_total $(echo "$json" | jq -r '.throughput.unbans_total // 0')\n"
    metrics+="nftban.throughput.bans_per_min $(echo "$json" | jq -r '.throughput.bans_per_min // 0')\n"

    # IPC metrics
    metrics+="nftban.ipc.requests $(echo "$json" | jq -r '.ipc.requests_total // 0')\n"
    metrics+="nftban.ipc.latency_ms $(echo "$json" | jq -r '.ipc.avg_latency_ms // 0')\n"
    metrics+="nftban.ipc.errors $(echo "$json" | jq -r '.ipc.errors_total // 0')\n"

    # Health metrics
    metrics+="nftban.health.status $(echo "$json" | jq -r '.health.status // 0')\n"
    metrics+="nftban.health.passed $(echo "$json" | jq -r '.health.passed // 0')\n"
    metrics+="nftban.health.failed $(echo "$json" | jq -r '.health.failed // 0')\n"

    # Module metrics
    metrics+="nftban.modules.enabled $(echo "$json" | jq -r '.modules.enabled // 0')\n"
    metrics+="nftban.modules.active $(echo "$json" | jq -r '.modules.active // 0')\n"
    metrics+="nftban.modules.failed $(echo "$json" | jq -r '.modules.failed // 0')\n"

    # nftables metrics
    metrics+="nftban.nft.sets_total $(echo "$json" | jq -r '.nftables.sets // 0')\n"
    metrics+="nftban.nft.elements_total $(echo "$json" | jq -r '.nftables.elements // 0')\n"
    metrics+="nftban.nft.rules_total $(echo "$json" | jq -r '.nftables.rules // 0')\n"
    metrics+="nftban.nft.packets_blocked_ipv4 $(echo "$json" | jq -r '.nftables.packets_blocked_ipv4 // 0')\n"
    metrics+="nftban.nft.packets_blocked_ipv6 $(echo "$json" | jq -r '.nftables.packets_blocked_ipv6 // 0')\n"

    # Feed metrics
    metrics+="nftban.feeds.enabled $(echo "$json" | jq -r '.feeds.enabled // 0')\n"
    metrics+="nftban.feeds.loaded $(echo "$json" | jq -r '.feeds.loaded // 0')\n"
    metrics+="nftban.feeds.failed $(echo "$json" | jq -r '.feeds.failed // 0')\n"
    metrics+="nftban.feeds.ips_total $(echo "$json" | jq -r '.feeds.ips_total // 0')\n"

    # Network metrics
    metrics+="nftban.connections.active $(echo "$json" | jq -r '.network.connections.active // 0')\n"
    metrics+="nftban.connections.established $(echo "$json" | jq -r '.network.connections.established // 0')\n"
    metrics+="nftban.connections.time_wait $(echo "$json" | jq -r '.network.connections.time_wait // 0')\n"
    metrics+="nftban.connections.close_wait $(echo "$json" | jq -r '.network.connections.close_wait // 0')\n"

    # System metrics
    metrics+="nftban.server.load_1m $(echo "$json" | jq -r '.system.load_1m // 0')\n"
    metrics+="nftban.server.load_5m $(echo "$json" | jq -r '.system.load_5m // 0')\n"
    metrics+="nftban.server.load_15m $(echo "$json" | jq -r '.system.load_15m // 0')\n"
    metrics+="nftban.server.mem_used_percent $(echo "$json" | jq -r '.system.mem_used_percent // 0')\n"
    metrics+="nftban.server.iowait_percent $(echo "$json" | jq -r '.system.iowait_percent // 0')\n"
    metrics+="nftban.server.disk_used_percent $(echo "$json" | jq -r '.system.disk_used_percent // 0')\n"

    # GeoIP metrics
    metrics+="nftban.geoip.database_age $(echo "$json" | jq -r '.geoip.database_age // 0')\n"
    metrics+="nftban.geoip.countries_blocked $(echo "$json" | jq -r '.geoip.countries_blocked // 0')\n"

    # Watchdog status
    local watchdog_status=0
    [[ $(echo "$json" | jq -r '.runtime.goroutines // 0') != "0" ]] && watchdog_status=1
    metrics+="nftban.watchdog.status $watchdog_status\n"

    # Server inventory (if present)
    if echo "$json" | jq -e '.server' &>/dev/null; then
        metrics+="nftban.server.hostname $(echo "$json" | jq -r '.server.hostname // ""')\n"
        metrics+="nftban.server.fqdn $(echo "$json" | jq -r '.server.fqdn // ""')\n"
        metrics+="nftban.server.os $(echo "$json" | jq -r '.server.os // ""')\n"
        metrics+="nftban.server.os_release $(echo "$json" | jq -r '.server.os_release // ""')\n"
        metrics+="nftban.server.kernel $(echo "$json" | jq -r '.server.kernel // ""')\n"
        metrics+="nftban.server.arch $(echo "$json" | jq -r '.server.arch // ""')\n"
        metrics+="nftban.server.cpu_cores $(echo "$json" | jq -r '.server.cpu_cores // 0')\n"
        metrics+="nftban.server.cpu_model $(echo "$json" | jq -r '.server.cpu_model // ""')\n"
        metrics+="nftban.server.memory_total $(echo "$json" | jq -r '.server.memory_total // 0')\n"
        metrics+="nftban.server.memory_available $(echo "$json" | jq -r '.system.mem_available_mb // 0' | awk '{print $1 * 1048576}')\n"
        metrics+="nftban.server.uptime $(echo "$json" | jq -r '.server.uptime // 0')\n"
        metrics+="nftban.server.boot_time $(echo "$json" | jq -r '.server.boot_time // 0')\n"
        metrics+="nftban.server.primary_ip $(echo "$json" | jq -r '.server.primary_ip // ""')\n"
        metrics+="nftban.server.ipv6 $(echo "$json" | jq -r '.server.ipv6 // ""')\n"
        metrics+="nftban.server.mac_address $(echo "$json" | jq -r '.server.mac_address // ""')\n"
        metrics+="nftban.server.subnet_mask $(echo "$json" | jq -r '.server.subnet_mask // ""')\n"
        metrics+="nftban.server.gateway $(echo "$json" | jq -r '.server.gateway // ""')\n"
        metrics+="nftban.server.public_ip $(echo "$json" | jq -r '.server.public_ip // ""')\n"
        metrics+="nftban.server.interfaces $(echo "$json" | jq -c '.server.interfaces // []')\n"
        metrics+="nftban.server.networks $(echo "$json" | jq -c '.server.networks // []')\n"
        metrics+="nftban.server.timezone $(echo "$json" | jq -r '.server.timezone // ""')\n"
        metrics+="nftban.server.virtualization $(echo "$json" | jq -r '.server.virtualization // ""')\n"
        metrics+="nftban.server.cloud_provider $(echo "$json" | jq -r '.server.cloud_provider // ""')\n"
    fi

    echo -e "$metrics"
}

# =============================================================================
# ZABBIX SENDER FUNCTIONS
# =============================================================================

send_to_zabbix() {
    local metrics="$1"

    # Build Zabbix sender data format
    local data='{"request":"sender data","data":['
    local first=true

    while IFS=' ' read -r key value; do
        [[ -z "$key" ]] && continue

        # Escape value for JSON
        value=$(echo "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')

        [[ "$first" != "true" ]] && data+=","
        data+="{\"host\":\"$ZABBIX_HOSTNAME\",\"key\":\"$key\",\"value\":\"$value\"}"
        first=false
    done <<< "$(echo -e "$metrics")"

    data+=']}'

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "=== DRY RUN: Would send to $ZABBIX_SERVER:$ZABBIX_PORT ==="
        echo "$data" | jq .
        return 0
    fi

    # Send using native Zabbix protocol
    local data_len=${#data}

    # Build length header (8 bytes, little-endian)
    local len_hex
    len_hex=$(printf '%016x' "$data_len")

    # Send: ZBXD\x01 + length (8 bytes LE) + data
    local response=""
    response=$( (
        printf 'ZBXD\x01'
        # Length as little-endian 8 bytes
        printf "\\x${len_hex:14:2}\\x${len_hex:12:2}\\x${len_hex:10:2}\\x${len_hex:8:2}"
        printf '\x00\x00\x00\x00'
        printf '%s' "$data"
    ) 2>/dev/null | timeout 10 nc "$ZABBIX_SERVER" "$ZABBIX_PORT" 2>/dev/null | tr -d '\0' | strings ) || response=""

    if [[ -n "${response:-}" ]] && echo "$response" | grep -q '"response":"success"'; then
        local info
        info=$(echo "$response" | grep -oP '"info":"\K[^"]+' || echo "sent")
        log_info "Zabbix: $info"
        return 0
    else
        log_error "Failed to send to Zabbix: ${response:-no response}"
        return 1
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --verbose)  VERBOSE=true; shift ;;
            --dry-run)  DRY_RUN=true; shift ;;
            --force)    FORCE_COLLECT=true; shift ;;
            --help|-h)
                echo "NFTBan Zabbix Exporter v2 (Central Collector)"
                echo ""
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --verbose   Show detailed output"
                echo "  --dry-run   Show what would be sent without sending"
                echo "  --force     Force fresh metrics collection"
                echo ""
                echo "This exporter reads from central collector:"
                echo "  $COMBINED_FILE"
                exit 0
                ;;
            *) shift ;;
        esac
    done

    # Check if Zabbix is enabled
    if [[ "$ZABBIX_ENABLED" != "true" ]]; then
        log_info "Zabbix export disabled"
        exit 0
    fi

    # Check prerequisites
    if [[ -z "$ZABBIX_SERVER" ]]; then
        log_error "NFTBAN_ZABBIX_SERVER not configured"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq is required"
        exit 1
    fi

    # Get metrics from central collector
    local metrics_json=""

    if [[ "$FORCE_COLLECT" == "true" ]] || [[ ! -f "$COMBINED_FILE" ]]; then
        log_info "Running central collector..."
        if [[ -x "$COLLECTOR_SCRIPT" ]]; then
            "$COLLECTOR_SCRIPT" --force
        fi
    fi

    if [[ -f "$COMBINED_FILE" ]]; then
        metrics_json=$(cat "$COMBINED_FILE")
        log_info "Read metrics from $COMBINED_FILE"
    else
        # Fallback: run collector and get output directly
        log_info "Running collector inline..."
        metrics_json=$("$COLLECTOR_SCRIPT" --stdout --force 2>/dev/null)
    fi

    if [[ -z "$metrics_json" ]]; then
        log_error "No metrics available"
        exit 1
    fi

    # Convert to Zabbix format
    log_info "Converting to Zabbix format..."
    local zabbix_metrics
    zabbix_metrics=$(json_to_zabbix_metrics "$metrics_json")

    # Count metrics
    local count=$(echo -e "$zabbix_metrics" | grep -c "^nftban\." || echo "0")
    log_info "Prepared $count metrics"

    # Send to Zabbix
    log_info "Sending to $ZABBIX_SERVER:$ZABBIX_PORT..."
    send_to_zabbix "$zabbix_metrics"
}

main "$@"
