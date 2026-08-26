#!/usr/bin/env bash
# =============================================================================
# NFTBan CI — PRODUCER SIGNAL BINDING  (v1.229.4 VAF-0 Stage 3C)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="check-producer-signal-binding"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="BLOCKING. Where a declared producer emits a STRUCTURED signal (::error title=X::), a test asserting that producer state must bind to the structured signal rather than to prose. Five recurrences in one release train, twice inside the file that documented the rule: the correct message for a state routinely contains the words denying the opposite state ('NOT suppression drift', 'this is not no Go changes'), so a bare phrase match hits the sentence that states the opposite. Static; reads the declared population, the producers' own run blocks and the test files; no host."
# meta:inventory.files="scripts/ci/data/security-observation-steps.tsv,.github/workflows,cli/lib/nftban/tests"
# meta:inventory.privileges="none"
# =============================================================================
#
#   TOOL PROSE != PROTOCOL SIGNAL
#
#   AUTHORITY CHAIN — signals come from the PRODUCER, never from a repo-wide search:
#
#       DECLARED PRODUCER STEP
#         -> structured signal extracted ONLY from that step's own `run` block
#            -> test claiming that producer state
#               -> assertion MUST bind to the producer-owned signal
#
#   ⛔ NEVER `grep repo for "::error title="` and treat every match as protocol. MEASURED:
#      four test files and scripts/ci/publish-trusted-gate-status.sh already contain such
#      strings. Consumer text is not producer authority — treating it as such would
#      recreate the same false match one layer up.
#
#   ⛔ NO STRUCTURED SIGNAL != AUTOMATIC DEFECT. Where a producer emits none, prose
#      assertions remain allowed. Producers must NOT be modified merely to satisfy this
#      guard.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DECL="$ROOT/scripts/ci/data/security-observation-steps.tsv"
TESTS="$ROOT/cli/lib/nftban/tests"
RC=0
ok(){ echo "  [PASS] $1"; }
no(){ echo "  [FAIL] $1"; RC=1; }
inf(){ echo "         $1"; }

echo "=== producer signal binding (v1.229.4 VAF-0 Stage 3C) ==="
[[ -f "$DECL" ]]  || { echo "  SUBJECT_NOT_FOUND: $DECL";  echo "RESULT: FAIL"; exit 1; }
[[ -d "$TESTS" ]] || { echo "  SUBJECT_NOT_FOUND: $TESTS"; echo "RESULT: FAIL"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; echo "RESULT: FAIL"; exit 1; }

set +e
OUT="$(python3 - "$ROOT" "$DECL" "$TESTS" <<'SIGPY'
import sys, os, re, glob, yaml
root, decl, tests = sys.argv[1], sys.argv[2], sys.argv[3]

rows=[]
for line in open(decl, encoding="utf-8"):
    if line.startswith("#") or not line.strip(): continue
    f=line.rstrip("\n").split("\t")
    if f[0]=="step" and len(f)>=7: rows.append(f[1:7])

cache={}
def wf(p):
    if p not in cache: cache[p]=yaml.safe_load(open(os.path.join(root,p), encoding="utf-8"))
    return cache[p]

# ---- signals, extracted ONLY from declared producers' own run blocks ------------
titles={}                       # title -> owning "workflow / step"
for w, job, step, tier, prod, role in rows:
    j=(wf(w).get('jobs') or {}).get(job)
    if not isinstance(j, dict): continue
    for st in j.get('steps') or []:
        if str(st.get('name','')) != step: continue
        run = st.get('run') or ""
        for m in re.finditer(r'::error title=([^:]+)::', run):
            titles[m.group(1).strip()] = "%s / %s" % (w, step)

print("SIGNALS=%d" % len(titles))
if not titles:
    print("NOSIGNALS")

# ---- candidate prose phrases a test might match instead of the signal -----------
# For "OSV suppression drift" -> {"OSV suppression drift", "suppression drift"}.
# Two-word minimum keeps this from firing on ordinary English.
phrases={}
for t in titles:
    w_=t.split()
    for i in range(0, max(1, len(w_)-1)):
        p=" ".join(w_[i:])
        if len(p.split())>=2: phrases.setdefault(p.lower(), t)

ASSERT = re.compile(r'\b(grep|=~|\[\[.*==)')
# ---- AUTHORITY LINK: a test is only accountable to the producers it DECLARES -------
# Each test declares meta:inventory.files. Without this scoping a title from one workflow
# would be enforced against a test of a different subject. MEASURED false positives before
# scoping: a release.yml "SBOM not parseable" title fired on OSV and govulncheck tests.
INV = re.compile(r'meta:inventory\.files="([^"]*)"')
viol=[]
for f in sorted(glob.glob(os.path.join(tests, "*_test.sh"))):
    rel=os.path.relpath(f, root)
    body=open(f, encoding="utf-8").read()
    m=INV.search(body)
    declared=set(x.strip() for x in (m.group(1).split(",") if m else []) if x.strip())
    scoped={t:o for t,o in titles.items() if any(o.startswith(d) for d in declared)}
    if not scoped:
        continue
    scoped_phrases={p:t for p,t in phrases.items() if t in scoped}
    for n, line in enumerate(open(f, encoding="utf-8"), 1):
        s=line.strip()
        if not s or s.startswith("#"): continue
        if not ASSERT.search(s): continue
        if "::error title=" in s:            # already bound to the protocol signal
            continue
        low=s.lower()
        for p, t in scoped_phrases.items():
            # ⛔ WORD BOUNDARIES. MEASURED: the phrase "not run" matched inside "not runtime",
            #    flagging an unrelated redaction assertion. Substring matching is exactly the
            #    imprecision this guard exists to police.
            if re.search(r'(?<![\w-])%s(?![\w-])' % re.escape(p), low):
                viol.append("%s:%d asserts the state %r using PROSE %r; the producer (%s) "
                            "emits a structured signal '::error title=%s::' and the assertion "
                            "must bind to it" % (rel, n, t, p, titles[t], t))
                break
for v in viol: print("VIOL::"+v)
SIGPY
)"
EVAL_RC=$?
set -e
if [[ "$EVAL_RC" -ne 0 ]]; then
    no "SIGNAL EVALUATION DID NOT COMPLETE (rc=$EVAL_RC) — ⛔ an evaluator crash is NOT a clean result"
    echo "RESULT: FAIL"; exit 1
fi

SIGN="$(grep -oP '^SIGNALS=\K[0-9]+' <<<"$OUT" || echo 0)"
# ⛔ CARDINALITY PRECONDITION: zero signals would make every arm below vacuous.
if [[ "${SIGN:-0}" -eq 0 ]]; then
    no "ZERO producer-owned signals extracted — the guard would be vacuous. ⛔ 0 SUBJECTS != 0 VIOLATIONS."
    echo "RESULT: FAIL"; exit 1
fi
ok "extracted $SIGN producer-owned structured signal(s) from declared steps' own run blocks"

VIOL="$(grep '^VIOL::' <<<"$OUT" | sed 's/^VIOL:://' || true)"
if [[ -z "$VIOL" ]]; then
    ok "every test assertion over a signal-bearing producer state binds to the structured signal"
else
    while IFS= read -r v; do [[ -n "$v" ]] && no "$v"; done <<<"$VIOL"
    inf "⛔ TOOL PROSE != PROTOCOL SIGNAL. The correct message for a state routinely contains"
    inf "   the words of the state it DENIES, so a bare phrase match hits the opposite sentence."
fi

echo
[[ $RC -eq 0 ]] && echo "RESULT: producer signal binding PASS" || echo "RESULT: producer signal binding FAIL"
exit $RC
