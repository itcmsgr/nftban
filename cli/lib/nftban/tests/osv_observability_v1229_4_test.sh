#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.4 PR-A — AN OBSERVATION FAILURE IS NOT A CLEAN SCAN
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="osv-observability-v1229-4-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-18"
# meta:description="PR-A. The OSV workflow ran under bash -e, so a non-clean scan terminated the step at the scanner line: scanner_ran was never set, the SARIF containing the findings was never uploaded, and every classification branch was dead code. Proves the exit status is captured, that the verdict derives from scanner-native SARIF results rather than the exit code, that findings dominate coincident suppression drift, and that no failure mode can render CLEAN."
# meta:inventory.files=".github/workflows/osv-scanner.yml"
# meta:inventory.privileges="none"
# meta:ta.id="osv_observability_v1229_4_test"
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
#   ⛔ SCAN JOB RUN        != FINDING DATA PRODUCED
#   ⛔ OBSERVATION FAILURE != CLEAN
#   ⛔ UNUSED_IGNORE       != VULNERABILITY
#   ⛔ UNPARSEABLE ARTIFACT != EMPTY ARTIFACT
#
#   MEASURED DEFECT (25/25 runs from 2026-08-13): the scan produced a SARIF holding
#   7 real findings; `bash -e` killed the step before it could be classified or
#   uploaded; the dashboard therefore showed no current finding data at all.
#
#   The verdict logic is EXTRACTED FROM THE PRODUCTION WORKFLOW and executed against
#   fixtures, so these arms bind to shipped YAML rather than to a copy.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WF="$ROOT/.github/workflows/osv-scanner.yml"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== OSV observability (v1.229.4 PR-A) ==="
[[ -f "$WF" ]] || { echo "  SUBJECT_NOT_FOUND: $WF"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT

# ---- extract the verdict step from PRODUCTION yaml ---------------------------
python3 - "$WF" "$TMP/verdict.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for job in d.get('jobs', {}).values():
    for st in job.get('steps', []):
        if str(st.get('name','')).startswith('OSV verdict'):
            open(sys.argv[2],'w').write(st['run']); sys.exit(0)
sys.exit(3)
PY
if [[ ! -s "$TMP/verdict.sh" ]]; then
    fail "A0 SUBJECT_NOT_FOUND: could not extract the 'OSV verdict' step from the workflow"
    echo "RESULT: FAIL"; exit 1
fi
pass "A0 verdict logic extracted from the production workflow"
bash -n "$TMP/verdict.sh" 2>/dev/null && pass "A0b extracted verdict block is syntactically valid" \
                                      || fail "A0b extracted verdict block has a syntax error"

run_verdict(){ ( cd "$TMP" && SARIF_READY="$1" OSV_EXIT="$2" bash verdict.sh 2>&1 ); }
rc_of(){ ( cd "$TMP" && SARIF_READY="$1" OSV_EXIT="$2" bash verdict.sh >/dev/null 2>&1 ); echo $?; }

# ---- A1 · POSITIVE SECURITY CONTROL (mandatory) -------------------------------
# A SARIF carrying real findings must fail as a SECURITY finding even when the
# scanner also reported unused ignores on the same run.
python3 - "$TMP/osv-results.sarif" <<'PY'
import json,sys
ids=["GO-2026-5026","GO-2026-5972","GO-2026-6088","GO-2026-6089","GO-2026-6090","GO-2026-6091","GO-2026-6218"]
json.dump({"version":"2.1.0","runs":[{"results":[{"ruleId":i,"message":{"text":i}} for i in ids]}]},
          open(sys.argv[1],"w"))
PY
out="$(run_verdict true 1)"; rc="$(rc_of true 1)"
if [[ "$rc" -ne 0 ]] && grep -q 'OSV vulnerability findings' <<<"$out" && grep -q '7 finding' <<<"$out"; then
    pass "A1 POSITIVE SECURITY CONTROL: 7 real findings -> security failure (rc=$rc)"
else
    fail "A1 real findings did not produce a security failure (rc=$rc)"; sed 's/^/        /' <<<"$out" | head -3
fi

# ---- A2 · FINDINGS DOMINATE coincident drift ---------------------------------
# ⛔ Match the DRIFT VERDICT, not the word "drift". The findings message deliberately
# contains "Coincident suppression drift, if any, does NOT downgrade this" — asserting
# on the phrase matched the sentence that states the opposite.
if ! grep -q '::error title=OSV suppression drift::' <<<"$out"; then
    pass "A2 findings are NOT downgraded to suppression drift (rc=1 is ambiguous; results decide)"
else
    fail "A2 a run with real findings was labelled suppression drift — the false-negative-green defect"
fi

# ---- A3 · CLEAN ---------------------------------------------------------------
printf '{"version":"2.1.0","runs":[{"results":[]}]}' > "$TMP/osv-results.sarif"
out="$(run_verdict true 0)"; rc="$(rc_of true 0)"
[[ "$rc" -eq 0 ]] && grep -q 'CLEAN' <<<"$out" \
  && pass "A3 zero results + rc0 -> CLEAN" \
  || fail "A3 a genuinely clean scan did not pass (rc=$rc)"

# ---- A4 · DRIFT ONLY is drift, not vulnerability ------------------------------
out="$(run_verdict true 1)"; rc="$(rc_of true 1)"
if [[ "$rc" -ne 0 ]] && grep -qi 'suppression drift' <<<"$out" && ! grep -q 'vulnerability findings' <<<"$out"; then
    pass "A4 zero results + rc1 -> CONFIGURATION DRIFT, not a vulnerability"
else
    fail "A4 drift-only run misclassified (rc=$rc)"; sed 's/^/        /' <<<"$out" | head -3
fi

# ---- A5 · FAILURE CONTROL: no SARIF -> never CLEAN ----------------------------
out="$(run_verdict false 1)"; rc="$(rc_of false 1)"
if [[ "$rc" -ne 0 ]] && grep -q 'OBSERVATION_FAILURE' <<<"$out" && ! grep -q 'CLEAN' <<<"$out"; then
    pass "A5 FAILURE CONTROL: unvalidated SARIF -> OBSERVATION_FAILURE, never CLEAN"
else
    fail "A5 a missing SARIF did not fail closed (rc=$rc)"
fi

# ---- A6 · UNPARSEABLE != EMPTY ------------------------------------------------
printf 'this is not json' > "$TMP/osv-results.sarif"
out="$(run_verdict true 1)"; rc="$(rc_of true 1)"
if [[ "$rc" -ne 0 ]] && grep -q 'not parseable' <<<"$out"; then
    pass "A6 an unparseable SARIF is an observation failure, not an empty result set"
else
    fail "A6 unparseable SARIF was treated as empty (rc=$rc)"
fi

# ---- A7 · the root defect: exit status must be CAPTURED, not fatal ------------
SCAN_RUN="$(python3 - "$WF" <<'PY'
import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
for job in d.get('jobs',{}).values():
    for st in job.get('steps',[]):
        if st.get('id')=='scan': print(st.get('run','')); sys.exit(0)
PY
)"
if grep -q 'set +e' <<<"$SCAN_RUN" && grep -qE '^\s*OSV_EXIT=\$\?' <<<"$SCAN_RUN"; then
    pass "A7 scanner status is captured with -e disabled (the step can no longer die at the scanner line)"
else
    fail "A7 the scanner invocation can still terminate the step before scanner_ran is set"
fi
# ⛔ CODE ONLY. The step's comment block quotes the OLD fatal form to explain the
# defect; matching raw text flagged that explanation as the defect itself. Third
# instance of DOCUMENTATION-ABOUT-X matching a guard for X in this session.
SCAN_CODE="$(grep -vE '^[[:space:]]*#' <<<"$SCAN_RUN")"
if grep -qE '\./osv-scanner[^|]*;[[:space:]]*OSV_EXIT=' <<<"$SCAN_CODE"; then
    fail 'A7b the fatal "cmd; VAR=$?" form is still present'
else
    pass 'A7b the fatal "cmd; VAR=$?" form is gone'
fi

# ---- A8 · the verdict must not be issued before the SARIF is uploaded ---------
ORDER="$(python3 - "$WF" <<'PY'
import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
for job in d.get('jobs',{}).values():
    names=[str(s.get('name','')) for s in job.get('steps',[])]
    if any(n.startswith('OSV verdict') for n in names):
        up=[i for i,n in enumerate(names) if 'Upload SARIF' in n]
        vd=[i for i,n in enumerate(names) if n.startswith('OSV verdict')]
        print(f"{up[0]} {vd[0]}"); sys.exit(0)
PY
)"
set -- $ORDER
if [[ -n "${1:-}" && -n "${2:-}" && "$2" -gt "$1" ]]; then
    pass "A8 verdict is issued AFTER the SARIF upload (finding evidence is never lost to an early failure)"
else
    fail "A8 the verdict precedes the upload — a failing verdict could discard the evidence"
fi

# ---- A9 · INVERSION: the pre-fix form DOES die before capture -----------------
cat > "$TMP/prefix.sh" <<'EOF'
set -e
false; RC=$?
echo "REACHED_AFTER=$RC"
EOF
pre="$(bash "$TMP/prefix.sh" 2>&1 || true)"
if ! grep -q 'REACHED_AFTER' <<<"$pre"; then
    pass 'A9 INVERSION: under -e, "cmd; VAR=$?" never reaches the next line (A7 is falsifiable)' 
else
    fail "A9 inversion did not reproduce the -e termination — A7 may be vacuous"
fi

echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
