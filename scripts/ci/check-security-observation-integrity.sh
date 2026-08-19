#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — SECURITY OBSERVATION INTEGRITY  (v1.229.4 VAF-0 Stage 3B)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-security-observation-integrity"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="BLOCKING recurrence guard over the DECLARED security-observation step population (tier-aware: 14 Tier-A, 2 Tier-B gosec, 1 gate). G1: a claim-bearing producer's failure may be suppressed only if the status is captured AND consumed by a downstream classifier -- gosec ran under bare '|| true' for years, so a crashed scanner was indistinguishable from a clean one. G4: a validator may not create or replace the artifact it validates on an absence/failure path -- the SBOM validator fabricated a stub attributing itself to the producer that had just failed. Static; reads the declaration and the workflow files; no host."
# meta:inventory.files="scripts/ci/data/security-observation-steps.tsv,.github/workflows"
# meta:inventory.privileges="none"
# =============================================================================
#
#   ⛔ THIS IS NOT A REPO-WIDE `|| true` LINT. `|| true` occurs 91 times across 8 workflow
#      files, nearly all legitimate, and VAF explicitly PERMITS suppression when the failure
#      is subsequently consumed and classified. The subject is the DECLARED population only.
#
#   G1  CLAIM-BEARING OBSERVATION FAILURE MUST BE CONSUMED
#         ALLOWED    set +e ; cmd ; RC=$? ; set -e ; ... $RC consumed
#         REJECTED   cmd || true   with no authoritative consumer
#       Witnesses: G1-W1 gosec producer failure swallowed (fixed in this train)
#                  G1-W2 the Stage-3A SBOM validator draft swallowed its own status (fixed)
#
#   G4  A VALIDATOR MUST NOT MANUFACTURE ITS SUBJECT
#         REJECTED   if [ ! -f "$ARTIFACT" ]; then  <write $ARTIFACT>  fi
#       Witness: G4-W1 the SBOM validator fabricated a stub on producer absence.
#       ⛔ THE GUARD DOES NOT INSPECT ARTIFACT BYTES. Whether an artifact was manufactured
#          cannot be decided from its content — a native empty CLEAN artifact and a
#          fabricated one can be byte-identical. VAF requires execution status + artifact
#          validity + native diagnostic. So G4 is enforced STRUCTURALLY: no fallback writer
#          on an absence/failure trigger.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DECL="$ROOT/scripts/ci/data/security-observation-steps.tsv"
RC=0
ok(){ echo "  [PASS] $1"; }
no(){ echo "  [FAIL] $1"; RC=1; }
inf(){ echo "         $1"; }

echo "=== security observation integrity (v1.229.4 VAF-0 Stage 3B) ==="
if [[ ! -f "$DECL" ]]; then
    echo "  [FAIL] DECLARATION_MISSING: $DECL"
    echo "         ⛔ A MISSING DECLARATION IS NOT AN EMPTY POPULATION."
    echo "RESULT: FAIL"; exit 1
fi
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; echo "RESULT: FAIL"; exit 1; }

EXPECTED_TOTAL="$(awk -F'\t' '$1=="expected_total"{print $2; exit}' "$DECL" | tr -d '[:space:]')"
[[ "$EXPECTED_TOTAL" =~ ^[0-9]+$ ]] || { no "expected_total missing/non-numeric"; echo "RESULT: FAIL"; exit 1; }
DECL_N="$(awk -F'\t' '$1=="step" && NF>=7' "$DECL" | wc -l | tr -d ' ')"
if [[ "$DECL_N" -eq 0 ]]; then
    no "DECLARED_POPULATION_EMPTY — 0 declared steps. ⛔ 0 SUBJECTS != 0 DEFECTS."
    echo "RESULT: FAIL"; exit 1
fi
[[ "$DECL_N" -eq "$EXPECTED_TOTAL" ]] \
  && ok "declared population: $DECL_N step(s), coherent with expected_total" \
  || no "declaration incoherent: $DECL_N rows vs expected_total=$EXPECTED_TOTAL"

# =============================================================================
# Rule evaluation — ONE python pass over the declared rows
# =============================================================================
# ⛔ Captured, then classified. A crash here must not read as "no findings": the exit
#    status is consumed below before the empty-output branch is allowed to mean PASS.
set +e
EVAL="$(python3 - "$ROOT" "$DECL" <<'PY'
import sys, os, re, yaml
root, decl = sys.argv[1], sys.argv[2]
rows=[]
for line in open(decl, encoding="utf-8"):
    if line.startswith("#") or not line.strip(): continue
    f=line.rstrip("\n").split("\t")
    if f[0]=="step" and len(f)>=7: rows.append(f[1:7])
cache={}
def steps_of(wf):
    if wf not in cache: cache[wf]=yaml.safe_load(open(os.path.join(root,wf), encoding="utf-8"))
    return cache[wf]
def find(wf, job, step):
    j=(steps_of(wf).get('jobs') or {}).get(job)
    if not isinstance(j,dict): return None
    for st in j.get('steps') or []:
        if str(st.get('name',''))==step: return st
    return None
def code_only(run): return "\n".join(l for l in run.split("\n") if not l.lstrip().startswith("#"))
fails=[]
for wf, job, step, tier, producer, role in rows:
    st=find(wf,job,step)
    if st is None: fails.append("DECLARED STEP NOT FOUND: %s / %s / %s"%(wf,job,step)); continue
    run=st.get('run')
    if run is None: continue
    code=code_only(run)
    if re.search(r'\|\|\s*true\s*$', code, re.M):
        cap=re.search(r'^\s*([A-Z_][A-Z0-9_]*)=\$\?', code, re.M)
        if not cap: fails.append("G1 %s / %s: `|| true` with NO status capture or consumer"%(wf,step))
        else:
            v=cap.group(1)
            if not re.search(r'\$\{?%s\b'%re.escape(v), code.replace(cap.group(0),"",1)):
                fails.append("G1 %s / %s: status %s captured but never consumed"%(wf,step,v))
    if re.search(r'^\s*set \+e\s*$', code, re.M):
        cap=re.search(r'^\s*([A-Z_][A-Z0-9_]*)=\$\?', code, re.M)
        if not cap: fails.append("G1 %s / %s: `set +e` without status capture"%(wf,step))
        else:
            v=cap.group(1)
            if not re.search(r'\$\{?%s\b'%re.escape(v), code.replace(cap.group(0),"",1)):
                fails.append("G1 %s / %s: `set +e` captured %s but nothing consumes it"%(wf,step,v))
    if role in ("validator","classifier","gate"):
        for m in re.finditer(r'if\s*\[+\s*!\s*-[fse]\s+"?([^"\]\s]+)"?\s*\]+\s*;\s*then(.*?)\bfi\b', code, re.S):
            target, body = m.group(1), m.group(2)
            base=os.path.basename(target.strip('"').replace("$",""))
            if re.search(r'(cat\s*>|tee\s|>\s*)"?[^"\s]*%s'%re.escape(base), body) or re.search(r'<<\s*\w*EOF', body):
                fails.append("G4 %s / %s: absence of %s triggers a fallback that WRITES it"%(wf,step,target))
for f in fails: print(f)
PY
)"
EVAL_RC=$?
set -e
if [[ "$EVAL_RC" -ne 0 ]]; then
    no "RULE EVALUATION DID NOT COMPLETE (rc=$EVAL_RC) — ⛔ an evaluator crash is NOT a clean result"
    echo "RESULT: FAIL"; exit 1
fi
if [[ -z "$EVAL" ]]; then
    ok "G1: every declared observation step captures AND consumes its producer status"
    ok "G4: no declared validator manufactures the artifact it validates"
else
    while IFS= read -r line; do [[ -n "$line" ]] && no "$line"; done <<<"$EVAL"
fi

# =============================================================================
# POPULATION PARITY — declared vs structurally discovered
# =============================================================================
# ⛔ Discovery does NOT define the expectation; it detects UNREGISTERED GROWTH.
DISC="$(python3 - "$ROOT" <<'DISCPY'
import sys,os,re,glob,yaml
root=sys.argv[1]
# MENTIONING A PRODUCER != OBSERVING WITH IT. "Install gosec", "Generate SLSA Summary" and
# the curl that downloads osv-scanner all name a producer without observing anything.
# An OBSERVATION step INVOKES the producer in COMMAND POSITION with a subcommand/flag.
PROD = r'(osv-scanner|govulncheck|gosec|slsa-verifier)'
INVOKE = re.compile(r'(?:^|[|;&]|\$\()\s*\S*?' + PROD + r'"?\s+(?:-{1,2}\w|scan\b|verify-artifact\b)')
INSTALL = re.compile(r'\b(curl|wget|go\s+install|chmod|tar|unzip|mv|cp|rm)\b')
# A VERSION/HELP PROBE IS PROVISIONING VERIFICATION, NOT A SECURITY OBSERVATION.
PROBE = re.compile(r'\s--?(version|help)\b')
ECHOISH = re.compile(r'^\s*(echo|printf|cat\s+<<)')
for f in sorted(glob.glob(os.path.join(root,".github/workflows/*.yml"))):
    rel=os.path.relpath(f,root)
    try: d=yaml.safe_load(open(f,encoding="utf-8"))
    except Exception: continue
    for jn,job in (d.get('jobs') or {}).items():
        if not isinstance(job,dict): continue
        for st in job.get('steps') or []:
            run=st.get('run') or ""
            hit=False
            for line in run.split("\n"):
                l=line.strip()
                if not l or l.startswith("#"): continue
                if INSTALL.search(l) or ECHOISH.match(l) or PROBE.search(l): continue
                if INVOKE.search(l): hit=True; break
            if hit:
                print("%s\t%s\t%s"%(rel,jn,str(st.get('name',''))))
DISCPY
)"
DECL_KEYS="$(awk -F'\t' '$1=="step" && NF>=7 {print $2"\t"$3"\t"$4}' "$DECL" | sort)"
UNREG="$(comm -13 <(printf '%s\n' "$DECL_KEYS") <(printf '%s\n' "$DISC" | sort))"
if [[ -z "$UNREG" ]]; then
    ok "POPULATION PARITY: no unregistered security-scanner observation step"
else
    no "UNREGISTERED security-observation step(s) — present but outside the declaration:"
    sed 's/^/           /' <<<"$UNREG"
    inf "-> register them in $(basename "$DECL") with a tier, or the guard cannot police them."
fi

# ---- the declaration must not be self-generating -------------------------------
if grep -qiE '^\s*(ls|find|grep|awk|python)' "$DECL"; then
    no "the declaration contains enumeration logic — it must be hand-maintained data"
else
    ok "the declaration is declarative data, not a rediscovery of current reality"
fi

echo
[[ $RC -eq 0 ]] && echo "RESULT: security observation integrity PASS" || echo "RESULT: security observation integrity FAIL"
exit $RC
