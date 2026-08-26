#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.4 R2 — THE PUBLIC CHECKSUM POPULATION MUST BE DECLARED AND COMPLETE
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="checksum-population-v1229-4-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-20"
# meta:description="R2 / supply-chain item 4. Gate 3 writes the SHA256SUMS users verify against. It used to glob whatever happened to be on disk while an upstream step DECLARED nftban-core required, so the binary vanished from the published checksums without a word. Asserts Gate 3 reads a hand-maintained declaration, fails when it is missing, fails when a declared subject is absent rather than skipping it, and fails when a published file has no build-time ground truth unless it is declared as deriving integrity from signed provenance."
# meta:inventory.files=".github/workflows/release.yml,scripts/ci/data/release-binary-witness-subjects.tsv"
# meta:inventory.privileges="none"
# meta:ta.id="checksum_population_v1229_4_test"
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
#   ⛔ TWO DISTINCT FALSE-GREEN SHAPES LIVE IN THIS ONE STEP:
#
#     G2 population   `binaries=(nftban-core... nftband...)` declared the requirement,
#                     `[[ -f "$f" ]] && all_files+=("$f")` dropped absentees, and
#                     `if [ ${#all_files[@]} -gt 0 ]` asked only "any", never "all".
#                     DECLARED REQUIRED + SILENTLY SKIPPED = a published checksum file
#                     that is missing an artifact users were told to verify.
#
#     G2 cross-check  `if [ -n "$BUILD_HASH" ]` had NO else, so a file with no entry in
#                     SHA256SUMS.build was not cross-validated and said nothing about it.
#                     Harmless until R2 — every subject used to come from build-binaries.
#                     R2 adds nftban-core, built by the SLSA builder and NOT reliably in
#                     SHA256SUMS.build, which turns the silence into a real gap.
#
#   ⛔ The fix is a DECLARATION, not a broader glob. Integrity authority is stated per
#      subject, so "cannot have a build hash" and "should have had one" stop looking alike.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WF="$ROOT/.github/workflows/release.yml"
DECL_SRC="$ROOT/scripts/ci/data/release-binary-witness-subjects.tsv"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }
info(){ echo "        $1"; }

echo "=== public checksum population (v1.229.4 R2 / item 4) ==="
for f in "$WF" "$DECL_SRC"; do
    [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; echo "RESULT: FAIL"; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; echo "RESULT: FAIL"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT

# ---- extract the PRODUCTION step, never a paraphrase of it ----------------------
python3 - "$WF" "$TMP/gate3.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for job in (d.get('jobs') or {}).values():
    if not isinstance(job, dict): continue
    for st in job.get('steps') or []:
        if str(st.get('name','')).startswith('Gate 3'):
            open(sys.argv[2],'w').write(st['run']); sys.exit(0)
sys.exit(3)
PY
[[ -s "$TMP/gate3.sh" ]] || { fail "G0 could not extract the Gate 3 step"; echo "RESULT: FAIL"; exit 1; }
pass "G0 Gate 3 logic extracted from the production workflow"
bash -n "$TMP/gate3.sh" 2>/dev/null && pass "G0b extracted block is syntactically valid" \
                                    || { fail "G0b extracted block has a syntax error"; echo "RESULT: FAIL"; exit 1; }
# ⛔ NONZERO_TEST_RC != EXPECTED FAILURE PROVEN. Without this precondition an invalid
#    block exits non-zero on every arm and each negative control "passes" for the wrong
#    reason. The syntax gate is what makes the arms below mean anything.

# ---- hermetic relocation (path only; no logic, condition or message altered) ------
# ⛔ verify-release reads from the ABSOLUTE /tmp/release-verify. Executing that unmodified
#    would read a SHARED directory: racy against a concurrent run, and able to pass on
#    files this test never created. Assert the rewrite APPLIED — if the workflow renames
#    the directory this sed matches nothing, every arm runs against an empty path and the
#    negative controls all "detect" vacuously.
ABS_DIR="/tmp/release-verify"
grep -qF "$ABS_DIR" "$TMP/gate3.sh" || { fail "G0c Gate 3 no longer references $ABS_DIR — relocation would be vacuous"; echo "RESULT: FAIL"; exit 1; }
sed -i "s|${ABS_DIR}|\$PWD/dist|g" "$TMP/gate3.sh"
grep -qF "$ABS_DIR" "$TMP/gate3.sh" && { fail "G0c relocation incomplete — an absolute path survived"; echo "RESULT: FAIL"; exit 1; }
pass "G0c artifact directory relocated to the per-case sandbox"

# ---- scenario builder -----------------------------------------------------------
# $1 case name · $2 declaration body (tsv) · $3 files to create · $4 build-hash subjects
build(){
    local d="$TMP/$1"; rm -rf "$d"; mkdir -p "$d/dist" "$d/scripts/ci/data"
    printf '%b' "$2" > "$d/scripts/ci/data/release-binary-witness-subjects.tsv"
    local f
    for f in $3; do printf 'content-of-%s\n' "$f" > "$d/dist/$f"; done
    ( cd "$d/dist" || exit 1
      : > SHA256SUMS.build
      for f in $4; do [[ -f "$f" ]] && sha256sum "$f" >> SHA256SUMS.build; done
      sort -o SHA256SUMS.build SHA256SUMS.build )
    printf '%s' "$d"
}
run_g3(){ ( cd "$1" && GITHUB_WORKSPACE="$1" bash "$TMP/gate3.sh" 2>&1 ); }
rc_g3(){  ( cd "$1" && GITHUB_WORKSPACE="$1" bash "$TMP/gate3.sh" >/dev/null 2>&1 ); echo $?; }

DECL_OK='# fixture\nsubject\tnftband-linux-amd64\tbuild-checksum\nsubject\tnftban-core-linux-amd64\tslsa-provenance\nexpected_total\t2\n'
BOTH='nftband-linux-amd64 nftban-core-linux-amd64'

# ---- POSITIVE · the shipped shape must actually pass -----------------------------
# ⛔ Without this the negative arms prove only that the step can fail, which every broken
#    script does. The positive is what makes the negatives discriminating.
d="$(build pos "$DECL_OK" "$BOTH" "nftband-linux-amd64")"
out="$(run_g3 "$d")"; rc="$(rc_g3 "$d")"
if [[ "$rc" -eq 0 ]]; then
    pass "POS complete declared population with mixed integrity authorities -> PASS"
    grep -q 'integrity authority = slsa-provenance' <<<"$out" \
        && info "nftban-core classified by declaration, not skipped by silence"
else
    fail "POS the shipped shape did not pass (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -5
fi

# ---- N1 · the declaration itself is missing --------------------------------------
d="$(build n1 "$DECL_OK" "$BOTH" "nftband-linux-amd64")"
rm -f "$d/scripts/ci/data/release-binary-witness-subjects.tsv"
out="$(run_g3 "$d")"; rc="$(rc_g3 "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF '::error title=Checksum subject declaration missing::' <<<"$out"; then
    pass "N1 missing declaration -> FAIL (⛔ MISSING DECLARATION != EMPTY POPULATION)"
else
    fail "N1 a missing declaration did not fail (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -3
fi

# ---- N2 · a DECLARED subject was never downloaded --------------------------------
# This is the exact v1.229.3 defect: nftban-core declared required, absent, published anyway.
d="$(build n2 "$DECL_OK" "nftband-linux-amd64" "nftband-linux-amd64")"
out="$(run_g3 "$d")"; rc="$(rc_g3 "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF '::error title=Required checksum subject missing::' <<<"$out"; then
    pass "N2 declared subject absent at finalization -> FAIL (ABSENCE IS NOT A SKIP)"
    info "⛔ the pre-R2 step published SHA256SUMS without it and said nothing"
else
    fail "N2 an absent declared subject did not fail (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -3
fi

# ---- N3 · published file with NO build hash and NO declared provenance authority --
# The branch that did not exist before R2. nftban-core is declared build-checksum here,
# so its missing SHA256SUMS.build entry is a real gap rather than a design property.
DECL_MISCLASS='# fixture\nsubject\tnftband-linux-amd64\tbuild-checksum\nsubject\tnftban-core-linux-amd64\tbuild-checksum\nexpected_total\t2\n'
d="$(build n3 "$DECL_MISCLASS" "$BOTH" "nftband-linux-amd64")"
out="$(run_g3 "$d")"; rc="$(rc_g3 "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF '::error title=Checksum cross-check silently skipped::' <<<"$out"; then
    pass "N3 published file with no ground truth -> FAIL (UNCHECKABLE-BY-DESIGN != ACCIDENTALLY-UNCHECKED)"
else
    fail "N3 a silently uncross-checked published file did not fail (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -3
fi

# ---- N4 · an UNDECLARED file appears in the published checksums -------------------
# A subject nobody declared must not ride along on a glob with no ground truth.
d="$(build n4 "$DECL_OK" "$BOTH stowaway-linux-amd64" "nftband-linux-amd64")"
out="$(run_g3 "$d")"; rc="$(rc_g3 "$d")"
if [[ "$rc" -ne 0 ]] && grep -qF '<undeclared>' <<<"$out"; then
    pass "N4 an undeclared published binary -> FAIL, and is reported as <undeclared>"
else
    fail "N4 an undeclared binary was published without a ground truth (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -3
fi

# ---- N5 · a corrupted asset must still fail the cross-check ----------------------
# ⛔ Guards against the repair having disabled the ORIGINAL comparison while adding the
#    new classification branch. The else-branch must not become an escape hatch.
d="$(build n5 "$DECL_OK" "$BOTH" "nftband-linux-amd64")"
printf 'tampered\n' > "$d/dist/nftband-linux-amd64"
out="$(run_g3 "$d")"; rc="$(rc_g3 "$d")"
if [[ "$rc" -ne 0 ]] && grep -q 'SHA256SUMS != SHA256SUMS.build' <<<"$out"; then
    pass "N5 an asset whose content changed after build -> FAIL (the original comparison still bites)"
else
    fail "N5 a tampered asset passed the cross-check (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -3
fi

# ---- DECL · the shipped declaration is real, coherent and hand-maintained ---------
DC=$(awk -F'\t' '$1=="subject" && NF>=3' "$DECL_SRC" | wc -l | tr -d ' ')
EC=$(awk -F'\t' '$1=="expected_total"{print $2; exit}' "$DECL_SRC" | tr -d '[:space:]')
if [[ "$DC" -gt 0 && "$DC" == "$EC" ]]; then
    pass "DECL every shipped subject declares an integrity authority (subjects=$DC expected_total=$EC)"
else
    fail "DECL declaration incoherent or a subject lacks an integrity authority (with-authority=$DC expected_total=$EC)"
fi
UNKNOWN="$(awk -F'\t' '$1=="subject" && $3!="build-checksum" && $3!="slsa-provenance" {print $2" -> "$3}' "$DECL_SRC")"
if [[ -z "$UNKNOWN" ]]; then
    pass "DECL2 every declared integrity authority is one Gate 3 actually understands"
else
    fail "DECL2 unrecognised integrity authority — Gate 3 would treat it as a gap:"
    sed 's/^/          /' <<<"$UNKNOWN"
fi

echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
