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
# meta:inventory.systemd_units="nftban-unified-exporter.timer"
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

    # Daemon metrics (keys must match template exactly)
    metrics+="nftban.daemon.up $(echo "$json" | jq -r '.daemon.status // 0')\n"
    metrics+="nftban.version $(echo "$json" | jq -r '.daemon.version // "unknown"')\n"
    metrics+="nftban.uptime.seconds $(echo "$json" | jq -r '.daemon.uptime // 0')\n"
    metrics+="nftban.pid $(echo "$json" | jq -r '.daemon.pid // 0')\n"
    metrics+="nftban.mode $(echo "$json" | jq -r '.daemon.mode // "unknown"')\n"

    # Ban metrics (keys must match template exactly)
    metrics+="nftban.active.count $(echo "$json" | jq -r '.bans.active // 0')\n"
    metrics+="nftban.bans.last.24h $(echo "$json" | jq -r '.bans.bans_24h // 0')\n"
    metrics+="nftban.bans.last.1h $(echo "$json" | jq -r '.bans.bans_1h // 0')\n"
    metrics+="nftban.throughput.bans.per.minute $(echo "$json" | jq -r '.bans.rate // 0')\n"
    metrics+="nftban.bans.total $(echo "$json" | jq -r '.bans.total // 0')\n"
    metrics+="nftban.blacklist.ipv4.perm $(echo "$json" | jq -r '.bans.permanent // 0')\n"
    metrics+="nftban.whitelist.ipv4.count $(echo "$json" | jq -r '.bans.whitelist // 0')\n"

    # Memory metrics (keys must match template exactly)
    metrics+="nftban.memory.rss.bytes $(echo "$json" | jq -r '.memory.rss // 0')\n"
    metrics+="nftban.open.fds $(echo "$json" | jq -r '.memory.fds // 0')\n"
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

    # nftables metrics (keys must match template exactly)
    metrics+="nftban.nftables.sets.total $(echo "$json" | jq -r '.nftables.sets // 0')\n"
    metrics+="nftban.nftables.set.elements.total $(echo "$json" | jq -r '.nftables.elements // 0')\n"
    metrics+="nftban.nftables.rules.total $(echo "$json" | jq -r '.nftables.rules // 0')\n"
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
    metrics+="nftban.server.disk_total $(echo "$json" | jq -r '.system.disk_total // 0')\n"
    metrics+="nftban.server.disk_used $(echo "$json" | jq -r '.system.disk_used // 0')\n"
    metrics+="nftban.server.panel $(echo "$json" | jq -r '.server.panel // "none"')\n"

    # Daemon process metrics (from daemon_stats)
    metrics+="nftban.daemon.cpu_percent $(echo "$json" | jq -r '.daemon_stats.cpu_percent // 0')\n"
    metrics+="nftban.daemon.mem_percent $(echo "$json" | jq -r '.daemon_stats.mem_percent // 0')\n"
    metrics+="nftban.daemon.vsz_bytes $(echo "$json" | jq -r '.daemon_stats.vsz_bytes // 0')\n"
    metrics+="nftban.daemon.uptime_seconds $(echo "$json" | jq -r '.daemon.uptime // 0')\n"
    metrics+="nftban.daemon.memory_growth_rate $(echo "$json" | jq -r '.daemon_stats.memory_growth_rate // 0')\n"
    metrics+="nftban.daemon.memory_pressure $(echo "$json" | jq -r '.daemon_stats.memory_pressure // 0')\n"
    metrics+="nftban.daemon.memory_health $(echo "$json" | jq -r '.daemon_stats.memory_health // 0')\n"

    # GeoIP metrics
    metrics+="nftban.geoip.database_age $(echo "$json" | jq -r '.geoip.database_age // 0')\n"
    metrics+="nftban.geoip.countries_blocked $(echo "$json" | jq -r '.geoip.countries_blocked // 0')\n"

    # Kernel metrics (Phase 1)
    metrics+="nftban.conntrack.entries $(echo "$json" | jq -r '.kernel.conntrack_entries // 0')\n"
    metrics+="nftban.conntrack.max $(echo "$json" | jq -r '.kernel.conntrack_max // 0')\n"
    metrics+="nftban.conntrack.utilization $(echo "$json" | jq -r '.kernel.conntrack_utilization // 0')\n"
    metrics+="nftban.softnet.drops $(echo "$json" | jq -r '.kernel.softnet_drops // 0')\n"
    metrics+="nftban.softnet.backlog $(echo "$json" | jq -r '.kernel.softnet_backlog // 0')\n"

    # Module status (Phase 1) - 1=up, 0=down
    for module in suricata loginmon portscan ddos feeds geoban watchdog; do
        metrics+="nftban.module.up[${module}] $(echo "$json" | jq -r ".module_status.${module} // 0")\n"
    done

    # Suricata IDS metrics
    metrics+="nftban.suricata.up $(echo "$json" | jq -r '.suricata.up // 0')\n"

    # Suricata version (get directly from suricata command if available)
    local suricata_version="not installed"
    if command -v suricata &>/dev/null; then
        suricata_version=$(suricata --build-info 2>/dev/null | grep -oP 'Suricata version \K[0-9.]+' || suricata -V 2>/dev/null | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || echo "unknown")
    fi
    metrics+="nftban.suricata.version $suricata_version\n"
    metrics+="nftban.suricata.alerts.total $(echo "$json" | jq -r '.suricata.alerts_total // 0')\n"
    metrics+="nftban.suricata.alerts.severity[1] $(echo "$json" | jq -r '.suricata.alerts_by_severity."1" // 0')\n"
    metrics+="nftban.suricata.alerts.severity[2] $(echo "$json" | jq -r '.suricata.alerts_by_severity."2" // 0')\n"
    metrics+="nftban.suricata.alerts.severity[3] $(echo "$json" | jq -r '.suricata.alerts_by_severity."3" // 0')\n"
    metrics+="nftban.suricata.alerts.severity[4] $(echo "$json" | jq -r '.suricata.alerts_by_severity."4" // 0')\n"
    metrics+="nftban.suricata.rules.total $(echo "$json" | jq -r '.suricata.rules_total // 0')\n"
    metrics+="nftban.suricata.rules.filtered $(echo "$json" | jq -r '.suricata.rules_filtered // 0')\n"
    metrics+="nftban.suricata.bans.total $(echo "$json" | jq -r '.suricata.bans_total // 0')\n"
    metrics+="nftban.suricata.eve_errors $(echo "$json" | jq -r '.suricata.eve_parse_errors // 0')\n"
    metrics+="nftban.suricata.last_alert $(echo "$json" | jq -r '.suricata.last_alert_timestamp // 0')\n"

    # Suricata v1.9.1 metrics (categories and local rules)
    # Compute directly from config files if JSON doesn't have them
    local categories_enabled=0 local_rules_count=0
    if [[ -f "/etc/nftban/suricata/rules/categories.enabled" ]]; then
        categories_enabled=$(grep -cv "^#\|^$" /etc/nftban/suricata/rules/categories.enabled 2>/dev/null || echo "0")
    fi
    if [[ -f "/etc/nftban/suricata/rules/local.rules" ]]; then
        local_rules_count=$(grep -c "^alert\|^drop\|^reject" /etc/nftban/suricata/rules/local.rules 2>/dev/null || echo "0")
    fi
    metrics+="nftban.suricata.categories.enabled $categories_enabled\n"
    metrics+="nftban.suricata.local_rules $local_rules_count\n"

    # Event Bus metrics
    metrics+="nftban.eventbus.events.total $(echo "$json" | jq -r '.eventbus.events_total // 0')\n"
    metrics+="nftban.eventbus.events.dropped $(echo "$json" | jq -r '.eventbus.events_dropped // 0')\n"
    metrics+="nftban.eventbus.queue_size $(echo "$json" | jq -r '.eventbus.queue_size // 0')\n"
    metrics+="nftban.eventbus.handlers $(echo "$json" | jq -r '.eventbus.handlers_total // 0')\n"

    # NFTables Performance metrics
    metrics+="nftban.nftables.apply_latency $(echo "$json" | jq -r '.nftables_perf.apply_latency_ms // 0')\n"
    metrics+="nftban.nftables.apply_errors $(echo "$json" | jq -r '.nftables_perf.apply_errors_total // 0')\n"
    metrics+="nftban.nftables.rules.total $(echo "$json" | jq -r '.nftables_perf.rules_total // 0')\n"
    metrics+="nftban.nftables.sets.total $(echo "$json" | jq -r '.nftables_perf.sets_total // 0')\n"
    metrics+="nftban.nftables.commands.total $(echo "$json" | jq -r '.nftables_perf.commands_total // 0')\n"

    # Ban Details (Phase 4)
    for src in manual feeds loginmon portscan ddos suricata geoban; do
        metrics+="nftban.bans.source[${src}] $(echo "$json" | jq -r ".ban_details.bans_by_source.${src} // 0")\n"
    done
    metrics+="nftban.escalations.total $(echo "$json" | jq -r '.ban_details.escalations_total // 0')\n"
    metrics+="nftban.persistent.total $(echo "$json" | jq -r '.ban_details.persistent_offenders_total // 0')\n"
    metrics+="nftban.recidivist.total $(echo "$json" | jq -r '.ban_details.recidivist_ips_total // 0')\n"

    # Analytics (Phase 5)
    metrics+="nftban.analytics.unique_ips_24h $(echo "$json" | jq -r '.analytics.unique_ips_24h // 0')\n"
    metrics+="nftban.analytics.recidivism_rate $(echo "$json" | jq -r '.analytics.recidivism_rate // 0')\n"
    metrics+="nftban.analytics.top_attackers $(echo "$json" | jq -r '.analytics.top_attackers_total // 0')\n"
    metrics+="nftban.watchdog.mode_transitions $(echo "$json" | jq -r '.analytics.watchdog_mode_transitions_total // 0')\n"
    metrics+="nftban.geoban.db_age $(echo "$json" | jq -r '.analytics.geoban_database_age_seconds // 0')\n"

    # Feed health metrics (Phase 1)
    metrics+="nftban.feeds.total $(echo "$json" | jq -r '.feed_health.total_feeds // 0')\n"
    metrics+="nftban.feeds.active $(echo "$json" | jq -r '.feed_health.active_feeds // 0')\n"
    metrics+="nftban.feeds.stale $(echo "$json" | jq -r '.feed_health.stale_feeds // 0')\n"
    metrics+="nftban.feeds.sync_errors $(echo "$json" | jq -r '.feed_health.sync_errors_24h // 0')\n"

    # Watchdog metrics (from daemon stats)
    metrics+="nftban.watchdog.status $(echo "$json" | jq -r '.watchdog.status // 0')\n"
    metrics+="nftban.watchdog.mode $(echo "$json" | jq -r '.watchdog.mode // "unknown"')\n"
    metrics+="nftban.watchdog.cpu_score $(echo "$json" | jq -r '.watchdog.cpu_score // 0')\n"
    metrics+="nftban.watchdog.mem_score $(echo "$json" | jq -r '.watchdog.mem_score // 0')\n"
    metrics+="nftban.watchdog.io_score $(echo "$json" | jq -r '.watchdog.io_score // 0')\n"

    # Daemon mode (check both sources: daemon_mode from watchdog, or daemon.mode from inventory)
    metrics+="nftban.mode $(echo "$json" | jq -r '.daemon_mode // .daemon.mode // "unknown"')\n"

    # Server inventory (if present)
    if echo "$json" | jq -e '.server' &>/dev/null; then
        metrics+="nftban.server.hostname $(echo "$json" | jq -r '.server.hostname // ""')\n"
        # Region: check both server_region (from daemon stats) and server.region (from inventory)
        metrics+="nftban.server.region $(echo "$json" | jq -r '.server_region // .server.region // "unknown"')\n"
        metrics+="nftban.server.fqdn $(echo "$json" | jq -r '.server.fqdn // ""')\n"
        metrics+="nftban.server.os $(echo "$json" | jq -r '.server.os // ""')\n"
        metrics+="nftban.server.os_release $(echo "$json" | jq -r '.server.os_release // ""')\n"
        metrics+="nftban.server.kernel $(echo "$json" | jq -r '.server.kernel // ""')\n"

        # Combined OS full string for Zabbix inventory "OS (Full details)"
        local os_name os_release kernel_ver
        os_name=$(echo "$json" | jq -r '.server.os // "Linux"')
        os_release=$(echo "$json" | jq -r '.server.os_release // ""')
        kernel_ver=$(echo "$json" | jq -r '.server.kernel // ""')
        metrics+="nftban.server.os_full ${os_release} (${kernel_ver})\n"
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

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "=== DRY RUN: Would send to $ZABBIX_SERVER:$ZABBIX_PORT ==="
        echo "Hostname: $ZABBIX_HOSTNAME"
        echo "$metrics"
        return 0
    fi

    # Prefer zabbix_sender (official tool, handles protocol correctly)
    if command -v zabbix_sender &>/dev/null; then
        _send_via_zabbix_sender "$metrics"
        return $?
    fi

    # Fallback: native Zabbix protocol via nc
    if command -v nc &>/dev/null; then
        _send_via_nc "$metrics"
        return $?
    fi

    log_error "No transport available: install zabbix_sender or nc (nmap-ncat)"
    return 1
}

# Send metrics using zabbix_sender (preferred)
_send_via_zabbix_sender() {
    local metrics="$1"
    local sender_file
    sender_file=$(mktemp /tmp/nftban_zabbix_XXXXXX.txt)

    # Convert "key value" to tab-separated "hostname\tkey\tvalue" for zabbix_sender
    while IFS=' ' read -r key value; do
        [[ -z "$key" ]] && continue
        printf '%s\t%s\t%s\n' "$ZABBIX_HOSTNAME" "$key" "$value" >> "$sender_file"
    done <<< "$(echo -e "$metrics")"

    local count
    count=$(wc -l < "$sender_file")
    log_info "Sending $count metrics via zabbix_sender..."

    local response=""
    local exit_code=0
    response=$(zabbix_sender -z "$ZABBIX_SERVER" -p "$ZABBIX_PORT" -i "$sender_file" 2>&1) || exit_code=$?
    rm -f "$sender_file"

    # zabbix_sender exit codes: 0=all ok, 1=some failed, 2=send error
    # Partial success (some processed) is acceptable — template may not cover all keys
    local processed
    processed=$(echo "$response" | { grep -oP 'processed:\s*\K[0-9]+' || echo "0"; })

    if [[ $exit_code -eq 0 ]]; then
        log_info "Zabbix: $response"
        return 0
    elif [[ "$processed" -gt 0 ]]; then
        log_info "Zabbix: $response"
        log_info "Partial success — import full template for remaining keys"
        return 0
    else
        log_error "zabbix_sender failed (exit $exit_code): $response"
        return 1
    fi
}

# Send metrics using native Zabbix protocol via nc (fallback)
_send_via_nc() {
    local metrics="$1"

    # Build Zabbix sender data JSON
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

    # Send using native Zabbix protocol
    local data_len=${#data}

    # Build length header (8 bytes, little-endian)
    local len_hex
    len_hex=$(printf '%016x' "$data_len")

    log_info "Sending via nc (native protocol)..."

    # Send: ZBXD\x01 + length (8 bytes LE) + data
    local response=""
    response=$( (
        printf 'ZBXD\x01'
        printf "\\x${len_hex:14:2}\\x${len_hex:12:2}\\x${len_hex:10:2}\\x${len_hex:8:2}"
        printf '\x00\x00\x00\x00'
        printf '%s' "$data"
    ) 2>/dev/null | timeout 10 nc "$ZABBIX_SERVER" "$ZABBIX_PORT" 2>/dev/null | tr -d '\0' | { strings || true; } ) || response=""

    if [[ -n "${response:-}" ]] && echo "$response" | grep -q '"response":"success"'; then
        local info
        info=$(echo "$response" | { grep -oP '"info":"\K[^"]+' || true; })
        log_info "Zabbix: ${info:-sent}"
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
    local count
    count=$(echo -e "$zabbix_metrics" | grep -c "^nftban\." || echo "0")
    log_info "Prepared $count metrics"

    # Send to Zabbix
    log_info "Sending to $ZABBIX_SERVER:$ZABBIX_PORT..."
    send_to_zabbix "$zabbix_metrics"
}

main "$@"
