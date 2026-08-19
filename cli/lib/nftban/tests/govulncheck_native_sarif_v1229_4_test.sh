#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.4 PR-B — A PARSE FAILURE MUST NOT BECOME AN EMPTY RESULT SET
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="govulncheck-native-sarif-v1229-4-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-18"
# meta:description="PR-B. The govulncheck lane read -json as one object per line while the tool emits multi-line objects; the converter's except-branch wrote an EMPTY SARIF, so a tree with 7 findings (5 reachable) reported results=0. Proves the converter is deleted in favour of native -format sarif, that rc0 is not treated as clean, that reachable and present-only findings are distinguished, and that no failure mode manufactures a clean artifact."
# meta:inventory.files=".github/workflows/secure-go.yml"
# meta:inventory.privileges="none"
# meta:ta.id="govulncheck_native_sarif_v1229_4_test"
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
#   ⛔ GOVULNCHECK_RC0 != NO_VULNERABILITIES
#      In SARIF/JSON mode govulncheck exits 0 even with findings — VERIFIED on lab2:
#      rc=0 with 7 results (level error=5, note=2).
#   ⛔ NATIVE ARTIFACT FIRST — no second translation authority between tool and verdict.
#   ⛔ EVIDENCE_MANUFACTURED (VAF G4) — a parse failure must never write a clean artifact.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WF="$ROOT/.github/workflows/secure-go.yml"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }
echo "=== govulncheck native SARIF (v1.229.4 PR-B) ==="
[[ -f "$WF" ]] || { echo "  SUBJECT_NOT_FOUND: $WF"; exit 1; }
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT

# ---- B1 · the converter is GONE, not repaired --------------------------------
GVC_CODE="$(python3 - "$WF" <<'PY'
import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
out=[]
for job in d.get('jobs',{}).values():
    for st in job.get('steps',[]):
        nm=str(st.get('name',''))
        if 'govulncheck' in nm.lower():
            out.append(nm+"\n"+str(st.get('run','')))
print("\n---\n".join(out))
PY
)"
CODE_ONLY="$(grep -vE '^\s*#' <<<"$GVC_CODE")"
if grep -q 'Convert govulncheck to SARIF' <<<"$GVC_CODE"; then
    fail "B1 the bespoke converter step still exists"
elif grep -qE 'govulncheck -json|govulncheck\.json' <<<"$CODE_ONLY"; then
    fail "B1 govulncheck is still invoked in -json mode (converter path alive)"
else
    pass "B1 the bespoke JSON->SARIF converter is DELETED"
fi

# ---- B2 · native SARIF is used ------------------------------------------------
grep -q 'format sarif' <<<"$CODE_ONLY" \
  && pass "B2 govulncheck is invoked with native -format sarif" \
  || fail "B2 native SARIF output is not used"

# ---- B3 · no manufactured artifact (VAF G4) -----------------------------------
if grep -qE '"results": *\[\]|results.*:.*\[\]' <<<"$CODE_ONLY"; then
    fail "B3 workflow still contains an empty-results SARIF template (EVIDENCE_MANUFACTURED)"
else
    pass "B3 no empty-SARIF template remains (G4 satisfied)"
fi

# ---- extract the verdict for behavioural arms --------------------------------
python3 - "$WF" "$TMP/verdict.sh" <<'PY'
import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
for job in d.get('jobs',{}).values():
    for st in job.get('steps',[]):
        if str(st.get('name','')).startswith('govulncheck verdict'):
            open(sys.argv[2],'w').write(st['run']); sys.exit(0)
sys.exit(3)
PY
[[ -s "$TMP/verdict.sh" ]] || { fail "B4 SUBJECT_NOT_FOUND: govulncheck verdict step"; echo "RESULT: FAIL"; exit 1; }
pass "B4 verdict logic extracted from the production workflow"
mk(){ python3 -c "
import json,sys
e,n=int(sys.argv[1]),int(sys.argv[2])
res=[{'ruleId':f'GO-E{i}','level':'error'} for i in range(e)]+[{'ruleId':f'GO-N{i}','level':'note'} for i in range(n)]
json.dump({'version':'2.1.0','runs':[{'results':res}]},open('$TMP/govulncheck.sarif','w'))" "$1" "$2"; }
runv(){ ( cd "$TMP" && bash verdict.sh 2>&1 ); }
rcv(){ ( cd "$TMP" && bash verdict.sh >/dev/null 2>&1 ); echo $?; }

# ---- B5 · POSITIVE SECURITY CONTROL: the real 5-reachable shape ---------------
mk 5 2
out="$(runv)"; rc="$(rcv)"
if [[ "$rc" -ne 0 ]] && grep -q '::error title=govulncheck reachable vulnerabilities::' <<<"$out" && grep -q 'reachable(error)=5' <<<"$out"; then
    pass "B5 POSITIVE CONTROL: 5 reachable + 2 present -> security failure, counts reported"
else
    fail "B5 the real finding shape did not fail as a security finding (rc=$rc)"; sed 's/^/        /' <<<"$out" | head -3
fi

# ---- B6 · present-but-not-reachable is still a finding, distinctly labelled ---
mk 0 2
out="$(runv)"; rc="$(rcv)"
if [[ "$rc" -ne 0 ]] && grep -q 'vulnerable code present' <<<"$out" && ! grep -q '::error title=govulncheck reachable vulnerabilities::' <<<"$out"; then
    pass "B6 present-only findings are reported distinctly from reachable ones"
else
    fail "B6 present-only findings misclassified (rc=$rc)"
fi

# ---- B7 · CLEAN ---------------------------------------------------------------
mk 0 0
out="$(runv)"; rc="$(rcv)"
[[ "$rc" -eq 0 ]] && grep -q 'CLEAN' <<<"$out" \
  && pass "B7 zero results -> CLEAN" || fail "B7 a genuinely clean result did not pass (rc=$rc)"

# ---- B8 · FAILURE CONTROL: missing artifact never CLEAN -----------------------
rm -f "$TMP/govulncheck.sarif"
out="$(runv)"; rc="$(rcv)"
if [[ "$rc" -ne 0 ]] && grep -q 'OBSERVATION_FAILURE' <<<"$out" && ! grep -q 'CLEAN' <<<"$out"; then
    pass "B8 FAILURE CONTROL: missing SARIF -> OBSERVATION_FAILURE, never CLEAN"
else
    fail "B8 a missing SARIF did not fail closed (rc=$rc)"
fi

# ---- B9 · UNPARSEABLE != EMPTY (the exact converter defect) -------------------
printf 'not json' > "$TMP/govulncheck.sarif"
out="$(runv)"; rc="$(rcv)"
if [[ "$rc" -ne 0 ]] && grep -q 'not parseable' <<<"$out"; then
    pass "B9 unparseable SARIF -> OBSERVATION_FAILURE (the converter wrote CLEAN here)"
else
    fail "B9 unparseable artifact treated as empty (rc=$rc)"
fi

# ---- B10 · rc0 must not be read as clean --------------------------------------
RUNSTEP="$(python3 - "$WF" <<'PY'
import sys,yaml
d=yaml.safe_load(open(sys.argv[1]))
for job in d.get('jobs',{}).values():
    for st in job.get('steps',[]):
        if st.get('id')=='gvc': print(st.get('run','')); sys.exit(0)
PY
)"
if grep -q 'set +e' <<<"$RUNSTEP" && grep -qE 'GVC_RC=\$\?' <<<"$RUNSTEP"; then
    pass "B10 tool status is captured safely (rc!=0 in sarif mode means TOOL failure)"
else
    fail "B10 the govulncheck invocation can still terminate the step or lose its status"
fi

# ---- B11 · INVERSION: the deleted converter DID manufacture a clean artifact ---
cat > "$TMP/oldconv.py" <<'EOF'
import json
try:
    findings=[json.loads(l) for l in open('multiline.json') if l.strip()]
    results=[{"ruleId":"x"} for f in findings if f.get('finding')]
except Exception:
    results=[]                       # the original fallback
json.dump({"runs":[{"results":results}]}, open('out.sarif','w'))
EOF
printf '{\n  "finding": {\n    "osv": {"id": "GO-2026-6090"}\n  }\n}\n' > "$TMP/multiline.json"
( cd "$TMP" && python3 oldconv.py 2>/dev/null )
n=$(python3 -c "import json;print(len(json.load(open('$TMP/out.sarif'))['runs'][0]['results']))" 2>/dev/null || echo -1)
if [[ "$n" -eq 0 ]]; then
    pass "B11 INVERSION: the old converter turns a REAL multi-line finding into results=0 (B1 is falsifiable)"
else
    fail "B11 inversion did not reproduce the false zero (results=$n)"
fi
echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
