#!/usr/bin/env bash

# BUG51 FIX: Add strict mode for production-grade security
set -Eeuo pipefail
IFS=$'\n\t'
umask 027


# =============================================================================
# NFTBan Feeds Library
# Version: 0.9.2
# Location: lib/nftban_feeds_lib.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Threat intelligence feed management library
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_FEEDS_LIB_LOADED:-}" ]] && return 0
readonly NFTBAN_FEEDS_LIB_LOADED=1

# =============================================================================
# FEED CONFIGURATION LOADER
# =============================================================================

# Load feed configuration with priority override
load_feed_config() {
    local feed_name="$1"
    local feed_var="FEED_${feed_name}_ENABLED"
    local override_var="NFTBAN_FEED_${feed_name}_ENABLED"
    
    # Priority: nftban.conf.local > nftban.conf > feeds.conf
    if [[ -n "${!override_var}" ]]; then
        echo "${!override_var}"
    else
        echo "${!feed_var}"
    fi
}

# Get all feed variable names
get_feed_list() {
    # Get all FEED_*_ENABLED variables from feeds.conf
    grep -E "^FEED_[A-Z0-9_]+_ENABLED=" "$NFTBAN_FEEDS_CONFIG" 2>/dev/null | \
        sed 's/FEED_//g' | \
        sed 's/_ENABLED=.*//g' | \
        sort -u
}

# Get feed property
get_feed_property() {
    local feed_name="$1"
    local property="$2"
    local var_name="FEED_${feed_name}_${property}"
    echo "${!var_name}"
}

# =============================================================================
# FEED VALIDATION
# =============================================================================

# Validate IP address
validate_ip() {
    local ip="$1"
    
    # IPv4 validation
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a octets=($ip)
        for octet in "${octets[@]}"; do
            if ((octet > 255)); then
                return 1
            fi
        done
        return 0
    fi
    
    # IPv6 validation (basic)
    if [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]; then
        return 0
    fi
    
    return 1
}

# Validate CIDR notation
validate_cidr() {
    local cidr="$1"
    
    # IPv4 CIDR
    if [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        local ip="${cidr%/*}"
        local prefix="${cidr#*/}"
        
        if ! validate_ip "$ip"; then
            return 1
        fi
        
        if ((prefix < 0 || prefix > 32)); then
            return 1
        fi
        
        return 0
    fi
    
    # IPv6 CIDR
    if [[ "$cidr" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}/[0-9]{1,3}$ ]]; then
        local prefix="${cidr#*/}"
        if ((prefix < 0 || prefix > 128)); then
            return 1
        fi
        return 0
    fi
    
    return 1
}

# BUG47 FIX: CIDR-aware whitelist checking
# Checks if an IP or CIDR overlaps with any entry in whitelist
is_whitelisted() {
    local input="$1"
    local whitelist_file="$NFTBAN_F2B_IGNOREIP"

    if [[ ! -f "$whitelist_file" ]]; then
        return 1
    fi

    # First, check for exact match (fast path)
    if grep -qE "^${input}$" "$whitelist_file" 2>/dev/null; then
        return 0
    fi

    # If input is an individual IP, check if it falls within any CIDR in whitelist
    if [[ "$input" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        # Read whitelist and check each CIDR
        while IFS= read -r whitelist_entry; do
            [[ -z "$whitelist_entry" || "$whitelist_entry" =~ ^[[:space:]]*# ]] && continue

            # If whitelist entry is a CIDR, check if input IP is within it
            if [[ "$whitelist_entry" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
                if ip_in_cidr "$input" "$whitelist_entry"; then
                    return 0
                fi
            fi
        done < "$whitelist_file"
    fi

    # If input is a CIDR, check for any overlap with whitelist
    # For now, we only check if the network address is whitelisted
    # Full CIDR-vs-CIDR overlap checking would require complex IP math
    if [[ "$input" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        local network_addr="${input%/*}"

        while IFS= read -r whitelist_entry; do
            [[ -z "$whitelist_entry" || "$whitelist_entry" =~ ^[[:space:]]*# ]] && continue

            # Check if whitelist CIDR contains our network address
            if [[ "$whitelist_entry" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
                if ip_in_cidr "$network_addr" "$whitelist_entry"; then
                    return 0
                fi
            # Check if whitelist individual IP falls within our CIDR
            elif [[ "$whitelist_entry" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                if ip_in_cidr "$whitelist_entry" "$input"; then
                    return 0
                fi
            fi
        done < "$whitelist_file"
    fi

    return 1
}

# Helper: Check if an IP address is within a CIDR range
# Usage: ip_in_cidr "192.168.1.10" "192.168.1.0/24"
ip_in_cidr() {
    local ip="$1"
    local cidr="$2"
    local network="${cidr%/*}"
    local prefix="${cidr#*/}"

    # Convert IP addresses to 32-bit integers
    local ip_int=$(ip_to_int "$ip")
    local net_int=$(ip_to_int "$network")

    # Calculate network mask
    local mask_int=$(( 0xFFFFFFFF << (32 - prefix) ))

    # Check if IP is in CIDR range
    if [[ $(( ip_int & mask_int )) -eq $(( net_int & mask_int )) ]]; then
        return 0
    fi

    return 1
}

# Helper: Convert IPv4 address to 32-bit integer
# Usage: ip_to_int "192.168.1.10"
ip_to_int() {
    local ip="$1"
    local IFS='.'
    local -a octets=($ip)

    echo $(( (octets[0] << 24) + (octets[1] << 16) + (octets[2] << 8) + octets[3] ))
}

# =============================================================================
# FEED DOWNLOAD & PARSING
# =============================================================================

# Download feed
download_feed() {
    local feed_name="$1"
    local feed_url=$(get_feed_property "$feed_name" "URL")
    local feed_file="$NFTBAN_FEEDS_DATA_DIR/${feed_name}.txt"
    local temp_file="${feed_file}.tmp"
    
    if [[ -z "$feed_url" ]]; then
        log_error "No URL defined for feed: $feed_name"
        return 1
    fi
    
    log_info "Downloading feed: $feed_name from $feed_url"

    # BUG53 FIX: Use safe_curl for secure downloads
    # safe_curl already includes: --proto '=https', --tlsv1.2, --fail-with-body, timeouts
    if safe_curl --max-time "$NFTBAN_FEEDS_DOWNLOAD_TIMEOUT" \
         -A "$FEEDS_USER_AGENT" \
         -o "$temp_file" \
         "$feed_url"; then
        
        # Verify file is not empty
        if [[ ! -s "$temp_file" ]]; then
            log_error "Downloaded feed is empty: $feed_name"
            rm -f "$temp_file"
            return 1
        fi
        
        # Move to final location
        mv "$temp_file" "$feed_file"
        log_success "Feed downloaded: $feed_name ($(wc -l < "$feed_file") lines)"
        return 0
    else
        log_error "Failed to download feed: $feed_name"
        rm -f "$temp_file"
        return 1
    fi
}

# Parse feed and extract IPs
parse_feed() {
    local feed_name="$1"
    local feed_file="$NFTBAN_FEEDS_DATA_DIR/${feed_name}.txt"
    local feed_format=$(get_feed_property "$feed_name" "FORMAT")
    local output_file="$NFTBAN_FEEDS_DATA_DIR/${feed_name}.parsed"
    
    if [[ ! -f "$feed_file" ]]; then
        log_error "Feed file not found: $feed_file"
        return 1
    fi
    
    log_info "Parsing feed: $feed_name (format: $feed_format)"
    
    # Clear output file
    > "$output_file"
    
    local valid_count=0
    local invalid_count=0
    
    while IFS= read -r line; do
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
        
        # Extract IP/CIDR based on format
        local ip=""
        
        case "$feed_format" in
            plain)
                # Plain IP per line
                ip=$(echo "$line" | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
                ;;
            cidr)
                # CIDR notation
                ip=$(echo "$line" | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}')
                ;;
            auto)
                # Auto-detect
                if [[ "$line" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2} ]]; then
                    ip=$(echo "$line" | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}')
                else
                    ip=$(echo "$line" | grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
                fi
                ;;
            csv)
                # CSV - assume IP in first column
                ip=$(echo "$line" | cut -d',' -f1 | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')
                ;;
        esac
        
        # Validate and save
        if [[ -n "$ip" ]]; then
            if [[ "$ip" =~ / ]]; then
                # CIDR notation
                if validate_cidr "$ip"; then
                    # BUG47 FIX: Check full CIDR against whitelist (CIDR-aware)
                    if [[ "$NFTBAN_FEEDS_RESPECT_WHITELIST" == "true" ]]; then
                        if is_whitelisted "$ip"; then
                            log_debug "Skipping whitelisted CIDR: $ip"
                            continue
                        fi
                    fi
                    echo "$ip" >> "$output_file"
                    ((valid_count++))
                else
                    ((invalid_count++))
                fi
            else
                # Single IP
                if validate_ip "$ip"; then
                    # Check whitelist if enabled
                    if [[ "$NFTBAN_FEEDS_RESPECT_WHITELIST" == "true" ]]; then
                        if is_whitelisted "$ip"; then
                            log_debug "Skipping whitelisted IP: $ip"
                            continue
                        fi
                    fi
                    echo "$ip" >> "$output_file"
                    ((valid_count++))
                else
                    ((invalid_count++))
                fi
            fi
        fi
        
        # Check max IPs limit
        if [[ "$NFTBAN_FEEDS_MAX_IPS_PER_FEED" -gt 0 ]] && \
           [[ "$valid_count" -ge "$NFTBAN_FEEDS_MAX_IPS_PER_FEED" ]]; then
            log_warning "Reached maximum IPs limit for feed: $feed_name"
            break
        fi
        
    done < "$feed_file"
    
    log_success "Parsed feed: $feed_name (valid: $valid_count, invalid: $invalid_count)"
    return 0
}

# =============================================================================
# NFTABLES INTEGRATION
# =============================================================================

# Create nftables set for feeds
create_feed_nftset() {
    local set_name="$NFTBAN_FEEDS_NFT_SET"
    local table="$NFTBAN_FEEDS_NFT_TABLE"
    
    log_info "Creating nftables set: $set_name"
    
    # Check if set exists
    if nft list set "$table" "$set_name" &>/dev/null; then
        log_debug "Set already exists: $set_name"
        return 0
    fi
    
    # Create set
    if nft add set "$table" "$set_name" "{ type ipv4_addr; flags interval; auto-merge; }"; then
        log_success "Created nftables set: $set_name"
        return 0
    else
        log_error "Failed to create nftables set: $set_name"
        return 1
    fi
}

# Import feed into nftables
import_feed_to_nftables() {
    local feed_name="$1"
    local parsed_file="$NFTBAN_FEEDS_DATA_DIR/${feed_name}.parsed"
    local set_name="$NFTBAN_FEEDS_NFT_SET"
    local table="$NFTBAN_FEEDS_NFT_TABLE"
    
    if [[ ! -f "$parsed_file" ]]; then
        log_error "Parsed feed file not found: $parsed_file"
        return 1
    fi
    
    log_info "Importing feed to nftables: $feed_name"
    
    # Create set if it doesn't exist
    create_feed_nftset
    
    local count=0
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        
        if nft add element "$table" "$set_name" "{ $ip }" 2>/dev/null; then
            ((count++))
        else
            log_debug "Failed to add IP to nftables: $ip"
        fi
    done < "$parsed_file"
    
    log_success "Imported $count IPs from feed: $feed_name"
    return 0
}

# =============================================================================
# FEED OPERATIONS
# =============================================================================

# Update single feed
update_feed() {
    local feed_name="$1"
    
    # Check if feed is enabled
    local enabled=$(load_feed_config "$feed_name")
    if [[ "$enabled" != "true" ]]; then
        log_debug "Feed is disabled: $feed_name"
        return 1
    fi
    
    log_info "Updating feed: $feed_name"
    
    # Download feed
    if ! download_feed "$feed_name"; then
        return 1
    fi
    
    # Parse feed
    if ! parse_feed "$feed_name"; then
        return 1
    fi
    
    # Import to nftables if enabled
    if [[ "$NFTBAN_FEEDS_AUTO_IMPORT" == "true" ]]; then
        if ! import_feed_to_nftables "$feed_name"; then
            return 1
        fi
    fi
    
    log_success "Feed updated successfully: $feed_name"
    return 0
}

# Update all enabled feeds
update_all_feeds() {
    log_info "Updating all enabled feeds..."
    
    local success=0
    local failed=0
    
    for feed in $(get_feed_list); do
        local enabled=$(load_feed_config "$feed")
        if [[ "$enabled" == "true" ]]; then
            if update_feed "$feed"; then
                ((success++))
            else
                ((failed++))
            fi
        fi
    done
    
    log_info "Feed update complete: $success successful, $failed failed"
    return 0
}

# List all feeds
list_feeds() {
    local show_all="${1:-false}"
    
    echo "=========================================="
    echo "NFTBAN THREAT INTELLIGENCE FEEDS"
    echo "=========================================="
    echo
    
    for feed in $(get_feed_list); do
        local enabled=$(load_feed_config "$feed")
        local name=$(get_feed_property "$feed" "NAME")
        local url=$(get_feed_property "$feed" "URL")
        local priority=$(get_feed_property "$feed" "PRIORITY")
        local description=$(get_feed_property "$feed" "DESCRIPTION")
        
        # Skip disabled feeds unless show_all
        if [[ "$show_all" != "true" && "$enabled" != "true" ]]; then
            continue
        fi
        
        local status="❌ DISABLED"
        [[ "$enabled" == "true" ]] && status="✅ ENABLED"
        
        echo "Feed: $name"
        echo "  Status: $status"
        echo "  Priority: $priority"
        echo "  Description: $description"
        echo "  URL: $url"
        
        # Check if feed data exists
        local feed_file="$NFTBAN_FEEDS_DATA_DIR/${feed}.txt"
        if [[ -f "$feed_file" ]]; then
            local last_update=$(stat -c %y "$feed_file" 2>/dev/null | cut -d'.' -f1)
            local ip_count=$(wc -l < "${NFTBAN_FEEDS_DATA_DIR}/${feed}.parsed" 2>/dev/null || echo "0")
            echo "  Last Update: $last_update"
            echo "  IPs Loaded: $ip_count"
        else
            echo "  Last Update: Never"
            echo "  IPs Loaded: 0"
        fi
        echo
    done
}

# Enable feed
enable_feed() {
    local feed_name="$1"
    local conf_local="$CONFIG_DIR/nftban.conf.local"

    # SECURITY: Validate feed identifier (must be alphanumeric with underscores only)
    if [[ ! "$feed_name" =~ ^[A-Z0-9_]+$ ]]; then
        log_error "Invalid feed identifier: $feed_name (must be uppercase alphanumeric with underscores)"
        return 1
    fi

    # Verify feed exists
    if ! get_feed_list | grep -q "^${feed_name}$"; then
        log_error "Feed not found: $feed_name"
        return 1
    fi

    log_info "Enabling feed: $feed_name"

    # Add to conf.local
    local override_var="NFTBAN_FEED_${feed_name}_ENABLED"
    
    if grep -q "^${override_var}=" "$conf_local" 2>/dev/null; then
        # Update existing entry
        sed -i "s/^${override_var}=.*/${override_var}=\"true\"/" "$conf_local"
    else
        # Add new entry
        echo "${override_var}=\"true\"" >> "$conf_local"
    fi
    
    log_success "Feed enabled: $feed_name"
    return 0
}

# Disable feed
disable_feed() {
    local feed_name="$1"
    local conf_local="$CONFIG_DIR/nftban.conf.local"

    # SECURITY: Validate feed identifier (must be alphanumeric with underscores only)
    if [[ ! "$feed_name" =~ ^[A-Z0-9_]+$ ]]; then
        log_error "Invalid feed identifier: $feed_name (must be uppercase alphanumeric with underscores)"
        return 1
    fi

    log_info "Disabling feed: $feed_name"

    local override_var="NFTBAN_FEED_${feed_name}_ENABLED"
    
    if grep -q "^${override_var}=" "$conf_local" 2>/dev/null; then
        sed -i "s/^${override_var}=.*/${override_var}=\"false\"/" "$conf_local"
    else
        echo "${override_var}=\"false\"" >> "$conf_local"
    fi
    
    log_success "Feed disabled: $feed_name"
    return 0
}

# Get feed statistics
feed_stats() {
    echo "=========================================="
    echo "FEED STATISTICS"
    echo "=========================================="
    echo
    
    local total_feeds=$(get_feed_list | wc -l)
    local enabled_count=0
    local total_ips=0
    
    for feed in $(get_feed_list); do
        local enabled=$(load_feed_config "$feed")
        if [[ "$enabled" == "true" ]]; then
            ((enabled_count++))
            local parsed_file="$NFTBAN_FEEDS_DATA_DIR/${feed}.parsed"
            if [[ -f "$parsed_file" ]]; then
                local count=$(wc -l < "$parsed_file")
                ((total_ips += count))
            fi
        fi
    done
    
    echo "Total Feeds: $total_feeds"
    echo "Enabled Feeds: $enabled_count"
    echo "Total IPs Blocked: $total_ips"
    echo
}

# =============================================================================
# MARK LIBRARY AS LOADED
# =============================================================================
log_debug "nftban_feeds.sh library loaded"
