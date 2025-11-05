# =============================================================================
# NFTBan v0.30.0 - Threat Feeds Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Dynamic threat intelligence feed management with Go integration
#
# meta:name=nftban_feeds
# meta:type=core
# meta:header=Threat Feeds Core
# meta:version=0.30.1
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Dynamic threat intelligence feeds with beautiful selection UI
# meta:input=Feed URLs from config (dynamic discovery)
# meta:output=Parsed IPs/CIDRs to nftables, logs to /var/log/nftban/feeds.log
#
# **Inventory & Requirements**
# meta:depends=bash,curl,flock,nftban-feeds (Go binary)
#
# meta:created_date=2025-11-05
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

readonly NFTBAN_FEEDS_CONFIG="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/feeds.conf"
readonly NFTBAN_FEEDS_STORAGE_DIR="${NFTBAN_FEEDS_STORAGE_DIR:-/var/lib/nftban/feeds}"
readonly NFTBAN_FEEDS_CACHE_DIR="${NFTBAN_FEEDS_CACHE_DIR:-/var/cache/nftban/feeds}"
readonly NFTBAN_FEEDS_LOG="${NFTBAN_FEEDS_LOG:-/var/log/nftban/feeds.log}"
readonly NFTBAN_FEEDS_BINARY="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-feeds"
readonly NFTBAN_FEEDS_LOCKFILE="${RUNDIR:-/run/nftban}/feeds-update.lock"

# nftables configuration
readonly NFTBAN_NFT_TABLE="nftban_main"
readonly NFTBAN_NFT_SET_FEEDS_V4="feed_v4"
readonly NFTBAN_NFT_SET_FEEDS_V6="feed_v6"

# =============================================================================
# LOCKING - Prevent concurrent updates
# =============================================================================

# Ensure lock directory exists
mkdir -p "$(dirname "$NFTBAN_FEEDS_LOCKFILE")" 2>/dev/null || true

# Acquire lock (30 second timeout)
_feeds_lock() {
    exec 9>"$NFTBAN_FEEDS_LOCKFILE"
    if ! flock -w 30 9; then
        return 1
    fi
    return 0
}

# Release lock
_feeds_unlock() {
    flock -u 9 2>/dev/null || true
}

# Check if another update is running
_feeds_is_locked() {
    if [[ -f "$NFTBAN_FEEDS_LOCKFILE" ]]; then
        # Check if lock is stale (older than 1 hour = hung process)
        local lock_age=$(( $(date +%s) - $(stat -c %Y "$NFTBAN_FEEDS_LOCKFILE" 2>/dev/null || echo 0) ))
        if [[ $lock_age -gt 3600 ]]; then
            # Stale lock, remove it
            rm -f "$NFTBAN_FEEDS_LOCKFILE"
            return 1
        fi

        # Try to acquire lock (non-blocking check)
        if exec 9>"$NFTBAN_FEEDS_LOCKFILE" && flock -n 9 2>/dev/null; then
            flock -u 9
            return 1  # Not locked
        fi
        return 0  # Locked
    fi
    return 1  # Not locked
}

# =============================================================================
# LOGGING
# =============================================================================

nftban_feeds_log() {
    local level="$1"; shift
    local msg="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Ensure log directory exists
    mkdir -p "$(dirname "$NFTBAN_FEEDS_LOG")"

    # Log to dedicated feeds.log
    echo "[$timestamp] [$level] $msg" | tee -a "$NFTBAN_FEEDS_LOG"

    # Also log via main nftban logging if available
    if declare -f nftban_log_${level,,} >/dev/null 2>&1; then
        nftban_log_${level,,} "FEEDS: $msg"
    fi
}

# =============================================================================
# DYNAMIC FEED DISCOVERY (NO HARDCODED ARRAYS!)
# =============================================================================

# Discover all feeds from config file
nftban_feeds_discover_all() {
    if [[ ! -f "$NFTBAN_FEEDS_CONFIG" ]]; then
        nftban_feeds_log ERROR "Config file not found: $NFTBAN_FEEDS_CONFIG"
        return 1
    fi

    # Find all FEED_*_URL variables (dynamic discovery!)
    grep -oP 'FEED_\K[A-Z0-9_]+(?=_URL=)' "$NFTBAN_FEEDS_CONFIG" | sort -u
}

# Get feed property dynamically
nftban_feeds_get_property() {
    local feed_name="$1"
    local property="$2"  # URL, ENABLED, CATEGORY, DESCRIPTION, etc.

    if [[ ! -f "$NFTBAN_FEEDS_CONFIG" ]]; then
        echo ""
        return 1
    fi

    # Read property from config
    local var_name="FEED_${feed_name}_${property}"
    grep "^${var_name}=" "$NFTBAN_FEEDS_CONFIG" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' || echo ""
}

# Set feed property (enable/disable)
nftban_feeds_set_property() {
    local feed_name="$1"
    local property="$2"
    local value="$3"

    if [[ ! -f "$NFTBAN_FEEDS_CONFIG" ]]; then
        nftban_feeds_log ERROR "Config file not found: $NFTBAN_FEEDS_CONFIG"
        return 1
    fi

    local var_name="FEED_${feed_name}_${property}"

    # Update with sed (preserves comments and structure)
    if grep -q "^${var_name}=" "$NFTBAN_FEEDS_CONFIG"; then
        sed -i "s|^${var_name}=.*|${var_name}=\"${value}\"|" "$NFTBAN_FEEDS_CONFIG"
    else
        echo "${var_name}=\"${value}\"" >> "$NFTBAN_FEEDS_CONFIG"
    fi
}

# Get all feeds in a category
nftban_feeds_get_by_category() {
    local category="$1"
    local all_feeds
    all_feeds=$(nftban_feeds_discover_all)

    for feed in $all_feeds; do
        local feed_category
        feed_category=$(nftban_feeds_get_property "$feed" "CATEGORY")
        if [[ "$feed_category" == "$category" ]]; then
            echo "$feed"
        fi
    done
}

# Get all categories (dynamic!)
nftban_feeds_get_categories() {
    local all_feeds
    all_feeds=$(nftban_feeds_discover_all)

    local categories=()
    for feed in $all_feeds; do
        local cat
        cat=$(nftban_feeds_get_property "$feed" "CATEGORY")
        if [[ -n "$cat" ]] && [[ ! " ${categories[@]} " =~ " ${cat} " ]]; then
            categories+=("$cat")
        fi
    done

    printf '%s\n' "${categories[@]}" | sort -u
}

# =============================================================================
# FEED OPERATIONS
# =============================================================================

# Enable a feed
nftban_feeds_enable() {
    local feed_name="$1"

    # Validate feed exists
    local feed_url
    feed_url=$(nftban_feeds_get_property "$feed_name" "URL")
    if [[ -z "$feed_url" ]]; then
        nftban_feeds_log ERROR "Feed not found: $feed_name"
        return 1
    fi

    # Enable feed
    nftban_feeds_set_property "$feed_name" "ENABLED" "true"
    nftban_feeds_log INFO "Feed enabled: $feed_name"

    # Show immediate feedback
    echo "✓ Feed enabled: $feed_name"
    echo "⏳ Downloading in background..."
    echo ""
    echo "Check status with: nftban feeds status"
    echo "View progress: tail -f /var/log/nftban/feeds.log"

    # Download in background to avoid hanging CLI
    (nftban_feeds_update_single "$feed_name" &>/dev/null) &
    disown
}

# Disable a feed
nftban_feeds_disable() {
    local feed_name="$1"

    # Disable feed
    nftban_feeds_set_property "$feed_name" "ENABLED" "false"
    nftban_feeds_log INFO "Feed disabled: $feed_name"

    # Show immediate feedback
    echo "✓ Feed disabled: $feed_name"
    echo "⏳ Updating nftables in background..."
    echo ""
    echo "Check status with: nftban feeds status"
    echo "View progress: tail -f /var/log/nftban/feeds.log"

    # Resync nftables in background to avoid hanging CLI
    (nftban_feeds_sync_to_nftables &>/dev/null) &
    disown
}

# Update single feed
nftban_feeds_update_single() {
    local feed_name="$1"
    local no_sync="${2:-false}"  # Optional: skip sync (for batch updates)

    nftban_feeds_log INFO "Updating feed: $feed_name"

    # Get feed properties
    local feed_url
    feed_url=$(nftban_feeds_get_property "$feed_name" "URL")
    local feed_enabled
    feed_enabled=$(nftban_feeds_get_property "$feed_name" "ENABLED")

    if [[ "$feed_enabled" != "true" ]]; then
        nftban_feeds_log WARN "Feed is disabled, skipping: $feed_name"
        return 0
    fi

    # Ensure directories exist
    mkdir -p "$NFTBAN_FEEDS_STORAGE_DIR" "$NFTBAN_FEEDS_CACHE_DIR"

    # Download feed
    local temp_file="${NFTBAN_FEEDS_CACHE_DIR}/${feed_name}.tmp"
    nftban_feeds_log DEBUG "Downloading: $feed_url"

    if ! curl -sSL --max-time 30 "$feed_url" > "$temp_file" 2>/dev/null; then
        nftban_feeds_log ERROR "Download failed: $feed_name"
        rm -f "$temp_file"
        return 1
    fi

    # Parse with Go binary (FAST!)
    local parsed_file="${NFTBAN_FEEDS_STORAGE_DIR}/${feed_name}.txt"

    if [[ ! -x "$NFTBAN_FEEDS_BINARY" ]]; then
        nftban_feeds_log ERROR "Go binary not found or not executable: $NFTBAN_FEEDS_BINARY"
        return 1
    fi

    local parse_result
    parse_result=$("$NFTBAN_FEEDS_BINARY" parse --list < "$temp_file" 2>/dev/null)
    local parse_exit=$?

    if [[ $parse_exit -ne 0 ]]; then
        nftban_feeds_log ERROR "Parsing failed: $feed_name"
        rm -f "$temp_file"
        return 1
    fi

    # Save parsed IPs
    echo "$parse_result" > "$parsed_file"
    local ip_count=$(echo "$parse_result" | wc -l)

    # Validate minimum entries
    local min_entries=$(grep "^FEEDS_MIN_ENTRIES=" "$NFTBAN_FEEDS_CONFIG" | cut -d'=' -f2 | cut -d'#' -f1 | tr -d '" ' | grep -oE '[0-9]+')
    min_entries=${min_entries:-10}

    if [[ $ip_count -lt $min_entries ]]; then
        nftban_feeds_log ERROR "Feed has only $ip_count entries (minimum: $min_entries), rejecting: $feed_name"
        rm -f "$temp_file" "$parsed_file"
        return 1
    fi

    nftban_feeds_log INFO "Feed updated: $feed_name ($ip_count IPs)"

    # Cleanup
    rm -f "$temp_file"

    # Sync to nftables (unless told to skip for batch updates)
    if [[ "$no_sync" != "true" ]]; then
        nftban_feeds_sync_to_nftables
    fi

    return 0
}

# Update all enabled feeds
nftban_feeds_update_all() {
    # Check if another update is already running
    if _feeds_is_locked; then
        echo "⚠️  Another feed update is already running"
        echo ""
        echo "If this is stuck, check: ps aux | grep 'nftban feeds'"
        echo "Lock file: $NFTBAN_FEEDS_LOCKFILE"
        nftban_feeds_log WARN "Update skipped: another update is already running"
        return 1
    fi

    # Acquire lock with timeout
    if ! _feeds_lock; then
        echo "❌ Failed to acquire lock (timeout after 30 seconds)"
        echo ""
        echo "Another update may be running or system is overloaded."
        echo "Wait and try again, or check: ps aux | grep 'nftban feeds'"
        nftban_feeds_log ERROR "Failed to acquire update lock (timeout)"
        return 1
    fi

    # Ensure lock is released on exit
    trap '_feeds_unlock' EXIT INT TERM

    nftban_feeds_log INFO "Updating all enabled feeds... (lock acquired)"

    echo "⏳ Downloading all enabled feeds..."
    echo ""

    local all_feeds
    all_feeds=$(nftban_feeds_discover_all)

    local success_count=0
    local fail_count=0

    # Download all feeds WITHOUT syncing (sync once at the end for efficiency)
    for feed in $all_feeds; do
        local enabled
        enabled=$(nftban_feeds_get_property "$feed" "ENABLED")

        if [[ "$enabled" == "true" ]]; then
            echo "  → Downloading: $feed"
            if nftban_feeds_update_single "$feed" "true"; then
                success_count=$((success_count + 1))
            else
                fail_count=$((fail_count + 1))
            fi
        fi
    done

    echo ""
    echo "✓ Downloaded $success_count feed(s), $fail_count failed"

    nftban_feeds_log INFO "Update complete: $success_count succeeded, $fail_count failed"

    # Determine sync mode: synchronous for systemd, background for CLI
    if [[ -n "${INVOCATION_ID:-}" ]] || [[ "$NFTBAN_FEEDS_SYNC_MODE" == "sync" ]]; then
        # Running from systemd or explicit sync mode - wait for sync to complete
        echo "⏳ Syncing to nftables..."
        nftban_feeds_sync_to_nftables
        echo "✓ Sync complete"
    else
        # Running from CLI - sync in background for better UX
        echo "⏳ Syncing to nftables in background..."
        echo ""
        echo "Check status with: nftban feeds status"
        echo "View progress: tail -f /var/log/nftban/feeds.log"

        (nftban_feeds_sync_to_nftables &>/dev/null) &
        disown
    fi

    # Lock will be released by trap
    return 0
}

# Sync all enabled feeds to nftables
nftban_feeds_sync_to_nftables() {
    nftban_feeds_log INFO "Syncing feeds to nftables..."

    # Ensure nftables sets exist
    nft list set inet "$NFTBAN_NFT_TABLE" "$NFTBAN_NFT_SET_FEEDS_V4" >/dev/null 2>&1 || {
        nftban_feeds_log INFO "Creating IPv4 feeds set..."
        nft add set inet "$NFTBAN_NFT_TABLE" "$NFTBAN_NFT_SET_FEEDS_V4" { type ipv4_addr \; flags interval \; auto-merge \; }
    }

    nft list set inet "$NFTBAN_NFT_TABLE" "$NFTBAN_NFT_SET_FEEDS_V6" >/dev/null 2>&1 || {
        nftban_feeds_log INFO "Creating IPv6 feeds set..."
        nft add set inet "$NFTBAN_NFT_TABLE" "$NFTBAN_NFT_SET_FEEDS_V6" { type ipv6_addr \; flags interval \; auto-merge \; }
    }

    # Flush existing sets
    nft flush set inet "$NFTBAN_NFT_TABLE" "$NFTBAN_NFT_SET_FEEDS_V4" 2>/dev/null || true
    nft flush set inet "$NFTBAN_NFT_TABLE" "$NFTBAN_NFT_SET_FEEDS_V6" 2>/dev/null || true

    # Collect all IPs from enabled feeds
    local ipv4_list="${NFTBAN_FEEDS_CACHE_DIR}/feeds_ipv4.tmp"
    local ipv6_list="${NFTBAN_FEEDS_CACHE_DIR}/feeds_ipv6.tmp"

    > "$ipv4_list"
    > "$ipv6_list"

    local all_feeds
    all_feeds=$(nftban_feeds_discover_all)

    for feed in $all_feeds; do
        local enabled
        enabled=$(nftban_feeds_get_property "$feed" "ENABLED")

        if [[ "$enabled" == "true" ]]; then
            local feed_file="${NFTBAN_FEEDS_STORAGE_DIR}/${feed}.txt"
            if [[ -f "$feed_file" ]]; then
                # Separate IPv4 and IPv6
                while IFS= read -r ip; do
                    if [[ "$ip" =~ : ]]; then
                        echo "$ip" >> "$ipv6_list"
                    else
                        echo "$ip" >> "$ipv4_list"
                    fi
                done < "$feed_file"
            fi
        fi
    done

    # Deduplicate and add to nftables (BULK LOADING for performance)
    local ipv4_count=0
    local ipv6_count=0

    if [[ -s "$ipv4_list" ]]; then
        # Build comma-separated list for bulk insert (FAST)
        local ipv4_elements
        ipv4_elements=$(sort -u "$ipv4_list" | tr '\n' ',' | sed 's/,$//')
        ipv4_count=$(sort -u "$ipv4_list" | wc -l)

        if [[ -n "$ipv4_elements" ]]; then
            nft add element inet "$NFTBAN_NFT_TABLE" "$NFTBAN_NFT_SET_FEEDS_V4" "{ $ipv4_elements }" 2>/dev/null || true
        fi
    fi

    if [[ -s "$ipv6_list" ]]; then
        # Build comma-separated list for bulk insert (FAST)
        local ipv6_elements
        ipv6_elements=$(sort -u "$ipv6_list" | tr '\n' ',' | sed 's/,$//')
        ipv6_count=$(sort -u "$ipv6_list" | wc -l)

        if [[ -n "$ipv6_elements" ]]; then
            nft add element inet "$NFTBAN_NFT_TABLE" "$NFTBAN_NFT_SET_FEEDS_V6" "{ $ipv6_elements }" 2>/dev/null || true
        fi
    fi

    nftban_feeds_log INFO "Sync complete: $ipv4_count IPv4, $ipv6_count IPv6"

    # Cleanup
    rm -f "$ipv4_list" "$ipv6_list"

    return 0
}

# =============================================================================
# STATUS & INFORMATION
# =============================================================================

# List all feeds with status
nftban_feeds_list_simple() {
    local all_feeds
    all_feeds=$(nftban_feeds_discover_all)

    for feed in $all_feeds; do
        local enabled
        enabled=$(nftban_feeds_get_property "$feed" "ENABLED")
        local category
        category=$(nftban_feeds_get_property "$feed" "CATEGORY")
        local description
        description=$(nftban_feeds_get_property "$feed" "DESCRIPTION")

        local status_icon="[✗]"
        [[ "$enabled" == "true" ]] && status_icon="[✓]"

        printf "%-4s %-30s %-15s %s\n" "$status_icon" "$feed" "$category" "$description"
    done
}

# Get feed statistics
nftban_feeds_get_stats() {
    local all_feeds
    all_feeds=$(nftban_feeds_discover_all)

    local total_count=0
    local enabled_count=0
    local total_ips=0

    for feed in $all_feeds; do
        total_count=$((total_count + 1))

        local enabled
        enabled=$(nftban_feeds_get_property "$feed" "ENABLED")

        if [[ "$enabled" == "true" ]]; then
            enabled_count=$((enabled_count + 1))

            local feed_file="${NFTBAN_FEEDS_STORAGE_DIR}/${feed}.txt"
            if [[ -f "$feed_file" ]]; then
                local count
                count=$(wc -l < "$feed_file")
                ((total_ips += count))
            fi
        fi
    done

    echo "$enabled_count/$total_count feeds enabled | $total_ips total IPs"
}

# Export functions
export -f nftban_feeds_discover_all
export -f nftban_feeds_get_property
export -f nftban_feeds_set_property
export -f nftban_feeds_get_by_category
export -f nftban_feeds_get_categories
export -f nftban_feeds_enable
export -f nftban_feeds_disable
export -f nftban_feeds_update_single
export -f nftban_feeds_update_all
export -f nftban_feeds_sync_to_nftables
export -f nftban_feeds_list_simple
export -f nftban_feeds_get_stats
export -f nftban_feeds_log
