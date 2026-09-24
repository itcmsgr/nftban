#!/usr/bin/env bash
# =============================================================================
# NFTBan - module enable/disable TRANSACTION (v1.233.1)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="module_txn"
# meta:type="lib"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-09-25"
# meta:description="The owner-ruled 11-step enable/disable transaction (V1_234_0 claim-truth contract §6-§7, rulings L1-L3), shared by every module that has a plan-bearing reconcile root. It was written for PortScan (lane v1233-1-portscan) and moved here UNCHANGED IN BEHAVIOUR so DDoS reuses the same lock acquisition, transaction-record writer/format, outcome derivation + rc table and kernel-postcondition discipline instead of copying them. The module supplies only what is module-specific, through named hooks: its reconcile root, its kernel observation, its expected kernel class per effective mode, its input loader, its labels and a record-write wrapper. v1.233.1 minimal reuse, not the v1.234 generic framework."
# meta:inventory.files="/run/nftban/module-txn-<module>.env, /run/nftban/nft_operations.lock"
# meta:inventory.binaries="systemctl,date"
# meta:inventory.env_vars="NFTBAN_PLAN_RECORD_DIR,NFTBAN_RUN_DIR"
# meta:inventory.config_files="conf.d/<module>/main.conf.local (through nftban_module_set_enabled only)"
# meta:inventory.systemd_units="nftband.service (restart, enable only, lifecycle action)"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
#
# THE TRANSACTION (owner rulings L1-L3, V1_234_0 §7):
#    1 acquire the canonical convergence lock (/run/nftban/nft_operations.lock)
#    2 create the runtime transaction record
#    3 atomically persist the requested intent, and prove it resolves
#    4 run THE reconcile root in-process, under the lock, against that intent
#    5 verify the postconditions that are safe to inspect under the lock: the
#      committed plan generation, the plan's enabled flag and effective mode, and
#      the KERNEL through the module's typed observation
#    6 record the reconcile result
#    7 release the lock
#    8 restart nftband as a LIFECYCLE action only (enable; disable needs none)
#    9 observe daemon readiness, bounded
#   10 verify the daemon observes the committed plan and does not contradict the
#      kernel
#   11 derive EXACTLY ONE terminal outcome; the printed verdict and the exit
#      code are both rendered from it
#
# WHY STEP 4 CANNOT SELF-DEADLOCK: see the PortScan design note
# (v1234_artifacts/portscan_enable_disable_txn_2026_09_25/DESIGN_NOTE.md §1).
# The reconcile root JOINS the held lock (_nftban_plan_lock_acquire returns
# without re-acquiring while NFTBAN_NFTLOCK_HELD is set); every kernel write it
# reaches is either the nft binary (no flock) or IPC apply_ruleset (backend
# mutex only, never internal/nftlock). The restart comes AFTER the release
# because the restarted daemon's own reconcile takes this lock fail-fast.
#
# OUTCOMES -> exit code:
#   CONVERGED 0 · FAILED_ROLLED_BACK 1 · DEGRADED 3 · PENDING_TIMED_OUT 4
#   REFUSED 7 (convergence lock busy) or 5 (another precondition).
# L3: an unobservable kernel is UNMEASURED -> DEGRADED. It is never a success,
# and it is never treated as absence.
#
# MODULE HOOKS (m = module name as module_authority knows it):
#   nftban_<m>_reconcile            THE reconcile root (plan-bearing)
#   _nftban_<m>_txn_prepare         load the inputs observation needs; rc!=0 -> REFUSED
#   _nftban_<m>_kernel_observe      set NFTBAN_MTXN_KCLASS / NFTBAN_MTXN_KDETAIL;
#                                   class UNMEASURED when any query failed
#   _nftban_<m>_expected_kclass <effective-mode>   echo the required class
#                                   ("A|B" = either converged shape)
#   _nftban_<m>_txn_labels          set _MT_TITLE _MT_NAME _MT_LOWER _MT_WHAT
#   _nftban_<m>_txn_record_write    wrapper: `nftban_mtxn_record_write` (a named
#                                   function so a test can fault it by name)
#   _nftban_<m>_log <LEVEL> <msg>   optional
#   _nftban_<m>_txn_status_lines    optional: its presence means `nftban <m>
#                                   status` renders the record
# =============================================================================

[[ -n "${_NFTBAN_MODULE_TXN_LOADED:-}" ]] && return 0
_NFTBAN_MODULE_TXN_LOADED=1

# shellcheck disable=SC2034  # results read by module hooks and callers
NFTBAN_MTXN_KCLASS=""; NFTBAN_MTXN_KDETAIL=""

nftban_mtxn_record_path() {
    printf '%s/module-txn-%s.env' "${NFTBAN_PLAN_RECORD_DIR:-/run/nftban}" "${1:-$_MT_MOD}"
}

_nftban_mtxn_reset() {
    _MT_MOD="${1:-}"
    _MT_ID=""; _MT_OP=""; _MT_WANT=""; _MT_PREV=""
    _MT_STARTED=""; _MT_GEN_BEFORE=""; _MT_GEN_AFTER=""
    _MT_PHASE=""; _MT_OUTCOME=""; _MT_REASON=""; _MT_EFFECTIVE=""
    _MT_PRE_EFFECTIVE=""; _MT_PRE_KCLASS=""; _MT_RECORD_OK="true"
    _MT_OPENED="false"; _MT_STAGE=""; _MT_KDETAIL=""; _MT_REFUSE_RC=5
    _MT_TITLE="$_MT_MOD"; _MT_NAME="$_MT_MOD"; _MT_LOWER="$_MT_MOD"; _MT_WHAT="the module"
}

_nftban_mtxn_log() {
    if declare -F "_nftban_${_MT_MOD}_log" >/dev/null 2>&1; then
        "_nftban_${_MT_MOD}_log" "$1" "$2" || true
    fi
    return 0
}

# Hook dispatch. Every call site names the hook explicitly.
_nftban_mtxn_record() { "_nftban_${_MT_MOD}_txn_record_write"; }
_nftban_mtxn_observe() {
    NFTBAN_MTXN_KCLASS="UNMEASURED"; NFTBAN_MTXN_KDETAIL=""
    if ! declare -F "_nftban_${_MT_MOD}_kernel_observe" >/dev/null 2>&1; then
        NFTBAN_MTXN_KDETAIL="kernel observation authority unavailable"; return 0
    fi
    "_nftban_${_MT_MOD}_kernel_observe" || true
    [[ -n "$NFTBAN_MTXN_KCLASS" ]] || NFTBAN_MTXN_KCLASS="UNMEASURED"
    return 0
}
_nftban_mtxn_expect() { "_nftban_${_MT_MOD}_expected_kclass" "$1"; }
# _nftban_mtxn_kclass_ok <expected> <observed> — the expectation may name
# alternatives ("A|B") when a mode admits more than one converged kernel shape.
# UNMEASURED never satisfies an expectation.
_nftban_mtxn_kclass_ok() {
    [[ -n "$2" && "$2" != "UNMEASURED" && "|$1|" == *"|$2|"* ]]
}
_nftban_mtxn_reconcile() { "nftban_${_MT_MOD}_reconcile"; }

# The module's in-shell intent variable, kept in step with the saved intent
# (the module's own code reads it).
_nftban_mtxn_set_intent_var() {
    local var
    var="$(_nftban_module_enable_var "$_MT_MOD")" || return 0
    printf -v "$var" '%s' "$1"
}

# nftban_mtxn_record_write — atomic (tmp + rename), root-only (0600), mirroring
# the plan-record publication in the reconcile roots.
nftban_mtxn_record_write() {
    local path tmp boot="" now reason
    path="$(nftban_mtxn_record_path "$_MT_MOD")"
    tmp="${path}.tmp.$$"
    if [[ -r /proc/sys/kernel/random/boot_id ]]; then
        read -r boot < /proc/sys/kernel/random/boot_id || boot=""
    fi
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    reason="${_MT_REASON//$'\n'/ }"
    if ! ( umask 077
           {
               printf 'NFTBAN_TXN_ID=%s\n'                  "$_MT_ID"
               printf 'NFTBAN_TXN_MODULE=%s\n'              "$_MT_MOD"
               printf 'NFTBAN_TXN_OP=%s\n'                  "$_MT_OP"
               printf 'NFTBAN_TXN_REQUESTED_INTENT=%s\n'    "$_MT_WANT"
               printf 'NFTBAN_TXN_PREVIOUS_INTENT=%s\n'     "$_MT_PREV"
               printf 'NFTBAN_TXN_STARTED_AT=%s\n'          "$_MT_STARTED"
               printf 'NFTBAN_TXN_UPDATED_AT=%s\n'          "$now"
               printf 'NFTBAN_TXN_PID=%s\n'                 "$$"
               printf 'NFTBAN_TXN_BOOT_ID=%s\n'             "$boot"
               printf 'NFTBAN_TXN_GENERATION_BEFORE=%s\n'   "$_MT_GEN_BEFORE"
               printf 'NFTBAN_TXN_EXPECTED_GENERATION=%s\n' "$(( ${_MT_GEN_BEFORE:-0} + 1 ))"
               printf 'NFTBAN_TXN_RESULTING_GENERATION=%s\n' "$_MT_GEN_AFTER"
               printf 'NFTBAN_TXN_EFFECTIVE_MODE=%s\n'      "$_MT_EFFECTIVE"
               printf 'NFTBAN_TXN_PHASE=%s\n'               "$_MT_PHASE"
               printf 'NFTBAN_TXN_OUTCOME=%s\n'             "$_MT_OUTCOME"
               printf 'NFTBAN_TXN_REASON=%s\n'              "$reason"
           } > "$tmp" ) 2>/dev/null; then
        rm -f "$tmp"; _MT_RECORD_OK="false"; return 1
    fi
    if ! chmod 0600 "$tmp" 2>/dev/null || ! mv -f "$tmp" "$path" 2>/dev/null; then
        rm -f "$tmp"; _MT_RECORD_OK="false"; return 1
    fi
    return 0
}

# _nftban_mtxn_phase <PHASE> — advance and persist the phase. A failed write is
# remembered (_MT_RECORD_OK=false) and caps the outcome below CONVERGED:
# interruption visibility is part of the contract.
_nftban_mtxn_phase() {
    _MT_PHASE="$1"
    _nftban_mtxn_record
}

# _nftban_mtxn_read_plan <generation> — read the COMMITTED record for a
# generation. Sets _MT_PLAN_ENABLED / _MT_PLAN_EFF / _MT_PLAN_BOUND.
_nftban_mtxn_read_plan() {
    local gen="$1" pf line k v
    _MT_PLAN_ENABLED=""; _MT_PLAN_EFF=""; _MT_PLAN_BOUND=""
    pf="$(nftban_plan_record_path "$_MT_MOD" "$gen")"
    [[ -r "$pf" ]] || return 1
    while IFS= read -r line; do
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            NFTBAN_PLAN_ENABLED)          _MT_PLAN_ENABLED="$v" ;;
            NFTBAN_PLAN_EFFECTIVE_MODE)   _MT_PLAN_EFF="$v" ;;
            NFTBAN_PLAN_BOUND_GENERATION) _MT_PLAN_BOUND="$v" ;;
        esac
    done < "$pf"
    [[ "$_MT_PLAN_BOUND" == "$gen" && -n "$_MT_PLAN_EFF" && -n "$_MT_PLAN_ENABLED" ]]
}

# _nftban_mtxn_intent — echo true|false|unknown for the effective intent.
_nftban_mtxn_intent() {
    local irc=0
    nftban_module_effective_enabled "$_MT_MOD" || irc=$?
    case "$irc" in
        0) printf 'true' ;;
        1) printf 'false' ;;
        *) printf 'unknown' ;;
    esac
}

# _nftban_mtxn_rollback <why> — re-establish the PREVIOUS state through the
# same primitives, then VERIFY it. Rollback is recovery, not success:
#   verified     -> FAILED_ROLLED_BACK
#   not verified -> DEGRADED (every axis that could not be shown is named)
# Runs under the lock (called from the locked phase only).
_nftban_mtxn_rollback() {
    local why="$1" ok="true" notes="" cur gen_now kcls rb_rc=0
    echo "  ERROR: ${why} — rolling back to the previous state (intent ${_MT_PREV})." >&2
    _nftban_mtxn_log "ERROR" "txn ${_MT_ID}: ${why}; rolling back"
    _nftban_mtxn_phase "ROLLING_BACK" || _MT_RECORD_OK="false"
    # A failed forward reconcile normally aborts its own convergence
    # transaction; if one is still open, discard its staged records first so the
    # rollback reconcile opens (and commits) a transaction of its own.
    if [[ -n "${NFTBAN_PLAN_TARGET_GENERATION:-}" ]]; then
        nftban_plan_txn_abort
    fi

    cur="$(_nftban_mtxn_intent)"
    if [[ "$cur" != "$_MT_PREV" ]]; then
        if ! nftban_module_set_enabled "$_MT_MOD" "$_MT_PREV"; then
            ok="false"; notes="${notes}restoring intent=${_MT_PREV} FAILED; "
        fi
        cur="$(_nftban_mtxn_intent)"
        if [[ "$cur" != "$_MT_PREV" ]]; then
            ok="false"; notes="${notes}intent resolves ${cur}, previous was ${_MT_PREV}; "
        fi
    fi
    [[ "$cur" == "true" || "$cur" == "false" ]] && _nftban_mtxn_set_intent_var "$cur"

    gen_now="$(nftban_plan_generation_current)"
    _nftban_mtxn_observe
    kcls="$NFTBAN_MTXN_KCLASS"
    if [[ "$ok" == "true" ]] \
       && [[ "$gen_now" != "$_MT_GEN_BEFORE" || "$kcls" != "$_MT_PRE_KCLASS" ]]; then
        if [[ "$kcls" == "UNMEASURED" ]]; then
            ok="false"; notes="${notes}kernel unobservable (${NFTBAN_MTXN_KDETAIL}) — not re-reconciling blind; "
        else
            # Re-establish through THE reconcile root, now resolving the restored
            # intent. Never a hand-rolled undo.
            _nftban_mtxn_reconcile || rb_rc=$?
            if (( rb_rc != 0 )); then
                ok="false"; notes="${notes}rollback reconcile FAILED (rc=${rb_rc}); "
            fi
            gen_now="$(nftban_plan_generation_current)"
            _nftban_mtxn_observe
            kcls="$NFTBAN_MTXN_KCLASS"
        fi
    fi

    # VERIFY. Nothing below is assumed from the steps above having returned 0.
    if [[ "$ok" == "true" ]]; then
        if [[ "$kcls" == "UNMEASURED" || "$_MT_PRE_KCLASS" == "UNMEASURED" ]]; then
            ok="false"; notes="${notes}kernel state not measurable (before=${_MT_PRE_KCLASS} now=${kcls}: ${NFTBAN_MTXN_KDETAIL}); "
        elif [[ "$kcls" != "$_MT_PRE_KCLASS" ]]; then
            ok="false"; notes="${notes}kernel is ${kcls}, previously ${_MT_PRE_KCLASS} (${NFTBAN_MTXN_KDETAIL}); "
        fi
    fi
    if [[ "$ok" == "true" && "$gen_now" != "$_MT_GEN_BEFORE" ]]; then
        if ! _nftban_mtxn_read_plan "$gen_now"; then
            ok="false"; notes="${notes}plan generation ${gen_now} has no valid record; "
        elif [[ "$_MT_PLAN_ENABLED" != "$_MT_PREV" ]]; then
            ok="false"; notes="${notes}plan generation ${gen_now} says enabled=${_MT_PLAN_ENABLED}; "
        elif [[ "$_MT_PREV" == "false" && "$_MT_PLAN_EFF" != "inactive" ]] \
          || [[ "$_MT_PREV" == "true" && "$_MT_PLAN_EFF" != "$_MT_PRE_EFFECTIVE" ]]; then
            ok="false"; notes="${notes}plan generation ${gen_now} effective=${_MT_PLAN_EFF}, previously ${_MT_PRE_EFFECTIVE}; "
        fi
    fi

    if [[ "$ok" == "true" ]]; then
        _MT_STAGE="FAILED_ROLLED_BACK"
        _MT_REASON="${why}; previous state re-established and verified (intent=${_MT_PREV}, plan generation ${gen_now}, kernel ${kcls}: ${NFTBAN_MTXN_KDETAIL})"
        _nftban_mtxn_phase "ROLLED_BACK" || _MT_RECORD_OK="false"
    else
        _MT_STAGE="DEGRADED"
        _MT_REASON="${why}; rollback NOT verified: ${notes% }"
        _nftban_mtxn_phase "ROLLBACK_UNVERIFIED" || _MT_RECORD_OK="false"
    fi
    return 0
}

# _nftban_mtxn_locked — steps 2-6. Runs with the canonical lock held.
# Sets _MT_STAGE to RECONCILED (continue) or to a terminal outcome.
_nftban_mtxn_locked() {
    local rrc=0 expect
    _MT_STAGE="REFUSED"

    # Inputs the observation and the pre-snapshot need. The reconcile root calls
    # the same loaders; this adds no system mutation.
    if ! "_nftban_${_MT_MOD}_txn_prepare"; then
        _MT_REASON="${_MT_MOD} mode modules failed to load — nothing was changed"
        return 0
    fi
    _MT_PREV="$(_nftban_mtxn_intent)"
    if [[ "$_MT_PREV" != "true" && "$_MT_PREV" != "false" ]]; then
        _MT_REASON="the current intent could not be resolved — nothing was changed"
        return 0
    fi
    _MT_GEN_BEFORE="$(nftban_plan_generation_current)"
    if [[ "$_MT_PREV" == "true" ]]; then
        eval "$(nftban_module_report_modes "$_MT_MOD")"
        _MT_PRE_EFFECTIVE="${NFTBAN_REPORT_EFFECTIVE_MODE:-unknown}"
    else
        _MT_PRE_EFFECTIVE="inactive"
    fi
    _nftban_mtxn_observe
    _MT_PRE_KCLASS="$NFTBAN_MTXN_KCLASS"

    # STEP 2 — the record exists BEFORE anything is mutated.
    _MT_PHASE="OPEN"
    if ! _nftban_mtxn_record; then
        _MT_REASON="the transaction record could not be written to $(nftban_mtxn_record_path "$_MT_MOD") — nothing was changed"
        # The write may have landed even though it reported failure. Mark the
        # record as ours so the terminal write closes it: an OPEN record must
        # never outlive a transaction that ended.
        _MT_OPENED="true"
        return 0
    fi
    _MT_OPENED="true"
    echo "  Transaction ${_MT_ID}: ${_MT_OP} (intent ${_MT_PREV} -> ${_MT_WANT})"

    # STEP 3 — persist the requested intent, then prove it resolves.
    if ! nftban_module_set_enabled "$_MT_MOD" "$_MT_WANT"; then
        _nftban_mtxn_rollback "persisting intent=${_MT_WANT} failed"
        return 0
    fi
    if [[ "$(_nftban_mtxn_intent)" != "$_MT_WANT" ]]; then
        _nftban_mtxn_rollback "intent=${_MT_WANT} was written but does not resolve as the effective intent"
        return 0
    fi
    _nftban_mtxn_set_intent_var "$_MT_WANT"
    _nftban_mtxn_phase "INTENT_PERSISTED" || _MT_RECORD_OK="false"

    # STEP 4 — THE reconcile root, against the saved intent, joining our lock.
    _nftban_mtxn_reconcile || rrc=$?
    if (( rrc != 0 )); then
        _nftban_mtxn_rollback "reconcile against the saved intent failed (rc=${rrc})"
        return 0
    fi

    # STEP 5 — postconditions that are safe to inspect under the lock.
    _MT_GEN_AFTER="$(nftban_plan_generation_current)"
    if [[ ! "$_MT_GEN_AFTER" =~ ^[0-9]+$ || ! "$_MT_GEN_BEFORE" =~ ^[0-9]+$ ]] \
       || (( _MT_GEN_AFTER <= _MT_GEN_BEFORE )); then
        _nftban_mtxn_rollback "reconcile returned 0 but committed no new plan generation (before=${_MT_GEN_BEFORE} after=${_MT_GEN_AFTER})"
        return 0
    fi
    if ! _nftban_mtxn_read_plan "$_MT_GEN_AFTER"; then
        _nftban_mtxn_rollback "the committed plan record for generation ${_MT_GEN_AFTER} is missing or malformed"
        return 0
    fi
    if [[ "$_MT_PLAN_ENABLED" != "$_MT_WANT" ]] \
       || [[ "$_MT_WANT" == "false" && "$_MT_PLAN_EFF" != "inactive" ]] \
       || [[ "$_MT_WANT" == "true" && "$_MT_PLAN_EFF" != "classic" && "$_MT_PLAN_EFF" != "suricata" ]]; then
        _nftban_mtxn_rollback "the committed plan (enabled=${_MT_PLAN_ENABLED}, effective=${_MT_PLAN_EFF}) contradicts intent=${_MT_WANT}"
        return 0
    fi
    _MT_EFFECTIVE="$_MT_PLAN_EFF"
    expect="$(_nftban_mtxn_expect "$_MT_EFFECTIVE")"
    _nftban_mtxn_observe
    if [[ "$NFTBAN_MTXN_KCLASS" == "UNMEASURED" ]]; then
        # L3: we cannot tell whether the kernel converged. Rolling back blind
        # could make it worse, so the state is reported, not guessed.
        _MT_STAGE="DEGRADED"
        _MT_REASON="kernel postcondition UNMEASURED after reconcile (${NFTBAN_MTXN_KDETAIL}); intent=${_MT_WANT} and plan generation ${_MT_GEN_AFTER} (effective=${_MT_EFFECTIVE}) are committed, the kernel state is NOT proven"
        _nftban_mtxn_phase "RECONCILE_UNVERIFIED" || _MT_RECORD_OK="false"
        return 0
    fi
    if ! _nftban_mtxn_kclass_ok "$expect" "$NFTBAN_MTXN_KCLASS"; then
        _nftban_mtxn_rollback "kernel postcondition failed: expected ${expect}, observed ${NFTBAN_MTXN_KCLASS} (${NFTBAN_MTXN_KDETAIL})"
        return 0
    fi
    _MT_KDETAIL="$NFTBAN_MTXN_KDETAIL"

    # STEP 6
    _nftban_mtxn_phase "RECONCILED" || _MT_RECORD_OK="false"
    _MT_STAGE="RECONCILED"
    return 0
}

# _nftban_mtxn_lifecycle — steps 8-10 (enable only), OUTSIDE the lock.
# The restart is lifecycle evidence only: it is never what makes the requested
# state true, and a restart exit code is never a verdict on enforcement.
_nftban_mtxn_lifecycle() {
    local i ready="false" expect gen_now
    if ! systemctl is-active --quiet nftband 2>/dev/null; then
        _MT_STAGE="DEGRADED"
        _MT_REASON="kernel rules verified (${_MT_KDETAIL}), but nftband is not running — ${_MT_WHAT} is NOT active. Start it: systemctl start nftband"
        return 0
    fi
    echo "  Restarting nftband daemon (lifecycle action)..."
    _nftban_mtxn_phase "LIFECYCLE" || _MT_RECORD_OK="false"
    if ! systemctl restart nftband; then
        _MT_STAGE="DEGRADED"
        _MT_REASON="kernel rules verified (${_MT_KDETAIL}), but the nftband restart FAILED — ${_MT_WHAT} is not running on the new intent. Run: systemctl restart nftband"
        return 0
    fi
    # STEP 9 — bounded readiness: the unit is active AND the IPC socket answers.
    for (( i = 0; i < 30; i++ )); do
        if systemctl is-active --quiet nftband 2>/dev/null \
           && declare -F nft_ipc_is_daemon_running >/dev/null 2>&1 \
           && nft_ipc_is_daemon_running; then
            ready="true"; break
        fi
        sleep 1
    done
    if [[ "$ready" != "true" ]]; then
        _MT_STAGE="PENDING_TIMED_OUT"
        _MT_REASON="kernel rules verified, nftband restarted, but the daemon was not ready within 30s (unit active + IPC ping) — ${_MT_WHAT} readiness is UNPROVEN"
        return 0
    fi
    # STEP 10 — the daemon's own start-up reconcile must agree with us.
    for (( i = 0; i < 5; i++ )); do
        eval "$(nftban_module_report_modes "$_MT_MOD")"
        [[ "${NFTBAN_REPORT_EFFECTIVE_BASIS:-}" != "convergence_in_progress" ]] && break
        sleep 1
    done
    if [[ "${NFTBAN_REPORT_EFFECTIVE_MODE:-}" != "$_MT_EFFECTIVE" \
          || "${NFTBAN_REPORT_EFFECTIVE_BASIS:-}" != "current_plan" ]]; then
        _MT_STAGE="DEGRADED"
        _MT_REASON="after the restart the committed plan reports effective=${NFTBAN_REPORT_EFFECTIVE_MODE:-?} (${NFTBAN_REPORT_EFFECTIVE_BASIS:-?}), contradicting this transaction's ${_MT_EFFECTIVE}"
        return 0
    fi
    gen_now="$(nftban_plan_generation_current)"
    if [[ ! "$gen_now" =~ ^[0-9]+$ ]] || (( gen_now < _MT_GEN_AFTER )); then
        _MT_STAGE="DEGRADED"
        _MT_REASON="after the restart the convergence generation is ${gen_now}, older than this transaction's ${_MT_GEN_AFTER}"
        return 0
    fi
    expect="$(_nftban_mtxn_expect "$_MT_EFFECTIVE")"
    _nftban_mtxn_observe
    if [[ "$NFTBAN_MTXN_KCLASS" == "UNMEASURED" ]]; then
        _MT_STAGE="DEGRADED"
        _MT_REASON="after the restart the kernel is UNMEASURED (${NFTBAN_MTXN_KDETAIL}) — the enforcement state is not proven"
        return 0
    fi
    if ! _nftban_mtxn_kclass_ok "$expect" "$NFTBAN_MTXN_KCLASS"; then
        _MT_STAGE="DEGRADED"
        _MT_REASON="after the restart the kernel is ${NFTBAN_MTXN_KCLASS} (${NFTBAN_MTXN_KDETAIL}), contradicting the converged ${expect}"
        return 0
    fi
    _MT_STAGE="CONVERGED"
    _MT_REASON="intent=true; plan generation ${gen_now} effective=${_MT_EFFECTIVE}; kernel ${NFTBAN_MTXN_KCLASS} (${NFTBAN_MTXN_KDETAIL}); nftband ready"
    return 0
}

# _nftban_mtxn_finish <OUTCOME> <reason> — STEP 11. The ONLY place a verdict is
# printed and the ONLY source of the exit code.
_nftban_mtxn_finish() {
    local outcome="$1" reason="$2" rc
    if [[ "$outcome" == "CONVERGED" && "$_MT_RECORD_OK" != "true" ]]; then
        outcome="DEGRADED"
        reason="${reason}; the transaction record could not be kept current — interruption visibility was lost"
    fi
    if [[ "$_MT_OPENED" == "true" ]]; then
        _MT_OUTCOME="$outcome"; _MT_REASON="$reason"; _MT_PHASE="CLOSED"
        if ! _nftban_mtxn_record && [[ "$outcome" == "CONVERGED" ]]; then
            # A success that cannot be recorded is not a success. Downgrade, and
            # try once more so the record and the printed verdict agree.
            outcome="DEGRADED"
            reason="${reason}; the terminal transaction record could not be written"
            _MT_OUTCOME="$outcome"; _MT_REASON="$reason"
            _nftban_mtxn_record || reason="${reason} (retry failed too)"
        fi
    fi
    case "$outcome" in
        CONVERGED)          rc=0 ;;
        FAILED_ROLLED_BACK) rc=1 ;;
        DEGRADED)           rc=3 ;;
        PENDING_TIMED_OUT)  rc=4 ;;
        REFUSED)            rc="${_MT_REFUSE_RC:-5}" ;;
        *)                  outcome="DEGRADED"; rc=3; reason="unrecognised outcome; ${reason}" ;;
    esac

    local want_word="enabled"
    [[ "$_MT_WANT" == "false" ]] && want_word="disabled"
    echo ""
    case "$outcome" in
        CONVERGED)
            if [[ "$_MT_OP" == "enable" ]]; then
                echo "╔══════════════════════════════════════════════════════════╗"
                echo "║  ✅ ${_MT_TITLE} ENABLED (${_MT_EFFECTIVE^^})"
                echo "╚══════════════════════════════════════════════════════════╝"
            else
                echo "  ✅ ${_MT_LOWER} DISABLED — module rules verified absent/empty in the kernel"
            fi
            echo "  Verified: ${reason}"
            ;;
        FAILED_ROLLED_BACK)
            echo "  ❌ ${_MT_NAME} ${_MT_OP} FAILED — nothing changed: the previous state was restored and verified."
            echo "     Reason: ${reason}"
            ;;
        DEGRADED)
            echo "  ⚠️  ${_MT_NAME} ${_MT_OP} DEGRADED — the requested state (${want_word}) is NOT proven."
            echo "     Reason: ${reason}"
            if declare -F "_nftban_${_MT_MOD}_txn_status_lines" >/dev/null 2>&1; then
                echo "     'nftban ${_MT_MOD} status' shows this transaction (${_MT_ID})."
            else
                echo "     Transaction record: $(nftban_mtxn_record_path "$_MT_MOD") (${_MT_ID})."
            fi
            ;;
        PENDING_TIMED_OUT)
            echo "  ⏳ ${_MT_NAME} ${_MT_OP} PENDING — convergence was not confirmed in time."
            echo "     Reason: ${reason}"
            ;;
        REFUSED)
            echo "  ❌ ${_MT_NAME} ${_MT_OP} REFUSED — nothing was changed."
            echo "     Reason: ${reason}"
            ;;
    esac
    echo ""
    printf 'NFTBAN_OUTCOME=%s module=%s op=%s txn=%s rc=%s reason=%s\n' \
        "$outcome" "$_MT_MOD" "$_MT_OP" "${_MT_ID:-none}" "$rc" "${reason//$'\n'/ }"
    _nftban_mtxn_log "INFO" "txn ${_MT_ID:-none} ${_MT_OP}: ${outcome} rc=${rc} (${reason})"
    return "$rc"
}

# nftban_module_txn <module> <enable|disable> — the whole transaction.
nftban_module_txn() {
    local mod="${1:-}" op="${2:-}" lockfd=""
    _nftban_mtxn_reset "$mod"
    _MT_OP="$op"
    if declare -F "_nftban_${mod}_txn_labels" >/dev/null 2>&1; then
        "_nftban_${mod}_txn_labels"
    fi
    case "$op" in
        enable)  _MT_WANT="true" ;;
        disable) _MT_WANT="false" ;;
        *) echo "  ERROR: unknown ${mod} transaction '${op}'" >&2; return 2 ;;
    esac
    _MT_ID="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || _MT_ID=""
    [[ -n "$_MT_ID" ]] || _MT_ID="txn-$$-$(date +%s)"
    _MT_STARTED="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    local fn
    for fn in nftban_module_set_enabled nftban_module_effective_enabled \
              nftban_module_report_modes nftban_plan_generation_current \
              nftban_plan_record_path _nftban_plan_lock_acquire _nftban_plan_lock_release \
              _nftban_module_enable_var \
              "nftban_${mod}_reconcile" "_nftban_${mod}_txn_prepare" \
              "_nftban_${mod}_kernel_observe" "_nftban_${mod}_expected_kclass" \
              "_nftban_${mod}_txn_record_write"; do
        if ! declare -F "$fn" >/dev/null 2>&1; then
            _nftban_mtxn_finish "REFUSED" "module authority unavailable (${fn} is not loaded)"
            return $?
        fi
    done
    if [[ -n "${NFTBAN_PLAN_TARGET_GENERATION:-}" ]]; then
        _nftban_mtxn_finish "REFUSED" "a convergence transaction is already open in this process tree (target ${NFTBAN_PLAN_TARGET_GENERATION})"
        return $?
    fi
    if [[ ! -d "${NFTBAN_PLAN_RECORD_DIR:-/run/nftban}" ]]; then
        _nftban_mtxn_finish "REFUSED" "runtime directory ${NFTBAN_PLAN_RECORD_DIR:-/run/nftban} is absent (owned by systemd-tmpfiles: systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf)"
        return $?
    fi

    # STEP 1 — the canonical lock. Direct call (never $(...)): a lock taken in
    # a subshell is released when the subshell exits.
    if ! _nftban_plan_lock_acquire; then
        _MT_REFUSE_RC=7
        _nftban_mtxn_finish "REFUSED" "the convergence lock is held by another nft operation"
        return $?
    fi
    lockfd="${NFTBAN_PLAN_TXN_LOCKFD:-}"
    unset NFTBAN_PLAN_TXN_LOCKFD

    _nftban_mtxn_locked

    # STEP 7 — release (a no-op when an ancestor holds the lock and we joined).
    _nftban_plan_lock_release "$lockfd"

    if [[ "$_MT_STAGE" != "RECONCILED" ]]; then
        _nftban_mtxn_finish "$_MT_STAGE" "$_MT_REASON"
        return $?
    fi
    if [[ "$op" == "enable" ]]; then
        _nftban_mtxn_lifecycle
    else
        # Disable needs no lifecycle action: the kernel is verified, and the
        # running daemon consults the saved intent.
        _MT_STAGE="CONVERGED"
        _MT_REASON="intent=false; plan generation ${_MT_GEN_AFTER} effective=${_MT_EFFECTIVE}; kernel $(_nftban_mtxn_expect "$_MT_EFFECTIVE") (${_MT_KDETAIL})"
    fi
    _nftban_mtxn_finish "$_MT_STAGE" "$_MT_REASON"
    return $?
}

# nftban_mtxn_status_lines <module> — report the runtime transaction record.
# Sets NFTBAN_MTXN_UNSETTLED=true when the record shows a transaction that is
# OPEN (in progress or interrupted) in this boot, or whose terminal outcome is
# DEGRADED / PENDING_TIMED_OUT. Read-only: it never takes the convergence lock.
# shellcheck disable=SC2034  # NFTBAN_MTXN_UNSETTLED is read by the module status callers
nftban_mtxn_status_lines() {
    local mod="${1:-}" rec line k v r_id="" r_op="" r_phase="" r_out="" r_pid="" r_boot=""
    local r_started="" r_reason="" boot="" state
    NFTBAN_MTXN_UNSETTLED="false"
    rec="$(nftban_mtxn_record_path "$mod")"
    [[ -r "$rec" ]] || return 0
    while IFS= read -r line; do
        k="${line%%=*}"; v="${line#*=}"
        case "$k" in
            NFTBAN_TXN_ID)         r_id="$v" ;;
            NFTBAN_TXN_OP)         r_op="$v" ;;
            NFTBAN_TXN_PHASE)      r_phase="$v" ;;
            NFTBAN_TXN_OUTCOME)    r_out="$v" ;;
            NFTBAN_TXN_PID)        r_pid="$v" ;;
            NFTBAN_TXN_BOOT_ID)    r_boot="$v" ;;
            NFTBAN_TXN_STARTED_AT) r_started="$v" ;;
            NFTBAN_TXN_REASON)     r_reason="$v" ;;
        esac
    done < "$rec"
    if [[ -r /proc/sys/kernel/random/boot_id ]]; then
        read -r boot < /proc/sys/kernel/random/boot_id || boot=""
    fi
    # /run does not survive a reboot; a record from another boot is not ours.
    if [[ -n "$boot" && -n "$r_boot" && "$boot" != "$r_boot" ]]; then
        return 0
    fi
    if [[ "$r_phase" != "CLOSED" ]]; then
        state="INTERRUPTED"
        if [[ "$r_pid" =~ ^[0-9]+$ ]] && kill -0 "$r_pid" 2>/dev/null; then state="IN PROGRESS"; fi
        NFTBAN_MTXN_UNSETTLED="true"
        echo "  Transaction: ⚠️  ${state} — ${mod} ${r_op:-?} ${r_id:-?} (started ${r_started:-?}, pid ${r_pid:-?}, phase ${r_phase:-?})"
        echo "               Intent, plan and kernel may disagree until it is re-run: nftban ${mod} ${r_op:-enable|disable}"
        echo ""
        return 0
    fi
    case "$r_out" in
        DEGRADED|PENDING_TIMED_OUT)
            NFTBAN_MTXN_UNSETTLED="true"
            echo "  Transaction: ⚠️  last ${mod} ${r_op:-?} ended ${r_out} (${r_id:-?})"
            echo "               ${r_reason}"
            echo ""
            ;;
    esac
    return 0
}
