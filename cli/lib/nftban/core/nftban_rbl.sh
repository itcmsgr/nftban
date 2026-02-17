#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - RBL Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Real-time Blackhole List (RBL) checking core logic
#
# meta:name="nftban_rbl"
# meta:type="core"
# meta:header="RBL Core Logic"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="RBL checking against 40+ DNS blackhole lists"
# meta:input="IP addresses, RBL configuration"
# meta:output="Blacklist status, cached results, alerts"
# meta:depends="bash>=4.0, dig, host"
# meta:created_date="2025-12-31"
# meta:updated_date="2026-01-13"
#
# meta:inventory.files=""
# meta:inventory.binaries="dig, host, mail"
# meta:inventory.env_vars="NFTBAN_RBL_ENABLED, NFTBAN_RBL_TIMEOUT, NFTBAN_RBL_PARALLEL_JOBS"
# meta:inventory.config_files="/etc/nftban/conf.d/rbl/main.conf, /etc/nftban/conf.d/rbl/rbls.conf, /etc/nftban/conf.d/rbl/watchlist.conf"
# meta:inventory.systemd_units="nftban-rbl-check.timer"
# meta:inventory.network="DNS queries (port 53/udp)"
# meta:inventory.privileges="none"
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_RBL_CORE_LOADED:-}" ]] && return 0
readonly NFTBAN_RBL_CORE_LOADED=1

# =============================================================================
# LOAD SHARED LIBRARIES
# =============================================================================

# Determine library path
_NFTBAN_RBL_LIB_DIR="${NFTBAN_LIB_DIR:-/usr/lib/nftban}"

# Load timestamp library (for nftban_timestamp, nftban_timestamp_unix)
if [[ -f "${_NFTBAN_RBL_LIB_DIR}/lib/nftban_timestamp.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_NFTBAN_RBL_LIB_DIR}/lib/nftban_timestamp.sh"
fi

# Load file utilities library (for nftban_file_age, nftban_file_mtime, nftban_file_is_stale)
if [[ -f "${_NFTBAN_RBL_LIB_DIR}/lib/nftban_file_utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_NFTBAN_RBL_LIB_DIR}/lib/nftban_file_utils.sh"
fi

# Load alert throttle library (for nftban_should_alert)
if [[ -f "${_NFTBAN_RBL_LIB_DIR}/lib/nftban_alert_throttle.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_NFTBAN_RBL_LIB_DIR}/lib/nftban_alert_throttle.sh"
fi

# Load configuration
[[ -z "${NFTBAN_CONFIG_DIR:-}" ]] && readonly NFTBAN_CONFIG_DIR="/etc/nftban"
[[ -z "${NFTBAN_LOG_DIR:-}" ]] && readonly NFTBAN_LOG_DIR="/var/log/nftban"

# Load RBL configuration (package defaults)
if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/rbl/main.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/conf.d/rbl/main.conf"
fi

# Load user overrides (takes precedence over defaults)
if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/rbl/main.conf.local" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/conf.d/rbl/main.conf.local"
fi

# Set defaults if not configured
: "${NFTBAN_RBL_ENABLED:=NO}"
: "${NFTBAN_RBL_TIMEOUT:=4}"
: "${NFTBAN_RBL_CACHE_TTL:=24}"
: "${NFTBAN_RBL_AUTO_DISCOVER_IPS:=YES}"
: "${NFTBAN_RBL_CHECK_IPV6:=YES}"
: "${NFTBAN_RBL_CACHE_DIR:=${NFTBAN_LOG_DIR}/rbl}"
: "${NFTBAN_RBL_PROVIDERS_FILE:=${NFTBAN_CONFIG_DIR}/conf.d/rbl/rbls.conf}"
: "${NFTBAN_RBL_CUSTOM_FILE:=${NFTBAN_CONFIG_DIR}/conf.d/rbl/custom.conf}"
: "${NFTBAN_RBL_WATCHLIST_FILE:=${NFTBAN_CONFIG_DIR}/conf.d/rbl/watchlist.conf}"
: "${NFTBAN_RBL_ALERT_ON_NEW_LISTING:=YES}"
: "${NFTBAN_RBL_PARALLEL_JOBS:=10}"

# =============================================================================
# IP DISCOVERY FUNCTIONS
# =============================================================================

nftban_rbl_get_public_ips() {
    # Auto-discover public IPs from network interfaces
    # Output: One IP per line

    local ips=()

    # Get all IPv4 addresses from interfaces (excluding loopback)
    while IFS= read -r ip; do
        if nftban_rbl_is_public_ip "$ip"; then
            ips+=("$ip")
        fi
    done < <(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.')

    # Get all IPv6 addresses if enabled (excluding link-local and loopback)
    if [[ "${NFTBAN_RBL_CHECK_IPV6:-YES}" == "YES" ]]; then
        while IFS= read -r ip; do
            if nftban_rbl_is_public_ip "$ip"; then
                ips+=("$ip")
            fi
        done < <(ip -6 addr show | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^::1' | grep -v '^fe80:')
    fi

    # Remove duplicates and output
    printf '%s\n' "${ips[@]}" | sort -u
}

nftban_rbl_get_critical_ips() {
    # Get critical IPs from configuration
    # Format: NFTBAN_RBL_CRITICAL_IPS="1.2.3.4:mail,5.6.7.8:web"
    # Output: IP:tag (one per line)

    if [[ -z "${NFTBAN_RBL_CRITICAL_IPS:-}" ]]; then
        return 0
    fi

    # Split by comma and output
    echo "$NFTBAN_RBL_CRITICAL_IPS" | tr ',' '\n' | grep -v '^$'
}

nftban_rbl_is_public_ip() {
    # Check if IP is public (not private/loopback)
    # Args: $1 = IP address (IPv4 or IPv6)
    # Return: 0 if public, 1 if private

    local ip="$1"

    # IPv4 private ranges
    if [[ "$ip" =~ ^10\. ]] ||              # 10.0.0.0/8
       [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] ||  # 172.16.0.0/12
       [[ "$ip" =~ ^192\.168\. ]] ||        # 192.168.0.0/16
       [[ "$ip" =~ ^127\. ]] ||             # 127.0.0.0/8 (loopback)
       [[ "$ip" =~ ^169\.254\. ]]; then     # 169.254.0.0/16 (link-local)
        return 1
    fi

    # IPv6 private/special ranges
    if [[ "$ip" =~ ^::1$ ]] ||              # Loopback
       [[ "$ip" =~ ^fe80: ]] ||             # Link-local
       [[ "$ip" =~ ^fc00: ]] ||             # Unique local (ULA)
       [[ "$ip" =~ ^fd00: ]]; then          # Unique local (ULA)
        return 1
    fi

    return 0
}

nftban_rbl_reverse_ip() {
    # Reverse IP address for DNS lookup
    # Args: $1 = IP address (IPv4 or IPv6)
    # Output: Reversed IP for RBL query

    local ip="$1"

    # Detect IPv4 vs IPv6
    if [[ "$ip" =~ : ]]; then
        # IPv6: Use nibble format with .ip6.arpa
        # Note: Most RBLs don't support IPv6 yet, but we prepare for it
        # Example: 2001:db8::1 -> 1.0.0.0...8.b.d.0.1.0.0.2.ip6.arpa

        # Expand IPv6 to full form first (simplified approach)
        # For production, would use 'sipcalc' or similar tool
        # For now, just return the compressed form (most RBLs won't accept it anyway)
        echo "$ip"  # Placeholder - full IPv6 reverse is complex
    else
        # IPv4: Simple octet reversal
        echo "$ip" | awk -F. '{print $4"."$3"."$2"."$1}'
    fi
}

# =============================================================================
# WATCHLIST FUNCTIONS
# =============================================================================

nftban_rbl_watchlist_get() {
    # Get all watchlist entries
    # Output: IP|description|tags|notify_email (one per line)

    local watchlist_file="${NFTBAN_RBL_WATCHLIST_FILE}"

    if [[ ! -f "$watchlist_file" ]]; then
        return 0
    fi

    # Read entries, skip comments and empty lines
    grep -v '^#' "$watchlist_file" 2>/dev/null | grep -v '^$' | grep '|'
}

nftban_rbl_watchlist_add() {
    # Add IP to watchlist
    # Args: $1 = IP address
    #       $2 = description (optional)
    #       $3 = tags (optional, comma-separated)
    #       $4 = notify_email (optional)

    local ip="$1"
    local description="${2:-}"
    local tags="${3:-}"
    local notify_email="${4:-}"
    local watchlist_file="${NFTBAN_RBL_WATCHLIST_FILE}"

    # Validate IP format
    if ! [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
       ! [[ "$ip" =~ ^[0-9a-fA-F:]+$ ]]; then
        echo "Error: Invalid IP address format: $ip" >&2
        return 1
    fi

    # Check if already exists
    if grep -q "^${ip}|" "$watchlist_file" 2>/dev/null; then
        echo "Error: IP $ip already in watchlist" >&2
        return 1
    fi

    # Sanitize description (remove pipes)
    description="${description//|/-}"

    # Add entry
    echo "${ip}|${description}|${tags}|${notify_email}" >> "$watchlist_file"

    echo "Added to watchlist: $ip"
    [[ -n "$description" ]] && echo "  Description: $description"
    [[ -n "$tags" ]] && echo "  Tags: $tags"
    return 0
}

nftban_rbl_watchlist_remove() {
    # Remove IP from watchlist
    # Args: $1 = IP address

    local ip="$1"
    local watchlist_file="${NFTBAN_RBL_WATCHLIST_FILE}"

    if [[ ! -f "$watchlist_file" ]]; then
        echo "Error: Watchlist file not found" >&2
        return 1
    fi

    # Check if exists
    if ! grep -q "^${ip}|" "$watchlist_file" 2>/dev/null; then
        echo "Error: IP $ip not found in watchlist" >&2
        return 1
    fi

    # Remove entry
    grep -v "^${ip}|" "$watchlist_file" > "${watchlist_file}.tmp"
    mv "${watchlist_file}.tmp" "$watchlist_file"

    echo "Removed from watchlist: $ip"
    return 0
}

nftban_rbl_watchlist_list() {
    # List all watchlist entries in formatted output
    # Args: $1 = format (text|json)

    local format="${1:-text}"
    local count=0

    if [[ "$format" == "json" ]]; then
        echo "["
        local first=1
        while IFS='|' read -r ip description tags notify_email; do
            [[ -z "$ip" ]] && continue
            [[ $first -eq 0 ]] && echo ","
            echo "  {"
            echo "    \"ip\": \"$ip\","
            echo "    \"description\": \"${description:-}\","
            echo "    \"tags\": \"${tags:-}\","
            echo "    \"notify_email\": \"${notify_email:-}\""
            echo -n "  }"
            first=0
            ((count++))
        done < <(nftban_rbl_watchlist_get)
        echo ""
        echo "]"
    else
        echo "RBL Watchlist"
        echo "─────────────────────────────────────────────────────────"

        while IFS='|' read -r ip description tags notify_email; do
            [[ -z "$ip" ]] && continue
            ((count++))
            printf "%d. %-18s" "$count" "$ip"
            [[ -n "$description" ]] && printf "  %s" "$description"
            echo ""
            [[ -n "$tags" ]] && echo "   Tags: $tags"
            [[ -n "$notify_email" ]] && echo "   Notify: $notify_email"
        done < <(nftban_rbl_watchlist_get)

        if [[ $count -eq 0 ]]; then
            echo "(No IPs in watchlist)"
            echo ""
            echo "Add IPs with: nftban rbl watchlist add <IP> [description]"
        fi

        echo "─────────────────────────────────────────────────────────"
        echo "Total: $count watched IP(s)"
    fi
}

# =============================================================================
# PARALLEL DNS FUNCTIONS
# =============================================================================

nftban_rbl_check_ip_parallel() {
    # Check single IP against all RBL providers using parallel DNS queries
    # Args: $1 = IP address
    #       $2 = output format (text|json)
    # Output: RBL check results (much faster than sequential)

    local ip="$1"
    local format="${2:-text}"
    local reversed_ip
    local temp_dir
    local jobs="${NFTBAN_RBL_PARALLEL_JOBS:-10}"

    reversed_ip=$(nftban_rbl_reverse_ip "$ip")
    temp_dir=$(mktemp -d)

    # Create list of RBL checks to run
    local rbl_list=()
    while IFS=: read -r rbl_domain rbl_url; do
        rbl_list+=("${rbl_domain}:${rbl_url}")
    done < <(nftban_rbl_load_providers)

    # Run DNS lookups in parallel using background jobs
    local pids=()
    local job_count=0

    for rbl_entry in "${rbl_list[@]}"; do
        local rbl_domain="${rbl_entry%%:*}"
        local rbl_url="${rbl_entry#*:}"

        # Run lookup in background, write result to temp file
        (
            local result
            local txt_record=""
            result=$(nftban_rbl_dns_lookup "$reversed_ip" "$rbl_domain")

            if [[ "$result" == "LISTED" ]]; then
                txt_record=$(nftban_rbl_get_txt_record "$reversed_ip" "$rbl_domain")
            fi

            echo "${result}|${rbl_domain}|${rbl_url}|${txt_record}" > "${temp_dir}/${rbl_domain}.result"
        ) &

        pids+=($!)
        job_count=$((job_count + 1))

        # Limit concurrent jobs
        if [[ $job_count -ge $jobs ]]; then
            wait "${pids[0]}"
            pids=("${pids[@]:1}")
            ((job_count--))
        fi
    done

    # Wait for all remaining jobs
    wait

    # Collect results
    local listed_count=0
    local clean_count=0
    local timeout_count=0

    if [[ "$format" == "json" ]]; then
        echo "{"
        echo "  \"ip\": \"$ip\","
        echo "  \"checks\": ["
    else
        echo "RBL Check Results for: $ip"
        echo "─────────────────────────────────────────────────────────"
    fi

    local first=1
    for result_file in "${temp_dir}"/*.result; do
        [[ ! -f "$result_file" ]] && continue

        IFS='|' read -r result rbl_domain rbl_url txt_record < "$result_file"

        if [[ "$result" == "LISTED" ]]; then
            ((listed_count++))

            if [[ "$format" == "json" ]]; then
                [[ $first -eq 0 ]] && echo ","
                echo "    {"
                echo "      \"rbl\": \"$rbl_domain\","
                echo "      \"status\": \"listed\","
                echo "      \"reason\": \"$txt_record\","
                echo "      \"url\": \"$rbl_url\""
                echo -n "    }"
                first=0
            else
                echo "❌ LISTED: $rbl_domain"
                [[ -n "$txt_record" ]] && echo "   Reason: $txt_record"
                echo "   Info: $rbl_url"
            fi
        elif [[ "$result" == "TIMEOUT" ]]; then
            ((timeout_count++))

            if [[ "$format" == "json" ]]; then
                [[ $first -eq 0 ]] && echo ","
                echo "    {"
                echo "      \"rbl\": \"$rbl_domain\","
                echo "      \"status\": \"timeout\","
                echo "      \"url\": \"$rbl_url\""
                echo -n "    }"
                first=0
            else
                echo "⏱️  TIMEOUT: $rbl_domain"
            fi
        else
            ((clean_count++))

            if [[ "$format" == "text" ]] && [[ "${NFTBAN_RBL_VERBOSE:-NO}" == "YES" ]]; then
                echo "✅ CLEAN: $rbl_domain"
            fi
        fi
    done

    # Cleanup temp dir
    rm -rf "$temp_dir"

    if [[ "$format" == "json" ]]; then
        echo ""
        echo "  ],"
        echo "  \"summary\": {"
        echo "    \"listed\": $listed_count,"
        echo "    \"clean\": $clean_count,"
        echo "    \"timeout\": $timeout_count"
        echo "  }"
        echo "}"
    else
        echo "─────────────────────────────────────────────────────────"
        echo "Summary:"
        echo "  Listed: $listed_count"
        echo "  Clean: $clean_count"
        echo "  Timeout: $timeout_count"
    fi

    # Return 1 if any listings found
    [[ $listed_count -gt 0 ]] && return 1
    return 0
}

# =============================================================================
# RBL PROVIDER FUNCTIONS
# =============================================================================

nftban_rbl_load_providers() {
    # Load RBL providers from configuration files
    # Output: domain:url (one per line)

    local providers=()
    local disabled_rbls=()
    local enabled_rbls=()

    # Load custom disable/enable list first
    if [[ -f "$NFTBAN_RBL_CUSTOM_FILE" ]]; then
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ "$line" =~ ^#.*$ ]] && continue
            [[ -z "$line" ]] && continue

            if [[ "$line" =~ ^disablerbl:(.*)$ ]]; then
                disabled_rbls+=("${BASH_REMATCH[1]}")
            elif [[ "$line" =~ ^enablerbl:(.*)$ ]]; then
                enabled_rbls+=("${BASH_REMATCH[1]}")
            fi
        done < "$NFTBAN_RBL_CUSTOM_FILE"
    fi

    # Load main RBL list
    if [[ -f "$NFTBAN_RBL_PROVIDERS_FILE" ]]; then
        while IFS= read -r line; do
            # Skip comments and empty lines
            [[ "$line" =~ ^#.*$ ]] && continue
            [[ -z "$line" ]] && continue

            # Extract domain (before colon)
            local domain="${line%%:*}"

            # Check if disabled
            local is_disabled=0
            for disabled in "${disabled_rbls[@]:-}"; do
                if [[ "$domain" == "$disabled" ]]; then
                    is_disabled=1
                    break
                fi
            done

            if [[ $is_disabled -eq 0 ]]; then
                providers+=("$line")
            fi
        done < "$NFTBAN_RBL_PROVIDERS_FILE"
    fi

    # Add enabled custom RBLs
    for enabled in "${enabled_rbls[@]:-}"; do
        providers+=("$enabled")
    done

    # Output unique providers
    printf '%s\n' "${providers[@]}" | sort -u
}

# =============================================================================
# DNS LOOKUP FUNCTIONS
# =============================================================================

nftban_rbl_check_ip() {
    # Check single IP against all RBL providers
    # Args: $1 = IP address
    #       $2 = output format (text|json)
    # Output: RBL check results

    local ip="$1"
    local format="${2:-text}"
    local reversed_ip
    # shellcheck disable=SC2034  # Reserved for detailed RBL results
    local results=()
    local listed_count=0
    local clean_count=0
    local timeout_count=0

    reversed_ip=$(nftban_rbl_reverse_ip "$ip")

    if [[ "$format" == "json" ]]; then
        echo "{"
        echo "  \"ip\": \"$ip\","
        echo "  \"checks\": ["
    else
        echo "RBL Check Results for: $ip"
        echo "─────────────────────────────────────────────────────────"
    fi

    local first=1
    while IFS=: read -r rbl_domain rbl_url; do
        local result
        local txt_record

        result=$(nftban_rbl_dns_lookup "$reversed_ip" "$rbl_domain")

        if [[ "$result" == "LISTED" ]]; then
            txt_record=$(nftban_rbl_get_txt_record "$reversed_ip" "$rbl_domain")
            ((listed_count++))

            if [[ "$format" == "json" ]]; then
                [[ $first -eq 0 ]] && echo ","
                echo "    {"
                echo "      \"rbl\": \"$rbl_domain\","
                echo "      \"status\": \"listed\","
                echo "      \"reason\": \"$txt_record\","
                echo "      \"url\": \"$rbl_url\""
                echo -n "    }"
                first=0
            else
                echo "❌ LISTED: $rbl_domain"
                [[ -n "$txt_record" ]] && echo "   Reason: $txt_record"
                echo "   Info: $rbl_url"
            fi
        elif [[ "$result" == "TIMEOUT" ]]; then
            ((timeout_count++))

            if [[ "$format" == "json" ]]; then
                [[ $first -eq 0 ]] && echo ","
                echo "    {"
                echo "      \"rbl\": \"$rbl_domain\","
                echo "      \"status\": \"timeout\","
                echo "      \"url\": \"$rbl_url\""
                echo -n "    }"
                first=0
            else
                echo "⏱️  TIMEOUT: $rbl_domain"
            fi
        else
            ((clean_count++))

            if [[ "$format" == "text" ]] && [[ "${NFTBAN_RBL_VERBOSE:-NO}" == "YES" ]]; then
                echo "✅ CLEAN: $rbl_domain"
            fi
        fi
    done < <(nftban_rbl_load_providers)

    if [[ "$format" == "json" ]]; then
        echo ""
        echo "  ],"
        echo "  \"summary\": {"
        echo "    \"listed\": $listed_count,"
        echo "    \"clean\": $clean_count,"
        echo "    \"timeout\": $timeout_count"
        echo "  }"
        echo "}"
    else
        echo "─────────────────────────────────────────────────────────"
        echo "Summary:"
        echo "  Listed: $listed_count"
        echo "  Clean: $clean_count"
        echo "  Timeout: $timeout_count"
    fi
}

nftban_rbl_dns_lookup() {
    # Perform DNS A record lookup for RBL
    # Args: $1 = reversed IP (4.3.2.1)
    #       $2 = RBL domain (zen.spamhaus.org)
    # Output: LISTED, CLEAN, or TIMEOUT

    local reversed_ip="$1"
    local rbl_domain="$2"
    local lookup_host="${reversed_ip}.${rbl_domain}"
    local timeout="${NFTBAN_RBL_TIMEOUT:-4}"

    # Perform DNS lookup with timeout
    if timeout "$timeout" host -t A "$lookup_host" &>/dev/null; then
        echo "LISTED"
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            echo "TIMEOUT"
        else
            echo "CLEAN"
        fi
    fi
}

nftban_rbl_get_txt_record() {
    # Get TXT record for listed IP (reason/description)
    # Args: $1 = reversed IP (4.3.2.1)
    #       $2 = RBL domain
    # Output: TXT record content (or empty)

    local reversed_ip="$1"
    local rbl_domain="$2"
    local lookup_host="${reversed_ip}.${rbl_domain}"
    local timeout="${NFTBAN_RBL_TIMEOUT:-4}"

    # Get TXT record
    timeout "$timeout" host -t TXT "$lookup_host" 2>/dev/null | \
        grep -oP '(?<=").*(?=")' | \
        head -n1 || echo ""
}

# =============================================================================
# CACHE FUNCTIONS
# =============================================================================

nftban_rbl_cache_get() {
    # Get cached RBL results for IP
    # Args: $1 = IP address
    # Return: 0 if valid cache exists, 1 otherwise
    # Output: Cache file path if valid

    local ip="$1"
    local cache_file="${NFTBAN_RBL_CACHE_DIR}/${ip}.cache"
    local cache_ttl_seconds=$((NFTBAN_RBL_CACHE_TTL * 3600))

    if [[ ! -f "$cache_file" ]]; then
        return 1
    fi

    # Check if cache expired
    local cache_age=$(($(date +%s) - $(stat -c %Y "$cache_file" 2>/dev/null || echo 0)))
    if [[ $cache_age -gt $cache_ttl_seconds ]]; then
        return 1
    fi

    echo "$cache_file"
    return 0
}

nftban_rbl_cache_set() {
    # Cache RBL results for IP
    # Args: $1 = IP address
    #       stdin = check results

    local ip="$1"
    local cache_file="${NFTBAN_RBL_CACHE_DIR}/${ip}.cache"

    # Create cache directory if needed
    mkdir -p "$NFTBAN_RBL_CACHE_DIR"

    # Write cache file
    cat > "$cache_file"

    # Set permissions
    chmod 640 "$cache_file" 2>/dev/null || true
}

nftban_rbl_cache_purge() {
    # Purge RBL cache
    # Args: $1 = IP address (optional, purge all if empty)

    local ip="${1:-}"

    if [[ -n "$ip" ]]; then
        # Purge specific IP
        rm -f "${NFTBAN_RBL_CACHE_DIR}/${ip}.cache"
        echo "Purged cache for: $ip"
    else
        # Purge all
        rm -f "${NFTBAN_RBL_CACHE_DIR}"/*.cache 2>/dev/null || true
        echo "Purged all RBL cache files"
    fi
}

nftban_rbl_cache_expired() {
    # Check if cache is expired
    # Args: $1 = IP address
    # Return: 0 if expired, 1 if valid

    local ip="$1"

    if nftban_rbl_cache_get "$ip" &>/dev/null; then
        return 1  # Valid cache
    else
        return 0  # Expired or missing
    fi
}

# =============================================================================
# ALERT FUNCTIONS
# =============================================================================

nftban_rbl_check_new_listing() {
    # Check if IP has new listing (state transition: clean → listed)
    # Args: $1 = IP address
    #       $2 = current status (listed/clean)
    # Return: 0 if new listing, 1 otherwise

    local ip="$1"
    local current_status="$2"
    local state_file="${NFTBAN_RBL_CACHE_DIR}/state.dat"

    # If currently clean, no alert needed
    if [[ "$current_status" != "listed" ]]; then
        return 1
    fi

    # Check previous state
    if [[ ! -f "$state_file" ]]; then
        # No previous state - this is first check, treat as new
        return 0
    fi

    # Check if IP was already listed (format: IP=status|timestamp|...)
    local prev_status
    prev_status=$(grep "^${ip}=" "$state_file" 2>/dev/null | head -1 | cut -d'|' -f1 | cut -d'=' -f2)

    if [[ "$prev_status" == "listed" ]]; then
        return 1  # Already listed, not new
    fi

    return 0  # New listing (was clean or unknown)
}

nftban_rbl_check_delisting() {
    # Check if IP was delisted (state transition: listed → clean)
    # Args: $1 = IP address
    #       $2 = current status (listed/clean)
    # Return: 0 if delisted, 1 otherwise

    local ip="$1"
    local current_status="$2"
    local state_file="${NFTBAN_RBL_CACHE_DIR}/state.dat"

    # If currently listed, not delisted
    if [[ "$current_status" != "clean" ]]; then
        return 1
    fi

    # Check previous state
    if [[ ! -f "$state_file" ]]; then
        return 1  # No previous state
    fi

    # Check if IP was previously listed
    local prev_status
    prev_status=$(grep "^${ip}=" "$state_file" 2>/dev/null | head -1 | cut -d'|' -f1 | cut -d'=' -f2)

    if [[ "$prev_status" == "listed" ]]; then
        return 0  # Was listed, now clean = DELISTED
    fi

    return 1  # Was not listed before
}

nftban_rbl_update_state() {
    # Update RBL state file (preserves all IP states)
    # Args: $1 = IP address
    #       $2 = status (listed/clean/timeout)
    #
    # State file format: Simple key=value for bash compatibility
    # IP=status|timestamp|previous_status|previous_timestamp
    # This preserves history and supports multi-IP tracking

    local ip="$1"
    local status="$2"
    local state_file="${NFTBAN_RBL_CACHE_DIR}/state.dat"
    local state_json="${NFTBAN_RBL_CACHE_DIR}/state.json"  # JSON view for compatibility
    local timestamp
    timestamp=$(date -Iseconds)

    # Create directory if needed
    mkdir -p "$NFTBAN_RBL_CACHE_DIR"

    # Initialize state file if missing
    [[ ! -f "$state_file" ]] && touch "$state_file"

    # Get previous state for this IP (for history tracking)
    local prev_entry=""
    local prev_status=""
    local prev_timestamp=""
    if [[ -f "$state_file" ]]; then
        prev_entry=$(grep "^${ip}=" "$state_file" 2>/dev/null | head -1)
        if [[ -n "$prev_entry" ]]; then
            prev_status=$(echo "$prev_entry" | cut -d'|' -f1 | cut -d'=' -f2)
            prev_timestamp=$(echo "$prev_entry" | cut -d'|' -f2)
        fi
    fi

    # Remove old entry for this IP
    if [[ -f "$state_file" ]]; then
        grep -v "^${ip}=" "$state_file" > "${state_file}.tmp" 2>/dev/null || true
        mv "${state_file}.tmp" "$state_file"
    fi

    # Add updated entry (format: IP=status|timestamp|prev_status|prev_timestamp)
    echo "${ip}=${status}|${timestamp}|${prev_status}|${prev_timestamp}" >> "$state_file"

    # Generate JSON view for API compatibility
    _nftban_rbl_state_to_json > "$state_json"
}

_nftban_rbl_state_to_json() {
    # Convert state.dat to state.json for API compatibility
    local state_file="${NFTBAN_RBL_CACHE_DIR}/state.dat"

    echo "{"
    local first=1
    while IFS='=' read -r ip data; do
        [[ -z "$ip" ]] && continue
        [[ "$ip" =~ ^# ]] && continue

        local status timestamp prev_status prev_timestamp
        status=$(echo "$data" | cut -d'|' -f1)
        timestamp=$(echo "$data" | cut -d'|' -f2)
        prev_status=$(echo "$data" | cut -d'|' -f3)
        prev_timestamp=$(echo "$data" | cut -d'|' -f4)

        [[ $first -eq 0 ]] && echo ","
        echo "  \"$ip\": {"
        echo "    \"status\": \"$status\","
        echo "    \"timestamp\": \"$timestamp\","
        echo "    \"previous_status\": \"${prev_status:-null}\","
        echo "    \"previous_timestamp\": \"${prev_timestamp:-null}\""
        echo -n "  }"
        first=0
    done < "$state_file"
    echo ""
    echo "}"
}

nftban_rbl_get_state() {
    # Get current state for an IP
    # Args: $1 = IP address
    # Output: status (listed/clean/timeout) or empty if not tracked

    local ip="$1"
    local state_file="${NFTBAN_RBL_CACHE_DIR}/state.dat"

    if [[ -f "$state_file" ]]; then
        grep "^${ip}=" "$state_file" 2>/dev/null | head -1 | cut -d'|' -f1 | cut -d'=' -f2
    fi
}

nftban_rbl_get_severity() {
    # Get severity level for IP tag
    # Args: $1 = tag (mail/web/panel/unknown)
    # Output: critical/high/medium/low

    local tag="${1:-unknown}"

    case "$tag" in
        mail|smtp|mta)
            echo "${NFTBAN_RBL_SEVERITY_MAIL:-critical}"
            ;;
        web|http|https)
            echo "${NFTBAN_RBL_SEVERITY_WEB:-high}"
            ;;
        panel|cpanel|directadmin|plesk)
            echo "${NFTBAN_RBL_SEVERITY_PANEL:-high}"
            ;;
        *)
            echo "${NFTBAN_RBL_SEVERITY_DEFAULT:-medium}"
            ;;
    esac
}

nftban_rbl_send_alert() {
    # Send RBL listing alert
    # Args: $1 = IP address
    #       $2 = RBL domain
    #       $3 = reason
    #       $4 = tag (mail/web/panel)

    local ip="$1"
    local rbl="$2"
    local reason="$3"
    local tag="${4:-unknown}"
    # Per-module override: NFTBAN_RBL_ALERT_EMAIL, fallback: NFTBAN_MAIL_RECIPIENT
    local email="${NFTBAN_RBL_ALERT_EMAIL:-${NFTBAN_MAIL_RECIPIENT:-}}"

    if [[ -z "$email" ]]; then
        return 0
    fi

    # Get severity based on tag
    local severity
    severity=$(nftban_rbl_get_severity "$tag")
    local severity_upper
    severity_upper=$(echo "$severity" | tr '[:lower:]' '[:upper:]')

    # Build alert message
    local subject="[NFTBAN ${severity_upper}] IP Blacklisted: $ip ($tag)"
    # Build impact message based on tag
    local impact_msg
    case "$tag" in
        mail|smtp|mta)
            impact_msg="  - Email delivery WILL FAIL to many recipients
  - Server reputation severely damaged
  - Spam complaints may escalate
  - Possible mail server compromise"
            ;;
        web|http|https)
            impact_msg="  - Some security filters may block access
  - Web reputation affected
  - May indicate malware/spam on server"
            ;;
        *)
            impact_msg="  - Reputation damage
  - Some services may be blocked
  - Possible compromise indicator"
            ;;
    esac

    local body
    body=$(cat <<EOF
Subject: $subject

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NFTBan RBL Alert - IP Blacklisted
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Severity:     ${severity_upper}
IP Address:   $ip
Tag:          $tag
Blacklist:    $rbl
Reason:       $reason
Detected:     $(date)

Impact:
$impact_msg

Recommended Actions:
  1. Check outbound mail logs for spam
  2. Verify no open relay: telnet localhost 25
  3. Check for unauthorized processes
  4. Review recent logins: last -n 50
  5. Request delisting from RBL provider

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Full Report: nftban rbl check --verbose
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
)

    # Send via NFTBan unified mail mechanism
    nftban_mail_send "$body" "$email" 2>/dev/null || \
        echo "Warning: Failed to send RBL alert email" >&2
}

nftban_rbl_send_degraded_alert() {
    # Send alert when too many RBLs timeout (degraded monitoring)
    # Args: $1 = timeout count
    #       $2 = total RBL count

    local timeout_count="$1"
    local total_count="$2"
    # Per-module override: NFTBAN_RBL_ALERT_EMAIL, fallback: NFTBAN_MAIL_RECIPIENT
    local email="${NFTBAN_RBL_ALERT_EMAIL:-${NFTBAN_MAIL_RECIPIENT:-}}"

    if [[ -z "$email" ]]; then
        return 0
    fi

    # Only alert if degraded alerts are enabled
    if [[ "${NFTBAN_RBL_ALERT_ON_DEGRADED:-NO}" != "YES" ]]; then
        return 0
    fi

    # Calculate timeout percentage
    local timeout_pct=$(( (timeout_count * 100) / total_count ))

    # Only alert if >30% of RBLs timeout
    if [[ $timeout_pct -lt 30 ]]; then
        return 0
    fi

    local body
    body=$(cat <<EOF
Subject: [NFTBAN WARNING] RBL Monitoring Degraded (${timeout_pct}% timeouts)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NFTBan RBL Alert - Monitoring Degraded
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Severity:     WARNING
Issue:        Many RBL servers timing out
Timeouts:     $timeout_count / $total_count (${timeout_pct}%)
Detected:     $(date)

Impact:
  - RBL monitoring is incomplete
  - Blacklisted IPs may go undetected
  - False sense of security

Possible Causes:
  1. Network connectivity issues
  2. DNS resolver problems
  3. RBL servers experiencing issues
  4. Firewall blocking DNS queries

Recommended Actions:
  1. Check DNS resolver: dig +short zen.spamhaus.org
  2. Check network: ping -c 3 8.8.8.8
  3. Increase timeout: NFTBAN_RBL_TIMEOUT=10
  4. Review firewall rules for outbound DNS (port 53)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Run manually: nftban rbl check --fresh --verbose
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
EOF
)

    # Send via NFTBan unified mail mechanism
    nftban_mail_send "$body" "$email" 2>/dev/null || \
        echo "Warning: Failed to send degraded alert email" >&2
}

# =============================================================================
# STATUS FUNCTIONS
# =============================================================================

nftban_rbl_status() {
    # Get overall RBL monitoring status
    # Args: $1 = format (text|json)

    local format="${1:-text}"
    local last_check
    local cache_count

    # Get last check time
    if [[ -f "${NFTBAN_RBL_CACHE_DIR}/last_check" ]]; then
        last_check=$(cat "${NFTBAN_RBL_CACHE_DIR}/last_check")
    else
        last_check="Never"
    fi

    # Count cache files
    cache_count=$(find "${NFTBAN_RBL_CACHE_DIR}" -name "*.cache" 2>/dev/null | wc -l)

    if [[ "$format" == "json" ]]; then
        echo "{"
        echo "  \"enabled\": \"${NFTBAN_RBL_ENABLED}\","
        echo "  \"last_check\": \"$last_check\","
        echo "  \"cached_ips\": $cache_count,"
        echo "  \"cache_ttl_hours\": ${NFTBAN_RBL_CACHE_TTL}"
        echo "}"
    else
        echo "RBL Monitoring Status"
        echo "─────────────────────────────────────────────────────────"
        echo "Enabled: ${NFTBAN_RBL_ENABLED}"
        echo "Last Check: $last_check"
        echo "Cached IPs: $cache_count"
        echo "Cache TTL: ${NFTBAN_RBL_CACHE_TTL} hours"
    fi
}

# Export functions for use by CLI module
export -f nftban_rbl_get_public_ips
export -f nftban_rbl_get_critical_ips
export -f nftban_rbl_is_public_ip
export -f nftban_rbl_check_ip
export -f nftban_rbl_cache_purge
export -f nftban_rbl_cache_get
export -f nftban_rbl_cache_set
export -f nftban_rbl_status
export -f nftban_rbl_load_providers
export -f nftban_rbl_get_severity
export -f nftban_rbl_send_alert
export -f nftban_rbl_send_degraded_alert
export -f nftban_rbl_check_new_listing
export -f nftban_rbl_check_delisting
export -f nftban_rbl_update_state
export -f nftban_rbl_get_state
export -f nftban_rbl_watchlist_get
export -f nftban_rbl_watchlist_add
export -f nftban_rbl_watchlist_remove
export -f nftban_rbl_watchlist_list
export -f nftban_rbl_check_ip_parallel
