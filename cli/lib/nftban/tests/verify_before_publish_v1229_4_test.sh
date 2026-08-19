#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.4 SC-A — NOTHING PROVENANCE-BEARING IS EXPOSED BEFORE VERIFICATION
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="verify-before-publish-v1229-4-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-19"
# meta:description="SC-A. slsa-go-releaser uploaded nftban-core to an ALREADY-PUBLIC release and verified its provenance afterwards, so the artifact was publicly downloadable before it was checked and STAYED downloadable if the check failed -- nothing in that job deletes assets. Asserts verification precedes upload, that neither step can be bypassed with continue-on-error, that no deletion/rollback authority was introduced, and that VERIFY.txt no longer tells operators to treat missing checksum coverage as success."
# meta:inventory.files=".github/workflows/slsa-go-releaser.yml,.github/workflows/release.yml"
# meta:inventory.privileges="none"
# meta:ta.id="verify_before_publish_v1229_4_test"
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
#   PRE-PUBLICATION VERIFICATION > POST-PUBLICATION DETECTION + ROLLBACK
#   PARTIAL PROGRESS != SAFE INTERMEDIATE STATE
#
#   ⛔ CLAIM BOUNDARY. This proves a provenance-bearing artifact cannot be UPLOADED
#      before its verification succeeds. It does NOT prove the whole GitHub release
#      cannot become public before all release verification — the release is published
#      by release.yml BEFORE this workflow is triggered at all. That remains R2's
#      subject (release-topology recon) and ITEM 4 stays OPEN behind it.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SLSA="$ROOT/.github/workflows/slsa-go-releaser.yml"
REL="$ROOT/.github/workflows/release.yml"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }
info(){ echo "        $1"; }

echo "=== verify before publish (v1.229.4 SC-A) ==="
for f in "$SLSA" "$REL"; do
    [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; echo "RESULT: FAIL"; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; echo "RESULT: FAIL"; exit 1; }

# ---- S1 · ORDER: verification must precede the upload --------------------------
ORDER="$(python3 - "$SLSA" <<'PY'
import sys, yaml
d=yaml.safe_load(open(sys.argv[1]))
j=(d.get('jobs') or {}).get('assemble-release') or {}
vi=ui=-1
for i,st in enumerate(j.get('steps') or []):
    n=str(st.get('name','')); u=str(st.get('uses',''))
    if n.startswith('Verify SLSA Provenance'): vi=i
    if 'action-gh-release' in u:               ui=i
print("%d %d" % (vi,ui))
PY
)"
set -- $ORDER
VI="${1:--1}"; UI="${2:--1}"
if [[ "$VI" -lt 0 || "$UI" -lt 0 ]]; then
    fail "S1 could not locate both the verification and upload steps (verify=$VI upload=$UI)"
elif [[ "$VI" -lt "$UI" ]]; then
    pass "S1 verification (step $((VI+1))) precedes upload (step $((UI+1)))"
    info "verification failure therefore aborts the job BEFORE the artifact is exposed"
else
    fail "S1 UPLOAD PRECEDES VERIFICATION — an unverified artifact becomes public first"
fi

# ---- S2 · neither step may be bypassed -----------------------------------------
# A `continue-on-error` on verification would restore the defect while keeping the order.
BYPASS="$(python3 - "$SLSA" <<'PY'
import sys, yaml
d=yaml.safe_load(open(sys.argv[1]))
j=(d.get('jobs') or {}).get('assemble-release') or {}
out=[]
for st in j.get('steps') or []:
    n=str(st.get('name','')); u=str(st.get('uses',''))
    if n.startswith('Verify SLSA Provenance') or 'action-gh-release' in u:
        if str(st.get('continue-on-error','')).lower() in ('true','1'):
            out.append(n or u)
        c=str(st.get('if',''))
        if c and 'always()' in c:
            out.append((n or u)+" [if: always()]")
for o in out: print(o)
PY
)"
if [[ -z "$BYPASS" ]]; then
    pass "S2 neither verification nor upload is bypassable (no continue-on-error, no always())"
else
    fail "S2 a bypass was introduced on a load-bearing step:"
    sed 's/^/          /' <<<"$BYPASS"
fi

# ---- S3 · NO deletion/rollback authority was introduced -------------------------
# The fix must close the window by ORDERING, not by acquiring the power to delete
# published assets. ⛔ CODE ONLY — the step comments describe the old defect.
DELCODE="$(python3 - "$SLSA" <<'PY'
import sys, yaml, re
d=yaml.safe_load(open(sys.argv[1]))
for j in (d.get('jobs') or {}).values():
    if not isinstance(j,dict): continue
    for st in j.get('steps') or []:
        r=st.get('run') or ""
        code="\n".join(l for l in r.split("\n") if not l.lstrip().startswith("#"))
        for pat in (r'release\s+delete', r'delete-asset', r'gh\s+release\s+delete', r'--delete'):
            if re.search(pat, code):
                print("%s :: %s" % (st.get('name','?'), pat))
PY
)"
if [[ -z "$DELCODE" ]]; then
    pass "S3 no deletion/rollback authority added — the window is closed by ORDER alone"
else
    fail "S3 a deletion authority appeared in the release path:"
    sed 's/^/          /' <<<"$DELCODE"
fi

# ---- S4 · VERIFY.txt must not turn missing coverage into success -----------------
VTXT="$(python3 - "$REL" <<'PY'
import sys, yaml
d=yaml.safe_load(open(sys.argv[1]))
for j in (d.get('jobs') or {}).values():
    if not isinstance(j,dict): continue
    for st in j.get('steps') or []:
        if str(st.get('name',''))=='Create VERIFY.txt':
            print(st.get('run','')); sys.exit(0)
PY
)"
if [[ -z "$VTXT" ]]; then
    fail "S4 could not extract the VERIFY.txt step"
else
    # The operator must be told to check their file BY NAME, and that an absent entry
    # is not a pass. A bare --ignore-missing as the only instruction is the defect.
    HAS_BYNAME=0; HAS_ABSENCE=0
    grep -q 'sha256sum -c -' <<<"$VTXT" && HAS_BYNAME=1
    grep -qiE 'NOT a pass|no published checksum' <<<"$VTXT" && HAS_ABSENCE=1
    if [[ "$HAS_BYNAME" -eq 1 && "$HAS_ABSENCE" -eq 1 ]]; then
        pass "S4 VERIFY.txt requires a per-file check and states that absence is NOT a pass"
    else
        fail "S4 VERIFY.txt still lets missing checksum coverage read as success (byname=$HAS_BYNAME absence=$HAS_ABSENCE)"
    fi
fi

# ---- S5 · the claim boundary must stay recorded in the workflow ------------------
# ⛔ ITEM 4 IS STILL OPEN. If this comment disappears, a reader could conclude the
#    release cannot publish anything unverified, which is NOT what SC-A proves.
if grep -q "R2's" "$SLSA" || grep -q "does NOT yet prove" "$SLSA"; then
    pass "S5 the claim boundary (release publication is R2's subject) is recorded in-file"
else
    fail "S5 the claim boundary was removed — SC-A must not read as full publication safety"
fi

echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
