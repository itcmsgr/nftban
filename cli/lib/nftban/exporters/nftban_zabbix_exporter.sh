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

readonly NFTBAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban}"
readonly NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
readonly NFTBAN_RUN_DIR="${NFTBAN_RUN_DIR:-/run/nftban}"
readonly NFTBAN_LOG_DIR="${NFTBAN_LOG_DIR:-/var/log/nftban}"
readonly NFTBAN_CACHE_DIR="${NFTBAN_CACHE_DIR:-/var/cache/nftban}"

# Load config
if [[ -f "${NFTBAN_CONFIG_DIR}/nftban.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/nftban.conf"
fi

# =============================================================================
# CONFIGURATION
# =============================================================================

# Zabbix server settings
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

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() {
    [[ "$VERBOSE" == "true" ]] && echo "[INFO] $*"
}

log_error() {
    echo "[ERROR] $*" >&2
}

# =============================================================================
# METRIC COLLECTION FUNCTIONS
# =============================================================================

collect_daemon_metrics() {
    # Daemon status and info metrics
    local metrics=""

    # Version
    local version="unknown"
    if [[ -f "${NFTBAN_CONFIG_DIR}/../VERSION" ]]; then
        version=$(cat "${NFTBAN_CONFIG_DIR}/../VERSION" 2>/dev/null | head -1 || echo "unknown")
    elif [[ -f "/etc/nftban/VERSION" ]]; then
        version=$(cat "/etc/nftban/VERSION" 2>/dev/null | head -1 || echo "unknown")
    fi
    metrics+="nftban.version $version\n"

    # Daemon status (1=running, 0=stopped)
    local status=0
    if systemctl is-active nftban.service &>/dev/null; then
        status=1
    fi
    metrics+="nftban.status $status\n"

    # Uptime (seconds since daemon start)
    if [[ $status -eq 1 ]]; then
        local start_time
        start_time=$(systemctl show nftban.service -p ActiveEnterTimestamp --value 2>/dev/null || echo "")
        if [[ -n "$start_time" ]]; then
            local start_epoch now_epoch uptime
            start_epoch=$(date -d "$start_time" +%s 2>/dev/null || echo "0")
            now_epoch=$(date +%s)
            uptime=$((now_epoch - start_epoch))
            metrics+="nftban.uptime $uptime\n"
        fi
    fi

    # PID
    local pid=""
    if [[ -f "${NFTBAN_RUN_DIR}/nftban.pid" ]]; then
        pid=$(cat "${NFTBAN_RUN_DIR}/nftban.pid" 2>/dev/null || echo "")
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

    echo -e "$metrics"
}

collect_memory_metrics() {
    # Memory metrics (from /proc if daemon is running)
    local metrics=""

    local pid=""
    if [[ -f "${NFTBAN_RUN_DIR}/nftban.pid" ]]; then
        pid=$(cat "${NFTBAN_RUN_DIR}/nftban.pid" 2>/dev/null || echo "")
    fi

    if [[ -n "$pid" ]] && [[ -d "/proc/$pid" ]]; then
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

    if command -v nft &>/dev/null; then
        # Count total sets
        local sets_count
        sets_count=$(nft list sets inet nftban 2>/dev/null | grep -c "set " || echo "0")
        metrics+="nftban.nft.sets_total $sets_count\n"

        # Count total elements across all sets (fast method)
        local elements_total=0
        for set_name in blacklist_ipv4 blacklist_ipv6 whitelist_ipv4 whitelist_ipv6; do
            local count
            count=$(nft -j list set inet nftban "$set_name" 2>/dev/null | jq -r '.nftables[]?.set?.elem // [] | length' 2>/dev/null || echo "0")
            elements_total=$((elements_total + count))
        done
        metrics+="nftban.nft.elements_total $elements_total\n"

        # Count rules (approximate)
        local rules_count
        rules_count=$(nft list table inet nftban 2>/dev/null | grep -cE "^\s+(accept|drop|reject|return|jump|goto)" || echo "0")
        metrics+="nftban.nft.rules_total $rules_count\n"
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

    # Network - Primary IP
    local primary_ip
    primary_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' || hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    metrics+="nftban.server.primary_ip ${primary_ip}\n"

    # Network interfaces (JSON array)
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

    echo -e "$metrics" | while IFS=' ' read -r key value; do
        [[ -z "$key" ]] && continue
        [[ "$first" != "true" ]] && data+=","
        data+="{\"host\":\"$ZABBIX_HOSTNAME\",\"key\":\"$key\",\"value\":\"$value\"}"
        first=false
    done

    data+=']}'

    if [[ "$DRY_RUN" == "true" ]]; then
        echo "=== DRY RUN: Would send to $ZABBIX_SERVER:$ZABBIX_PORT ==="
        echo "$data" | jq . 2>/dev/null || echo "$data"
        return 0
    fi

    # Send using netcat or bash /dev/tcp
    local header
    local data_len=${#data}

    # Zabbix protocol header: ZBXD\x01 + 8-byte little-endian length
    header=$(printf 'ZBXD\x01')
    header+=$(printf '%08x' "$data_len" | sed 's/\(..\)/\\x\1/g' | tac -rs ..)

    # Send data
    {
        printf '%s' "$header"
        printf '%s' "$data"
    } | timeout 10 nc "$ZABBIX_SERVER" "$ZABBIX_PORT" 2>/dev/null

    log_info "Metrics sent via native protocol"
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
            --help|-h)
                echo "NFTBan Zabbix Exporter"
                echo ""
                echo "Usage: $0 [options]"
                echo ""
                echo "Options:"
                echo "  --dry-run    Show what would be sent without sending"
                echo "  --verbose    Show detailed output"
                echo "  --json       Output metrics as JSON instead of sending"
                echo "  --once       Run once and exit (default)"
                echo ""
                echo "Configuration is read from /etc/nftban/nftban.conf:"
                echo "  NFTBAN_ZABBIX_SERVER   Zabbix server address"
                echo "  NFTBAN_ZABBIX_PORT     Zabbix server port (default: 10051)"
                echo "  NFTBAN_ZABBIX_HOSTNAME Hostname to report (default: auto)"
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                exit 1
                ;;
        esac
    done

    # Check configuration
    if [[ -z "$ZABBIX_SERVER" ]] && [[ "$JSON_OUTPUT" != "true" ]]; then
        log_error "Zabbix server not configured"
        echo "Set NFTBAN_ZABBIX_SERVER in /etc/nftban/nftban.conf"
        echo "Or run: nftban zabbix setup"
        exit 1
    fi

    log_info "Collecting NFTBan metrics..."

    # Collect all metrics
    local all_metrics=""
    all_metrics+=$(collect_daemon_metrics)
    all_metrics+=$(collect_ban_metrics)
    all_metrics+=$(collect_memory_metrics)
    all_metrics+=$(collect_module_metrics)
    all_metrics+=$(collect_nftables_metrics)
    all_metrics+=$(collect_feeds_metrics)
    all_metrics+=$(collect_geoip_metrics)
    all_metrics+=$(collect_server_metrics)
    all_metrics+=$(collect_watchdog_metrics)

    # Output or send
    if [[ "$JSON_OUTPUT" == "true" ]]; then
        output_json "$all_metrics"
        exit 0
    fi

    log_info "Sending metrics to $ZABBIX_SERVER:$ZABBIX_PORT..."

    # Use zabbix_sender if available, otherwise native protocol
    if command -v zabbix_sender &>/dev/null; then
        send_metrics_zabbix_sender "$all_metrics"
    else
        send_metrics_native "$all_metrics"
    fi
}

main "$@"
