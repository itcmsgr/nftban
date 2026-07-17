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
# Negative self-test: strip one Mode-3 argument → the guard MUST catch it.
_neg="$(mktemp)"
sed '0,/--use-prebuilt --prebuilt-manifest/s/--use-prebuilt --prebuilt-manifest [^ ]*//' .github/workflows/release.yml > "$_neg"
if check_workflow_mode3 "$_neg" >/dev/null 2>&1; then
    echo "::error::NEGATIVE SELF-TEST FAILED — guard did not catch a stripped Mode-3 argument"; FAIL=1
else
    echo "  OK: negative self-test — guard catches a stripped Mode-3 argument"
fi
rm -f "$_neg"

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
