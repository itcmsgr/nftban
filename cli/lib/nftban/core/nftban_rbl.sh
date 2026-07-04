#!/usr/bin/env bash
# =============================================================================
# NFTBan - RBL Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Real-time Blackhole List (RBL) checking core logic
#
# meta:name="nftban_rbl"
# meta:type="core"
# meta:header="RBL Core Logic"
# meta:version="1.39.0"
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
    source "${_NFTBAN_RBL_LIB_DIR}/lib/nftban_timestamp.sh" || return 1
fi

# Load file utilities library (for nftban_file_age, nftban_file_mtime, nftban_file_is_stale)
if [[ -f "${_NFTBAN_RBL_LIB_DIR}/lib/nftban_file_utils.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_NFTBAN_RBL_LIB_DIR}/lib/nftban_file_utils.sh" || return 1
fi

# Load alert throttle library (for nftban_should_alert)
if [[ -f "${_NFTBAN_RBL_LIB_DIR}/lib/nftban_alert_throttle.sh" ]]; then
    # shellcheck source=/dev/null
    source "${_NFTBAN_RBL_LIB_DIR}/lib/nftban_alert_throttle.sh" || return 1
fi

# Load configuration
[[ -z "${NFTBAN_CONFIG_DIR:-}" ]] && readonly NFTBAN_CONFIG_DIR="/etc/nftban"
[[ -z "${NFTBAN_LOG_DIR:-}" ]] && readonly NFTBAN_LOG_DIR="/var/log/nftban"

# Load RBL configuration (package defaults)
if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/rbl/main.conf" ]]; then
    # shellcheck source=/dev/null
    source "${NFTBAN_CONFIG_DIR}/conf.d/rbl/main.conf" || true
fi

# Load user overrides (takes precedence over defaults)
if [[ -f "${NFTBAN_CONFIG_DIR}/conf.d/rbl/main.conf.local" ]]; then
    # shellcheck source=/dev/null
    # IMPL-1: ensure _source_local is defined wherever this file is loaded (env.sh idempotent)
    declare -F _source_local >/dev/null 2>&1 || source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh" 2>/dev/null || true
    _source_local "${NFTBAN_CONFIG_DIR}/conf.d/rbl/main.conf.local"
fi

# Set defaults if not configured
: "${NFTBAN_RBL_ENABLED:=NO}"
: "${NFTBAN_RBL_TIMEOUT:=4}"
: "${NFTBAN_RBL_CACHE_TTL:=24}"
: "${NFTBAN_RBL_AUTO_DISCOVER_IPS:=YES}"
: "${NFTBAN_RBL_CHECK_IPV6:=YES}"
: "${NFTBAN_RBL_CACHE_DIR:=${NFTBAN_CACHE_DIR:-/var/cache/nftban}/rbl}"
: "${NFTBAN_RBL_PROVIDERS_FILE:=${NFTBAN_CONFIG_DIR}/conf.d/rbl/rbls.conf}"
: "${NFTBAN_RBL_CUSTOM_FILE:=${NFTBAN_CONFIG_DIR}/conf.d/rbl/custom.conf}"
: "${NFTBAN_RBL_WATCHLIST_FILE:=${NFTBAN_CONFIG_DIR}/conf.d/rbl/watchlist.conf}"
: "${NFTBAN_RBL_ALERT_ON_NEW_LISTING:=YES}"
: "${NFTBAN_RBL_PARALLEL_JOBS:=10}"

# =============================================================================
# LOGGING (P1.4 — dedicated RBL log file, v1.29.0)
# =============================================================================

: "${NFTBAN_RBL_LOG_FILE:=${NFTBAN_LOG_DIR}/rbl.log}"

nftban_rbl_log() {
    # Write structured entry to dedicated RBL log file
    # Args: $1 = level (INFO|WARN|ERROR)
    #       $2 = message
    local level="${1:-INFO}"
    local message="$2"
    local timestamp
    timestamp=$(date -Iseconds 2>/dev/null || date)

    # Ensure log directory exists
    local log_dir
    log_dir=$(dirname "$NFTBAN_RBL_LOG_FILE")
    [[ -d "$log_dir" ]] || mkdir -p "$log_dir" 2>/dev/null || true

    printf '%s [%s] %s\n' "$timestamp" "$level" "$message" >> "$NFTBAN_RBL_LOG_FILE" 2>/dev/null || true
}

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
        # v1.19.0: Full IPv6 nibble-format reverse (R23)
        # Example: 2001:db8::1 -> 1.0.0.0...8.b.d.0.1.0.0.2
        # First expand to full 32-char hex form
        # v1.150 (16.6): initialize so the no-python3 path doesn't trip `set -u`
        # (the `if command -v python3` block below is skipped when absent, which
        # used to leave `expanded` unbound for the `[[ -n "$expanded" ]]` test).
        local expanded=""
        if command -v python3 &>/dev/null; then
            expanded=$(python3 -c "
import ipaddress
try:
    addr = ipaddress.ip_address('$ip')
    full = addr.exploded.replace(':','')
    print('.'.join(reversed(full)))
except:
    print('')
" 2>/dev/null) || expanded=""
        fi

        if [[ -n "$expanded" ]]; then
            echo "$expanded"
        else
            # No python3 — cannot reverse IPv6, return empty to skip
            echo ""
        fi
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

    # Atomic check + remove: filter out entry, compare line counts to detect if it existed
    local _before _after
    _before=$(wc -l < "$watchlist_file" 2>/dev/null || echo 0)
    grep -v "^${ip}|" "$watchlist_file" > "${watchlist_file}.tmp" 2>/dev/null || true
    _after=$(wc -l < "${watchlist_file}.tmp" 2>/dev/null || echo 0)
    if [[ "$_before" -eq "$_after" ]]; then
        rm -f "${watchlist_file}.tmp"
        echo "Error: IP $ip not found in watchlist" >&2
        return 1
    fi
    mv -f "${watchlist_file}.tmp" "$watchlist_file"

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
            # v1.19.20 FIX
            ((count++)) || true
        done < <(nftban_rbl_watchlist_get)
        echo ""
        echo "]"
    else
        echo "RBL Watchlist"
        echo "─────────────────────────────────────────────────────────"

        while IFS='|' read -r ip description tags notify_email; do
            [[ -z "$ip" ]] && continue
            # v1.19.20 FIX
            ((count++)) || true
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
    # Note: Uses subshell to scope EXIT trap — prevents collision with caller's traps

    local ip="$1"
    local format="${2:-text}"

    # Run entire parallel block in subshell to scope the EXIT trap (P0.3 fix)
    (
        local reversed_ip
        local temp_dir
        local jobs="${NFTBAN_RBL_PARALLEL_JOBS:-10}"
        # Cap parallel jobs to prevent resource exhaustion (VULN-19, P1-5)
        # v1.33.0: Hard cap at 10 concurrent DNS lookups
        [[ "$jobs" -gt 10 ]] && jobs=10

        reversed_ip=$(nftban_rbl_reverse_ip "$ip")
        # v1.206 (TODO-1) IPv6 honesty: detect family + the operator-declared set of
        # IPv4-only RBL zones (space-separated domains in NFTBAN_RBL_IPV4_ONLY_ZONES).
        # For an IPv6 target: a zone with no IPv6 reputation must be SKIPPED, and an
        # un-reversible IPv6 (no python3) is UNSUPPORTED — NEVER a silent CLEAN.
        local _ip_family="ipv4"
        [[ "$ip" == *:* ]] && _ip_family="ipv6"
        local _ipv4_only_zones=" ${NFTBAN_RBL_IPV4_ONLY_ZONES:-} "
        temp_dir=$(mktemp -d)
        # shellcheck disable=SC2064  # Intentional: expand $temp_dir NOW at set time (local var)
        trap "rm -rf '$temp_dir'" EXIT

        # Create list of RBL checks to run
        local rbl_list=()
        while IFS=: read -r rbl_domain rbl_url; do
            rbl_list+=("${rbl_domain}:${rbl_url}")
        done < <(nftban_rbl_load_providers)

        # v1.150 (11.5): enforce the per-run query cap in the PARENT, before
        # fan-out. The per-query _NFTBAN_RBL_QUERY_COUNT increment lives inside
        # `( … ) &` background subshells, so it never propagates back here and
        # the cap never tripped on the parallel path. Bound the number of
        # providers dispatched to min(count, MAX_QUERIES_PER_RUN) when the cap
        # is set and > 0.
        local _max_queries="${NFTBAN_RBL_MAX_QUERIES_PER_RUN:-0}"
        if [[ "$_max_queries" =~ ^[0-9]+$ ]] && [[ "$_max_queries" -gt 0 ]] \
           && [[ "${#rbl_list[@]}" -gt "$_max_queries" ]]; then
            rbl_list=("${rbl_list[@]:0:$_max_queries}")
        fi

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
                # v1.206: IPv6 zone-support gating BEFORE any query — distinct
                # degraded states, never CLEAN.
                if [[ "$_ip_family" == "ipv6" ]] && [[ -z "$reversed_ip" ]]; then
                    result="UNSUPPORTED_IPV6_ZONE"
                elif [[ "$_ip_family" == "ipv6" ]] && [[ "$_ipv4_only_zones" == *" ${rbl_domain} "* ]]; then
                    result="SKIPPED_IPV4_ONLY_ZONE"
                else
                    result=$(nftban_rbl_dns_lookup "$reversed_ip" "$rbl_domain")
                    if [[ "$result" == "LISTED" ]]; then
                        txt_record=$(nftban_rbl_get_txt_record "$reversed_ip" "$rbl_domain")
                    fi
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
        # v1.206 (TODO-1): degraded sub-counts. NONE of these ever count as clean.
        local blocked_count=0     # RESOLVER_BLOCKED (Spamhaus block-code / REFUSED)
        local skipped_count=0     # SKIPPED_IPV4_ONLY_ZONE
        local unsupported_count=0 # UNSUPPORTED_IPV6_ZONE

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
                # v1.19.20 FIX
                ((listed_count++)) || true

                if [[ "$format" == "json" ]]; then
                    [[ $first -eq 0 ]] && echo ","
                    # v1.150 (11.6): build the object with jq so a TXT record
                    # containing " \ or newline can't corrupt the JSON.
                    nftban_rbl_json_listed_obj "$rbl_domain" "$txt_record" "$rbl_url"
                    first=0
                else
                    echo "❌ LISTED: $rbl_domain"
                    [[ -n "$txt_record" ]] && echo "   Reason: $txt_record"
                    echo "   Info: $rbl_url"
                fi
            elif [[ "$result" == "TIMEOUT" ]] || [[ "$result" == "ERROR" ]] || [[ "$result" == "RATE_LIMITED" ]] \
                 || [[ "$result" == "RESOLVER_BLOCKED" ]] || [[ "$result" == "SKIPPED_IPV4_ONLY_ZONE" ]] \
                 || [[ "$result" == "UNSUPPORTED_IPV6_ZONE" ]]; then
                # v1.150 (11.3): ERROR/RATE_LIMITED counted as degraded, never CLEAN.
                # v1.206 (TODO-1): RESOLVER_BLOCKED / SKIPPED_IPV4_ONLY_ZONE /
                # UNSUPPORTED_IPV6_ZONE are ALSO degraded — they mean the IP's
                # reputation is UNKNOWN, and MUST NEVER increment clean_count.
                local _status_lc
                case "$result" in
                    TIMEOUT)               _status_lc="timeout";                ((timeout_count++)) || true ;;
                    ERROR)                 _status_lc="error";                  ((timeout_count++)) || true ;;
                    RATE_LIMITED)          _status_lc="rate_limited";           ((timeout_count++)) || true ;;
                    RESOLVER_BLOCKED)      _status_lc="resolver_blocked";       ((blocked_count++)) || true ;;
                    SKIPPED_IPV4_ONLY_ZONE) _status_lc="skipped_ipv4_only_zone"; ((skipped_count++)) || true ;;
                    UNSUPPORTED_IPV6_ZONE) _status_lc="unsupported_ipv6_zone";  ((unsupported_count++)) || true ;;
                esac

                if [[ "$format" == "json" ]]; then
                    [[ $first -eq 0 ]] && echo ","
                    nftban_rbl_json_status_obj "$rbl_domain" "$_status_lc" "$rbl_url"
                    first=0
                else
                    case "$result" in
                        RESOLVER_BLOCKED)       echo "🚫 RESOLVER_BLOCKED: $rbl_domain (reputation UNKNOWN — not clean)" ;;
                        SKIPPED_IPV4_ONLY_ZONE) echo "⏭️  SKIPPED (IPv4-only zone): $rbl_domain" ;;
                        UNSUPPORTED_IPV6_ZONE)  echo "⏭️  UNSUPPORTED (no IPv6 reputation): $rbl_domain" ;;
                        *)                      echo "⏱️  ${result}: $rbl_domain" ;;
                    esac
                fi
            else
                # v1.19.20 FIX — reached ONLY by a genuine successful negative lookup.
                ((clean_count++)) || true

                if [[ "$format" == "text" ]] && [[ "${NFTBAN_RBL_VERBOSE:-NO}" == "YES" ]]; then
                    echo "✅ CLEAN: $rbl_domain"
                fi
            fi
        done

        # v1.206: total degraded = every non-LISTED, non-CLEAN outcome. When >0
        # the IP's reputation is NOT fully verified — callers/posture must not
        # report "fully protected/clean".
        local degraded_count=$(( timeout_count + blocked_count + skipped_count + unsupported_count ))

        if [[ "$format" == "json" ]]; then
            echo ""
            echo "  ],"
            echo "  \"summary\": {"
            echo "    \"listed\": $listed_count,"
            echo "    \"clean\": $clean_count,"
            echo "    \"timeout\": $timeout_count,"
            echo "    \"resolver_blocked\": $blocked_count,"
            echo "    \"skipped_ipv4_only_zone\": $skipped_count,"
            echo "    \"unsupported_ipv6_zone\": $unsupported_count,"
            echo "    \"degraded\": $degraded_count"
            echo "  }"
            echo "}"
        else
            echo "─────────────────────────────────────────────────────────"
            echo "Summary:"
            echo "  Listed: $listed_count"
            echo "  Clean: $clean_count"
            echo "  Timeout: $timeout_count"
            [[ $blocked_count -gt 0 ]]     && echo "  Resolver-blocked: $blocked_count (reputation UNKNOWN — not clean)"
            [[ $skipped_count -gt 0 ]]     && echo "  Skipped (IPv4-only zone): $skipped_count"
            [[ $unsupported_count -gt 0 ]] && echo "  Unsupported (no IPv6 reputation): $unsupported_count"
            [[ $degraded_count -gt 0 ]]    && echo "  Degraded total: $degraded_count (RBL coverage incomplete — NOT fully verified)"
        fi

        # Exit code: 1 = listed; 2 = no listings but degraded (reputation not fully
        # verified — callers must not treat as a clean all-pass); 0 = all-clean.
        [[ $listed_count -gt 0 ]] && exit 1
        [[ $degraded_count -gt 0 ]] && exit 2
        exit 0
    )
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

# v1.150 (11.6): JSON object builders. The RBL TXT "reason" field is attacker-
# influenced data (it is whatever the remote blocklist returns) and may contain
# `"`, `\`, or newlines, which broke the old string-concat JSON. Build the
# object with `jq -n --arg` so every field is properly escaped. `jq` is already
# a hard dependency on the JSON path (see nftban_rbl_status).
nftban_rbl_json_listed_obj() {
    # Args: $1 = rbl domain, $2 = reason (raw TXT), $3 = info url
    local rbl="$1" reason="$2" url="$3"
    if command -v jq &>/dev/null; then
        jq -n --arg rbl "$rbl" --arg reason "$reason" --arg url "$url" \
            '{rbl: $rbl, status: "listed", reason: $reason, url: $url}'
    else
        # Fallback: no jq — emit a minimal object with the unsafe field dropped
        # rather than risk corrupt JSON. (jq is expected to be present.)
        printf '{"rbl":%s,"status":"listed","url":%s}' \
            "$(_nftban_rbl_json_str "$rbl")" "$(_nftban_rbl_json_str "$url")"
    fi
}

nftban_rbl_json_status_obj() {
    # Args: $1 = rbl domain, $2 = status (timeout|error|rate_limited), $3 = url
    local rbl="$1" status="$2" url="$3"
    if command -v jq &>/dev/null; then
        jq -n --arg rbl "$rbl" --arg status "$status" --arg url "$url" \
            '{rbl: $rbl, status: $status, url: $url}'
    else
        printf '{"rbl":%s,"status":%s,"url":%s}' \
            "$(_nftban_rbl_json_str "$rbl")" \
            "$(_nftban_rbl_json_str "$status")" \
            "$(_nftban_rbl_json_str "$url")"
    fi
}

_nftban_rbl_json_str() {
    # Minimal JSON string escaper for the no-jq fallback path.
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\r'/\\r}"
    printf '"%s"' "$s"
}

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
    # v1.206 (TODO-1) degraded sub-counts — never count as clean.
    local blocked_count=0 skipped_count=0 unsupported_count=0

    reversed_ip=$(nftban_rbl_reverse_ip "$ip")
    # v1.206 IPv6 honesty (parity with parallel path)
    local _ip_family="ipv4"
    [[ "$ip" == *:* ]] && _ip_family="ipv6"
    local _ipv4_only_zones=" ${NFTBAN_RBL_IPV4_ONLY_ZONES:-} "

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

        # v1.206: IPv6 zone-support gating before any query (never silent CLEAN).
        if [[ "$_ip_family" == "ipv6" ]] && [[ -z "$reversed_ip" ]]; then
            result="UNSUPPORTED_IPV6_ZONE"
        elif [[ "$_ip_family" == "ipv6" ]] && [[ "$_ipv4_only_zones" == *" ${rbl_domain} "* ]]; then
            result="SKIPPED_IPV4_ONLY_ZONE"
        else
            result=$(nftban_rbl_dns_lookup "$reversed_ip" "$rbl_domain")
        fi

        if [[ "$result" == "LISTED" ]]; then
            txt_record=$(nftban_rbl_get_txt_record "$reversed_ip" "$rbl_domain")
            # v1.19.20 FIX
            ((listed_count++)) || true

            if [[ "$format" == "json" ]]; then
                [[ $first -eq 0 ]] && echo ","
                # v1.150 (11.6): jq-escaped object (raw TXT can contain " \ newline).
                nftban_rbl_json_listed_obj "$rbl_domain" "$txt_record" "$rbl_url"
                first=0
            else
                echo "❌ LISTED: $rbl_domain"
                [[ -n "$txt_record" ]] && echo "   Reason: $txt_record"
                echo "   Info: $rbl_url"
            fi
        elif [[ "$result" == "TIMEOUT" ]] || [[ "$result" == "ERROR" ]] || [[ "$result" == "RATE_LIMITED" ]] \
             || [[ "$result" == "RESOLVER_BLOCKED" ]] || [[ "$result" == "SKIPPED_IPV4_ONLY_ZONE" ]] \
             || [[ "$result" == "UNSUPPORTED_IPV6_ZONE" ]]; then
            # v1.150 (11.3) + v1.206 (TODO-1): all of these are non-clean unknowns
            # (degraded) — MUST NEVER count as CLEAN.
            local _status_lc
            case "$result" in
                TIMEOUT)                _status_lc="timeout";                 ((timeout_count++)) || true ;;
                ERROR)                  _status_lc="error";                   ((timeout_count++)) || true ;;
                RATE_LIMITED)           _status_lc="rate_limited";            ((timeout_count++)) || true ;;
                RESOLVER_BLOCKED)       _status_lc="resolver_blocked";        ((blocked_count++)) || true ;;
                SKIPPED_IPV4_ONLY_ZONE) _status_lc="skipped_ipv4_only_zone";  ((skipped_count++)) || true ;;
                UNSUPPORTED_IPV6_ZONE)  _status_lc="unsupported_ipv6_zone";   ((unsupported_count++)) || true ;;
            esac

            if [[ "$format" == "json" ]]; then
                [[ $first -eq 0 ]] && echo ","
                nftban_rbl_json_status_obj "$rbl_domain" "$_status_lc" "$rbl_url"
                first=0
            else
                case "$result" in
                    RESOLVER_BLOCKED)       echo "🚫 RESOLVER_BLOCKED: $rbl_domain (reputation UNKNOWN — not clean)" ;;
                    SKIPPED_IPV4_ONLY_ZONE) echo "⏭️  SKIPPED (IPv4-only zone): $rbl_domain" ;;
                    UNSUPPORTED_IPV6_ZONE)  echo "⏭️  UNSUPPORTED (no IPv6 reputation): $rbl_domain" ;;
                    *)                      echo "⏱️  ${result}: $rbl_domain" ;;
                esac
            fi
        else
            # v1.19.20 FIX — reached ONLY by a genuine successful negative lookup.
            ((clean_count++)) || true

            if [[ "$format" == "text" ]] && [[ "${NFTBAN_RBL_VERBOSE:-NO}" == "YES" ]]; then
                echo "✅ CLEAN: $rbl_domain"
            fi
        fi
    done < <(nftban_rbl_load_providers)

    local degraded_count=$(( timeout_count + blocked_count + skipped_count + unsupported_count ))

    if [[ "$format" == "json" ]]; then
        echo ""
        echo "  ],"
        echo "  \"summary\": {"
        echo "    \"listed\": $listed_count,"
        echo "    \"clean\": $clean_count,"
        echo "    \"timeout\": $timeout_count,"
        echo "    \"resolver_blocked\": $blocked_count,"
        echo "    \"skipped_ipv4_only_zone\": $skipped_count,"
        echo "    \"unsupported_ipv6_zone\": $unsupported_count,"
        echo "    \"degraded\": $degraded_count"
        echo "  }"
        echo "}"
    else
        echo "─────────────────────────────────────────────────────────"
        echo "Summary:"
        echo "  Listed: $listed_count"
        echo "  Clean: $clean_count"
        echo "  Timeout: $timeout_count"
        [[ $blocked_count -gt 0 ]]     && echo "  Resolver-blocked: $blocked_count (reputation UNKNOWN — not clean)"
        [[ $skipped_count -gt 0 ]]     && echo "  Skipped (IPv4-only zone): $skipped_count"
        [[ $unsupported_count -gt 0 ]] && echo "  Unsupported (no IPv6 reputation): $unsupported_count"
        [[ $degraded_count -gt 0 ]]    && echo "  Degraded total: $degraded_count (RBL coverage incomplete — NOT fully verified)"
    fi

    # Exit code parity with the parallel path: 1=listed, 2=degraded-only, 0=all-clean.
    [[ $listed_count -gt 0 ]] && return 1
    [[ $degraded_count -gt 0 ]] && return 2
    return 0
}

# v1.150 (11.1): resolver-binary selection. `host` is preferred (its output
# is what the legacy parsers expect), then `dig`, then `nslookup`. If NONE of
# them exists we MUST NOT pretend the answer was empty (= false CLEAN); callers
# treat an empty selection as "no resolver → ERROR/unknown".
nftban_rbl_resolver() {
    # Output: the name of the first available resolver binary, or empty.
    if command -v host &>/dev/null; then
        echo "host"
    elif command -v dig &>/dev/null; then
        echo "dig"
    elif command -v nslookup &>/dev/null; then
        echo "nslookup"
    else
        echo ""
    fi
}

nftban_rbl_dns_lookup() {
    # Perform DNS A record lookup for RBL.
    # Args: $1 = reversed IP (4.3.2.1)
    #       $2 = RBL domain (zen.spamhaus.org)
    # Output (v1.206 7-state model): LISTED, CLEAN, ERROR, RESOLVER_BLOCKED,
    #        TIMEOUT, RATE_LIMITED  (zone-skip states SKIPPED_IPV4_ONLY_ZONE /
    #        UNSUPPORTED_IPV6_ZONE are decided by the caller before this query).
    #
    # INVARIANT (v1.206 TODO-1): CLEAN means ONLY a successful negative lookup
    # (authoritative NXDOMAIN / RFC5782 not-listed). A resolver/provider failure
    # or a provider block-code must NEVER collapse into CLEAN.
    #
    # v1.150 (11.1/11.3): capture the resolver's real rc (no `|| true`).
    #   rc==124              → TIMEOUT
    #   rc!=0 (other)        → ERROR (resolver/network failure — NOT clean)
    # v1.206 classification (rc==0):
    #   answer 127.255.255.252/.253/.254 → RESOLVER_BLOCKED (Spamhaus query-blocked
    #        / volume-limit / wrong-query — NOT listed and NOT clean) — carved out
    #        BEFORE the blanket 127/8 listed check.
    #   dig status REFUSED   → RESOLVER_BLOCKED (the resolver refused the zone)
    #   dig status SERVFAIL  → ERROR (authority/delegation failure — NOT clean)
    #   dig status NXDOMAIN / empty 127/8-absent → CLEAN (authoritative negative)
    #   other 127/8 answer   → LISTED (RFC 5782 valid hit)
    #   non-127/8 answer     → CLEAN (invalid per RFC 5782)

    local reversed_ip="$1"
    local rbl_domain="$2"
    local lookup_host="${reversed_ip}.${rbl_domain}"
    local timeout="${NFTBAN_RBL_TIMEOUT:-4}"

    # v1.19.0: Rate limiting - track query count per run (R23)
    _NFTBAN_RBL_QUERY_COUNT=$(( ${_NFTBAN_RBL_QUERY_COUNT:-0} + 1 ))
    local max_queries="${NFTBAN_RBL_MAX_QUERIES_PER_RUN:-500}"
    if [[ $_NFTBAN_RBL_QUERY_COUNT -gt $max_queries ]]; then
        echo "RATE_LIMITED"
        return 0
    fi

    # v1.150 (11.1): no resolver at all → unknown, never CLEAN.
    local resolver
    resolver=$(nftban_rbl_resolver)
    if [[ -z "$resolver" ]]; then
        echo "ERROR"
        return 0
    fi

    # Perform DNS lookup with timeout. Capture rc WITHOUT `|| true` (preserves the
    # real rc: 124 for timeout SIGTERM, etc). For dig we ALSO capture the response
    # status (REFUSED/SERVFAIL/NXDOMAIN/NOERROR) so resolver-block and authority
    # failures are classified honestly instead of looking empty/CLEAN.
    local dns_result="" rc=0 dns_status=""
    case "$resolver" in
        host)
            dns_result=$(timeout "$timeout" host -t A "$lookup_host" 2>/dev/null) || rc=$?
            ;;
        dig)
            # +noall +answer +comments → answer records AND the "status:" line in
            # one query (no extra round-trip), so REFUSED/SERVFAIL are visible.
            local dig_full=""
            dig_full=$(timeout "$timeout" dig +noall +answer +comments A "$lookup_host" 2>/dev/null) || rc=$?
            dns_status=$(printf '%s\n' "$dig_full" | grep -oP 'status:\s*\K[A-Z]+' | head -1)
            dns_result=$(printf '%s\n' "$dig_full" | awk '!/^;/ && NF {print $NF}' | grep -E '^[0-9.]+$')
            ;;
        nslookup)
            dns_result=$(timeout "$timeout" nslookup -type=A "$lookup_host" 2>/dev/null) || rc=$?
            dns_status=$(printf '%s\n' "$dns_result" | grep -oiP '\b(REFUSED|SERVFAIL|NXDOMAIN)\b' | head -1 | tr '[:lower:]' '[:upper:]')
            ;;
    esac

    if [[ $rc -eq 124 ]]; then
        echo "TIMEOUT"
        return 0
    fi

    # v1.206: resolver-status classification (when the resolver surfaced one).
    # REFUSED = the resolver/provider refused to answer the zone → blocked, not clean.
    # SERVFAIL = authority/delegation failure → ERROR, never clean.
    case "$dns_status" in
        REFUSED)  echo "RESOLVER_BLOCKED"; return 0 ;;
        SERVFAIL) echo "ERROR";            return 0 ;;
    esac

    if [[ $rc -ne 0 ]]; then
        # host returns rc=1 on NXDOMAIN (not listed); dig/nslookup return rc=0
        # with empty output. For `host`, distinguish "not found" (= CLEAN) from
        # a genuine resolver/network failure (= ERROR). dig REFUSED/SERVFAIL were
        # already handled above via dns_status.
        if [[ "$resolver" == "host" ]] && \
           printf '%s' "$dns_result" | grep -qi "not found\|NXDOMAIN\|has no .* record"; then
            echo "CLEAN"
        elif [[ "$resolver" == "host" ]] && \
             printf '%s' "$dns_result" | grep -qi "REFUSED"; then
            echo "RESOLVER_BLOCKED"
        else
            echo "ERROR"
        fi
        return 0
    fi

    # rc==0 + authoritative negative → CLEAN.
    if [[ "$dns_status" == "NXDOMAIN" ]]; then
        echo "CLEAN"
        return 0
    fi
    if [[ -z "$dns_result" ]] || printf '%s' "$dns_result" | grep -qi "not found\|NXDOMAIN"; then
        echo "CLEAN"
        return 0
    fi

    # v1.19.0: RFC 5782 validation - responses must be in 127.0.0.0/8 (R23).
    local response_ip
    response_ip=$(printf '%s' "$dns_result" | grep -oP '\d+\.\d+\.\d+\.\d+' | head -1)
    # v1.206 (TODO-1): carve out Spamhaus resolver/provider BLOCK codes BEFORE the
    # blanket 127/8 listed check — these answers do NOT mean "listed", they mean
    # the query was blocked (open-resolver / volume-limit / use DQS) and the IP's
    # true reputation is UNKNOWN. Must classify RESOLVER_BLOCKED, never LISTED/CLEAN.
    case "$response_ip" in
        127.255.255.252|127.255.255.253|127.255.255.254)
            echo "RESOLVER_BLOCKED"
            return 0
            ;;
    esac
    if [[ -n "$response_ip" ]] && [[ "$response_ip" =~ ^127\. ]]; then
        echo "LISTED"
    elif [[ -n "$response_ip" ]]; then
        # Non-127.x.x.x response is invalid per RFC 5782 - treat as CLEAN
        echo "CLEAN"
    else
        # rc==0 but no parseable A record (e.g. nslookup header text only) →
        # treat as CLEAN (a resolver success that returned no listing address).
        echo "CLEAN"
    fi
}

nftban_rbl_get_txt_record() {
    # Get TXT record for listed IP (reason/description)
    # Args: $1 = reversed IP (4.3.2.1)
    #       $2 = RBL domain
    # Output: TXT record content (or empty)
    #
    # v1.150 (11.1): same resolver fallback as the A-record path. Empty output
    # here is only a "no reason text" signal (the LISTED verdict was already
    # decided by nftban_rbl_dns_lookup), so empty-on-failure is acceptable.

    local reversed_ip="$1"
    local rbl_domain="$2"
    local lookup_host="${reversed_ip}.${rbl_domain}"
    local timeout="${NFTBAN_RBL_TIMEOUT:-4}"

    local resolver
    resolver=$(nftban_rbl_resolver)
    [[ -z "$resolver" ]] && { echo ""; return 0; }

    case "$resolver" in
        host)
            timeout "$timeout" host -t TXT "$lookup_host" 2>/dev/null | \
                grep -oP '(?<=").*(?=")' | \
                head -n1 || echo ""
            ;;
        dig)
            # dig +short TXT yields quoted strings; strip the surrounding quotes.
            timeout "$timeout" dig +short TXT "$lookup_host" 2>/dev/null | \
                head -n1 | sed -E 's/^"(.*)"$/\1/' || echo ""
            ;;
        nslookup)
            timeout "$timeout" nslookup -type=TXT "$lookup_host" 2>/dev/null | \
                grep -oP '(?<=text = ").*(?=")' | \
                head -n1 || echo ""
            ;;
    esac
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
    mkdir -p "$NFTBAN_RBL_CACHE_DIR" || return 1

    # Write cache file
    cat > "$cache_file"

    # Set permissions
    chmod 640 "$cache_file" 2>/dev/null || true
}

nftban_rbl_cache_purge() {
    # Purge RBL cache
    # Args: $1 = IP address, "--expired", or empty (purge all)
    #   nftban_rbl_cache_purge              → purge ALL cache files
    #   nftban_rbl_cache_purge 1.2.3.4      → purge specific IP
    #   nftban_rbl_cache_purge --expired    → purge only files older than TTL (v1.46.0)

    local ip="${1:-}"

    if [[ "$ip" == "--expired" ]]; then
        # Prune only expired entries (TTL-aware)
        [[ ! -d "$NFTBAN_RBL_CACHE_DIR" ]] && return 0
        local cache_ttl_seconds=$((NFTBAN_RBL_CACHE_TTL * 3600))
        local pruned=0 now
        now=$(date +%s)
        for cache_file in "${NFTBAN_RBL_CACHE_DIR}"/*.cache; do
            [[ -f "$cache_file" ]] || continue
            local file_mtime
            file_mtime=$(stat -c %Y "$cache_file" 2>/dev/null || echo 0)
            if (( now - file_mtime > cache_ttl_seconds )); then
                rm -f "$cache_file"
                ((pruned++)) || true
            fi
        done
        [[ $pruned -gt 0 ]] && echo "Pruned $pruned expired RBL cache entries"
    elif [[ -n "$ip" ]]; then
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
    mkdir -p "$NFTBAN_RBL_CACHE_DIR" || return 1

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

    # Log state transitions
    if [[ "$status" != "$prev_status" ]] && [[ -n "$prev_status" ]]; then
        nftban_rbl_log "INFO" "STATE: IP=$ip transition ${prev_status}→${status}"
    fi

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

    # v1.19.0: Use alert throttle to prevent duplicate alerts (R07)
    if declare -f nftban_should_alert &>/dev/null; then
        if ! nftban_should_alert "rbl_${ip}_${rbl}" 43200; then
            return 0  # Throttled (12-hour window per IP+RBL combination)
        fi
    fi

    # Per-module override: NFTBAN_RBL_ALERT_EMAIL, fallback: NFTBAN_MAIL_RECIPIENT
    local email="${NFTBAN_RBL_ALERT_EMAIL:-${NFTBAN_MAIL_RECIPIENT:-}}"

    if [[ -z "$email" ]]; then
        return 0
    fi

    nftban_rbl_log "WARN" "ALERT: IP=$ip listed on $rbl — reason: ${reason:-unknown} — sending to $email"

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
    # Get overall RBL monitoring status (enhanced v1.29.0)
    # Args: $1 = format (text|json|brief)

    local format="${1:-text}"
    local last_check last_check_ago=""
    local cache_count provider_count
    local listed_count=0
    local timer_status="unknown" timer_next=""

    # Get last check time
    if [[ -f "${NFTBAN_RBL_CACHE_DIR}/last_check" ]]; then
        last_check=$(cat "${NFTBAN_RBL_CACHE_DIR}/last_check")
        local last_epoch now_epoch
        last_epoch=$(date -d "$last_check" +%s 2>/dev/null || echo 0)
        now_epoch=$(date +%s)
        if [[ $last_epoch -gt 0 ]]; then
            local hours_ago=$(( (now_epoch - last_epoch) / 3600 ))
            last_check_ago="${hours_ago}h ago"
        fi
    else
        last_check="Never"
    fi

    # Count cache files
    cache_count=$(find "${NFTBAN_RBL_CACHE_DIR}" -name "*.cache" 2>/dev/null | wc -l)

    # Count providers
    provider_count=$(nftban_rbl_load_providers 2>/dev/null | wc -l) || provider_count=0

    # Check for blacklisted IPs
    local state_file="${NFTBAN_RBL_CACHE_DIR}/state.json"
    if [[ -f "$state_file" ]]; then
        listed_count=$(grep -c '"listed"' "$state_file" 2>/dev/null || true)
        listed_count=${listed_count:-0}
    fi

    # Timer status
    if systemctl is-active nftban-rbl-check.timer &>/dev/null 2>&1; then
        timer_status="active"
        timer_next=$(systemctl show nftban-rbl-check.timer --property=NextElapseUSecRealtime 2>/dev/null | cut -d= -f2 | head -c 19 || echo "")
    elif systemctl is-enabled nftban-rbl-check.timer &>/dev/null 2>&1; then
        timer_status="enabled (not active)"
    else
        timer_status="disabled"
    fi

    # Count monitored IPs (auto-discovered)
    local monitored_ipv4=0 monitored_ipv6=0
    if [[ "${NFTBAN_RBL_ENABLED}" == "YES" ]]; then
        monitored_ipv4=$(ip -4 addr show 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '^127\.' | sort -u | wc -l)
        if [[ "${NFTBAN_RBL_CHECK_IPV6:-YES}" == "YES" ]]; then
            monitored_ipv6=$(ip -6 addr show 2>/dev/null | grep -oP '(?<=inet6\s)[0-9a-f:]+' | grep -v '^::1' | grep -v '^fe80:' | grep -v '^fc00:' | grep -v '^fd00:' | sort -u | wc -l)
        fi
    fi
    local monitored_total=$((monitored_ipv4 + monitored_ipv6))

    # Brief mode (one-line)
    if [[ "$format" == "brief" ]]; then
        if [[ "${NFTBAN_RBL_ENABLED}" == "YES" ]]; then
            if [[ $listed_count -gt 0 ]]; then
                echo "RBL: ENABLED — ${listed_count} IP(s) BLACKLISTED — ${provider_count} providers — last check: ${last_check_ago:-never}"
            else
                echo "RBL: ENABLED — clean — ${provider_count} providers — last check: ${last_check_ago:-never}"
            fi
        else
            echo "RBL: DISABLED (enable with: nftban rbl enable)"
        fi
        return 0
    fi

    if [[ "$format" == "json" ]]; then
        if command -v jq &>/dev/null; then
            jq -n \
                --arg enabled "${NFTBAN_RBL_ENABLED}" \
                --arg last_check "$last_check" \
                --arg last_check_ago "${last_check_ago:-}" \
                --argjson cached_ips "$cache_count" \
                --argjson cache_ttl "${NFTBAN_RBL_CACHE_TTL}" \
                --argjson provider_count "$provider_count" \
                --argjson listed_count "$listed_count" \
                --arg timer_status "$timer_status" \
                --arg timer_next "${timer_next:-}" \
                --argjson monitored_ipv4 "$monitored_ipv4" \
                --argjson monitored_ipv6 "$monitored_ipv6" \
                '{
                    enabled: ($enabled == "YES"),
                    last_check: $last_check,
                    last_check_ago: $last_check_ago,
                    cached_ips: $cached_ips,
                    cache_ttl_hours: $cache_ttl,
                    provider_count: $provider_count,
                    listed_count: $listed_count,
                    timer_status: $timer_status,
                    timer_next: $timer_next,
                    monitored_ipv4: $monitored_ipv4,
                    monitored_ipv6: $monitored_ipv6
                }'
        else
            echo "{"
            echo "  \"enabled\": \"${NFTBAN_RBL_ENABLED}\","
            echo "  \"last_check\": \"$last_check\","
            echo "  \"cached_ips\": $cache_count,"
            echo "  \"cache_ttl_hours\": ${NFTBAN_RBL_CACHE_TTL},"
            echo "  \"provider_count\": $provider_count,"
            echo "  \"listed_count\": $listed_count"
            echo "}"
        fi
    else
        echo "RBL Monitoring Status"
        echo "─────────────────────────────────────────────────────────"
        echo "  Module:       RBL (Self-IP reputation monitoring)"
        echo "  Enabled:      ${NFTBAN_RBL_ENABLED}"
        if [[ "${NFTBAN_RBL_ENABLED}" != "YES" ]]; then
            echo "                (enable with: nftban rbl enable)"
        fi
        echo "  Timer:        $timer_status"
        [[ -n "$timer_next" ]] && echo "                (next: $timer_next)"
        echo "  Last Check:   ${last_check}${last_check_ago:+ ($last_check_ago)}"
        echo "  Providers:    $provider_count active"
        echo "  Monitored:    $monitored_total IPs ($monitored_ipv4 IPv4, $monitored_ipv6 IPv6)"
        if [[ $listed_count -gt 0 ]]; then
            echo "  Blacklisted:  $listed_count (run 'nftban rbl check' for details)"
        else
            echo "  Blacklisted:  0"
        fi
        echo "  Cache:        $cache_count entries (${NFTBAN_RBL_CACHE_TTL}h TTL)"
    fi
}

# =============================================================================
# OBSERVABILITY COUNTERS (P1.5 — v1.29.0)
# =============================================================================

nftban_rbl_update_counters() {
    # Update RBL observability counters after a check run
    # Args: $1 = listed_count
    #       $2 = clean_count
    #       $3 = timeout_count
    #       $4 = duration_ms (optional)

    local listed="${1:-0}"
    local clean="${2:-0}"
    local timeout="${3:-0}"
    local duration_ms="${4:-0}"
    local counters_file="${NFTBAN_RBL_CACHE_DIR}/counters.dat"
    local total=$((listed + clean + timeout))

    # Load existing counters
    local prev_total_checks=0 prev_total_listed=0 prev_total_timeouts=0
    if [[ -f "$counters_file" ]]; then
        prev_total_checks=$(grep "^total_checks=" "$counters_file" 2>/dev/null | cut -d= -f2 || echo 0)
        prev_total_listed=$(grep "^total_listed=" "$counters_file" 2>/dev/null | cut -d= -f2 || echo 0)
        prev_total_timeouts=$(grep "^total_timeouts=" "$counters_file" 2>/dev/null | cut -d= -f2 || echo 0)
    fi

    # Write updated counters
    mkdir -p "$NFTBAN_RBL_CACHE_DIR" 2>/dev/null || true
    cat > "$counters_file" <<EOF
total_checks=$((prev_total_checks + total))
total_listed=$((prev_total_listed + listed))
total_timeouts=$((prev_total_timeouts + timeout))
last_run_checks=$total
last_run_listed=$listed
last_run_timeouts=$timeout
last_duration_ms=$duration_ms
last_run_timestamp=$(date -Iseconds 2>/dev/null || date)
EOF

    nftban_rbl_log "INFO" "CHECK: total=$total listed=$listed clean=$clean timeout=$timeout duration=${duration_ms}ms"
}

nftban_rbl_get_counters() {
    # Get current observability counters
    # Args: $1 = format (text|json)
    local format="${1:-text}"
    local counters_file="${NFTBAN_RBL_CACHE_DIR}/counters.dat"

    if [[ ! -f "$counters_file" ]]; then
        if [[ "$format" == "json" ]]; then
            echo '{"total_checks":0,"total_listed":0,"total_timeouts":0}'
        else
            echo "No counter data (run 'nftban rbl check' first)"
        fi
        return 0
    fi

    if [[ "$format" == "json" ]]; then
        # Convert key=value to JSON
        echo "{"
        local first=1
        while IFS='=' read -r key value; do
            [[ -z "$key" ]] && continue
            [[ $first -eq 0 ]] && echo ","
            if [[ "$value" =~ ^[0-9]+$ ]]; then
                echo -n "  \"$key\": $value"
            else
                echo -n "  \"$key\": \"$value\""
            fi
            first=0
        done < "$counters_file"
        echo ""
        echo "}"
    else
        echo "RBL Observability Counters"
        echo "─────────────────────────────────────────────────────────"
        while IFS='=' read -r key value; do
            [[ -z "$key" ]] && continue
            printf "  %-20s  %s\n" "$key" "$value"
        done < "$counters_file"
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
export -f nftban_rbl_resolver
export -f nftban_rbl_json_listed_obj
export -f nftban_rbl_json_status_obj
export -f nftban_rbl_log
export -f nftban_rbl_update_counters
export -f nftban_rbl_get_counters
