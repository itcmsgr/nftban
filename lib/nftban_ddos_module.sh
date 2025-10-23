#!/usr/bin/env bash

# =============================================================================
# NFTBan DDoS Protection Module
# Version: 0.9.2
# Location: lib/nftban_ddos_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Implements SYN flood, connection limits, port flood, and ICMP protection
# =============================================================================

# Strict mode for production-grade security
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_DDOS_LOADED:-}" ]] && return 0
readonly NFTBAN_DDOS_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_DDOS_CONFIG="${NFTBAN_CONFIG_DIR}/ddos_protection.conf"
readonly NFTBAN_DDOS_CONFIG_LOCAL="${NFTBAN_CONFIG_DIR}/ddos_protection.conf.local"
readonly NFTBAN_DDOS_LOG="${NFTBAN_LOG_DIR}/ddos-protection.log"
readonly NFTBAN_DDOS_STATS_FILE="${NFTBAN_DATA_DIR}/ddos-stats.tmp"

# nftables table and chain names
# v0.9.0: Use core module constants (NFTBAN_NFT_TABLE_V4/V6, NFTBAN_NFT_FAMILY_V4/V6)
readonly NFTBAN_NFT_SYNFLOOD_CHAIN="synflood_protection"
readonly NFTBAN_NFT_CONNLIMIT_CHAIN="connlimit_protection"
readonly NFTBAN_NFT_PORTFLOOD_CHAIN="portflood_protection"
readonly NFTBAN_NFT_ICMP_CHAIN="icmp_protection"

# Configuration cache
declare -A NFTBAN_DDOS_CONFIG_CACHE

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

# Helper: Get array of table specs for iteration
# Returns: Array of "family:table" pairs for both IPv4 and IPv6
# Usage: for table_info in $(nftban_ddos_get_tables); do ... done
nftban_ddos_get_tables() {
    echo "ip:$NFTBAN_NFT_TABLE_V4 ip6:$NFTBAN_NFT_TABLE_V6"
}

# Load DDoS configuration
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

    local value="$default"

    # Load from .local file first (user overrides)
    if [[ -f "$NFTBAN_DDOS_CONFIG_LOCAL" ]]; then
        value=$(grep "^${key}=" "$NFTBAN_DDOS_CONFIG_LOCAL" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | head -n1)
    fi

    # Fallback to main config
    if [[ -z "$value" && -f "$NFTBAN_DDOS_CONFIG" ]]; then
        value=$(grep "^${key}=" "$NFTBAN_DDOS_CONFIG" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | head -n1)
    fi

    # Use default if still empty
    value="${value:-$default}"

    # Cache the value (temporarily disable nounset for array access)
    set +u
    NFTBAN_DDOS_CONFIG_CACHE[$key]="$value"
    set -u

    echo "$value"
}

# Log to DDoS log file
nftban_ddos_log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    echo "[${timestamp}] [${level}] ${message}" >> "$NFTBAN_DDOS_LOG"

    # Also log to main nftban log
    case "$level" in
        ERROR)   nftban_log_error "$message" ;;
        WARNING) nftban_log_warning "$message" ;;
        INFO)    nftban_log_info "$message" ;;
        DEBUG)   nftban_log_debug "$message" ;;
        *)       nftban_log_info "$message" ;;
    esac
}

# Check if DDoS protection is globally enabled
nftban_ddos_is_enabled() {
    local enabled
    enabled=$(nftban_ddos_load_config "DDOS_PROTECTION_ENABLED" "1")
    [[ "${enabled:-1}" == "1" ]]
}

# Convert rate format (e.g., "100/second") to nftables format
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
nftban_ddos_synflood_enable() {
    if ! nftban_ddos_is_enabled; then
        nftban_ddos_log "WARNING" "DDoS protection is globally disabled"
        echo "Warning: DDoS protection is globally disabled in config"
        return 1
    fi

    local rate burst
    rate=$(nftban_ddos_load_config "SYNFLOOD_RATE" "100/second")
    burst=$(nftban_ddos_load_config "SYNFLOOD_BURST" "150")

    rate=$(nftban_ddos_convert_rate "$rate")

    nftban_ddos_log "INFO" "Enabling SYN flood protection (rate: $rate, burst: $burst)"

    # Log if enabled
    local log_enabled
    log_enabled=$(nftban_ddos_load_config "SYNFLOOD_LOG" "1")

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
        if [[ "$log_enabled" == "1" ]]; then
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
    echo "✓ SYN flood protection enabled (rate: $rate, burst: $burst)"

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
    echo "✓ SYN flood protection disabled"

    return 0
}

# Show SYN flood protection status
nftban_ddos_synflood_status() {
    echo ""
    echo "======================================================="
    echo "  SYN Flood Protection Status"
    echo "======================================================="
    echo ""

    local enabled
    enabled=$(nftban_ddos_load_config "SYNFLOOD_ENABLE" "0")

    echo "Configuration:"
    echo "  Enabled: $enabled"

    if [[ "$enabled" == "1" ]]; then
        local rate burst
        rate=$(nftban_ddos_load_config "SYNFLOOD_RATE" "100/second")
        burst=$(nftban_ddos_load_config "SYNFLOOD_BURST" "150")
        echo "  Rate Limit: $rate"
        echo "  Burst: $burst packets"
    fi

    echo ""
    echo "Active Rules (IPv4):"
    if nft list chain ip $NFTBAN_NFT_TABLE_V4 $NFTBAN_NFT_SYNFLOOD_CHAIN &>/dev/null; then
        nft list chain ip $NFTBAN_NFT_TABLE_V4 $NFTBAN_NFT_SYNFLOOD_CHAIN | \
            grep -E 'tcp flags syn|counter|limit' | sed 's/^/  /'
    else
        echo "  (chain not created)"
    fi

    echo ""
    echo "Active Rules (IPv6):"
    if nft list chain ip6 $NFTBAN_NFT_TABLE_V6 $NFTBAN_NFT_SYNFLOOD_CHAIN &>/dev/null; then
        nft list chain ip6 $NFTBAN_NFT_TABLE_V6 $NFTBAN_NFT_SYNFLOOD_CHAIN | \
            grep -E 'tcp flags syn|counter|limit' | sed 's/^/  /'
    else
        echo "  (chain not created)"
    fi

    echo ""
    echo "======================================================="
}

# =============================================================================
# CONNECTION LIMIT PROTECTION
# =============================================================================

# Enable connection limit for a specific port
nftban_ddos_connlimit_add_port() {
    local port="$1"
    local limit="$2"
    local action="${3:-reject}"

    if ! nftban_ddos_is_enabled; then
        nftban_ddos_log "WARNING" "DDoS protection is globally disabled"
        return 1
    fi

    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
        nftban_ddos_log "ERROR" "Invalid port: $port"
        echo "Error: Invalid port number: $port"
        return 1
    fi

    if [[ ! "$limit" =~ ^[0-9]+$ ]] || [[ $limit -lt 1 ]]; then
        nftban_ddos_log "ERROR" "Invalid connection limit: $limit"
        echo "Error: Invalid connection limit: $limit"
        return 1
    fi

    nftban_ddos_log "INFO" "Adding connection limit for port $port: $limit connections"

    # Add rule before the accept rule
    local reject_action="reject with tcp reset"
    [[ "$action" == "drop" ]] && reject_action="drop"

    # Log if enabled
    local log_enabled
    log_enabled=$(nftban_ddos_load_config "CONNLIMIT_LOG" "1")

    # Apply to both IPv4 and IPv6 tables
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        # Check if input chain exists
        if ! nft list chain $family $table input &>/dev/null; then
            nftban_ddos_log "ERROR" "$family $table input chain does not exist"
            continue
        fi

        # Log if enabled
        if [[ "$log_enabled" == "1" ]]; then
            nft insert rule $family $table input \
                tcp dport $port \
                tcp flags syn \
                ct state new \
                ct count over $limit \
                limit rate 10/minute burst 5 packets \
                log prefix "\"nftban: CONNLIMIT port $port: \"" \
                counter 2>/dev/null || true
        fi

        # Add connection limit rule
        nft insert rule $family $table input \
            tcp dport $port \
            tcp flags syn \
            ct state new \
            ct count over $limit \
            counter $reject_action
    done

    nftban_ddos_log "INFO" "Connection limit added for port $port: max $limit connections"
    echo "✓ Connection limit added for port $port: max $limit connections per IP"

    return 0
}

# Enable connection limits from configuration
nftban_ddos_connlimit_enable() {
    if ! nftban_ddos_is_enabled; then
        nftban_ddos_log "WARNING" "DDoS protection is globally disabled"
        echo "Warning: DDoS protection is globally disabled in config"
        return 1
    fi

    local enabled
    enabled=$(nftban_ddos_load_config "CONNLIMIT_ENABLE" "1")

    if [[ "$enabled" != "1" ]]; then
        echo "Connection limit protection is disabled in config"
        return 0
    fi

    nftban_ddos_log "INFO" "Enabling connection limit protection"

    local action
    action=$(nftban_ddos_load_config "CONNLIMIT_ACTION" "reject")

    # Standard ports
    local ssh_limit http_limit https_limit ftp_limit smtp_limit pop3_limit imap_limit mysql_limit pgsql_limit
    ssh_limit=$(nftban_ddos_load_config "CONNLIMIT_SSH" "5")
    http_limit=$(nftban_ddos_load_config "CONNLIMIT_HTTP" "20")
    https_limit=$(nftban_ddos_load_config "CONNLIMIT_HTTPS" "20")
    ftp_limit=$(nftban_ddos_load_config "CONNLIMIT_FTP" "3")
    smtp_limit=$(nftban_ddos_load_config "CONNLIMIT_SMTP" "5")
    pop3_limit=$(nftban_ddos_load_config "CONNLIMIT_POP3" "5")
    imap_limit=$(nftban_ddos_load_config "CONNLIMIT_IMAP" "5")
    mysql_limit=$(nftban_ddos_load_config "CONNLIMIT_MYSQL" "10")
    pgsql_limit=$(nftban_ddos_load_config "CONNLIMIT_POSTGRESQL" "10")

    local count=0

    [[ "$ssh_limit" != "0" ]] && { nftban_ddos_connlimit_add_port 22 "$ssh_limit" "$action" && ((count++)) || true; }
    [[ "$http_limit" != "0" ]] && { nftban_ddos_connlimit_add_port 80 "$http_limit" "$action" && ((count++)) || true; }
    [[ "$https_limit" != "0" ]] && { nftban_ddos_connlimit_add_port 443 "$https_limit" "$action" && ((count++)) || true; }
    [[ "$ftp_limit" != "0" ]] && { nftban_ddos_connlimit_add_port 21 "$ftp_limit" "$action" && ((count++)) || true; }
    [[ "$smtp_limit" != "0" ]] && { nftban_ddos_connlimit_add_port 25 "$smtp_limit" "$action" && ((count++)) || true; }
    [[ "$pop3_limit" != "0" ]] && { nftban_ddos_connlimit_add_port 110 "$pop3_limit" "$action" && ((count++)) || true; }
    [[ "$imap_limit" != "0" ]] && { nftban_ddos_connlimit_add_port 143 "$imap_limit" "$action" && ((count++)) || true; }
    [[ "$mysql_limit" != "0" ]] && { nftban_ddos_connlimit_add_port 3306 "$mysql_limit" "$action" && ((count++)) || true; }
    [[ "$pgsql_limit" != "0" ]] && { nftban_ddos_connlimit_add_port 5432 "$pgsql_limit" "$action" && ((count++)) || true; }

    # Custom ports
    local custom
    custom=$(nftban_ddos_load_config "CONNLIMIT_CUSTOM" "")

    if [[ -n "$custom" ]]; then
        IFS=',' read -ra PAIRS <<< "$custom"
        for pair in "${PAIRS[@]}"; do
            if [[ "$pair" =~ ^([0-9]+)\;([0-9]+)$ ]]; then
                local port="${BASH_REMATCH[1]}"
                local limit="${BASH_REMATCH[2]}"
                nftban_ddos_connlimit_add_port "$port" "$limit" "$action" && ((count++)) || true
            fi
        done
    fi

    nftban_ddos_log "INFO" "Connection limit protection enabled: $count port(s) configured"
    echo "✓ Connection limit protection enabled: $count port(s) configured"

    return 0
}

# Disable connection limit protection
nftban_ddos_connlimit_disable() {
    nftban_ddos_log "INFO" "Disabling connection limit protection"

    # Remove all connlimit rules from both tables
    local count=0
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        while nft -a list chain $family $table input 2>/dev/null | grep -q "ct count"; do
            local handle
            handle=$(nft -a list chain $family $table input 2>/dev/null | grep "ct count" | head -n1 | grep -oP 'handle \K[0-9]+')
            if [[ -n "$handle" ]]; then
                nft delete rule $family $table input handle "$handle" 2>/dev/null || true
                ((count++)) || true
            else
                break
            fi
        done
    done

    nftban_ddos_log "INFO" "Connection limit protection disabled: $count rule(s) removed"
    echo "✓ Connection limit protection disabled: $count rule(s) removed"

    return 0
}

# Show connection limit status
nftban_ddos_connlimit_status() {
    echo ""
    echo "======================================================="
    echo "  Connection Limit Protection Status"
    echo "======================================================="
    echo ""

    local enabled
    enabled=$(nftban_ddos_load_config "CONNLIMIT_ENABLE" "1")

    echo "Configuration:"
    echo "  Enabled: $enabled"

    if [[ "$enabled" == "1" ]]; then
        echo "  Action: $(nftban_ddos_load_config "CONNLIMIT_ACTION" "reject")"
        echo ""
        echo "Port Limits:"
        echo "  SSH (22):       $(nftban_ddos_load_config "CONNLIMIT_SSH" "5")"
        echo "  HTTP (80):      $(nftban_ddos_load_config "CONNLIMIT_HTTP" "20")"
        echo "  HTTPS (443):    $(nftban_ddos_load_config "CONNLIMIT_HTTPS" "20")"
        echo "  FTP (21):       $(nftban_ddos_load_config "CONNLIMIT_FTP" "3")"
        echo "  SMTP (25):      $(nftban_ddos_load_config "CONNLIMIT_SMTP" "5")"
        echo "  POP3 (110):     $(nftban_ddos_load_config "CONNLIMIT_POP3" "5")"
        echo "  IMAP (143):     $(nftban_ddos_load_config "CONNLIMIT_IMAP" "5")"
        echo "  MySQL (3306):   $(nftban_ddos_load_config "CONNLIMIT_MYSQL" "10")"
        echo "  PostgreSQL (5432): $(nftban_ddos_load_config "CONNLIMIT_POSTGRESQL" "10")"

        local custom
        custom=$(nftban_ddos_load_config "CONNLIMIT_CUSTOM" "")
        if [[ -n "$custom" ]]; then
            echo "  Custom:         $custom"
        fi
    fi

    echo ""
    echo "Active Rules (IPv4):"
    if nft list chain ip $NFTBAN_NFT_TABLE_V4 input 2>/dev/null | grep -q "ct count"; then
        nft list chain ip $NFTBAN_NFT_TABLE_V4 input 2>/dev/null | \
            grep "ct count" | sed 's/^/  /'
    else
        echo "  (no active connection limit rules)"
    fi

    echo ""
    echo "Active Rules (IPv6):"
    if nft list chain ip6 $NFTBAN_NFT_TABLE_V6 input 2>/dev/null | grep -q "ct count"; then
        nft list chain ip6 $NFTBAN_NFT_TABLE_V6 input 2>/dev/null | \
            grep "ct count" | sed 's/^/  /'
    else
        echo "  (no active connection limit rules)"
    fi

    echo ""
    echo "======================================================="
}

# =============================================================================
# PORT FLOOD PROTECTION
# =============================================================================

# Add port flood protection for a specific port
nftban_ddos_portflood_add_port() {
    local port="$1"
    local rate_config="$2"  # Format: "connections/seconds" e.g., "5/300"

    if ! nftban_ddos_is_enabled; then
        nftban_ddos_log "WARNING" "DDoS protection is globally disabled"
        return 1
    fi

    if [[ ! "$port" =~ ^[0-9]+$ ]] || [[ $port -lt 1 ]] || [[ $port -gt 65535 ]]; then
        nftban_ddos_log "ERROR" "Invalid port: $port"
        echo "Error: Invalid port number: $port"
        return 1
    fi

    if [[ ! "$rate_config" =~ ^([0-9]+)/([0-9]+)$ ]]; then
        nftban_ddos_log "ERROR" "Invalid rate format: $rate_config (expected: connections/seconds)"
        echo "Error: Invalid rate format: $rate_config (expected: connections/seconds)"
        return 1
    fi

    local connections="${BASH_REMATCH[1]}"
    local seconds="${BASH_REMATCH[2]}"

    nftban_ddos_log "INFO" "Adding port flood protection for port $port: $connections connections per $seconds seconds"

    # Calculate rate for nftables
    # nftables wants "rate over X/time"
    local nft_rate="${connections}/${seconds} second"

    # Log if enabled
    local log_enabled
    log_enabled=$(nftban_ddos_load_config "PORTFLOOD_LOG" "1")

    # Apply to both IPv4 and IPv6 tables
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        # Log if enabled
        if [[ "$log_enabled" == "1" ]]; then
            nft insert rule $family $table input \
                tcp dport $port \
                ct state new \
                limit rate over $nft_rate \
                limit rate 10/minute burst 5 packets \
                log prefix "\"nftban: PORTFLOOD port $port: \"" \
                counter 2>/dev/null || true
        fi

        # Add rate limiting rule
        nft insert rule $family $table input \
            tcp dport $port \
            ct state new \
            limit rate over $nft_rate \
            counter drop
    done

    nftban_ddos_log "INFO" "Port flood protection added for port $port: max $connections/$seconds"
    echo "✓ Port flood protection added for port $port: max $connections connections per $seconds seconds"

    return 0
}

# Enable port flood protection from configuration
nftban_ddos_portflood_enable() {
    if ! nftban_ddos_is_enabled; then
        nftban_ddos_log "WARNING" "DDoS protection is globally disabled"
        echo "Warning: DDoS protection is globally disabled in config"
        return 1
    fi

    local enabled
    enabled=$(nftban_ddos_load_config "PORTFLOOD_ENABLE" "1")

    if [[ "$enabled" != "1" ]]; then
        echo "Port flood protection is disabled in config"
        return 0
    fi

    nftban_ddos_log "INFO" "Enabling port flood protection"

    local count=0

    # Standard ports
    local ssh_rate http_rate https_rate ftp_rate smtp_rate
    ssh_rate=$(nftban_ddos_load_config "PORTFLOOD_SSH" "5/300")
    http_rate=$(nftban_ddos_load_config "PORTFLOOD_HTTP" "20/5")
    https_rate=$(nftban_ddos_load_config "PORTFLOOD_HTTPS" "20/5")
    ftp_rate=$(nftban_ddos_load_config "PORTFLOOD_FTP" "10/60")
    smtp_rate=$(nftban_ddos_load_config "PORTFLOOD_SMTP" "5/300")

    [[ "$ssh_rate" != "0" ]] && { nftban_ddos_portflood_add_port 22 "$ssh_rate" && ((count++)) || true; }
    [[ "$http_rate" != "0" ]] && { nftban_ddos_portflood_add_port 80 "$http_rate" && ((count++)) || true; }
    [[ "$https_rate" != "0" ]] && { nftban_ddos_portflood_add_port 443 "$https_rate" && ((count++)) || true; }
    [[ "$ftp_rate" != "0" ]] && { nftban_ddos_portflood_add_port 21 "$ftp_rate" && ((count++)) || true; }
    [[ "$smtp_rate" != "0" ]] && { nftban_ddos_portflood_add_port 25 "$smtp_rate" && ((count++)) || true; }

    # Custom ports
    local custom
    custom=$(nftban_ddos_load_config "PORTFLOOD_CUSTOM" "")

    if [[ -n "$custom" ]]; then
        IFS=',' read -ra PAIRS <<< "$custom"
        for pair in "${PAIRS[@]}"; do
            if [[ "$pair" =~ ^([0-9]+)\;([0-9]+/[0-9]+)$ ]]; then
                local port="${BASH_REMATCH[1]}"
                local rate="${BASH_REMATCH[2]}"
                nftban_ddos_portflood_add_port "$port" "$rate" && ((count++)) || true
            fi
        done
    fi

    nftban_ddos_log "INFO" "Port flood protection enabled: $count port(s) configured"
    echo "✓ Port flood protection enabled: $count port(s) configured"

    return 0
}

# Disable port flood protection
nftban_ddos_portflood_disable() {
    nftban_ddos_log "INFO" "Disabling port flood protection"

    # Remove all port flood rules (limit rate over) from both tables
    local count=0
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        while nft -a list chain $family $table input 2>/dev/null | grep -q "limit rate over"; do
            local handle
            handle=$(nft -a list chain $family $table input 2>/dev/null | grep "limit rate over" | head -n1 | grep -oP 'handle \K[0-9]+')
            if [[ -n "$handle" ]]; then
                nft delete rule $family $table input handle "$handle" 2>/dev/null || true
                ((count++)) || true
            else
                break
            fi
        done
    done

    nftban_ddos_log "INFO" "Port flood protection disabled: $count rule(s) removed"
    echo "✓ Port flood protection disabled: $count rule(s) removed"

    return 0
}

# Show port flood status
nftban_ddos_portflood_status() {
    echo ""
    echo "======================================================="
    echo "  Port Flood Protection Status"
    echo "======================================================="
    echo ""

    local enabled
    enabled=$(nftban_ddos_load_config "PORTFLOOD_ENABLE" "1")

    echo "Configuration:"
    echo "  Enabled: $enabled"

    if [[ "$enabled" == "1" ]]; then
        echo ""
        echo "Port Rates:"
        echo "  SSH (22):    $(nftban_ddos_load_config "PORTFLOOD_SSH" "5/300")"
        echo "  HTTP (80):   $(nftban_ddos_load_config "PORTFLOOD_HTTP" "20/5")"
        echo "  HTTPS (443): $(nftban_ddos_load_config "PORTFLOOD_HTTPS" "20/5")"
        echo "  FTP (21):    $(nftban_ddos_load_config "PORTFLOOD_FTP" "10/60")"
        echo "  SMTP (25):   $(nftban_ddos_load_config "PORTFLOOD_SMTP" "5/300")"

        local custom
        custom=$(nftban_ddos_load_config "PORTFLOOD_CUSTOM" "")
        if [[ -n "$custom" ]]; then
            echo "  Custom:      $custom"
        fi
    fi

    echo ""
    echo "Active Rules (IPv4):"
    if nft list chain ip $NFTBAN_NFT_TABLE_V4 input 2>/dev/null | grep -q "limit rate over"; then
        nft list chain ip $NFTBAN_NFT_TABLE_V4 input 2>/dev/null | \
            grep "limit rate over" | sed 's/^/  /'
    else
        echo "  (no active port flood rules)"
    fi

    echo ""
    echo "Active Rules (IPv6):"
    if nft list chain ip6 $NFTBAN_NFT_TABLE_V6 input 2>/dev/null | grep -q "limit rate over"; then
        nft list chain ip6 $NFTBAN_NFT_TABLE_V6 input 2>/dev/null | \
            grep "limit rate over" | sed 's/^/  /'
    else
        echo "  (no active port flood rules)"
    fi

    echo ""
    echo "======================================================="
}

# =============================================================================
# ICMP PROTECTION
# =============================================================================

# Enable ICMP rate limiting
nftban_ddos_icmp_enable() {
    if ! nftban_ddos_is_enabled; then
        nftban_ddos_log "WARNING" "DDoS protection is globally disabled"
        echo "Warning: DDoS protection is globally disabled in config"
        return 1
    fi

    local enabled
    enabled=$(nftban_ddos_load_config "ICMP_RATELIMIT_ENABLE" "1")

    if [[ "$enabled" != "1" ]]; then
        echo "ICMP rate limiting is disabled in config"
        return 0
    fi

    nftban_ddos_log "INFO" "Enabling ICMP protection"

    local in_rate
    in_rate=$(nftban_ddos_load_config "ICMP_IN_RATE" "1/second")
    in_rate=$(nftban_ddos_convert_rate "$in_rate")

    # Drop ICMP timestamp requests if enabled
    local timestamp_drop
    timestamp_drop=$(nftban_ddos_load_config "ICMP_TIMESTAMP_DROP" "0")

    # Drop ICMP address mask requests if enabled
    local addressmask_drop
    addressmask_drop=$(nftban_ddos_load_config "ICMP_ADDRESSMASK_DROP" "1")

    # Apply to both IPv4 and IPv6 tables
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        if [[ "$family" == "ip" ]]; then
            # IPv4 ICMP rules
            # Rate limit incoming ICMP echo requests (ping)
            if [[ "$in_rate" != "0" ]]; then
                nft insert rule $family $table input \
                    ip protocol icmp \
                    icmp type echo-request \
                    limit rate $in_rate \
                    counter accept

                # Drop excess
                nft insert rule $family $table input \
                    ip protocol icmp \
                    icmp type echo-request \
                    counter drop
            fi

            # Drop ICMP timestamp requests
            if [[ "$timestamp_drop" == "1" ]]; then
                nft insert rule $family $table input \
                    ip protocol icmp \
                    icmp type timestamp-request \
                    counter drop
            fi

            # Drop ICMP address mask requests
            if [[ "$addressmask_drop" == "1" ]]; then
                nft insert rule $family $table input \
                    ip protocol icmp \
                    icmp type address-mask-request \
                    counter drop
            fi
        else
            # IPv6 ICMPv6 rules
            # Rate limit incoming ICMPv6 echo requests (ping)
            if [[ "$in_rate" != "0" ]]; then
                nft insert rule $family $table input \
                    ip6 nexthdr icmpv6 \
                    icmpv6 type echo-request \
                    limit rate $in_rate \
                    counter accept

                # Drop excess
                nft insert rule $family $table input \
                    ip6 nexthdr icmpv6 \
                    icmpv6 type echo-request \
                    counter drop
            fi
        fi
    done

    # Output messages
    if [[ "$in_rate" != "0" ]]; then
        echo "✓ ICMP echo request rate limiting enabled: $in_rate"
    fi
    if [[ "$timestamp_drop" == "1" ]]; then
        echo "✓ ICMP timestamp requests blocked (PCI compliance)"
    fi
    if [[ "$addressmask_drop" == "1" ]]; then
        echo "✓ ICMP address mask requests blocked"
    fi

    nftban_ddos_log "INFO" "ICMP protection enabled"

    return 0
}

# Disable ICMP protection
nftban_ddos_icmp_disable() {
    nftban_ddos_log "INFO" "Disabling ICMP protection"

    # Remove all ICMP rules from both tables
    local count=0
    for table_info in $(nftban_ddos_get_tables); do
        local family="${table_info%%:*}"
        local table="${table_info##*:}"

        # Remove ICMP/ICMPv6 rules (search for both icmp and icmpv6)
        while nft -a list chain $family $table input 2>/dev/null | grep -qE "icmp type|icmpv6 type"; do
            local handle
            handle=$(nft -a list chain $family $table input 2>/dev/null | grep -E "icmp type|icmpv6 type" | head -n1 | grep -oP 'handle \K[0-9]+')
            if [[ -n "$handle" ]]; then
                nft delete rule $family $table input handle "$handle" 2>/dev/null || true
                ((count++)) || true
            else
                break
            fi
        done
    done

    nftban_ddos_log "INFO" "ICMP protection disabled: $count rule(s) removed"
    echo "✓ ICMP protection disabled: $count rule(s) removed"

    return 0
}

# Show ICMP protection status
nftban_ddos_icmp_status() {
    echo ""
    echo "======================================================="
    echo "  ICMP Protection Status"
    echo "======================================================="
    echo ""

    local enabled
    enabled=$(nftban_ddos_load_config "ICMP_RATELIMIT_ENABLE" "1")

    echo "Configuration:"
    echo "  Enabled: $enabled"

    if [[ "$enabled" == "1" ]]; then
        echo "  Incoming Rate: $(nftban_ddos_load_config "ICMP_IN_RATE" "1/second")"
        echo "  Timestamp Drop: $(nftban_ddos_load_config "ICMP_TIMESTAMP_DROP" "0")"
        echo "  Address Mask Drop: $(nftban_ddos_load_config "ICMP_ADDRESSMASK_DROP" "1")"
    fi

    echo ""
    echo "Active Rules (IPv4):"
    if nft list chain ip $NFTBAN_NFT_TABLE_V4 input 2>/dev/null | grep -q "icmp type"; then
        nft list chain ip $NFTBAN_NFT_TABLE_V4 input 2>/dev/null | \
            grep "icmp type" | sed 's/^/  /'
    else
        echo "  (no active ICMP protection rules)"
    fi

    echo ""
    echo "Active Rules (IPv6):"
    if nft list chain ip6 $NFTBAN_NFT_TABLE_V6 input 2>/dev/null | grep -q "icmpv6 type"; then
        nft list chain ip6 $NFTBAN_NFT_TABLE_V6 input 2>/dev/null | \
            grep "icmpv6 type" | sed 's/^/  /'
    else
        echo "  (no active ICMPv6 protection rules)"
    fi

    echo ""
    echo "======================================================="
}

# =============================================================================
# MASTER CONTROL FUNCTIONS
# =============================================================================

# Enable all DDoS protections
nftban_ddos_enable_all() {
    echo ""
    echo "Enabling all DDoS protections..."
    echo ""

    local synflood_enabled connlimit_enabled portflood_enabled icmp_enabled
    synflood_enabled=$(nftban_ddos_load_config "SYNFLOOD_ENABLE" "0")
    connlimit_enabled=$(nftban_ddos_load_config "CONNLIMIT_ENABLE" "1")
    portflood_enabled=$(nftban_ddos_load_config "PORTFLOOD_ENABLE" "1")
    icmp_enabled=$(nftban_ddos_load_config "ICMP_RATELIMIT_ENABLE" "1")

    [[ "$synflood_enabled" == "1" ]] && nftban_ddos_synflood_enable
    [[ "$connlimit_enabled" == "1" ]] && nftban_ddos_connlimit_enable
    [[ "$portflood_enabled" == "1" ]] && nftban_ddos_portflood_enable
    [[ "$icmp_enabled" == "1" ]] && nftban_ddos_icmp_enable

    echo ""
    echo "✓ DDoS protection initialization complete"

    return 0
}

# Disable all DDoS protections
nftban_ddos_disable_all() {
    echo ""
    echo "Disabling all DDoS protections..."
    echo ""

    nftban_ddos_synflood_disable
    nftban_ddos_connlimit_disable
    nftban_ddos_portflood_disable
    nftban_ddos_icmp_disable

    echo ""
    echo "✓ All DDoS protections disabled"

    return 0
}

# Show complete DDoS protection status
nftban_ddos_status() {
    echo ""
    echo "======================================================="
    echo "  NFTBan DDoS Protection Status"
    echo "======================================================="
    echo ""
    echo "Global Status: $(nftban_ddos_is_enabled && echo "ENABLED" || echo "DISABLED")"
    echo "Logging: $(nftban_ddos_load_config "DDOS_LOGGING_ENABLED" "1")"
    echo "Email Alerts: $(nftban_ddos_load_config "DDOS_EMAIL_ALERTS" "1")"
    echo ""

    nftban_ddos_synflood_status
    nftban_ddos_connlimit_status
    nftban_ddos_portflood_status
    nftban_ddos_icmp_status

    return 0
}

# =============================================================================
# MODULE INITIALIZATION
# =============================================================================

nftban_ddos_init() {
    # Create directories
    mkdir -p "$(dirname "$NFTBAN_DDOS_LOG")"
    mkdir -p "$(dirname "$NFTBAN_DDOS_STATS_FILE")"

    # Touch files
    touch "$NFTBAN_DDOS_LOG"
    touch "$NFTBAN_DDOS_STATS_FILE"

    nftban_ddos_log "DEBUG" "DDoS protection module initialized"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
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
export -f nftban_ddos_enable_all
export -f nftban_ddos_disable_all
export -f nftban_ddos_status
export -f nftban_ddos_init

# Auto-initialize
nftban_ddos_init

nftban_log_debug "NFTBan DDoS Protection Module loaded"
