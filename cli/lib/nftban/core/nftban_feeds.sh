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
        local lock_age
        lock_age=$(( $(date +%s) - $(stat -c %Y "$NFTBAN_FEEDS_LOCKFILE" 2>/dev/null || echo 0) ))
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
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

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
# Uses config architecture: check .conf.local override first, fallback to feeds.conf default
nftban_feeds_get_property() {
    local feed_name="$1"
    local property="$2"  # URL, ENABLED, CATEGORY, DESCRIPTION, etc.

    local var_name="FEED_${feed_name}_${property}"
    local value=""
    local local_conf="${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf.local"

    # 1. Check .conf.local override first (user customizations)
    if [[ -f "$local_conf" ]]; then
        value=$(grep "^${var_name}=" "$local_conf" 2>/dev/null | tail -1 | cut -d'=' -f2- | tr -d '"')
    fi

    # 2. Fallback to feeds.conf default if not overridden
    if [[ -z "$value" ]] && [[ -f "$NFTBAN_FEEDS_CONFIG" ]]; then
        value=$(grep "^${var_name}=" "$NFTBAN_FEEDS_CONFIG" 2>/dev/null | head -1 | cut -d'=' -f2- | tr -d '"')
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

    # Disable feed
    nftban_feeds_set_property "$feed_name" "ENABLED" "false"
    nftban_feeds_log INFO "Feed disabled: $feed_name"

    # Show immediate feedback
    echo "✓ Feed disabled: $feed_name"
    echo ""

    # ARCHITECTURE COMPLIANCE: Always use timer-based queue for nftables sync
    # NEVER execute synchronous sync - all feeds/ban/unban/countries managed by timer
    # This prevents 30+ second hangs with large feed sets and respects async architecture
    if command -v nftban_queue_add &>/dev/null; then
        nftban_queue_add "feeds_sync" "Feed disabled: $feed_name" >/dev/null 2>&1
        echo "✅ Feed disabled successfully"
        echo "   NFTables update queued (processed every 2 minutes)"
        echo "   Check queue: tail -f /var/log/nftban/queue.log"
        echo ""
    else
        nftban_feeds_log "WARN" "Queue function not available, sync will run on next timer cycle"
        echo "✅ Feed disabled successfully"
        echo "   NFTables will sync on next timer cycle (every 2 minutes)"
        echo ""
    fi
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

    # Save parsed IPs
    echo "$parse_result" > "$parsed_file"
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

# Bash feed sync (fallback, v0.6.0) - ATOMIC RELOAD
nftban_feeds_sync_to_nftables_bash() {
    # Collect all IPs from enabled feeds
    local ipv4_list="${NFTBAN_FEEDS_CACHE_DIR}/feeds_ipv4.tmp"
    local ipv6_list="${NFTBAN_FEEDS_CACHE_DIR}/feeds_ipv6.tmp"

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

    # Count unique IPs
    local ipv4_count=0
    local ipv6_count=0
    [[ -s "$ipv4_list" ]] && ipv4_count=$(sort -u "$ipv4_list" | wc -l)
    [[ -s "$ipv6_list" ]] && ipv6_count=$(sort -u "$ipv6_list" | wc -l)

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
        nftban_feeds_log INFO "Sync complete: $ipv4_count IPv4, $ipv6_count IPv6"
    else
        nftban_feeds_log ERROR "Atomic reload failed"
        # Cleanup
        rm -f "$ipv4_list" "$ipv6_list" "$nft_file"
        return 1
    fi

    # Cleanup
    rm -f "$ipv4_list" "$ipv6_list" "$nft_file"

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
