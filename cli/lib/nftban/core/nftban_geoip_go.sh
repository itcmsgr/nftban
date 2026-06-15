#!/usr/bin/env bash
# =============================================================================
# NFTBan - GO GeoIP Wrapper Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Wrapper for nftban-geoip GO binary
#
# meta:name="nftban_geoip_go"
# meta:type="core"
# meta:header="GO GeoIP Wrapper"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# **Description & Purpose**
# meta:description="Fast microsecond GeoIP lookups using GO binary with MaxMind GeoLite2"
# meta:input="IP addresses for geolocation lookup"
# meta:output="Country codes and geographic information"
#
# **Inventory & Requirements**
# meta:depends="nftban-core,dbip-country-lite.mmdb"
# meta:inventory.files="/usr/lib/nftban/bin/nftban-core"
# meta:inventory.binaries="nftban-core"
# meta:inventory.env_vars="NFTBAN_CORE_BIN,NFTBAN_GEOIP_TIMEOUT"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# meta:created_date="2025-11-05"
# meta:updated_date="2025-11-24"
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_GEOIP_GO_LOADED:-}" ]] && return 0
readonly NFTBAN_GEOIP_GO_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================
# GeoIP is a subcommand of nftban-core (same pattern as cmd_geoip.sh)
readonly NFTBAN_CORE_BIN="${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core}"
readonly NFTBAN_GEOIP_TIMEOUT="${NFTBAN_GEOIP_TIMEOUT:-5}"  # seconds

# =============================================================================
# CORE FUNCTIONS
# =============================================================================

nftban_geoip_check_available() {
    # Check if nftban-core geoip is available
    # Returns: 0 if available, 1 if not

    if [[ ! -x "$NFTBAN_CORE_BIN" ]]; then
        return 1
    fi

    # Check if database exists via geoip status
    if ! timeout "$NFTBAN_GEOIP_TIMEOUT" "$NFTBAN_CORE_BIN" geoip status &>/dev/null; then
        return 1
    fi

    return 0
}

nftban_geoip_lookup_fast() {
    # Fast IP geolocation lookup using GO binary
    # Args: $1 = IP address
    # Returns: JSON with geo data
    # Speed: 50-200 microseconds

    local ip="$1"

    if [[ -z "$ip" ]]; then
        echo '{"error":"IP address required"}'
        return 1
    fi

    # Validate IP format (basic)
    if [[ ! "$ip" =~ ^[0-9a-fA-F:.]+$ ]]; then
        echo '{"error":"Invalid IP format"}'
        return 1
    fi

    # Call nftban-core geoip lookup with timeout
    local result
    result=$(timeout "$NFTBAN_GEOIP_TIMEOUT" "$NFTBAN_CORE_BIN" geoip lookup "$ip" --json 2>/dev/null)

    if [[ $? -eq 0 && -n "$result" ]]; then
        echo "$result"
        return 0
    else
        echo '{"error":"Lookup failed or timed out"}'
        return 1
    fi
}

nftban_geoip_get_country() {
    # Get country name from IP
    # Args: $1 = IP address
    # Returns: Country name or "Unknown"

    local ip="$1"
    local json

    json=$(nftban_geoip_lookup_fast "$ip" 2>/dev/null)

    if command -v jq &>/dev/null; then
        echo "$json" | jq -r '.country // "Unknown"' 2>/dev/null || echo "Unknown"
    else
        # Fallback without jq
        echo "$json" | grep -o '"country":"[^"]*"' | cut -d'"' -f4 | head -1 || echo "Unknown"
    fi
}

nftban_geoip_get_country_code() {
    # Get country code from IP
    # Args: $1 = IP address
    # Returns: Country code (e.g., "US", "CN") or "??"

    local ip="$1"
    local json

    json=$(nftban_geoip_lookup_fast "$ip" 2>/dev/null)

    if command -v jq &>/dev/null; then
        echo "$json" | jq -r '.country_code // "??"' 2>/dev/null || echo "??"
    else
        # Fallback without jq
        echo "$json" | grep -o '"country_code":"[^"]*"' | cut -d'"' -f4 | head -1 || echo "??"
    fi
}

nftban_geoip_get_city() {
    # Get city name from IP
    # Args: $1 = IP address
    # Returns: City name or "Unknown"

    local ip="$1"
    local json

    json=$(nftban_geoip_lookup_fast "$ip" 2>/dev/null)

    if command -v jq &>/dev/null; then
        echo "$json" | jq -r '.city // "Unknown"' 2>/dev/null || echo "Unknown"
    else
        # Fallback without jq
        echo "$json" | grep -o '"city":"[^"]*"' | cut -d'"' -f4 | head -1 || echo "Unknown"
    fi
}

nftban_geoip_get_compact() {
    # Get compact geo info: Country/City
    # Args: $1 = IP address
    # Returns: "Country/City" with spaces replaced by underscores

    local ip="$1"
    local json

    json=$(nftban_geoip_lookup_fast "$ip" 2>/dev/null)

    local country city

    if command -v jq &>/dev/null; then
        country=$(echo "$json" | jq -r '.country // "Unknown"' 2>/dev/null || echo "Unknown")
        city=$(echo "$json" | jq -r '.city // "Unknown"' 2>/dev/null || echo "Unknown")
    else
        # Fallback without jq
        country=$(echo "$json" | grep -o '"country":"[^"]*"' | cut -d'"' -f4 | head -1 || echo "Unknown")
        city=$(echo "$json" | grep -o '"city":"[^"]*"' | cut -d'"' -f4 | head -1 || echo "Unknown")
    fi

    echo "${country}/${city}" | tr ' ' '_'
}

nftban_geoip_get_compact_full() {
    # Get full compact geo info: CountryCode/City/Timezone
    # Args: $1 = IP address
    # Returns: "CC/City/Timezone" with spaces replaced by underscores

    local ip="$1"
    local json

    json=$(nftban_geoip_lookup_fast "$ip" 2>/dev/null)

    local country_code city timezone

    if command -v jq &>/dev/null; then
        country_code=$(echo "$json" | jq -r '.country_code // "??"' 2>/dev/null || echo "??")
        city=$(echo "$json" | jq -r '.city // "Unknown"' 2>/dev/null || echo "Unknown")
        timezone=$(echo "$json" | jq -r '.timezone // ""' 2>/dev/null || echo "")
    else
        # Fallback without jq
        country_code=$(echo "$json" | grep -o '"country_code":"[^"]*"' | cut -d'"' -f4 | head -1 || echo "??")
        city=$(echo "$json" | grep -o '"city":"[^"]*"' | cut -d'"' -f4 | head -1 || echo "Unknown")
        timezone=$(echo "$json" | grep -o '"timezone":"[^"]*"' | cut -d'"' -f4 | head -1 || echo "")
    fi

    if [[ -n "$timezone" ]]; then
        echo "${country_code}/${city}/${timezone}" | tr ' ' '_'
    else
        echo "${country_code}/${city}" | tr ' ' '_'
    fi
}

nftban_geoip_bulk_lookup() {
    # Bulk lookup from file or stdin
    # Args: $1 = input file (optional, uses stdin if not provided)
    # Returns: One result per line (CC/Country format)
    # Note: nftban-core geoip does not have bulk command, process line by line

    local input_file="${1:-}"
    local ip

    if [[ -n "$input_file" && -f "$input_file" ]]; then
        while IFS= read -r ip || [[ -n "$ip" ]]; do
            [[ -z "$ip" || "$ip" =~ ^# ]] && continue
            timeout "$NFTBAN_GEOIP_TIMEOUT" "$NFTBAN_CORE_BIN" geoip lookup "$ip" 2>/dev/null || echo "??/Unknown"
        done < "$input_file"
    else
        while IFS= read -r ip || [[ -n "$ip" ]]; do
            [[ -z "$ip" || "$ip" =~ ^# ]] && continue
            timeout "$NFTBAN_GEOIP_TIMEOUT" "$NFTBAN_CORE_BIN" geoip lookup "$ip" 2>/dev/null || echo "??/Unknown"
        done
    fi
}

nftban_geoip_status() {
    # Get GeoIP system status
    # Returns: Status output from nftban-core geoip status

    timeout "$NFTBAN_GEOIP_TIMEOUT" "$NFTBAN_CORE_BIN" geoip status 2>/dev/null || echo '{"status":"error","message":"nftban-core geoip not available"}'
}

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================

nftban_geoip_format_for_log() {
    # Format geo data for log entry: [CC/City]
    # Args: $1 = IP address
    # Returns: "[CC/City]" or "[??/Unknown]" if lookup fails

    local ip="$1"
    local compact

    compact=$(nftban_geoip_get_compact_full "$ip" 2>/dev/null)

    if [[ -n "$compact" && "$compact" != "Unknown/Unknown" ]]; then
        echo "[$compact]"
    else
        echo "[??/Unknown]"
    fi
}

nftban_geoip_is_local_ip() {
    # Check if IP is local/private
    # Args: $1 = IP address
    # Returns: 0 if local, 1 if public

    local ip="$1"

    # Check for private IPv4 ranges
    if [[ "$ip" =~ ^10\. ]] || \
       [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[01])\. ]] || \
       [[ "$ip" =~ ^192\.168\. ]] || \
       [[ "$ip" =~ ^127\. ]] || \
       [[ "$ip" =~ ^169\.254\. ]]; then
        return 0
    fi

    # Check for private IPv6 ranges
    if [[ "$ip" =~ ^fe80: ]] || \
       [[ "$ip" =~ ^fc00: ]] || \
       [[ "$ip" =~ ^fd00: ]] || \
       [[ "$ip" == "::1" ]]; then
        return 0
    fi

    return 1
}

# =============================================================================
# EXPORTS
# =============================================================================

# Export functions for use by other modules
export -f nftban_geoip_check_available
export -f nftban_geoip_lookup_fast
export -f nftban_geoip_get_country
export -f nftban_geoip_get_country_code
export -f nftban_geoip_get_city
export -f nftban_geoip_get_compact
export -f nftban_geoip_get_compact_full
export -f nftban_geoip_bulk_lookup
export -f nftban_geoip_status
export -f nftban_geoip_format_for_log
export -f nftban_geoip_is_local_ip

# Log module load
if declare -f nftban_log_debug >/dev/null 2>&1; then
    nftban_log_debug "GO GeoIP wrapper module loaded (fast microsecond lookups)"
fi
