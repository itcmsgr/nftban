#!/usr/bin/env bash

# =============================================================================
# NFTBan GEO Blocking Module
# Version: 0.9.0
# Location: lib/nftban_geo_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Country-level IP blocking using GeoIP databases with split table architecture
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

    # Create main configuration file
    local config_file="${NFTBAN_CONFIG_DIR}/geo-blocking.conf"
    if [[ ! -f "$config_file" ]]; then
        cat > "$config_file" <<'EOF'
# =============================================================================
# NFTBan GEO-Blocking Configuration
# =============================================================================

# Enable/Disable GEO-blocking
GEO_BLOCKING_ENABLED="FALSE"

# Blocking mode: "blacklist" or "whitelist"
# blacklist = Allow all EXCEPT countries in geo-blacklist.conf
# whitelist = Block all EXCEPT countries in geo-whitelist.conf
GEO_BLOCKING_MODE="blacklist"

# Dry-run mode (RECOMMENDED for testing)
# TRUE = Log what would be blocked, but don't actually block
# FALSE = Actually block traffic (production)
GEO_DRY_RUN="TRUE"

# Enable IPv4/IPv6 blocking
GEO_BLOCK_IPV4="TRUE"
GEO_BLOCK_IPV6="TRUE"

# Auto-block suspicious countries
GEO_AUTO_BLOCK="FALSE"

# Maximum blocked countries (memory limit)
GEO_MAX_BLOCKED_COUNTRIES="50"

# nftables batch size for loading IP ranges
GEO_NFTABLES_BATCH_SIZE="1000"

EOF
        chmod 644 "$config_file"
        nftban_log_success "Created GEO config: $config_file"
    fi

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
            
            # Create set if doesn't exist (v0.9.0: split tables, no _v4 suffix)
            nft add set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" "geo_block_${country_code}" \
                "{ type ipv4_addr; flags interval; comment \"GEO block ${country_code}\"; }" 2>/dev/null || true

            # Flush existing
            nft flush set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" "geo_block_${country_code}" 2>/dev/null

            # Add in batches
            local batch_file="${NFTBAN_GEO_SETS_DIR}/${country_code}-ipv4.nft"
            echo "add element ${NFTBAN_NFT_FAMILY_V4:-ip} ${NFTBAN_NFT_TABLE_V4:-nftban_v4} geo_block_${country_code} {" > "$batch_file"
            
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
            
            # Create set if doesn't exist (v0.9.0: split tables, no _v6 suffix)
            nft add set "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" "geo_block_${country_code}" \
                "{ type ipv6_addr; flags interval; comment \"GEO block ${country_code}\"; }" 2>/dev/null || true

            # Flush existing
            nft flush set "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" "geo_block_${country_code}" 2>/dev/null

            # Add in batches
            local batch_file="${NFTBAN_GEO_SETS_DIR}/${country_code}-ipv6.nft"
            echo "add element ${NFTBAN_NFT_FAMILY_V6:-ip6} ${NFTBAN_NFT_TABLE_V6:-nftban_v6} geo_block_${country_code} {" > "$batch_file"
            
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
    
    # Remove IPv4 set (v0.9.0: split tables, no _v4 suffix)
    if [[ "$ip_version" == "4" ]] || [[ "$ip_version" == "both" ]]; then
        if nft delete set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" "geo_block_${country_code}" 2>/dev/null; then
            nftban_log_success "  Removed IPv4 GEO set"
            nftban_geo_log "UNBLOCK" "$country_code" "4" "Set removed"
            removed=true
        fi
    fi

    # Remove IPv6 set (v0.9.0: split tables, no _v6 suffix)
    if [[ "$ip_version" == "6" ]] || [[ "$ip_version" == "both" ]]; then
        if nft delete set "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" "geo_block_${country_code}" 2>/dev/null; then
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
        
        # Check if active in nftables (v0.9.0: split tables, no _v4/_v6 suffix)
        local v4_active=false
        local v6_active=false

        nft list set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" "geo_block_${country}" &>/dev/null && v4_active=true
        nft list set "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" "geo_block_${country}" &>/dev/null && v6_active=true
        
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
        echo "  IPv4 table (${NFTBAN_NFT_FAMILY_V4:-ip} ${NFTBAN_NFT_TABLE_V4:-nftban_v4}):"
        nft list sets "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" 2>/dev/null | grep "geo_block" | while read -r line; do
            echo "    $line"
        done
        echo "  IPv6 table (${NFTBAN_NFT_FAMILY_V6:-ip6} ${NFTBAN_NFT_TABLE_V6:-nftban_v6}):"
        nft list sets "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" 2>/dev/null | grep "geo_block" | while read -r line; do
            echo "    $line"
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
    
    # Check all GEO sets (v0.9.0: split tables, no _v4/_v6 suffix)
    local table_family table_name
    if [[ "$ver" == "4" ]]; then
        table_family="${NFTBAN_NFT_FAMILY_V4:-ip}"
        table_name="${NFTBAN_NFT_TABLE_V4:-nftban_v4}"
    else
        table_family="${NFTBAN_NFT_FAMILY_V6:-ip6}"
        table_name="${NFTBAN_NFT_TABLE_V6:-nftban_v6}"
    fi

    local geo_sets=$(nft list sets "$table_family" "$table_name" 2>/dev/null | grep "geo_block_" | awk '{print $2}')

    for set in $geo_sets; do
        if nft list set "$table_family" "$table_name" "$set" 2>/dev/null | grep -q "$ip"; then
            local country=$(echo "$set" | sed 's/geo_block_//')
            echo "IP $ip belongs to GEO blocked country: $country"
            return 0
        fi
    done
    
    return 1
}

# =============================================================================
# ENABLE GEO-BLOCKING
# =============================================================================
nftban_geo_enable() {
    echo ""
    echo "======================================================================="
    echo "  NFTBan GEO-Blocking Enable"
    echo "======================================================================="
    echo ""

    # Read current config file
    local config_file="${NFTBAN_CONFIG_DIR}/geo-blocking.conf"

    if [[ ! -f "$config_file" ]]; then
        nftban_log_error "Configuration file not found: $config_file"
        echo ""
        echo "Run 'nftban geo init' first to initialize GEO-blocking."
        return 1
    fi

    # Check current status
    local current_status=$(grep "^GEO_BLOCKING_ENABLED=" "$config_file" 2>/dev/null | cut -d'"' -f2)

    if [[ "$current_status" == "TRUE" ]]; then
        echo "⚠️  GEO-blocking is already ENABLED"
        echo ""
        echo "Current status:"
        nftban_geo_status
        return 0
    fi

    # Show warning
    echo "⚠️  WARNING: You are about to enable GEO-blocking!"
    echo ""
    echo "This will block traffic from countries listed in:"
    echo "  ${NFTBAN_CONFIG_DIR}/geo-blacklist.conf"
    echo ""
    echo "Before enabling, make sure you have:"
    echo "  1. Reviewed and configured geo-blacklist.conf"
    echo "  2. Reviewed and configured geo-whitelist.conf"
    echo "  3. Set GEO_DRY_RUN=\"TRUE\" for testing (recommended)"
    echo "  4. Understand the risks of blocking entire countries"
    echo ""

    # Show current blacklist
    if [[ -f "$NFTBAN_GEO_BLACKLIST" ]]; then
        local blacklist_count=$(grep -cE "^[A-Z]{2}" "$NFTBAN_GEO_BLACKLIST" 2>/dev/null || echo "0")
        echo "Countries in blacklist: $blacklist_count"
        if [[ $blacklist_count -gt 0 ]]; then
            echo "Configured countries:"
            grep -E "^[A-Z]{2}" "$NFTBAN_GEO_BLACKLIST" | head -10 | while IFS= read -r line; do
                echo "  - $line"
            done
            [[ $blacklist_count -gt 10 ]] && echo "  ... and $((blacklist_count - 10)) more"
        fi
    fi
    echo ""

    # Check dry-run mode
    local dry_run=$(grep "^GEO_DRY_RUN=" "$config_file" 2>/dev/null | cut -d'"' -f2)
    if [[ "$dry_run" == "TRUE" ]]; then
        echo "✅ DRY-RUN mode is ENABLED (safe - will only log, not block)"
    else
        echo "⚠️  DRY-RUN mode is DISABLED (will actually block traffic!)"
        echo ""
        echo "STRONGLY RECOMMENDED: Enable dry-run first:"
        echo "  1. Edit: $config_file"
        echo "  2. Set: GEO_DRY_RUN=\"TRUE\""
        echo "  3. Test for 1-2 weeks"
        echo "  4. Review logs: tail -f ${NFTBAN_LOG_DIR}/geo-blocking.log"
        echo "  5. Only then disable dry-run for production"
    fi
    echo ""

    # Confirmation
    read -p "Do you want to enable GEO-blocking? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo ""
        echo "GEO-blocking NOT enabled. Cancelled by user."
        return 0
    fi

    echo ""
    nftban_log_info "Enabling GEO-blocking..."

    # Update configuration
    nftban_set_config "GEO_BLOCKING_ENABLED" "TRUE"

    # Initialize GEO system
    nftban_geo_init

    # Sync blacklist to nftables
    nftban_geo_sync_blacklist

    # Log the change
    nftban_geo_log "ENABLE" "SYSTEM" "both" "GEO-blocking enabled"

    echo ""
    echo "✅ GEO-blocking ENABLED"
    echo ""
    echo "Next steps:"
    echo "  1. Monitor logs: tail -f ${NFTBAN_LOG_DIR}/geo-blocking.log"
    echo "  2. Check status: nftban geo status"
    echo "  3. List blocked: nftban geo list"
    echo "  4. Test IP: nftban geo check <IP>"
    echo ""
    echo "To disable: nftban geo disable"
    echo ""
}

# =============================================================================
# DISABLE GEO-BLOCKING
# =============================================================================
nftban_geo_disable() {
    echo ""
    echo "======================================================================="
    echo "  NFTBan GEO-Blocking Disable"
    echo "======================================================================="
    echo ""

    # Read current config file
    local config_file="${NFTBAN_CONFIG_DIR}/geo-blocking.conf"

    if [[ ! -f "$config_file" ]]; then
        nftban_log_error "Configuration file not found: $config_file"
        echo ""
        echo "Run 'nftban geo init' first to initialize GEO-blocking."
        return 1
    fi

    # Check current status
    local current_status=$(grep "^GEO_BLOCKING_ENABLED=" "$config_file" 2>/dev/null | cut -d'"' -f2)

    if [[ "$current_status" == "FALSE" ]]; then
        echo "✅ GEO-blocking is already DISABLED"
        echo ""
        echo "Current status:"
        nftban_geo_status
        return 0
    fi

    # Show warning
    echo "You are about to disable GEO-blocking."
    echo ""
    echo "This will:"
    echo "  1. Remove ALL country blocks from nftables"
    echo "  2. Allow traffic from previously blocked countries"
    echo "  3. Keep blacklist/whitelist files (for future use)"
    echo ""

    # Show what will be removed
    if [[ -f "$NFTBAN_GEO_BLACKLIST" ]]; then
        local blacklist_count=$(grep -cE "^[A-Z]{2}" "$NFTBAN_GEO_BLACKLIST" 2>/dev/null || echo "0")
        echo "Countries currently blocked: $blacklist_count"
    fi
    echo ""

    # Confirmation
    read -p "Do you want to disable GEO-blocking? (yes/no): " confirm
    if [[ "$confirm" != "yes" ]]; then
        echo ""
        echo "GEO-blocking NOT disabled. Cancelled by user."
        return 0
    fi

    echo ""
    nftban_log_info "Disabling GEO-blocking..."

    # Update configuration
    nftban_set_config "GEO_BLOCKING_ENABLED" "FALSE"

    # Remove all GEO sets from nftables
    if nftban_check_nftables_table; then
        nftban_log_info "Removing GEO sets from nftables..."

        # Remove IPv4 GEO sets
        local v4_sets=$(nft list sets "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" 2>/dev/null | grep "geo_block_" | awk '{print $2}')
        for set in $v4_sets; do
            nft delete set "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" "$set" 2>/dev/null
            nftban_log_debug "Removed IPv4 GEO set: $set"
        done

        # Remove IPv6 GEO sets
        local v6_sets=$(nft list sets "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" 2>/dev/null | grep "geo_block_" | awk '{print $2}')
        for set in $v6_sets; do
            nft delete set "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" "$set" 2>/dev/null
            nftban_log_debug "Removed IPv6 GEO set: $set"
        done
    fi

    # Log the change
    nftban_geo_log "DISABLE" "SYSTEM" "both" "GEO-blocking disabled"

    echo ""
    echo "✅ GEO-blocking DISABLED"
    echo ""
    echo "All country blocks have been removed from nftables."
    echo "Blacklist/whitelist files preserved at:"
    echo "  - ${NFTBAN_CONFIG_DIR}/geo-blacklist.conf"
    echo "  - ${NFTBAN_CONFIG_DIR}/geo-whitelist.conf"
    echo ""
    echo "To re-enable: nftban geo enable"
    echo ""
}

# =============================================================================
# SHOW GEO-BLOCKING STATUS
# =============================================================================
nftban_geo_status() {
    echo ""
    echo "======================================================================="
    echo "  NFTBan GEO-Blocking Status"
    echo "======================================================================="
    echo ""

    # Read configuration
    local config_file="${NFTBAN_CONFIG_DIR}/geo-blocking.conf"

    if [[ ! -f "$config_file" ]]; then
        echo "❌ Configuration file not found: $config_file"
        echo ""
        echo "Run 'nftban geo init' first to initialize GEO-blocking."
        return 1
    fi

    # Get configuration values
    local geo_enabled=$(grep "^GEO_BLOCKING_ENABLED=" "$config_file" 2>/dev/null | cut -d'"' -f2)
    local geo_mode=$(grep "^GEO_BLOCKING_MODE=" "$config_file" 2>/dev/null | cut -d'"' -f2)
    local geo_dry_run=$(grep "^GEO_DRY_RUN=" "$config_file" 2>/dev/null | cut -d'"' -f2)
    local geo_ipv4=$(grep "^GEO_BLOCK_IPV4=" "$config_file" 2>/dev/null | cut -d'"' -f2)
    local geo_ipv6=$(grep "^GEO_BLOCK_IPV6=" "$config_file" 2>/dev/null | cut -d'"' -f2)
    local geo_auto=$(grep "^GEO_AUTO_BLOCK=" "$config_file" 2>/dev/null | cut -d'"' -f2)

    # Master status
    echo "Master Status:"
    if [[ "$geo_enabled" == "TRUE" ]]; then
        echo "  GEO-Blocking: ✅ ENABLED"
    else
        echo "  GEO-Blocking: ❌ DISABLED"
    fi
    echo ""

    # Configuration
    echo "Configuration:"
    echo "  Mode: $geo_mode"

    if [[ "$geo_dry_run" == "TRUE" ]]; then
        echo "  Dry-Run: ✅ ENABLED (safe - logging only, no blocking)"
    else
        echo "  Dry-Run: ❌ DISABLED (production - actually blocking!)"
    fi

    echo "  IPv4 Blocking: $geo_ipv4"
    echo "  IPv6 Blocking: $geo_ipv6"
    echo "  Auto-Block: $geo_auto"
    echo ""

    # Blacklist stats
    echo "Blacklist (${NFTBAN_CONFIG_DIR}/geo-blacklist.conf):"
    if [[ -f "$NFTBAN_GEO_BLACKLIST" ]]; then
        local blacklist_count=$(grep -cE "^[A-Z]{2}" "$NFTBAN_GEO_BLACKLIST" 2>/dev/null || echo "0")
        echo "  Countries configured: $blacklist_count"
        if [[ $blacklist_count -gt 0 ]]; then
            echo "  Countries:"
            grep -E "^[A-Z]{2}" "$NFTBAN_GEO_BLACKLIST" | while IFS= read -r line; do
                local country_code=$(echo "$line" | awk '{print $1}')
                local comment=$(echo "$line" | sed 's/^[A-Z]\{2\}[[:space:]]*//')
                printf "    - %-4s %s\n" "$country_code" "$comment"
            done
        fi
    else
        echo "  File not found"
    fi
    echo ""

    # Whitelist stats
    echo "Whitelist (${NFTBAN_CONFIG_DIR}/geo-whitelist.conf):"
    if [[ -f "$NFTBAN_GEO_WHITELIST" ]]; then
        local whitelist_count=$(grep -cE "^[A-Z]{2}" "$NFTBAN_GEO_WHITELIST" 2>/dev/null || echo "0")
        echo "  Countries configured: $whitelist_count"
        if [[ $whitelist_count -gt 0 ]]; then
            echo "  Countries (always allowed):"
            grep -E "^[A-Z]{2}" "$NFTBAN_GEO_WHITELIST" | head -5 | while IFS= read -r line; do
                local country_code=$(echo "$line" | awk '{print $1}')
                local comment=$(echo "$line" | sed 's/^[A-Z]\{2\}[[:space:]]*//')
                printf "    - %-4s %s\n" "$country_code" "$comment"
            done
            [[ $whitelist_count -gt 5 ]] && echo "    ... and $((whitelist_count - 5)) more"
        fi
    else
        echo "  File not found"
    fi
    echo ""

    # nftables status
    if [[ "$geo_enabled" == "TRUE" ]] && nftban_check_nftables_table; then
        echo "Active nftables GEO sets:"

        # Count IPv4 sets
        local v4_count=$(nft list sets "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" 2>/dev/null | grep -c "geo_block_" || echo "0")
        echo "  IPv4 GEO sets: $v4_count"

        # Count IPv6 sets
        local v6_count=$(nft list sets "${NFTBAN_NFT_FAMILY_V6:-ip6}" "${NFTBAN_NFT_TABLE_V6:-nftban_v6}" 2>/dev/null | grep -c "geo_block_" || echo "0")
        echo "  IPv6 GEO sets: $v6_count"

        # Show example sets
        if [[ $v4_count -gt 0 ]] || [[ $v6_count -gt 0 ]]; then
            echo "  Active countries:"
            nft list sets "${NFTBAN_NFT_FAMILY_V4:-ip}" "${NFTBAN_NFT_TABLE_V4:-nftban_v4}" 2>/dev/null | grep "geo_block_" | awk '{print $2}' | sed 's/geo_block_//' | head -10 | while read -r country; do
                echo "    - $country"
            done
            local total=$((v4_count > v6_count ? v4_count : v6_count))
            [[ $total -gt 10 ]] && echo "    ... and $((total - 10)) more"
        fi
    else
        echo "Active nftables GEO sets:"
        echo "  No GEO sets loaded (GEO-blocking disabled or not synced)"
    fi
    echo ""

    # Recent activity
    if [[ -f "$NFTBAN_GEO_LOG" ]]; then
        echo "Recent Activity (last 5 entries):"
        tail -5 "$NFTBAN_GEO_LOG" 2>/dev/null | while IFS='|' read -r timestamp action country ipver details; do
            printf "  [%s] %s - %s (IPv%s) - %s\n" "$timestamp" "$action" "$country" "$ipver" "$details"
        done
    else
        echo "Recent Activity:"
        echo "  No activity log found"
    fi
    echo ""

    # Helpful commands
    echo "Useful Commands:"
    if [[ "$geo_enabled" == "FALSE" ]]; then
        echo "  Enable:  nftban geo enable"
    else
        echo "  Disable: nftban geo disable"
    fi
    echo "  Block country:   nftban geo block CN"
    echo "  Unblock country: nftban geo unblock CN"
    echo "  List blocked:    nftban geo list"
    echo "  Check IP:        nftban geo check <IP>"
    echo "  Reload all:      nftban geo reload"
    echo ""
    echo "======================================================================="
    echo ""
}

# =============================================================================
# GEO-BLOCKING HELP
# =============================================================================
nftban_geo_help() {
    cat << 'EOF'

=======================================================================
  NFTBan GEO-Blocking Help - "Stupid User Friendly" Edition
=======================================================================

⚠️  IMPORTANT: GEO-blocking can block LEGITIMATE users!
Read this help carefully before using GEO-blocking features.

=======================================================================
WHAT IS GEO-BLOCKING?
=======================================================================

GEO-blocking prevents connections from specific countries based on
their IP address geographical location.

Example: Block all traffic from China (CN), Russia (RU), etc.

Use Cases:
  ✅ GOOD: Block countries with no legitimate users
  ✅ GOOD: Temporarily block during country-specific attacks
  ❌ BAD: Block countries with customers/partners
  ❌ BAD: Use as primary security (ineffective against VPNs)

=======================================================================
QUICK START - SAFE APPROACH
=======================================================================

Step 1: Configure countries to block
  Edit: /etc/nftban/config/geo-blacklist.conf
  Add country codes (one per line):
    CN  # China
    RU  # Russia

Step 2: Enable in dry-run mode (safe - only logs)
  nftban geo enable
  (Confirm when prompted)

Step 3: Monitor for 1-2 weeks
  tail -f /var/log/nftban/geo-blocking.log
  Look for false positives (legitimate users blocked)

Step 4: If clean, disable dry-run for production
  Edit: /etc/nftban/config/geo-blocking.conf
  Set: GEO_DRY_RUN="FALSE"
  nftban geo reload

=======================================================================
COMMANDS
=======================================================================

Basic Commands:
--------------
  nftban geo status
    Show current GEO-blocking status, configuration, and statistics
    Example output: Enabled/disabled, countries blocked, dry-run mode
    Run this FIRST to understand current state

  nftban geo enable
    Enable GEO-blocking for countries in blacklist
    ⚠️  Shows confirmation prompt before enabling
    ⚠️  Recommends dry-run mode for safety

  nftban geo disable
    Disable ALL GEO-blocking, remove all country blocks
    ⚠️  Shows confirmation prompt
    Keeps blacklist/whitelist files for future use

  nftban geo help
    Show this help message (you're reading it now!)

Country Management:
------------------
  nftban geo block <COUNTRY> [reason]
    Block a specific country immediately
    Examples:
      nftban geo block CN "High attack volume"
      nftban geo block RU
    Note: Automatically downloads IP ranges if not cached

  nftban geo unblock <COUNTRY>
    Unblock a specific country
    Example: nftban geo unblock CN
    Removes from blacklist AND nftables

  nftban geo list
    List all blocked countries and their status
    Shows: Country code, IPv4/IPv6 status, active/inactive

Testing & Verification:
----------------------
  nftban geo check <IP>
    Check if an IP address is GEO-blocked
    Examples:
      nftban geo check 1.2.3.4
      nftban geo check 2001:db8::1
    Shows: Which country the IP belongs to (if blocked)

  nftban geo test <COUNTRY>
    Test blocking a country in dry-run mode
    Downloads IP ranges but doesn't actually block
    Use for testing before production

Maintenance:
-----------
  nftban geo reload
    Reload GEO-blocking configuration from files
    Syncs blacklist to nftables
    Run after editing blacklist/whitelist files

  nftban geo update [COUNTRY]
    Update GeoIP database for country/countries
    Examples:
      nftban geo update CN    # Update China only
      nftban geo update ALL   # Update all blocked countries
    Database refreshed from: DB-IP community (free, monthly updates)

  nftban geo sync
    Synchronize blacklist file to nftables
    Adds any countries in blacklist not yet in nftables
    Useful after editing geo-blacklist.conf manually

  nftban geo stats
    Show GEO-blocking statistics
    Blocks per country, memory usage, performance metrics

=======================================================================
CONFIGURATION FILES
=======================================================================

Main Config: /etc/nftban/config/geo-blocking.conf
  Master settings (enable/disable, dry-run, mode, etc.)
  Edit to change global GEO-blocking behavior

Blacklist: /etc/nftban/config/geo-blacklist.conf
  Countries to BLOCK (used in blacklist mode)
  Format: One country code per line (CN, RU, etc.)
  Empty file = no countries blocked

Whitelist: /etc/nftban/config/geo-whitelist.conf
  Countries to ALWAYS ALLOW (overrides blacklist)
  Format: One country code per line (US, GB, etc.)
  Use for: Your country, customer countries, etc.

Logs: /var/log/nftban/geo-blocking.log
  All GEO-blocking activity logged here
  Monitor: tail -f /var/log/nftban/geo-blocking.log

=======================================================================
BLOCKING MODES
=======================================================================

Mode 1: BLACKLIST (Recommended)
  Allow all countries EXCEPT those in geo-blacklist.conf
  Config: GEO_BLOCKING_MODE="blacklist"
  Use for: Most servers (block known bad sources)

Mode 2: WHITELIST (Strict)
  Block all countries EXCEPT those in geo-whitelist.conf
  Config: GEO_BLOCKING_MODE="whitelist"
  ⚠️  DANGER: Empty whitelist = block entire world!
  Use for: Services serving specific regions only

=======================================================================
DRY-RUN MODE (STRONGLY RECOMMENDED FOR TESTING)
=======================================================================

What it does:
  - Logs what WOULD be blocked
  - Does NOT actually block traffic
  - Perfect for testing without risk

How to enable:
  Edit: /etc/nftban/config/geo-blocking.conf
  Set: GEO_DRY_RUN="TRUE"

Testing workflow:
  1. Enable dry-run mode (above)
  2. Enable GEO-blocking: nftban geo enable
  3. Monitor logs: tail -f /var/log/nftban/geo-blocking.log
  4. Watch for false positives (legitimate users "blocked")
  5. After 1-2 weeks clean, disable dry-run for production

=======================================================================
COUNTRY CODES (ISO 3166-1 alpha-2)
=======================================================================

Common Countries:
  US = United States   CN = China        RU = Russia
  GB = United Kingdom  DE = Germany      FR = France
  JP = Japan           IN = India        BR = Brazil
  CA = Canada          AU = Australia    IT = Italy
  ES = Spain           MX = Mexico       KR = South Korea
  NL = Netherlands     SG = Singapore    GR = Greece

High-Risk Sources (research before blocking!):
  CN = China           RU = Russia       KP = North Korea
  IR = Iran            VN = Vietnam      BD = Bangladesh
  IN = India           BR = Brazil       TR = Turkey

Full list: https://en.wikipedia.org/wiki/ISO_3166-1_alpha-2

=======================================================================
COMMON SCENARIOS
=======================================================================

Scenario 1: Block specific countries
  1. Edit: /etc/nftban/config/geo-blacklist.conf
  2. Add: CN, RU, KP (one per line)
  3. Enable: nftban geo enable
  4. Monitor: nftban geo status

Scenario 2: Temporarily block during attack
  nftban geo block CN "DDoS attack"
  (Later: nftban geo unblock CN when attack stops)

Scenario 3: Allow only specific countries
  1. Edit: /etc/nftban/config/geo-whitelist.conf
  2. Add: US, CA, GB (your countries)
  3. Edit: /etc/nftban/config/geo-blocking.conf
  4. Set: GEO_BLOCKING_MODE="whitelist"
  5. Enable: nftban geo enable

Scenario 4: Test before production
  1. Set: GEO_DRY_RUN="TRUE"
  2. Enable: nftban geo enable
  3. Monitor: tail -f /var/log/nftban/geo-blocking.log
  4. After testing: GEO_DRY_RUN="FALSE"

=======================================================================
TROUBLESHOOTING
=======================================================================

Problem: Legitimate user blocked
Solution:
  1. Add their country to whitelist:
     Edit: /etc/nftban/config/geo-whitelist.conf
     Add: US (example)
  2. Or whitelist specific IP:
     nftban whitelist add <IP> "Legitimate user"
  3. Or unblock entire country:
     nftban geo unblock CN

Problem: Countries not blocking
Solution:
  1. Check enabled: nftban geo status
  2. Check dry-run: Should be FALSE for production
  3. Reload: nftban geo reload
  4. Verify nftables: nft list sets ip nftban_v4 | grep geo

Problem: High memory usage
Solution:
  1. Block fewer large countries (US, CN have most IPs)
  2. Reduce GEO_MAX_BLOCKED_COUNTRIES in config
  3. Check: nftban geo stats

Problem: Slow performance
Solution:
  1. Increase GEO_NFTABLES_BATCH_SIZE in config
  2. Reduce number of blocked countries
  3. Pre-download IP ranges: nftban geo update ALL

=======================================================================
WARNINGS & LIMITATIONS
=======================================================================

⚠️  GEO-blocking is NOT foolproof:
  - VPNs bypass GEO-blocking (users appear from different country)
  - Proxies/Tor can bypass
  - GeoIP databases are ~95-98% accurate (not 100%)
  - Legitimate users traveling abroad get blocked
  - Cloud services may show incorrect country

⚠️  Can cause false positives:
  - Corporate VPNs route through other countries
  - Mobile roaming shows foreign IPs
  - CDNs may appear from unexpected locations
  - Shared hosting affects neighboring users

⚠️  Legal considerations:
  - Some jurisdictions prohibit geographic discrimination
  - GDPR requires legitimate reason to block EU countries
  - Document business justification
  - Consult legal team for compliance

⚠️  Best practices:
  - Use as secondary defense, not primary
  - Combine with other security measures
  - Keep blacklist minimal (only proven threats)
  - Review regularly (threat landscape changes)
  - Monitor logs for false positives
  - Provide alternative access (support contact)

=======================================================================
FOR MORE HELP
=======================================================================

Documentation: /etc/nftban/templates/conf/geo-blocking.conf
  Comprehensive configuration documentation with examples

Logs: /var/log/nftban/geo-blocking.log
  All GEO-blocking activity

Support: contact@itcms.gr

=======================================================================

EOF
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
export -f nftban_geo_enable
export -f nftban_geo_disable
export -f nftban_geo_status
export -f nftban_geo_help

nftban_log_debug "NFTBan GEO Module loaded"
