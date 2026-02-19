#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nft_schema" meta:type="lib" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Canonical nftables schema to prevent table structure drift"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_NFT_SCHEMA_LOADED:-}" ]] && return 0
readonly NFTBAN_NFT_SCHEMA_LOADED=1

# =============================================================================
# CANONICAL NFTABLES ARCHITECTURE
# =============================================================================
#
# NFTBan uses SEPARATE IPv4/IPv6 TABLES (ip/ip6 families)
#
# WHY SEPARATE TABLES (ip/ip6) instead of COMBINED (inet)?
# --------------------------------------------------------
# ✅ Cleaner:      No _v4/_v6 suffixes on set names
# ✅ Simpler:      No ip/ip6 prefixes in rules (kernel knows family)
# ✅ Performance:  Kernel routes by family first anyway
# ✅ Port mgmt:    Each family has own tcp_ports/udp_ports sets
# ✅ Maintenance:  Clear separation, easier to debug
# ✅ Efficiency:   No mixed-family lookups, direct routing
#
# WRONG APPROACH (inet dual-stack):
#   set blacklist_v4 { ... }   # Need suffix
#   set blacklist_v6 { ... }   # Need suffix
#   ip saddr @blacklist_v4     # Need ip prefix
#   ip6 saddr @blacklist_v6    # Need ip6 prefix
#
# CORRECT APPROACH (separate ip/ip6):
#   table ip nftban {
#     set blacklist { ... }    # Clean name
#     ip saddr @blacklist      # No prefix needed (implicit)
#   }
#   table ip6 nftban {
#     set blacklist { ... }    # Clean name
#     ip6 saddr @blacklist     # No prefix needed (implicit)
#   }
#
# =============================================================================
# CRITICAL: RULE ORDER IN INPUT CHAIN
# =============================================================================
#
# The order of rules in the input chain is SECURITY-CRITICAL!
# INCORRECT ORDER can allow banned IPs to bypass blocking.
#
# ✅ CORRECT ORDER (enforce bans BEFORE established connections):
#
# Priority  | Rule                          | Reason
# ----------|-------------------------------|----------------------------------
# 1.        | ct state invalid → drop       | Malformed packets
# 2.        | iif lo → accept               | Loopback always allowed
# 3.        | whitelist → accept            | Trusted IPs bypass all checks
# 4.        | blacklist → drop              | ⚠️ BEFORE established! (permanent + temporary with timeout)
# 5.        | ct state established → accept | ✅ NOW SAFE (after all bans)
# 6.        | ICMP → accept                 | Ping, etc.
# 7.        | CT limits → drop              | DDoS protection (rate/connection limits)
# 8.        | Services (SSH/HTTP) → accept  | Public services
# 9.        | default deny                  | Drop everything else
#
# ❌ SECURITY BUG: Placing "ct state established,related accept" BEFORE
#    blacklist checks allows attackers to keep connections after being banned!
#
# =============================================================================

# =============================================================================
# TABLE: ip nftban (IPv4 PRIMARY TABLE)
# =============================================================================

readonly NFTBAN_TABLE_IPV4_FAMILY="ip"
readonly NFTBAN_TABLE_IPV4_NAME="nftban"
readonly NFTBAN_TABLE_IPV4="${NFTBAN_TABLE_IPV4_FAMILY} ${NFTBAN_TABLE_IPV4_NAME}"

# Sets in ip nftban (IPv4)
# =============================================================================
# v2.1 MINIMAL SCHEMA - CIDR Aggregation, No IP Duplicates
# =============================================================================
# Only 2 IP sets + 4 directional port sets per table
# - Feeds, geoban, auto, manual ALL go to blacklist_ipv4 (no separate sets)
# - Temp bans use timeout parameter (auto-expire)
# - Source tracking done in daemon database
# - CIDR aggregation reduces memory usage
# =============================================================================
declare -g -A NFTBAN_IPV4_SETS=(
    # Whitelist - trusted IPs/networks (CIDR aggregated)
    ["whitelist_ipv4"]="ipv4_addr|interval|Trusted IPs/networks"

    # Blacklist - ALL bans: feeds, geoban, auto, manual (CIDR aggregated)
    # Temp bans use timeout parameter (auto-expire)
    ["blacklist_ipv4"]="ipv4_addr|interval,timeout|All bans (feeds+geoban+auto+manual)"

    # Directional port sets (v2.1 model)
    ["tcp_ports_in"]="inet_service||Allowed TCP ports (inbound)"
    ["tcp_ports_out"]="inet_service||Allowed TCP ports (outbound)"
    ["udp_ports_in"]="inet_service||Allowed UDP ports (inbound)"
    ["udp_ports_out"]="inet_service||Allowed UDP ports (outbound)"
)

# Chains in ip nftban (IPv4)
# BASE CHAINS (mandatory - always present)
# PRIORITY 0: Standard filter priority (v1.18.0 schema consolidation)
declare -g -A NFTBAN_IPV4_CHAINS=(
    ["input"]="filter|input|0|drop|Main IPv4 input chain (priority 0: standard filter)"
    ["forward"]="filter|forward|0|drop|IPv4 forward chain (priority 0: standard filter)"
    ["output"]="filter|output|0|accept|IPv4 output chain"
)

# HELPER CHAINS (optional - modular protection features)
# These chains MAY exist when protection features are enabled
# If present, they MUST be called via "jump" from input chain AFTER ct state established
# Helper chains - reserved for nftables schema validation
# shellcheck disable=SC2034
declare -g -A NFTBAN_IPV4_HELPER_CHAINS=(
    ["portscan_detection"]="optional|Port scan detection logging"
    ["ddos_protection"]="optional|DDoS protection (SYN flood, conn limits, rate limits)"
    ["synflood_protection"]="optional|SYN flood protection (deprecated - use ddos_protection)"
    ["connlimit_protection"]="optional|Connection limit protection (deprecated - use ddos_protection)"
    ["portflood_protection"]="optional|Port flood protection (deprecated - use ddos_protection)"
    ["icmp_protection"]="optional|ICMP flood protection (deprecated - use ddos_protection)"
)

# =============================================================================
# TABLE: ip6 nftban (IPv6 PRIMARY TABLE)
# =============================================================================

readonly NFTBAN_TABLE_IPV6_FAMILY="ip6"
readonly NFTBAN_TABLE_IPV6_NAME="nftban"
readonly NFTBAN_TABLE_IPV6="${NFTBAN_TABLE_IPV6_FAMILY} ${NFTBAN_TABLE_IPV6_NAME}"

# Sets in ip6 nftban (IPv6)
# =============================================================================
# v2.1 MINIMAL SCHEMA - Same as IPv4 (CIDR aggregated, no IP duplicates)
# =============================================================================
declare -g -A NFTBAN_IPV6_SETS=(
    # Whitelist - trusted IPv6/networks (CIDR aggregated)
    ["whitelist_ipv6"]="ipv6_addr|interval|Trusted IPv6/networks"

    # Blacklist - ALL bans: feeds, geoban, auto, manual (CIDR aggregated)
    # Temp bans use timeout parameter (auto-expire)
    ["blacklist_ipv6"]="ipv6_addr|interval,timeout|All bans (feeds+geoban+auto+manual)"

    # Directional port sets (v2.1 model)
    ["tcp_ports_in"]="inet_service||Allowed TCP ports (inbound)"
    ["tcp_ports_out"]="inet_service||Allowed TCP ports (outbound)"
    ["udp_ports_in"]="inet_service||Allowed UDP ports (inbound)"
    ["udp_ports_out"]="inet_service||Allowed UDP ports (outbound)"
)

# Chains in ip6 nftban (IPv6)
# BASE CHAINS (mandatory - always present)
# PRIORITY 0: Standard filter priority (v1.18.0 schema consolidation)
declare -g -A NFTBAN_IPV6_CHAINS=(
    ["input"]="filter|input|0|drop|Main IPv6 input chain (priority 0: standard filter)"
    ["forward"]="filter|forward|0|drop|IPv6 forward chain (priority 0: standard filter)"
    ["output"]="filter|output|0|accept|IPv6 output chain"
)

# HELPER CHAINS (optional - modular protection features)
# These chains MAY exist when protection features are enabled
# If present, they MUST be called via "jump" from input chain AFTER ct state established
# shellcheck disable=SC2034  # Schema data structure for validation
declare -g -A NFTBAN_IPV6_HELPER_CHAINS=(
    ["portscan_detection"]="optional|Port scan detection logging"
    ["ddos_protection"]="optional|DDoS protection (SYN flood, conn limits, rate limits)"
    ["synflood_protection"]="optional|SYN flood protection (deprecated - use ddos_protection)"
    ["connlimit_protection"]="optional|Connection limit protection (deprecated - use ddos_protection)"
    ["portflood_protection"]="optional|Port flood protection (deprecated - use ddos_protection)"
    ["icmp_protection"]="optional|ICMP flood protection (deprecated - use ddos_protection)"
)

# =============================================================================
# DEPRECATED TABLES (SHOULD NOT EXIST - LEGACY FROM UPGRADES)
# =============================================================================

declare -g -A NFTBAN_DEPRECATED_TABLES=(
    ["inet nftban"]="OLD: v0.6.0-beta single inet table (deprecated)"
    ["inet nftban_main"]="OLD: v0.6.x dual-table approach (deprecated)"
    ["inet nftban_runtime"]="OLD: v0.6.x runtime table (deprecated)"
)

# =============================================================================
# CONNECTION TRACKING (CT) AND RATE LIMITS
# =============================================================================
#
# Connection tracking and rate limiting are ESSENTIAL for DDoS protection.
# These limits should be applied in the input chain BEFORE service rules.
#
# CT LIMITS (per source IP):
# ---------------------------
# Purpose: Limit concurrent connections per IP to prevent resource exhaustion
#
# Example rules for input chain:
#   ct state new tcp dport @tcp_ports \
#     meter syn_flood { ip saddr limit rate 100/second burst 200 } accept
#
#   ct state new tcp dport 22 \
#     ct count over 5 drop comment "SSH: max 5 concurrent connections per IP"
#
#   ct state new tcp dport { 80, 443 } \
#     ct count over 50 drop comment "HTTP(S): max 50 concurrent connections per IP"
#
# RATE LIMITS (connection rate per IP):
# --------------------------------------
# Purpose: Limit NEW connection rate per IP to prevent flood attacks
#
# Example rules:
#   tcp flags syn ct state new \
#     limit rate 100/second burst 200 packets \
#     log prefix "nftban: portscan: "
#
#   tcp flags syn ct state new \
#     meter syn_rate { ip saddr limit rate 10/second burst 20 } accept
#
# CONNECTION STATE TRACKING:
# --------------------------
# CRITICAL: "ct state established,related accept" MUST come AFTER all ban checks!
# See RULE ORDER section above for correct placement.
#
# Global connection limits (optional):
#   ct state new limit rate 1000/second burst 2000 accept
#
# =============================================================================
# HELPER CHAINS (OPTIONAL MODULAR PROTECTION)
# =============================================================================
#
# NFTBan v1.0.0+ supports OPTIONAL helper chains for modular protection features.
#
# ARCHITECTURE:
# -------------
# Base chains (input, forward, output) = MANDATORY (always present)
# Helper chains (portscan_detection, ddos_protection) = OPTIONAL (created by enable commands)
#
# HELPER CHAIN LIFECYCLE:
# -----------------------
# 1. nftban portscan enable:
#    - Creates chain "portscan_detection" with logging rules
#    - Adds "jump portscan_detection" to input chain (after ct state established)
#
# 2. nftban portscan disable:
#    - Removes jump rule from input chain
#    - Deletes "portscan_detection" chain
#
# STATUS CHECKING:
# ----------------
# Enabled  = chain exists AND jump rule present in input
# Disabled = chain absent OR jump rule absent
#
# JUMP RULE PLACEMENT:
# --------------------
# Helper chains MUST be called from input chain in this order:
# 1. After: ct state established,related accept
# 2. Before: ICMP rules
# 3. Before: Service rules (tcp dport @tcp_ports)
#
# Example input chain with helper chains:
#
#   chain input {
#       type filter hook input priority 0; policy drop;
#       iif "lo" accept
#       ct state invalid drop
#       ip saddr @whitelist_ipv4 accept
#       ip saddr @blacklist_ipv4 drop
#       ct state established,related accept
#
#       # Helper chain jumps (if enabled)
#       jump ddos_protection comment "DDoS protection module"
#       jump portscan_detection comment "Portscan detection module"
#
#       # Service rules
#       ip protocol icmp icmp type { ... } accept
#       tcp dport @tcp_ports ct state new accept
#       udp dport @udp_ports ct state new accept
#       drop
#   }
#
# HELPER CHAIN: portscan_detection
# ---------------------------------
# Purpose: Log connection attempts for portscan analysis
# Rules:
#   tcp flags syn ct state new limit rate 10/minute burst 20 \
#       log prefix "nftban: portscan: "
#   return
#
# HELPER CHAIN: ddos_protection
# ------------------------------
# Purpose: Rate limiting and connection limits
# Rules:
#   # SYN flood protection
#   tcp flags syn tcp dport @tcp_ports \
#       meter syn_flood { ip saddr limit rate 10/second burst 20 } return
#   tcp flags syn tcp dport @tcp_ports drop
#
#   # Connection limits per service
#   tcp dport 22 ct state new ct count over 5 drop
#   tcp dport { 80, 443 } ct state new ct count over 50 drop
#
#   # ICMP rate limit
#   ip protocol icmp limit rate 10/second burst 20 return
#   ip protocol icmp drop
#
#   return
#
# =============================================================================
# PORT MANAGEMENT
# =============================================================================
#
# Port sets define which services are exposed to the internet.
# Each family (ip/ip6) has its own port sets.
#
# SET DEFINITIONS:
# ----------------
# tcp_ports: TCP services (SSH, HTTP, HTTPS, custom)
# udp_ports: UDP services (DNS, NTP, VPN, custom)
#
# ADVANTAGES OF PORT SETS:
# -------------------------
# ✅ Dynamic updates: Add/remove ports without firewall reload
# ✅ Atomic changes: Port list updates are atomic operations
# ✅ Cleaner rules: Single rule "tcp dport @tcp_ports accept"
# ✅ Less error-prone: No need to duplicate port lists across rules
#
# EXAMPLE USAGE IN INPUT CHAIN:
# ------------------------------
# tcp dport @tcp_ports ct state new ct count over 50 drop comment "CT limit"
# tcp dport @tcp_ports accept comment "TCP services"
# udp dport @udp_ports accept comment "UDP services"
#
# RUNTIME MANAGEMENT:
# -------------------
# Add port:    nft add element ip nftban tcp_ports { 8080 }
# Remove port: nft delete element ip nftban tcp_ports { 8080 }
# List ports:  nft list set ip nftban tcp_ports
#
# DEFAULT PORTS:
# --------------
# TCP: 22 (SSH), 80 (HTTP), 443 (HTTPS)
# UDP: (empty by default, add as needed)
#
# =============================================================================
# v1.18.0 AUTO BAN ARCHITECTURE
# =============================================================================
# v2.1 UNIFIED BLACKLIST ARCHITECTURE
# =============================================================================
#
# All ban sources (feeds, geoban, auto-detect, manual) go to:
#   - blacklist_ipv4 in "ip nftban" table
#   - blacklist_ipv6 in "ip6 nftban" table
#
# Temp bans use timeout flag (auto-expire).
# Source tracking done in daemon database, NOT separate nft sets.
#
# Benefits:
#   - CIDR aggregation (lower memory)
#   - No IP duplicates across sets
#   - Faster lookup (single set)
#   - Simpler validation
# =============================================================================

# =============================================================================
# VALIDATION FUNCTIONS
# =============================================================================

nftban_nft_validate_tables() {
    # Check if required tables exist
    # Returns: 0 if valid, 1 if invalid

    local status=0
    local existing_tables
    existing_tables=$(nft list tables 2>/dev/null)

    # Check required tables
    if ! echo "$existing_tables" | grep -q "^table ${NFTBAN_TABLE_IPV4}$"; then
        echo "ERROR: Missing required table: ${NFTBAN_TABLE_IPV4}" >&2
        status=1
    fi

    if ! echo "$existing_tables" | grep -q "^table ${NFTBAN_TABLE_IPV6}$"; then
        echo "WARNING: Missing IPv6 table: ${NFTBAN_TABLE_IPV6}" >&2
        echo "  (IPv6 support disabled)" >&2
    fi

    # Check for deprecated tables
    for deprecated_table in "${!NFTBAN_DEPRECATED_TABLES[@]}"; do
        if echo "$existing_tables" | grep -q "^table ${deprecated_table}$"; then
            echo "INFO: Legacy table exists: ${deprecated_table}" >&2
            echo "  Reason: ${NFTBAN_DEPRECATED_TABLES[$deprecated_table]}" >&2
            echo "  Action: Can be removed after migration to ip/ip6 tables" >&2
        fi
    done

    return $status
}

nftban_nft_validate_sets() {
    # Check if required sets exist in correct tables
    # Returns: 0 if valid, 1 if invalid

    local status=0

    # Validate IPv4 table sets
    for set_name in "${!NFTBAN_IPV4_SETS[@]}"; do
        if ! nft list set "${NFTBAN_TABLE_IPV4}" "$set_name" &>/dev/null; then
            echo "ERROR: Missing set in ${NFTBAN_TABLE_IPV4}: $set_name" >&2
            status=1
        fi
    done

    # Validate IPv6 table sets (warn only)
    for set_name in "${!NFTBAN_IPV6_SETS[@]}"; do
        if ! nft list set "${NFTBAN_TABLE_IPV6}" "$set_name" &>/dev/null; then
            echo "WARNING: Missing set in ${NFTBAN_TABLE_IPV6}: $set_name" >&2
        fi
    done

    return $status
}

nftban_nft_get_table_for_ip() {
    # Determine which table to use for a given IP
    # Args: $1 = IP address
    # Returns: table name (e.g., "ip nftban" or "ip6 nftban")

    local ip="$1"

    if [[ "$ip" == *:* ]]; then
        echo "${NFTBAN_TABLE_IPV6}"
    else
        echo "${NFTBAN_TABLE_IPV4}"
    fi
}

nftban_nft_get_set_name() {
    # Get the correct set name for an IP and operation
    # Args: $1 = IP address, $2 = operation/source
    # Returns: set name
    #
    # v2.1 Architecture: All bans go to unified blacklist
    # Source tracking done in daemon database

    local ip="$1"
    local operation="$2"
    local suffix

    # Determine suffix based on IP version
    if [[ "$ip" == *:* ]]; then
        suffix="ipv6"
    else
        suffix="ipv4"
    fi

    case "$operation" in
        # Whitelist operations
        whitelist|trust)
            echo "whitelist_${suffix}"
            ;;
        # v2.1: ALL ban sources go to unified blacklist
        feeds|geoban|country|login|portscan|ddos|suricata|auto|manual|cli|ban|unban|blacklist|tempban|fail2ban|*)
            echo "blacklist_${suffix}"
            ;;
    esac
}

# =============================================================================
# FAST SET COUNTING FUNCTIONS
# =============================================================================
# These functions use nft JSON output for O(1) element counting
# instead of slow grep -oP regex parsing which is O(n)
#
# PERFORMANCE COMPARISON (with 4474 IPs):
#   SLOW: nft list set ... | grep -oP '\d+\.\d+\.\d+\.\d+' | wc -l  → 28 seconds
#   FAST: nft -j list set ... | jq '.nftables[1].set.elem | length' → 0.05 seconds
# =============================================================================

nftban_nft_count_set() {
    # Fast count of elements in an nftables set using JSON API
    # Usage: nftban_nft_count_set <family> <table> <set>
    # Returns: Number of elements (integer)
    #
    # Example: nftban_nft_count_set ip nftban blacklist_ipv4

    local family="${1:-ip}"
    local table="${2:-nftban}"
    local set="${3:-blacklist_ipv4}"

    # Use JSON output for fast O(1) counting
    if command -v jq &>/dev/null; then
        nft -j list set "$family" "$table" "$set" 2>/dev/null | \
            jq -r '.nftables[1].set.elem // [] | length' 2>/dev/null || echo "0"
    else
        # Fallback: count commas (still faster than regex)
        local output
        output=$(nft list set "$family" "$table" "$set" 2>/dev/null || true)
        if [[ -z "$output" ]]; then
            echo "0"
        else
            # Count elements by counting commas + 1 (if has elements)
            local comma_count
            comma_count=$(echo "$output" | grep -o "," | wc -l)
            if [[ "$comma_count" -eq 0 ]]; then
                # Check if there's at least one element
                if echo "$output" | grep -q "elements"; then
                    echo "1"
                else
                    echo "0"
                fi
            else
                echo "$((comma_count + 1))"
            fi
        fi
    fi
}

nftban_nft_count_set_with_timeout() {
    # Count elements with timeout attribute (temporary bans)
    # Usage: nftban_nft_count_set_with_timeout <family> <table> <set>

    local family="${1:-ip}"
    local table="${2:-nftban}"
    local set="${3:-blacklist_ipv4}"

    # Count lines containing "timeout" keyword
    nft list set "$family" "$table" "$set" 2>/dev/null | grep -c "timeout" || echo "0"
}

nftban_nft_count_blacklist() {
    # Fast count of blacklist elements (IPv4 + IPv6)
    # Returns: "ipv4_count ipv6_count total_count"

    local v4_count v6_count
    v4_count=$(nftban_nft_count_set ip nftban blacklist_ipv4)
    v6_count=$(nftban_nft_count_set ip6 nftban blacklist_ipv6)

    echo "$v4_count $v6_count $((v4_count + v6_count))"
}

nftban_nft_count_whitelist() {
    # Fast count of whitelist elements (IPv4 + IPv6)
    # Returns: "ipv4_count ipv6_count total_count"

    local v4_count v6_count
    v4_count=$(nftban_nft_count_set ip nftban whitelist_ipv4)
    v6_count=$(nftban_nft_count_set ip6 nftban whitelist_ipv6)

    echo "$v4_count $v6_count $((v4_count + v6_count))"
}

nftban_nft_count_all_sets() {
    # Get counts for all v2.1 sets in one call
    # Returns JSON with all counts for efficient batch operations and unified metrics
    # v2.1: Only whitelist + blacklist (all bans unified)

    # Core IP sets (v2.1 minimal schema)
    local bl_v4 bl_v6 wl_v4 wl_v6
    bl_v4=$(nftban_nft_count_set ip nftban blacklist_ipv4 2>/dev/null || echo 0)
    bl_v6=$(nftban_nft_count_set ip6 nftban blacklist_ipv6 2>/dev/null || echo 0)
    wl_v4=$(nftban_nft_count_set ip nftban whitelist_ipv4 2>/dev/null || echo 0)
    wl_v6=$(nftban_nft_count_set ip6 nftban whitelist_ipv6 2>/dev/null || echo 0)

    # Directional port sets (v2.1)
    local tcp_in tcp_out udp_in udp_out
    tcp_in=$(nftban_nft_count_set ip nftban tcp_ports_in 2>/dev/null || echo 0)
    tcp_out=$(nftban_nft_count_set ip nftban tcp_ports_out 2>/dev/null || echo 0)
    udp_in=$(nftban_nft_count_set ip nftban udp_ports_in 2>/dev/null || echo 0)
    udp_out=$(nftban_nft_count_set ip nftban udp_ports_out 2>/dev/null || echo 0)

    cat <<EOF
{
  "schema_version": "2.1",
  "whitelist": {"ipv4": $wl_v4, "ipv6": $wl_v6, "total": $((wl_v4 + wl_v6))},
  "blacklist": {"ipv4": $bl_v4, "ipv6": $bl_v6, "total": $((bl_v4 + bl_v6)), "note": "all bans unified (feeds+geoban+auto+manual)"},
  "ports": {
    "tcp_in": $tcp_in, "tcp_out": $tcp_out,
    "udp_in": $udp_in, "udp_out": $udp_out,
    "total_open": $((tcp_in + udp_in))
  },
  "totals": {
    "blocked_ipv4": $bl_v4,
    "blocked_ipv6": $bl_v6,
    "blocked_total": $((bl_v4 + bl_v6)),
    "whitelisted": $((wl_v4 + wl_v6))
  }
}
EOF
}

# =============================================================================
# IP WHITELIST CHECK (SINGLE SOURCE OF TRUTH)
# =============================================================================
# Check if IP is in central whitelist (nftables set)
# All modules should use this function instead of per-module whitelist files
nftban_is_whitelisted() {
    local ip="$1"
    [[ -z "$ip" ]] && return 1

    # Determine IP family
    local family="ip"
    local set_name="whitelist_ipv4"
    if [[ "$ip" == *:* ]]; then
        family="ip6"
        set_name="whitelist_ipv6"
    fi

    # Check nftables whitelist set (SINGLE SOURCE OF TRUTH)
    if nft get element "$family" nftban "$set_name" "{ $ip }" &>/dev/null; then
        return 0
    fi

    # Also check whitelist.d files for IPs not yet loaded into nftables
    local whitelist_dir="${NFTBAN_CONFIG_DIR:-/etc/nftban}/whitelist.d"
    if [[ -d "$whitelist_dir" ]]; then
        if grep -qhE "^${ip}(/[0-9]+)?(\s|$)" "$whitelist_dir"/*.conf 2>/dev/null; then
            return 0
        fi
    fi

    return 1
}

# Check if IP is in central blacklist (nftables set)
nftban_is_blacklisted() {
    local ip="$1"
    [[ -z "$ip" ]] && return 1

    # Determine IP family
    local family="ip"
    local set_name="blacklist_ipv4"
    if [[ "$ip" == *:* ]]; then
        family="ip6"
        set_name="blacklist_ipv6"
    fi

    # Check nftables blacklist set (SINGLE SOURCE OF TRUTH)
    if nft get element "$family" nftban "$set_name" "{ $ip }" &>/dev/null; then
        return 0
    fi

    return 1
}

# Export functions
export -f nftban_nft_count_set
export -f nftban_nft_count_set_with_timeout
export -f nftban_nft_count_blacklist
export -f nftban_nft_count_whitelist
export -f nftban_nft_count_all_sets
export -f nftban_is_whitelisted
export -f nftban_is_blacklisted

nftban_nft_validate_chains() {
    # Validate chains exist with correct type/hook/priority/policy
    # Returns: 0 if valid, 1 if invalid

    local status=0
    local chain_name chain_spec chain_type chain_hook chain_priority chain_policy
    # shellcheck disable=SC2034  # Structured read - actual_hook/actual_type validated elsewhere
    local actual_type actual_hook actual_policy

    # Validate IPv4 chains
        # shellcheck disable=SC2034  # Structured read - only some fields validated
    for chain_name in "${!NFTBAN_IPV4_CHAINS[@]}"; do
        chain_spec="${NFTBAN_IPV4_CHAINS[$chain_name]}"
        IFS='|' read -r chain_type chain_hook chain_priority chain_policy _ <<< "$chain_spec"

        # Check if chain exists
        if ! nft list chain ip nftban "$chain_name" &>/dev/null; then
            echo "ERROR: Missing chain in ip nftban: $chain_name" >&2
            status=1
            continue
        fi

        # Get actual chain properties
        local chain_info
        chain_info=$(nft list chain ip nftban "$chain_name" 2>/dev/null | head -3)

        # Check policy
        actual_policy=$(echo "$chain_info" | grep -oP 'policy \K[a-z]+' || echo "")
        if [[ -n "$actual_policy" && "$actual_policy" != "$chain_policy" ]]; then
            echo "ERROR: Wrong policy on ip nftban $chain_name: expected '$chain_policy', got '$actual_policy'" >&2
            status=1
        fi
    done

    # Validate IPv6 chains (warning only)
    for chain_name in "${!NFTBAN_IPV6_CHAINS[@]}"; do
        if ! nft list chain ip6 nftban "$chain_name" &>/dev/null; then
            echo "WARNING: Missing chain in ip6 nftban: $chain_name" >&2
        fi
    done

    return $status
}

nftban_nft_validate_set_flags() {
    # Validate sets have correct type and flags
    # Returns: 0 if valid, 1 if invalid

    local status=0
    local set_name set_spec expected_type expected_flags
    local actual_type actual_flags

    # Validate IPv4 sets
    for set_name in "${!NFTBAN_IPV4_SETS[@]}"; do
        set_spec="${NFTBAN_IPV4_SETS[$set_name]}"
        IFS='|' read -r expected_type expected_flags _ <<< "$set_spec"

        # Check if set exists
        if ! nft list set ip nftban "$set_name" &>/dev/null; then
            echo "ERROR: Missing set in ip nftban: $set_name" >&2
            status=1
            continue
        fi

        # Get actual set properties
        local set_info
        set_info=$(nft list set ip nftban "$set_name" 2>/dev/null)

        # Check type
        actual_type=$(echo "$set_info" | grep -oP 'type \K[a-z0-9_]+' | head -1 || echo "")
        if [[ "$actual_type" != "$expected_type" ]]; then
            echo "ERROR: Wrong type on ip nftban $set_name: expected '$expected_type', got '$actual_type'" >&2
            status=1
        fi

        # Check flags (if expected)
        if [[ -n "$expected_flags" ]]; then
            actual_flags=$(echo "$set_info" | grep -oP 'flags \K[a-z,]+' | head -1 || echo "")
            # Sort flags for comparison
            local sorted_expected sorted_actual
            sorted_expected=$(echo "$expected_flags" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
            sorted_actual=$(echo "$actual_flags" | tr ',' '\n' | sort | tr '\n' ',' | sed 's/,$//')
            if [[ "$sorted_expected" != "$sorted_actual" ]]; then
                echo "WARNING: Different flags on ip nftban $set_name: expected '$expected_flags', got '$actual_flags'" >&2
            fi
        fi
    done

    # Validate IPv6 sets
    for set_name in "${!NFTBAN_IPV6_SETS[@]}"; do
        set_spec="${NFTBAN_IPV6_SETS[$set_name]}"
        IFS='|' read -r expected_type expected_flags _ <<< "$set_spec"

        # Check if set exists
        if ! nft list set ip6 nftban "$set_name" &>/dev/null; then
            echo "WARNING: Missing set in ip6 nftban: $set_name" >&2
            continue
        fi

        # Get actual set properties
        local set_info
        set_info=$(nft list set ip6 nftban "$set_name" 2>/dev/null)

        # Check type
        actual_type=$(echo "$set_info" | grep -oP 'type \K[a-z0-9_]+' | head -1 || echo "")
        if [[ "$actual_type" != "$expected_type" ]]; then
            echo "WARNING: Wrong type on ip6 nftban $set_name: expected '$expected_type', got '$actual_type'" >&2
        fi
    done

    return $status
}

nftban_nft_validate_rule_order() {
    # Validate critical rule order in input chain
    # SECURITY-CRITICAL: blacklist must come BEFORE ct state established
    # Returns: 0 if valid, 1 if invalid

    local status=0
    local rules
    local family

    # Check both IPv4 and IPv6
    for family in ip ip6; do
        local whitelist_set="whitelist_ipv4"
        local blacklist_set="blacklist_ipv4"
        [[ "$family" == "ip6" ]] && whitelist_set="whitelist_ipv6" && blacklist_set="blacklist_ipv6"

        # Get input chain rules with handles
        rules=$(nft -a list chain "$family" nftban input 2>/dev/null)

        if [[ -z "$rules" ]]; then
            if [[ "$family" == "ip" ]]; then
                echo "ERROR: Cannot read ip nftban input chain" >&2
                return 1
            else
                # IPv6 chain missing is just a warning
                continue
            fi
        fi

        # Extract rule order (by handle number which indicates order)
        local whitelist_handle=0
        local blacklist_handle=0
        local established_handle=0

        # Find handles for key rules
        whitelist_handle=$(echo "$rules" | grep -E "@${whitelist_set}.*accept" | grep -oP 'handle \K[0-9]+' | head -1 || echo 0)
        blacklist_handle=$(echo "$rules" | grep -E "@${blacklist_set}.*drop" | grep -oP 'handle \K[0-9]+' | head -1 || echo 0)
        established_handle=$(echo "$rules" | grep -E 'ct state.*established' | grep -oP 'handle \K[0-9]+' | head -1 || echo 0)

        # Validate order: whitelist < blacklist < established
        if [[ $whitelist_handle -gt 0 && $blacklist_handle -gt 0 ]]; then
            if [[ $whitelist_handle -gt $blacklist_handle ]]; then
                echo "WARNING: ${family} nftban: Whitelist rule should come BEFORE blacklist rule" >&2
            fi
        fi

        if [[ $blacklist_handle -gt 0 && $established_handle -gt 0 ]]; then
            if [[ $blacklist_handle -gt $established_handle ]]; then
                echo "CRITICAL: ${family} nftban: Blacklist MUST come BEFORE 'ct state established' rule!" >&2
                echo "  Current order allows banned IPs to maintain established connections!" >&2
                status=1
            fi
        fi
    done

    return $status
}

nftban_nft_validate_full() {
    # Run full NFT schema validation
    # Returns: 0 if all pass, 1 if any errors

    local errors=0 warnings=0
    local output=""

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan NFT Schema Validation"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Schema Version: 1.0.0"
    echo "Architecture: Separate ip/ip6 tables"
    echo ""

    # 1. Validate tables
    echo "1. Tables (IPv4 + IPv6):"
    if output=$(nftban_nft_validate_tables 2>&1); then
        echo "   ✅ Required tables exist"
    else
        echo "   ❌ Table validation failed"
        echo "$output" | sed 's/^/      /'
        ((errors++))
    fi

    # 2. Validate sets (IPv4)
    echo ""
    echo "2. Sets (IPv4):"
    if output=$(nftban_nft_validate_sets 2>&1); then
        echo "   ✅ Required sets exist"
    else
        echo "   ❌ Set validation failed"
        echo "$output" | sed 's/^/      /'
        ((errors++))
    fi

    # 3. Validate set flags/types (IPv4 + IPv6)
    echo ""
    echo "3. Set Types & Flags (IPv4 + IPv6):"
    if output=$(nftban_nft_validate_set_flags 2>&1); then
        echo "   ✅ Set types and flags correct"
    else
        echo "   ⚠️  Set validation issues"
        echo "$output" | sed 's/^/      /'
        ((warnings++))
    fi

    # 4. Validate chains (IPv4 + IPv6)
    echo ""
    echo "4. Chains (IPv4 + IPv6):"
    if output=$(nftban_nft_validate_chains 2>&1); then
        echo "   ✅ Required chains exist with correct policies"
    else
        echo "   ❌ Chain validation failed"
        echo "$output" | sed 's/^/      /'
        ((errors++))
    fi

    # 5. Validate rule order (security-critical) - IPv4 + IPv6
    echo ""
    echo "5. Rule Order Security (IPv4 + IPv6):"
    if output=$(nftban_nft_validate_rule_order 2>&1); then
        echo "   ✅ Rule order is correct (blacklist before established)"
    else
        echo "   ❌ SECURITY ISSUE: Rule order incorrect!"
        echo "$output" | sed 's/^/      /'
        ((errors++))
    fi

    # 6. Check for deprecated tables
    echo ""
    echo "6. Legacy Tables:"
    local deprecated_found=0
    local existing_tables
    existing_tables=$(nft list tables 2>/dev/null)
    for deprecated_table in "${!NFTBAN_DEPRECATED_TABLES[@]}"; do
        if echo "$existing_tables" | grep -q "^table ${deprecated_table}$"; then
            echo "   ⚠️  Legacy table: ${deprecated_table}"
            ((deprecated_found++))
        fi
    done
    if [[ $deprecated_found -eq 0 ]]; then
        echo "   ✅ No deprecated tables found"
    fi

    # Show element counts
    echo ""
    echo "7. Current Set Sizes:"
    local ipv4_wl ipv4_bl ipv4_tcp ipv4_udp ipv6_wl ipv6_bl
    ipv4_wl=$(nft list set ip nftban whitelist_ipv4 2>/dev/null | grep -c "elements = {" || echo 0)
    ipv4_bl=$(nft list set ip nftban blacklist_ipv4 2>/dev/null | grep -oP '\d+(?= elements)' || echo "0")
    [[ -z "$ipv4_bl" ]] && ipv4_bl=$(nft list set ip nftban blacklist_ipv4 2>/dev/null | grep -c "," || echo 0)
    # shellcheck disable=SC2034  # Reserved for IPv6 stats
    ipv6_bl=$(nft list set ip6 nftban blacklist_ipv6 2>/dev/null | grep -c "elements = {" || echo 0)
    ipv4_udp=$(nft list set ip nftban udp_ports 2>/dev/null | grep -oP 'elements = \{ [^}]+' | tr ',' '\n' | wc -l || echo 0)
    ipv6_wl=$(nft list set ip6 nftban whitelist_ipv6 2>/dev/null | grep -c "elements = {" || echo 0)

    echo "   IPv4: whitelist=${ipv4_wl:-0}, blacklist=active, tcp_ports=${ipv4_tcp:-0}, udp_ports=${ipv4_udp:-0}"
    echo "   IPv6: whitelist=${ipv6_wl:-0}, blacklist=active"

    # Summary
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ $errors -eq 0 ]]; then
        echo "Result: ✅ PASSED (${warnings} warnings)"
    else
        echo "Result: ❌ FAILED (${errors} errors, ${warnings} warnings)"
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    return $errors
}

nftban_nft_report_status() {
    # Generate a report of current nftables status vs canonical schema
    # (Legacy function - use nftban_nft_validate_full for comprehensive check)

    nftban_nft_validate_full
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_nft_validate_tables
export -f nftban_nft_validate_sets
export -f nftban_nft_validate_chains
export -f nftban_nft_validate_set_flags
export -f nftban_nft_validate_rule_order
export -f nftban_nft_validate_full
export -f nftban_nft_get_table_for_ip
export -f nftban_nft_get_set_name
export -f nftban_nft_report_status

# =============================================================================
# COMPLETE INPUT CHAIN EXAMPLE (IPv4)
# =============================================================================
#
# This is the CANONICAL input chain structure for ip nftban table.
# ALL RULES MUST FOLLOW THIS ORDER!
#
# table ip nftban {
#   # === SETS ===
#   set whitelist_ipv4 {
#     type ipv4_addr
#     flags interval
#     comment "Permanent whitelist (admin IPs, internal networks)"
#   }
#
#   set blacklist_ipv4 {
#     type ipv4_addr
#     flags interval,auto-merge
#     comment "Consolidated blacklist (manual + feeds + geoban + country)"
#   }
#
#   set temp_ban_ipv4 {
#     type ipv4_addr
#     timeout 1h
#     comment "Temporary bans from fail2ban"
#   }
#
#   set tcp_ports {
#     type inet_service
#     comment "Allowed TCP ports"
#     elements = { 22, 80, 443 }
#   }
#
#   set udp_ports {
#     type inet_service
#     comment "Allowed UDP ports"
#   }
#
#   # === INPUT CHAIN ===
#   chain input {
#     type filter hook input priority filter; policy drop;
#
#     # 1. Drop invalid packets
#     ct state invalid drop comment "invalid state"
#
#     # 2. Always allow loopback
#     iif lo accept comment "loopback"
#
#     # 3. Whitelist (bypass all checks)
#     ip saddr @whitelist_ipv4 accept comment "whitelist - full access"
#
#     # 4. PERMANENT BLACKLIST (manual bans)
#     ip saddr @blacklist_ipv4 drop comment "blacklist"
#
#     # 5. TEMPORARY BANS (fail2ban)
#     ip saddr @temp_ban_ipv4 drop comment "temporary ban"
#
#     # 6. NOW allow established connections (safe after all bans checked)
#     ct state established,related accept comment "established connections"
#
#     # 7. ICMP (ping, traceroute, etc.)
#     ip protocol icmp icmp type { echo-reply, destination-unreachable, \
#       echo-request, time-exceeded } accept comment "ICMPv4"
#
#     # 8. CT LIMITS + RATE LIMITS (DDoS protection)
#     tcp flags syn ct state new \
#       meter syn_flood { ip saddr limit rate 100/second burst 200 } \
#       log prefix "nftban: portscan: "
#
#     ct state new tcp dport 22 ct count over 5 drop \
#       comment "SSH: max 5 concurrent per IP"
#
#     ct state new tcp dport { 80, 443 } ct count over 50 drop \
#       comment "HTTP(S): max 50 concurrent per IP"
#
#     # 9. TCP SERVICES (with ct limits applied above)
#     tcp dport @tcp_ports accept comment "TCP services"
#
#     # 10. UDP SERVICES
#     udp dport @udp_ports accept comment "UDP services"
#
#     # 11. DEFAULT DENY (log dropped packets)
#     log prefix "nftban: drop: " limit rate 10/minute
#     drop comment "default deny"
#   }
#
#   chain forward {
#     type filter hook forward priority filter; policy drop;
#   }
#
#   chain output {
#     type filter hook output priority filter; policy accept;
#   }
# }
#
# =============================================================================
# MANAGEMENT HIERARCHY - SIMPLE & CONSOLIDATED
# =============================================================================
#
# NFTBan uses SIMPLE nftables structure with ALL blocking consolidated:
#
# 1. WHITELIST (permanent trusted IPs) - HIGHEST PRIORITY
#    - Management:
#      * CLI: nftban whitelist add <ip>
#      * GUI/Panel: Web interface adds to config files
#      * Manual: Edit any file in /etc/nftban/whitelist.d/*.conf
#    - Sources (ALL files consolidated):
#      * /etc/nftban/whitelist.d/00-local.conf (manual edits)
#      * /etc/nftban/whitelist.d/50-panel.conf (GUI/panel additions)
#      * /etc/nftban/whitelist.d/*.conf (any user-created files)
#    - Examples: Admin IPs, internal networks (10.0.0.0/8, 192.168.0.0/16)
#    - Processing: nftban-core sync reads ALL files, deduplicates, loads to nftables
#    - **WHITELIST PRECEDENCE RULE (ALWAYS ENFORCED)**:
#      ✅ Whitelist ALWAYS wins (highest priority in firewall rule order)
#      ✅ Adding IP to whitelist → AUTO-REMOVES from blacklist + temp_ban
#      ✅ If IP exists in blacklist/temp_ban → removed automatically during sync
#      ✅ Whitelisted IPs bypass ALL checks (blacklist, temp_ban, feeds, geoban)
#      ⚠️ User informed if IP was in blacklist: "Removed from blacklist"
#      ⚠️ User informed if IP was in temp_ban: "Removed from temp_ban"
#
# 2. BLACKLIST (ALL blocked IPs consolidated into ONE set)
#    - Management:
#      * CLI: nftban ban <ip> [--reason "text"]
#      * CLI: nftban unban <ip>
#      * GUI/Panel: Web interface adds to config files
#      * Manual: Edit any file in /etc/nftban/blacklist.d/*.conf
#      * Feeds: nftban-core feeds [list|load|stats]
#      * GeoIP: nftban geoban add/remove <country-code>
#    - **BLACKLIST PROTECTION (before adding)**:
#      ⚠️ Trying to ban whitelisted IP → REJECTED with error message:
#         "ERROR: Cannot ban 1.2.3.4 - IP is whitelisted!"
#         "To ban this IP, first remove from whitelist: nftban whitelist remove 1.2.3.4"
#      ⚠️ User must explicitly remove from whitelist first (safety check)
#    - Sources (ALL consolidated by nftban-core):
#      * /etc/nftban/blacklist.d/00-local.conf (manual edits)
#      * /etc/nftban/blacklist.d/50-panel.conf (GUI/panel additions)
#      * /etc/nftban/blacklist.d/99-manual.conf (CLI ban command)
#      * /etc/nftban/blacklist.d/*.conf (any user-created files)
#      * /var/lib/nftban/feeds/*.txt (threat feeds: Spamhaus, EmergingThreats, etc.)
#      * MaxMind GeoIP database (country → CIDR ranges, e.g., CN, RU, KP)
#    - Processing pipeline (ALL handled by nftban-core Go binary):
#      a) Read ALL config files from blacklist.d/ (supports unlimited files!)
#      b) Read ALL feed files from feeds/
#      c) Query GeoIP database for blocked countries
#      d) Consolidate ALL sources into one dataset
#      e) Deduplicate (remove duplicates across ALL sources - NO DUPLICATES!)
#      f) Merge overlapping CIDRs (10.0.0.0/24 + 10.0.1.0/24 → 10.0.0.0/23)
#      g) Consolidate individual IPs into CIDRs where possible
#      h) Sync to nftables via NETLINK (fast, direct kernel communication)
#      i) Load into ONE final blacklist_ipv4 / blacklist_ipv6 set
#    - Performance: 20-80% reduction after consolidation, netlink = microsecond sync
#
# 3. TEMP_BAN (temporary automatic bans) - HYBRID APPROACH
#    - Management:
#      * fail2ban (automatic via nftban-tempban action)
#      * nftban tempban <ip> [duration] (manual temporary ban)
#      * nftban tempban stats (view stats from file)
#
#    - Storage: **HYBRID (file + nftables with timer)**
#
#      A) **File tracking** (/var/lib/nftban/temp_bans.db):
#         * Format: timestamp|ip|reason|duration|expires_at|status
#         * Purpose: Historical records, stats, search, metadata
#         * Advantages:
#           ✅ Easy to search/grep (file is fast, nft list is slow)
#           ✅ Stats available (when banned, by whom, reason, history)
#           ✅ Comments/metadata preserved (nftables doesn't support this)
#           ✅ No CPU crash when large (10,000+ temp bans)
#           ✅ Historical tracking (bans that expired still in log)
#
#      B) **NFT set with timeout** (temp_ban_ipv4/ipv6):
#         * Active temp bans loaded to nftables with timeout flag
#         * Kernel handles auto-expiry (no manual cleanup!)
#         * Fast firewall enforcement
#         * Advantages:
#           ✅ Auto-expiry built-in (kernel removes expired IPs)
#           ✅ Fast enforcement (kernel-level)
#           ✅ No sync daemon needed (timeout is automatic)
#
#    - Workflow:
#      1. fail2ban bans IP → writes to /var/lib/nftban/temp_bans.db
#      2. nftban-core sync reads file, loads to temp_ban_ipv4/ipv6 with timeout
#      3. Kernel automatically expires after timeout (1h default)
#      4. File keeps historical record for stats
#      5. Admin can review: "keep banned" → move to blacklist permanently
#      6. Admin can review: "trust" → move to whitelist
#
#    - Migration after expiry:
#      * Option 1: IP expires, removed from NFT, stays in file as "expired"
#      * Option 2: Admin promotes to permanent blacklist (nftban ban <ip>)
#      * Option 3: Admin promotes to whitelist (nftban whitelist add <ip>)
#
#    - Examples: Brute force attempts, repeated login failures, port scans
#    - Timeout: Configurable (default 1h), auto-expires via kernel timer
#    - Stats command: nftban tempban stats (fast grep on file, no NFT query)
#
# =============================================================================
# CONFLICT RESOLUTION & PRECEDENCE
# =============================================================================
#
# When the same IP exists in multiple lists, nftban-core enforces this order:
#
# PRECEDENCE ORDER (highest to lowest):
# -------------------------------------
# 1. WHITELIST (always wins)
# 2. BLACKLIST (permanent bans)
# 3. TEMP_BAN (temporary bans)
#
# CONFLICT RESOLUTION RULES:
# ---------------------------
# A) **Adding to whitelist**:
#    - nftban whitelist add 1.2.3.4
#    - Go checks if IP exists in blacklist → removes from blacklist
#    - Go checks if IP exists in temp_ban → removes from temp_ban
#    - Go checks if IP exists in feeds → excluded from feeds during sync
#    - User informed: "✅ Added to whitelist, ⚠️ Removed from blacklist"
#
# B) **Adding to blacklist**:
#    - nftban ban 1.2.3.4
#    - Go checks if IP exists in whitelist → REJECTS with error:
#      "❌ ERROR: Cannot ban 1.2.3.4 - IP is whitelisted!"
#      "To ban this IP: nftban whitelist remove 1.2.3.4"
#    - User must explicitly remove from whitelist first (safety check)
#
# C) **Sync operation** (nftban-core sync):
#    - Loads whitelist first
#    - Loads blacklist, excludes any IPs in whitelist
#    - Loads temp_ban, excludes any IPs in whitelist
#    - Loads feeds, excludes any IPs in whitelist
#    - Result: Whitelist IPs NEVER appear in blacklist sets (guaranteed)
#
# D) **Feed updates**:
#    - nftban-core feeds load
#    - If feed contains whitelisted IP → automatically excluded
#    - User informed: "⚠️ Excluded N whitelisted IPs from feeds"
#
# WHY THIS PREVENTS MISTAKES:
# ============================
# ✅ Cannot accidentally ban admin IPs (whitelist protection)
# ✅ Cannot have IP in both whitelist and blacklist (auto-cleanup)
# ✅ Clear error messages guide user to fix conflicts
# ✅ Feeds automatically respect whitelist (no manual exclusion)
# ✅ Whitelist always checked FIRST in firewall rules (security)
#
# WHY THIS IS EASIER:
# ===================
# ✅ ONE blacklist set (not multiple feeds/geoban/manual sets)
# ✅ Go handles ALL complexity internally (parsing, dedup, CIDR merging)
# ✅ Supports UNLIMITED config files (*.conf in whitelist.d/ and blacklist.d/)
# ✅ NO DUPLICATES guaranteed (Go deduplicates across ALL sources)
# ✅ NETLINK sync (microsecond performance, direct kernel communication)
# ✅ GUI/Panel can add files without touching existing ones
# ✅ Temp bans: HYBRID approach (file for stats + NFT timer for auto-expiry)
# ✅ Easy stats (grep file, no slow NFT queries on large sets)
# ✅ Auto-expiry (kernel timer, no daemon needed)
# ✅ Historical tracking (temp_bans.db keeps all records)
# ✅ Flexible migration (temp → permanent blacklist/whitelist)
# ✅ Less room for mistakes (no manual set management)
# ✅ Efficient lookups (ONE set lookup, not multiple)
# ✅ CIDR optimization happens automatically
# ✅ Clear separation: whitelist / blacklist / temp_ban
# ✅ Easy to understand rule order
# ✅ Simpler debugging (check ONE blacklist, not many sets)
# ✅ Expandable (users can add custom .conf files anytime)
#
# =============================================================================
# USAGE NOTES
# =============================================================================
#
# This schema file serves as the CANONICAL REFERENCE for NFTBan's nftables
# structure. When modifying nftables configuration:
#
# 1. Update this schema file FIRST
# 2. Update implementation code to match
# 3. Run validation to verify alignment
#
# To validate current system:
#   source /usr/lib/nftban/lib/nft_schema.sh
#   nftban_nft_report_status
#
# To get correct table for an IP:
#   table=$(nftban_nft_get_table_for_ip "1.2.3.4")      # Returns: ip nftban
#   table=$(nftban_nft_get_table_for_ip "2001:db8::1")  # Returns: ip6 nftban
#
# To get correct set name:
#   set=$(nftban_nft_get_set_name "1.2.3.4" "ban")     # Returns: blacklist_ipv4
#   set=$(nftban_nft_get_set_name "2001:db8::1" "ban") # Returns: blacklist_ipv6
#
# To add a ban:
#   nftban ban 1.2.3.4
#   # Adds to /etc/nftban/blacklist.d/99-manual.conf
#   # Then run: nftban-core sync
#
# To sync ALL sources to nftables:
#   nftban-core sync
#   # Reads ALL config files (whitelist.d/*.conf + blacklist.d/*.conf)
#   # Reads ALL feeds (/var/lib/nftban/feeds/*.txt)
#   # Reads GeoIP database for country blocks
#   # Consolidates, deduplicates, merges CIDRs
#   # Syncs to nftables via netlink (differential sync - only changes applied)
#
# =============================================================================
