#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.96 - Rebuild Failure Classification + Recovery Marker
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_rebuild_classify"
# meta:type="lib"
# meta:version="1.96.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-17"
# meta:description="Failure classification and recovery marker helpers for rebuild"
# meta:inventory.files="cli/lib/nftban/core/nftban_rebuild_classify.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Contract: V196_REBUILD_RECOVERY_CONTRACT.md
# INV-RR-005: PREVALIDATION_FAILED never enters recovery flow
# INV-RR-006: Retry count is finite and persisted
# INV-RR-007: Module restore failure is surfaced, not silent
# =============================================================================

set -Eeuo pipefail

[[ -n "${_NFTBAN_REBUILD_CLASSIFY_LOADED:-}" ]] && return 0
_NFTBAN_REBUILD_CLASSIFY_LOADED=1

# Recovery marker path
# shellcheck disable=SC2034  # Constants used by sourcing scripts (cmd_firewall.sh)
readonly REBUILD_RECOVERY_MARKER="/var/lib/nftban/state/rebuild_recovery.json"

# Failure classes (match Go enum in internal/rebuild/types.go)
# shellcheck disable=SC2034
readonly FC_PREVALIDATION_FAILED="PREVALIDATION_FAILED"
# shellcheck disable=SC2034
readonly FC_SNAPSHOT_FAILED="SNAPSHOT_FAILED"
# shellcheck disable=SC2034
readonly FC_APPLY_FAILED="APPLY_FAILED"
# shellcheck disable=SC2034
readonly FC_POSTVALIDATION_REGRESSION="POSTVALIDATION_REGRESSION"
# shellcheck disable=SC2034
readonly FC_POSTVALIDATION_HARD_FAIL="POSTVALIDATION_HARD_FAIL"
# shellcheck disable=SC2034
readonly FC_DAEMON_RESTART_FAILED="DAEMON_RESTART_FAILED"
# shellcheck disable=SC2034
readonly FC_MODULE_RESTORE_FAILED="MODULE_RESTORE_FAILED"
# shellcheck disable=SC2034
readonly FC_MODULE_RESTORE_INCOMPLETE="MODULE_RESTORE_INCOMPLETE"
# shellcheck disable=SC2034
readonly FC_ROLLBACK_FAILED="ROLLBACK_FAILED"
# shellcheck disable=SC2034
readonly FC_AUTHORITY_CONFLICT="AUTHORITY_CONFLICT"
# shellcheck disable=SC2034
readonly FC_BACKUP_MISSING="BACKUP_MISSING"
# shellcheck disable=SC2034
readonly FC_RETRY_EXHAUSTED="RETRY_EXHAUSTED"

# Operation results (match Go enum)
# shellcheck disable=SC2034
readonly OR_SUCCESS="SUCCESS"
# shellcheck disable=SC2034
readonly OR_FAILED_RECOVERED="FAILED_RECOVERED"
# shellcheck disable=SC2034
readonly OR_FAILED_DEGRADED="FAILED_DEGRADED"
# shellcheck disable=SC2034
readonly OR_FAILED_FATAL="FAILED_FATAL"

# Module restore results
# shellcheck disable=SC2034
readonly MR_OK="RESTORE_OK"
# shellcheck disable=SC2034
readonly MR_FAILED="RESTORE_FAILED"
# shellcheck disable=SC2034
readonly MR_INCOMPLETE="RESTORE_INCOMPLETE"
# shellcheck disable=SC2034
readonly MR_SKIPPED="RESTORE_SKIPPED"

# Per-rebuild tracking variables
_REBUILD_FAILURE_CLASS=""
_REBUILD_OPERATION_RESULT=""
_REBUILD_DAEMON_WAS_DOWN="false"
_REBUILD_MODULE_DDOS="$MR_SKIPPED"
_REBUILD_MODULE_PORTSCAN="$MR_SKIPPED"
_REBUILD_MODULE_BOTGUARD="$MR_SKIPPED"
_REBUILD_MODULE_LOGINMON="$MR_SKIPPED"

# =============================================================================
# Classification helpers
# =============================================================================

# Reset tracking state at start of rebuild
_rebuild_classify_reset() {
    _REBUILD_FAILURE_CLASS=""
    _REBUILD_OPERATION_RESULT=""
    _REBUILD_DAEMON_WAS_DOWN="false"
    _REBUILD_MODULE_DDOS="$MR_SKIPPED"
    _REBUILD_MODULE_PORTSCAN="$MR_SKIPPED"
    _REBUILD_MODULE_BOTGUARD="$MR_SKIPPED"
    _REBUILD_MODULE_LOGINMON="$MR_SKIPPED"
}

# Record that daemon was down during module re-enable
_rebuild_classify_daemon_down() {
    _REBUILD_DAEMON_WAS_DOWN="true"
}

# Record module restore result
# Args: $1=module (ddos|portscan|botguard|loginmon), $2=result (RESTORE_OK|RESTORE_FAILED|...)
_rebuild_classify_module_result() {
    local module="$1" result="$2"
    case "$module" in
        ddos)     _REBUILD_MODULE_DDOS="$result" ;;
        portscan) _REBUILD_MODULE_PORTSCAN="$result" ;;
        botguard) _REBUILD_MODULE_BOTGUARD="$result" ;;
        loginmon) _REBUILD_MODULE_LOGINMON="$result" ;;
    esac
}

# Determine if any module restore failed or is incomplete
_rebuild_classify_has_module_failure() {
    [[ "$_REBUILD_MODULE_DDOS" == "$MR_FAILED" ]] && return 0
    [[ "$_REBUILD_MODULE_PORTSCAN" == "$MR_FAILED" ]] && return 0
    [[ "$_REBUILD_MODULE_BOTGUARD" == "$MR_FAILED" ]] && return 0
    [[ "$_REBUILD_MODULE_LOGINMON" == "$MR_FAILED" ]] && return 0
    return 1
}

_rebuild_classify_has_module_incomplete() {
    [[ "$_REBUILD_MODULE_DDOS" == "$MR_INCOMPLETE" ]] && return 0
    [[ "$_REBUILD_MODULE_PORTSCAN" == "$MR_INCOMPLETE" ]] && return 0
    [[ "$_REBUILD_MODULE_BOTGUARD" == "$MR_INCOMPLETE" ]] && return 0
    [[ "$_REBUILD_MODULE_LOGINMON" == "$MR_INCOMPLETE" ]] && return 0
    return 1
}

# =============================================================================
# Recovery marker helpers
# =============================================================================

# Write recovery marker (JSON).
# INV-RR-005: NEVER call this for PREVALIDATION_FAILED.
# Args: $1=failure_class, $2=operation_result, $3=backup_path, $4=health_state
_rebuild_marker_write() {
    local failure_class="$1"
    local operation_result="$2"
    local backup_path="${3:-}"
    local health_state="${4:-unknown}"

    # INV-RR-005: PREVALIDATION_FAILED must never enter recovery flow
    if [[ "$failure_class" == "$FC_PREVALIDATION_FAILED" ]]; then
        return 0  # silently skip — this is by contract
    fi

    local marker_dir
    marker_dir=$(dirname "$REBUILD_RECOVERY_MARKER")
    mkdir -p "$marker_dir" 2>/dev/null || true

    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    # Read existing marker for retry count continuity
    local retry_count=0
    local first_failure_at="$now"
    local max_retries=3  # 1 immediate + 2 deferred
    local exhausted="false"

    if [[ -f "$REBUILD_RECOVERY_MARKER" ]]; then
        local existing_count existing_first
        existing_count=$(jq -r '.retry_count // 0' "$REBUILD_RECOVERY_MARKER" 2>/dev/null || echo "0")
        existing_first=$(jq -r '.first_failure_at // ""' "$REBUILD_RECOVERY_MARKER" 2>/dev/null || echo "")
        retry_count=$((existing_count + 1))
        [[ -n "$existing_first" ]] && first_failure_at="$existing_first"
        if [[ $retry_count -ge $max_retries ]]; then
            exhausted="true"
        fi
    fi

    local deferred_pending="false"
    # Schedule deferred retry for eligible classes
    case "$failure_class" in
        "$FC_APPLY_FAILED"|"$FC_DAEMON_RESTART_FAILED"|"$FC_MODULE_RESTORE_FAILED"|"$FC_MODULE_RESTORE_INCOMPLETE")
            [[ "$exhausted" == "false" ]] && deferred_pending="true"
            ;;
        "$FC_POSTVALIDATION_REGRESSION")
            # Only if daemon-related
            [[ "$_REBUILD_DAEMON_WAS_DOWN" == "true" && "$exhausted" == "false" ]] && deferred_pending="true"
            ;;
    esac

    # Determine rollback state
    local rollback_attempted="false" rollback_result="not_attempted"
    if [[ "$failure_class" == "$FC_POSTVALIDATION_REGRESSION" ]]; then
        rollback_attempted="true"
        rollback_result="success"
    elif [[ "$failure_class" == "$FC_ROLLBACK_FAILED" ]]; then
        rollback_attempted="true"
        rollback_result="failed"
    fi

    # Write marker atomically
    local tmp_marker="${REBUILD_RECOVERY_MARKER}.tmp"
    cat > "$tmp_marker" <<MARKER_EOF
{
  "failure_class": "$failure_class",
  "operation_result": "$operation_result",
  "retry_count": $retry_count,
  "max_retries": $max_retries,
  "deferred_retry_pending": $deferred_pending,
  "first_failure_at": "$first_failure_at",
  "last_failure_at": "$now",
  "rollback_attempted": $rollback_attempted,
  "rollback_result": "$rollback_result",
  "backup_path": "$backup_path",
  "last_health_state": "$health_state",
  "exhausted": $exhausted,
  "daemon_related": $_REBUILD_DAEMON_WAS_DOWN,
  "module_restore": {
    "ddos": "$_REBUILD_MODULE_DDOS",
    "portscan": "$_REBUILD_MODULE_PORTSCAN",
    "botguard": "$_REBUILD_MODULE_BOTGUARD",
    "loginmon": "$_REBUILD_MODULE_LOGINMON"
  }
}
MARKER_EOF

    mv -f "$tmp_marker" "$REBUILD_RECOVERY_MARKER" 2>/dev/null || {
        rm -f "$tmp_marker" 2>/dev/null
        return 1
    }
    chmod 640 "$REBUILD_RECOVERY_MARKER" 2>/dev/null || true
}

# Clear recovery marker on success
_rebuild_marker_clear() {
    rm -f "$REBUILD_RECOVERY_MARKER" 2>/dev/null || true
}

# Check if recovery marker exists
_rebuild_marker_exists() {
    [[ -f "$REBUILD_RECOVERY_MARKER" ]]
}

# Read failure class from existing marker
_rebuild_marker_get_class() {
    jq -r '.failure_class // ""' "$REBUILD_RECOVERY_MARKER" 2>/dev/null || echo ""
}

# Check if marker is exhausted
_rebuild_marker_is_exhausted() {
    local exhausted
    exhausted=$(jq -r '.exhausted // false' "$REBUILD_RECOVERY_MARKER" 2>/dev/null || echo "false")
    [[ "$exhausted" == "true" ]]
}
