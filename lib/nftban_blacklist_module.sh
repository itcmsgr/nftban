#!/usr/bin/env bash

# =============================================================================
# NFTBan Blacklist Module
# Version: 1.0.0
# Ban operations, temporary bans, and persistent offender management
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_BLACKLIST_LOADED:-}" ]] && return 0
readonly NFTBAN_BLACKLIST_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_BLACKLIST_PERSISTENT="${NFTBAN_CONFIG_DIR}/blacklist-persistent.conf"
readonly NFTBAN_BLACKLIST_USER="${NFTBAN_CONFIG_DIR}/blacklist-user.conf"
readonly NFTBAN_RATE_LIMIT_FILE="${NFTBAN_DATA_DIR}/rate-limit-tracker.tmp"

# Ban settings (can be overridden in config)
NFTBAN_DEFAULT_BAN_TIME="${NFTBAN_DEFAULT_BAN_TIME:-3600}"
NFTBAN_PERSISTENT_THRESHOLD="${NFTBAN_PERSISTENT_THRESHOLD:-3}"
NFTBAN_RATE_LIMIT_PER_MIN="${NFTBAN_RATE_LIMIT_PER_MIN:-60}"

# =============================================================================
# INITIALIZATION
# =============================================================================

nftban_blacklist_init() {
    nftban_log_info "Initializing blacklist system..."
    
    mkdir -p "$NFTBAN_CONFIG_DIR" "$NFTBAN_DATA_DIR"
    
    # Create persistent blacklist
    if [[ ! -f "$NFTBAN_BLACKLIST_PERSISTENT" ]]; then
        cat > "$NFTBAN_BLACKLIST_PERSISTENT" << 'EOF'
# =============================================================================
# nftban Persistent Blacklist
# =============================================================================
# Auto-managed: IPs that have been banned multiple times
# These are automatically added when threshold is exceeded
# Format: IP_ADDRESS  # Date - Reason
# =============================================================================

EOF
        chmod 644 "$NFTBAN_BLACKLIST_PERSISTENT"
        nftban_log_debug "Created persistent blacklist"
    fi
    
    # Create user blacklist
    if [[ ! -f "$NFTBAN_BLACKLIST_USER" ]]; then
        cat > "$NFTBAN_BLACKLIST_USER" << 'EOF'
# =============================================================================
# nftban User Blacklist
# =============================================================================
# Manually managed permanent bans
# Format: IP_ADDRESS  # Comment
# Examples:
#   192.0.2.100    # Known attacker
#   198.51.100.0/24  # Malicious network
# =============================================================================

EOF
        chmod 644 "$NFTBAN_BLACKLIST_USER"
        nftban_log_debug "Created user blacklist"
    fi
    
    # Initialize rate limit tracker
    touch "$NFTBAN_RATE_LIMIT_FILE"
    
    nftban_log_success "Blacklist system initialized"
}

# =============================================================================
# RATE LIMITING
# =============================================================================

nftban_blacklist_check_rate_limit() {
    local current_time one_minute_ago recent_count
    current_time=$(date +%s)
    one_minute_ago=$((current_time - 60))
    
    # Count recent ban attempts
    recent_count=$(awk -v cutoff="$one_minute_ago" '$1 >= cutoff' "$NFTBAN_RATE_LIMIT_FILE" 2>/dev/null | wc -l)
    
    if [[ $recent_count -ge $NFTBAN_RATE_LIMIT_PER_MIN ]]; then
        nftban_log_error "RATE LIMIT EXCEEDED: ${recent_count} bans/min (limit: ${NFTBAN_RATE_LIMIT_PER_MIN})"
        return 1
    fi
    
    return 0
}

nftban_blacklist_record_ban_attempt() {
    local current_time
    current_time=$(date +%s)
    
    echo "$current_time" >> "$NFTBAN_RATE_LIMIT_FILE"
    
    # Clean old entries (older than 2 minutes)
    local two_minutes_ago=$((current_time - 120))
    awk -v cutoff="$two_minutes_ago" '$1 >= cutoff' "$NFTBAN_RATE_LIMIT_FILE" > "${NFTBAN_RATE_LIMIT_FILE}.tmp" 2>/dev/null || true
    mv "${NFTBAN_RATE_LIMIT_FILE}.tmp" "$NFTBAN_RATE_LIMIT_FILE" 2>/dev/null || true
}

# =============================================================================
# TEMPORARY BAN OPERATIONS
# =============================================================================

# Ban IP temporarily
nftban_blacklist_ban_ip() {
    local ip="$1"
    local jail="${2:-manual}"
    local ban_time="${3:-$NFTBAN_DEFAULT_BAN_TIME}"
    
    # Validate IP
    nftban_validate_ip "$ip" || return 1
    
    local ver
    ver=$(nftban_detect_ip_version "$ip")
    
    # Check rate limit
    nftban_blacklist_check_rate_limit || {
        nftban_log_ban "$ip" "$jail" "DENIED" "Rate limit exceeded"
        return 1
    }
    
    nftban_blacklist_record_ban_attempt
    
    # CRITICAL: Check whitelist first
    if nftban_whitelist_check_ip "$ip"; then
        nftban_log_warning "IP $ip is whitelisted - BAN DENIED"
        nftban_log_ban "$ip" "$jail" "DENIED" "Whitelisted"
        return 1
    fi
    
    # Check if already banned in nftables
    if nftban_nftables_check_table; then
        if nft list set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "temp_ban_v${ver}" 2>/dev/null | grep -q "$ip"; then
            nftban_log_warning "IP $ip already banned (skipping)"
            nftban_log_ban "$ip" "$jail" "ALREADY_BANNED" "Exists in temp_ban set"
            return 0
        fi
    else
        nftban_log_error "nftables table not initialized"
        return 1
    fi
    
    # Execute ban
    if nft add element "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "temp_ban_v${ver}" \
        "{ $ip timeout ${ban_time}s comment \"${jail}\" }" 2>/dev/null; then
        
        nftban_log_success "Banned $ip for ${ban_time}s (jail: $jail)"
        nftban_log_ban "$ip" "$jail" "BANNED" "Timeout: ${ban_time}s"
        
        # Check for persistent offender
        if nftban_blacklist_check_persistent_offender "$ip"; then
            local ban_count
            ban_count=$(grep -c "|${ip}|.*|BANNED|" "$NFTBAN_BAN_LOG" 2>/dev/null || echo "0")
            nftban_blacklist_add_permanent "$ip" "Repeat offender: ${ban_count} bans from ${jail}"
        fi
        
        return 0
    else
        nftban_log_error "Failed to ban $ip"
        nftban_log_ban "$ip" "$jail" "ERROR" "nftables add failed"
        return 1
    fi
}

# Unban IP
nftban_blacklist_unban_ip() {
    local ip="$1"
    local jail="${2:-manual}"
    
    # Validate IP
    nftban_validate_ip "$ip" || return 1
    
    local ver
    ver=$(nftban_detect_ip_version "$ip")
    
    if ! nftban_nftables_check_table; then
        nftban_log_error "nftables table not initialized"
        return 1
    fi
    
    # Remove from temp_ban set
    if nft delete element "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "temp_ban_v${ver}" "{ $ip }" 2>/dev/null; then
        nftban_log_success "Unbanned $ip"
        nftban_log_ban "$ip" "$jail" "UNBANNED" "Manual unban"
        return 0
    else
        nftban_log_warning "IP $ip not found in temporary ban list"
        return 1
    fi
}

# =============================================================================
# PERSISTENT OFFENDER MANAGEMENT
# =============================================================================

# Check if IP is a persistent offender
nftban_blacklist_check_persistent_offender() {
    local ip="$1"
    local threshold="$NFTBAN_PERSISTENT_THRESHOLD"
    
    [[ "$threshold" == "0" ]] && return 1
    [[ ! -f "$NFTBAN_BAN_LOG" ]] && return 1
    
    local ban_count
    ban_count=$(grep -c "|${ip}|.*|BANNED|" "$NFTBAN_BAN_LOG" 2>/dev/null || echo "0")
    
    if [[ $ban_count -ge $threshold ]]; then
        nftban_log_warning "IP $ip is persistent offender ($ban_count bans, threshold: $threshold)"
        return 0
    fi
    
    return 1
}

# Add IP to persistent blacklist
nftban_blacklist_add_permanent() {
    local ip="$1"
    local reason="${2:-Manual permanent ban}"
    
    # Validate IP
    nftban_validate_ip "$ip" || return 1
    
    local ver
    ver=$(nftban_detect_ip_version "$ip")
    
    # Check if already in persistent blacklist
    if grep -qE "^${ip}([[:space:]]|$)" "$NFTBAN_BLACKLIST_PERSISTENT" 2>/dev/null; then
        nftban_log_warning "IP $ip already in persistent blacklist"
        return 0
    fi
    
    # Add to file
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "${ip}  # ${timestamp} - ${reason}" >> "$NFTBAN_BLACKLIST_PERSISTENT"
    
    # Add to nftables user_blacklist set (permanent)
    if nftban_nftables_check_table; then
        if nft add element "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "user_blacklist_v${ver}" "{ $ip }" 2>/dev/null; then
            nftban_log_success "Added $ip to permanent blacklist (nftables + file)"
        else
            nftban_log_warning "Added to file but failed to add to nftables"
        fi
    else
        nftban_log_success "Added $ip to permanent blacklist file"
    fi
    
    nftban_log_ban "$ip" "PERSISTENT" "PERMANENT" "$reason"
    
    # Rebuild search index
    if declare -f nftban_search_build_index &>/dev/null; then
        nftban_search_build_index
    fi
    
    return 0
}

# Remove IP from persistent blacklist
nftban_blacklist_remove_permanent() {
    local ip="$1"
    
    # Validate IP
    nftban_validate_ip "$ip" || return 1
    
    local ver
    ver=$(nftban_detect_ip_version "$ip")
    
    local removed=false
    
    # Remove from files
    for file in "$NFTBAN_BLACKLIST_PERSISTENT" "$NFTBAN_BLACKLIST_USER"; do
        if [[ -f "$file" ]] && grep -qE "^${ip}([[:space:]]|$)" "$file"; then
            sed -i "/^${ip}[[:space:]]/d" "$file"
            nftban_log_success "Removed $ip from $(basename "$file")"
            removed=true
        fi
    done
    
    # Remove from nftables
    if nftban_nftables_check_table; then
        if nft delete element "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "user_blacklist_v${ver}" "{ $ip }" 2>/dev/null; then
            nftban_log_success "Removed $ip from nftables user_blacklist"
            removed=true
        fi
    fi
    
    if [[ "$removed" == true ]]; then
        # Rebuild search index
        if declare -f nftban_search_build_index &>/dev/null; then
            nftban_search_build_index
        fi
        
        nftban_log_ban "$ip" "MANUAL" "UNBLACKLISTED" "Removed from permanent blacklist"
        return 0
    else
        nftban_log_warning "IP $ip not found in permanent blacklist"
        return 1
    fi
}

# List permanent blacklist
nftban_blacklist_list_permanent() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Permanent Blacklist"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    
    echo -e "${NFTBAN_CYAN}Persistent Offenders (Auto-added):${NFTBAN_NC}"
    if [[ -f "$NFTBAN_BLACKLIST_PERSISTENT" ]]; then
        grep -E "^[0-9a-fA-F.:]+([[:space:]]|$)" "$NFTBAN_BLACKLIST_PERSISTENT" 2>/dev/null | nl -w3 -s'. ' || echo "  (empty)"
    else
        echo "  File not found"
    fi
    echo ""
    
    echo -e "${NFTBAN_CYAN}User Blacklist (Manual):${NFTBAN_NC}"
    if [[ -f "$NFTBAN_BLACKLIST_USER" ]]; then
        grep -E "^[0-9a-fA-F.:]+([[:space:]]|$)" "$NFTBAN_BLACKLIST_USER" 2>/dev/null | nl -w3 -s'. ' || echo "  (empty)"
    else
        echo "  File not found"
    fi
    echo ""
    
    # Show nftables sets if available
    if nftban_nftables_check_table; then
        echo -e "${NFTBAN_CYAN}nftables Sets:${NFTBAN_NC}"
        for ver in 4 6; do
            if nft list set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "user_blacklist_v${ver}" &>/dev/null; then
                local count
                count=$(nft list set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "user_blacklist_v${ver}" 2>/dev/null | \
                        grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F.:]\+' | wc -l)
                printf "  %-25s %3d IPs\n" "user_blacklist_v${ver}:" "$count"
            fi
            
            if nft list set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "temp_ban_v${ver}" &>/dev/null; then
                local count
                count=$(nft list set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "temp_ban_v${ver}" 2>/dev/null | \
                        grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F.:]\+' | wc -l)
                printf "  %-25s %3d IPs\n" "temp_ban_v${ver}:" "$count"
            fi
        done
        echo ""
    fi
}

# Sync blacklist to nftables
nftban_blacklist_sync_to_nftables() {
    nftban_log_info "Syncing blacklist to nftables..."
    
    if ! nftban_nftables_check_table; then
        nftban_log_error "nftables table not initialized"
        return 1
    fi
    
    # Flush existing blacklist sets
    nft flush set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" user_blacklist_v4 2>/dev/null || true
    nft flush set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" user_blacklist_v6 2>/dev/null || true
    
    local synced_v4=0
    local synced_v6=0
    
    # Process blacklist files
    local blacklist_files=(
        "$NFTBAN_BLACKLIST_PERSISTENT"
        "$NFTBAN_BLACKLIST_USER"
    )
    
    for file in "${blacklist_files[@]}"; do
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
                if nft add element "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" user_blacklist_v4 "{ $ip }" 2>/dev/null; then
                    ((synced_v4++))
                fi
            elif [[ "$ver" == "6" ]]; then
                if nft add element "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" user_blacklist_v6 "{ $ip }" 2>/dev/null; then
                    ((synced_v6++))
                fi
            fi
        done < "$file"
    done
    
    nftban_log_success "Synced to nftables: $synced_v4 IPv4, $synced_v6 IPv6"
    
    return 0
}

# =============================================================================
# STATISTICS AND REPORTING
# =============================================================================

# Show recent ban statistics
nftban_blacklist_show_recent_stats() {
    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "  No ban data available"
        return 0
    fi
    
    local cutoff_time
    cutoff_time=$(date -d '24 hours ago' +'%Y-%m-%d %H:%M:%S' 2>/dev/null || \
                  date -v-24H +'%Y-%m-%d %H:%M:%S' 2>/dev/null)
    
    if [[ -n "$cutoff_time" ]]; then
        local total_bans denied_bans permanent_bans
        total_bans=$(awk -F'|' -v cutoff="$cutoff_time" '$1 >= cutoff && $4 == "BANNED"' "$NFTBAN_BAN_LOG" | wc -l)
        denied_bans=$(awk -F'|' -v cutoff="$cutoff_time" '$1 >= cutoff && $4 == "DENIED"' "$NFTBAN_BAN_LOG" | wc -l)
        permanent_bans=$(awk -F'|' -v cutoff="$cutoff_time" '$1 >= cutoff && $4 == "PERMANENT"' "$NFTBAN_BAN_LOG" | wc -l)
        
        echo "  Bans: $total_bans | Denied: $denied_bans | Permanent: $permanent_bans"
    fi
}

# Get top banned IPs
nftban_blacklist_get_top_ips() {
    local limit="${1:-10}"
    
    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        return 0
    fi
    
    awk -F'|' '$4 == "BANNED" {print $2}' "$NFTBAN_BAN_LOG" | \
        sort | uniq -c | sort -rn | head -n "$limit"
}

# Get ban count for IP
nftban_blacklist_get_ip_ban_count() {
    local ip="$1"
    
    if [[ ! -f "$NFTBAN_BAN_LOG" ]]; then
        echo "0"
        return 0
    fi
    
    grep -c "|${ip}|.*|BANNED|" "$NFTBAN_BAN_LOG" 2>/dev/null || echo "0"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_blacklist_init
export -f nftban_blacklist_check_rate_limit
export -f nftban_blacklist_record_ban_attempt
export -f nftban_blacklist_ban_ip
export -f nftban_blacklist_unban_ip
export -f nftban_blacklist_check_persistent_offender
export -f nftban_blacklist_add_permanent
export -f nftban_blacklist_remove_permanent
export -f nftban_blacklist_list_permanent
export -f nftban_blacklist_sync_to_nftables
export -f nftban_blacklist_show_recent_stats
export -f nftban_blacklist_get_top_ips
export -f nftban_blacklist_get_ip_ban_count

nftban_log_debug "NFTBan Blacklist Module loaded"