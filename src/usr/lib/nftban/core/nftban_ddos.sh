#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.6 - DDoS Protection Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Comprehensive DDoS protection using nftables
#
# meta:name=nftban_ddos
# meta:type=core
# meta:header=DDoS Protection
# meta:version=0.32.6
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Implements SYN flood, connection limits, port flood, and ICMP protection
# meta:input=Configuration from /etc/nftban/conf.d/ddos.conf
# meta:output=nftables rules for DDoS protection
#
# **Inventory & Requirements**
# meta:depends=bash>=4.0,nftables>=0.9.0,nftban_output.sh
#
# meta:created_date=2025-11-05
# meta:migrated_from=v0.9.5:lib/nftban_ddos_module.sh
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# MODULE GUARD
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_DDOS_LOADED:-}" ]] && return 0
readonly NFTBAN_DDOS_LOADED=1

# =============================================================================
# MODULE METADATA
# =============================================================================

readonly MODULE_NAME="nftban_ddos"
readonly MODULE_VERSION="0.31.0"
readonly MODULE_TYPE="core"
readonly MODULE_DESCRIPTION="DDoS Protection Module"

# =============================================================================
# FHS COMPLIANT PATHS
# =============================================================================

# Configuration (loaded from conf.d/ddos.conf via main CLI)
# These paths are defined in the config file but we set defaults here
readonly NFTBAN_DDOS_DATA_DIR="${DDOS_DATA_DIR:-/var/lib/nftban/ddos}"
readonly NFTBAN_DDOS_CACHE_DIR="${DDOS_CACHE_DIR:-/var/cache/nftban/ddos}"
readonly NFTBAN_DDOS_LOG_FILE="${DDOS_LOG_FILE:-/var/log/nftban/ddos.log}"
readonly NFTBAN_DDOS_STATS_FILE="${DDOS_STATS_FILE:-/var/lib/nftban/ddos/stats.json}"

# =============================================================================
# NFTABLES CONFIGURATION
# =============================================================================

# nftables table and chain names
readonly NFTBAN_NFT_TABLE_V4="${NFTBAN_NFT_TABLE_V4:-nftban_v4}"
readonly NFTBAN_NFT_TABLE_V6="${NFTBAN_NFT_TABLE_V6:-nftban_v6}"

# DDoS protection chains
readonly NFTBAN_NFT_SYNFLOOD_CHAIN="synflood_protection"
readonly NFTBAN_NFT_CONNLIMIT_CHAIN="connlimit_protection"
readonly NFTBAN_NFT_PORTFLOOD_CHAIN="portflood_protection"
readonly NFTBAN_NFT_ICMP_CHAIN="icmp_protection"

# Configuration cache (for performance)
declare -A NFTBAN_DDOS_CONFIG_CACHE

# =============================================================================
# BANNER FUNCTION
# =============================================================================

nftban_ddos_banner() {
    cat <<'BANNER'
╔══════════════════════════════════════════════════════════╗
║  🛡️  DDoS Protection                                     ║
║  nftban — Simplifying Linux Firewall Management         ║
╚══════════════════════════════════════════════════════════╝
BANNER
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Helper: Get array of table specs for iteration
# Returns: Array of "family:table" pairs for both IPv4 and IPv6
# Usage: for table_info in $(nftban_ddos_get_tables); do ... done
nftban_ddos_get_tables() {
    echo "ip:$NFTBAN_NFT_TABLE_V4 ip6:$NFTBAN_NFT_TABLE_V6"
}

# Load DDoS configuration value
# Args:
#   $1 - Configuration key
#   $2 - Default value (optional)
# Returns: Configuration value (from cache, config, or default)
nftban_ddos_load_config() {
    local key="$1"
    local default="${2:-}"

    # Check cache first (temporarily disable nounset for array access with set -u)
    set +u
    if [[ -n "${NFTBAN_DDOS_CONFIG_CACHE[$key]:-}" ]]; then
        local cached_value="${NFTBAN_DDOS_CONFIG_CACHE[$key]}"
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

    # Cache the value (temporarily disable nounset for array access)
    set +u
    NFTBAN_DDOS_CONFIG_CACHE[$key]="$value"
    set -u

    echo "$value"
}

# Log to DDoS log file
# Args:
#   $1 - Log level (INFO, WARNING, ERROR, DEBUG)
#   $@ - Log message
nftban_ddos_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    # Create log directory if it doesn't exist
    mkdir -p "$(dirname "$NFTBAN_DDOS_LOG_FILE")"

    # Write to DDoS log
    echo "[${timestamp}] [${level}] ${message}" >> "$NFTBAN_DDOS_LOG_FILE"
}

# Check if DDoS protection is globally enabled
# Returns: 0 if enabled, 1 if disabled
nftban_ddos_is_enabled() {
    local enabled
    enabled=$(nftban_ddos_load_config "DDOS_PROTECTION_ENABLED" "true")
    [[ "${enabled:-true}" == "true" ]]
}

# Convert rate format to nftables format
# Args: $1 - Rate in format "X/time" (e.g., "100/second")
# Returns: Rate in nftables format
nftban_ddos_convert_rate() {
    local rate="$1"

    # Already in correct format
    if [[ "$rate" =~ ^[0-9]+/(second|minute|hour|day)$ ]]; then
        echo "$rate"
        return 0
    fi

    # Try to parse legacy formats
    if [[ "$rate" =~ ^([0-9]+)/s$ ]]; then
        echo "${BASH_REMATCH[1]}/second"
        return 0
    fi

    # Default
    echo "$rate"
}

# =============================================================================
# SYN FLOOD PROTECTION
# =============================================================================

# Enable SYN flood protection
# Protects against TCP SYN flood attacks by rate limiting SYN packets
# ⚠️  WARNING: Only enable during active attack (adds latency to all new connections)
nftban_ddos_synflood_enable() {
    if ! nftban_ddos_is_enabled; then
        nftban_ddos_log "WARNING" "DDoS protection is globally disabled"
        echo "⚠️  Warning: DDoS protection is globally disabled in config"
        return 1
    fi

    local rate burst log_enabled
    rate=$(nftban_ddos_load_config "DDOS_SYNFLOOD_RATE" "100/second")
    burst=$(nftban_ddos_load_config "DDOS_SYNFLOOD_BURST" "150")
    log_enabled=$(nftban_ddos_load_config "DDOS_SYNFLOOD_LOG" "true")

    rate=$(nftban_ddos_convert_rate "$rate")

    nftban_ddos_log "INFO" "Enabling SYN flood protection (rate: $rate, burst: $burst)"

    # Apply to both IPv4 and IPv6 tables
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        # Create chain if it doesn't exist
        if ! nft list chain $family $table $NFTBAN_NFT_SYNFLOOD_CHAIN &>/dev/null; then
            nft add chain $family $table $NFTBAN_NFT_SYNFLOOD_CHAIN \
                '{ type filter hook input priority -10; policy accept; }' 2>/dev/null || \
            nft add chain $family $table $NFTBAN_NFT_SYNFLOOD_CHAIN 2>/dev/null || true
        fi

        # Flush existing rules
        nft flush chain $family $table $NFTBAN_NFT_SYNFLOOD_CHAIN 2>/dev/null || true

        # Add rate limiting rule
        nft add rule $family $table $NFTBAN_NFT_SYNFLOOD_CHAIN \
            tcp flags syn \
            tcp dport != 0 \
            ct state new \
            limit rate $rate burst $burst packets \
            counter accept

        # Log and drop excess (if logging enabled)
        if [[ "$log_enabled" == "true" ]]; then
            nft add rule $family $table $NFTBAN_NFT_SYNFLOOD_CHAIN \
                tcp flags syn \
                limit rate 30/minute burst 5 packets \
                log prefix '"nftban: SYNFLOOD: "' \
                counter
        fi

        # Drop excess SYN packets
        nft add rule $family $table $NFTBAN_NFT_SYNFLOOD_CHAIN \
            tcp flags syn \
            counter drop
    done

    nftban_ddos_log "INFO" "SYN flood protection enabled successfully"
    echo "✅ SYN flood protection enabled (rate: $rate, burst: $burst)"

    return 0
}

# Disable SYN flood protection
nftban_ddos_synflood_disable() {
    nftban_ddos_log "INFO" "Disabling SYN flood protection"

    # Flush chain on both tables
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        if nft list chain $family $table $NFTBAN_NFT_SYNFLOOD_CHAIN &>/dev/null; then
            nft flush chain $family $table $NFTBAN_NFT_SYNFLOOD_CHAIN 2>/dev/null || true
        fi
    done

    nftban_ddos_log "INFO" "SYN flood protection disabled"
    echo "✅ SYN flood protection disabled"

    return 0
}

# Show SYN flood protection status
nftban_ddos_synflood_status() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📊 SYN Flood Protection Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local enabled
    enabled=$(nftban_ddos_load_config "DDOS_SYNFLOOD_ENABLED" "false")

    echo "Configuration:"
    if [[ "$enabled" == "true" ]]; then
        echo "  ✅ Enabled: true"
        local rate burst
        rate=$(nftban_ddos_load_config "DDOS_SYNFLOOD_RATE" "100/second")
        burst=$(nftban_ddos_load_config "DDOS_SYNFLOOD_BURST" "150")
        echo "  Rate Limit: $rate"
        echo "  Burst: $burst packets"
    else
        echo "  ❌ Enabled: false"
    fi

    echo ""
    echo "Active Rules (IPv4):"
    if nft list chain ip $NFTBAN_NFT_TABLE_V4 $NFTBAN_NFT_SYNFLOOD_CHAIN &>/dev/null; then
        nft list chain ip $NFTBAN_NFT_TABLE_V4 $NFTBAN_NFT_SYNFLOOD_CHAIN | grep -v "^table\|^chain" | sed 's/^/  /'
    else
        echo "  (no active rules)"
    fi

    echo ""
    echo "Active Rules (IPv6):"
    if nft list chain ip6 $NFTBAN_NFT_TABLE_V6 $NFTBAN_NFT_SYNFLOOD_CHAIN &>/dev/null; then
        nft list chain ip6 $NFTBAN_NFT_TABLE_V6 $NFTBAN_NFT_SYNFLOOD_CHAIN | grep -v "^table\|^chain" | sed 's/^/  /'
    else
        echo "  (no active rules)"
    fi

    return 0
}

# =============================================================================
# CONNECTION LIMIT PROTECTION
# =============================================================================

# Add connection limit rule for a specific port
# Args:
#   $1 - Port number
#   $2 - Connection limit
#   $3 - Protocol (tcp/udp, default: tcp)
nftban_ddos_connlimit_add_port() {
    local port="$1"
    local limit="$2"
    local protocol="${3:-tcp}"

    # Skip if limit is 0 (disabled)
    [[ "$limit" == "0" ]] && return 0

    local action log_enabled
    action=$(nftban_ddos_load_config "DDOS_CONNLIMIT_ACTION" "reject")
    log_enabled=$(nftban_ddos_load_config "DDOS_CONNLIMIT_LOG" "true")

    # Apply to both IPv4 and IPv6
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        # Add connection limit rule
        nft add rule $family $table $NFTBAN_NFT_CONNLIMIT_CHAIN \
            $protocol dport $port \
            ct count over $limit \
            counter $action

        # Add logging rule if enabled
        if [[ "$log_enabled" == "true" ]]; then
            nft add rule $family $table $NFTBAN_NFT_CONNLIMIT_CHAIN \
                $protocol dport $port \
                ct count over $limit \
                limit rate 10/minute burst 5 packets \
                log prefix "\"nftban: CONNLIMIT($port): \"" \
                counter
        fi
    done

    return 0
}

# Enable connection limit protection
nftban_ddos_connlimit_enable() {
    if ! nftban_ddos_is_enabled; then
        nftban_ddos_log "WARNING" "DDoS protection is globally disabled"
        echo "⚠️  Warning: DDoS protection is globally disabled in config"
        return 1
    fi

    nftban_ddos_log "INFO" "Enabling connection limit protection"

    # Apply to both IPv4 and IPv6 tables
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        # Create chain if it doesn't exist
        if ! nft list chain $family $table $NFTBAN_NFT_CONNLIMIT_CHAIN &>/dev/null; then
            nft add chain $family $table $NFTBAN_NFT_CONNLIMIT_CHAIN \
                '{ type filter hook input priority 0; policy accept; }' 2>/dev/null || \
            nft add chain $family $table $NFTBAN_NFT_CONNLIMIT_CHAIN 2>/dev/null || true
        fi

        # Flush existing rules
        nft flush chain $family $table $NFTBAN_NFT_CONNLIMIT_CHAIN 2>/dev/null || true
    done

    # Load per-service connection limits
    local ssh_limit http_limit https_limit ftp_limit smtp_limit pop3_limit imap_limit mysql_limit pgsql_limit

    ssh_limit=$(nftban_ddos_load_config "DDOS_CONNLIMIT_SSH" "5")
    http_limit=$(nftban_ddos_load_config "DDOS_CONNLIMIT_HTTP" "20")
    https_limit=$(nftban_ddos_load_config "DDOS_CONNLIMIT_HTTPS" "20")
    ftp_limit=$(nftban_ddos_load_config "DDOS_CONNLIMIT_FTP" "3")
    smtp_limit=$(nftban_ddos_load_config "DDOS_CONNLIMIT_SMTP" "5")
    pop3_limit=$(nftban_ddos_load_config "DDOS_CONNLIMIT_POP3" "5")
    imap_limit=$(nftban_ddos_load_config "DDOS_CONNLIMIT_IMAP" "5")
    mysql_limit=$(nftban_ddos_load_config "DDOS_CONNLIMIT_MYSQL" "10")
    pgsql_limit=$(nftban_ddos_load_config "DDOS_CONNLIMIT_POSTGRESQL" "10")

    # Add rules for each service (skip if limit is 0)
    [[ "$ssh_limit" != "0" ]] && nftban_ddos_connlimit_add_port 22 "$ssh_limit" tcp && \
        echo "  ✅ SSH: max $ssh_limit connections per IP"
    [[ "$http_limit" != "0" ]] && nftban_ddos_connlimit_add_port 80 "$http_limit" tcp && \
        echo "  ✅ HTTP: max $http_limit connections per IP"
    [[ "$https_limit" != "0" ]] && nftban_ddos_connlimit_add_port 443 "$https_limit" tcp && \
        echo "  ✅ HTTPS: max $https_limit connections per IP"
    [[ "$ftp_limit" != "0" ]] && nftban_ddos_connlimit_add_port 21 "$ftp_limit" tcp && \
        echo "  ✅ FTP: max $ftp_limit connections per IP"
    [[ "$smtp_limit" != "0" ]] && nftban_ddos_connlimit_add_port 25 "$smtp_limit" tcp && \
        echo "  ✅ SMTP: max $smtp_limit connections per IP"
    [[ "$pop3_limit" != "0" ]] && nftban_ddos_connlimit_add_port 110 "$pop3_limit" tcp && \
        echo "  ✅ POP3: max $pop3_limit connections per IP"
    [[ "$imap_limit" != "0" ]] && nftban_ddos_connlimit_add_port 143 "$imap_limit" tcp && \
        echo "  ✅ IMAP: max $imap_limit connections per IP"
    [[ "$mysql_limit" != "0" ]] && nftban_ddos_connlimit_add_port 3306 "$mysql_limit" tcp && \
        echo "  ✅ MySQL: max $mysql_limit connections per IP"
    [[ "$pgsql_limit" != "0" ]] && nftban_ddos_connlimit_add_port 5432 "$pgsql_limit" tcp && \
        echo "  ✅ PostgreSQL: max $pgsql_limit connections per IP"

    # Handle custom connection limits
    local custom_limits
    custom_limits=$(nftban_ddos_load_config "DDOS_CONNLIMIT_CUSTOM" "")
    if [[ -n "$custom_limits" ]]; then
        # Parse custom limits: "port;limit,port;limit,..."
        IFS=',' read -ra CUSTOM_ARRAY <<< "$custom_limits"
        for entry in "${CUSTOM_ARRAY[@]}"; do
            if [[ "$entry" =~ ^([0-9]+)\;([0-9]+)$ ]]; then
                local port="${BASH_REMATCH[1]}"
                local limit="${BASH_REMATCH[2]}"
                nftban_ddos_connlimit_add_port "$port" "$limit" tcp && \
                    echo "  ✅ Port $port: max $limit connections per IP"
            fi
        done
    fi

    nftban_ddos_log "INFO" "Connection limit protection enabled"
    echo ""
    echo "✅ Connection limit protection enabled"

    return 0
}

# Disable connection limit protection
nftban_ddos_connlimit_disable() {
    nftban_ddos_log "INFO" "Disabling connection limit protection"

    # Flush chain on both tables
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        if nft list chain $family $table $NFTBAN_NFT_CONNLIMIT_CHAIN &>/dev/null; then
            nft flush chain $family $table $NFTBAN_NFT_CONNLIMIT_CHAIN 2>/dev/null || true
        fi
    done

    nftban_ddos_log "INFO" "Connection limit protection disabled"
    echo "✅ Connection limit protection disabled"

    return 0
}

# Show connection limit protection status
nftban_ddos_connlimit_status() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📊 Connection Limit Protection Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local enabled
    enabled=$(nftban_ddos_load_config "DDOS_CONNLIMIT_ENABLED" "true")

    echo "Configuration:"
    if [[ "$enabled" == "true" ]]; then
        echo "  ✅ Enabled: true"

        # Show per-service limits
        echo ""
        echo "  Per-Service Limits:"
        local ssh http https ftp smtp pop3 imap mysql pgsql
        ssh=$(nftban_ddos_load_config "DDOS_CONNLIMIT_SSH" "5")
        http=$(nftban_ddos_load_config "DDOS_CONNLIMIT_HTTP" "20")
        https=$(nftban_ddos_load_config "DDOS_CONNLIMIT_HTTPS" "20")
        ftp=$(nftban_ddos_load_config "DDOS_CONNLIMIT_FTP" "3")
        smtp=$(nftban_ddos_load_config "DDOS_CONNLIMIT_SMTP" "5")
        pop3=$(nftban_ddos_load_config "DDOS_CONNLIMIT_POP3" "5")
        imap=$(nftban_ddos_load_config "DDOS_CONNLIMIT_IMAP" "5")
        mysql=$(nftban_ddos_load_config "DDOS_CONNLIMIT_MYSQL" "10")
        pgsql=$(nftban_ddos_load_config "DDOS_CONNLIMIT_POSTGRESQL" "10")

        echo "    SSH (22):        $ssh connections per IP"
        echo "    HTTP (80):       $http connections per IP"
        echo "    HTTPS (443):     $https connections per IP"
        echo "    FTP (21):        $ftp connections per IP"
        echo "    SMTP (25):       $smtp connections per IP"
        echo "    POP3 (110):      $pop3 connections per IP"
        echo "    IMAP (143):      $imap connections per IP"
        echo "    MySQL (3306):    $mysql connections per IP"
        echo "    PostgreSQL (5432): $pgsql connections per IP"
    else
        echo "  ❌ Enabled: false"
    fi

    echo ""
    echo "Active Rules (IPv4):"
    if nft list chain ip $NFTBAN_NFT_TABLE_V4 $NFTBAN_NFT_CONNLIMIT_CHAIN &>/dev/null; then
        nft list chain ip $NFTBAN_NFT_TABLE_V4 $NFTBAN_NFT_CONNLIMIT_CHAIN | grep -v "^table\|^chain" | sed 's/^/  /'
    else
        echo "  (no active rules)"
    fi

    return 0
}

# =============================================================================
# PORT FLOOD PROTECTION
# =============================================================================

# Add port flood rate limit rule
# Args:
#   $1 - Port number
#   $2 - Rate/time (e.g., "20/5" = 20 connections per 5 seconds)
#   $3 - Protocol (tcp/udp, default: tcp)
nftban_ddos_portflood_add_port() {
    local port="$1"
    local rate_time="$2"
    local protocol="${3:-tcp}"

    # Skip if rate is 0 (disabled)
    [[ "$rate_time" == "0" ]] && return 0

    # Parse rate/time
    if [[ "$rate_time" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        local rate="${BASH_REMATCH[1]}"
        local time="${BASH_REMATCH[2]}"
    else
        return 1
    fi

    local log_enabled
    log_enabled=$(nftban_ddos_load_config "DDOS_PORTFLOOD_LOG" "true")

    # Apply to both IPv4 and IPv6
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        # Add rate limiting rule
        nft add rule $family $table $NFTBAN_NFT_PORTFLOOD_CHAIN \
            $protocol dport $port \
            ct state new \
            limit rate over $rate/$time second \
            counter drop

        # Add logging rule if enabled
        if [[ "$log_enabled" == "true" ]]; then
            nft add rule $family $table $NFTBAN_NFT_PORTFLOOD_CHAIN \
                $protocol dport $port \
                ct state new \
                limit rate over $rate/$time second \
                limit rate 10/minute burst 5 packets \
                log prefix "\"nftban: PORTFLOOD($port): \"" \
                counter
        fi
    done

    return 0
}

# Enable port flood protection
nftban_ddos_portflood_enable() {
    if ! nftban_ddos_is_enabled; then
        nftban_ddos_log "WARNING" "DDoS protection is globally disabled"
        echo "⚠️  Warning: DDoS protection is globally disabled in config"
        return 1
    fi

    nftban_ddos_log "INFO" "Enabling port flood protection"

    # Apply to both IPv4 and IPv6 tables
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        # Create chain if it doesn't exist
        if ! nft list chain $family $table $NFTBAN_NFT_PORTFLOOD_CHAIN &>/dev/null; then
            nft add chain $family $table $NFTBAN_NFT_PORTFLOOD_CHAIN \
                '{ type filter hook input priority 0; policy accept; }' 2>/dev/null || \
            nft add chain $family $table $NFTBAN_NFT_PORTFLOOD_CHAIN 2>/dev/null || true
        fi

        # Flush existing rules
        nft flush chain $family $table $NFTBAN_NFT_PORTFLOOD_CHAIN 2>/dev/null || true
    done

    # Load per-service port flood limits
    local ssh_rate http_rate https_rate ftp_rate smtp_rate

    ssh_rate=$(nftban_ddos_load_config "DDOS_PORTFLOOD_SSH" "5/300")
    http_rate=$(nftban_ddos_load_config "DDOS_PORTFLOOD_HTTP" "20/5")
    https_rate=$(nftban_ddos_load_config "DDOS_PORTFLOOD_HTTPS" "20/5")
    ftp_rate=$(nftban_ddos_load_config "DDOS_PORTFLOOD_FTP" "10/60")
    smtp_rate=$(nftban_ddos_load_config "DDOS_PORTFLOOD_SMTP" "5/300")

    # Add rules for each service (skip if rate is 0)
    [[ "$ssh_rate" != "0" ]] && nftban_ddos_portflood_add_port 22 "$ssh_rate" tcp && \
        echo "  ✅ SSH: max $ssh_rate"
    [[ "$http_rate" != "0" ]] && nftban_ddos_portflood_add_port 80 "$http_rate" tcp && \
        echo "  ✅ HTTP: max $http_rate"
    [[ "$https_rate" != "0" ]] && nftban_ddos_portflood_add_port 443 "$https_rate" tcp && \
        echo "  ✅ HTTPS: max $https_rate"
    [[ "$ftp_rate" != "0" ]] && nftban_ddos_portflood_add_port 21 "$ftp_rate" tcp && \
        echo "  ✅ FTP: max $ftp_rate"
    [[ "$smtp_rate" != "0" ]] && nftban_ddos_portflood_add_port 25 "$smtp_rate" tcp && \
        echo "  ✅ SMTP: max $smtp_rate"

    # Handle custom port flood limits
    local custom_limits
    custom_limits=$(nftban_ddos_load_config "DDOS_PORTFLOOD_CUSTOM" "")
    if [[ -n "$custom_limits" ]]; then
        # Parse custom limits: "port;rate/time,port;rate/time,..."
        IFS=',' read -ra CUSTOM_ARRAY <<< "$custom_limits"
        for entry in "${CUSTOM_ARRAY[@]}"; do
            if [[ "$entry" =~ ^([0-9]+)\;([0-9]+/[0-9]+)$ ]]; then
                local port="${BASH_REMATCH[1]}"
                local rate="${BASH_REMATCH[2]}"
                nftban_ddos_portflood_add_port "$port" "$rate" tcp && \
                    echo "  ✅ Port $port: max $rate"
            fi
        done
    fi

    nftban_ddos_log "INFO" "Port flood protection enabled"
    echo ""
    echo "✅ Port flood protection enabled"

    return 0
}

# Disable port flood protection
nftban_ddos_portflood_disable() {
    nftban_ddos_log "INFO" "Disabling port flood protection"

    # Flush chain on both tables
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        if nft list chain $family $table $NFTBAN_NFT_PORTFLOOD_CHAIN &>/dev/null; then
            nft flush chain $family $table $NFTBAN_NFT_PORTFLOOD_CHAIN 2>/dev/null || true
        fi
    done

    nftban_ddos_log "INFO" "Port flood protection disabled"
    echo "✅ Port flood protection disabled"

    return 0
}

# Show port flood protection status
nftban_ddos_portflood_status() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📊 Port Flood Protection Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local enabled
    enabled=$(nftban_ddos_load_config "DDOS_PORTFLOOD_ENABLED" "true")

    echo "Configuration:"
    if [[ "$enabled" == "true" ]]; then
        echo "  ✅ Enabled: true"

        # Show per-service limits
        echo ""
        echo "  Per-Service Limits:"
        local ssh http https ftp smtp
        ssh=$(nftban_ddos_load_config "DDOS_PORTFLOOD_SSH" "5/300")
        http=$(nftban_ddos_load_config "DDOS_PORTFLOOD_HTTP" "20/5")
        https=$(nftban_ddos_load_config "DDOS_PORTFLOOD_HTTPS" "20/5")
        ftp=$(nftban_ddos_load_config "DDOS_PORTFLOOD_FTP" "10/60")
        smtp=$(nftban_ddos_load_config "DDOS_PORTFLOOD_SMTP" "5/300")

        echo "    SSH (22):    $ssh"
        echo "    HTTP (80):   $http"
        echo "    HTTPS (443): $https"
        echo "    FTP (21):    $ftp"
        echo "    SMTP (25):   $smtp"
    else
        echo "  ❌ Enabled: false"
    fi

    echo ""
    echo "Active Rules (IPv4):"
    if nft list chain ip $NFTBAN_NFT_TABLE_V4 $NFTBAN_NFT_PORTFLOOD_CHAIN &>/dev/null; then
        nft list chain ip $NFTBAN_NFT_TABLE_V4 $NFTBAN_NFT_PORTFLOOD_CHAIN | grep -v "^table\|^chain" | sed 's/^/  /'
    else
        echo "  (no active rules)"
    fi

    return 0
}

# =============================================================================
# ICMP FLOOD PROTECTION
# =============================================================================

# Enable ICMP flood protection
nftban_ddos_icmp_enable() {
    if ! nftban_ddos_is_enabled; then
        nftban_ddos_log "WARNING" "DDoS protection is globally disabled"
        echo "⚠️  Warning: DDoS protection is globally disabled in config"
        return 1
    fi

    local rate burst log_enabled timestamp_drop addressmask_drop
    rate=$(nftban_ddos_load_config "DDOS_ICMPFLOOD_RATE" "1/second")
    burst=$(nftban_ddos_load_config "DDOS_ICMPFLOOD_BURST" "10")
    log_enabled=$(nftban_ddos_load_config "DDOS_ICMPFLOOD_LOG" "false")
    timestamp_drop=$(nftban_ddos_load_config "DDOS_ICMP_TIMESTAMP_DROP" "false")
    addressmask_drop=$(nftban_ddos_load_config "DDOS_ICMP_ADDRESSMASK_DROP" "true")

    rate=$(nftban_ddos_convert_rate "$rate")

    nftban_ddos_log "INFO" "Enabling ICMP flood protection (rate: $rate, burst: $burst)"

    # Apply to both IPv4 and IPv6
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        # Create chain if it doesn't exist
        if ! nft list chain $family $table $NFTBAN_NFT_ICMP_CHAIN &>/dev/null; then
            nft add chain $family $table $NFTBAN_NFT_ICMP_CHAIN \
                '{ type filter hook input priority 0; policy accept; }' 2>/dev/null || \
            nft add chain $family $table $NFTBAN_NFT_ICMP_CHAIN 2>/dev/null || true
        fi

        # Flush existing rules
        nft flush chain $family $table $NFTBAN_NFT_ICMP_CHAIN 2>/dev/null || true

        # IPv4-specific ICMP rules
        if [[ "$family" == "ip" ]]; then
            # Accept ICMP echo requests within rate limit
            nft add rule $family $table $NFTBAN_NFT_ICMP_CHAIN \
                icmp type echo-request \
                limit rate $rate burst $burst packets \
                counter accept

            # Drop ICMP timestamp requests (type 13) if enabled
            if [[ "$timestamp_drop" == "true" ]]; then
                nft add rule $family $table $NFTBAN_NFT_ICMP_CHAIN \
                    icmp type timestamp-request \
                    counter drop
            fi

            # Drop ICMP address mask requests (type 17) if enabled
            if [[ "$addressmask_drop" == "true" ]]; then
                nft add rule $family $table $NFTBAN_NFT_ICMP_CHAIN \
                    icmp type address-mask-request \
                    counter drop
            fi

            # Log and drop excess ICMP if logging enabled
            if [[ "$log_enabled" == "true" ]]; then
                nft add rule $family $table $NFTBAN_NFT_ICMP_CHAIN \
                    icmp type echo-request \
                    limit rate 10/minute burst 5 packets \
                    log prefix '"nftban: ICMPFLOOD: "' \
                    counter
            fi

            # Drop excess ICMP echo requests
            nft add rule $family $table $NFTBAN_NFT_ICMP_CHAIN \
                icmp type echo-request \
                counter drop

        # IPv6-specific ICMPv6 rules
        elif [[ "$family" == "ip6" ]]; then
            # Accept ICMPv6 echo requests within rate limit
            nft add rule $family $table $NFTBAN_NFT_ICMP_CHAIN \
                icmpv6 type echo-request \
                limit rate $rate burst $burst packets \
                counter accept

            # Log and drop excess ICMPv6 if logging enabled
            if [[ "$log_enabled" == "true" ]]; then
                nft add rule $family $table $NFTBAN_NFT_ICMP_CHAIN \
                    icmpv6 type echo-request \
                    limit rate 10/minute burst 5 packets \
                    log prefix '"nftban: ICMP6FLOOD: "' \
                    counter
            fi

            # Drop excess ICMPv6 echo requests
            nft add rule $family $table $NFTBAN_NFT_ICMP_CHAIN \
                icmpv6 type echo-request \
                counter drop

            # Accept essential ICMPv6 types (Neighbor Discovery, Router Discovery)
            nft add rule $family $table $NFTBAN_NFT_ICMP_CHAIN \
                icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } \
                counter accept
        fi
    done

    nftban_ddos_log "INFO" "ICMP flood protection enabled successfully"
    echo "✅ ICMP flood protection enabled (rate: $rate, burst: $burst)"

    return 0
}

# Disable ICMP flood protection
nftban_ddos_icmp_disable() {
    nftban_ddos_log "INFO" "Disabling ICMP flood protection"

    # Flush chain on both tables
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        if nft list chain $family $table $NFTBAN_NFT_ICMP_CHAIN &>/dev/null; then
            nft flush chain $family $table $NFTBAN_NFT_ICMP_CHAIN 2>/dev/null || true
        fi
    done

    nftban_ddos_log "INFO" "ICMP flood protection disabled"
    echo "✅ ICMP flood protection disabled"

    return 0
}

# Show ICMP flood protection status
nftban_ddos_icmp_status() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  📊 ICMP Flood Protection Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local enabled
    enabled=$(nftban_ddos_load_config "DDOS_ICMPFLOOD_ENABLED" "true")

    echo "Configuration:"
    if [[ "$enabled" == "true" ]]; then
        echo "  ✅ Enabled: true"
        local rate burst
        rate=$(nftban_ddos_load_config "DDOS_ICMPFLOOD_RATE" "1/second")
        burst=$(nftban_ddos_load_config "DDOS_ICMPFLOOD_BURST" "10")
        echo "  Rate Limit: $rate"
        echo "  Burst: $burst packets"
    else
        echo "  ❌ Enabled: false"
    fi

    echo ""
    echo "Active Rules (IPv4):"
    if nft list chain ip $NFTBAN_NFT_TABLE_V4 $NFTBAN_NFT_ICMP_CHAIN &>/dev/null; then
        nft list chain ip $NFTBAN_NFT_TABLE_V4 $NFTBAN_NFT_ICMP_CHAIN | grep -v "^table\|^chain" | sed 's/^/  /'
    else
        echo "  (no active rules)"
    fi

    echo ""
    echo "Active Rules (IPv6):"
    if nft list chain ip6 $NFTBAN_NFT_TABLE_V6 $NFTBAN_NFT_ICMP_CHAIN &>/dev/null; then
        nft list chain ip6 $NFTBAN_NFT_TABLE_V6 $NFTBAN_NFT_ICMP_CHAIN | grep -v "^table\|^chain" | sed 's/^/  /'
    else
        echo "  (no active rules)"
    fi

    return 0
}

# =============================================================================
# GLOBAL DDOS FUNCTIONS
# =============================================================================

# Enable all DDoS protections (based on config)
nftban_ddos_enable() {
    nftban_ddos_banner
    echo ""
    echo "⏳ Enabling DDoS protections..."
    echo ""

    # Check if globally enabled
    if ! nftban_ddos_is_enabled; then
        echo "❌ DDoS protection is globally disabled in configuration"
        echo "   Set DDOS_PROTECTION_ENABLED=\"true\" to enable"
        return 1
    fi

    local synflood_enabled connlimit_enabled portflood_enabled icmp_enabled
    synflood_enabled=$(nftban_ddos_load_config "DDOS_SYNFLOOD_ENABLED" "false")
    connlimit_enabled=$(nftban_ddos_load_config "DDOS_CONNLIMIT_ENABLED" "true")
    portflood_enabled=$(nftban_ddos_load_config "DDOS_PORTFLOOD_ENABLED" "true")
    icmp_enabled=$(nftban_ddos_load_config "DDOS_ICMPFLOOD_ENABLED" "true")

    # Enable each protection based on config
    echo "Enabling protections:"
    echo ""

    if [[ "$synflood_enabled" == "true" ]]; then
        echo "🛡️  SYN Flood Protection:"
        nftban_ddos_synflood_enable
        echo ""
    fi

    if [[ "$connlimit_enabled" == "true" ]]; then
        echo "🛡️  Connection Limit Protection:"
        nftban_ddos_connlimit_enable
        echo ""
    fi

    if [[ "$portflood_enabled" == "true" ]]; then
        echo "🛡️  Port Flood Protection:"
        nftban_ddos_portflood_enable
        echo ""
    fi

    if [[ "$icmp_enabled" == "true" ]]; then
        echo "🛡️  ICMP Flood Protection:"
        nftban_ddos_icmp_enable
        echo ""
    fi

    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ DDoS Protection ENABLED                              ║"
    echo "╚══════════════════════════════════════════════════════════╝"

    return 0
}

# Disable all DDoS protections
nftban_ddos_disable() {
    nftban_ddos_banner
    echo ""
    echo "⏳ Disabling all DDoS protections..."
    echo ""

    nftban_ddos_synflood_disable
    nftban_ddos_connlimit_disable
    nftban_ddos_portflood_disable
    nftban_ddos_icmp_disable

    echo ""
    echo "╔══════════════════════════════════════════════════════════╗"
    echo "║  ✅ All DDoS Protections DISABLED                        ║"
    echo "╚══════════════════════════════════════════════════════════╝"

    return 0
}

# Show complete DDoS protection status
nftban_ddos_status() {
    nftban_ddos_banner
    echo ""
    echo "Global Configuration:"
    echo "  Master Switch: $(nftban_ddos_is_enabled && echo "✅ ENABLED" || echo "❌ DISABLED")"
    echo "  Logging: $(nftban_ddos_load_config "DDOS_LOGGING_ENABLED" "true")"
    echo "  Email Alerts: $(nftban_ddos_load_config "DDOS_EMAIL_ALERTS" "true")"

    nftban_ddos_synflood_status
    nftban_ddos_connlimit_status
    nftban_ddos_portflood_status
    nftban_ddos_icmp_status

    echo ""
    echo "📁 Log File: $NFTBAN_DDOS_LOG_FILE"
    echo ""

    return 0
}

# =============================================================================
# MODULE INITIALIZATION
# =============================================================================

nftban_ddos_init() {
    # Create FHS directories
    mkdir -p "$NFTBAN_DDOS_DATA_DIR"
    mkdir -p "$NFTBAN_DDOS_CACHE_DIR"
    mkdir -p "$(dirname "$NFTBAN_DDOS_LOG_FILE")"

    # Touch log file
    touch "$NFTBAN_DDOS_LOG_FILE"

    nftban_ddos_log "DEBUG" "DDoS protection module initialized (v$MODULE_VERSION)"
}

# Auto-initialize on module load
nftban_ddos_init

# =============================================================================
# EXPORT FUNCTIONS FOR CLI HANDLER
# =============================================================================
export -f nftban_ddos_banner
export -f nftban_ddos_get_tables
export -f nftban_ddos_load_config
export -f nftban_ddos_log
export -f nftban_ddos_is_enabled
export -f nftban_ddos_convert_rate
export -f nftban_ddos_synflood_enable
export -f nftban_ddos_synflood_disable
export -f nftban_ddos_synflood_status
export -f nftban_ddos_connlimit_add_port
export -f nftban_ddos_connlimit_enable
export -f nftban_ddos_connlimit_disable
export -f nftban_ddos_connlimit_status
export -f nftban_ddos_portflood_add_port
export -f nftban_ddos_portflood_enable
export -f nftban_ddos_portflood_disable
export -f nftban_ddos_portflood_status
export -f nftban_ddos_icmp_enable
export -f nftban_ddos_icmp_disable
export -f nftban_ddos_icmp_status
export -f nftban_ddos_enable
export -f nftban_ddos_disable
export -f nftban_ddos_status
export -f nftban_ddos_init

# =============================================================================
# END OF MODULE
# =============================================================================
