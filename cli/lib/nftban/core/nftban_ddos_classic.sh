#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - DDoS Protection Module - CLASSIC MODE
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Standalone DDoS protection using native nftables (no Suricata)
#
# meta:name=nftban_ddos_classic
# meta:type=core
# meta:header=DDoS Protection (Classic)
# meta:version=1.0.0
#
# **Description**
# Pure nftables-based DDoS protection using:
# - Rate limiting meters (SYN flood, ICMP flood, UDP flood)
# - Connection tracking limits (per-service)
# - Auto-tuning based on system resources (optional)
#
# **When to use Classic Mode:**
# - Suricata is NOT installed
# - Minimal resource footprint required
# - Simple rate-limiting is sufficient
# - Edge/embedded systems
#
# meta:depends=bash>=4.0,nftables>=0.9.0
# meta:created_date=2025-12-01
# meta:updated_date=2025-12-01
# =============================================================================

# =============================================================================
# MODULE GUARD
# =============================================================================

[[ -n "${NFTBAN_DDOS_CLASSIC_LOADED:-}" ]] && return 0
readonly NFTBAN_DDOS_CLASSIC_LOADED=1

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

# Load classic mode config
_nftban_ddos_classic_load_config() {
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/classic.conf"

    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file"
    fi

    # Set defaults if not configured
    : "${DDOS_CLASSIC_SYN_RATE:=25/second}"
    : "${DDOS_CLASSIC_SYN_BURST:=50}"
    : "${DDOS_CLASSIC_SSH_CONN_LIMIT:=10}"
    : "${DDOS_CLASSIC_HTTP_CONN_LIMIT:=100}"
    : "${DDOS_CLASSIC_HTTPS_CONN_LIMIT:=100}"
    : "${DDOS_CLASSIC_SMTP_CONN_LIMIT:=20}"
    : "${DDOS_CLASSIC_DNS_CONN_LIMIT:=50}"
    : "${DDOS_CLASSIC_GENERIC_CONN_LIMIT:=50}"
    : "${DDOS_CLASSIC_ICMP_RATE:=10/second}"
    : "${DDOS_CLASSIC_ICMP_BURST:=20}"
    : "${DDOS_CLASSIC_ICMPV6_RATE:=10/second}"
    : "${DDOS_CLASSIC_ICMPV6_BURST:=20}"
    : "${DDOS_CLASSIC_UDP_RATE:=100/second}"
    : "${DDOS_CLASSIC_UDP_BURST:=200}"
    : "${DDOS_CLASSIC_PORT_FLOOD_RATE:=50/second}"
    : "${DDOS_CLASSIC_PORT_FLOOD_BURST:=100}"
    : "${DDOS_CLASSIC_AUTO_TUNE:=true}"
    : "${DDOS_CLASSIC_BAN_DURATION_SHORT:=300}"
    : "${DDOS_CLASSIC_BAN_DURATION_MEDIUM:=1800}"
    : "${DDOS_CLASSIC_BAN_DURATION_LONG:=3600}"
    : "${DDOS_CLASSIC_LOG_FILE:=/var/log/nftban/ddos-classic.log}"
    : "${DDOS_CLASSIC_LOG_LEVEL:=INFO}"
    : "${DDOS_CLASSIC_SYN_METER:=ddos_syn_flood}"
    : "${DDOS_CLASSIC_ICMP_METER:=ddos_icmp_flood}"
    : "${DDOS_CLASSIC_UDP_METER:=ddos_udp_flood}"
    : "${DDOS_CLASSIC_BLOCK_SET:=ddos_blocked}"
}

# =============================================================================
# LOGGING
# =============================================================================

_nftban_ddos_classic_log() {
    local level="$1"
    local message="$2"
    local log_file="${DDOS_CLASSIC_LOG_FILE:-/var/log/nftban/ddos-classic.log}"

    # Create log directory if needed
    mkdir -p "$(dirname "$log_file")" 2>/dev/null

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CLASSIC] [$level] $message" >> "$log_file"
}

# =============================================================================
# AUTO-TUNING (Based on System Resources)
# =============================================================================

_nftban_ddos_classic_auto_tune() {
    if [[ "${DDOS_CLASSIC_AUTO_TUNE}" != "true" ]]; then
        return 0
    fi

    local cores
    cores=$(nproc 2>/dev/null || echo 1)

    local mem_kb
    mem_kb=$(grep MemTotal /proc/meminfo 2>/dev/null | awk '{print $2}')
    local mem_gb=$(( mem_kb / 1024 / 1024 ))

    _nftban_ddos_classic_log "INFO" "Auto-tuning: cores=$cores, mem=${mem_gb}GB"

    # Scale connection limits based on resources
    if [[ $cores -ge 4 && $mem_gb -ge 4 ]]; then
        # High-end system: more generous limits
        DDOS_CLASSIC_SYN_RATE="50/second"
        DDOS_CLASSIC_SYN_BURST="100"
        DDOS_CLASSIC_HTTP_CONN_LIMIT="200"
        DDOS_CLASSIC_HTTPS_CONN_LIMIT="200"
        _nftban_ddos_classic_log "INFO" "Auto-tune: HIGH profile applied"
    elif [[ $cores -ge 2 && $mem_gb -ge 2 ]]; then
        # Medium system: default limits
        _nftban_ddos_classic_log "INFO" "Auto-tune: MEDIUM profile (defaults)"
    else
        # Low-end system: stricter limits
        DDOS_CLASSIC_SYN_RATE="15/second"
        DDOS_CLASSIC_SYN_BURST="30"
        DDOS_CLASSIC_HTTP_CONN_LIMIT="50"
        DDOS_CLASSIC_HTTPS_CONN_LIMIT="50"
        DDOS_CLASSIC_SSH_CONN_LIMIT="5"
        _nftban_ddos_classic_log "INFO" "Auto-tune: LOW profile applied"
    fi
}

# =============================================================================
# NFTABLES HELPERS
# =============================================================================

_nftban_ddos_classic_chain_exists() {
    local table="$1"
    local chain="$2"
    nft list chain $table "$chain" &>/dev/null
}

_nftban_ddos_classic_jump_exists() {
    local table="$1"
    local chain="$2"
    nft list chain $table input 2>/dev/null | grep -q "jump $chain"
}

_nftban_ddos_classic_add_jump_rule() {
    local table="$1"
    local chain="$2"

    # Find position after "ct state established,related accept"
    local handle=""
    local chain_output
    chain_output=$(nft -a list chain $table input 2>/dev/null) || true
    if [[ -n "$chain_output" ]]; then
        handle=$(echo "$chain_output" | grep "ct state established,related accept" | grep -oP 'handle \K[0-9]+' | head -1) || true
    fi

    if [[ -n "$handle" ]]; then
        nft add rule $table input position "$handle" jump "$chain" \
            comment "\"DDoS classic protection\"" 2>/dev/null || true
    else
        nft insert rule $table input jump "$chain" \
            comment "\"DDoS classic protection\"" 2>/dev/null || true
    fi
}

_nftban_ddos_classic_remove_jump_rule() {
    local table="$1"
    local chain="$2"

    local handles
    handles=$(nft -a list chain $table input 2>/dev/null | \
        grep "jump $chain" | grep -oP 'handle \K[0-9]+')

    while IFS= read -r handle; do
        [[ -n "$handle" ]] && nft delete rule $table input handle "$handle" 2>/dev/null || true
    done <<< "$handles"
}

# =============================================================================
# SETUP PROTECTION (IPv4)
# =============================================================================

_nftban_ddos_classic_setup_ipv4() {
    local table="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local chain="${DDOS_NFT_CHAIN:-ddos_protection}"

    echo "  [IPv4] Setting up Classic DDoS protection..."

    # Create chain if not exists
    if ! _nftban_ddos_classic_chain_exists "$table" "$chain"; then
        nft add chain $table "$chain" 2>/dev/null || {
            echo "  [IPv4] ERROR: Failed to create chain"
            return 1
        }
        echo "     Created chain: $chain"
    fi

    # Flush existing rules
    nft flush chain $table "$chain" 2>/dev/null || true

    # --- SYN Flood Protection ---
    nft add rule $table "$chain" \
        tcp flags syn \
        meter "${DDOS_CLASSIC_SYN_METER}" { ip saddr limit rate "${DDOS_CLASSIC_SYN_RATE}" burst "${DDOS_CLASSIC_SYN_BURST}" packets } \
        return \
        comment "\"SYN: rate OK\"" 2>/dev/null || true

    nft add rule $table "$chain" \
        tcp flags syn \
        counter drop \
        comment "\"SYN flood: rate exceeded\"" 2>/dev/null || true

    # --- Connection Limits per Service ---
    # SSH
    nft add rule $table "$chain" \
        tcp dport 22 ct state new \
        ct count over "${DDOS_CLASSIC_SSH_CONN_LIMIT}" \
        counter drop \
        comment "\"SSH: max ${DDOS_CLASSIC_SSH_CONN_LIMIT} conn/IP\"" 2>/dev/null || true

    # HTTP
    nft add rule $table "$chain" \
        tcp dport 80 ct state new \
        ct count over "${DDOS_CLASSIC_HTTP_CONN_LIMIT}" \
        counter drop \
        comment "\"HTTP: max ${DDOS_CLASSIC_HTTP_CONN_LIMIT} conn/IP\"" 2>/dev/null || true

    # HTTPS
    nft add rule $table "$chain" \
        tcp dport 443 ct state new \
        ct count over "${DDOS_CLASSIC_HTTPS_CONN_LIMIT}" \
        counter drop \
        comment "\"HTTPS: max ${DDOS_CLASSIC_HTTPS_CONN_LIMIT} conn/IP\"" 2>/dev/null || true

    # SMTP
    nft add rule $table "$chain" \
        tcp dport 25 ct state new \
        ct count over "${DDOS_CLASSIC_SMTP_CONN_LIMIT}" \
        counter drop \
        comment "\"SMTP: max ${DDOS_CLASSIC_SMTP_CONN_LIMIT} conn/IP\"" 2>/dev/null || true

    # --- ICMP Rate Limiting ---
    nft add rule $table "$chain" \
        ip protocol icmp \
        meter "${DDOS_CLASSIC_ICMP_METER}" { ip saddr limit rate "${DDOS_CLASSIC_ICMP_RATE}" burst "${DDOS_CLASSIC_ICMP_BURST}" packets } \
        return \
        comment "\"ICMP: rate OK\"" 2>/dev/null || true

    nft add rule $table "$chain" \
        ip protocol icmp \
        counter drop \
        comment "\"ICMP flood: rate exceeded\"" 2>/dev/null || true

    # --- UDP Flood Protection ---
    nft add rule $table "$chain" \
        ip protocol udp \
        meter "${DDOS_CLASSIC_UDP_METER}" { ip saddr limit rate "${DDOS_CLASSIC_UDP_RATE}" burst "${DDOS_CLASSIC_UDP_BURST}" packets } \
        return \
        comment "\"UDP: rate OK\"" 2>/dev/null || true

    nft add rule $table "$chain" \
        ip protocol udp \
        counter drop \
        comment "\"UDP flood: rate exceeded\"" 2>/dev/null || true

    # --- Return to input chain ---
    nft add rule $table "$chain" return 2>/dev/null || true

    # Add jump rule if not exists
    if ! _nftban_ddos_classic_jump_exists "$table" "$chain"; then
        _nftban_ddos_classic_add_jump_rule "$table" "$chain"
        echo "     Added jump rule to input chain"
    fi

    echo "  [IPv4] Classic DDoS protection enabled"
    _nftban_ddos_classic_log "INFO" "IPv4 classic protection enabled"

    return 0
}

# =============================================================================
# SETUP PROTECTION (IPv6)
# =============================================================================

_nftban_ddos_classic_setup_ipv6() {
    local table="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_NFT_CHAIN:-ddos_protection}"

    # Check if IPv6 table exists
    if ! nft list table $table &>/dev/null; then
        echo "  [IPv6] Table not found, skipping"
        return 0
    fi

    echo "  [IPv6] Setting up Classic DDoS protection..."

    # Create chain if not exists
    if ! _nftban_ddos_classic_chain_exists "$table" "$chain"; then
        nft add chain $table "$chain" 2>/dev/null || {
            echo "  [IPv6] ERROR: Failed to create chain"
            return 1
        }
        echo "     Created chain: $chain"
    fi

    # Flush existing rules
    nft flush chain $table "$chain" 2>/dev/null || true

    # --- SYN Flood Protection ---
    nft add rule $table "$chain" \
        tcp flags syn \
        meter "${DDOS_CLASSIC_SYN_METER}6" { ip6 saddr limit rate "${DDOS_CLASSIC_SYN_RATE}" burst "${DDOS_CLASSIC_SYN_BURST}" packets } \
        return \
        comment "\"SYN: rate OK\"" 2>/dev/null || true

    nft add rule $table "$chain" \
        tcp flags syn \
        counter drop \
        comment "\"SYN flood: rate exceeded\"" 2>/dev/null || true

    # --- Connection Limits ---
    nft add rule $table "$chain" \
        tcp dport 22 ct state new \
        ct count over "${DDOS_CLASSIC_SSH_CONN_LIMIT}" \
        counter drop \
        comment "\"SSH: max ${DDOS_CLASSIC_SSH_CONN_LIMIT} conn/IP\"" 2>/dev/null || true

    nft add rule $table "$chain" \
        tcp dport { 80, 443 } ct state new \
        ct count over "${DDOS_CLASSIC_HTTP_CONN_LIMIT}" \
        counter drop \
        comment "\"HTTP(S): max ${DDOS_CLASSIC_HTTP_CONN_LIMIT} conn/IP\"" 2>/dev/null || true

    # --- ICMPv6 Rate Limiting ---
    nft add rule $table "$chain" \
        meta l4proto icmpv6 \
        meter "${DDOS_CLASSIC_ICMP_METER}6" { ip6 saddr limit rate "${DDOS_CLASSIC_ICMPV6_RATE}" burst "${DDOS_CLASSIC_ICMPV6_BURST}" packets } \
        return \
        comment "\"ICMPv6: rate OK\"" 2>/dev/null || true

    nft add rule $table "$chain" \
        meta l4proto icmpv6 \
        counter drop \
        comment "\"ICMPv6 flood: rate exceeded\"" 2>/dev/null || true

    # --- Return ---
    nft add rule $table "$chain" return 2>/dev/null || true

    # Add jump rule
    if ! _nftban_ddos_classic_jump_exists "$table" "$chain"; then
        _nftban_ddos_classic_add_jump_rule "$table" "$chain"
        echo "     Added jump rule to input chain"
    fi

    echo "  [IPv6] Classic DDoS protection enabled"
    _nftban_ddos_classic_log "INFO" "IPv6 classic protection enabled"

    return 0
}

# =============================================================================
# REMOVE PROTECTION
# =============================================================================

_nftban_ddos_classic_remove_ipv4() {
    local table="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local chain="${DDOS_NFT_CHAIN:-ddos_protection}"

    echo "  [IPv4] Removing Classic DDoS protection..."

    # Remove jump rule first
    _nftban_ddos_classic_remove_jump_rule "$table" "$chain"

    # Delete chain
    if _nftban_ddos_classic_chain_exists "$table" "$chain"; then
        nft flush chain $table "$chain" 2>/dev/null || true
        nft delete chain $table "$chain" 2>/dev/null || true
        echo "     Deleted chain: $chain"
    fi

    _nftban_ddos_classic_log "INFO" "IPv4 classic protection disabled"
}

_nftban_ddos_classic_remove_ipv6() {
    local table="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_NFT_CHAIN:-ddos_protection}"

    if ! nft list table $table &>/dev/null; then
        return 0
    fi

    echo "  [IPv6] Removing Classic DDoS protection..."

    _nftban_ddos_classic_remove_jump_rule "$table" "$chain"

    if _nftban_ddos_classic_chain_exists "$table" "$chain"; then
        nft flush chain $table "$chain" 2>/dev/null || true
        nft delete chain $table "$chain" 2>/dev/null || true
        echo "     Deleted chain: $chain"
    fi

    _nftban_ddos_classic_log "INFO" "IPv6 classic protection disabled"
}

# =============================================================================
# PUBLIC API
# =============================================================================

nftban_ddos_classic_enable() {
    _nftban_ddos_classic_load_config
    _nftban_ddos_classic_auto_tune

    echo ""
    echo "Enabling Classic DDoS Protection..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    _nftban_ddos_classic_setup_ipv4
    _nftban_ddos_classic_setup_ipv6

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Thresholds:"
    echo "  SYN Rate:    ${DDOS_CLASSIC_SYN_RATE} burst ${DDOS_CLASSIC_SYN_BURST}"
    echo "  SSH Conn:    max ${DDOS_CLASSIC_SSH_CONN_LIMIT}/IP"
    echo "  HTTP Conn:   max ${DDOS_CLASSIC_HTTP_CONN_LIMIT}/IP"
    echo "  ICMP Rate:   ${DDOS_CLASSIC_ICMP_RATE} burst ${DDOS_CLASSIC_ICMP_BURST}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    return 0
}

nftban_ddos_classic_disable() {
    _nftban_ddos_classic_load_config

    echo ""
    echo "Disabling Classic DDoS Protection..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    _nftban_ddos_classic_remove_ipv4
    _nftban_ddos_classic_remove_ipv6

    echo ""
    echo "Classic DDoS protection disabled"
    echo ""

    return 0
}

nftban_ddos_classic_status() {
    _nftban_ddos_classic_load_config

    local table_v4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_v6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_NFT_CHAIN:-ddos_protection}"

    echo ""
    echo "Classic DDoS Protection Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # IPv4 Status
    if _nftban_ddos_classic_chain_exists "$table_v4" "$chain"; then
        if _nftban_ddos_classic_jump_exists "$table_v4" "$chain"; then
            echo "  IPv4: ENABLED (chain + jump active)"
        else
            echo "  IPv4: PARTIAL (chain exists, no jump)"
        fi
    else
        echo "  IPv4: DISABLED"
    fi

    # IPv6 Status
    if nft list table $table_v6 &>/dev/null; then
        if _nftban_ddos_classic_chain_exists "$table_v6" "$chain"; then
            if _nftban_ddos_classic_jump_exists "$table_v6" "$chain"; then
                echo "  IPv6: ENABLED (chain + jump active)"
            else
                echo "  IPv6: PARTIAL (chain exists, no jump)"
            fi
        else
            echo "  IPv6: DISABLED"
        fi
    else
        echo "  IPv6: N/A (table not found)"
    fi

    echo ""
    echo "Configuration:"
    echo "  SYN Rate:    ${DDOS_CLASSIC_SYN_RATE} burst ${DDOS_CLASSIC_SYN_BURST}"
    echo "  SSH Conn:    max ${DDOS_CLASSIC_SSH_CONN_LIMIT}/IP"
    echo "  HTTP Conn:   max ${DDOS_CLASSIC_HTTP_CONN_LIMIT}/IP"
    echo "  ICMP Rate:   ${DDOS_CLASSIC_ICMP_RATE} burst ${DDOS_CLASSIC_ICMP_BURST}"
    echo "  Auto-tune:   ${DDOS_CLASSIC_AUTO_TUNE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    return 0
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_ddos_classic_enable
export -f nftban_ddos_classic_disable
export -f nftban_ddos_classic_status
