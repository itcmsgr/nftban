#!/usr/bin/env bash
# =============================================================================
# NFTBan Zabbix Exporter (Bash Fallback)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_zabbix_exporter"
# meta:type="exporter"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:version="1.0.0"
# meta:created_date="2026-01-22"
# meta:description="Bash fallback exporter for Zabbix metrics collection"
# meta:inventory.files=""
# meta:inventory.binaries="zabbix_sender(optional)"
# meta:inventory.env_vars="NFTBAN_ZABBIX_SERVER,NFTBAN_ZABBIX_PORT,NFTBAN_ZABBIX_HOSTNAME"
# meta:inventory.config_files="/etc/nftban/nftban.conf"
# meta:inventory.systemd_units="nftban-zabbix-exporter.timer"
# meta:inventory.network="10051/tcp"
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail

# Bootstrap paths (nftban.conf will set these as readonly)
: "${NFTBAN_CONFIG_DIR:=/etc/nftban}"
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
: "${NFTBAN_RUN_DIR:=/run/nftban}"
: "${NFTBAN_LOG_DIR:=/var/log/nftban}"
: "${NFTBAN_CACHE_DIR:=/var/cache/nftban}"

# Load config (sets readonly paths and all settings)
if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/nftban.conf"
fi

# Load user overrides (highest priority)
if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf.local" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/nftban.conf.local" 2>/dev/null || true
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

# Zabbix server settings
ZABBIX_ENABLED="${NFTBAN_ZABBIX_ENABLED:-false}"
ZABBIX_SERVER="${NFTBAN_ZABBIX_SERVER:-}"
ZABBIX_PORT="${NFTBAN_ZABBIX_PORT:-10051}"
ZABBIX_HOSTNAME="${NFTBAN_ZABBIX_HOSTNAME:-auto}"

# Resolve hostname if auto
if [[ "$ZABBIX_HOSTNAME" == "auto" ]]; then
    ZABBIX_HOSTNAME=$(hostname -f 2>/dev/null || hostname)
fi

# Runtime options
DRY_RUN=false
VERBOSE=false
JSON_OUTPUT=false
FORCE_INVENTORY=false

# Buffer settings (for offline metric storage)
BUFFER_DIR="${NFTBAN_CACHE_DIR}/zabbix_buffer"
BUFFER_MAX_AGE=86400  # 1 day in seconds

# Inventory collection settings (static data doesn't change often)
INVENTORY_INTERVAL=3600  # Collect inventory every 1 hour (3600 seconds)
INVENTORY_STAMP_FILE="${NFTBAN_CACHE_DIR}/zabbix_inventory_stamp"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() {
    [[ "$VERBOSE" == "true" ]] && echo "[INFO] $*" || true
}

log_error() {
    echo "[ERROR] $*" >&2
}

# Check if inventory collection is needed (runs hourly, not every minute)
should_collect_inventory() {
    [[ "$FORCE_INVENTORY" == "true" ]] && return 0

    if [[ ! -f "$INVENTORY_STAMP_FILE" ]]; then
        return 0  # No stamp file, collect inventory
    fi

    local last_run now_epoch age
    last_run=$(cat "$INVENTORY_STAMP_FILE" 2>/dev/null || echo "0")
    now_epoch=$(date +%s)
    age=$((now_epoch - last_run))

    if [[ $age -ge $INVENTORY_INTERVAL ]]; then
        return 0  # Interval passed, collect inventory
    fi

    return 1  # Skip inventory collection
}

# Update inventory collection timestamp
update_inventory_stamp() {
    mkdir -p "$(dirname "$INVENTORY_STAMP_FILE")" 2>/dev/null || true
    date +%s > "$INVENTORY_STAMP_FILE"
}

# =============================================================================
# BUFFER FUNCTIONS (offline metric storage, max 1 day retention)
# =============================================================================

buffer_init() {
    # Create buffer directory if needed
    mkdir -p "$BUFFER_DIR" 2>/dev/null || true
}

buffer_save() {
    # Save metrics to buffer file on send failure
    local metrics="$1"
    local timestamp
    timestamp=$(date +%s)

    buffer_init
    echo "$metrics" > "${BUFFER_DIR}/${timestamp}.metrics"
    log_info "Buffered metrics to ${BUFFER_DIR}/${timestamp}.metrics"
}

buffer_cleanup() {
    # Remove buffer files older than BUFFER_MAX_AGE
    [[ ! -d "$BUFFER_DIR" ]] && return 0

    local now cutoff
    now=$(date +%s)
    cutoff=$((now - BUFFER_MAX_AGE))

    local count=0
    for file in "${BUFFER_DIR}"/*.metrics; do
        [[ -f "$file" ]] || continue
        local ts
        ts=$(basename "$file" .metrics)
        if [[ "$ts" =~ ^[0-9]+$ ]] && [[ "$ts" -lt "$cutoff" ]]; then
            rm -f "$file"
            ((count++)) || true
        fi
    done

    [[ $count -gt 0 ]] && log_info "Cleaned up $count expired buffer files"
}

buffer_send() {
    # Try to send buffered metrics (called after successful live send)
    [[ ! -d "$BUFFER_DIR" ]] && return 0

    local sent=0
    for file in "${BUFFER_DIR}"/*.metrics; do
        [[ -f "$file" ]] || continue
        local buffered_metrics
        buffered_metrics=$(cat "$file")

        log_info "Sending buffered metrics from $(basename "$file")..."
        if _send_metrics "$buffered_metrics"; then
            rm -f "$file"
            ((sent++)) || true
        else
            log_error "Failed to send buffered metrics, will retry later"
            break  # Stop on first failure
        fi
    done

    [[ $sent -gt 0 ]] && log_info "Sent $sent buffered metric sets"
}

# =============================================================================
# METRIC COLLECTION FUNCTIONS
# =============================================================================

collect_daemon_metrics() {
    # Daemon status and info metrics
    local metrics=""

    # Version - prefer config variable, then check file locations
    local version="unknown"
    if [[ -n "${NFTBAN_VERSION:-}" && "${NFTBAN_VERSION}" != "unknown" ]]; then
        version="${NFTBAN_VERSION}"
    elif [[ -f "${NFTBAN_LIB_DIR}/VERSION" ]]; then
        version=$(cat "${NFTBAN_LIB_DIR}/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "unknown")
    elif [[ -f "/usr/lib/nftban/VERSION" ]]; then
        version=$(cat "/usr/lib/nftban/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "unknown")
    elif [[ -f "/opt/nftban/VERSION" ]]; then
        version=$(cat "/opt/nftban/VERSION" 2>/dev/null | head -1 | tr -d '[:space:]' || echo "unknown")
    fi
    metrics+="nftban.version $version\n"

    # Daemon status (1=running, 0=stopped) - use central config variable
    local daemon_service="${NFTBAN_SERVICE_DAEMON:-nftband.service}"
    local status=0
    if systemctl is-active "$daemon_service" &>/dev/null; then
        status=1
    fi
    metrics+="nftban.status $status\n"

    # Uptime (seconds since daemon start)
    if [[ $status -eq 1 ]]; then
        local start_time
        start_time=$(systemctl show "$daemon_service" -p ActiveEnterTimestamp --value 2>/dev/null || echo "")
        if [[ -n "$start_time" ]]; then
            local start_epoch now_epoch uptime
            start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            uptime=$((now_epoch - start_epoch))
            metrics+="nftban.uptime $uptime\n"
        fi
    fi

    # PID - daemon is nftband
    local pid=""
    if [[ -f "${NFTBAN_RUN_DIR}/nftband.pid" ]]; then
        pid=$(cat "${NFTBAN_RUN_DIR}/nftband.pid" 2>/dev/null || echo "")
    fi
    [[ -n "$pid" ]] && metrics+="nftban.pid $pid\n"

    # Mode (normal/degraded/survival)
    local mode="normal"
    if [[ -f "${NFTBAN_RUN_DIR}/mode" ]]; then
        mode=$(cat "${NFTBAN_RUN_DIR}/mode" 2>/dev/null || echo "normal")
    fi
    metrics+="nftban.mode $mode\n"

    echo -e "$metrics"
}

collect_ban_metrics() {
    # Ban statistics
    local metrics=""

    # Get active ban count from nftables
    local active_ipv4=0 active_ipv6=0
    if command -v nft &>/dev/null; then
        # Fast JSON method
        active_ipv4=$(nft -j list set inet nftban blacklist_ipv4 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
        active_ipv6=$(nft -j list set inet nftban blacklist_ipv6 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
    fi
    local active_total=$((active_ipv4 + active_ipv6))
    metrics+="nftban.active.count $active_total\n"

    # Get bans from log file for time-based stats
    local bans_log="${NFTBAN_LOG_DIR}/bans.log"
    if [[ -f "$bans_log" ]]; then
        local now_epoch
        now_epoch=$(date +%s)

        # Bans in last 24 hours
        local bans_24h=0
        local cutoff_24h=$((now_epoch - 86400))
        bans_24h=$(awk -F'|' -v cutoff="$cutoff_24h" '
            $1 ~ /^[0-9]+$/ && $1 >= cutoff { count++ }
            END { print count+0 }
        ' "$bans_log" 2>/dev/null || echo "0")
        metrics+="nftban.bans.24h $bans_24h\n"

        # Bans in last hour
        local bans_1h=0
        local cutoff_1h=$((now_epoch - 3600))
        bans_1h=$(awk -F'|' -v cutoff="$cutoff_1h" '
            $1 ~ /^[0-9]+$/ && $1 >= cutoff { count++ }
            END { print count+0 }
        ' "$bans_log" 2>/dev/null || echo "0")
        metrics+="nftban.bans.1h $bans_1h\n"

        # Ban rate per minute (based on last 5 minutes)
        local cutoff_5m=$((now_epoch - 300))
        local bans_5m
        bans_5m=$(awk -F'|' -v cutoff="$cutoff_5m" '
            $1 ~ /^[0-9]+$/ && $1 >= cutoff { count++ }
            END { print count+0 }
        ' "$bans_log" 2>/dev/null || echo "0")
        local rate
        rate=$(echo "scale=2; $bans_5m / 5" | bc 2>/dev/null || echo "0")
        metrics+="nftban.bans.rate $rate\n"

        # Total bans (line count)
        local total_bans
        total_bans=$(wc -l < "$bans_log" 2>/dev/null || echo "0")
        metrics+="nftban.bans.total $total_bans\n"
    fi

    # Permanent bans
    local permanent_count=0
    if [[ -f "${NFTBAN_CONFIG_DIR}/permanent.list" ]]; then
        permanent_count=$(grep -cE "^[0-9]" "${NFTBAN_CONFIG_DIR}/permanent.list" 2>/dev/null || echo "0")
    fi
    metrics+="nftban.permanent.count $permanent_count\n"

    # Whitelist count (from file + nftables set)
    local whitelist_count=0
    if [[ -f "${NFTBAN_CONFIG_DIR}/whitelist.conf" ]]; then
        whitelist_count=$(grep -cE "^[0-9]" "${NFTBAN_CONFIG_DIR}/whitelist.conf" 2>/dev/null || echo "0")
    fi
    # Also check nftables whitelist sets
    if command -v nft &>/dev/null; then
        local wl_ipv4 wl_ipv6
        wl_ipv4=$(nft -j list set inet nftban whitelist_ipv4 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
        wl_ipv6=$(nft -j list set inet nftban whitelist_ipv6 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
        whitelist_count=$((whitelist_count + wl_ipv4 + wl_ipv6))
    fi
    metrics+="nftban.whitelist.count $whitelist_count\n"

    echo -e "$metrics"
}

collect_memory_metrics() {
    # Memory metrics (from /proc if daemon is running)
    local metrics=""
    local daemon_service="${NFTBAN_SERVICE_DAEMON:-nftband.service}"

    # Get PID - try multiple methods
    local pid=""
    if [[ -f "${NFTBAN_RUN_DIR}/nftband.pid" ]]; then
        pid=$(cat "${NFTBAN_RUN_DIR}/nftband.pid" 2>/dev/null || echo "")
    fi
    # Fallback: get PID from systemctl
    if [[ -z "$pid" ]] || [[ ! -d "/proc/$pid" ]]; then
        pid=$(systemctl show "$daemon_service" -p MainPID --value 2>/dev/null || echo "")
    fi

    if [[ -n "$pid" ]] && [[ "$pid" != "0" ]] && [[ -d "/proc/$pid" ]]; then
        # RSS (Resident Set Size) in bytes
        local rss
        rss=$(awk '/VmRSS/ {print $2 * 1024}' "/proc/$pid/status" 2>/dev/null || echo "0")
        metrics+="nftban.memory.rss $rss\n"

        # Open file descriptors
        local fds
        fds=$(ls -1 "/proc/$pid/fd" 2>/dev/null | wc -l || echo "0")
        metrics+="nftban.fds.open $fds\n"

        # Threads
        local threads
        threads=$(awk '/Threads/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo "0")
        metrics+="nftban.threads $threads\n"

        # Goroutines (from daemon status endpoint if available)
        local goroutines=0
        if [[ -S "${NFTBAN_RUN_DIR}/nftband.sock" ]]; then
            goroutines=$(echo '{"cmd":"status"}' | timeout 2 socat - "UNIX-CONNECT:${NFTBAN_RUN_DIR}/nftband.sock" 2>/dev/null | jq -r '.goroutines // 0' 2>/dev/null || echo "0")
        fi
        [[ "$goroutines" != "0" ]] && metrics+="nftban.goroutines $goroutines\n"
    fi

    echo -e "$metrics"
}

collect_health_metrics() {
    # Health check metrics
    local metrics=""
    local health_file="${NFTBAN_RUN_DIR}/health.status"

    if [[ -f "$health_file" ]]; then
        local passed failed status
        passed=$(jq -r '.passed // 0' "$health_file" 2>/dev/null || echo "0")
        failed=$(jq -r '.failed // 0' "$health_file" 2>/dev/null || echo "0")
        status=$(jq -r '.healthy // false' "$health_file" 2>/dev/null || echo "false")

        metrics+="nftban.health.passed $passed\n"
        metrics+="nftban.health.failed $failed\n"
        [[ "$status" == "true" ]] && metrics+="nftban.health.status 1\n" || metrics+="nftban.health.status 0\n"
    fi

    echo -e "$metrics"
}

collect_module_metrics() {
    # Module status metrics
    local metrics=""

    # Count enabled modules
    local enabled=0 active=0 failed=0

    for module in login portscan ddos feeds geoban suricata rbl botscan; do
        if [[ -f "${NFTBAN_CONFIG_DIR}/modules/${module}.conf" ]]; then
            ((enabled++))
            # Check if module service/timer is active
            if systemctl is-active "nftban-${module}.timer" &>/dev/null 2>&1 || \
               systemctl is-active "nftban-${module}.service" &>/dev/null 2>&1; then
                ((active++))
            elif systemctl is-failed "nftban-${module}.service" &>/dev/null 2>&1; then
                ((failed++))
            fi
        fi
    done

    metrics+="nftban.modules.enabled $enabled\n"
    metrics+="nftban.modules.active $active\n"
    metrics+="nftban.modules.failed $failed\n"

    echo -e "$metrics"
}

collect_nftables_metrics() {
    # nftables metrics
    local metrics=""

    if command -v nft &>/dev/null && nft list table inet nftban &>/dev/null; then
        # Count total sets
        local sets_count
        sets_count=$(nft list sets inet nftban 2>/dev/null | grep -c "set " || true)
        : "${sets_count:=0}"
        metrics+="nftban.nft.sets_total $sets_count\n"

        # Count total elements across all sets (fast method)
        local elements_total=0
        for set_name in blacklist_ipv4 blacklist_ipv6 whitelist_ipv4 whitelist_ipv6; do
            local count
            count=$(nft -j list set inet nftban "$set_name" 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || true)
            : "${count:=0}"
            elements_total=$((elements_total + count))
        done
        metrics+="nftban.nft.elements_total $elements_total\n"

        # Count rules (approximate)
        local rules_count
        rules_count=$(nft list table inet nftban 2>/dev/null | grep -cE "^\s+(accept|drop|reject|return|jump|goto)" || true)
        : "${rules_count:=0}"
        metrics+="nftban.nft.rules_total $rules_count\n"

        # Packets blocked (from counter rules if available)
        local packets_ipv4=0 packets_ipv6=0
        # Try to get packet counters from nft counters or chain statistics
        packets_ipv4=$(nft -j list chain inet nftban input 2>/dev/null | jq -r '[.nftables[]?.rule?.expr[]? | select(.counter) | .counter.packets] | add // 0' 2>/dev/null || echo "0")
        packets_ipv6=$(nft -j list chain inet nftban input6 2>/dev/null | jq -r '[.nftables[]?.rule?.expr[]? | select(.counter) | .counter.packets] | add // 0' 2>/dev/null || echo "0")
        metrics+="nftban.nft.packets_blocked_ipv4 $packets_ipv4\n"
        metrics+="nftban.nft.packets_blocked_ipv6 $packets_ipv6\n"
    else
        # Table doesn't exist, report zeros
        metrics+="nftban.nft.sets_total 0\n"
        metrics+="nftban.nft.elements_total 0\n"
        metrics+="nftban.nft.rules_total 0\n"
        metrics+="nftban.nft.packets_blocked_ipv4 0\n"
        metrics+="nftban.nft.packets_blocked_ipv6 0\n"
    fi

    echo -e "$metrics"
}

collect_feeds_metrics() {
    # Threat feeds metrics
    local metrics=""

    local enabled=0 loaded=0 failed=0 total_ips=0

    if [[ -d "${NFTBAN_CONFIG_DIR}/feeds" ]]; then
        for feed_file in "${NFTBAN_CONFIG_DIR}/feeds"/*.conf; do
            [[ -f "$feed_file" ]] || continue
            ((enabled++))

            local feed_name
            feed_name=$(basename "$feed_file" .conf)
            local feed_data="${NFTBAN_CACHE_DIR}/feeds/${feed_name}.list"

            if [[ -f "$feed_data" ]]; then
                ((loaded++))
                local feed_ips
                feed_ips=$(wc -l < "$feed_data" 2>/dev/null || echo "0")
                total_ips=$((total_ips + feed_ips))
            else
                ((failed++))
            fi
        done
    fi

    metrics+="nftban.feeds.enabled $enabled\n"
    metrics+="nftban.feeds.loaded $loaded\n"
    metrics+="nftban.feeds.failed $failed\n"
    metrics+="nftban.feeds.ips_total $total_ips\n"

    echo -e "$metrics"
}

collect_geoip_metrics() {
    # GeoIP metrics
    local metrics=""

    # Check database age
    local db_path=""
    for path in "/var/lib/nftban/geoip/GeoLite2-Country.mmdb" \
                "/usr/share/GeoIP/GeoLite2-Country.mmdb" \
                "${NFTBAN_LIB_DIR}/data/GeoLite2-Country.mmdb"; do
        if [[ -f "$path" ]]; then
            db_path="$path"
            break
        fi
    done

    if [[ -n "$db_path" ]]; then
        local db_mtime now_epoch age_days
        db_mtime=$(stat -c %Y "$db_path" 2>/dev/null || echo "0")
        now_epoch=$(date +%s)
        age_days=$(( (now_epoch - db_mtime) / 86400 ))
        metrics+="nftban.geoip.database_age $age_days\n"

        # Count blocked countries
        if [[ -f "${NFTBAN_CONFIG_DIR}/modules/geoban.conf" ]]; then
            # shellcheck source=/dev/null
            source "${NFTBAN_CONFIG_DIR}/modules/geoban.conf"
            local country_count
            # shellcheck disable=SC2153
            country_count=$(echo "${NFTBAN_GEOBAN_COUNTRIES:-}" | wc -w 2>/dev/null || echo "0")
            metrics+="nftban.geoip.countries_blocked $country_count\n"
        fi
    fi

    echo -e "$metrics"
}

collect_server_metrics() {
    # Server info metrics (full inventory for Zabbix 7.x)
    local metrics=""

    # Basic identification
    metrics+="nftban.server.hostname $(hostname -s 2>/dev/null || hostname)\n"
    metrics+="nftban.server.fqdn $(hostname -f 2>/dev/null || hostname)\n"

    # OS information
    local os_id os_pretty
    os_id=$(grep -m1 "^ID=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "linux")
    os_pretty=$(grep -m1 "^PRETTY_NAME=" /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "Linux")
    metrics+="nftban.server.os ${os_id}\n"
    metrics+="nftban.server.os_release ${os_pretty}\n"
    metrics+="nftban.server.kernel $(uname -r)\n"
    metrics+="nftban.server.arch $(uname -m)\n"

    # CPU information
    local cpu_cores cpu_model
    cpu_cores=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")
    cpu_model=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "Unknown")
    metrics+="nftban.server.cpu_cores $cpu_cores\n"
    metrics+="nftban.server.cpu_model ${cpu_model}\n"

    # Memory information
    local mem_total mem_avail
    if [[ -f /proc/meminfo ]]; then
        mem_total=$(awk '/MemTotal/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo "0")
        mem_avail=$(awk '/MemAvailable/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo "0")
        metrics+="nftban.server.memory_total $mem_total\n"
        metrics+="nftban.server.memory_available $mem_avail\n"
    fi

    # Uptime and boot time
    if [[ -f /proc/uptime ]]; then
        local uptime_secs boot_time
        uptime_secs=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")
        boot_time=$(($(date +%s) - uptime_secs))
        metrics+="nftban.server.uptime $uptime_secs\n"
        metrics+="nftban.server.boot_time $boot_time\n"
    fi

    # Network - Primary IP (IPv4)
    local primary_ip primary_iface
    primary_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    primary_iface=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $5; exit}' || echo "eth0")
    metrics+="nftban.server.primary_ip ${primary_ip}\n"

    # IPv6 address (primary global)
    local ipv6_addr
    ipv6_addr=$(ip -6 addr show scope global 2>/dev/null | awk '/inet6/{print $2; exit}' | cut -d'/' -f1 || echo "")
    [[ -n "$ipv6_addr" ]] && metrics+="nftban.server.ipv6 ${ipv6_addr}\n"

    # MAC address (primary interface)
    local mac_addr
    mac_addr=$(ip link show "$primary_iface" 2>/dev/null | awk '/ether/{print $2}' || cat /sys/class/net/"$primary_iface"/address 2>/dev/null || echo "")
    [[ -n "$mac_addr" ]] && metrics+="nftban.server.mac_address ${mac_addr}\n"

    # Subnet mask
    local subnet_mask cidr
    cidr=$(ip -4 addr show "$primary_iface" 2>/dev/null | awk '/inet/{print $2}' | cut -d'/' -f2 | head -1)
    if [[ -n "$cidr" ]]; then
        # Convert CIDR to dotted decimal
        case "$cidr" in
            8)  subnet_mask="255.0.0.0" ;;
            16) subnet_mask="255.255.0.0" ;;
            24) subnet_mask="255.255.255.0" ;;
            25) subnet_mask="255.255.255.128" ;;
            26) subnet_mask="255.255.255.192" ;;
            27) subnet_mask="255.255.255.224" ;;
            28) subnet_mask="255.255.255.240" ;;
            29) subnet_mask="255.255.255.248" ;;
            30) subnet_mask="255.255.255.252" ;;
            32) subnet_mask="255.255.255.255" ;;
            *)  subnet_mask="/${cidr}" ;;
        esac
        metrics+="nftban.server.subnet_mask ${subnet_mask}\n"
    fi

    # Default gateway
    local gateway
    gateway=$(ip route show default 2>/dev/null | awk '{print $3; exit}' || echo "")
    [[ -n "$gateway" ]] && metrics+="nftban.server.gateway ${gateway}\n"

    # All networks (JSON: interface, ip, mac)
    local networks
    networks=$(ip -j addr show 2>/dev/null | jq -c '[.[] | select(.ifname != "lo") | {iface: .ifname, mac: .address, ips: [.addr_info[]? | select(.family == "inet" or .family == "inet6") | {ip: .local, prefix: .prefixlen, family: .family}]}]' 2>/dev/null || echo '[]')
    metrics+="nftban.server.networks ${networks}\n"

    # Network interfaces (JSON array - simple list)
    local interfaces
    interfaces=$(ip -j link show 2>/dev/null | jq -c '[.[].ifname]' 2>/dev/null || echo '[]')
    metrics+="nftban.server.interfaces ${interfaces}\n"

    # Timezone
    local timezone
    timezone=$(timedatectl show -p Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "UTC")
    metrics+="nftban.server.timezone ${timezone}\n"

    # Virtualization detection
    local virt_type="none"
    if [[ -f /sys/hypervisor/type ]]; then
        virt_type=$(cat /sys/hypervisor/type 2>/dev/null || echo "none")
    elif grep -q "^flags.*hypervisor" /proc/cpuinfo 2>/dev/null; then
        if grep -qi "kvm" /sys/class/dmi/id/product_name 2>/dev/null; then
            virt_type="kvm"
        elif grep -qi "vmware" /sys/class/dmi/id/sys_vendor 2>/dev/null; then
            virt_type="vmware"
        elif [[ -f /.dockerenv ]]; then
            virt_type="docker"
        else
            virt_type="vm"
        fi
    fi
    metrics+="nftban.server.virtualization ${virt_type}\n"

    # Cloud provider detection
    local cloud_provider="none"
    if curl -s -m 1 http://169.254.169.254/latest/meta-data/ &>/dev/null; then
        cloud_provider="aws"
    elif curl -s -m 1 -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/ &>/dev/null; then
        cloud_provider="gcp"
    elif curl -s -m 1 -H "Metadata: true" "http://169.254.169.254/metadata/instance?api-version=2021-02-01" &>/dev/null; then
        cloud_provider="azure"
    elif [[ -f /etc/digitalocean ]] || curl -s -m 1 http://169.254.169.254/metadata/v1/ &>/dev/null; then
        cloud_provider="digitalocean"
    fi
    metrics+="nftban.server.cloud_provider ${cloud_provider}\n"

    # Public IP (prefer IPv4, try multiple services)
    local public_ip=""
    public_ip=$(curl -4 -s -m 2 https://api.ipify.org 2>/dev/null || \
                curl -4 -s -m 2 https://ifconfig.me 2>/dev/null || \
                curl -4 -s -m 2 https://icanhazip.com 2>/dev/null || \
                echo "")
    # Validate it's an IPv4 address
    if [[ "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        metrics+="nftban.server.public_ip ${public_ip}\n"
    fi

    # Region (from cloud metadata if available)
    local region=""
    if [[ "$cloud_provider" == "aws" ]]; then
        # AWS IMDSv1 - try with token first (IMDSv2), fallback to direct
        local token
        token=$(curl -s -m 1 -X PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" 2>/dev/null || echo "")
        if [[ -n "$token" ]]; then
            region=$(curl -s -m 1 -H "X-aws-ec2-metadata-token: $token" http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "")
        else
            region=$(curl -s -m 1 http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || echo "")
        fi
    elif [[ "$cloud_provider" == "gcp" ]]; then
        region=$(curl -s -m 1 -H "Metadata-Flavor: Google" http://169.254.169.254/computeMetadata/v1/instance/zone 2>/dev/null | sed 's|.*/||; s|-[a-z]$||' || echo "")
    elif [[ "$cloud_provider" == "azure" ]]; then
        region=$(curl -s -m 1 -H "Metadata: true" "http://169.254.169.254/metadata/instance/compute/location?api-version=2021-02-01&format=text" 2>/dev/null || echo "")
    fi
    # Only output if valid region (not error message)
    if [[ -n "$region" && ! "$region" =~ (Not Found|error|404) ]]; then
        metrics+="nftban.server.region ${region}\n"
    fi

    # Load averages
    if [[ -f /proc/loadavg ]]; then
        read -r load1 load5 load15 _ < /proc/loadavg
        metrics+="nftban.server.load_1m $load1\n"
        metrics+="nftban.server.load_5m $load5\n"
        metrics+="nftban.server.load_15m $load15\n"
    fi

    echo -e "$metrics"
}

collect_watchdog_metrics() {
    # Watchdog metrics (if available)
    local metrics=""

    local watchdog_status="${NFTBAN_RUN_DIR}/watchdog.status"
    if [[ -f "$watchdog_status" ]]; then
        # Read watchdog status file (JSON or simple format)
        if command -v jq &>/dev/null && head -1 "$watchdog_status" | grep -q "^{"; then
            local cpu_score mem_score io_score
            cpu_score=$(jq -r '.cpu_score // 0' "$watchdog_status" 2>/dev/null || echo "0")
            mem_score=$(jq -r '.mem_score // 0' "$watchdog_status" 2>/dev/null || echo "0")
            io_score=$(jq -r '.io_score // 0' "$watchdog_status" 2>/dev/null || echo "0")

            metrics+="nftban.watchdog.cpu_score $cpu_score\n"
            metrics+="nftban.watchdog.mem_score $mem_score\n"
            metrics+="nftban.watchdog.io_score $io_score\n"
        fi
        metrics+="nftban.watchdog.status 1\n"
    else
        metrics+="nftban.watchdog.status 0\n"
    fi

    echo -e "$metrics"
}

# =============================================================================
# METRIC SENDING
# =============================================================================

send_metrics_zabbix_sender() {
    # Send metrics using zabbix_sender
    local metrics="$1"

    if ! command -v zabbix_sender &>/dev/null; then
        log_error "zabbix_sender not found"
        return 1
    fi

    # Create temp file for batch send
    local tmp_file
    tmp_file=$(mktemp)
    # shellcheck disable=SC2064
    trap "rm -f '$tmp_file'" EXIT

    # Format metrics for zabbix_sender: hostname key value
    echo -e "$metrics" | while IFS=' ' read -r key value; do
        [[ -z "$key" ]] && continue
        echo "$ZABBIX_HOSTNAME $key $value"
    done > "$tmp_file"

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "=== DRY RUN: Would send to $ZABBIX_SERVER:$ZABBIX_PORT ==="
        cat "$tmp_file"
        return 0
    fi

    # Send to Zabbix
    local result
    result=$(zabbix_sender -z "$ZABBIX_SERVER" -p "$ZABBIX_PORT" -i "$tmp_file" 2>&1)

    if [[ "$VERBOSE" == "true" ]]; then
        echo "$result"
    fi

    # Parse result
    if echo "$result" | grep -q "failed: 0"; then
        log_info "All metrics sent successfully"
        return 0
    else
        log_error "Some metrics failed to send"
        return 1
    fi
}

send_metrics_native() {
    # Send metrics using native Zabbix protocol (fallback)
    local metrics="$1"

    log_info "Using native protocol (zabbix_sender not available)"

    # Build Zabbix sender protocol JSON
    local data='{"request":"sender data","data":['
    local first=true
    local key value

    # Use process substitution to avoid subshell variable scope issue
    while IFS=' ' read -r key value; do
        [[ -z "$key" ]] && continue
        # Escape JSON special characters in value
        value="${value//\\/\\\\}"    # backslash
        value="${value//\"/\\\"}"    # double quote
        value="${value//$'\n'/\\n}"  # newline
        value="${value//$'\r'/\\r}"  # carriage return
        value="${value//$'\t'/\\t}"  # tab
        [[ "$first" != "true" ]] && data+=","
        data+="{\"host\":\"$ZABBIX_HOSTNAME\",\"key\":\"$key\",\"value\":\"$value\"}"
        first=false
    done < <(echo -e "$metrics")

    data+=']}'

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "=== DRY RUN: Would send to $ZABBIX_SERVER:$ZABBIX_PORT ==="
        echo "$data" | jq . 2>/dev/null || echo "$data"
        return 0
    fi

    # Send using netcat to capture response
    local data_len=${#data}
    local len_hex
    len_hex=$(printf '%016x' "$data_len")

    # Send data and capture response (filter null bytes from binary protocol header)
    local response
    response=$(
    {
        printf 'ZBXD\x01'
        # Little-endian 8-byte length
        printf "\\x${len_hex:14:2}\\x${len_hex:12:2}\\x${len_hex:10:2}\\x${len_hex:8:2}"
        printf "\\x${len_hex:6:2}\\x${len_hex:4:2}\\x${len_hex:2:2}\\x${len_hex:0:2}"
        printf '%s' "$data"
    } | timeout 10 nc "$ZABBIX_SERVER" "$ZABBIX_PORT" 2>/dev/null | tr -d '\0'
    ) || {
        log_error "Failed to connect to $ZABBIX_SERVER:$ZABBIX_PORT"
        return 1
    }

    # Parse response
    local info
    info=$(echo "$response" | strings | grep -oP '"info":"\K[^"]+' 2>/dev/null || echo "")

    if [[ -n "$info" ]]; then
        log_info "Zabbix: $info"
    else
        log_info "Metrics sent via native protocol"
    fi

    # Check for failures
    if echo "$response" | grep -q '"response":"success"'; then
        return 0
    else
        log_error "Zabbix rejected the data"
        return 1
    fi
}

_send_metrics() {
    # Internal send function (used by buffer_send)
    local metrics="$1"
    if command -v zabbix_sender &>/dev/null; then
        send_metrics_zabbix_sender "$metrics"
    else
        send_metrics_native "$metrics"
    fi
}

output_json() {
    # Output metrics as JSON
    local metrics="$1"

    echo "{"
    echo "  \"timestamp\": \"$(date -Iseconds)\","
    echo "  \"hostname\": \"$ZABBIX_HOSTNAME\","
    echo "  \"metrics\": {"

    local first=true
    echo -e "$metrics" | while IFS=' ' read -r key value; do
        [[ -z "$key" ]] && continue
        [[ "$first" != "true" ]] && echo ","
        printf '    "%s": "%s"' "$key" "$value"
        first=false
    done

    echo ""
    echo "  }"
    echo "}"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)  DRY_RUN=true; shift ;;
            --verbose)  VERBOSE=true; shift ;;
            --json)     JSON_OUTPUT=true; shift ;;
            --once)     shift ;;  # Default behavior
            --check)    CHECK_PREREQ=true; shift ;;  # Check prerequisites only
            --force-inventory) FORCE_INVENTORY=true; shift ;;  # Force inventory collection
            --help|-h)
                echo "NFTBan Zabbix Exporter"
                echo ""
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --dry-run         Show what would be sent without sending"
                echo "  --verbose         Show detailed output"
                echo "  --json            Output metrics as JSON instead of sending"
                echo "  --once            Run once and exit (default)"
                echo "  --check           Check prerequisites and exit"
                echo "  --force-inventory Force inventory collection (bypasses hourly limit)"
                echo ""
                echo "Configuration is read from /etc/nftban/nftban.conf:"
                echo "  NFTBAN_ZABBIX_SERVER   Zabbix server address"
                echo "  NFTBAN_ZABBIX_PORT     Zabbix server port (default: 10051)"
                echo "  NFTBAN_ZABBIX_HOSTNAME Hostname to report (default: auto)"
                echo ""
                echo "Prerequisites:"
                echo "  - NFTBan must be installed"
                echo "  - NFTBAN_ZABBIX_ENABLED=true in config"
                echo "  - NFTBAN_ZABBIX_SERVER configured"
                echo "  - Network connectivity to Zabbix server"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # ==========================================================================
    # PREREQUISITE CHECKS
    # ==========================================================================
    local prereq_ok=true
    local prereq_errors=""

    # Check 1: NFTBan config exists
    if [[ ! -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
        prereq_ok=false
        prereq_errors+="  [FAIL] NFTBan config not found: ${NFTBAN_CONFIG_DIR}/nftban.conf\n"
    else
        [[ "$VERBOSE" == "true" ]] && echo "[OK] NFTBan config found"
    fi

    # Check 2: Zabbix export enabled
    if [[ "$ZABBIX_ENABLED" != "true" ]]; then
        prereq_ok=false
        prereq_errors+="  [FAIL] Zabbix export disabled (NFTBAN_ZABBIX_ENABLED != true)\n"
    else
        [[ "$VERBOSE" == "true" ]] && echo "[OK] Zabbix export enabled"
    fi

    # Check 3: Zabbix server configured
    if [[ -z "$ZABBIX_SERVER" ]]; then
        prereq_ok=false
        prereq_errors+="  [FAIL] Zabbix server not configured (NFTBAN_ZABBIX_SERVER empty)\n"
    else
        [[ "$VERBOSE" == "true" ]] && echo "[OK] Zabbix server: $ZABBIX_SERVER:$ZABBIX_PORT"
    fi

    # Check 4: Network tool available (nc or zabbix_sender)
    if ! command -v zabbix_sender &>/dev/null && ! command -v nc &>/dev/null; then
        prereq_ok=false
        prereq_errors+="  [FAIL] No network tool available (need zabbix_sender or nc)\n"
    else
        if command -v zabbix_sender &>/dev/null; then
            [[ "$VERBOSE" == "true" ]] && echo "[OK] zabbix_sender available"
        else
            [[ "$VERBOSE" == "true" ]] && echo "[OK] nc (netcat) available"
        fi
    fi

    # Check 5: NFTBan service exists (optional - just warn)
    if ! systemctl list-unit-files nftban.service &>/dev/null 2>&1; then
        [[ "$VERBOSE" == "true" ]] && echo "[WARN] NFTBan service not found (metrics may be limited)"
    fi

    # If --check mode, show results and exit
    if [[ "${CHECK_PREREQ:-false}" == "true" ]]; then
        echo "=== NFTBan Zabbix Exporter Prerequisites ==="
        if [[ "$prereq_ok" == "true" ]]; then
            echo "[OK] All prerequisites met"
            echo ""
            echo "Configuration:"
            echo "  Zabbix Server:   $ZABBIX_SERVER:$ZABBIX_PORT"
            echo "  Hostname:        $ZABBIX_HOSTNAME"
            echo "  Buffer Dir:      $BUFFER_DIR"
            exit 0
        else
            echo "[FAIL] Prerequisites not met:"
            echo -e "$prereq_errors"
            echo ""
            echo "To fix:"
            echo "  1. Run: nftban zabbix setup"
            echo "  2. Set NFTBAN_ZABBIX_ENABLED=true in ${NFTBAN_CONFIG_DIR}/conf.d/zabbix.conf"
            echo "  3. Set NFTBAN_ZABBIX_SERVER=<your-zabbix-server>"
            exit 1
        fi
    fi

    # If prerequisites failed and not JSON mode, exit with error
    if [[ "$prereq_ok" != "true" ]] && [[ "$JSON_OUTPUT" != "true" ]]; then
        log_error "Prerequisites not met. Run with --check for details."
        exit 1
    fi

    # ==========================================================================
    # COLLECT METRICS (Smart: dynamic every run, inventory hourly)
    # ==========================================================================
    log_info "Collecting NFTBan metrics..."

    local all_metrics=""

    # DYNAMIC METRICS - collect every run (these change frequently)
    all_metrics+="$(collect_daemon_metrics)"$'\n'      # status, uptime, mode
    all_metrics+="$(collect_ban_metrics)"$'\n'         # bans, rate, counts
    all_metrics+="$(collect_memory_metrics)"$'\n'      # RSS, threads, FDs
    all_metrics+="$(collect_health_metrics)"$'\n'      # health status
    all_metrics+="$(collect_module_metrics)"$'\n'      # module status
    all_metrics+="$(collect_nftables_metrics)"$'\n'    # rules, sets, packets
    all_metrics+="$(collect_feeds_metrics)"$'\n'       # feed status
    all_metrics+="$(collect_watchdog_metrics)"$'\n'    # pressure scores

    # INVENTORY METRICS - collect hourly (static data, rarely changes)
    if should_collect_inventory; then
        log_info "Collecting inventory metrics (hourly)..."
        all_metrics+="$(collect_server_metrics)"$'\n'  # OS, IPs, hardware
        all_metrics+="$(collect_geoip_metrics)"$'\n'   # GeoIP database info
        update_inventory_stamp
    else
        log_info "Skipping inventory (last collected < ${INVENTORY_INTERVAL}s ago)"
    fi

    # JSON output mode
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json "$all_metrics"
        exit 0
    fi

    # Check if backend is enabled - if not, exit silently (no buffering)
    if [[ "$ZABBIX_ENABLED" != "true" ]]; then
        log_info "Zabbix backend disabled, exiting"
        exit 0
    fi

    # Check server configuration (only if enabled)
    if [[ -z "$ZABBIX_SERVER" ]]; then
        log_error "Zabbix enabled but server not configured"
        echo "Set NFTBAN_ZABBIX_SERVER in /etc/nftban/nftban.conf"
        echo "Or run: nftban zabbix setup"
        exit 1
    fi

    log_info "Sending metrics to $ZABBIX_SERVER:$ZABBIX_PORT..."

    # Clean up old buffer files (>1 day)
    buffer_cleanup

    # Try to send current metrics
    if _send_metrics "$all_metrics"; then
        log_info "Live metrics sent successfully"
        # On success, try to send any buffered metrics
        buffer_send
    else
        # On failure, save to buffer for later
        log_error "Failed to send metrics, buffering for later..."
        buffer_save "$all_metrics"
        exit 1
    fi
}

main "$@"
