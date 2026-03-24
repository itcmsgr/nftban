#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.30 - Bot Scanner Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Detect and block bot scanners, webshell probes, exploit attempts
#
# meta:name="nftban_botscan"
# meta:type="core"
# meta:header="Bot Scanner Detection Engine"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Bot scanner detection using pattern matching on access logs"
# meta:inventory.files="/usr/lib/nftban/core/nftban_botscan.sh"
# meta:inventory.binaries="nft,grep,awk"
# meta:inventory.env_vars="BOTSCAN_ENABLED,BOTSCAN_PATTERNS_DIR"
# meta:inventory.config_files="/etc/nftban/conf.d/botscan/main.conf"
# meta:inventory.systemd_units="none"
# meta:inventory.network="none"
# meta:inventory.privileges="root:read-logs,nftables"
# meta:created_date="2026-01-11"
# meta:updated_date="2026-01-11"
# =============================================================================

# Enhanced strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Prevent double-loading
[[ -n "${NFTBAN_BOTSCAN_LOADED:-}" ]] && return 0
readonly NFTBAN_BOTSCAN_LOADED=1

# =============================================================================
# SHARED LIBRARIES
# =============================================================================

# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" 2>/dev/null || true

# =============================================================================
# CONFIGURATION
# =============================================================================

# Load config if not already loaded
nftban_botscan_load_config() {
    local config_file="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/botscan/main.conf"
    local config_local="${config_file}.local"

    # Defaults
    : "${BOTSCAN_ENABLED:=true}"
    : "${BOTSCAN_ACTION_MODE:=both}"
    : "${BOTSCAN_LOG_AUTO:=true}"
    : "${BOTSCAN_LOG_APACHE:=/var/log/apache2/access.log}"
    : "${BOTSCAN_LOG_APACHE_ALT:=/var/log/httpd/access_log}"
    : "${BOTSCAN_LOG_NGINX:=/var/log/nginx/access.log}"
    : "${BOTSCAN_DEFAULT_THRESHOLD:=5}"
    : "${BOTSCAN_DEFAULT_WINDOW:=60}"
    : "${BOTSCAN_DEFAULT_BAN_SHORT:=1800}"
    : "${BOTSCAN_DEFAULT_BAN_LONG:=7200}"
    : "${BOTSCAN_404_TRACKING:=true}"
    : "${BOTSCAN_404_THRESHOLD:=50}"
    : "${BOTSCAN_404_WINDOW:=300}"
    : "${BOTSCAN_404_BAN:=3600}"
    : "${BOTSCAN_PROGRESSIVE_ENABLED:=true}"
    : "${BOTSCAN_PROGRESSIVE_MULTIPLIER:=2}"
    : "${BOTSCAN_PROGRESSIVE_MAX:=86400}"
    : "${BOTSCAN_PATTERNS_DIR:=${NFTBAN_CONFIG_DIR:-/etc/nftban}/patterns.d/botscan}"
    : "${BOTSCAN_WHITELIST_BOTS:=googlebot,bingbot,yandexbot,duckduckbot,slurp,facebot}"
    : "${BOTSCAN_WHITELIST_PATHS:=/robots\\.txt|/favicon\\.ico|/sitemap\\.xml|/ads\\.txt}"
    : "${BOTSCAN_USE_GLOBAL_WHITELIST:=true}"
    : "${BOTSCAN_STATE_FILE:=${NFTBAN_DATA_DIR:-/var/lib/nftban}/botscan-state.db}"
    : "${BOTSCAN_LOG_FILE:=${NFTBAN_LOG_DIR:-/var/log/nftban}/botscan.log}"
    : "${BOTSCAN_DEBUG:=false}"

    # Source config files
    # shellcheck source=/dev/null
    source "$config_file" 2>/dev/null || true
    # shellcheck source=/dev/null
    source "$config_local" 2>/dev/null || true
    return 0
}

# =============================================================================
# STATE MANAGEMENT
# =============================================================================

# Associative arrays for tracking
declare -gA _BOTSCAN_IP_HITS        # IP -> hit count
declare -gA _BOTSCAN_IP_PATTERNS    # IP -> matched patterns
declare -gA _BOTSCAN_IP_FIRST_SEEN  # IP -> first seen timestamp
declare -gA _BOTSCAN_IP_LAST_SEEN   # IP -> last seen timestamp
declare -gA _BOTSCAN_IP_404_COUNT      # IP -> 404 count
declare -gA _BOTSCAN_IP_404_FIRST_SEEN # IP -> 404 first seen timestamp
declare -gA _BOTSCAN_PATTERNS          # Pattern name -> pattern definition

# Initialize state
nftban_botscan_init_state() {
    _BOTSCAN_IP_HITS=()
    _BOTSCAN_IP_PATTERNS=()
    _BOTSCAN_IP_FIRST_SEEN=()
    _BOTSCAN_IP_LAST_SEEN=()
    _BOTSCAN_IP_404_COUNT=()
    _BOTSCAN_IP_404_FIRST_SEEN=()
}

# =============================================================================
# PATTERN MANAGEMENT
# =============================================================================

# Load patterns from file
# Format: NAME|PATTERN|MATCH_TYPE|THRESHOLD|WINDOW|BAN|ENABLED|DESCRIPTION
nftban_botscan_load_patterns() {
    local patterns_dir="${BOTSCAN_PATTERNS_DIR}"
    local pattern_count=0

    _BOTSCAN_PATTERNS=()

    for pattern_file in "$patterns_dir"/*.patterns; do
        [[ -f "$pattern_file" ]] || continue

        while IFS='|' read -r name pattern match_type threshold window ban enabled description; do
            # Skip comments and empty lines
            [[ -z "$name" || "$name" =~ ^# ]] && continue

            # Skip disabled patterns
            [[ "$enabled" != "true" ]] && continue

            # Store pattern: name -> "pattern|match_type|threshold|window|ban|description"
            _BOTSCAN_PATTERNS["$name"]="${pattern}|${match_type}|${threshold}|${window}|${ban}|${description}"
            pattern_count=$((pattern_count + 1))

        done < "$pattern_file"
    done

    [[ "$BOTSCAN_DEBUG" == "true" ]] && echo "[DEBUG] Loaded $pattern_count patterns" >&2
    return 0
}

# List all patterns
nftban_botscan_list_patterns() {
    local filter="${1:-all}"  # all, enabled, disabled, category
    local category="${2:-}"

    printf "%-20s %-8s %-10s %-6s %-6s %-6s %s\n" "NAME" "ENABLED" "MATCH" "THRESH" "WINDOW" "BAN" "DESCRIPTION"
    printf "%s\n" "$(printf '=%.0s' {1..100})"

    for pattern_file in "$BOTSCAN_PATTERNS_DIR"/*.patterns; do
        [[ -f "$pattern_file" ]] || continue

        # Category filter
        if [[ -n "$category" ]]; then
            local file_category
            file_category=$(basename "$pattern_file" .patterns)
            [[ "$file_category" != "$category" ]] && continue
        fi

        while IFS='|' read -r name pattern match_type threshold window ban enabled description; do
            [[ -z "$name" || "$name" =~ ^# ]] && continue

            # Filter
            case "$filter" in
                enabled)  [[ "$enabled" != "true" ]] && continue ;;
                disabled) [[ "$enabled" == "true" ]] && continue ;;
            esac

            printf "%-20s %-8s %-10s %-6s %-6s %-6s %s\n" \
                "$name" "$enabled" "$match_type" "$threshold" "$window" "$ban" "${description:0:40}"

        done < "$pattern_file"
    done
}

# Add custom pattern
nftban_botscan_add_pattern() {
    local name="$1"
    local pattern="$2"
    local match_type="${3:-url-404}"
    local threshold="${4:-$BOTSCAN_DEFAULT_THRESHOLD}"
    local window="${5:-$BOTSCAN_DEFAULT_WINDOW}"
    local ban="${6:-$BOTSCAN_DEFAULT_BAN_SHORT}"
    local description="${7:-Custom pattern}"

    local custom_file="${BOTSCAN_PATTERNS_DIR}/custom.patterns"

    # Check if pattern already exists
    if grep -q "^${name}|" "$custom_file" 2>/dev/null; then
        echo "ERROR: Pattern '$name' already exists" >&2
        return 1
    fi

    # Add pattern
    echo "${name}|${pattern}|${match_type}|${threshold}|${window}|${ban}|true|${description}" >> "$custom_file"
    echo "Added pattern: $name"
    return 0
}

# Remove custom pattern
nftban_botscan_remove_pattern() {
    local name="$1"
    local custom_file="${BOTSCAN_PATTERNS_DIR}/custom.patterns"

    if ! grep -q "^${name}|" "$custom_file" 2>/dev/null; then
        echo "ERROR: Pattern '$name' not found in custom.patterns" >&2
        return 1
    fi

    # v1.19.0: Escape pattern name for safe sed usage (R23)
    local safe_name
    safe_name=$(printf '%s' "$name" | sed 's/[[\.*^$()+?{}|/]/\\&/g')
    sed -i "/^${safe_name}|/d" "$custom_file"
    echo "Removed pattern: $name"
    return 0
}

# Enable/disable pattern
nftban_botscan_toggle_pattern() {
    local name="$1"
    local action="$2"  # enable or disable
    local new_state

    [[ "$action" == "enable" ]] && new_state="true" || new_state="false"

    local found=0
    for pattern_file in "$BOTSCAN_PATTERNS_DIR"/*.patterns; do
        [[ -f "$pattern_file" ]] || continue

        if grep -q "^${name}|" "$pattern_file"; then
            # Toggle the enabled field (7th field)
            sed -i "s/^\(${name}|[^|]*|[^|]*|[^|]*|[^|]*|[^|]*|\)[^|]*/\1${new_state}/" "$pattern_file"
            echo "${action^}d pattern: $name"
            found=1
            break
        fi
    done

    [[ $found -eq 0 ]] && echo "ERROR: Pattern '$name' not found" >&2 && return 1
    return 0
}

# =============================================================================
# LOG PARSING
# =============================================================================

# Find access log
nftban_botscan_find_log() {
    if [[ -f "$BOTSCAN_LOG_NGINX" ]]; then
        echo "$BOTSCAN_LOG_NGINX"
    elif [[ -f "$BOTSCAN_LOG_APACHE" ]]; then
        echo "$BOTSCAN_LOG_APACHE"
    elif [[ -f "$BOTSCAN_LOG_APACHE_ALT" ]]; then
        echo "$BOTSCAN_LOG_APACHE_ALT"
    else
        echo ""
    fi
}

# Parse access log line
# Returns: IP|URL|METHOD|STATUS|USER_AGENT
nftban_botscan_parse_line() {
    local line="$1"
    local ip url method status ua

    # Combined Log Format: IP - - [date] "METHOD URL PROTO" STATUS SIZE "REFERER" "UA"
    # IPv4 and IPv6 compatible (v1.19.0, v1.19.12 bracket fix R22)
    # Handles: 192.168.1.1, 2001:db8::1, [2001:db8::1]:8080
    if [[ "$line" =~ ^\[?([0-9a-fA-F.:]+)\]?.*\"([A-Z]+)\ ([^\"\ ]+).*\"\ ([0-9]+) ]]; then
        ip="${BASH_REMATCH[1]}"
        method="${BASH_REMATCH[2]}"
        url="${BASH_REMATCH[3]}"
        status="${BASH_REMATCH[4]}"

        # Extract user agent
        if [[ "$line" =~ \"([^\"]+)\"$ ]]; then
            ua="${BASH_REMATCH[1]}"
        else
            ua="-"
        fi

        echo "${ip}|${url}|${method}|${status}|${ua}"
        return 0
    fi

    return 1
}

# Check if IP is whitelisted — v1.19.0: IPv4/IPv6 parity
nftban_botscan_is_whitelisted() {
    local ip="$1"
    local ua="${2:-}"

    # Localhost (both families)
    [[ "$ip" == "127.0.0.1" || "$ip" == "::1" ]] && return 0

    # Private networks (both families — never ban internal traffic)
    [[ "$ip" =~ ^10\. ]] && return 0
    [[ "$ip" =~ ^172\.(1[6-9]|2[0-9]|3[0-1])\. ]] && return 0
    [[ "$ip" =~ ^192\.168\. ]] && return 0
    [[ "$ip" =~ ^[Ff][CcDd] ]] && return 0
    [[ "$ip" =~ ^[Ff][Ee]80: ]] && return 0

    # Check global whitelist
    if [[ "$BOTSCAN_USE_GLOBAL_WHITELIST" == "true" ]]; then
        if type -t nftban_is_whitelisted &>/dev/null; then
            nftban_is_whitelisted "$ip" && return 0
        fi
    fi

    # Check bot whitelist (user agent)
    if [[ -n "$ua" ]]; then
        # IFS-safe split: strict.sh sets IFS=$'\n\t', so space-separated vars need explicit splitting
        local bot _whitelist_bots
        IFS=' ' read -ra _whitelist_bots <<< "${BOTSCAN_WHITELIST_BOTS//,/ }"
        for bot in "${_whitelist_bots[@]}"; do
            if [[ "${ua,,}" =~ ${bot,,} ]]; then
                return 0
            fi
        done
    fi

    return 1
}

# Check if URL is whitelisted
nftban_botscan_is_path_whitelisted() {
    local url="$1"

    if [[ "$url" =~ $BOTSCAN_WHITELIST_PATHS ]]; then
        return 0
    fi

    return 1
}

# =============================================================================
# DETECTION ENGINE
# =============================================================================

# Match URL against patterns
# Returns: matched pattern name or empty
nftban_botscan_match_url() {
    local url="$1"
    local method="$2"
    local status="$3"
    local ua="${4:-}"

    for name in "${!_BOTSCAN_PATTERNS[@]}"; do
        local def="${_BOTSCAN_PATTERNS[$name]}"
        local pattern match_type

        IFS='|' read -r pattern match_type _ _ _ _ <<< "$def"

        # Check match type
        case "$match_type" in
            url-404)
                [[ "$status" != "404" ]] && continue
                # Match URL pattern
                if [[ "$url" =~ $pattern ]]; then
                    echo "$name"
                    return 0
                fi
                ;;
            url-post)
                [[ "$method" != "POST" ]] && continue
                if [[ "$url" =~ $pattern ]]; then
                    echo "$name"
                    return 0
                fi
                ;;
            url-get)
                [[ "$method" != "GET" ]] && continue
                if [[ "$url" =~ $pattern ]]; then
                    echo "$name"
                    return 0
                fi
                ;;
            url-any)
                if [[ "$url" =~ $pattern ]]; then
                    echo "$name"
                    return 0
                fi
                ;;
            useragent)
                # Match against user-agent string
                if [[ -n "$ua" && "$ua" =~ $pattern ]]; then
                    echo "$name"
                    return 0
                fi
                ;;
        esac
    done

    return 1
}

# Process log entry
nftban_botscan_process_entry() {
    local ip="$1"
    local url="$2"
    local method="$3"
    local status="$4"
    local ua="$5"
    local now
    now=$(nftban_timestamp_unix 2>/dev/null || date +%s)

    # Check whitelists
    nftban_botscan_is_whitelisted "$ip" "$ua" && return 0
    nftban_botscan_is_path_whitelisted "$url" && return 0

    # Track 404s
    if [[ "$BOTSCAN_404_TRACKING" == "true" && "$status" == "404" ]]; then
        _BOTSCAN_IP_404_COUNT["$ip"]=$(( ${_BOTSCAN_IP_404_COUNT[$ip]:-0} + 1 ))
        [[ -z "${_BOTSCAN_IP_404_FIRST_SEEN[$ip]:-}" ]] && _BOTSCAN_IP_404_FIRST_SEEN["$ip"]="$now"
    fi

    # Match against patterns (URL and user-agent)
    local matched_pattern
    matched_pattern=$(nftban_botscan_match_url "$url" "$method" "$status" "$ua") || true

    if [[ -n "$matched_pattern" ]]; then
        # Update tracking
        _BOTSCAN_IP_HITS["$ip"]=$(( ${_BOTSCAN_IP_HITS[$ip]:-0} + 1 ))
        _BOTSCAN_IP_PATTERNS["$ip"]="${_BOTSCAN_IP_PATTERNS[$ip]:-} $matched_pattern"
        _BOTSCAN_IP_LAST_SEEN["$ip"]="$now"
        [[ -z "${_BOTSCAN_IP_FIRST_SEEN[$ip]:-}" ]] && _BOTSCAN_IP_FIRST_SEEN["$ip"]="$now"

        [[ "$BOTSCAN_DEBUG" == "true" ]] && echo "[DEBUG] $ip matched $matched_pattern: $url" >&2
    fi

    return 0
}

# Analyze tracked IPs and ban if threshold exceeded
nftban_botscan_analyze() {
    local now
    now=$(nftban_timestamp_unix 2>/dev/null || date +%s)
    local banned=0

    for ip in "${!_BOTSCAN_IP_HITS[@]}"; do
        local hits="${_BOTSCAN_IP_HITS[$ip]}"
        local first_seen="${_BOTSCAN_IP_FIRST_SEEN[$ip]:-$now}"
        local time_window=$((now - first_seen))
        local patterns="${_BOTSCAN_IP_PATTERNS[$ip]:-}"

        # Get threshold from most severe matched pattern
        local threshold="$BOTSCAN_DEFAULT_THRESHOLD"
        local ban_duration="$BOTSCAN_DEFAULT_BAN_SHORT"
        local window="$BOTSCAN_DEFAULT_WINDOW"

        for pattern_name in $patterns; do
            [[ -z "$pattern_name" ]] && continue
            local def="${_BOTSCAN_PATTERNS[$pattern_name]:-}"
            [[ -z "$def" ]] && continue

            local p_threshold p_window p_ban
            IFS='|' read -r _ _ p_threshold p_window p_ban _ <<< "$def"

            # Use lowest threshold (most sensitive)
            [[ "$p_threshold" -lt "$threshold" ]] && threshold="$p_threshold"
            # Use longest ban
            [[ "$p_ban" -gt "$ban_duration" ]] && ban_duration="$p_ban"
            # Use shortest window
            [[ "$p_window" -lt "$window" ]] && window="$p_window"
        done

        # Check threshold
        if [[ "$hits" -ge "$threshold" && "$time_window" -le "$window" ]]; then
            nftban_botscan_ban_ip "$ip" "$ban_duration" "botscan" "Matched patterns: $patterns (hits: $hits)"
            banned=$((banned + 1))
        fi
    done

    # Check 404 flood (enforce BOTSCAN_404_WINDOW)
    if [[ "$BOTSCAN_404_TRACKING" == "true" ]]; then
        local now_ts
        now_ts=$(date +%s)
        for ip in "${!_BOTSCAN_IP_404_COUNT[@]}"; do
            local count="${_BOTSCAN_IP_404_COUNT[$ip]}"
            local first_seen="${_BOTSCAN_IP_404_FIRST_SEEN[$ip]:-$now_ts}"
            local elapsed=$(( now_ts - first_seen ))
            if [[ "$count" -ge "$BOTSCAN_404_THRESHOLD" && "$elapsed" -le "$BOTSCAN_404_WINDOW" ]]; then
                nftban_botscan_ban_ip "$ip" "$BOTSCAN_404_BAN" "botscan-404" "404 flood: $count in ${elapsed}s"
                banned=$((banned + 1))
            fi
        done
    fi

    return $banned
}

# Write a batch signal to JSONL for Go daemon (Clock 2) consumption
# Args: ip, score, action, reasons...
nftban_botscan_write_signal() {
    local ip="$1"
    local score="$2"
    local action="$3"
    shift 3
    local reasons=("$@")

    local signal_file="${BOTSCAN_BATCH_SIGNAL_FILE:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/botguard/batch_signals.jsonl}"

    # Build JSON reasons array
    local reasons_json="["
    local first=true
    for r in "${reasons[@]}"; do
        if [[ "$first" == "true" ]]; then
            reasons_json+="\"${r//\"/\\\"}\""
            first=false
        else
            reasons_json+=",\"${r//\"/\\\"}\""
        fi
    done
    reasons_json+="]"

    local ts
    ts=$(date +%s)

    # Atomic append (single write, no partial lines)
    printf '{"ip":"%s","score":%d,"reasons":%s,"action":"%s","ts":%d}\n' \
        "${ip//\"/\\\"}" "$score" "$reasons_json" "${action//\"/\\\"}" "$ts" \
        >> "$signal_file"
}

# Ban IP
nftban_botscan_ban_ip() {
    local ip="$1"
    local duration="$2"
    local source="$3"
    local reason="$4"

    [[ "$BOTSCAN_ACTION_MODE" == "alert" ]] && {
        echo "[ALERT] Would ban $ip for ${duration}s: $reason"
        return 0
    }

    # Clock 3 batch signal mode: write JSONL for Go daemon instead of direct ban
    if [[ "${BOTSCAN_BATCH_SIGNAL_MODE:-false}" == "true" ]]; then
        local score=80
        local action="ban"
        # Shorter bans → grey instead of ban
        if [[ "$duration" -le 1800 ]]; then
            score=50
            action="grey"
        fi
        nftban_botscan_write_signal "$ip" "$score" "$action" "$source" "$reason"
        echo "$(date -Iseconds)|$source|$ip|${duration}|SIGNAL|$reason" >> "$BOTSCAN_LOG_FILE"
        return 0
    fi

    # Direct ban mode (legacy/standalone)
    if type -t nftban_ban &>/dev/null; then
        nftban_ban "$ip" "$duration" "$source" "$reason"
    elif [[ -x "${NFTBAN_BIN:-/usr/sbin/nftban}" ]]; then
        "${NFTBAN_BIN:-/usr/sbin/nftban}" ban "$ip" --duration "$duration" --source "$source" --reason "$reason" 2>/dev/null
    else
        echo "[ERROR] Cannot ban $ip - nftban not available" >&2
        return 1
    fi

    # Log
    echo "$(date -Iseconds)|$source|$ip|${duration}|BANNED|$reason" >> "$BOTSCAN_LOG_FILE"

    return 0
}

# =============================================================================
# MAIN FUNCTIONS
# =============================================================================

# Process logs (main entry point)
nftban_botscan_process_logs() {
    local log_file="${1:-}"
    local time_window="${2:-60}"

    [[ "$BOTSCAN_ENABLED" != "true" ]] && {
        echo "Bot scanner is disabled"
        return 0
    }

    # Find log file
    if [[ -z "$log_file" ]]; then
        log_file=$(nftban_botscan_find_log)
        [[ -z "$log_file" ]] && {
            echo "ERROR: No access log found" >&2
            return 1
        }
    fi

    # Initialize
    nftban_botscan_init_state
    nftban_botscan_load_patterns

    echo "Processing: $log_file"
    echo "Patterns loaded: ${#_BOTSCAN_PATTERNS[@]}"

    # Process recent entries (last 1000 lines)
    local processed=0

    while IFS= read -r line; do
        local parsed
        parsed=$(nftban_botscan_parse_line "$line") || continue

        local ip url method status ua
        IFS='|' read -r ip url method status ua <<< "$parsed"

        nftban_botscan_process_entry "$ip" "$url" "$method" "$status" "$ua"
        processed=$((processed + 1))

    done < <(tail -1000 "$log_file")

    echo "Processed: $processed entries"
    echo "IPs tracked: ${#_BOTSCAN_IP_HITS[@]}"

    # Analyze and ban
    local banned
    banned=$(nftban_botscan_analyze) || banned=0
    echo "Banned: $banned IPs"

    return 0
}

# Check/run once
nftban_botscan_check() {
    nftban_botscan_load_config
    nftban_botscan_process_logs "$@"
}

# Status
nftban_botscan_status() {
    nftban_botscan_load_config

    echo "Bot Scanner Status"
    echo "=================="
    echo ""
    echo "Enabled:        $BOTSCAN_ENABLED"
    echo "Action Mode:    $BOTSCAN_ACTION_MODE"
    echo "Patterns Dir:   $BOTSCAN_PATTERNS_DIR"
    echo ""

    # Count patterns
    local total=0 enabled=0
    for pattern_file in "$BOTSCAN_PATTERNS_DIR"/*.patterns; do
        [[ -f "$pattern_file" ]] || continue
        while IFS='|' read -r name _ _ _ _ _ is_enabled _; do
            [[ -z "$name" || "$name" =~ ^# ]] && continue
            total=$((total + 1))
            [[ "$is_enabled" == "true" ]] && enabled=$((enabled + 1))
        done < "$pattern_file"
    done

    echo "Patterns:       $enabled enabled / $total total"
    echo ""

    # Log source
    local log
    log=$(nftban_botscan_find_log)
    echo "Log Source:     ${log:-NOT FOUND}"

    return 0
}

# Initialize on source
nftban_botscan_load_config
