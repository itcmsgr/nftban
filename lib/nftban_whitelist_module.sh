#!/usr/bin/env bash

# =============================================================================
# NFTBan Whitelist Module
# Version: 1.0.0
# Whitelist management with priority handling
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_WHITELIST_LOADED:-}" ]] && return 0
readonly NFTBAN_WHITELIST_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_WHITELIST_SYSTEM="${NFTBAN_CONFIG_DIR}/whitelist-system.conf"
readonly NFTBAN_WHITELIST_USER="${NFTBAN_CONFIG_DIR}/whitelist-user.conf"
readonly NFTBAN_WHITELIST_CF="${NFTBAN_CONFIG_DIR}/whitelist-cloudflare.conf"

# =============================================================================
# INITIALIZATION
# =============================================================================

nftban_whitelist_init() {
    nftban_log_info "Initializing whitelist system..."
    
    mkdir -p "$NFTBAN_CONFIG_DIR"
    
    # Create system whitelist
    if [[ ! -f "$NFTBAN_WHITELIST_SYSTEM" ]]; then
        cat > "$NFTBAN_WHITELIST_SYSTEM" << 'EOF'
# =============================================================================
# nftban System Whitelist
# =============================================================================
# Auto-managed IPs that should NEVER be banned
# DO NOT edit manually - this file is auto-generated
# =============================================================================

127.0.0.1       # Localhost IPv4
::1             # Localhost IPv6
EOF
        chmod 644 "$NFTBAN_WHITELIST_SYSTEM"
        nftban_log_debug "Created system whitelist"
    fi
    
    # Create user whitelist
    if [[ ! -f "$NFTBAN_WHITELIST_USER" ]]; then
        cat > "$NFTBAN_WHITELIST_USER" << 'EOF'
# =============================================================================
# nftban User Whitelist
# =============================================================================
# Add IPs or CIDR ranges that should NEVER be banned
# Format: IP_ADDRESS  # Comment
# Examples:
#   192.168.1.100     # Office server
#   10.0.0.0/8        # Private network
#   2001:db8::/32     # IPv6 range
# =============================================================================

EOF
        chmod 644 "$NFTBAN_WHITELIST_USER"
        nftban_log_debug "Created user whitelist"
    fi
    
    # Create Cloudflare whitelist placeholder
    if [[ ! -f "$NFTBAN_WHITELIST_CF" ]]; then
        cat > "$NFTBAN_WHITELIST_CF" << 'EOF'
# =============================================================================
# nftban Cloudflare Whitelist
# =============================================================================
# Auto-managed - Populated when Cloudflare integration is enabled
# =============================================================================

EOF
        chmod 644 "$NFTBAN_WHITELIST_CF"
        nftban_log_debug "Created Cloudflare whitelist"
    fi
    
    nftban_log_success "Whitelist system initialized"
}

# =============================================================================
# IP MANAGEMENT
# =============================================================================

# Add IP to whitelist
nftban_whitelist_add_ip() {
    local ip="$1"
    local comment="${2:-Added on $(date +'%Y-%m-%d')}"
    
    # Validate IP
    nftban_validate_ip "$ip" || return 1
    
    local ver
    ver=$(nftban_detect_ip_version "$ip")
    
    # Check if already whitelisted
    if nftban_whitelist_check_ip "$ip"; then
        nftban_log_warning "IP $ip is already whitelisted"
        return 0
    fi
    
    # Add to user whitelist file
    echo "${ip}  # ${comment}" >> "$NFTBAN_WHITELIST_USER"
    
    # Add to nftables set
    if nftban_nftables_check_table; then
        if nft add element "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "whitelist_v${ver}" "{ $ip }" 2>/dev/null; then
            nftban_log_success "Added $ip to whitelist (nftables + file)"
        else
            nftban_log_warning "Added $ip to file, but failed to add to nftables"
        fi
    else
        nftban_log_success "Added $ip to whitelist file (nftables not initialized)"
    fi
    
    # Rebuild search index
    if declare -f nftban_search_build_index &>/dev/null; then
        nftban_search_build_index
    fi
    
    nftban_log "WHITELIST" "Added: ${ip}"
    
    return 0
}

# Remove IP from whitelist
nftban_whitelist_remove_ip() {
    local ip="$1"
    
    # Validate IP
    nftban_validate_ip "$ip" || return 1
    
    local ver
    ver=$(nftban_detect_ip_version "$ip")
    
    local removed=false
    
    # Remove from user whitelist file
    if [[ -f "$NFTBAN_WHITELIST_USER" ]] && grep -qE "^${ip}([[:space:]]|$)" "$NFTBAN_WHITELIST_USER"; then
        sed -i "/^${ip}[[:space:]]/d" "$NFTBAN_WHITELIST_USER"
        nftban_log_success "Removed $ip from user whitelist file"
        removed=true
    fi
    
    # Remove from nftables set
    if nftban_nftables_check_table; then
        if nft delete element "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "whitelist_v${ver}" "{ $ip }" 2>/dev/null; then
            nftban_log_success "Removed $ip from nftables whitelist"
            removed=true
        fi
    fi
    
    if [[ "$removed" == true ]]; then
        # Rebuild search index
        if declare -f nftban_search_build_index &>/dev/null; then
            nftban_search_build_index
        fi
        
        nftban_log "WHITELIST" "Removed: ${ip}"
        return 0
    else
        nftban_log_warning "IP $ip not found in whitelist"
        return 1
    fi
}

# Check if IP is whitelisted
nftban_whitelist_check_ip() {
    local ip="$1"
    
    # Validate IP
    nftban_validate_ip "$ip" || return 2
    
    local whitelist_files=(
        "$NFTBAN_WHITELIST_SYSTEM"
        "$NFTBAN_WHITELIST_USER"
        "$NFTBAN_WHITELIST_CF"
    )
    
    for file in "${whitelist_files[@]}"; do
        [[ ! -f "$file" ]] && continue
        
        # Check for exact match or CIDR match
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue
            
            local entry
            entry=$(echo "$line" | awk '{print $1}')
            [[ -z "$entry" ]] && continue
            
            # Exact match
            if [[ "$entry" == "$ip" ]]; then
                return 0
            fi
            
            # Simple CIDR prefix match (for basic cases)
            if [[ "$entry" =~ / ]]; then
                local network="${entry%/*}"
                local prefix="${entry#*/}"
                
                # Basic IPv4 CIDR matching
                if [[ "$prefix" == "24" ]]; then
                    [[ "${ip%.*}" == "${network%.*}" ]] && return 0
                elif [[ "$prefix" == "16" ]]; then
                    [[ "${ip%.*.*}" == "${network%.*.*}" ]] && return 0
                elif [[ "$prefix" == "8" ]]; then
                    [[ "${ip%%.*}" == "${network%%.*}" ]] && return 0
                fi
            fi
        done < "$file"
    done
    
    return 1
}

# List whitelisted IPs
nftban_whitelist_list() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Whitelisted IPs"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    echo -e "${NFTBAN_CYAN}System Whitelist:${NFTBAN_NC}"
    if [[ -f "$NFTBAN_WHITELIST_SYSTEM" ]]; then
        grep -E "^[0-9a-fA-F.:]+([[:space:]]|$)" "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null | nl -w3 -s'. ' || echo "  (empty)"
    else
        echo "  File not found"
    fi
    echo ""
    
    echo -e "${NFTBAN_CYAN}User Whitelist:${NFTBAN_NC}"
    if [[ -f "$NFTBAN_WHITELIST_USER" ]]; then
        grep -E "^[0-9a-fA-F.:]+([[:space:]]|$)" "$NFTBAN_WHITELIST_USER" 2>/dev/null | nl -w3 -s'. ' || echo "  (empty)"
    else
        echo "  File not found"
    fi
    echo ""
    
    echo -e "${NFTBAN_CYAN}Cloudflare Whitelist:${NFTBAN_NC}"
    if [[ -f "$NFTBAN_WHITELIST_CF" ]]; then
        local cf_count
        cf_count=$(grep -cE "^[0-9a-fA-F.:]+([[:space:]]|$)" "$NFTBAN_WHITELIST_CF" 2>/dev/null || echo "0")
        if [[ $cf_count -gt 0 ]]; then
            echo "  $cf_count Cloudflare IP ranges"
            echo "  (Use 'nftban cloudflare status' for details)"
        else
            echo "  (empty - enable with: nftban cloudflare enable)"
        fi
    else
        echo "  File not found"
    fi
    echo ""
    
    # Show nftables sets if available
    if nftban_nftables_check_table; then
        echo -e "${NFTBAN_CYAN}nftables Sets:${NFTBAN_NC}"
        for ver in 4 6; do
            if nft list set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "whitelist_v${ver}" &>/dev/null; then
                local count
                count=$(nft list set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "whitelist_v${ver}" 2>/dev/null | \
                        grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F.:]\+' | wc -l)
                printf "  %-20s %3d IPs\n" "whitelist_v${ver}:" "$count"
            fi
        done
        echo ""
    fi
}

# Sync whitelist files to nftables
nftban_whitelist_sync_to_nftables() {
    nftban_log_info "Syncing whitelist to nftables..."
    
    if ! nftban_nftables_check_table; then
        nftban_log_error "nftables table not initialized"
        return 1
    fi
    
    # Flush existing whitelist sets
    nft flush set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" whitelist_v4 2>/dev/null || true
    nft flush set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" whitelist_v6 2>/dev/null || true
    
    local synced_v4=0
    local synced_v6=0
    
    # Process all whitelist files
    local whitelist_files=(
        "$NFTBAN_WHITELIST_SYSTEM"
        "$NFTBAN_WHITELIST_USER"
        "$NFTBAN_WHITELIST_CF"
    )
    
    for file in "${whitelist_files[@]}"; do
        [[ ! -f "$file" ]] && continue
        
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue
            
            local ip
            ip=$(echo "$line" | awk '{print $1}')
            [[ -z "$ip" ]] && continue
            
            # Detect IP version and add to appropriate set
            local ver
            ver=$(nftban_detect_ip_version "$ip")
            
            if [[ "$ver" == "4" ]]; then
                if nft add element "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" whitelist_v4 "{ $ip }" 2>/dev/null; then
                    ((synced_v4++))
                fi
            elif [[ "$ver" == "6" ]]; then
                if nft add element "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" whitelist_v6 "{ $ip }" 2>/dev/null; then
                    ((synced_v6++))
                fi
            fi
        done < "$file"
    done
    
    nftban_log_success "Synced to nftables: $synced_v4 IPv4, $synced_v6 IPv6"
    
    return 0
}

# Verify whitelist system
nftban_whitelist_verify() {
    local issues=0
    
    # Check if files exist
    if [[ ! -f "$NFTBAN_WHITELIST_SYSTEM" ]]; then
        nftban_log_error "System whitelist missing"
        ((issues++))
    fi
    
    if [[ ! -f "$NFTBAN_WHITELIST_USER" ]]; then
        nftban_log_warning "User whitelist missing"
        ((issues++))
    fi
    
    # Check if localhost is whitelisted
    if ! nftban_whitelist_check_ip "127.0.0.1"; then
        nftban_log_error "Localhost (127.0.0.1) not whitelisted!"
        ((issues++))
    fi
    
    if ! nftban_whitelist_check_ip "::1"; then
        nftban_log_error "Localhost (::1) not whitelisted!"
        ((issues++))
    fi
    
    # Check nftables sync
    if nftban_nftables_check_table; then
        local file_count_v4 file_count_v6 nft_count_v4 nft_count_v6
        
        file_count_v4=$(grep -hE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" \
                        "$NFTBAN_WHITELIST_SYSTEM" "$NFTBAN_WHITELIST_USER" 2>/dev/null | wc -l)
        
        nft_count_v4=$(nft list set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" whitelist_v4 2>/dev/null | \
                       grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | wc -l)
        
        if [[ $file_count_v4 -ne $nft_count_v4 ]]; then
            nftban_log_warning "IPv4 whitelist out of sync (files: $file_count_v4, nftables: $nft_count_v4)"
            ((issues++))
        fi
    fi
    
    return $issues
}

# Add server's own IPs to whitelist
nftban_whitelist_add_server_ips() {
    nftban_log_info "Adding server IPs to whitelist..."
    
    # Get server IPs
    local server_ips
    server_ips=$(ip -o addr show | awk '/inet/ {print $4}' | grep -v '^127\.' | cut -d'/' -f1)
    
    for ip in $server_ips; do
        if ! nftban_whitelist_check_ip "$ip"; then
            # Add to system whitelist
            if ! grep -q "^${ip}[[:space:]]" "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null; then
                echo "${ip}  # Server IP (auto-detected)" >> "$NFTBAN_WHITELIST_SYSTEM"
                nftban_log_info "Added server IP: $ip"
            fi
        fi
    done
    
    # Sync to nftables
    nftban_whitelist_sync_to_nftables
}

# Get whitelist statistics
nftban_whitelist_get_stats() {
    local system_count user_count cf_count
    
    system_count=$(grep -cE "^[0-9a-fA-F.:]+([[:space:]]|$)" "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null || echo "0")
    user_count=$(grep -cE "^[0-9a-fA-F.:]+([[:space:]]|$)" "$NFTBAN_WHITELIST_USER" 2>/dev/null || echo "0")
    cf_count=$(grep -cE "^[0-9a-fA-F.:]+([[:space:]]|$)" "$NFTBAN_WHITELIST_CF" 2>/dev/null || echo "0")
    
    echo "System: $system_count | User: $user_count | Cloudflare: $cf_count | Total: $((system_count + user_count + cf_count))"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_whitelist_init
export -f nftban_whitelist_add_ip
export -f nftban_whitelist_remove_ip
export -f nftban_whitelist_check_ip
export -f nftban_whitelist_list
export -f nftban_whitelist_sync_to_nftables
export -f nftban_whitelist_verify
export -f nftban_whitelist_add_server_ips
export -f nftban_whitelist_get_stats

nftban_log_debug "NFTBan Whitelist Module loaded"