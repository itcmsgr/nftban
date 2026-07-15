#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.3.0 - Update Command Helper Functions
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Helper functions for update command
#
# meta:name="cmd_update_helpers"
# meta:type="cli"
# meta:header="Update Command Helpers"
# meta:version="1.60.1"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage="https://nftban.com"
#
# meta:description="Helper functions for update command (logging, dpkg repair, immutable flags)"
# meta:depends="cmd_update.sh"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="nftban"
# meta:created_date="2026-02-04"
# =============================================================================

set -Eeuo pipefail

# Prevent double-loading
[[ -n "${_NFTBAN_CLI_UPDATE_HELPERS_LOADED:-}" ]] && return 0
_NFTBAN_CLI_UPDATE_HELPERS_LOADED=1

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

_update_log() {
    local level="$1"
    shift
    local msg="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    # Log to file
    mkdir -p "$(dirname "$UPDATE_LOG_FILE")" 2>/dev/null || true
    echo "[$timestamp] [$level] $msg" >> "$UPDATE_LOG_FILE" 2>/dev/null || true

    # Output to terminal
    case "$level" in
        INFO)  echo "  $msg" ;;
        OK)    echo "  ✓ $msg" ;;
        WARN)  echo "  ⚠ $msg" ;;
        ERROR) echo "  ✗ $msg" >&2 ;;
    esac
}

# v1.198 R1b-3: fixed-phase progress marker for the full `nftban update` run.
# Emits "[n/total] <phase>[ — <hint>]" through _update_log (timestamped in the
# log, prefixed on the terminal). Presentation only — there is NO progress bar
# and NO dynamic state machine; it does not change update logic, ordering, or
# the rc contract. The total is a fixed phase count for a full run.
_NFTBAN_UPDATE_PHASE_TOTAL="${_NFTBAN_UPDATE_PHASE_TOTAL:-6}"
_NFTBAN_UPDATE_PHASE_DONE=0   # v1.215.0: last phase reached (for the final "Completed phases: N/M")
_update_phase() {
    local n="$1" name="$2" hint="${3:-}"
    _NFTBAN_UPDATE_PHASE_DONE="$n"   # side-effect only; the emitted marker string is unchanged
    _update_log INFO "[${n}/${_NFTBAN_UPDATE_PHASE_TOTAL}] ${name}${hint:+ — ${hint}}"
}

# v1.215.0 (OPEN_INSTALL_UPDATE_OBSERVABILITY, PR-1): the up-front progress contract —
# announce the total phase count + run_id + per-run log dir at the START of the run so the
# operator knows how many phases to expect and where the full record lives. Presentation
# only; identical for RPM and DEB (both flow through the same _cmd_update_main phases).
# Usage: _update_start_banner  (reads module-global _RUN_ID / FORENSIC_RUN_DIR)
_update_start_banner() {
    local run_id="${_RUN_ID:-${NFTBAN_RUN_ID:-n/a}}"
    local log_dir="${FORENSIC_RUN_DIR:-n/a}"
    echo ""
    echo "  NFTBan update started — ${_NFTBAN_UPDATE_PHASE_TOTAL} phases expected"
    echo "    run_id: ${run_id}"
    echo "    Logs:   ${log_dir}"
    echo ""
}

# v1.215.0 (OPEN_INSTALL_UPDATE_OBSERVABILITY, PR-1): one structured final operator
# summary, emitted on every terminal update path (COMMITTED/DEGRADED/FAILED/fallback).
# PRESENTATION ONLY — additive to the existing verdict blocks; does NOT change update
# logic, the rc contract, the per-run run.jsonl (untouched, machine-only), or the legacy
# "Updated: vX → vY" line. No lifecycle JSON is emitted here (v1.199 invariant preserved).
# Reads the module-global _RUN_ID / FORENSIC_RUN_DIR / UPDATE_LOG_FILE; failed-unit count
# is read LIVE at summary time. Usage:
#   _update_final_summary <result> <before_ver> <after_ver> <duration_s> <warnings> <validation>

# _update_classify_warnings: bucket the WARN/⚠ lines in THIS run's installer.log slice
# into operator-meaningful classes (v1.216.4) so a clean upgrade does not report generic
# scary warnings. Sets module globals used by _update_final_summary:
#   _NFTBAN_WARN_REAL      — warnings that require operator action
#   _NFTBAN_WARN_RECOVERED — transients that self-healed (e.g. a recovered timer restore)
#   _NFTBAN_WARN_ACCEPTED  — deliberate register-tracked exceptions (tmpfiles firewall-validate, v1.175)
#   _NFTBAN_WARN_EXTERNAL  — OS/package-manager advisories (needrestart, pending kernel) — not NFTBan
# W2 (tmpfiles exit 73) + W3 (unsafe path transition) are the SAME tmpfiles event → deduped to
# ONE accepted exception; needrestart/kernel lines dedup to one external advisory.
# Usage: _update_classify_warnings <installer_log> <before_line_count>
_update_classify_warnings() {
    local ilog="${1:-}" before="${2:-0}"
    _NFTBAN_WARN_REAL=0; _NFTBAN_WARN_RECOVERED=0; _NFTBAN_WARN_ACCEPTED=0; _NFTBAN_WARN_EXTERNAL=0
    [[ -f "$ilog" ]] || return 0
    # Classify by SIGNATURE first (accepted/external lines often lack a WARN tag), skipping
    # the installer's own meta self-report; only genuinely warn-tagged remainder = REAL.
    # Order matters: specific signatures are matched before the generic WARN/non-fatal catch.
    local line _tmpfiles=0 _external=0
    while IFS= read -r line; do
        case "$line" in
            *"recovered — verified active"*)                                             _NFTBAN_WARN_RECOVERED=$((_NFTBAN_WARN_RECOVERED + 1)); continue ;;
            *"exit 73"*|*"unsafe path transition"*|*"firewall-validate"*)                 _tmpfiles=1; continue ;;                                       # W2/W3 accepted (deduped)
            *"Pending kernel"*|*needrestart*|*"deferred"*|*"Restarting services"*|*"outdated binaries"*) _external=1; continue ;;                        # W4 external (deduped)
            *"still inactive after restore"*)                                            _NFTBAN_WARN_REAL=$((_NFTBAN_WARN_REAL + 1)); continue ;;      # W1 real
            *", with "*"warning"*|*" warning — non-fatal"*|*"non-fatal"*)                 continue ;;                                                    # installer meta self-report — skip
            *"WARN"*|*"⚠"*)                                                              _NFTBAN_WARN_REAL=$((_NFTBAN_WARN_REAL + 1)); continue ;;      # any other warn-tagged line = real
        esac
    done < <(tail -n +$((before + 1)) "$ilog" 2>/dev/null)
    [[ "$_tmpfiles" -eq 1 ]] && _NFTBAN_WARN_ACCEPTED=1
    [[ "$_external" -eq 1 ]] && _NFTBAN_WARN_EXTERNAL=1
    return 0
}

_update_final_summary() {
    local result="${1:-UNKNOWN}" before="${2:-?}" after="${3:-?}" dur="${4:-?}"
    local warnings="${5:-0}" validation="${6:-unavailable}"
    local run_id="${_RUN_ID:-${NFTBAN_RUN_ID:-n/a}}"
    local log_dir="${FORENSIC_RUN_DIR:-n/a}"
    local log_path="${UPDATE_LOG_FILE:-/var/log/nftban/update.log}"
    local failed_units
    failed_units=$(systemctl --failed --no-legend 2>/dev/null | grep -c -i 'nftban' || true)
    failed_units=${failed_units//[^0-9]/}; failed_units=${failed_units:-0}
    [[ "$warnings" =~ ^[0-9]+$ ]] || warnings=0
    local phases_done="${_NFTBAN_UPDATE_PHASE_DONE:-0}" phases_total="${_NFTBAN_UPDATE_PHASE_TOTAL:-6}"

    echo ""
    echo "  ┌─ Update summary ─────────────────────────────────────"
    printf '  │ %-16s %s\n' "Result:"          "$result"
    printf '  │ %-16s %s\n' "Version:"         "v${before} → v${after} (${dur}s)"
    # v1.216.4: class-aware warning breakdown so a clean upgrade doesn't show a scary
    # generic count. Falls back to the plain count if warnings were not classified.
    if [[ -n "${_NFTBAN_WARN_REAL:-}" ]]; then
        printf '  │ %-16s %s\n' "Warnings:" "${_NFTBAN_WARN_REAL} action / ${_NFTBAN_WARN_RECOVERED:-0} recovered / ${_NFTBAN_WARN_ACCEPTED:-0} accepted / ${_NFTBAN_WARN_EXTERNAL:-0} external"
    else
        printf '  │ %-16s %s\n' "Warnings:" "$warnings"
    fi
    printf '  │ %-16s %s\n' "Failed units:"    "$failed_units"
    printf '  │ %-16s %s\n' "Validation:"      "$validation"
    printf '  │ %-16s %s\n' "Completed phases:" "${phases_done}/${phases_total}"
    printf '  │ %-16s %s\n' "Run ID:"          "$run_id"
    printf '  │ %-16s %s\n' "Log dir:"         "$log_dir"
    printf '  │ %-16s %s\n' "Log:"             "$log_path"
    echo "  └──────────────────────────────────────────────────────"
    echo ""
}

_update_banner() {
    local current_ver
    current_ver=$(_get_current_version 2>/dev/null || echo "unknown")

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  NFTBan Update (current: v${current_ver})"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

_fix_broken_dpkg() {
    # Fix broken dpkg state left by interrupted installs
    # Safe to call even when dpkg is healthy - it will be a no-op
    # Returns: 0 on success or no dpkg, 1 on failure to repair

    if ! command -v dpkg &>/dev/null; then
        return 0
    fi

    # Check if dpkg has interrupted/broken packages
    local dpkg_audit
    dpkg_audit=$(dpkg --audit 2>&1) || true

    local needs_configure=0

    # dpkg --audit outputs nothing when everything is clean
    if [[ -n "$dpkg_audit" ]]; then
        needs_configure=1
        _update_log WARN "Broken dpkg state detected"
        _update_log INFO "dpkg audit: $(echo "$dpkg_audit" | head -3)"
    fi

    # Also check for packages in an inconsistent state
    if dpkg -l nftban 2>/dev/null | grep -qE "^(iF|iU|iW|iH|.R|.H)"; then
        needs_configure=1
        _update_log WARN "NFTBan package in inconsistent dpkg state"
    fi
    if dpkg -l nftban-core 2>/dev/null | grep -qE "^(iF|iU|iW|iH|.R|.H)"; then
        needs_configure=1
        _update_log WARN "NFTBan-core package in inconsistent dpkg state"
    fi

    # Also check /var/lib/dpkg/updates for pending triggers
    if [[ -d /var/lib/dpkg/updates ]] && compgen -G "/var/lib/dpkg/updates/*" >/dev/null 2>&1; then
        needs_configure=1
        _update_log WARN "Pending dpkg updates found"
    fi

    if [[ "$needs_configure" -eq 1 ]]; then
        _update_log INFO "Running dpkg --configure -a to fix broken state..."
        if dpkg --configure -a 2>&1 | while read -r line; do echo "    $line"; done; then
            _update_log OK "dpkg state repaired"
            return 0
        else
            _update_log ERROR "dpkg --configure -a failed"
            _update_log INFO "Manual intervention may be needed: sudo dpkg --configure -a"
            return 1
        fi
    fi

    return 0
}

_remove_immutable_flags() {
    # Remove immutable (chattr +i) flags from ALL nftban files
    # This is needed before any install/update/rollback can modify files
    # Safe to call even if no immutable flags are set

    _update_log INFO "Removing immutable flags from nftban files..."

    # Locate chattr binary (may not be in minimal PATH during package operations)
    local chattr_bin
    chattr_bin=$(command -v chattr 2>/dev/null || echo "")
    if [[ -z "$chattr_bin" ]]; then
        for p in /usr/bin/chattr /bin/chattr /sbin/chattr /usr/sbin/chattr; do
            [[ -x "$p" ]] && chattr_bin="$p" && break || true
        done
    fi

    if [[ -z "$chattr_bin" ]]; then
        _update_log WARN "chattr not found - cannot remove immutable flags"
        return 0
    fi

    # Locate lsattr binary
    local lsattr_bin
    lsattr_bin=$(command -v lsattr 2>/dev/null || echo "")
    [[ -z "$lsattr_bin" ]] && for p in /usr/bin/lsattr /bin/lsattr; do
        [[ -x "$p" ]] && lsattr_bin="$p" && break || true
    done

    # Critical file that is known to be immutable
    local schema="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nft_schema.sh"

    # Helper to check if file has immutable flag
    _has_immutable() {
        local file="$1"
        [[ -z "$lsattr_bin" ]] && return 1
        [[ ! -f "$file" ]] && return 1
        # lsattr output: "----i--------e-- /path/to/file"
        # The 'i' at position 5 indicates immutable
        local attrs
        attrs=$("$lsattr_bin" "$file" 2>/dev/null | awk '{print $1}') || return 1
        [[ "${attrs:4:1}" == "i" ]]
    }

    # Remove immutable flag from the critical file first (most common failure point)
    if [[ -f "$schema" ]] && _has_immutable "$schema"; then
        local err
        if ! err=$("$chattr_bin" -i "$schema" 2>&1); then
            _update_log WARN "chattr -i failed on $schema: $err"
        fi
    fi

    local dirs_to_check=(
        "${NFTBAN_LIB_DIR:-/usr/lib/nftban}"
        "/usr/sbin/nftban"
        "${NFTBAN_CONFIG_DIR:-/etc/nftban}"
    )

    for path in "${dirs_to_check[@]}"; do
        if [[ -e "$path" ]]; then
            if [[ -d "$path" ]]; then
                # Use find to locate immutable files and remove flag individually
                # This is more reliable than -R which can fail silently
                if [[ -n "$lsattr_bin" ]]; then
                    while IFS= read -r -d '' file; do
                        "$chattr_bin" -i "$file" 2>/dev/null || true
                    done < <(find "$path" -type f -print0 2>/dev/null)
                else
                    # Fallback: brute-force recursive removal
                    "$chattr_bin" -i -R "$path" 2>/dev/null || true
                fi
            else
                "$chattr_bin" -i "$path" 2>/dev/null || true
            fi
        fi
    done

    # Verify the critical file is no longer immutable
    if [[ -f "$schema" ]]; then
        if _has_immutable "$schema"; then
            _update_log WARN "Immutable flag on nft_schema.sh persists, retrying with verbose..."
            # Final attempt - show actual error
            local err
            err=$("$chattr_bin" -i "$schema" 2>&1) || true
            [[ -n "$err" ]] && _update_log WARN "chattr output: $err"

            if _has_immutable "$schema"; then
                _update_log ERROR "Cannot remove immutable flag from $schema"
                _update_log ERROR "Possible causes:"
                _update_log ERROR "  - Filesystem doesn't support extended attributes"
                _update_log ERROR "  - File is on a read-only mount"
                _update_log ERROR "  - SELinux/AppArmor policy blocking"
                _update_log ERROR "Run manually: chattr -i $schema"
                # Don't fail - let dpkg try anyway, it might work
                return 0
            fi
        fi
        _update_log OK "Immutable flags cleared"
    else
        _update_log INFO "No immutable files found"
    fi
}

_load_config() {
    if [[ -f "$UPDATE_CONFIG_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$UPDATE_CONFIG_FILE" || true
    fi
}

_update_write_history() {
    # Write update result to JSON history file (keep last 9 entries)
    # Args: $1=from_version $2=to_version $3=status(ok|fail) $4=install_type $5=duration_secs
    local from_ver="$1" to_ver="$2" status="$3" install_type="$4" duration="$5"
    local history_file="${NFTBAN_DATA_DIR:-/var/lib/nftban}/update-history.json"
    local hostname_val
    hostname_val=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown")
    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    local new_entry
    new_entry=$(printf '{"timestamp":"%s","from":"%s","to":"%s","status":"%s","type":"%s","duration_s":%s,"host":"%s"}' \
        "$ts" "$from_ver" "$to_ver" "$status" "$install_type" "$duration" "$hostname_val")

    mkdir -p "$(dirname "$history_file")" 2>/dev/null || true

    if command -v jq &>/dev/null && [[ -f "$history_file" ]] && jq empty "$history_file" 2>/dev/null; then
        # Prepend new entry + keep last 9
        local tmp_hist
        tmp_hist=$(mktemp "${history_file}.XXXXXX") || return 0
        jq --argjson entry "$new_entry" '[$entry] + . | .[0:9]' "$history_file" > "$tmp_hist" 2>/dev/null && \
            mv -f "$tmp_hist" "$history_file" || rm -f "$tmp_hist"
    else
        # First entry or no jq — write single-element array
        printf '[%s]\n' "$new_entry" > "$history_file" 2>/dev/null || true
    fi
    chmod 0640 "$history_file" 2>/dev/null || true
}


# =============================================================================
# v1.198.3 PR-A (BUG-WATCHDOG-TIMER-UPDATE-SWAP-EXEC203-RACE)
# -----------------------------------------------------------------------------
# Cadence timers (nftban-watchdog.timer @120s, nftban-maintenance.timer @15m)
# exec /usr/sbin/nftban. If one fires while `nftban update` is replacing /
# permission/attribute-toggling the binary, systemd hits a transient EXEC-203
# Permission-denied, latches the .service failed, and the post-install
# failed-unit assertion marks install_state=DEGRADED on an otherwise-healthy
# upgrade (reproduced on dns2 2026-06-22 20:23:24Z). These helpers transiently
# STOP the racing timers for the binary-swap critical section and RESTORE exactly
# the ones that were active — never mask, never enable a disabled timer.
# =============================================================================

# Timers that exec the nftban binary on a tight enough cadence to race the swap.
# watchdog = the proven 120s racer; maintenance = defensive 15m sibling.
_NFTBAN_UPDATE_CADENCE_TIMERS=("nftban-watchdog.timer" "nftban-maintenance.timer")
# Records exactly which timers THIS run stopped (so restore only re-starts those).
_NFTBAN_INHIBITED_TIMERS=""

# _update_inhibit_cadence_timers: stop the racing cadence timers that are
# currently active; record them for restore. Best-effort — never fail the update.
_update_inhibit_cadence_timers() {
    _NFTBAN_INHIBITED_TIMERS=""
    command -v systemctl >/dev/null 2>&1 || return 0
    local t
    for t in "${_NFTBAN_UPDATE_CADENCE_TIMERS[@]}"; do
        if systemctl is-active --quiet "$t" 2>/dev/null; then
            if systemctl stop "$t" 2>/dev/null; then
                _NFTBAN_INHIBITED_TIMERS="${_NFTBAN_INHIBITED_TIMERS:+$_NFTBAN_INHIBITED_TIMERS }$t"
            fi
        fi
    done
    [[ -n "$_NFTBAN_INHIBITED_TIMERS" ]] && _update_log INFO "Inhibited cadence timer(s) for the install window: ${_NFTBAN_INHIBITED_TIMERS}" || true
    return 0
}

# _update_restore_cadence_timers: re-start exactly the timers this run stopped.
# IDEMPOTENT (empty list = no-op), so it is safe to call from both the normal
# path and a scoped INT/TERM trap. Never enables a timer that was disabled.
_update_restore_cadence_timers() {
    [[ -z "${_NFTBAN_INHIBITED_TIMERS:-}" ]] && return 0
    command -v systemctl >/dev/null 2>&1 || { _NFTBAN_INHIBITED_TIMERS=""; return 0; }
    # v1.216.4 BUG-UPDATE-INHIBITED-TIMER-FALSE-WARN: _NFTBAN_INHIBITED_TIMERS is a
    # space-joined string, but the update entrypoint sets IFS=$'\n\t' (space excluded),
    # so a bare `for t in $var` did NOT split it — systemctl was handed both timers as
    # ONE malformed unit name and always "failed", emitting a false WARN even though the
    # installer's timer reconciliation left them active. Split on space explicitly (scoped
    # IFS on the read), start each timer individually, then VERIFY with is-active: warn
    # ONLY if a timer is genuinely still inactive after restore (a transient start failure
    # that self-heals is a recovered advisory, not a real warning).
    local t transient=0
    local -a _timers_arr=() restored=() still_inactive=()
    IFS=' ' read -r -a _timers_arr <<< "$_NFTBAN_INHIBITED_TIMERS"
    for t in "${_timers_arr[@]}"; do
        [[ -n "$t" ]] || continue
        systemctl start "$t" 2>/dev/null || transient=1
        if systemctl is-active --quiet "$t" 2>/dev/null; then
            restored+=("$t")
        else
            still_inactive+=("$t")
        fi
    done
    if [[ ${#still_inactive[@]} -gt 0 ]]; then
        # WARN_REAL: a cadence timer is actually down after restore — operator action needed.
        _update_log WARN "cadence timer(s) still inactive after restore: ${still_inactive[*]} — start manually: systemctl start ${still_inactive[*]}"
    elif [[ "$transient" -eq 1 ]]; then
        # WARN_RECOVERED: start returned non-zero but is-active confirms recovery (no action).
        _update_log INFO "Restored cadence timer(s): ${restored[*]} (recovered — verified active after a transient start error)"
    else
        _update_log INFO "Restored cadence timer(s): ${restored[*]} (verified active)"
    fi
    _NFTBAN_INHIBITED_TIMERS=""
    return 0
}

# _update_verify_watchdog: after the swap + restore, run the watchdog oneshot
# ONCE to confirm it is healthy on the new binary. Clears a stale failed-latch
# only if the fresh run succeeds (never masks a genuinely-broken watchdog).
# Returns 0 if the post-update watchdog run is clean (or systemctl/unit absent),
# 1 if the watchdog genuinely still fails.
_update_verify_watchdog() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl cat nftban-watchdog.service >/dev/null 2>&1 || return 0
    systemctl reset-failed nftban-watchdog.service 2>/dev/null || true
    systemctl start nftban-watchdog.service 2>/dev/null || true
    if systemctl is-failed --quiet nftban-watchdog.service 2>/dev/null; then
        _update_log WARN "post-update watchdog verification FAILED — nftban-watchdog.service still failing after the update (not a transient swap-window race)"
        return 1
    fi
    _update_log OK "post-update watchdog verification passed"
    return 0
}

# =============================================================================
# v1.199 Lifecycle Forensics (BUG-INSTALLER-PER-RUN-FORENSIC-LOG-MISSING +
#                            BUG-INSTALLER-LOG-FORMAT-MIXED-JSON)
# -----------------------------------------------------------------------------
# Per-run forensic record under /var/log/nftban/update-runs/<run_id>/: a parseable
# JSONL event stream (run.jsonl) + a human slice (human.log) + allowlisted
# lifecycle snapshots at pre-swap / post-swap / post-restore. jq-free; values are
# redaction-filtered; ONLY an explicit allowlist of fields is emitted (no env, no
# secrets, no config dump). Bounded retention (keep newest N, prune + log the rest).
# Forensics ONLY — no reliability/self-heal logic here.
# =============================================================================
FORENSIC_RUNS_DIR="${NFTBAN_LOG_DIR:-/var/log/nftban}/update-runs"
FORENSIC_RETAIN_N="${NFTBAN_FORENSIC_RETAIN:-20}"
FORENSIC_RUN_DIR=""; FORENSIC_JSONL=""; FORENSIC_HUMAN=""

# deterministic run_id (tests/callers may pin via NFTBAN_RUN_ID)
_forensic_run_id() { printf '%s' "${NFTBAN_RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null)-$$}"; }

# minimal JSON string escaper (no jq dependency)
_fx_jstr() { local s="${1-}"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/ }"; s="${s//$'\t'/ }"; s="${s//$'\r'/ }"; printf '%s' "$s"; }
# secret redaction safety-net (the snapshot is allowlisted, but values pass this too)
_fx_redact() {
    # SEC-P1-2 P2b-1/P-retire-2: delegate to the shared redaction authority (the ONLY secret path).
    if ! declare -F nftban_redact_stream >/dev/null 2>&1 && [[ -f "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_redact.sh" ]]; then
        # shellcheck source=/dev/null
        source "${NFTBAN_LIB_DIR:-/usr/lib/nftban}/lib/nftban_redact.sh" 2>/dev/null || true
    fi
    # FAIL-CLOSED — the legacy weak sed (missed *_PASS) is RETIRED. If the authority is unavailable,
    # drain+discard stdin and emit the marker; never weak-redact, never raw passthrough.
    if declare -F nftban_redact_stream >/dev/null 2>&1; then
        nftban_redact_stream
    else
        cat >/dev/null 2>&1
        printf '%s\n' '[REDACTION-UNAVAILABLE: do not share]'
        echo '[SECURITY][ERROR] nftban_redact.sh unavailable — redaction skipped, content suppressed' >&2
    fi
    return 0
}

# _forensic_begin <run_id> <mode> <from> <to>
_forensic_begin() {
    local id="$1" mode="${2:-}" from="${3:-}" to="${4:-}"
    command -v date >/dev/null 2>&1 || return 0
    FORENSIC_RUN_DIR="$FORENSIC_RUNS_DIR/$id"
    mkdir -p "$FORENSIC_RUN_DIR" 2>/dev/null || { FORENSIC_RUN_DIR=""; return 0; }
    chmod 0750 "$FORENSIC_RUN_DIR" 2>/dev/null || true
    FORENSIC_JSONL="$FORENSIC_RUN_DIR/run.jsonl"; FORENSIC_HUMAN="$FORENSIC_RUN_DIR/human.log"
    : > "$FORENSIC_JSONL" 2>/dev/null || true; : > "$FORENSIC_HUMAN" 2>/dev/null || true
    chmod 0640 "$FORENSIC_JSONL" "$FORENSIC_HUMAN" 2>/dev/null || true
    _forensic_event "$id" run_start "mode=$mode" "from=$from" "to=$to" "pid=$$"
    _forensic_prune
}

# _forensic_event <run_id> <event> [key=value ...]  (values redacted; allowlisted callers only)
_forensic_event() {
    [ -n "${FORENSIC_JSONL:-}" ] || return 0
    local id="$1" ev="$2"; shift 2 || true
    local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf '')
    local json kv k v
    json="{\"ts\":\"$(_fx_jstr "$ts")\",\"run_id\":\"$(_fx_jstr "$id")\",\"event\":\"$(_fx_jstr "$ev")\""
    for kv in "$@"; do
        k="${kv%%=*}"; v="${kv#*=}"
        # defense-in-depth: if the KEY is secret-named, redact the whole value;
        # otherwise run the substring redaction safety-net over the value.
        if printf '%s' "$k" | grep -qiE '^(pass(word)?|secret|token|api[_-]?key|bearer|authorization)$'; then
            v="<redacted>"
        else
            v=$(printf '%s' "$v" | _fx_redact)
        fi
        json="$json,\"$(_fx_jstr "$k")\":\"$(_fx_jstr "$v")\""
    done
    json="$json}"
    printf '%s\n' "$json" >> "$FORENSIC_JSONL" 2>/dev/null || true
}

# _forensic_snapshot <run_id> <phase>  (allowlisted lifecycle-critical fields ONLY)
_forensic_snapshot() {
    [ -n "${FORENSIC_JSONL:-}" ] || return 0
    local id="$1" ph="$2" bin="${NFTBAN_SBIN:-/usr/sbin/nftban}"
    local mode mtime xattr ist wd_act wd_next mt_act failed u
    mode=$(stat -c '%a' "$bin" 2>/dev/null || printf '?'); mtime=$(stat -c '%Y' "$bin" 2>/dev/null || printf '?')
    xattr=$(lsattr "$bin" 2>/dev/null | awk '{print $1}' || printf '?')
    ist=$(grep -m1 '^INSTALL_STATE=' "${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/install_state" 2>/dev/null | cut -d= -f2- || printf '?')
    wd_act=$(systemctl is-active nftban-watchdog.timer 2>/dev/null || printf '?')
    wd_next=$(systemctl show nftban-watchdog.timer -p NextElapseUSecRealtime --value 2>/dev/null || printf '?')
    mt_act=$(systemctl is-active nftban-maintenance.timer 2>/dev/null || printf '?')
    failed=$(systemctl --failed --no-legend 2>/dev/null | grep -iE 'nftban|nftband' | awk '{print $2}' | tr '\n' ',' || printf '')
    _forensic_event "$id" snapshot "phase=$ph" "bin_mode=$mode" "bin_mtime=$mtime" "bin_xattr=$xattr" \
        "install_state=$ist" "watchdog_timer=$wd_act" "watchdog_next=$wd_next" "maintenance_timer=$mt_act" "failed_units=$failed"
    for u in $(systemctl --failed --no-legend 2>/dev/null | grep -iE 'nftban|nftband' | awk '{print $2}'); do
        _forensic_event "$id" failed_unit "phase=$ph" "unit=$u" \
            "result=$(systemctl show "$u" -p Result --value 2>/dev/null)" \
            "exec_status=$(systemctl show "$u" -p ExecMainStatus --value 2>/dev/null)" \
            "exec_exit=$(systemctl show "$u" -p ExecMainExitTimestamp --value 2>/dev/null)" \
            "inactive_enter=$(systemctl show "$u" -p InactiveEnterTimestamp --value 2>/dev/null)"
    done
}

# _forensic_end <run_id> <state> <rc>
_forensic_end() { [ -n "${FORENSIC_JSONL:-}" ] || return 0; _forensic_event "$1" run_end "state=${2:-}" "rc=${3:-}"; }

# _forensic_prune — keep newest N run dirs; log what is pruned (no silent cap)
_forensic_prune() {
    [ -d "$FORENSIC_RUNS_DIR" ] || return 0
    # read the env at call time (operator may set NFTBAN_FORENSIC_RETAIN after source)
    local n="${NFTBAN_FORENSIC_RETAIN:-${FORENSIC_RETAIN_N:-20}}"; [ "$n" -gt 0 ] 2>/dev/null || n=20
    local total; total=$(find "$FORENSIC_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
    [ "${total:-0}" -le "$n" ] && return 0
    local pruned=0 d
    while IFS= read -r d; do [ -n "$d" ] && rm -rf "$d" 2>/dev/null && pruned=$((pruned+1)); done < <(
        find "$FORENSIC_RUNS_DIR" -mindepth 1 -maxdepth 1 -type d -printf '%T@\t%p\n' 2>/dev/null | sort -n | head -n "$(( total - n ))" | cut -f2-)
    [ "$pruned" -gt 0 ] && _update_log INFO "forensics: pruned $pruned old run-record(s), retained newest $n (NFTBAN_FORENSIC_RETAIN)" || true
    return 0
}
