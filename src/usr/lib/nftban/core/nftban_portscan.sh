#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.25 - Port Scan Detection Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Detects and blocks port scanning activity
#
# meta:name=nftban_portscan
# meta:type=core
# meta:header=Port Scan Detection
# meta:version=0.32.24
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Detects IP addresses accessing multiple ports and auto-bans scanners
# meta:input=Configuration from /etc/nftban/conf.d/portscan.conf
# meta:output=nftables logging rules and ban actions
#
# **Inventory & Requirements**
# meta:depends=bash>=4.0,nftables>=0.9.0,nftban_output.sh
#
# meta:created_date=2025-11-05
# meta:migrated_from=v0.9.5:lib/nftban_portscan_module.sh
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# MODULE GUARD
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_PORTSCAN_LOADED:-}" ]] && return 0
readonly NFTBAN_PORTSCAN_LOADED=1

# =============================================================================
# MODULE METADATA
# =============================================================================

readonly MODULE_NAME="nftban_portscan"
readonly MODULE_VERSION="0.31.0"
readonly MODULE_TYPE="core"
readonly MODULE_DESCRIPTION="Port Scan Detection Module"

# =============================================================================
# FHS COMPLIANT PATHS
# =============================================================================

# Configuration (loaded from conf.d/portscan.conf via main CLI)
readonly NFTBAN_PORTSCAN_DATA_DIR="${PORTSCAN_DATA_DIR:-/var/lib/nftban/portscan}"
readonly NFTBAN_PORTSCAN_CACHE_DIR="${PORTSCAN_CACHE_DIR:-/var/cache/nftban/portscan}"
readonly NFTBAN_PORTSCAN_LOG_FILE="${PORTSCAN_LOG_FILE:-/var/log/nftban/portscan.log}"
readonly NFTBAN_PORTSCAN_DB_FILE="${PORTSCAN_DB_FILE:-/var/lib/nftban/portscan/tracker.db}"
readonly NFTBAN_PORTSCAN_STATS_FILE="${PORTSCAN_STATS_FILE:-/var/lib/nftban/portscan/stats.json}"
readonly NFTBAN_PORTSCAN_WHITELIST_FILE="${PORTSCAN_WHITELIST_FILE:-/etc/nftban/portscan_whitelist.conf}"

# =============================================================================
# NFTABLES CONFIGURATION
# =============================================================================

readonly NFTBAN_NFT_TABLE="${NFTBAN_NFT_TABLE:-nftban_main}"
readonly NFTBAN_NFT_FAMILY="${NFTBAN_NFT_FAMILY:-inet}"
readonly NFTBAN_NFT_PORTSCAN_CHAIN="portscan_detection"
readonly NFTBAN_NFT_LOG_PREFIX="nftban: portscan: "

# Configuration cache
declare -A NFTBAN_PORTSCAN_CONFIG_CACHE

# In-memory tracking (associative arrays)
declare -A NFTBAN_PORTSCAN_IP_PORTS      # IP -> "port1,port2,port3,..."
declare -A NFTBAN_PORTSCAN_IP_FIRST_SEEN # IP -> timestamp
declare -A NFTBAN_PORTSCAN_IP_COUNT      # IP -> count of distinct ports

# =============================================================================
# BANNER FUNCTION
# =============================================================================

nftban_portscan_banner() {
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════╗
║  🔍 Port Scan Detection                                  ║
║  nftban — Simplifying Linux Firewall Management         ║
╚══════════════════════════════════════════════════════════╝
BANNER
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Load port scan configuration value
nftban_portscan_load_config() {
    local key="$1"
    local default="${2:-}"

    # Check cache first
    set +u
    if [[ -n "${NFTBAN_PORTSCAN_CONFIG_CACHE[$key]:-}" ]]; then
        local cached_value="${NFTBAN_PORTSCAN_CONFIG_CACHE[$key]}"
        set -u
        echo "$cached_value"
        return 0
    fi
    set -u

    # Try to get from environment (already sourced by main CLI)
    local value
    if [[ -n "${!key:-}" ]]; then
        value="${!key}"
    else
        value="$default"
    fi

    # Cache the value
    set +u
    NFTBAN_PORTSCAN_CONFIG_CACHE[$key]="$value"
    set -u

    echo "$value"
}

# Log to port scan log file
nftban_portscan_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    # Create log directory if it doesn't exist (only if we have permissions)
    mkdir -p "$(dirname "$NFTBAN_PORTSCAN_LOG_FILE")" 2>/dev/null || true

    # FHS-compliant: Ensure log file has correct ownership for auditors
    # Fix: portscan.log was owned by root:root, blocking nftban-auditors access
    if [[ ! -f "$NFTBAN_PORTSCAN_LOG_FILE" ]]; then
        touch "$NFTBAN_PORTSCAN_LOG_FILE" 2>/dev/null || true
        # Prefer nftban-auditors group for audit access, fallback to nftban
        if getent group nftban-auditors >/dev/null 2>&1; then
            chown nftban:nftban-auditors "$NFTBAN_PORTSCAN_LOG_FILE" 2>/dev/null || chown nftban:nftban "$NFTBAN_PORTSCAN_LOG_FILE" 2>/dev/null || true
        else
            chown nftban:nftban "$NFTBAN_PORTSCAN_LOG_FILE" 2>/dev/null || true
        fi
        chmod 640 "$NFTBAN_PORTSCAN_LOG_FILE" 2>/dev/null || true
    fi

    # Write to portscan log
    echo "[${timestamp}] [${level}] ${message}" >> "$NFTBAN_PORTSCAN_LOG_FILE" 2>/dev/null || true
}

# Check if port scan detection is globally enabled
nftban_portscan_is_enabled() {
    local enabled
    enabled=$(nftban_portscan_load_config "PORTSCAN_ENABLED" "true")
    [[ "${enabled:-true}" == "true" ]]
}

# Check if IP is whitelisted for port scan detection
nftban_portscan_is_whitelisted() {
    local ip="$1"

    # Check port scan specific whitelist
    if [[ -f "$NFTBAN_PORTSCAN_WHITELIST_FILE" ]]; then
        if grep -q "^${ip}\b" "$NFTBAN_PORTSCAN_WHITELIST_FILE" 2>/dev/null; then
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
    # Create directories if they don't exist (only if we have permissions)
    mkdir -p "$NFTBAN_PORTSCAN_DATA_DIR" 2>/dev/null || true
    mkdir -p "$NFTBAN_PORTSCAN_CACHE_DIR" 2>/dev/null || true

    # Clear old tracking data (older than time window)
    local retention
    retention=$(nftban_portscan_load_config "PORTSCAN_DB_RETENTION" "86400")
    find "$NFTBAN_PORTSCAN_CACHE_DIR" -type f -mmin "+$(( retention / 60 ))" -delete 2>/dev/null || true
}

# Record port access for an IP
nftban_portscan_record_access() {
    local ip="$1"
    local port="$2"
    local current_time
    current_time=$(date +%s)

    # Initialize if first time seeing this IP
    set +u
    if [[ -z "${NFTBAN_PORTSCAN_IP_FIRST_SEEN[$ip]:-}" ]]; then
        NFTBAN_PORTSCAN_IP_FIRST_SEEN[$ip]=$current_time
        NFTBAN_PORTSCAN_IP_PORTS[$ip]=""
        NFTBAN_PORTSCAN_IP_COUNT[$ip]=0
    fi

    # Check if port is already recorded for this IP
    local existing_ports="${NFTBAN_PORTSCAN_IP_PORTS[$ip]}"
    set -u

    if [[ ! "$existing_ports" =~ (^|,)${port}(,|$) ]]; then
        # New port for this IP
        if [[ -z "$existing_ports" ]]; then
            NFTBAN_PORTSCAN_IP_PORTS[$ip]="$port"
        else
            NFTBAN_PORTSCAN_IP_PORTS[$ip]="${existing_ports},${port}"
        fi
        NFTBAN_PORTSCAN_IP_COUNT[$ip]=$((${NFTBAN_PORTSCAN_IP_COUNT[$ip]:-0} + 1))
    fi
}

# Check if IP should be flagged as scanner
nftban_portscan_check_ip() {
    local ip="$1"
    local current_time
    current_time=$(date +%s)

    # Get configuration
    local time_window threshold
    time_window=$(nftban_portscan_load_config "PORTSCAN_TIME_WINDOW" "300")
    threshold=$(nftban_portscan_load_config "PORTSCAN_THRESHOLD" "10")

    # Check if IP has tracking data
    set +u
    local first_seen="${NFTBAN_PORTSCAN_IP_FIRST_SEEN[$ip]:-0}"
    local port_count="${NFTBAN_PORTSCAN_IP_COUNT[$ip]:-0}"
    set -u

    if [[ "$first_seen" == "0" ]]; then
        return 1  # No tracking data
    fi

    # Check if within time window
    local elapsed=$((current_time - first_seen))
    if [[ "$elapsed" -gt "$time_window" ]]; then
        # Reset tracking for this IP (outside time window)
        unset 'NFTBAN_PORTSCAN_IP_FIRST_SEEN[$ip]'
        unset 'NFTBAN_PORTSCAN_IP_PORTS[$ip]'
        unset 'NFTBAN_PORTSCAN_IP_COUNT[$ip]'
        return 1
    fi

    # Check if threshold exceeded
    if [[ "$port_count" -ge "$threshold" ]]; then
        return 0  # Port scanner detected!
    fi

    return 1
}

# Handle detected port scanner
nftban_portscan_handle_detected_scanner() {
    local ip="$1"

    # Check whitelist
    if nftban_portscan_is_whitelisted "$ip"; then
        nftban_portscan_log "INFO" "Scanner detected but whitelisted: $ip"
        return 0
    fi

    set +u
    local port_count="${NFTBAN_PORTSCAN_IP_COUNT[$ip]:-0}"
    local ports="${NFTBAN_PORTSCAN_IP_PORTS[$ip]:-}"
    set -u

    nftban_portscan_log "WARNING" "Port scanner detected: $ip (accessed $port_count ports: ${ports:0:100})"

    # Check if auto-ban is enabled
    local auto_ban
    auto_ban=$(nftban_portscan_load_config "PORTSCAN_AUTO_BAN" "true")

    if [[ "$auto_ban" == "true" ]]; then
        local ban_type ban_time
        ban_type=$(nftban_portscan_load_config "PORTSCAN_BAN_TYPE" "temporary")
        ban_time=$(nftban_portscan_load_config "PORTSCAN_BAN_TIME" "3600")

        nftban_portscan_log "INFO" "Auto-banning scanner: $ip (type: $ban_type, time: ${ban_time}s)"

        # Ban the IP using nftban ban command
        if command -v nftban >/dev/null 2>&1; then
            if [[ "$ban_type" == "permanent" ]]; then
                nftban ban "$ip" --reason "Port scan detected" 2>/dev/null || \
                    nftban_portscan_log "ERROR" "Failed to ban $ip"
            else
                nftban ban "$ip" --temp --timeout "$ban_time" --reason "Port scan detected" 2>/dev/null || \
                    nftban_portscan_log "ERROR" "Failed to ban $ip"
            fi
        else
            nftban_portscan_log "WARNING" "nftban command not found, cannot ban $ip"
        fi

        echo "  🚫 Auto-banned: $ip (accessed $port_count ports)"
    else
        nftban_portscan_log "INFO" "Auto-ban disabled, only logging for $ip"
        echo "  ⚠️  Detected (not banned): $ip (accessed $port_count ports)"
    fi

    # Send alert if enabled
    local email_alerts
    email_alerts=$(nftban_portscan_load_config "PORTSCAN_EMAIL_ALERTS" "true")
    if [[ "$email_alerts" == "true" ]]; then
        nftban_portscan_log "INFO" "Email alert would be sent for $ip"
        # Email functionality can be integrated later
    fi

    return 0
}

# =============================================================================
# NFTABLES INTEGRATION
# =============================================================================

# Setup nftables logging for port scan detection
nftban_portscan_setup_nftables_logging() {
    nftban_portscan_log "INFO" "Setting up nftables logging for port scan detection"

    local monitor_ports
    monitor_ports=$(nftban_portscan_load_config "PORTSCAN_MONITOR_PORTS" "closed")

    # Create chain if it doesn't exist
    if ! nft list chain $NFTBAN_NFT_FAMILY $NFTBAN_NFT_TABLE $NFTBAN_NFT_PORTSCAN_CHAIN &>/dev/null; then
        nft add chain $NFTBAN_NFT_FAMILY $NFTBAN_NFT_TABLE $NFTBAN_NFT_PORTSCAN_CHAIN \
            '{ type filter hook input priority -1; policy accept; }' 2>/dev/null || \
        nft add chain $NFTBAN_NFT_FAMILY $NFTBAN_NFT_TABLE $NFTBAN_NFT_PORTSCAN_CHAIN 2>/dev/null || true
    fi

    # Flush existing rules
    nft flush chain $NFTBAN_NFT_FAMILY $NFTBAN_NFT_TABLE $NFTBAN_NFT_PORTSCAN_CHAIN 2>/dev/null || true

    # Add logging rules based on monitor mode
    case "$monitor_ports" in
        all)
            # Log all new connections
            nft add rule $NFTBAN_NFT_FAMILY $NFTBAN_NFT_TABLE $NFTBAN_NFT_PORTSCAN_CHAIN \
                ct state new \
                limit rate 100/second burst 200 packets \
                log prefix "\"$NFTBAN_NFT_LOG_PREFIX\"" \
                counter
            ;;
        closed)
            # Log connections to ports not in allow list (simplified: log rejected)
            nft add rule $NFTBAN_NFT_FAMILY $NFTBAN_NFT_TABLE $NFTBAN_NFT_PORTSCAN_CHAIN \
                tcp flags syn \
                ct state new \
                limit rate 100/second burst 200 packets \
                log prefix "\"$NFTBAN_NFT_LOG_PREFIX\"" \
                counter
            ;;
        custom)
            local custom_ports
            custom_ports=$(nftban_portscan_load_config "PORTSCAN_CUSTOM_PORTS" "")
            if [[ -n "$custom_ports" ]]; then
                nft add rule $NFTBAN_NFT_FAMILY $NFTBAN_NFT_TABLE $NFTBAN_NFT_PORTSCAN_CHAIN \
                    tcp dport "{ $custom_ports }" \
                    ct state new \
                    limit rate 100/second burst 200 packets \
                    log prefix "\"$NFTBAN_NFT_LOG_PREFIX\"" \
                    counter
            fi
            ;;
    esac

    nftban_portscan_log "INFO" "nftables logging configured for mode: $monitor_ports"
    echo "  ✅ nftables logging configured (mode: $monitor_ports)"

    return 0
}

# Remove nftables logging for port scan detection
nftban_portscan_remove_nftables_logging() {
    nftban_portscan_log "INFO" "Removing nftables logging for port scan detection"

    # Flush chain
    if nft list chain $NFTBAN_NFT_FAMILY $NFTBAN_NFT_TABLE $NFTBAN_NFT_PORTSCAN_CHAIN &>/dev/null; then
        nft flush chain $NFTBAN_NFT_FAMILY $NFTBAN_NFT_TABLE $NFTBAN_NFT_PORTSCAN_CHAIN 2>/dev/null || true
    fi

    nftban_portscan_log "INFO" "nftables logging removed"

    return 0
}

# =============================================================================
# LOG PARSING & DETECTION
# =============================================================================

# Parse nftables logs for port scan detection
nftban_portscan_parse_logs() {
    local log_file="${1:-/var/log/kern.log}"

    if [[ ! -f "$log_file" ]]; then
        return 0
    fi

    # Parse recent log entries (last 5 minutes)
    local time_window
    time_window=$(nftban_portscan_load_config "PORTSCAN_TIME_WINDOW" "300")
    local since_time=$(($(date +%s) - time_window))

    # Look for nftables log entries with our prefix
    grep "$NFTBAN_NFT_LOG_PREFIX" "$log_file" 2>/dev/null | tail -n 1000 | while IFS= read -r line; do
        # Extract IP and port from log line
        # Example: nftban: portscan: IN=eth0 SRC=1.2.3.4 DST=5.6.7.8 PROTO=TCP SPT=12345 DPT=80
        if [[ "$line" =~ SRC=([0-9.]+|[0-9a-f:]+).*DPT=([0-9]+) ]]; then
            local src_ip="${BASH_REMATCH[1]}"
            local dst_port="${BASH_REMATCH[2]}"

            # Skip whitelisted IPs
            if nftban_portscan_is_whitelisted "$src_ip"; then
                continue
            fi

            # Record access
            nftban_portscan_record_access "$src_ip" "$dst_port"

            # Check if IP should be flagged
            if nftban_portscan_check_ip "$src_ip"; then
                nftban_portscan_handle_detected_scanner "$src_ip"
            fi
        fi
    done

    return 0
}

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

# Enable port scan detection
nftban_portscan_enable() {
    nftban_portscan_banner
    echo ""
    echo "⏳ Enabling port scan detection..."
    echo ""

    # Check if globally enabled
    if ! nftban_portscan_is_enabled; then
        echo "❌ Port scan detection is globally disabled in configuration"
        echo "   Set PORTSCAN_ENABLED=\"true\" to enable"
        return 1
    fi

    # Initialize tracking
    nftban_portscan_init_tracking

    # Setup nftables logging
    nftban_portscan_setup_nftables_logging

    # Show configuration
    local threshold time_window auto_ban
    threshold=$(nftban_portscan_load_config "PORTSCAN_THRESHOLD" "10")
    time_window=$(nftban_portscan_load_config "PORTSCAN_TIME_WINDOW" "300")
    auto_ban=$(nftban_portscan_load_config "PORTSCAN_AUTO_BAN" "true")

    echo ""
    echo "Configuration:"
    echo "  Threshold: $threshold ports in $time_window seconds"
    echo "  Auto-ban: $auto_ban"

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ Port Scan Detection ENABLED                          ║"
    echo "╚══════════════════════════════════════════════════════════╝"

    nftban_portscan_log "INFO" "Port scan detection enabled"

    return 0
}

# Disable port scan detection
nftban_portscan_disable() {
    nftban_portscan_banner
    echo ""
    echo "⏳ Disabling port scan detection..."
    echo ""

    # Remove nftables logging
    nftban_portscan_remove_nftables_logging

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ Port Scan Detection DISABLED                         ║"
    echo "╚══════════════════════════════════════════════════════════╝"

    nftban_portscan_log "INFO" "Port scan detection disabled"

    return 0
}

# Show port scan detection status
nftban_portscan_status() {
    nftban_portscan_banner
    echo ""
    echo "Global Configuration:"
    echo "  Master Switch: $(nftban_portscan_is_enabled && echo "✅ ENABLED" || echo "❌ DISABLED")"
    echo "  Logging: $(nftban_portscan_load_config "PORTSCAN_LOGGING" "true")"
    echo "  Email Alerts: $(nftban_portscan_load_config "PORTSCAN_EMAIL_ALERTS" "true")"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📊 Detection Parameters"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local threshold time_window diversity monitor_ports
    threshold=$(nftban_portscan_load_config "PORTSCAN_THRESHOLD" "10")
    time_window=$(nftban_portscan_load_config "PORTSCAN_TIME_WINDOW" "300")
    diversity=$(nftban_portscan_load_config "PORTSCAN_DIVERSITY" "true")
    monitor_ports=$(nftban_portscan_load_config "PORTSCAN_MONITOR_PORTS" "closed")

    echo "  Time Window: $time_window seconds"
    echo "  Threshold: $threshold distinct ports"
    echo "  Diversity Check: $diversity"
    echo "  Monitor Ports: $monitor_ports"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📊 Auto-Ban Settings"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local auto_ban ban_type ban_time
    auto_ban=$(nftban_portscan_load_config "PORTSCAN_AUTO_BAN" "true")
    ban_type=$(nftban_portscan_load_config "PORTSCAN_BAN_TYPE" "temporary")
    ban_time=$(nftban_portscan_load_config "PORTSCAN_BAN_TIME" "3600")

    echo "  Auto-Ban: $auto_ban"
    echo "  Ban Type: $ban_type"
    if [[ "$ban_type" == "temporary" ]]; then
        echo "  Ban Time: $ban_time seconds ($(($ban_time / 60)) minutes)"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📊 Active Rules"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if nft list chain $NFTBAN_NFT_FAMILY $NFTBAN_NFT_TABLE $NFTBAN_NFT_PORTSCAN_CHAIN &>/dev/null; then
        nft list chain $NFTBAN_NFT_FAMILY $NFTBAN_NFT_TABLE $NFTBAN_NFT_PORTSCAN_CHAIN | grep -v "^table\|^chain" | sed 's/^/  /'
    else
        echo "  (no active rules)"
    fi

    echo ""
    echo "📁 Log File: $NFTBAN_PORTSCAN_LOG_FILE"
    echo ""

    return 0
}

# Run port scan check (parse logs and detect)
nftban_portscan_check() {
    local log_file="${1:-/var/log/kern.log}"

    nftban_portscan_init_tracking
    nftban_portscan_parse_logs "$log_file"

    return 0
}

# =============================================================================
# MODULE INITIALIZATION
# =============================================================================

nftban_portscan_init() {
    # Create module-specific directories (parent directories handled by FHS spec)
    # Only create if running as root or nftban user, otherwise let health check handle it
    if [[ $EUID -eq 0 ]] || [[ $(id -un) == "nftban" ]]; then
        mkdir -p "$NFTBAN_PORTSCAN_DATA_DIR" 2>/dev/null || true
        mkdir -p "$NFTBAN_PORTSCAN_CACHE_DIR" 2>/dev/null || true
        mkdir -p "$(dirname "$NFTBAN_PORTSCAN_LOG_FILE")" 2>/dev/null || true

        # Set correct ownership if running as root
        if [[ $EUID -eq 0 ]] && id -u nftban >/dev/null 2>&1; then
            chown nftban:nftban "$NFTBAN_PORTSCAN_DATA_DIR" 2>/dev/null || true
            chown nftban:nftban "$NFTBAN_PORTSCAN_CACHE_DIR" 2>/dev/null || true
        fi
    fi

    # Touch files and set proper permissions
    touch "$NFTBAN_PORTSCAN_LOG_FILE" 2>/dev/null || true
    touch "$NFTBAN_PORTSCAN_WHITELIST_FILE" 2>/dev/null || true

    # Fix permissions if file was created as root
    if [[ -f "$NFTBAN_PORTSCAN_WHITELIST_FILE" ]]; then
        chmod 644 "$NFTBAN_PORTSCAN_WHITELIST_FILE" 2>/dev/null || true
        if [[ $EUID -eq 0 ]] && id -u nftban >/dev/null 2>&1; then
            chown nftban:nftban "$NFTBAN_PORTSCAN_WHITELIST_FILE" 2>/dev/null || true
        fi
    fi

    nftban_portscan_log "DEBUG" "Port scan detection module initialized (v$MODULE_VERSION)"
}

# Auto-initialize on module load
nftban_portscan_init

# =============================================================================
# EXPORT FUNCTIONS FOR CLI HANDLER
# =============================================================================
export -f nftban_portscan_banner
export -f nftban_portscan_load_config
export -f nftban_portscan_log
export -f nftban_portscan_is_enabled
export -f nftban_portscan_is_whitelisted
export -f nftban_portscan_init_tracking
export -f nftban_portscan_record_access
export -f nftban_portscan_check_ip
export -f nftban_portscan_handle_detected_scanner
export -f nftban_portscan_setup_nftables_logging
export -f nftban_portscan_remove_nftables_logging
export -f nftban_portscan_parse_logs
export -f nftban_portscan_enable
export -f nftban_portscan_disable
export -f nftban_portscan_status
export -f nftban_portscan_check
export -f nftban_portscan_init

# =============================================================================
# END OF MODULE
# =============================================================================
