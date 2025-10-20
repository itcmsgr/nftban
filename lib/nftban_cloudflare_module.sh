#!/usr/bin/env bash

# =============================================================================
# NFTBan Cloudflare Module
# Version: 0.9.0
# Location: lib/nftban_cloudflare_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Cloudflare IP ranges management and whitelist integration
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_CLOUDFLARE_LOADED:-}" ]] && return 0
readonly NFTBAN_CLOUDFLARE_LOADED=1

# =============================================================================
# CLOUDFLARE MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_CF_IPV4_CACHE="${NFTBAN_CACHE_DIR}/cloudflare-ipv4.txt"
readonly NFTBAN_CF_IPV6_CACHE="${NFTBAN_CACHE_DIR}/cloudflare-ipv6.txt"
readonly NFTBAN_CF_LOG="${NFTBAN_LOG_DIR}/cloudflare.log"

# Read configuration from nftban.conf
CLOUDFLARE_IPV4_URL="${CLOUDFLARE_IPV4_URL:-https://www.cloudflare.com/ips-v4}"
CLOUDFLARE_IPV6_URL="${CLOUDFLARE_IPV6_URL:-https://www.cloudflare.com/ips-v6}"
CLOUDFLARE_IPV4_WHITELIST_FILE="${CLOUDFLARE_IPV4_WHITELIST_FILE:-/etc/nftban/config/cloudflare-whitelist_ipsv4.conf}"
CLOUDFLARE_IPV6_WHITELIST_FILE="${CLOUDFLARE_IPV6_WHITELIST_FILE:-/etc/nftban/config/cloudflare-whitelist_ipsv6.conf}"

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
    if curl -sf "$CLOUDFLARE_IPV4_URL" -o "${NFTBAN_CF_IPV4_CACHE}.tmp" 2>/dev/null; then
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
    if curl -sf "$CLOUDFLARE_IPV6_URL" -o "${NFTBAN_CF_IPV6_CACHE}.tmp" 2>/dev/null; then
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
# UPDATE CLOUDFLARE WHITELIST FILES (IPv4 and IPv6 separately)
# =============================================================================
nftban_cloudflare_update_whitelist() {
    local ipv4_enabled=$(nftban_get_config "CLOUDFLARE_IPV4_WHITELIST" "FALSE")
    local ipv6_enabled=$(nftban_get_config "CLOUDFLARE_IPV6_WHITELIST" "FALSE")

    if [[ "$ipv4_enabled" != "TRUE" && "$ipv6_enabled" != "TRUE" ]]; then
        nftban_log_debug "Cloudflare whitelisting disabled, skipping whitelist update"
        return 0
    fi

    nftban_log_info "Updating Cloudflare whitelist files..."

    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    # Update IPv4 whitelist if enabled
    if [[ "$ipv4_enabled" == "TRUE" && -f "$NFTBAN_CF_IPV4_CACHE" ]]; then
        local temp_file="${CLOUDFLARE_IPV4_WHITELIST_FILE}.tmp"

        cat > "$temp_file" <<HEADER
# =============================================================================
# Cloudflare IPv4 Ranges - Auto-generated
# Generated: $timestamp
# Source: $CLOUDFLARE_IPV4_URL
# =============================================================================

HEADER

        cat "$NFTBAN_CF_IPV4_CACHE" >> "$temp_file"

        local ipv4_count=$(wc -l < "$NFTBAN_CF_IPV4_CACHE")

        cat >> "$temp_file" <<FOOTER

# =============================================================================
# Last updated: $timestamp
# Status: ENABLED - $ipv4_count IPv4 ranges
# =============================================================================
FOOTER

        mv "$temp_file" "$CLOUDFLARE_IPV4_WHITELIST_FILE"
        chmod 644 "$CLOUDFLARE_IPV4_WHITELIST_FILE"

        nftban_log_success "  IPv4 whitelist updated: $ipv4_count ranges"
        nftban_cf_log "IPv4 whitelist file updated: $ipv4_count ranges"
    fi

    # Update IPv6 whitelist if enabled
    if [[ "$ipv6_enabled" == "TRUE" && -f "$NFTBAN_CF_IPV6_CACHE" ]]; then
        local temp_file="${CLOUDFLARE_IPV6_WHITELIST_FILE}.tmp"

        cat > "$temp_file" <<HEADER
# =============================================================================
# Cloudflare IPv6 Ranges - Auto-generated
# Generated: $timestamp
# Source: $CLOUDFLARE_IPV6_URL
# =============================================================================

HEADER

        cat "$NFTBAN_CF_IPV6_CACHE" >> "$temp_file"

        local ipv6_count=$(wc -l < "$NFTBAN_CF_IPV6_CACHE")

        cat >> "$temp_file" <<FOOTER

# =============================================================================
# Last updated: $timestamp
# Status: ENABLED - $ipv6_count IPv6 ranges
# =============================================================================
FOOTER

        mv "$temp_file" "$CLOUDFLARE_IPV6_WHITELIST_FILE"
        chmod 644 "$CLOUDFLARE_IPV6_WHITELIST_FILE"

        nftban_log_success "  IPv6 whitelist updated: $ipv6_count ranges"
        nftban_cf_log "IPv6 whitelist file updated: $ipv6_count ranges"
    fi

    nftban_log_success "Cloudflare whitelist files updated"

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
    nftban_log_info "Enabling Cloudflare whitelisting..."

    # Update configuration - enable both IPv4 and IPv6
    nftban_set_config "CLOUDFLARE_IPV4_WHITELIST" "TRUE"
    nftban_set_config "CLOUDFLARE_IPV6_WHITELIST" "TRUE"

    # Download IP ranges
    if ! nftban_cloudflare_download_ips; then
        nftban_log_error "Failed to download Cloudflare IPs"
        return 1
    fi

    # Apply to nftables if table exists
    if nftban_check_nftables_table; then
        nftban_cloudflare_apply_to_nftables
    fi

    nftban_log_success "Cloudflare whitelisting enabled (IPv4 and IPv6)"
    nftban_cf_log "Cloudflare whitelisting enabled"

    return 0
}

# =============================================================================
# DISABLE CLOUDFLARE INTEGRATION
# =============================================================================
nftban_cloudflare_disable() {
    nftban_log_info "Disabling Cloudflare whitelisting..."

    # Update configuration - disable both IPv4 and IPv6
    nftban_set_config "CLOUDFLARE_IPV4_WHITELIST" "FALSE"
    nftban_set_config "CLOUDFLARE_IPV6_WHITELIST" "FALSE"

    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    # Clear IPv4 whitelist file but keep template header
    cat > "$CLOUDFLARE_IPV4_WHITELIST_FILE" <<'EOF'
# =============================================================================
# NFTBan Template File
# Version: init 1.0
# Template Name: cloudflare-whitelist_ipsv4.conf
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Template Directory: /etc/nftban/templates/conf
# User Customization Path: /etc/nftban/config
#
# Description:
# This template is used to store a list of IPv4 addresses provided by Cloudflare.
# These IPs are typically whitelisted to ensure uninterrupted access from Cloudflare's edge network.
#
# Behavior:
# - Users may override this template by creating a custom version under /etc/nftban/config.
# - If no custom file is found, the default template will be applied.
#
# Notes:
# - Keep the IP list updated according to Cloudflare's official documentation.
# - Ensure proper formatting to avoid parsing errors.
# =============================================================================

# (No IPs - Cloudflare IPv4 whitelist is DISABLED)
# To enable: nftban cloudflare enable

EOF
    echo "# =============================================================================" >> "$CLOUDFLARE_IPV4_WHITELIST_FILE"
    echo "# Last updated: $timestamp" >> "$CLOUDFLARE_IPV4_WHITELIST_FILE"
    echo "# Status: DISABLED" >> "$CLOUDFLARE_IPV4_WHITELIST_FILE"
    echo "# =============================================================================" >> "$CLOUDFLARE_IPV4_WHITELIST_FILE"
    chmod 644 "$CLOUDFLARE_IPV4_WHITELIST_FILE"

    # Clear IPv6 whitelist file but keep template header
    cat > "$CLOUDFLARE_IPV6_WHITELIST_FILE" <<'EOF'
# =============================================================================
# NFTBan Template File
# Version: init 1.0
# Template Name: cloudflare-whitelist_ipsv6.conf
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Template Directory: /etc/nftban/templates/conf
# User Customization Path: /etc/nftban/config
#
# Description:
# This template is used to store a list of IPv6 addresses provided by Cloudflare.
# These IPs are typically whitelisted to ensure uninterrupted access from Cloudflare's edge network.
#
# Behavior:
# - Users may override this template by creating a custom version under /etc/nftban/config.
# - If no custom file is found, the default template will be applied.
#
# Notes:
# - Keep the IP list updated according to Cloudflare's official documentation.
# - Ensure proper formatting to avoid parsing errors.
# =============================================================================

# (No IPs - Cloudflare IPv6 whitelist is DISABLED)
# To enable: nftban cloudflare enable

EOF
    echo "# =============================================================================" >> "$CLOUDFLARE_IPV6_WHITELIST_FILE"
    echo "# Last updated: $timestamp" >> "$CLOUDFLARE_IPV6_WHITELIST_FILE"
    echo "# Status: DISABLED" >> "$CLOUDFLARE_IPV6_WHITELIST_FILE"
    echo "# =============================================================================" >> "$CLOUDFLARE_IPV6_WHITELIST_FILE"
    chmod 644 "$CLOUDFLARE_IPV6_WHITELIST_FILE"

    # Remove from nftables if table exists
    if nftban_check_nftables_table; then
        nftban_cloudflare_remove_from_nftables
    fi

    # Rebuild search index
    if declare -f nftban_search_build_index &>/dev/null; then
        nftban_search_build_index
    fi

    nftban_log_success "Cloudflare whitelisting disabled (IPv4 and IPv6)"
    nftban_cf_log "Cloudflare whitelisting disabled"

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

    # Whitelist file status (IPv4)
    if [[ -f "$CLOUDFLARE_IPV4_WHITELIST_FILE" ]]; then
        local wl_count_v4=$(grep -cvE '^#|^$' "$CLOUDFLARE_IPV4_WHITELIST_FILE" 2>/dev/null || echo 0)
        echo "Whitelist IPv4 file:"
        echo "  Ranges: $wl_count_v4"
        echo "  File: $CLOUDFLARE_IPV4_WHITELIST_FILE"
    else
        echo "Whitelist IPv4 file: Not created"
    fi
    echo ""

    # Whitelist file status (IPv6)
    if [[ -f "$CLOUDFLARE_IPV6_WHITELIST_FILE" ]]; then
        local wl_count_v6=$(grep -cvE '^#|^$' "$CLOUDFLARE_IPV6_WHITELIST_FILE" 2>/dev/null || echo 0)
        echo "Whitelist IPv6 file:"
        echo "  Ranges: $wl_count_v6"
        echo "  File: $CLOUDFLARE_IPV6_WHITELIST_FILE"
    else
        echo "Whitelist IPv6 file: Not created"
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
    mkdir -p "$(dirname "$CLOUDFLARE_IPV4_WHITELIST_FILE")"

    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')

    # Create IPv4 whitelist template file if doesn't exist
    if [[ ! -f "$CLOUDFLARE_IPV4_WHITELIST_FILE" ]]; then
        cat > "$CLOUDFLARE_IPV4_WHITELIST_FILE" <<'EOF'
# =============================================================================
# NFTBan Template File
# Version: init 1.0
# Template Name: cloudflare-whitelist_ipsv4.conf
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Template Directory: /etc/nftban/templates/conf
# User Customization Path: /etc/nftban/config
#
# Description:
# This template is used to store a list of IPv4 addresses provided by Cloudflare.
# These IPs are typically whitelisted to ensure uninterrupted access from Cloudflare's edge network.
#
# Behavior:
# - Users may override this template by creating a custom version under /etc/nftban/config.
# - If no custom file is found, the default template will be applied.
#
# Notes:
# - Keep the IP list updated according to Cloudflare's official documentation.
# - Ensure proper formatting to avoid parsing errors.
# =============================================================================

# (No IPs - Cloudflare IPv4 whitelist is DISABLED)
# To enable: nftban cloudflare enable

EOF
        echo "# =============================================================================" >> "$CLOUDFLARE_IPV4_WHITELIST_FILE"
        echo "# Created: $timestamp" >> "$CLOUDFLARE_IPV4_WHITELIST_FILE"
        echo "# Status: DISABLED" >> "$CLOUDFLARE_IPV4_WHITELIST_FILE"
        echo "# =============================================================================" >> "$CLOUDFLARE_IPV4_WHITELIST_FILE"
        chmod 644 "$CLOUDFLARE_IPV4_WHITELIST_FILE"
    fi

    # Create IPv6 whitelist template file if doesn't exist
    if [[ ! -f "$CLOUDFLARE_IPV6_WHITELIST_FILE" ]]; then
        cat > "$CLOUDFLARE_IPV6_WHITELIST_FILE" <<'EOF'
# =============================================================================
# NFTBan Template File
# Version: init 1.0
# Template Name: cloudflare-whitelist_ipsv6.conf
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Template Directory: /etc/nftban/templates/conf
# User Customization Path: /etc/nftban/config
#
# Description:
# This template is used to store a list of IPv6 addresses provided by Cloudflare.
# These IPs are typically whitelisted to ensure uninterrupted access from Cloudflare's edge network.
#
# Behavior:
# - Users may override this template by creating a custom version under /etc/nftban/config.
# - If no custom file is found, the default template will be applied.
#
# Notes:
# - Keep the IP list updated according to Cloudflare's official documentation.
# - Ensure proper formatting to avoid parsing errors.
# =============================================================================

# (No IPs - Cloudflare IPv6 whitelist is DISABLED)
# To enable: nftban cloudflare enable

EOF
        echo "# =============================================================================" >> "$CLOUDFLARE_IPV6_WHITELIST_FILE"
        echo "# Created: $timestamp" >> "$CLOUDFLARE_IPV6_WHITELIST_FILE"
        echo "# Status: DISABLED" >> "$CLOUDFLARE_IPV6_WHITELIST_FILE"
        echo "# =============================================================================" >> "$CLOUDFLARE_IPV6_WHITELIST_FILE"
        chmod 644 "$CLOUDFLARE_IPV6_WHITELIST_FILE"
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
