#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.96 - Rebuild Failure Classification + Recovery Marker
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
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
# v1.229.12 P12-A01b: a GENERATION COMMIT failure is its own class. It is deliberately
# ABSENT from the deferred-retry case list below — a transaction that could not become
# authoritative is FATAL and must not schedule a retry as though it were recoverable
# degradation. Using FC_APPLY_FAILED here (the first attempt) silently scheduled one.
# shellcheck disable=SC2034
readonly FC_COMMIT_FAILED="COMMIT_FAILED"
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

# =============================================================================
# v1.229.12 P12-A01/A01b — INSTALLER CONTINUATION CLASSIFIER
# =============================================================================
# ⛔ THIS IS A THIRD, ORTHOGONAL AXIS. It is a POLICY DECISION over existing facts,
# not another description of the rebuild:
#     OperationResult (OR_*)  = what happened during the rebuild
#     validator.Status        = what the firewall currently looks like
#     Continuation (here)     = may this lifecycle phase proceed?
# Adding a "deferred" value to OR_* would re-create the A01/A01b conflation.
#
# ⛔ ATTRIBUTION AUTHORITY IS THE VALIDATOR, NOT THIS FILE.
#   ModuleJSON.Runtime is "omitted if not daemon-dependent" — so its PRESENCE is the
#   validator's own statement that a module has daemon-runtime semantics.
#   NEVER hard-code a list of daemon-dependent modules here; that would be a second,
#   drifting authority.
#
# ⛔ DAEMON STATE USES AN EXPLICIT ACCEPTED SET, NEVER `!= RUNNING`.
#   RuntimeError ("ERROR") means *the systemctl query itself failed* — that is UNKNOWN,
#   not "stopped as expected during install". A loose `!= RUNNING` test would let a FAILED
#   QUERY license deferral. Only STOPPED is deferral-eligible.
# ⛔ SUPPORTED PRODUCER SCHEMA — must equal Go validator.SchemaVersionCurrent.
# CI asserts equality (see tools/check-validator-schema-pin.sh). Space-separated if a
# future release must accept more than one PROVEN-COMPATIBLE version.
readonly SUPPORTED_VALIDATOR_SCHEMAS="1.84.0"
readonly CR_SCHEMA_UNSUPPORTED="VALIDATOR_SCHEMA_UNSUPPORTED"
readonly RD_COMPLETE="COMPLETE"
readonly RD_DEFERRED_RUNTIME="DEFERRED_RUNTIME"
readonly RD_REGRESSION="REGRESSION"
readonly RD_FATAL="FATAL"

# Internal reason codes (diagnostics; not additional continuation outcomes)
readonly CR_FATAL_STAGE="FATAL_STAGE"
readonly CR_INSUFFICIENT_EVIDENCE="INSUFFICIENT_EVIDENCE"
readonly CR_UNATTRIBUTABLE_ABSENCE="UNATTRIBUTABLE_ABSENCE"
readonly CR_RUNTIME_DEFERRED="RUNTIME_MODULE_PROJECTION_DEFERRED"
readonly CR_DAEMON_UNAVAILABLE="DAEMON_UNAVAILABLE"
readonly CR_SCHEMA_UNUSABLE="VALIDATOR_SCHEMA_UNUSABLE"

# _rebuild_join_reasons <item>...
# Joins reason codes with "," WITHOUT mutating IFS.
#
# ⛔ WHY NOT `$(IFS=,; echo "${arr[*]}")`: that idiom is safe here (the assignment is confined
# to a command-substitution subshell, and the parent IFS is provably unchanged), but it is an
# AVOIDABLE new scanner/policy surface in new code. EXISTING TOLERATED DEBT IS NOT PRECEDENT
# FOR INTRODUCING AVOIDABLE NEW DEBT — the repository's 324 historical `while IFS=` sites are
# policy surface already carried; this PR does not need to add site 325.
#
# ⛔ REASON-CODE GRAMMAR: codes are a controlled vocabulary of [A-Z_]+ with an optional
# ":<count>" suffix (e.g. RUNTIME_MODULE_PROJECTION_DEFERRED:2). They MUST NOT contain a
# comma — otherwise this joined form would be an ambiguous interchange format. Asserted by
# the reason-grammar test; if a comma-bearing code is ever introduced, that test fails first.
_rebuild_join_reasons() {
    local out="" item
    for item in "$@"; do
        [[ -n "$out" ]] && out+=","
        out+="$item"
    done
    printf '%s' "$out"
}

# _rebuild_disposition_classify <context> <validator_json_file> <fatal_class> <post_status>
#   context      : install-deferred | runtime-required
#   fatal_class  : non-empty FC_* if a fatal stage already occurred (dominates everything)
# Emits: "CLASSIFICATION<TAB>reason,reason,..."
_rebuild_disposition_classify() {
    local context="${1:-runtime-required}"
    local vjson="${2:-}"
    local fatal_class="${3:-}"
    local post_status="${4:-unknown}"
    local -a reasons=()

    # ---- PRECEDENCE 1: a fatal stage DOMINATES. No module or daemon fact may downgrade it.
    if [[ -n "$fatal_class" ]]; then
        printf '%s\t%s\n' "$RD_FATAL" "$CR_FATAL_STAGE:$fatal_class"
        return 0
    fi

    # ---- PRECEDENCE 2: evidence must be usable at all (rule O).
    if [[ -z "$vjson" || ! -s "$vjson" ]] || ! command -v jq >/dev/null 2>&1 \
       || ! jq -e . "$vjson" >/dev/null 2>&1; then
        printf '%s\t%s\n' "$RD_REGRESSION" "$CR_INSUFFICIENT_EVIDENCE:$CR_SCHEMA_UNUSABLE"
        return 0
    fi

    # ---- PRECEDENCE 2b (rule O): the observation must be SELF-IDENTIFYING **AND COMPATIBLE**.
    # ⛔ PRESENCE IS NOT COMPATIBILITY. This classifier does not merely read field names —
    # it relies on SCHEMA SEMANTICS that a future version could legitimately change:
    #     Runtime OMITTED      => module is not daemon-dependent
    #     Runtime=stopped      => daemon dependency may explain a structural absence
    #     Structural=unknown   => "expectation unestablished"
    #     has("config")        => this object is a module in the shape we understand
    # A newer schema is NOT compatible until PROVEN compatible. For an installer deciding
    # whether missing firewall protection is tolerable, failing an upgrade because the
    # producer contract is newer than understood is strictly preferable to silently
    # accepting missing protection under stale semantics.
    #
    # ⛔ THIS IS A PRODUCER/CONSUMER COMPATIBILITY CONTRACT, NOT A SECOND SEMANTIC AUTHORITY.
    # The value duplicates Go's validator.SchemaVersionCurrent deliberately, and the drift is
    # made MECHANICALLY DETECTABLE by a CI check that asserts the two are equal. When the
    # validator schema moves, CI fails and forces the real question to be answered:
    # "are the fields and OMISSION SEMANTICS consumed here still compatible?"
    local schema_ver
    schema_ver=$(jq -r '.schema_version // ""' "$vjson" 2>/dev/null)
    if [[ -z "$schema_ver" || "$schema_ver" == "null" ]]; then
        printf '%s\t%s\n' "$RD_REGRESSION" "$CR_INSUFFICIENT_EVIDENCE:$CR_SCHEMA_UNUSABLE:no_schema_version"
        return 0
    fi
    local _supported _ok=0 _sv
    for _sv in $SUPPORTED_VALIDATOR_SCHEMAS; do
        [[ "$schema_ver" == "$_sv" ]] && { _ok=1; break; }
    done
    if (( _ok == 0 )); then
        printf '%s\t%s\n' "$RD_REGRESSION" "$CR_INSUFFICIENT_EVIDENCE:$CR_SCHEMA_UNSUPPORTED:$schema_ver"
        return 0
    fi

    local daemon
    daemon=$(jq -r '.service_state.nftband // "ERROR"' "$vjson" 2>/dev/null)

    # Per-module attribution. Only entries carrying `config` are ModuleJSON
    # (blacklist has a different shape) — discriminated by SHAPE, not by name.
    local missing_attributable=0 missing_unattributable=0 missing_unknown=0
    local mod cfg structural runtime
    while IFS=$'\t' read -r mod cfg structural runtime; do
        [[ -z "$mod" ]] && continue
        [[ "$cfg" != "enabled" ]] && continue          # disabled -> no requirement, cannot defer
        case "$structural" in
            present) continue ;;
            unknown) missing_unknown=$((missing_unknown+1)); continue ;;   # "expectation unestablished"
            missing) : ;;
            *)       missing_unknown=$((missing_unknown+1)); continue ;;
        esac
        # structural=missing from here on
        if [[ -z "$runtime" || "$runtime" == "null" ]]; then
            missing_unattributable=$((missing_unattributable+1))          # not daemon-dependent
        elif [[ "$runtime" == "stopped" && "$daemon" == "STOPPED" ]]; then
            missing_attributable=$((missing_attributable+1))
        elif [[ "$daemon" == "ERROR" ]]; then
            missing_unknown=$((missing_unknown+1))                        # query failed -> UNKNOWN
        else
            missing_unattributable=$((missing_unattributable+1))          # daemon up: unexplained
        fi
    done < <(jq -r '(.modules // {}) | to_entries[]
                    | select(.value | type == "object" and has("config"))
                    | [.key, (.value.config // ""), (.value.structural // ""), (.value.runtime // "")]
                    | @tsv' "$vjson" 2>/dev/null)

    # ---- PRECEDENCE 3: any unexplained absence is a regression, even alongside attributable ones.
    # ⛔ DEFERRED_RUNTIME REQUIRES *ALL* MATERIAL MISSING REQUIREMENTS TO BE ATTRIBUTABLE.
    if (( missing_unattributable > 0 )); then
        printf '%s\t%s\n' "$RD_REGRESSION" "$CR_UNATTRIBUTABLE_ABSENCE:$missing_unattributable"
        return 0
    fi

    # ---- PRECEDENCE 4: attribution required but not established -> fail closed (rule O).
    if (( missing_unknown > 0 )); then
        printf '%s\t%s\n' "$RD_REGRESSION" "$CR_INSUFFICIENT_EVIDENCE:$missing_unknown"
        return 0
    fi

    # ---- PRECEDENCE 5: deferral, only in install context with the daemon-down fact established.
    if (( missing_attributable > 0 )); then
        if [[ "$context" == "install-deferred" && "$daemon" == "STOPPED" ]]; then
            reasons+=("$CR_DAEMON_UNAVAILABLE" "$CR_RUNTIME_DEFERRED:$missing_attributable")
            printf '%s\t%s\n' "$RD_DEFERRED_RUNTIME" "$(_rebuild_join_reasons "${reasons[@]}")"
        else
            printf '%s\t%s\n' "$RD_REGRESSION" "$CR_UNATTRIBUTABLE_ABSENCE:not-install-context"
        fi
        return 0
    fi

    # ---- PRECEDENCE 6: nothing missing. Health must still be acceptable.
    case "$post_status" in
        protected|idle) printf '%s\t%s\n' "$RD_COMPLETE" "" ;;
        *)              printf '%s\t%s\n' "$RD_REGRESSION" "post_status:$post_status" ;;
    esac
    return 0
}

# =============================================================================
# v1.229.12 P12-A01 — PER-OPERATION STRUCTURED RESULT (shell -> Go transport)
# =============================================================================
# ⛔ THE PATH IS ALLOCATED BY THE CALLER AND PASSED IN (--result-file). Never a fixed
# global path: a shared name reintroduces stale-result and concurrency hazards across runs.
#
# ⛔ FAIL-CLOSED BY CONSTRUCTION. Not every shell exit path needs to emit. A path that
# does not emit leaves NO result, and a missing result is FATAL to the installer. That is
# what makes unexpected bash aborts (including the readonly case that started this) safe
# WITHOUT the shell having to anticipate them.
#
# ⛔ ATOMIC PUBLICATION: write a temp file in the same directory, then rename(2). A reader
# must never observe a partial record.
readonly REBUILD_RESULT_SCHEMA_VERSION="1"

# ⛔ PUBLISH AFTER THE MUTATION, NEVER BEFORE IT.
# The record is a FINAL TRANSACTION RECORD, not an intention record. Emitting REGRESSION and
# then attempting rollback would let Go consume a semantically final result while the rollback
# subsequently failed. The disposition must reflect the state that actually resulted:
#     classify REGRESSION -> rollback OK      -> emit REGRESSION, rollback_performed=true
#     classify REGRESSION -> rollback FAILED  -> emit FATAL
#     classify COMPLETE   -> commit OK        -> emit COMPLETE, committed=true
#     classify COMPLETE   -> commit FAILED    -> emit FATAL
#
# pre_status/post_status are read from the caller's scope (bash dynamic scoping) so the record
# carries the comparison the disposition was derived from, without duplicating the observation.
#
# _rebuild_emit_result <disposition> <reasons> <rollback_performed> <generation_committed> <retry_reason>
_rebuild_emit_result() {
    local disposition="${1:-}" reason_list="${2:-}" rollback="${3:-false}"
    local committed="${4:-false}" retry_reason="${5:-}"
    local out="${_NFTBAN_REBUILD_RESULT_FILE:-}"
    [[ -n "$out" ]] || return 0                      # not requested -> legacy caller, no-op
    local dir tmp; dir=$(dirname "$out")
    mkdir -p "$dir" 2>/dev/null || true
    tmp=$(mktemp "${dir}/.result.XXXXXX" 2>/dev/null) || return 0

    # reasons is a comma-separated internal list; emit as a JSON array without inventing fields.
    local codes="[]"
    if [[ -n "$reason_list" ]]; then
        codes=$(printf '%s' "$reason_list" | awk -F, '{printf "["; for(i=1;i<=NF;i++){printf "%s\"%s\"", (i>1?",":""), $i}; printf "]"}')
    fi
    cat > "$tmp" <<JSON
{
  "schema_version": "$REBUILD_RESULT_SCHEMA_VERSION",
  "operation_id": "${_NFTBAN_REBUILD_OPERATION_ID:-}",
  "context": "${_NFTBAN_REBUILD_CONTEXT:-runtime-required}",
  "disposition": "$disposition",
  "reason_codes": $codes,
  "rollback_performed": $rollback,
  "transaction": { "committed": $committed, "reason": "$( [[ "$committed" == "true" ]] && echo COMMITTED || { [[ "$disposition" == "DEFERRED_RUNTIME" ]] && echo DEFERRED_CONVERGENCE || echo FAILURE; } )" },
  "retry": { "reason": "${retry_reason:-NONE}" },
  "pre_status": "${pre_status:-unknown}",
  "post_status": "${post_status:-unknown}",
  "emitted_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
    # fsync-ish: flush before rename so a reader cannot see a truncated record
    sync -f "$tmp" 2>/dev/null || sync 2>/dev/null || true
    mv -f "$tmp" "$out" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
    return 0
}
