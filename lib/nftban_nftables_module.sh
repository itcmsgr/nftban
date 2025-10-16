#!/usr/bin/env bash

# =============================================================================
# NFTBan nftables Module
# Version: 1.1.0
# Comprehensive nftables table, set, and rule management with Feeds support
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_NFTABLES_LOADED:-}" ]] && return 0
readonly NFTBAN_NFTABLES_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_NFT_TABLE="${NFTBAN_NFT_TABLE:-nftban_global}"
readonly NFTBAN_NFT_FAMILY="${NFTBAN_NFT_FAMILY:-inet}"

# Port configuration files
readonly NFTBAN_PORT_CONFIG_DIR="${NFTBAN_CONFIG_DIR}/ports"
readonly NFTBAN_IPV4_INPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv4-input.conf"
readonly NFTBAN_IPV4_OUTPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv4-output.conf"
readonly NFTBAN_IPV6_INPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv6-input.conf"
readonly NFTBAN_IPV6_OUTPUT_PORTS="${NFTBAN_PORT_CONFIG_DIR}/ipv6-output.conf"

# =============================================================================
# TABLE MANAGEMENT
# =============================================================================

# Check if nftables table exists
nftban_nftables_check_table() {
    nft list table "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" &>/dev/null
}

# Create nftables table structure
nftban_nftables_create_table() {
    nftban_log_info "Creating nftables table: $NFTBAN_NFT_FAMILY $NFTBAN_NFT_TABLE"
    
    # Create table
    nft add table "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" 2>/dev/null || true
    
    # =============================================================================
    # WHITELIST SETS
    # =============================================================================
    nft add set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" whitelist_v4 \
        "{ type ipv4_addr; flags interval; comment \"Whitelisted IPv4\"; }" 2>/dev/null || true
    
    nft add set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" whitelist_v6 \
        "{ type ipv6_addr; flags interval; comment \"Whitelisted IPv6\"; }" 2>/dev/null || true
    
    # =============================================================================
    # TEMPORARY BAN SETS (with timeout)
    # =============================================================================
    nft add set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" temp_ban_v4 \
        "{ type ipv4_addr; flags timeout; timeout 1h; comment \"Temporary bans IPv4\"; }" 2>/dev/null || true
    
    nft add set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" temp_ban_v6 \
        "{ type ipv6_addr; flags timeout; timeout 1h; comment \"Temporary bans IPv6\"; }" 2>/dev/null || true
    
    # =============================================================================
    # BLACKLIST SETS (permanent)
    # =============================================================================
    nft add set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" user_blacklist_v4 \
        "{ type ipv4_addr; flags interval; comment \"User blacklist IPv4\"; }" 2>/dev/null || true
    
    nft add set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" user_blacklist_v6 \
        "{ type ipv6_addr; flags interval; comment \"User blacklist IPv6\"; }" 2>/dev/null || true
    
    nft add set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" system_blacklist_v4 \
        "{ type ipv4_addr; flags interval; comment \"System blacklist IPv4\"; }" 2>/dev/null || true
    
    nft add set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" system_blacklist_v6 \
        "{ type ipv6_addr; flags interval; comment \"System blacklist IPv6\"; }" 2>/dev/null || true
    
    # =============================================================================
    # FEEDS SETS (threat intelligence) - NEW
    # =============================================================================
    nft add set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" feeds_v4 \
        "{ type ipv4_addr; flags interval; auto-merge; comment \"Threat feeds IPv4\"; }" 2>/dev/null || true
    
    nft add set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" feeds_v6 \
        "{ type ipv6_addr; flags interval; auto-merge; comment \"Threat feeds IPv6\"; }" 2>/dev/null || true
    
    # =============================================================================
    # BASE CHAINS
    # =============================================================================
    nft add chain "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        "{ type filter hook input priority filter; policy accept; }" 2>/dev/null || true
    
    nft add chain "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" output \
        "{ type filter hook output priority filter; policy accept; }" 2>/dev/null || true
    
    nftban_log_success "nftables table created successfully"
    
    # Apply rules after table creation
    nftban_nftables_apply_rules
}

# Apply firewall rules
nftban_nftables_apply_rules() {
    nftban_log_info "Applying nftables rules..."
    
    if ! nftban_nftables_check_table; then
        nftban_log_error "Table does not exist"
        return 1
    fi
    
    # Flush existing rules
    nft flush chain "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input 2>/dev/null || true
    nft flush chain "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" output 2>/dev/null || true
    
    # =============================================================================
    # INPUT CHAIN RULES (priority order is CRITICAL!)
    # =============================================================================
    
    # RULE 1: Accept established connections (ALWAYS FIRST)
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        ct state established,related counter accept \
        comment "Accept established/related" 2>/dev/null || true
    
    # RULE 2: Accept loopback (ALWAYS ALLOW)
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        iif lo counter accept \
        comment "Accept loopback" 2>/dev/null || true
    
    # RULE 3: WHITELIST CHECK (HIGHEST PRIORITY - ALWAYS ACCEPT)
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        ip saddr @whitelist_v4 counter accept \
        comment "Accept whitelisted IPv4" 2>/dev/null || true
    
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        ip6 saddr @whitelist_v6 counter accept \
        comment "Accept whitelisted IPv6" 2>/dev/null || true
    
    # RULE 4: THREAT FEEDS BLOCKING (BLOCK BEFORE OTHER BANS)
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        ip saddr @feeds_v4 counter drop \
        comment "Block threat feeds IPv4" 2>/dev/null || true
    
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        ip6 saddr @feeds_v6 counter drop \
        comment "Block threat feeds IPv6" 2>/dev/null || true
    
    # RULE 5: TEMPORARY BANS (fail2ban dynamic bans)
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        ip saddr @temp_ban_v4 counter drop \
        comment "Block temporary banned IPv4" 2>/dev/null || true
    
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        ip6 saddr @temp_ban_v6 counter drop \
        comment "Block temporary banned IPv6" 2>/dev/null || true
    
    # RULE 6: USER BLACKLIST (permanent user-added bans)
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        ip saddr @user_blacklist_v4 counter drop \
        comment "Block user blacklist IPv4" 2>/dev/null || true
    
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        ip6 saddr @user_blacklist_v6 counter drop \
        comment "Block user blacklist IPv6" 2>/dev/null || true
    
    # RULE 7: SYSTEM BLACKLIST (permanent system-added bans)
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        ip saddr @system_blacklist_v4 counter drop \
        comment "Block system blacklist IPv4" 2>/dev/null || true
    
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        ip6 saddr @system_blacklist_v6 counter drop \
        comment "Block system blacklist IPv6" 2>/dev/null || true
    
    # RULE 8: Accept ICMP/ICMPv6 (for network diagnostics)
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        ip protocol icmp counter accept \
        comment "Accept ICMP" 2>/dev/null || true
    
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" input \
        ip6 nexthdr icmpv6 counter accept \
        comment "Accept ICMPv6" 2>/dev/null || true
    
    # RULE 9: Apply configured port rules
    nftban_nftables_apply_port_rules "input"
    
    # =============================================================================
    # OUTPUT CHAIN RULES
    # =============================================================================
    
    # Accept established connections
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" output \
        ct state established,related counter accept \
        comment "Accept established/related" 2>/dev/null || true
    
    # Accept loopback
    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" output \
        oif lo counter accept \
        comment "Accept loopback" 2>/dev/null || true
    
    # Apply port rules
    nftban_nftables_apply_port_rules "output"
    
    nftban_log_success "nftables rules applied successfully"
}

# Delete table (for flush operation)
nftban_nftables_delete_table() {
    nftban_log_warning "Deleting nftables table: $NFTBAN_NFT_FAMILY $NFTBAN_NFT_TABLE"
    nft delete table "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" 2>/dev/null || true
    nftban_log_success "Table deleted"
}

# Verify table structure
nftban_nftables_verify_structure() {
    local missing=0
    
    if ! nftban_nftables_check_table; then
        nftban_log_error "Table does not exist"
        return 1
    fi
    
    local required_sets=(
        "whitelist_v4" "whitelist_v6"
        "temp_ban_v4" "temp_ban_v6"
        "user_blacklist_v4" "user_blacklist_v6"
        "system_blacklist_v4" "system_blacklist_v6"
        "feeds_v4" "feeds_v6"
    )
    
    for set_name in "${required_sets[@]}"; do
        if ! nft list set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "$set_name" &>/dev/null; then
            nftban_log_error "Missing set: $set_name"
            ((missing++))
        fi
    done
    
    if [[ $missing -gt 0 ]]; then
        nftban_log_error "Structure verification failed: $missing missing sets"
        return 1
    fi
    
    nftban_log_success "Structure verification passed"
    return 0
}

# Show set statistics
nftban_nftables_show_set_stats() {
    echo "  Sets:"
    for ver in 4 6; do
        for set_type in whitelist temp_ban user_blacklist system_blacklist feeds; do
            if nft list set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "${set_type}_v${ver}" &>/dev/null; then
                local count
                count=$(nft list set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "${set_type}_v${ver}" 2>/dev/null | \
                        grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F.:]\+' | wc -l)
                printf "    %-25s %3d IPs\n" "${set_type}_v${ver}:" "$count"
            fi
        done
    done
}

# Show status
nftban_nftables_show_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  nftables Status"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    if nftban_nftables_check_table; then
        echo -e "${NFTBAN_GREEN}✓${NFTBAN_NC} Table exists: $NFTBAN_NFT_FAMILY $NFTBAN_NFT_TABLE"
        echo ""
        nftban_nftables_show_set_stats
    else
        echo -e "${NFTBAN_RED}✗${NFTBAN_NC} Table not found"
        echo "Run: nftban nftables init"
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

# Apply port rules from config files
nftban_nftables_apply_port_rules() {
    local direction="$1"  # input or output
    
    # Determine which config files to use
    local ipv4_config ipv6_config
    if [[ "$direction" == "input" ]]; then
        ipv4_config="$NFTBAN_IPV4_INPUT_PORTS"
        ipv6_config="$NFTBAN_IPV6_INPUT_PORTS"
    else
        ipv4_config="$NFTBAN_IPV4_OUTPUT_PORTS"
        ipv6_config="$NFTBAN_IPV6_OUTPUT_PORTS"
    fi
    
    # Process IPv4 ports
    if [[ -f "$ipv4_config" ]]; then
        while IFS='|' read -r port protocol; do
            [[ -z "$port" || "$port" =~ ^# ]] && continue
            
            case "$protocol" in
                T)
                    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "$direction" \
                        tcp dport "$port" counter accept \
                        comment "Allow TCP port $port" 2>/dev/null || true
                    ;;
                U)
                    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "$direction" \
                        udp dport "$port" counter accept \
                        comment "Allow UDP port $port" 2>/dev/null || true
                    ;;
                B)
                    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "$direction" \
                        tcp dport "$port" counter accept \
                        comment "Allow TCP port $port" 2>/dev/null || true
                    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "$direction" \
                        udp dport "$port" counter accept \
                        comment "Allow UDP port $port" 2>/dev/null || true
                    ;;
            esac
        done < <(grep -vE '^#|^$' "$ipv4_config" 2>/dev/null || true)
    fi
    
    # Process IPv6 ports
    if [[ -f "$ipv6_config" ]]; then
        while IFS='|' read -r port protocol; do
            [[ -z "$port" || "$port" =~ ^# ]] && continue
            
            case "$protocol" in
                T)
                    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "$direction" \
                        ip6 version 6 tcp dport "$port" counter accept \
                        comment "Allow TCP port $port IPv6" 2>/dev/null || true
                    ;;
                U)
                    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "$direction" \
                        ip6 version 6 udp dport "$port" counter accept \
                        comment "Allow UDP port $port IPv6" 2>/dev/null || true
                    ;;
                B)
                    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "$direction" \
                        ip6 version 6 tcp dport "$port" counter accept \
                        comment "Allow TCP port $port IPv6" 2>/dev/null || true
                    nft add rule "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "$direction" \
                        ip6 version 6 udp dport "$port" counter accept \
                        comment "Allow UDP port $port IPv6" 2>/dev/null || true
                    ;;
            esac
        done < <(grep -vE '^#|^$' "$ipv6_config" 2>/dev/null || true)
    fi
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_nftables_check_table
export -f nftban_nftables_create_table
export -f nftban_nftables_apply_rules
export -f nftban_nftables_delete_table
export -f nftban_nftables_verify_structure
export -f nftban_nftables_show_set_stats
export -f nftban_nftables_show_status
export -f nftban_nftables_init_port_configs
export -f nftban_nftables_add_port
export -f nftban_nftables_remove_port
export -f nftban_nftables_list_ports
export -f nftban_nftables_apply_port_rules

nftban_log_debug "NFTBan nftables Module loaded (v1.1.0 with Feeds support)"