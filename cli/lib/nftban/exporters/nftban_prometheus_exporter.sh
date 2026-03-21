#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_prometheus_exporter"
# meta:type="exporter"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Consolidated all-in-one metrics exporter: blocks, bandwidth, counters, health"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
# shellcheck disable=SC1091
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" 2>/dev/null || true
source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local" 2>/dev/null || true

# =============================================================================
# CONFIGURATION
# =============================================================================

# Set library directory (before sourcing schema)
NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR}"

# Load NFT schema for table names
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" || return 1
else
    echo "ERROR: nft_schema.sh not found at ${NFTBAN_LIB_DIR}/lib/nft_schema.sh" >&2
    exit 1
fi

# Now make readonly after sourcing
readonly NFTBAN_LIB_DIR
readonly OUTPUT_FILE="${NFTBAN_METRICS_FILE:-/var/lib/node_exporter/textfile_collector/nftban.prom}"
TEMP_FILE=$(mktemp "${OUTPUT_FILE}.XXXXXX")
readonly TEMP_FILE
readonly NFTBAN_STATE_DIR="${NFTBAN_DATA_DIR}"
readonly NFTBAN_LOG_DIR="${NFTBAN_LOG_DIR}"
readonly TEMP_DIR="${NFTBAN_RUN_DIR}"
readonly STATE_FILE="${TEMP_DIR}/bandwidth_state.dat"
readonly PEAK_FILE="${TEMP_DIR}/bandwidth_peaks.dat"
readonly COMBINED_FILE="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/metrics/combined.json"

# Bandwidth tracking configuration
readonly PEAK_WINDOW=300  # Peak tracking window (5 minutes)
readonly SKIP_INTERFACES="lo docker0 veth br-"  # Interfaces to skip

# Cleanup trap - prevent orphaned temp files on interruption
cleanup_prometheus_temp() {
    rm -f "$TEMP_FILE" 2>/dev/null || true
    # Clean up orphaned .prom.* files older than 1 hour
    local textfile_dir
    textfile_dir=$(dirname "$OUTPUT_FILE")
    find "$textfile_dir" -maxdepth 1 -name "nftban.prom.*" -mmin +60 -delete 2>/dev/null || true
}
trap cleanup_prometheus_temp EXIT INT TERM HUP

# Metric collection start time
START_TIME=$(date +%s.%N)
readonly START_TIME
START_TIME_UNIX=$(date +%s)
readonly START_TIME_UNIX

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Write metric to output file
# Usage: write_metric "metric_name{labels}" "value" ["HELP text"] ["TYPE gauge|counter"]
write_metric() {
    local metric="$1"
    local value="$2"
    local help="${3:-}"
    local type="${4:-gauge}"

    # Write HELP line if provided
    if [[ -n "$help" ]]; then
        echo "# HELP $metric $help" >> "$TEMP_FILE"
    fi

    # Write TYPE line
    echo "# TYPE $metric $type" >> "$TEMP_FILE"

    # Write metric value
    echo "$metric $value" >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"
}

# Get block count from nftban state
get_block_count() {
    local block_type="$1"  # total, permanent, temporary

    # v1.32.0: Use daemon cache (0 kernel calls) with kernel fallback
    case "$block_type" in
        total)
            local black_v4 black_v6

            # Prefer cached counting from daemon
            if declare -f nftban_nft_count_set_cached >/dev/null 2>&1; then
                black_v4=$(nftban_nft_count_set_cached blacklist_ipv4 2>/dev/null) || black_v4=0
                black_v6=$(nftban_nft_count_set_cached blacklist_ipv6 2>/dev/null) || black_v6=0
            elif declare -f nftban_nft_count_set >/dev/null 2>&1; then
                black_v4=$(nftban_nft_count_set ip nftban blacklist_ipv4 2>/dev/null) || black_v4=0
                black_v6=$(nftban_nft_count_set ip6 nftban blacklist_ipv6 2>/dev/null) || black_v6=0
            else
                black_v4=0
                black_v6=0
            fi

            [[ "$black_v4" =~ ^[0-9]+$ ]] || black_v4=0
            [[ "$black_v6" =~ ^[0-9]+$ ]] || black_v6=0

            echo $((black_v4 + black_v6))
            ;;
        permanent|temporary|geoban)
            # All ban types unified in blacklist_ipv4/ipv6 — cannot distinguish from nft
            local count
            if declare -f nftban_nft_count_set_cached >/dev/null 2>&1; then
                count=$(nftban_nft_count_set_cached blacklist_ipv4 2>/dev/null) || count=0
            elif declare -f nftban_nft_count_set >/dev/null 2>&1; then
                count=$(nftban_nft_count_set ip nftban blacklist_ipv4 2>/dev/null) || count=0
            else
                count=0
            fi
            [[ "$count" =~ ^[0-9]+$ ]] || count=0
            echo "$count"
            ;;
    esac
}

# Get block count by country
# Uses nftban stats API for accurate per-country metrics
get_blocks_by_country() {
    local cache_file="${NFTBAN_CACHE_DIR}/metrics_countries.json"
    local cache_max_age=300  # 5 minutes

    # Check cache first
    if [[ -f "$cache_file" ]]; then
        local cache_age
        cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        if [[ $cache_age -lt $cache_max_age ]]; then
            # Use cached data
            _parse_country_metrics "$cache_file"
            return 0
        fi
    fi

    # Query nftban stats for per-country data
    local json_data
    if command -v nftban &>/dev/null; then
        json_data=$(nftban stats top countries 50 --json 2>/dev/null) || json_data=""
    fi

    # If we got valid JSON, cache it and parse
    if [[ -n "$json_data" ]] && echo "$json_data" | grep -q '"success":true'; then
        echo "$json_data" > "$cache_file" 2>/dev/null || true
        _parse_country_metrics "$cache_file"
        return 0
    fi

    # Fallback: Parse geoban.d config files for banned countries
    _fallback_country_metrics
}

# Parse country metrics from JSON cache
_parse_country_metrics() {
    local cache_file="$1"

    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi

    # Check if jq is available
    if command -v jq &>/dev/null; then
        # Parse JSON with jq
        jq -r '.data.items[]? | "nftban_blocks_by_country{country=\"\(.country)\"} \(.count)"' "$cache_file" 2>/dev/null
    else
        # Fallback: grep/awk parsing
        grep -oP '"country":\s*"\K[^"]+|"count":\s*\K\d+' "$cache_file" 2>/dev/null | \
        while read -r country && read -r count; do
            echo "nftban_blocks_by_country{country=\"$country\"} $count"
        done
    fi
}

# Fallback: Get approximate metrics from geoban config
_fallback_country_metrics() {
    # v1.32.0: Use cached counting
    local total_ips=0
    if declare -f nftban_nft_count_set_cached >/dev/null 2>&1; then
        total_ips=$(nftban_nft_count_set_cached blacklist_ipv4 2>/dev/null) || total_ips=0
    elif declare -f nftban_nft_count_set >/dev/null 2>&1; then
        total_ips=$(nftban_nft_count_set ip nftban blacklist_ipv4 2>/dev/null) || total_ips=0
    fi
    [[ "$total_ips" =~ ^[0-9]+$ ]] || total_ips=0

    [[ $total_ips -eq 0 ]] && return 0

    # Get configured countries from geoban config
    local country_count=0
    local conf_files=()
    if [[ -d "${NFTBAN_CONFIG_DIR}/geoban.d" ]]; then
        # Use nullglob to handle empty directory gracefully
        shopt -s nullglob
        conf_files=("${NFTBAN_CONFIG_DIR}"/geoban.d/*.conf)
        shopt -u nullglob
        country_count=${#conf_files[@]}
    fi

    [[ $country_count -eq 0 ]] && return 0

    # Distribute IPs evenly (approximate)
    local per_country=$((total_ips / country_count))

    for conf in "${conf_files[@]}"; do
        local country
        country=$(basename "$conf" .conf | tr '[:lower:]' '[:upper:]')
        echo "nftban_blocks_by_country{country=\"$country\"} $per_country"
    done
}

# Get total ban count (cumulative)
get_total_bans() {
    local count=0
    if [[ -f "${NFTBAN_STATE_DIR}/stats/total_bans" ]]; then
        count=$(cat "${NFTBAN_STATE_DIR}/stats/total_bans" 2>/dev/null) || count=0
    else
        # Try from logs
        count=$(grep -c "BLOCKED" "${NFTBAN_LOG_DIR}/nftban.log" 2>/dev/null) || count=0
    fi
    echo "${count:-0}"
}

# Get bans in last 24 hours
get_bans_24h() {
    local cutoff count=0
    cutoff=$(date -d '24 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -v-24H '+%Y-%m-%d %H:%M:%S' 2>/dev/null)

    if [[ -n "$cutoff" ]] && [[ -f "${NFTBAN_LOG_DIR}/nftban.log" ]]; then
        count=$(awk -v cutoff="$cutoff" '$0 > cutoff' "${NFTBAN_LOG_DIR}/nftban.log" 2>/dev/null | \
            grep -c "BLOCKED" 2>/dev/null) || count=0
    fi
    echo "${count:-0}"
}

# Get health status for a component
# Returns: 0=OK, 1=WARN, 2=ERROR, 3=CRITICAL
get_health_status() {
    local component="$1"

    if command -v nftban &>/dev/null; then
        # Use nftban health command
        local health_output
        health_output=$(nftban health "$component" 2>/dev/null || echo "ERROR")

        case "$health_output" in
            *"OK"*|*"PASS"*) echo "0" ;;
            *"WARN"*) echo "1" ;;  # Matches both WARN and WARNING
            *"ERROR"*|*"FAIL"*) echo "2" ;;
            *"CRITICAL"*) echo "3" ;;
            *) echo "2" ;;  # Default to ERROR if unknown
        esac
    else
        # Fallback: basic checks
        case "$component" in
            nftables)
                systemctl is-active nftables &>/dev/null && echo "0" || echo "2"
                ;;
            ssh)
                systemctl is-active sshd &>/dev/null || systemctl is-active ssh &>/dev/null && echo "0" || echo "2"
                ;;
            polkit)
                systemctl is-active polkit &>/dev/null || systemctl is-active polkitd &>/dev/null && echo "0" || echo "1"
                ;;
            *)
                echo "2"
                ;;
        esac
    fi
}

# Get nftables rule count
get_nftables_rules_count() {
    local count=0
    if command -v nft &>/dev/null; then
        count=$(nft list ruleset 2>/dev/null | grep -c "^[[:space:]]*\(ip\|ip6\)" 2>/dev/null) || count=0
    fi
    echo "${count:-0}"
}

# Removed: fail2ban jails count (v1.0 migration to Suricata)

# =============================================================================
# BANDWIDTH METRICS FUNCTIONS (v0.6.1 - Consolidated)
# =============================================================================

# Initialize temp directory for bandwidth state
init_bandwidth_temp_dir() {
    if [[ ! -d "$TEMP_DIR" ]]; then
        mkdir -p "$TEMP_DIR" || return 1
        chmod 750 "$TEMP_DIR"
    fi
}

# Parse /proc/net/dev for interface statistics
get_interface_stats() {
    local interface=$1
    local stats

    # Read stats from /proc/net/dev
    stats=$(grep -E "^\\s*${interface}:" /proc/net/dev 2>/dev/null || echo "")

    if [[ -z "$stats" ]]; then
        return 1
    fi

    # Remove interface name and extract values
    stats=$(echo "$stats" | sed 's/^[^:]*://' | tr -s ' ')

    # Extract relevant fields
    local rx_bytes
    local rx_packets
    local tx_bytes
    local tx_packets
    rx_bytes=$(echo "$stats" | awk '{print $1}')
    rx_packets=$(echo "$stats" | awk '{print $2}')
    tx_bytes=$(echo "$stats" | awk '{print $9}')
    tx_packets=$(echo "$stats" | awk '{print $10}')

    echo "${rx_bytes} ${rx_packets} ${tx_bytes} ${tx_packets}"
}

# v1.19.12: calculate_mbps moved to nftban_unified_exporter_helpers.sh (consolidation)
# This function is now provided by the helpers module sourced above

# Get protocol statistics from /proc/net/snmp
get_protocol_stats() {
    local protocol=$1
    local metric=$2  # bytes or packets

    case "$protocol" in
        tcp)
            if [[ "$metric" == "bytes" ]]; then
                local in_segs
                local out_segs
                in_segs=$(grep "^Tcp:" /proc/net/snmp | tail -1 | awk '{print $11}')
                out_segs=$(grep "^Tcp:" /proc/net/snmp | tail -1 | awk '{print $12}')
                # Assume average packet size of 1200 bytes
                echo $(( (in_segs + out_segs) * 1200 ))
            else
                local in_segs
                local out_segs
                in_segs=$(grep "^Tcp:" /proc/net/snmp | tail -1 | awk '{print $11}')
                out_segs=$(grep "^Tcp:" /proc/net/snmp | tail -1 | awk '{print $12}')
                echo $(( in_segs + out_segs ))
            fi
            ;;
        udp)
            if [[ "$metric" == "bytes" ]]; then
                local in_dgrams
                local out_dgrams
                in_dgrams=$(grep "^Udp:" /proc/net/snmp | tail -1 | awk '{print $2}')
                out_dgrams=$(grep "^Udp:" /proc/net/snmp | tail -1 | awk '{print $5}')
                # Assume average datagram size of 500 bytes
                echo $(( (in_dgrams + out_dgrams) * 500 ))
            else
                local in_dgrams
                local out_dgrams
                in_dgrams=$(grep "^Udp:" /proc/net/snmp | tail -1 | awk '{print $2}')
                out_dgrams=$(grep "^Udp:" /proc/net/snmp | tail -1 | awk '{print $5}')
                echo $(( in_dgrams + out_dgrams ))
            fi
            ;;
        icmp)
            if [[ "$metric" == "bytes" ]]; then
                local in_msgs
                local out_msgs
                in_msgs=$(grep "^Icmp:" /proc/net/snmp | tail -1 | awk '{print $2}')
                out_msgs=$(grep "^Icmp:" /proc/net/snmp | tail -1 | awk '{print $22}')
                # ICMP packets are typically small (64 bytes)
                echo $(( (in_msgs + out_msgs) * 64 ))
            else
                local in_msgs
                local out_msgs
                in_msgs=$(grep "^Icmp:" /proc/net/snmp | tail -1 | awk '{print $2}')
                out_msgs=$(grep "^Icmp:" /proc/net/snmp | tail -1 | awk '{print $22}')
                echo $(( in_msgs + out_msgs ))
            fi
            ;;
        *)
            echo "0"
            ;;
    esac
}

# Get connection statistics using ss
get_connection_stats() {
    local state=$1

    if ! command -v ss &>/dev/null; then
        echo "0"
        return
    fi

    local count
    case "$state" in
        active)
            count=$(ss -tan 2>/dev/null | grep -cE "ESTAB|SYN-SENT|SYN-RECV|FIN-WAIT|CLOSE-WAIT|TIME-WAIT" || true)
            ;;
        established)
            count=$(ss -tan 2>/dev/null | grep -c "ESTAB" || true)
            ;;
        time_wait)
            count=$(ss -tan 2>/dev/null | grep -c "TIME-WAIT" || true)
            ;;
        close_wait)
            count=$(ss -tan 2>/dev/null | grep -c "CLOSE-WAIT" || true)
            ;;
        *)
            count=0
            ;;
    esac
    echo "${count:-0}"
}

# Update peak values
update_peaks() {
    local rx_mbps=$1
    local tx_mbps=$2
    local current_ts=$3

    # Initialize peaks file if missing
    if [[ ! -f "$PEAK_FILE" ]]; then
        echo "0 0 $current_ts" > "$PEAK_FILE"
    fi

    # Read current peaks
    local peak_data
    local peak_rx
    local peak_tx
    local peak_ts
    peak_data=$(cat "$PEAK_FILE")
    peak_rx=$(echo "$peak_data" | awk '{print $1}')
    peak_tx=$(echo "$peak_data" | awk '{print $2}')
    peak_ts=$(echo "$peak_data" | awk '{print $3}')

    # Check if peak window expired (5 minutes)
    if [[ $(( current_ts - peak_ts )) -gt $PEAK_WINDOW ]]; then
        # Reset peaks
        peak_rx=$rx_mbps
        peak_tx=$tx_mbps
        peak_ts=$current_ts
    else
        # Update peaks if current is higher
        peak_rx=$(awk -v curr="$rx_mbps" -v peak="$peak_rx" 'BEGIN {print (curr > peak) ? curr : peak}')
        peak_tx=$(awk -v curr="$tx_mbps" -v peak="$peak_tx" 'BEGIN {print (curr > peak) ? curr : peak}')
    fi

    # Save peaks
    echo "$peak_rx $peak_tx $peak_ts" > "$PEAK_FILE"

    # Output peaks
    echo "$peak_rx $peak_tx"
}

# Get list of active network interfaces
get_active_interfaces() {
    local interfaces=()
    local line

    while IFS= read -r line; do
        # Skip header lines
        [[ "$line" =~ ^(Inter-|face) ]] && continue

        # Extract interface name
        local iface
        iface=$(echo "$line" | awk -F: '{print $1}' | tr -d ' ')

        # Skip unwanted interfaces
        local skip=0
        local skip_pattern
        for skip_pattern in $SKIP_INTERFACES; do
            if [[ "$iface" =~ ^${skip_pattern} ]]; then
                skip=1
                break
            fi
        done

        [[ $skip -eq 1 ]] && continue

        # Check if interface is up
        if [[ -d "/sys/class/net/$iface" ]]; then
            local operstate
            operstate=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
            if [[ "$operstate" == "up" ]]; then
                interfaces+=("$iface")
            fi
        fi
    done < /proc/net/dev

    printf '%s\n' "${interfaces[@]}"
}

# =============================================================================
# NFTABLES ADVANCED METRICS FUNCTIONS (v0.6.1 - Consolidated)
# =============================================================================

# Get NFTables set sizes (number of elements in each set)
# v1.32.0: Uses daemon cache for counting (0 kernel calls when cache available)
get_nftables_set_sizes() {
    # v1.32.0: Prefer daemon cache file — all set counts in single read
    local cache_file="/run/nftban/set_counts.json"
    if [[ -f "$cache_file" ]] && command -v jq &>/dev/null; then
        local cache_age
        cache_age=$(( $(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0) ))
        if [[ "$cache_age" -lt 120 ]]; then
            jq -r '.sets | to_entries[] | "\(.key) \(.value.count)"' "$cache_file" 2>/dev/null
            return
        fi
    fi

    # Fallback: use cached counting functions or direct nft
    local sets="whitelist_ipv4 whitelist_ipv6 blacklist_ipv4 blacklist_ipv6"
    local set_name
    for set_name in $sets; do
        local count=0
        if declare -f nftban_nft_count_set_cached >/dev/null 2>&1; then
            count=$(nftban_nft_count_set_cached "$set_name" 2>/dev/null) || count=0
        elif declare -f nftban_nft_count_set >/dev/null 2>&1; then
            local _fam="ip"
            [[ "$set_name" == *"_ipv6" || "$set_name" == *"6" ]] && _fam="ip6"
            count=$(nftban_nft_count_set "$_fam" nftban "$set_name" 2>/dev/null) || count=0
        fi
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
        echo "${set_name} ${count}"
    done
}

# Get detailed ban metrics (IPv4/IPv6, temp/perm breakdown)
# Returns: family type count (e.g., "ipv4 permanent 10")
get_ban_breakdown() {
    # v1.32.0: Use cached counting (0 kernel calls) — temp/perm split not
    # available from cache, report all as permanent (consistent with unified arch)
    local v4_total=0 v4_temp=0 v4_perm=0
    local v6_total=0 v6_temp=0 v6_perm=0

    if declare -f nftban_nft_count_set_cached >/dev/null 2>&1; then
        v4_total=$(nftban_nft_count_set_cached blacklist_ipv4 2>/dev/null) || v4_total=0
        v6_total=$(nftban_nft_count_set_cached blacklist_ipv6 2>/dev/null) || v6_total=0
    elif declare -f nftban_nft_count_set >/dev/null 2>&1; then
        v4_total=$(nftban_nft_count_set ip nftban blacklist_ipv4 2>/dev/null) || v4_total=0
        v6_total=$(nftban_nft_count_set ip6 nftban blacklist_ipv6 2>/dev/null) || v6_total=0
    fi

    [[ "$v4_total" =~ ^[0-9]+$ ]] || v4_total=0
    [[ "$v6_total" =~ ^[0-9]+$ ]] || v6_total=0
    v4_perm=$v4_total
    v6_perm=$v6_total

    echo "ipv4 permanent $v4_perm"
    echo "ipv4 temporary $v4_temp"
    echo "ipv4 total $v4_total"
    echo "ipv6 permanent $v6_perm"
    echo "ipv6 temporary $v6_temp"
    echo "ipv6 total $v6_total"
}

# Get threat feeds metrics
get_feeds_metrics() {
    local feeds_dir="${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds"
    local total_ipv4=0 total_ipv6=0 enabled_count=0

    if [[ -d "$feeds_dir" ]] && type -t nftban_feeds_discover_all >/dev/null 2>&1; then
        local all_feeds
        all_feeds=$(nftban_feeds_discover_all 2>/dev/null || true)
        for feed in $all_feeds; do
            local enabled
            enabled=$(nftban_feeds_get_property "$feed" "ENABLED" 2>/dev/null || echo "false")
            if [[ "$enabled" == "true" ]]; then
                # v1.19.20 FIX
                ((enabled_count++)) || true
                local feed_lower="${feed,,}"
                local feed_file="${feeds_dir}/${feed_lower}.txt"
                if [[ -f "$feed_file" ]]; then
                    local v4 v6
                    v4=$(grep -cE '^[0-9]+\.' "$feed_file" 2>/dev/null) || v4=0
                    v6=$(grep -cE '^[0-9a-fA-F]*:' "$feed_file" 2>/dev/null) || v6=0
                    # Sanitize to ensure numeric-only values
                    v4=${v4//[^0-9]/}; v4=${v4:-0}
                    v6=${v6//[^0-9]/}; v6=${v6:-0}
                    total_ipv4=$((total_ipv4 + v4))
                    total_ipv6=$((total_ipv6 + v6))
                fi
            fi
        done
    fi

    echo "enabled $enabled_count"
    echo "ipv4 $total_ipv4"
    echo "ipv6 $total_ipv6"
}

# Get NFTables firewall counters (packets and bytes per rule/chain)
# Schema v0.7.3: Uses separate ip/ip6 tables, aggregates both families
get_nftables_counters() {
    if ! command -v nft &>/dev/null; then
        return
    fi

    # Get counters from both IPv4 and IPv6 tables and aggregate them
    local ipv4_data
    local ipv6_data

    # IPv4 counters
    ipv4_data=$(nft list chain ip nftban input 2>/dev/null || echo "")
    # IPv6 counters
    ipv6_data=$(nft list chain ip6 nftban input 2>/dev/null || echo "")

    # Default drop counters (aggregate IPv4 + IPv6)
    local ipv4_drop_pkts ipv4_drop_bytes ipv6_drop_pkts ipv6_drop_bytes
    ipv4_drop_pkts=$(echo "$ipv4_data" | grep "default deny" | grep -oP 'counter packets \K\d+' || echo "0")
    ipv4_drop_bytes=$(echo "$ipv4_data" | grep "default deny" | grep -oP 'bytes \K\d+' || echo "0")
    ipv6_drop_pkts=$(echo "$ipv6_data" | grep "default deny" | grep -oP 'counter packets \K\d+' || echo "0")
    ipv6_drop_bytes=$(echo "$ipv6_data" | grep "default deny" | grep -oP 'bytes \K\d+' || echo "0")

    local total_drop_pkts=$((ipv4_drop_pkts + ipv6_drop_pkts))
    local total_drop_bytes=$((ipv4_drop_bytes + ipv6_drop_bytes))
    echo "default_drop ${total_drop_pkts} ${total_drop_bytes}"

    # Blacklist counters (unified blacklist_ipv4 set in schema v0.7.3)
    local ipv4_bl_pkts ipv4_bl_bytes ipv6_bl_pkts ipv6_bl_bytes
    ipv4_bl_pkts=$(echo "$ipv4_data" | grep "@blacklist_ipv4" | grep -oP 'counter packets \K\d+' || echo "0")
    ipv4_bl_bytes=$(echo "$ipv4_data" | grep "@blacklist_ipv4" | grep -oP 'bytes \K\d+' || echo "0")
    ipv6_bl_pkts=$(echo "$ipv6_data" | grep "@blacklist_ipv6" | grep -oP 'counter packets \K\d+' || echo "0")
    ipv6_bl_bytes=$(echo "$ipv6_data" | grep "@blacklist_ipv6" | grep -oP 'bytes \K\d+' || echo "0")

    local total_bl_pkts=$((ipv4_bl_pkts + ipv6_bl_pkts))
    local total_bl_bytes=$((ipv4_bl_bytes + ipv6_bl_bytes))
    echo "blacklist ${total_bl_pkts} ${total_bl_bytes}"

    # Whitelist accept counters
    local ipv4_wl_pkts ipv4_wl_bytes ipv6_wl_pkts ipv6_wl_bytes
    ipv4_wl_pkts=$(echo "$ipv4_data" | grep "@whitelist_ipv4" | grep -oP 'counter packets \K\d+' || echo "0")
    ipv4_wl_bytes=$(echo "$ipv4_data" | grep "@whitelist_ipv4" | grep -oP 'bytes \K\d+' || echo "0")
    ipv6_wl_pkts=$(echo "$ipv6_data" | grep "@whitelist_ipv6" | grep -oP 'counter packets \K\d+' || echo "0")
    ipv6_wl_bytes=$(echo "$ipv6_data" | grep "@whitelist_ipv6" | grep -oP 'bytes \K\d+' || echo "0")

    local total_wl_pkts=$((ipv4_wl_pkts + ipv6_wl_pkts))
    local total_wl_bytes=$((ipv4_wl_bytes + ipv6_wl_bytes))
    echo "whitelist ${total_wl_pkts} ${total_wl_bytes}"

    # ICMP counters
    local ipv4_icmp_pkts ipv4_icmp_bytes ipv6_icmp_pkts ipv6_icmp_bytes
    ipv4_icmp_pkts=$(echo "$ipv4_data" | grep "ICMPv4" | grep -oP 'counter packets \K\d+' || echo "0")
    ipv4_icmp_bytes=$(echo "$ipv4_data" | grep "ICMPv4" | grep -oP 'bytes \K\d+' || echo "0")
    ipv6_icmp_pkts=$(echo "$ipv6_data" | grep "ICMPv6" | grep -oP 'counter packets \K\d+' || echo "0")
    ipv6_icmp_bytes=$(echo "$ipv6_data" | grep "ICMPv6" | grep -oP 'bytes \K\d+' || echo "0")

    local total_icmp_pkts=$((ipv4_icmp_pkts + ipv6_icmp_pkts))
    local total_icmp_bytes=$((ipv4_icmp_bytes + ipv6_icmp_bytes))
    echo "icmp_accept ${total_icmp_pkts} ${total_icmp_bytes}"

    # Established connections
    local ipv4_est_pkts ipv4_est_bytes ipv6_est_pkts ipv6_est_bytes
    ipv4_est_pkts=$(echo "$ipv4_data" | grep "established" | grep -oP 'counter packets \K\d+' || echo "0")
    ipv4_est_bytes=$(echo "$ipv4_data" | grep "established" | grep -oP 'bytes \K\d+' || echo "0")
    ipv6_est_pkts=$(echo "$ipv6_data" | grep "established" | grep -oP 'counter packets \K\d+' || echo "0")
    ipv6_est_bytes=$(echo "$ipv6_data" | grep "established" | grep -oP 'bytes \K\d+' || echo "0")

    local total_est_pkts=$((ipv4_est_pkts + ipv6_est_pkts))
    local total_est_bytes=$((ipv4_est_bytes + ipv6_est_bytes))
    echo "established ${total_est_pkts} ${total_est_bytes}"
}

# =============================================================================
# METRIC COLLECTION
# =============================================================================

collect_metrics() {
    # Initialize temp file
    : > "$TEMP_FILE"

    echo "# NFTBan Prometheus Metrics" >> "$TEMP_FILE"
    echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')" >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"

    # -------------------------------------------------------------------------
    # Daemon & Watchdog Metrics (Schema v2)
    # -------------------------------------------------------------------------

    # Get daemon stats via IPC
    local daemon_json=""
    if command -v nftban &>/dev/null; then
        daemon_json=$(nftban watchdog stats --json 2>/dev/null | grep -A100 "^{" | head -50) || daemon_json=""
    fi

    # Parse daemon stats if available
    if [[ -n "$daemon_json" ]] && echo "$daemon_json" | jq -e . &>/dev/null 2>&1; then
        # Daemon info
        local daemon_uptime daemon_pid daemon_mode
        daemon_uptime=$(echo "$daemon_json" | jq -r '.daemon.uptime_seconds // 0')
        daemon_pid=$(echo "$daemon_json" | jq -r '.daemon.pid // 0')
        daemon_mode=$(echo "$daemon_json" | jq -r '.daemon.mode // "unknown"')

        echo "# HELP nftban_daemon_up Whether the NFTBan daemon is running (1=up, 0=down)" >> "$TEMP_FILE"
        echo "# TYPE nftban_daemon_up gauge" >> "$TEMP_FILE"
        echo "nftban_daemon_up 1" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

        echo "# HELP nftban_daemon_uptime_seconds Daemon uptime in seconds" >> "$TEMP_FILE"
        echo "# TYPE nftban_daemon_uptime_seconds gauge" >> "$TEMP_FILE"
        echo "nftban_daemon_uptime_seconds ${daemon_uptime}" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

        echo "# HELP nftban_daemon_info Daemon information" >> "$TEMP_FILE"
        echo "# TYPE nftban_daemon_info gauge" >> "$TEMP_FILE"
        echo "nftban_daemon_info{mode=\"${daemon_mode}\",pid=\"${daemon_pid}\"} 1" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

        # Watchdog metrics
        local wd_status wd_mode wd_cpu wd_mem wd_io
        wd_status=$(echo "$daemon_json" | jq -r '.watchdog.status // 0')
        wd_mode=$(echo "$daemon_json" | jq -r '.watchdog.mode // "unknown"')
        wd_cpu=$(echo "$daemon_json" | jq -r '.watchdog.cpu_score // 0')
        wd_mem=$(echo "$daemon_json" | jq -r '.watchdog.mem_score // 0')
        wd_io=$(echo "$daemon_json" | jq -r '.watchdog.io_score // 0')

        echo "# HELP nftban_watchdog_up Whether the watchdog is running (1=up, 0=down)" >> "$TEMP_FILE"
        echo "# TYPE nftban_watchdog_up gauge" >> "$TEMP_FILE"
        echo "nftban_watchdog_up ${wd_status}" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

        echo "# HELP nftban_watchdog_info Watchdog information" >> "$TEMP_FILE"
        echo "# TYPE nftban_watchdog_info gauge" >> "$TEMP_FILE"
        echo "nftban_watchdog_info{mode=\"${wd_mode}\"} 1" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

        echo "# HELP nftban_watchdog_pressure_score System pressure scores (0-100)" >> "$TEMP_FILE"
        echo "# TYPE nftban_watchdog_pressure_score gauge" >> "$TEMP_FILE"
        echo "nftban_watchdog_pressure_score{type=\"cpu\"} ${wd_cpu}" >> "$TEMP_FILE"
        echo "nftban_watchdog_pressure_score{type=\"memory\"} ${wd_mem}" >> "$TEMP_FILE"
        echo "nftban_watchdog_pressure_score{type=\"io\"} ${wd_io}" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

        # Runtime metrics (Go runtime)
        local goroutines heap_mb alloc_mb sys_mb gc_cycles gc_pause_ms
        goroutines=$(echo "$daemon_json" | jq -r '.runtime.goroutines // 0')
        heap_mb=$(echo "$daemon_json" | jq -r '.runtime.memory_heap_mb // 0')
        alloc_mb=$(echo "$daemon_json" | jq -r '.runtime.memory_alloc_mb // 0')
        sys_mb=$(echo "$daemon_json" | jq -r '.runtime.memory_sys_mb // 0')
        gc_cycles=$(echo "$daemon_json" | jq -r '.runtime.gc_cycles // 0')
        gc_pause_ms=$(echo "$daemon_json" | jq -r '.runtime.gc_pause_ms // 0')

        echo "# HELP nftban_runtime_goroutines Number of active goroutines" >> "$TEMP_FILE"
        echo "# TYPE nftban_runtime_goroutines gauge" >> "$TEMP_FILE"
        echo "nftban_runtime_goroutines ${goroutines}" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

        echo "# HELP nftban_runtime_memory_bytes Memory usage in bytes" >> "$TEMP_FILE"
        echo "# TYPE nftban_runtime_memory_bytes gauge" >> "$TEMP_FILE"
        local heap_bytes alloc_bytes sys_bytes
        heap_bytes=$(awk -v mb="$heap_mb" 'BEGIN {printf "%.0f", mb * 1048576}')
        alloc_bytes=$(awk -v mb="$alloc_mb" 'BEGIN {printf "%.0f", mb * 1048576}')
        sys_bytes=$(awk -v mb="$sys_mb" 'BEGIN {printf "%.0f", mb * 1048576}')
        echo "nftban_runtime_memory_bytes{type=\"heap\"} ${heap_bytes}" >> "$TEMP_FILE"
        echo "nftban_runtime_memory_bytes{type=\"alloc\"} ${alloc_bytes}" >> "$TEMP_FILE"
        echo "nftban_runtime_memory_bytes{type=\"sys\"} ${sys_bytes}" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

        echo "# HELP nftban_runtime_gc_cycles_total Total garbage collection cycles" >> "$TEMP_FILE"
        echo "# TYPE nftban_runtime_gc_cycles_total counter" >> "$TEMP_FILE"
        echo "nftban_runtime_gc_cycles_total ${gc_cycles}" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

        echo "# HELP nftban_runtime_gc_pause_seconds Last GC pause duration in seconds" >> "$TEMP_FILE"
        echo "# TYPE nftban_runtime_gc_pause_seconds gauge" >> "$TEMP_FILE"
        local gc_pause_sec
        gc_pause_sec=$(awk -v ms="$gc_pause_ms" 'BEGIN {printf "%.6f", ms / 1000}')
        echo "nftban_runtime_gc_pause_seconds ${gc_pause_sec}" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

        # IPC metrics
        local ipc_requests ipc_latency_ms ipc_errors
        ipc_requests=$(echo "$daemon_json" | jq -r '.ipc.requests_total // 0')
        ipc_latency_ms=$(echo "$daemon_json" | jq -r '.ipc.avg_latency_ms // 0')
        ipc_errors=$(echo "$daemon_json" | jq -r '.ipc.errors_total // 0')

        echo "# HELP nftban_ipc_requests_total Total IPC requests to daemon" >> "$TEMP_FILE"
        echo "# TYPE nftban_ipc_requests_total counter" >> "$TEMP_FILE"
        echo "nftban_ipc_requests_total ${ipc_requests}" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

        echo "# HELP nftban_ipc_latency_seconds Average IPC request latency in seconds" >> "$TEMP_FILE"
        echo "# TYPE nftban_ipc_latency_seconds gauge" >> "$TEMP_FILE"
        local ipc_latency_sec
        ipc_latency_sec=$(awk -v ms="$ipc_latency_ms" 'BEGIN {printf "%.6f", ms / 1000}')
        echo "nftban_ipc_latency_seconds ${ipc_latency_sec}" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

        echo "# HELP nftban_ipc_errors_total Total IPC errors" >> "$TEMP_FILE"
        echo "# TYPE nftban_ipc_errors_total counter" >> "$TEMP_FILE"
        echo "nftban_ipc_errors_total ${ipc_errors}" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

        # Throughput metrics
        local tp_bans tp_unbans tp_events tp_bans_per_min
        tp_bans=$(echo "$daemon_json" | jq -r '.throughput.bans_total // 0')
        tp_unbans=$(echo "$daemon_json" | jq -r '.throughput.unbans_total // 0')
        tp_events=$(echo "$daemon_json" | jq -r '.throughput.events_total // 0')
        tp_bans_per_min=$(echo "$daemon_json" | jq -r '.throughput.bans_per_min // 0')

        echo "# HELP nftban_throughput_total Throughput counters" >> "$TEMP_FILE"
        echo "# TYPE nftban_throughput_total counter" >> "$TEMP_FILE"
        echo "nftban_throughput_total{type=\"bans\"} ${tp_bans}" >> "$TEMP_FILE"
        echo "nftban_throughput_total{type=\"unbans\"} ${tp_unbans}" >> "$TEMP_FILE"
        echo "nftban_throughput_total{type=\"events\"} ${tp_events}" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

        echo "# HELP nftban_throughput_bans_per_minute Current ban rate per minute" >> "$TEMP_FILE"
        echo "# TYPE nftban_throughput_bans_per_minute gauge" >> "$TEMP_FILE"
        echo "nftban_throughput_bans_per_minute ${tp_bans_per_min}" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"

    else
        # Daemon not available
        echo "# HELP nftban_daemon_up Whether the NFTBan daemon is running (1=up, 0=down)" >> "$TEMP_FILE"
        echo "# TYPE nftban_daemon_up gauge" >> "$TEMP_FILE"
        echo "nftban_daemon_up 0" >> "$TEMP_FILE"
        echo "" >> "$TEMP_FILE"
    fi

    # -------------------------------------------------------------------------
    # Block Metrics
    # -------------------------------------------------------------------------

    local blocks_total
    blocks_total=$(get_block_count total)
    write_metric "nftban_blocks_total" "$blocks_total" \
        "Total number of IPs currently blocked by NFTBan" "gauge"

    local blocks_permanent
    blocks_permanent=$(get_block_count permanent)
    write_metric "nftban_blocks_permanent" "$blocks_permanent" \
        "Number of permanently blocked IPs" "gauge"

    local blocks_temporary
    blocks_temporary=$(get_block_count temporary)
    write_metric "nftban_blocks_temporary" "$blocks_temporary" \
        "Number of temporarily blocked IPs" "gauge"

    local blocks_geoban
    blocks_geoban=$(get_block_count geoban)
    write_metric "nftban_blocks_geoban" "$blocks_geoban" \
        "Number of IPs blocked by geographic restrictions" "gauge"

    # Blocks by country
    echo "# HELP nftban_blocks_by_country Number of blocked IPs by country code" >> "$TEMP_FILE"
    echo "# TYPE nftban_blocks_by_country gauge" >> "$TEMP_FILE"
    get_blocks_by_country >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"

    # -------------------------------------------------------------------------
    # Ban Statistics
    # -------------------------------------------------------------------------

    local bans_total
    bans_total=$(get_total_bans)
    write_metric "nftban_bans_total" "$bans_total" \
        "Cumulative number of bans since last reset" "counter"

    local bans_24h
    bans_24h=$(get_bans_24h)
    write_metric "nftban_bans_last_24h" "$bans_24h" \
        "Number of bans in the last 24 hours" "gauge"

    # -------------------------------------------------------------------------
    # System Health
    # -------------------------------------------------------------------------

    echo "# HELP nftban_health_status Component health status (0=OK, 1=WARN, 2=ERROR, 3=CRITICAL)" >> "$TEMP_FILE"
    echo "# TYPE nftban_health_status gauge" >> "$TEMP_FILE"

    for component in nftables polkit ssh; do
        local status
        status=$(get_health_status "$component")
        echo "nftban_health_status{component=\"$component\"} $status" >> "$TEMP_FILE"
    done
    echo "" >> "$TEMP_FILE"

    local rules_count
    rules_count=$(get_nftables_rules_count)
    write_metric "nftban_nftables_rules_count" "$rules_count" \
        "Number of nftables firewall rules" "gauge"

    # Removed: fail2ban jails metric (v1.0 migration to Suricata)

    # -------------------------------------------------------------------------
    # NFTables Set Size Metrics (v0.6.1 - Consolidated)
    # -------------------------------------------------------------------------

    echo "# HELP nftban_set_size Number of elements in each nftables set" >> "$TEMP_FILE"
    echo "# TYPE nftban_set_size gauge" >> "$TEMP_FILE"

    # Get set sizes (avoid process substitution)
    local set_sizes
    set_sizes=$(get_nftables_set_sizes)

    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local set_name
            local set_count
            set_name=$(echo "$line" | awk '{print $1}')
            set_count=$(echo "$line" | awk '{print $2}')
            echo "nftban_set_size{set=\"${set_name}\"} ${set_count}" >> "$TEMP_FILE"
        fi
    done <<< "$set_sizes"

    echo "" >> "$TEMP_FILE"

    # -------------------------------------------------------------------------
    # Ban Breakdown Metrics (v1.1.0 - IPv4/IPv6 and temp/perm)
    # -------------------------------------------------------------------------

    echo "# HELP nftban_banned_ips Number of banned IPs by family and type" >> "$TEMP_FILE"
    echo "# TYPE nftban_banned_ips gauge" >> "$TEMP_FILE"

    local ban_breakdown
    ban_breakdown=$(get_ban_breakdown)

    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local family ban_type ban_count
            family=$(echo "$line" | awk '{print $1}')
            ban_type=$(echo "$line" | awk '{print $2}')
            ban_count=$(echo "$line" | awk '{print $3}')
            echo "nftban_banned_ips{family=\"${family}\",type=\"${ban_type}\"} ${ban_count}" >> "$TEMP_FILE"
        fi
    done <<< "$ban_breakdown"

    echo "" >> "$TEMP_FILE"

    # -------------------------------------------------------------------------
    # Threat Feeds Metrics (v1.1.0)
    # -------------------------------------------------------------------------

    echo "# HELP nftban_feeds_enabled Number of enabled threat feeds" >> "$TEMP_FILE"
    echo "# TYPE nftban_feeds_enabled gauge" >> "$TEMP_FILE"
    echo "# HELP nftban_feeds_ips Total IPs from enabled threat feeds" >> "$TEMP_FILE"
    echo "# TYPE nftban_feeds_ips gauge" >> "$TEMP_FILE"

    local feeds_metrics
    feeds_metrics=$(get_feeds_metrics)

    local feeds_enabled feeds_ipv4 feeds_ipv6
    feeds_enabled=$(echo "$feeds_metrics" | grep "^enabled" | awk '{print $2}')
    feeds_ipv4=$(echo "$feeds_metrics" | grep "^ipv4" | awk '{print $2}')
    feeds_ipv6=$(echo "$feeds_metrics" | grep "^ipv6" | awk '{print $2}')

    echo "nftban_feeds_enabled ${feeds_enabled:-0}" >> "$TEMP_FILE"
    echo "nftban_feeds_ips{family=\"ipv4\"} ${feeds_ipv4:-0}" >> "$TEMP_FILE"
    echo "nftban_feeds_ips{family=\"ipv6\"} ${feeds_ipv6:-0}" >> "$TEMP_FILE"

    echo "" >> "$TEMP_FILE"

    # -------------------------------------------------------------------------
    # NFTables Firewall Counter Metrics (v0.6.1 - Consolidated)
    # -------------------------------------------------------------------------

    echo "# HELP nftban_firewall_packets_total Total packets processed by firewall rules" >> "$TEMP_FILE"
    echo "# TYPE nftban_firewall_packets_total counter" >> "$TEMP_FILE"
    echo "# HELP nftban_firewall_bytes_total Total bytes processed by firewall rules" >> "$TEMP_FILE"
    echo "# TYPE nftban_firewall_bytes_total counter" >> "$TEMP_FILE"

    # Get counters (avoid process substitution)
    local nft_counters
    nft_counters=$(get_nftables_counters)

    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local reason
            local packets
            local bytes
            local action

            reason=$(echo "$line" | awk '{print $1}')
            packets=$(echo "$line" | awk '{print $2}')
            bytes=$(echo "$line" | awk '{print $3}')

            # Determine action based on reason
            if [[ "$reason" == "whitelist" ]]; then
                action="accept"
            else
                action="drop"
            fi

            echo "nftban_firewall_packets_total{action=\"${action}\",reason=\"${reason}\"} ${packets}" >> "$TEMP_FILE"
            echo "nftban_firewall_bytes_total{action=\"${action}\",reason=\"${reason}\"} ${bytes}" >> "$TEMP_FILE"
        fi
    done <<< "$nft_counters"

    echo "" >> "$TEMP_FILE"

    # -------------------------------------------------------------------------
    # Phase 1 Metrics from Combined JSON (Kernel, Module Status, Feed Health)
    # -------------------------------------------------------------------------

    if [[ -f "$COMBINED_FILE" ]] && command -v jq &>/dev/null; then
        # PERFORMANCE: Extract all Phase 1 metrics in single jq call (was 16 separate calls)
        local phase1_values
        phase1_values=$(jq -r '
            [
                .kernel.conntrack_entries // 0,
                .kernel.conntrack_max // 0,
                .kernel.conntrack_utilization // 0,
                .kernel.softnet_drops // 0,
                .kernel.softnet_backlog // 0,
                .module_status.suricata // 0,
                .module_status.loginmon // 0,
                .module_status.portscan // 0,
                .module_status.ddos // 0,
                .module_status.feeds // 0,
                .module_status.geoban // 0,
                .module_status.watchdog // 0,
                .feed_health.total_feeds // 0,
                .feed_health.active_feeds // 0,
                .feed_health.stale_feeds // 0,
                .feed_health.sync_errors_24h // 0
            ] | @tsv
        ' "$COMBINED_FILE" 2>/dev/null) || phase1_values=""

        if [[ -n "$phase1_values" ]]; then
            # Parse the tab-separated values
            local ct_entries ct_max ct_util sn_drops sn_backlog
            local mod_suricata mod_loginmon mod_portscan mod_ddos mod_feeds mod_geoban mod_watchdog
            local fh_total fh_active fh_stale fh_errors
            # shellcheck disable=SC2034
            IFS=$'\t' read -r ct_entries ct_max ct_util sn_drops sn_backlog \
                mod_suricata mod_loginmon mod_portscan mod_ddos mod_feeds mod_geoban mod_watchdog \
                fh_total fh_active fh_stale fh_errors <<< "$phase1_values"

            # Kernel metrics
            echo "# HELP nftban_conntrack_entries Current conntrack table entries" >> "$TEMP_FILE"
            echo "# TYPE nftban_conntrack_entries gauge" >> "$TEMP_FILE"
            echo "nftban_conntrack_entries ${ct_entries:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_conntrack_max Maximum conntrack table size" >> "$TEMP_FILE"
            echo "# TYPE nftban_conntrack_max gauge" >> "$TEMP_FILE"
            echo "nftban_conntrack_max ${ct_max:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_conntrack_utilization Conntrack utilization percentage" >> "$TEMP_FILE"
            echo "# TYPE nftban_conntrack_utilization gauge" >> "$TEMP_FILE"
            echo "nftban_conntrack_utilization ${ct_util:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_softnet_drops_total Kernel softnet packet drops" >> "$TEMP_FILE"
            echo "# TYPE nftban_softnet_drops_total counter" >> "$TEMP_FILE"
            echo "nftban_softnet_drops_total ${sn_drops:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_softnet_backlog_total Kernel softnet backlog overflow" >> "$TEMP_FILE"
            echo "# TYPE nftban_softnet_backlog_total counter" >> "$TEMP_FILE"
            echo "nftban_softnet_backlog_total ${sn_backlog:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            # Module status metrics - values already extracted (no loop needed)
            echo "# HELP nftban_module_up Module running status" >> "$TEMP_FILE"
            echo "# TYPE nftban_module_up gauge" >> "$TEMP_FILE"
            echo "nftban_module_up{module=\"suricata\"} ${mod_suricata:-0}" >> "$TEMP_FILE"
            echo "nftban_module_up{module=\"loginmon\"} ${mod_loginmon:-0}" >> "$TEMP_FILE"
            echo "nftban_module_up{module=\"portscan\"} ${mod_portscan:-0}" >> "$TEMP_FILE"
            echo "nftban_module_up{module=\"ddos\"} ${mod_ddos:-0}" >> "$TEMP_FILE"
            echo "nftban_module_up{module=\"feeds\"} ${mod_feeds:-0}" >> "$TEMP_FILE"
            echo "nftban_module_up{module=\"geoban\"} ${mod_geoban:-0}" >> "$TEMP_FILE"
            echo "nftban_module_up{module=\"watchdog\"} ${mod_watchdog:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            # Feed health metrics - values already extracted
            echo "# HELP nftban_feeds_total Total configured feeds" >> "$TEMP_FILE"
            echo "# TYPE nftban_feeds_total gauge" >> "$TEMP_FILE"
            echo "nftban_feeds_total ${fh_total:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_feeds_active_total Active feeds count" >> "$TEMP_FILE"
            echo "# TYPE nftban_feeds_active_total gauge" >> "$TEMP_FILE"
            echo "nftban_feeds_active_total ${fh_active:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_feeds_stale Stale feeds count" >> "$TEMP_FILE"
            echo "# TYPE nftban_feeds_stale gauge" >> "$TEMP_FILE"
            echo "nftban_feeds_stale ${fh_stale:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_feeds_sync_errors_total Feed sync errors in last 24h" >> "$TEMP_FILE"
            echo "# TYPE nftban_feeds_sync_errors_total counter" >> "$TEMP_FILE"
            echo "nftban_feeds_sync_errors_total ${fh_errors:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"
        fi
    fi

    # -------------------------------------------------------------------------
    # Suricata IDS Metrics
    # -------------------------------------------------------------------------

    # Suricata IDS metrics
    # PERFORMANCE: Extract all Suricata metrics in single jq call (was 11 separate calls)
    if [[ -f "$COMBINED_FILE" ]] && command -v jq &>/dev/null; then
        local suricata_values
        suricata_values=$(jq -r '
            [
                .suricata.up // 0,
                .suricata.alerts_total // 0,
                .suricata.alerts_by_severity."1" // 0,
                .suricata.alerts_by_severity."2" // 0,
                .suricata.alerts_by_severity."3" // 0,
                .suricata.alerts_by_severity."4" // 0,
                .suricata.rules_total // 0,
                .suricata.rules_filtered // 0,
                .suricata.bans_total // 0,
                .suricata.eve_parse_errors // 0,
                .suricata.last_alert_timestamp // 0,
                .suricata.rule_profile // "unknown"
            ] | @tsv
        ' "$COMBINED_FILE" 2>/dev/null) || suricata_values=""

        if [[ -n "$suricata_values" ]]; then
            local sur_up sur_alerts sur_sev1 sur_sev2 sur_sev3 sur_sev4
            local sur_rules sur_filtered sur_bans sur_eve_errors sur_last_ts sur_profile
            # shellcheck disable=SC2034
            IFS=$'\t' read -r sur_up sur_alerts sur_sev1 sur_sev2 sur_sev3 sur_sev4 \
                sur_rules sur_filtered sur_bans sur_eve_errors sur_last_ts sur_profile <<< "$suricata_values"

            echo "# HELP nftban_suricata_up Suricata daemon running status" >> "$TEMP_FILE"
            echo "# TYPE nftban_suricata_up gauge" >> "$TEMP_FILE"
            echo "nftban_suricata_up ${sur_up:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_suricata_alerts_total Total Suricata alerts" >> "$TEMP_FILE"
            echo "# TYPE nftban_suricata_alerts_total counter" >> "$TEMP_FILE"
            echo "nftban_suricata_alerts_total ${sur_alerts:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_suricata_alerts_by_severity Suricata alerts by severity level" >> "$TEMP_FILE"
            echo "# TYPE nftban_suricata_alerts_by_severity counter" >> "$TEMP_FILE"
            echo "nftban_suricata_alerts_by_severity{severity=\"1\"} ${sur_sev1:-0}" >> "$TEMP_FILE"
            echo "nftban_suricata_alerts_by_severity{severity=\"2\"} ${sur_sev2:-0}" >> "$TEMP_FILE"
            echo "nftban_suricata_alerts_by_severity{severity=\"3\"} ${sur_sev3:-0}" >> "$TEMP_FILE"
            echo "nftban_suricata_alerts_by_severity{severity=\"4\"} ${sur_sev4:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_suricata_rules_total Total active Suricata rules" >> "$TEMP_FILE"
            echo "# TYPE nftban_suricata_rules_total gauge" >> "$TEMP_FILE"
            echo "nftban_suricata_rules_total ${sur_rules:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_suricata_rules_filtered Filtered/disabled Suricata rules" >> "$TEMP_FILE"
            echo "# TYPE nftban_suricata_rules_filtered gauge" >> "$TEMP_FILE"
            echo "nftban_suricata_rules_filtered ${sur_filtered:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_suricata_bans_total Bans triggered by Suricata" >> "$TEMP_FILE"
            echo "# TYPE nftban_suricata_bans_total counter" >> "$TEMP_FILE"
            echo "nftban_suricata_bans_total ${sur_bans:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_suricata_eve_parse_errors_total EVE JSON parsing errors" >> "$TEMP_FILE"
            echo "# TYPE nftban_suricata_eve_parse_errors_total counter" >> "$TEMP_FILE"
            echo "nftban_suricata_eve_parse_errors_total ${sur_eve_errors:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_suricata_last_alert_timestamp Unix timestamp of last alert" >> "$TEMP_FILE"
            echo "# TYPE nftban_suricata_last_alert_timestamp gauge" >> "$TEMP_FILE"
            echo "nftban_suricata_last_alert_timestamp ${sur_last_ts:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_suricata_info Suricata configuration info" >> "$TEMP_FILE"
            echo "# TYPE nftban_suricata_info gauge" >> "$TEMP_FILE"
            echo "nftban_suricata_info{rule_profile=\"${sur_profile:-unknown}\"} 1" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"
        fi
    fi

    # -------------------------------------------------------------------------
    # Event Bus metrics
    # -------------------------------------------------------------------------

    # PERFORMANCE: Extract all Event Bus metrics in single jq call (was 11 separate calls)
    if [[ -f "$COMBINED_FILE" ]] && command -v jq &>/dev/null; then
        local eventbus_values
        eventbus_values=$(jq -r '
            [
                .eventbus.events_total // 0,
                .eventbus.events_by_type.ban // 0,
                .eventbus.events_by_type.unban // 0,
                .eventbus.events_by_type.login_fail // 0,
                .eventbus.events_by_type.ddos_detected // 0,
                .eventbus.events_by_type.portscan_detected // 0,
                .eventbus.events_by_type.suricata_alert // 0,
                .eventbus.events_by_type.feed_sync // 0,
                .eventbus.events_dropped // 0,
                .eventbus.queue_size // 0,
                .eventbus.handlers_total // 0
            ] | @tsv
        ' "$COMBINED_FILE" 2>/dev/null) || eventbus_values=""

        if [[ -n "$eventbus_values" ]]; then
            local eb_total eb_ban eb_unban eb_login eb_ddos eb_portscan eb_suricata eb_feed
            local eb_dropped eb_queue eb_handlers
            # shellcheck disable=SC2034
            IFS=$'\t' read -r eb_total eb_ban eb_unban eb_login eb_ddos eb_portscan eb_suricata eb_feed \
                eb_dropped eb_queue eb_handlers <<< "$eventbus_values"

            echo "# HELP nftban_eventbus_events_total Total events processed by event bus" >> "$TEMP_FILE"
            echo "# TYPE nftban_eventbus_events_total counter" >> "$TEMP_FILE"
            echo "nftban_eventbus_events_total ${eb_total:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_eventbus_events_by_type Events by type" >> "$TEMP_FILE"
            echo "# TYPE nftban_eventbus_events_by_type counter" >> "$TEMP_FILE"
            echo "nftban_eventbus_events_by_type{type=\"ban\"} ${eb_ban:-0}" >> "$TEMP_FILE"
            echo "nftban_eventbus_events_by_type{type=\"unban\"} ${eb_unban:-0}" >> "$TEMP_FILE"
            echo "nftban_eventbus_events_by_type{type=\"login_fail\"} ${eb_login:-0}" >> "$TEMP_FILE"
            echo "nftban_eventbus_events_by_type{type=\"ddos_detected\"} ${eb_ddos:-0}" >> "$TEMP_FILE"
            echo "nftban_eventbus_events_by_type{type=\"portscan_detected\"} ${eb_portscan:-0}" >> "$TEMP_FILE"
            echo "nftban_eventbus_events_by_type{type=\"suricata_alert\"} ${eb_suricata:-0}" >> "$TEMP_FILE"
            echo "nftban_eventbus_events_by_type{type=\"feed_sync\"} ${eb_feed:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_eventbus_events_dropped_total Dropped events" >> "$TEMP_FILE"
            echo "# TYPE nftban_eventbus_events_dropped_total counter" >> "$TEMP_FILE"
            echo "nftban_eventbus_events_dropped_total ${eb_dropped:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_eventbus_queue_size Current event queue depth" >> "$TEMP_FILE"
            echo "# TYPE nftban_eventbus_queue_size gauge" >> "$TEMP_FILE"
            echo "nftban_eventbus_queue_size ${eb_queue:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_eventbus_handlers_total Registered event handlers" >> "$TEMP_FILE"
            echo "# TYPE nftban_eventbus_handlers_total gauge" >> "$TEMP_FILE"
            echo "nftban_eventbus_handlers_total ${eb_handlers:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"
        fi
    fi

    # -------------------------------------------------------------------------
    # NFTables Performance metrics
    # -------------------------------------------------------------------------

    # PERFORMANCE: Extract all NFTables Performance metrics in single jq call (was 9 separate calls)
    if [[ -f "$COMBINED_FILE" ]] && command -v jq &>/dev/null; then
        local nftperf_values
        nftperf_values=$(jq -r '
            [
                .nftables_perf.apply_latency_ms // 0,
                .nftables_perf.apply_errors_total // 0,
                .nftables_perf.rules_total // 0,
                .nftables_perf.sets_total // 0,
                .nftables_perf.set_elements.blacklist_ipv4 // 0,
                .nftables_perf.set_elements.blacklist_ipv6 // 0,
                .nftables_perf.set_elements.whitelist_ipv4 // 0,
                .nftables_perf.set_elements.whitelist_ipv6 // 0,
                .nftables_perf.commands_total // 0
            ] | @tsv
        ' "$COMBINED_FILE" 2>/dev/null) || nftperf_values=""

        if [[ -n "$nftperf_values" ]]; then
            local nft_latency nft_errors nft_rules nft_sets
            local nft_bl4 nft_bl6 nft_wl4 nft_wl6 nft_cmds
            # shellcheck disable=SC2034
            IFS=$'\t' read -r nft_latency nft_errors nft_rules nft_sets \
                nft_bl4 nft_bl6 nft_wl4 nft_wl6 nft_cmds <<< "$nftperf_values"

            echo "# HELP nftban_nftables_apply_latency_ms Rule application latency" >> "$TEMP_FILE"
            echo "# TYPE nftban_nftables_apply_latency_ms gauge" >> "$TEMP_FILE"
            echo "nftban_nftables_apply_latency_ms ${nft_latency:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_nftables_apply_errors_total Rule application failures" >> "$TEMP_FILE"
            echo "# TYPE nftban_nftables_apply_errors_total counter" >> "$TEMP_FILE"
            echo "nftban_nftables_apply_errors_total ${nft_errors:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_nftables_rules_total Total nftables rules" >> "$TEMP_FILE"
            echo "# TYPE nftban_nftables_rules_total gauge" >> "$TEMP_FILE"
            echo "nftban_nftables_rules_total ${nft_rules:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_nftables_sets_total Total nftables sets" >> "$TEMP_FILE"
            echo "# TYPE nftban_nftables_sets_total gauge" >> "$TEMP_FILE"
            echo "nftban_nftables_sets_total ${nft_sets:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_nftables_set_elements Elements per set" >> "$TEMP_FILE"
            echo "# TYPE nftban_nftables_set_elements gauge" >> "$TEMP_FILE"
            echo "nftban_nftables_set_elements{set=\"blacklist_ipv4\"} ${nft_bl4:-0}" >> "$TEMP_FILE"
            echo "nftban_nftables_set_elements{set=\"blacklist_ipv6\"} ${nft_bl6:-0}" >> "$TEMP_FILE"
            echo "nftban_nftables_set_elements{set=\"whitelist_ipv4\"} ${nft_wl4:-0}" >> "$TEMP_FILE"
            echo "nftban_nftables_set_elements{set=\"whitelist_ipv6\"} ${nft_wl6:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_nftables_commands_total Total nft commands executed" >> "$TEMP_FILE"
            echo "# TYPE nftban_nftables_commands_total counter" >> "$TEMP_FILE"
            echo "nftban_nftables_commands_total ${nft_cmds:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"
        fi
    fi

    # -------------------------------------------------------------------------
    # Ban Details metrics (Phase 4)
    # -------------------------------------------------------------------------

    # PERFORMANCE: Extract all Ban Details metrics in single jq call (was 11 separate calls)
    if [[ -f "$COMBINED_FILE" ]] && command -v jq &>/dev/null; then
        local bandetails_values
        bandetails_values=$(jq -r '
            [
                .ban_details.bans_by_source.manual // 0,
                .ban_details.bans_by_source.feeds // 0,
                .ban_details.bans_by_source.loginmon // 0,
                .ban_details.bans_by_source.portscan // 0,
                .ban_details.bans_by_source.ddos // 0,
                .ban_details.bans_by_source.suricata // 0,
                .ban_details.bans_by_source.geoban // 0,
                .ban_details.escalations_total // 0,
                .ban_details.persistent_offenders_total // 0,
                .ban_details.recidivist_ips_total // 0,
                .ban_details.ban_failures_total // 0
            ] | @tsv
        ' "$COMBINED_FILE" 2>/dev/null) || bandetails_values=""

        if [[ -n "$bandetails_values" ]]; then
            local bd_manual bd_feeds bd_loginmon bd_portscan bd_ddos bd_suricata bd_geoban
            local bd_escalations bd_persistent bd_recidivist bd_failures
            # shellcheck disable=SC2034
            IFS=$'\t' read -r bd_manual bd_feeds bd_loginmon bd_portscan bd_ddos bd_suricata bd_geoban \
                bd_escalations bd_persistent bd_recidivist bd_failures <<< "$bandetails_values"

            echo "# HELP nftban_bans_by_source_total Bans by source" >> "$TEMP_FILE"
            echo "# TYPE nftban_bans_by_source_total counter" >> "$TEMP_FILE"
            echo "nftban_bans_by_source_total{source=\"manual\"} ${bd_manual:-0}" >> "$TEMP_FILE"
            echo "nftban_bans_by_source_total{source=\"feeds\"} ${bd_feeds:-0}" >> "$TEMP_FILE"
            echo "nftban_bans_by_source_total{source=\"loginmon\"} ${bd_loginmon:-0}" >> "$TEMP_FILE"
            echo "nftban_bans_by_source_total{source=\"portscan\"} ${bd_portscan:-0}" >> "$TEMP_FILE"
            echo "nftban_bans_by_source_total{source=\"ddos\"} ${bd_ddos:-0}" >> "$TEMP_FILE"
            echo "nftban_bans_by_source_total{source=\"suricata\"} ${bd_suricata:-0}" >> "$TEMP_FILE"
            echo "nftban_bans_by_source_total{source=\"geoban\"} ${bd_geoban:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_escalations_total Ban escalations" >> "$TEMP_FILE"
            echo "# TYPE nftban_escalations_total counter" >> "$TEMP_FILE"
            echo "nftban_escalations_total ${bd_escalations:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_persistent_offenders_total Permanent banned IPs" >> "$TEMP_FILE"
            echo "# TYPE nftban_persistent_offenders_total gauge" >> "$TEMP_FILE"
            echo "nftban_persistent_offenders_total ${bd_persistent:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_recidivist_ips_total IPs banned multiple times" >> "$TEMP_FILE"
            echo "# TYPE nftban_recidivist_ips_total gauge" >> "$TEMP_FILE"
            echo "nftban_recidivist_ips_total ${bd_recidivist:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_ban_failures_total Failed ban attempts" >> "$TEMP_FILE"
            echo "# TYPE nftban_ban_failures_total counter" >> "$TEMP_FILE"
            echo "nftban_ban_failures_total ${bd_failures:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"
        fi
    fi

    # -------------------------------------------------------------------------
    # Analytics metrics (Phase 5)
    # -------------------------------------------------------------------------

    # PERFORMANCE: Extract all Analytics metrics in single jq call (was 8 separate calls)
    if [[ -f "$COMBINED_FILE" ]] && command -v jq &>/dev/null; then
        local analytics_values
        analytics_values=$(jq -r '
            [
                .analytics.unique_ips_24h // 0,
                .analytics.recidivism_rate // 0,
                .analytics.top_attackers_total // 0,
                .analytics.watchdog_mode_transitions_total // 0,
                .analytics.alerts_active.info // 0,
                .analytics.alerts_active.warning // 0,
                .analytics.alerts_active.critical // 0,
                .analytics.geoban_database_age_seconds // 0
            ] | @tsv
        ' "$COMBINED_FILE" 2>/dev/null) || analytics_values=""

        if [[ -n "$analytics_values" ]]; then
            local an_unique an_recid an_top an_wdtrans an_info an_warn an_crit an_geoage
            # shellcheck disable=SC2034
            IFS=$'\t' read -r an_unique an_recid an_top an_wdtrans an_info an_warn an_crit an_geoage <<< "$analytics_values"

            echo "# HELP nftban_analytics_unique_ips_24h Unique IPs banned in last 24 hours" >> "$TEMP_FILE"
            echo "# TYPE nftban_analytics_unique_ips_24h gauge" >> "$TEMP_FILE"
            echo "nftban_analytics_unique_ips_24h ${an_unique:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_analytics_recidivism_rate Percentage of repeat offender IPs" >> "$TEMP_FILE"
            echo "# TYPE nftban_analytics_recidivism_rate gauge" >> "$TEMP_FILE"
            echo "nftban_analytics_recidivism_rate ${an_recid:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_analytics_top_attackers_total IPs with more than 5 bans" >> "$TEMP_FILE"
            echo "# TYPE nftban_analytics_top_attackers_total gauge" >> "$TEMP_FILE"
            echo "nftban_analytics_top_attackers_total ${an_top:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_watchdog_mode_transitions_total Watchdog mode changes" >> "$TEMP_FILE"
            echo "# TYPE nftban_watchdog_mode_transitions_total counter" >> "$TEMP_FILE"
            echo "nftban_watchdog_mode_transitions_total ${an_wdtrans:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            echo "# HELP nftban_alerts_active Active alerts by level" >> "$TEMP_FILE"
            echo "# TYPE nftban_alerts_active gauge" >> "$TEMP_FILE"
            echo "nftban_alerts_active{level=\"info\"} ${an_info:-0}" >> "$TEMP_FILE"
            echo "nftban_alerts_active{level=\"warning\"} ${an_warn:-0}" >> "$TEMP_FILE"
            echo "nftban_alerts_active{level=\"critical\"} ${an_crit:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"

            # v1.19.12: Fixed naming - geoip is the database, geoban is the module
            echo "# HELP nftban_geoip_database_age_seconds Age of GeoIP database in seconds" >> "$TEMP_FILE"
            echo "# TYPE nftban_geoip_database_age_seconds gauge" >> "$TEMP_FILE"
            echo "nftban_geoip_database_age_seconds ${an_geoage:-0}" >> "$TEMP_FILE"
            echo "" >> "$TEMP_FILE"
        fi
    fi

    # -------------------------------------------------------------------------
    # Performance Metrics
    # -------------------------------------------------------------------------

    local end_time
    end_time=$(date +%s.%N)
    local duration
    duration=$(echo "$end_time - $START_TIME" | bc -l 2>/dev/null || echo "0")

    write_metric "nftban_exporter_duration_seconds" "$duration" \
        "Time taken to collect all metrics in seconds" "gauge"

    local timestamp
    timestamp=$(date +%s)
    write_metric "nftban_last_update_timestamp" "$timestamp" \
        "Unix timestamp of last metrics update" "gauge"

    # -------------------------------------------------------------------------
    # Network Bandwidth Metrics (v0.6.1 - Consolidated)
    # -------------------------------------------------------------------------

    # Initialize bandwidth temp directory
    init_bandwidth_temp_dir

    echo "# HELP nftban_network_rx_bytes Total received bytes per interface" >> "$TEMP_FILE"
    echo "# TYPE nftban_network_rx_bytes counter" >> "$TEMP_FILE"
    echo "# HELP nftban_network_tx_bytes Total transmitted bytes per interface" >> "$TEMP_FILE"
    echo "# TYPE nftban_network_tx_bytes counter" >> "$TEMP_FILE"
    echo "# HELP nftban_network_rx_packets Total received packets per interface" >> "$TEMP_FILE"
    echo "# TYPE nftban_network_rx_packets counter" >> "$TEMP_FILE"
    echo "# HELP nftban_network_tx_packets Total transmitted packets per interface" >> "$TEMP_FILE"
    echo "# TYPE nftban_network_tx_packets counter" >> "$TEMP_FILE"
    echo "# HELP nftban_network_rx_mbps Current receive bandwidth in Mbps" >> "$TEMP_FILE"
    echo "# TYPE nftban_network_rx_mbps gauge" >> "$TEMP_FILE"
    echo "# HELP nftban_network_tx_mbps Current transmit bandwidth in Mbps" >> "$TEMP_FILE"
    echo "# TYPE nftban_network_tx_mbps gauge" >> "$TEMP_FILE"

    # Collect per-interface statistics
    local total_rx_bytes=0
    local total_tx_bytes=0
    local total_rx_packets=0
    local total_tx_packets=0
    local total_rx_mbps=0
    local total_tx_mbps=0
    local iface

    # Get list of interfaces first (avoid process substitution)
    local active_interfaces
    active_interfaces=$(get_active_interfaces)

    for iface in $active_interfaces; do
        local stats
        local rx_bytes
        local rx_packets
        local tx_bytes
        local tx_packets
        stats=$(get_interface_stats "$iface") || continue

        rx_bytes=$(echo "$stats" | awk '{print $1}')
        rx_packets=$(echo "$stats" | awk '{print $2}')
        tx_bytes=$(echo "$stats" | awk '{print $3}')
        tx_packets=$(echo "$stats" | awk '{print $4}')

        # Output counter metrics
        echo "nftban_network_rx_bytes{interface=\"${iface}\"} ${rx_bytes}" >> "$TEMP_FILE"
        echo "nftban_network_tx_bytes{interface=\"${iface}\"} ${tx_bytes}" >> "$TEMP_FILE"
        echo "nftban_network_rx_packets{interface=\"${iface}\"} ${rx_packets}" >> "$TEMP_FILE"
        echo "nftban_network_tx_packets{interface=\"${iface}\"} ${tx_packets}" >> "$TEMP_FILE"

        # Calculate bandwidth (Mbps) from previous state
        if [[ -f "$STATE_FILE" ]]; then
            local prev_data
            prev_data=$(grep "^${iface} " "$STATE_FILE" 2>/dev/null || echo "")

            if [[ -n "$prev_data" ]]; then
                local prev_ts
                local prev_rx
                local prev_tx
                local time_delta
                local rx_delta
                local tx_delta
                local rx_mbps
                local tx_mbps

                prev_ts=$(echo "$prev_data" | awk '{print $2}')
                prev_rx=$(echo "$prev_data" | awk '{print $3}')
                prev_tx=$(echo "$prev_data" | awk '{print $4}')

                time_delta=$(( START_TIME_UNIX - prev_ts ))
                rx_delta=$(( rx_bytes - prev_rx ))
                tx_delta=$(( tx_bytes - prev_tx ))

                # Handle counter resets
                [[ $rx_delta -lt 0 ]] && rx_delta=$rx_bytes
                [[ $tx_delta -lt 0 ]] && tx_delta=$tx_bytes

                rx_mbps=$(calculate_mbps "$rx_delta" "$time_delta")
                tx_mbps=$(calculate_mbps "$tx_delta" "$time_delta")

                echo "nftban_network_rx_mbps{interface=\"${iface}\"} ${rx_mbps}" >> "$TEMP_FILE"
                echo "nftban_network_tx_mbps{interface=\"${iface}\"} ${tx_mbps}" >> "$TEMP_FILE"

                total_rx_mbps=$(awk -v a="$total_rx_mbps" -v b="$rx_mbps" 'BEGIN {printf "%.2f", a + b}')
                total_tx_mbps=$(awk -v a="$total_tx_mbps" -v b="$tx_mbps" 'BEGIN {printf "%.2f", a + b}')
            fi
        fi

        # Accumulate totals
        total_rx_bytes=$(( total_rx_bytes + rx_bytes ))
        total_tx_bytes=$(( total_tx_bytes + tx_bytes ))
        total_rx_packets=$(( total_rx_packets + rx_packets ))
        total_tx_packets=$(( total_tx_packets + tx_packets ))

    done

    echo "" >> "$TEMP_FILE"

    # Output total bandwidth
    echo "# HELP nftban_network_total_rx_mbps Total receive bandwidth across all interfaces" >> "$TEMP_FILE"
    echo "# TYPE nftban_network_total_rx_mbps gauge" >> "$TEMP_FILE"
    echo "nftban_network_total_rx_mbps ${total_rx_mbps}" >> "$TEMP_FILE"
    echo "# HELP nftban_network_total_tx_mbps Total transmit bandwidth across all interfaces" >> "$TEMP_FILE"
    echo "# TYPE nftban_network_total_tx_mbps gauge" >> "$TEMP_FILE"
    echo "nftban_network_total_tx_mbps ${total_tx_mbps}" >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"

    # Protocol statistics
    echo "# HELP nftban_protocol_bytes Total bytes per protocol" >> "$TEMP_FILE"
    echo "# TYPE nftban_protocol_bytes counter" >> "$TEMP_FILE"
    echo "nftban_protocol_bytes{protocol=\"tcp\"} $(get_protocol_stats tcp bytes)" >> "$TEMP_FILE"
    echo "nftban_protocol_bytes{protocol=\"udp\"} $(get_protocol_stats udp bytes)" >> "$TEMP_FILE"
    echo "nftban_protocol_bytes{protocol=\"icmp\"} $(get_protocol_stats icmp bytes)" >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"

    echo "# HELP nftban_protocol_packets Total packets per protocol" >> "$TEMP_FILE"
    echo "# TYPE nftban_protocol_packets counter" >> "$TEMP_FILE"
    echo "nftban_protocol_packets{protocol=\"tcp\"} $(get_protocol_stats tcp packets)" >> "$TEMP_FILE"
    echo "nftban_protocol_packets{protocol=\"udp\"} $(get_protocol_stats udp packets)" >> "$TEMP_FILE"
    echo "nftban_protocol_packets{protocol=\"icmp\"} $(get_protocol_stats icmp packets)" >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"

    # Connection statistics
    echo "# HELP nftban_connections_active Total active TCP connections" >> "$TEMP_FILE"
    echo "# TYPE nftban_connections_active gauge" >> "$TEMP_FILE"
    echo "nftban_connections_active $(get_connection_stats active)" >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"

    echo "# HELP nftban_connections_established Established TCP connections" >> "$TEMP_FILE"
    echo "# TYPE nftban_connections_established gauge" >> "$TEMP_FILE"
    echo "nftban_connections_established $(get_connection_stats established)" >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"

    echo "# HELP nftban_connections_time_wait TCP connections in TIME_WAIT state" >> "$TEMP_FILE"
    echo "# TYPE nftban_connections_time_wait gauge" >> "$TEMP_FILE"
    echo "nftban_connections_time_wait $(get_connection_stats time_wait)" >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"

    echo "# HELP nftban_connections_close_wait TCP connections in CLOSE_WAIT state" >> "$TEMP_FILE"
    echo "# TYPE nftban_connections_close_wait gauge" >> "$TEMP_FILE"
    echo "nftban_connections_close_wait $(get_connection_stats close_wait)" >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"

    # Peak tracking
    local peaks
    local peak_rx
    local peak_tx
    peaks=$(update_peaks "$total_rx_mbps" "$total_tx_mbps" "$START_TIME_UNIX")
    peak_rx=$(echo "$peaks" | awk '{print $1}')
    peak_tx=$(echo "$peaks" | awk '{print $2}')

    echo "# HELP nftban_bandwidth_peak_rx_mbps Peak receive bandwidth in last 5 minutes" >> "$TEMP_FILE"
    echo "# TYPE nftban_bandwidth_peak_rx_mbps gauge" >> "$TEMP_FILE"
    echo "nftban_bandwidth_peak_rx_mbps ${peak_rx}" >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"

    echo "# HELP nftban_bandwidth_peak_tx_mbps Peak transmit bandwidth in last 5 minutes" >> "$TEMP_FILE"
    echo "# TYPE nftban_bandwidth_peak_tx_mbps gauge" >> "$TEMP_FILE"
    echo "nftban_bandwidth_peak_tx_mbps ${peak_tx}" >> "$TEMP_FILE"
    echo "" >> "$TEMP_FILE"

    # Update state file for next run
    {
        for iface in $active_interfaces; do
            local stats
            local rx_bytes
            local tx_bytes
            stats=$(get_interface_stats "$iface") || continue
            rx_bytes=$(echo "$stats" | awk '{print $1}')
            tx_bytes=$(echo "$stats" | awk '{print $3}')
            echo "${iface} ${START_TIME_UNIX} ${rx_bytes} ${tx_bytes}"
        done
    } > "${STATE_FILE}.new"
    mv -f "${STATE_FILE}.new" "$STATE_FILE" 2>/dev/null || true

    # -------------------------------------------------------------------------
    # Call Sub-Exporters (v0.6.1+)
    # -------------------------------------------------------------------------

    # Run additional exporters if they exist
    local exporter_dir="${NFTBAN_LIB_DIR}/exporters"

    if [[ -x "${exporter_dir}/nftban_firewall_exporter.sh" ]]; then
        "${exporter_dir}/nftban_firewall_exporter.sh" 2>/dev/null || true
    fi

    if [[ -x "${exporter_dir}/nftban_geoban_exporter.sh" ]]; then
        "${exporter_dir}/nftban_geoban_exporter.sh" 2>/dev/null || true
    fi

    if [[ -x "${exporter_dir}/nftban_portscan_exporter.sh" ]]; then
        "${exporter_dir}/nftban_portscan_exporter.sh" 2>/dev/null || true
    fi

    # -------------------------------------------------------------------------
    # Finalize
    # -------------------------------------------------------------------------

    # Atomic write: move temp file to final location
    chmod 644 "$TEMP_FILE"
    mv -f "$TEMP_FILE" "$OUTPUT_FILE"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Ensure output directory exists
    local output_dir
    output_dir=$(dirname "$OUTPUT_FILE")

    if [[ ! -d "$output_dir" ]]; then
        mkdir -p "$output_dir" || return 1
        # Set ownership if running as root (non-recursive - just the directory)
        if [[ $EUID -eq 0 ]]; then
            chown nftban:nftban "$output_dir" 2>/dev/null || true
        fi
    fi

    # Collect and write metrics
    collect_metrics

    # Log to syslog if available
    if command -v logger &>/dev/null; then
        logger -t nftban-exporter "Metrics exported successfully to $OUTPUT_FILE"
    fi

    exit 0
}

# Run main function
main "$@"

# =============================================================================
# LICENSE
# =============================================================================
# Mozilla Public License 2.0 (MPL-2.0)
# Copyright © 2024–2026 NFTBAN Project / Antonios Voulvoulis
# Contact: contact@nftban.com | Website: https://nftban.com
#
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at https://mozilla.org/MPL/2.0/.
#
# Full license: https://github.com/itcmsgr/nftban/blob/main/LICENSE
# =============================================================================
