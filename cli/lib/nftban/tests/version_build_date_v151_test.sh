#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.151 BUG-VERSION-BUILD-DATE-RUNTIME: build-date resolver
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="version_build_date_v151_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-06"
# meta:description="Verifies _nftban_resolve_build_date in lib/version.sh never returns the current clock. Resolution order: (1) build-stamp file ${NFTBAN_LIB_DIR}/.build_date, (2) rpm BUILDTIME of nftban-core, (3) EMPTY string (v1.220.x: the caller omits the Build Date field entirely — no 'unknown', no invented timestamp). Asserts the stamp wins, the rpm path formats the real build epoch (UTC, not today), and the absent/non-numeric path is empty — never \$(date)-now. Hermetic: temp NFTBAN_LIB_DIR + rpm() stub; no host/nft/IPC."
# meta:input="None (self-contained)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,date,grep"
# meta:inventory.files="cli/lib/nftban/lib/version.sh"
# meta:inventory.binaries="bash,date"
# meta:inventory.env_vars="NFTBAN_LIB_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
VS="$REPO_ROOT/cli/lib/nftban/lib/version.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

# resolve <setup-shell-snippet> → runs the snippet then prints _nftban_resolve_build_date,
# each in its own subshell (version.sh sets readonly vars / strict mode).
resolve() {
    local setup="$1"
    bash -c '
        set +e
        eval "$1"
        # shellcheck source=/dev/null
        source "$2" >/dev/null 2>&1 || true
        _nftban_resolve_build_date
    ' _ "$setup" "$VS"
}

TODAY="$(date '+%Y-%m-%d')"

echo "=== resolver exists in version.sh ==="
grep -q '_nftban_resolve_build_date' "$VS" && ok "function present" || no "function missing"
grep -qE 'NFTBAN_BUILD_DATE="\$\(date ' "$VS" && no "still uses \$(date) for build date!" || ok "no raw \$(date) build-date assignment"

echo "=== 1. build-stamp file wins ==="
D1="$(mktemp -d)"; printf 'STAMP-2026-06-01 09:00:00 UTC\n' > "$D1/.build_date"
out="$(resolve "NFTBAN_LIB_DIR='$D1'; rpm() { echo 9999999999; }")"
[[ "$out" == "STAMP-2026-06-01 09:00:00 UTC" ]] && ok "stamp file used verbatim (beats rpm)" || no "stamp" "$out"
rm -rf "$D1"

echo "=== 2. rpm BUILDTIME → real UTC date (not today) ==="
D2="$(mktemp -d)"  # empty: no stamp
EPOCH=1717286400   # fixed past build epoch
EXP="$(date -u -d "@$EPOCH" '+%Y-%m-%d %H:%M:%S UTC' 2>/dev/null)"
out="$(resolve "NFTBAN_LIB_DIR='$D2'; rpm() { echo $EPOCH; }")"
[[ "$out" == "$EXP" ]] && ok "rpm path formats real BUILDTIME ($EXP)" || no "rpm path" "got=$out exp=$EXP"
[[ "$out" != "$TODAY"* ]] && ok "rpm path is NOT today's date" || no "rpm-today regression" "$out"
rm -rf "$D2"

# v1.220.x: no authoritative build metadata now returns EMPTY (the caller omits
# the "Build Date" field entirely — no "unknown", no invented timestamp).
echo "=== 3. no stamp + package-absent rpm → '' (empty; field omitted, never now) ==="
D3="$(mktemp -d)"
out="$(resolve "NFTBAN_LIB_DIR='$D3'; rpm() { return 1; }")"
[[ -z "$out" ]] && ok "absent → '' (empty)" || no "empty fallback" "$out"
[[ "$out" != "$TODAY"* ]] && ok "fallback is NOT today's date (no \$(date)-now leak)" || no "fallback-today regression" "$out"
rm -rf "$D3"

echo "=== 4. rpm emits non-numeric → '' (empty; no bogus date) ==="
D4="$(mktemp -d)"
out="$(resolve "NFTBAN_LIB_DIR='$D4'; rpm() { echo 'not-installed'; }")"
[[ -z "$out" ]] && ok "non-numeric BUILDTIME → '' (empty)" || no "non-numeric" "$out"
rm -rf "$D4"

echo ""
echo "================================================================"
echo "version_build_date_v151: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
