#!/usr/bin/env bash

# =============================================================================
# NFTBan Safety Module - NEW
# Version: 1.0.0
# Comprehensive safety verification and initialization safeguards
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_SAFETY_LOADED:-}" ]] && return 0
readonly NFTBAN_SAFETY_LOADED=1

# =============================================================================
# INITIALIZATION SAFEGUARDS
# =============================================================================

nftban_init_safeguards() {
    nftban_log_info "Applying initialization safeguards..."
    
    local protected=0
    
    # 1. Ensure critical localhost entries
    nftban_log_info "Step 1/5: Protecting localhost..."
    local localhost_ips=("127.0.0.1" "::1")
    
    for ip in "${localhost_ips[@]}"; do
        if ! grep -qE "^${ip}([[:space:]]|$)" "${NFTBAN_CONFIG_DIR}/whitelist-system.conf" 2>/dev/null; then
            echo "${ip}  # Localhost (critical protection)" >> "${NFTBAN_CONFIG_DIR}/whitelist-system.conf"
            nftban_log_success "Protected localhost: $ip"
            ((protected++))
        fi
    done
    
    # 2. Protect all server interface IPs
    nftban_log_info "Step 2/5: Protecting server interface IPs..."
    local server_ips
    server_ips=$(ip -o addr show 2>/dev/null | awk '/inet/ {gsub(/\/.*/, "", $4); print $4}' | sort -u)
    
    while IFS= read -r ip; do
        [[ -z "$ip" || "$ip" =~ ^127\. ]] && continue
        
        if ! grep -qE "^${ip}([[:space:]]|$)" "${NFTBAN_CONFIG_DIR}/whitelist-system.conf" 2>/dev/null; then
            echo "${ip}  # Server IP (auto-detected)" >> "${NFTBAN_CONFIG_DIR}/whitelist-system.conf"
            nftban_log_success "Protected server IP: $ip"
            ((protected++))
        fi
    done <<< "$server_ips"
    
    # 3. Protect public server IPs
    nftban_log_info "Step 3/5: Detecting and protecting public IPs..."
    local public_ipv4 public_ipv6
    
    public_ipv4=$(nftban_get_public_ip "ipv4")
    if [[ -n "$public_ipv4" ]]; then
        if ! grep -qE "^${public_ipv4}([[:space:]]|$)" "${NFTBAN_CONFIG_DIR}/whitelist-system.conf" 2>/dev/null; then
            echo "${public_ipv4}  # Server public IPv4 (auto-detected)" >> "${NFTBAN_CONFIG_DIR}/whitelist-system.conf"
            nftban_log_success "Protected public IPv4: $public_ipv4"
            ((protected++))
        fi
    fi
    
    public_ipv6=$(nftban_get_public_ip "ipv6")
    if [[ -n "$public_ipv6" ]]; then
        if ! grep -qE "^${public_ipv6}([[:space:]]|$)" "${NFTBAN_CONFIG_DIR}/whitelist-system.conf" 2>/dev/null; then
            echo "${public_ipv6}  # Server public IPv6 (auto-detected)" >> "${NFTBAN_CONFIG_DIR}/whitelist-system.conf"
            nftban_log_success "Protected public IPv6: $public_ipv6"
            ((protected++))
        fi
    fi
    
    # 4. Protect current user's IP
    nftban_log_info "Step 4/5: Protecting current admin user IP..."
    local current_user_ip
    current_user_ip=$(nftban_get_current_user_ip)
    
    if [[ -n "$current_user_ip" ]]; then
        if ! grep -qE "^${current_user_ip}([[:space:]]|$)" "${NFTBAN_CONFIG_DIR}/whitelist-user.conf" 2>/dev/null; then
            echo "${current_user_ip}  # Current admin user (auto-protected on $(date +'%Y-%m-%d'))" >> \
                "${NFTBAN_CONFIG_DIR}/whitelist-user.conf"
            nftban_log_success "Protected current user IP: $current_user_ip"
            nftban_log_warning "⚠️  IMPORTANT: Your IP ($current_user_ip) has been whitelisted to prevent lockout"
            ((protected++))
        fi
    else
        nftban_log_warning "Could not detect current user's IP - please add manually if remote"
    fi
    
    # 5. Sync everything to nftables
    nftban_log_info "Step 5/5: Syncing protections to nftables..."
    if declare -f nftban_whitelist_sync_to_nftables &>/dev/null; then
        nftban_whitelist_sync_to_nftables
    fi
    
    # 6. Verify critical protections
    nftban_log_info "Verifying critical protections..."
    local verification_failed=0
    
    if ! nftban_whitelist_check_ip "127.0.0.1"; then
        nftban_log_error "CRITICAL: Localhost not properly whitelisted!"
        ((verification_failed++))
    fi
    
    if [[ -n "$current_user_ip" ]] && ! nftban_whitelist_check_ip "$current_user_ip"; then
        nftban_log_error "CRITICAL: Current user IP not properly whitelisted!"
        ((verification_failed++))
    fi
    
    if [[ $verification_failed -gt 0 ]]; then
        nftban_log_error "Safeguard verification failed! Manual intervention required."
        return 1
    fi
    
    nftban_log_success "All safeguards applied successfully ($protected new protections)"
    return 0
}

# =============================================================================
# COMPREHENSIVE SAFETY CHECKS
# =============================================================================

nftban_check_safeguards() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  NFTBAN SAFETY VERIFICATION"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    local issues=0
    local warnings=0
    
    # Check 1: Localhost Protection
    echo -e "${NFTBAN_CYAN}[1/8] Localhost Protection${NFTBAN_NC}"
    echo -n "  Checking 127.0.0.1... "
    if nftban_whitelist_check_ip "127.0.0.1"; then
        echo -e "${NFTBAN_GREEN}✓ PROTECTED${NFTBAN_NC}"
    else
        echo -e "${NFTBAN_RED}✗ NOT PROTECTED${NFTBAN_NC}"
        ((issues++))
    fi
    
    echo -n "  Checking ::1... "
    if nftban_whitelist_check_ip "::1"; then
        echo -e "${NFTBAN_GREEN}✓ PROTECTED${NFTBAN_NC}"
    else
        echo -e "${NFTBAN_RED}✗ NOT PROTECTED${NFTBAN_NC}"
        ((issues++))
    fi
    echo ""
    
    # Check 2: Server IP Protection
    echo -e "${NFTBAN_CYAN}[2/8] Server IP Protection${NFTBAN_NC}"
    local unprotected_ips=0
    local total_ips=0
    
    while IFS= read -r ip; do
        [[ -z "$ip" || "$ip" =~ ^127\. ]] && continue
        ((total_ips++))
        if ! nftban_whitelist_check_ip "$ip"; then
            echo -e "  ${NFTBAN_RED}✗ NOT PROTECTED: $ip${NFTBAN_NC}"
            ((unprotected_ips++))
        fi
    done < <(ip -o addr show 2>/dev/null | awk '/inet/ {gsub(/\/.*/, "", $4); print $4}')
    
    if [[ $unprotected_ips -eq 0 ]]; then
        echo -e "  ${NFTBAN_GREEN}✓ ALL $total_ips SERVER IPS PROTECTED${NFTBAN_NC}"
    else
        echo -e "  ${NFTBAN_YELLOW}⚠ $unprotected_ips OF $total_ips IPS NOT PROTECTED${NFTBAN_NC}"
        ((warnings++))
    fi
    echo ""
    
    # Check 3: Current User IP Protection
    echo -e "${NFTBAN_CYAN}[3/8] Current User IP Protection${NFTBAN_NC}"
    local current_ip
    current_ip=$(nftban_get_current_user_ip)
    
    if [[ -n "$current_ip" ]]; then
        echo -n "  Current IP: $current_ip... "
        if nftban_whitelist_check_ip "$current_ip"; then
            echo -e "${NFTBAN_GREEN}✓ PROTECTED${NFTBAN_NC}"
        else
            echo -e "${NFTBAN_RED}✗ NOT PROTECTED${NFTBAN_NC}"
            echo -e "  ${NFTBAN_RED}⚠️  CRITICAL: Risk of self-lockout!${NFTBAN_NC}"
            ((issues++))
        fi
    else
        echo -e "  ${NFTBAN_YELLOW}N/A (Local console or undetectable)${NFTBAN_NC}"
    fi
    echo ""
    
    # Check 4: nftables Table Status
    echo -e "${NFTBAN_CYAN}[4/8] nftables Status${NFTBAN_NC}"
    echo -n "  Checking table... "
    if nftban_check_nftables_table; then
        echo -e "${NFTBAN_GREEN}✓ TABLE EXISTS${NFTBAN_NC}"
    else
        echo -e "${NFTBAN_RED}✗ TABLE MISSING${NFTBAN_NC}"
        ((issues++))
    fi
    echo ""
    
    # Check 5: Required Sets
    echo -e "${NFTBAN_CYAN}[5/8] Required nftables Sets${NFTBAN_NC}"
    if nftban_check_nftables_table; then
        local required_sets=(
            "whitelist_v4" "whitelist_v6"
            "temp_ban_v4" "temp_ban_v6"
            "user_blacklist_v4" "user_blacklist_v6"
            "system_blacklist_v4" "system_blacklist_v6"
            "feeds_v4" "feeds_v6"
        )
        
        local missing_sets=0
        for set_name in "${required_sets[@]}"; do
            if ! nft list set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" "$set_name" &>/dev/null; then
                echo -e "  ${NFTBAN_RED}✗ MISSING: $set_name${NFTBAN_NC}"
                ((missing_sets++))
            fi
        done
        
        if [[ $missing_sets -eq 0 ]]; then
            echo -e "  ${NFTBAN_GREEN}✓ ALL ${#required_sets[@]} SETS EXIST${NFTBAN_NC}"
        else
            echo -e "  ${NFTBAN_RED}✗ $missing_sets SETS MISSING${NFTBAN_NC}"
            ((issues++))
        fi
    else
        echo -e "  ${NFTBAN_YELLOW}⚠ SKIPPED (table missing)${NFTBAN_NC}"
    fi
    echo ""
    
    # Check 6: Whitelist Sync
    echo -e "${NFTBAN_CYAN}[6/8] Whitelist Synchronization${NFTBAN_NC}"
    if nftban_check_nftables_table; then
        local file_v4 nft_v4
        file_v4=$(grep -hE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" \
                  "${NFTBAN_CONFIG_DIR}/whitelist-system.conf" \
                  "${NFTBAN_CONFIG_DIR}/whitelist-user.conf" 2>/dev/null | wc -l)
        nft_v4=$(nft list set "$NFTBAN_NFT_FAMILY" "$NFTBAN_NFT_TABLE" whitelist_v4 2>/dev/null | \
                 grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+' | wc -l)
        
        if [[ $file_v4 -le $nft_v4 ]]; then
            echo -e "  ${NFTBAN_GREEN}✓ SYNCED (files: $file_v4, nft: $nft_v4)${NFTBAN_NC}"
        else
            echo -e "  ${NFTBAN_YELLOW}⚠ OUT OF SYNC (files: $file_v4, nft: $nft_v4)${NFTBAN_NC}"
            echo "  Run: nftban whitelist sync"
            ((warnings++))
        fi
    else
        echo -e "  ${NFTBAN_YELLOW}⚠ SKIPPED (table missing)${NFTBAN_NC}"
    fi
    echo ""
    
    # Check 7: Configuration Files
    echo -e "${NFTBAN_CYAN}[7/8] Configuration Files${NFTBAN_NC}"
    local required_files=(
        "${NFTBAN_CONFIG_DIR}/whitelist-system.conf:System Whitelist"
        "${NFTBAN_CONFIG_DIR}/whitelist-user.conf:User Whitelist"
        "${NFTBAN_CONFIG_DIR}/blacklist-persistent.conf:Persistent Blacklist"
        "${NFTBAN_CONFIG_DIR}/blacklist-user.conf:User Blacklist"
    )
    
    local missing_files=0
    for entry in "${required_files[@]}"; do
        local file="${entry%%:*}"
        local name="${entry##*:}"
        if [[ -f "$file" ]]; then
            echo -e "  ${NFTBAN_GREEN}✓${NFTBAN_NC} $name"
        else
            echo -e "  ${NFTBAN_RED}✗${NFTBAN_NC} $name"
            ((missing_files++))
        fi
    done
    
    if [[ $missing_files -gt 0 ]]; then
        ((issues++))
    fi
    echo ""
    
    # Check 8: Conflicting Entries
    echo -e "${NFTBAN_CYAN}[8/8] Conflict Detection${NFTBAN_NC}"
    local conflicts=0
    
    # Check if any whitelisted IP is also blacklisted
    if [[ -f "${NFTBAN_CONFIG_DIR}/whitelist-user.conf" ]]; then
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "$line" ]] && continue
            
            local ip=$(echo "$line" | awk '{print $1}')
            [[ -z "$ip" ]] && continue
            
            # Check if in blacklist files
            if grep -qE "^${ip}([[:space:]]|$)" "${NFTBAN_CONFIG_DIR}/blacklist-user.conf" 2>/dev/null || \
               grep -qE "^${ip}([[:space:]]|$)" "${NFTBAN_CONFIG_DIR}/blacklist-persistent.conf" 2>/dev/null; then
                echo -e "  ${NFTBAN_YELLOW}⚠ CONFLICT: $ip (both whitelisted and blacklisted)${NFTBAN_NC}"
                ((conflicts++))
            fi
        done < "${NFTBAN_CONFIG_DIR}/whitelist-user.conf"
    fi
    
    if [[ $conflicts -eq 0 ]]; then
        echo -e "  ${NFTBAN_GREEN}✓ NO CONFLICTS DETECTED${NFTBAN_NC}"
    else
        echo -e "  ${NFTBAN_YELLOW}⚠ $conflicts CONFLICTS FOUND${NFTBAN_NC}"
        ((warnings++))
    fi
    echo ""
    
    # Summary
    echo "═══════════════════════════════════════════════════════"
    echo "  SUMMARY"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    if [[ $issues -eq 0 && $warnings -eq 0 ]]; then
        echo -e "${NFTBAN_GREEN}✓ ALL CHECKS PASSED${NFTBAN_NC}"
        echo ""
        echo "Your nftban installation is secure and properly configured."
        return 0
    elif [[ $issues -gt 0 ]]; then
        echo -e "${NFTBAN_RED}✗ CRITICAL: $issues issue(s) found${NFTBAN_NC}"
        [[ $warnings -gt 0 ]] && echo -e "${NFTBAN_YELLOW}⚠ $warnings warning(s) found${NFTBAN_NC}"
        echo ""
        echo "RECOMMENDED ACTIONS:"
        echo "  1. Run: nftban init --safeguards"
        echo "  2. Run: nftban whitelist sync"
        echo "  3. Re-run: nftban check-safety"
        return 1
    else
        echo -e "${NFTBAN_YELLOW}⚠ $warnings warning(s) found${NFTBAN_NC}"
        echo ""
        echo "Your system is functional but has minor issues."
        echo "Run: nftban whitelist sync  to resolve sync warnings"
        return 0
    fi
}

# =============================================================================
# QUICK SAFETY CHECK (for cron/automated checks)
# =============================================================================

nftban_quick_safety_check() {
    local critical_failed=0
    
    # Silent checks - only report failures
    
    # Check localhost
    if ! nftban_whitelist_check_ip "127.0.0.1" || ! nftban_whitelist_check_ip "::1"; then
        echo "CRITICAL: Localhost not protected"
        ((critical_failed++))
    fi
    
    # Check server IPs
    while IFS= read -r ip; do
        [[ -z "$ip" || "$ip" =~ ^127\. ]] && continue
        if ! nftban_whitelist_check_ip "$ip"; then
            echo "WARNING: Server IP not protected: $ip"
        fi
    done < <(ip -o addr show 2>/dev/null | awk '/inet/ {gsub(/\/.*/, "", $4); print $4}')
    
    # Check current user
    local current_ip
    current_ip=$(nftban_get_current_user_ip)
    if [[ -n "$current_ip" ]] && ! nftban_whitelist_check_ip "$current_ip"; then
        echo "CRITICAL: Current user IP not protected: $current_ip"
        ((critical_failed++))
    fi
    
    # Check nftables table
    if ! nftban_check_nftables_table; then
        echo "CRITICAL: nftables table missing"
        ((critical_failed++))
    fi
    
    return $critical_failed
}

# =============================================================================
# IP LOCATION REPORT (Enhanced)
# =============================================================================

nftban_check_ip_location() {
    local ip="$1"
    
    if [[ -z "$ip" ]]; then
        nftban_log_error "Usage: nftban check-ip <IP_ADDRESS>"
        return 1
    fi
    
    # Validate IP
    nftban_validate_ip "$ip" || return 1
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  IP LOCATION CHECK: $ip"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    # Check what locations IP exists in
    local locations
    locations=$(nftban_find_ip_locations "$ip")
    
    if [[ -n "$locations" ]]; then
        echo -e "${NFTBAN_CYAN}Found in:${NFTBAN_NC}"
        echo "$locations" | while read -r location; do
            echo "  • $location"
        done
        echo ""
    else
        echo -e "${NFTBAN_GREEN}✓ Not found in any list${NFTBAN_NC}"
        echo ""
    fi
    
    # Check protection status
    echo -e "${NFTBAN_CYAN}Protection Status:${NFTBAN_NC}"
    
    echo -n "  Whitelisted: "
    if nftban_whitelist_check_ip "$ip"; then
        echo -e "${NFTBAN_GREEN}YES ✓${NFTBAN_NC}"
    else
        echo -e "${NFTBAN_YELLOW}NO${NFTBAN_NC}"
    fi
    
    echo -n "  Can be banned: "
    if nftban_whitelist_check_ip "$ip"; then
        echo -e "${NFTBAN_RED}NO (whitelisted)${NFTBAN_NC}"
    else
        echo -e "${NFTBAN_GREEN}YES${NFTBAN_NC}"
    fi
    
    # Check special statuses
    echo ""
    echo -e "${NFTBAN_CYAN}Special Status:${NFTBAN_NC}"
    
    local current_ip
    current_ip=$(nftban_get_current_user_ip)
    
    if [[ "$ip" == "127.0.0.1" ]] || [[ "$ip" == "::1" ]]; then
        echo "  • Localhost (critical protection)"
    fi
    
    if ip -o addr show 2>/dev/null | grep -qF "$ip"; then
        echo "  • Server interface IP (auto-protected)"
    fi
    
    if [[ -n "$current_ip" && "$current_ip" == "$ip" ]]; then
        echo "  • Current user's connection IP (lockout protection)"
    fi
    
    echo ""
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_init_safeguards
export -f nftban_check_safeguards
export -f nftban_quick_safety_check
export -f nftban_check_ip_location

nftban_log_debug "NFTBan Safety Module loaded (v1.0.0)"
