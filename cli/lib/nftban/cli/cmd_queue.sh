#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Queue CLI Handler
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Handle task queue CLI commands including DLQ management
#
# meta:name="cmd_queue"
# meta:type="cli"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-01-07"
#
# meta:description="CLI interface for task queue and dead-letter queue management"
# meta:input="Command line arguments for queue operations"
# meta:output="Queue status, DLQ listings, and operation results"
# meta:depends="bash,nftban_task_queue.sh"
#
# meta:inventory.files="nftban_task_queue.sh,strict.sh,version.sh,json_output.sh,nftban_output.sh"
# meta:inventory.binaries="find,date"
# meta:inventory.env_vars="NFTBAN_LIB_DIR,NFTBAN_DATA_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# =============================================================================

# Strict mode
set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Load dependencies
[[ -z "${NFTBAN_LIB_DIR:-}" ]] && readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Load strict mode library
if [[ -f "${NFTBAN_LIB_DIR}/lib/strict.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/strict.sh" || return 1
fi

# Load version library
if [[ -f "${NFTBAN_LIB_DIR}/lib/version.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/lib/version.sh" || return 1
fi

# Load JSON helper for --json support
JSON_HELPER="${NFTBAN_LIB_DIR}/helpers/json_output.sh"
if [[ -f "$JSON_HELPER" ]]; then
    # shellcheck source=../helpers/json_output.sh
    source "$JSON_HELPER" || return 1
fi

# Load task queue module
if [[ -f "${NFTBAN_LIB_DIR}/helpers/nftban_task_queue.sh" ]]; then
    source "${NFTBAN_LIB_DIR}/helpers/nftban_task_queue.sh" || return 1
else
    echo "ERROR: nftban_task_queue.sh not found" >&2
    return 1
fi

# =============================================================================
# HELP FUNCTION
# =============================================================================

_nftban_queue_help() {
    # Load output module for banner
    if [[ -f "${NFTBAN_LIB_DIR}/core/nftban_output.sh" ]]; then
        source "${NFTBAN_LIB_DIR}/core/nftban_output.sh" || return 1
    fi

    if type -t nftban_banner >/dev/null 2>&1; then
        nftban_banner "queue"
        echo ""
    fi

    cat <<'EOF'
Task Queue Management
=====================

USAGE:
  nftban queue <command> [options]

COMMANDS:
  status              Show queue status (pending, working, DLQ counts)
  list                List pending tasks
  process             Process next task manually (normally done by timer)

DLQ (Dead-Letter Queue) Management:
  dlq list            List all tasks in dead-letter queue
  dlq retry <id>      Retry a specific DLQ task (reset retry count)
  dlq retry-all       Retry all DLQ tasks
  dlq purge [days]    Purge DLQ tasks older than N days (default: 7)
  dlq show <id>       Show details of a specific DLQ task

METRICS:
  metrics             Show queue metrics (processed, failed, retries)

EXAMPLES:
  nftban queue status              # Quick status overview
  nftban queue dlq list            # Show failed tasks
  nftban queue dlq retry abc123    # Retry specific task
  nftban queue dlq purge 30        # Delete DLQ tasks older than 30 days

ARCHITECTURE:
  Tasks flow through: pending/ → work/ → (success: delete | fail: retry/DLQ)

  Retry policy:
    - Tasks retry up to 3 times with exponential backoff (30s, 60s, 120s)
    - After 3 failures, tasks move to DLQ for manual review
    - DLQ tasks are preserved until manually retried or purged

  Timer: nftban-queue.timer runs every 2 minutes

LOG FILES:
  Queue log:    ${NFTBAN_LOG_DIR}/queue.log
  Metrics:      /var/lib/nftban/metrics/queue.prom

EOF
}

# =============================================================================
# QUEUE STATUS
# =============================================================================

_queue_status() {
    local json_mode="${1:-false}"

    _queue_init 2>/dev/null || true

    local pending working dlq
    pending=$(find "$QUEUE_PENDING_DIR" -name "*.task" -type f 2>/dev/null | wc -l)
    working=$(find "$QUEUE_WORK_DIR" -name "*.task" -type f 2>/dev/null | wc -l)
    dlq=$(find "$QUEUE_DLQ_DIR" -name "*.task" -type f 2>/dev/null | wc -l)

    local processed failed retries
    processed=$(_queue_counter_get "processed_total" 2>/dev/null || echo "0")
    failed=$(_queue_counter_get "failed_total" 2>/dev/null || echo "0")
    retries=$(_queue_counter_get "retries_total" 2>/dev/null || echo "0")

    if [[ "$json_mode" == "true" ]]; then
        cat <<EOF
{
  "pending": $pending,
  "working": $working,
  "dlq": $dlq,
  "processed_total": $processed,
  "failed_total": $failed,
  "retries_total": $retries
}
EOF
    else
        echo "Queue Status"
        echo "============"
        echo ""
        echo "Current State:"
        printf "  Pending tasks:   %d\n" "$pending"
        printf "  Working tasks:   %d\n" "$working"
        printf "  DLQ tasks:       %d\n" "$dlq"
        echo ""
        echo "Lifetime Counters:"
        printf "  Processed:       %d\n" "$processed"
        printf "  Failed:          %d\n" "$failed"
        printf "  Retries:         %d\n" "$retries"
        echo ""
        echo "Directories:"
        echo "  Pending: $QUEUE_PENDING_DIR"
        echo "  Work:    $QUEUE_WORK_DIR"
        echo "  DLQ:     $QUEUE_DLQ_DIR"

        if [[ $dlq -gt 0 ]]; then
            echo ""
            echo "⚠️  You have $dlq tasks in the dead-letter queue."
            echo "   Run 'nftban queue dlq list' to view them."
        fi
    fi
}

# =============================================================================
# LIST PENDING TASKS
# =============================================================================

_queue_list_pending() {
    _queue_init 2>/dev/null || true

    local count=0
    echo "Pending Tasks"
    echo "============="
    echo ""

    for task_file in "$QUEUE_PENDING_DIR"/*.task; do
        [[ ! -f "$task_file" ]] && continue

        # task file path from queue directory enumeration
        # shellcheck disable=SC1090
        source "$task_file" || true
        # v1.19.20 FIX
        ((count++)) || true

        local created_date next_date
        created_date=$(date -d "@$TASK_CREATED_EPOCH" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")

        if [[ "${TASK_NEXT_ATTEMPT_EPOCH:-0}" -gt 0 ]]; then
            next_date=$(date -d "@$TASK_NEXT_ATTEMPT_EPOCH" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "unknown")
            printf "%d. %s\n" "$count" "$TASK_ID"
            printf "   Type: %s | Retries: %s | Next attempt: %s\n" "$TASK_TYPE" "${TASK_RETRIES:-0}" "$next_date"
        else
            printf "%d. %s\n" "$count" "$TASK_ID"
            printf "   Type: %s | Created: %s\n" "$TASK_TYPE" "$created_date"
        fi
        printf "   Description: %s\n\n" "$TASK_DESCRIPTION"
    done

    if [[ $count -eq 0 ]]; then
        echo "No pending tasks."
    else
        echo "Total: $count task(s)"
    fi
}

# =============================================================================
# METRICS
# =============================================================================

_queue_metrics() {
    local metrics_file="${QUEUE_METRICS_FILE:-${NFTBAN_DATA_DIR}/metrics/queue.prom}"

    if [[ -f "$metrics_file" ]]; then
        echo "Queue Metrics (Prometheus format)"
        echo "================================="
        echo ""
        cat "$metrics_file"
    else
        echo "Metrics file not found: $metrics_file"
        echo "Run 'nftban queue status' to generate metrics."
    fi
}

# =============================================================================
# DLQ SHOW DETAILS
# =============================================================================

_queue_dlq_show() {
    local task_id="$1"

    if [[ -z "$task_id" ]]; then
        echo "Usage: nftban queue dlq show <task_id>" >&2
        return 1
    fi

    # Find task file (may include .task extension or not)
    local task_file=""
    if [[ -f "${QUEUE_DLQ_DIR}/${task_id}.task" ]]; then
        task_file="${QUEUE_DLQ_DIR}/${task_id}.task"
    elif [[ -f "${QUEUE_DLQ_DIR}/${task_id}" ]]; then
        task_file="${QUEUE_DLQ_DIR}/${task_id}"
    else
        echo "Task not found in DLQ: $task_id" >&2
        return 1
    fi

    # task file path from queue directory
    # shellcheck disable=SC1090
    source "$task_file" || true

    local created_date dlq_date
    created_date=$(date -d "@$TASK_CREATED_EPOCH" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    dlq_date=$(date -d "@${TASK_DLQ_EPOCH:-0}" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")

    echo "DLQ Task Details"
    echo "================"
    echo ""
    echo "Task ID:      $TASK_ID"
    echo "Type:         $TASK_TYPE"
    echo "Description:  $TASK_DESCRIPTION"
    echo "Created:      $created_date"
    echo "Moved to DLQ: $dlq_date"
    echo "Retries:      ${TASK_RETRIES:-0}"
    echo "DLQ Reason:   ${TASK_DLQ_REASON:-unknown}"
    echo "Last Error:   ${TASK_LAST_ERROR:-none}"
    echo ""
    echo "Payload File: ${TASK_PAYLOAD_FILE:-none}"

    if [[ -n "${TASK_PAYLOAD_FILE:-}" ]] && [[ -f "$TASK_PAYLOAD_FILE" ]]; then
        echo ""
        echo "Payload Contents:"
        echo "-----------------"
        cat "$TASK_PAYLOAD_FILE"
    fi
}

# =============================================================================
# DLQ RETRY ALL
# =============================================================================

_queue_dlq_retry_all() {
    _queue_init 2>/dev/null || true

    local count=0
    for task_file in "$QUEUE_DLQ_DIR"/*.task; do
        [[ ! -f "$task_file" ]] && continue

        local task_id
        task_id=$(basename "$task_file" .task)

        # v1.19.20 FIX
        nftban_queue_dlq_retry "$task_id" >/dev/null 2>&1 && { ((count++)) || true; }
    done

    if [[ $count -eq 0 ]]; then
        echo "No tasks in DLQ to retry."
    else
        echo "Retried $count task(s) from DLQ."
    fi
}

# =============================================================================
# MAIN COMMAND HANDLER
# =============================================================================

nftban_cmd_queue() {
    local subcmd="${1:-help}"
    shift || true

    # Check for JSON mode
    local json_mode="false"
    for arg in "$@"; do
        [[ "$arg" == "--json" ]] && json_mode="true" || true
    done

    case "$subcmd" in
        status)
            _queue_status "$json_mode"
            ;;

        list)
            _queue_list_pending
            ;;

        process)
            echo "Processing next task..."
            nftban_queue_process_next
            local rc=$?
            case $rc in
                0) echo "Task processed successfully." ;;
                1) echo "No eligible tasks to process." ;;
                2) echo "Queue processor already running." ;;
                *) echo "Task processing failed (rc=$rc)." ;;
            esac
            return $rc
            ;;

        dlq)
            local dlq_cmd="${1:-list}"
            shift || true

            case "$dlq_cmd" in
                list)
                    echo "Dead-Letter Queue"
                    echo "================="
                    echo ""
                    nftban_queue_dlq_list
                    local dlq_count
                    dlq_count=$(nftban_queue_count_dlq 2>/dev/null || echo "0")
                    if [[ "$dlq_count" -eq 0 ]]; then
                        echo "No tasks in dead-letter queue."
                    fi
                    ;;

                retry)
                    local task_id="${1:-}"
                    if [[ -z "$task_id" ]]; then
                        echo "Usage: nftban queue dlq retry <task_id>" >&2
                        return 1
                    fi
                    nftban_queue_dlq_retry "$task_id"
                    ;;

                retry-all)
                    _queue_dlq_retry_all
                    ;;

                purge)
                    local days="${1:-7}"
                    echo "Purging DLQ tasks older than $days days..."
                    nftban_queue_dlq_purge "$days"
                    ;;

                show)
                    local task_id="${1:-}"
                    _queue_dlq_show "$task_id"
                    ;;

                help)
                    echo "Usage: nftban queue dlq <command> [args]"
                    echo ""
                    echo "Commands:"
                    echo "  list              List all DLQ tasks"
                    echo "  retry <id>        Retry specific task"
                    echo "  retry-all         Retry all DLQ tasks"
                    echo "  purge [days]      Purge tasks older than N days (default: 7)"
                    echo "  show <id>         Show task details"
                    ;;

                *)
                    echo "Unknown DLQ command: $dlq_cmd" >&2
                    echo "Run 'nftban queue dlq help' for usage." >&2
                    return 1
                    ;;
            esac
            ;;

        metrics)
            _queue_metrics
            ;;

        help|--help|-h)
            _nftban_queue_help
            ;;

        *)
            echo "Unknown queue command: $subcmd" >&2
            echo "Run 'nftban queue help' for usage." >&2
            return 1
            ;;
    esac
}

# Export function for auto-loading
export -f nftban_cmd_queue
