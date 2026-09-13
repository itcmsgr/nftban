#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.225.0 PR-A: update DEGRADED render truth (E1a + E1b)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="update_degraded_render_truth_v225_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-07-22"
# meta:description="Regression guard for v1.225.0 PR-A. E1a (BUG-V1_222_1-UPDATE-STATEFILE-GREP-UNGUARDED): _render_degraded_failed_units must NOT abort under set -Eeuo pipefail when SERVICES_FAILED is ABSENT from a readable DEGRADED install_state (grep rc=1 = key absent, not a read error), and must not fabricate success on a missing/unreadable file. E1b (BUG-V1_222_1-UPDATE-DEGRADED-ALL-UNITS-FILTERED-NO-HINT): a non-empty raw SERVICES_FAILED whose tokens are all non-canonical must still print a truthful 'recorded-but-all-filtered' hint distinct from the 'no list recorded' fallback; canonical units render; no false-health claims. Hermetic: sources cmd_update.sh, drives the helper with temp fixtures, no root/systemd/network/real state. v1.230.0 P0-D2 (RELEASE BLOCKER) adds the update terminal verdict itself: _update_finalize_verdict must authorise the success verdict, the update-history \"success\" row and the deletion of state/update_failed ONLY on a positively asserted INSTALL_STATE=COMMITTED. The pre-v1.230.0 case dispatched on the raw literal with a FAILED_*|FAILED glob that anchors at the start, so INSTALL_FAILED fell to the catch-all green arm which recorded a failed update as successful and deleted its failure marker; an absent/unreadable state file defaulted to COMMITTED and took the same arm. The cases assert FILESYSTEM EFFECTS (the status actually written into update-history.json, and whether state/update_failed survives) for COMMITTED, FAILED_REBUILD, INSTALL_FAILED, an INVENTED literal, a missing file and a file with no INSTALL_STATE key, plus a declared-inversion negative control that reproduces the pre-fix mutations. Hermetic: throwaway NFTBAN_DATA_DIR per case, no root/systemd/network/real state."
# meta:inventory.files="cli/lib/nftban/cli/cmd_update.sh"
# meta:inventory.binaries="bash,grep,cut"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# meta:ta.id="update_degraded_render_truth_v225_test"
# meta:ta.owner="update"
# meta:ta.module="update"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="policy-gates"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
CMD_UPDATE="$REPO_ROOT/cli/lib/nftban/cli/cmd_update.sh"

PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ✓ $1"; }
no(){ FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

echo "v1.225.0 PR-A update DEGRADED render truth (E1a+E1b):"

# v1.230.0 P0-D2: point NFTBAN_LIB_DIR at the repo tree BEFORE the single source.
# cmd_update.sh carries a readonly double-load guard (NFTBAN_CLI_UPDATE_LOADED), so
# it can only be sourced once per process — the P0-D2 section at the end of this
# file drives the update verdict, which needs cmd_update_helpers.sh
# (_update_write_history) and core/nftban_output.sh (the shared install-state
# authority) resolvable from that one load. The E1a/E1b cases below are unaffected:
# they exercise a helper defined in cmd_update.sh itself.
export NFTBAN_LIB_DIR="$REPO_ROOT/cli/lib/nftban"

# Source only the function (definitions only; the file auto-runs nothing when sourced).
# shellcheck disable=SC1090
if ! source "$CMD_UPDATE" 2>/dev/null; then :; fi
if ! declare -F _render_degraded_failed_units >/dev/null; then
    no "_render_degraded_failed_units is defined after sourcing cmd_update.sh" "not found"
    echo "RESULT: $PASS passed, $FAIL failed"; exit 1
fi
ok "_render_degraded_failed_units defined after sourcing cmd_update.sh"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# render <state-body...>  → writes fixture, runs helper under strict mode, captures out/rc/err
run_render() {
    local body=$1 sf="$TMP/state"
    printf '%s' "$body" > "$sf"
    local out rc err
    err="$TMP/err"
    set +e
    out=$( set -Eeuo pipefail; _render_degraded_failed_units "$sf" 2>"$err" ); rc=$?
    set -e
    LAST_OUT="$out"; LAST_RC=$rc; LAST_ERR="$(cat "$err")"
}
no_false_health() { # assert output makes no false-health / recovery claim
    if echo "$LAST_OUT" | grep -qiE "no failed units|all services healthy|state recovered|recovered\b|healthy"; then
        no "$1 makes no false-health claim" "found health claim"
    else ok "$1 makes no false-health claim"; fi
}

# ---- E1a: strict-mode abort must be prevented ----
# A. key present, canonical value
run_render $'INSTALL_STATE=DEGRADED\nSERVICES_FAILED=nftban-botscan.service\n'
{ [[ $LAST_RC -eq 0 ]] && echo "$LAST_OUT" | grep -q "Failed unit: nftban-botscan.service"; } \
  && ok "E1a-A present canonical → rc0 + unit rendered" || no "E1a-A present canonical" "rc=$LAST_RC"

# B. key present, empty value
run_render $'INSTALL_STATE=DEGRADED\nSERVICES_FAILED=\n'
{ [[ $LAST_RC -eq 0 ]] && echo "$LAST_OUT" | grep -q "structured failed-unit list unavailable"; } \
  && ok "E1a-B present-empty → rc0 + no-list fallback" || no "E1a-B present-empty" "rc=$LAST_RC out=[$LAST_OUT]"

# C. key ABSENT (the strict-mode abort bug) — must NOT abort
# (missing/unreadable-file cases are UNREACHABLE in this renderer — INSTALL_STATE defaults to
#  COMMITTED upstream on any unreadable/missing file — so they are intentionally NOT tested here.)
run_render $'INSTALL_STATE=DEGRADED\nFAILURE_REASON=resource policy\n'
{ [[ $LAST_RC -eq 0 ]] && echo "$LAST_OUT" | grep -q "structured failed-unit list unavailable"; } \
  && ok "E1a-C absent-key → NO strict-mode abort (rc0) + fallback" || no "E1a-C absent-key strict abort" "rc=$LAST_RC"

# absent key must never invent a Failed-unit line
run_render $'INSTALL_STATE=DEGRADED\nFAILURE_REASON=resource policy\n'
echo "$LAST_OUT" | grep -q "Failed unit:" && no "E1a absent-key never invents a unit line" "invented unit" \
  || ok "E1a absent-key never invents a Failed-unit line"

# stderr clean on the benign absent-key path
run_render $'INSTALL_STATE=DEGRADED\n'
[[ -z "$LAST_ERR" ]] && ok "E1a absent-key emits no stderr noise" || no "E1a stderr clean" "err=[$LAST_ERR]"

# ---- E1b: filtered-units hint ----
# canonical single
run_render $'SERVICES_FAILED=nftban-health.service\n'
echo "$LAST_OUT" | grep -q "Failed unit: nftban-health.service" \
  && ok "E1b canonical single rendered" || no "E1b canonical single"

# canonical multiple
run_render $'SERVICES_FAILED=nftban-health.service,nftban-maintenance.timer\n'
{ echo "$LAST_OUT" | grep -q "nftban-health.service" && echo "$LAST_OUT" | grep -q "nftban-maintenance.timer"; } \
  && ok "E1b multiple canonical rendered" || no "E1b multiple canonical"

# mixed canonical / non-canonical → only canonical rendered, no filtered-hint (>=1 rendered)
run_render $'SERVICES_FAILED=nftban-health.service,evil;rm -rf,notaunit\n'
{ echo "$LAST_OUT" | grep -q "Failed unit: nftban-health.service" \
  && ! echo "$LAST_OUT" | grep -q "evil" \
  && ! echo "$LAST_OUT" | grep -q "remained after filtering"; } \
  && ok "E1b mixed → only canonical rendered, no filtered-hint" || no "E1b mixed"

# ALL non-canonical → the E1b truthful 'recorded-but-all-filtered' hint (distinct from no-list)
run_render $'INSTALL_STATE=DEGRADED\nSERVICES_FAILED=sshd.service,foo.bar,notaunit\n'
{ [[ $LAST_RC -eq 0 ]] && echo "$LAST_OUT" | grep -q "remained after filtering" \
  && ! echo "$LAST_OUT" | grep -q "Failed unit:"; } \
  && ok "E1b all-filtered → truthful 'recorded but all filtered' hint" || no "E1b all-filtered hint" "out=[$LAST_OUT]"
no_false_health "E1b all-filtered"

# the all-filtered hint is DISTINCT from the no-list fallback
run_render $'SERVICES_FAILED=onlyjunk\n'; ALLFILT="$LAST_OUT"
run_render $'SERVICES_FAILED=\n'; NOLIST="$LAST_OUT"
[[ "$ALLFILT" != "$NOLIST" ]] && ok "E1b all-filtered hint distinct from no-list fallback" || no "E1b hint distinctness"

# whitespace-only field → deterministic (non-empty → all-filtered hint), rc0
run_render $'SERVICES_FAILED=   \n'
[[ $LAST_RC -eq 0 ]] && ok "E1b whitespace-only field → deterministic rc0" || no "E1b whitespace-only" "rc=$LAST_RC"

# =============================================================================
# v1.230.0 P0-D2 — THE UPDATE VERDICT MUST NOT MUTATE STATE ON A NON-COMMITTED
# TRANSACTION  (RELEASE BLOCKER)
# =============================================================================
# Subject: _update_finalize_verdict in cli/cmd_update.sh.
#
# THE DEFECT. The pre-v1.230.0 verdict dispatched on the raw install_state
# literal with the arms COMMITTED) / DEGRADED) / FAILED_*|FAILED) / *). The glob
# anchors at the START of the literal, so INSTALL_FAILED did NOT match it and
# reached `*)`, which logged "falling back to legacy green verdict" and then
#
#     _update_write_history … "success"                       <- records a FAILED
#     rm -f "${NFTBAN_DATA_DIR}/state/update_failed"              update as SUCCESSFUL
#                                                                 and DELETES the
#                                                                 failure marker
#
# The acquisition above it also defaulted _installer_state to COMMITTED when the
# state file was absent or unreadable, so "I could not read the outcome" took the
# same green arm. Every literal not prefixed FAILED_ — INSTALL_FAILED, the
# RESTORE_*/UNINSTALL_* terminals, the intermediate FILES_INSTALLED /
# SWITCH_COMPLETE literals a killed installer leaves behind, and any literal a
# future Go release adds — inherited it.
#
# ⛔ THESE ASSERT FILESYSTEM EFFECTS, NOT EXIT CODES OR PRINTED TEXT: the status
#    actually written into update-history.json, and whether state/update_failed
#    still exists afterwards. A verdict that merely PRINTS "failed" while still
#    recording success would pass a text assertion and fail these.
#
# NEGATIVE CONTROL: the same four fixtures run against the verbatim pre-fix block
# at immutable SHA 9162f2a0 produce RC=0 / marker DELETED / history "success" for
# INSTALL_FAILED, for an invented literal, and for a missing state file.
# =============================================================================
echo ""
echo "v1.230.0 P0-D2 update verdict — filesystem effects:"

# Every function these cases need must be resolvable from the single source at the
# top of this file, or the cases below would prove nothing.
for _fn in _update_finalize_verdict _update_write_history nftban_install_state_classify nftban_install_state_field; do
    if declare -F "$_fn" >/dev/null; then
        ok "$_fn resolvable for the verdict cases"
    else
        no "$_fn resolvable for the verdict cases" "not found — the cases below would prove nothing"
        echo "RESULT: $PASS passed, $FAIL failed"; exit 1
    fi
done

# p0_run <state-body|-> ; sets P0_RC / P0_MARKER / P0_HISTORY_STATUS / P0_SUCCESS_ROWS
# Runs in a SUBSHELL against a throwaway NFTBAN_DATA_DIR so nothing here can touch
# the real /var/lib/nftban and the stubs cannot leak into the cases above.
p0_run() {
    local body="$1" sb res
    sb="$(mktemp -d "$TMP/p0.XXXXXX")"
    mkdir -p "$sb/state"
    # PRE-STATE: a failure marker exists and the newest history row is a failure.
    # If the verdict wrongly takes the success arm it must visibly destroy both.
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$sb/state/update_failed"
    printf '[{"timestamp":"2026-01-01T00:00:00Z","from":"1.0.0","to":"1.0.1","status":"install_fail","type":"rpm","duration_s":1,"host":"h"}]\n' \
        > "$sb/update-history.json"
    [[ "$body" == "-" ]] || printf '%b' "$body" > "$sb/state/install_state"

    res=$(
        set +e
        export NFTBAN_DATA_DIR="$sb"
        _install_state_file="$sb/state/install_state"
        _installer_state=""
        [[ -r "$_install_state_file" ]] && \
            _installer_state=$(nftban_install_state_field "$_install_state_file" INSTALL_STATE)
        current_version="1.229.14"; new_version="1.230.0"; install_type="rpm"
        # These stand in for locals of _cmd_update_main_locked. The verdict function
        # reads them through bash DYNAMIC SCOPING, which shellcheck cannot follow.
        # shellcheck disable=SC2034
        { _update_duration=7; _summary_warnings=0; health_status=0
          _ilog_file="$sb/installer.log"; : > "$_ilog_file"; _ilog_before_lines=0
          UPDATE_LOG_FILE="$sb/update.log"; _NFTBAN_WARN_REAL=0; FORENSIC_RUN_DIR=""; }
        _update_final_summary() { :; }
        _update_render_actionable_warnings() { :; }
        _update_log() { :; }
        _update_finalize_verdict >/dev/null 2>&1
        printf 'rc=%s' "$?"
    )
    P0_RC="${res#rc=}"
    P0_MARKER=absent; [[ -e "$sb/state/update_failed" ]] && P0_MARKER=present
    P0_HISTORY_STATUS=$(jq -r '.[0].status // "?"' "$sb/update-history.json" 2>/dev/null || echo "?")
    P0_SUCCESS_ROWS=$(jq -r '[.[] | select(.status == "success")] | length' "$sb/update-history.json" 2>/dev/null || echo "?")
    rm -rf "$sb"
}

# ---- A1 COMMITTED: the positive control. It MUST still record success and MUST
#      still clear the marker, or the fix has simply broken the success path.
p0_run 'INSTALL_STATE=COMMITTED\n'
[[ "$P0_RC" == "0" ]]                    && ok "A1 COMMITTED → rc 0"                                  || no "A1 COMMITTED rc" "rc=$P0_RC"
[[ "$P0_HISTORY_STATUS" == "success" ]]  && ok "A1 COMMITTED → history row written as success"        || no "A1 COMMITTED history" "status=$P0_HISTORY_STATUS"
[[ "$P0_MARKER" == "absent" ]]           && ok "A1 COMMITTED → state/update_failed cleared"           || no "A1 COMMITTED marker" "marker=$P0_MARKER"

# ---- A2 FAILED_REBUILD (the state measured on production host dns1) ----------
p0_run 'INSTALL_STATE=FAILED_REBUILD\nFAILURE_REASON=rebuild failed: ruleset rejected by the kernel (exit 1)\n'
[[ "$P0_RC" != "0" ]]                    && ok "A2 FAILED_REBUILD → non-zero rc (never success)"      || no "A2 FAILED_REBUILD rc" "rc=$P0_RC"
[[ "$P0_SUCCESS_ROWS" == "0" ]]          && ok "A2 FAILED_REBUILD → NO success row written"           || no "A2 FAILED_REBUILD history" "success rows=$P0_SUCCESS_ROWS"
[[ "$P0_MARKER" == "present" ]]          && ok "A2 FAILED_REBUILD → failure marker NOT deleted"       || no "A2 FAILED_REBUILD marker" "marker=$P0_MARKER"

# ---- A3 INSTALL_FAILED: the exact literal the FAILED_*|FAILED glob missed ----
p0_run 'INSTALL_STATE=INSTALL_FAILED\nINSTALL_TIMESTAMP=2026-09-08T10:00:00Z\nPHASE_REACHED=switch\n'
[[ "$P0_RC" != "0" ]]                    && ok "A3 INSTALL_FAILED → non-zero rc (never success)"      || no "A3 INSTALL_FAILED rc" "rc=$P0_RC"
[[ "$P0_HISTORY_STATUS" != "success" ]]  && ok "A3 INSTALL_FAILED → history NOT written as success"   || no "A3 INSTALL_FAILED history" "status=$P0_HISTORY_STATUS"
[[ "$P0_SUCCESS_ROWS" == "0" ]]          && ok "A3 INSTALL_FAILED → no success row anywhere in history" || no "A3 INSTALL_FAILED success rows" "rows=$P0_SUCCESS_ROWS"
[[ "$P0_MARKER" == "present" ]]          && ok "A3 INSTALL_FAILED → state/update_failed NOT deleted"  || no "A3 INSTALL_FAILED marker" "marker=$P0_MARKER"

# ---- A4 an INVENTED literal — the case a longer failure list cannot pass -----
# FUTURE_STATE_XYZ appears in no state source; only a POSITIVE assertion on
# COMMITTED can classify it correctly.
p0_run 'INSTALL_STATE=FUTURE_STATE_XYZ\n'
[[ "$P0_RC" != "0" ]]                    && ok "A4 invented literal → non-zero rc (never success)"    || no "A4 invented literal rc" "rc=$P0_RC"
[[ "$P0_SUCCESS_ROWS" == "0" ]]          && ok "A4 invented literal → NO success row written"         || no "A4 invented literal history" "rows=$P0_SUCCESS_ROWS"
[[ "$P0_MARKER" == "present" ]]          && ok "A4 invented literal → failure marker NOT deleted"     || no "A4 invented literal marker" "marker=$P0_MARKER"

# ---- A5 missing state file: the fail-open acquisition default ----------------
p0_run '-'
[[ "$P0_RC" != "0" ]]                    && ok "A5 missing install_state → non-zero rc (never success)" || no "A5 missing state rc" "rc=$P0_RC"
[[ "$P0_SUCCESS_ROWS" == "0" ]]          && ok "A5 missing install_state → NO success row written"      || no "A5 missing state history" "rows=$P0_SUCCESS_ROWS"
[[ "$P0_MARKER" == "present" ]]          && ok "A5 missing install_state → failure marker NOT deleted"  || no "A5 missing state marker" "marker=$P0_MARKER"
[[ "$P0_HISTORY_STATUS" == "indeterminate" ]] \
    && ok "A5 missing install_state → recorded as indeterminate, neither success nor a fabricated failure" \
    || no "A5 missing state history status" "status=$P0_HISTORY_STATUS"

# ---- A5b readable file with no INSTALL_STATE key -----------------------------
p0_run 'AUTHORITY=UPDATE\nCONFLICTS=\n'
[[ "$P0_SUCCESS_ROWS" == "0" ]]          && ok "A5b no INSTALL_STATE key → NO success row written"    || no "A5b no-key history" "rows=$P0_SUCCESS_ROWS"
[[ "$P0_MARKER" == "present" ]]          && ok "A5b no INSTALL_STATE key → failure marker NOT deleted" || no "A5b no-key marker" "marker=$P0_MARKER"

# ---- NEGATIVE CONTROL (declared inversion) -----------------------------------
# ⛔ The assertions above are only worth their green if they can go red. This
#    reconstructs the PRE-v1.230.0 DECISION — the FAILED_*|FAILED glob plus the
#    catch-all green arm carrying both mutations, and the fail-open COMMITTED
#    acquisition default — and drives THE SAME fixtures through it. The inverted
#    subject must record INSTALL_FAILED as a success and delete the failure
#    marker; if it does not, these assertions are not testing what they claim.
#
#    A declared inversion, not a checkout of the old file: origin/main stops being
#    "pre-fix" the moment the fix merges, and a shipped tree in CI has no pre-fix
#    copy to point at.
_p0_inverted_verdict() {          # verbatim pre-fix shape, mutations included
    local _st="COMMITTED"         # <- the fail-open acquisition default
    if [[ -f "$_install_state_file" ]]; then
        _st=$(grep -m1 '^INSTALL_STATE=' "$_install_state_file" 2>/dev/null | cut -d= -f2- || echo "COMMITTED")
    fi
    case "$_st" in
        COMMITTED)
            _update_write_history "$current_version" "$new_version" "success" "$install_type" "$_update_duration"
            rm -f "${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/update_failed" 2>/dev/null || true
            return 0 ;;
        DEGRADED)
            _update_write_history "$current_version" "$new_version" "verify_fail" "$install_type" "$_update_duration"
            return 1 ;;
        FAILED_*|FAILED)
            _update_write_history "$current_version" "$new_version" "install_fail" "$install_type" "$_update_duration"
            return 2 ;;
        *)                        # <- the legacy green fall-through
            _update_write_history "$current_version" "$new_version" "success" "$install_type" "$_update_duration"
            rm -f "${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/update_failed" 2>/dev/null || true
            return 0 ;;
    esac
}
p0_run_inverted() {
    local body="$1" sb res
    sb="$(mktemp -d "$TMP/p0inv.XXXXXX")"
    mkdir -p "$sb/state"
    date -u '+%Y-%m-%dT%H:%M:%SZ' > "$sb/state/update_failed"
    printf '[{"timestamp":"2026-01-01T00:00:00Z","from":"1.0.0","to":"1.0.1","status":"install_fail","type":"rpm","duration_s":1,"host":"h"}]\n' \
        > "$sb/update-history.json"
    [[ "$body" == "-" ]] || printf '%b' "$body" > "$sb/state/install_state"
    res=$(
        set +e
        export NFTBAN_DATA_DIR="$sb"
        _install_state_file="$sb/state/install_state"
        current_version="1.229.14"; new_version="1.230.0"; install_type="rpm"; _update_duration=7
        _p0_inverted_verdict >/dev/null 2>&1
        printf 'rc=%s' "$?"
    )
    P0_RC="${res#rc=}"
    P0_MARKER=absent; [[ -e "$sb/state/update_failed" ]] && P0_MARKER=present
    P0_HISTORY_STATUS=$(jq -r '.[0].status // "?"' "$sb/update-history.json" 2>/dev/null || echo "?")
    rm -rf "$sb"
}

# The inversion must REPRODUCE the motivating defect on the motivating literal.
p0_run_inverted 'INSTALL_STATE=INSTALL_FAILED\n'
{ [[ "$P0_RC" == "0" && "$P0_HISTORY_STATUS" == "success" && "$P0_MARKER" == "absent" ]]; } \
  && ok "NEG-A3 pre-fix shape DOES record INSTALL_FAILED as success and DOES delete the marker (assertions are live)" \
  || no "NEG-A3 inversion did not reproduce the motivating defect" "rc=$P0_RC history=$P0_HISTORY_STATUS marker=$P0_MARKER — the A3 assertions may be vacuous"

p0_run_inverted 'INSTALL_STATE=FUTURE_STATE_XYZ\n'
{ [[ "$P0_RC" == "0" && "$P0_HISTORY_STATUS" == "success" && "$P0_MARKER" == "absent" ]]; } \
  && ok "NEG-A4 pre-fix shape DOES green-light an invented literal (A4 assertions are live)" \
  || no "NEG-A4 inversion did not reproduce the defect for an invented literal" "rc=$P0_RC history=$P0_HISTORY_STATUS marker=$P0_MARKER"

p0_run_inverted '-'
{ [[ "$P0_RC" == "0" && "$P0_HISTORY_STATUS" == "success" && "$P0_MARKER" == "absent" ]]; } \
  && ok "NEG-A5 pre-fix shape DOES green-light a missing state file (A5 assertions are live)" \
  || no "NEG-A5 inversion did not reproduce the fail-open default" "rc=$P0_RC history=$P0_HISTORY_STATUS marker=$P0_MARKER"

# ...and it must NOT fire on the positive control, or the inversion is just broken.
p0_run_inverted 'INSTALL_STATE=FAILED_REBUILD\n'
{ [[ "$P0_RC" == "2" && "$P0_HISTORY_STATUS" == "install_fail" && "$P0_MARKER" == "present" ]]; } \
  && ok "NEG-A2 pre-fix shape already handled FAILED_REBUILD correctly (the inversion is faithful, not a strawman)" \
  || no "NEG-A2 inversion misbehaves on a literal the pre-fix glob did match" "rc=$P0_RC history=$P0_HISTORY_STATUS marker=$P0_MARKER"

# ---- the legacy green fall-through must be GONE from the source --------------
# ⛔ Structural, not behavioural: a future edit that reinstates a catch-all arm
#    reintroduces the defect for every literal the arms above do not name.
# Count the two MUTATIONS themselves. Exactly ONE call site each — the COMMITTED
# arm. Any second occurrence means some other arm can record a success or destroy
# the failure marker again. (Counting the mutations, not a log phrase, because
# this test file's own commentary quotes the old log phrase.)
_n_hist=$(grep -c '_update_write_history "$current_version" "$new_version" "success"' "$CMD_UPDATE" || true)
_n_rm=$(grep -c 'rm -f "${NFTBAN_DATA_DIR:-/var/lib/nftban}/state/update_failed"' "$CMD_UPDATE" || true)
[[ "$_n_hist" == "1" ]] && ok "P0-D2 exactly one arm writes history as success" || no "P0-D2 success-history call sites" "found $_n_hist, expected 1"
[[ "$_n_rm"  == "1" ]] && ok "P0-D2 exactly one arm deletes state/update_failed" || no "P0-D2 marker-deletion call sites" "found $_n_rm, expected 1"
# and that one arm must be the COMMITTED one.
if awk '/^        COMMITTED\)$/{f=1} f&&/_update_write_history "\$current_version" "\$new_version" "success"/{print;exit}' "$CMD_UPDATE" | grep -q success; then
    ok "P0-D2 the single success-history write lives in the COMMITTED arm"
else
    no "P0-D2 the single success-history write lives in the COMMITTED arm" "not found under COMMITTED)"
fi
if grep -qE '^\s*FAILED_\*\|FAILED\)' "$CMD_UPDATE"; then
    no "P0-D2 the FAILED_*|FAILED glob is replaced by a positive assertion" "the glob arm is still present"
else
    ok "P0-D2 the FAILED_*|FAILED glob is replaced by a positive assertion"
fi
if grep -qF 'default: green if state file absent' "$CMD_UPDATE"; then
    no "P0-D2 the fail-open COMMITTED acquisition default is removed" "still defaults to COMMITTED"
else
    ok "P0-D2 the fail-open COMMITTED acquisition default is removed"
fi

echo "RESULT: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
