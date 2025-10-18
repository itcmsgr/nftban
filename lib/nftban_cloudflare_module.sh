#!/usr/bin/env bash

# =============================================================================
# NFTBan Cloudflare Module
# Version: 2.0.0 - v0.9.0 SPLIT TABLE ARCHITECTURE
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Cloudflare IP ranges management and whitelist integration
# v0.9.0 UPDATE: Uses split ip/ip6 tables for better performance
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_CLOUDFLARE_LOADED:-}" ]] && return 0
readonly NFTBAN_CLOUDFLARE_LOADED=1

# =============================================================================
# CLOUDFLARE MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_CF_IPV4_CACHE="${NFTBAN_CACHE_DIR}/cloudflare-ipv4.txt"
readonly NFTBAN_CF_IPV6_CACHE="${NFTBAN_CACHE_DIR}/cloudflare-ipv6.txt"
readonly NFTBAN_CF_WHITELIST="${NFTBAN_CONFIG_DIR}/whitelist-cloudflare.conf"
readonly NFTBAN_CF_LOG="${NFTBAN_LOG_DIR}/cloudflare.log"

# Cloudflare IP list URLs
readonly NFTBAN_CF_IPV4_URL="https://www.cloudflare.com/ips-v4"
readonly NFTBAN_CF_IPV6_URL="https://www.cloudflare.com/ips-v6"

# =============================================================================
# CLOUDFLARE LOGGING
# =============================================================================
nftban_cf_log() {
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$(dirname "$NFTBAN_CF_LOG")"
    echo "[${timestamp}] ${message}" >> "$NFTBAN_CF_LOG"
}

# =============================================================================
# DOWNLOAD CLOUDFLARE IP RANGES
# =============================================================================
nftban_cloudflare_download_ips() {
    nftban_log_info "Downloading Cloudflare IP ranges..."
    
    local success=true
    
    # Download IPv4 ranges
    nftban_log_info "  Downloading IPv4 ranges..."
    if curl -sf "$NFTBAN_CF_IPV4_URL" -o "${NFTBAN_CF_IPV4_CACHE}.tmp" 2>/dev/null; then
        mv "${NFTBAN_CF_IPV4_CACHE}.tmp" "$NFTBAN_CF_IPV4_CACHE"
        local ipv4_count=$(wc -l < "$NFTBAN_CF_IPV4_CACHE")
        nftban_log_success "  Downloaded $ipv4_count IPv4 ranges"
        nftban_cf_log "IPv4 ranges updated: $ipv4_count entries"
    else
        nftban_log_error "  Failed to download IPv4 ranges"
        nftban_cf_log "ERROR: Failed to download IPv4 ranges"
        success=false
        rm -f "${NFTBAN_CF_IPV4_CACHE}.tmp"
    fi
    
    # Download IPv6 ranges
    nftban_log_info "  Downloading IPv6 ranges..."
    if curl -sf "$NFTBAN_CF_IPV6_URL" -o "${NFTBAN_CF_IPV6_CACHE}.tmp" 2>/dev/null; then
        mv "${NFTBAN_CF_IPV6_CACHE}.tmp" "$NFTBAN_CF_IPV6_CACHE"
        local ipv6_count=$(wc -l < "$NFTBAN_CF_IPV6_CACHE")
        nftban_log_success "  Downloaded $ipv6_count IPv6 ranges"
        nftban_cf_log "IPv6 ranges updated: $ipv6_count entries"
    else
        nftban_log_error "  Failed to download IPv6 ranges"
        nftban_cf_log "ERROR: Failed to download IPv6 ranges"
        success=false
        rm -f "${NFTBAN_CF_IPV6_CACHE}.tmp"
    fi
    
    if $success; then
        nftban_log_success "Cloudflare IP ranges downloaded successfully"
        
        # Update whitelist file
        nftban_cloudflare_update_whitelist
        
        return 0
    else
        nftban_log_error "Failed to download Cloudflare IP ranges"
        return 1
    fi
}

# =============================================================================
# UPDATE CLOUDFLARE WHITELIST FILE
# =============================================================================
nftban_cloudflare_update_whitelist() {
    local cf_enabled=$(nftban_get_config "CLOUDFLARE_ENABLED" "false")
    
    if [[ "$cf_enabled" != "true" ]]; then
        nftban_log_debug "Cloudflare integration disabled, skipping whitelist update"
        return 0
    fi
    
    nftban_log_info "Updating Cloudflare whitelist file..."
    
    local temp_file="${NFTBAN_CF_WHITELIST}.tmp"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    # Create whitelist header
    cat > "$temp_file" <<HEADER
# =============================================================================
# Cloudflare IP Ranges - Auto-generated
# Generated: $timestamp
# Source: $NFTBAN_CF_IPV4_URL
#         $NFTBAN_CF_IPV6_URL
# =============================================================================
# These IPs are automatically whitelisted when CLOUDFLARE_ENABLED=true
# =============================================================================

HEADER
    
    local total_ranges=0
    
    # Add IPv4 ranges
    if [[ -f "$NFTBAN_CF_IPV4_CACHE" ]]; then
        echo "# IPv4 Ranges" >> "$temp_file"
        cat "$NFTBAN_CF_IPV4_CACHE" >> "$temp_file"
        local ipv4_count=$(wc -l < "$NFTBAN_CF_IPV4_CACHE")
        total_ranges=$((total_ranges + ipv4_count))
        echo "" >> "$temp_file"
    fi
    
    # Add IPv6 ranges
    if [[ -f "$NFTBAN_CF_IPV6_CACHE" ]]; then
        echo "# IPv6 Ranges" >> "$temp_file"
        cat "$NFTBAN_CF_IPV6_CACHE" >> "$temp_file"
        local ipv6_count=$(wc -l < "$NFTBAN_CF_IPV6_CACHE")
        total_ranges=$((total_ranges + ipv6_count))
    fi
    
    # Add footer
    cat >> "$temp_file" <<FOOTER

# =============================================================================
# Total ranges: $total_ranges
# Last updated: $timestamp
# =============================================================================
FOOTER
    
    # Atomic move
    mv "$temp_file" "$NFTBAN_CF_WHITELIST"
    chmod 644 "$NFTBAN_CF_WHITELIST"
    
    nftban_log_success "Cloudflare whitelist updated: $total_ranges ranges"
    nftban_cf_log "Whitelist file updated: $total_ranges ranges"
    
    # Trigger search index rebuild
    if declare -f nftban_search_build_index &>/dev/null; then
        nftban_search_build_index
    fi
    
    return 0
}

# =============================================================================
# APPLY CLOUDFLARE RANGES TO NFTABLES
# =============================================================================
nftban_cloudflare_apply_to_nftables() {
    local cf_enabled=$(nftban_get_config "CLOUDFLARE_ENABLED" "false")
    
    if [[ "$cf_enabled" != "true" ]]; then
        nftban_log_warning "Cloudflare integration disabled"
        return 1
    fi
    
    if ! nftban_check_nftables_table; then
        nftban_log_error "nftables table '$NFTBAN_NFT_TABLE' not found"
        return 1
    fi
    
    nftban_log_info "Applying Cloudflare ranges to nftables..."
    
    local added_v4=0
    local added_v6=0
    
    # Add IPv4 ranges (v0.9.0: split tables)
    if [[ -f "$NFTBAN_CF_IPV4_CACHE" ]]; then
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue

            if nft add element "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" "whitelist" "{ $cidr }" 2>/dev/null; then
                ((added_v4++))
            fi
        done < "$NFTBAN_CF_IPV4_CACHE"

        nftban_log_success "  Added $added_v4 IPv4 ranges to nftables"
    fi

    # Add IPv6 ranges (v0.9.0: split tables)
    if [[ -f "$NFTBAN_CF_IPV6_CACHE" ]]; then
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue

            if nft add element "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" "whitelist" "{ $cidr }" 2>/dev/null; then
                ((added_v6++))
            fi
        done < "$NFTBAN_CF_IPV6_CACHE"

        nftban_log_success "  Added $added_v6 IPv6 ranges to nftables"
    fi
    
    nftban_log_success "Cloudflare ranges applied to nftables"
    nftban_cf_log "Applied to nftables: $added_v4 IPv4, $added_v6 IPv6"
    
    return 0
}

# =============================================================================
# REMOVE CLOUDFLARE RANGES FROM NFTABLES
# =============================================================================
nftban_cloudflare_remove_from_nftables() {
    if ! nftban_check_nftables_table; then
        nftban_log_error "nftables table '$NFTBAN_NFT_TABLE' not found"
        return 1
    fi
    
    nftban_log_info "Removing Cloudflare ranges from nftables..."
    
    local removed_v4=0
    local removed_v6=0
    
    # Remove IPv4 ranges (v0.9.0: split tables)
    if [[ -f "$NFTBAN_CF_IPV4_CACHE" ]]; then
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue

            if nft delete element "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" "whitelist" "{ $cidr }" 2>/dev/null; then
                ((removed_v4++))
            fi
        done < "$NFTBAN_CF_IPV4_CACHE"
    fi

    # Remove IPv6 ranges (v0.9.0: split tables)
    if [[ -f "$NFTBAN_CF_IPV6_CACHE" ]]; then
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue

            if nft delete element "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" "whitelist" "{ $cidr }" 2>/dev/null; then
                ((removed_v6++))
            fi
        done < "$NFTBAN_CF_IPV6_CACHE"
    fi
    
    nftban_log_success "Removed Cloudflare ranges: $removed_v4 IPv4, $removed_v6 IPv6"
    nftban_cf_log "Removed from nftables: $removed_v4 IPv4, $removed_v6 IPv6"
    
    return 0
}

# =============================================================================
# ENABLE CLOUDFLARE INTEGRATION
# =============================================================================
nftban_cloudflare_enable() {
    nftban_log_info "Enabling Cloudflare integration..."
    
    # Update configuration
    nftban_set_config "CLOUDFLARE_ENABLED" "true"
    
    # Download IP ranges
    if ! nftban_cloudflare_download_ips; then
        nftban_log_error "Failed to download Cloudflare IPs"
        return 1
    fi
    
    # Apply to nftables if table exists
    if nftban_check_nftables_table; then
        nftban_cloudflare_apply_to_nftables
    fi
    
    nftban_log_success "Cloudflare integration enabled"
    nftban_cf_log "Cloudflare integration enabled"
    
    return 0
}

# =============================================================================
# DISABLE CLOUDFLARE INTEGRATION
# =============================================================================
nftban_cloudflare_disable() {
    nftban_log_info "Disabling Cloudflare integration..."
    
    # Update configuration
    nftban_set_config "CLOUDFLARE_ENABLED" "false"
    
    # Clear whitelist file
    > "$NFTBAN_CF_WHITELIST"
    
    # Remove from nftables if table exists
    if nftban_check_nftables_table; then
        nftban_cloudflare_remove_from_nftables
    fi
    
    # Rebuild search index
    if declare -f nftban_search_build_index &>/dev/null; then
        nftban_search_build_index
    fi
    
    nftban_log_success "Cloudflare integration disabled"
    nftban_cf_log "Cloudflare integration disabled"
    
    return 0
}

# =============================================================================
# SHOW CLOUDFLARE STATUS
# =============================================================================
nftban_cloudflare_status() {
    echo -e "\n${NFTBAN_CYAN}=== Cloudflare Integration Status ===${NFTBAN_NC}\n"
    
    local cf_enabled=$(nftban_get_config "CLOUDFLARE_ENABLED" "false")
    local cf_auto_update=$(nftban_get_config "CLOUDFLARE_AUTO_UPDATE" "false")
    local cf_update_interval=$(nftban_get_config "CLOUDFLARE_UPDATE_INTERVAL" "86400")
    
    echo "Status: $cf_enabled"
    echo "Auto-update: $cf_auto_update"
    echo "Update interval: $((cf_update_interval / 3600)) hours"
    echo ""
    
    # IPv4 cache status
    if [[ -f "$NFTBAN_CF_IPV4_CACHE" ]]; then
        local ipv4_count=$(wc -l < "$NFTBAN_CF_IPV4_CACHE")
        local ipv4_mtime=$(stat -c %Y "$NFTBAN_CF_IPV4_CACHE")
        local ipv4_age=$(( ($(date +%s) - ipv4_mtime) / 3600 ))
        
        echo -e "${NFTBAN_GREEN}IPv4 Ranges:${NFTBAN_NC}"
        echo "  Count: $ipv4_count"
        echo "  Age: ${ipv4_age} hours"
        echo "  File: $NFTBAN_CF_IPV4_CACHE"
    else
        echo -e "${NFTBAN_RED}IPv4 Ranges: Not downloaded${NFTBAN_NC}"
    fi
    echo ""
    
    # IPv6 cache status
    if [[ -f "$NFTBAN_CF_IPV6_CACHE" ]]; then
        local ipv6_count=$(wc -l < "$NFTBAN_CF_IPV6_CACHE")
        local ipv6_mtime=$(stat -c %Y "$NFTBAN_CF_IPV6_CACHE")
        local ipv6_age=$(( ($(date +%s) - ipv6_mtime) / 3600 ))
        
        echo -e "${NFTBAN_GREEN}IPv6 Ranges:${NFTBAN_NC}"
        echo "  Count: $ipv6_count"
        echo "  Age: ${ipv6_age} hours"
        echo "  File: $NFTBAN_CF_IPV6_CACHE"
    else
        echo -e "${NFTBAN_RED}IPv6 Ranges: Not downloaded${NFTBAN_NC}"
    fi
    echo ""
    
    # Whitelist file status
    if [[ -f "$NFTBAN_CF_WHITELIST" ]]; then
        local wl_count=$(grep -cvE '^#|^$' "$NFTBAN_CF_WHITELIST" 2>/dev/null || echo 0)
        echo "Whitelist file:"
        echo "  Ranges: $wl_count"
        echo "  File: $NFTBAN_CF_WHITELIST"
    else
        echo "Whitelist file: Not created"
    fi
    echo ""
    
    # Recent log entries
    if [[ -f "$NFTBAN_CF_LOG" ]]; then
        echo -e "${NFTBAN_CYAN}Recent Activity (last 5):${NFTBAN_NC}"
        tail -5 "$NFTBAN_CF_LOG" | while read -r line; do
            echo "  $line"
        done
    fi
}

# =============================================================================
# CHECK IF UPDATE IS NEEDED
# =============================================================================
nftban_cloudflare_needs_update() {
    local cf_enabled=$(nftban_get_config "CLOUDFLARE_ENABLED" "false")
    [[ "$cf_enabled" != "true" ]] && return 1
    
    local update_interval=$(nftban_get_config "CLOUDFLARE_UPDATE_INTERVAL" "86400")
    
    # Check if cache files exist
    [[ ! -f "$NFTBAN_CF_IPV4_CACHE" ]] && return 0
    [[ ! -f "$NFTBAN_CF_IPV6_CACHE" ]] && return 0
    
    # Check age of cache files
    local ipv4_mtime=$(stat -c %Y "$NFTBAN_CF_IPV4_CACHE" 2>/dev/null || echo 0)
    local current_time=$(date +%s)
    local age=$((current_time - ipv4_mtime))
    
    if [[ $age -gt $update_interval ]]; then
        nftban_log_debug "Cloudflare cache expired (age: $((age / 3600))h)"
        return 0
    fi
    
    return 1
}

# =============================================================================
# AUTO-UPDATE (for cron)
# =============================================================================
nftban_cloudflare_auto_update() {
    local cf_auto_update=$(nftban_get_config "CLOUDFLARE_AUTO_UPDATE" "false")
    
    if [[ "$cf_auto_update" != "true" ]]; then
        nftban_log_debug "Cloudflare auto-update disabled"
        return 0
    fi
    
    if nftban_cloudflare_needs_update; then
        nftban_log_info "Running Cloudflare auto-update..."
        nftban_cloudflare_download_ips
        
        # Apply to nftables if enabled
        if nftban_check_nftables_table; then
            nftban_cloudflare_apply_to_nftables
        fi
    else
        nftban_log_debug "Cloudflare cache is fresh, no update needed"
    fi
}

# =============================================================================
# INITIALIZE CLOUDFLARE MODULE
# =============================================================================
nftban_cloudflare_init() {
    # Create cache directory
    mkdir -p "$(dirname "$NFTBAN_CF_IPV4_CACHE")"
    
    # Create whitelist file if doesn't exist
    if [[ ! -f "$NFTBAN_CF_WHITELIST" ]]; then
        cat > "$NFTBAN_CF_WHITELIST" <<EOF
# Cloudflare IP Ranges
# This file is automatically generated
# Do not edit manually
EOF
        chmod 644 "$NFTBAN_CF_WHITELIST"
    fi
    
    nftban_log_debug "Cloudflare module initialized"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_cloudflare_download_ips
export -f nftban_cloudflare_update_whitelist
export -f nftban_cloudflare_apply_to_nftables
export -f nftban_cloudflare_enable
export -f nftban_cloudflare_disable
export -f nftban_cloudflare_status
export -f nftban_cloudflare_auto_update

# Auto-initialize
nftban_cloudflare_init

nftban_log_debug "NFTBan Cloudflare Module loaded"
