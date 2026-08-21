#!/usr/bin/env bash
# =============================================================================
# NFTBan — A RELEASE STEP CANNOT READ A FILE ITS JOB DID NOT CHECK OUT
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="check-verify-release-workspace"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-21"
# meta:description="BLOCKING. The v1.229.4 first tag attempt failed unpublished because verify-release checks out a sparse workspace (VERSION only) while three claim-bearing steps read repo-resident declarations. Asserts every repository path those steps reference is provided by the job's own checkout configuration, so the mismatch fails on a PR instead of at tag time."
# meta:inventory.files=".github/workflows/release.yml"
# meta:inventory.privileges="none"
# =============================================================================
#
#   ⛔ THE CLASS THIS CLOSES:
#
#        FIXTURE PROVIDES REQUIRED DECLARATION
#        !=
#        PRODUCTION JOB PROVIDES REQUIRED DECLARATION
#
#      The step-logic controls extract a step and run it against fixtures they build
#      themselves — so the declaration always exists, and the control cannot fail for
#      the one reason production did. STEP LOGIC VALID != STEP INPUT REACHABLE.
#
#   ⛔ This checks REACHABILITY ONLY. Whether a declaration is correct, coherent or
#      complete is the business of the step-logic controls; do not duplicate that here.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WF="${1:-$ROOT/.github/workflows/release.yml}"
FAIL=0

echo "=== verify-release workspace precondition ==="
[[ -f "$WF" ]] || { echo "  SUBJECT_NOT_FOUND: $WF"; echo "RESULT: FAIL"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; echo "RESULT: FAIL"; exit 1; }

OUT="$(python3 - "$WF" "$ROOT" <<'PY'
import sys, re, os, yaml

wf, root = sys.argv[1], sys.argv[2]
d = yaml.safe_load(open(wf))
job = (d.get('jobs') or {}).get('verify-release')
if not job:
    print("ERR\tverify-release job is absent from the workflow"); sys.exit(0)

steps = job.get('steps') or []

# ---- what the checkout PROVIDES -------------------------------------------------
co = [s for s in steps if 'actions/checkout' in str(s.get('uses', ''))]
if not co:
    print("ERR\tverify-release has no checkout step, but its steps read repository files")
    sys.exit(0)
with_ = co[0].get('with') or {}
sparse = with_.get('sparse-checkout')
if sparse is None:
    # A full checkout provides everything; nothing to prove.
    print("FULL\tcheckout is not sparse — every repository path is available")
    sys.exit(0)
provided = [p.strip() for p in str(sparse).split('\n') if p.strip()]

# ---- what the steps REQUIRE ------------------------------------------------------
# Repo-relative paths under known source roots, plus anything under $GITHUB_WORKSPACE.
pat = re.compile(r'(?<![\w/.$])((?:scripts|cli|build|packaging|docs|tools)/[\w./-]+)')
ws  = re.compile(r'\$GITHUB_WORKSPACE/([\w./-]+)')
required = {}
for i, st in enumerate(steps, 1):
    blob = st.get('run') or ''
    for m in list(pat.findall(blob)) + list(ws.findall(blob)):
        required.setdefault(m, set()).add((i, str(st.get('name', '?'))))

for path in sorted(required):
    where = sorted(required[path])
    # non-cone sparse-checkout matches by path prefix
    ok = any(path == p or path.startswith(p.rstrip('/') + '/') for p in provided)
    exists = os.path.exists(os.path.join(root, path))
    steplist = ", ".join(f"step {i} ({n[:40]})" for i, n in where)
    if not ok:
        print(f"MISS\t{path}\t{steplist}")
    elif not exists:
        print(f"GHOST\t{path}\t{steplist}")
    else:
        print(f"OK\t{path}\t{steplist}")

# A declared sparse path that no step reads is not an error, but report it: it is
# either dead weight or a dependency someone removed without updating the checkout.
for p in provided:
    if p != 'VERSION' and not any(r == p or r.startswith(p.rstrip('/') + '/') for r in required):
        print(f"UNUSED\t{p}\t-")
PY
)"

[[ -n "$OUT" ]] || { echo "  [FAIL] the evaluator produced no output — ⛔ an empty result is NOT a pass"; echo "RESULT: FAIL"; exit 1; }

while IFS=$'\t' read -r kind path where; do
    case "$kind" in
        FULL)  echo "  [PASS] $path" ;;
        OK)    echo "  [PASS] $path is provided by the job checkout (read by $where)" ;;
        MISS)
            echo "  [FAIL] $path is READ by $where but is NOT provided by the job's checkout."
            echo "         ⛔ The step cannot run at all. A declaration that is absent from the"
            echo "            workspace is not an empty population — it is an unreachable input,"
            echo "            and this only surfaces at tag time where nothing else can catch it."
            FAIL=1 ;;
        GHOST)
            echo "  [FAIL] $path is checked out and read by $where but does not exist in the repository."
            FAIL=1 ;;
        UNUSED)
            echo "  [WARN] $path is checked out but no step reads it (stale dependency or dead weight)" ;;
        ERR)
            echo "  [FAIL] $path"; FAIL=1 ;;
    esac
done <<< "$OUT"

echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: verify-release workspace precondition PASS"; exit 0; }
echo "RESULT: verify-release workspace precondition FAIL"; exit 1
