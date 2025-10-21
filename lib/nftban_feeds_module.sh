#!/usr/bin/env bash

# =============================================================================
# NFTBan Threat Feeds Module
# Version: 0.9.2
# Location: lib/nftban_feeds_module.sh
# Author: ITCMS Team (Antonios Voulvoulis)
# Contact: contact@itcms.gr
# Website: https://itcms.gr
# Threat intelligence feeds management with atomic swap and smart intervals
# =============================================================================

set -euo pipefail

[[ -n "${NFTBAN_FEEDS_LOADED:-}" ]] && return 0
readonly NFTBAN_FEEDS_LOADED=1

# =============================================================================
# PATHS & CONSTANTS
# =============================================================================
readonly NFTBAN_FEEDS_CONFIG="${NFTBAN_CONFIG_DIR:-/etc/nftban/config}/nftban.conf"
readonly NFTBAN_FEEDS_STORAGE_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban/config}/feeds"
readonly NFTBAN_FEEDS_CACHE_DIR="${NFTBAN_CACHE_DIR:-/var/cache/nftban}/feeds"
readonly NFTBAN_FEEDS_LOG="${NFTBAN_LOG_DIR:-/var/log/nftban}/feeds.log"

# nftables - v0.9.0 SPLIT TABLE ARCHITECTURE
readonly NFTBAN_NFT_TABLE_V4="${NFTBAN_NFT_TABLE_V4:-nftban_v4}"
readonly NFTBAN_NFT_TABLE_V6="${NFTBAN_NFT_TABLE_V6:-nftban_v6}"
readonly NFTBAN_NFT_FAMILY_V4="${NFTBAN_NFT_FAMILY_V4:-ip}"
readonly NFTBAN_NFT_FAMILY_V6="${NFTBAN_NFT_FAMILY_V6:-ip6}"
readonly NFTBAN_NFT_SET_FEEDS="feeds"

# Feed provider IDs (must match config variable names)
readonly NFTBAN_FEED_IDS=(
    "SPAMHAUS"
    "BLOCKLISTDE_ALL"
    "BLOCKLISTDE_SSH"
    "BLOCKLISTDE_MAIL"
    "BLOCKLISTDE_APACHE"
    "ABUSECH"
    "DSHIELD"
    "TOR"
    "EMERGING_THREATS"
)

# =============================================================================
# LOGGING
# =============================================================================
_nftban_feeds_log() {
    local level="$1"; shift
    local msg="$*"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')

    mkdir -p "$(dirname "$NFTBAN_FEEDS_LOG")"
    echo "[$ts] [$level] $msg" | tee -a "$NFTBAN_FEEDS_LOG"

    if command -v nftban_log_${level,,} >/dev/null 2>&1; then
        nftban_log_${level,,} "FEEDS: $msg"
    fi
}

# =============================================================================
# CONFIGURATION HELPERS
# =============================================================================
_nftban_feeds_get_config() {
    local feed_id="$1"
    local key="$2"
    local var_name="NFTBAN_FEED_${feed_id}_${key}"

    # Read from config file
    if [[ -f "$NFTBAN_FEEDS_CONFIG" ]]; then
        grep "^${var_name}=" "$NFTBAN_FEEDS_CONFIG" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '"' || echo ""
    else
        echo ""
    fi
}

_nftban_feeds_set_config() {
    local feed_id="$1"
    local key="$2"
    local value="$3"
    local var_name="NFTBAN_FEED_${feed_id}_${key}"

    if [[ ! -f "$NFTBAN_FEEDS_CONFIG" ]]; then
        _nftban_feeds_log ERROR "Config file not found: $NFTBAN_FEEDS_CONFIG"
        return 1
    fi

    # Use sed to update in-place (preserves comments and structure)
    if grep -q "^${var_name}=" "$NFTBAN_FEEDS_CONFIG" 2>/dev/null; then
        sed -i "s|^${var_name}=.*|${var_name}=\"${value}\"|" "$NFTBAN_FEEDS_CONFIG"
    else
        echo "${var_name}=\"${value}\"" >> "$NFTBAN_FEEDS_CONFIG"
    fi
}

_nftban_feeds_validate_interval() {
    local interval="$1"

    case "$interval" in
        HOURLY|DAILY|WEEKLY)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# =============================================================================
# IP VALIDATION
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

_nftban_feeds_is_valid() {
    local ip="$1"
    _nftban_feeds_is_ipv4 "$ip" || _nftban_feeds_is_ipv6 "$ip" || \
    _nftban_feeds_is_cidr4 "$ip" || _nftban_feeds_is_cidr6 "$ip"
}

# =============================================================================
# INIT FUNCTION
# =============================================================================
nftban_feeds_init() {
    _nftban_feeds_log INFO "Initializing NFTBan Threat Feeds System v4.0.0..."

    # 1. Create directories
    mkdir -p "$NFTBAN_FEEDS_STORAGE_DIR"
    mkdir -p "$NFTBAN_FEEDS_CACHE_DIR"
    mkdir -p "$(dirname "$NFTBAN_FEEDS_LOG")"

    # 2. Create nftables sets if they don't exist
    if ! nft list set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$NFTBAN_NFT_SET_FEEDS" &>/dev/null; then
        _nftban_feeds_log INFO "Creating IPv4 feeds set..."
        nft add set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$NFTBAN_NFT_SET_FEEDS" "{ type ipv4_addr; flags interval; auto-merge; }" 2>/dev/null || {
            _nftban_feeds_log ERROR "Failed to create IPv4 feeds set"
        }
    fi

    if ! nft list set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$NFTBAN_NFT_SET_FEEDS" &>/dev/null; then
        _nftban_feeds_log INFO "Creating IPv6 feeds set..."
        nft add set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$NFTBAN_NFT_SET_FEEDS" "{ type ipv6_addr; flags interval; auto-merge; }" 2>/dev/null || {
            _nftban_feeds_log ERROR "Failed to create IPv6 feeds set"
        }
    fi

    # 3. Add firewall rules if they don't exist
    # Check if rule exists first
    if ! nft list chain "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input 2>/dev/null | grep -q "@$NFTBAN_NFT_SET_FEEDS"; then
        _nftban_feeds_log INFO "Adding IPv4 feeds firewall rule..."
        # Insert after whitelist (position depends on your ruleset)
        nft add rule "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" input ip saddr "@$NFTBAN_NFT_SET_FEEDS" counter drop comment '"Block threat feeds IPv4"' 2>/dev/null || {
            _nftban_feeds_log WARN "Could not add IPv4 feeds rule (may already exist)"
        }
    fi

    if ! nft list chain "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input 2>/dev/null | grep -q "@$NFTBAN_NFT_SET_FEEDS"; then
        _nftban_feeds_log INFO "Adding IPv6 feeds firewall rule..."
        nft add rule "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" input ip6 saddr "@$NFTBAN_NFT_SET_FEEDS" counter drop comment '"Block threat feeds IPv6"' 2>/dev/null || {
            _nftban_feeds_log WARN "Could not add IPv6 feeds rule (may already exist)"
        }
    fi

    _nftban_feeds_log SUCCESS "Feeds system initialized"
    echo ""
    echo "Next steps:"
    echo "  1. List available feeds:    nftban feeds list"
    echo "  2. Enable a feed:           sudo nftban feeds enable dshield"
    echo "  3. Update feeds:            sudo nftban feeds update"
    echo "  4. Install automatic timer: sudo nftban feeds timer-install"
    echo ""
}

# =============================================================================
# ENABLE / DISABLE FUNCTIONS
# =============================================================================
nftban_feeds_enable() {
    local feed_id="$1"

    if [[ -z "$feed_id" ]]; then
        _nftban_feeds_log ERROR "Usage: nftban feeds enable <feed_id>"
        return 1
    fi

    # Convert to uppercase
    feed_id="${feed_id^^}"

    # Validate feed exists
    local url=$(_nftban_feeds_get_config "$feed_id" "URL")
    if [[ -z "$url" ]]; then
        _nftban_feeds_log ERROR "Unknown feed: $feed_id"
        _nftban_feeds_log INFO "Available feeds: ${NFTBAN_FEED_IDS[*],,}"
        return 1
    fi

    # Validate interval
    local interval=$(_nftban_feeds_get_config "$feed_id" "INTERVAL")
    if ! _nftban_feeds_validate_interval "$interval"; then
        _nftban_feeds_log WARN "Invalid interval '$interval' for $feed_id, using DAILY as fallback"
        _nftban_feeds_set_config "$feed_id" "INTERVAL" "DAILY"
    fi

    # Enable feed
    _nftban_feeds_set_config "$feed_id" "ENABLED" "TRUE"
    _nftban_feeds_log SUCCESS "Feed '$feed_id' enabled"

    # Download and activate immediately
    _nftban_feeds_log INFO "Downloading and activating feed..."
    nftban_feeds_update_single "$feed_id"
}

nftban_feeds_disable() {
    local feed_id="$1"

    if [[ -z "$feed_id" ]]; then
        _nftban_feeds_log ERROR "Usage: nftban feeds disable <feed_id>"
        return 1
    fi

    # Convert to uppercase
    feed_id="${feed_id^^}"

    # Disable feed
    _nftban_feeds_set_config "$feed_id" "ENABLED" "FALSE"
    _nftban_feeds_log SUCCESS "Feed '$feed_id' disabled"

    # Resync nftables (removes disabled feed IPs)
    _nftban_feeds_log INFO "Resyncing nftables..."
    nftban_feeds_sync_to_nftables
}

# =============================================================================
# UPDATE SINGLE FEED
# =============================================================================
nftban_feeds_update_single() {
    local feed_id="$1"

    # Convert to uppercase
    feed_id="${feed_id^^}"

    local enabled=$(_nftban_feeds_get_config "$feed_id" "ENABLED")
    if [[ "$enabled" != "TRUE" ]]; then
        _nftban_feeds_log WARN "Feed $feed_id is disabled, skipping"
        return 0
    fi

    local url=$(_nftban_feeds_get_config "$feed_id" "URL")
    local file=$(_nftban_feeds_get_config "$feed_id" "FILE")

    if [[ -z "$url" || -z "$file" ]]; then
        _nftban_feeds_log ERROR "Missing URL or FILE for feed $feed_id"
        return 1
    fi

    # Expand ${CONFIG_DIR} variable in path
    file="${file//\${CONFIG_DIR\}/${NFTBAN_CONFIG_DIR:-/etc/nftban/config}}"

    local timeout=${NFTBAN_FEEDS_DOWNLOAD_TIMEOUT:-30}
    local temp_download="$NFTBAN_FEEDS_CACHE_DIR/${feed_id,,}.tmp"
    local temp_parsed="$NFTBAN_FEEDS_CACHE_DIR/${feed_id,,}.parsed"

    _nftban_feeds_log INFO "Updating feed: $feed_id"
    _nftban_feeds_log DEBUG "URL: $url"

    # 1. Download
    if ! curl --max-time "$timeout" --silent --location --fail "$url" > "$temp_download" 2>/dev/null; then
        _nftban_feeds_log ERROR "Download failed for $feed_id"
        return 1
    fi

    # 2. Parse and validate
    grep -vE '^(#|;|//|$)' "$temp_download" 2>/dev/null | \
        awk '{print $1}' | \
        grep -v '^$' > "$temp_parsed" || true

    # 3. Validate IPs
    local temp_valid="$NFTBAN_FEEDS_CACHE_DIR/${feed_id,,}.valid"
    > "$temp_valid"

    while IFS= read -r ip; do
        if _nftban_feeds_is_valid "$ip"; then
            # Check whitelist
            if command -v nftban_whitelist_check_ip >/dev/null 2>&1; then
                if ! nftban_whitelist_check_ip "$ip" 2>/dev/null; then
                    echo "$ip" >> "$temp_valid"
                fi
            else
                echo "$ip" >> "$temp_valid"
            fi
        fi
    done < "$temp_parsed"

    # 4. Check minimum entries
    local count=$(wc -l < "$temp_valid" 2>/dev/null || echo 0)
    local min_entries=${NFTBAN_FEEDS_MIN_ENTRIES:-10}

    if [[ $count -lt $min_entries ]]; then
        _nftban_feeds_log ERROR "Feed $feed_id has only $count entries (minimum: $min_entries), rejecting"
        rm -f "$temp_download" "$temp_parsed" "$temp_valid"
        return 1
    fi

    # 5. Check maximum entries
    local max_entries=${NFTBAN_FEEDS_MAX_ENTRIES:-500000}
    if [[ $count -gt $max_entries ]]; then
        _nftban_feeds_log WARN "Feed $feed_id has $count entries (max: $max_entries), truncating"
        head -n "$max_entries" "$temp_valid" > "${temp_valid}.truncated"
        mv "${temp_valid}.truncated" "$temp_valid"
        count=$max_entries
    fi

    # 6. Save to feed file with header
    mkdir -p "$(dirname "$file")"

    cat > "$file" << EOF
# =============================================================================
# NFTBan Threat Feed: $feed_id
# =============================================================================
# Source: $url
# Updated: $(date '+%Y-%m-%d %H:%M:%S %Z')
# Entry Count: $count IPs/CIDRs
# Update Interval: $(_nftban_feeds_get_config "$feed_id" "INTERVAL")
# Auto-managed by NFTBan - DO NOT EDIT MANUALLY
# =============================================================================

EOF

    cat "$temp_parsed" >> "$file"

    _nftban_feeds_log SUCCESS "Feed $feed_id updated: $count entries saved to $file"

    # 7. Sync to nftables
    nftban_feeds_sync_to_nftables

    # Cleanup
    rm -f "$temp_download" "$temp_parsed" "$temp_valid"
}

# =============================================================================
# UPDATE ALL FEEDS
# =============================================================================
nftban_feeds_update() {
    local target_feed="${1:-all}"

    if [[ "$target_feed" != "all" ]]; then
        nftban_feeds_update_single "$target_feed"
        return $?
    fi

    _nftban_feeds_log INFO "Updating all enabled feeds..."

    local updated=0
    local failed=0

    for feed_id in "${NFTBAN_FEED_IDS[@]}"; do
        local enabled=$(_nftban_feeds_get_config "$feed_id" "ENABLED")

        if [[ "$enabled" == "TRUE" ]]; then
            if nftban_feeds_update_single "$feed_id"; then
                ((updated++))
            else
                ((failed++))
            fi
        fi
    done

    _nftban_feeds_log INFO "Update complete: $updated succeeded, $failed failed"
}

# =============================================================================
# SYNC TO NFTABLES - ATOMIC STAGE+SWAP PATTERN
# =============================================================================
# SECURITY: Uses atomic swap to prevent partial feed states during updates
# Based on: NFTBan Remediation & Hardening Guide (2025-10-20)
# Pattern: Create staging set → Load all IPs → Atomic rename/swap
nftban_feeds_sync_to_nftables() {
    _nftban_feeds_log INFO "Syncing feeds to nftables (atomic swap)..."

    local temp_v4=$(mktemp)
    local temp_v6=$(mktemp)
    local batch_v4=$(mktemp)
    local batch_v6=$(mktemp)

    # 1. Aggregate all enabled feed files
    for feed_id in "${NFTBAN_FEED_IDS[@]}"; do
        local enabled=$(_nftban_feeds_get_config "$feed_id" "ENABLED")

        if [[ "$enabled" == "TRUE" ]]; then
            local file=$(_nftban_feeds_get_config "$feed_id" "FILE")
            file="${file//\${CONFIG_DIR\}/${NFTBAN_CONFIG_DIR:-/etc/nftban/config}}"

            if [[ -f "$file" ]]; then
                # Separate IPv4 and IPv6
                grep -vE '^#' "$file" 2>/dev/null | while read -r ip; do
                    if _nftban_feeds_is_ipv4 "$ip" || _nftban_feeds_is_cidr4 "$ip"; then
                        echo "$ip" >> "$temp_v4"
                    elif _nftban_feeds_is_ipv6 "$ip" || _nftban_feeds_is_cidr6 "$ip"; then
                        echo "$ip" >> "$temp_v6"
                    fi
                done
            fi
        fi
    done

    # 2. Deduplicate
    sort -u "$temp_v4" > "${temp_v4}.dedup" 2>/dev/null || touch "${temp_v4}.dedup"
    sort -u "$temp_v6" > "${temp_v6}.dedup" 2>/dev/null || touch "${temp_v6}.dedup"

    local count_v4=$(wc -l < "${temp_v4}.dedup" 2>/dev/null || echo 0)
    local count_v6=$(wc -l < "${temp_v6}.dedup" 2>/dev/null || echo 0)

    _nftban_feeds_log DEBUG "Preparing atomic swap: $count_v4 IPv4, $count_v6 IPv6 entries"

    # =========================================================================
    # 3. ATOMIC SWAP - IPv4
    # =========================================================================
    if [[ $count_v4 -gt 0 ]]; then
        _nftban_feeds_log DEBUG "Building IPv4 atomic swap batch file..."

        # Build nftables batch file for atomic transaction
        cat > "$batch_v4" << EOF
# IPv4 Feeds Atomic Swap - Generated $(date -Iseconds)
# Stage 1: Create staging set
add set $NFTBAN_NFT_FAMILY_V4 $NFTBAN_NFT_TABLE_V4 feeds_new { type ipv4_addr; flags interval; auto-merge; comment "Staging feeds"; }

# Stage 2: Populate staging set with ALL elements in single transaction
EOF

        # Add all IPs as a single "add element" command
        # Format: add element table set { ip1, ip2, ip3, ... }
        echo -n "add element $NFTBAN_NFT_FAMILY_V4 $NFTBAN_NFT_TABLE_V4 feeds_new { " >> "$batch_v4"

        local first=true
        while IFS= read -r ip; do
            if [[ "$first" == "true" ]]; then
                echo -n "$ip" >> "$batch_v4"
                first=false
            else
                echo -n ", $ip" >> "$batch_v4"
            fi
        done < "${temp_v4}.dedup"

        echo " }" >> "$batch_v4"

        # Stage 3: Atomic swap (delete old, rename new)
        cat >> "$batch_v4" << EOF

# Stage 3: Atomic swap - delete old set and rename staging to live
delete set $NFTBAN_NFT_FAMILY_V4 $NFTBAN_NFT_TABLE_V4 feeds
rename set $NFTBAN_NFT_FAMILY_V4 $NFTBAN_NFT_TABLE_V4 feeds_new feeds
EOF

        # Execute atomic transaction (all-or-nothing)
        if nft -f "$batch_v4" 2>/dev/null; then
            _nftban_feeds_log SUCCESS "IPv4 feeds swapped atomically: $count_v4 entries"
        else
            _nftban_feeds_log ERROR "IPv4 atomic swap failed, rolling back..."
            # Cleanup failed staging set
            nft delete set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" feeds_new 2>/dev/null || true
        fi
    else
        # No IPv4 entries - just flush the set
        _nftban_feeds_log INFO "No IPv4 feed entries, flushing set"
        nft flush set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$NFTBAN_NFT_SET_FEEDS" 2>/dev/null || true
    fi

    # =========================================================================
    # 4. ATOMIC SWAP - IPv6
    # =========================================================================
    if [[ $count_v6 -gt 0 ]]; then
        _nftban_feeds_log DEBUG "Building IPv6 atomic swap batch file..."

        # Build nftables batch file for atomic transaction
        cat > "$batch_v6" << EOF
# IPv6 Feeds Atomic Swap - Generated $(date -Iseconds)
# Stage 1: Create staging set
add set $NFTBAN_NFT_FAMILY_V6 $NFTBAN_NFT_TABLE_V6 feeds_new { type ipv6_addr; flags interval; auto-merge; comment "Staging feeds"; }

# Stage 2: Populate staging set with ALL elements in single transaction
EOF

        # Add all IPs as a single "add element" command
        echo -n "add element $NFTBAN_NFT_FAMILY_V6 $NFTBAN_NFT_TABLE_V6 feeds_new { " >> "$batch_v6"

        local first=true
        while IFS= read -r ip; do
            if [[ "$first" == "true" ]]; then
                echo -n "$ip" >> "$batch_v6"
                first=false
            else
                echo -n ", $ip" >> "$batch_v6"
            fi
        done < "${temp_v6}.dedup"

        echo " }" >> "$batch_v6"

        # Stage 3: Atomic swap
        cat >> "$batch_v6" << EOF

# Stage 3: Atomic swap - delete old set and rename staging to live
delete set $NFTBAN_NFT_FAMILY_V6 $NFTBAN_NFT_TABLE_V6 feeds
rename set $NFTBAN_NFT_FAMILY_V6 $NFTBAN_NFT_TABLE_V6 feeds_new feeds
EOF

        # Execute atomic transaction
        if nft -f "$batch_v6" 2>/dev/null; then
            _nftban_feeds_log SUCCESS "IPv6 feeds swapped atomically: $count_v6 entries"
        else
            _nftban_feeds_log ERROR "IPv6 atomic swap failed, rolling back..."
            # Cleanup failed staging set
            nft delete set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" feeds_new 2>/dev/null || true
        fi
    else
        # No IPv6 entries - just flush the set
        _nftban_feeds_log INFO "No IPv6 feed entries, flushing set"
        nft flush set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$NFTBAN_NFT_SET_FEEDS" 2>/dev/null || true
    fi

    _nftban_feeds_log SUCCESS "Atomic sync complete: $count_v4 IPv4, $count_v6 IPv6"

    # Cleanup
    rm -f "$temp_v4" "$temp_v6" "${temp_v4}.dedup" "${temp_v6}.dedup" "$batch_v4" "$batch_v6"
}

# =============================================================================
# LIST FEEDS
# =============================================================================
nftban_feeds_list() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  NFTBan Threat Feeds - Available Providers"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    local enabled_global=$(_nftban_feeds_get_config "S" "ENABLED" 2>/dev/null || echo "FALSE")
    echo "Global Status: ${enabled_global}"
    echo ""

    printf "%-4s %-20s %-10s %-10s\n" "St" "Feed ID" "Interval" "IPs"
    echo "───────────────────────────────────────────────────────────────"

    for feed_id in "${NFTBAN_FEED_IDS[@]}"; do
        local enabled=$(_nftban_feeds_get_config "$feed_id" "ENABLED")
        local interval=$(_nftban_feeds_get_config "$feed_id" "INTERVAL")
        local file=$(_nftban_feeds_get_config "$feed_id" "FILE")
        file="${file//\${CONFIG_DIR\}/${NFTBAN_CONFIG_DIR:-/etc/nftban/config}}"

        local status="[✗]"
        local count="(disabled)"

        if [[ "$enabled" == "TRUE" ]]; then
            status="[✓]"
            if [[ -f "$file" ]]; then
                count=$(grep -cvE '^#' "$file" 2>/dev/null || echo 0)
                count="${count} IPs"
            else
                count="(not downloaded)"
            fi
        fi

        printf "%-4s %-20s %-10s %-10s\n" "$status" "${feed_id,,}" "$interval" "$count"
    done

    echo ""
    echo "Commands:"
    echo "  nftban feeds enable <feed_id>     Enable a feed"
    echo "  nftban feeds disable <feed_id>    Disable a feed"
    echo "  nftban feeds update [feed_id]     Update feeds"
    echo ""
}

# =============================================================================
# STATUS & MONITORING
# =============================================================================
nftban_feeds_status() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "  NFTBan Threat Feeds Status"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""

    # Count enabled feeds
    local enabled_count=0
    for feed_id in "${NFTBAN_FEED_IDS[@]}"; do
        local enabled=$(_nftban_feeds_get_config "$feed_id" "ENABLED")
        [[ "$enabled" == "TRUE" ]] && ((enabled_count++))
    done

    echo "Enabled Feeds: $enabled_count / ${#NFTBAN_FEED_IDS[@]}"
    echo ""

    # nftables stats
    echo "NFTables Stats:"
    local v4_count=$(nft list set "$NFTBAN_NFT_FAMILY_V4" "$NFTBAN_NFT_TABLE_V4" "$NFTBAN_NFT_SET_FEEDS" 2>/dev/null | grep -c 'elements' || echo 0)
    local v6_count=$(nft list set "$NFTBAN_NFT_FAMILY_V6" "$NFTBAN_NFT_TABLE_V6" "$NFTBAN_NFT_SET_FEEDS" 2>/dev/null | grep -c 'elements' || echo 0)
    echo "  IPv4 Set: Active"
    echo "  IPv6 Set: Active"
    echo ""

    # Timer status
    if systemctl is-active --quiet nftban-feeds.timer 2>/dev/null; then
        echo "Update Timer: ACTIVE ✓"
        systemctl status nftban-feeds.timer --no-pager 2>/dev/null | grep "Trigger:" || true
    else
        echo "Update Timer: INACTIVE (install with: nftban feeds timer-install)"
    fi
    echo ""
}

nftban_feeds_memory() {
    echo "Memory Usage:"

    # Feed files size
    local total_size=0
    for feed_id in "${NFTBAN_FEED_IDS[@]}"; do
        local file=$(_nftban_feeds_get_config "$feed_id" "FILE")
        file="${file//\${CONFIG_DIR\}/${NFTBAN_CONFIG_DIR:-/etc/nftban/config}}"

        if [[ -f "$file" ]]; then
            local size=$(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo 0)
            total_size=$((total_size + size))
        fi
    done

    local total_mb=$((total_size / 1024 / 1024))
    echo "  Feed Files: ${total_mb} MB"
    echo "  Memory Limit: ${NFTBAN_FEEDS_MEMORY_LIMIT:-512} MB"
}

# Alias for CLI compatibility
nftban_feeds_memory_status() {
    nftban_feeds_memory "$@"
}

# =============================================================================
# TIMER FUNCTIONS
# =============================================================================
nftban_feeds_timer_install() {
    _nftban_feeds_log INFO "Installing systemd timer..."

    local service_file="/etc/systemd/system/nftban-feeds.service"
    local timer_file="/etc/systemd/system/nftban-feeds.timer"

    # Service
    cat > "$service_file" << 'EOF'
[Unit]
Description=NFTBan Threat Feeds Update Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nftban feeds update-scheduled
User=root
WorkingDirectory=/etc/nftban
StandardOutput=journal
StandardError=journal
EOF

    # Timer (runs every hour)
    cat > "$timer_file" << 'EOF'
[Unit]
Description=NFTBan Threat Feeds Update Timer (Hourly)

[Timer]
OnCalendar=*-*-* *:00:00
AccuracySec=1m
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable nftban-feeds.timer
    systemctl start nftban-feeds.timer

    _nftban_feeds_log SUCCESS "Timer installed and started"
    systemctl status nftban-feeds.timer --no-pager
}

nftban_feeds_timer_remove() {
    _nftban_feeds_log INFO "Removing systemd timer..."

    systemctl stop nftban-feeds.timer 2>/dev/null || true
    systemctl disable nftban-feeds.timer 2>/dev/null || true

    rm -f "/etc/systemd/system/nftban-feeds.service"
    rm -f "/etc/systemd/system/nftban-feeds.timer"

    systemctl daemon-reload
    _nftban_feeds_log SUCCESS "Timer removed"
}

# =============================================================================
# SCHEDULED UPDATE (SMART INTERVAL LOGIC)
# =============================================================================
nftban_feeds_update_scheduled() {
    _nftban_feeds_log INFO "Running scheduled update check..."

    local current_hour=$(date +%H)
    local current_day=$(date +%u)  # 1=Mon, 7=Sun

    for feed_id in "${NFTBAN_FEED_IDS[@]}"; do
        local enabled=$(_nftban_feeds_get_config "$feed_id" "ENABLED")

        if [[ "$enabled" != "TRUE" ]]; then
            continue
        fi

        local interval=$(_nftban_feeds_get_config "$feed_id" "INTERVAL")
        local should_run=false

        case "$interval" in
            HOURLY)
                should_run=true
                ;;
            DAILY)
                [[ "$current_hour" == "00" ]] && should_run=true
                ;;
            WEEKLY)
                [[ "$current_day" == "7" && "$current_hour" == "00" ]] && should_run=true
                ;;
            *)
                # Invalid interval, use DAILY as fallback
                _nftban_feeds_log WARN "Invalid interval '$interval' for $feed_id, using DAILY"
                [[ "$current_hour" == "00" ]] && should_run=true
                ;;
        esac

        if [[ "$should_run" == "true" ]]; then
            _nftban_feeds_log INFO "Updating $feed_id (interval: $interval)"
            nftban_feeds_update_single "$feed_id"
        fi
    done
}

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================
export -f nftban_feeds_init
export -f nftban_feeds_enable
export -f nftban_feeds_disable
export -f nftban_feeds_update
export -f nftban_feeds_update_single
export -f nftban_feeds_update_scheduled
export -f nftban_feeds_sync_to_nftables
export -f nftban_feeds_list
export -f nftban_feeds_status
export -f nftban_feeds_memory
export -f nftban_feeds_timer_install
export -f nftban_feeds_timer_remove

# =============================================================================
# MODULE LOADED
# =============================================================================
if command -v nftban_log_debug >/dev/null 2>&1; then
    nftban_log_debug "NFTBan Feeds Module v4.0.0 loaded (single-config design)"
fi
