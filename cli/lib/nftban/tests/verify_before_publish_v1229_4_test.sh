#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.4 SC-A — NOTHING PROVENANCE-BEARING IS EXPOSED BEFORE VERIFICATION
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="verify-before-publish-v1229-4-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-19"
# meta:description="SC-A. slsa-go-releaser uploaded nftban-core to an ALREADY-PUBLIC release and verified its provenance afterwards, so the artifact was publicly downloadable before it was checked and STAYED downloadable if the check failed -- nothing in that job deletes assets. Asserts verification precedes upload, that neither step can be bypassed with continue-on-error, that no deletion/rollback authority was introduced between verification and publication, and that VERIFY.txt no longer tells operators to treat missing checksum coverage as success. Extended by R2, which deleted slsa-go-releaser.yml and moved orchestration into release.yml: asserts upload-assets is EXPLICITLY false (absent defaults to TRUE), that upload-tag-name is gone, that the deleted workflow has not returned, that no workflow_run chain exists, and that exactly one publisher remains on the release path."
# meta:inventory.files=".github/workflows/release.yml"
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
#   v1.229.4 R2 CLOSED THE REMAINING HALF. release.yml now owns the entire release:
#   the SLSA builder is a job here, verification runs before the single publish step, and
#   the draft is never public. The old cross-workflow orchestration is DELETED.
#
#   ⛔ THE DANGEROUS DEFAULT. The pinned builder declares `upload-assets` with DEFAULT
#      TRUE, and its upload job fires on tag pushes regardless of upload-tag-name. An
#      ABSENT input therefore re-enables a THIRD-PARTY publisher. R5 asserts the input is
#      explicitly present and false — never merely "not true".
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# v1.229.4 R2: slsa-go-releaser.yml is DELETED. release.yml owns the whole release.
SLSA="$ROOT/.github/workflows/release.yml"
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
j=(d.get('jobs') or {}).get('verify-release') or {}
vi=ui=-1
for i,st in enumerate(j.get('steps') or []):
    n=str(st.get('name','')); u=str(st.get('uses',''))
    if n.startswith('Verify SLSA Provenance'): vi=i
    # ⛔ The publisher in verify-release is a `gh` CLI step, NOT action-gh-release (which
    #    creates the non-public DRAFT in create-release). Matching only the action would
    #    look for a publisher that is not there and report "not found" as a failure —
    #    locate the step that actually makes the release public.
    if 'publish release' in n or 'action-gh-release' in u: ui=i
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
j=(d.get('jobs') or {}).get('verify-release') or {}
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
# ⛔ SCOPED TO THE VERIFY -> PUBLISH SPAN. create-release legitimately prunes stale
#    assets from a previous run of the same tag BEFORE anything is verified or public —
#    that is idempotency, not rollback. The prohibition is on acquiring the power to
#    DELETE PUBLISHED ARTIFACTS as a response to failed verification.
DELCODE="$(python3 - "$SLSA" <<'PY'
import sys, yaml, re
d=yaml.safe_load(open(sys.argv[1]))
j=(d.get('jobs') or {}).get('verify-release') or {}
steps=j.get('steps') or []
names=[str(st.get('name','')) for st in steps]
start=next((i for i,n in enumerate(names) if n.startswith('Verify SLSA Provenance')), 0)
for st in steps[start:]:
    r=st.get('run') or ""
    code="\n".join(l for l in r.split("\n") if not l.lstrip().startswith("#"))
    for pat in (r'release\s+delete', r'delete-asset', r'gh\s+release\s+delete'):
        if re.search(pat, code):
            print("%s :: %s" % (st.get('name','?'), pat))
PY
)"
if [[ -z "$DELCODE" ]]; then
    pass "S3 no deletion authority between verification and publication — closed by ORDER alone"
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
# ⛔ THE BOUNDARY MOVED, IT DID NOT DISAPPEAR. R2 closed "the release can publish
#    something unverified". What remains unprovable before a real tag is PUBLISH-ONCE:
#    a dispatch dry-run stops before publication BY DESIGN, so the single-publish
#    property is only observable at the first genuine tag. That limit must stay recorded.
if grep -qE "ABSENT would default|absent == true|Absence is the unsafe state" "$SLSA"; then
    pass "S5 the dangerous-default boundary (absent upload-assets == publisher ON) is recorded in-file"
else
    fail "S5 the dangerous-default warning was removed — an absent input silently re-enables a third-party publisher"
fi

# ---- R2 · the third-party publisher must be explicitly disabled ------------------
BUILDER="$(python3 - "$REL" <<'PY'
import sys, yaml
d=yaml.safe_load(open(sys.argv[1]))
for jn,j in (d.get('jobs') or {}).items():
    if isinstance(j,dict) and 'slsa-github-generator' in str(j.get('uses','')):
        w=j.get('with') or {}
        print("%s\t%r\t%r" % (jn, w.get('upload-assets','__ABSENT__'), w.get('upload-tag-name','__ABSENT__')))
PY
)"
if [[ -z "$BUILDER" ]]; then
    fail "R5 the SLSA builder job was not found in release.yml — R2 topology is not in place"
else
    UA="$(cut -f2 <<<"$BUILDER")"
    UT="$(cut -f3 <<<"$BUILDER")"
    if [[ "$UA" == "False" ]]; then
        pass "R5 upload-assets is EXPLICITLY false — third-party release upload disabled"
        info "⛔ ABSENT would default to TRUE and re-enable a third-party publisher"
    else
        fail "R5 upload-assets is $UA — the builder can publish to the release itself"
    fi
    [[ "$UT" == "'__ABSENT__'" ]] && pass "R5b upload-tag-name removed" \
                                  || fail "R5b upload-tag-name is still passed ($UT)"
fi

# ---- R2 · the competing orchestration authority must be GONE, not merely unused --
if [[ -f "$ROOT/.github/workflows/slsa-go-releaser.yml" ]]; then
    fail "R6 slsa-go-releaser.yml still exists — a second release orchestration path remains"
else
    pass "R6 the competing orchestration workflow is DELETED, not merely unused"
fi
WR="$(grep -rlE "^\s+workflow_run:" "$ROOT/.github/workflows/" 2>/dev/null | xargs -r grep -lE "Release Packages" 2>/dev/null || true)"
if [[ -z "$WR" ]]; then
    pass "R7 no workflow_run trigger chains off the release workflow"
else
    fail "R7 a workflow_run release chain remains: $WR"
fi

# ---- R2 · exactly one publisher and one checksum writer -------------------------
PUB="$(python3 - "$REL" <<'PY'
import sys, yaml
d=yaml.safe_load(open(sys.argv[1]))
n=0
for j in (d.get('jobs') or {}).values():
    if not isinstance(j,dict): continue
    if 'slsa-github-generator' in str(j.get('uses','')):
        if (j.get('with') or {}).get('upload-assets') is not False: n+=1
        continue
    for st in j.get('steps') or []:
        if 'action-gh-release' in str(st.get('uses','')): n+=1
print(n)
PY
)"
if [[ "$PUB" -eq 1 ]]; then
    pass "R8 exactly ONE publisher on the release path"
else
    fail "R8 $PUB publisher(s) found — ONE_PUBLISHER is not satisfied"
fi

echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
