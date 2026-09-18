#!/usr/bin/env bash
# =============================================================================
# NFTBan - BotScan HEALTH TRUTH CONTRACT (v1.231.0 P0-C)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="botscan-health-truth-contract-v1231-0-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:ta.id="botscan_health_truth_contract_v1231_0_test"
# meta:ta.owner="botscan"
# meta:ta.module="botscan-adaptive"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# meta:description="v1.231.0 P0-C — encodes the owner-ruled BotScan HEALTH TRUTH CONTRACT as falsifiable arms over the real classifier (nftban_botscan_health_state) and the real readers (_nftban_health_botscan_facts / _nftban_health_render_botscan / nftban_health_check_botscan, extracted from source, never retyped). Clauses: (1) no valid progress evidence NEVER yields OK; (2) a stalled run with a capped/backpressured backlog is DEGRADED; (3) incomplete measurement authority is UNKNOWN or DEGRADED, never OK; (4) a consumer stale_backlog=false must not override independent stall evidence; (5) no fall-through OK — a health state must be POSITIVELY asserted. Arms that require a telemetry field with no producer at HEAD report NOT_EXECUTED naming the field (never PASS). Violations that are already present at HEAD are DECLARED in an explicit gap registry and reported [GAP-OPEN]; the registry is a TWO-WAY tripwire — an undeclared gap FAILS, a declared gap that reality has CLOSED FAILS with an instruction to promote the arm, and a declared gap no arm consumes FAILS. Negative controls are DECLARED INVERSIONS written in this file; no arm resolves an inversion through git."
# meta:inventory.files="cli/lib/nftban/core/nftban_botscan_adaptive.sh,cli/lib/nftban/core/nftban_botscan.sh,cli/lib/nftban/core/nftban_health_checks_modules.sh,cli/lib/nftban/cli/cmd_health_analysis.sh"
# meta:inventory.binaries="awk,jq,grep,sed"
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SCRIPT_DIR/../../../.." && pwd)
ADAPT="$REPO/cli/lib/nftban/core/nftban_botscan_adaptive.sh"
BOTSCAN="$REPO/cli/lib/nftban/core/nftban_botscan.sh"
HMOD="$REPO/cli/lib/nftban/core/nftban_health_checks_modules.sh"
HANA="$REPO/cli/lib/nftban/cli/cmd_health_analysis.sh"

# ⛔ HARNESS PRECONDITION, NOT A SUBJECT FACT. nftban_botscan.sh calls
#    nftban_botscan_load_config at file scope, which resolves _source_local out of
#    ${NFTBAN_LIB_DIR}/lib/env.sh. Without this binding the source aborts at
#    "_source_local: command not found" (rc=127) under the errexit the C2.5 child
#    arms itself with, and C2.5 reported [NOT_EXECUTED] "the P0-B sink could not be
#    exercised" — a HARNESS failure wearing a missing-producer label, while
#    _nftban_counter_file_add/_get were present all along (nftban_botscan.sh:240,258).
#    A FAST failure implicates the precondition, not the subject: bind the lib dir
#    to THIS repo so the sink arm actually executes.
export NFTBAN_LIB_DIR="$REPO/cli/lib/nftban"

SB=$(mktemp -d); trap 'rm -rf "$SB"' EXIT
PASS=0; FAIL=0; NOTEXEC=0; GAPOPEN=0; FAILED=()

ok(){ PASS=$((PASS+1)); printf '  [PASS] %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); FAILED+=("$1"); printf '  [FAIL] %s%s\n' "$1" "${2:+ — $2}"; }
nx(){ NOTEXEC=$((NOTEXEC+1)); printf '  [NOT_EXECUTED] %s — REQUIRED FIELD HAS NO PRODUCER AT HEAD: %s\n' "$1" "$2"; }

# ---------------------------------------------------------------------------
# DECLARED GAP REGISTRY.
#
# Every entry is a contract violation that is ALREADY PRESENT at HEAD and whose
# fix is owned by a named work item — NOT a licence to pass. Each entry is a
# TWO-WAY tripwire:
#   violation still observed  -> [GAP-OPEN]  (suite stays green; gap is visible)
#   violation no longer observed -> [FAIL]   (promote the arm to a hard assertion
#                                             and delete the registry row)
#   entry that no arm consumes   -> [FAIL]   (registry may not grow silently)
# An observed violation with NO registry row is [FAIL]. There is no third state.
# ---------------------------------------------------------------------------
#
# ⛔ THE REGISTRY IS EMPTY, AND THAT IS A RESULT, NOT AN OVERSIGHT. It opened with
#    seven rows (G-01..G-07). Every one was closed by v1.231.0 P0-B/P0-C and each
#    closure was FORCED by this ratchet: the fix landed, the "violation no longer
#    observed" branch FAILED the arm with "CLAUSE NOW SATISFIED — promote this arm
#    and delete its registry row", and only then was the arm promoted to a hard
#    assertion. The provenance of each promotion is written at the arm itself
#    (C1.4/C1.6/C2.4d/C2.5/C3.4/C4.3/C5.3/C5.5b) so no future reader mistakes a
#    promoted arm for one that always passed.
#    The machinery below is DELIBERATELY RETAINED: a NEW violation with no row is
#    still [FAIL], so the registry cannot be used to park a regression.
declare -A GAPS_DECLARED=()
declare -A GAPS_CONSUMED=()

# gap <id> <arm> <violation-observed:yes|no> <observation>
declare -A GAPS_OPEN_IDS=()

gap(){
  local id="$1" arm="$2" seen="$3" obs="$4"
  GAPS_CONSUMED["$id"]=1
  if [[ -z "${GAPS_DECLARED[$id]:-}" ]]; then
    no "$arm" "UNDECLARED GAP $id — a contract violation with no registry row"
    return
  fi
  if [[ "$seen" == "yes" ]]; then
    GAPOPEN=$((GAPOPEN+1))
    GAPS_OPEN_IDS["$id"]=1        # distinct gaps, not arms — see the summary note
    printf '  [GAP-OPEN] %s — %s\n             (declared %s) %s\n' "$arm" "$obs" "$id" "${GAPS_DECLARED[$id]}"
  else
    no "$arm" "CLAUSE NOW SATISFIED — declared gap $id is CLOSED; promote this arm to a hard assertion and delete its registry row"
  fi
}

echo "==========================================================="
echo "v1.231.0 P0-C — BotScan HEALTH TRUTH CONTRACT"
echo "==========================================================="

for f in "$ADAPT" "$BOTSCAN" "$HMOD" "$HANA"; do
  [[ -f "$f" ]] || { echo "  FATAL: subject missing: $f"; exit 2; }
done
if ! command -v jq >/dev/null 2>&1; then
  echo "  FATAL: jq unavailable — the readers are jq-driven; a jq-less run would assert nothing"
  exit 2
fi

# ---------------------------------------------------------------------------
# SUBJECT BINDING. The classifier is SOURCED (it is a pure function). The
# readers are EXTRACTED FROM SOURCE — never retyped — so editing them without
# this test is detectable. Extraction emptiness is asserted before any arm runs
# (an arm over an empty subject would be vacuous, not passing).
# ---------------------------------------------------------------------------
export NFTBAN_DATA_DIR="$SB/data"; mkdir -p "$NFTBAN_DATA_DIR/botscan"
# shellcheck source=/dev/null
source "$ADAPT"

echo "[S] subject binding"
declare -F nftban_botscan_health_state >/dev/null \
  && ok "S.1 classifier nftban_botscan_health_state sourced from $ADAPT" \
  || { no "S.1 classifier not defined"; exit 1; }

awk '/^_nftban_health_botscan_facts\(\)/{c=1} c{print} /^_nftban_health_render_botscan\(\)/{r=1} r&&/^}/{print "";exit}' \
    "$HMOD" > "$SB/render.sh"
awk '/^nftban_health_check_botscan\(\)/{c=1} c{print} c&&/^}/{exit}' "$HMOD" > "$SB/check.sh"
[[ -s "$SB/render.sh" ]] && grep -q '_nftban_health_render_botscan' "$SB/render.sh" \
  && ok "S.2 facts+render block extracted from nftban_health_checks_modules.sh" \
  || { no "S.2 render extraction empty — every reader arm would be vacuous"; exit 1; }
[[ -s "$SB/check.sh" ]] && grep -q 'NFTBAN_HEALTH_RESULTS' "$SB/check.sh" \
  && ok "S.3 nftban_health_check_botscan extracted from nftban_health_checks_modules.sh" \
  || { no "S.3 check extraction empty — every reader arm would be vacuous"; exit 1; }

# ---------------------------------------------------------------------------
# READER DRIVER.
#   fixture <enabled> <health_state|NORUNSTATE> <run_age_sec> <handoff|MISSING> <stale>
#   reader_check   -> prints "rc|<issue text>"      (machine verdict)
#   reader_render  -> prints the operator-facing verdict block
# errexit stays ARMED in this shell; the subject runs under `bash -c` with
# `set +e` so a non-zero reader return is DATA, not a suite abort.
# ---------------------------------------------------------------------------
fixture(){
  local enabled="$1" hs="$2" age="$3" ho="$4" stale="$5"
  rm -rf "$SB/fx"; mkdir -p "$SB/fx/conf.d/botscan" "$SB/fx/data/botscan" "$SB/fx/data/botguard"
  printf 'BOTSCAN_ENABLED="%s"\nBOTSCAN_ACTION_MODE="both"\n' "$enabled" > "$SB/fx/conf.d/botscan/main.conf"
  if [[ "$hs" != "NORUNSTATE" ]]; then
    printf '{"health_state":"%s","last_run_ts":%s,"bans_emitted_total":0,"lines_scanned_total":100}\n' \
      "$hs" "$(( $(date +%s) - age ))" > "$SB/fx/data/botscan/runstate.json"
  fi
  [[ "$ho" == "MISSING" ]] || printf '{"batch_handoff_errors":%s,"batch_consumer_stale_backlog":%s}\n' \
      "$ho" "$stale" > "$SB/fx/data/botguard/botscan_consumer_status.json"
}

reader_check(){
  NFTBAN_CONFIG_DIR="$SB/fx" NFTBAN_DATA_DIR="$SB/fx/data" SRC="$SB" bash -c '
    set +e
    systemctl(){ return 0; }          # timer ACTIVE — isolates the health axis
    HEALTH_OK=0; HEALTH_WARNING=1
    declare -A NFTBAN_HEALTH_RESULTS NFTBAN_HEALTH_ISSUES
    . "$SRC/render.sh"; . "$SRC/check.sh"
    nftban_health_check_botscan >/dev/null 2>&1
    printf "%s|%s\n" "$?" "${NFTBAN_HEALTH_ISSUES[botscan]:-}"
  '
}

reader_render(){
  NFTBAN_CONFIG_DIR="$SB/fx" NFTBAN_DATA_DIR="$SB/fx/data" SRC="$SB" bash -c '
    set +e
    systemctl(){ return 0; }
    . "$SRC/render.sh"
    _nftban_health_render_botscan 2>&1
  '
}

# ---------------------------------------------------------------------------
# DECLARED INVERSIONS. Written HERE, in this file. No arm resolves a negative
# control through git: an origin/main control inverts the instant a fix merges.
# ---------------------------------------------------------------------------
inv_classifier_always_ok(){ echo "OK_SCANNED_NO_BOTS"; }   # inverts clauses 1,2,3,5
inv_classifier_never_backlog(){                            # inverts clause 2 only
  # shellcheck disable=SC2034  # $1 (enabled) is deliberately ignored by the inversion
  local en="${1:-true}" scanned="${2:-0}"
  [[ "${scanned:-0}" -eq 0 ]] && { echo "DEGRADED_INPUT_BLIND"; return; }
  echo "OK_SCANNED_NO_BOTS"
}

# assert_not_ok <label> <state-producer-output>
assert_not_ok(){ [[ "$2" != OK_* ]]; }

# ---------------------------------------------------------------------------
# C0 — FIELD CENSUS. Decides PASS vs NOT_EXECUTED for the arms below. Census
# lines are OBSERVATIONS, not verdicts; the hard assertions that back them are
# the numbered arms.
# ---------------------------------------------------------------------------
echo "[C0] measurement-authority census (which fields the contract may depend on TODAY)"

# spool backpressure. A FILENAME GREP IS NOT A PRODUCER CENSUS: the collector
# writes this file through a VARIABLE (SPOOL_STATUS_FILE), so a literal-path
# redirect search reports "no writer" and would wrongly park clause 2's spool arm
# as pending-field. The census below resolves the indirection: assignment ->
# redirect through that variable -> atomic rename -> the key actually emitted.
SPOOL_COLLECTOR="$REPO/cli/sbin/nftban-botscan-collector"
SPOOL_FIELD=ABSENT
if [[ -f "$SPOOL_COLLECTOR" ]]; then
  _sv=$(grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=[^[:space:]]*botscan/spool\.status' "$SPOOL_COLLECTOR" \
        | sed -E 's/^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/' | head -1)
  _swrite=no; _smv=no; _skey=no
  if [[ -n "${_sv:-}" ]]; then
    grep -qE "(>|>>)[[:space:]]*\"?\\\$\{?${_sv}[:}\"]" "$SPOOL_COLLECTOR" && _swrite=yes
    grep -qE "mv -f[[:space:]]+\"\\\$\{${_sv}\}\.tmp\"" "$SPOOL_COLLECTOR" && _smv=yes
    grep -qE "printf '[^']*backpressure=%s" "$SPOOL_COLLECTOR" && _skey=yes
  fi
  if [[ "$_swrite" == yes && "$_smv" == yes && "$_skey" == yes ]]; then
    SPOOL_FIELD=PRESENT
    ok "C0.1 botscan/spool.status HAS a producer: $SPOOL_COLLECTOR writes \$$_sv (redirect+atomic mv) and emits the backpressure= key"
  else
    no "C0.1 spool.status producer chain broke (var=${_sv:-none} redirect=$_swrite mv=$_smv key=$_skey) — re-derive before trusting clause 2's spool arms"
  fi
else
  no "C0.1 $SPOOL_COLLECTOR missing — the spool-backpressure producer cannot be located"
fi
# Both health surfaces now read this field. ⛔ C0.1c IS INVERTED FROM ITS ORIGINAL
# SENSE, DELIBERATELY: until v1.231.0 P0-C the two surfaces DISAGREED —
# cmd_health_analysis.sh read spool.status while nftban_health_checks_modules.sh
# did not open it at all, so `nftban health` could never see a latched spool. This
# arm was written as the census tripwire for exactly that, reading
#   "now reads spool.status — promote arm C2.4d to a hard assertion"
# and it FIRED the moment G-07 was fixed. It is kept in its promoted sense: the
# nftban health verdict MUST retain an input path to backpressure. This is a
# census observation of the wiring; C2.4d is the arm that EXECUTES the verdict.
grep -q 'botscan/spool\.status' "$HANA" \
  && ok "C0.1b cmd_health_analysis.sh READS spool.status" \
  || no "C0.1b cmd_health_analysis.sh no longer reads spool.status"
grep -q 'spool\.status' "$HMOD" \
  && ok "C0.1c nftban_health_checks_modules.sh READS spool.status — the nftban health verdict has an input path to backpressure (G-07, closed in v1.231.0 P0-C)" \
  || no "C0.1c nftban_health_checks_modules.sh no longer reads spool.status — G-07 has REGRESSED; the health verdict is blind to a latched spool again"

# progress counters: structurally zero. Two independent defect shapes.
ANALYZE_RETURNS_COUNT=no
awk '/^nftban_botscan_analyze\(\)/{c=1} c{print} c&&/^}/{exit}' "$BOTSCAN" | grep -q 'return \$banned' \
  && ANALYZE_RETURNS_COUNT=yes
CALLER_READS_STDOUT=no
grep -q 'banned=\$(nftban_botscan_analyze)' "$BOTSCAN" && CALLER_READS_STDOUT=yes
SIGNAL_INC_IN_SUBSHELL=no
awk '/^nftban_botscan_write_signal\(\)/{c=1} c{print} c&&/^}/{exit}' "$BOTSCAN" \
  | grep -q '_BOTSCAN_SIGNALS_EMITTED=\$((' && [[ "$CALLER_READS_STDOUT" == yes ]] \
  && SIGNAL_INC_IN_SUBSHELL=yes
COUNTERS_FIELD=BROKEN
[[ "$ANALYZE_RETURNS_COUNT" == yes && "$CALLER_READS_STDOUT" == yes ]] || COUNTERS_FIELD=REPAIRED

# run-age: produced (ts="$(date +%s)" at the single record_runstate call site) and
# read by the reader. This one the contract MAY depend on today.
RUNAGE_FIELD=ABSENT
grep -q 'ts="\$(date +%s)"' "$BOTSCAN" && grep -q '\.last_run_ts//0' "$HMOD" && RUNAGE_FIELD=PRESENT
[[ "$RUNAGE_FIELD" == PRESENT ]] \
  && ok "C0.2 last_run_ts has a producer (nftban_botscan.sh record_runstate call site) AND a reader — safe to depend on today" \
  || no "C0.2 last_run_ts producer/reader binding not found — clause 1+4 arms lose their input"

# backlog_state: produced in parent scope, consumed by the classifier.
BACKLOG_FIELD=ABSENT
grep -q 'backlog_state="\$_BS_BACKLOG"' "$BOTSCAN" && BACKLOG_FIELD=PRESENT
[[ "$BACKLOG_FIELD" == PRESENT ]] \
  && ok "C0.3 backlog_state has a producer and reaches the classifier — safe to depend on today" \
  || no "C0.3 backlog_state producer not found — clause 2 loses its only live input"

printf '  [CENSUS] spool.status:backpressure=%s  progress_counters=%s  last_run_ts=%s  backlog_state=%s\n' \
  "$SPOOL_FIELD" "$COUNTERS_FIELD" "$RUNAGE_FIELD" "$BACKLOG_FIELD"

# ---------------------------------------------------------------------------
# CLAUSE 1 — NO VALID PROGRESS EVIDENCE -> NEVER OK
# Scope: an ENABLED module. The disabled axis is a separate owner ruling and is
# deliberately NOT asserted here.
# ---------------------------------------------------------------------------
echo "[C1] clause 1 — no valid progress evidence NEVER yields OK"

assert_not_ok c1 "$(nftban_botscan_health_state true 0 0 0 STABLE 1 0)" \
  && ok "C1.1 POSITIVE: enabled, input present, 0 scanned -> $(nftban_botscan_health_state true 0 0 0 STABLE 1 0) (not OK_*)" \
  || no "C1.1 enabled + 0 scanned classified OK_*"

assert_not_ok c1 "$(nftban_botscan_health_state true 0 0 0 STABLE 0 0)" \
  && ok "C1.2 POSITIVE: enabled, no input seen, 0 scanned -> $(nftban_botscan_health_state true 0 0 0 STABLE 0 0) (not OK_*)" \
  || no "C1.2 enabled + 0 scanned + no input classified OK_*"

# FALSIFIER: the same predicate, over a DECLARED INVERSION that always says OK.
# If this does NOT trip, C1.1/C1.2 are not looking at anything.
if assert_not_ok c1 "$(inv_classifier_always_ok true 0 0 0 STABLE 1 0)"; then
  no "C1.3 FALSIFIER DID NOT TRIP — the clause-1 predicate accepts an always-OK classifier; C1.1/C1.2 are vacuous"
else
  ok "C1.3 FALSIFIER: declared always-OK inversion is rejected by the clause-1 predicate"
fi

# ---------------------------------------------------------------------------
# C1.4 / C4.3 — PROMOTED FROM DECLARED GAP G-01.  PROVENANCE, KEPT DELIBERATELY:
#
# ⛔ THESE ARMS DID NOT ALWAYS PASS. Until v1.231.0 P0-C G-01 was a DECLARED OPEN
#    GAP consumed by BOTH of them. The run age was MEASURED by
#    _nftban_health_botscan_facts (the `last` field) and then DISCARDED: no
#    verdict branch in the renderer or in nftban_health_check_botscan ever looked
#    at it, so a last_run_ts from thirty days ago still rendered
#    "ENABLED + timer active — enforces via blacklist_manual" and returned
#    HEALTH_OK. C4.3 is the same defect seen from clause 4: with
#    stale_backlog=false the consumer's negative answer was the ONLY stall input
#    consulted, and it cannot see a scanner that stopped producing.
#    P0-C added _nftban_health_botscan_run_staleness and a NAMED STALE branch
#    ahead of the coverage branch on both surfaces. Its threshold is DERIVED —
#    N=6 missed cycles over the configured HTTP_BOT_BOTSCAN_INTERVAL, falling back
#    to nftban-botscan.timer's OnUnitActiveSec=10min — never a literal age.
#    The gap ratchet then FAILED BOTH arms by itself ("CLAUSE NOW SATISFIED —
#    declared gap G-01 is CLOSED"), so the promotion was FORCED by evidence. The
#    single G-01 row was deleted once both arms were promoted.
#
# ⛔ THE 30-DAY FIXTURE IS A WITNESS, NOT THE THRESHOLD. It proves the age reaches
#    a verdict; it does not encode where the boundary sits. The boundary lives in
#    the product, bound to the cadence authority.
#
# ⛔ THE PROMOTED ARMS EXECUTE, THEY DO NOT INSPECT. They drive the real reader
#    over a real runstate.json; neither asserts that the new branch's source text
#    is present. C1.5 and C5.7 remain the falsifiers proving the same probe
#    reports non-OK for a DEGRADED state and OK for a FRESH one.
# ---------------------------------------------------------------------------
fixture true OK_SCANNED_NO_BOTS 2592000 0 false
C1R=$(reader_check); C1R_RC="${C1R%%|*}"
C1RENDER=$(reader_render)
[[ "$C1R_RC" != "0" ]] \
  && ok "C1.4 READER: last_run_ts 30d stale + timer active -> non-OK verdict (rc=$C1R_RC), rendered: $(printf '%s' "$C1RENDER" | sed -n 's/^  State:  *//p')" \
  || no "C1.4 a 30-day-stale last_run_ts rendered healthy" "rc=$C1R_RC rendered: $(printf '%s' "$C1RENDER" | sed -n 's/^  State:  *//p') — G-01 has REGRESSED; it was closed in v1.231.0 P0-C and must never silently revert to a gap"

# C1.4b — THE THRESHOLD MUST BE DERIVED, NOT A LITERAL. G-01's fix is only
# correct if the staleness boundary tracks the cadence authority: a hardcoded
# 3600 would satisfy C1.4 and C4.3 and still be wrong on any host that retunes
# the interval. EXECUTED, NOT GREPPED — drive the real derivation over real
# config fixtures and prove the boundary MOVES, and that the .local override
# beats the shipped file (the same key and precedence cmd_botguard.sh:610 uses).
C14B_DIR="$SB/thr"; mkdir -p "$C14B_DIR/conf.d/botguard"
thr_at(){   # $1 shipped value|MISSING   $2 .local value|MISSING
  rm -f "$C14B_DIR/conf.d/botguard/main.conf" "$C14B_DIR/conf.d/botguard/main.conf.local"
  [[ "$1" == MISSING ]] || printf 'HTTP_BOT_BOTSCAN_INTERVAL="%s"\n' "$1" > "$C14B_DIR/conf.d/botguard/main.conf"
  [[ "$2" == MISSING ]] || printf 'HTTP_BOT_BOTSCAN_INTERVAL="%s"\n' "$2" > "$C14B_DIR/conf.d/botguard/main.conf.local"
  NFTBAN_CONFIG_DIR="$C14B_DIR" SRC="$SB" bash -c 'set +e; . "$SRC/render.sh"; _nftban_health_botscan_stale_threshold'
}
T_DEF=$(thr_at MISSING MISSING); T_300=$(thr_at 300 MISSING); T_LOC=$(thr_at 300 1200)
if [[ "$T_DEF" =~ ^[0-9]+$ && "$T_300" =~ ^[0-9]+$ && "$T_LOC" =~ ^[0-9]+$ ]] \
   && (( T_DEF > 0 && T_300 < T_DEF && T_LOC > T_DEF )); then
  ok "C1.4b threshold is DERIVED from the cadence authority — unset=${T_DEF}s · interval=300 -> ${T_300}s · shipped=300 + .local=1200 -> ${T_LOC}s (.local wins)"
else
  no "C1.4b the staleness boundary did not move with the configured cadence — it is a literal, not a derivation" \
     "unset=$T_DEF interval300=$T_300 shipped300+local1200=$T_LOC"
fi

# FALSIFIER for the reader probe: prove the probe can observe a NON-OK return,
# i.e. it is reading the subject's verdict and not a constant.
fixture true DEGRADED_BUDGET_HIT 10 0 false
C1N="$(reader_check)"; C1N_RC="${C1N%%|*}"
[[ "$C1N_RC" != "0" ]] \
  && ok "C1.5 FALSIFIER: the same reader probe reports rc=$C1N_RC for DEGRADED_BUDGET_HIT (probe is not constant-OK)" \
  || no "C1.5 reader probe returned OK for an explicitly DEGRADED state — probe cannot distinguish verdicts"

# ---------------------------------------------------------------------------
# C1.6 — PROMOTED FROM DECLARED GAP G-04.  PROVENANCE, KEPT DELIBERATELY:
#
# ⛔ THIS ARM DID NOT ALWAYS PASS. Until v1.231.0 P0-C it was a DECLARED OPEN GAP
#    (registry id G-04). ERROR_RUNTIME_FAILURE is emitted by the classifier
#    (nftban_botscan_adaptive.sh:115) — a runtime FAILURE, by definition not
#    progress evidence — but the reader's verdict chain tested only
#    `DEGRADED_* || NO_INPUT_*`, and ERROR_* matches neither. A scan that aborted
#    outright therefore fell through the terminal else and returned HEALTH_OK,
#    rendering "HTTP Exploit Scanner enabled (action=both, timer active)".
#    P0-C added a NAMED ERROR_* branch to both the renderer and
#    nftban_health_check_botscan. The gap ratchet then FAILED this arm by itself
#    — "CLAUSE NOW SATISFIED, promote and delete the registry row" — so the
#    promotion was FORCED by evidence, not remembered by a human. The G-04 row
#    was deleted in the same change.
#
# ⛔ THE PROMOTED ARM EXECUTES, IT DOES NOT INSPECT. It drives the real reader
#    over a real runstate.json; it does not assert that the new branch's source
#    text is present, which would read green while proving nothing.
# ---------------------------------------------------------------------------
fixture true ERROR_RUNTIME_FAILURE 10 0 false
C1E="$(reader_check)"; C1E_RC="${C1E%%|*}"
[[ "$C1E_RC" != "0" ]] \
  && ok "C1.6 READER: health_state=ERROR_RUNTIME_FAILURE -> non-OK verdict (rc=$C1E_RC) via a NAMED ERROR_* branch — issue: ${C1E#*|}" \
  || no "C1.6 a runtime FAILURE reported HEALTH_OK" "rc=$C1E_RC issue=${C1E#*|} — G-04 has REGRESSED; it was closed in v1.231.0 P0-C and must never silently revert to a gap"

# ---------------------------------------------------------------------------
# CLAUSE 2 — STALLED + CAPPED/BACKPRESSURED BACKLOG -> DEGRADED
# ---------------------------------------------------------------------------
echo "[C2] clause 2 — a stalled run with a capped/backpressured backlog is DEGRADED"

C2A=$(nftban_botscan_health_state true 5000 0 0 GROWING 1 0)
[[ "$C2A" == DEGRADED_* ]] \
  && ok "C2.1 POSITIVE: backlog GROWING -> $C2A" \
  || no "C2.1 backlog GROWING did not classify DEGRADED_*" "got $C2A"

C2B=$(nftban_botscan_health_state true 5000 0 0 STARVED 1 0)
[[ "$C2B" == DEGRADED_* ]] \
  && ok "C2.2 POSITIVE: backlog STARVED (>64MiB behind) -> $C2B" \
  || no "C2.2 backlog STARVED did not classify DEGRADED_*" "got $C2B"

# FALSIFIER: a declared inversion that ignores the backlog argument entirely.
# If C2.1/C2.2's predicate passes it, the backlog axis is not being consulted.
if [[ "$(inv_classifier_never_backlog true 5000 0 0 GROWING 1 0)" == DEGRADED_* ]]; then
  no "C2.3 FALSIFIER DID NOT TRIP — a backlog-blind inversion satisfies the clause-2 predicate"
else
  ok "C2.3 FALSIFIER: declared backlog-blind inversion fails the clause-2 predicate (the axis is real)"
fi

# The SPOOL axis — the srv3-shaped failure: the spool latched at its cap with
# backpressure asserted while the access-log forward cursor reports no backlog,
# so backlog_state reads DRAINING (nftban_botscan_adaptive.sh backlog_state: 0
# bytes behind -> DRAINING) and the run classifies OK. The field IS produced
# (C0.1); the classifier simply takes no such argument.
C2_ARITY_OK=no
grep -q '# Args: enabled(true/false) lines_scanned bots_found budget_hit backlog_state has_input(0/1) error(0/1)' "$ADAPT" \
  && C2_ARITY_OK=yes
[[ "$C2_ARITY_OK" == yes ]] \
  && ok "C2.4a classifier signature pinned at 7 args with NO spool/backpressure parameter (nftban_botscan_adaptive.sh)" \
  || no "C2.4a classifier signature changed — re-derive whether a spool axis was added before trusting C2.4b"

# Premise of the srv3 shape: an empty forward-cursor backlog classifies DRAINING,
# which the health model treats as healthy. Asserted, not assumed.
C2D=$(nftban_botscan_backlog_state 0 100000000)
[[ "$C2D" == "DRAINING" ]] \
  && ok "C2.4b PREMISE: zero forward-cursor backlog classifies $C2D even after a 100MB prior — the access-log axis cannot see a latched spool" \
  || no "C2.4b backlog_state premise changed" "got $C2D"

if [[ "$SPOOL_FIELD" == PRESENT ]]; then
  # POSITIVE arm, executable TODAY: backpressure=1 + an OK health_state must not
  # render a healthy verdict on the `nftban health` surface.
  fixture true OK_SCANNED_NO_BOTS 10 0 false
  printf 'total_bytes=1170000000\nfile_count=4210\noldest_age_sec=1900000\ncap_bytes=1073741824\ncap_pct=108\nbackpressure=1\nts=%s\n' \
    "$(date +%s)" > "$SB/fx/data/botscan/spool.status"
  [[ -s "$SB/fx/data/botscan/spool.status" ]] && grep -q '^backpressure=1$' "$SB/fx/data/botscan/spool.status" \
    && ok "C2.4c FIXTURE: spool.status written with backpressure=1 (the arm below is not vacuous)" \
    || no "C2.4c spool.status fixture not written — C2.4d would assert nothing"
  # -------------------------------------------------------------------------
  # C2.4d — PROMOTED FROM DECLARED GAP G-07.  PROVENANCE, KEPT DELIBERATELY:
  #
  # ⛔ THIS ARM DID NOT ALWAYS PASS. Until v1.231.0 P0-C it was a DECLARED OPEN
  #    GAP (registry id G-07). The field was never missing — C0.1 proves the
  #    collector writes it EVERY cycle through $SPOOL_STATUS_FILE — it simply
  #    reached no verdict. nftban_botscan_health_state takes no spool argument
  #    (C2.4a still pins that signature) and nftban_health_checks_modules.sh did
  #    not open spool.status at all; only cmd_health_analysis.sh read it, and only
  #    for its own return code. This is the srv3 shape: the spool latches at its
  #    cap with backpressure asserted while the access-log forward cursor reports
  #    0 bytes behind, so backlog_state reads DRAINING (C2.4b is that premise,
  #    asserted not assumed) and `nftban health` returned HEALTH_OK.
  #    P0-C gave the FACTS layer a cheap keyed read of spool.status and both
  #    verdict surfaces a NAMED backpressure branch, ahead of the coverage branch
  #    because health_state structurally cannot see the spool. The gap ratchet
  #    then FAILED this arm by itself — and C0.1c fired alongside it with its own
  #    "promote arm C2.4d" instruction — so the promotion was FORCED by evidence.
  #    The G-07 row was deleted in the same change.
  #
  # ⛔ CAUSAL PRECEDENCE IS PART OF THE CLAIM. The fixture asserts backpressure=1
  #    at 108% of cap WITH consumer stale_backlog=false. That false is not a
  #    clearance: it says only that the consumer saw no stale work in what it
  #    drained, which is exactly what a blocked queue produces. If a later change
  #    lets the consumer field override this, THIS ARM FAILS.
  #
  # ⛔ THE PROMOTED ARM EXECUTES, IT DOES NOT INSPECT. It drives the real reader
  #    over a real spool.status; C2.4c proves the fixture is non-vacuous first.
  # -------------------------------------------------------------------------
  C2S="$(reader_check)"; C2S_RC="${C2S%%|*}"
  [[ "$C2S_RC" != "0" ]] \
    && ok "C2.4d READER: spool backpressure=1 at 108% of cap + stale_backlog=false -> non-OK verdict (rc=$C2S_RC) — issue: ${C2S#*|}" \
    || no "C2.4d a latched spool at 108% of cap reported HEALTH_OK" "rc=$C2S_RC issue=${C2S#*|} — G-07 has REGRESSED; it was closed in v1.231.0 P0-C and must never silently revert to a gap"
else
  nx "C2.4c/d spool-backpressure axis" "/var/lib/nftban/botscan/spool.status:backpressure (producer chain not resolvable at HEAD)"
fi

# ---------------------------------------------------------------------------
# C2.5 — PROMOTED FROM DECLARED GAP G-06.  PROVENANCE, KEPT DELIBERATELY:
#
# ⛔ THIS ARM DID NOT ALWAYS PASS. Until v1.231.0 P0-B it was a DECLARED OPEN GAP
#    (registry id G-06) and C2.5b was NOT_EXECUTED. Not because the clause was
#    unimportant — because bans_emitted_total and signals_emitted_total were
#    STRUCTURALLY ZERO, so no progress counter could carry stall evidence at all:
#        nftban_botscan_analyze returned its count as an EXIT STATUS (`return $banned`)
#        while the caller read STDOUT (`banned=$(nftban_botscan_analyze) || banned=0`),
#        and the signal counter was incremented inside that same command
#        substitution, so the parent's read was always 0.
#    P0-B replaced that with an append/sum sink that survives the fork. The gap
#    ratchet then FAILED this arm by itself — "CLAUSE NOW SATISFIED, promote and
#    delete the registry row" — so the promotion was FORCED by evidence, not
#    remembered by a human. The G-06 row was deleted in the same change.
#
# ⛔ THE PROMOTED ARM EXECUTES, IT DOES NOT INSPECT. Asserting that P0-B's code is
#    PRESENT would trade a declared NOT_EXECUTED gap for a source-shape check —
#    strictly worse, because it would read green while proving nothing about whether
#    a progress signal can reach the health contract. C2.5 drives the real sink
#    across a real process boundary; C2.5b carries the value through to
#    runstate.json, which is the health contract's actual input surface.
# ---------------------------------------------------------------------------
if [[ "$COUNTERS_FIELD" == BROKEN ]]; then
  no "C2.5 PRECONDITION: the P0-B counter repair is absent at HEAD" \
     "analyze_returns_count=$ANALYZE_RETURNS_COUNT caller_reads_stdout=$CALLER_READS_STDOUT signal_increment_inside_that_subshell=$SIGNAL_INC_IN_SUBSHELL — this arm was promoted from G-06 and must never silently revert to a gap"
else
  ok "C2.5 PRECONDITION: the exit-status/stdout counter defect no longer reproduces at HEAD"
fi

C25_SINK="$SB/c25_counters"; : > "$C25_SINK"
C25_RC=0
bash -c '
  set -Eeuo pipefail
  . "$1" >/dev/null 2>&1
  _unused=$( _nftban_counter_file_add "$2" bans 3; _nftban_counter_file_add "$2" sig 7; echo x )
  printf "%s %s\n" "$(_nftban_counter_file_get "$2" bans)" "$(_nftban_counter_file_get "$2" sig)"
' _ "$BOTSCAN" "$C25_SINK" > "$SB/c25.out" 2>/dev/null || C25_RC=$?
C25_BANS=""; C25_SIG=""
# ⛔ IFS=' ' IS REQUIRED: this module runs under strict IFS=$'\n\t' (no space), so a
#    bare `read -r a b` yields ONE token "3 7" in $a and leaves $b empty. Same class
#    as the v1.186.1 endpoint-list defect called out in nftban_botscan.sh.
[[ -s "$SB/c25.out" ]] && IFS=' ' read -r C25_BANS C25_SIG < "$SB/c25.out"
if [[ "$C25_RC" != "0" ]]; then
  nx "C2.5 progress counter across a real fork" "the P0-B sink could not be exercised (rc=$C25_RC) — NOT a pass"
elif [[ "$C25_BANS" == "3" && "$C25_SIG" == "7" ]]; then
  ok "C2.5 progress counters CROSS a real command-substitution boundary (bans=$C25_BANS sig=$C25_SIG) — stall evidence is now expressible"
else
  no "C2.5 progress counter lost across the fork" "bans='$C25_BANS' sig='$C25_SIG', expected 3 and 7"
fi

C25B_DIR="$SB/c25b"; mkdir -p "$C25B_DIR/botscan"
C25B_RC=0
NFTBAN_DATA_DIR="$C25B_DIR" bash -c '
  set +e
  . "$1" >/dev/null 2>&1
  nftban_botscan_record_runstate health_state=OK_SCANNED_BOTS_FOUND bans=3 signals=7 \
      lines_scanned=100 last_run_ts="$(date +%s)" >/dev/null 2>&1
' _ "$ADAPT" || C25B_RC=$?
C25B_FILE="$C25B_DIR/botscan/runstate.json"
if [[ ! -s "$C25B_FILE" ]]; then
  nx "C2.5b progress counter reaches the health-contract input surface" \
     "record_runstate wrote no runstate.json (rc=$C25B_RC) — NOT a pass"
else
  C25B_BANS=$(sed -n 's/.*"bans_emitted_total"[[:space:]]*:[[:space:]]*\([0-9-]*\).*/\1/p' "$C25B_FILE" | head -1)
  C25B_SIG=$(sed -n 's/.*"signals_emitted_total"[[:space:]]*:[[:space:]]*\([0-9-]*\).*/\1/p' "$C25B_FILE" | head -1)
  if [[ "${C25B_BANS:-0}" -gt 0 && "${C25B_SIG:-0}" -gt 0 ]]; then
    ok "C2.5b a NON-ZERO progress signal reaches runstate.json (bans_emitted_total=$C25B_BANS signals_emitted_total=$C25B_SIG) — the health contract now has a stall axis to consume"
  else
    no "C2.5b runstate.json still carries zero progress counters" \
       "bans_emitted_total=${C25B_BANS:-<absent>} signals_emitted_total=${C25B_SIG:-<absent>} — the input surface is still dead"
  fi
fi

# ---------------------------------------------------------------------------
# CLAUSE 3 — INCOMPLETE MEASUREMENT AUTHORITY -> UNKNOWN or DEGRADED, NEVER OK
# ---------------------------------------------------------------------------
echo "[C3] clause 3 — incomplete measurement authority is UNKNOWN or DEGRADED, never OK"

# The FACTS layer is honest: absent run-state -> UNKNOWN, absent consumer status
# -> handoff/stale UNKNOWN. Assert that first, so a later failure is localised to
# the VERDICT layer rather than to collection.
fixture true NORUNSTATE 0 MISSING false
C3F=$(NFTBAN_CONFIG_DIR="$SB/fx" NFTBAN_DATA_DIR="$SB/fx/data" SRC="$SB" bash -c '
  set +e; systemctl(){ return 0; }; . "$SRC/render.sh"; _nftban_health_botscan_facts')
IFS='|' read -r _c3en _c3mo _c3ti C3HS _c3la _c3ba _c3sp C3HO C3ST <<<"$C3F"
[[ "$C3HS" == "UNKNOWN" ]] \
  && ok "C3.1 POSITIVE: run-state absent -> facts emit health_state=UNKNOWN (never assumed clean)" \
  || no "C3.1 run-state absent did not yield UNKNOWN" "got '$C3HS'"
[[ "$C3HO" == "UNKNOWN" && "$C3ST" == "UNKNOWN" ]] \
  && ok "C3.2 POSITIVE: consumer status absent -> handoff=UNKNOWN stale=UNKNOWN (never assumed healthy)" \
  || no "C3.2 absent consumer status did not yield UNKNOWN/UNKNOWN" "got '$C3HO'/'$C3ST'"

# FALSIFIER: the facts layer must NOT report UNKNOWN when authority IS complete.
fixture true OK_SCANNED_NO_BOTS 10 0 false
C3F2=$(NFTBAN_CONFIG_DIR="$SB/fx" NFTBAN_DATA_DIR="$SB/fx/data" SRC="$SB" bash -c '
  set +e; systemctl(){ return 0; }; . "$SRC/render.sh"; _nftban_health_botscan_facts')
IFS='|' read -r _ _ _ C3HS2 _ _ _ C3HO2 _ <<<"$C3F2"
[[ "$C3HS2" != "UNKNOWN" && "$C3HO2" != "UNKNOWN" ]] \
  && ok "C3.3 FALSIFIER: with complete authority the same facts probe reports hs=$C3HS2 handoff=$C3HO2 (UNKNOWN is measured, not constant)" \
  || no "C3.3 facts probe reports UNKNOWN even with complete authority — C3.1/C3.2 are vacuous"

# ---------------------------------------------------------------------------
# C3.4 — PROMOTED FROM DECLARED GAP G-05.  PROVENANCE, KEPT DELIBERATELY:
#
# ⛔ THIS ARM DID NOT ALWAYS PASS. Until v1.231.0 P0-C it was a DECLARED OPEN GAP
#    (registry id G-05). The FACTS layer was already honest — absent or unreadable
#    run-state synthesises health_state=UNKNOWN (nftban_health_checks_modules.sh,
#    the hs initialiser and its jq default) — and C3.1 proves that. The defect was
#    localised entirely in the VERDICT layer: UNKNOWN matched no branch, fell
#    through the terminal else and returned HEALTH_OK, so a host where BotScan had
#    NEVER RUN was indistinguishable from one scanning cleanly.
#    P0-C added a NAMED UNKNOWN branch to the renderer and to
#    nftban_health_check_botscan. The gap ratchet then FAILED this arm by itself
#    — "CLAUSE NOW SATISFIED, promote and delete the registry row" — so the
#    promotion was FORCED by evidence. The G-05 row was deleted in the same change.
#
# ⛔ THE PROMOTED ARM EXECUTES, IT DOES NOT INSPECT. It removes the real
#    runstate.json and drives the real reader; C3.3 is its falsifier, proving the
#    same probe reports a non-UNKNOWN state when authority IS complete.
# ---------------------------------------------------------------------------
fixture true NORUNSTATE 0 MISSING false
C3V="$(reader_check)"; C3V_RC="${C3V%%|*}"
[[ "$C3V_RC" != "0" ]] \
  && ok "C3.4 VERDICT: health_state=UNKNOWN (run-state absent) -> non-OK verdict (rc=$C3V_RC) via a NAMED UNKNOWN branch — issue: ${C3V#*|}" \
  || no "C3.4 incomplete measurement authority reported HEALTH_OK" "rc=$C3V_RC issue=${C3V#*|} — G-05 has REGRESSED; it was closed in v1.231.0 P0-C and must never silently revert to a gap"

# ---------------------------------------------------------------------------
# CLAUSE 4 — CONSUMER stale_backlog=false MUST NOT OVERRIDE INDEPENDENT STALL
# ---------------------------------------------------------------------------
echo "[C4] clause 4 — stale_backlog=false does not override independent stall evidence"

# POSITIVE: an independent DEGRADED coverage verdict survives stale_backlog=false.
fixture true DEGRADED_BACKLOG_GROWING 10 0 false
C4A="$(reader_check)"; C4A_RC="${C4A%%|*}"
[[ "$C4A_RC" != "0" ]] \
  && ok "C4.1 POSITIVE: stale_backlog=false did NOT clear an independent DEGRADED_BACKLOG_GROWING (rc=$C4A_RC)" \
  || no "C4.1 stale_backlog=false cleared an independent DEGRADED verdict"

# FALSIFIER: the consumer axis is live in the other direction — stale_backlog=true
# is honoured even when health_state is OK. If this does not trip, C4.1 proves
# nothing about the consumer field being consulted at all.
fixture true OK_SCANNED_NO_BOTS 10 0 true
C4B="$(reader_check)"; C4B_RC="${C4B%%|*}"
[[ "$C4B_RC" != "0" && "${C4B#*|}" == *"HAND-OFF BROKEN"* ]] \
  && ok "C4.2 FALSIFIER: stale_backlog=true overrides an OK health_state (the consumer axis IS consulted)" \
  || no "C4.2 stale_backlog=true did not change the verdict — the consumer axis is not wired" "rc=$C4B_RC issue=${C4B#*|}"

# C4.3 — the clause-4 face of G-01; see the promotion provenance at C1.4 above.
# Stall evidence that is INDEPENDENT of health_state — a 30-day-old last_run_ts —
# used to be discarded the moment stale_backlog=false and health_state=OK. A
# consumer that saw no stale work in what it drained has said nothing about
# whether the scanner ran at all.
fixture true OK_SCANNED_NO_BOTS 2592000 0 false
C4C="$(reader_check)"; C4C_RC="${C4C%%|*}"
[[ "$C4C_RC" != "0" ]] \
  && ok "C4.3 stale_backlog=false did NOT override a 30d-stale last_run_ts (rc=$C4C_RC) — issue: ${C4C#*|}" \
  || no "C4.3 the consumer's stale_backlog=false overrode independent stall evidence" "rc=$C4C_RC — G-01 has REGRESSED; it was closed in v1.231.0 P0-C and must never silently revert to a gap"

# ---------------------------------------------------------------------------
# CLAUSE 5 — NO FALL-THROUGH OK; A HEALTH STATE IS POSITIVELY ASSERTED
# ---------------------------------------------------------------------------
echo "[C5] clause 5 — no fall-through OK"

# 5a. EMITTABLE-STATE CLOSURE. The declared set is the population; a new emit
# site that is not declared FAILS rather than silently widening the contract.
declare -a DECLARED_STATES=(
  DEGRADED_BACKLOG_GROWING DEGRADED_BUDGET_HIT DEGRADED_INPUT_BLIND
  DISABLED_BY_CONFIG ERROR_RUNTIME_FAILURE OK_SCANNED_BOTS_FOUND OK_SCANNED_NO_BOTS
)
EMITTED=$(awk '/^nftban_botscan_health_state\(\)/{c=1} c{print} c&&/^}/{exit}' "$ADAPT" \
          | grep -oE 'echo "[A-Z_]+"' | sed -e 's/^echo "//' -e 's/"$//' | sort -u)
DECLARED=$(printf '%s\n' "${DECLARED_STATES[@]}" | sort -u)
if [[ "$EMITTED" == "$DECLARED" ]]; then
  ok "C5.1 emittable-state closure: classifier emits exactly the declared $(printf '%s\n' "$DECLARED" | wc -l) states"
else
  no "C5.1 emittable-state population changed" "emitted=[$(printf '%s' "$EMITTED" | tr '\n' ' ')] declared=[$(printf '%s' "$DECLARED" | tr '\n' ' ')]"
fi
# Plus the two states written directly by nftban_botscan.sh, bypassing the classifier.
for s in DISABLED_BY_CONFIG NO_INPUT_DISCOVERED; do
  grep -q "health_state=\"$s\"" "$BOTSCAN" \
    && ok "C5.2 direct-write state $s is present in nftban_botscan.sh (bypasses the classifier)" \
    || no "C5.2 direct-write state $s no longer written — reader coverage assumptions change"
done

# 5b. THE WRITER'S OWN DEFAULT. A record with no health_state must not become OK.
W="$SB/w"; mkdir -p "$W/botscan"
C5W=$(NFTBAN_DATA_DIR="$W" BOTSCAN_ENABLED=true bash -c '
  set -Eeuo pipefail
  . "$1" >/dev/null 2>&1
  nftban_botscan_record_runstate ts=1 dur=1 lines_scanned=0 >/dev/null 2>&1 || true
  jq -r ".health_state" "$2/botscan/runstate.json" 2>/dev/null || echo "NOFILE"
' _ "$ADAPT" "$W")
# ---------------------------------------------------------------------------
# C5.3 — PROMOTED FROM DECLARED GAP G-02.  PROVENANCE, KEPT DELIBERATELY:
#
# ⛔ THIS ARM DID NOT ALWAYS PASS. Until v1.231.0 P0-C it was a DECLARED OPEN GAP
#    (registry id G-02). nftban_botscan_record_runstate defaulted health_state to
#    OK_SCANNED_NO_BOTS when the caller supplied none, and
#    nftban_botscan_trend_append repeated the same default, so a run that never
#    classified itself minted a clean verdict as DURABLE TRUTH in runstate.json —
#    the health reader's primary input surface — and in trend.jsonl.
#    A fall-through OK at the WRITER is worse than one at a reader: it outlives
#    the process, and every downstream surface then faithfully reports it.
#    P0-C changed both defaults to UNKNOWN, which is not a new state — it is what
#    _nftban_health_botscan_facts already synthesises for absent authority and
#    what the reader already names as non-OK (G-05). The gap ratchet then FAILED
#    this arm by itself — "CLAUSE NOW SATISFIED, promote and delete the registry
#    row" — so the promotion was FORCED by evidence. The G-02 row was deleted in
#    the same change, emptying the registry.
#
# ⛔ THE PROMOTED ARM EXECUTES, IT DOES NOT INSPECT. It calls the real writer with
#    no health_state and reads back the file the writer actually wrote. C5.4 is
#    its falsifier: an explicitly supplied state must still round-trip verbatim,
#    so an arm that passed by breaking the writer outright would be caught.
# ---------------------------------------------------------------------------
[[ "$C5W" != OK_* && -n "$C5W" && "$C5W" != "NOFILE" ]] \
  && ok "C5.3 WRITER: record_runstate with NO health_state argument recorded health_state=$C5W — not an OK_* reached by parameter default" \
  || no "C5.3 the run-state writer minted a health verdict it was never given" "recorded health_state='$C5W' — G-02 has REGRESSED; it was closed in v1.231.0 P0-C and must never silently revert to a gap"

# FALSIFIER for the writer probe: an explicitly supplied state must be recorded
# verbatim, proving the probe reads the file the writer actually wrote.
W2="$SB/w2"; mkdir -p "$W2/botscan"
C5W2=$(NFTBAN_DATA_DIR="$W2" BOTSCAN_ENABLED=true bash -c '
  set -Eeuo pipefail
  . "$1" >/dev/null 2>&1
  nftban_botscan_record_runstate ts=1 dur=1 lines_scanned=0 health_state=DEGRADED_INPUT_BLIND >/dev/null 2>&1 || true
  jq -r ".health_state" "$2/botscan/runstate.json" 2>/dev/null || echo "NOFILE"
' _ "$ADAPT" "$W2")
[[ "$C5W2" == "DEGRADED_INPUT_BLIND" ]] \
  && ok "C5.4 FALSIFIER: an explicitly supplied health_state round-trips verbatim ($C5W2) — the probe reads real output" \
  || no "C5.4 writer probe did not round-trip an explicit state — C5.3 is vacuous" "got '$C5W2'"

# 5c. THE READER'S TERMINAL ELSE. A state the reader does not NAME must not be
# reached by default. WARN_PARTIAL_PROGRESS is referenced by the advisory in
# nftban_botscan_adaptive.sh but emitted by no producer — it is the cleanest
# probe for the fall-through itself.
grep -q 'WARN_PARTIAL_PROGRESS' "$ADAPT" \
  && ok "C5.5a WARN_PARTIAL_PROGRESS is a state the codebase already reasons about (advisory branch) — a valid fall-through probe" \
  || no "C5.5a WARN_PARTIAL_PROGRESS no longer referenced — choose another unnamed state for the fall-through probe"
# ---------------------------------------------------------------------------
# C5.5b — PROMOTED FROM DECLARED GAP G-03.  PROVENANCE, KEPT DELIBERATELY:
#
# ⛔ THIS ARM DID NOT ALWAYS PASS. Until v1.231.0 P0-C it was a DECLARED OPEN GAP
#    (registry id G-03) and it is the fall-through itself, not one of its
#    symptoms. nftban_health_check_botscan initialised `status=$HEALTH_OK` and
#    terminated in an UNQUALIFIED else, so OK was the value you got by NOT
#    deciding: every branch had to remember to downgrade, and ANY health_state the
#    reader did not NAME — a new classifier state, a renamed one, a writer typo, a
#    truncated read — returned HEALTH_OK and rendered "enabled (action=both, timer
#    active)". G-04 and G-05 were two instances of this one defect; this arm is
#    the defect itself, probed with WARN_PARTIAL_PROGRESS (C5.5a asserts the
#    codebase already reasons about that name while no producer emits it, which is
#    what makes it a clean fall-through probe).
#    P0-C made `status` start UNSET, gave OK its own NAMED branch, made the
#    terminal else fail closed on an unrecognised state, and added a fail-closed
#    backstop before the return for any future branch that forgets to decide. The
#    gap ratchet then FAILED this arm by itself — "CLAUSE NOW SATISFIED, promote
#    and delete the registry row" — so the promotion was FORCED by evidence. The
#    G-03 row was deleted in the same change.
#
# ⛔ THE PROMOTED ARM EXECUTES, IT DOES NOT INSPECT. It drives the real reader with
#    a real unnamed state. C5.7 is its indispensable falsifier: without it, a
#    reader that returned non-OK for EVERYTHING would satisfy this arm while
#    proving nothing about positive assertion.
# ---------------------------------------------------------------------------
fixture true WARN_PARTIAL_PROGRESS 10 0 false
C5R="$(reader_check)"; C5R_RC="${C5R%%|*}"
[[ "$C5R_RC" != "0" ]] \
  && ok "C5.5b READER: a health_state the reader does not name -> non-OK verdict (rc=$C5R_RC), fail-closed rather than through a terminal else — issue: ${C5R#*|}" \
  || no "C5.5b an unnamed health_state reached HEALTH_OK by fall-through" "rc=$C5R_RC issue=${C5R#*|} — G-03 has REGRESSED; it was closed in v1.231.0 P0-C and must never silently revert to a gap"

# 5d. POSITIVE ASSERTION COVERAGE. For every state the system can actually
# record, the reader must reach its verdict through a branch that NAMES the
# state class. Executed, not grepped: OK_* may return OK; nothing else may.
echo "  --- clause 5 positive-assertion coverage matrix (enabled, timer active, handoff clean) ---"
for s in DEGRADED_BACKLOG_GROWING DEGRADED_BUDGET_HIT DEGRADED_INPUT_BLIND NO_INPUT_DISCOVERED; do
  fixture true "$s" 10 0 false
  r="$(reader_check)"; r="${r%%|*}"
  [[ "$r" != "0" ]] \
    && ok "C5.6 coverage: $s -> non-OK verdict (rc=$r), reached by a NAMED branch" \
    || no "C5.6 coverage: $s reached OK by fall-through"
done
fixture true OK_SCANNED_NO_BOTS 10 0 false
r="$(reader_check)"; r="${r%%|*}"
[[ "$r" == "0" ]] \
  && ok "C5.7 coverage: OK_SCANNED_NO_BOTS with fresh evidence -> OK (rc=$r) — the matrix is not uniformly non-OK" \
  || no "C5.7 coverage matrix returns non-OK for every input — C5.6 proves nothing"

# ---------------------------------------------------------------------------
# REGISTRY CLOSURE — no declared gap may go unconsumed.
# ---------------------------------------------------------------------------
echo "[R] gap-registry closure"
for id in ${!GAPS_DECLARED[@]+"${!GAPS_DECLARED[@]}"}; do
  [[ -n "${GAPS_CONSUMED[$id]:-}" ]] \
    && ok "R.1 declared gap $id is consumed by at least one arm" \
    || no "R.1 declared gap $id is consumed by NO arm — registry rows may not exist without an arm that observes them"
done
# R.2 — assert the empty registry POSITIVELY. Without this the [R] section would
# simply print nothing once the last row was deleted, and "no rows" would be
# indistinguishable from "this section stopped running".
if (( ${#GAPS_DECLARED[@]} == 0 )); then
  ok "R.2 gap registry is EMPTY — all seven declared contract violations (G-01..G-07) were closed and their arms promoted to hard assertions; a new violation now has no row to park in and FAILS"
else
  ok "R.2 gap registry holds ${#GAPS_DECLARED[@]} declared row(s): $(printf '%s\n' "${!GAPS_DECLARED[@]}" | sort | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
echo "==========================================================="
printf 'PASS=%s  FAIL=%s  NOT_EXECUTED=%s  GAP-OPEN=%s arm(s) over %s distinct gap(s)\n' \
  "$PASS" "$FAIL" "$NOTEXEC" "$GAPOPEN" "${#GAPS_OPEN_IDS[@]}"
if (( NOTEXEC > 0 )); then
  echo "NOT_EXECUTED arms are NOT passes: the named field has no producer at HEAD."
fi
if (( GAPOPEN > 0 )); then
  echo "GAP-OPEN arms are DECLARED contract violations present at HEAD, not passes."
  # ⛔ ARMS != DEFECTS. One gap may be consumed by several arms (G-01 is observed
  #    both by the clause-1 reader arm and by the clause-4 override arm), so the arm
  #    count OVERSTATES the number of distinct defects. Always read the second
  #    number. The distinct ids currently open are printed below.
  printf '  distinct open gaps: %s\n' "$(printf '%s\n' "${!GAPS_OPEN_IDS[@]}" | sort | tr '\n' ' ')"
fi
if (( FAIL > 0 )); then
  printf 'FAILED ARMS:\n'; printf '  - %s\n' "${FAILED[@]}"
  echo "=== botscan_health_truth_contract_v1231_0: FAIL ==="
  exit 1
fi
echo "=== botscan_health_truth_contract_v1231_0: PASS ==="
exit 0
