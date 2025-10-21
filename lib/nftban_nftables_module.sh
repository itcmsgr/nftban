#!/usr/bin/env bash

# =============================================================================
# NFTBan nftables Module
# Version: 0.9.0
# Location: lib/nftban_nftables_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Dual-table architecture for improved performance and split IPv4/IPv6 handling
# =============================================================================

# Strict mode for production-grade security
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_NFTABLES_LOADED:-}" ]] && return 0
readonly NFTBAN_NFTABLES_LOADED=1

# =============================================================================
# MODULE CONFIGURATION - v0.9.0 SPLIT TABLES
# =============================================================================

# NEW: Separate table names for IPv4 and IPv6
readonly NFTBAN_NFT_TABLE_V4="nftban_v4"
readonly NFTBAN_NFT_TABLE_V6="nftban_v6"
readonly NFTBAN_NFT_FAMILY_V4="ip"
readonly NFTBAN_NFT_FAMILY_V6="ip6"

# Legacy support (for migration detection)
readonly NFTBAN_NFT_TABLE_LEGACY="nftban_global"
readonly NFTBAN_NFT_FAMILY_LEGACY="inet"

# Port configuration files
readonly NFTBAN_PORT_CONFIG_DIR="${NFTBAN_CONFIG_DIR}/ports"
readonly NFTBAN_IPV4_INPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv4-input.conf"
readonly NFTBAN_IPV4_OUTPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv4-output.conf"
readonly NFTBAN_IPV6_INPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv6-input.conf"
readonly NFTBAN_IPV6_OUTPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv6-output.conf"

# =============================================================================
# TABLE MANAGEMENT - DUAL TABLE SUPPORT
# =============================================================================

# Check if v0.9.0 split tables exist
nftban_nftables_check_table() {
    local family="${1:-both}"  # v4, v6, or both

    case "$family" in
        v4)
            nft list table "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" &>/dev/null
            ;;
        v6)
            nft list table "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" &>/dev/null
            ;;
        both)
            nft list table "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" &>/dev/null && \
            nft list table "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" &>/dev/null
            ;;
        *)
            nftban_log_error "Invalid family: $family (use v4, v6, or both)"
            return 1
            ;;
    esac
}

# Check if legacy v0.8.5 table exists
nftban_nftables_check_legacy_table() {
    nft list table "$NFTBAN_NFT_FAMILY_LEGACY" "$NFTBAN_NFT_TABLE_LEGACY" &>/dev/null
}

# Create IPv4 table structure
nftban_nftables_create_table_v4() {
    nftban_log_info "Creating IPv4 table: $NFTBAN_NFT_FAMILY_V4 $NFTBAN_NFT_TABLE_V4"

    # Create table
    nft add table "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" 2>/dev/null || true

    # =============================================================================
    # IPv4 SETS (no _v4 suffix needed - table is already IPv4-specific)
    # =============================================================================

    # Whitelist
    nft add set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" whitelist \
        "{ type ipv4_addr; flags interval; comment \"Whitelisted IPv4\"; }" 2>/dev/null || true

    # Temporary bans (with timeout)
    nft add set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" temp_ban \
        "{ type ipv4_addr; flags timeout; timeout 1h; comment \"Temporary bans\"; }" 2>/dev/null || true

    # User blacklist (permanent)
    nft add set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" user_blacklist \
        "{ type ipv4_addr; flags interval; comment \"User blacklist\"; }" 2>/dev/null || true

    # System blacklist (permanent)
    nft add set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" system_blacklist \
        "{ type ipv4_addr; flags interval; comment \"System blacklist\"; }" 2>/dev/null || true

    # Threat feeds
    nft add set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" feeds \
        "{ type ipv4_addr; flags interval; auto-merge; comment \"Threat feeds\"; }" 2>/dev/null || true

    # =============================================================================
    # IPv4 CHAINS
    # =============================================================================

    # Input chain
    nft add chain "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        "{ type filter hook input priority filter; policy accept; }" 2>/dev/null || true

    # Output chain
    nft add chain "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" output \
        "{ type filter hook output priority filter; policy accept; }" 2>/dev/null || true

    nftban_log_success "IPv4 table created successfully"
}

# Create IPv6 table structure
nftban_nftables_create_table_v6() {
    nftban_log_info "Creating IPv6 table: $NFTBAN_NFT_FAMILY_V6 $NFTBAN_NFT_TABLE_V6"

    # Create table
    nft add table "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" 2>/dev/null || true

    # =============================================================================
    # IPv6 SETS (mirror IPv4 structure)
    # =============================================================================

    # Whitelist
    nft add set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" whitelist \
        "{ type ipv6_addr; flags interval; comment \"Whitelisted IPv6\"; }" 2>/dev/null || true

    # Temporary bans (with timeout)
    nft add set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" temp_ban \
        "{ type ipv6_addr; flags timeout; timeout 1h; comment \"Temporary bans\"; }" 2>/dev/null || true

    # User blacklist (permanent)
    nft add set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" user_blacklist \
        "{ type ipv6_addr; flags interval; comment \"User blacklist\"; }" 2>/dev/null || true

    # System blacklist (permanent)
    nft add set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" system_blacklist \
        "{ type ipv6_addr; flags interval; comment \"System blacklist\"; }" 2>/dev/null || true

    # Threat feeds
    nft add set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" feeds \
        "{ type ipv6_addr; flags interval; auto-merge; comment \"Threat feeds\"; }" 2>/dev/null || true

    # =============================================================================
    # IPv6 CHAINS
    # =============================================================================

    # Input chain
    nft add chain "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        "{ type filter hook input priority filter; policy accept; }" 2>/dev/null || true

    # Output chain
    nft add chain "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" output \
        "{ type filter hook output priority filter; policy accept; }" 2>/dev/null || true

    nftban_log_success "IPv6 table created successfully"
}

# Create both tables
nftban_nftables_create_table() {
    nftban_log_info "Creating nftban v0.9.0 split table architecture..."

    # Check if legacy table exists
    if nftban_nftables_check_legacy_table; then
        nftban_log_warning "Legacy v0.8.5 table detected: $NFTBAN_NFT_FAMILY_LEGACY $NFTBAN_NFT_TABLE_LEGACY"
        nftban_log_warning "Please run migration: nftban migrate v085-to-v090"
        nftban_log_warning "Continuing with v0.9.0 table creation..."
    fi

    # Create both tables
    nftban_nftables_create_table_v4
    nftban_nftables_create_table_v6

    # Apply rules after table creation
    nftban_nftables_apply_rules

    nftban_log_success "Split table architecture created successfully"
}

# Apply IPv4 rules
nftban_nftables_apply_rules_v4() {
    nftban_log_info "Applying IPv4 rules..."

    if ! nftban_nftables_check_table "v4"; then
        nftban_log_error "IPv4 table does not exist"
        return 1
    fi

    # Flush existing rules
    nft flush chain "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input 2>/dev/null || true
    nft flush chain "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" output 2>/dev/null || true

    # =============================================================================
    # IPv4 INPUT CHAIN RULES
    # =============================================================================

    # RULE 1: Accept established connections (ALWAYS FIRST)
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        ct state established,related counter accept \
        comment "Accept established/related" 2>/dev/null || true

    # RULE 2: Accept loopback (ALWAYS ALLOW)
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        iif lo counter accept \
        comment "Accept loopback" 2>/dev/null || true

    # RULE 3: WHITELIST CHECK (HIGHEST PRIORITY - MUST BE FIRST ACCEPT!)
    # SECURITY: Whitelisted IPs MUST NEVER be blocked
    # NOTE: No 'ip saddr' needed - table is already IPv4-specific!
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        saddr @whitelist counter accept \
        comment "Accept whitelisted" 2>/dev/null || true

    # RULE 4: Accept ICMP (for network diagnostics)
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        icmp type { echo-request, echo-reply } counter accept \
        comment "Accept ICMP" 2>/dev/null || true

    # RULE 5: Apply configured port rules (service acceptance before drops)
    nftban_nftables_apply_port_rules_v4 "input"

    # =============================================================================
    # DROP ZONE: Order here determines priority for logging/counters only
    # All drops are equal from security perspective, but order matters for visibility
    # =============================================================================

    # RULE 6: TEMPORARY BANS (highest priority drop - active threats)
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        saddr @temp_ban counter drop \
        comment "Block temporary banned" 2>/dev/null || true

    # RULE 7: USER BLACKLIST (manual permanent bans)
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        saddr @user_blacklist counter drop \
        comment "Block user blacklist" 2>/dev/null || true

    # RULE 8: SYSTEM BLACKLIST (automatic permanent bans)
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        saddr @system_blacklist counter drop \
        comment "Block system blacklist" 2>/dev/null || true

    # RULE 9: THREAT FEEDS BLOCKING (LOWEST PRIORITY - last resort)
    # SECURITY: Feeds come LAST so temp/perm bans take precedence
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input \
        saddr @feeds counter drop \
        comment "Block threat feeds" 2>/dev/null || true

    # =============================================================================
    # IPv4 OUTPUT CHAIN RULES
    # =============================================================================

    # Accept established connections
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" output \
        ct state established,related counter accept \
        comment "Accept established/related" 2>/dev/null || true

    # Accept loopback
    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" output \
        oif lo counter accept \
        comment "Accept loopback" 2>/dev/null || true

    # Apply port rules
    nftban_nftables_apply_port_rules_v4 "output"

    nftban_log_success "IPv4 rules applied successfully"
}

# Apply IPv6 rules
nftban_nftables_apply_rules_v6() {
    nftban_log_info "Applying IPv6 rules..."

    if ! nftban_nftables_check_table "v6"; then
        nftban_log_error "IPv6 table does not exist"
        return 1
    fi

    # Flush existing rules
    nft flush chain "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input 2>/dev/null || true
    nft flush chain "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" output 2>/dev/null || true

    # =============================================================================
    # IPv6 INPUT CHAIN RULES (mirror IPv4 structure)
    # =============================================================================

    # RULE 1: Accept established connections
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        ct state established,related counter accept \
        comment "Accept established/related" 2>/dev/null || true

    # RULE 2: Accept loopback
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        iif lo counter accept \
        comment "Accept loopback" 2>/dev/null || true

    # RULE 3: WHITELIST CHECK (HIGHEST PRIORITY - MUST BE FIRST ACCEPT!)
    # SECURITY: Whitelisted IPs MUST NEVER be blocked
    # NOTE: No 'ip6 saddr' needed - table is already IPv6-specific!
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        saddr @whitelist counter accept \
        comment "Accept whitelisted" 2>/dev/null || true

    # RULE 4: Accept ICMPv6 (essential for IPv6 - must be before drops!)
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        icmpv6 type { echo-request, echo-reply, nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert } counter accept \
        comment "Accept ICMPv6" 2>/dev/null || true

    # RULE 5: Apply configured port rules (service acceptance before drops)
    nftban_nftables_apply_port_rules_v6 "input"

    # =============================================================================
    # DROP ZONE: Order here determines priority for logging/counters only
    # All drops are equal from security perspective, but order matters for visibility
    # =============================================================================

    # RULE 6: TEMPORARY BANS (highest priority drop - active threats)
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        saddr @temp_ban counter drop \
        comment "Block temporary banned" 2>/dev/null || true

    # RULE 7: USER BLACKLIST (manual permanent bans)
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        saddr @user_blacklist counter drop \
        comment "Block user blacklist" 2>/dev/null || true

    # RULE 8: SYSTEM BLACKLIST (automatic permanent bans)
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        saddr @system_blacklist counter drop \
        comment "Block system blacklist" 2>/dev/null || true

    # RULE 9: THREAT FEEDS BLOCKING (LOWEST PRIORITY - last resort)
    # SECURITY: Feeds come LAST so temp/perm bans take precedence
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input \
        saddr @feeds counter drop \
        comment "Block threat feeds" 2>/dev/null || true

    # =============================================================================
    # IPv6 OUTPUT CHAIN RULES
    # =============================================================================

    # Accept established connections
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" output \
        ct state established,related counter accept \
        comment "Accept established/related" 2>/dev/null || true

    # Accept loopback
    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" output \
        oif lo counter accept \
        comment "Accept loopback" 2>/dev/null || true

    # Apply port rules
    nftban_nftables_apply_port_rules_v6 "output"

    nftban_log_success "IPv6 rules applied successfully"
}

# Apply rules to both tables
nftban_nftables_apply_rules() {
    nftban_log_info "Applying nftables rules to both tables..."

    nftban_nftables_apply_rules_v4
    nftban_nftables_apply_rules_v6

    nftban_log_success "All nftables rules applied successfully"
}

# Delete IPv4 table
nftban_nftables_delete_table_v4() {
    nftban_log_warning "Deleting IPv4 table: $NFTBAN_NFT_FAMILY_V4 $NFTBAN_NFT_TABLE_V4"
    nft delete table "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" 2>/dev/null || true
    nftban_log_success "IPv4 table deleted"
}

# Delete IPv6 table
nftban_nftables_delete_table_v6() {
    nftban_log_warning "Deleting IPv6 table: $NFTBAN_NFT_FAMILY_V6 $NFTBAN_NFT_TABLE_V6"
    nft delete table "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" 2>/dev/null || true
    nftban_log_success "IPv6 table deleted"
}

# Delete both tables
nftban_nftables_delete_table() {
    nftban_log_warning "Deleting all nftban tables..."
    nftban_nftables_delete_table_v4
    nftban_nftables_delete_table_v6
    nftban_log_success "All tables deleted"
}

# Delete legacy v0.8.5 table
nftban_nftables_delete_legacy_table() {
    if nftban_nftables_check_legacy_table; then
        nftban_log_warning "Deleting legacy table: $NFTBAN_NFT_FAMILY_LEGACY $NFTBAN_NFT_TABLE_LEGACY"
        nft delete table "$NFTBAN_NFT_FAMILY_LEGACY" "$NFTBAN_NFT_TABLE_LEGACY" 2>/dev/null || true
        nftban_log_success "Legacy table deleted"
    else
        nftban_log_info "No legacy table found"
    fi
}

# Verify table structure
nftban_nftables_verify_structure() {
    local missing=0

    # Check IPv4 table
    if ! nftban_nftables_check_table "v4"; then
        nftban_log_error "IPv4 table does not exist"
        ((missing++))
    else
        local required_sets=("whitelist" "temp_ban" "user_blacklist" "system_blacklist" "feeds")

        for set_name in "${required_sets[@]}"; do
            if ! nft list set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$set_name" &>/dev/null; then
                nftban_log_error "Missing IPv4 set: $set_name"
                ((missing++))
            fi
        done
    fi

    # Check IPv6 table
    if ! nftban_nftables_check_table "v6"; then
        nftban_log_error "IPv6 table does not exist"
        ((missing++))
    else
        local required_sets=("whitelist" "temp_ban" "user_blacklist" "system_blacklist" "feeds")

        for set_name in "${required_sets[@]}"; do
            if ! nft list set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$set_name" &>/dev/null; then
                nftban_log_error "Missing IPv6 set: $set_name"
                ((missing++))
            fi
        done
    fi

    if [[ $missing -gt 0 ]]; then
        nftban_log_error "Structure verification failed: $missing issues found"
        return 1
    fi

    nftban_log_success "Structure verification passed"
    return 0
}

# Show set statistics
nftban_nftables_show_set_stats() {
    echo "  Sets (IPv4 - $NFTBAN_NFT_TABLE_V4):"
    for set_type in whitelist temp_ban user_blacklist system_blacklist feeds; do
        if nft list set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$set_type" &>/dev/null; then
            local count
            count=$(nft list set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$set_type" 2>/dev/null | \
                    grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9.]\+' | wc -l)
            printf "    %-25s %3d IPs\n" "$set_type:" "$count"
        fi
    done

    echo ""
    echo "  Sets (IPv6 - $NFTBAN_NFT_TABLE_V6):"
    for set_type in whitelist temp_ban user_blacklist system_blacklist feeds; do
        if nft list set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$set_type" &>/dev/null; then
            local count
            count=$(nft list set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$set_type" 2>/dev/null | \
                    grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F:]\+' | wc -l)
            printf "    %-25s %3d IPs\n" "$set_type:" "$count"
        fi
    done
}

# Show status
nftban_nftables_show_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  nftables Status (v0.9.0 Split Tables)"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    if nftban_nftables_check_table "both"; then
        echo -e "${NFTBAN_GREEN}✓${NFTBAN_NC} IPv4 table: $NFTBAN_NFT_FAMILY_V4 $NFTBAN_NFT_TABLE_V4"
        echo -e "${NFTBAN_GREEN}✓${NFTBAN_NC} IPv6 table: $NFTBAN_NFT_FAMILY_V6 $NFTBAN_NFT_TABLE_V6"
        echo ""
        nftban_nftables_show_set_stats
    else
        echo -e "${NFTBAN_RED}✗${NFTBAN_NC} Tables not found"
        echo "Run: nftban nftables init"
    fi

    # Check for legacy table
    if nftban_nftables_check_legacy_table; then
        echo ""
        echo -e "${NFTBAN_YELLOW}⚠${NFTBAN_NC} Legacy v0.8.5 table detected: $NFTBAN_NFT_FAMILY_LEGACY $NFTBAN_NFT_TABLE_LEGACY"
        echo "Run migration: nftban migrate v085-to-v090"
    fi

    echo ""
}

# =============================================================================
# PORT MANAGEMENT
# =============================================================================

# Initialize port configuration files
nftban_nftables_init_port_configs() {
    mkdir -p "$NFTBAN_PORT_CONFIG_DIR"

    local port_files=(
        "$NFTBAN_IPV4_INPUT_PORTS"
        "$NFTBAN_IPV4_OUTPUT_PORTS"
        "$NFTBAN_IPV6_INPUT_PORTS"
        "$NFTBAN_IPV6_OUTPUT_PORTS"
    )

    for file in "${port_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            cat > "$file" << 'EOF'
# nftban Port Configuration
# Format: PORT|PROTOCOL
# Protocol: T=TCP, U=UDP, B=Both
# Examples:
#   22|T        # SSH (TCP only)
#   53|U        # DNS (UDP only)
#   80|B        # HTTP (both TCP and UDP)
#   443|T       # HTTPS (TCP only)
#   8080-8090|T # Port range (TCP)
EOF
            chmod 644 "$file"
            nftban_log_debug "Created port config: $(basename "$file")"
        fi
    done
}

# Apply IPv4 port rules from config files
nftban_nftables_apply_port_rules_v4() {
    local direction="$1"  # input or output

    # Determine which config file to use
    local config_file
    if [[ "$direction" == "input" ]]; then
        config_file="$NFTBAN_IPV4_INPUT_PORTS"
    else
        config_file="$NFTBAN_IPV4_OUTPUT_PORTS"
    fi

    # Process ports
    if [[ -f "$config_file" ]]; then
        while IFS='|' read -r port protocol; do
            [[ -z "$port" || "$port" =~ ^# ]] && continue

            case "$protocol" in
                T)
                    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$direction" \
                        tcp dport "$port" counter accept \
                        comment "Allow TCP port $port" 2>/dev/null || true
                    ;;
                U)
                    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$direction" \
                        udp dport "$port" counter accept \
                        comment "Allow UDP port $port" 2>/dev/null || true
                    ;;
                B)
                    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$direction" \
                        tcp dport "$port" counter accept \
                        comment "Allow TCP port $port" 2>/dev/null || true
                    nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$direction" \
                        udp dport "$port" counter accept \
                        comment "Allow UDP port $port" 2>/dev/null || true
                    ;;
            esac
        done < <(grep -vE '^#|^$' "$config_file" 2>/dev/null || true)
    fi
}

# Apply IPv6 port rules from config files
nftban_nftables_apply_port_rules_v6() {
    local direction="$1"  # input or output

    # Determine which config file to use
    local config_file
    if [[ "$direction" == "input" ]]; then
        config_file="$NFTBAN_IPV6_INPUT_PORTS"
    else
        config_file="$NFTBAN_IPV6_OUTPUT_PORTS"
    fi

    # Process ports
    if [[ -f "$config_file" ]]; then
        while IFS='|' read -r port protocol; do
            [[ -z "$port" || "$port" =~ ^# ]] && continue

            case "$protocol" in
                T)
                    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$direction" \
                        tcp dport "$port" counter accept \
                        comment "Allow TCP port $port" 2>/dev/null || true
                    ;;
                U)
                    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$direction" \
                        udp dport "$port" counter accept \
                        comment "Allow UDP port $port" 2>/dev/null || true
                    ;;
                B)
                    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$direction" \
                        tcp dport "$port" counter accept \
                        comment "Allow TCP port $port" 2>/dev/null || true
                    nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$direction" \
                        udp dport "$port" counter accept \
                        comment "Allow UDP port $port" 2>/dev/null || true
                    ;;
            esac
        done < <(grep -vE '^#|^$' "$config_file" 2>/dev/null || true)
    fi
}

# Add port to configuration
nftban_nftables_add_port() {
    local port="$1"
    local protocol="${2:-T}"  # T, U, or B
    local direction="${3:-input}"  # input or output
    local ip_version="${4:-4}"  # 4 or 6

    # Validate port
    if [[ ! "$port" =~ ^[0-9]+(-[0-9]+)?$ ]]; then
        nftban_log_error "Invalid port format: $port"
        return 1
    fi

    # Validate protocol
    if [[ ! "$protocol" =~ ^[TUB]$ ]]; then
        nftban_log_error "Invalid protocol: $protocol (use T, U, or B)"
        return 1
    fi

    # Select config file
    local config_file
    if [[ "$ip_version" == "4" ]]; then
        if [[ "$direction" == "input" ]]; then
            config_file="$NFTBAN_IPV4_INPUT_PORTS"
        else
            config_file="$NFTBAN_IPV4_OUTPUT_PORTS"
        fi
    else
        if [[ "$direction" == "input" ]]; then
            config_file="$NFTBAN_IPV6_INPUT_PORTS"
        else
            config_file="$NFTBAN_IPV6_OUTPUT_PORTS"
        fi
    fi

    # Check if already exists
    if grep -qE "^${port}\|${protocol}$" "$config_file" 2>/dev/null; then
        nftban_log_warning "Port already configured: $port $protocol"
        return 0
    fi

    # Add to config file
    echo "${port}|${protocol}" >> "$config_file"

    nftban_log_success "Added port: $port ($protocol) to IPv${ip_version} ${direction}"

    # Apply rules
    nftban_nftables_apply_rules
}

# Remove port from configuration
nftban_nftables_remove_port() {
    local port="$1"
    local protocol="${2:-T}"
    local direction="${3:-input}"
    local ip_version="${4:-4}"

    # Select config file
    local config_file
    if [[ "$ip_version" == "4" ]]; then
        if [[ "$direction" == "input" ]]; then
            config_file="$NFTBAN_IPV4_INPUT_PORTS"
        else
            config_file="$NFTBAN_IPV4_OUTPUT_PORTS"
        fi
    else
        if [[ "$direction" == "input" ]]; then
            config_file="$NFTBAN_IPV6_INPUT_PORTS"
        else
            config_file="$NFTBAN_IPV6_OUTPUT_PORTS"
        fi
    fi

    # Remove from config
    if [[ -f "$config_file" ]]; then
        sed -i "/^${port}|${protocol}$/d" "$config_file"
        nftban_log_success "Removed port: $port ($protocol) from IPv${ip_version} ${direction}"

        # Apply rules
        nftban_nftables_apply_rules
    else
        nftban_log_error "Config file not found: $config_file"
        return 1
    fi
}

# List configured ports
nftban_nftables_list_ports() {
    local filter="${1:-all}"  # all, input, output

    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Configured Ports"
    echo "═══════════════════════════════════════════════════════"
    echo ""

    if [[ "$filter" == "all" || "$filter" == "input" ]]; then
        echo -e "${NFTBAN_CYAN}IPv4 INPUT:${NFTBAN_NC}"
        if [[ -f "$NFTBAN_IPV4_INPUT_PORTS" ]]; then
            grep -vE '^#|^$' "$NFTBAN_IPV4_INPUT_PORTS" 2>/dev/null | \
                awk -F'|' '{printf "  %-20s %s\n", $1, ($2=="T"?"TCP":$2=="U"?"UDP":"TCP+UDP")}' || echo "  (none)"
        fi
        echo ""
    fi

    if [[ "$filter" == "all" || "$filter" == "output" ]]; then
        echo -e "${NFTBAN_CYAN}IPv4 OUTPUT:${NFTBAN_NC}"
        if [[ -f "$NFTBAN_IPV4_OUTPUT_PORTS" ]]; then
            grep -vE '^#|^$' "$NFTBAN_IPV4_OUTPUT_PORTS" 2>/dev/null | \
                awk -F'|' '{printf "  %-20s %s\n", $1, ($2=="T"?"TCP":$2=="U"?"UDP":"TCP+UDP")}' || echo "  (none)"
        fi
        echo ""
    fi

    if [[ "$filter" == "all" || "$filter" == "input" ]]; then
        echo -e "${NFTBAN_CYAN}IPv6 INPUT:${NFTBAN_NC}"
        if [[ -f "$NFTBAN_IPV6_INPUT_PORTS" ]]; then
            grep -vE '^#|^$' "$NFTBAN_IPV6_INPUT_PORTS" 2>/dev/null | \
                awk -F'|' '{printf "  %-20s %s\n", $1, ($2=="T"?"TCP":$2=="U"?"UDP":"TCP+UDP")}' || echo "  (none)"
        fi
        echo ""
    fi

    if [[ "$filter" == "all" || "$filter" == "output" ]]; then
        echo -e "${NFTBAN_CYAN}IPv6 OUTPUT:${NFTBAN_NC}"
        if [[ -f "$NFTBAN_IPV6_OUTPUT_PORTS" ]]; then
            grep -vE '^#|^$' "$NFTBAN_IPV6_OUTPUT_PORTS" 2>/dev/null | \
                awk -F'|' '{printf "  %-20s %s\n", $1, ($2=="T"?"TCP":$2=="U"?"UDP":"TCP+UDP")}' || echo "  (none)"
        fi
        echo ""
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_nftables_check_table
export -f nftban_nftables_check_legacy_table
export -f nftban_nftables_create_table
export -f nftban_nftables_create_table_v4
export -f nftban_nftables_create_table_v6
export -f nftban_nftables_apply_rules
export -f nftban_nftables_apply_rules_v4
export -f nftban_nftables_apply_rules_v6
export -f nftban_nftables_delete_table
export -f nftban_nftables_delete_table_v4
export -f nftban_nftables_delete_table_v6
export -f nftban_nftables_delete_legacy_table
export -f nftban_nftables_verify_structure
export -f nftban_nftables_show_set_stats
export -f nftban_nftables_show_status
export -f nftban_nftables_init_port_configs
export -f nftban_nftables_add_port
export -f nftban_nftables_remove_port
export -f nftban_nftables_list_ports
export -f nftban_nftables_apply_port_rules_v4
export -f nftban_nftables_apply_port_rules_v6

nftban_log_debug "NFTBan nftables Module loaded (v2.0.0 - Split Table Architecture)"
