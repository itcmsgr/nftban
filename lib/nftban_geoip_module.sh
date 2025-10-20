#!/usr/bin/env bash

# =============================================================================
# NFTBan GeoIP Lookup Integration Module
# Version: 0.9.0
# Location: lib/nftban_geoip_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Advanced GeoIP lookup with multiple providers and caching
# =============================================================================

# Prevent double-loading
[[ -n "${NFTBAN_GEOIP_LOADED:-}" ]] && return 0
readonly NFTBAN_GEOIP_LOADED=1

# =============================================================================
# MODULE CONFIGURATION
# =============================================================================
readonly NFTBAN_GEOIP_CACHE_DIR="${NFTBAN_CACHE_DIR}/geoip"
readonly NFTBAN_GEOIP_LOG="${NFTBAN_LOG_DIR}/geoip-lookup.log"
readonly NFTBAN_GEOIP_CACHE_TTL=86400  # 24 hours

# GeoIP API endpoints (in priority order)
readonly NFTBAN_GEOIP_PROVIDERS=(
    "ip-api.com"
    "ipinfo.io"
    "ipapi.co"
    "freegeoip.app"
)

# =============================================================================
# GEOIP CACHE MANAGEMENT
# =============================================================================

nftban_geoip_init() {
    mkdir -p "$NFTBAN_GEOIP_CACHE_DIR"
    nftban_log_debug "GeoIP lookup module initialized"
}

# Get cache file path for IP
nftban_geoip_get_cache_file() {
    local ip="$1"
    local cache_key
    cache_key=$(echo "$ip" | md5sum | cut -d' ' -f1)
    echo "${NFTBAN_GEOIP_CACHE_DIR}/${cache_key}.json"
}

# Check if cache is valid
nftban_geoip_is_cache_valid() {
    local cache_file="$1"
    
    [[ ! -f "$cache_file" ]] && return 1
    
    local cache_time
    cache_time=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
    local current_time
    current_time=$(date +%s)
    local age=$((current_time - cache_time))
    
    [[ $age -lt $NFTBAN_GEOIP_CACHE_TTL ]] && return 0 || return 1
}

# Save to cache
nftban_geoip_save_cache() {
    local ip="$1"
    local data="$2"
    local cache_file
    cache_file=$(nftban_geoip_get_cache_file "$ip")
    
    echo "$data" > "$cache_file"
}

# Load from cache
nftban_geoip_load_cache() {
    local ip="$1"
    local cache_file
    cache_file=$(nftban_geoip_get_cache_file "$ip")
    
    if nftban_geoip_is_cache_valid "$cache_file"; then
        cat "$cache_file"
        return 0
    fi
    
    return 1
}

# Clear cache
nftban_geoip_clear_cache() {
    rm -rf "${NFTBAN_GEOIP_CACHE_DIR:?}"/*
    mkdir -p "$NFTBAN_GEOIP_CACHE_DIR"
    nftban_log_info "GeoIP cache cleared"
}

# =============================================================================
# GEOIP PROVIDERS
# =============================================================================

# Query ip-api.com
nftban_geoip_query_ipapi() {
    local ip="$1"
    
    if ! command -v curl &>/dev/null; then
        return 1
    fi
    
    local response
    response=$(curl -s --connect-timeout 3 \
        "http://ip-api.com/json/${ip}?fields=status,message,country,countryCode,region,regionName,city,isp,org,as,mobile,proxy,hosting" 2>/dev/null)
    
    if [[ -z "$response" ]]; then
        return 1
    fi
    
    # Check if successful
    if echo "$response" | grep -q '"status":"success"'; then
        echo "$response"
        return 0
    fi
    
    return 1
}

# Query ipinfo.io
nftban_geoip_query_ipinfo() {
    local ip="$1"
    
    if ! command -v curl &>/dev/null; then
        return 1
    fi
    
    local response
    response=$(curl -s --connect-timeout 3 "https://ipinfo.io/${ip}/json" 2>/dev/null)
    
    if [[ -n "$response" ]] && echo "$response" | grep -q '"ip"'; then
        echo "$response"
        return 0
    fi
    
    return 1
}

# Query ipapi.co
nftban_geoip_query_ipapico() {
    local ip="$1"
    
    if ! command -v curl &>/dev/null; then
        return 1
    fi
    
    local response
    response=$(curl -s --connect-timeout 3 "https://ipapi.co/${ip}/json/" 2>/dev/null)
    
    if [[ -n "$response" ]] && ! echo "$response" | grep -q '"error"'; then
        echo "$response"
        return 0
    fi
    
    return 1
}

# Query freegeoip.app
nftban_geoip_query_freegeoip() {
    local ip="$1"
    
    if ! command -v curl &>/dev/null; then
        return 1
    fi
    
    local response
    response=$(curl -s --connect-timeout 3 "https://freegeoip.app/json/${ip}" 2>/dev/null)
    
    if [[ -n "$response" ]] && echo "$response" | grep -q '"ip"'; then
        echo "$response"
        return 0
    fi
    
    return 1
}

# Query local GeoIP database (if available)
nftban_geoip_query_local() {
    local ip="$1"
    
    # Try geoiplookup command
    if command -v geoiplookup &>/dev/null; then
        local result
        result=$(geoiplookup "$ip" 2>/dev/null)
        
        if [[ -n "$result" ]]; then
            # Convert to JSON format
            local country
            country=$(echo "$result" | head -1 | cut -d: -f2- | tr -d ' ')
            
            echo "{\"ip\":\"${ip}\",\"country\":\"${country}\",\"source\":\"local\"}"
            return 0
        fi
    fi
    
    return 1
}

# =============================================================================
# MAIN GEOIP LOOKUP
# =============================================================================

# Lookup IP with fallback through providers
nftban_geoip_lookup() {
    local ip="$1"
    local force_refresh="${2:-false}"
    
    # Validate IP
    nftban_validate_ip "$ip" || {
        echo "{\"error\":\"Invalid IP\"}"
        return 1
    }
    
    # Check if GeoIP is enabled
    local geoip_enabled
    geoip_enabled=$(nftban_get_config "NFTBAN_GEOIP_ENABLE" "true")
    
    if [[ "$geoip_enabled" != "true" ]]; then
        echo "{\"ip\":\"${ip}\",\"status\":\"disabled\"}"
        return 0
    fi
    
    # Try cache first (unless force refresh)
    if [[ "$force_refresh" != "true" ]]; then
        local cached
        cached=$(nftban_geoip_load_cache "$ip" 2>/dev/null)
        
        if [[ -n "$cached" ]]; then
            nftban_log_debug "GeoIP cache hit for $ip"
            echo "$cached"
            return 0
        fi
    fi
    
    # Try local database first
    local result
    result=$(nftban_geoip_query_local "$ip" 2>/dev/null)
    
    if [[ -n "$result" ]]; then
        nftban_log_debug "GeoIP local lookup for $ip"
        nftban_geoip_save_cache "$ip" "$result"
        echo "$result"
        return 0
    fi
    
    # Try online providers
    local providers=("ipapi" "ipinfo" "ipapico" "freegeoip")
    
    for provider in "${providers[@]}"; do
        nftban_log_debug "Trying GeoIP provider: $provider"
        
        case "$provider" in
            ipapi)
                result=$(nftban_geoip_query_ipapi "$ip" 2>/dev/null)
                ;;
            ipinfo)
                result=$(nftban_geoip_query_ipinfo "$ip" 2>/dev/null)
                ;;
            ipapico)
                result=$(nftban_geoip_query_ipapico "$ip" 2>/dev/null)
                ;;
            freegeoip)
                result=$(nftban_geoip_query_freegeoip "$ip" 2>/dev/null)
                ;;
        esac
        
        if [[ -n "$result" ]]; then
            nftban_log_debug "GeoIP lookup successful via $provider"
            
            # Save to cache
            nftban_geoip_save_cache "$ip" "$result"
            
            # Log lookup
            local timestamp
            timestamp=$(date +'%Y-%m-%d %H:%M:%S')
            echo "[${timestamp}] ${ip} | ${provider} | SUCCESS" >> "$NFTBAN_GEOIP_LOG"
            
            echo "$result"
            return 0
        fi
    done
    
    # All providers failed
    nftban_log_warning "GeoIP lookup failed for $ip (all providers failed)"
    
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    echo "[${timestamp}] ${ip} | ALL_PROVIDERS | FAILED" >> "$NFTBAN_GEOIP_LOG"
    
    echo "{\"ip\":\"${ip}\",\"error\":\"All providers failed\"}"
    return 1
}

# =============================================================================
# FORMATTED OUTPUT
# =============================================================================

# Get formatted GeoIP info
nftban_geoip_get_formatted() {
    local ip="$1"
    
    local result
    result=$(nftban_geoip_lookup "$ip")
    
    if ! command -v python3 &>/dev/null; then
        echo "$result"
        return 0
    fi
    
    # Parse JSON and format nicely
    python3 << PYTHON
import json
import sys

try:
    data = json.loads('''$result''')
    
    if 'error' in data:
        print(f"GeoIP Lookup Failed: {data.get('error', 'Unknown error')}")
        sys.exit(1)
    
    # Handle different provider formats
    if 'status' in data and data['status'] == 'fail':
        print(f"GeoIP Lookup Failed: {data.get('message', 'Unknown error')}")
        sys.exit(1)
    
    if 'status' in data and data['status'] == 'disabled':
        print("GeoIP Disabled")
        sys.exit(0)
    
    # Extract common fields
    ip = data.get('ip', '$ip')
    country = data.get('country', data.get('country_name', 'Unknown'))
    country_code = data.get('countryCode', data.get('country_code', '??'))
    region = data.get('regionName', data.get('region', 'Unknown'))
    city = data.get('city', 'Unknown')
    isp = data.get('isp', data.get('org', 'Unknown'))
    
    # Additional fields
    asn = data.get('as', '')
    mobile = data.get('mobile', False)
    proxy = data.get('proxy', False)
    hosting = data.get('hosting', False)
    
    print(f"IP: {ip}")
    print(f"Country: {country} ({country_code})")
    print(f"Region: {region}")
    print(f"City: {city}")
    print(f"ISP: {isp}")
    
    if asn:
        print(f"ASN: {asn}")
    
    flags = []
    if mobile:
        flags.append("Mobile")
    if proxy:
        flags.append("Proxy")
    if hosting:
        flags.append("Hosting")
    
    if flags:
        print(f"Flags: {', '.join(flags)}")
    
except Exception as e:
    print(f"Error parsing GeoIP data: {e}")
    print("Raw data:", '''$result'''[:200])
    sys.exit(1)
PYTHON
}

# Get compact GeoIP info (one line)
nftban_geoip_get_compact() {
    local ip="$1"
    
    local result
    result=$(nftban_geoip_lookup "$ip")
    
    if ! command -v python3 &>/dev/null; then
        echo "GeoIP_Unavailable"
        return 0
    fi
    
    python3 << PYTHON
import json
try:
    data = json.loads('''$result''')
    
    if 'error' in data or (data.get('status') == 'fail'):
        print("GeoIP_Failed")
    elif data.get('status') == 'disabled':
        print("GeoIP_Disabled")
    else:
        country = data.get('country', data.get('country_name', 'Unknown'))
        city = data.get('city', 'Unknown')
        isp = data.get('isp', data.get('org', ''))[:30]
        
        result = f"{country}/{city}"
        if isp:
            result += f"/{isp}"
        
        # Replace spaces with underscores for single-word output
        print(result.replace(' ', '_'))
except:
    print("GeoIP_Error")
PYTHON
}

# =============================================================================
# BATCH LOOKUP
# =============================================================================

# Lookup multiple IPs
nftban_geoip_bulk_lookup() {
    local ip_file="$1"
    
    if [[ ! -f "$ip_file" ]]; then
        nftban_log_error "IP file not found: $ip_file"
        return 1
    fi
    
    nftban_log_info "Starting bulk GeoIP lookup..."
    
    local total=0
    local success=0
    local failed=0
    
    while IFS= read -r ip; do
        [[ -z "$ip" || "$ip" =~ ^# ]] && continue
        
        ((total++))
        
        echo ""
        echo "Lookup $total: $ip"
        echo "-----------------------------------"
        
        if nftban_geoip_get_formatted "$ip"; then
            ((success++))
        else
            ((failed++))
        fi
        
        # Small delay to avoid rate limiting
        sleep 0.5
    done < "$ip_file"
    
    echo ""
    echo "======================================================="
    echo "Bulk Lookup Summary:"
    echo "  Total: $total"
    echo "  Success: $success"
    echo "  Failed: $failed"
    echo "======================================================="
}

# =============================================================================
# STATISTICS
# =============================================================================

# Show GeoIP statistics
nftban_geoip_stats() {
    echo ""
    echo "======================================================="
    echo "  GeoIP Lookup Statistics"
    echo "======================================================="
    echo ""
    
    local enabled
    enabled=$(nftban_get_config "NFTBAN_GEOIP_ENABLE" "true")
    echo "Status: $enabled"
    echo ""
    
    # Cache statistics
    if [[ -d "$NFTBAN_GEOIP_CACHE_DIR" ]]; then
        local cached_count
        cached_count=$(find "$NFTBAN_GEOIP_CACHE_DIR" -name "*.json" -type f 2>/dev/null | wc -l)
        echo "Cached Entries: $cached_count"
        
        if [[ $cached_count -gt 0 ]]; then
            local oldest newest
            oldest=$(find "$NFTBAN_GEOIP_CACHE_DIR" -name "*.json" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -1 | cut -d' ' -f1)
            newest=$(find "$NFTBAN_GEOIP_CACHE_DIR" -name "*.json" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f1)
            
            if [[ -n "$oldest" ]]; then
                local oldest_age=$(( $(date +%s) - ${oldest%.*} ))
                echo "Oldest Cache: $(( oldest_age / 3600 )) hours ago"
            fi
        fi
    fi
    echo ""
    
    # Lookup statistics from log
    if [[ -f "$NFTBAN_GEOIP_LOG" ]]; then
        echo "Recent Lookups (last 100):"
        local total_lookups success_lookups failed_lookups
        total_lookups=$(tail -100 "$NFTBAN_GEOIP_LOG" | wc -l)
        success_lookups=$(tail -100 "$NFTBAN_GEOIP_LOG" | grep -c "SUCCESS")
        failed_lookups=$(tail -100 "$NFTBAN_GEOIP_LOG" | grep -c "FAILED")
        
        echo "  Total: $total_lookups"
        echo "  Success: $success_lookups"
        echo "  Failed: $failed_lookups"
        
        if [[ $total_lookups -gt 0 ]]; then
            local success_rate=$(( success_lookups * 100 / total_lookups ))
            echo "  Success Rate: ${success_rate}%"
        fi
        echo ""
        
        echo "Provider Usage (last 100):"
        tail -100 "$NFTBAN_GEOIP_LOG" | awk -F'|' '{print $2}' | sed 's/^ *//;s/ *$//' | sort | uniq -c | sort -rn | while read -r count provider; do
            printf "  %-20s %3d lookups\n" "$provider" "$count"
        done
    fi
    
    echo ""
    echo "======================================================="
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_geoip_init
export -f nftban_geoip_lookup
export -f nftban_geoip_get_formatted
export -f nftban_geoip_get_compact
export -f nftban_geoip_bulk_lookup
export -f nftban_geoip_clear_cache
export -f nftban_geoip_stats

# Auto-initialize
nftban_geoip_init

nftban_log_debug "NFTBan GeoIP Lookup Integration Module loaded"
