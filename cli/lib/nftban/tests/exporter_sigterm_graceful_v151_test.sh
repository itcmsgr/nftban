#!/usr/bin/env bash
# =============================================================================
# NFTBan - v1.151 D-EXPORTER-EXIT2-PHASE-4: signal-aware ERR trap (class-killer)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="exporter_sigterm_graceful_v151_test"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-06-06"
# meta:description="Exercises the REAL permanent ERR trap shipped in nftban_unified_exporter.sh: a signal-induced rc (>=128, e.g. 143 SIGTERM / 130 SIGINT) must be reported as a graceful INFO interruption (no ERROR:), while a real command/logic failure (rc<128) must keep the loud diagnosable ERROR: line. The trap is extracted verbatim from the source so the test verifies the shipped behavior, not a copy. Hermetic: temp scripts only; no host/nft/IPC."
# meta:input="None (self-contained)"
# meta:output="Pass/fail assertions; exit 0 on all-pass"
# meta:depends="bash,grep,mktemp"
# meta:inventory.files="cli/lib/nftban/exporters/nftban_unified_exporter.sh"
# meta:inventory.binaries="bash,grep,mktemp"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../../.." && pwd)"
SRC="$REPO_ROOT/cli/lib/nftban/exporters/nftban_unified_exporter.sh"

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "  ✓ $1"; }
no() { FAIL=$((FAIL+1)); echo "  ✗ $1${2:+ — $2}"; }

# Extract the REAL ERR trap line shipped in the exporter (single line ending in ' ERR').
TRAP_LINE="$(grep -E "^trap '.*' ERR$" "$SRC" | head -1)"
[[ -n "$TRAP_LINE" ]] && ok "extracted the shipped ERR trap from the exporter" \
                      || no "could not find the ERR trap in $SRC"

# run_case <exit-code> → prints the trap's stderr output followed by 'RC=<rc>'
run_case() {
    local code="$1" tmp out rc
    tmp="$(mktemp)"
    {
        echo 'set -Eeuo pipefail'
        printf '%s\n' "$TRAP_LINE"
        echo "( exit $code )"   # a command that returns <code> → fires the ERR trap
    } > "$tmp"
    out="$(bash "$tmp" 2>&1)"; rc=$?
    rm -f "$tmp"
    printf '%s\nRC=%s' "$out" "$rc"
}

echo "=== rc=143 (SIGTERM) → graceful INFO, NOT ERROR ==="
r="$(run_case 143)"
echo "$r" | grep -q "interrupted by signal (rc=143)" && ok "143: emits graceful INFO interruption" || no "143 INFO" "$r"
echo "$r" | grep -q "next scheduled run will collect" && ok "143: reassures next run collects" || no "143 next-run" "$r"
echo "$r" | grep -qi "ERROR: nftban-unified-exporter aborted" && no "143: must NOT emit ERROR" "$r" || ok "143: no ERROR line"
echo "$r" | grep -q "RC=143" && ok "143: preserves exit code 143" || no "143 rc" "$r"

echo "=== rc=130 (SIGINT) → graceful INFO ==="
r="$(run_case 130)"
echo "$r" | grep -q "interrupted by signal (rc=130)" && ok "130: graceful INFO" || no "130 INFO" "$r"
echo "$r" | grep -qi "ERROR:.*aborted" && no "130: must NOT emit ERROR" "$r" || ok "130: no ERROR line"

echo "=== rc=1 (real logic failure) → loud ERROR (regression guard) ==="
r="$(run_case 1)"
echo "$r" | grep -q "ERROR: nftban-unified-exporter aborted rc=1" && ok "1: keeps diagnosable ERROR line" || no "1 ERROR" "$r"
echo "$r" | grep -q "interrupted by signal" && no "1: must NOT be treated as a signal" "$r" || ok "1: not mislabeled as signal"
echo "$r" | grep -q "RC=1" && ok "1: preserves exit code 1" || no "1 rc" "$r"

echo "=== rc=2 (INVALIDARGUMENT class) → loud ERROR ==="
r="$(run_case 2)"
echo "$r" | grep -q "ERROR: nftban-unified-exporter aborted rc=2" && ok "2: keeps ERROR line" || no "2 ERROR" "$r"

echo ""
echo "================================================================"
echo "exporter_sigterm_graceful_v151: PASS=$PASS FAIL=$FAIL"
echo "================================================================"
[[ $FAIL -eq 0 ]]
