#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nft_fragment" meta:type="lib" meta:version="1.39.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Fragment renderer for nftables rulesets"
# meta:inventory.files="/etc/nftban/rules.d"
# meta:inventory.binaries="nft"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"

set -Eeuo pipefail

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
# v1.19.20 FIX: Implements PORTSCAN_NFT_JUMP_POSITION for correct rule ordering
nft_fragment_render_portscan_classic_jump() {
    local table_ipv4="${PORTSCAN_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${PORTSCAN_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${PORTSCAN_NFT_CHAIN:-portscan_detection}"
    local position="${PORTSCAN_NFT_JUMP_POSITION:-established}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/11-portscan-classic-jump.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    # v1.19.20 FIX: Find the handle to insert AFTER based on position config
    # This ensures portscan detection sees traffic BEFORE service accepts
    local ipv4_cmd="add rule ${table_ipv4} input jump ${chain}"
    local ipv6_cmd="add rule ${table_ipv6} input jump ${chain}"
    local position_comment="(appended to end - fallback)"
    local handle_ipv4=""
    local handle_ipv6=""

    case "$position" in
        first)
            # Insert at beginning of chain (before everything)
            ipv4_cmd="insert rule ${table_ipv4} input jump ${chain}"
            ipv6_cmd="insert rule ${table_ipv6} input jump ${chain}"
            position_comment="(at beginning)"
            ;;
        established)
            # Find handle of "ct state established" rule
            handle_ipv4=$(nft -a list chain ${table_ipv4} input 2>/dev/null | \
                grep -E "ct state.*(established|related)" | grep -oP 'handle \K\d+' | head -1) || true
            if [[ -n "$handle_ipv4" ]]; then
                ipv4_cmd="add rule ${table_ipv4} input position ${handle_ipv4} jump ${chain}"
                position_comment="(after established, handle ${handle_ipv4})"
            fi
            handle_ipv6=$(nft -a list chain ${table_ipv6} input 2>/dev/null | \
                grep -E "ct state.*(established|related)" | grep -oP 'handle \K\d+' | head -1) || true
            if [[ -n "$handle_ipv6" ]]; then
                ipv6_cmd="add rule ${table_ipv6} input position ${handle_ipv6} jump ${chain}"
            fi
            ;;
        whitelist)
            # Find handle of whitelist rule
            handle_ipv4=$(nft -a list chain ${table_ipv4} input 2>/dev/null | \
                grep -E "@whitelist" | grep -oP 'handle \K\d+' | head -1) || true
            if [[ -n "$handle_ipv4" ]]; then
                ipv4_cmd="add rule ${table_ipv4} input position ${handle_ipv4} jump ${chain}"
                position_comment="(after whitelist, handle ${handle_ipv4})"
            fi
            handle_ipv6=$(nft -a list chain ${table_ipv6} input 2>/dev/null | \
                grep -E "@whitelist" | grep -oP 'handle \K\d+' | head -1) || true
            if [[ -n "$handle_ipv6" ]]; then
                ipv6_cmd="add rule ${table_ipv6} input position ${handle_ipv6} jump ${chain}"
            fi
            ;;
        ddos)
            # Find handle of ddos jump rule
            handle_ipv4=$(nft -a list chain ${table_ipv4} input 2>/dev/null | \
                grep -E "jump ddos" | grep -oP 'handle \K\d+' | head -1) || true
            if [[ -n "$handle_ipv4" ]]; then
                ipv4_cmd="add rule ${table_ipv4} input position ${handle_ipv4} jump ${chain}"
                position_comment="(after ddos, handle ${handle_ipv4})"
            fi
            handle_ipv6=$(nft -a list chain ${table_ipv6} input 2>/dev/null | \
                grep -E "jump ddos" | grep -oP 'handle \K\d+' | head -1) || true
            if [[ -n "$handle_ipv6" ]]; then
                ipv6_cmd="add rule ${table_ipv6} input position ${handle_ipv6} jump ${chain}"
            fi
            ;;
    esac

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan Portscan Classic - Jump Rules
# Generated: ${timestamp}
# Position: ${position} ${position_comment}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# NOTE: Jump rules are added idempotently. If the jump already exists,
# nftables will add a duplicate. The bash script checks before rendering.

${ipv4_cmd}
${ipv6_cmd}
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
# DDOS SANITY FRAGMENTS (Packet Validation - Stage 3)
# =============================================================================

# Render DDoS sanity check fragment for packet validation
# Drops invalid/malformed packets BEFORE rate limiting
# Writes to: /etc/nftban/rules.d/12-ddos-sanity.nft
nft_fragment_render_ddos_sanity() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_SANITY_CHAIN:-ddos_sanity}"

    # Logging options
    local log_invalid="${DDOS_SANITY_LOG_INVALID:-false}"
    local log_prefix="${DDOS_SANITY_LOG_PREFIX:-NFTBAN_SANITY:}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/12-ddos-sanity.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    # Build optional logging rules
    local log_xmas_ipv4=""
    local log_null_ipv4=""
    local log_nonsyn_ipv4=""
    local log_invalid_ct_ipv4=""
    local log_frag_ipv4=""
    local log_xmas_ipv6=""
    local log_null_ipv6=""
    local log_nonsyn_ipv6=""
    local log_invalid_ct_ipv6=""

    if [[ "$log_invalid" == "true" ]]; then
        log_xmas_ipv4="add rule ${table_ipv4} ${chain} tcp flags & (fin|syn|rst|psh|ack|urg) == fin|syn|rst|psh|ack|urg limit rate 5/second burst 10 packets log prefix \"${log_prefix}XMAS \" level warn"
        log_null_ipv4="add rule ${table_ipv4} ${chain} tcp flags & (fin|syn|rst|psh|ack|urg) == 0x0 limit rate 5/second burst 10 packets log prefix \"${log_prefix}NULL \" level warn"
        log_nonsyn_ipv4="add rule ${table_ipv4} ${chain} tcp flags & syn != syn ct state new limit rate 5/second burst 10 packets log prefix \"${log_prefix}NONSYN \" level warn"
        log_invalid_ct_ipv4="add rule ${table_ipv4} ${chain} ct state invalid limit rate 5/second burst 10 packets log prefix \"${log_prefix}INVALID \" level warn"
        log_frag_ipv4="add rule ${table_ipv4} ${chain} ip frag-off & 0x1fff != 0 tcp dport >= 1024 limit rate 5/second burst 10 packets log prefix \"${log_prefix}FRAG \" level warn"
        log_xmas_ipv6="add rule ${table_ipv6} ${chain} tcp flags & (fin|syn|rst|psh|ack|urg) == fin|syn|rst|psh|ack|urg limit rate 5/second burst 10 packets log prefix \"${log_prefix}XMAS \" level warn"
        log_null_ipv6="add rule ${table_ipv6} ${chain} tcp flags & (fin|syn|rst|psh|ack|urg) == 0x0 limit rate 5/second burst 10 packets log prefix \"${log_prefix}NULL \" level warn"
        log_nonsyn_ipv6="add rule ${table_ipv6} ${chain} tcp flags & syn != syn ct state new limit rate 5/second burst 10 packets log prefix \"${log_prefix}NONSYN \" level warn"
        log_invalid_ct_ipv6="add rule ${table_ipv6} ${chain} ct state invalid limit rate 5/second burst 10 packets log prefix \"${log_prefix}INVALID \" level warn"
    fi

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Sanity Check - Packet Validation (Stage 3)
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# PURPOSE: Drop invalid/malformed packets BEFORE rate limiting
# This runs BEFORE SYNPROXY to filter out garbage traffic early.
#
# Rules:
#   - Drop Christmas tree packets (all TCP flags set)
#   - Drop NULL packets (no TCP flags)
#   - Drop new connections that aren't SYN
#   - Drop packets with invalid conntrack state
#   - Drop fragmented packets to high ports (amplification)

# --- IPv4 Sanity Checks ---
add chain ${table_ipv4} ${chain}
flush chain ${table_ipv4} ${chain}

# 1. Drop Christmas tree packets (all flags set - scan/attack signature)
${log_xmas_ipv4:+${log_xmas_ipv4}
}add rule ${table_ipv4} ${chain} tcp flags & (fin|syn|rst|psh|ack|urg) == fin|syn|rst|psh|ack|urg counter drop comment "SANITY: Xmas tree packet"

# 2. Drop NULL packets (no flags - scan signature)
${log_null_ipv4:+${log_null_ipv4}
}add rule ${table_ipv4} ${chain} tcp flags & (fin|syn|rst|psh|ack|urg) == 0x0 counter drop comment "SANITY: NULL packet"

# 3. Drop new connections that aren't SYN (stateful bypass attempt)
${log_nonsyn_ipv4:+${log_nonsyn_ipv4}
}add rule ${table_ipv4} ${chain} tcp flags & syn != syn ct state new counter drop comment "SANITY: new non-SYN"

# 4. Drop packets with invalid conntrack state
${log_invalid_ct_ipv4:+${log_invalid_ct_ipv4}
}add rule ${table_ipv4} ${chain} ct state invalid counter drop comment "SANITY: invalid ct state"

# 5. Drop fragmented packets to high ports (common in amplification attacks)
${log_frag_ipv4:+${log_frag_ipv4}
}add rule ${table_ipv4} ${chain} ip frag-off & 0x1fff != 0 tcp dport >= 1024 counter drop comment "SANITY: frag to high port"
add rule ${table_ipv4} ${chain} ip frag-off & 0x1fff != 0 udp dport >= 1024 counter drop comment "SANITY: frag to high port"

# Return to continue processing
add rule ${table_ipv4} ${chain} return

# --- IPv6 Sanity Checks ---
add chain ${table_ipv6} ${chain}
flush chain ${table_ipv6} ${chain}

# 1. Drop Christmas tree packets
${log_xmas_ipv6:+${log_xmas_ipv6}
}add rule ${table_ipv6} ${chain} tcp flags & (fin|syn|rst|psh|ack|urg) == fin|syn|rst|psh|ack|urg counter drop comment "SANITY: Xmas tree packet"

# 2. Drop NULL packets
${log_null_ipv6:+${log_null_ipv6}
}add rule ${table_ipv6} ${chain} tcp flags & (fin|syn|rst|psh|ack|urg) == 0x0 counter drop comment "SANITY: NULL packet"

# 3. Drop new connections that aren't SYN
${log_nonsyn_ipv6:+${log_nonsyn_ipv6}
}add rule ${table_ipv6} ${chain} tcp flags & syn != syn ct state new counter drop comment "SANITY: new non-SYN"

# 4. Drop packets with invalid conntrack state
${log_invalid_ct_ipv6:+${log_invalid_ct_ipv6}
}add rule ${table_ipv6} ${chain} ct state invalid counter drop comment "SANITY: invalid ct state"

# Note: IPv6 fragmentation is handled differently (via extension headers)
# Fragment header detection for IPv6
add rule ${table_ipv6} ${chain} exthdr frag exists tcp dport >= 1024 counter drop comment "SANITY: IPv6 frag to high port"
add rule ${table_ipv6} ${chain} exthdr frag exists udp dport >= 1024 counter drop comment "SANITY: IPv6 frag to high port"

# Return to continue processing
add rule ${table_ipv6} ${chain} return
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render DDoS sanity jump rules fragment
nft_fragment_render_ddos_sanity_jump() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_SANITY_CHAIN:-ddos_sanity}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/13-ddos-sanity-jump.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Sanity - Jump Rules
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# NOTE: This jump should be FIRST in the input chain to filter
# malformed packets before any other processing.

add rule ${table_ipv4} input jump ${chain} comment "Sanity check (Stage 3)"
add rule ${table_ipv6} input jump ${chain} comment "Sanity check (Stage 3)"
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render DDoS sanity cleanup fragment (for disable)
nft_fragment_render_ddos_sanity_cleanup() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_SANITY_CHAIN:-ddos_sanity}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/99-ddos-sanity-cleanup.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Sanity - CLEANUP
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
# SYNPROXY FRAGMENTS
# =============================================================================

# Render SYNPROXY fragment for SYN flood protection
# SYNPROXY handles TCP handshake at kernel level before passing to services
# Writes to: /etc/nftban/rules.d/15-ddos-synproxy.nft
nft_fragment_render_synproxy() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_SYNPROXY_CHAIN:-ddos_synproxy}"

    # SYNPROXY options
    local mss="${DDOS_SYNPROXY_MSS:-1460}"
    local wscale="${DDOS_SYNPROXY_WSCALE:-7}"
    local sack="${DDOS_SYNPROXY_SACK:-true}"
    local tstamp="${DDOS_SYNPROXY_TSTAMP:-true}"
    local ports="${DDOS_SYNPROXY_PORTS:-80,443,25,587,993,995,3306,5432,6379,27017}"

    # v1.34.0 SECURITY FIX: Force-strip SSH port from SYNPROXY — notrack on SSH
    # breaks conntrack for whitelisted IPs, causing SSH lockout under attack.
    # The raw table fires before filter, so whitelisted IPs' SYN gets notracked,
    # then subsequent ACK arrives as ct state INVALID and gets dropped.
    local _ssh_port="${SSH_PORT:-22}"
    [[ -f "${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/ssh_port_active.state" ]] && \
        _ssh_port=$(cat "${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/ssh_port_active.state" 2>/dev/null) || true
    [[ -z "$_ssh_port" || ! "$_ssh_port" =~ ^[0-9]+$ ]] && _ssh_port=22
    local _stripped_ports
    _stripped_ports=$(echo "$ports" | tr ',' '\n' | grep -vxF "$_ssh_port" | tr '\n' ',' | sed 's/,$//')
    if [[ "$_stripped_ports" != "$ports" ]]; then
        log "WARN" "SYNPROXY: Stripped SSH port ${_ssh_port} from SYNPROXY ports (lockout prevention)" 2>/dev/null || true
        ports="$_stripped_ports"
    fi
    local log_prefix="${DDOS_SYNPROXY_LOG_PREFIX:-NFTBAN_SYNPROXY:}"

    # Build SYNPROXY options string
    local synproxy_opts="mss ${mss} wscale ${wscale}"
    [[ "$sack" == "true" ]] && synproxy_opts="${synproxy_opts} sack-perm"
    [[ "$tstamp" == "true" ]] && synproxy_opts="${synproxy_opts} timestamp"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/15-ddos-synproxy.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan SYNPROXY Protection
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# SYNPROXY: Kernel-level TCP handshake proxy for SYN flood mitigation
# Options: ${synproxy_opts}
# Protected ports: ${ports}
#
# IMPORTANT: SYNPROXY requires notrack for incoming SYNs and proper
# conntrack for the proxied connection. The raw table rules handle this.

# --- IPv4 SYNPROXY ---
add chain ${table_ipv4} ${chain}
flush chain ${table_ipv4} ${chain}

# Mark packets that have completed SYNPROXY handshake (invalid from server's view)
add rule ${table_ipv4} ${chain} ct state invalid,untracked tcp dport { ${ports} } tcp flags syn / syn,ack,fin,rst synproxy ${synproxy_opts} counter comment "SYNPROXY: handle SYN"

# Accept packets from valid SYNPROXY-completed connections
add rule ${table_ipv4} ${chain} ct state established,related counter return comment "SYNPROXY: pass established"

# Return for other traffic (not handled by SYNPROXY)
add rule ${table_ipv4} ${chain} return

# --- IPv6 SYNPROXY ---
add chain ${table_ipv6} ${chain}
flush chain ${table_ipv6} ${chain}

# Mark packets that have completed SYNPROXY handshake
add rule ${table_ipv6} ${chain} ct state invalid,untracked tcp dport { ${ports} } tcp flags syn / syn,ack,fin,rst synproxy ${synproxy_opts} counter comment "SYNPROXY: handle SYN"

# Accept packets from valid SYNPROXY-completed connections
add rule ${table_ipv6} ${chain} ct state established,related counter return comment "SYNPROXY: pass established"

# Return for other traffic
add rule ${table_ipv6} ${chain} return
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render SYNPROXY raw table rules (for notrack on incoming SYNs)
# These MUST be applied to the raw table prerouting chain
nft_fragment_render_synproxy_raw() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local ports="${DDOS_SYNPROXY_PORTS:-80,443,25,587,993,995,3306,5432,6379,27017}"

    # v1.34.0 SECURITY FIX: Force-strip SSH port from SYNPROXY notrack rules.
    # notrack in raw table fires BEFORE filter chain. Whitelisted IPs' SYN gets
    # notracked → subsequent ACK arrives as ct state INVALID → DROPPED by first
    # rule in input chain. This causes SSH lockout even for whitelisted IPs.
    local _ssh_port="${SSH_PORT:-22}"
    [[ -f "${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/ssh_port_active.state" ]] && \
        _ssh_port=$(cat "${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/ssh_port_active.state" 2>/dev/null) || true
    [[ -z "$_ssh_port" || ! "$_ssh_port" =~ ^[0-9]+$ ]] && _ssh_port=22
    local _stripped_ports
    _stripped_ports=$(echo "$ports" | tr ',' '\n' | grep -vxF "$_ssh_port" | tr '\n' ',' | sed 's/,$//')
    if [[ "$_stripped_ports" != "$ports" ]]; then
        log "WARN" "SYNPROXY: Stripped SSH port ${_ssh_port} from notrack rules (lockout prevention)" 2>/dev/null || true
        ports="$_stripped_ports"
    fi

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/14-ddos-synproxy-raw.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan SYNPROXY Raw Table Rules
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# These rules mark SYN packets as NOTRACK so SYNPROXY can intercept them.
# Without notrack, the kernel would drop untracked SYN packets.

# --- IPv4 Raw Table (NOTRACK for SYNs) ---
add table ip raw
add chain ip raw prerouting { type filter hook prerouting priority raw; policy accept; }

# Don't track SYN packets to SYNPROXY-protected ports (let SYNPROXY handle them)
# v1.46.0 FIX-H: Comment-based rule replacement instead of flush chain
# Old: flush chain ip raw prerouting — destroyed Docker/K8s rules
# New: Pre-cleanup via _nft_cleanup_synproxy_raw() deletes only our rules by comment
add rule ip raw prerouting tcp dport { ${ports} } tcp flags syn / syn,ack,fin,rst notrack comment "SYNPROXY: notrack SYN"

# --- IPv6 Raw Table (NOTRACK for SYNs) ---
add table ip6 raw
add chain ip6 raw prerouting { type filter hook prerouting priority raw; policy accept; }

# Don't track SYN packets to SYNPROXY-protected ports
add rule ip6 raw prerouting tcp dport { ${ports} } tcp flags syn / syn,ack,fin,rst notrack comment "SYNPROXY: notrack SYN"
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render SYNPROXY jump rules fragment
nft_fragment_render_synproxy_jump() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_SYNPROXY_CHAIN:-ddos_synproxy}"

    # v1.33.0: SYNPROXY jump MUST be positioned BEFORE 'ct state established,related'
    # because notrack (raw table) breaks conntrack for synproxied ports.
    # If the jump is appended at the end (old behavior), untracked packets are
    # dropped by policy before reaching the SYNPROXY chain → SSH lockout.
    #
    # Strategy: Find the handle of 'ct state established,related accept' in each
    # input chain and insert the jump BEFORE it. Fall back to 'add rule' if the
    # handle is not found (new install without stateful rule).

    local family handle
    for family in ip ip6; do
        local table_fam="${family} nftban"
        # Skip if jump already exists
        if nft -a list chain ${table_fam} input 2>/dev/null | grep -q "jump ${chain}"; then
            continue
        fi

        # Find handle of 'ct state established,related accept'
        handle=$(nft -a list chain ${table_fam} input 2>/dev/null \
            | grep 'ct state established,related accept' \
            | grep -oP 'handle \K\d+' | head -1)

        if [[ -n "$handle" ]]; then
            # Insert BEFORE the established,related rule
            nft insert rule ${table_fam} input position "$handle" jump "${chain}" comment "\"SYNPROXY protection\"" 2>/dev/null || {
                echo "WARNING: Failed to insert SYNPROXY jump before handle $handle in ${table_fam}" >&2
                # Fallback: append (better than nothing)
                nft add rule ${table_fam} input jump "${chain}" comment "\"SYNPROXY protection\"" 2>/dev/null
            }
        else
            # No established,related rule found — append
            nft add rule ${table_fam} input jump "${chain}" comment "\"SYNPROXY protection\"" 2>/dev/null
        fi
    done

    # Return a dummy path for API compatibility (no file written)
    echo "/dev/null"
}

# Remove only nftban-managed rules from raw prerouting chains
# Uses comment-based matching to avoid destroying Docker/K8s rules
# Usage: _nft_cleanup_synproxy_raw
_nft_cleanup_synproxy_raw() {
    local family
    for family in ip ip6; do
        nft -a list chain "$family" raw prerouting 2>/dev/null | \
            grep -i 'comment.*"SYNPROXY:' | \
            grep -oP 'handle \K\d+' | \
            while read -r handle; do
                nft delete rule "$family" raw prerouting handle "$handle" 2>/dev/null || true
            done
    done
}

# Render SYNPROXY cleanup fragment (for disable)
nft_fragment_render_synproxy_cleanup() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_SYNPROXY_CHAIN:-ddos_synproxy}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/99-ddos-synproxy-cleanup.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan SYNPROXY - CLEANUP
# Generated: ${timestamp}
# Managed by nftband

# Flush SYNPROXY chains (nftban-owned, safe to flush entirely)
flush chain ${table_ipv4} ${chain}
flush chain ${table_ipv6} ${chain}

# NOTE: Raw prerouting cleanup is handled by _nft_cleanup_synproxy_raw()
# which deletes only nftban-managed rules (matching comment "SYNPROXY:")
# to avoid destroying Docker/K8s/other rules in the raw prerouting chain.
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# =============================================================================
# DDOS PREFIX AGGREGATION FRAGMENTS
# =============================================================================

# Render DDoS prefix aggregation fragment for distributed attack detection
# Tracks by /24 (IPv4) and /64 (IPv6) prefixes to detect botnets
# Writes to: /etc/nftban/rules.d/18-ddos-prefix.nft
nft_fragment_render_ddos_prefix() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_PREFIX_CHAIN:-ddos_prefix}"

    # Rate limits for prefix aggregation (higher than per-IP)
    local syn_rate="${DDOS_PREFIX_SYN_RATE:-100/second}"
    local syn_burst="${DDOS_PREFIX_SYN_BURST:-200}"
    local conn_rate="${DDOS_PREFIX_CONN_RATE:-500/second}"
    local conn_burst="${DDOS_PREFIX_CONN_BURST:-1000}"

    # Meter names
    local syn_meter="${DDOS_PREFIX_METER_SYN:-ddos_prefix_syn}"
    local conn_meter="${DDOS_PREFIX_METER_CONN:-ddos_prefix_conn}"

    # Network masks
    local ipv4_mask="${DDOS_PREFIX_IPV4_MASK:-/24}"
    local ipv6_mask="${DDOS_PREFIX_IPV6_MASK:-/64}"

    # Convert CIDR to nftables bitmask for IPv4
    local ipv4_bitmask
    case "$ipv4_mask" in
        /24) ipv4_bitmask="255.255.255.0" ;;
        /16) ipv4_bitmask="255.255.0.0" ;;
        /8)  ipv4_bitmask="255.0.0.0" ;;
        *)   ipv4_bitmask="255.255.255.0" ;;  # default to /24
    esac

    # Convert CIDR to nftables bitmask for IPv6
    local ipv6_bitmask
    case "$ipv6_mask" in
        /64) ipv6_bitmask="ffff:ffff:ffff:ffff::" ;;
        /48) ipv6_bitmask="ffff:ffff:ffff::" ;;
        /32) ipv6_bitmask="ffff:ffff::" ;;
        *)   ipv6_bitmask="ffff:ffff:ffff:ffff::" ;;  # default to /64
    esac

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/18-ddos-prefix.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Prefix Aggregation Protection
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# PURPOSE: Detect distributed botnets by aggregating traffic by network prefix.
# A single IP might stay under rate limits, but many IPs from the same /24
# subnet will trigger this protection.
#
# IPv4 Prefix: ${ipv4_mask} (${ipv4_bitmask})
# IPv6 Prefix: ${ipv6_mask} (${ipv6_bitmask})
# SYN Rate: ${syn_rate} burst ${syn_burst}
# Conn Rate: ${conn_rate} burst ${conn_burst}

# --- IPv4 Prefix Aggregation ---
add chain ${table_ipv4} ${chain}
flush chain ${table_ipv4} ${chain}

# SYN flood protection by /24 prefix
add rule ${table_ipv4} ${chain} tcp flags syn meter ${syn_meter} { ip saddr & ${ipv4_bitmask} limit rate ${syn_rate} burst ${syn_burst} packets } return comment "Prefix SYN: rate OK"
add rule ${table_ipv4} ${chain} tcp flags syn counter drop comment "Prefix SYN flood: ${ipv4_mask} rate exceeded"

# Connection rate by /24 prefix
add rule ${table_ipv4} ${chain} ct state new meter ${conn_meter} { ip saddr & ${ipv4_bitmask} limit rate ${conn_rate} burst ${conn_burst} packets } return comment "Prefix conn: rate OK"
add rule ${table_ipv4} ${chain} ct state new counter drop comment "Prefix conn flood: ${ipv4_mask} rate exceeded"

# Return to input chain for remaining traffic
add rule ${table_ipv4} ${chain} return

# --- IPv6 Prefix Aggregation ---
add chain ${table_ipv6} ${chain}
flush chain ${table_ipv6} ${chain}

# SYN flood protection by /64 prefix
add rule ${table_ipv6} ${chain} tcp flags syn meter ${syn_meter}6 { ip6 saddr & ${ipv6_bitmask} limit rate ${syn_rate} burst ${syn_burst} packets } return comment "Prefix SYN: rate OK"
add rule ${table_ipv6} ${chain} tcp flags syn counter drop comment "Prefix SYN flood: ${ipv6_mask} rate exceeded"

# Connection rate by /64 prefix
add rule ${table_ipv6} ${chain} ct state new meter ${conn_meter}6 { ip6 saddr & ${ipv6_bitmask} limit rate ${conn_rate} burst ${conn_burst} packets } return comment "Prefix conn: rate OK"
add rule ${table_ipv6} ${chain} ct state new counter drop comment "Prefix conn flood: ${ipv6_mask} rate exceeded"

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

# Render DDoS prefix aggregation jump rules fragment
nft_fragment_render_ddos_prefix_jump() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_PREFIX_CHAIN:-ddos_prefix}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/19-ddos-prefix-jump.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Prefix Aggregation - Jump Rules
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY

add rule ${table_ipv4} input jump ${chain} comment "Prefix aggregation protection"
add rule ${table_ipv6} input jump ${chain} comment "Prefix aggregation protection"
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render DDoS prefix aggregation cleanup fragment (for disable)
nft_fragment_render_ddos_prefix_cleanup() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_PREFIX_CHAIN:-ddos_prefix}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/99-ddos-prefix-cleanup.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Prefix Aggregation - CLEANUP
# Generated: ${timestamp}
# Managed by nftband

# Flush prefix aggregation chains
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

    # SSH port detection: state file → sshd_config → fallback 22
    local ssh_port=22
    local _ssh_port_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/ssh_port_active.state"
    if [[ -f "$_ssh_port_file" ]]; then
        local _sp
        _sp=$(cat "$_ssh_port_file" 2>/dev/null) || true
        [[ "$_sp" =~ ^[0-9]+$ ]] && ssh_port="$_sp"
    elif [[ -f /etc/ssh/sshd_config ]]; then
        local _sp
        _sp=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1) || true
        [[ "$_sp" =~ ^[0-9]+$ ]] && ssh_port="$_sp"
    fi

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
#   SSH Conn: max ${ssh_limit}/IP (port ${ssh_port})
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
add rule ${table_ipv4} ${chain} tcp dport ${ssh_port} ct state new ct count over ${ssh_limit} counter drop comment "SSH(${ssh_port}): max ${ssh_limit} conn/IP"
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
add rule ${table_ipv6} ${chain} tcp dport ${ssh_port} ct state new ct count over ${ssh_limit} counter drop comment "SSH(${ssh_port}): max ${ssh_limit} conn/IP"
add rule ${table_ipv6} ${chain} tcp dport { 80, 443 } ct state new ct count over ${http_limit} counter drop comment "HTTP(S): max ${http_limit} conn/IP"

# ICMPv6 Rate Limiting
add rule ${table_ipv6} ${chain} meta l4proto icmpv6 meter ${icmp_meter}6 { ip6 saddr limit rate ${icmpv6_rate} burst ${icmpv6_burst} packets } return comment "ICMPv6: rate OK"
add rule ${table_ipv6} ${chain} meta l4proto icmpv6 counter drop comment "ICMPv6 flood: rate exceeded"

# v1.46.0 FIX-J: IPv6 UDP Flood Protection (mirrors IPv4 pattern at line 992-993)
add rule ${table_ipv6} ${chain} meta l4proto udp meter ${udp_meter}6 { ip6 saddr limit rate ${udp_rate} burst ${udp_burst} packets } return comment "UDP: rate OK"
add rule ${table_ipv6} ${chain} meta l4proto udp counter drop comment "UDP flood: rate exceeded"

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
# v1.46.0 FIX-A: Insert BEFORE service port accept rules (was append → bypassed)
# Uses same position-aware strategy as SYNPROXY jump (line 642)
nft_fragment_render_ddos_classic_jump() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_NFT_CHAIN:-ddos_protection}"

    local family handle table_fam
    for family in ip ip6; do
        table_fam="${family} nftban"
        # Skip if jump already exists
        if nft -a list chain ${table_fam} input 2>/dev/null | grep -q "jump ${chain}"; then
            continue
        fi

        # Find handle of first service port accept rule (tcp dport @tcp_ports_in)
        # Insert BEFORE it so DDoS rate limits fire before service port accept
        handle=$(nft -a list chain ${table_fam} input 2>/dev/null \
            | grep '@tcp_ports_in' \
            | grep -oP 'handle \K\d+' | head -1)

        if [[ -n "$handle" ]]; then
            # Insert BEFORE service port rules
            nft insert rule ${table_fam} input position "$handle" jump "${chain}" \
                comment "\"DDoS classic protection\"" 2>/dev/null || {
                echo "WARNING: Failed to insert DDoS jump before handle $handle in ${table_fam}" >&2
                # Fallback: append (matches old behavior)
                nft add rule ${table_fam} input jump "${chain}" \
                    comment "\"DDoS classic protection\"" 2>/dev/null
            }
        else
            # No service port rule found — append (new install)
            nft add rule ${table_fam} input jump "${chain}" \
                comment "\"DDoS classic protection\"" 2>/dev/null
        fi
    done

    # Return a dummy path for API compatibility (no file written)
    echo "/dev/null"
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
# DDOS BAN SET FRAGMENTS (Stage 4 - High Attribution Bans)
# =============================================================================

# Render DDoS ban set fragment - creates sets with timeout
# These sets hold high-attribution banned IPs (proven real, not spoofed)
# Writes to: /etc/nftban/rules.d/03-ddos-ban-set.nft
nft_fragment_render_ddos_ban_set() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local ban_set="${DDOS_BAN_SET:-ddos_banned}"
    local ban_timeout="${DDOS_BAN_TIMEOUT:-1h}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/03-ddos-ban-set.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Ban Set - High Attribution Bans (Stage 4)
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# PURPOSE: Create sets for banned IPs with automatic timeout expiry
# These sets are populated programmatically when high-attribution
# criteria are met (completed handshakes, repeated violations, etc.)
#
# Ban criteria (require at least one):
#   1. Completed TCP handshakes + sustained abuse (proves real IP)
#   2. Repeated SYNPROXY failures (failed to complete handshake)
#   3. Persistence across time windows (not just a burst)

# --- IPv4 Ban Set ---
add set ${table_ipv4} ${ban_set} { type ipv4_addr; flags timeout; timeout ${ban_timeout}; comment "High-attribution banned IPs"; }

# --- IPv6 Ban Set ---
add set ${table_ipv6} ${ban_set}6 { type ipv6_addr; flags timeout; timeout ${ban_timeout}; comment "High-attribution banned IPs"; }
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render DDoS ban enforcement fragment - drops traffic from banned IPs
# Checked very early in input chain (after sanity, before rate limiting)
# Writes to: /etc/nftban/rules.d/04-ddos-ban-enforce.nft
nft_fragment_render_ddos_ban_enforce() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local ban_set="${DDOS_BAN_SET:-ddos_banned}"
    local ban_log="${DDOS_BAN_LOG:-true}"
    local log_prefix="${DDOS_BAN_LOG_PREFIX:-NFTBAN_BAN:}"
    local chain="ddos_ban_enforce"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/04-ddos-ban-enforce.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    # Build optional logging rules
    local log_rule_ipv4=""
    local log_rule_ipv6=""
    if [[ "$ban_log" == "true" ]]; then
        log_rule_ipv4="add rule ${table_ipv4} ${chain} ip saddr @${ban_set} limit rate 1/second burst 5 packets log prefix \"${log_prefix}DROP \" level warn"
        log_rule_ipv6="add rule ${table_ipv6} ${chain} ip6 saddr @${ban_set}6 limit rate 1/second burst 5 packets log prefix \"${log_prefix}DROP \" level warn"
    fi

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Ban Enforcement - High Attribution Bans (Stage 4)
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# PURPOSE: Drop all traffic from IPs in the ban set
# This chain runs EARLY in the input chain for efficiency.

# --- IPv4 Ban Enforcement ---
add chain ${table_ipv4} ${chain}
flush chain ${table_ipv4} ${chain}

# Log banned IP traffic (rate-limited to avoid log flood)
${log_rule_ipv4:+${log_rule_ipv4}
}
# Drop all traffic from banned IPs
add rule ${table_ipv4} ${chain} ip saddr @${ban_set} counter drop comment "DDoS banned IP"

# Return for non-banned traffic
add rule ${table_ipv4} ${chain} return

# --- IPv6 Ban Enforcement ---
add chain ${table_ipv6} ${chain}
flush chain ${table_ipv6} ${chain}

# Log banned IP traffic (rate-limited)
${log_rule_ipv6:+${log_rule_ipv6}
}
# Drop all traffic from banned IPs
add rule ${table_ipv6} ${chain} ip6 saddr @${ban_set}6 counter drop comment "DDoS banned IP"

# Return for non-banned traffic
add rule ${table_ipv6} ${chain} return
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render DDoS ban jump rules fragment
nft_fragment_render_ddos_ban_jump() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="ddos_ban_enforce"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/05-ddos-ban-jump.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Ban - Jump Rules
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# NOTE: This jump should be EARLY in the input chain (after sanity checks)
# to drop banned IPs before any rate limiting or connection tracking.

add rule ${table_ipv4} input jump ${chain} comment "DDoS ban check (Stage 4)"
add rule ${table_ipv6} input jump ${chain} comment "DDoS ban check (Stage 4)"
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render DDoS ban cleanup fragment (for disable)
nft_fragment_render_ddos_ban_cleanup() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local ban_set="${DDOS_BAN_SET:-ddos_banned}"
    local chain="ddos_ban_enforce"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/99-ddos-ban-cleanup.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Ban - CLEANUP
# Generated: ${timestamp}
# Managed by nftband
#
# NOTE: This flushes the enforcement chain and clears ban sets.
# Use with caution - all banned IPs will be immediately unbanned.

# Flush enforcement chains
flush chain ${table_ipv4} ${chain}
flush chain ${table_ipv6} ${chain}

# Flush ban sets (unban all IPs)
flush set ${table_ipv4} ${ban_set}
flush set ${table_ipv6} ${ban_set}6
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# =============================================================================
# DDOS PENALTY LADDER FRAGMENTS
# =============================================================================

# Render penalty ladder sets with auto-expiry timeouts
# Writes to: /etc/nftban/rules.d/06-ddos-penalty-sets.nft
nft_fragment_render_ddos_penalty_sets() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"

    # Set names
    local set_limit_10s="${DDOS_PENALTY_SET_LIMIT_10S:-ddos_limit_10s}"
    local set_limit_5m="${DDOS_PENALTY_SET_LIMIT_5M:-ddos_limit_5m}"
    local set_drop_5m="${DDOS_PENALTY_SET_DROP_5M:-ddos_drop_5m}"
    local set_ban_1h="${DDOS_PENALTY_SET_BAN_1H:-ddos_ban_1h}"

    # Timeouts
    local timeout_10s="${DDOS_PENALTY_TIMEOUT_10S:-10s}"
    local timeout_5m="${DDOS_PENALTY_TIMEOUT_5M:-5m}"
    local timeout_1h="${DDOS_PENALTY_TIMEOUT_1H:-1h}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/06-ddos-penalty-sets.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Penalty Ladder Sets
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# Penalty ladder progression:
#   1. ${set_limit_10s} -> Light rate limiting (${timeout_10s} auto-clear)
#   2. ${set_limit_5m}  -> Moderate rate limiting (${timeout_5m} auto-clear)
#   3. ${set_drop_5m}   -> Packet drop (${timeout_5m} auto-clear)
#   4. ${set_ban_1h}    -> Full ban (${timeout_1h} auto-clear)
#
# IPs are added programmatically and auto-expire after timeout.

# --- IPv4 Penalty Sets ---
add set ${table_ipv4} ${set_limit_10s} { type ipv4_addr; flags timeout; timeout ${timeout_10s}; comment "Light rate limit"; }
add set ${table_ipv4} ${set_limit_5m} { type ipv4_addr; flags timeout; timeout ${timeout_5m}; comment "Moderate rate limit"; }
add set ${table_ipv4} ${set_drop_5m} { type ipv4_addr; flags timeout; timeout ${timeout_5m}; comment "Packet drop"; }
add set ${table_ipv4} ${set_ban_1h} { type ipv4_addr; flags timeout; timeout ${timeout_1h}; comment "Full ban"; }

# --- IPv6 Penalty Sets ---
add set ${table_ipv6} ${set_limit_10s}6 { type ipv6_addr; flags timeout; timeout ${timeout_10s}; comment "Light rate limit"; }
add set ${table_ipv6} ${set_limit_5m}6 { type ipv6_addr; flags timeout; timeout ${timeout_5m}; comment "Moderate rate limit"; }
add set ${table_ipv6} ${set_drop_5m}6 { type ipv6_addr; flags timeout; timeout ${timeout_5m}; comment "Packet drop"; }
add set ${table_ipv6} ${set_ban_1h}6 { type ipv6_addr; flags timeout; timeout ${timeout_1h}; comment "Full ban"; }
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render penalty ladder enforcement rules
# Writes to: /etc/nftban/rules.d/07-ddos-penalty-enforce.nft
nft_fragment_render_ddos_penalty_enforce() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_PENALTY_CHAIN:-ddos_penalty}"

    # Set names
    local set_limit_10s="${DDOS_PENALTY_SET_LIMIT_10S:-ddos_limit_10s}"
    local set_limit_5m="${DDOS_PENALTY_SET_LIMIT_5M:-ddos_limit_5m}"
    local set_drop_5m="${DDOS_PENALTY_SET_DROP_5M:-ddos_drop_5m}"
    local set_ban_1h="${DDOS_PENALTY_SET_BAN_1H:-ddos_ban_1h}"

    # Rate limits for penalty levels
    local limit_10s_rate="${DDOS_PENALTY_LIMIT_10S_RATE:-50/second}"
    local limit_10s_burst="${DDOS_PENALTY_LIMIT_10S_BURST:-100}"
    local limit_5m_rate="${DDOS_PENALTY_LIMIT_5M_RATE:-10/second}"
    local limit_5m_burst="${DDOS_PENALTY_LIMIT_5M_BURST:-20}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/07-ddos-penalty-enforce.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Penalty Ladder Enforcement
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# Enforcement order (most severe first):
#   1. Ban set     -> drop immediately
#   2. Drop set    -> drop
#   3. Limit 5m    -> severe rate limit
#   4. Limit 10s   -> moderate rate limit

# --- IPv4 Enforcement Chain ---
add chain ${table_ipv4} ${chain}
flush chain ${table_ipv4} ${chain}

# Level 4: Full ban - drop all packets immediately
add rule ${table_ipv4} ${chain} ip saddr @${set_ban_1h} counter drop comment "Penalty: 1h ban"

# Level 3: Drop set - drop all packets
add rule ${table_ipv4} ${chain} ip saddr @${set_drop_5m} counter drop comment "Penalty: 5m drop"

# Level 2: Severe rate limit (5m)
add rule ${table_ipv4} ${chain} ip saddr @${set_limit_5m} limit rate ${limit_5m_rate} burst ${limit_5m_burst} packets counter return comment "Penalty: 5m rate limit OK"
add rule ${table_ipv4} ${chain} ip saddr @${set_limit_5m} counter drop comment "Penalty: 5m rate exceeded"

# Level 1: Light rate limit (10s)
add rule ${table_ipv4} ${chain} ip saddr @${set_limit_10s} limit rate ${limit_10s_rate} burst ${limit_10s_burst} packets counter return comment "Penalty: 10s rate limit OK"
add rule ${table_ipv4} ${chain} ip saddr @${set_limit_10s} counter drop comment "Penalty: 10s rate exceeded"

# Return for non-penalized traffic
add rule ${table_ipv4} ${chain} return

# --- IPv6 Enforcement Chain ---
add chain ${table_ipv6} ${chain}
flush chain ${table_ipv6} ${chain}

# Level 4: Full ban - drop all packets immediately
add rule ${table_ipv6} ${chain} ip6 saddr @${set_ban_1h}6 counter drop comment "Penalty: 1h ban"

# Level 3: Drop set - drop all packets
add rule ${table_ipv6} ${chain} ip6 saddr @${set_drop_5m}6 counter drop comment "Penalty: 5m drop"

# Level 2: Severe rate limit (5m)
add rule ${table_ipv6} ${chain} ip6 saddr @${set_limit_5m}6 limit rate ${limit_5m_rate} burst ${limit_5m_burst} packets counter return comment "Penalty: 5m rate limit OK"
add rule ${table_ipv6} ${chain} ip6 saddr @${set_limit_5m}6 counter drop comment "Penalty: 5m rate exceeded"

# Level 1: Light rate limit (10s)
add rule ${table_ipv6} ${chain} ip6 saddr @${set_limit_10s}6 limit rate ${limit_10s_rate} burst ${limit_10s_burst} packets counter return comment "Penalty: 10s rate limit OK"
add rule ${table_ipv6} ${chain} ip6 saddr @${set_limit_10s}6 counter drop comment "Penalty: 10s rate exceeded"

# Return for non-penalized traffic
add rule ${table_ipv6} ${chain} return
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render penalty ladder jump rules
nft_fragment_render_ddos_penalty_jump() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_PENALTY_CHAIN:-ddos_penalty}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/08-ddos-penalty-jump.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Penalty Ladder - Jump Rules
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY

add rule ${table_ipv4} input jump ${chain} comment "DDoS penalty ladder"
add rule ${table_ipv6} input jump ${chain} comment "DDoS penalty ladder"
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render penalty ladder cleanup fragment (for disable)
nft_fragment_render_ddos_penalty_cleanup() {
    local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${DDOS_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${DDOS_PENALTY_CHAIN:-ddos_penalty}"

    # Set names
    local set_limit_10s="${DDOS_PENALTY_SET_LIMIT_10S:-ddos_limit_10s}"
    local set_limit_5m="${DDOS_PENALTY_SET_LIMIT_5M:-ddos_limit_5m}"
    local set_drop_5m="${DDOS_PENALTY_SET_DROP_5M:-ddos_drop_5m}"
    local set_ban_1h="${DDOS_PENALTY_SET_BAN_1H:-ddos_ban_1h}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/99-ddos-penalty-cleanup.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan DDoS Penalty Ladder - CLEANUP
# Generated: ${timestamp}
# Managed by nftband
#
# Flushes penalty chain and deletes penalty sets

# Flush enforcement chains
flush chain ${table_ipv4} ${chain}
flush chain ${table_ipv6} ${chain}

# Delete IPv4 penalty sets
delete set ${table_ipv4} ${set_limit_10s}
delete set ${table_ipv4} ${set_limit_5m}
delete set ${table_ipv4} ${set_drop_5m}
delete set ${table_ipv4} ${set_ban_1h}

# Delete IPv6 penalty sets
delete set ${table_ipv6} ${set_limit_10s}6
delete set ${table_ipv6} ${set_limit_5m}6
delete set ${table_ipv6} ${set_drop_5m}6
delete set ${table_ipv6} ${set_ban_1h}6
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
add rule ${table_ipv4} ${chain} udp dport { ${udp_ports} } accept

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
# HTTP BOT GUARD FRAGMENTS (v1.21.0, sets v1.21.4)
# =============================================================================

# Ensure HTTP Bot Guard nft sets exist (idempotent)
# Since v1.21.4 these sets are in the base schema (nftables.conf).
# This function is for systems that haven't rebuilt their schema yet.
# Writes to: /etc/nftban/rules.d/14-http-botguard-sets.nft
nft_fragment_render_http_botguard_sets() {
    local table_ipv4="${BOTGUARD_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${BOTGUARD_NFT_TABLE_IPV6:-ip6 nftban}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/14-http-botguard-sets.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan HTTP Bot Guard - Set Definitions
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# These sets are always present (cost nothing when empty).
# Since v1.21.4 they are also in the base nftables.conf schema.
# This fragment ensures they exist on systems not yet rebuilt.

# --- IPv4 Bot Guard Sets ---
add set ${table_ipv4} http_bot_suspect { type ipv4_addr; flags timeout; comment "Kernel-populated HTTP bot suspects"; }
add set ${table_ipv4} http_bot_pending { type ipv4_addr; flags timeout; comment "Awaiting bot classification"; }
add set ${table_ipv4} http_bot_allow { type ipv4_addr; flags timeout; comment "Verified allowed crawlers"; }
add set ${table_ipv4} http_bot_grey { type ipv4_addr; flags timeout; comment "Suspicious bots, throttled"; }
add set ${table_ipv4} http_bot_ban { type ipv4_addr; flags timeout; comment "Denied/malicious bots"; }
add set ${table_ipv4} http_bot_emergency { type ipv4_addr; flags timeout; comment "Emergency pressure blocks"; }

# --- IPv6 Bot Guard Sets ---
add set ${table_ipv6} http_bot_suspect6 { type ipv6_addr; flags timeout; comment "Kernel-populated HTTP bot suspects"; }
add set ${table_ipv6} http_bot_pending6 { type ipv6_addr; flags timeout; comment "Awaiting bot classification"; }
add set ${table_ipv6} http_bot_allow6 { type ipv6_addr; flags timeout; comment "Verified allowed crawlers"; }
add set ${table_ipv6} http_bot_grey6 { type ipv6_addr; flags timeout; comment "Suspicious bots, throttled"; }
add set ${table_ipv6} http_bot_ban6 { type ipv6_addr; flags timeout; comment "Denied/malicious bots"; }
add set ${table_ipv6} http_bot_emergency6 { type ipv6_addr; flags timeout; comment "Emergency pressure blocks"; }
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render HTTP Bot Guard enforcement chain fragment
# Order: allow(bypass) → ban(drop) → emergency(drop) → grey(throttle) → pending(light throttle) → suspect meter → return
# Writes to: /etc/nftban/rules.d/15-http-botguard.nft
nft_fragment_render_http_botguard() {
    local table_ipv4="${BOTGUARD_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${BOTGUARD_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${BOTGUARD_NFT_CHAIN:-http_bot_guard}"

    # Suspect marking meter config
    local suspect_rate="${HTTP_BOT_SUSPECT_RATE:-30/second}"
    local suspect_burst="${HTTP_BOT_SUSPECT_BURST:-60}"
    local suspect_timeout="${HTTP_BOT_SUSPECT_TIMEOUT:-5m}"

    # Grey throttle config
    local grey_rate="${HTTP_BOT_GREY_RATE:-5/second}"
    local grey_burst="${HTTP_BOT_GREY_BURST:-10}"

    # Pending throttle config
    local pending_rate="${HTTP_BOT_PENDING_RATE:-15/second}"
    local pending_burst="${HTTP_BOT_PENDING_BURST:-30}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/15-http-botguard.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan HTTP Bot Guard - Enforcement Chain
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY
#
# Architecture: Kernel DETECTS, Go DECIDES, Kernel ENFORCES
# Set ownership: suspect=kernel, allow/ban/grey/emergency/pending=Go
#
# Chain order (most permissive → most restrictive):
#   1. Allow set: bypass throttle (verified crawlers)
#   2. Ban set: full drop (denied/malicious bots)
#   3. Emergency set: immediate drop (pressure mode)
#   4. Grey set: heavy throttle (suspicious bots)
#   5. Pending set: light throttle (awaiting classification)
#   6. Suspect meter: mark new suspects for Go classification
#   7. Return: back to input chain

# --- IPv4 HTTP Bot Guard ---
add chain ${table_ipv4} ${chain}
flush chain ${table_ipv4} ${chain}

# 1. Allow set: verified crawlers bypass throttle
add rule ${table_ipv4} ${chain} ip saddr @http_bot_allow accept comment "BotGuard: verified crawler allow"

# 2. Ban set: denied/malicious bots get dropped
add rule ${table_ipv4} ${chain} ip saddr @http_bot_ban counter drop comment "BotGuard: denied bot ban"

# 3. Emergency set: pressure mode immediate drop
add rule ${table_ipv4} ${chain} ip saddr @http_bot_emergency counter drop comment "BotGuard: emergency drop"

# 4. Grey set: suspicious bots get heavy throttle
add rule ${table_ipv4} ${chain} ip saddr @http_bot_grey tcp dport {80, 443} ct state new meter http_bot_grey_meter { ip saddr limit rate ${grey_rate} burst ${grey_burst} packets } accept comment "BotGuard: grey throttle OK"
add rule ${table_ipv4} ${chain} ip saddr @http_bot_grey tcp dport {80, 443} counter drop comment "BotGuard: grey throttle exceeded"

# 5. Pending set: awaiting classification, light throttle
add rule ${table_ipv4} ${chain} ip saddr @http_bot_pending tcp dport {80, 443} ct state new meter http_bot_pending_meter { ip saddr limit rate ${pending_rate} burst ${pending_burst} packets } accept comment "BotGuard: pending throttle OK"
add rule ${table_ipv4} ${chain} ip saddr @http_bot_pending tcp dport {80, 443} counter drop comment "BotGuard: pending throttle exceeded"

# 6. Suspect meter: mark IPs exceeding rate for Go classification
add rule ${table_ipv4} ${chain} tcp dport {80, 443} ct state new meter http_bot_meter { ip saddr limit rate over ${suspect_rate} burst ${suspect_burst} packets } add @http_bot_suspect { ip saddr timeout ${suspect_timeout} } comment "BotGuard: suspect marking"

# 7. Return to input chain
add rule ${table_ipv4} ${chain} return

# --- IPv6 HTTP Bot Guard ---
add chain ${table_ipv6} ${chain}
flush chain ${table_ipv6} ${chain}

# 1. Allow set
add rule ${table_ipv6} ${chain} ip6 saddr @http_bot_allow6 accept comment "BotGuard: verified crawler allow"

# 2. Ban set
add rule ${table_ipv6} ${chain} ip6 saddr @http_bot_ban6 counter drop comment "BotGuard: denied bot ban"

# 3. Emergency set
add rule ${table_ipv6} ${chain} ip6 saddr @http_bot_emergency6 counter drop comment "BotGuard: emergency drop"

# 4. Grey set
add rule ${table_ipv6} ${chain} ip6 saddr @http_bot_grey6 tcp dport {80, 443} ct state new meter http_bot_grey_meter6 { ip6 saddr limit rate ${grey_rate} burst ${grey_burst} packets } accept comment "BotGuard: grey throttle OK"
add rule ${table_ipv6} ${chain} ip6 saddr @http_bot_grey6 tcp dport {80, 443} counter drop comment "BotGuard: grey throttle exceeded"

# 5. Pending set
add rule ${table_ipv6} ${chain} ip6 saddr @http_bot_pending6 tcp dport {80, 443} ct state new meter http_bot_pending_meter6 { ip6 saddr limit rate ${pending_rate} burst ${pending_burst} packets } accept comment "BotGuard: pending throttle OK"
add rule ${table_ipv6} ${chain} ip6 saddr @http_bot_pending6 tcp dport {80, 443} counter drop comment "BotGuard: pending throttle exceeded"

# 6. Suspect meter
add rule ${table_ipv6} ${chain} tcp dport {80, 443} ct state new meter http_bot_meter6 { ip6 saddr limit rate over ${suspect_rate} burst ${suspect_burst} packets } add @http_bot_suspect6 { ip6 saddr timeout ${suspect_timeout} } comment "BotGuard: suspect marking"

# 7. Return
add rule ${table_ipv6} ${chain} return
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render HTTP Bot Guard jump rules fragment
# Jump is placed BEFORE ddos_protection so bot classification runs first
nft_fragment_render_http_botguard_jump() {
    local table_ipv4="${BOTGUARD_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${BOTGUARD_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${BOTGUARD_NFT_CHAIN:-http_bot_guard}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/16-http-botguard-jump.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan HTTP Bot Guard - Jump Rules
# Generated: ${timestamp}
# Managed by nftband - DO NOT EDIT MANUALLY

add rule ${table_ipv4} input tcp dport {80, 443} jump ${chain} comment "HTTP Bot Guard"
add rule ${table_ipv6} input tcp dport {80, 443} jump ${chain} comment "HTTP Bot Guard"
EOF
    )

    _nft_fragment_write "$fragment_path" "$content" || {
        echo "ERROR: Failed to write fragment: $fragment_path" >&2
        return 1
    }

    echo "$fragment_path"
}

# Render HTTP Bot Guard cleanup fragment (for disable)
nft_fragment_render_http_botguard_cleanup() {
    local table_ipv4="${BOTGUARD_NFT_TABLE_IPV4:-ip nftban}"
    local table_ipv6="${BOTGUARD_NFT_TABLE_IPV6:-ip6 nftban}"
    local chain="${BOTGUARD_NFT_CHAIN:-http_bot_guard}"

    nft_fragment_init || return 1

    local fragment_path="${NFTBAN_FRAGMENT_DIR}/99-http-botguard-cleanup.nft"
    local timestamp
    timestamp=$(date -Iseconds)

    local content
    content=$(cat <<EOF
#!/usr/sbin/nft -f
# NFTBan HTTP Bot Guard - CLEANUP
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
        ddos-sanity|ddos_sanity)
            fragment_path=$(nft_fragment_render_ddos_sanity) || return 1
            nft_fragment_apply "$fragment_path" || return 1

            # Add jump if not present
            local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
            local chain="${DDOS_SANITY_CHAIN:-ddos_sanity}"
            if ! nft_fragment_has_jump "$table_ipv4" "$chain"; then
                local jump_path
                jump_path=$(nft_fragment_render_ddos_sanity_jump) || return 1
                nft_fragment_apply "$jump_path" || return 1
            fi
            ;;
        ddos-synproxy|ddos_synproxy|synproxy)
            # SYNPROXY requires raw table rules first
            local raw_path
            raw_path=$(nft_fragment_render_synproxy_raw) || return 1
            nft_fragment_apply "$raw_path" || return 1

            fragment_path=$(nft_fragment_render_synproxy) || return 1
            nft_fragment_apply "$fragment_path" || return 1

            # Add jump if not present
            local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
            local chain="${DDOS_SYNPROXY_CHAIN:-ddos_synproxy}"
            if ! nft_fragment_has_jump "$table_ipv4" "$chain"; then
                local jump_path
                jump_path=$(nft_fragment_render_synproxy_jump) || return 1
                nft_fragment_apply "$jump_path" || return 1
            fi
            ;;
        ddos-prefix|ddos_prefix)
            fragment_path=$(nft_fragment_render_ddos_prefix) || return 1
            nft_fragment_apply "$fragment_path" || return 1

            # Add jump if not present
            local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
            local chain="${DDOS_PREFIX_CHAIN:-ddos_prefix}"
            if ! nft_fragment_has_jump "$table_ipv4" "$chain"; then
                local jump_path
                jump_path=$(nft_fragment_render_ddos_prefix_jump) || return 1
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
        ddos-ban|ddos_ban)
            # Create ban sets first
            local set_path
            set_path=$(nft_fragment_render_ddos_ban_set) || return 1
            nft_fragment_apply "$set_path" || return 1

            # Then create enforcement chain
            fragment_path=$(nft_fragment_render_ddos_ban_enforce) || return 1
            nft_fragment_apply "$fragment_path" || return 1

            # Add jump if not present
            local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
            local chain="ddos_ban_enforce"
            if ! nft_fragment_has_jump "$table_ipv4" "$chain"; then
                local jump_path
                jump_path=$(nft_fragment_render_ddos_ban_jump) || return 1
                nft_fragment_apply "$jump_path" || return 1
            fi
            ;;
        ddos-penalty|ddos_penalty)
            # Create penalty ladder sets first
            local set_path
            set_path=$(nft_fragment_render_ddos_penalty_sets) || return 1
            nft_fragment_apply "$set_path" || return 1

            # Then create enforcement chain
            fragment_path=$(nft_fragment_render_ddos_penalty_enforce) || return 1
            nft_fragment_apply "$fragment_path" || return 1

            # Add jump if not present
            local table_ipv4="${DDOS_NFT_TABLE_IPV4:-ip nftban}"
            local chain="${DDOS_PENALTY_CHAIN:-ddos_penalty}"
            if ! nft_fragment_has_jump "$table_ipv4" "$chain"; then
                local jump_path
                jump_path=$(nft_fragment_render_ddos_penalty_jump) || return 1
                nft_fragment_apply "$jump_path" || return 1
            fi
            ;;
        http-botguard|http_botguard|botguard)
            # Create sets first (idempotent — no-op if sets already in schema)
            local set_path
            set_path=$(nft_fragment_render_http_botguard_sets) || return 1
            nft_fragment_apply "$set_path" || return 1

            # Clean up stale meters from previous enable before re-applying rules
            # Meters are stored as sets — must flush referencing rules first
            local bg_table_v4="${BOTGUARD_NFT_TABLE_IPV4:-ip nftban}"
            local bg_table_v6="${BOTGUARD_NFT_TABLE_IPV6:-ip6 nftban}"
            local bg_chain="${BOTGUARD_NFT_CHAIN:-http_bot_guard}"
            nft flush chain $bg_table_v4 "$bg_chain" 2>/dev/null || true
            nft delete set $bg_table_v4 http_bot_grey_meter 2>/dev/null || true
            nft delete set $bg_table_v4 http_bot_pending_meter 2>/dev/null || true
            nft delete set $bg_table_v4 http_bot_meter 2>/dev/null || true
            nft flush chain $bg_table_v6 "$bg_chain" 2>/dev/null || true
            nft delete set $bg_table_v6 http_bot_grey_meter6 2>/dev/null || true
            nft delete set $bg_table_v6 http_bot_pending_meter6 2>/dev/null || true
            nft delete set $bg_table_v6 http_bot_meter6 2>/dev/null || true

            # Then create enforcement chain + rules
            fragment_path=$(nft_fragment_render_http_botguard) || return 1
            nft_fragment_apply "$fragment_path" || return 1

            # Add jump if not present
            local table_ipv4="${BOTGUARD_NFT_TABLE_IPV4:-ip nftban}"
            local chain="${BOTGUARD_NFT_CHAIN:-http_bot_guard}"
            if ! nft_fragment_has_jump "$table_ipv4" "$chain"; then
                local jump_path
                jump_path=$(nft_fragment_render_http_botguard_jump) || return 1
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
        ddos-sanity|ddos_sanity)
            fragment_path=$(nft_fragment_render_ddos_sanity_cleanup) || return 1
            nft_fragment_apply "$fragment_path" || return 1
            ;;
        ddos-synproxy|ddos_synproxy|synproxy)
            # First, remove nftban-managed rules from raw prerouting chains
            # (targeted deletion to avoid destroying Docker/K8s rules)
            _nft_cleanup_synproxy_raw
            # Then flush nftban-owned SYNPROXY chains
            fragment_path=$(nft_fragment_render_synproxy_cleanup) || return 1
            nft_fragment_apply "$fragment_path" || return 1
            ;;
        ddos-prefix|ddos_prefix)
            fragment_path=$(nft_fragment_render_ddos_prefix_cleanup) || return 1
            nft_fragment_apply "$fragment_path" || return 1
            ;;
        ddos-classic|ddos_classic)
            fragment_path=$(nft_fragment_render_ddos_classic_cleanup) || return 1
            nft_fragment_apply "$fragment_path" || return 1
            ;;
        ddos-ban|ddos_ban)
            fragment_path=$(nft_fragment_render_ddos_ban_cleanup) || return 1
            nft_fragment_apply "$fragment_path" || return 1
            ;;
        ddos-penalty|ddos_penalty)
            fragment_path=$(nft_fragment_render_ddos_penalty_cleanup) || return 1
            nft_fragment_apply "$fragment_path" || return 1
            ;;
        http-botguard|http_botguard|botguard)
            fragment_path=$(nft_fragment_render_http_botguard_cleanup) || return 1
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
export -f nft_fragment_render_ddos_sanity
export -f nft_fragment_render_ddos_sanity_jump
export -f nft_fragment_render_ddos_sanity_cleanup
export -f nft_fragment_render_synproxy
export -f nft_fragment_render_synproxy_raw
export -f nft_fragment_render_synproxy_jump
export -f _nft_cleanup_synproxy_raw
export -f nft_fragment_render_synproxy_cleanup
export -f nft_fragment_render_ddos_prefix
export -f nft_fragment_render_ddos_prefix_jump
export -f nft_fragment_render_ddos_prefix_cleanup
export -f nft_fragment_render_ddos_classic
export -f nft_fragment_render_ddos_classic_jump
export -f nft_fragment_render_ddos_classic_cleanup
export -f nft_fragment_render_ddos_ban_set
export -f nft_fragment_render_ddos_ban_enforce
export -f nft_fragment_render_ddos_ban_jump
export -f nft_fragment_render_ddos_ban_cleanup
export -f nft_fragment_render_ddos_penalty_sets
export -f nft_fragment_render_ddos_penalty_enforce
export -f nft_fragment_render_ddos_penalty_jump
export -f nft_fragment_render_ddos_penalty_cleanup
export -f nft_fragment_render_http_botguard_sets
export -f nft_fragment_render_http_botguard
export -f nft_fragment_render_http_botguard_jump
export -f nft_fragment_render_http_botguard_cleanup
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
        render-sanity)
            nft_fragment_render_ddos_sanity
            ;;
        render-synproxy)
            nft_fragment_render_synproxy_raw
            nft_fragment_render_synproxy
            ;;
        render-prefix)
            nft_fragment_render_ddos_prefix
            ;;
        render-ddos)
            nft_fragment_render_ddos_classic
            ;;
        render-ban)
            nft_fragment_render_ddos_ban_set
            nft_fragment_render_ddos_ban_enforce
            ;;
        render-penalty)
            nft_fragment_render_ddos_penalty_sets
            nft_fragment_render_ddos_penalty_enforce
            ;;
        render-botguard)
            nft_fragment_render_http_botguard
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
            echo "Usage: $0 {render-portscan|render-sanity|render-synproxy|render-prefix|render-ddos|render-ban|render-penalty|render-botguard|enable <module>|disable <module>|list}"
            exit 1
            ;;
    esac
fi
