#!/usr/bin/env bash

# =============================================================================
# NFTBan Feeds Module (Enhanced with Global Exclusion & Deduplication)
# Version: 2.4.1
# Author: ITCMS Team + AI Assistant
#
# Purpose:
#   Pulls external threat intelligence IP/CIDR feeds. Strictly enforces:
#   1. **Prior Exclusion:** IPs/CIDRs present in Whitelist or Persistent
#      Blacklist lists (from other modules) are IGNORED.
#   2. **Global Deduplication:** If an IP/CIDR exists in one feed, it is
#      IGNORED when encountered in any subsequent feed.
#   3. **Validation Ready:** Compatible with SHA256 validation system
# =============================================================================

set -euo pipefail

[[ -n "${NFTBAN_FEEDS_LOADED:-}" ]] && return 0
readonly NFTBAN_FEEDS_LOADED=1

# =============================================================================
# PATHS & CONSTANTS
# =============================================================================
readonly NFTBAN_FEEDS_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban/config}/feeds"
readonly NFTBAN_FEEDS_REGISTRY_FILE="${NFTBAN_FEEDS_CONFIG_DIR}/providers.tsv"
readonly NFTBAN_FEEDS_SETTINGS_FILE="${NFTBAN_FEEDS_CONFIG_DIR}/settings.conf"
readonly NFTBAN_FEEDS_CACHE_DIR="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/feeds"
readonly NFTBAN_FEEDS_LOG="${NFTBAN_LOG_DIR:-/var/log/nftban}/feeds.log"
readonly NFTBAN_FEEDS_LOCK_FILE="${NFTBAN_RUN_DIR:-/var/run/nftban}/nftban-feeds.lock"

# **PRIOR EXCLUSION TARGETS from other modules**
readonly NFTBAN_WHITELIST_SYSTEM="${NFTBAN_CONFIG_DIR:-/etc/nftban/config}/whitelist-system.conf"
readonly NFTBAN_WHITELIST_USER="${NFTBAN_CONFIG_DIR:-/etc/nftban/config}/whitelist-user.conf"
readonly NFTBAN_WHITELIST_CF="${NFTBAN_CONFIG_DIR:-/etc/nftban/config}/whitelist-cloudflare.conf"
readonly NFTBAN_BLACKLIST_PERSISTENT="${NFTBAN_CONFIG_DIR:-/etc/nftban/config}/blacklist-persistent.conf"

# Critical Binaries
readonly NFT_BIN="/usr/sbin/nft"
readonly CURL_BIN="/usr/bin/curl"
readonly WGET_BIN="/usr/bin/wget"
readonly FLOCK_BIN="/usr/bin/flock"
readonly SORT_BIN="/usr/bin/sort"
readonly AWK_BIN="/usr/bin/awk"
readonly GREP_BIN="/usr/bin/grep"
readonly HEAD_BIN="/usr/bin/head"
readonly WC_BIN="/usr/bin/wc"
readonly DATE_BIN="/usr/bin/date"
readonly TEE_BIN="/usr/bin/tee"
readonly MKDIR_BIN="/usr/bin/mkdir"
readonly CAT_BIN="/usr/bin/cat"

# nftables configuration
readonly NFTBAN_FEEDS_TABLE="${NFTBAN_NFT_TABLE:-nftban_global}"
readonly NFTBAN_FEEDS_FAMILY="${NFTBAN_NFT_FAMILY:-inet}"
readonly NFTBAN_FEEDS_SET_V4="feeds_v4"
readonly NFTBAN_FEEDS_SET_V6="feeds_v6"

# Memory safety limits (in MB)
NFTBAN_FEEDS_MEMORY_LIMIT="${NFTBAN_FEEDS_MEMORY_LIMIT:-512}"
NFTBAN_FEEDS_MAX_ENTRIES="${NFTBAN_FEEDS_MAX_ENTRIES:-500000}"

# Default configuration values
NFTBAN_FEEDS_UPDATE_INTERVAL="${NFTBAN_FEEDS_UPDATE_INTERVAL:-24h}"
NFTBAN_FEEDS_DOWNLOAD_TIMEOUT="${NFTBAN_FEEDS_DOWNLOAD_TIMEOUT:-20}"
NFTBAN_FEEDS_MIN_ENTRIES="${NFTBAN_FEEDS_MIN_ENTRIES:-50}"
NFTBAN_FEEDS_MAX_FAILURES="${NFTBAN_FEEDS_MAX_FAILURES:-3}"
NFTBAN_FEEDS_LARGE_CHANGE_ALERT_PERCENT="${NFTBAN_FEEDS_LARGE_CHANGE_ALERT_PERCENT:-30}"

# Systemd directory
readonly NFTBAN_SYSTEMD_DIR="${NFTBAN_SYSTEMD_DIR:-/etc/systemd/system}"
readonly NFTBAN_BASE_DIR="${NFTBAN_BASE_DIR:-/etc/nftban}"

# =============================================================================
# INTERNAL HELPER FUNCTIONS
# =============================================================================

_nftban_feeds_log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts=$("$DATE_BIN" '+%Y-%m-%d %H:%M:%S')
    "$MKDIR_BIN" -p "$(dirname "$NFTBAN_FEEDS_LOG")"
    echo "[$ts] [$level] $msg" | "$TEE_BIN" -a "$NFTBAN_FEEDS_LOG"
    
    if command -v nftban_log >/dev/null 2>&1; then
        nftban_log "FEEDS" "$level" "$msg"
    fi
}

_nftban_feeds_require() {
    local bin="$1"
    if ! command -v "$bin" > /dev/null 2>&1; then
        _nftban_feeds_log ERROR "Required command '$bin' not found. Cannot proceed."
        return 1
    fi
    return 0
}

_nftban_feeds_lock() {
    exec 9>"$NFTBAN_FEEDS_LOCK_FILE" || return 1
    "$FLOCK_BIN" -w 300 9 || { 
        _nftban_feeds_log ERROR "Could not acquire feeds lock (timeout: 300s)"
        return 1
    }
}

_nftban_feeds_unlock() { 
    exec 9>&- 2>/dev/null || true
    rm -f "$NFTBAN_FEEDS_LOCK_FILE" 2>/dev/null || true
}

_nftban_feeds_get_memory_usage() {
    if [[ -f /proc/self/status ]]; then
        "$GREP_BIN" VmRSS /proc/self/status | "$AWK_BIN" '{print $2}'
    else
        echo "0"
    fi
}

_nftban_feeds_check_memory_limit() {
    local current_mem_kb="$1"
    local limit_mb="$NFTBAN_FEEDS_MEMORY_LIMIT"
    local limit_kb=$((limit_mb * 1024))
    
    if [[ "$current_mem_kb" -gt "$limit_kb" ]]; then
        local current_mb=$((current_mem_kb / 1024))
        _nftban_feeds_log ERROR "Memory limit exceeded: ${current_mb}MB > ${limit_mb}MB"
        return 1
    fi
    return 0
}

_nftban_feeds_memory_safe_operation() {
    local operation="$1"
    local current_mem; current_mem=$(_nftban_feeds_get_memory_usage)
    
    if ! _nftban_feeds_check_memory_limit "$current_mem"; then
        _nftban_feeds_log ERROR "Memory safety check failed before: $operation"
        return 1
    fi
    
    shift
    "$@"
    
    current_mem=$(_nftban_feeds_get_memory_usage)
    if ! _nftban_feeds_check_memory_limit "$current_mem"; then
        _nftban_feeds_log ERROR "Memory safety check failed after: $operation"
        return 1
    fi
    return 0
}

# =============================================================================
# CORE DEDUPLICATION/UNIQUENESS FUNCTION
# =============================================================================
_nftban_feeds_make_unique_and_limit() {
    local input_file="$1"
    local output_file="$2"
    
    # 1. Enforce Uniqueness
    if command -v "$SORT_BIN" >/dev/null 2>&1; then
        "$SORT_BIN" -S 50% --temporary-directory="$NFTBAN_FEEDS_CACHE_DIR" -u "$input_file" > "$output_file"
    else
        "$AWK_BIN" '!seen[$0]++' "$input_file" > "$output_file"
    fi
    
    # 2. Apply Entry Limits
    local entry_count; entry_count=$("$WC_BIN" -l < "$output_file" 2>/dev/null || echo 0)
    if [[ "$entry_count" -gt "$NFTBAN_FEEDS_MAX_ENTRIES" ]]; then
        _nftban_feeds_log WARNING "Truncating entries from $entry_count to $NFTBAN_FEEDS_MAX_ENTRIES (safety limit)"
        "$HEAD_BIN" -n "$NFTBAN_FEEDS_MAX_ENTRIES" "$output_file" > "${output_file}.tmp"
        mv "${output_file}.tmp" "$output_file"
    fi
}

_nftban_feeds_deduplicate_file() {
    local input_file="$1"
    local output_file="$2"
    if [[ ! -f "$input_file" ]]; then return 1; fi
    
    local temp_file; temp_file=$(mktemp)
    _nftban_feeds_memory_safe_operation "deduplication" \
        _nftban_feeds_make_unique_and_limit "$input_file" "$temp_file"
    
    local original_count; original_count=$("$WC_BIN" -l < "$input_file" 2>/dev/null || echo 0)
    local dedup_count; dedup_count=$("$WC_BIN" -l < "$temp_file" 2>/dev/null || echo 0)
    local duplicates_removed=$((original_count - dedup_count))
    
    if [[ "$duplicates_removed" -gt 0 ]]; then
        _nftban_feeds_log INFO "Deduplication: Removed $duplicates_removed duplicate entries."
    fi
    
    mv "$temp_file" "$output_file"
    return 0
}

# =============================================================================
# PRIOR EXCLUSION CHECKS
# =============================================================================

_nftban_feeds_apply_exclusion_and_dedupe() {
    local input_file="$1"
    local output_file="$2"
    
    local temp_exclusion_list; temp_exclusion_list=$(mktemp)
    local temp_filtered; temp_filtered=$(mktemp)
    
    _nftban_feeds_log DEBUG "Performing prior exclusion checks against Whitelist/Blacklist modules."
    
    # 1. Build combined exclusion list
    "$CAT_BIN" "$NFTBAN_WHITELIST_SYSTEM" "$NFTBAN_WHITELIST_USER" "$NFTBAN_WHITELIST_CF" "$NFTBAN_BLACKLIST_PERSISTENT" 2>/dev/null >> "$temp_exclusion_list" || true
    
    # 2. Clean up the exclusion list
    if [[ -s "$temp_exclusion_list" ]]; then
        local temp_cleaned_list; temp_cleaned_list=$(mktemp)
        
        "$GREP_BIN" -vE '^(#|$)' "$temp_exclusion_list" 2>/dev/null | "$AWK_BIN" '{print $1}' | \
            _nftban_feeds_make_unique_and_limit /dev/stdin "$temp_cleaned_list"
        
        # 3. Filter the current feed against the combined exclusion list
        local original_count; original_count=$("$WC_BIN" -l < "$input_file" 2>/dev/null || echo 0)
        
        "$GREP_BIN" -Fvx -f "$temp_cleaned_list" "$input_file" 2>/dev/null > "$temp_filtered" || true
        
        local excluded_count=$((original_count - $("$WC_BIN" -l < "$temp_filtered" 2>/dev/null || echo 0)))
        if [[ "$excluded_count" -gt 0 ]]; then
            _nftban_feeds_log INFO "Prior Check: Excluded $excluded_count entries due to Whitelist/Persistent Blacklist modules."
        fi
        
        mv "$temp_filtered" "$input_file"
        rm -f "$temp_cleaned_list"
    else
        _nftban_feeds_log DEBUG "Prior exclusion list is empty. Skipping filtering."
    fi
    
    # 4. Deduplicate the resulting feed internally
    _nftban_feeds_deduplicate_file "$input_file" "$output_file"
    
    rm -f "$temp_exclusion_list" "$temp_filtered"
}

# =============================================================================
# IP/CIDR VALIDATION FUNCTIONS
# =============================================================================
_nftban_feeds_is_ipv4() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && {
        IFS='.' read -r a b c d <<<"$1"
        [[ $a -le 255 && $b -le 255 && $c -le 255 && $d -le 255 ]]
    }
}

_nftban_feeds_is_ipv6() {
    [[ $1 =~ : ]]
}

_nftban_feeds_is_cidr4() {
    [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]] && _nftban_feeds_is_ipv4 "${1%/*}"
}

_nftban_feeds_is_cidr6() {
    [[ $1 =~ ^[0-9a-fA-F:]+/[0-9]{1,3}$ ]] && [[ ${1#*/} -le 128 ]]
}

_nftban_feeds_is_token_valid() {
    local t="$1"
    if _nftban_feeds_is_ipv4 "$t" || _nftban_feeds_is_ipv6 "$t" || \
       _nftban_feeds_is_cidr4 "$t" || _nftban_feeds_is_cidr6 "$t"; then
        return 0
    fi
    return 1
}

_nftban_feeds_parse_tokens_file() {
    local input_file="$1"
    local output_file="$2"
    
    "$GREP_BIN" -vE '^(#|$)' "$input_file" 2>/dev/null | \
        "$AWK_BIN" '{print $1}' | \
        "$AWK_BIN" '{gsub(/\r/,""); print}' > "$output_file"
}

_nftban_feeds_filter_valid_file() {
    local input_file="$1"
    local output_file="$2"
    
    local temp_file; temp_file=$(mktemp)
    
    while IFS= read -r line; do
        if _nftban_feeds_is_token_valid "$line"; then
            echo "$line" >> "$temp_file"
        fi
    done < "$input_file"
    
    mv "$temp_file" "$output_file"
}

# =============================================================================
# REGISTRY & SETTINGS MANAGEMENT
# =============================================================================

_nftban_feeds_list_providers() {
    "$AWK_BIN" 'BEGIN{FS="\t"} /^#/ {next} NF>=5 {print $1"\t"$2"\t"$3"\t"$4"\t"$5"\t"$6"\t"$7}' "$NFTBAN_FEEDS_REGISTRY_FILE" 2>/dev/null
}

_nftban_feeds_update_registry_entry() {
    local id="$1"
    local field="$2"
    local value="$3"

    if [[ ! -f "$NFTBAN_FEEDS_REGISTRY_FILE" ]]; then return 1; fi

    local temp_reg_file; temp_reg_file=$(mktemp)

    "$AWK_BIN" -v id="$id" -v field_idx="$field" -v new_value="$value" '
        BEGIN{FS=OFS="\t"} 
        $1 == id {
            if (field_idx >= 1 && field_idx <= 7) {
                $field_idx = new_value
            }
        } 
        {print}
    ' "$NFTBAN_FEEDS_REGISTRY_FILE" > "$temp_reg_file"

    mv "$temp_reg_file" "$NFTBAN_FEEDS_REGISTRY_FILE"
}

_nftban_feeds_load_settings() {
    if [[ -f "$NFTBAN_FEEDS_SETTINGS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$NFTBAN_FEEDS_SETTINGS_FILE"
    else
        _nftban_feeds_save_settings
    fi
}

_nftban_feeds_save_settings() {
    "$MKDIR_BIN" -p "$(dirname "$NFTBAN_FEEDS_SETTINGS_FILE")"
    "$CAT_BIN" > "$NFTBAN_FEEDS_SETTINGS_FILE" << EOF
NFTBAN_FEEDS_UPDATE_INTERVAL="${NFTBAN_FEEDS_UPDATE_INTERVAL}"
NFTBAN_FEEDS_DOWNLOAD_TIMEOUT="${NFTBAN_FEEDS_DOWNLOAD_TIMEOUT}"
NFTBAN_FEEDS_MIN_ENTRIES="${NFTBAN_FEEDS_MIN_ENTRIES}"
NFTBAN_FEEDS_MAX_ENTRIES="${NFTBAN_FEEDS_MAX_ENTRIES}"
NFTBAN_FEEDS_MAX_FAILURES="${NFTBAN_FEEDS_MAX_FAILURES}"
NFTBAN_FEEDS_MEMORY_LIMIT="${NFTBAN_FEEDS_MEMORY_LIMIT}"
EOF
}

# =============================================================================
# MODULE INIT FUNCTION
# =============================================================================

nftban_feeds_init() {
    _nftban_feeds_log INFO "Initializing feeds module system..."
    
    "$MKDIR_BIN" -p "$NFTBAN_FEEDS_CONFIG_DIR" "$NFTBAN_FEEDS_CACHE_DIR" "${NFTBAN_RUN_DIR:-/var/run/nftban}"
    
    _nftban_feeds_load_settings
    nftban_feeds_timer_remove 2>/dev/null || true

    if [[ ! -f "$NFTBAN_FEEDS_REGISTRY_FILE" ]]; then
        _nftban_feeds_log INFO "Creating default feed providers registry (all disabled)"
        "$CAT_BIN" > "$NFTBAN_FEEDS_REGISTRY_FILE" << 'EOF'
# id	name	url	type	enabled	failures	last_success
spamhaus	Spamhaus DROP	http://www.spamhaus.org/drop/drop.lasso	ip4	false	0	0
dshield	DShield Top 20	https://isc.sans.edu/feeds/top20.txt	ip4	false	0	0
EOF
    fi

    _nftban_feeds_log INFO "Feeds module initialized."
}

# =============================================================================
# FEED PROCESSING
# =============================================================================

_nftban_feeds_process_feed_safe() {
    local provider_id="$1"
    local input_file="$2"
    local output_file="$3"

    if [[ ! -f "$input_file" ]]; then return 1; fi
    
    local temp_stage1; temp_stage1=$(mktemp)
    local temp_stage2; temp_stage2=$(mktemp)
    
    _nftban_feeds_log INFO "Processing feed $provider_id: Parsing, Validation, and Prior Exclusion."

    _nftban_feeds_memory_safe_operation "parsing" \
        _nftban_feeds_parse_tokens_file "$input_file" "$temp_stage1"
    
    _nftban_feeds_memory_safe_operation "validation" \
        _nftban_feeds_filter_valid_file "$temp_stage1" "$temp_stage2"
    
    _nftban_feeds_memory_safe_operation "prior_exclusion" \
        _nftban_feeds_apply_exclusion_and_dedupe "$temp_stage2" "$output_file"
    
    rm -f "$temp_stage1" "$temp_stage2"
}

_nftban_feeds_download_feed() {
    local id="$1" url="$2"
    local output_file="${NFTBAN_FEEDS_CACHE_DIR}/${id}.tmp"
    
    _nftban_feeds_log DEBUG "Downloading $id from $url"
    
    if "$CURL_BIN" --max-time "$NFTBAN_FEEDS_DOWNLOAD_TIMEOUT" --silent --location --compressed "$url" > "$output_file" 2>/dev/null; then
        _nftban_feeds_log DEBUG "Download success for $id."
        return 0
    else
        _nftban_feeds_log ERROR "Download failed for $id."
        return 1
    fi
}

# =============================================================================
# NFTABLES SYNC
# =============================================================================
_nftban_feeds_update_nftables() {
    local final_file="$1"
    
    _nftban_feeds_log INFO "Syncing final feeds list to nftables sets: ${NFTBAN_FEEDS_SET_V4} and ${NFTBAN_FEEDS_SET_V6}"

    "$NFT_BIN" flush set "${NFTBAN_FEEDS_FAMILY}" "${NFTBAN_FEEDS_TABLE}" "${NFTBAN_FEEDS_SET_V4}" 2>/dev/null || true
    "$NFT_BIN" flush set "${NFTBAN_FEEDS_FAMILY}" "${NFTBAN_FEEDS_TABLE}" "${NFTBAN_FEEDS_SET_V6}" 2>/dev/null || true
    
    local ipv4_count=0
    local ipv6_count=0

    while IFS= read -r line; do
        if _nftban_feeds_is_ipv4 "$line" || _nftban_feeds_is_cidr4 "$line"; then
            "$NFT_BIN" add element "${NFTBAN_FEEDS_FAMILY}" "${NFTBAN_FEEDS_TABLE}" "${NFTBAN_FEEDS_SET_V4}" "{ $line }" 2>/dev/null || true
            ipv4_count=$((ipv4_count + 1))
        elif _nftban_feeds_is_ipv6 "$line" || _nftban_feeds_is_cidr6 "$line"; then
            "$NFT_BIN" add element "${NFTBAN_FEEDS_FAMILY}" "${NFTBAN_FEEDS_TABLE}" "${NFTBAN_FEEDS_SET_V6}" "{ $line }" 2>/dev/null || true
            ipv6_count=$((ipv6_count + 1))
        fi
    done < "$final_file"

    _nftban_feeds_log SUCCESS "NFTables sync complete. IPv4: $ipv4_count | IPv6: $ipv6_count"
    return 0
}

# =============================================================================
# MAIN UPDATE FUNCTION
# =============================================================================

nftban_feeds_update() {
    local target_id="${1:-}"
    
    if ! _nftban_feeds_lock; then return 1; fi
    
    _nftban_feeds_log INFO "Starting feed update cycle."
    _nftban_feeds_load_settings
    
    local processed_files=()
    local temp_aggregate; temp_aggregate=$(mktemp)
    local temp_dedup; temp_dedup=$(mktemp)
    
    while IFS=$'\t' read -r id name url type enabled failures last_success; do
        [[ -z "$id" || "$id" =~ ^# ]] && continue
        
        if [[ "$enabled" != "true" ]]; then continue; fi
        if [[ -n "$target_id" && "$id" != "$target_id" ]]; then continue; fi
        
        _nftban_feeds_log INFO "Processing provider: $id"
        
        if _nftban_feeds_download_feed "$id" "$url"; then
            local temp_processed; temp_processed=$(mktemp)
            
            if _nftban_feeds_process_feed_safe "$id" "${NFTBAN_FEEDS_CACHE_DIR}/${id}.tmp" "$temp_processed"; then
                _nftban_feeds_log SUCCESS "Provider $id processed successfully."
                
                if [[ -s "$temp_processed" ]]; then
                    "$CAT_BIN" "$temp_processed" >> "$temp_aggregate"
                fi

                processed_files+=("$temp_processed")
                _nftban_feeds_update_registry_entry "$id" 6 "0"
                _nftban_feeds_update_registry_entry "$id" 7 "$("$DATE_BIN" +%s)"
            else
                _nftban_feeds_log ERROR "Provider $id failed during processing."
                _nftban_feeds_update_registry_entry "$id" 6 "$(("$failures" + 1))"
            fi
        fi
        
    done < <(_nftban_feeds_list_providers)

    if [[ -s "$temp_aggregate" ]]; then
        _nftban_feeds_log INFO "Applying FINAL GLOBAL DEDUPLICATION across all feeds..."
        _nftban_feeds_deduplicate_file "$temp_aggregate" "$temp_dedup"
        _nftban_feeds_log INFO "Aggregation complete. Total unique entries: $("$WC_BIN" -l < "$temp_dedup")"
        _nftban_feeds_update_nftables "$temp_dedup"
    else
        _nftban_feeds_log WARNING "No valid entries collected from any feed."
    fi

    rm -f "$temp_aggregate" "$temp_dedup"
    for file in "${processed_files[@]}"; do rm -f "$file"; done
    
    _nftban_feeds_unlock
    _nftban_feeds_log INFO "Feed update cycle finished."
    return 0
}

# =============================================================================
# CLI INTEGRATION
# =============================================================================

nftban_feeds_list() {
    _nftban_feeds_init_registry 2>/dev/null || true
    
    printf "%-20s %-30s %-10s %-8s %-8s\n" "ID" "Name" "Type" "Enabled" "Failures"
    echo "-------------------------------------------------------------------------------"
    
    while IFS=$'\t' read -r id name url type enabled failures last_success; do
        [[ -z "$id" || "$id" =~ ^# ]] && continue
        printf "%-20s %-30s %-10s %-8s %-8s\n" "$id" "$name" "$type" "$enabled" "$failures"
    done < <(_nftban_feeds_list_providers)
}

nftban_feeds_enable_provider() {
    local id="$1"
    if [[ -z "$id" ]]; then
        _nftban_feeds_log ERROR "Usage: nftban feeds enable <provider_id>"
        return 1
    fi
    _nftban_feeds_update_registry_entry "$id" 5 "true"
    _nftban_feeds_log INFO "Provider '$id' enabled."
}

nftban_feeds_disable_provider() {
    local id="$1"
    if [[ -z "$id" ]]; then
        _nftban_feeds_log ERROR "Usage: nftban feeds disable <provider_id>"
        return 1
    fi
    _nftban_feeds_update_registry_entry "$id" 5 "false"
    _nftban_feeds_log INFO "Provider '$id' disabled."
}

nftban_feeds_status() {
    _nftban_feeds_log INFO "Feeds Status"
    echo "======================================================"
    nftban_feeds_memory_status
    echo "Update Interval: ${NFTBAN_FEEDS_UPDATE_INTERVAL}"
    echo "Max Entries: ${NFTBAN_FEEDS_MAX_ENTRIES}"
    echo "Max Failures: ${NFTBAN_FEEDS_MAX_FAILURES}"
    echo "Config Dir: ${NFTBAN_FEEDS_CONFIG_DIR}"
    echo "Cache Dir: ${NFTBAN_FEEDS_CACHE_DIR}"
}

nftban_feeds_set_interval() {
    local interval="$1"
    if [[ -z "$interval" ]]; then
        _nftban_feeds_log ERROR "Usage: nftban feeds set-interval <12h|24h|48h|minutes>"
        return 1
    fi
    
    NFTBAN_FEEDS_UPDATE_INTERVAL="$interval"
    _nftban_feeds_save_settings
    _nftban_feeds_log INFO "Update interval set to: $interval"
}

nftban_feeds_timer_install() {
    _nftban_feeds_log INFO "Installing systemd timer..."
    
    local service_file="${NFTBAN_SYSTEMD_DIR}/nftban-feeds.service"
    local timer_file="${NFTBAN_SYSTEMD_DIR}/nftban-feeds.timer"
    local on_calendar_setting="OnCalendar=*-*-* 00:00:00"

    case "$NFTBAN_FEEDS_UPDATE_INTERVAL" in
        12h) on_calendar_setting="OnCalendar=*-*-* 0/12:00:00" ;;
        24h) on_calendar_setting="OnCalendar=*-*-* 00:00:00" ;;
        48h) on_calendar_setting="OnCalendar=*-*-* 00:00:00" ;;
        *) on_calendar_setting="OnUnitActiveSec=$NFTBAN_FEEDS_UPDATE_INTERVAL" ;;
    esac

    "$MKDIR_BIN" -p "$NFTBAN_SYSTEMD_DIR"
    "$CAT_BIN" > "$service_file" << EOF
[Unit]
Description=NFTBan Feeds Update Service
After=network.target

[Service]
Type=oneshot
ExecStart=${NFTBAN_BASE_DIR}/bin/nftban feeds update
User=root
WorkingDirectory=${NFTBAN_BASE_DIR}
StandardOutput=journal
StandardError=journal
EOF

    "$CAT_BIN" > "$timer_file" << EOF
[Unit]
Description=Runs NFTBan feeds update timer

[Timer]
$on_calendar_setting
AccuracySec=1m
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    systemctl daemon-reload
    systemctl enable nftban-feeds.timer
    systemctl start nftban-feeds.timer
    _nftban_feeds_log SUCCESS "Systemd timer installed and started."
}

nftban_feeds_timer_remove() {
    _nftban_feeds_log INFO "Removing systemd timer..."
    
    if systemctl is-enabled nftban-feeds.timer >/dev/null 2>&1; then
        systemctl stop nftban-feeds.timer
        systemctl disable nftban-feeds.timer
    fi
    
    rm -f "${NFTBAN_SYSTEMD_DIR}/nftban-feeds.service"
    rm -f "${NFTBAN_SYSTEMD_DIR}/nftban-feeds.timer"
    systemctl daemon-reload
    _nftban_feeds_log SUCCESS "Systemd timer removed."
}

nftban_feeds_memory_status() {
    local current_mem_kb=$(_nftban_feeds_get_memory_usage)
    local current_mem_mb=$((current_mem_kb / 1024))
    
    echo "Memory Usage:"
    printf "  Process RSS: %d KB (%d MB)\n" "$current_mem_kb" "$current_mem_mb"
    echo "  Configured Limit: ${NFTBAN_FEEDS_MEMORY_LIMIT} MB"
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_feeds_init
export -f nftban_feeds_list
export -f nftban_feeds_enable_provider
export -f nftban_feeds_disable_provider
export -f nftban_feeds_update
export -f nftban_feeds_status
export -f nftban_feeds_set_interval
export -f nftban_feeds_timer_install
export -f nftban_feeds_timer_remove
export -f nftban_feeds_memory_status
export -f _nftban_feeds_list_providers

# =============================================================================
# MODULE LOADED
# =============================================================================
if command -v nftban_log_debug >/dev/null 2>&1; then
    nftban_log_debug "NFTBan Feeds Module v2.4.1 loaded"
fi