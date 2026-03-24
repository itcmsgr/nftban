#!/usr/bin/env bash
# shellcheck disable=SC1083  # Braces in nftables syntax are literal, not bash
# =============================================================================
# NFTBan v1.0 - DDoS Protection Module - CLASSIC MODE
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Standalone DDoS protection using native nftables (no Suricata)
#
# meta:name="nftban_ddos_classic"
# meta:type="core"
# meta:header="DDoS Protection (Classic)"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Pure nftables-based DDoS protection with rate limiting"
# meta:input="IPC commands, nftables metrics"
# meta:output="nftables rules, log entries"
# meta:depends="bash>=4.0,nftables>=0.9.0"
# meta:inventory.files="${NFTBAN_LOG_DIR}/ddos-classic.log"
# meta:inventory.binaries="nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files="/etc/nftban/conf.d/ddos/classic.conf"
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# meta:created_date="2025-12-01"
# meta:updated_date="2026-02-07"
# =============================================================================

set -Eeuo pipefail

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
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_timestamp.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_file_utils.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/lib/nftban_alert_throttle.sh" 2>/dev/null || true

# =============================================================================
# CONFIGURATION LOADING
# =============================================================================

# Load classic mode config
_nftban_ddos_classic_load_config() {
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/ddos/classic.conf"
    local local_config="${config_file%.conf}.conf.local"

    # Load base config
    if [[ -f "$config_file" ]]; then
        # shellcheck source=/dev/null
        source "$config_file" || true
    fi

    # Load local overrides (BUG-003 fix: was missing .local support)
    if [[ -f "$local_config" ]]; then
        # shellcheck source=/dev/null
        source "$local_config" || true
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
    : "${DDOS_CLASSIC_LOG_FILE:=${NFTBAN_LOG_DIR:-/var/log/nftban}/ddos-classic.log}"
    : "${DDOS_CLASSIC_LOG_LEVEL:=INFO}"
    : "${DDOS_CLASSIC_SYN_METER:=ddos_syn_flood}"
    : "${DDOS_CLASSIC_ICMP_METER:=ddos_icmp_flood}"
    : "${DDOS_CLASSIC_UDP_METER:=ddos_udp_flood}"
    : "${DDOS_CLASSIC_BLOCK_SET:=ddos_blocked}"

    # SYNPROXY defaults
    : "${DDOS_SYNPROXY_ENABLED:=true}"
    : "${DDOS_SYNPROXY_MSS:=1460}"
    : "${DDOS_SYNPROXY_WSCALE:=7}"
    : "${DDOS_SYNPROXY_SACK:=true}"
    : "${DDOS_SYNPROXY_TSTAMP:=true}"
    : "${DDOS_SYNPROXY_PORTS:=80,443,25,587,993,995,3306,5432,6379,27017}"
    : "${DDOS_SYNPROXY_CHAIN:=ddos_synproxy}"
    : "${DDOS_SYNPROXY_LOG_NEW:=false}"
    : "${DDOS_SYNPROXY_LOG_PREFIX:=NFTBAN_SYNPROXY:}"

    # Sanity check defaults (Stage 3 - packet validation)
    : "${DDOS_SANITY_CHAIN:=ddos_sanity}"
    : "${DDOS_SANITY_LOG_INVALID:=false}"
    : "${DDOS_SANITY_LOG_PREFIX:=NFTBAN_SANITY:}"

    # Prefix aggregation defaults (Stage 1.5 - distributed attack detection)
    : "${DDOS_PREFIX_ENABLED:=true}"
    : "${DDOS_PREFIX_IPV4_MASK:=/24}"
    : "${DDOS_PREFIX_IPV6_MASK:=/64}"
    : "${DDOS_PREFIX_SYN_RATE:=100/second}"
    : "${DDOS_PREFIX_SYN_BURST:=200}"
    : "${DDOS_PREFIX_CONN_RATE:=500/second}"
    : "${DDOS_PREFIX_CONN_BURST:=1000}"
    : "${DDOS_PREFIX_METER_SYN:=ddos_prefix_syn}"
    : "${DDOS_PREFIX_METER_CONN:=ddos_prefix_conn}"
    : "${DDOS_PREFIX_CHAIN:=ddos_prefix}"
}

# =============================================================================
# LOGGING
# =============================================================================

_nftban_ddos_classic_log() {
    local level="$1"
    local message="$2"
    local log_file="${DDOS_CLASSIC_LOG_FILE:-${NFTBAN_LOG_DIR:-/var/log/nftban}/ddos-classic.log}"

    # Create log directory if needed
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || return 1

    # Use timestamp library with graceful fallback
    local timestamp
    if type -t nftban_timestamp_log &>/dev/null; then
        timestamp=$(nftban_timestamp_log)
    else
        timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"
    fi

    echo "${timestamp} [CLASSIC] [$level] $message" >> "$log_file"
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

# Check if SYNPROXY fragment functions are available
_nftban_ddos_synproxy_has_ipc() {
    type -t nft_fragment_render_synproxy &>/dev/null && \
    type -t nft_fragment_render_synproxy_raw &>/dev/null && \
    type -t nft_fragment_apply &>/dev/null
}

# Check if sanity check fragment functions are available
_nftban_ddos_sanity_has_ipc() {
    type -t nft_fragment_render_ddos_sanity &>/dev/null && \
    type -t nft_fragment_apply &>/dev/null
}

# Check if prefix aggregation fragment functions are available
_nftban_ddos_prefix_has_ipc() {
    type -t nft_fragment_render_ddos_prefix &>/dev/null && \
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

_nftban_ddos_synproxy_chain_exists() {
    local table="$1"
    local chain="${DDOS_SYNPROXY_CHAIN:-ddos_synproxy}"
    nft list chain $table "$chain" &>/dev/null
}

_nftban_ddos_sanity_chain_exists() {
    local table="$1"
    local chain="${DDOS_SANITY_CHAIN:-ddos_sanity}"
    nft list chain $table "$chain" &>/dev/null
}

_nftban_ddos_prefix_chain_exists() {
    local table="$1"
    local chain="${DDOS_PREFIX_CHAIN:-ddos_prefix}"
    nft list chain $table "$chain" &>/dev/null
}

# =============================================================================
# SANITY CHECK SETUP (Fragment+IPC approach) - Stage 3
# =============================================================================

_nftban_ddos_sanity_setup_via_ipc() {
    if ! _nftban_ddos_sanity_has_ipc; then
        echo "  WARNING: Sanity check fragment functions not available"
        return 1
    fi

    local table_v4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local chain="${DDOS_SANITY_CHAIN:-ddos_sanity}"

    echo "  Setting up sanity check protection (Stage 3)..."

    # Render and apply sanity check fragment
    local fragment_path
    fragment_path=$(nft_fragment_render_ddos_sanity) || {
        echo "  ERROR: Failed to render sanity check fragment"
        return 1
    }
    echo "     Fragment: $fragment_path"

    if ! nft_fragment_apply "$fragment_path"; then
        echo "  ERROR: Failed to apply sanity check rules"
        return 1
    fi
    echo "     Applied sanity check rules"

    # Add jump rules if not present
    if ! _nftban_ddos_classic_jump_exists "$table_v4" "$chain"; then
        local jump_path
        jump_path=$(nft_fragment_render_ddos_sanity_jump) || {
            echo "  ERROR: Failed to render sanity check jump fragment"
            return 1
        }
        if nft_fragment_apply "$jump_path"; then
            echo "     Added sanity check jump rules to input chains"
        fi
    else
        echo "     Sanity check jump rules already present"
    fi

    _nftban_ddos_classic_log "INFO" "Sanity check protection enabled (log_invalid=${DDOS_SANITY_LOG_INVALID})"
    return 0
}

_nftban_ddos_sanity_remove_via_ipc() {
    if ! _nftban_ddos_sanity_has_ipc; then
        return 0
    fi

    echo "  Removing sanity check protection..."

    local cleanup_path
    cleanup_path=$(nft_fragment_render_ddos_sanity_cleanup) || {
        echo "  ERROR: Failed to render sanity check cleanup fragment"
        return 1
    }

    if nft_fragment_apply "$cleanup_path"; then
        echo "     Flushed sanity check chains"
    else
        echo "  WARNING: Failed to apply sanity check cleanup"
    fi

    _nftban_ddos_classic_log "INFO" "Sanity check protection disabled"
    return 0
}

# =============================================================================
# SYNPROXY SETUP (Fragment+IPC approach)
# =============================================================================

_nftban_ddos_synproxy_setup_via_ipc() {
    if [[ "${DDOS_SYNPROXY_ENABLED}" != "true" ]]; then
        echo "  SYNPROXY: Disabled (DDOS_SYNPROXY_ENABLED=false)"
        return 0
    fi

    if ! _nftban_ddos_synproxy_has_ipc; then
        echo "  WARNING: SYNPROXY fragment functions not available"
        return 1
    fi

    local table_v4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local chain="${DDOS_SYNPROXY_CHAIN:-ddos_synproxy}"

    echo "  Setting up SYNPROXY protection..."

    # Step 1: Apply raw table rules (notrack for SYN packets)
    local raw_path
    raw_path=$(nft_fragment_render_synproxy_raw) || {
        echo "  ERROR: Failed to render SYNPROXY raw fragment"
        return 1
    }
    echo "     Raw fragment: $raw_path"

    if ! nft_fragment_apply "$raw_path"; then
        echo "  ERROR: Failed to apply SYNPROXY raw rules"
        return 1
    fi
    echo "     Applied SYNPROXY notrack rules"

    # Step 2: Apply SYNPROXY chain rules
    local fragment_path
    fragment_path=$(nft_fragment_render_synproxy) || {
        echo "  ERROR: Failed to render SYNPROXY fragment"
        return 1
    }
    echo "     Fragment: $fragment_path"

    if ! nft_fragment_apply "$fragment_path"; then
        echo "  ERROR: Failed to apply SYNPROXY rules"
        return 1
    fi
    echo "     Applied SYNPROXY protection rules"

    # Step 3: Add jump rules if not present
    if ! _nftban_ddos_classic_jump_exists "$table_v4" "$chain"; then
        local jump_path
        jump_path=$(nft_fragment_render_synproxy_jump) || {
            echo "  ERROR: Failed to render SYNPROXY jump fragment"
            return 1
        }
        if nft_fragment_apply "$jump_path"; then
            echo "     Added SYNPROXY jump rules to input chains"
        fi
    else
        echo "     SYNPROXY jump rules already present"
    fi

    _nftban_ddos_classic_log "INFO" "SYNPROXY protection enabled (MSS=${DDOS_SYNPROXY_MSS}, WSCALE=${DDOS_SYNPROXY_WSCALE})"
    return 0
}

_nftban_ddos_synproxy_remove_via_ipc() {
    if ! _nftban_ddos_synproxy_has_ipc; then
        return 0
    fi

    echo "  Removing SYNPROXY protection..."

    local cleanup_path
    cleanup_path=$(nft_fragment_render_synproxy_cleanup) || {
        echo "  ERROR: Failed to render SYNPROXY cleanup fragment"
        return 1
    }

    if nft_fragment_apply "$cleanup_path"; then
        echo "     Flushed SYNPROXY chains and raw rules"
    else
        echo "  WARNING: Failed to apply SYNPROXY cleanup"
    fi

    _nftban_ddos_classic_log "INFO" "SYNPROXY protection disabled"
    return 0
}

# =============================================================================
# PREFIX AGGREGATION SETUP (Fragment+IPC approach) - Stage 1.5
# =============================================================================

_nftban_ddos_prefix_setup_via_ipc() {
    if [[ "${DDOS_PREFIX_ENABLED}" != "true" ]]; then
        echo "  Prefix Aggregation: Disabled (DDOS_PREFIX_ENABLED=false)"
        return 0
    fi

    if ! _nftban_ddos_prefix_has_ipc; then
        echo "  WARNING: Prefix aggregation fragment functions not available"
        return 1
    fi

    local table_v4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_v6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_PREFIX_CHAIN:-ddos_prefix}"
    local syn_meter="${DDOS_PREFIX_METER_SYN:-ddos_prefix_syn}"
    local conn_meter="${DDOS_PREFIX_METER_CONN:-ddos_prefix_conn}"

    echo "  Setting up prefix aggregation protection (Stage 1.5)..."

    # Clean up stale meters from previous enable (flush chain first, then delete meters)
    # Meters are stored as sets internally — must flush referencing rules before deleting
    nft flush chain $table_v4 "$chain" 2>/dev/null || true
    nft delete set $table_v4 "$syn_meter" 2>/dev/null || true
    nft delete set $table_v4 "$conn_meter" 2>/dev/null || true
    nft flush chain $table_v6 "$chain" 2>/dev/null || true
    nft delete set $table_v6 "${syn_meter}6" 2>/dev/null || true
    nft delete set $table_v6 "${conn_meter}6" 2>/dev/null || true

    # Render and apply prefix aggregation fragment
    local fragment_path
    fragment_path=$(nft_fragment_render_ddos_prefix) || {
        echo "  ERROR: Failed to render prefix aggregation fragment"
        return 1
    }
    echo "     Fragment: $fragment_path"

    if ! nft_fragment_apply "$fragment_path"; then
        echo "  ERROR: Failed to apply prefix aggregation rules"
        return 1
    fi
    echo "     Applied prefix aggregation rules"

    # Add jump rules if not present
    if ! _nftban_ddos_classic_jump_exists "$table_v4" "$chain"; then
        local jump_path
        jump_path=$(nft_fragment_render_ddos_prefix_jump) || {
            echo "  ERROR: Failed to render prefix aggregation jump fragment"
            return 1
        }
        if nft_fragment_apply "$jump_path"; then
            echo "     Added prefix aggregation jump rules to input chains"
        fi
    else
        echo "     Prefix aggregation jump rules already present"
    fi

    _nftban_ddos_classic_log "INFO" "Prefix aggregation enabled (IPv4=${DDOS_PREFIX_IPV4_MASK}, IPv6=${DDOS_PREFIX_IPV6_MASK})"
    return 0
}

_nftban_ddos_prefix_remove_via_ipc() {
    if ! _nftban_ddos_prefix_has_ipc; then
        return 0
    fi

    echo "  Removing prefix aggregation protection..."

    local cleanup_path
    cleanup_path=$(nft_fragment_render_ddos_prefix_cleanup) || {
        echo "  ERROR: Failed to render prefix aggregation cleanup fragment"
        return 1
    }

    if nft_fragment_apply "$cleanup_path"; then
        echo "     Flushed prefix aggregation chains"
    else
        echo "  WARNING: Failed to apply prefix aggregation cleanup"
    fi

    _nftban_ddos_classic_log "INFO" "Prefix aggregation protection disabled"
    return 0
}

# =============================================================================
# SETUP PROTECTION (Fragment+IPC approach)
# =============================================================================

_nftban_ddos_classic_setup_via_ipc() {
    local table_v4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_v6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_NFT_CHAIN:-ddos_protection}"
    local syn_meter="${DDOS_CLASSIC_SYN_METER:-ddos_syn_flood}"
    local icmp_meter="${DDOS_CLASSIC_ICMP_METER:-ddos_icmp_flood}"
    local udp_meter="${DDOS_CLASSIC_UDP_METER:-ddos_udp_flood}"

    echo "  Setting up Classic DDoS protection via IPC..."

    # Clean up stale meters from previous enable (flush chain first, then delete meters)
    nft flush chain $table_v4 "$chain" 2>/dev/null || true
    nft delete set $table_v4 "$syn_meter" 2>/dev/null || true
    nft delete set $table_v4 "$icmp_meter" 2>/dev/null || true
    nft delete set $table_v4 "$udp_meter" 2>/dev/null || true
    nft flush chain $table_v6 "$chain" 2>/dev/null || true
    nft delete set $table_v6 "${syn_meter}6" 2>/dev/null || true
    nft delete set $table_v6 "${icmp_meter}6" 2>/dev/null || true

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
        # Stage 3: Sanity checks (drop invalid/malformed packets)
        # Applied FIRST to filter garbage before any other processing
        _nftban_ddos_sanity_setup_via_ipc || {
            echo "  WARNING: Sanity check setup failed, continuing without packet validation"
        }

        echo ""

        # Stage 1: SYNPROXY (kernel-level SYN flood protection)
        # Applied BEFORE rate limiting for maximum efficiency
        _nftban_ddos_synproxy_setup_via_ipc || {
            echo "  WARNING: SYNPROXY setup failed, continuing with classic protection"
        }

        echo ""

        # Stage 1.5: Prefix Aggregation (distributed attack detection)
        # Tracks by /24 (IPv4) and /64 (IPv6) to detect botnets
        _nftban_ddos_prefix_setup_via_ipc || {
            echo "  WARNING: Prefix aggregation setup failed, continuing without subnet-level protection"
        }

        echo ""

        # Stage 2: Classic rate limiting and connection limits
        _nftban_ddos_classic_setup_via_ipc || return 1
    else
        echo "  WARNING: IPC not available, DDoS classic cannot be enabled"
        echo "  Ensure nftband daemon is running and nft_fragment.sh is loaded"
        return 1
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Protection Stages:"
    if [[ "${DDOS_SYNPROXY_ENABLED}" == "true" ]]; then
        echo "  Stage 1 - SYNPROXY:"
        echo "    MSS:       ${DDOS_SYNPROXY_MSS}"
        echo "    WSCALE:    ${DDOS_SYNPROXY_WSCALE}"
        echo "    SACK:      ${DDOS_SYNPROXY_SACK}"
        echo "    Timestamp: ${DDOS_SYNPROXY_TSTAMP}"
        echo "    Ports:     ${DDOS_SYNPROXY_PORTS}"
        echo ""
    fi
    if [[ "${DDOS_PREFIX_ENABLED}" == "true" ]]; then
        echo "  Stage 1.5 - Prefix Aggregation:"
        echo "    IPv4 Mask: ${DDOS_PREFIX_IPV4_MASK}"
        echo "    IPv6 Mask: ${DDOS_PREFIX_IPV6_MASK}"
        echo "    SYN Rate:  ${DDOS_PREFIX_SYN_RATE} burst ${DDOS_PREFIX_SYN_BURST}"
        echo "    Conn Rate: ${DDOS_PREFIX_CONN_RATE} burst ${DDOS_PREFIX_CONN_BURST}"
        echo ""
    fi
    echo "  Stage 2 - Rate Limiting:"
    echo "    SYN Rate:  ${DDOS_CLASSIC_SYN_RATE} burst ${DDOS_CLASSIC_SYN_BURST}"
    echo "    SSH Conn:  max ${DDOS_CLASSIC_SSH_CONN_LIMIT}/IP"
    echo "    HTTP Conn: max ${DDOS_CLASSIC_HTTP_CONN_LIMIT}/IP"
    echo "    ICMP Rate: ${DDOS_CLASSIC_ICMP_RATE} burst ${DDOS_CLASSIC_ICMP_BURST}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    return 0
}

nftban_ddos_classic_disable() {
    # Prevent duplicate disable calls (causes double logging)
    [[ -n "${_NFTBAN_DDOS_CLASSIC_DISABLED:-}" ]] && return 0
    _NFTBAN_DDOS_CLASSIC_DISABLED=1

    _nftban_ddos_classic_load_config

    echo ""
    echo "Disabling Classic DDoS Protection..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Use IPC if available (single-writer architecture)
    if _nftban_ddos_classic_has_ipc; then
        # Remove in reverse order of enable

        # Remove classic rate limiting first
        _nftban_ddos_classic_remove_via_ipc || true

        # Remove prefix aggregation
        _nftban_ddos_prefix_remove_via_ipc || true

        # Then remove SYNPROXY
        _nftban_ddos_synproxy_remove_via_ipc || true

        # Finally remove sanity checks (applied first, removed last)
        _nftban_ddos_sanity_remove_via_ipc || true
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
    local synproxy_chain="${DDOS_SYNPROXY_CHAIN:-ddos_synproxy}"
    local sanity_chain="${DDOS_SANITY_CHAIN:-ddos_sanity}"
    local prefix_chain="${DDOS_PREFIX_CHAIN:-ddos_prefix}"

    echo ""
    echo "Classic DDoS Protection Status"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Sanity Check Status (Stage 3 - applied first)
    echo ""
    echo "Stage 3 - Sanity Checks (Packet Validation):"
    if _nftban_ddos_sanity_chain_exists "$table_v4"; then
        if _nftban_ddos_classic_jump_exists "$table_v4" "$sanity_chain"; then
            echo "  IPv4: ENABLED (chain + jump active)"
        else
            echo "  IPv4: PARTIAL (chain exists but not active — run 'nftban ddos enable')"
        fi
        if _nftban_ddos_sanity_chain_exists "$table_v6"; then
            if _nftban_ddos_classic_jump_exists "$table_v6" "$sanity_chain"; then
                echo "  IPv6: ENABLED (chain + jump active)"
            else
                echo "  IPv6: PARTIAL (chain exists but not active — run 'nftban ddos enable')"
            fi
        else
            echo "  IPv6: DISABLED"
        fi
    else
        echo "  IPv4: DISABLED (chain not found)"
        echo "  IPv6: DISABLED"
    fi

    # SYNPROXY Status
    echo ""
    echo "Stage 1 - SYNPROXY:"
    if [[ "${DDOS_SYNPROXY_ENABLED}" != "true" ]]; then
        echo "  Status: DISABLED (config)"
    elif _nftban_ddos_synproxy_chain_exists "$table_v4"; then
        if _nftban_ddos_classic_jump_exists "$table_v4" "$synproxy_chain"; then
            echo "  IPv4: ENABLED (chain + jump active)"
        else
            echo "  IPv4: PARTIAL (chain exists but not active — run 'nftban ddos enable')"
        fi
        if _nftban_ddos_synproxy_chain_exists "$table_v6"; then
            if _nftban_ddos_classic_jump_exists "$table_v6" "$synproxy_chain"; then
                echo "  IPv6: ENABLED (chain + jump active)"
            else
                echo "  IPv6: PARTIAL (chain exists but not active — run 'nftban ddos enable')"
            fi
        else
            echo "  IPv6: DISABLED"
        fi
    else
        echo "  IPv4: DISABLED (chain not found)"
        echo "  IPv6: DISABLED"
    fi

    # Prefix Aggregation Status (Stage 1.5)
    echo ""
    echo "Stage 1.5 - Prefix Aggregation:"
    if [[ "${DDOS_PREFIX_ENABLED}" != "true" ]]; then
        echo "  Status: DISABLED (config)"
    elif _nftban_ddos_prefix_chain_exists "$table_v4"; then
        if _nftban_ddos_classic_jump_exists "$table_v4" "$prefix_chain"; then
            echo "  IPv4: ENABLED (chain + jump active)"
        else
            echo "  IPv4: PARTIAL (chain exists but not active — run 'nftban ddos enable')"
        fi
        if _nftban_ddos_prefix_chain_exists "$table_v6"; then
            if _nftban_ddos_classic_jump_exists "$table_v6" "$prefix_chain"; then
                echo "  IPv6: ENABLED (chain + jump active)"
            else
                echo "  IPv6: PARTIAL (chain exists but not active — run 'nftban ddos enable')"
            fi
        else
            echo "  IPv6: DISABLED"
        fi
    else
        echo "  IPv4: DISABLED (chain not found)"
        echo "  IPv6: DISABLED"
    fi

    # Classic Rate Limiting Status
    echo ""
    echo "Stage 2 - Rate Limiting:"
    if _nftban_ddos_classic_chain_exists "$table_v4" "$chain"; then
        if _nftban_ddos_classic_jump_exists "$table_v4" "$chain"; then
            echo "  IPv4: ENABLED (chain + jump active)"
        else
            echo "  IPv4: PARTIAL (chain exists but not active — run 'nftban ddos enable')"
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
                echo "  IPv6: PARTIAL (chain exists but not active — run 'nftban ddos enable')"
            fi
        else
            echo "  IPv6: DISABLED"
        fi
    else
        echo "  IPv6: N/A (table not found)"
    fi

    echo ""
    echo "Configuration:"
    echo "  SYNPROXY:"
    echo "    Enabled:   ${DDOS_SYNPROXY_ENABLED}"
    echo "    MSS:       ${DDOS_SYNPROXY_MSS}"
    echo "    WSCALE:    ${DDOS_SYNPROXY_WSCALE}"
    echo "    SACK:      ${DDOS_SYNPROXY_SACK}"
    echo "    Timestamp: ${DDOS_SYNPROXY_TSTAMP}"
    echo "    Ports:     ${DDOS_SYNPROXY_PORTS}"
    echo ""
    echo "  Prefix Aggregation:"
    echo "    Enabled:   ${DDOS_PREFIX_ENABLED}"
    echo "    IPv4 Mask: ${DDOS_PREFIX_IPV4_MASK}"
    echo "    IPv6 Mask: ${DDOS_PREFIX_IPV6_MASK}"
    echo "    SYN Rate:  ${DDOS_PREFIX_SYN_RATE} burst ${DDOS_PREFIX_SYN_BURST}"
    echo "    Conn Rate: ${DDOS_PREFIX_CONN_RATE} burst ${DDOS_PREFIX_CONN_BURST}"
    echo ""
    echo "  Rate Limiting:"
    echo "    SYN Rate:  ${DDOS_CLASSIC_SYN_RATE} burst ${DDOS_CLASSIC_SYN_BURST}"
    echo "    SSH Conn:  max ${DDOS_CLASSIC_SSH_CONN_LIMIT}/IP"
    echo "    HTTP Conn: max ${DDOS_CLASSIC_HTTP_CONN_LIMIT}/IP"
    echo "    ICMP Rate: ${DDOS_CLASSIC_ICMP_RATE} burst ${DDOS_CLASSIC_ICMP_BURST}"
    echo "    Auto-tune: ${DDOS_CLASSIC_AUTO_TUNE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    return 0
}

# =============================================================================
# HIGH ATTRIBUTION BAN API (Stage 4) - v1.18.0 IPC-ONLY
# =============================================================================
# These functions use IPC to communicate with nftband daemon.
# Direct nft commands are ONLY used for verification (read-only).

# Convert human-readable timeout (1h, 30m, etc.) to seconds
_nftban_ddos_timeout_to_seconds() {
    local timeout="$1"
    local value="${timeout%[smhd]}"
    local unit="${timeout: -1}"

    case "$unit" in
        s) echo "$value" ;;
        m) echo "$((value * 60))" ;;
        h) echo "$((value * 3600))" ;;
        d) echo "$((value * 86400))" ;;
        *) echo "$timeout" ;;  # Assume already in seconds
    esac
}

# Add IP to ban set via IPC (called by external detection logic)
# Usage: nftban_ddos_ban_ip <ip> [timeout]
# Example: nftban_ddos_ban_ip 192.168.1.100 1h
nftban_ddos_ban_ip() {
    local ip="$1"
    local timeout="${2:-${DDOS_BAN_TIMEOUT:-1h}}"

    if [[ -z "$ip" ]]; then
        echo "ERROR: IP address required" >&2
        return 1
    fi

    # Convert timeout to seconds for IPC
    local timeout_seconds
    timeout_seconds=$(_nftban_ddos_timeout_to_seconds "$timeout")

    # Use IPC for ban operation (v1.18.0: IPC-only writes)
    if nft_ipc_ban "$ip" "$timeout_seconds" "ddos-classic" "ddos"; then
        _nftban_ddos_classic_log "INFO" "Banned via IPC: $ip (timeout: $timeout)"

        # Verify the ban was applied (read-only nft check)
        # v2.1: All bans go to unified blacklist set
        local family="ip"
        local set_name="blacklist_ipv4"
        [[ "$ip" =~ : ]] && family="ip6" && set_name="blacklist_ipv6"

        if nft get element "$family" nftban "$set_name" "{ $ip }" &>/dev/null; then
            [[ "${DDOS_BAN_LOG:-true}" == "true" ]] && echo "Banned: $ip (timeout: $timeout)"
            return 0
        else
            _nftban_ddos_classic_log "WARN" "IPC success but verification failed for $ip"
            [[ "${DDOS_BAN_LOG:-true}" == "true" ]] && echo "Banned: $ip (timeout: $timeout)"
            return 0
        fi
    else
        echo "ERROR: Failed to ban $ip via IPC" >&2
        return 1
    fi
}

# Remove IP from ban set via IPC
# Usage: nftban_ddos_unban_ip <ip>
nftban_ddos_unban_ip() {
    local ip="$1"

    if [[ -z "$ip" ]]; then
        echo "ERROR: IP address required" >&2
        return 1
    fi

    # Use IPC for unban operation (v1.18.0: IPC-only writes)
    if nft_ipc_unban "$ip"; then
        _nftban_ddos_classic_log "INFO" "Unbanned via IPC: $ip"

        # Verify the unban was applied (read-only nft check)
        # v2.1: All bans go to unified blacklist set
        local family="ip"
        local set_name="blacklist_ipv4"
        [[ "$ip" =~ : ]] && family="ip6" && set_name="blacklist_ipv6"

        if ! nft get element "$family" nftban "$set_name" "{ $ip }" &>/dev/null; then
            echo "Unbanned: $ip"
            return 0
        else
            _nftban_ddos_classic_log "WARN" "IPC success but verification shows IP still in set for $ip"
            echo "Unbanned: $ip"
            return 0
        fi
    else
        echo "ERROR: Failed to unban $ip via IPC" >&2
        return 1
    fi
}

# List all currently banned IPs
# Usage: nftban_ddos_list_banned
nftban_ddos_list_banned() {
    local table_v4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_v6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local ban_set="${DDOS_BAN_SET:-ddos_banned}"

    echo "DDoS Banned IPs (Stage 4 - High Attribution)"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "IPv4 banned IPs (${ban_set}):"
    if timeout 10s nft list set "${table_v4}" "${ban_set}" 2>/dev/null | grep -q "elements"; then
        timeout 10s nft list set "${table_v4}" "${ban_set}" 2>/dev/null | grep -A100 "elements" | grep -v "elements" | tr ',' '\n' | sed 's/[{}]//g' | sed 's/^[ \t]*/  /'
    else
        echo "  (none)"
    fi

    echo ""
    echo "IPv6 banned IPs (${ban_set}6):"
    if timeout 10s nft list set "${table_v6}" "${ban_set}6" 2>/dev/null | grep -q "elements"; then
        timeout 10s nft list set "${table_v6}" "${ban_set}6" 2>/dev/null | grep -A100 "elements" | grep -v "elements" | tr ',' '\n' | sed 's/[{}]//g' | sed 's/^[ \t]*/  /'
    else
        echo "  (none)"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Check if ban set fragment functions are available
_nftban_ddos_ban_has_ipc() {
    type -t nft_fragment_render_ddos_ban_set &>/dev/null && \
    type -t nft_fragment_render_ddos_ban_enforce &>/dev/null && \
    type -t nft_fragment_apply &>/dev/null
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_ddos_classic_enable
export -f nftban_ddos_classic_disable
export -f nftban_ddos_classic_status
export -f nftban_ddos_ban_ip
export -f nftban_ddos_unban_ip
export -f nftban_ddos_list_banned
