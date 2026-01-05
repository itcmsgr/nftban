#!/usr/bin/env bash
# =============================================================================
# NFTBan Task Queue System
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Async task queue for heavy operations (feeds sync, geoban apply)
#
# How it works:
# 1. Commands (feeds disable, geoban ban, etc.) add tasks to queue
# 2. Systemd timer runs nftban-sync.timer every minute
# 3. Timer processes ONE task at a time (prevents parallel syncs)
# 4. Lock file prevents multiple timer instances
#
# Task Types:
# - feeds_sync: Sync all feeds to nftables
# - geoban_apply: Apply GeoBan rules to nftables
#
# =============================================================================

# Prevent double-loading (required for circular dependency with nftban_feeds.sh)
[[ -n "${NFTBAN_TASK_QUEUE_LOADED:-}" ]] && return 0
readonly NFTBAN_TASK_QUEUE_LOADED=1

# Source central config for canonical paths (NO HARDCODED FALLBACKS)
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

readonly TASK_QUEUE_DIR="${NFTBAN_DATA_DIR}/queue"
readonly TASK_LOCK_FILE="${NFTBAN_RUN_DIR}/queue.lock"
readonly TASK_LOG="${NFTBAN_LOG_DIR}/queue.log"

# Source required modules for task processing
: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/core/nftban_feeds.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/core/nftban_geoban.sh" 2>/dev/null || true

# Initialize queue directory (with correct ownership)
_queue_init() {
    mkdir -p "$TASK_QUEUE_DIR" 2>/dev/null
    mkdir -p "$(dirname "$TASK_LOCK_FILE")" 2>/dev/null
    touch "$TASK_LOG" 2>/dev/null
    chown nftban:nftban "$TASK_LOG" 2>/dev/null || true
    chmod 640 "$TASK_LOG" 2>/dev/null || true
}

# Log to queue log
_queue_log() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*" >> "$TASK_LOG"
}

# Add task to queue
# Usage: nftban_queue_add <task_type> [description]
nftban_queue_add() {
    local task_type="$1"
    local description="${2:-$task_type}"

    _queue_init

    # Create task file with timestamp
    local task_id task_file
    task_id="$(date +%s)-${task_type}"
    task_file="${TASK_QUEUE_DIR}/${task_id}.task"

    cat > "$task_file" <<EOF
TASK_TYPE="$task_type"
TASK_DESCRIPTION="$description"
TASK_CREATED="$(date '+%Y-%m-%d %H:%M:%S')"
TASK_STATUS="pending"
EOF

    _queue_log "INFO" "Task queued: $task_type ($description)"
    echo "$task_id"
}

# Check if queue has pending tasks
nftban_queue_has_pending() {
    _queue_init
    [[ -n "$(find "$TASK_QUEUE_DIR" -name "*.task" -type f 2>/dev/null)" ]]
}

# Get pending task count
nftban_queue_count() {
    _queue_init
    find "$TASK_QUEUE_DIR" -name "*.task" -type f 2>/dev/null | wc -l
}

# Process next task in queue
# Returns: 0 if task processed, 1 if no tasks, 2 if locked
nftban_queue_process_next() {
    _queue_init

    # Check for lock (prevent parallel processing)
    if [[ -f "$TASK_LOCK_FILE" ]]; then
        local lock_pid
        lock_pid=$(cat "$TASK_LOCK_FILE" 2>/dev/null)
        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            # Check if locked for over 15 minutes (900 seconds)
            local lock_age
            lock_age=$(( $(date +%s) - $(stat -c %Y "$TASK_LOCK_FILE" 2>/dev/null || echo 0) ))
            if [[ $lock_age -gt 900 ]]; then
                _queue_log "ALERT" "Queue processor stuck for ${lock_age}s (PID: $lock_pid) - SOMETHING WRONG!"
                # Log to syslog for admin alerts
                logger -t nftban-queue -p user.alert "NFTBan queue processor stuck for ${lock_age}s - manual intervention required"
            fi
            _queue_log "WARN" "Queue processor already running (PID: $lock_pid)"
            return 2
        else
            # Stale lock, remove it
            rm -f "$TASK_LOCK_FILE"
        fi
    fi

    # Acquire lock
    echo "$$" > "$TASK_LOCK_FILE"

    # Get oldest task
    local task_file
    task_file=$(find "$TASK_QUEUE_DIR" -name "*.task" -type f 2>/dev/null | sort | head -1)

    if [[ -z "$task_file" ]]; then
        rm -f "$TASK_LOCK_FILE"
        return 1
    fi

    # Load task
    # shellcheck source=/dev/null
    source "$task_file"

    _queue_log "INFO" "Processing task: $TASK_TYPE ($TASK_DESCRIPTION)"

    # Process based on type
    local result=0
    case "$TASK_TYPE" in
        feeds_sync)
            _queue_log "INFO" "Running feeds sync..."
            if nftban_feeds_sync_to_nftables >> "$TASK_LOG" 2>&1; then
                _queue_log "SUCCESS" "Feeds sync completed"
            else
                _queue_log "ERROR" "Feeds sync failed"
                result=1
            fi
            ;;
        geoban_apply)
            _queue_log "INFO" "Running GeoBan apply..."
            if nftban_geoban_apply_to_nftables >> "$TASK_LOG" 2>&1; then
                _queue_log "SUCCESS" "GeoBan apply completed"
            else
                _queue_log "ERROR" "GeoBan apply failed"
                result=1
            fi
            ;;
        *)
            _queue_log "ERROR" "Unknown task type: $TASK_TYPE"
            result=1
            ;;
    esac

    # Remove task file
    rm -f "$task_file"

    # Release lock
    rm -f "$TASK_LOCK_FILE"

    return $result
}

# Export functions
export -f nftban_queue_add
export -f nftban_queue_has_pending
export -f nftban_queue_count
export -f nftban_queue_process_next
