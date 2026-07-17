#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# meta:name="check-build-provenance"
# meta:type="script"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="CI gate: the packaging build must never silently reuse a stale bin/* artifact. Static-lints build_nftban.sh + build.sh for the anti-stale-prebuilt guard, then runs the hermetic provenance test suite."
# meta:inventory.files=""
# meta:inventory.binaries="bash, grep, git"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
FAIL=0
BN="packaging/build_nftban.sh"
BS="build.sh"

echo "========================================"
echo "NFTBan CI: Build Provenance (anti-stale-prebuilt)"
echo "========================================"

# 1) The exact old footgun must be GONE: reuse binaries because bin/ ELFs exist.
if grep -q "Pre-built binaries found in bin/ - Go not required" "$BN" 2>/dev/null; then
    echo "::error::stale-prebuilt footgun present — build_nftban.sh still declares 'Go not required' from bin/ presence"; FAIL=1
fi
if grep -q "Using pre-built binaries from bin/ - skipping rebuild" "$BN" 2>/dev/null; then
    echo "::error::build_nftban.sh still SILENTLY reuses bin/* (skip-rebuild path must be removed)"; FAIL=1
fi

# 2) Source-build path must clean + verify (positive wiring inside build_binaries()).
body="$(awk '/^build_binaries\(\) \{/{p=1} p{print} p&&/^}/{exit}' "$BN")"
grep -q 'prov_clean_generated_bins' <<<"$body" || { echo "::error::build_binaries must clean allowlisted bin/* before rebuild"; FAIL=1; }
grep -q 'prov_verify_source_build' <<<"$body"  || { echo "::error::build_binaries must verify the source build provenance"; FAIL=1; }
grep -q 'prov_verify_prebuilt'     <<<"$body"  || { echo "::error::build_binaries must verify prebuilt provenance in Mode 3"; FAIL=1; }

# 3) Mode 3 must require BOTH --use-prebuilt and a manifest (no silent prebuilt).
grep -q 'use-prebuilt requires --prebuilt-manifest' "$BN" || { echo "::error::--use-prebuilt must require --prebuilt-manifest"; FAIL=1; }

# 4) build.sh must resolve identity via provenance (no silent 'dev') + emit a manifest.
grep -q 'prov_resolve_source_identity' "$BS" || { echo "::error::build.sh must resolve source identity via provenance"; FAIL=1; }
grep -q 'prov_write_manifest'          "$BS" || { echo "::error::build.sh must emit a build manifest"; FAIL=1; }
grep -qE 'rev-parse --short=12 HEAD .* echo "dev"' "$BS" && { echo "::error::build.sh still silently falls back to short-sha/'dev'"; FAIL=1; }

# 5) bin/ must be gitignored (generated outputs never tracked).
if ! git check-ignore -q bin/nftband 2>/dev/null; then
    echo "::error::bin/ is not gitignored — generated binaries could be committed"; FAIL=1
fi
for b in nftban-core nftband nftban-botscan-matcher nftban-validate nftban-detect-ssh-ports nftban-installer; do
    if git ls-files --error-unmatch "bin/$b" >/dev/null 2>&1; then
        echo "::error::bin/$b is git-tracked (must be a generated output, not source)"; FAIL=1
    fi
done

# 6) Hermetic provenance test suite must pass.
echo "[hermetic] packaging/tests/build_provenance_test.sh"
if bash packaging/tests/build_provenance_test.sh >/tmp/_prov_test.log 2>&1; then
    echo "  PASS ($(grep -c '\[PASS\]' /tmp/_prov_test.log) assertions)"
else
    echo "::error::hermetic provenance tests failed:"; tail -20 /tmp/_prov_test.log; FAIL=1
fi
rm -f /tmp/_prov_test.log

# 7) Release + package workflows must use the explicit Mode-3 verified-prebuilt
#    contract (regression guard for OPEN_RELEASE_YML_MODE3_PREBUILT_GAP — v1.221.0
#    shipped incomplete because release.yml called bare build_nftban.sh deb|rpm
#    while build-packages.yml was already Mode-3). Semantic (tolerant of YAML
#    formatting): every build_nftban.sh deb|rpm invocation must carry BOTH
#    --use-prebuilt and --prebuilt-manifest within its command window; the package
#    jobs must build binaries once (build-binaries) and download the go-binaries
#    artifact. Checks a 3-line window so a multiline command cannot bypass it.
check_workflow_mode3() {
    local wf="$1" rc=0
    grep -qE '^[[:space:]]+build-binaries:' "$wf" || { echo "::error::$wf missing build-binaries job (build-once)"; rc=1; }
    grep -q 'name: go-binaries' "$wf" || { echo "::error::$wf missing the go-binaries artifact (build-once manifest handoff)"; rc=1; }
    grep -q 'needs: build-binaries' "$wf" || { echo "::error::$wf package jobs must 'needs: build-binaries'"; rc=1; }
    local ln block
    while IFS= read -r ln; do
        [[ -z "$ln" ]] && continue
        block="$(sed -n "${ln},$((ln + 2))p" "$wf")"
        if ! { grep -q -- '--use-prebuilt' <<<"$block" && grep -q -- '--prebuilt-manifest' <<<"$block"; }; then
            echo "::error::$wf:$ln bare 'build_nftban.sh deb|rpm' — missing Mode-3 --use-prebuilt/--prebuilt-manifest"; rc=1
        fi
    done < <(grep -nE 'build_nftban\.sh (deb|rpm)' "$wf" | cut -d: -f1)
    return $rc
}
for wf in .github/workflows/release.yml .github/workflows/build-packages.yml; do
    echo "[workflow-mode3] $wf"
    check_workflow_mode3 "$wf" || FAIL=1
done

# 7b) Mode-3 CONTAINER PREREQUISITES (regression guard for
#     OPEN_RELEASE_YML_MODE3_JQ_PREREQUISITE_GAP — v1.221.1: the first executable
#     dry-run entered Mode 3 in all 7 package jobs, then FAILED because `jq` — the
#     mandatory --use-prebuilt manifest-verification dependency — was absent from
#     the Go-less distro containers). The Mode-3 command flags are necessary but
#     NOT sufficient: each package job must also INSTALL its verification deps.
#     Anchored to the actual dependency-install command inside each job (dnf …
#     rpm-build / apt-get … dpkg-dev) so a stray `jq` elsewhere in the YAML — e.g.
#     a manifest-tamper test or a parity check — does NOT satisfy the guard.
#     Also asserts the package containers do NOT install a Go toolchain (Mode 3 is
#     verified-prebuilt precisely so Go is not required there; installing Go would
#     lose the by-construction binary parity that build-once provides).
check_release_mode3_prereqs() {
    local wf="$1" rc=0 rpm_line deb_line
    # RPM job: the dnf line that pulls rpm-build must also install jq (+file), no Go.
    rpm_line="$(grep -E 'dnf -y install --allowerasing[[:space:]]+rpm-build' "$wf" || true)"
    if [[ -z "$rpm_line" ]]; then
        echo "::error::$wf: RPM dependency-install line (dnf … rpm-build) not found — cannot verify Mode-3 prerequisites"; rc=1
    else
        grep -qw jq   <<<"$rpm_line" || { echo "::error::$wf: RPM package job does not install 'jq' (Mode-3 --use-prebuilt manifest verification prerequisite)"; rc=1; }
        grep -qw file <<<"$rpm_line" || { echo "::error::$wf: RPM package job does not install 'file' (DEB/RPM daemon-parity check prerequisite)"; rc=1; }
        grep -qwE 'golang|golang-go|go-toolset|gcc-go|gccgo' <<<"$rpm_line" && { echo "::error::$wf: RPM package container must NOT install a Go toolchain (Mode 3 is verified-prebuilt — Go not required)"; rc=1; }
    fi
    # DEB job: the apt-get install line that pulls dpkg-dev must also install jq, no Go.
    deb_line="$(grep -E 'apt-get install -y[[:space:]]+dpkg-dev' "$wf" || true)"
    if [[ -z "$deb_line" ]]; then
        echo "::error::$wf: DEB dependency-install line (apt-get … dpkg-dev) not found — cannot verify Mode-3 prerequisites"; rc=1
    else
        grep -qw jq <<<"$deb_line" || { echo "::error::$wf: DEB package job does not install 'jq' (Mode-3 --use-prebuilt manifest verification prerequisite)"; rc=1; }
        grep -qwE 'golang|golang-go|go-toolset|gccgo' <<<"$deb_line" && { echo "::error::$wf: DEB package container must NOT install a Go toolchain (Mode 3 is verified-prebuilt — Go not required)"; rc=1; }
    fi
    return $rc
}
for wf in .github/workflows/release.yml .github/workflows/build-packages.yml; do
    echo "[release-mode3-prereqs] $wf"
    check_release_mode3_prereqs "$wf" || FAIL=1
done

# Negative self-tests: each mutation to release.yml MUST make the relevant guard
# fail-closed. Proves the guard actually discriminates (not a broad "jq appears
# somewhere" grep). name → sed mutation → checker that must then return non-zero.
_neg_expect_fail() {
    local name="$1" expr="$2" fn="$3" tmp
    tmp="$(mktemp)"
    sed "$expr" .github/workflows/release.yml > "$tmp"
    if "$fn" "$tmp" >/dev/null 2>&1; then
        echo "::error::NEGATIVE SELF-TEST FAILED ($name) — guard did not fail-closed on the mutation"; FAIL=1
    else
        echo "  OK: negative self-test $name — guard fails closed"
    fi
    rm -f "$tmp"
}
# jq stripped from the RPM / DEB install line → prereq guard must fail.
_neg_expect_fail RPM_JQ_REMOVED         '/dnf -y install --allowerasing[[:space:]]\+rpm-build/s/ jq//' check_release_mode3_prereqs
_neg_expect_fail DEB_JQ_REMOVED         '/apt-get install -y[[:space:]]\+dpkg-dev/s/ jq//'            check_release_mode3_prereqs
# Mode-3 flags stripped from the build_nftban.sh invocation(s) → mode3 flag guard
# must fail (separately for each flag). Anchored to the invocation lines so a
# documentary mention of the flag in a comment is not what gets mutated.
_neg_expect_fail USE_PREBUILT_REMOVED       '/build_nftban\.sh .*--use-prebuilt/s/--use-prebuilt//'                 check_workflow_mode3
_neg_expect_fail PREBUILT_MANIFEST_REMOVED  '/build_nftban\.sh .*--prebuilt-manifest/s/--prebuilt-manifest [^ ]*//' check_workflow_mode3

# 8) Downstream SLSA contract: nftban-core-linux-amd64 (+ .intoto.jsonl provenance)
#    are the TWO assets the release intentionally splits to the SLSA workflow, which
#    runs only after a SUCCESSFUL Release Packages run. Guards that this gating stays
#    intact so the final 15-asset set is not silently reduced (the release.yml dry-run
#    only certifies the pre-SLSA 13; these 2 come from here).
SLSA=".github/workflows/slsa-go-releaser.yml"
if [[ -f "$SLSA" ]]; then
    echo "[slsa-contract] $SLSA"
    grep -q 'workflows: \["Release Packages"\]' "$SLSA" || { echo "::error::SLSA must trigger on the 'Release Packages' workflow_run"; FAIL=1; }
    grep -qE "workflow_run\.conclusion == 'success'" "$SLSA" || { echo "::error::SLSA must gate on Release Packages conclusion == success"; FAIL=1; }
    grep -q 'nftban-core' "$SLSA" || { echo "::error::SLSA must build/upload nftban-core"; FAIL=1; }
    grep -qiE 'builder_go_slsa3|slsa-github-generator' "$SLSA" || { echo "::error::SLSA must use the slsa-github-generator (provenance) builder"; FAIL=1; }
    # dry-run safety: SLSA must only publish for a real tag PUSH, never for a
    # successful manual Release Packages dry-run (workflow_dispatch).
    grep -qE "workflow_run\.event == 'push'" "$SLSA" || { echo "::error::SLSA must require workflow_run.event=='push' (a Release Packages dry-run must not trigger SLSA publication)"; FAIL=1; }
else
    echo "::error::$SLSA missing — the downstream nftban-core provenance assets would be absent from releases"; FAIL=1
fi

echo "========================================"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS — build provenance guard holds"; exit 0; fi
echo "RESULT: FAIL — stale-prebuilt guard violated (see ::error:: above)"; exit 1
