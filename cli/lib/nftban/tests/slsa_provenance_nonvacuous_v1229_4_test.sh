#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.4 VAF-0 Stage 1 — SLSA VERIFICATION MUST NOT BE VACUOUS
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="slsa-provenance-nonvacuous-v1229-4-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-19"
# meta:description="VAF-0 Stage 1. The SLSA provenance verifier carried three vacuity layers at once: a glob that could match nothing left VERIFY_FAILED=0 and reported success, an -f test with no else silently skipped a SHIPPED BINARY THAT HAD NO PROVENANCE, and no expected population was ever asserted. The second was a live FALSE SECURITY CLAIM about a specific artifact. Executes the verification logic EXTRACTED FROM THE PRODUCTION WORKFLOW against a declared subject population and proves that zero subjects, a missing binary, a missing provenance file, a non-binding provenance, and a short count all FAIL."
# meta:inventory.files=".github/workflows/release.yml,scripts/ci/data/slsa-subjects.tsv"
# meta:inventory.privileges="none"
# meta:ta.id="slsa_provenance_nonvacuous_v1229_4_test"
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
#   SLSA_VALIDATION_FALSE_GREEN — three witnesses, ONE validator:
#
#     L1  ZERO_SUBJECT_ITERATION            0 iterations -> rc0 -> "verified"
#     L2  REQUIRED_SUBJECT_ABSENCE_SKIPPED  no provenance -> silently skipped -> PASS
#     L3  EXPECTED_POPULATION_NOT_ASSERTED  nothing declared what should be verified
#
#   ⛔ PROVENANCE_FILES_FOUND MUST NOT DEFINE PROVENANCE_FILES_EXPECTED.
#      Enumerating the expectation from disk would let a missing provenance vanish from
#      the enumeration, shrinking the expectation to match reality — the false green
#      would survive the fix.
#
#   ⛔ SCOPE OF THIS TEST: the validator's CONTROL FLOW — population, absence, binding
#      propagation, coverage count. slsa-verifier's cryptography is NOT under test; a stub
#      stands in for it via SLSA_VERIFIER_BIN so the arms are hermetic and offline. The
#      seam is deliberate and narrow: the stub decides only pass/fail, never the shape.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# ⛔ v1.229.4 R2 relocated the verification steps into release.yml and DELETED
#    slsa-go-releaser.yml. The validator logic under test is unchanged; only its host
#    workflow moved. Retargeted so this control keeps a live subject.
WF="$ROOT/.github/workflows/release.yml"
DECL_SRC="$ROOT/scripts/ci/data/slsa-subjects.tsv"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }
info(){ echo "        $1"; }

echo "=== SLSA provenance verification non-vacuity (v1.229.4 VAF-0 Stage 1) ==="
# ⛔ Repo-resident subjects: absence is a FAILURE, never a skip.
for f in "$WF" "$DECL_SRC"; do
    [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; echo "RESULT: FAIL"; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; echo "RESULT: FAIL"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT

python3 - "$WF" "$TMP/verify.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for job in d.get('jobs', {}).values():
    if not isinstance(job, dict): continue
    for st in job.get('steps', []) or []:
        if str(st.get('name','')) == 'Verify SLSA Provenance':
            open(sys.argv[2],'w').write(st['run']); sys.exit(0)
sys.exit(3)
PY
[[ -s "$TMP/verify.sh" ]] || { fail "G0 could not extract 'Verify SLSA Provenance' from the workflow"; echo "RESULT: FAIL"; exit 1; }
pass "G0 verification logic extracted from the production workflow"

# ---- hermetic relocation of the artifact directory -------------------------------
# ⛔ verify-release reads artifacts from the ABSOLUTE path /tmp/release-verify (the
#    pre-existing convention of that job, not something R2 introduced). A control that
#    executed it unmodified would read a SHARED real directory: non-hermetic, racy
#    against a concurrent run, and able to "pass" on files this test never created.
#    Only the PATH is relocated to the per-case sandbox — no logic, no condition and no
#    message is altered.
# ⛔ ASSERT THE SUBSTITUTION APPLIED. If the workflow later renames that directory this
#    sed silently matches nothing, every arm runs against an empty path, and the negative
#    controls all "detect" for the wrong reason. A rewrite that no longer matches its
#    subject is a vacuous control, so its absence is a hard failure.
ABS_DIR="/tmp/release-verify"
if ! grep -qF "$ABS_DIR" "$TMP/verify.sh"; then
    fail "G0c the extracted step no longer references $ABS_DIR — the relocation would be vacuous"
    info "⛔ the arms below would test an empty directory and pass for the wrong reason"
    echo "RESULT: FAIL"; exit 1
fi
sed -i "s|${ABS_DIR}|\$PWD/dist|g" "$TMP/verify.sh"
grep -qF "$ABS_DIR" "$TMP/verify.sh" && { fail "G0c relocation incomplete — an absolute path survived"; echo "RESULT: FAIL"; exit 1; }
pass "G0c artifact directory relocated to the per-case sandbox (path only; logic untouched)"
bash -n "$TMP/verify.sh" 2>/dev/null && pass "G0b extracted block is syntactically valid" \
                                     || { fail "G0b extracted block has a syntax error"; echo "RESULT: FAIL"; exit 1; }

# ⛔ NONZERO_TEST_RC != EXPECTED FAILURE PROVEN — the syntax precondition above exists
#    because an invalid block exits non-zero for EVERY arm, which would make every
#    negative control "pass" for the wrong reason.

# ---- stub verifier: decides ONLY pass/fail, never the control flow --------------
mk_stub(){ # $1 = exit code
    printf '#!/usr/bin/env bash\nexit %s\n' "$1" > "$TMP/slsa-verifier"
    chmod +x "$TMP/slsa-verifier"
}

# ---- scenario builder ----------------------------------------------------------
# $1 = case dir  $2 = declared rows (tsv body)  $3 = expected_count
build(){
    local d="$TMP/$1"; rm -rf "$d"; mkdir -p "$d/dist" "$d/scripts/ci/data"
    {
      printf '# hermetic fixture declaration\n'
      printf '%b' "$2"
      printf 'expected_count\t%s\n' "$3"
      printf 'source_uri\tgithub.com/itcmsgr/nftban\n'
    } > "$d/scripts/ci/data/slsa-subjects.tsv"
    printf '%s' "$d"
}
run_case(){ ( cd "$1" && SLSA_VERIFIER_BIN="$TMP/slsa-verifier" bash "$TMP/verify.sh" 2>&1 ); }
rc_case(){ ( cd "$1" && SLSA_VERIFIER_BIN="$TMP/slsa-verifier" bash "$TMP/verify.sh" >/dev/null 2>&1 ); echo $?; }

ROW_CORE='subject\tnftban-core-linux-amd64\tnftban-core-linux-amd64.intoto.jsonl\n'
mk_stub 0

# ---- POSITIVE · complete population, every binding valid -----------------------
d="$(build pos "$ROW_CORE" 1)"
: > "$d/dist/nftban-core-linux-amd64"
: > "$d/dist/nftban-core-linux-amd64.intoto.jsonl"
out="$(run_case "$d")"; rc="$(rc_case "$d")"
if [[ "$rc" -eq 0 ]] && grep -q 'verified for all 1 declared subject' <<<"$out"; then
    pass "POSITIVE complete declared population with valid bindings -> PASS"
else
    fail "POSITIVE a complete, valid population did not pass (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -3
fi

# ---- S1 · ZERO matching provenance subjects (L1) --------------------------------
# Empty dist/ entirely: the old glob matched nothing and reported success.
d="$(build s1 "$ROW_CORE" 1)"
out="$(run_case "$d")"; rc="$(rc_case "$d")"
if [[ "$rc" -ne 0 ]] && grep -q '::error title=SLSA subject binary missing::' <<<"$out"; then
    pass "S1 zero subjects present on disk -> FAIL (L1 closed: 0 iterations is not a pass)"
else
    fail "S1 an empty dist/ did not fail (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -3
fi

# ---- S1b · a DECLARED-EMPTY population must also fail ---------------------------
d="$(build s1b "" 0)"
out="$(run_case "$d")"; rc="$(rc_case "$d")"
if [[ "$rc" -ne 0 ]] && grep -q '::error title=SLSA population empty::' <<<"$out"; then
    pass "S1b a declaration listing ZERO subjects -> FAIL (L3 closed)"
else
    fail "S1b an empty declared population did not fail (rc=$rc)"
fi

# ---- S2 · binary ships but provenance is MISSING (L2 — the false claim) ---------
d="$(build s2 "$ROW_CORE" 1)"
: > "$d/dist/nftban-core-linux-amd64"          # provenance deliberately absent
out="$(run_case "$d")"; rc="$(rc_case "$d")"
if [[ "$rc" -ne 0 ]] && grep -q '::error title=SLSA provenance missing::' <<<"$out"; then
    pass "S2 shipped binary with NO provenance -> FAIL (L2 closed)"
    info "⛔ the pre-fix validator PASSED this exact state — a false security claim"
else
    fail "S2 a binary without provenance did not fail (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -3
fi

# ---- S3 · provenance exists but does NOT bind ----------------------------------
mk_stub 1
d="$(build s3 "$ROW_CORE" 1)"
: > "$d/dist/nftban-core-linux-amd64"
: > "$d/dist/nftban-core-linux-amd64.intoto.jsonl"
out="$(run_case "$d")"; rc="$(rc_case "$d")"
if [[ "$rc" -ne 0 ]] && grep -q '::error title=SLSA provenance binding failed::' <<<"$out"; then
    pass "S3 provenance present but not binding -> FAIL (verifier failure propagates)"
else
    fail "S3 a non-binding provenance did not fail (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -3
fi
mk_stub 0

# ---- S4 · expected N, verified N-1 ---------------------------------------------
# Two declared subjects, only the first fully present.
d="$(build s4 "${ROW_CORE}subject\tnftband-linux-amd64\tnftband-linux-amd64.intoto.jsonl\n" 2)"
: > "$d/dist/nftban-core-linux-amd64"
: > "$d/dist/nftban-core-linux-amd64.intoto.jsonl"
out="$(run_case "$d")"; rc="$(rc_case "$d")"
if [[ "$rc" -ne 0 ]]; then
    pass "S4 expected 2, one subject unverifiable -> FAIL (partial coverage is not a pass)"
else
    fail "S4 a partial population passed (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -3
fi

# ---- S5 · declaration count incoherent with declared rows ----------------------
d="$(build s5 "$ROW_CORE" 3)"
: > "$d/dist/nftban-core-linux-amd64"
: > "$d/dist/nftban-core-linux-amd64.intoto.jsonl"
out="$(run_case "$d")"; rc="$(rc_case "$d")"
if [[ "$rc" -ne 0 ]] && grep -q '::error title=SLSA declaration incoherent::' <<<"$out"; then
    pass "S5 subject rows != expected_count -> FAIL (a silently removed subject cannot pass)"
else
    fail "S5 an incoherent declaration passed (rc=$rc)"
fi

# ---- S6 · the declaration itself is missing ------------------------------------
d="$(build s6 "$ROW_CORE" 1)"
rm -f "$d/scripts/ci/data/slsa-subjects.tsv"
: > "$d/dist/nftban-core-linux-amd64"
: > "$d/dist/nftban-core-linux-amd64.intoto.jsonl"
out="$(run_case "$d")"; rc="$(rc_case "$d")"
if [[ "$rc" -ne 0 ]] && grep -q '::error title=SLSA subject declaration missing::' <<<"$out"; then
    pass "S6 a missing declaration -> FAIL (⛔ MISSING DECLARATION != EMPTY POPULATION)"
else
    fail "S6 a missing declaration did not fail (rc=$rc)"
fi

# ---- the SHIPPED declaration must be real and coherent -------------------------
DC=$(awk -F'\t' '$1=="subject" && NF>=3' "$DECL_SRC" | wc -l | tr -d ' ')
EC=$(awk -F'\t' '$1=="expected_count"{print $2; exit}' "$DECL_SRC" | tr -d '[:space:]')
if [[ "$DC" -gt 0 && "$DC" == "$EC" ]]; then
    pass "DECL the shipped declaration is non-empty and coherent (subjects=$DC expected_count=$EC)"
else
    fail "DECL the shipped declaration is empty or incoherent (subjects=$DC expected_count=$EC)"
fi
# ⛔ The declaration must not be machine-generated from disk contents.
if grep -qiE '^\s*(ls|find|glob)' "$DECL_SRC"; then
    fail "DECL2 the declaration appears to contain enumeration logic — it must be hand-maintained"
else
    pass "DECL2 the declaration is declarative data, not an enumeration of what exists"
fi

echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
