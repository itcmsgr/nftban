#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_trace"
# meta:type="helper"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Logs START/END of scripts with unique trace IDs to detect stuck scripts"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

set -Eeuo pipefail

# =============================================================================
# MODULE GUARD
# =============================================================================

[[ -n "${NFTBAN_TRACE_LOADED:-}" ]] && return 0
readonly NFTBAN_TRACE_LOADED=1

# =============================================================================
# CONFIGURATION
# =============================================================================

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

# Defaults
: "${NFTBAN_DEBUG_TRACE:=false}"
: "${NFTBAN_DEBUG_TRACE_LOG:=${NFTBAN_LOG_DIR}/debug_trace.log}"

# =============================================================================
# TRACE STATE
# =============================================================================

# Current trace ID (set by nftban_trace_start)
declare -g _NFTBAN_TRACE_ID=""
declare -g _NFTBAN_TRACE_MODULE=""
declare -g _NFTBAN_TRACE_START_TIME=""

# =============================================================================
# TRACE FUNCTIONS
# =============================================================================

# Generate unique trace ID: MODULE-TIMESTAMP-PID
# Format: login_alert-20251204_114532_123456-12345
_nftban_trace_generate_id() {
    local module="$1"
    local timestamp
    timestamp=$(date '+%Y%m%d_%H%M%S_%N')
    echo "${module}-${timestamp}-$$"
}

# Start trace - call at beginning of script/function
# Usage: nftban_trace_start "module_name" [function_name]
nftban_trace_start() {
    # Skip if debug trace disabled
    [[ "${NFTBAN_DEBUG_TRACE}" != "true" ]] && return 0

    local module="${1:-unknown}"
    local function_name="${2:-main}"

    # Generate trace ID
    _NFTBAN_TRACE_ID=$(_nftban_trace_generate_id "$module")
    _NFTBAN_TRACE_MODULE="$module"
    _NFTBAN_TRACE_START_TIME=$(date '+%Y-%m-%d %H:%M:%S.%N')

    # Ensure log directory exists
    local log_dir
    log_dir="$(dirname "$NFTBAN_DEBUG_TRACE_LOG")"
    [[ ! -d "$log_dir" ]] && mkdir -p "$log_dir" 2>/dev/null

    # Write START entry
    local entry="[${_NFTBAN_TRACE_START_TIME}] [START] [${_NFTBAN_TRACE_ID}] ${module}::${function_name} PID=$$ PPID=$PPID"
    echo "$entry" >> "$NFTBAN_DEBUG_TRACE_LOG" 2>/dev/null || true

    # Also store in temp file for crash detection (use mktemp for security)
    local trace_file
    trace_file="$(mktemp -t nftban-trace-XXXXXX)" 2>/dev/null || trace_file="/tmp/nftban_trace_$$"
    echo "$_NFTBAN_TRACE_ID" > "$trace_file" 2>/dev/null || true
    # Store path for cleanup
    export _NFTBAN_TRACE_FILE="$trace_file"
}

# End trace - call at end of script/function
# Usage: nftban_trace_end [exit_code]
nftban_trace_end() {
    # Skip if debug trace disabled
    [[ "${NFTBAN_DEBUG_TRACE}" != "true" ]] && return 0

    # Skip if no trace started
    [[ -z "${_NFTBAN_TRACE_ID:-}" ]] && return 0

    local exit_code="${1:-0}"
    local end_time
    end_time=$(date '+%Y-%m-%d %H:%M:%S.%N')

    # Calculate duration if possible
    local duration="N/A"
    if [[ -n "${_NFTBAN_TRACE_START_TIME:-}" ]]; then
        # Simple duration calculation (seconds)
        local start_epoch end_epoch
        start_epoch=$(date -d "${_NFTBAN_TRACE_START_TIME}" '+%s' 2>/dev/null || echo "0")
        end_epoch=$(date '+%s')
        if [[ "$start_epoch" != "0" ]]; then
            duration="$((end_epoch - start_epoch))s"
        fi
    fi

    # Write END entry
    local status="OK"
    [[ "$exit_code" != "0" ]] && status="ERROR($exit_code)"

    local entry="[${end_time}] [END]   [${_NFTBAN_TRACE_ID}] ${_NFTBAN_TRACE_MODULE} status=${status} duration=${duration}"
    echo "$entry" >> "$NFTBAN_DEBUG_TRACE_LOG" 2>/dev/null || true

    # Remove temp file (use stored path from mktemp)
    [[ -n "${_NFTBAN_TRACE_FILE:-}" ]] && rm -f "$_NFTBAN_TRACE_FILE" 2>/dev/null || true

    # Clear state
    _NFTBAN_TRACE_ID=""
    _NFTBAN_TRACE_MODULE=""
    _NFTBAN_TRACE_START_TIME=""
    unset _NFTBAN_TRACE_FILE
}

# Mark trace as error (before exit)
# Usage: nftban_trace_error "error message"
nftban_trace_error() {
    [[ "${NFTBAN_DEBUG_TRACE}" != "true" ]] && return 0
    [[ -z "${_NFTBAN_TRACE_ID:-}" ]] && return 0

    local error_msg="${1:-Unknown error}"
    local error_time
    error_time=$(date '+%Y-%m-%d %H:%M:%S.%N')

    local entry="[${error_time}] [ERROR] [${_NFTBAN_TRACE_ID}] ${_NFTBAN_TRACE_MODULE}: ${error_msg}"
    echo "$entry" >> "$NFTBAN_DEBUG_TRACE_LOG" 2>/dev/null || true
}

# Add checkpoint to trace (for long-running scripts)
# Usage: nftban_trace_checkpoint "description"
nftban_trace_checkpoint() {
    [[ "${NFTBAN_DEBUG_TRACE}" != "true" ]] && return 0
    [[ -z "${_NFTBAN_TRACE_ID:-}" ]] && return 0

    local checkpoint="${1:-checkpoint}"
    local checkpoint_time
    checkpoint_time=$(date '+%Y-%m-%d %H:%M:%S.%N')

    local entry="[${checkpoint_time}] [CHECK] [${_NFTBAN_TRACE_ID}] ${_NFTBAN_TRACE_MODULE}: ${checkpoint}"
    echo "$entry" >> "$NFTBAN_DEBUG_TRACE_LOG" 2>/dev/null || true
}

# =============================================================================
# TRACE ANALYSIS FUNCTIONS
# =============================================================================

# Find orphaned traces (START without END)
# Usage: nftban_trace_find_orphans [minutes_ago]
nftban_trace_find_orphans() {
    local minutes_ago="${1:-5}"  # Default: look for traces older than 5 minutes
    local trace_log="${NFTBAN_DEBUG_TRACE_LOG}"

    [[ ! -f "$trace_log" ]] && echo "No trace log found" && return 1

    echo "=== Orphaned Traces (START without END, older than ${minutes_ago}m) ==="
    echo ""

    # Get all START trace IDs
    local start_ids
    start_ids=$(grep '\[START\]' "$trace_log" | sed 's/.*\[\([^]]*\)\].*/\1/' | grep -E '^[a-z_]+-[0-9]+_[0-9]+_[0-9]+-[0-9]+$')

    # Get all END trace IDs
    local end_ids
    end_ids=$(grep '\[END\]' "$trace_log" | sed 's/.*\[\([^]]*\)\].*/\1/' | grep -E '^[a-z_]+-[0-9]+_[0-9]+_[0-9]+-[0-9]+$')

    local orphan_count=0
    local current_time
    current_time=$(date '+%s')
    local threshold=$((minutes_ago * 60))

    for trace_id in $start_ids; do
        # Check if this trace has an END
        if ! echo "$end_ids" | grep -q "^${trace_id}$"; then
            # Found orphan - check age
            local trace_time
            trace_time=$(grep "\[${trace_id}\]" "$trace_log" | head -1 | sed 's/\[\([^]]*\)\].*/\1/')
            local trace_epoch
            trace_epoch=$(date -d "$trace_time" '+%s' 2>/dev/null || echo "0")

            if [[ "$trace_epoch" != "0" ]]; then
                local age=$((current_time - trace_epoch))
                if [[ $age -gt $threshold ]]; then
                    ((orphan_count++))
                    echo "ORPHAN #${orphan_count}:"
                    echo "  Trace ID: $trace_id"
                    echo "  Age: $((age / 60))m $((age % 60))s"
                    grep "\[${trace_id}\]" "$trace_log" | sed 's/^/  /'
                    echo ""
                fi
            fi
        fi
    done

    if [[ $orphan_count -eq 0 ]]; then
        echo "No orphaned traces found (all scripts completed normally)"
    else
        echo "Found $orphan_count orphaned trace(s) - these scripts may have crashed"
    fi

    return $orphan_count
}

# Show recent trace activity
# Usage: nftban_trace_recent [count]
nftban_trace_recent() {
    local count="${1:-20}"
    local trace_log="${NFTBAN_DEBUG_TRACE_LOG}"

    [[ ! -f "$trace_log" ]] && echo "No trace log found" && return 1

    echo "=== Recent Trace Activity (last $count entries) ==="
    tail -n "$count" "$trace_log"
}

# Show trace statistics
# Usage: nftban_trace_stats
nftban_trace_stats() {
    local trace_log="${NFTBAN_DEBUG_TRACE_LOG}"

    [[ ! -f "$trace_log" ]] && echo "No trace log found" && return 1

    echo "=== Trace Statistics ==="
    echo ""
    echo "Total START entries: $(grep -c '\[START\]' "$trace_log" 2>/dev/null || echo 0)"
    echo "Total END entries:   $(grep -c '\[END\]' "$trace_log" 2>/dev/null || echo 0)"
    echo "Total ERROR entries: $(grep -c '\[ERROR\]' "$trace_log" 2>/dev/null || echo 0)"
    echo "Total CHECK entries: $(grep -c '\[CHECK\]' "$trace_log" 2>/dev/null || echo 0)"
    echo ""
    echo "Log file size: $(du -h "$trace_log" 2>/dev/null | cut -f1)"
    echo ""

    echo "=== Traces by Module (last 24h) ==="
    local yesterday
    yesterday=$(date -d '1 day ago' '+%Y-%m-%d')
    grep '\[START\]' "$trace_log" | grep -E "^\[$yesterday|^\[$(date '+%Y-%m-%d')" | \
        sed 's/.*\] \([^:]*\)::.*/\1/' | sort | uniq -c | sort -rn | head -10
}

# Clear old trace entries (log rotation)
# Usage: nftban_trace_rotate [days_to_keep]
nftban_trace_rotate() {
    local days="${1:-7}"
    local trace_log="${NFTBAN_DEBUG_TRACE_LOG}"

    [[ ! -f "$trace_log" ]] && return 0

    local cutoff_date
    cutoff_date=$(date -d "$days days ago" '+%Y-%m-%d')

    local backup="${trace_log}.old"
    local temp="${trace_log}.tmp"

    # Keep only recent entries
    awk -v cutoff="$cutoff_date" '
        /^\[/ {
            # Extract date from [YYYY-MM-DD HH:MM:SS.nnnnnnnnn]
            match($0, /\[([0-9]{4}-[0-9]{2}-[0-9]{2})/, arr)
            if (arr[1] >= cutoff) print
        }
    ' "$trace_log" > "$temp"

    # Backup and replace
    [[ -f "$backup" ]] && rm -f "$backup"
    mv "$trace_log" "$backup"
    mv "$temp" "$trace_log"
    chmod 640 "$trace_log" 2>/dev/null || true

    echo "Rotated trace log, kept entries from $cutoff_date onwards"
}

# =============================================================================
# TRAP HANDLER (Auto-log on unexpected exit)
# =============================================================================

# Trap handler for unexpected exits
_nftban_trace_trap_handler() {
    local exit_code=$?
    if [[ -n "${_NFTBAN_TRACE_ID:-}" ]] && [[ "${NFTBAN_DEBUG_TRACE}" == "true" ]]; then
        nftban_trace_error "Unexpected exit (signal/error)"
        nftban_trace_end "$exit_code"
    fi
}

# Install trap (only if trace is enabled)
if [[ "${NFTBAN_DEBUG_TRACE}" == "true" ]]; then
    trap '_nftban_trace_trap_handler' EXIT ERR
fi

# =============================================================================
# EXPORT FUNCTIONS
# =============================================================================

export -f nftban_trace_start
export -f nftban_trace_end
export -f nftban_trace_error
export -f nftban_trace_checkpoint
export -f nftban_trace_find_orphans
export -f nftban_trace_recent
export -f nftban_trace_stats
export -f nftban_trace_rotate

# =============================================================================
# MODULE LOADED
# =============================================================================

if [[ "${NFTBAN_DEBUG_TRACE}" == "true" ]]; then
    # Log that trace module is loaded (only in debug mode)
    echo "[$(date '+%Y-%m-%d %H:%M:%S.%N')] [LOAD]  [nftban_trace] Module loaded PID=$$" >> "$NFTBAN_DEBUG_TRACE_LOG" 2>/dev/null || true
fi
