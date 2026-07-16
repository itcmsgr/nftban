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

echo "========================================"
if [[ "$FAIL" -eq 0 ]]; then echo "RESULT: PASS — build provenance guard holds"; exit 0; fi
echo "RESULT: FAIL — stale-prebuilt guard violated (see ::error:: above)"; exit 1
