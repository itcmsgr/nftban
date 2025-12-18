#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Unified Prometheus Metrics Exporter (ALL-IN-ONE)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Export comprehensive NFTBan metrics in Prometheus text exposition format
# Location: /usr/lib/nftban/exporters/nftban_prometheus_exporter.sh
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
# nftban — Simplifying Linux Firewall Management
#
# meta:name=nftban_prometheus_exporter
# meta:type=exporter
# meta:header=Unified Prometheus Metrics Exporter (Consolidated)
# meta:version=1.0.0
#
# **Description & Purpose**
# meta:description=Consolidated all-in-one metrics exporter: blocks, bandwidth, counters, health
# meta:input=NFTables sets/counters, /proc/net/*, nftban state, system stats
# meta:output=Prometheus text exposition format metrics to textfile collector
#
# **Metrics Collected**
# - Block metrics: total, permanent, temporary, by-country
# - Bandwidth metrics: RX/TX bytes/packets/Mbps per interface, protocol stats, connections
# - NFTables counters: packets/bytes per rule/action/reason
# - NFTables set sizes: element counts for all sets
# - Health metrics: component status (nftables, polkit, ssh)
# - Performance metrics: exporter duration, last update timestamp
#
# **Inventory & Requirements**
# meta:depends=bash,bc,date,awk,grep,nft,ss
# meta:requires_env=NFTBAN_LIB_DIR
#
# meta:created_date=2025-11-17
# meta:updated_date=2025-11-26
# meta:changelog=v0.7.3: Removed deprecated files, fixed permissions, cleaned up for v0.7 release
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

# =============================================================================
# CONFIGURATION
# =============================================================================

# Set library directory (before sourcing schema)
NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR}"

# Load NFT schema for table names
if [[ -f "${NFTBAN_LIB_DIR}/lib/nft_schema.sh" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nft_schema.sh"
else
    echo "ERROR: nft_schema.sh not found at ${NFTBAN_LIB_DIR}/lib/nft_schema.sh" >&2
    exit 1
fi

# Now make readonly after sourcing
readonly NFTBAN_LIB_DIR
readonly OUTPUT_FILE="${NFTBAN_METRICS_FILE:-/var/lib/node_exporter/textfile_collector/nftban.prom}"
readonly TEMP_FILE="${OUTPUT_FILE}.$$"
readonly NFTBAN_STATE_DIR="${NFTBAN_DATA_DIR}"
readonly NFTBAN_LOG_DIR="${NFTBAN_LOG_DIR}"
readonly TEMP_DIR="${NFTBAN_RUN_DIR}"
readonly STATE_FILE="${TEMP_DIR}/bandwidth_state.dat"
readonly PEAK_FILE="${TEMP_DIR}/bandwidth_peaks.dat"

# Bandwidth tracking configuration
readonly PEAK_WINDOW=300  # Peak tracking window (5 minutes)
readonly SKIP_INTERFACES="lo docker0 veth br-"  # Interfaces to skip

# Metric collection start time
readonly START_TIME=$(date +%s.%N)
readonly START_TIME_UNIX=$(date +%s)

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

    # Query nftables sets directly
    case "$block_type" in
        total)
            # Total = permanent + temporary + feeds + geoban (IPv4 + IPv6) - v0.6.2 fixed
            # v0.7.3 Unified Blacklist Architecture
            # All ban sources (permanent + temp + feeds + geoban) consolidated into single sets
            # NOTE: Cannot distinguish ban sources from nftables - all in blacklist_ipv4/ipv6
            local black_v4 black_v6

            # Count total IPs in unified blacklist sets
            black_v4=$(nft list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 2>/dev/null | { grep -oE '\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' || true; } | wc -l)
            black_v6=$(nft list set ${NFTBAN_TABLE_IPV6} blacklist_ipv6 2>/dev/null | { grep -oE '([0-9a-f]{0,4}:){2,7}[0-9a-f]{0,4}' || true; } | wc -l)

            # Set defaults
            black_v4=${black_v4:-0}
            black_v6=${black_v6:-0}

            # Return total count (unified blacklist)
            echo $((black_v4 + black_v6))
            ;;
        permanent|temporary|geoban)
            # v0.7.3: All ban types unified in blacklist_ipv4/ipv6
            # Cannot distinguish permanent/temporary/geoban from nftables alone
            # Return total blacklist count (metadata in config files/DB, not NFT)
            local count
            count=$(nft list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 2>/dev/null | { grep -o '[0-9.]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' || true; } | wc -l)
            echo "${count:-0}"
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
    # Get total blacklist count
    local total_ips
    total_ips=$(nft list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 2>/dev/null | { grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' || true; } | wc -l)
    total_ips=${total_ips:-0}

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
            *"WARN"*|*"WARNING"*) echo "1" ;;
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
        mkdir -p "$TEMP_DIR"
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

# Calculate bandwidth in Mbps from byte deltas
calculate_mbps() {
    local bytes_delta=$1
    local time_delta=$2

    if [[ $time_delta -eq 0 ]]; then
        echo "0"
        return
    fi

    # bytes/second -> bits/second -> megabits/second
    local mbps
    mbps=$(awk -v bd="$bytes_delta" -v td="$time_delta" 'BEGIN {printf "%.2f", (bd / td) * 8 / 1000000}')
    echo "$mbps"
}

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
get_nftables_set_sizes() {
    if ! command -v nft &>/dev/null; then
        return
    fi

    # List all sets in inet nftban table
    local sets
    sets=$(nft -j list table inet nftban 2>/dev/null | \
        jq -r '.nftables[] | select(.set != null) | .set.name' 2>/dev/null || \
        nft list table ${NFTBAN_TABLE_IPV4} 2>/dev/null | grep -oP 'set \K\w+' || echo "")

    if [[ -z "$sets" ]]; then
        # Fallback: try common set names (v0.6.2: fixed geoban set names)
        sets="whitelist_v4 whitelist_v6 blacklist_v4 blacklist_v6 temp_ban_v4 temp_ban_v6 feed_v4 feed_v6 geoban_blocked_v4 geoban_blocked_v6"
    fi

    # Count elements in each set
    local set_name
    for set_name in $sets; do
        # Check if set exists first
        if nft list set inet nftban "$set_name" &>/dev/null; then
            local count
            count=$(nft list set inet nftban "$set_name" 2>/dev/null | \
                grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}|([0-9a-fA-F]{1,4}:){7}[0-9a-fA-F]{1,4}' | \
                wc -l || echo "0")
            echo "${set_name} ${count:-0}"
        fi
    done
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
    local ipv4_drop_pkts=$(echo "$ipv4_data" | grep "default deny" | grep -oP 'counter packets \K\d+' || echo "0")
    local ipv4_drop_bytes=$(echo "$ipv4_data" | grep "default deny" | grep -oP 'bytes \K\d+' || echo "0")
    local ipv6_drop_pkts=$(echo "$ipv6_data" | grep "default deny" | grep -oP 'counter packets \K\d+' || echo "0")
    local ipv6_drop_bytes=$(echo "$ipv6_data" | grep "default deny" | grep -oP 'bytes \K\d+' || echo "0")

    local total_drop_pkts=$((ipv4_drop_pkts + ipv6_drop_pkts))
    local total_drop_bytes=$((ipv4_drop_bytes + ipv6_drop_bytes))
    echo "default_drop ${total_drop_pkts} ${total_drop_bytes}"

    # Blacklist counters (unified blacklist_ipv4 set in schema v0.7.3)
    local ipv4_bl_pkts=$(echo "$ipv4_data" | grep "@blacklist_ipv4" | grep -oP 'counter packets \K\d+' || echo "0")
    local ipv4_bl_bytes=$(echo "$ipv4_data" | grep "@blacklist_ipv4" | grep -oP 'bytes \K\d+' || echo "0")
    local ipv6_bl_pkts=$(echo "$ipv6_data" | grep "@blacklist_ipv6" | grep -oP 'counter packets \K\d+' || echo "0")
    local ipv6_bl_bytes=$(echo "$ipv6_data" | grep "@blacklist_ipv6" | grep -oP 'bytes \K\d+' || echo "0")

    local total_bl_pkts=$((ipv4_bl_pkts + ipv6_bl_pkts))
    local total_bl_bytes=$((ipv4_bl_bytes + ipv6_bl_bytes))
    echo "blacklist ${total_bl_pkts} ${total_bl_bytes}"

    # Whitelist accept counters
    local ipv4_wl_pkts=$(echo "$ipv4_data" | grep "@whitelist_ipv4" | grep -oP 'counter packets \K\d+' || echo "0")
    local ipv4_wl_bytes=$(echo "$ipv4_data" | grep "@whitelist_ipv4" | grep -oP 'bytes \K\d+' || echo "0")
    local ipv6_wl_pkts=$(echo "$ipv6_data" | grep "@whitelist_ipv6" | grep -oP 'counter packets \K\d+' || echo "0")
    local ipv6_wl_bytes=$(echo "$ipv6_data" | grep "@whitelist_ipv6" | grep -oP 'bytes \K\d+' || echo "0")

    local total_wl_pkts=$((ipv4_wl_pkts + ipv6_wl_pkts))
    local total_wl_bytes=$((ipv4_wl_bytes + ipv6_wl_bytes))
    echo "whitelist ${total_wl_pkts} ${total_wl_bytes}"

    # ICMP counters
    local ipv4_icmp_pkts=$(echo "$ipv4_data" | grep "ICMPv4" | grep -oP 'counter packets \K\d+' || echo "0")
    local ipv4_icmp_bytes=$(echo "$ipv4_data" | grep "ICMPv4" | grep -oP 'bytes \K\d+' || echo "0")
    local ipv6_icmp_pkts=$(echo "$ipv6_data" | grep "ICMPv6" | grep -oP 'counter packets \K\d+' || echo "0")
    local ipv6_icmp_bytes=$(echo "$ipv6_data" | grep "ICMPv6" | grep -oP 'bytes \K\d+' || echo "0")

    local total_icmp_pkts=$((ipv4_icmp_pkts + ipv6_icmp_pkts))
    local total_icmp_bytes=$((ipv4_icmp_bytes + ipv6_icmp_bytes))
    echo "icmp_accept ${total_icmp_pkts} ${total_icmp_bytes}"

    # Established connections
    local ipv4_est_pkts=$(echo "$ipv4_data" | grep "established" | grep -oP 'counter packets \K\d+' || echo "0")
    local ipv4_est_bytes=$(echo "$ipv4_data" | grep "established" | grep -oP 'bytes \K\d+' || echo "0")
    local ipv6_est_pkts=$(echo "$ipv6_data" | grep "established" | grep -oP 'counter packets \K\d+' || echo "0")
    local ipv6_est_bytes=$(echo "$ipv6_data" | grep "established" | grep -oP 'bytes \K\d+' || echo "0")

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
    mv "$TEMP_FILE" "$OUTPUT_FILE"

    # Set permissions (readable by node_exporter)
    chmod 644 "$OUTPUT_FILE"
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Ensure output directory exists
    local output_dir
    output_dir=$(dirname "$OUTPUT_FILE")

    if [[ ! -d "$output_dir" ]]; then
        mkdir -p "$output_dir"
        # Set ownership if running as root
        if [[ $EUID -eq 0 ]]; then
            chown -R nftban:nftban "$output_dir" 2>/dev/null || true
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
