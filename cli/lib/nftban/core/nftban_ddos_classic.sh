#!/usr/bin/env bash
# shellcheck disable=SC1083  # Braces in nftables syntax are literal, not bash
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
# LOAD IPC/FRAGMENT LIBRARIES (for single-writer architecture)
# =============================================================================
# These libraries provide fragment rendering and IPC communication with nftband

# Bootstrap path (may be readonly from nftban.conf)
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_fragment.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true

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
    local mem_gb
    mem_gb=$(( mem_kb / 1024 / 1024 ))

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

# Check if fragment/IPC libraries are available
_nftban_ddos_classic_has_ipc() {
    type -t nft_fragment_render_ddos_classic &>/dev/null && \
    type -t nft_fragment_apply &>/dev/null
}

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

# =============================================================================
# SETUP PROTECTION (Fragment+IPC approach)
# =============================================================================

_nftban_ddos_classic_setup_via_ipc() {
    local table_v4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local chain="${DDOS_NFT_CHAIN:-ddos_protection}"

    echo "  Setting up Classic DDoS protection via IPC..."

    # Render the fragment with all config values
    local fragment_path
    fragment_path=$(nft_fragment_render_ddos_classic) || {
        echo "  ERROR: Failed to render fragment"
        return 1
    }
    echo "     Fragment: $fragment_path"

    # Apply via IPC
    if ! nft_fragment_apply "$fragment_path"; then
        echo "  ERROR: Failed to apply fragment via IPC"
        return 1
    fi
    echo "     Applied DDoS protection rules"

    # Add jump rules if not present
    if ! _nftban_ddos_classic_jump_exists "$table_v4" "$chain"; then
        local jump_path
        jump_path=$(nft_fragment_render_ddos_classic_jump) || {
            echo "  ERROR: Failed to render jump fragment"
            return 1
        }
        if nft_fragment_apply "$jump_path"; then
            echo "     Added jump rules to input chains"
        fi
    else
        echo "     Jump rules already present"
    fi

    _nftban_ddos_classic_log "INFO" "Classic protection enabled via IPC"
    return 0
}

# =============================================================================
# REMOVE PROTECTION (Fragment+IPC approach)
# =============================================================================

_nftban_ddos_classic_remove_via_ipc() {
    echo "  Removing Classic DDoS protection via IPC..."

    # Render the cleanup fragment
    local cleanup_path
    cleanup_path=$(nft_fragment_render_ddos_classic_cleanup) || {
        echo "  ERROR: Failed to render cleanup fragment"
        return 1
    }

    # Apply via IPC (this flushes the chains)
    if nft_fragment_apply "$cleanup_path"; then
        echo "     Flushed DDoS protection chains"
    else
        echo "  WARNING: Failed to apply cleanup fragment"
    fi

    _nftban_ddos_classic_log "INFO" "Classic protection disabled via IPC"
    return 0
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

    # Use IPC if available (single-writer architecture)
    if _nftban_ddos_classic_has_ipc; then
        _nftban_ddos_classic_setup_via_ipc || return 1
    else
        echo "  WARNING: IPC not available, DDoS classic cannot be enabled"
        echo "  Ensure nftband daemon is running and nft_fragment.sh is loaded"
        return 1
    fi

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

    # Use IPC if available (single-writer architecture)
    if _nftban_ddos_classic_has_ipc; then
        _nftban_ddos_classic_remove_via_ipc || return 1
    else
        echo "  WARNING: IPC not available, cannot disable properly"
        return 1
    fi

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
