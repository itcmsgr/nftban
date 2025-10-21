#!/usr/bin/env bash

# =============================================================================
# NFTBan Port Scan Detection Module
# Version: 0.9.2
# Location: lib/nftban_portscan_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Detects and blocks port scanning activity
# =============================================================================

# Strict mode for production-grade security
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_PORTSCAN_LOADED:-}" ]] && return 0
readonly NFTBAN_PORTSCAN_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_PORTSCAN_CONFIG="${NFTBAN_CONFIG_DIR}/portscan.conf"
readonly NFTBAN_PORTSCAN_CONFIG_LOCAL="${NFTBAN_CONFIG_DIR}/portscan.conf.local"
readonly NFTBAN_PORTSCAN_LOG="${NFTBAN_LOG_DIR}/portscan-detection.log"
readonly NFTBAN_PORTSCAN_DB="${NFTBAN_DATA_DIR}/portscan-tracker.db"
readonly NFTBAN_PORTSCAN_WHITELIST="${NFTBAN_CONFIG_DIR}/portscan_whitelist.conf"

# Tracking database (simple file-based)
readonly NFTBAN_PORTSCAN_TRACKING_DIR="${NFTBAN_DATA_DIR}/portscan-tracking"

# Configuration cache
declare -A NFTBAN_PORTSCAN_CONFIG_CACHE

# In-memory tracking (associative arrays)
declare -A NFTBAN_PORTSCAN_IP_PORTS      # IP -> "port1,port2,port3,..."
declare -A NFTBAN_PORTSCAN_IP_FIRST_SEEN # IP -> timestamp
declare -A NFTBAN_PORTSCAN_IP_COUNT      # IP -> count of distinct ports

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Load port scan configuration
nftban_portscan_load_config() {
    local key="$1"
    local default="${2:-}"

    # Check cache first
    if [[ -n "${NFTBAN_PORTSCAN_CONFIG_CACHE[$key]:-}" ]]; then
        echo "${NFTBAN_PORTSCAN_CONFIG_CACHE[$key]}"
        return 0
    fi

    local value="$default"

    # Load from .local file first (user overrides)
    if [[ -f "$NFTBAN_PORTSCAN_CONFIG_LOCAL" ]]; then
        value=$(grep "^${key}=" "$NFTBAN_PORTSCAN_CONFIG_LOCAL" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | head -n1)
    fi

    # Fallback to main config
    if [[ -z "$value" && -f "$NFTBAN_PORTSCAN_CONFIG" ]]; then
        value=$(grep "^${key}=" "$NFTBAN_PORTSCAN_CONFIG" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | head -n1)
    fi

    # Use default if still empty
    value="${value:-$default}"

    # Cache the value
    NFTBAN_PORTSCAN_CONFIG_CACHE[$key]="$value"

    echo "$value"
}

# Log to port scan log file
nftban_portscan_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    echo "[${timestamp}] [${level}] ${message}" >> "$NFTBAN_PORTSCAN_LOG"

    # Also log to main nftban log
    case "$level" in
        ERROR)   nftban_log_error "$message" ;;
        WARNING) nftban_log_warning "$message" ;;
        INFO)    nftban_log_info "$message" ;;
        DEBUG)   nftban_log_debug "$message" ;;
        *)       nftban_log_info "$message" ;;
    esac
}

# Check if port scan detection is globally enabled
nftban_portscan_is_enabled() {
    local enabled="${NFTBAN_PORTSCAN_ENABLED:-}"
    if [[ -z "$enabled" ]]; then
        enabled=$(nftban_portscan_load_config "PORTSCAN_ENABLED" "1")
    fi
    [[ "$enabled" == "1" ]]
}

# Check if IP is whitelisted for port scan detection
nftban_portscan_is_whitelisted() {
    local ip="$1"

    # Check main whitelist first
    if command -v nftban_whitelist_check_ip >/dev/null 2>&1; then
        if nftban_whitelist_check_ip "$ip" 2>/dev/null; then
            return 0
        fi
    fi

    # Check port scan specific whitelist
    if [[ -f "$NFTBAN_PORTSCAN_WHITELIST" ]]; then
        if grep -q "^${ip}\b" "$NFTBAN_PORTSCAN_WHITELIST" 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# =============================================================================
# TRACKING FUNCTIONS
# =============================================================================

# Initialize port scan tracking
nftban_portscan_init_tracking() {
    mkdir -p "$NFTBAN_PORTSCAN_TRACKING_DIR"

    # Clear old tracking data
    find "$NFTBAN_PORTSCAN_TRACKING_DIR" -type f -mmin +10 -delete 2>/dev/null || true
}

# Record port access for an IP
nftban_portscan_record_access() {
    local ip="$1"
    local port="$2"
    local current_time
    current_time=$(date +%s)

    # Initialize if first time seeing this IP
    if [[ -z "${NFTBAN_PORTSCAN_IP_FIRST_SEEN[$ip]:-}" ]]; then
        NFTBAN_PORTSCAN_IP_FIRST_SEEN[$ip]=$current_time
        NFTBAN_PORTSCAN_IP_PORTS[$ip]=""
        NFTBAN_PORTSCAN_IP_COUNT[$ip]=0
    fi

    # Check if port already recorded for this IP
    local existing_ports="${NFTBAN_PORTSCAN_IP_PORTS[$ip]}"
    if [[ ",$existing_ports," != *",$port,"* ]]; then
        # New port - add it
        if [[ -z "$existing_ports" ]]; then
            NFTBAN_PORTSCAN_IP_PORTS[$ip]="$port"
        else
            NFTBAN_PORTSCAN_IP_PORTS[$ip]="${existing_ports},${port}"
        fi

        # Increment count
        local count=${NFTBAN_PORTSCAN_IP_COUNT[$ip]}
        ((count++))
        NFTBAN_PORTSCAN_IP_COUNT[$ip]=$count

        nftban_portscan_log "DEBUG" "IP $ip accessed port $port (total: $count distinct ports)"
    fi
}

# Check if IP should be flagged as scanner
nftban_portscan_check_ip() {
    local ip="$1"
    local threshold
    local time_window
    local current_time

    threshold=$(nftban_portscan_load_config "PORTSCAN_THRESHOLD" "10")
    time_window=$(nftban_portscan_load_config "PORTSCAN_TIME_WINDOW" "300")
    current_time=$(date +%s)

    # Check if IP has tracking data
    if [[ -z "${NFTBAN_PORTSCAN_IP_COUNT[$ip]:-}" ]]; then
        return 1
    fi

    local count=${NFTBAN_PORTSCAN_IP_COUNT[$ip]}
    local first_seen=${NFTBAN_PORTSCAN_IP_FIRST_SEEN[$ip]}
    local elapsed=$((current_time - first_seen))

    # Check if within time window
    if [[ $elapsed -gt $time_window ]]; then
        # Reset tracking for this IP
        unset "NFTBAN_PORTSCAN_IP_COUNT[$ip]"
        unset "NFTBAN_PORTSCAN_IP_PORTS[$ip]"
        unset "NFTBAN_PORTSCAN_IP_FIRST_SEEN[$ip]"
        return 1
    fi

    # Check if threshold exceeded
    if [[ $count -ge $threshold ]]; then
        nftban_portscan_log "WARNING" "Port scan detected: IP $ip accessed $count ports in $elapsed seconds"
        return 0
    fi

    return 1
}

# Get port list for IP
nftban_portscan_get_ports() {
    local ip="$1"
    echo "${NFTBAN_PORTSCAN_IP_PORTS[$ip]:-}"
}

# =============================================================================
# DETECTION FUNCTIONS
# =============================================================================

# Parse nftables log for port scan activity
nftban_portscan_parse_nftables_log() {
    local log_file="/var/log/messages"
    local log_prefix
    log_prefix=$(nftban_portscan_load_config "PORTSCAN_NFT_LOG_PREFIX" "nftban: portscan: ")

    # Find kernel log file (varies by distro)
    if [[ -f "/var/log/kern.log" ]]; then
        log_file="/var/log/kern.log"
    elif [[ -f "/var/log/syslog" ]]; then
        log_file="/var/log/syslog"
    fi

    if [[ ! -f "$log_file" ]]; then
        nftban_portscan_log "WARNING" "Log file not found: $log_file"
        return 1
    fi

    # Parse last 1000 lines for port scan logs
    local lines
    lines=$(tail -n 1000 "$log_file" 2>/dev/null | grep "$log_prefix" || true)

    if [[ -z "$lines" ]]; then
        return 0
    fi

    # Extract IP and port from log lines
    # Expected format: ... nftban: portscan: SRC=1.2.3.4 ... DPT=80 ...
    while IFS= read -r line; do
        local src_ip port

        # Extract source IP
        src_ip=$(echo "$line" | grep -oP 'SRC=\K[0-9.]+')

        # Extract destination port
        port=$(echo "$line" | grep -oP 'DPT=\K[0-9]+')

        if [[ -n "$src_ip" && -n "$port" ]]; then
            # Skip if whitelisted
            if nftban_portscan_is_whitelisted "$src_ip"; then
                continue
            fi

            # Record the access
            nftban_portscan_record_access "$src_ip" "$port"

            # Check if should be flagged
            if nftban_portscan_check_ip "$src_ip"; then
                nftban_portscan_handle_detected_scanner "$src_ip"
            fi
        fi
    done <<< "$lines"
}

# Handle detected port scanner
nftban_portscan_handle_detected_scanner() {
    local ip="$1"
    local ports
    local count
    local auto_ban
    local ban_type
    local ban_time

    ports=$(nftban_portscan_get_ports "$ip")
    count=${NFTBAN_PORTSCAN_IP_COUNT[$ip]:-0}
    auto_ban=$(nftban_portscan_load_config "PORTSCAN_AUTO_BAN" "1")
    ban_type=$(nftban_portscan_load_config "PORTSCAN_BAN_TYPE" "temporary")
    ban_time=$(nftban_portscan_load_config "PORTSCAN_BAN_TIME" "3600")

    nftban_portscan_log "WARNING" "Port scanner detected: $ip (accessed $count ports: ${ports:0:100}...)"

    # Send email alert
    local email_alerts
    email_alerts=$(nftban_portscan_load_config "PORTSCAN_EMAIL_ALERTS" "1")
    if [[ "$email_alerts" == "1" ]]; then
        nftban_portscan_send_alert "$ip" "$count" "$ports"
    fi

    # Auto-ban if enabled
    if [[ "$auto_ban" == "1" ]]; then
        nftban_portscan_log "INFO" "Auto-banning port scanner: $ip"

        if [[ "$ban_type" == "permanent" ]]; then
            # Permanent ban
            if command -v nftban_blacklist_add_permanent >/dev/null 2>&1; then
                nftban_blacklist_add_permanent "$ip" "Port scan detected ($count ports)" 2>/dev/null || \
                    nftban_portscan_log "ERROR" "Failed to permanently ban $ip"
            fi
        else
            # Temporary ban
            if command -v nftban_blacklist_ban_ip >/dev/null 2>&1; then
                nftban_blacklist_ban_ip "$ip" "$ban_time" "Port scan detected ($count ports)" 2>/dev/null || \
                    nftban_portscan_log "ERROR" "Failed to temporarily ban $ip"
            fi
        fi
    fi

    # Clear tracking for this IP (already handled)
    unset "NFTBAN_PORTSCAN_IP_COUNT[$ip]"
    unset "NFTBAN_PORTSCAN_IP_PORTS[$ip]"
    unset "NFTBAN_PORTSCAN_IP_FIRST_SEEN[$ip]"
}

# Send port scan alert email
nftban_portscan_send_alert() {
    local ip="$1"
    local count="$2"
    local ports="$3"

    local recipient
    recipient=$(nftban_portscan_load_config "PORTSCAN_REPORT_EMAIL" "")

    if [[ -z "$recipient" ]]; then
        recipient=$(nftban_get_config "NFTBAN_F2B_RECIPIENT" "root@localhost")
    fi

    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    local subject="[nftban] Port Scan Detected from $ip on $(hostname -f)"

    local body="nftban PORT SCAN ALERT

WARNING: Port scanning activity detected!

Timestamp: $timestamp
Server: $(hostname -f)
Scanner IP: $ip
Ports Accessed: $count distinct ports
Time Window: Last $(nftban_portscan_load_config "PORTSCAN_TIME_WINDOW" "300") seconds

Ports Accessed:
${ports}

Action Taken:
$(if [[ "$(nftban_portscan_load_config "PORTSCAN_AUTO_BAN" "1")" == "1" ]]; then
    echo "IP has been automatically banned"
else
    echo "No automatic action (monitoring mode)"
fi)

Ban Type: $(nftban_portscan_load_config "PORTSCAN_BAN_TYPE" "temporary")
Ban Duration: $(nftban_portscan_load_config "PORTSCAN_BAN_TIME" "3600") seconds

Investigation Commands:
  nftban stats history $ip
  nftban portscan check $ip
  whois $ip

---
This is an automated alert from nftban port scan detection"

    # Send via core email function
    if command -v nftban_send_email >/dev/null 2>&1; then
        nftban_send_email "$recipient" "$subject" "$body" "high" 2>/dev/null || \
            nftban_portscan_log "ERROR" "Failed to send port scan alert email"
    fi
}

# =============================================================================
# COMMAND FUNCTIONS
# =============================================================================

# Enable port scan detection
nftban_portscan_enable() {
    if ! nftban_portscan_is_enabled; then
        nftban_portscan_log "WARNING" "Port scan detection is disabled in configuration"
        echo "Warning: Port scan detection is globally disabled in config"
        echo "To enable, set PORTSCAN_ENABLED=\"1\" in portscan.conf.local"
        return 1
    fi

    nftban_portscan_log "INFO" "Enabling port scan detection"

    # Initialize tracking
    nftban_portscan_init_tracking

    # Add nftables logging rules for closed ports
    nftban_portscan_setup_nftables_logging

    nftban_portscan_log "INFO" "Port scan detection enabled successfully"
    echo "✓ Port scan detection enabled"

    return 0
}

# Setup nftables logging for port scan detection
nftban_portscan_setup_nftables_logging() {
    local use_nft_log
    use_nft_log=$(nftban_portscan_load_config "PORTSCAN_USE_NFTABLES_LOG" "1")

    if [[ "$use_nft_log" != "1" ]]; then
        return 0
    fi

    # Add logging rule for dropped packets (port scans hit closed ports)
    # This should be added to the input chain with low priority
    # v0.9.0: Add to both IPv4 and IPv6 tables
    nft insert rule "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" input \
    nft insert rule # OLD input \
    nft insert rule "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" input \
    # (IPv6 version) 
        ct state new \
        limit rate 10/minute burst 5 packets \
        log prefix "\"nftban: portscan: \"" \
        2>/dev/null || \
        nftban_portscan_log "WARNING" "Failed to add nftables logging rule"

    nftban_portscan_log "INFO" "nftables logging rules added for port scan detection"
}

# Disable port scan detection
nftban_portscan_disable() {
    nftban_portscan_log "INFO" "Disabling port scan detection"

    # Remove nftables logging rules
    nftban_portscan_remove_nftables_logging

    nftban_portscan_log "INFO" "Port scan detection disabled"
    echo "✓ Port scan detection disabled"

    return 0
}

# Remove nftables logging rules
nftban_portscan_remove_nftables_logging() {
    # Remove all portscan logging rules
    while nft -a list chain ${NFTBAN_NFT_FAMILY_V4:-ip} ${NFTBAN_NFT_TABLE_V4:-nftban_v4} input 2>/dev/null | grep -q "nftban: portscan:"; do
        local handle
        handle=$(nft -a list chain ${NFTBAN_NFT_FAMILY_V4:-ip} ${NFTBAN_NFT_TABLE_V4:-nftban_v4} input 2>/dev/null | grep "nftban: portscan:" | head -n1 | grep -oP 'handle \K[0-9]+')
        if [[ -n "$handle" ]]; then
            nft delete rule ${NFTBAN_NFT_FAMILY_V4:-ip} ${NFTBAN_NFT_TABLE_V4:-nftban_v4} input handle "$handle" 2>/dev/null || break
        else
            break
        fi
    done
}

# Run port scan detection check
nftban_portscan_check() {
    if ! nftban_portscan_is_enabled; then
        echo "Port scan detection is disabled"
        return 1
    fi

    nftban_portscan_log "INFO" "Running port scan detection check"

    # Parse logs
    nftban_portscan_parse_nftables_log

    nftban_portscan_log "INFO" "Port scan check completed"

    return 0
}

# Show port scan detection status
nftban_portscan_status() {
    echo ""
    echo "======================================================="
    echo "  Port Scan Detection Status"
    echo "======================================================="
    echo ""

    local enabled
    enabled=$(nftban_portscan_load_config "PORTSCAN_ENABLED" "1")

    echo "Configuration:"
    echo "  Enabled: $enabled"

    if [[ "$enabled" == "1" ]]; then
        echo "  Threshold: $(nftban_portscan_load_config "PORTSCAN_THRESHOLD" "10") ports"
        echo "  Time Window: $(nftban_portscan_load_config "PORTSCAN_TIME_WINDOW" "300") seconds"
        echo "  Auto-Ban: $(nftban_portscan_load_config "PORTSCAN_AUTO_BAN" "1")"
        echo "  Ban Type: $(nftban_portscan_load_config "PORTSCAN_BAN_TYPE" "temporary")"
        if [[ "$(nftban_portscan_load_config "PORTSCAN_BAN_TYPE" "temporary")" == "temporary" ]]; then
            echo "  Ban Duration: $(nftban_portscan_load_config "PORTSCAN_BAN_TIME" "3600") seconds"
        fi
    fi

    echo ""
    echo "Tracking:"
    echo "  IPs Currently Tracked: ${#NFTBAN_PORTSCAN_IP_COUNT[@]}"

    if [[ ${#NFTBAN_PORTSCAN_IP_COUNT[@]} -gt 0 ]]; then
        echo ""
        echo "  Top Active IPs:"
        for ip in "${!NFTBAN_PORTSCAN_IP_COUNT[@]}"; do
            local count=${NFTBAN_PORTSCAN_IP_COUNT[$ip]}
            echo "    $ip: $count ports"
        done | sort -t: -k2 -rn | head -10
    fi

    echo ""
    echo "Recent Detections:"
    if [[ -f "$NFTBAN_PORTSCAN_LOG" ]]; then
        grep "Port scanner detected" "$NFTBAN_PORTSCAN_LOG" 2>/dev/null | tail -5 | sed 's/^/  /' || echo "  (none)"
    else
        echo "  (no log file)"
    fi

    echo ""
    echo "======================================================="
}

# Check specific IP for port scan activity
nftban_portscan_check_ip_manual() {
    local ip="$1"

    echo "Checking IP: $ip"
    echo ""

    if nftban_portscan_is_whitelisted "$ip"; then
        echo "Status: WHITELISTED (will not be detected)"
        return 0
    fi

    if [[ -n "${NFTBAN_PORTSCAN_IP_COUNT[$ip]:-}" ]]; then
        local count=${NFTBAN_PORTSCAN_IP_COUNT[$ip]}
        local ports=$(nftban_portscan_get_ports "$ip")
        local first_seen=${NFTBAN_PORTSCAN_IP_FIRST_SEEN[$ip]}
        local current_time
        current_time=$(date +%s)
        local elapsed=$((current_time - first_seen))

        echo "Status: BEING TRACKED"
        echo "Ports Accessed: $count"
        echo "Time Elapsed: $elapsed seconds"
        echo "Ports: $ports"
        echo ""

        local threshold
        threshold=$(nftban_portscan_load_config "PORTSCAN_THRESHOLD" "10")

        if [[ $count -ge $threshold ]]; then
            echo "⚠️  WARNING: Threshold exceeded! This IP will be flagged."
        else
            local remaining=$((threshold - count))
            echo "ℹ️  $remaining more ports until detection threshold"
        fi
    else
        echo "Status: NOT TRACKED"
        echo "No recent port access activity recorded for this IP"
    fi

    return 0
}

# Show statistics
nftban_portscan_stats() {
    echo ""
    echo "======================================================="
    echo "  Port Scan Detection Statistics"
    echo "======================================================="
    echo ""

    echo "Detection Summary:"
    if [[ -f "$NFTBAN_PORTSCAN_LOG" ]]; then
        local total_detections
        total_detections=$(grep -c "Port scanner detected" "$NFTBAN_PORTSCAN_LOG" 2>/dev/null || echo "0")
        echo "  Total Detections: $total_detections"

        local today_detections
        today_detections=$(grep "Port scanner detected" "$NFTBAN_PORTSCAN_LOG" 2>/dev/null | \
            grep "$(date +'%Y-%m-%d')" | wc -l)
        echo "  Today: $today_detections"
    else
        echo "  No log file found"
    fi

    echo ""
    echo "Current Tracking:"
    echo "  Active IPs: ${#NFTBAN_PORTSCAN_IP_COUNT[@]}"

    echo ""
    echo "Configuration:"
    echo "  Threshold: $(nftban_portscan_load_config "PORTSCAN_THRESHOLD" "10") ports"
    echo "  Time Window: $(nftban_portscan_load_config "PORTSCAN_TIME_WINDOW" "300")s"
    echo "  Auto-Ban: $(nftban_portscan_load_config "PORTSCAN_AUTO_BAN" "1")"

    echo ""
    echo "======================================================="
}

# =============================================================================
# MODULE INITIALIZATION
# =============================================================================

nftban_portscan_init() {
    # Create directories
    mkdir -p "$(dirname "$NFTBAN_PORTSCAN_LOG")"
    mkdir -p "$(dirname "$NFTBAN_PORTSCAN_DB")"
    mkdir -p "$NFTBAN_PORTSCAN_TRACKING_DIR"

    # Touch files
    touch "$NFTBAN_PORTSCAN_LOG"
    touch "$NFTBAN_PORTSCAN_WHITELIST"

    nftban_portscan_log "DEBUG" "Port scan detection module initialized"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_portscan_load_config
export -f nftban_portscan_log
export -f nftban_portscan_is_enabled
export -f nftban_portscan_is_whitelisted
export -f nftban_portscan_init_tracking
export -f nftban_portscan_record_access
export -f nftban_portscan_check_ip
export -f nftban_portscan_get_ports
export -f nftban_portscan_parse_nftables_log
export -f nftban_portscan_handle_detected_scanner
export -f nftban_portscan_send_alert
export -f nftban_portscan_enable
export -f nftban_portscan_setup_nftables_logging
export -f nftban_portscan_disable
export -f nftban_portscan_remove_nftables_logging
export -f nftban_portscan_check
export -f nftban_portscan_status
export -f nftban_portscan_check_ip_manual
export -f nftban_portscan_stats
export -f nftban_portscan_init

# Auto-initialize
nftban_portscan_init

nftban_log_debug "NFTBan Port Scan Detection Module loaded"
