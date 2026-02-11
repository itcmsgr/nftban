#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_task_queue"
# meta:type="helper"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Async task queue with retry, exponential backoff, and dead-letter queue"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
#
# Architecture:
#   pending/  - New tasks waiting to be processed
#   work/     - Task currently being processed (atomic claim via rename)
#   dlq/      - Failed tasks after max retries (manual review required)
#
# Task file format:
#   TASK_ID="<timestamp>-<type>-<rand>"
#   TASK_TYPE="feeds_sync|geoban_apply|mail_send|..."
#   TASK_DESCRIPTION="Human-readable description"
#   TASK_CREATED_EPOCH="<unix timestamp>"
#   TASK_RETRIES="0"
#   TASK_NEXT_ATTEMPT_EPOCH="0"
#   TASK_LAST_ERROR=""
#   TASK_PAYLOAD_FILE=""  # Optional: path to JSON payload
#
# Processing flow:
#   1. Timer triggers every 2 minutes
#   2. Claim oldest eligible task (NEXT_ATTEMPT_EPOCH <= now) via atomic rename
#   3. Execute task handler
#   4. On success: delete task, increment success counter
#   5. On failure: increment RETRIES, calculate backoff, move back to pending
#   6. If RETRIES >= MAX: move to DLQ, emit alert
#
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${NFTBAN_TASK_QUEUE_LOADED:-}" ]] && return 0
readonly NFTBAN_TASK_QUEUE_LOADED=1

# Source central config
# shellcheck source=/etc/nftban/nftban.conf
[[ -f "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf" ]] && source "${NFTBAN_CONFIG_DIR:-/etc/nftban}/nftban.conf"

# =============================================================================
# CONFIGURATION (with safe defaults)
# =============================================================================

readonly QUEUE_MAX_RETRIES="${NFTBAN_QUEUE_MAX_RETRIES:-3}"
readonly QUEUE_BACKOFF_BASE="${NFTBAN_QUEUE_BACKOFF_BASE_SECONDS:-30}"
readonly QUEUE_BACKOFF_MAX="${NFTBAN_QUEUE_BACKOFF_MAX_SECONDS:-900}"
readonly QUEUE_LOCK_STUCK_THRESHOLD="${NFTBAN_QUEUE_LOCK_STUCK_THRESHOLD:-1200}"

# CWE-400 mitigation: Bounded queue to prevent resource exhaustion
readonly QUEUE_MAX_PENDING="${NFTBAN_QUEUE_MAX_PENDING:-10000}"
readonly QUEUE_DLQ_AUTO_RETENTION_DAYS="${NFTBAN_QUEUE_DLQ_AUTO_RETENTION_DAYS:-7}"

readonly QUEUE_PENDING_DIR="${NFTBAN_QUEUE_PENDING_DIR:-${NFTBAN_DATA_DIR}/queue/pending}"
readonly QUEUE_WORK_DIR="${NFTBAN_QUEUE_WORK_DIR:-${NFTBAN_DATA_DIR}/queue/work}"
readonly QUEUE_DLQ_DIR="${NFTBAN_QUEUE_DLQ_DIR:-${NFTBAN_DATA_DIR}/queue/dlq}"
readonly QUEUE_LOCK_FILE="${NFTBAN_RUN_DIR}/queue.lock"
readonly QUEUE_LOG="${NFTBAN_LOG_DIR}/queue.log"
readonly QUEUE_METRICS_FILE="${NFTBAN_QUEUE_METRICS_FILE:-${NFTBAN_DATA_DIR}/metrics/queue.prom}"

# Counters directory (atomic increment files)
readonly QUEUE_COUNTERS_DIR="${NFTBAN_DATA_DIR}/metrics/counters"

# =============================================================================
# SOURCE TASK HANDLERS (after config is loaded)
# =============================================================================

: "${NFTBAN_LIB_DIR:=/usr/lib/nftban}"
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/core/nftban_feeds.sh" 2>/dev/null || true
# shellcheck source=/dev/null
source "${NFTBAN_LIB_DIR}/core/nftban_geoban.sh" 2>/dev/null || true

# =============================================================================
# INITIALIZATION
# =============================================================================

_queue_init() {
    # Create all queue directories with correct ownership
    local dir
    for dir in "$QUEUE_PENDING_DIR" "$QUEUE_WORK_DIR" "$QUEUE_DLQ_DIR" "$QUEUE_COUNTERS_DIR" "$(dirname "$QUEUE_METRICS_FILE")"; do
        mkdir -p "$dir" 2>/dev/null || true
        chown nftban:nftban "$dir" 2>/dev/null || true
        chmod 750 "$dir" 2>/dev/null || true
    done

    mkdir -p "$(dirname "$QUEUE_LOCK_FILE")" 2>/dev/null || true
    touch "$QUEUE_LOG" 2>/dev/null || true
    chown nftban:nftban "$QUEUE_LOG" 2>/dev/null || true
    chmod 640 "$QUEUE_LOG" 2>/dev/null || true

    # Initialize counter files if missing
    local counter
    for counter in processed_total failed_total retries_total dlq_total; do
        [[ ! -f "${QUEUE_COUNTERS_DIR}/${counter}" ]] && echo "0" > "${QUEUE_COUNTERS_DIR}/${counter}"
    done
}

# =============================================================================
# LOGGING
# =============================================================================

_queue_log() {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $*" >> "$QUEUE_LOG"

    # Also log to syslog for ALERT/ERROR levels
    if [[ "$level" == "ALERT" || "$level" == "ERROR" ]]; then
        logger -t nftban-queue -p "user.${level,,}" "$*"
    fi
}

# =============================================================================
# METRICS (Atomic counter increment)
# =============================================================================

_queue_counter_inc() {
    local counter_name="$1"
    local increment="${2:-1}"
    local counter_file="${QUEUE_COUNTERS_DIR}/${counter_name}"

    (
        flock -x 200
        local current
        current=$(cat "$counter_file" 2>/dev/null || echo "0")
        echo "$((current + increment))" > "$counter_file"
    ) 200>"${counter_file}.lock"
}

_queue_counter_get() {
    local counter_name="$1"
    cat "${QUEUE_COUNTERS_DIR}/${counter_name}" 2>/dev/null || echo "0"
}

_queue_write_metrics() {
    # Write Prometheus metrics to textfile
    local pending working dlq
    pending=$(find "$QUEUE_PENDING_DIR" -name "*.task" -type f 2>/dev/null | wc -l)
    working=$(find "$QUEUE_WORK_DIR" -name "*.task" -type f 2>/dev/null | wc -l)
    dlq=$(find "$QUEUE_DLQ_DIR" -name "*.task" -type f 2>/dev/null | wc -l)

    local processed_total failed_total retries_total dlq_total
    processed_total=$(_queue_counter_get "processed_total")
    failed_total=$(_queue_counter_get "failed_total")
    retries_total=$(_queue_counter_get "retries_total")
    dlq_total=$(_queue_counter_get "dlq_total")

    # Calculate oldest pending task age (seconds)
    local oldest_pending_age=0
    if (( pending > 0 )); then
        local oldest_file now oldest_mtime
        oldest_file=$(find "$QUEUE_PENDING_DIR" -name "*.task" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | head -1 | cut -d' ' -f2)
        if [[ -n "$oldest_file" ]] && [[ -f "$oldest_file" ]]; then
            now=$(date +%s)
            oldest_mtime=$(stat -c %Y "$oldest_file" 2>/dev/null || echo "$now")
            oldest_pending_age=$((now - oldest_mtime))
        fi
    fi

    cat > "${QUEUE_METRICS_FILE}.tmp" <<EOF
# HELP nftban_queue_tasks_pending Number of tasks waiting to be processed
# TYPE nftban_queue_tasks_pending gauge
nftban_queue_tasks_pending $pending

# HELP nftban_queue_tasks_working Number of tasks currently being processed
# TYPE nftban_queue_tasks_working gauge
nftban_queue_tasks_working $working

# HELP nftban_queue_tasks_dlq Number of tasks in dead-letter queue
# TYPE nftban_queue_tasks_dlq gauge
nftban_queue_tasks_dlq $dlq

# HELP nftban_queue_oldest_pending_age_seconds Age of oldest pending task in seconds
# TYPE nftban_queue_oldest_pending_age_seconds gauge
nftban_queue_oldest_pending_age_seconds $oldest_pending_age

# HELP nftban_queue_tasks_processed_total Total tasks successfully processed
# TYPE nftban_queue_tasks_processed_total counter
nftban_queue_tasks_processed_total $processed_total

# HELP nftban_queue_tasks_failed_total Total task processing failures
# TYPE nftban_queue_tasks_failed_total counter
nftban_queue_tasks_failed_total $failed_total

# HELP nftban_queue_task_retries_total Total task retry attempts
# TYPE nftban_queue_task_retries_total counter
nftban_queue_task_retries_total $retries_total

# HELP nftban_queue_dlq_total Total tasks moved to dead-letter queue
# TYPE nftban_queue_dlq_total counter
nftban_queue_dlq_total $dlq_total

# HELP nftban_queue_last_run_timestamp Unix timestamp of last queue processor run
# TYPE nftban_queue_last_run_timestamp gauge
nftban_queue_last_run_timestamp $(date +%s)
EOF

    mv "${QUEUE_METRICS_FILE}.tmp" "$QUEUE_METRICS_FILE" 2>/dev/null || true
    chmod 644 "$QUEUE_METRICS_FILE" 2>/dev/null || true
}

# =============================================================================
# BACKOFF CALCULATION
# =============================================================================

_queue_calculate_backoff() {
    local retries="$1"
    local backoff

    # Exponential backoff: min(max, base * 2^retries)
    backoff=$((QUEUE_BACKOFF_BASE * (1 << retries)))

    if [[ $backoff -gt $QUEUE_BACKOFF_MAX ]]; then
        backoff=$QUEUE_BACKOFF_MAX
    fi

    echo "$backoff"
}

# =============================================================================
# TASK ID GENERATION
# =============================================================================

_queue_generate_task_id() {
    local task_type="$1"
    local timestamp rand
    timestamp=$(date +%Y%m%dT%H%M%SZ)
    rand=$(head -c 4 /dev/urandom | xxd -p 2>/dev/null || echo "$$")
    echo "${timestamp}-${task_type}-${rand}"
}

# =============================================================================
# ADD TASK TO QUEUE
# =============================================================================

nftban_queue_add() {
    local task_type="$1"
    local description="${2:-$task_type}"
    local payload_file="${3:-}"

    _queue_init

    # CWE-400 mitigation: Check pending queue capacity
    local pending_count
    pending_count=$(find "$QUEUE_PENDING_DIR" -name "*.task" -type f 2>/dev/null | wc -l)
    if [[ $pending_count -ge $QUEUE_MAX_PENDING ]]; then
        _queue_log "ERROR" "Queue at capacity ($QUEUE_MAX_PENDING tasks). Rejecting task: $task_type"
        echo "ERROR: Queue full" >&2
        return 1
    fi

    local task_id task_file now
    task_id=$(_queue_generate_task_id "$task_type")
    task_file="${QUEUE_PENDING_DIR}/${task_id}.task"
    now=$(date +%s)

    cat > "$task_file" <<EOF
TASK_ID="$task_id"
TASK_TYPE="$task_type"
TASK_DESCRIPTION="$description"
TASK_CREATED_EPOCH="$now"
TASK_RETRIES="0"
TASK_NEXT_ATTEMPT_EPOCH="0"
TASK_LAST_ERROR=""
TASK_PAYLOAD_FILE="$payload_file"
EOF

    chown nftban:nftban "$task_file" 2>/dev/null || true
    chmod 640 "$task_file" 2>/dev/null || true

    _queue_log "INFO" "Task queued: $task_id ($task_type: $description)"
    echo "$task_id"
}

# =============================================================================
# QUEUE STATUS FUNCTIONS
# =============================================================================

nftban_queue_has_pending() {
    _queue_init
    [[ -n "$(find "$QUEUE_PENDING_DIR" -name "*.task" -type f 2>/dev/null | head -1)" ]]
}

nftban_queue_count() {
    _queue_init
    find "$QUEUE_PENDING_DIR" -name "*.task" -type f 2>/dev/null | wc -l
}

nftban_queue_count_dlq() {
    _queue_init
    find "$QUEUE_DLQ_DIR" -name "*.task" -type f 2>/dev/null | wc -l
}

# =============================================================================
# LOCK MANAGEMENT (with auto-recovery)
# =============================================================================

_queue_acquire_lock() {
    local now lock_pid lock_age
    now=$(date +%s)

    if [[ -f "$QUEUE_LOCK_FILE" ]]; then
        lock_pid=$(cat "$QUEUE_LOCK_FILE" 2>/dev/null | head -1)

        if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
            # Process exists, check if stuck
            lock_age=$(( now - $(stat -c %Y "$QUEUE_LOCK_FILE" 2>/dev/null || echo "$now") ))

            if [[ $lock_age -gt $QUEUE_LOCK_STUCK_THRESHOLD ]]; then
                # Stuck lock - auto-recovery
                _queue_log "ALERT" "Queue processor stuck for ${lock_age}s (PID: $lock_pid) - initiating auto-recovery"

                # Try graceful termination first
                kill -TERM "$lock_pid" 2>/dev/null || true
                sleep 5

                # Force kill if still running
                if kill -0 "$lock_pid" 2>/dev/null; then
                    _queue_log "WARN" "Graceful termination failed, force killing PID $lock_pid"
                    kill -KILL "$lock_pid" 2>/dev/null || true
                    sleep 1
                fi

                # Clean up any orphaned work tasks
                local orphan_task
                for orphan_task in "$QUEUE_WORK_DIR"/*.task; do
                    [[ ! -f "$orphan_task" ]] && continue
                    _queue_log "WARN" "Moving orphaned work task back to pending: $(basename "$orphan_task")"
                    mv "$orphan_task" "$QUEUE_PENDING_DIR/" 2>/dev/null || true
                done

                rm -f "$QUEUE_LOCK_FILE"
                _queue_counter_inc "lock_recoveries_total"
                _queue_log "INFO" "Lock auto-recovery completed"
            else
                _queue_log "DEBUG" "Queue processor running (PID: $lock_pid, age: ${lock_age}s)"
                return 1  # Lock held, not stuck
            fi
        else
            # Stale lock (process doesn't exist)
            _queue_log "DEBUG" "Removing stale lock (PID $lock_pid not found)"
            rm -f "$QUEUE_LOCK_FILE"
        fi
    fi

    # Acquire lock with PID and timestamp
    echo "$$" > "$QUEUE_LOCK_FILE"
    echo "$now" >> "$QUEUE_LOCK_FILE"
    return 0
}

_queue_release_lock() {
    rm -f "$QUEUE_LOCK_FILE"
}

# =============================================================================
# GET NEXT ELIGIBLE TASK
# =============================================================================

_queue_get_next_eligible_task() {
    local now task_file
    now=$(date +%s)

    # Find oldest task that is eligible (NEXT_ATTEMPT_EPOCH <= now)
    for task_file in $(find "$QUEUE_PENDING_DIR" -name "*.task" -type f 2>/dev/null | sort); do
        [[ ! -f "$task_file" ]] && continue

        # Read NEXT_ATTEMPT_EPOCH from task
        local next_attempt
        next_attempt=$(grep "^TASK_NEXT_ATTEMPT_EPOCH=" "$task_file" 2>/dev/null | cut -d'"' -f2)
        next_attempt="${next_attempt:-0}"

        if [[ $next_attempt -le $now ]]; then
            echo "$task_file"
            return 0
        fi
    done

    return 1
}

# =============================================================================
# TASK EXECUTION HANDLERS
# =============================================================================

_queue_execute_task() {
    local task_type="$1"
    local task_description="$2"
    local task_payload_file="$3"
    local error_output

    case "$task_type" in
        feeds_sync)
            _queue_log "INFO" "Executing: $task_description"
            error_output=$(nftban_feeds_sync_to_nftables 2>&1) && return 0
            ;;
        geoban_apply)
            _queue_log "INFO" "Executing: geoban apply"
            error_output=$(nftban_geoban_apply_to_nftables 2>&1) && return 0
            ;;
        mail_send)
            _queue_log "INFO" "Executing: mail send"
            if [[ -n "$task_payload_file" ]] && [[ -f "$task_payload_file" ]]; then
                # Load mail payload (expects: MAIL_BODY_FILE, MAIL_TO, MAIL_SUBJECT)
                # shellcheck source=/dev/null
                source "$task_payload_file"
                # Validate required payload vars
                if [[ -z "${MAIL_BODY_FILE:-}" ]]; then
                    error_output="Mail payload missing MAIL_BODY_FILE"
                elif [[ ! -f "$MAIL_BODY_FILE" ]]; then
                    error_output="Mail body file not found: $MAIL_BODY_FILE"
                elif type nftban_mail_send &>/dev/null; then
                    # nftban_mail_send(content, [recipient]) - content first, recipient second
                    error_output=$(nftban_mail_send "$MAIL_BODY_FILE" "$MAIL_TO" 2>&1) && return 0
                else
                    error_output="nftban_mail_send function not available"
                fi
            else
                error_output="Mail payload file not found: $task_payload_file"
            fi
            ;;
        *)
            error_output="Unknown task type: $task_type"
            ;;
    esac

    # If we get here, task failed
    # Sanitize error output (truncate, strip secrets)
    error_output="${error_output:0:200}"
    error_output="${error_output//[^a-zA-Z0-9 ._:\/\-]/_}"  # Strip special chars
    echo "$error_output"
    return 1
}

# =============================================================================
# HANDLE TASK FAILURE (Retry or DLQ)
# =============================================================================

_queue_handle_failure() {
    local task_file="$1"
    local error_msg="$2"
    local task_id task_type retries next_attempt backoff now

    # Read current values
    # shellcheck source=/dev/null
    source "$task_file"

    retries=$((TASK_RETRIES + 1))
    now=$(date +%s)

    _queue_counter_inc "failed_total"

    if [[ $retries -ge $QUEUE_MAX_RETRIES ]]; then
        # Move to DLQ
        _queue_log "ERROR" "Task $TASK_ID exhausted retries ($retries/$QUEUE_MAX_RETRIES), moving to DLQ"

        # Update task with final state
        cat > "$task_file" <<EOF
TASK_ID="$TASK_ID"
TASK_TYPE="$TASK_TYPE"
TASK_DESCRIPTION="$TASK_DESCRIPTION"
TASK_CREATED_EPOCH="$TASK_CREATED_EPOCH"
TASK_RETRIES="$retries"
TASK_NEXT_ATTEMPT_EPOCH="0"
TASK_LAST_ERROR="$error_msg"
TASK_PAYLOAD_FILE="$TASK_PAYLOAD_FILE"
TASK_DLQ_EPOCH="$now"
TASK_DLQ_REASON="max_retries_exceeded"
EOF

        mv "$task_file" "$QUEUE_DLQ_DIR/" 2>/dev/null || true
        _queue_counter_inc "dlq_total"

        # Emit alert
        logger -t nftban-queue -p user.alert "Task moved to DLQ: $TASK_ID ($TASK_TYPE) after $retries retries"

        return 1
    else
        # Calculate backoff and reschedule
        backoff=$(_queue_calculate_backoff "$retries")
        next_attempt=$((now + backoff))

        _queue_log "WARN" "Task $TASK_ID failed (attempt $retries/$QUEUE_MAX_RETRIES), retry in ${backoff}s"
        _queue_counter_inc "retries_total"

        # Update task with retry info
        cat > "$task_file" <<EOF
TASK_ID="$TASK_ID"
TASK_TYPE="$TASK_TYPE"
TASK_DESCRIPTION="$TASK_DESCRIPTION"
TASK_CREATED_EPOCH="$TASK_CREATED_EPOCH"
TASK_RETRIES="$retries"
TASK_NEXT_ATTEMPT_EPOCH="$next_attempt"
TASK_LAST_ERROR="$error_msg"
TASK_PAYLOAD_FILE="$TASK_PAYLOAD_FILE"
EOF

        # Move back to pending
        mv "$task_file" "$QUEUE_PENDING_DIR/" 2>/dev/null || true

        return 0
    fi
}

# =============================================================================
# MAIN: PROCESS NEXT TASK
# =============================================================================

# Returns: 0=task processed, 1=no eligible tasks, 2=lock held, 3=processing error
nftban_queue_process_next() {
    local start_time task_file work_file task_basename
    start_time=$(date +%s)

    _queue_init

    # Try to acquire lock
    if ! _queue_acquire_lock; then
        return 2
    fi

    # CWE-400 mitigation: Auto-purge old DLQ entries to prevent unbounded growth
    _queue_auto_purge_dlq

    # Find next eligible task
    task_file=$(_queue_get_next_eligible_task)

    if [[ -z "$task_file" ]] || [[ ! -f "$task_file" ]]; then
        _queue_release_lock
        _queue_write_metrics
        return 1
    fi

    task_basename=$(basename "$task_file")
    work_file="${QUEUE_WORK_DIR}/${task_basename}"

    # Atomic claim: rename to work directory
    if ! mv "$task_file" "$work_file" 2>/dev/null; then
        _queue_log "WARN" "Failed to claim task (race condition?): $task_basename"
        _queue_release_lock
        return 1
    fi

    # Load task
    # shellcheck source=/dev/null
    source "$work_file"

    _queue_log "INFO" "Processing task: $TASK_ID ($TASK_TYPE: $TASK_DESCRIPTION)"

    # Execute task
    local error_output
    error_output=$(_queue_execute_task "$TASK_TYPE" "$TASK_DESCRIPTION" "$TASK_PAYLOAD_FILE")
    local result=$?

    if [[ $result -eq 0 ]]; then
        # Success
        _queue_log "SUCCESS" "Task completed: $TASK_ID (${TASK_TYPE})"
        _queue_counter_inc "processed_total"

        # Clean up payload file if exists
        [[ -n "$TASK_PAYLOAD_FILE" ]] && [[ -f "$TASK_PAYLOAD_FILE" ]] && rm -f "$TASK_PAYLOAD_FILE"

        # Delete task
        rm -f "$work_file"
    else
        # Failure - handle retry or DLQ
        _queue_log "ERROR" "Task failed: $TASK_ID ($TASK_TYPE): $error_output"
        _queue_handle_failure "$work_file" "$error_output"
    fi

    # Calculate duration and write metrics
    local duration=$(($(date +%s) - start_time))
    _queue_log "DEBUG" "Queue processor completed in ${duration}s"

    _queue_release_lock
    _queue_write_metrics

    return $result
}

# =============================================================================
# DLQ MANAGEMENT
# =============================================================================

nftban_queue_dlq_list() {
    # List all DLQ tasks
    _queue_init

    local task_file
    for task_file in "$QUEUE_DLQ_DIR"/*.task; do
        [[ ! -f "$task_file" ]] && continue

        # shellcheck source=/dev/null
        source "$task_file"

        local created_date dlq_date
        created_date=$(date -d "@$TASK_CREATED_EPOCH" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
        dlq_date=$(date -d "@${TASK_DLQ_EPOCH:-0}" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")

        printf "%s | %s | %s | Created: %s | DLQ: %s | Error: %s\n" \
            "$TASK_ID" "$TASK_TYPE" "$TASK_DESCRIPTION" \
            "$created_date" "$dlq_date" "${TASK_LAST_ERROR:0:50}"
    done
}

nftban_queue_dlq_retry() {
    # Retry a specific DLQ task
    local task_id="$1"

    if [[ -z "$task_id" ]]; then
        echo "Usage: nftban_queue_dlq_retry <task_id>" >&2
        return 1
    fi

    local dlq_file="${QUEUE_DLQ_DIR}/${task_id}.task"

    if [[ ! -f "$dlq_file" ]]; then
        echo "Task not found in DLQ: $task_id" >&2
        return 1
    fi

    # Reset retry counter and move to pending
    # shellcheck source=/dev/null
    source "$dlq_file"

    cat > "$dlq_file" <<EOF
TASK_ID="$TASK_ID"
TASK_TYPE="$TASK_TYPE"
TASK_DESCRIPTION="$TASK_DESCRIPTION"
TASK_CREATED_EPOCH="$TASK_CREATED_EPOCH"
TASK_RETRIES="0"
TASK_NEXT_ATTEMPT_EPOCH="0"
TASK_LAST_ERROR=""
TASK_PAYLOAD_FILE="$TASK_PAYLOAD_FILE"
EOF

    mv "$dlq_file" "$QUEUE_PENDING_DIR/"
    _queue_log "INFO" "DLQ task retried: $task_id"
    echo "Task $task_id moved from DLQ to pending queue"
}

nftban_queue_dlq_purge() {
    # Purge all DLQ tasks older than N days
    local days="${1:-7}"
    local cutoff now count
    now=$(date +%s)
    cutoff=$((now - (days * 86400)))
    count=0

    local task_file
    for task_file in "$QUEUE_DLQ_DIR"/*.task; do
        [[ ! -f "$task_file" ]] && continue

        # shellcheck source=/dev/null
        source "$task_file"

        if [[ ${TASK_DLQ_EPOCH:-0} -lt $cutoff ]]; then
            rm -f "$task_file"
            [[ -n "$TASK_PAYLOAD_FILE" ]] && [[ -f "$TASK_PAYLOAD_FILE" ]] && rm -f "$TASK_PAYLOAD_FILE"
            ((count++))
        fi
    done

    _queue_log "INFO" "Purged $count DLQ tasks older than $days days"
    echo "Purged $count tasks from DLQ"
}

# =============================================================================
# AUTO-PURGE DLQ (CWE-400 mitigation)
# =============================================================================

_queue_auto_purge_dlq() {
    # Silently purge old DLQ entries based on configured retention
    # Called automatically during queue processing to prevent unbounded growth
    local days="$QUEUE_DLQ_AUTO_RETENTION_DAYS"
    local cutoff now count
    now=$(date +%s)
    cutoff=$((now - (days * 86400)))
    count=0

    local task_file
    for task_file in "$QUEUE_DLQ_DIR"/*.task; do
        [[ ! -f "$task_file" ]] && continue

        # shellcheck source=/dev/null
        source "$task_file"

        if [[ ${TASK_DLQ_EPOCH:-0} -lt $cutoff ]]; then
            rm -f "$task_file"
            [[ -n "$TASK_PAYLOAD_FILE" ]] && [[ -f "$TASK_PAYLOAD_FILE" ]] && rm -f "$TASK_PAYLOAD_FILE"
            ((count++))
        fi
    done

    if [[ $count -gt 0 ]]; then
        _queue_log "INFO" "Auto-purged $count DLQ tasks older than $days days"
    fi
}

# =============================================================================
# EXPORTS
# =============================================================================

export -f nftban_queue_add
export -f nftban_queue_has_pending
export -f nftban_queue_count
export -f nftban_queue_count_dlq
export -f nftban_queue_process_next
export -f nftban_queue_dlq_list
export -f nftban_queue_dlq_retry
export -f nftban_queue_dlq_purge
