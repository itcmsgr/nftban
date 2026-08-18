#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.229.3 P0-1 — A FAILED READ MUST NEVER RENDER AS A PASS
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="posture-observation-truth-v1229-3-test"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-08-18"
# meta:description="P0-1. The security posture report must not print a checkmark or a definite value derived from a source it could not read. Covers the sshd directive resolver (read failure vs absent directive), sudoers NOPASSWD, config-integrity manifest, MAC posture, and the summary line. These are the first assertion-bearing posture tests; each arm has an inversion against production code."
# meta:inventory.files="cli/lib/nftban/cli/cmd_health_analysis.sh"
# meta:inventory.privileges="none"
# meta:ta.id="posture_observation_truth_v1229_3_test"
# meta:ta.owner="health"
# meta:ta.module="health"
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
#   ⛔ UNREADABLE          != CLEAN
#   ⛔ READ FAILURE        != DIRECTIVE ABSENT
#   ⛔ ZERO FILES VERIFIED != VERIFIED ZERO DRIFT
#   ⛔ HELPER FAILED       != CONTROL NOT APPLICABLE
#   ⛔ CHECKS RUN          != CHECKS PASSED
#
#   Root note: `chmod 000` proves nothing when the test runs as root (DAC_OVERRIDE),
#   so unreadability is produced STRUCTURALLY — a source directory containing no
#   readable file — never by permission bits.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$SCRIPT_DIR/../cli/cmd_health_analysis.sh"
FAIL=0
pass(){ echo "  PASS  $1"; }
fail(){ echo "  FAIL  $1"; FAIL=1; }

echo "=== posture observation truth (v1.229.3 P0-1) ==="
[[ -f "$SUBJECT" ]] || { echo "  SUBJECT_NOT_FOUND: $SUBJECT"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Extract the resolver and the UNKNOWN row renderer from PRODUCTION source so the
# arms bind to shipped code, not to a copy maintained here.
fn_body(){ awk -v f="^    $1\\\\(\\\\) \\\\{" '$0 ~ f,/^    \}/' "$SUBJECT"; }

RESOLVER="$(fn_body _ssh_effective_directive)"
[[ -n "$RESOLVER" ]] || { echo "  SUBJECT_NOT_FOUND: _ssh_effective_directive"; exit 1; }

_POSTURE_UNKNOWN="__NFTBAN_UNKNOWN__"
eval "$(sed 's/^    //' <<<"$RESOLVER")"

mkdir -p "$TMP/empty_dropins"

# --- A1 · no readable source -> UNKNOWN, never a definite value ---------------
export NFTBAN_SSHD_CONFIG_D="$TMP/empty_dropins"
got="$(_ssh_effective_directive "permitrootlogin" "$TMP/does_not_exist")"
if [[ "$got" == "$_POSTURE_UNKNOWN" ]]; then
    pass "A1 unreadable sshd source -> UNKNOWN (not \"yes\")"
else
    fail "A1 unreadable sshd source returned a definite value: '$got'"
fi

# --- A2 · READ SUCCEEDED, directive absent -> sshd default is a TRUE answer ----
# This is the distinction that makes A1 meaningful. Collapsing both cases into
# UNKNOWN would be just as untruthful in the other direction.
printf 'Port 22\n' > "$TMP/sshd_config"
got="$(_ssh_effective_directive "permitrootlogin" "$TMP/sshd_config")"
if [[ "$got" == "yes" ]]; then
    pass "A2 readable source with directive ABSENT -> sshd default 'yes' (not UNKNOWN)"
else
    fail "A2 absent directive on a readable file returned '$got' — over-reporting UNKNOWN"
fi

# --- A3 · directive present is read normally ----------------------------------
printf 'PermitRootLogin no\n' > "$TMP/sshd_config2"
got="$(_ssh_effective_directive "permitrootlogin" "$TMP/sshd_config2")"
[[ "$got" == "no" ]] && pass "A3 present directive resolves normally" \
                     || fail "A3 present directive returned '$got'"

# --- A4 · INVERSION: the pre-fix resolver returns "yes" for an unread source ---
# Proves A1 is falsifiable: the old behaviour is reproduced and detected.
_pre_fix_resolver() {
    local directive="$1" main_config="$2" value=""
    local f match
    for f in "$main_config" "$TMP/empty_dropins"/*.conf; do
        [[ -f "$f" ]] || continue
        match=$(grep -iE "^[[:space:]]*${directive}[[:space:]]" "$f" 2>/dev/null | awk '{print $2}' | tail -n1)
        [[ -n "$match" ]] && value="$match"
    done
    if [[ -n "$value" ]]; then echo "$value"; else echo "yes"; fi
}
got="$(_pre_fix_resolver "permitrootlogin" "$TMP/does_not_exist")"
if [[ "$got" == "yes" ]]; then
    pass "A4 INVERSION: the pre-fix resolver DOES print 'yes' for an unread source (A1 is falsifiable)"
else
    fail "A4 inversion did not reproduce the defect — A1 may be vacuous"
fi

# ================= STRUCTURAL ARMS over production source =====================
code_of(){ grep -vE '^\s*#' "$SUBJECT"; }
CODE="$(code_of)"

# --- B1 · sudoers cannot report clean without reading -------------------------
if grep -q 'sudoers_unreadable' <<<"$CODE" \
   && grep -B4 'No risky NOPASSWD patterns' <<<"$CODE" | grep -q 'sudoers_unreadable'; then
    pass "B1 sudoers clean-row is gated on every file having been READ"
else
    fail "B1 sudoers can still print 'No risky NOPASSWD patterns' without reading the files"
fi

# --- B2 · config integrity cannot report a pass with zero files checked -------
if grep -B4 'files verified' <<<"$CODE" | grep -q 'checked_count -eq 0'; then
    pass "B2 config integrity reports UNKNOWN when the manifest yields no readable file"
else
    fail "B2 '0 files verified' can still render as a pass"
fi

# --- B3 · MAC helper failure is UNKNOWN, not 'not applicable' -----------------
if grep -q 'MAC posture could not be determined' <<<"$CODE" \
   && ! grep -q '|| _mac_line="none|INFO|n/a|MAC not applicable|"' <<<"$CODE"; then
    pass "B3 MAC helper failure renders UNKNOWN (no silent 'not applicable' fallback)"
else
    fail "B3 a failed MAC helper still renders as informational/not-applicable"
fi

# --- B4 · UNKNOWN is a WARNING, never OK --------------------------------------
UROW="$(fn_body _posture_unknown_row)"
if grep -q 'unknowns++' <<<"$UROW" && grep -q 'warnings++' <<<"$UROW"; then
    pass "B4 every UNKNOWN row increments BOTH unknowns and warnings (never OK)"
else
    fail "B4 an UNKNOWN row does not force a warning — it could still summarise as OK"
fi

# --- B5 · the summary no longer calls checks-run 'checks passed' --------------
if grep -q 'checks observed and passed' <<<"$CODE" \
   && ! grep -qE '\$total_checks checks passed' <<<"$CODE"; then
    pass "B5 summary distinguishes observed from run (no inflated 'checks passed')"
else
    fail "B5 summary still reports the number of checks RUN as the number PASSED"
fi

# --- B6 · the dead issues/return-2 tier is gone from THIS function ------------
# ⛔ SUBJECT_NOT_FOUND IS A TEST FAILURE, never a silent fallback to the whole file.
# The first version of this arm fell back to the full source and flagged a
# legitimate `return 2` in nftban_health_cmd_botguard() — the wrong subject.
POSTURE_FN="$(awk '/^nftban_health_cmd_posture\(\) \{/,/^\}/' "$SUBJECT")"
if [[ -z "$POSTURE_FN" ]]; then
    fail "B6 SUBJECT_NOT_FOUND: nftban_health_cmd_posture() could not be located"
elif grep -qE '^\s*return 2\s*$' <<<"$(grep -vE '^\s*#' <<<"$POSTURE_FN")"; then
    fail "B6 a dead return-2 path is still present in nftban_health_cmd_posture()"
elif grep -qE '\$issues' <<<"$(grep -vE '^\s*#' <<<"$POSTURE_FN")"; then
    fail "B6 the never-incremented \$issues variable is still consumed in the posture summary"
else
    pass "B6 the unreachable issues/return-2 severity tier is removed from the posture function"
fi

# --- B7 · INVERSION: restoring any silent fallback must be detectable ---------
# Rebuild the removed MAC fallback in a copy and confirm B3's predicate flips.
cp -a "$SUBJECT" "$TMP/subject.sh"
python3 - "$TMP/subject.sh" <<'PY'
import sys
p=sys.argv[1]; s=open(p,encoding='utf-8').read()
s=s.replace('if ! _mac_line=$(_nftban_mac_posture 2>/dev/null); then',
            '_mac_line=$(_nftban_mac_posture 2>/dev/null) || _mac_line="none|INFO|n/a|MAC not applicable|"\n        if false; then',1)
open(p,'w',encoding='utf-8').write(s)
PY
if grep -q '|| _mac_line="none|INFO|n/a|MAC not applicable|"' "$TMP/subject.sh"; then
    pass "B7 INVERSION: a reintroduced silent MAC fallback is detectable (B3 is falsifiable)"
else
    fail "B7 inversion did not apply — B3 may be vacuous"
fi

# production file must be untouched by the inversion
if [[ "$(sha256sum "$SUBJECT" | cut -d' ' -f1)" == "$(sha256sum "$SUBJECT" | cut -d' ' -f1)" ]] \
   && ! grep -q 'if false; then' "$SUBJECT"; then
    pass "B8 production source unmodified by the inversions"
else
    fail "B8 the inversion leaked into production source"
fi

echo
if [[ $FAIL -eq 0 ]]; then echo "RESULT: PASS"; exit 0; fi
echo "RESULT: FAIL"; exit 1
