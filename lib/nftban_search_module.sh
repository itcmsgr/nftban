#!/usr/bin/env bash

# =============================================================================
# NFTBan Search Module
# Version: 1.0.0
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Consolidated IP search across all configuration files
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_SEARCH_LOADED:-}" ]] && return 0
readonly NFTBAN_SEARCH_LOADED=1

# =============================================================================
# SEARCH MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_SEARCH_DB="${NFTBAN_CACHE_DIR}/consolidated-search.db"
readonly NFTBAN_WHITELIST_INDEX="${NFTBAN_CACHE_DIR}/whitelist-index.db"
readonly NFTBAN_BLACKLIST_INDEX="${NFTBAN_CACHE_DIR}/blacklist-index.db"

# Configuration file paths
readonly NFTBAN_WHITELIST_SYSTEM="${NFTBAN_CONFIG_DIR}/whitelist-system.conf"
readonly NFTBAN_WHITELIST_USER="${NFTBAN_CONFIG_DIR}/whitelist-user.conf"
readonly NFTBAN_WHITELIST_CF="${NFTBAN_CONFIG_DIR}/whitelist-cloudflare.conf"
readonly NFTBAN_BLACKLIST_PERSISTENT="${NFTBAN_CONFIG_DIR}/blacklist-persistent.conf"
readonly NFTBAN_BLACKLIST_USER="${NFTBAN_CONFIG_DIR}/blacklist-user.conf"

# =============================================================================
# BUILD CONSOLIDATED SEARCH DATABASE
# =============================================================================
nftban_search_build_index() {
    nftban_log_info "Building consolidated search index..."
    
    local temp_file="${NFTBAN_SEARCH_DB}.tmp"
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    # Create header
    cat > "$temp_file" <<HEADER
# =============================================================================
# NFTBan Consolidated Search Database
# Generated: $timestamp
# Format: IP|SOURCE|TYPE|METADATA
# =============================================================================

HEADER
    
    local total_ips=0
    
    # Process System Whitelist
    if [[ -f "$NFTBAN_WHITELIST_SYSTEM" ]]; then
        while IFS= read -r line; do
            [[ $line =~ ^#.*$ || -z $line ]] && continue
            
            local ip=$(echo "$line" | awk '{print $1}')
            local comment=$(echo "$line" | sed 's/^[^#]*#\s*//' | sed 's/|.*$//')
            
            [[ -z "$ip" ]] && continue
            
            echo "${ip}|WHITELIST_SYSTEM|WHITELIST|${comment}" >> "$temp_file"
            ((total_ips++))
        done < "$NFTBAN_WHITELIST_SYSTEM"
    fi
    
    # Process User Whitelist
    if [[ -f "$NFTBAN_WHITELIST_USER" ]]; then
        while IFS= read -r line; do
            [[ $line =~ ^#.*$ || -z $line ]] && continue
            
            local ip=$(echo "$line" | awk '{print $1}')
            local comment=$(echo "$line" | sed 's/^[^#]*#\s*//' | sed 's/|.*$//')
            
            [[ -z "$ip" ]] && continue
            
            echo "${ip}|WHITELIST_USER|WHITELIST|${comment}" >> "$temp_file"
            ((total_ips++))
        done < "$NFTBAN_WHITELIST_USER"
    fi
    
    # Process Cloudflare Whitelist
    if [[ -f "$NFTBAN_WHITELIST_CF" ]]; then
        local cf_enabled=$(nftban_get_config "CLOUDFLARE_ENABLED" "false")
        
        if [[ "$cf_enabled" == "true" ]]; then
            while IFS= read -r line; do
                [[ $line =~ ^#.*$ || -z $line ]] && continue
                
                local ip=$(echo "$line" | awk '{print $1}')
                [[ -z "$ip" ]] && continue
                
                echo "${ip}|WHITELIST_CLOUDFLARE|WHITELIST|cloudflare" >> "$temp_file"
                ((total_ips++))
            done < "$NFTBAN_WHITELIST_CF"
        fi
    fi
    
    # Process Persistent Blacklist
    if [[ -f "$NFTBAN_BLACKLIST_PERSISTENT" ]]; then
        while IFS= read -r line; do
            [[ $line =~ ^#.*$ || -z $line ]] && continue
            
            local ip=$(echo "$line" | awk '{print $1}')
            local comment=$(echo "$line" | sed 's/^[^#]*#\s*//' | sed 's/|.*$//')
            
            [[ -z "$ip" ]] && continue
            
            echo "${ip}|BLACKLIST_PERSISTENT|BLACKLIST|${comment}" >> "$temp_file"
            ((total_ips++))
        done < "$NFTBAN_BLACKLIST_PERSISTENT"
    fi
    
    # Process User Blacklist
    if [[ -f "$NFTBAN_BLACKLIST_USER" ]]; then
        while IFS= read -r line; do
            [[ $line =~ ^#.*$ || -z $line ]] && continue
            
            local ip=$(echo "$line" | awk '{print $1}')
            local comment=$(echo "$line" | sed 's/^[^#]*#\s*//' | sed 's/|.*$//')
            
            [[ -z "$ip" ]] && continue
            
            echo "${ip}|BLACKLIST_USER|BLACKLIST|${comment}" >> "$temp_file"
            ((total_ips++))
        done < "$NFTBAN_BLACKLIST_USER"
    fi
    
    # Add footer
    cat >> "$temp_file" <<FOOTER

# =============================================================================
# Total indexed: $total_ips IP addresses
# Last updated: $timestamp
# =============================================================================
FOOTER
    
    # Atomic move
    mv "$temp_file" "$NFTBAN_SEARCH_DB"
    chmod 644 "$NFTBAN_SEARCH_DB"
    
    nftban_log_success "Search index built: $total_ips entries"
    
    # Build specialized indexes
    nftban_search_build_whitelist_index
    nftban_search_build_blacklist_index
    
    return 0
}

# =============================================================================
# BUILD WHITELIST-ONLY INDEX (for fast whitelist checks)
# =============================================================================
nftban_search_build_whitelist_index() {
    local temp_file="${NFTBAN_WHITELIST_INDEX}.tmp"
    
    if [[ -f "$NFTBAN_SEARCH_DB" ]]; then
        grep "|WHITELIST$" "$NFTBAN_SEARCH_DB" 2>/dev/null > "$temp_file" || true
        mv "$temp_file" "$NFTBAN_WHITELIST_INDEX"
        chmod 644 "$NFTBAN_WHITELIST_INDEX"
        nftban_log_debug "Whitelist index built"
    fi
}

# =============================================================================
# BUILD BLACKLIST-ONLY INDEX
# =============================================================================
nftban_search_build_blacklist_index() {
    local temp_file="${NFTBAN_BLACKLIST_INDEX}.tmp"
    
    if [[ -f "$NFTBAN_SEARCH_DB" ]]; then
        grep "|BLACKLIST$" "$NFTBAN_SEARCH_DB" 2>/dev/null > "$temp_file" || true
        mv "$temp_file" "$NFTBAN_BLACKLIST_INDEX"
        chmod 644 "$NFTBAN_BLACKLIST_INDEX"
        nftban_log_debug "Blacklist index built"
    fi
}

# =============================================================================
# CHECK IF INDEX NEEDS REBUILD
# =============================================================================
nftban_search_needs_rebuild() {
    # Check if index exists
    [[ ! -f "$NFTBAN_SEARCH_DB" ]] && return 0
    
    # Get index modification time
    local index_mtime=$(stat -c %Y "$NFTBAN_SEARCH_DB" 2>/dev/null || echo 0)
    
    # Check all source files
    local source_files=(
        "$NFTBAN_WHITELIST_SYSTEM"
        "$NFTBAN_WHITELIST_USER"
        "$NFTBAN_WHITELIST_CF"
        "$NFTBAN_BLACKLIST_PERSISTENT"
        "$NFTBAN_BLACKLIST_USER"
    )
    
    for file in "${source_files[@]}"; do
        if [[ -f "$file" ]]; then
            local file_mtime=$(stat -c %Y "$file" 2>/dev/null || echo 0)
            if [[ $file_mtime -gt $index_mtime ]]; then
                nftban_log_debug "Index rebuild needed: $(basename "$file") is newer"
                return 0
            fi
        fi
    done
    
    return 1
}

# =============================================================================
# AUTO-REBUILD IF NEEDED
# =============================================================================
nftban_search_ensure_index() {
    if nftban_search_needs_rebuild; then
        nftban_log_info "Auto-rebuilding search index..."
        nftban_search_build_index
    fi
}

# =============================================================================
# SEARCH FOR IP IN DATABASE
# =============================================================================
nftban_search_ip() {
    local ip="$1"
    
    # Validate IP
    nftban_validate_ip "$ip" || return 1
    
    # Ensure index is up to date
    nftban_search_ensure_index
    
    # Check if index exists
    if [[ ! -f "$NFTBAN_SEARCH_DB" ]]; then
        nftban_log_warning "Search index not available"
        return 1
    fi
    
    # Search for exact IP match
    local results=$(grep -E "^${ip}\|" "$NFTBAN_SEARCH_DB" 2>/dev/null || true)
    
    if [[ -n "$results" ]]; then
        echo "$results"
        return 0
    fi
    
    return 1
}

# =============================================================================
# CHECK IF IP IS WHITELISTED (fast)
# =============================================================================
nftban_search_is_whitelisted() {
    local ip="$1"
    
    # Validate IP
    nftban_validate_ip "$ip" || return 1
    
    # Ensure index is up to date
    nftban_search_ensure_index
    
    # Fast check using whitelist-only index
    if [[ -f "$NFTBAN_WHITELIST_INDEX" ]]; then
        grep -qE "^${ip}\|" "$NFTBAN_WHITELIST_INDEX" 2>/dev/null && return 0
    fi
    
    # Fallback to main search
    if nftban_search_ip "$ip" 2>/dev/null | grep -q "|WHITELIST$"; then
        return 0
    fi
    
    return 1
}

# =============================================================================
# CHECK IF IP IS BLACKLISTED
# =============================================================================
nftban_search_is_blacklisted() {
    local ip="$1"
    
    # Validate IP
    nftban_validate_ip "$ip" || return 1
    
    # Ensure index is up to date
    nftban_search_ensure_index
    
    # Fast check using blacklist-only index
    if [[ -f "$NFTBAN_BLACKLIST_INDEX" ]]; then
        grep -qE "^${ip}\|" "$NFTBAN_BLACKLIST_INDEX" 2>/dev/null && return 0
    fi
    
    # Fallback to main search
    if nftban_search_ip "$ip" 2>/dev/null | grep -q "|BLACKLIST$"; then
        return 0
    fi
    
    return 1
}

# =============================================================================
# GET IP DETAILS
# =============================================================================
nftban_search_get_details() {
    local ip="$1"
    
    local results
    results=$(nftban_search_ip "$ip" 2>/dev/null)
    
    if [[ -z "$results" ]]; then
        echo "IP not found in any list"
        return 1
    fi
    
    echo "$results" | while IFS='|' read -r found_ip source type metadata; do
        echo "IP: $found_ip"
        echo "Source: $source"
        echo "Type: $type"
        echo "Info: $metadata"
        echo ""
    done
}

# =============================================================================
# SHOW SEARCH STATISTICS
# =============================================================================
nftban_search_stats() {
    nftban_search_ensure_index
    
    echo -e "\n${NFTBAN_CYAN}=== Search Index Statistics ===${NFTBAN_NC}\n"
    
    if [[ ! -f "$NFTBAN_SEARCH_DB" ]]; then
        echo "Search index not available"
        return 1
    fi
    
    local total=$(grep -cvE '^#|^$' "$NFTBAN_SEARCH_DB" 2>/dev/null || echo 0)
    local whitelist=$(grep -cE "\|WHITELIST$" "$NFTBAN_SEARCH_DB" 2>/dev/null || echo 0)
    local blacklist=$(grep -cE "\|BLACKLIST$" "$NFTBAN_SEARCH_DB" 2>/dev/null || echo 0)
    
    echo "Total indexed: $total"
    echo "  Whitelisted: $whitelist"
    echo "  Blacklisted: $blacklist"
    echo ""
    
    # Show breakdown by source
    echo "Breakdown by source:"
    awk -F'|' '{print $2}' "$NFTBAN_SEARCH_DB" | grep -v '^#' | sort | uniq -c | while read -r count source; do
        printf "  %-25s %5d\n" "$source" "$count"
    done
    
    # Index freshness
    if [[ -f "$NFTBAN_SEARCH_DB" ]]; then
        local mtime=$(stat -c %Y "$NFTBAN_SEARCH_DB")
        local age=$(( $(date +%s) - mtime ))
        local age_human
        
        if [[ $age -lt 60 ]]; then
            age_human="${age} seconds"
        elif [[ $age -lt 3600 ]]; then
            age_human="$(( age / 60 )) minutes"
        else
            age_human="$(( age / 3600 )) hours"
        fi
        
        echo ""
        echo "Index age: $age_human"
    fi
}

# =============================================================================
# INITIALIZE SEARCH FILES
# =============================================================================
nftban_search_init() {
    # Create configuration files if they don't exist
    local config_files=(
        "$NFTBAN_WHITELIST_SYSTEM"
        "$NFTBAN_WHITELIST_USER"
        "$NFTBAN_BLACKLIST_PERSISTENT"
        "$NFTBAN_BLACKLIST_USER"
    )
    
    for file in "${config_files[@]}"; do
        if [[ ! -f "$file" ]]; then
            cat > "$file" <<EOF
# $(basename "$file")
# Format: IP_ADDRESS  # Comment
# Example:
#   192.168.1.100  # Office server
#   10.0.0.0/8     # Private network range

EOF
            chmod 644 "$file"
            nftban_log_debug "Created: $(basename "$file")"
        fi
    done
    
    # Build initial index
    nftban_search_build_index
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_search_build_index
export -f nftban_search_ip
export -f nftban_search_is_whitelisted
export -f nftban_search_is_blacklisted
export -f nftban_search_get_details
export -f nftban_search_stats

nftban_log_debug "NFTBan Search Module loaded"
