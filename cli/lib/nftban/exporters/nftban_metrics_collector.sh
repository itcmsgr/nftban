#!/usr/bin/env bash
# =============================================================================
# NFTBan Central Metrics Collector
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_metrics_collector"
# meta:type="exporter"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:version="1.0.0"
# meta:created_date="2026-01-24"
# meta:description="Central metrics collector - collect once, export to any backend"
# meta:inventory.files="/var/cache/nftban/metrics/"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftban-metrics-collector.timer"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
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
        ipv4=$(nft -j list set inet nftban blacklist_ipv4 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
        ipv6=$(nft -j list set inet nftban blacklist_ipv6 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
        active=$((ipv4 + ipv6))

        # Whitelist
        local wl4 wl6
        wl4=$(nft -j list set inet nftban whitelist_ipv4 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
        wl6=$(nft -j list set inet nftban whitelist_ipv6 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
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
    [[ -f "${NFTBAN_CONFIG_DIR}/permanent.list" ]] && permanent=$(grep -cE "^[0-9]" "${NFTBAN_CONFIG_DIR}/permanent.list" 2>/dev/null || echo "0")

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
        fds=$(ls -1 "/proc/$pid/fd" 2>/dev/null | wc -l || echo "0")
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

collect_nftables_metrics() {
    local sets=0 elements=0 rules=0 packets_ipv4=0 packets_ipv6=0

    if command -v nft &>/dev/null && nft list table inet nftban &>/dev/null 2>&1; then
        sets=$(nft list sets inet nftban 2>/dev/null | grep -c "set " || echo "0")

        for set_name in blacklist_ipv4 blacklist_ipv6 whitelist_ipv4 whitelist_ipv6; do
            local count
            count=$(nft -j list set inet nftban "$set_name" 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
            elements=$((elements + count))
        done

        rules=$(nft list table inet nftban 2>/dev/null | grep -cE "^\s+(accept|drop|reject|return|jump|goto)" || echo "0")

        packets_ipv4=$(nft -j list chain inet nftban input 2>/dev/null | jq -r '[.nftables[]?.rule?.expr[]? | select(.counter) | .counter.packets] | add // 0' 2>/dev/null || echo "0")
        packets_ipv6=$(nft -j list chain inet nftban input6 2>/dev/null | jq -r '[.nftables[]?.rule?.expr[]? | select(.counter) | .counter.packets] | add // 0' 2>/dev/null || echo "0")
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
    for iface in $(ls /sys/class/net/ 2>/dev/null | grep -v lo); do
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
        connections_established=$(ss -t state established 2>/dev/null | wc -l || echo "0")
        connections_time_wait=$(ss -t state time-wait 2>/dev/null | wc -l || echo "0")
        connections_close_wait=$(ss -t state close-wait 2>/dev/null | wc -l || echo "0")
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

    # Parse daemon stats
    local goroutines=0 heap_mb=0 alloc_mb=0 sys_mb=0 gc_cycles=0 gc_pause_ms=0
    local bans_total=0 unbans_total=0 events_total=0 bans_per_min=0
    local ipc_requests=0 ipc_latency_ms=0 ipc_errors=0

    if [[ -n "$daemon_json" ]] && echo "$daemon_json" | jq -e . &>/dev/null; then
        goroutines=$(echo "$daemon_json" | jq -r '.runtime.goroutines // 0')
        heap_mb=$(echo "$daemon_json" | jq -r '.runtime.memory_heap_mb // 0')
        alloc_mb=$(echo "$daemon_json" | jq -r '.runtime.memory_alloc_mb // 0')
        sys_mb=$(echo "$daemon_json" | jq -r '.runtime.memory_sys_mb // 0')
        gc_cycles=$(echo "$daemon_json" | jq -r '.runtime.gc_cycles // 0')
        gc_pause_ms=$(echo "$daemon_json" | jq -r '.runtime.gc_pause_ms // 0')
        bans_total=$(echo "$daemon_json" | jq -r '.throughput.bans_total // 0')
        unbans_total=$(echo "$daemon_json" | jq -r '.throughput.unbans_total // 0')
        events_total=$(echo "$daemon_json" | jq -r '.throughput.events_total // 0')
        bans_per_min=$(echo "$daemon_json" | jq -r '.throughput.bans_per_min // 0')
        ipc_requests=$(echo "$daemon_json" | jq -r '.ipc.requests_total // 0')
        ipc_latency_ms=$(echo "$daemon_json" | jq -r '.ipc.avg_latency_ms // 0')
        ipc_errors=$(echo "$daemon_json" | jq -r '.ipc.errors_total // 0')
    fi

    # Parse system check
    local load_1m=0 load_5m=0 load_15m=0
    local mem_used_pct=0 mem_available_mb=0
    local iowait_pct=0 disk_used_pct=0

    if [[ -n "$system_json" ]] && echo "$system_json" | jq -e . &>/dev/null; then
        load_1m=$(echo "$system_json" | jq -r '.load["1m"] // "0"')
        load_5m=$(echo "$system_json" | jq -r '.load["5m"] // "0"')
        load_15m=$(echo "$system_json" | jq -r '.load["15m"] // "0"')
        mem_used_pct=$(echo "$system_json" | jq -r '.memory.used_percent // "0"')
        mem_available_mb=$(echo "$system_json" | jq -r '.memory.available_mb // "0"')
        iowait_pct=$(echo "$system_json" | jq -r '.iowait.percent // "0"')
        disk_used_pct=$(echo "$system_json" | jq -r '.disk.used_percent // "0"')
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

    local db_path=""
    for path in "/var/lib/nftban/geoip/GeoLite2-Country.mmdb" \
                "/usr/share/GeoIP/GeoLite2-Country.mmdb" \
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
    local cidr=$(ip -4 addr show "$primary_iface" 2>/dev/null | awk '/inet/{print $2}' | cut -d'/' -f2 | head -1)
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
    local timestamp daemon bans memory health modules nftables feeds network watchdog geoip
    timestamp=$(date +%s)

    daemon=$(collect_daemon_metrics)
    bans=$(collect_ban_metrics)
    memory=$(collect_memory_metrics)
    health=$(collect_health_metrics)
    modules=$(collect_module_metrics)
    nftables=$(collect_nftables_metrics)
    feeds=$(collect_feeds_metrics)
    network=$(collect_network_metrics)
    watchdog=$(collect_watchdog_metrics)
    geoip=$(collect_geoip_metrics)

    # Merge all JSON objects
    echo "$daemon $bans $memory $health $modules $nftables $feeds $network $watchdog $geoip" | \
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
