#!/usr/bin/env bash
# =============================================================================
# NFTBan CLI Wording Lint
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="lint_cli_wording"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-03-30"
# meta:description="CI lint: detect forbidden wording in user-facing files"
# meta:input="None"
# meta:output="PASS/FAIL lint result to stdout"
# meta:depends=""
# meta:inventory.files="scripts/lint-cli-wording.sh"
# meta:inventory.binaries="rg"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Usage: scripts/lint-cli-wording.sh [--advisory]
#   --advisory  Also run advisory (non-blocking) checks
#
# Exit codes:
#   0  All checks passed
#   1  Forbidden wording found
# =============================================================================

set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

fail=0
advisory_mode=false
[[ "${1:-}" == "--advisory" ]] && advisory_mode=true

# File scope: user-facing files only
GLOBS="--glob=*.sh --glob=*.go --glob=*.md --glob=*.conf --glob=*.spec --glob=*.service --glob=*.timer --glob=*.8"

# Exclusions: historical changelogs, test fixtures, lint script itself
EXCLUDES="--glob=!packaging/deb/changelog --glob=!CHANGELOG.md --glob=!.claude/** --glob=!scripts/lint-cli-wording.sh"

# =============================================================================
# HARD-FAIL CHECKS (block CI)
# =============================================================================

hard_patterns=(
    "Unified Security Platform"
    "enterprise-grade"
    "AI-powered"
    "AI-assisted"
    "coming soon"
    "stay tuned"
    "next-gen"
    "best-in-class"
    "industry-leading"
    "cutting-edge"
    "intelligent defense"
)

echo "=== NFTBan CLI Wording Lint ==="
echo ""

for pattern in "${hard_patterns[@]}"; do
    # shellcheck disable=SC2086
    if rg -n -i $GLOBS $EXCLUDES "$pattern" . 2>/dev/null; then
        echo "ERROR: Forbidden wording: \"$pattern\""
        echo ""
        fail=1
    fi
done

if [[ "$fail" -eq 0 ]]; then
    echo "PASS: No forbidden wording found"
    echo ""
fi

# =============================================================================
# ADVISORY CHECKS (non-blocking, informational)
# =============================================================================

if [[ "$advisory_mode" == "true" ]]; then
    echo "=== Advisory Checks (non-blocking) ==="
    echo ""

    # Check for allowlist/denylist/safelist drift
    # shellcheck disable=SC2086
    if rg -n -i $GLOBS $EXCLUDES '\ballowlist\b|\bdenylist\b|\bsafelist\b' . 2>/dev/null; then
        echo "ADVISORY: Found allowlist/denylist/safelist — NFTBan uses whitelist/blacklist"
        echo ""
    fi

    # Check for "security engine" (forbidden identity term)
    # shellcheck disable=SC2086
    if rg -n -i $GLOBS $EXCLUDES '\bsecurity engine\b' . 2>/dev/null; then
        echo "ADVISORY: Found 'security engine' — use 'firewall manager' or 'IPS'"
        echo ""
    fi

    # Check for standalone "AI" near feature descriptions
    # shellcheck disable=SC2086
    if rg -n -i $GLOBS $EXCLUDES '\bAI\b' . 2>/dev/null | head -20; then
        echo "ADVISORY: Found 'AI' references — review for marketing language"
        echo ""
    fi

    echo "=== End Advisory Checks ==="
fi

# =============================================================================
# RESULT
# =============================================================================

if [[ "$fail" -eq 0 ]]; then
    echo "RESULT: PASS"
else
    echo "RESULT: FAIL — forbidden wording found (see above)"
fi

exit "$fail"
