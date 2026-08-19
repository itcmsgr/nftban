#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.4 VAF-0 Stage 3A — AN SBOM MUST NOT BE MANUFACTURED
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="sbom-no-fabrication-v1229-4-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-19"
# meta:description="VAF-0 Stage 3A, defect class EVIDENCE_MANUFACTURED (G4). When the authoritative producer (anchore/sbom-action) did not emit sbom.spdx.json, the Validate SBOM step FABRICATED a one-package substitute -- declaring creators 'Tool: anchore/sbom-action', impersonating the producer that had just failed -- and then validated only the two fields the stub supplied by construction, so it always passed and the substitute was published as the release SBOM. Executes the validator EXTRACTED FROM THE PRODUCTION WORKFLOW and asserts that absence, emptiness, unparseability, structural invalidity and a zero-package artifact all FAIL, and that no substitute file is ever created."
# meta:inventory.files=".github/workflows/release.yml"
# meta:inventory.privileges="none"
# meta:ta.id="sbom_no_fabrication_v1229_4_test"
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
#   PRODUCER FAILURE / SUBJECT ABSENCE
#   != AUTHORITY TO MANUFACTURE OBSERVATION EVIDENCE
#
#   ⛔ A NONZERO EXIT IS NOT ENOUGH. Every failure arm additionally asserts the
#      FILESYSTEM STATE: manufactured_sbom_exists = NO. A validator that failed loudly
#      while still leaving a synthesized artifact on disk would let a later step publish it.
#
#   ⛔ THE VALIDATOR MUST NEVER REPAIR ITS SUBJECT. A malformed authoritative SBOM is
#      reported, never overwritten with a valid-looking substitute.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
WF="$ROOT/.github/workflows/release.yml"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }
info(){ echo "        $1"; }

echo "=== SBOM must not be manufactured (v1.229.4 VAF-0 Stage 3A) ==="
[[ -f "$WF" ]] || { echo "  SUBJECT_NOT_FOUND: $WF"; echo "RESULT: FAIL"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "  SUBJECT_NOT_FOUND: python3"; echo "RESULT: FAIL"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP:?}"' EXIT

python3 - "$WF" "$TMP/validate.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for job in (d.get('jobs') or {}).values():
    if not isinstance(job, dict): continue
    for st in job.get('steps') or []:
        if str(st.get('name','')) == 'Validate SBOM':
            open(sys.argv[2],'w').write(st['run']); sys.exit(0)
sys.exit(3)
PY
[[ -s "$TMP/validate.sh" ]] || { fail "G0 could not extract 'Validate SBOM' from the workflow"; echo "RESULT: FAIL"; exit 1; }
pass "G0 validator extracted from the production workflow"
bash -n "$TMP/validate.sh" 2>/dev/null && pass "G0b extracted validator is syntactically valid" \
                                       || { fail "G0b extracted validator has a syntax error"; echo "RESULT: FAIL"; exit 1; }
# ⛔ NONZERO_TEST_RC != EXPECTED FAILURE PROVEN — without this precondition an invalid
#    block would exit non-zero for every arm and each negative control would "pass".

# ---- STATIC · the validator must contain no artifact-writing construct ----------
# ⛔ CODE ONLY. The step's comment block quotes the OLD fabricating form to explain the
#    defect; matching raw text would flag that explanation as the defect itself.
CODE="$(grep -vE '^[[:space:]]*#' "$TMP/validate.sh")"
WRITES=0
for frag in 'cat >' 'tee ' 'SBOM_EOF' '> "$SBOM"' '>"$SBOM"'; do
    grep -qF -- "$frag" <<<"$CODE" && { WRITES=1; info "found writer construct: $frag"; }
done
if [[ "$WRITES" -eq 0 ]]; then
    pass "STATIC the validator contains no artifact-writing construct (validator, not producer)"
else
    fail "STATIC the validator can still create/overwrite the SBOM artifact"
fi

# ---- harness ------------------------------------------------------------------
SBOM_REL="dist/packages/sbom.spdx.json"
mk(){ local d="$TMP/$1"; rm -rf "$d"; mkdir -p "$d/dist/packages"; printf '%s' "$d"; }
run_v(){ ( cd "$1" && VER=1.229.4 bash "$TMP/validate.sh" 2>&1 ); }
rc_v(){  ( cd "$1" && VER=1.229.4 bash "$TMP/validate.sh" >/dev/null 2>&1 ); echo $?; }
# THE load-bearing assertion for G4: no substitute may exist afterwards.
assert_no_fabrication(){ # $1 dir, $2 label
    if [[ -e "$1/$SBOM_REL" ]]; then
        fail "$2 manufactured_sbom_exists = YES — a substitute artifact was left on disk"
        info "⛔ failing loudly while synthesizing evidence is still EVIDENCE_MANUFACTURED"
    else
        pass "$2 manufactured_sbom_exists = NO"
    fi
}

real_sbom(){ # a structurally real, multi-package SBOM
    python3 - "$1" <<'PY'
import json,sys
json.dump({"spdxVersion":"SPDX-2.3","dataLicense":"CC0-1.0","SPDXID":"SPDXRef-DOCUMENT",
           "name":"nftban-test",
           "packages":[{"SPDXID":"SPDXRef-Package-%d"%i,"name":"pkg%d"%i,"versionInfo":"1.0"}
                       for i in range(5)]}, open(sys.argv[1],"w"))
PY
}

# ---- SBOM-P · authoritative output present and valid ---------------------------
d="$(mk p)"; real_sbom "$d/$SBOM_REL"
out="$(run_v "$d")"; rc="$(rc_v "$d")"
if [[ "$rc" -eq 0 ]] && grep -q 'SBOM valid: SPDX-2.3, 5 packages' <<<"$out"; then
    pass "SBOM-P authoritative producer output, structurally valid -> PASS"
else
    fail "SBOM-P a valid authoritative SBOM did not pass (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -3
fi

# ---- SBOM-N1 · expected SBOM ABSENT (the fabrication trigger) -------------------
d="$(mk n1)"
out="$(run_v "$d")"; rc="$(rc_v "$d")"
if [[ "$rc" -ne 0 ]] && grep -q '::error title=SBOM absent::' <<<"$out"; then
    pass "SBOM-N1 producer emitted nothing -> FAIL"
    info "⛔ the pre-fix validator FABRICATED a stub here and published it"
else
    fail "SBOM-N1 an absent SBOM did not fail (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -3
fi
assert_no_fabrication "$d" "SBOM-N1"

# ---- SBOM-N2 · producer ran but output unavailable / zero bytes -----------------
d="$(mk n2)"; : > "$d/$SBOM_REL"
out="$(run_v "$d")"; rc="$(rc_v "$d")"
if [[ "$rc" -ne 0 ]] && grep -q '::error title=SBOM empty::' <<<"$out"; then
    pass "SBOM-N2 zero-byte producer output -> FAIL / UNKNOWN, no fallback"
else
    fail "SBOM-N2 an empty SBOM did not fail (rc=$rc)"
fi
# the zero-byte file is the producer's own; what must NOT happen is replacement
if [[ -s "$d/$SBOM_REL" ]]; then
    fail "SBOM-N2 the empty authoritative artifact was OVERWRITTEN with content"
else
    pass "SBOM-N2 the authoritative artifact was left untouched (not replaced)"
fi

# ---- SBOM-N3 · malformed authoritative SBOM must not be repaired ----------------
d="$(mk n3)"; printf 'this is not json' > "$d/$SBOM_REL"
before="$(sha256sum "$d/$SBOM_REL" | cut -d' ' -f1)"
out="$(run_v "$d")"; rc="$(rc_v "$d")"
after="$(sha256sum "$d/$SBOM_REL" | cut -d' ' -f1)"
if [[ "$rc" -ne 0 ]] && grep -q '::error title=SBOM not parseable::' <<<"$out"; then
    pass "SBOM-N3 malformed authoritative SBOM -> FAIL"
else
    fail "SBOM-N3 a malformed SBOM did not fail (rc=$rc)"; sed 's/^/          /' <<<"$out" | tail -3
fi
if [[ "$before" == "$after" ]]; then
    pass "SBOM-N3 the malformed artifact was NOT overwritten with a valid-looking substitute"
else
    fail "SBOM-N3 the validator REPAIRED its own subject — that is manufacturing evidence"
fi

# ---- SBOM-N3b · structurally valid JSON, missing required fields ----------------
d="$(mk n3b)"; printf '{"hello":"world"}' > "$d/$SBOM_REL"
out="$(run_v "$d")"; rc="$(rc_v "$d")"
if [[ "$rc" -ne 0 ]] && grep -q '::error title=SBOM structurally invalid::' <<<"$out"; then
    pass "SBOM-N3b parseable JSON missing spdxVersion/packages -> FAIL"
else
    fail "SBOM-N3b a structurally invalid SBOM did not fail (rc=$rc)"
fi

# ---- SBOM-N3c · zero-package SBOM is not evidence -------------------------------
d="$(mk n3c)"; printf '{"spdxVersion":"SPDX-2.3","packages":[]}' > "$d/$SBOM_REL"
out="$(run_v "$d")"; rc="$(rc_v "$d")"
if [[ "$rc" -ne 0 ]] && grep -q '::error title=SBOM has no packages::' <<<"$out"; then
    pass "SBOM-N3c zero-package SBOM -> FAIL (0 PACKAGES != VALID EVIDENCE)"
else
    fail "SBOM-N3c a zero-package SBOM passed (rc=$rc)"
fi

echo
[[ $FAIL -eq 0 ]] && { echo "RESULT: PASS"; exit 0; }
echo "RESULT: FAIL"; exit 1
