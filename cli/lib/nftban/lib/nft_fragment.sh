#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - NFT Fragment Renderer Library
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
#
# PURPOSE: Renders .nft ruleset fragments from configuration and applies them
#          via IPC to the nftband daemon. This is the Wave 3 migration pattern
#          for chain/rule creation.
#
# ARCHITECTURE: See ARCHITECTURE-NFT-POLICY.md and docs/design/WAVE3-NFT-FRAGMENTS.md
#
# meta:name=nft_fragment
# meta:type=lib
# meta:version=1.0.0
# =============================================================================

# Source IPC library if not already loaded
if [[ -z "${_NFTBAN_NFT_IPC_LOADED:-}" ]]; then
    NFTBAN_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
    # shellcheck source=/dev/null
    source "${NFTBAN_LIB_DIR}/lib/nft_ipc.sh" 2>/dev/null || true
fi

# Prevent double sourcing
[[ -n "${_NFTBAN_NFT_FRAGMENT_LOADED:-}" ]] && return 0
declare -g _NFTBAN_NFT_FRAGMENT_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Fragment directory - use /etc/nftban/rules.d for SELinux compatibility
# (nft with iptables_exec_t context can read etc_t but not var_lib_t)
NFTBAN_FRAGMENT_DIR="${NFTBAN_FRAGMENT_DIR:-/etc/nftban/rules.d}"

# =============================================================================
# CORE FUNCTIONS
# =============================================================================

# Ensure fragment directory exists
nft_fragment_init() {
    if [[ ! -d "$NFTBAN_FRAGMENT_DIR" ]]; then
        mkdir -p "$NFTBAN_FRAGMENT_DIR" 2>/dev/null || {
            echo "ERROR: Cannot create fragment directory: $NFTBAN_FRAGMENT_DIR" >&2
            return 1
        }
    fi
    return 0
}

# Write fragment atomically (temp + rename)
# Usage: _nft_fragment_write <path> <content>
_nft_fragment_write() {
    local path="$1"
    local content="$2"
    local tmp_path="${path}.tmp.$$"

    echo "$content" > "$tmp_path" || {
        rm -f "$tmp_path" 2>/dev/null
        return 1
    }

    mv "$tmp_path" "$path" || {
        rm -f "$tmp_path" 2>/dev/null
        return 1
    }

    return 0
}

# Apply a fragment via IPC
# Usage: nft_fragment_apply <path> [check_only]
nft_fragment_apply() {
    local path="$1"
    local check_only="${2:-0}"

    if [[ ! -f "$path" ]]; then
        echo "ERROR: Fragment not found: $path" >&2
        return 1
    fi

    # Use IPC to apply
    if type -t nft_ipc_apply_ruleset &>/dev/null; then
        nft_ipc_apply_ruleset "$path" "$check_only"
    else
        echo "ERROR: IPC library not loaded" >&2
        return 1
    fi
}

# =============================================================================
# PORTSCAN CLASSIC FRAGMENTS
# =============================================================================

# Render portscan classic detection fragment
# Writes to: /var/lib/nftban/rules.d/10-portscan-classic.nft
nft_fragment_render_portscan_classic() {
    local table_ipv4="${PORTSCAN_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${PORTSCAN_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${PORTSCAN_NFT_CHAIN:-portscan_detection}"
    local log_prefix="${PORTSCAN_CLASSIC_LOG_PREFIX:-NFTBAN_PORTSCAN:}"
    local log_rate="${PORTSCAN_CLASSIC_LOG_RATE:-10/second}"
    local log_burst="${PORTSCAN_CLASSIC_LOG_BURST:-50}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/10-portscan-classic.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    # Note: Rules on single lines to avoid heredoc backslash issues
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan Portscan Classic Detection
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY

# --- IPv4 ---
add chain ${table_ipv4} ${chain}
flush chain ${table_ipv4} ${chain}

add rule ${table_ipv4} ${chain} tcp flags syn / syn,ack,fin,rst ct state new limit rate ${log_rate} burst ${log_burst} packets log prefix "${log_prefix}SYN " level info

add rule ${table_ipv4} ${chain} udp dport != { 53, 123, 443 } ct state new limit rate ${log_rate} burst ${log_burst} packets log prefix "${log_prefix}UDP " level info

# --- IPv6 ---
add chain ${table_ipv6} ${chain}
flush chain ${table_ipv6} ${chain}

add rule ${table_ipv6} ${chain} tcp flags syn / syn,ack,fin,rst ct state new limit rate ${log_rate} burst ${log_burst} packets log prefix "${log_prefix}SYN " level info

add rule ${table_ipv6} ${chain} udp dport != { 53, 123, 443 } ct state new limit rate ${log_rate} burst ${log_burst} packets log prefix "${log_prefix}UDP " level info
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render portscan classic jump rules fragment
# These are kept separate because they need idempotent handling
nft_fragment_render_portscan_classic_jump() {
    local table_ipv4="${PORTSCAN_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${PORTSCAN_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${PORTSCAN_NFT_CHAIN:-portscan_detection}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/11-portscan-classic-jump.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan Portscan Classic - Jump Rules
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# NOTE: Jump rules are added idempotently. If the jump already exists,
# nftables will add a duplicate. The bash script checks before rendering.

add rule ${table_ipv4} input jump ${chain}
add rule ${table_ipv6} input jump ${chain}
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render portscan classic cleanup fragment (for disable)
nft_fragment_render_portscan_classic_cleanup() {
    local table_ipv4="${PORTSCAN_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${PORTSCAN_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${PORTSCAN_NFT_CHAIN:-portscan_detection}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/99-portscan-classic-cleanup.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan Portscan Classic - CLEANUP
# Generated: ${timestamp}
# Managed by nftband

# Flush chains (removes all rules but keeps chain for reference safety)
flush chain ${table_ipv4} ${chain}
flush chain ${table_ipv6} ${chain}
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Check if jump rule already exists for a chain
# Usage: nft_fragment_has_jump <table> <chain>
# Returns: 0 if jump exists, 1 if not
nft_fragment_has_jump() {
    local table="$1"
    local chain="$2"

    nft list chain ${table} input 2>/dev/null | grep -q "jump ${chain}"
}

# =============================================================================
# DDOS CLASSIC FRAGMENTS
# =============================================================================

# Render DDoS classic fragment with full protection rules
nft_fragment_render_ddos_classic() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_NFT_CHAIN:-ddos_protection}"

    # Rate limits and bursts
    local syn_rate="${DDOS_CLASSIC_SYN_RATE:-25/second}"
    local syn_burst="${DDOS_CLASSIC_SYN_BURST:-50}"
    local icmp_rate="${DDOS_CLASSIC_ICMP_RATE:-10/second}"
    local icmp_burst="${DDOS_CLASSIC_ICMP_BURST:-20}"
    local icmpv6_rate="${DDOS_CLASSIC_ICMPV6_RATE:-10/second}"
    local icmpv6_burst="${DDOS_CLASSIC_ICMPV6_BURST:-20}"
    local udp_rate="${DDOS_CLASSIC_UDP_RATE:-100/second}"
    local udp_burst="${DDOS_CLASSIC_UDP_BURST:-200}"

    # Connection limits per service
    local ssh_limit="${DDOS_CLASSIC_SSH_CONN_LIMIT:-10}"
    local http_limit="${DDOS_CLASSIC_HTTP_CONN_LIMIT:-100}"
    local https_limit="${DDOS_CLASSIC_HTTPS_CONN_LIMIT:-100}"
    local smtp_limit="${DDOS_CLASSIC_SMTP_CONN_LIMIT:-20}"

    # Meter names
    local syn_meter="${DDOS_CLASSIC_SYN_METER:-ddos_syn_flood}"
    local icmp_meter="${DDOS_CLASSIC_ICMP_METER:-ddos_icmp_flood}"
    local udp_meter="${DDOS_CLASSIC_UDP_METER:-ddos_udp_flood}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/20-ddos-classic.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Classic Protection
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# Thresholds:
#   SYN Rate: ${syn_rate} burst ${syn_burst}
#   SSH Conn: max ${ssh_limit}/IP
#   HTTP Conn: max ${http_limit}/IP
#   ICMP Rate: ${icmp_rate} burst ${icmp_burst}
#   UDP Rate: ${udp_rate} burst ${udp_burst}

# --- IPv4 DDoS Protection ---
add chain ${table_ipv4} ${chain}
flush chain ${table_ipv4} ${chain}

# SYN Flood Protection
add rule ${table_ipv4} ${chain} tcp flags syn meter ${syn_meter} { ip saddr limit rate ${syn_rate} burst ${syn_burst} packets } return comment "SYN: rate OK"
add rule ${table_ipv4} ${chain} tcp flags syn counter drop comment "SYN flood: rate exceeded"

# Connection Limits per Service
add rule ${table_ipv4} ${chain} tcp dport 22 ct state new ct count over ${ssh_limit} counter drop comment "SSH: max ${ssh_limit} conn/IP"
add rule ${table_ipv4} ${chain} tcp dport 80 ct state new ct count over ${http_limit} counter drop comment "HTTP: max ${http_limit} conn/IP"
add rule ${table_ipv4} ${chain} tcp dport 443 ct state new ct count over ${https_limit} counter drop comment "HTTPS: max ${https_limit} conn/IP"
add rule ${table_ipv4} ${chain} tcp dport 25 ct state new ct count over ${smtp_limit} counter drop comment "SMTP: max ${smtp_limit} conn/IP"

# ICMP Rate Limiting
add rule ${table_ipv4} ${chain} ip protocol icmp meter ${icmp_meter} { ip saddr limit rate ${icmp_rate} burst ${icmp_burst} packets } return comment "ICMP: rate OK"
add rule ${table_ipv4} ${chain} ip protocol icmp counter drop comment "ICMP flood: rate exceeded"

# UDP Flood Protection
add rule ${table_ipv4} ${chain} ip protocol udp meter ${udp_meter} { ip saddr limit rate ${udp_rate} burst ${udp_burst} packets } return comment "UDP: rate OK"
add rule ${table_ipv4} ${chain} ip protocol udp counter drop comment "UDP flood: rate exceeded"

# Return to input chain
add rule ${table_ipv4} ${chain} return

# --- IPv6 DDoS Protection ---
add chain ${table_ipv6} ${chain}
flush chain ${table_ipv6} ${chain}

# SYN Flood Protection
add rule ${table_ipv6} ${chain} tcp flags syn meter ${syn_meter}6 { ip6 saddr limit rate ${syn_rate} burst ${syn_burst} packets } return comment "SYN: rate OK"
add rule ${table_ipv6} ${chain} tcp flags syn counter drop comment "SYN flood: rate exceeded"

# Connection Limits
add rule ${table_ipv6} ${chain} tcp dport 22 ct state new ct count over ${ssh_limit} counter drop comment "SSH: max ${ssh_limit} conn/IP"
add rule ${table_ipv6} ${chain} tcp dport { 80, 443 } ct state new ct count over ${http_limit} counter drop comment "HTTP(S): max ${http_limit} conn/IP"

# ICMPv6 Rate Limiting
add rule ${table_ipv6} ${chain} meta l4proto icmpv6 meter ${icmp_meter}6 { ip6 saddr limit rate ${icmpv6_rate} burst ${icmpv6_burst} packets } return comment "ICMPv6: rate OK"
add rule ${table_ipv6} ${chain} meta l4proto icmpv6 counter drop comment "ICMPv6 flood: rate exceeded"

# Return to input chain
add rule ${table_ipv6} ${chain} return
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render DDoS classic jump rules fragment
nft_fragment_render_ddos_classic_jump() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_NFT_CHAIN:-ddos_protection}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/21-ddos-classic-jump.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Classic - Jump Rules
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY

add rule ${table_ipv4} input jump ${chain} comment "DDoS classic protection"
add rule ${table_ipv6} input jump ${chain} comment "DDoS classic protection"
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render DDoS classic cleanup fragment (for disable)
nft_fragment_render_ddos_classic_cleanup() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_NFT_CHAIN:-ddos_protection}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/99-ddos-classic-cleanup.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Classic - CLEANUP
# Generated: ${timestamp}
# Managed by nftband

# Flush chains (removes all rules but keeps chain for reference safety)
flush chain ${table_ipv4} ${chain}
flush chain ${table_ipv6} ${chain}
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# =============================================================================
# PORT CONFIGURATION FRAGMENTS
# =============================================================================

# Render port configuration fragment
# Usage: nft_fragment_render_ports <allowed_tcp_ports> <allowed_udp_ports>
nft_fragment_render_ports() {
    local tcp_ports="${1:-22,80,443}"
    local udp_ports="${2:-53,123}"
    local table_ipv4="${PORT_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${PORT_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${PORT_NFT_CHAIN:-port_filter}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/30-port-config.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan Port Configuration
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# TCP Ports: ${tcp_ports}
# UDP Ports: ${udp_ports}

# --- IPv4 ---
add chain ${table_ipv4} ${chain}
flush chain ${table_ipv4} ${chain}

# Allow specified TCP ports
add rule ${table_ipv4} ${chain} tcp dport { ${tcp_ports} } accept

# Allow specified UDP ports
add rule ${table_ipv6} ${chain} udp dport { ${udp_ports} } accept

# --- IPv6 ---
add chain ${table_ipv6} ${chain}
flush chain ${table_ipv6} ${chain}

add rule ${table_ipv6} ${chain} tcp dport { ${tcp_ports} } accept
add rule ${table_ipv6} ${chain} udp dport { ${udp_ports} } accept
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Enable a module by rendering and applying its fragment
# Usage: nft_fragment_enable_module <module_name>
nft_fragment_enable_module() {
    local module="$1"
    local fragment_path

    case "$module" in
        portscan-classic|portscan_classic)
            fragment_path=$(nft_fragment_render_portscan_classic) || return 1
            nft_fragment_apply "$fragment_path" || return 1

            # Add jump if not present
            local table_ipv4="${PORTSCAN_NFT_TABLE_IPV4:-ip nftban}"
            local chain="${PORTSCAN_NFT_CHAIN:-portscan_detection}"
            if ! nft_fragment_has_jump "$table_ipv4" "$chain"; then
                local jump_path
                jump_path=$(nft_fragment_render_portscan_classic_jump) || return 1
                nft_fragment_apply "$jump_path" || return 1
            fi
            ;;
        ddos-classic|ddos_classic)
            fragment_path=$(nft_fragment_render_ddos_classic) || return 1
            nft_fragment_apply "$fragment_path" || return 1

            # Add jump if not present
            local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
            local chain="${DDOS_NFT_CHAIN:-ddos_protection}"
            if ! nft_fragment_has_jump "$table_ipv4" "$chain"; then
                local jump_path
                jump_path=$(nft_fragment_render_ddos_classic_jump) || return 1
                nft_fragment_apply "$jump_path" || return 1
            fi
            ;;
        *)
            echo "ERROR: Unknown module: $module" >&2
            return 1
            ;;
    esac

    return 0
}

# Disable a module by applying its cleanup fragment
# Usage: nft_fragment_disable_module <module_name>
nft_fragment_disable_module() {
    local module="$1"
    local fragment_path

    case "$module" in
        portscan-classic|portscan_classic)
            fragment_path=$(nft_fragment_render_portscan_classic_cleanup) || return 1
            nft_fragment_apply "$fragment_path" || return 1
            ;;
        ddos-classic|ddos_classic)
            fragment_path=$(nft_fragment_render_ddos_classic_cleanup) || return 1
            nft_fragment_apply "$fragment_path" || return 1
            ;;
        *)
            echo "ERROR: Unknown module: $module" >&2
            return 1
            ;;
    esac

    return 0
}

# List all fragments
nft_fragment_list() {
    if [[ -d "$NFTBAN_FRAGMENT_DIR" ]]; then
        ls -la "${NFTBAN_FRAGMENT_DIR}"/*.nft 2>/dev/null || echo "No fragments found"
    else
        echo "Fragment directory not found: $NFTBAN_FRAGMENT_DIR"
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export NFTBAN_FRAGMENT_DIR
export -f nft_fragment_init
export -f nft_fragment_apply
export -f nft_fragment_render_portscan_classic
export -f nft_fragment_render_portscan_classic_jump
export -f nft_fragment_render_portscan_classic_cleanup
export -f nft_fragment_render_ddos_classic
export -f nft_fragment_render_ddos_classic_jump
export -f nft_fragment_render_ddos_classic_cleanup
export -f nft_fragment_render_ports
export -f nft_fragment_has_jump
export -f nft_fragment_enable_module
export -f nft_fragment_disable_module
export -f nft_fragment_list

# =============================================================================
# STANDALONE EXECUTION (for testing)
# =============================================================================

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        render-portscan)
            nft_fragment_render_portscan_classic
            ;;
        render-ddos)
            nft_fragment_render_ddos_classic
            ;;
        enable)
            nft_fragment_enable_module "${2:-}"
            ;;
        disable)
            nft_fragment_disable_module "${2:-}"
            ;;
        list)
            nft_fragment_list
            ;;
        *)
            echo "Usage: $0 {render-portscan|render-ddos|enable <module>|disable <module>|list}"
            exit 1
            ;;
    esac
fi
