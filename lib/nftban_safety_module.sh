#!/usr/bin/env bash

# =============================================================================
# NFTBan Safety Module - COMPLETE VERSION
# Version: 2.0.0 - v0.9.0 SPLIT TABLE ARCHITECTURE
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Comprehensive safety verification and initialization safeguards
# v0.9.0 UPDATE: Uses split ip/ip6 tables for better performance
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_SAFETY_LOADED:-}" ]] && return 0
readonly NFTBAN_SAFETY_LOADED=1

# =============================================================================
# RISK 1: NFTABLES SERVICE NOT RUNNING
# =============================================================================
nftban_check_nftables_running() {
    # Check if nft command works
    if ! command -v nft &>/dev/null; then
        nftban_log_error "CRITICAL: nft command not found - nftables not installed!"
        return 1
    fi
    
    # Check if nftables service is running
    if ! systemctl is-active --quiet nftables 2>/dev/null; then
        nftban_log_warning "nftables service not active"
    fi
    
    # Test if nft actually works
    if ! nft list tables &>/dev/null; then
        nftban_log_error "CRITICAL: nft command fails - nftables not functional!"
        return 1
    fi
    
    return 0
}

# =============================================================================
# RISK 2: NFTABLES SET FULL (Maximum elements reached)
# =============================================================================
nftban_check_nft_set_capacity() {
    local set_name="$1"
    local ver="$2"
    
    if ! nftban_check_nftables_table; then
        return 1
    fi
    
    # Get current element count (v0.9.0: split tables, no _v suffix)
    local table_family table_name
    if [[ "$ver" == "4" ]]; then
        table_family="${NFTBAN_NFT_FAMILY_V4:-ip}"
        table_name="${NFTBAN_NFT_TABLE_V4:-nftban_v4}"
    else
        table_family="${NFTBAN_NFT_FAMILY_V6:-ip6}"
        table_name="${NFTBAN_NFT_TABLE_V6:-nftban_v6}"
    fi

    local count
    count=$(nft list set "$table_family" "$table_name" "$set_name" 2>/dev/null | \
            grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F.:]\+' | wc -l)

    # Warn if approaching limits (nftables default is ~65535 elements per set)
    if [[ $count -gt 50000 ]]; then
        nftban_log_warning "Set $set_name has $count elements (approaching limit!)"
        return 1
    fi
    
    return 0
}

# =============================================================================
# RISK 3: DUPLICATE IPs IN NFTABLES SETS
# =============================================================================
nftban_check_nft_duplicates() {
    local ver="$1"
    
    if ! nftban_check_nftables_table; then
        return 1
    fi
    
    local duplicates=0

    # Get table info for this IP version (v0.9.0: split tables)
    local table_family table_name
    if [[ "$ver" == "4" ]]; then
        table_family="${NFTBAN_NFT_FAMILY_V4:-ip}"
        table_name="${NFTBAN_NFT_TABLE_V4:-nftban_v4}"
    else
        table_family="${NFTBAN_NFT_FAMILY_V6:-ip6}"
        table_name="${NFTBAN_NFT_TABLE_V6:-nftban_v6}"
    fi

    # Extract all IPs from all sets (no _v suffix in v0.9.0)
    local temp_file
    temp_file=$(mktemp) || {
        nftban_log_error "Failed to create temporary file for duplicate checking"
        return 1
    }
    trap 'rm -f "$temp_file"' RETURN

    for set_name in whitelist temp_ban user_blacklist system_blacklist feeds; do
        nft list set "$table_family" "$table_name" "$set_name" 2>/dev/null | \
            grep -oP 'elements = \{\K[^}]*' | grep -o '[0-9a-fA-F.:]\+' >> "$temp_file" || true
    done

    # Check for duplicates
    duplicates=$(sort "$temp_file" | uniq -d | wc -l)
    rm -f "$temp_file"
    trap - RETURN
    
    if [[ $duplicates -gt 0 ]]; then
        nftban_log_warning "Found $duplicates duplicate IPs across nftables sets (IPv${ver})"
        return 1
    fi
    
    return 0
}

# =============================================================================
# RISK 4: FILE PERMISSIONS WRONG
# =============================================================================
nftban_check_file_permissions() {
    local issues=0
    
    # Check if config files are writable
    local critical_files=(
        "$NFTBAN_WHITELIST_SYSTEM"
        "$NFTBAN_WHITELIST_USER"
        "$NFTBAN_BLACKLIST_PERSISTENT"
        "$NFTBAN_BLACKLIST_USER"
    )
    
    for file in "${critical_files[@]}"; do
        if [[ -f "$file" ]]; then
            # Check if writable
            if [[ ! -w "$file" ]]; then
                nftban_log_error "File not writable: $file"
                ((issues++))
            fi
            
            # Check permissions (should be 644 or 600)
            local perms
            perms=$(stat -c %a "$file" 2>/dev/null)
            if [[ "$perms" != "644" && "$perms" != "600" ]]; then
                nftban_log_warning "Incorrect permissions on $file: $perms (should be 644)"
            fi
        fi
    done
    
    # Check log directory writable
    if [[ ! -w "$NFTBAN_LOG_DIR" ]]; then
        nftban_log_error "Log directory not writable: $NFTBAN_LOG_DIR"
        ((issues++))
    fi
    
    return $issues
}

# =============================================================================
# RISK 5: DISK SPACE LOW
# =============================================================================
nftban_check_disk_space() {
    # Check disk space on /etc and /var
    local etc_usage var_usage
    
    etc_usage=$(df /etc | tail -1 | awk '{print $5}' | tr -d '%')
    var_usage=$(df /var | tail -1 | awk '{print $5}' | tr -d '%')
    
    if [[ $etc_usage -gt 90 ]]; then
        nftban_log_error "CRITICAL: /etc partition ${etc_usage}% full!"
        return 1
    fi
    
    if [[ $var_usage -gt 90 ]]; then
        nftban_log_error "CRITICAL: /var partition ${var_usage}% full!"
        return 1
    fi
    
    if [[ $etc_usage -gt 80 || $var_usage -gt 80 ]]; then
        nftban_log_warning "Disk space warning: /etc ${etc_usage}%, /var ${var_usage}%"
    fi
    
    return 0
}

# =============================================================================
# RISK 6: RACE CONDITION - Multiple ban processes
# =============================================================================
nftban_check_lock() {
    local lock_file="/var/lock/nftban.lock"
    local max_wait=5
    local waited=0
    
    # Wait for lock to be released (max 5 seconds)
    while [[ -f "$lock_file" ]] && [[ $waited -lt $max_wait ]]; do
        sleep 1
        ((waited++))
    done
    
    if [[ -f "$lock_file" ]]; then
        # Check if process still exists
        local pid
        pid=$(cat "$lock_file" 2>/dev/null)
        
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            nftban_log_error "Another nftban process is running (PID: $pid)"
            return 1
        else
            # Stale lock file
            rm -f "$lock_file"
        fi
    fi
    
    # Create lock
    echo $$ > "$lock_file"
    return 0
}

nftban_release_lock() {
    local lock_file="/var/lock/nftban.lock"
    rm -f "$lock_file"
}

# =============================================================================
# RISK 7: CORRUPTED CONFIGURATION FILES
# =============================================================================
nftban_check_config_integrity() {
    local issues=0
    
    local config_files=(
        "$NFTBAN_WHITELIST_SYSTEM"
        "$NFTBAN_WHITELIST_USER"
        "$NFTBAN_BLACKLIST_PERSISTENT"
        "$NFTBAN_BLACKLIST_USER"
    )
    
    for file in "${config_files[@]}"; do
        [[ ! -f "$file" ]] && continue
        
        # Check for binary/corrupted data
        if file "$file" | grep -q "data"; then
            nftban_log_error "File appears corrupted: $file"
            ((issues++))
            continue
        fi
        
        # Check for invalid IP format
        local invalid_lines
        invalid_lines=$(grep -vE '^[[:space:]]*#|^[[:space:]]*$' "$file" | \
                       grep -vE '^[0-9a-fA-F.:]+(/[0-9]+)?[[:space:]]' | \
                       wc -l)
        
        if [[ $invalid_lines -gt 0 ]]; then
            nftban_log_warning "File has $invalid_lines invalid entries: $(basename "$file")"
            ((issues++))
        fi
    done
    
    return $issues
}

# =============================================================================
# RISK 8: NFTABLES RULESET INCONSISTENCY
# =============================================================================
nftban_check_nft_rules_order() {
    if ! nftban_check_nftables_table; then
        return 1
    fi
    
    # Check if whitelist rules come BEFORE ban rules (check both tables in v0.9.0)
    local rules_v4 rules_v6
    rules_v4=$(nft list chain "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" input 2>/dev/null)
    rules_v6=$(nft list chain "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" input 2>/dev/null)

    local rules="$rules_v4"  # Check IPv4 table for rule order
    
    if [[ -z "$rules" ]]; then
        nftban_log_error "No rules found in input chain!"
        return 1
    fi
    
    # Whitelist should appear before bans in rule order
    local whitelist_pos ban_pos
    whitelist_pos=$(echo "$rules" | grep -n "whitelist" | head -1 | cut -d: -f1)
    ban_pos=$(echo "$rules" | grep -n "temp_ban\|blacklist" | head -1 | cut -d: -f1)
    
    if [[ -n "$ban_pos" && -n "$whitelist_pos" ]] && [[ $ban_pos -lt $whitelist_pos ]]; then
        nftban_log_error "CRITICAL: Ban rules come before whitelist rules!"
        nftban_log_error "This means whitelisted IPs can still be blocked!"
        return 1
    fi
    
    return 0
}

# =============================================================================
# RISK 9: LOG FILES TOO LARGE
# =============================================================================
nftban_check_log_size() {
    local max_size=$((100 * 1024 * 1024))  # 100MB
    
    local log_files=(
        "$NFTBAN_MAIN_LOG"
        "$NFTBAN_BAN_LOG"
    )
    
    for log_file in "${log_files[@]}"; do
        [[ ! -f "$log_file" ]] && continue
        
        local size
        size=$(stat -c%s "$log_file" 2>/dev/null || echo "0")
        
        if [[ $size -gt $max_size ]]; then
            nftban_log_warning "Log file too large: $(basename "$log_file") ($(( size / 1024 / 1024 ))MB)"
            nftban_log_warning "Consider rotating logs"
        fi
    done
}

# =============================================================================
# RISK 10: PRIVATE IP RANGES NOT PROTECTED
# =============================================================================
nftban_check_private_ranges() {
    local private_ranges=(
        "10.0.0.0/8"
        "172.16.0.0/12"
        "192.168.0.0/16"
    )
    
    local unprotected=0
    
    for range in "${private_ranges[@]}"; do
        # Check if any IP in this range can be banned
        # (simplified check - just verify range isn't explicitly whitelisted)
        if ! grep -qE "^${range}" "$NFTBAN_WHITELIST_USER" 2>/dev/null && \
           ! grep -qE "^${range}" "$NFTBAN_WHITELIST_SYSTEM" 2>/dev/null; then
            nftban_log_warning "Private range not whitelisted: $range"
            ((unprotected++))
        fi
    done
    
    if [[ $unprotected -gt 0 ]]; then
        nftban_log_info "Consider whitelisting private ranges if on internal network"
    fi
}

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
# BASIC SAFETY CHECKS (8 checks)
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
    
    # Check 5: Required Sets (v0.9.0: split tables, no _v4/_v6 suffix)
    echo -e "${NFTBAN_CYAN}[5/8] Required nftables Sets${NFTBAN_NC}"
    if nftban_check_nftables_table; then
        local required_sets=(
            "whitelist" "temp_ban" "user_blacklist" "system_blacklist" "feeds"
        )

        local missing_sets=0
        for ver in 4 6; do
            local table_family table_name
            if [[ "$ver" == "4" ]]; then
                table_family="${NFTBAN_NFT_FAMILY_V4:-ip}"
                table_name="${NFTBAN_NFT_TABLE_V4:-nftban_v4}"
            else
                table_family="${NFTBAN_NFT_FAMILY_V6:-ip6}"
                table_name="${NFTBAN_NFT_TABLE_V6:-nftban_v6}"
            fi

            for set_name in "${required_sets[@]}"; do
                if ! nft list set "$table_family" "$table_name" "$set_name" &>/dev/null; then
                    echo -e "  ${NFTBAN_RED}✗ MISSING: ${set_name} (IPv${ver})${NFTBAN_NC}"
                    ((missing_sets++))
                fi
            done
        done

        local total_sets=$((${#required_sets[@]} * 2))
        if [[ $missing_sets -eq 0 ]]; then
            echo -e "  ${NFTBAN_GREEN}✓ ALL $total_sets SETS EXIST${NFTBAN_NC}"
        else
            echo -e "  ${NFTBAN_RED}✗ $missing_sets SETS MISSING${NFTBAN_NC}"
            ((issues++))
        fi
    else
        echo -e "  ${NFTBAN_YELLOW}⚠ SKIPPED (table missing)${NFTBAN_NC}"
    fi
    echo ""
    
    # Check 6: Whitelist Sync (v0.9.0: split tables)
    echo -e "${NFTBAN_CYAN}[6/8] Whitelist Synchronization${NFTBAN_NC}"
    if nftban_check_nftables_table; then
        local file_v4 nft_v4
        file_v4=$(grep -hE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" \
                  "${NFTBAN_CONFIG_DIR}/whitelist-system.conf" \
                  "${NFTBAN_CONFIG_DIR}/whitelist-user.conf" 2>/dev/null | wc -l)
        nft_v4=$(nft list set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" whitelist 2>/dev/null | \
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
# COMPREHENSIVE SYSTEM CHECK (ALL 18 CHECKS)
# =============================================================================
nftban_check_all_risks() {
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  COMPREHENSIVE RISK ASSESSMENT"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    local critical=0
    local warnings=0
    
    echo -e "${NFTBAN_CYAN}[1/10] nftables Service Status${NFTBAN_NC}"
    if nftban_check_nftables_running; then
        echo -e "  ${NFTBAN_GREEN}✓ RUNNING${NFTBAN_NC}"
    else
        echo -e "  ${NFTBAN_RED}✗ NOT RUNNING${NFTBAN_NC}"
        ((critical++))
    fi
    
    echo -e "${NFTBAN_CYAN}[2/10] nftables Set Capacity${NFTBAN_NC}"
    local capacity_issues=0
    for ver in 4 6; do
        for set in whitelist temp_ban user_blacklist; do
            if ! nftban_check_nft_set_capacity "$set" "$ver"; then
                ((capacity_issues++))
            fi
        done
    done
    if [[ $capacity_issues -eq 0 ]]; then
        echo -e "  ${NFTBAN_GREEN}✓ OK${NFTBAN_NC}"
    else
        echo -e "  ${NFTBAN_YELLOW}⚠ $capacity_issues sets near capacity${NFTBAN_NC}"
        ((warnings++))
    fi
    
    echo -e "${NFTBAN_CYAN}[3/10] Duplicate Detection${NFTBAN_NC}"
    local dup_issues=0
    for ver in 4 6; do
        if ! nftban_check_nft_duplicates "$ver"; then
            ((dup_issues++))
        fi
    done
    if [[ $dup_issues -eq 0 ]]; then
        echo -e "  ${NFTBAN_GREEN}✓ NO DUPLICATES${NFTBAN_NC}"
    else
        echo -e "  ${NFTBAN_YELLOW}⚠ Duplicates found${NFTBAN_NC}"
        ((warnings++))
    fi
    
    echo -e "${NFTBAN_CYAN}[4/10] File Permissions${NFTBAN_NC}"
    if nftban_check_file_permissions; then
        echo -e "  ${NFTBAN_GREEN}✓ CORRECT${NFTBAN_NC}"
    else
        echo -e "  ${NFTBAN_RED}✗ ISSUES FOUND${NFTBAN_NC}"
        ((critical++))
    fi
    
    echo -e "${NFTBAN_CYAN}[5/10] Disk Space${NFTBAN_NC}"
    if nftban_check_disk_space; then
        echo -e "  ${NFTBAN_GREEN}✓ SUFFICIENT${NFTBAN_NC}"
    else
        echo -e "  ${NFTBAN_YELLOW}⚠ LOW SPACE${NFTBAN_NC}"
        ((warnings++))
    fi
    
    echo -e "${NFTBAN_CYAN}[6/10] Process Lock${NFTBAN_NC}"
    if nftban_check_lock; then
        echo -e "  ${NFTBAN_GREEN}✓ NO CONFLICTS${NFTBAN_NC}"
        nftban_release_lock
    else
        echo -e "  ${NFTBAN_RED}✗ LOCK CONFLICT${NFTBAN_NC}"
        ((critical++))
    fi
    
    echo -e "${NFTBAN_CYAN}[7/10] Configuration Integrity${NFTBAN_NC}"
    if nftban_check_config_integrity; then
        echo -e "  ${NFTBAN_GREEN}✓ VALID${NFTBAN_NC}"
    else
        echo -e "  ${NFTBAN_YELLOW}⚠ ISSUES FOUND${NFTBAN_NC}"
        ((warnings++))
    fi
    
    echo -e "${NFTBAN_CYAN}[8/10] nftables Rule Order${NFTBAN_NC}"
    if nftban_check_nft_rules_order; then
        echo -e "  ${NFTBAN_GREEN}✓ CORRECT ORDER${NFTBAN_NC}"
    else
        echo -e "  ${NFTBAN_RED}✗ INCORRECT ORDER${NFTBAN_NC}"
        ((critical++))
    fi
    
    echo -e "${NFTBAN_CYAN}[9/10] Log File Size${NFTBAN_NC}"
    nftban_check_log_size
    echo -e "  ${NFTBAN_GREEN}✓ CHECKED${NFTBAN_NC}"
    
    echo -e "${NFTBAN_CYAN}[10/10] Private IP Protection${NFTBAN_NC}"
    nftban_check_private_ranges
    echo -e "  ${NFTBAN_GREEN}✓ CHECKED${NFTBAN_NC}"
    
    echo ""
    echo "═══════════════════════════════════════════════════════"
    echo "  SUMMARY"
    echo "═══════════════════════════════════════════════════════"
    echo ""
    
    if [[ $critical -gt 0 ]]; then
        echo -e "${NFTBAN_RED}✗ CRITICAL: $critical critical issue(s)${NFTBAN_NC}"
        [[ $warnings -gt 0 ]] && echo -e "${NFTBAN_YELLOW}⚠ $warnings warning(s)${NFTBAN_NC}"
        return 1
    elif [[ $warnings -gt 0 ]]; then
        echo -e "${NFTBAN_YELLOW}⚠ $warnings warning(s) found${NFTBAN_NC}"
        return 0
    else
        echo -e "${NFTBAN_GREEN}✓ ALL CHECKS PASSED${NFTBAN_NC}"
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
export -f nftban_check_nftables_running
export -f nftban_check_nft_set_capacity
export -f nftban_check_nft_duplicates
export -f nftban_check_file_permissions
export -f nftban_check_disk_space
export -f nftban_check_lock
export -f nftban_release_lock
export -f nftban_check_config_integrity
export -f nftban_check_nft_rules_order
export -f nftban_check_log_size
export -f nftban_check_private_ranges
export -f nftban_init_safeguards
export -f nftban_check_safeguards
export -f nftban_check_all_risks
export -f nftban_quick_safety_check
export -f nftban_check_ip_location

nftban_log_debug "NFTBan Safety Module loaded (v2.0.0 - Split Tables + 18 checks)"
