#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.4 VAF-0 Stage 3D — EXPECTED-FAILURE IDIOM + FIXTURE IDENTITY
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# meta:name="vaf0-stage3d-controls-v1229-4-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-19"
# meta:description="VAF-0 Stage 3D. (A) An expected-failure assertion must prove the subject was reached, the command executed, the status was non-zero AND the expected semantic signal was observed -- during C1b a draft with invalid shell syntax exited 2 for every arm, so several inversion arms 'passed' on the wrong failure mode entirely. (B) A displayed fixture identity must derive from content bytes and fixture-relative names, never from sha256sum output that serializes the absolute path: the F2 control printed two different digests for byte-identical fixtures purely because the checkout directory differed."
# meta:inventory.files="scripts/ci/check-security-observation-integrity.sh,cli/lib/nftban/tests/vaf_tier_a_instrument_health_v1229_4_test.sh"
# meta:inventory.privileges="none"
# meta:ta.id="vaf0_stage3d_controls_v1229_4_test"
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
#   ⛔ NONZERO_TEST_RC != EXPECTED FAILURE PROVEN
#   ⛔ WRONG FAILURE MODE != EXPECTED NEGATIVE CONTROL
#   ⛔ CONTENT IDENTITY MUST DERIVE FROM CONTENT BYTES
#
#   No new failure harness is introduced. The semantic already exists in
#   scripts/ci/run-test-suite.sh, which accepts a quarantined failure ONLY when the
#   captured output matches a registered expected_failure_pattern. Stage 3D adopts that
#   idiom in the Stage-3 controls; it does NOT refactor the runner or the registry.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
GUARD="$ROOT/scripts/ci/check-security-observation-integrity.sh"
F2TEST="$SCRIPT_DIR/vaf_tier_a_instrument_health_v1229_4_test.sh"
FIXROOT="$SCRIPT_DIR/fixtures/vaf_tier_a/govulncheck/db"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }
info(){ echo "        $1"; }

echo "=== VAF-0 Stage 3D controls (v1.229.4) ==="
for f in "$GUARD" "$F2TEST"; do
    [[ -f "$f" ]] || { echo "  SUBJECT_NOT_FOUND: $f"; echo "RESULT: FAIL"; exit 1; }
done
[[ -d "$FIXROOT" ]] || { echo "  SUBJECT_NOT_FOUND: $FIXROOT"; echo "RESULT: FAIL"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT

# =============================================================================
# 3D-A · EXPECTED-FAILURE SEMANTIC IDIOM
# =============================================================================
#   EXPECTED FAILURE PROVEN =
#       subject/precondition reached
#     + command actually executed
#     + non-zero status
#     + EXPECTED SEMANTIC SIGNAL observed
SUBJ="$TMP/guard.sh"
cp "$GUARD" "$SUBJ"

# ---- A0 · PRECONDITION: the subject must be executable shell -------------------
# Without this, a syntactically broken subject exits non-zero for EVERY arm and each
# negative control "passes" for a reason that has nothing to do with the property.
if bash -n "$SUBJ" 2>/dev/null; then
    pass "A0 PRECONDITION: the subject is syntactically valid and therefore reachable"
else
    fail "A0 the subject is not valid shell — no expected-failure claim can be made about it"
    echo "RESULT: FAIL"; exit 1
fi

# ---- A1 · the CORRECT expected-failure arm ------------------------------------
# Genuine defect injected: gosec's status swallowed with no consumer. The guard must exit
# non-zero AND emit its own semantic signal for THAT property.
WORK="$TMP/repo"; mkdir -p "$WORK"
cp -r "$ROOT/.github" "$ROOT/scripts" "$WORK/" 2>/dev/null
python3 - "$WORK" <<'PY'
import sys
p=sys.argv[1]+"/.github/workflows/secure-go.yml"
s=open(p).read()
a=s.index('      - name: Run gosec (SARIF)')
b=s.index('      - name: Fix gosec SARIF relationships')
open(p,"w").write(s[:a]+'      - name: Run gosec (SARIF)\n        run: gosec -fmt sarif -out gosec.sarif ./... || true\n\n'+s[b:])
PY
set +e
OUT_A1="$(cd "$WORK" && bash scripts/ci/check-security-observation-integrity.sh 2>&1)"
RC_A1=$?
set -e
SIGNAL_A1='\[FAIL\] G1 .*Run gosec \(SARIF\).*NO status capture or consumer'
if [[ "$RC_A1" -ne 0 ]] && grep -qE "$SIGNAL_A1" <<<"$OUT_A1"; then
    pass "A1 EXPECTED FAILURE PROVEN: non-zero AND the expected semantic signal is present"
else
    fail "A1 the expected-failure arm did not observe its signal (rc=$RC_A1)"
fi

# ---- A2 · WRONG FAILURE MODE must NOT satisfy the same expectation -------------
# THE C1b REPRODUCTION. The implementation is broken so it cannot run at all: rc is
# non-zero, but for a reason unrelated to the property under test, and the signal never
# appears. A bare `rc != 0` assertion accepts this; the correct assertion rejects it.
WORK2="$TMP/repo2"; mkdir -p "$WORK2"
cp -r "$ROOT/.github" "$ROOT/scripts" "$WORK2/" 2>/dev/null
# ⛔ The break must be EARLY. An earlier revision of this control APPENDED the broken
#    syntax after the script's final `exit`, so it was never reached and the subject exited
#    0 — the reproduction silently tested nothing. Injecting after the options line makes
#    the parse failure unavoidable.
python3 - "$WORK2/scripts/ci/check-security-observation-integrity.sh" <<'BRK'
import sys
p=sys.argv[1]; s=open(p).read()
i=s.index("set -uo pipefail")+len("set -uo pipefail")
open(p,"w").write(s[:i]+"\nif then fi(( unbalanced\n"+s[i:])
BRK
set +e
OUT_A2="$(cd "$WORK2" && bash scripts/ci/check-security-observation-integrity.sh 2>&1)"
RC_A2=$?
set -e
NAIVE_WOULD_PASS=false;  [[ "$RC_A2" -ne 0 ]] && NAIVE_WOULD_PASS=true
STRICT_PASSES=false
{ [[ "$RC_A2" -ne 0 ]] && grep -qE "$SIGNAL_A1" <<<"$OUT_A2"; } && STRICT_PASSES=true
if [[ "$NAIVE_WOULD_PASS" == true && "$STRICT_PASSES" == false ]]; then
    pass "A2 WRONG FAILURE MODE rejected: rc=$RC_A2 (non-zero) but the expected signal is ABSENT"
    info "⛔ a bare \`rc != 0\` assertion WOULD have passed here — that is the C1b false evidence"
elif [[ "$NAIVE_WOULD_PASS" == false ]]; then
    fail "A2 the broken subject exited 0 — the reproduction is not exercising the trap"
else
    fail "A2 the strict assertion accepted a wrong failure mode (rc=$RC_A2)"
fi

# ---- A3 · a syntax precondition detects the broken subject ---------------------
if bash -n "$WORK2/scripts/ci/check-security-observation-integrity.sh" 2>/dev/null; then
    fail "A3 the syntax precondition did not detect a deliberately broken subject"
else
    pass "A3 the syntax precondition detects the broken subject BEFORE any arm is believed"
fi

# =============================================================================
# 3D-B · FIXTURE IDENTITY MUST BE PATH-INDEPENDENT
# =============================================================================
# The function is EXTRACTED FROM THE SHIPPED TEST so these arms bind to the real
# implementation rather than to a copy of it.
python3 - "$F2TEST" "$TMP/ident.sh" <<'PY'
import sys, re
src=open(sys.argv[1], encoding="utf-8").read()
m=re.search(r'^fixture_identity\(\)\{.*?^\}', src, re.S | re.M)
if not m: sys.exit(3)
open(sys.argv[2],"w").write(m.group(0)+"\n")
PY
if [[ ! -s "$TMP/ident.sh" ]]; then
    fail "B0 could not extract fixture_identity() from the shipped F2 control"
    echo "RESULT: FAIL"; exit 1
fi
pass "B0 fixture_identity() extracted from the shipped F2 control"
# shellcheck disable=SC1090
. "$TMP/ident.sh"

mkA(){ mkdir -p "$1"; cp -r "$FIXROOT/." "$1/"; }

# ---- D-P1 · same bytes, different checkout path -------------------------------
mkA "$TMP/pathA/db"; mkA "$TMP/some/deeper/pathB/db"
IA="$(fixture_identity "$TMP/pathA/db")"
IB="$(fixture_identity "$TMP/some/deeper/pathB/db")"
if [[ -n "$IA" && "$IA" == "$IB" ]]; then
    pass "D-P1 identical bytes at different paths -> identical identity (${IA:0:12}…)"
else
    fail "D-P1 identity varied with the checkout path (A=${IA:0:12}… B=${IB:0:12}…)"
fi

# ---- D-P2 · mtime variation must not change identity --------------------------
find "$TMP/some/deeper/pathB/db" -type f -exec touch -d '2001-01-01 00:00:00' {} +
IB2="$(fixture_identity "$TMP/some/deeper/pathB/db")"
[[ "$IA" == "$IB2" ]] && pass "D-P2 mtime variation does not change identity" \
                      || fail "D-P2 identity changed with mtime"

# ---- D-N1 · one byte of content changes the identity --------------------------
mkA "$TMP/mut/db"; printf ' ' >> "$TMP/mut/db/index/db.json"
IM="$(fixture_identity "$TMP/mut/db")"
[[ "$IM" != "$IA" ]] && pass "D-N1 a one-byte content change CHANGES the identity" \
                     || fail "D-N1 a content mutation did not change the identity"

# ---- D-N2 · membership change (add / remove) changes the identity -------------
mkA "$TMP/add/db"; printf '{}' > "$TMP/add/db/index/extra.json"
IADD="$(fixture_identity "$TMP/add/db")"
mkA "$TMP/del/db"; rm -f "$TMP/del/db/index/vulns.json"
IDEL="$(fixture_identity "$TMP/del/db")"
if [[ "$IADD" != "$IA" && "$IDEL" != "$IA" ]]; then
    pass "D-N2 adding OR removing a fixture member changes the identity"
    info "fixture-relative NAME is part of identity, so a rename or swap cannot hide"
else
    fail "D-N2 a membership change did not change the identity (add=${IADD:0:12}… del=${IDEL:0:12}…)"
fi

# ---- D-N3 · traversal order must not change identity --------------------------
# Recreate the same content in a different creation order; find(1) order may differ.
mkdir -p "$TMP/ord/db/index" "$TMP/ord/db/ID"
cp "$FIXROOT/index/vulns.json"   "$TMP/ord/db/index/vulns.json"
cp "$FIXROOT/ID/GO-9999-0001.json" "$TMP/ord/db/ID/GO-9999-0001.json"
cp "$FIXROOT/index/db.json"      "$TMP/ord/db/index/db.json"
cp "$FIXROOT/index/modules.json" "$TMP/ord/db/index/modules.json"
IO="$(fixture_identity "$TMP/ord/db")"
[[ "$IO" == "$IA" ]] && pass "D-N3 filesystem traversal/creation order does not change identity" \
                     || fail "D-N3 identity depended on traversal order (${IO:0:12}… vs ${IA:0:12}…)"

# ---- B-STATIC · the identity must not be built from sha256sum-with-path --------
# ⛔ CODE ONLY: the helper's comment quotes the old defective form to explain it.
IDENT_CODE="$(grep -vE '^[[:space:]]*#' "$TMP/ident.sh")"
if grep -qE 'sha256sum[[:space:]]+"?\$' <<<"$IDENT_CODE"; then
    fail "B-STATIC the identity still hashes sha256sum output that serializes a path"
else
    pass "B-STATIC the identity reads content on stdin (no path in the hashed material)"
fi

echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
