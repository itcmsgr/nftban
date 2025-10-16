#!/usr/bin/env bash

# =============================================================================
# NFTBan GEO Blocking Module
# Version: 1.0.0
# Country-level IP blocking using GeoIP databases
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_GEO_LOADED:-}" ]] && return 0
readonly NFTBAN_GEO_LOADED=1

# =============================================================================
# GEO MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_GEO_DATA_DIR="${NFTBAN_DATA_DIR}/geoip"
readonly NFTBAN_GEO_CACHE_DIR="${NFTBAN_GEO_DATA_DIR}/cache"
readonly NFTBAN_GEO_SETS_DIR="${NFTBAN_GEO_DATA_DIR}/sets"
readonly NFTBAN_GEO_BLACKLIST="${NFTBAN_CONFIG_DIR}/geo-blacklist.conf"
readonly NFTBAN_GEO_WHITELIST="${NFTBAN_CONFIG_DIR}/geo-whitelist.conf"
readonly NFTBAN_GEO_LOG="${NFTBAN_LOG_DIR}/geo-blocking.log"
readonly NFTBAN_GEO_METADATA="${NFTBAN_GEO_DATA_DIR}/metadata.json"

# GEO IP database URL
readonly NFTBAN_GEO_DB_URL="https://raw.githubusercontent.com/sapics/ip-location-db/main/dbip-country"

# =============================================================================
# GEO LOGGING
# =============================================================================
nftban_geo_log() {
    local action="$1"      # DOWNLOAD, BLOCK, UNBLOCK, ERROR
    local country="$2"
    local ip_version="${3:-both}"
    local details="${4:-}"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    mkdir -p "$(dirname "$NFTBAN_GEO_LOG")"
    echo "${timestamp}|${action}|${country}|IPv${ip_version}|${details}" >> "$NFTBAN_GEO_LOG"
}

# =============================================================================
# INITIALIZE GEO BLOCKING SYSTEM
# =============================================================================
nftban_geo_init() {
    nftban_log_info "Initializing GEO blocking system..."
    
    # Create directories
    mkdir -p "$NFTBAN_GEO_DATA_DIR" "$NFTBAN_GEO_CACHE_DIR" "$NFTBAN_GEO_SETS_DIR"
    
    # Create blacklist file
    if [[ ! -f "$NFTBAN_GEO_BLACKLIST" ]]; then
        cat > "$NFTBAN_GEO_BLACKLIST" <<'EOF'
# =============================================================================
# NFTBan GEO Blacklist Configuration
# =============================================================================
# List country codes (ISO 3166-1 alpha-2) to block
# Format: COUNTRY_CODE  # Comment
# Example:
#   CN  # China
#   RU  # Russia
#   KP  # North Korea
# =============================================================================

EOF
        chmod 644 "$NFTBAN_GEO_BLACKLIST"
        nftban_log_success "Created GEO blacklist: $NFTBAN_GEO_BLACKLIST"
    fi
    
    # Create whitelist file
    if [[ ! -f "$NFTBAN_GEO_WHITELIST" ]]; then
        cat > "$NFTBAN_GEO_WHITELIST" <<'EOF'
# =============================================================================
# NFTBan GEO Whitelist Configuration
# =============================================================================
# List country codes that should NEVER be blocked
# Whitelist takes precedence over blacklist
# Format: COUNTRY_CODE  # Comment
# Example:
#   US  # United States
#   GB  # United Kingdom
#   GR  # Greece
# =============================================================================

EOF
        chmod 644 "$NFTBAN_GEO_WHITELIST"
        nftban_log_success "Created GEO whitelist: $NFTBAN_GEO_WHITELIST"
    fi
    
    # Initialize metadata
    if [[ ! -f "$NFTBAN_GEO_METADATA" ]]; then
        echo "{}" > "$NFTBAN_GEO_METADATA"
    fi
    
    nftban_log_success "GEO blocking system initialized"
    nftban_geo_log "INIT" "SYSTEM" "both" "GEO system initialized"
}

# =============================================================================
# UPDATE GEO METADATA
# =============================================================================
nftban_geo_update_metadata() {
    local country="$1"
    local action="$2"
    local timestamp="$3"
    
    if ! command -v python3 &> /dev/null; then
        return 0
    fi
    
    python3 <<PYTHON
import json
import sys

try:
    with open("${NFTBAN_GEO_METADATA}", 'r') as f:
        data = json.load(f)
except:
    data = {}

country = "${country}"
if country not in data:
    data[country] = {}

data[country]["last_${action}"] = "${timestamp}"

with open("${NFTBAN_GEO_METADATA}", 'w') as f:
    json.dump(data, f, indent=2)
PYTHON
}

# =============================================================================
# DOWNLOAD COUNTRY IP RANGES
# =============================================================================
nftban_geo_download_country() {
    local country_code="$1"
    local ip_version="${2:-both}"  # 4, 6, or both
    
    country_code=$(echo "$country_code" | tr '[:lower:]' '[:upper:]')
    
    nftban_log_info "Downloading IP ranges for $country_code (IPv${ip_version})..."
    
    if ! command -v curl &> /dev/null && ! command -v wget &> /dev/null; then
        nftban_log_error "Neither curl nor wget found"
        return 1
    fi
    
    local success=false
    local timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    
    # Download IPv4
    if [[ "$ip_version" == "4" ]] || [[ "$ip_version" == "both" ]]; then
        local ipv4_url="${NFTBAN_GEO_DB_URL}/${country_code}.cidr"
        local ipv4_file="${NFTBAN_GEO_CACHE_DIR}/${country_code}-ipv4.cidr"
        
        nftban_log_info "  Downloading IPv4 from: $ipv4_url"
        
        if command -v curl &> /dev/null; then
            curl -sL -o "$ipv4_file" "$ipv4_url" 2>/dev/null && success=true
        elif command -v wget &> /dev/null; then
            wget -q -O "$ipv4_file" "$ipv4_url" 2>/dev/null && success=true
        fi
        
        if [[ -f "$ipv4_file" ]] && [[ -s "$ipv4_file" ]]; then
            local count=$(wc -l < "$ipv4_file")
            nftban_log_success "  Downloaded $count IPv4 ranges for $country_code"
            nftban_geo_log "DOWNLOAD" "$country_code" "4" "Success: $count ranges"
        else
            nftban_log_warning "  Failed to download IPv4 ranges for $country_code"
            nftban_geo_log "DOWNLOAD" "$country_code" "4" "Failed"
            rm -f "$ipv4_file"
        fi
    fi
    
    # Download IPv6
    if [[ "$ip_version" == "6" ]] || [[ "$ip_version" == "both" ]]; then
        local ipv6_url="${NFTBAN_GEO_DB_URL}/${country_code}-ipv6.cidr"
        local ipv6_file="${NFTBAN_GEO_CACHE_DIR}/${country_code}-ipv6.cidr"
        
        nftban_log_info "  Downloading IPv6 from: $ipv6_url"
        
        if command -v curl &> /dev/null; then
            curl -sL -o "$ipv6_file" "$ipv6_url" 2>/dev/null && success=true
        elif command -v wget &> /dev/null; then
            wget -q -O "$ipv6_file" "$ipv6_url" 2>/dev/null && success=true
        fi
        
        if [[ -f "$ipv6_file" ]] && [[ -s "$ipv6_file" ]]; then
            local count=$(wc -l < "$ipv6_file")
            nftban_log_success "  Downloaded $count IPv6 ranges for $country_code"
            nftban_geo_log "DOWNLOAD" "$country_code" "6" "Success: $count ranges"
        else
            nftban_log_warning "  Failed to download IPv6 ranges for $country_code"
            nftban_geo_log "DOWNLOAD" "$country_code" "6" "Failed"
            rm -f "$ipv6_file"
        fi
    fi
    
    if $success; then
        nftban_geo_update_metadata "$country_code" "downloaded" "$timestamp"
        return 0
    else
        return 1
    fi
}

# =============================================================================
# BLOCK COUNTRY
# =============================================================================
nftban_geo_block_country() {
    local country_code="$1"
    local ip_version="${2:-both}"  # 4, 6, or both
    
    country_code=$(echo "$country_code" | tr '[:lower:]' '[:upper:]')
    
    nftban_log_info "Blocking country: $country_code (IPv${ip_version})"
    
    # Check if country is in whitelist
    if [[ -f "$NFTBAN_GEO_WHITELIST" ]] && grep -qE "^${country_code}([[:space:]]|#)" "$NFTBAN_GEO_WHITELIST"; then
        nftban_log_error "Country $country_code is in GEO whitelist - cannot block"
        return 1
    fi
    
    # Download IP ranges if not cached
    local needs_download=false
    
    if [[ "$ip_version" == "4" ]] || [[ "$ip_version" == "both" ]]; then
        [[ ! -f "${NFTBAN_GEO_CACHE_DIR}/${country_code}-ipv4.cidr" ]] && needs_download=true
    fi
    
    if [[ "$ip_version" == "6" ]] || [[ "$ip_version" == "both" ]]; then
        [[ ! -f "${NFTBAN_GEO_CACHE_DIR}/${country_code}-ipv6.cidr" ]] && needs_download=true
    fi
    
    if $needs_download; then
        nftban_geo_download_country "$country_code" "$ip_version" || {
            nftban_log_error "Failed to download IP ranges for $country_code"
            return 1
        }
    fi
    
    # Check nftables table exists
    if ! nftban_check_nftables_table; then
        nftban_log_error "nftables table '$NFTBAN_NFT_TABLE' not found"
        return 1
    fi
    
    local total_added=0
    
    # Block IPv4
    if [[ "$ip_version" == "4" ]] || [[ "$ip_version" == "both" ]]; then
        local ipv4_file="${NFTBAN_GEO_CACHE_DIR}/${country_code}-ipv4.cidr"
        
        if [[ -f "$ipv4_file" ]] && [[ -s "$ipv4_file" ]]; then
            nftban_log_info "  Adding IPv4 ranges to nftables..."
            
            # Create set if doesn't exist
            nft add set inet "$NFTBAN_NFT_TABLE" "geo_block_v4_${country_code}" \
                "{ type ipv4_addr; flags interval; comment \"GEO block ${country_code} IPv4\"; }" 2>/dev/null || true
            
            # Flush existing
            nft flush set inet "$NFTBAN_NFT_TABLE" "geo_block_v4_${country_code}" 2>/dev/null
            
            # Add in batches
            local batch_file="${NFTBAN_GEO_SETS_DIR}/${country_code}-ipv4.nft"
            echo "add element inet $NFTBAN_NFT_TABLE geo_block_v4_${country_code} {" > "$batch_file"
            
            local count=0
            while IFS= read -r cidr; do
                [[ -z "$cidr" || "$cidr" =~ ^# ]] && continue
                echo "  $cidr," >> "$batch_file"
                ((count++))
                ((total_added++))
            done < "$ipv4_file"
            
            echo "}" >> "$batch_file"
            nft -f "$batch_file" 2>/dev/null
            
            nftban_log_success "  Added $count IPv4 ranges"
            nftban_geo_log "BLOCK" "$country_code" "4" "Added $count ranges"
        fi
    fi
    
    # Block IPv6
    if [[ "$ip_version" == "6" ]] || [[ "$ip_version" == "both" ]]; then
        local ipv6_file="${NFTBAN_GEO_CACHE_DIR}/${country_code}-ipv6.cidr"
        
        if [[ -f "$ipv6_file" ]] && [[ -s "$ipv6_file" ]]; then
            nftban_log_info "  Adding IPv6 ranges to nftables..."
            
            # Create set if doesn't exist
            nft add set inet "$NFTBAN_NFT_TABLE" "geo_block_v6_${country_code}" \
                "{ type ipv6_addr; flags interval; comment \"GEO block ${country_code} IPv6\"; }" 2>/dev/null || true
            
            # Flush existing
            nft flush set inet "$NFTBAN_NFT_TABLE" "geo_block_v6_${country_code}" 2>/dev/null
            
            # Add in batches
            local batch_file="${NFTBAN_GEO_SETS_DIR}/${country_code}-ipv6.nft"
            echo "add element inet $NFTBAN_NFT_TABLE geo_block_v6_${country_code} {" > "$batch_file"
            
            local count=0
            while IFS= read -r cidr; do
                [[ -z "$cidr" || "$cidr" =~ ^# ]] && continue
                echo "  $cidr," >> "$batch_file"
                ((count++))
                ((total_added++))
            done < "$ipv6_file"
            
            echo "}" >> "$batch_file"
            nft -f "$batch_file" 2>/dev/null
            
            nftban_log_success "  Added $count IPv6 ranges"
            nftban_geo_log "BLOCK" "$country_code" "6" "Added $count ranges"
        fi
    fi
    
    # Add to blacklist file if not already there
    if [[ -f "$NFTBAN_GEO_BLACKLIST" ]] && ! grep -qE "^${country_code}([[:space:]]|#)" "$NFTBAN_GEO_BLACKLIST"; then
        echo "${country_code}  # Added: $(date +'%Y-%m-%d')" >> "$NFTBAN_GEO_BLACKLIST"
    fi
    
    # Update metadata
    nftban_geo_update_metadata "$country_code" "blocked" "$(date +'%Y-%m-%d %H:%M:%S')"
    
    nftban_log_success "Country $country_code blocked ($total_added total ranges)"
    return 0
}

# =============================================================================
# UNBLOCK COUNTRY
# =============================================================================
nftban_geo_unblock_country() {
    local country_code="$1"
    local ip_version="${2:-both}"  # 4, 6, or both
    
    country_code=$(echo "$country_code" | tr '[:lower:]' '[:upper:]')
    
    nftban_log_info "Unblocking country: $country_code (IPv${ip_version})"
    
    if ! nftban_check_nftables_table; then
        nftban_log_error "nftables table '$NFTBAN_NFT_TABLE' not found"
        return 1
    fi
    
    local removed=false
    
    # Remove IPv4 set
    if [[ "$ip_version" == "4" ]] || [[ "$ip_version" == "both" ]]; then
        if nft delete set inet "$NFTBAN_NFT_TABLE" "geo_block_v4_${country_code}" 2>/dev/null; then
            nftban_log_success "  Removed IPv4 GEO set"
            nftban_geo_log "UNBLOCK" "$country_code" "4" "Set removed"
            removed=true
        fi
    fi
    
    # Remove IPv6 set
    if [[ "$ip_version" == "6" ]] || [[ "$ip_version" == "both" ]]; then
        if nft delete set inet "$NFTBAN_NFT_TABLE" "geo_block_v6_${country_code}" 2>/dev/null; then
            nftban_log_success "  Removed IPv6 GEO set"
            nftban_geo_log "UNBLOCK" "$country_code" "6" "Set removed"
            removed=true
        fi
    fi
    
    # Remove from blacklist file
    if [[ -f "$NFTBAN_GEO_BLACKLIST" ]] && grep -qE "^${country_code}([[:space:]]|#)" "$NFTBAN_GEO_BLACKLIST"; then
        sed -i "/^${country_code}[[:space:]]/d" "$NFTBAN_GEO_BLACKLIST"
        removed=true
    fi
    
    if $removed; then
        nftban_geo_update_metadata "$country_code" "unblocked" "$(date +'%Y-%m-%d %H:%M:%S')"
        nftban_log_success "Country $country_code unblocked"
        return 0
    else
        nftban_log_warning "Country $country_code was not blocked"
        return 1
    fi
}

# =============================================================================
# LIST BLOCKED COUNTRIES
# =============================================================================
nftban_geo_list_blocked() {
    echo -e "\n${NFTBAN_CYAN}=== GEO Blocked Countries ===${NFTBAN_NC}\n"
    
    if [[ ! -f "$NFTBAN_GEO_BLACKLIST" ]]; then
        echo "No GEO blacklist configured"
        return 0
    fi
    
    local count=0
    echo "Configured countries:"
    
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        
        ((count++))
        local country=$(echo "$line" | awk '{print $1}')
        
        # Check if active in nftables
        local v4_active=false
        local v6_active=false
        
        nft list set inet "$NFTBAN_NFT_TABLE" "geo_block_v4_${country}" &>/dev/null && v4_active=true
        nft list set inet "$NFTBAN_NFT_TABLE" "geo_block_v6_${country}" &>/dev/null && v6_active=true
        
        printf "%3d. %-4s" "$count" "$country"
        
        if $v4_active && $v6_active; then
            echo -e " ${NFTBAN_GREEN}[IPv4 + IPv6 Active]${NFTBAN_NC}"
        elif $v4_active; then
            echo -e " ${NFTBAN_YELLOW}[IPv4 Active]${NFTBAN_NC}"
        elif $v6_active; then
            echo -e " ${NFTBAN_YELLOW}[IPv6 Active]${NFTBAN_NC}"
        else
            echo -e " ${NFTBAN_RED}[Not Active]${NFTBAN_NC}"
        fi
    done < "$NFTBAN_GEO_BLACKLIST"
    
    [[ $count -eq 0 ]] && echo "No countries configured"
    
    echo ""
    echo "Active nftables GEO sets:"
    if nftban_check_nftables_table; then
        nft list sets inet "$NFTBAN_NFT_TABLE" 2>/dev/null | grep "geo_block" | while read -r line; do
            echo "  $line"
        done
    fi
}

# =============================================================================
# SYNC BLACKLIST TO NFTABLES
# =============================================================================
nftban_geo_sync_blacklist() {
    nftban_log_info "Syncing GEO blacklist to nftables..."
    
    if [[ ! -f "$NFTBAN_GEO_BLACKLIST" ]]; then
        nftban_log_warning "GEO blacklist not found"
        return 0
    fi
    
    local synced=0
    local failed=0
    
    while IFS= read -r line; do
        [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
        
        local country=$(echo "$line" | awk '{print $1}' | tr '[:lower:]' '[:upper:]')
        
        if nftban_geo_block_country "$country" "both"; then
            ((synced++))
        else
            ((failed++))
        fi
    done < "$NFTBAN_GEO_BLACKLIST"
    
    nftban_log_success "GEO sync complete: $synced succeeded, $failed failed"
}

# =============================================================================
# UPDATE GEO DATABASE
# =============================================================================
nftban_geo_update_database() {
    local country_code="${1:-ALL}"
    
    if [[ "$country_code" == "ALL" ]]; then
        nftban_log_info "Updating all blocked countries..."
        
        [[ ! -f "$NFTBAN_GEO_BLACKLIST" ]] && return 0
        
        local updated=0
        while IFS= read -r line; do
            [[ "$line" =~ ^#.*$ || -z "$line" ]] && continue
            
            local country=$(echo "$line" | awk '{print $1}' | tr '[:lower:]' '[:upper:]')
            nftban_geo_download_country "$country" "both" && ((updated++))
        done < "$NFTBAN_GEO_BLACKLIST"
        
        nftban_log_success "Updated $updated countries"
    else
        nftban_geo_download_country "$country_code" "both"
    fi
}

# =============================================================================
# CHECK IF IP IS GEO BLOCKED
# =============================================================================
nftban_geo_check_ip() {
    local ip="$1"
    
    nftban_validate_ip "$ip" || return 1
    
    local ver=$(nftban_detect_ip_version "$ip")
    [[ "$ver" == "invalid" ]] && return 1
    
    if ! nftban_check_nftables_table; then
        return 1
    fi
    
    # Check all GEO sets
    local geo_sets=$(nft list sets inet "$NFTBAN_NFT_TABLE" 2>/dev/null | grep "geo_block_v${ver}_" | awk '{print $2}')
    
    for set in $geo_sets; do
        if nft list set inet "$NFTBAN_NFT_TABLE" "$set" 2>/dev/null | grep -q "$ip"; then
            local country=$(echo "$set" | sed 's/geo_block_v[46]_//')
            echo "IP $ip belongs to GEO blocked country: $country"
            return 0
        fi
    done
    
    return 1
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_geo_init
export -f nftban_geo_download_country
export -f nftban_geo_block_country
export -f nftban_geo_unblock_country
export -f nftban_geo_list_blocked
export -f nftban_geo_sync_blacklist
export -f nftban_geo_update_database
export -f nftban_geo_check_ip

nftban_log_debug "NFTBan GEO Module loaded"
