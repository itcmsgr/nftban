#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Threat Feeds Core Module
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_feeds"
# meta:type="core"
# meta:header="Threat Feeds Core"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
# meta:description="Dynamic threat intelligence feeds with beautiful selection UI"
# meta:input="Feed URLs from config (dynamic discovery)"
# meta:output="Parsed IPs/CIDRs to nftables, logs to /var/log/nftban/feeds.log"
# meta:depends="bash,curl,flock,nftban-feeds"
# meta:inventory.files=""
# meta:inventory.binaries="nftban-feeds"
# meta:inventory.env_vars="NFTBAN_CONFIG_DIR,NFTBAN_LIB_DIR"
# meta:inventory.config_files="/etc/nftban/conf.d/feeds.conf"
# meta:inventory.systemd_units="nftban-core-feeds.timer"
# meta:inventory.network="outbound"
# meta:inventory.privileges="nftban"
# meta:created_date="2025-11-05"
# meta:updated_date="2025-11-24"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading (required for circular dependency with task_queue.sh)
[[ -n "${NFTBAN_FEEDS_LOADED:-}" ]] && return 0
readonly NFTBAN_FEEDS_LOADED=1

# =============================================================================
# DEPENDENCIES
# =============================================================================

# Source canonical NFT schema (single source of truth for table/set names)
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh" 2>/dev/null || {
    echo "ERROR: Cannot load nft_schema.sh - NFTables schema undefined" >&2
    exit 1
}

# Load IPC library for single-writer architecture
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_ipc.sh" 2>/dev/null || true

# Load timestamp library (for consistent timestamp handling)
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_timestamp.sh" 2>/dev/null || true

# Load file utilities library (for file age/freshness checks)
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_file_utils.sh" 2>/dev/null || true

# =============================================================================
# CONFIGURATION
# =============================================================================

# Source central environment loader (single source of truth for paths)
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/env.sh"

readonly NFTBAN_FEEDS_CONFIG="${NFTBAN_CONFIG_DIR:-/etc/nftban}/conf.d/feeds.conf"
readonly NFTBAN_FEEDS_STORAGE_DIR="${NFTBAN_FEEDS_STORAGE_DIR:-${NFTBAN_DATA_DIR:-/var/lib/nftban}/feeds}"
readonly NFTBAN_FEEDS_CACHE_DIR="${NFTBAN_FEEDS_CACHE_DIR:-${NFTBAN_CACHE_DIR:-/var/cache/nftban}/feeds}"
readonly NFTBAN_FEEDS_LOG="${NFTBAN_FEEDS_LOG:-${NFTBAN_LOG_DIR:-/var/log/nftban}/feeds.log}"
# Use central config for Go binary path (with fallbacks)
readonly NFTBAN_FEEDS_BINARY="${NFTBAN_CORE_BIN:-${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-core}"
readonly NFTBAN_FEEDS_LOCKFILE="${NFTBAN_RUN_DIR:-/run/nftban}/feeds-update.lock"

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
        # Use library function with graceful fallback
        local lock_age
        if declare -f nftban_file_age &>/dev/null; then
            lock_age=$(nftban_file_age "$NFTBAN_FEEDS_LOCKFILE")
        else
            # Fallback: inline calculation if library not loaded
            lock_age=$(( $(date +%s) - $(stat -c %Y "$NFTBAN_FEEDS_LOCKFILE" 2>/dev/null || echo 0) ))
        fi
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
    local timestamp
    # Use library function with graceful fallback
    if declare -f nftban_timestamp_log &>/dev/null; then
        # nftban_timestamp_log returns "[YYYY-MM-DD HH:MM:SS]" format
        timestamp=$(nftban_timestamp_log)
    else
        timestamp="[$(date '+%Y-%m-%d %H:%M:%S')]"
    fi

    # Ensure log directory exists
    mkdir -p "$(dirname "$NFTBAN_FEEDS_LOG")"

    # Log to dedicated feeds.log (timestamp already has brackets from library)
    echo "${timestamp} [$level] $msg" | tee -a "$NFTBAN_FEEDS_LOG"

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
# Uses config architecture: check .conf.local override first, fallback to feeds.conf default
nftban_feeds_get_property() {
    local feed_name="$1"
    local property="$2"  # URL, ENABLED, CATEGORY, DESCRIPTION, etc.

    local var_name="FEED_${feed_name}_${property}"
    local value=""
    local local_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"

    # 1. Check .conf.local override first (user customizations)
    if [[ -f "$local_conf" ]]; then
        value=$(grep "^${var_name}=" "$local_conf" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '"' || true)
    fi

    # 2. Fallback to feeds.conf default if not overridden
    if [[ -z "$value" ]] && [[ -f "$NFTBAN_FEEDS_CONFIG" ]]; then
        value=$(grep "^${var_name}=" "$NFTBAN_FEEDS_CONFIG" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"' || true)
    fi

    echo "$value"
}

# Set feed property (enable/disable)
# Uses config architecture: writes to .conf.local (never modifies default feeds.conf)
nftban_feeds_set_property() {
    local feed_name="$1"
    local property="$2"
    local value="$3"

    local var_name="FEED_${feed_name}_${property}"
    local local_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"
    local section_marker="# --- FEEDS Configuration ---"

    # Ensure .conf.local exists
    if [[ ! -f "$local_conf" ]]; then
        cat > "$local_conf" << 'EOF'
# NFTBan Local Configuration Overrides
# User customizations - survives package updates
# Auto-generated by nftban

EOF
        chmod 640 "$local_conf"
        chown root:nftban "$local_conf" 2>/dev/null || true
    fi

    # Check if FEEDS section exists
    if ! grep -q "$section_marker" "$local_conf" 2>/dev/null; then
        # Add FEEDS section
        {
            echo ""
            echo "$section_marker"
            echo "${var_name}=\"${value}\""
        } >> "$local_conf"
        return 0
    fi

    # Section exists - update or add key
    local temp_file="${local_conf}.tmp.$$"
    local in_section=false
    local key_written=false

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Entering FEEDS section
        if [[ "$line" == *"$section_marker"* ]]; then
            in_section=true
            echo "$line"
            continue
        fi

        # Leaving section (next section marker)
        if [[ "$in_section" == true ]] && [[ "$line" == "# --- "* ]] && [[ "$line" != *"$section_marker"* ]]; then
            # Add key if not written yet
            if [[ "$key_written" == false ]]; then
                echo "${var_name}=\"${value}\""
                key_written=true
            fi
            in_section=false
            echo "$line"
            continue
        fi

        # In section - check if this is our key
        if [[ "$in_section" == true ]] && [[ "$line" =~ ^${var_name}= ]]; then
            echo "${var_name}=\"${value}\""
            key_written=true
            continue
        fi

        echo "$line"
    done < "$local_conf" > "$temp_file"

    # If still in section at EOF and key not written, add it
    if [[ "$in_section" == true ]] && [[ "$key_written" == false ]]; then
        echo "${var_name}=\"${value}\"" >> "$temp_file"
    fi

    mv "$temp_file" "$local_conf"
    chmod 640 "$local_conf"
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
        local cat_pattern=" ${cat} "
        if [[ -n "$cat" ]] && [[ ! " ${categories[*]} " =~ $cat_pattern ]]; then
            categories+=("$cat")
        fi
    done

    printf '%s\n' "${categories[@]}" | sort -u
}

# List all enabled feeds
nftban_feeds_list_enabled() {
    local all_feeds
    all_feeds=$(nftban_feeds_discover_all)

    for feed in $all_feeds; do
        local enabled
        enabled=$(nftban_feeds_get_property "$feed" "ENABLED")
        if [[ "$enabled" == "true" ]]; then
            echo "$feed"
        fi
    done
}

# =============================================================================
# FEED OPERATIONS
# =============================================================================

# Enable a feed
nftban_feeds_enable() {
    local feed_name="$1"
    local quiet="${2:-false}"  # Optional: quiet mode for batch operations

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

    # Download immediately (foreground) so user can see success/failure
    if [[ "$quiet" != "true" ]]; then
        echo "✓ Feed enabled: $feed_name"
        echo ""
        echo "📥 Downloading feed..."
    fi

    # Download in foreground with live feedback
    # Pass "true" for no_sync since we'll queue the sync after download
    if nftban_feeds_update_single "$feed_name" "true"; then
        if [[ "$quiet" != "true" ]]; then
            echo "✅ Feed downloaded successfully"
        fi

        # ARCHITECTURE COMPLIANCE: Always use timer-based queue for nftables sync
        # NEVER execute synchronous sync - all feeds/ban/unban/countries managed by timer
        # This prevents 30+ second hangs with large feed sets and respects async architecture
        if command -v nftban_queue_add &>/dev/null; then
            nftban_queue_add "feeds_sync" "Feed enabled: $feed_name" >/dev/null 2>&1
            if [[ "$quiet" != "true" ]]; then
                echo "   NFTables update queued (processed every 2 minutes)"
                echo "   Check queue: tail -f /var/log/nftban/queue.log"
                echo ""
            fi
        else
            # Queue function not available, note in logs
            nftban_feeds_log "WARN" "Queue function not available, sync will run on next timer cycle"
            if [[ "$quiet" != "true" ]]; then
                echo "   NFTables will sync on next timer cycle (every 2 minutes)"
                echo ""
            fi
        fi
    else
        if [[ "$quiet" != "true" ]]; then
            echo "❌ Feed download failed (check /var/log/nftban/feeds.log)"
            echo ""
        fi
        return 1
    fi
}

# Disable a feed
nftban_feeds_disable() {
    local feed_name="$1"
    local feed_lowercase
    feed_lowercase=$(echo "$feed_name" | tr '[:upper:]' '[:lower:]')
    local feed_file="${NFTBAN_FEEDS_STORAGE_DIR}/${feed_lowercase}.txt"

    # Disable feed in config
    nftban_feeds_set_property "$feed_name" "ENABLED" "false"
    nftban_feeds_log INFO "Feed disabled: $feed_name"

    echo "✓ Feed disabled: $feed_name"
    echo ""

    # Clear the feed file
    if [[ -f "$feed_file" ]]; then
        local ip_count
        ip_count=$(wc -l < "$feed_file" 2>/dev/null || echo "0")
        : > "$feed_file"
        echo "   ✅ Feed file cleared ($ip_count IPs)"
    fi

    # Re-sync all feeds to nftables (only enabled feeds will be loaded)
    # This is required because IPs are stored as optimized CIDR ranges
    # Individual IP deletion won't work - must rebuild blacklist
    echo ""
    echo "🔄 Rebuilding blacklist (only enabled feeds)..."
    if nftban_feeds_sync_to_nftables 2>/dev/null; then
        nftban_feeds_log INFO "Feed $feed_name IPs removed via full sync"
        echo "   ✅ Blacklist rebuilt - $feed_name IPs removed"
    else
        nftban_feeds_log WARN "Sync failed, IPs will be removed on next update"
        echo "   ⚠️  Sync pending - run 'nftban feeds update' to apply"
    fi

    echo ""
    echo "✅ Feed disabled"
    echo ""
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

    # Parse with Go binary (FAST!) or fallback to bash
    # Store files in lowercase for consistency with Go binary expectations
    local feed_name_lowercase
    feed_name_lowercase=$(echo "$feed_name" | tr '[:upper:]' '[:lower:]')
    local parsed_file="${NFTBAN_FEEDS_STORAGE_DIR}/${feed_name_lowercase}.txt"
    local parse_result=""

    # Parse feed file to extract IPs (bash parser - handles all formats)
    # Note: Go binary is used for 'feeds load' and 'feeds sync' operations
    parse_result=$(grep -v '^\s*$' "$temp_file" | \
                  grep -v '^\s*#' | \
                  grep -v '^\s*;' | \
                  sed 's/[[:space:]]*;.*//' | \
                  sed 's/[[:space:]]*#.*//' | \
                  grep -oE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}(/[0-9]{1,2})?' | \
                  sort -u)

    # Save parsed IPs (set nftban ownership for group access)
    echo "$parse_result" > "$parsed_file"
    chown nftban:nftban "$parsed_file" 2>/dev/null || true
    chmod 640 "$parsed_file" 2>/dev/null || true
    local ip_count
    ip_count=$(echo "$parse_result" | grep -c .)

    # Validate minimum entries
    local min_entries
    min_entries=$(grep "^FEEDS_MIN_ENTRIES=" "$NFTBAN_FEEDS_CONFIG" | cut -d'=' -f2 | cut -d'#' -f1 | tr -d '" ' | grep -oE '[0-9]+')
    min_entries=${min_entries:-10}

    # Final validation
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
        # ARCHITECTURE COMPLIANCE: Always use timer-based queue for nftables sync
        # NEVER execute synchronous sync - all feeds/ban/unban/countries managed by timer
        # This prevents system crashes when loading thousands of IPs at once
        if command -v nftban_queue_add &>/dev/null; then
            nftban_queue_add "feeds_sync" "Feed updated: $feed_name" >/dev/null 2>&1
        else
            nftban_feeds_log "WARN" "Queue function not available, sync will run on next timer cycle"
        fi
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

    # Immediately load feeds into nftables using Go binary (central config path)
    echo ""
    echo "⏳ Loading feeds into nftables..."
    if [[ -x "${NFTBAN_FEEDS_BINARY}" ]]; then
        if "${NFTBAN_FEEDS_BINARY}" feeds load 2>&1 | grep -E "^(✅|⚠️|Feed entries:|Total)" ; then
            nftban_feeds_log INFO "Feeds loaded into nftables successfully"
            echo ""
        else
            nftban_feeds_log ERROR "Failed to load feeds into nftables"
            echo "❌ Failed to load feeds - check logs"
            echo ""
        fi
    else
        nftban_feeds_log "WARN" "Go binary not found at ${NFTBAN_FEEDS_BINARY}, feeds downloaded but not loaded"
        echo "⚠️ Feeds downloaded but Go binary not found at: ${NFTBAN_FEEDS_BINARY}"
        echo "   Check NFTBAN_CORE_BIN in /etc/nftban/nftban.conf"
        echo ""
    fi

    # Lock will be released by trap
    return 0
}

# Sync all enabled feeds to nftables (Go-optimized with bash fallback)
nftban_feeds_sync_to_nftables() {
    nftban_feeds_log INFO "Syncing feeds to nftables (v0.7.3 architecture)..."

    # v0.7.3: Feeds add directly to existing blacklist_ipv4/blacklist_ipv6 sets
    # No separate feed sets needed - unified blacklist approach

    # Verify blacklist sets exist (should be created by nftables-safe.conf)
    if ! nft list set ${NFTBAN_TABLE_IPV4} blacklist_ipv4 >/dev/null 2>&1; then
        nftban_feeds_log ERROR "IPv4 blacklist set missing! Run: nftban nftables init"
        return 1
    fi

    if ! nft list set ${NFTBAN_TABLE_IPV6} blacklist_ipv6 >/dev/null 2>&1; then
        nftban_feeds_log ERROR "IPv6 blacklist set missing! Run: nftban nftables init"
        return 1
    fi

    # Check if Go binary is available (v0.6.0)
    local go_binary="${NFTBAN_LIB_DIR}/bin/nftban-feeds"
    if [[ -x "$go_binary" ]]; then
        nftban_feeds_log INFO "Using Go-optimized feed loader (fast, atomic)"
        nftban_feeds_sync_to_nftables_go
        return $?
    else
        nftban_feeds_log INFO "Using bash feed loader (Go binary not found)"
        nftban_feeds_sync_to_nftables_bash
        return $?
    fi
}

# Go-optimized feed sync (v0.6.0)
nftban_feeds_sync_to_nftables_go() {
    local go_binary="${NFTBAN_LIB_DIR}/bin/nftban-feeds"

    # Get list of enabled feeds
    local enabled_feeds
    enabled_feeds=$(nftban_feeds_list_enabled | tr '\n' ',' | sed 's/,$//')

    if [[ -z "$enabled_feeds" ]]; then
        nftban_feeds_log INFO "No feeds enabled"
        return 0
    fi

    nftban_feeds_log INFO "Enabled feeds: $enabled_feeds"

    # Convert feed names to lowercase for Go binary compatibility
    # Go binary expects: "firehol_anonymous", Bash config has: "FIREHOL_ANONYMOUS"
    local enabled_feeds_lowercase
    enabled_feeds_lowercase=$(echo "$enabled_feeds" | tr '[:upper:]' '[:lower:]')

    nftban_feeds_log DEBUG "Calling Go binary with: $enabled_feeds_lowercase"

    # Call Go binary with atomic loading
    if "$go_binary" sync "$enabled_feeds_lowercase" 2>&1 | tee -a "$NFTBAN_FEEDS_LOG"; then
        nftban_feeds_log INFO "Go feed sync completed successfully"
        return 0
    else
        nftban_feeds_log ERROR "Go feed sync failed, falling back to bash"
        nftban_feeds_sync_to_nftables_bash
        return $?
    fi
}

# =============================================================================
# CIDR MERGING FOR BASH FALLBACK
# =============================================================================
# nftables interval sets CANNOT have overlapping ranges. Multiple feeds often
# contain overlapping CIDRs (e.g., 1.0.0.0/8 and 1.0.0.0/24). This function
# merges them to prevent "conflicting intervals" errors.
#
# Priority order:
# 1. aggregate6 (Python tool, best CIDR aggregation)
# 2. netmask (C tool, good aggregation)
# 3. Pure bash fallback (removes contained CIDRs)
# =============================================================================

# Merge overlapping CIDRs in a file
# Usage: _feeds_merge_cidrs <input_file> <output_file> <ip_version>
# ip_version: 4 or 6
_feeds_merge_cidrs() {
    local input_file="$1"
    local output_file="$2"
    local ip_version="${3:-4}"

    if [[ ! -s "$input_file" ]]; then
        : > "$output_file"
        return 0
    fi

    local input_count
    input_count=$(wc -l < "$input_file")

    # Method 1: aggregate6 (best - handles all edge cases)
    if command -v aggregate6 &>/dev/null; then
        nftban_feeds_log DEBUG "Using aggregate6 for CIDR merging (IPv${ip_version})"
        if [[ "$ip_version" == "4" ]]; then
            aggregate6 -4 < "$input_file" > "$output_file" 2>/dev/null
        else
            aggregate6 -6 < "$input_file" > "$output_file" 2>/dev/null
        fi
        local output_count
        output_count=$(wc -l < "$output_file")
        local merged=$((input_count - output_count))
        [[ $merged -gt 0 ]] && nftban_feeds_log INFO "CIDR merge (aggregate6): ${input_count} -> ${output_count} (merged ${merged} overlaps)"
        return 0
    fi

    # Method 2: netmask (good alternative)
    if command -v netmask &>/dev/null && [[ "$ip_version" == "4" ]]; then
        nftban_feeds_log DEBUG "Using netmask for CIDR merging (IPv4)"
        # netmask can aggregate but needs special handling
        # Convert to ranges and back - this merges overlapping
        netmask -c < "$input_file" 2>/dev/null | sort -u > "$output_file"
        local output_count
        output_count=$(wc -l < "$output_file")
        local merged=$((input_count - output_count))
        [[ $merged -gt 0 ]] && nftban_feeds_log INFO "CIDR merge (netmask): ${input_count} -> ${output_count} (merged ${merged} overlaps)"
        return 0
    fi

    # Method 3: Pure bash fallback - remove obvious overlaps
    # This removes smaller CIDRs that are contained within larger ones
    # Not as comprehensive as aggregate6 but handles the most common cases
    nftban_feeds_log DEBUG "Using bash fallback for CIDR deduplication (IPv${ip_version})"
    _feeds_merge_cidrs_bash "$input_file" "$output_file" "$ip_version"
}

# Pure bash CIDR overlap removal
# Removes CIDRs that are contained within larger CIDRs
_feeds_merge_cidrs_bash() {
    local input_file="$1"
    local output_file="$2"
    local ip_version="${3:-4}"

    local temp_sorted="${input_file}.sorted"
    local temp_filtered="${input_file}.filtered"

    # Sort by prefix length (largest networks first, i.e., smallest prefix number)
    # Format: prefix_len|cidr for sorting
    if [[ "$ip_version" == "4" ]]; then
        # IPv4: extract prefix length, default to /32 for bare IPs
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue
            if [[ "$cidr" == */* ]]; then
                local prefix="${cidr##*/}"
                printf '%02d|%s\n' "$prefix" "$cidr"
            else
                printf '32|%s/32\n' "$cidr"
            fi
        done < "$input_file" | sort -t'|' -k1,1n -k2,2 | cut -d'|' -f2 > "$temp_sorted"
    else
        # IPv6: extract prefix length, default to /128 for bare IPs
        while IFS= read -r cidr; do
            [[ -z "$cidr" ]] && continue
            if [[ "$cidr" == */* ]]; then
                local prefix="${cidr##*/}"
                printf '%03d|%s\n' "$prefix" "$cidr"
            else
                printf '128|%s/128\n' "$cidr"
            fi
        done < "$input_file" | sort -t'|' -k1,1n -k2,2 | cut -d'|' -f2 > "$temp_sorted"
    fi

    # Now filter: keep only CIDRs not contained in a larger one
    # We process from largest (smallest prefix) to smallest (largest prefix)
    : > "$temp_filtered"
    declare -a kept_cidrs=()

    while IFS= read -r cidr; do
        [[ -z "$cidr" ]] && continue
        local dominated=false

        # Check if this CIDR is contained within any already-kept CIDR
        for kept in "${kept_cidrs[@]}"; do
            if _cidr_contains "$kept" "$cidr" "$ip_version"; then
                dominated=true
                break
            fi
        done

        if [[ "$dominated" == "false" ]]; then
            echo "$cidr" >> "$temp_filtered"
            kept_cidrs+=("$cidr")
        fi
    done < "$temp_sorted"

    # Move result to output
    mv "$temp_filtered" "$output_file"
    rm -f "$temp_sorted"

    local input_count output_count merged
    input_count=$(wc -l < "$input_file")
    output_count=$(wc -l < "$output_file")
    merged=$((input_count - output_count))
    [[ $merged -gt 0 ]] && nftban_feeds_log INFO "CIDR merge (bash): ${input_count} -> ${output_count} (removed ${merged} contained CIDRs)"
}

# Check if CIDR A contains CIDR B (IPv4)
# Returns 0 if A contains B, 1 otherwise
_cidr_contains() {
    local cidr_a="$1"
    local cidr_b="$2"
    local ip_version="${3:-4}"

    if [[ "$ip_version" == "4" ]]; then
        _cidr_contains_ipv4 "$cidr_a" "$cidr_b"
    else
        _cidr_contains_ipv6 "$cidr_a" "$cidr_b"
    fi
}

# IPv4 containment check
_cidr_contains_ipv4() {
    local cidr_a="$1"
    local cidr_b="$2"

    # Parse CIDR A
    local net_a="${cidr_a%/*}"
    local prefix_a="${cidr_a##*/}"
    [[ "$prefix_a" == "$cidr_a" ]] && prefix_a=32

    # Parse CIDR B
    local net_b="${cidr_b%/*}"
    local prefix_b="${cidr_b##*/}"
    [[ "$prefix_b" == "$cidr_b" ]] && prefix_b=32

    # A can only contain B if A's prefix is smaller or equal
    [[ $prefix_a -gt $prefix_b ]] && return 1

    # Convert IPs to integers
    local -a octets_a octets_b
    IFS='.' read -ra octets_a <<< "$net_a"
    IFS='.' read -ra octets_b <<< "$net_b"

    local int_a=$(( (octets_a[0] << 24) + (octets_a[1] << 16) + (octets_a[2] << 8) + octets_a[3] ))
    local int_b=$(( (octets_b[0] << 24) + (octets_b[1] << 16) + (octets_b[2] << 8) + octets_b[3] ))

    # Calculate network mask for A
    local mask=$(( 0xFFFFFFFF << (32 - prefix_a) & 0xFFFFFFFF ))

    # B is contained in A if (B & mask_A) == (A & mask_A)
    [[ $(( int_b & mask )) -eq $(( int_a & mask )) ]]
}

# IPv6 containment check (simplified - compares prefix bits)
_cidr_contains_ipv6() {
    local cidr_a="$1"
    local cidr_b="$2"

    # Parse prefixes
    local prefix_a="${cidr_a##*/}"
    local prefix_b="${cidr_b##*/}"
    [[ "$prefix_a" == "$cidr_a" ]] && prefix_a=128
    [[ "$prefix_b" == "$cidr_b" ]] && prefix_b=128

    # A can only contain B if A's prefix is smaller or equal
    [[ $prefix_a -gt $prefix_b ]] && return 1

    # For IPv6, we use a simpler string comparison of the network portion
    # This works for most common cases but isn't perfect
    local net_a="${cidr_a%/*}"
    local net_b="${cidr_b%/*}"

    # Expand IPv6 addresses to full form for comparison
    local expanded_a expanded_b
    expanded_a=$(_expand_ipv6 "$net_a")
    expanded_b=$(_expand_ipv6 "$net_b")

    # Compare the first prefix_a bits
    local chars_to_compare=$(( (prefix_a + 3) / 4 ))  # Hex chars needed
    local prefix_str_a="${expanded_a:0:$chars_to_compare}"
    local prefix_str_b="${expanded_b:0:$chars_to_compare}"

    [[ "$prefix_str_a" == "$prefix_str_b" ]]
}

# Expand IPv6 address to full 32-char hex form (no colons)
_expand_ipv6() {
    local addr="$1"

    # Handle :: expansion
    if [[ "$addr" == *"::"* ]]; then
        local left="${addr%%::*}"
        local right="${addr#*::}"
        local left_groups=0 right_groups=0

        [[ -n "$left" ]] && left_groups=$(echo "$left" | tr -cd ':' | wc -c)
        [[ -n "$left" ]] && ((left_groups++))
        [[ -n "$right" ]] && right_groups=$(echo "$right" | tr -cd ':' | wc -c)
        [[ -n "$right" ]] && ((right_groups++))

        local missing=$((8 - left_groups - right_groups))
        local zeros=""
        for ((i=0; i<missing; i++)); do
            zeros="${zeros}:0000"
        done

        if [[ -z "$left" ]]; then
            addr="${zeros#:}:$right"
        elif [[ -z "$right" ]]; then
            addr="$left$zeros"
        else
            addr="$left$zeros:$right"
        fi
    fi

    # Now expand each group to 4 hex chars
    IFS=':' read -ra groups <<< "$addr"
    for group in "${groups[@]}"; do
        printf '%04x' "0x${group:-0}" 2>/dev/null || printf '0000'
    done
}

# Bash feed sync (fallback, v0.6.0) - ATOMIC RELOAD
nftban_feeds_sync_to_nftables_bash() {
    # Collect all IPs from enabled feeds
    local ipv4_list="${NFTBAN_FEEDS_CACHE_DIR}/feeds_ipv4.tmp"
    local ipv6_list="${NFTBAN_FEEDS_CACHE_DIR}/feeds_ipv6.tmp"
    local ipv4_merged="${NFTBAN_FEEDS_CACHE_DIR}/feeds_ipv4_merged.tmp"
    local ipv6_merged="${NFTBAN_FEEDS_CACHE_DIR}/feeds_ipv6_merged.tmp"

    : > "$ipv4_list"
    : > "$ipv6_list"

    local all_feeds
    all_feeds=$(nftban_feeds_discover_all)

    for feed in $all_feeds; do
        local enabled
        enabled=$(nftban_feeds_get_property "$feed" "ENABLED")

        if [[ "$enabled" == "true" ]]; then
            # Convert to lowercase for filename (files are saved as lowercase)
            local feed_lowercase
            feed_lowercase=$(echo "$feed" | tr '[:upper:]' '[:lower:]')
            local feed_file="${NFTBAN_FEEDS_STORAGE_DIR}/${feed_lowercase}.txt"
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

    # Sort unique first, then merge overlapping CIDRs
    # This is CRITICAL for nftables interval sets which reject overlapping ranges
    local ipv4_count=0
    local ipv6_count=0

    if [[ -s "$ipv4_list" ]]; then
        sort -u "$ipv4_list" -o "$ipv4_list"
        _feeds_merge_cidrs "$ipv4_list" "$ipv4_merged" 4
        mv "$ipv4_merged" "$ipv4_list"
        ipv4_count=$(wc -l < "$ipv4_list")
    fi

    if [[ -s "$ipv6_list" ]]; then
        sort -u "$ipv6_list" -o "$ipv6_list"
        _feeds_merge_cidrs "$ipv6_list" "$ipv6_merged" 6
        mv "$ipv6_merged" "$ipv6_list"
        ipv6_count=$(wc -l < "$ipv6_list")
    fi

    # Build nftables file for atomic reload (v0.7.3 architecture - dual tables)
    local nft_file="${NFTBAN_FEEDS_CACHE_DIR}/feeds.nft"
    cat > "$nft_file" << EOF
#!/usr/sbin/nft -f
# NFTBan Feed Sync - Generated $(date)
# IPv4: $ipv4_count | IPv6: $ipv6_count
# Architecture: v0.7.3 (dual ip/ip6 tables, unified blacklist sets)

EOF

    # Add IPv4 elements to ip nftban blacklist_ipv4
    if [[ -s "$ipv4_list" ]]; then
        echo "add element ${NFTBAN_TABLE_IPV4} blacklist_ipv4 {" >> "$nft_file"
        sort -u "$ipv4_list" | sed 's/$/,/' | sed '$ s/,$//' >> "$nft_file"
        echo "}" >> "$nft_file"
        echo "" >> "$nft_file"
    fi

    # Add IPv6 elements to ip6 nftban blacklist_ipv6
    if [[ -s "$ipv6_list" ]]; then
        echo "add element ${NFTBAN_TABLE_IPV6} blacklist_ipv6 {" >> "$nft_file"
        sort -u "$ipv6_list" | sed 's/$/,/' | sed '$ s/,$//' >> "$nft_file"
        echo "}" >> "$nft_file"
    fi

    # Atomic reload using IPC
    if nft_ipc_apply_ruleset "$nft_file" 2>&1 | tee -a "$NFTBAN_FEEDS_LOG"; then
        nftban_feeds_log INFO "Sync complete: $ipv4_count IPv4, $ipv6_count IPv6 (CIDRs merged)"
    else
        nftban_feeds_log ERROR "Atomic reload failed"
        # Cleanup (including any leftover merge temp files)
        rm -f "$ipv4_list" "$ipv6_list" "$ipv4_merged" "$ipv6_merged" "$nft_file"
        rm -f "${ipv4_list}.sorted" "${ipv4_list}.filtered"
        rm -f "${ipv6_list}.sorted" "${ipv6_list}.filtered"
        return 1
    fi

    # Cleanup (including any leftover merge temp files)
    rm -f "$ipv4_list" "$ipv6_list" "$ipv4_merged" "$ipv6_merged" "$nft_file"
    rm -f "${ipv4_list}.sorted" "${ipv4_list}.filtered"
    rm -f "${ipv6_list}.sorted" "${ipv6_list}.filtered"

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

            # Convert to lowercase for filename (files are saved as lowercase)
            local feed_lowercase
            feed_lowercase=$(echo "$feed" | tr '[:upper:]' '[:lower:]')
            local feed_file="${NFTBAN_FEEDS_STORAGE_DIR}/${feed_lowercase}.txt"
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

# =============================================================================
# TASK QUEUE INTEGRATION
# =============================================================================
# Source task queue at end to make nftban_queue_add available for async operations
# Guard above prevents circular dependency (task_queue.sh sources this file)
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/helpers/nftban_task_queue.sh" 2>/dev/null || true
