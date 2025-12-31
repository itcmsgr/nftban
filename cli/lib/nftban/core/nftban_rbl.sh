#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - RBL Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Real-time Blackhole List (RBL) checking core logic
#
# meta:name=nftban_rbl
# meta:type=core
# meta:header=RBL Core Logic
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description**
# meta:description=RBL checking against 20+ DNS blackhole lists
# meta:input=IP addresses, RBL configuration
# meta:output=Blacklist status, cached results, alerts
#
# **Based on CSF RBL Implementation**
# Source: ConfigServer Security & Firewall
# Method: DNS reverse lookup with caching
#
# meta:created_date=2025-12-31
# meta:updated_date=2025-12-31
# =============================================================================

# Strict mode
set -euo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_RBL_CORE_LOADED:-}" ]] && return 0
readonly NFTBAN_RBL_CORE_LOADED=1

# Load configuration
[[ -z "${NFTBAN_CONFIG_DIR:-}" ]] && readonly NFTBAN_CONFIG_DIR="/etc/nftban"
[[ -z "${NFTBAN_LOG_DIR:-}" ]] && readonly NFTBAN_LOG_DIR="/var/log/nftban"

# Load RBL configuration
if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/rbl/main.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/conf.d/rbl/main.conf"
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
: "${NFTBAN_RBL_ALERT_ON_NEW_LISTING:=YES}"

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
    local results=()  # shellcheck disable=SC2034  # Reserved for detailed RBL results
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
    # Check if IP has new listing (state transition)
    # Args: $1 = IP address
    #       $2 = current status (listed/clean)
    # Return: 0 if new listing, 1 otherwise

    local ip="$1"
    local current_status="$2"
    local state_file="${NFTBAN_RBL_CACHE_DIR}/state.json"

    # If currently clean, no alert needed
    if [[ "$current_status" != "listed" ]]; then
        return 1
    fi

    # Check previous state
    if [[ ! -f "$state_file" ]]; then
        # No previous state - this is first check
        return 0
    fi

    # Check if IP was listed before
    if grep -q "\"$ip\".*\"listed\"" "$state_file" 2>/dev/null; then
        return 1  # Already listed
    fi

    return 0  # New listing
}

nftban_rbl_update_state() {
    # Update RBL state file
    # Args: $1 = IP address
    #       $2 = status (listed/clean/timeout)

    local ip="$1"
    local status="$2"
    local state_file="${NFTBAN_RBL_CACHE_DIR}/state.json"
    local timestamp
    timestamp=$(date -Iseconds)

    # Create directory if needed
    mkdir -p "$NFTBAN_RBL_CACHE_DIR"

    # Initialize state file if missing
    if [[ ! -f "$state_file" ]]; then
        echo "{}" > "$state_file"
    fi

    # Update state (simple JSON append for now)
    # Note: This is simplified - production would use jq
    {
        echo "{"
        echo "  \"$ip\": {"
        echo "    \"status\": \"$status\","
        echo "    \"timestamp\": \"$timestamp\""
        echo "  }"
        echo "}"
    } > "$state_file"
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
    local email="${NFTBAN_RBL_ALERT_EMAIL:-}"

    if [[ -z "$email" ]]; then
        return 0
    fi

    # Build alert message
    local subject="[NFTBAN ALERT] IP Blacklisted: $ip ($tag)"
    local body
    body=$(cat <<EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
NFTBan RBL Alert - IP Blacklisted
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Severity:     CRITICAL
IP Address:   $ip
Tag:          $tag
Blacklist:    $rbl
Reason:       $reason
Detected:     $(date)

Impact:
  - Email delivery may fail
  - Reputation damage
  - Possible compromise indicator

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

    # Send via mail command (basic implementation)
    echo "$body" | mail -s "$subject" "$email" 2>/dev/null || \
        echo "Warning: Failed to send RBL alert email" >&2
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
export -f nftban_rbl_check_ip
export -f nftban_rbl_cache_purge
export -f nftban_rbl_status
