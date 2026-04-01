#!/usr/bin/env bash
# =============================================================================
# NFTBan Jump Placement Lint (G1 + G2 + G3)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="lint_jump_placement"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-01"
# meta:description="CI lint: detect append-based input-chain jumps, broken anchor greps, and missing health checks"
# meta:input="None"
# meta:output="PASS/FAIL lint result to stdout"
# meta:depends=""
# meta:inventory.files="scripts/lint-jump-placement.sh"
# meta:inventory.binaries="grep,awk"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Gates:
#   G1: Reject append-based input-chain jumps in render_*_jump() functions
#   G2: Reject grep patterns known to fail against live nft output
#   G3: Reject placement-sensitive modules that lack a health check entry
#
# Exit codes:
#   0  All checks passed
#   1  One or more violations found
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

NFT_FRAGMENT="${REPO_ROOT}/cli/lib/nftban/lib/nft_fragment.sh"
HEALTH_CHECKS="${REPO_ROOT}/cli/lib/nftban/core/nftban_health_checks_security.sh"

failures=0

# =============================================================================
# G1: No append-based jumps in render_*_jump() functions
# =============================================================================
# Any function matching nft_fragment_render_*_jump() must NOT contain
# "add rule ... input ... jump" — all placement-sensitive jumps MUST use
# "nft insert rule ... position $handle".
# =============================================================================

echo "=== G1: Checking for append-based input-chain jumps ==="

if [[ ! -f "$NFT_FRAGMENT" ]]; then
    echo "FAIL: nft_fragment.sh not found at ${NFT_FRAGMENT}"
    exit 1
fi

# Extract function bodies of render_*_jump() functions and check for 'add rule' appends
# We look for heredoc-based fragments that use "add rule ... input ... jump"
# These are the fragment-file-based renderers (the broken pattern)
g1_hits=$(awk '
    /^nft_fragment_render_.*_jump\(\)/ { in_func=1; fname=$0; next }
    in_func && /^}/ { in_func=0; next }
    in_func && /add rule .* input .*jump/ { print NR": "fname" -> "$0 }
' "$NFT_FRAGMENT") || true

if [[ -n "$g1_hits" ]]; then
    echo "FAIL: Found append-based jump rules in render_*_jump() functions:"
    echo "$g1_hits"
    ((failures++))
else
    echo "PASS: No append-based jumps found in render_*_jump() functions"
fi

echo ""

# =============================================================================
# G2: No blacklisted anchor grep patterns
# =============================================================================
# These patterns are known to fail against live nft output because nft
# formats output differently than the pattern expects.
# =============================================================================

echo "=== G2: Checking for blacklisted anchor grep patterns ==="

g2_failures=0

# Pattern: grep "meter syn_meter" should be grep "syn_meter" (nft output may vary)
if grep -n 'grep.*"meter syn_meter' "$NFT_FRAGMENT" 2>/dev/null | grep -v '^#'; then
    echo "FAIL: Found 'grep \"meter syn_meter\"' — use 'grep \"syn_meter\"' or 'grep \"\${meter_name}\"'"
    ((g2_failures++))
fi
if grep -n "grep.*'meter syn_meter" "$NFT_FRAGMENT" 2>/dev/null | grep -v '^#'; then
    echo "FAIL: Found \"grep 'meter syn_meter'\" — use grep with just the meter name"
    ((g2_failures++))
fi

# Pattern: grep 'ct state established,related accept' should be grep 'established,related'
if grep -n "grep.*'ct state established,related accept'" "$NFT_FRAGMENT" 2>/dev/null | grep -v '^#'; then
    echo "FAIL: Found grep 'ct state established,related accept' — use grep 'established,related'"
    ((g2_failures++))
fi

if [[ "$g2_failures" -gt 0 ]]; then
    ((failures++))
else
    echo "PASS: No blacklisted anchor grep patterns found"
fi

echo ""

# =============================================================================
# G3: All placement-sensitive modules have health check entries
# =============================================================================
# Every module with a render_*_jump() function must have a corresponding
# entry in nftban_health_check_module_jump_placement() or
# nftban_health_check_portscan_placement().
# =============================================================================

echo "=== G3: Checking health check coverage for placement-sensitive modules ==="

if [[ ! -f "$HEALTH_CHECKS" ]]; then
    echo "FAIL: Health checks file not found at ${HEALTH_CHECKS}"
    exit 1
fi

# Placement-sensitive chains that MUST have health check entries
declare -a required_chains=(
    "ddos_sanity"
    "ddos_ban_enforce"
    "ddos_penalty"
    "ddos_prefix"
    "ddos_protection"
    "http_bot_guard"
    "ddos_synproxy"
    "portscan_detection"
)

g3_failures=0
for chain in "${required_chains[@]}"; do
    if ! grep -q "${chain}" "$HEALTH_CHECKS"; then
        echo "FAIL: No health check entry for '${chain}' in $(basename "$HEALTH_CHECKS")"
        ((g3_failures++))
    fi
done

if [[ "$g3_failures" -gt 0 ]]; then
    ((failures++))
else
    echo "PASS: All placement-sensitive modules have health check entries"
fi

echo ""

# =============================================================================
# Summary
# =============================================================================

if [[ "$failures" -gt 0 ]]; then
    echo "RESULT: FAIL (${failures} gate(s) failed)"
    exit 1
fi

echo "RESULT: PASS (all gates passed)"
exit 0
