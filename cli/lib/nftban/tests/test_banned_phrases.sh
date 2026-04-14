#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.81 - M81-5 Banned Phrase Detection
# =============================================================================
# meta:name="test_banned_phrases"
# meta:type="test"
# meta:version="1.81.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Detects vocabulary-banned phrases in CLI output code per CLI_OUTPUT_SPEC_v1.81.md"
# meta:inventory.files="cli/lib/nftban/cli/*.sh"
# meta:inventory.binaries="bash,grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# This test scans CLI shell files for phrases banned by M81-5.
# It runs as a static analysis pass — no runtime needed.
#
# Banned phrases are defined in:
#   CLI_OUTPUT_SPEC_v1.81.md Section 4
#   NFTBAN_VOCABULARY_REFERENCE_v1.81.md Section 2
#
# Severity levels:
#   ERROR:   phrase found in user-facing output (echo, printf to stdout)
#   WARN:    phrase found in internal variable assignments
#   SKIP:    phrase found in comments, test files, or non-output context
#
# This test does NOT block CI in v1.81 (many legacy instances exist).
# It produces a report for incremental cleanup. Full enforcement is v1.82.
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
CLI_DIR="$PROJECT_ROOT/cli/lib/nftban/cli"

echo "=========================================================="
echo "M81-5 Banned Phrase Scan"
echo "  source: CLI_OUTPUT_SPEC_v1.81.md"
echo "  target: cli/lib/nftban/cli/*.sh"
echo "=========================================================="
echo ""

total_findings=0

scan_phrase() {
    local phrase="$1"
    local description="$2"
    local pattern="$3"

    local hits
    hits=$(grep -rnI "$pattern" "$CLI_DIR"/*.sh 2>/dev/null \
        | grep -vE '^\s*#|test_|_test\.|spec\.|SPEC' \
        | grep -vE 'systemctl|is-active|ActiveState|ActiveEnter' \
        || true)

    local count
    count=$(echo "$hits" | grep -c . 2>/dev/null || echo "0")

    if [[ "$count" -gt 0 && -n "$hits" ]]; then
        echo "  FOUND ($count)  \"$phrase\" — $description"
        echo "$hits" | head -5 | sed 's/^/    /'
        if [[ "$count" -gt 5 ]]; then
            echo "    ... and $((count - 5)) more"
        fi
        total_findings=$((total_findings + count))
    else
        echo "  CLEAN        \"$phrase\""
    fi
    echo ""
}

echo "[1] Vocabulary-banned terms in CLI output"
echo ""

scan_phrase "healthy" \
    "banned: use PROTECTED with evidence" \
    '"healthy"\|= healthy\|: healthy\|"HEALTHY"'

scan_phrase "working" \
    "banned: use specific axis state" \
    '"working"\|is working'

scan_phrase "OK (health)" \
    "banned in health context: use PROTECTED" \
    '"OK"\|= "OK"\|="OK"'

scan_phrase "all clear" \
    "banned: absence of evidence != evidence of absence" \
    '"all clear"\|all clear'

scan_phrase "no attacks" \
    "banned: zero is NEUTRAL, not proof of safety" \
    '"no attacks"\|no attacks detected'

scan_phrase "threats blocked" \
    "banned: counter interpretation" \
    'threats.blocked\|attacks.blocked'

scan_phrase "protecting your" \
    "banned: PRESENT != ENFORCING" \
    'protecting your\|protects your'

echo "=========================================================="
echo "Total findings: $total_findings"
echo ""
echo "NOTE: This scan is informational for v1.81."
echo "Full enforcement (CI blocking) is v1.82 scope."
echo "=========================================================="

# Exit 0 always — informational, not blocking
exit 0
