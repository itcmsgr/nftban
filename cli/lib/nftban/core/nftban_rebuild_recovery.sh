#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.96 - Deferred Rebuild Recovery
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="nftban_rebuild_recovery"
# meta:type="script"
# meta:version="1.96.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-17"
# meta:description="Deferred rebuild recovery — reads marker, attempts one rebuild, updates state"
# meta:inventory.files="cli/lib/nftban/core/nftban_rebuild_recovery.sh"
# meta:inventory.binaries="/usr/sbin/nftban"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-rebuild-recovery.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# meta:called_by="nftban-rebuild-recovery.service (systemd oneshot)"
# meta:triggered_by="nftban-rebuild-recovery.timer (60s after boot, once)"
#
# Contract: V196_REBUILD_RECOVERY_CONTRACT.md §10 PR-04
# INV-RR-006: Retry is bounded — this script respects max retries
#
# Behavior:
#   1. Read recovery marker
#   2. If absent → exit 0 (nothing to do)
#   3. If exhausted → exit 0 (no more retries)
#   4. If failure class not retryable → exit 0
#   5. Increment retry count
#   6. Run rebuild
#   7. If success → clear marker, exit 0
#   8. If failure → update marker, exit 1
# =============================================================================

set -Eeuo pipefail

readonly MARKER_PATH="/var/lib/nftban/state/rebuild_recovery.json"
readonly NFTBAN_CLI="/usr/sbin/nftban"
readonly LOG_TAG="nftban-rebuild-recovery"

log_info()  { echo "[INFO]  $*"; logger -t "$LOG_TAG" -p daemon.info "$*" 2>/dev/null || true; }
log_warn()  { echo "[WARN]  $*" >&2; logger -t "$LOG_TAG" -p daemon.warning "$*" 2>/dev/null || true; }
log_error() { echo "[ERROR] $*" >&2; logger -t "$LOG_TAG" -p daemon.err "$*" 2>/dev/null || true; }

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Check marker exists
# ─────────────────────────────────────────────────────────────────────────────
if [[ ! -f "$MARKER_PATH" ]]; then
    log_info "No recovery marker found — nothing to do"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Read marker
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
    log_error "jq not available — cannot read recovery marker"
    exit 1
fi

failure_class=$(jq -r '.failure_class // ""' "$MARKER_PATH" 2>/dev/null || echo "")
retry_count=$(jq -r '.retry_count // 0' "$MARKER_PATH" 2>/dev/null || echo "0")
max_retries=$(jq -r '.max_retries // 3' "$MARKER_PATH" 2>/dev/null || echo "3")
exhausted=$(jq -r '.exhausted // false' "$MARKER_PATH" 2>/dev/null || echo "false")
deferred_pending=$(jq -r '.deferred_retry_pending // false' "$MARKER_PATH" 2>/dev/null || echo "false")

log_info "Recovery marker found: class=$failure_class, retries=$retry_count/$max_retries, exhausted=$exhausted, deferred=$deferred_pending"

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Check if we should proceed
# ─────────────────────────────────────────────────────────────────────────────

# Already exhausted
if [[ "$exhausted" == "true" ]]; then
    log_info "Recovery exhausted (retries=$retry_count/$max_retries) — no further action"
    exit 0
fi

# Deferred retry not requested
if [[ "$deferred_pending" != "true" ]]; then
    log_info "No deferred retry pending — nothing to do"
    exit 0
fi

# Non-retryable failure classes (INV-RR-005)
case "$failure_class" in
    PREVALIDATION_FAILED|SNAPSHOT_FAILED|POSTVALIDATION_HARD_FAIL|ROLLBACK_FAILED|AUTHORITY_CONFLICT|BACKUP_MISSING|RETRY_EXHAUSTED)
        log_info "Failure class $failure_class is non-retryable — clearing deferred flag"
        # Clear the deferred flag so we don't check again
        tmp="${MARKER_PATH}.tmp"
        jq '.deferred_retry_pending = false' "$MARKER_PATH" > "$tmp" 2>/dev/null && mv -f "$tmp" "$MARKER_PATH" || rm -f "$tmp"
        exit 0
        ;;
esac

# Retry cap check
if [[ $retry_count -ge $max_retries ]]; then
    log_warn "Retry cap reached ($retry_count/$max_retries) — marking exhausted"
    tmp="${MARKER_PATH}.tmp"
    jq '.exhausted = true | .deferred_retry_pending = false' "$MARKER_PATH" > "$tmp" 2>/dev/null && mv -f "$tmp" "$MARKER_PATH" || rm -f "$tmp"
    exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Check daemon is available (module restore needs it)
# ─────────────────────────────────────────────────────────────────────────────
if ! systemctl is-active --quiet nftband.service 2>/dev/null; then
    log_warn "Daemon not running — attempting start before recovery"
    systemctl reset-failed nftband.service 2>/dev/null || true
    systemctl reset-failed nftband.socket 2>/dev/null || true
    systemctl start nftband.service 2>/dev/null || true
    sleep 3
    if ! systemctl is-active --quiet nftband.service 2>/dev/null; then
        log_error "Daemon still not running — deferring recovery to next boot"
        exit 1
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Attempt rebuild recovery
# ─────────────────────────────────────────────────────────────────────────────
log_info "Attempting deferred rebuild recovery (attempt $((retry_count + 1))/$max_retries)..."

rebuild_exit=0
if [[ -x "$NFTBAN_CLI" ]]; then
    # v1.228.5: rebuild returns non-zero with the CAUSE on stderr. The previous form
    # let that text pass through to the caller's stdout unretained, so the recovery
    # log recorded only "failed (exit N)". Capture it and log a BOUNDED excerpt.
    # rebuild_exit semantics are unchanged.
    rebuild_output=""
    rebuild_output="$("$NFTBAN_CLI" firewall rebuild --quiet 2>&1)" || rebuild_exit=$?
    if [[ $rebuild_exit -ne 0 && -n "$rebuild_output" ]]; then
        log_warn "Rebuild reported the following (last 5 line(s)):"
        while IFS= read -r _rr_line; do
            if [[ -n "$_rr_line" ]]; then
                log_warn "  rebuild: $_rr_line"
            fi
        done <<< "$(printf '%s\n' "$rebuild_output" | tail -n 5)"
    fi
else
    log_error "nftban CLI not found at $NFTBAN_CLI"
    rebuild_exit=1
fi

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Process result
# ─────────────────────────────────────────────────────────────────────────────
if [[ $rebuild_exit -eq 0 ]]; then
    log_info "Deferred rebuild recovery SUCCEEDED — clearing marker"
    rm -f "$MARKER_PATH" 2>/dev/null || true
    exit 0
fi

# Rebuild still failed
log_warn "Deferred rebuild recovery failed (exit $rebuild_exit)"

# The rebuild itself already updated the marker via _rebuild_marker_write.
# We just need to check if it's now exhausted.
if [[ -f "$MARKER_PATH" ]]; then
    new_exhausted=$(jq -r '.exhausted // false' "$MARKER_PATH" 2>/dev/null || echo "false")
    new_count=$(jq -r '.retry_count // 0' "$MARKER_PATH" 2>/dev/null || echo "0")
    if [[ "$new_exhausted" == "true" ]]; then
        log_warn "Recovery exhausted after $new_count attempts — operator intervention required"
        log_warn "Run: nftban firewall rebuild"
    else
        log_info "Retry count: $new_count/$max_retries — will try again on next trigger"
    fi
fi

exit 1
