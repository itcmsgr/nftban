#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.4 VAF-C1b — A REQUIRED SECURITY GATE MUST BE TRUTHFUL
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="secure-go-gate-coverage-v1229-4-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-19"
# meta:description="VAF-C1b. The required context 'Build, Test, Scan (Go)' reported success in three distinct states where no vulnerability observation existed: a legitimate no-Go-change delta claimed 'OK', a FAILED change-detection job was read as 'no Go changes', and a skipped analysis was reported as 'analysis passed'. Measured: 16 of 20 runs passed with zero observation. Executes the gate logic EXTRACTED FROM THE PRODUCTION WORKFLOW against every state, and asserts the freshness events require a scan through event authority rather than filter output."
# meta:inventory.files=".github/workflows/secure-go.yml"
# meta:inventory.privileges="none"
# meta:ta.id="secure_go_gate_coverage_v1229_4_test"
# meta:ta.owner="cross-cutting"
# meta:ta.module="core"
# meta:ta.execution_class="CI_HERMETIC_SHELL"
# meta:ta.gate="ci-bash"
# meta:ta.hermetic="true"
# meta:ta.requires_root="false"
# meta:ta.requires_network="false"
# meta:ta.requires_systemd="false"
# meta:ta.requires_nftables="false"
# meta:ta.requires_package="false"
# =============================================================================
#
#   ⛔ "SKIPPED"      = EXECUTION FACT
#   ⛔ "SKIPPED (OK)" = POLICY VERDICT, and a verdict needs authority
#   ⛔ FAILED PRODUCER + EMPTY OUTPUT != "NO GO CHANGE"
#   ⛔ AN ABSENT ANALYSIS IS NOT A PASSING ANALYSIS
#   ⛔ NO SOURCE CHANGE != NO NEW VULNERABILITY INFORMATION
#
#   THE THREE MECHANISMS, all reproduced against the PRE-FIX gate on main c806a7bd
#   BEFORE this fix was designed (so the fix could not tune the expectation to itself):
#
#     PATH A  no Go change            -> "security scan skipped (OK)"     16/20 runs
#     PATH B  filter job FAILS        -> "No Go changes detected ... (OK)"  rc=0,
#             BYTE-IDENTICAL to a legitimate no-change PR
#     PATH C  analyze skipped         -> "Go security analysis passed"      rc=0
#
#   B produces a false skip. C produces a false PASS — the more brazen claim.
#
#   The gate logic is EXTRACTED FROM SHIPPED YAML and rendered exactly as GitHub renders
#   it (textual expression substitution before bash runs), so these arms bind to the
#   production workflow rather than to a copy of it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WF="$ROOT/.github/workflows/secure-go.yml"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }
info(){ echo "        $1"; }

echo "=== secure-go required-gate coverage (v1.229.4 VAF-C1b) ==="
# ⛔ A repo-resident subject is always present in a correct checkout; absence is a FAILURE.
[[ -f "$WF" ]] || { echo "  SUBJECT_NOT_FOUND: $WF"; echo "RESULT: FAIL"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; echo "RESULT: FAIL"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT

python3 - "$WF" "$TMP/gate.txt" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
job = d.get('jobs', {}).get('secure-go-gate')
if not job: sys.exit(3)
for st in job.get('steps', []):
    if 'run' in st:
        open(sys.argv[2], 'w').write(st['run']); sys.exit(0)
sys.exit(4)
PY
[[ -s "$TMP/gate.txt" ]] || { fail "G0 could not extract secure-go-gate logic from the production workflow"; echo "RESULT: FAIL"; exit 1; }
pass "G0 gate logic extracted from the production workflow"

# Render GitHub's expression substitution, then execute.
# $1 filter.result  $2 go_changed  $3 analyze.result  $4 event_name
render_run(){
    python3 - "$TMP/gate.txt" "$TMP/r.sh" "$1" "$2" "$3" "$4" <<'PY'
import sys
src=open(sys.argv[1]).read()
sub={"needs.filter.result":sys.argv[3],"needs.filter.outputs.go_changed":sys.argv[4],
     "needs.analyze.result":sys.argv[5],"github.event_name":sys.argv[6]}
for k,v in sub.items():
    for form in ("${{ %s }}"%k, "${{%s}}"%k):
        src=src.replace(form,v)
open(sys.argv[2],"w").write(src)
PY
    bash "$TMP/r.sh" 2>&1
}
rc_of(){ render_run "$1" "$2" "$3" "$4" >/dev/null 2>&1; }

bash -n "$TMP/gate.txt" 2>/dev/null && pass "G0b extracted gate block is syntactically valid" \
                                    || fail "G0b extracted gate block has a syntax error"

# ---- C1B-W1 · PATH B — a failed filter must never read as "no change" -----------
# ⛔ ANCHOR ON THE STRUCTURED SIGNAL (::error title=...::), NEVER ON PROSE. The correct
#   UNKNOWN message deliberately contains the words "this is not 'no Go changes'", so a bare
#   phrase match hits the sentence that DENIES the defect. This is the fifth occurrence of
#   DOCUMENTATION-ABOUT-X matching a guard for X in this train — including here, in the file
#   that states the rule.  TOOL PROSE != PROTOCOL SIGNAL.
out="$(render_run failure "" skipped pull_request)"; rc_of failure "" skipped pull_request; rc=$?
if [[ "$rc" -ne 0 ]] && grep -q '::error title=Go security coverage UNKNOWN::' <<<"$out"; then
    pass "C1B-W1 PATH B: filter FAILURE -> required gate FAILS (rc=$rc), not 'no Go changes'"
    info "⛔ FAILED PRODUCER + EMPTY OUTPUT != NEGATIVE DECISION"
else
    fail "C1B-W1 PATH B REGRESSION: a failed filter job passed the required gate (rc=$rc)"
    sed 's/^/          /' <<<"$out" | head -2
fi

# ---- C1B-W1b · filter succeeded but produced no usable value -------------------
out="$(render_run success "" skipped pull_request)"; rc_of success "" skipped pull_request; rc=$?
if [[ "$rc" -ne 0 ]]; then
    pass "C1B-W1b filter OK but go_changed empty -> UNKNOWN, gate FAILS (rc=$rc)"
else
    fail "C1B-W1b an unusable go_changed value passed the gate (rc=$rc)"
fi

# ---- C1B-W3 · PATH C — an absent analysis is not a passing analysis ------------
out="$(render_run success true skipped pull_request)"; rc_of success true skipped pull_request; rc=$?
if [[ "$rc" -ne 0 ]] && ! grep -q 'Go security analysis passed' <<<"$out"; then
    pass "C1B-W3 PATH C: scan REQUIRED but analyze skipped -> gate FAILS (rc=$rc)"
    info "⛔ the pre-fix form printed 'Go security analysis passed' here"
else
    fail "C1B-W3 PATH C REGRESSION: a skipped analysis was reported as passing (rc=$rc)"
fi

# ---- C1B-W2 · PATH A — a no-change PR may pass, but must CLAIM NOTHING ---------
out="$(render_run success false skipped pull_request)"; rc_of success false skipped pull_request; rc=$?
if [[ "$rc" -eq 0 ]]; then
    pass "C1B-W2 PATH A: no Go subject change -> PR gate passes (rc=0)"
else
    fail "C1B-W2 a legitimate no-change delta must not fail the PR gate (rc=$rc)"
fi
# ⛔ The wording is the actual subject here: it must not assert a security verdict.
if grep -qiE 'skipped \(ok\)|scan skipped \(ok\)' <<<"$out"; then
    fail "C1B-W2b the gate still emits the POLICY VERDICT 'skipped (OK)' for an unobserved subject"
elif grep -qi 'not required' <<<"$out" && grep -qiE 'execution fact|asserts nothing' <<<"$out"; then
    pass "C1B-W2b the no-change message states an EXECUTION FACT and makes no security claim"
else
    fail "C1B-W2b the no-change message neither disclaims a security verdict nor states a fact"
    sed 's/^/          /' <<<"$out" | head -3
fi

# ---- SCHEDULE ARM · event authority, not filter authority ----------------------
for ev in schedule workflow_dispatch; do
    # go_changed false AND empty must both still require the scan on a freshness event.
    for gc in false ""; do
        out="$(render_run success "$gc" skipped "$ev")"; rc_of success "$gc" skipped "$ev"; rc=$?
        lbl="$ev event, go_changed='${gc:-<empty>}'"
        if [[ "$rc" -ne 0 ]]; then
            pass "FRESH-$ev $lbl + analyze skipped -> gate FAILS (scan was REQUIRED by event)"
        else
            fail "FRESH-$ev $lbl passed without an analysis — event authority not enforced (rc=$rc)"
        fi
        out="$(render_run success "$gc" success "$ev")"; rc_of success "$gc" success "$ev"; rc=$?
        if [[ "$rc" -eq 0 ]] && grep -q 'passed' <<<"$out"; then
            pass "FRESH-$ev $lbl + analyze success -> gate PASSES"
        else
            fail "FRESH-$ev a completed freshness scan did not pass (rc=$rc)"
        fi
    done
done

# ---- ordinary states must still behave --------------------------------------
out="$(render_run success true success pull_request)"; rc_of success true success pull_request; rc=$?
[[ "$rc" -eq 0 ]] && pass "STD go_changed=true + analyze success -> PASS" \
                  || fail "STD a successful required scan did not pass (rc=$rc)"
for r in failure cancelled; do
    rc_of success true "$r" pull_request; rc=$?
    [[ "$rc" -ne 0 ]] && pass "STD analyze=$r -> gate FAILS" \
                      || fail "STD analyze=$r passed the gate (rc=$rc)"
done
# ⛔ DEFAULT DENY: an unrecognised state is not a pass.
rc_of success true some_future_state pull_request; rc=$?
[[ "$rc" -ne 0 ]] && pass "DENY an unrecognised analyze.result FAILS (default deny)" \
                  || fail "DENY an unrecognised analyze.result passed the gate (rc=$rc)"

# ---- the workflow must actually carry a freshness trigger ---------------------
python3 - "$WF" <<'PY' && pass "TRIG secure-go declares schedule + workflow_dispatch triggers" || fail "TRIG the workflow has no freshness trigger — PATH A is not closed"
import sys, yaml
d=yaml.safe_load(open(sys.argv[1]))
on=d.get(True, d.get('on'))            # PyYAML parses the bare key `on:` as boolean True
sys.exit(0 if isinstance(on,dict) and 'schedule' in on and 'workflow_dispatch' in on else 1)
PY

# ---- analyze must key on the EVENT, not on the filter output -----------------
python3 - "$WF" <<'PY' && pass "EVT analyze requires the scan via github.event_name (not via filter output)" || fail "EVT analyze does not gate freshness on the event — paths-filter has no diff base on schedule"
import sys, yaml
d=yaml.safe_load(open(sys.argv[1]))
cond=str(d['jobs']['analyze'].get('if',''))
sys.exit(0 if "github.event_name == 'schedule'" in cond and "github.event_name == 'workflow_dispatch'" in cond else 1)
PY

echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
