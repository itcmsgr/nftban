#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# meta:name="verify-release-assembly_test"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Hermetic tests for verify-release-assembly.sh: both modes exit 0 on a well-formed assembly (regression guard for the v1.221.1 push-path failure), mode-specific asset counts (push=12, dry-run=13), and negative cases (missing asset, wrong count, push-with-premature-SHA256SUMS, bad mode) fail closed. Parity is stubbed via the script's source-guard so the harness needs no real packages; real parity is exercised by the CI dry-run against real packages."
# meta:inventory.files=""
# meta:inventory.binaries="bash"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
# This is a TEST HARNESS: it deliberately runs cases that exit non-zero and
# records PASS/FAIL rather than aborting. Every assertion below is guarded
# (`… || RC=$?`, `{ … } && ok || bad`), so errexit stays on for real bugs while
# expected non-zero results are captured, not fatal.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../verify-release-assembly.sh"
PASS=0; FAIL=0
ok(){ echo "[PASS] $1"; PASS=$((PASS+1)); }
bad(){ echo "[FAIL] $1"; FAIL=$((FAIL+1)); }

# Build a well-formed base assembly (12 touched files) in a fresh dir.
mkfixture() {
    local d; d="$(mktemp -d)"
    ( cd "$d" || exit 1
      for i in ubuntu22.04 ubuntu24.04 ubuntu26.04 debian12 debian13; do : > "nftban-${i}-amd64.deb"; done
      for i in el9 el10; do : > "nftban-${i}-x86_64.rpm"; done
      : > nftband-linux-amd64
      : > sbom.spdx.json; : > SHA256SUMS.build; : > MANIFEST.txt; : > VERIFY.txt )
    echo "$d"
}

# run_case MODE DISTDIR STUB_PARITY_RC  → prints nothing, sets global RC
run_case() {
    local mode="$1" dir="$2" prc="$3"
    RC=0
    out="$(
        # shellcheck disable=SC1090
        source "$SCRIPT" 2>/dev/null || true
        verify_parity() { echo "EVIDENCE_PARITY=STUBBED(rc=$prc)"; return "$prc"; }
        main --mode "$mode" --dist-dir "$dir"
    )" || RC=$?
    LAST_OUT="$out"
}

# --- Positive: push mode exits 0 (THE v1.221.1 regression) ---
d="$(mkfixture)"
run_case push "$d" 0
{ [ "$RC" = 0 ] && grep -q 'EVIDENCE_ASSEMBLY_ASSET_COUNT=12' <<<"$LAST_OUT" && grep -q 'PASS (mode=push)' <<<"$LAST_OUT"; } \
  && ok "push mode: exit 0 (regression), assembly count 12" || bad "push mode positive (RC=$RC)"
grep -q 'EVIDENCE_SHA256SUMS_DEFERRED_TO_VERIFY_RELEASE=YES' <<<"$LAST_OUT" \
  && ok "push mode: SHA256SUMS deferred to verify-release" || bad "push mode SHA256SUMS deferral"
rm -rf "$d"

# --- Positive: dry-run mode exits 0, count 13, generates SHA256SUMS ---
d="$(mkfixture)"
run_case dry-run "$d" 0
{ [ "$RC" = 0 ] && grep -q 'EVIDENCE_ASSEMBLY_ASSET_COUNT=13' <<<"$LAST_OUT" && grep -q 'EVIDENCE_SHA256SUMS_GENERATED=YES' <<<"$LAST_OUT"; } \
  && ok "dry-run mode: exit 0, assembly count 13, SHA256SUMS generated" || bad "dry-run mode positive (RC=$RC)"
[ -f "$d/SHA256SUMS" ] && ok "dry-run mode: SHA256SUMS actually written" || bad "dry-run SHA256SUMS not written"
rm -rf "$d"

# --- Positive: RELATIVE --dist-dir (how release.yml invokes it) must work ---
# (regression guard: verify_parity cd's into a temp dir; a relative dist-dir would
#  break package extraction after that cd. The workflow passes `--dist-dir dist/packages`.)
d="$(mkfixture)"
parent="$(dirname "$d")"; sub="$(basename "$d")"
RC=0
out="$(
    cd "$parent" || exit 3
    # shellcheck disable=SC1090
    source "$SCRIPT" 2>/dev/null || true
    verify_parity() { echo "EVIDENCE_PARITY=STUBBED"; return 0; }
    main --mode push --dist-dir "$sub"
)" || RC=$?
{ [ "$RC" = 0 ] && grep -q 'PASS (mode=push)' <<<"$out"; } \
  && ok "relative --dist-dir resolves (regression: parity path survives inner cd)" || bad "relative --dist-dir (RC=$RC)"
rm -rf "$d"

# --- Negative: missing asset (drop a DEB) ---
d="$(mkfixture)"; rm -f "$d/nftban-debian12-amd64.deb"
run_case push "$d" 0
{ [ "$RC" != 0 ] && grep -q 'expected DEB_COUNT=5' <<<"$LAST_OUT"; } \
  && ok "negative: missing DEB fails closed" || bad "negative missing DEB (RC=$RC)"
rm -rf "$d"

# --- Negative: wrong count (extra RPM) ---
d="$(mkfixture)"; : > "$d/nftban-el11-x86_64.rpm"
run_case push "$d" 0
{ [ "$RC" != 0 ] && grep -q 'expected RPM_COUNT=2' <<<"$LAST_OUT"; } \
  && ok "negative: extra RPM fails closed" || bad "negative extra RPM (RC=$RC)"
rm -rf "$d"

# --- Negative: missing metadata file (MANIFEST) ---
d="$(mkfixture)"; rm -f "$d/MANIFEST.txt"
run_case push "$d" 0
{ [ "$RC" != 0 ] && grep -q 'MANIFEST.txt MISSING' <<<"$LAST_OUT"; } \
  && ok "negative: missing MANIFEST fails closed" || bad "negative missing MANIFEST (RC=$RC)"
rm -rf "$d"

# --- Negative: push path must reject a premature SHA256SUMS ---
d="$(mkfixture)"; : > "$d/SHA256SUMS"
run_case push "$d" 0
{ [ "$RC" != 0 ] && grep -q 'SHA256SUMS must NOT be pre-present on the push path' <<<"$LAST_OUT"; } \
  && ok "negative: premature SHA256SUMS on push fails closed" || bad "negative premature SHA256SUMS (RC=$RC)"
rm -rf "$d"

# --- Negative: parity failure propagates (stub returns 1) ---
d="$(mkfixture)"
run_case push "$d" 1
[ "$RC" != 0 ] && ok "negative: parity failure propagates to non-zero exit" || bad "negative parity propagation (RC=$RC)"
rm -rf "$d"

# --- Negative: bad --mode ---
d="$(mkfixture)"
run_case bogus "$d" 0
[ "$RC" = 2 ] && ok "negative: invalid --mode exits 2" || bad "negative bad mode (RC=$RC)"
rm -rf "$d"

# --- Negative: missing --dist-dir ---
RC=0
# shellcheck disable=SC1090
out="$( source "$SCRIPT" 2>/dev/null || true; main --mode push --dist-dir /nonexistent/xyz )" || RC=$?
[ "$RC" = 2 ] && ok "negative: nonexistent dist-dir exits 2" || bad "negative nonexistent dist-dir (RC=$RC)"

echo "----------------------------------------"
echo "verify-release-assembly tests: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ] || exit 1
