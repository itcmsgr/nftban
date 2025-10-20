#!/usr/bin/env bash

# =============================================================================
# NFTBan Whitelist Module
# Version: 0.9.0
# Location: lib/nftban_whitelist_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Whitelist management with auto-protection and split table architecture
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
readonly NFTBAN_WHITELIST_LOCK_DIR="${NFTBAN_LOCK_DIR:-/var/lock/nftban}"
readonly NFTBAN_WHITELIST_LOCK_TIMEOUT=5

# Ensure lock directory exists
[[ -d "$NFTBAN_WHITELIST_LOCK_DIR" ]] || mkdir -p "$NFTBAN_WHITELIST_LOCK_DIR" 2>/dev/null || true

# =============================================================================
# SECURITY: ATOMIC FILE WRITE HELPERS
# =============================================================================

# SECURITY: Atomic file append with exclusive lock (prevents race conditions)
_nftban_whitelist_safe_append() {
    local file="$1"
    local content="$2"
    local lockfile="${NFTBAN_WHITELIST_LOCK_DIR}/$(basename "$file").lock"

    (
        # Acquire exclusive lock for write
        if ! flock -x -w "$NFTBAN_WHITELIST_LOCK_TIMEOUT" 200; then
            nftban_log_error "Could not acquire write lock on $file"
            return 1
        fi

        # Append content under lock
        echo "$content" >> "$file"

    ) 200>"$lockfile"
}

# SECURITY: Atomic file modification with exclusive lock (sed operations)
_nftban_whitelist_safe_modify() {
    local file="$1"
    local sed_expression="$2"
    local lockfile="${NFTBAN_WHITELIST_LOCK_DIR}/$(basename "$file").lock"

    (
        # Acquire exclusive lock for write
        if ! flock -x -w "$NFTBAN_WHITELIST_LOCK_TIMEOUT" 200; then
            nftban_log_error "Could not acquire write lock on $file"
            return 1
        fi

        # Modify file under lock
        sed -i "$sed_expression" "$file"

    ) 200>"$lockfile"
}

# =============================================================================
# INITIALIZATION WITH AUTO-PROTECTION
# =============================================================================

nftban_whitelist_init() {
    nftban_log_info "Initializing whitelist system with auto-protection..."
    
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

# Common private network ranges (uncomment if needed):
# 10.0.0.0/8        # Private Class A
# 172.16.0.0/12     # Private Class B
# 192.168.0.0/16    # Private Class C
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
    
    # CRITICAL: Auto-protect server IPs
    nftban_whitelist_add_server_ips
    
    # CRITICAL: Auto-protect current user IP
    nftban_whitelist_protect_current_user
    
    nftban_log_success "Whitelist system initialized with protection"
}

# =============================================================================
# AUTO-PROTECTION: SERVER IPS
# =============================================================================

nftban_whitelist_add_server_ips() {
    nftban_log_info "Auto-protecting server interface IPs..."

    local protected_count=0

    # CRITICAL: ALWAYS protect localhost IPs first (BUG3 FIX)
    if ! grep -q '^127\.0\.0\.1' "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null; then
        _nftban_whitelist_safe_append "$NFTBAN_WHITELIST_SYSTEM" "127.0.0.1  # Localhost IPv4"
        nftban_log_success "Protected localhost IPv4"
        ((protected_count++))
    fi

    if ! grep -q '^::1' "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null; then
        _nftban_whitelist_safe_append "$NFTBAN_WHITELIST_SYSTEM" "::1  # Localhost IPv6"
        nftban_log_success "Protected localhost IPv6"
        ((protected_count++))
    fi

    # Get ALL server interface IPs (IPv4 and IPv6) - INCLUDING localhost
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue

        # Skip link-local IPv6 (fe80::) - they're not routable (BUG3.4 FIX)
        [[ "$ip" =~ ^fe80: ]] && continue

        # Skip if already whitelisted
        if grep -qE "^${ip}([[:space:]]|$)" "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null; then
            nftban_log_debug "Server IP already protected: $ip"
            continue
        fi

        # Add to system whitelist (SECURITY: atomic write with flock)
        _nftban_whitelist_safe_append "$NFTBAN_WHITELIST_SYSTEM" "${ip}  # Server IP (auto-detected on $(date +'%Y-%m-%d'))"
        nftban_log_success "Protected server IP: $ip"
        ((protected_count++))
    done < <(ip -o addr show 2>/dev/null | awk '/inet/ {gsub(/\/.*/, "", $4); print $4}' | sort -u)
    
    # Also get public IPs if possible
    local public_ipv4 public_ipv6
    
    public_ipv4=$(nftban_get_public_ip "ipv4")
    if [[ -n "$public_ipv4" ]] && ! grep -qE "^${public_ipv4}([[:space:]]|$)" "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null; then
        _nftban_whitelist_safe_append "$NFTBAN_WHITELIST_SYSTEM" "${public_ipv4}  # Server public IPv4 (auto-detected on $(date +'%Y-%m-%d'))"
        nftban_log_success "Protected public IPv4: $public_ipv4"
        ((protected_count++))
    fi

    public_ipv6=$(nftban_get_public_ip "ipv6")
    if [[ -n "$public_ipv6" ]] && ! grep -qE "^${public_ipv6}([[:space:]]|$)" "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null; then
        _nftban_whitelist_safe_append "$NFTBAN_WHITELIST_SYSTEM" "${public_ipv6}  # Server public IPv6 (auto-detected on $(date +'%Y-%m-%d'))"
        nftban_log_success "Protected public IPv6: $public_ipv6"
        ((protected_count++))
    fi
    
    if [[ $protected_count -gt 0 ]]; then
        nftban_log_success "Auto-protected $protected_count server IPs"
        # Sync to nftables after adding
        nftban_whitelist_sync_to_nftables
    else
        nftban_log_info "All server IPs already protected"
    fi
}

# =============================================================================
# AUTO-PROTECTION: CURRENT USER IP
# =============================================================================

nftban_whitelist_protect_current_user() {
    local current_user_ip
    current_user_ip=$(nftban_get_current_user_ip)
    
    if [[ -z "$current_user_ip" ]]; then
        nftban_log_debug "No remote user detected (local console?)"
        return 0
    fi
    
    # Check if already protected
    if grep -qE "^${current_user_ip}([[:space:]]|$)" "$NFTBAN_WHITELIST_USER" 2>/dev/null || \
       grep -qE "^${current_user_ip}([[:space:]]|$)" "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null; then
        nftban_log_debug "Current user IP already protected: $current_user_ip"
        return 0
    fi
    
    # Add to user whitelist (not system - allows manual removal) (SECURITY: atomic write)
    _nftban_whitelist_safe_append "$NFTBAN_WHITELIST_USER" "${current_user_ip}  # Current admin user (auto-protected on $(date +'%Y-%m-%d %H:%M:%S'))"
    nftban_log_success "Protected current user IP: $current_user_ip"
    nftban_log_warning "⚠️  IMPORTANT: Your IP ($current_user_ip) has been whitelisted to prevent lockout"
    
    # Sync to nftables
    nftban_whitelist_sync_to_nftables
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
    
    # Add to user whitelist file (SECURITY: atomic write)
    _nftban_whitelist_safe_append "$NFTBAN_WHITELIST_USER" "${ip}  # ${comment}"

    # Add to nftables set (v0.9.0: split tables, no _v4/_v6 suffix)
    if nftban_check_nftables_table; then
        local table_family table_name
        if [[ "$ver" == "4" ]]; then
            table_family="${NFTBAN_NFT_FAMILY_V4:-ip}"
            table_name="${NFTBAN_NFT_TABLE_V4:-nftban_v4}"
        else
            table_family="${NFTBAN_NFT_FAMILY_V6:-ip6}"
            table_name="${NFTBAN_NFT_TABLE_V6:-nftban_v6}"
        fi

        if nft add element "$table_family" "$table_name" "whitelist" "{ $ip }" 2>/dev/null; then
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
    
    # SAFETY CHECK: Don't allow removal of critical IPs
    if [[ "$ip" == "127.0.0.1" ]] || [[ "$ip" == "::1" ]]; then
        nftban_log_error "BLOCKED: Cannot remove localhost from whitelist!"
        return 1
    fi
    
    # Check if it's a server IP
    if ip -o addr show 2>/dev/null | grep -qF "$ip"; then
        nftban_log_error "BLOCKED: Cannot remove server's own IP from whitelist!"
        return 1
    fi
    
    # Check if it's current user IP
    local current_ip
    current_ip=$(nftban_get_current_user_ip)
    if [[ -n "$current_ip" && "$current_ip" == "$ip" ]]; then
        nftban_log_error "BLOCKED: Cannot remove current user's IP from whitelist!"
        nftban_log_error "This would cause immediate lockout!"
        return 1
    fi
    
    local removed=false
    
    # Remove from user whitelist file only (not system) (SECURITY: atomic modify)
    if [[ -f "$NFTBAN_WHITELIST_USER" ]] && grep -qE "^${ip}([[:space:]]|$)" "$NFTBAN_WHITELIST_USER"; then
        _nftban_whitelist_safe_modify "$NFTBAN_WHITELIST_USER" "/^${ip}[[:space:]]/d"
        nftban_log_success "Removed $ip from user whitelist file"
        removed=true
    fi
    
    # Check if in system whitelist (warn but don't remove)
    if grep -qE "^${ip}([[:space:]]|$)" "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null; then
        nftban_log_warning "IP $ip is in system whitelist (protected)"
        nftban_log_warning "Manual removal from $NFTBAN_WHITELIST_SYSTEM required if needed"
    fi
    
    # Remove from nftables set (v0.9.0: split tables, no _v4/_v6 suffix)
    if nftban_check_nftables_table; then
        local table_family table_name
        if [[ "$ver" == "4" ]]; then
            table_family="${NFTBAN_NFT_FAMILY_V4:-ip}"
            table_name="${NFTBAN_NFT_TABLE_V4:-nftban_v4}"
        else
            table_family="${NFTBAN_NFT_FAMILY_V6:-ip6}"
            table_name="${NFTBAN_NFT_TABLE_V6:-nftban_v6}"
        fi

        if nft delete element "$table_family" "$table_name" "whitelist" "{ $ip }" 2>/dev/null; then
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
        nftban_log_warning "IP $ip not found in user whitelist"
        return 1
    fi
}

# =============================================================================
# ENHANCED WHITELIST CHECK (Files + nftables + Server IPs + Current User)
# =============================================================================

nftban_whitelist_check_ip() {
    local ip="$1"
    
    # Validate IP
    nftban_validate_ip "$ip" || return 2
    
    local ver
    ver=$(nftban_detect_ip_version "$ip")
    
    # METHOD 1: Check nftables sets FIRST (fastest, most accurate) - v0.9.0: split tables
    if nftban_check_nftables_table; then
        local table_family table_name
        if [[ "$ver" == "4" ]]; then
            table_family="${NFTBAN_NFT_FAMILY_V4:-ip}"
            table_name="${NFTBAN_NFT_TABLE_V4:-nftban_v4}"
        else
            table_family="${NFTBAN_NFT_FAMILY_V6:-ip6}"
            table_name="${NFTBAN_NFT_TABLE_V6:-nftban_v6}"
        fi

        if nft list set "$table_family" "$table_name" "whitelist" 2>/dev/null | \
           grep -qE "(${ip}[[:space:],}]|${ip}\$)"; then
            nftban_log_debug "IP $ip found in nftables $table_family $table_name whitelist set"
            return 0
        fi
    fi
    
    # METHOD 2: Check configuration files (for non-synced entries or CIDR ranges)
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
                nftban_log_debug "IP $ip found in $(basename "$file") (exact match)"
                return 0
            fi
            
            # CIDR range match - use proper calculation
            if [[ "$entry" =~ / ]]; then
                if nftban_ip_in_cidr "$ip" "$entry"; then
                    nftban_log_debug "IP $ip matches CIDR $entry in $(basename "$file")"
                    return 0
                fi
            fi
        done < "$file"
    done
    
    # METHOD 3: Check if it's a server IP (dynamic check)
    if ip -o addr show 2>/dev/null | grep -qF "$ip"; then
        nftban_log_debug "IP $ip is a server interface IP"
        return 0
    fi
    
    # METHOD 4: Check if it's the current user's IP
    local current_user_ip
    current_user_ip=$(nftban_get_current_user_ip)
    if [[ -n "$current_user_ip" && "$current_user_ip" == "$ip" ]]; then
        nftban_log_debug "IP $ip is current user's connection IP"
        return 0
    fi
    
    return 1
}

# =============================================================================
# LIST & DISPLAY
# =============================================================================

# List whitelisted IPs
nftban_whitelist_list() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Whitelisted IPs"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    echo -e "${NFTBAN_CYAN}System Whitelist (Auto-Protected):${NFTBAN_NC}"
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
        cf_count=$(grep -cE "^[0-9a-fA-F.:]+([[:space:]]|$)" "$NFTBAN_WHITELIST_CF" 2>/dev/null || true)
        cf_count=${cf_count:-0}
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
    
    # Show nftables sets if available (v0.9.0: split tables)
    if nftban_check_nftables_table; then
        echo -e "${NFTBAN_CYAN}nftables Sets:${NFTBAN_NC}"

        # IPv4 table
        if nft list set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" "whitelist" &>/dev/null; then
            local count_v4
            count_v4=$(nft list set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" "whitelist" 2>/dev/null | \
                    grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | wc -l)
            printf "  %-20s %3d IPs\n" "whitelist (IPv4):" "$count_v4"
        fi

        # IPv6 table
        if nft list set "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" "whitelist" &>/dev/null; then
            local count_v6
            count_v6=$(nft list set "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" "whitelist" 2>/dev/null | \
                    grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F:]\+' | wc -l)
            printf "  %-20s %3d IPs\n" "whitelist (IPv6):" "$count_v6"
        fi
        echo ""
    fi
    
    # Show current protections
    echo -e "${NFTBAN_CYAN}Current Protections:${NFTBAN_NC}"
    local current_ip
    current_ip=$(nftban_get_current_user_ip)
    if [[ -n "$current_ip" ]]; then
        echo "  Current User IP: $current_ip"
    else
        echo "  Current User IP: N/A (local console)"
    fi
    
    local server_ip_count
    server_ip_count=$(ip -o addr show 2>/dev/null | awk '/inet/ {gsub(/\/.*/, "", $4); print $4}' | grep -v '^127\.' | wc -l)
    echo "  Server IPs: $server_ip_count protected"
    echo ""
}

# =============================================================================
# SYNC & MAINTENANCE
# =============================================================================

# Sync whitelist files to nftables
nftban_whitelist_sync_to_nftables() {
    nftban_log_info "Syncing whitelist to nftables..."
    
    if ! nftban_check_nftables_table; then
        nftban_log_error "nftables table not initialized"
        return 1
    fi
    
    # Flush existing whitelist sets (v0.9.0: split tables, no _v4/_v6 suffix)
    nft flush set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" whitelist 2>/dev/null || true
    nft flush set "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" whitelist 2>/dev/null || true

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

            # Detect IP version and add to appropriate table (v0.9.0: split tables)
            local ver
            ver=$(nftban_detect_ip_version "$ip")

            if [[ "$ver" == "4" ]]; then
                if nft add element "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" whitelist "{ $ip }" 2>/dev/null; then
                    ((synced_v4++))
                fi
            elif [[ "$ver" == "6" ]]; then
                if nft add element "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" whitelist "{ $ip }" 2>/dev/null; then
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
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  Whitelist Safety Verification"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    # Check if files exist
    echo -n "Checking system whitelist... "
    if [[ -f "$NFTBAN_WHITELIST_SYSTEM" ]]; then
        echo -e "${NFTBAN_GREEN}✓ EXISTS${NFTBAN_NC}"
    else
        echo -e "${NFTBAN_RED}✗ MISSING${NFTBAN_NC}"
        ((issues++))
    fi
    
    echo -n "Checking user whitelist... "
    if [[ -f "$NFTBAN_WHITELIST_USER" ]]; then
        echo -e "${NFTBAN_GREEN}✓ EXISTS${NFTBAN_NC}"
    else
        echo -e "${NFTBAN_RED}✗ MISSING${NFTBAN_NC}"
        ((issues++))
    fi
    
    # Check if localhost is whitelisted
    echo -n "Checking localhost protection... "
    if nftban_whitelist_check_ip "127.0.0.1" && nftban_whitelist_check_ip "::1"; then
        echo -e "${NFTBAN_GREEN}✓ PROTECTED${NFTBAN_NC}"
    else
        echo -e "${NFTBAN_RED}✗ NOT PROTECTED${NFTBAN_NC}"
        ((issues++))
    fi
    
    # Check server IPs
    echo -n "Checking server IP protection... "
    local unprotected=0
    while IFS= read -r ip; do
        [[ -z "$ip" || "$ip" =~ ^127\. ]] && continue
        if ! nftban_whitelist_check_ip "$ip"; then
            ((unprotected++))
        fi
    done < <(ip -o addr show 2>/dev/null | awk '/inet/ {gsub(/\/.*/, "", $4); print $4}')
    
    if [[ $unprotected -eq 0 ]]; then
        echo -e "${NFTBAN_GREEN}✓ ALL PROTECTED${NFTBAN_NC}"
    else
        echo -e "${NFTBAN_YELLOW}⚠ $unprotected IPs NOT PROTECTED${NFTBAN_NC}"
        ((issues++))
    fi
    
    # Check current user IP
    echo -n "Checking current user IP... "
    local current_ip
    current_ip=$(nftban_get_current_user_ip)
    
    if [[ -n "$current_ip" ]]; then
        if nftban_whitelist_check_ip "$current_ip"; then
            echo -e "${NFTBAN_GREEN}✓ PROTECTED ($current_ip)${NFTBAN_NC}"
        else
            echo -e "${NFTBAN_RED}✗ NOT PROTECTED ($current_ip)${NFTBAN_NC}"
            echo -e "  ${NFTBAN_RED}⚠️  WARNING: Risk of self-lockout!${NFTBAN_NC}"
            ((issues++))
        fi
    else
        echo -e "${NFTBAN_YELLOW}N/A (local console)${NFTBAN_NC}"
    fi
    
    # Check nftables sync (v0.9.0: split tables)
    echo -n "Checking nftables sync... "
    if nftban_check_nftables_table; then
        local file_v4 nft_v4
        file_v4=$(grep -hcE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" \
                  "$NFTBAN_WHITELIST_SYSTEM" "$NFTBAN_WHITELIST_USER" 2>/dev/null || echo "0")
        nft_v4=$(nft list set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" whitelist 2>/dev/null | \
                 grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | wc -l)

        if [[ $file_v4 -eq $nft_v4 ]]; then
            echo -e "${NFTBAN_GREEN}✓ SYNCED${NFTBAN_NC}"
        else
            echo -e "${NFTBAN_YELLOW}⚠ OUT OF SYNC (files: $file_v4, nft: $nft_v4)${NFTBAN_NC}"
        fi
    else
        echo -e "${NFTBAN_RED}✗ TABLE MISSING${NFTBAN_NC}"
        ((issues++))
    fi
    
    echo ""
    if [[ $issues -eq 0 ]]; then
        echo -e "${NFTBAN_GREEN}✓ ALL CHECKS PASSED${NFTBAN_NC}"
        return 0
    else
        echo -e "${NFTBAN_RED}$issues issue(s) found - run: nftban whitelist init${NFTBAN_NC}"
        return 1
    fi
}

# Get whitelist statistics
nftban_whitelist_get_stats() {
    local system_count user_count cf_count

    system_count=$(grep -cE "^[0-9a-fA-F.:]+([[:space:]]|$)" "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null || true)
    user_count=$(grep -cE "^[0-9a-fA-F.:]+([[:space:]]|$)" "$NFTBAN_WHITELIST_USER" 2>/dev/null || true)
    cf_count=$(grep -cE "^[0-9a-fA-F.:]+([[:space:]]|$)" "$NFTBAN_WHITELIST_CF" 2>/dev/null || true)

    system_count=${system_count:-0}
    user_count=${user_count:-0}
    cf_count=${cf_count:-0}

    echo "System: $system_count | User: $user_count | Cloudflare: $cf_count | Total: $((system_count + user_count + cf_count))"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_whitelist_init
export -f nftban_whitelist_add_server_ips
export -f nftban_whitelist_protect_current_user
export -f nftban_whitelist_add_ip
export -f nftban_whitelist_remove_ip
export -f nftban_whitelist_check_ip
export -f nftban_whitelist_list
export -f nftban_whitelist_sync_to_nftables
export -f nftban_whitelist_verify
export -f nftban_whitelist_get_stats

nftban_log_debug "NFTBan Whitelist Module loaded (v2.0.0 - Enhanced Protection + Split Tables)"
