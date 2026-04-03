#!/usr/bin/env bash
# =============================================================================
# NFTBan Update Safety Lint (U1 + U2)
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="lint_update_safety"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-03"
# meta:description="CI lint: enforce rebuild-failure-is-fatal invariant in postinst scripts"
# meta:input="None"
# meta:output="PASS/FAIL lint result to stdout"
# meta:depends=""
# meta:inventory.files="scripts/lint-update-safety.sh"
# meta:inventory.binaries="grep"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Gates:
#   U1: Reject fallback reload after rebuild failure in postinst
#       (systemctl reload nftables after rebuild fail = stale schema = false success)
#   U2: Reject rebuild failure without NFTBAN_INSTALL_FAILED=1 in postinst
#       (rebuild fail must propagate as package install failure)
#
# Exit codes:
#   0  All checks passed
#   1  One or more violations found
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

failures=0

# Files to check: RPM postinst (heredoc in build_nftban.sh) + DEB postinst
RPM_POSTINST="${REPO_ROOT}/packaging/build_nftban.sh"
DEB_POSTINST="${REPO_ROOT}/packaging/deb/postinst"

# =============================================================================
# U1: No fallback reload after rebuild failure
# =============================================================================
# The false-success path: rebuild fails → fallback to systemctl reload nftables
# → old schema stays in kernel → VERSION says new, kernel has old → all
# downstream trust (status, health, verification) is corrupted.
#
# This pattern must NEVER appear in postinst:
#   rebuild fail → systemctl reload nftables
# =============================================================================

echo "=== U1: Checking for fallback reload after rebuild failure ==="
u1_violations=0

for file in "$RPM_POSTINST" "$DEB_POSTINST"; do
    [[ -f "$file" ]] || continue
    basename=$(basename "$file")

    # Look for the dangerous pattern: rebuild fail block containing systemctl reload nftables
    # This catches both "systemctl reload nftables" and "systemctl reload nftables 2>/dev/null"
    # We scan for lines between "rebuild" fail blocks that contain "reload nftables"
    if grep -n 'rebuild failed\|rebuild FAILED\|Firewall rebuild failed' "$file" 2>/dev/null | while IFS=: read -r lineno _content; do
        # Check the next 5 lines after a rebuild failure message for a reload fallback
        for offset in 1 2 3 4 5; do
            check_line=$(sed -n "$((lineno + offset))p" "$file" 2>/dev/null || true)
            if echo "$check_line" | grep -q 'systemctl reload nftables' 2>/dev/null; then
                echo "::error file=${file},line=$((lineno + offset))::U1 VIOLATION: fallback 'systemctl reload nftables' after rebuild failure"
                echo "  ${lineno}: ${_content}"
                echo "  $((lineno + offset)): ${check_line}"
                echo "  Fix: remove fallback reload — set NFTBAN_INSTALL_FAILED=1 instead"
                exit 1  # signal violation from subshell
            fi
        done
    done; then
        # grep found matches but no violations in the loop
        :
    else
        if [[ $? -eq 1 ]]; then
            u1_violations=$((u1_violations + 1))
        fi
    fi
done

if [[ $u1_violations -gt 0 ]]; then
    echo ""
    echo "FAIL: $u1_violations U1 violation(s) — remove fallback reload after rebuild failure"
    failures=$((failures + u1_violations))
else
    echo "PASS: No fallback reload after rebuild failure"
fi

echo ""

# =============================================================================
# U2: Rebuild failure must set NFTBAN_INSTALL_FAILED=1
# =============================================================================
# Every rebuild failure path in postinst must set NFTBAN_INSTALL_FAILED=1.
# Without this, the package manager reports success despite stale kernel schema.
# =============================================================================

echo "=== U2: Checking that rebuild failure sets NFTBAN_INSTALL_FAILED ==="
u2_violations=0

for file in "$RPM_POSTINST" "$DEB_POSTINST"; do
    [[ -f "$file" ]] || continue
    basename=$(basename "$file")

    # Find all "rebuild failed/FAILED" error/warn messages
    while IFS=: read -r lineno content; do
        # Skip comment lines
        stripped=$(echo "$content" | sed 's/^[[:space:]]*//')
        [[ "$stripped" == \#* ]] && continue

        # Check the next 5 lines for NFTBAN_INSTALL_FAILED=1
        found_flag=false
        for offset in 1 2 3 4 5; do
            check_line=$(sed -n "$((lineno + offset))p" "$file" 2>/dev/null || true)
            if echo "$check_line" | grep -q 'NFTBAN_INSTALL_FAILED=1' 2>/dev/null; then
                found_flag=true
                break
            fi
        done

        if [[ "$found_flag" == "false" ]]; then
            echo "::error file=${file},line=${lineno}::U2 VIOLATION: rebuild failure without NFTBAN_INSTALL_FAILED=1"
            echo "  ${lineno}: ${content}"
            echo "  Fix: add 'NFTBAN_INSTALL_FAILED=1' after the error message"
            u2_violations=$((u2_violations + 1))
        fi
    done < <(grep -n 'rebuild FAILED\|rebuild failed' "$file" 2>/dev/null | grep -v '^\s*#' | grep -v 'run manually' || true)
done

if [[ $u2_violations -gt 0 ]]; then
    echo ""
    echo "FAIL: $u2_violations U2 violation(s) — rebuild failure must set NFTBAN_INSTALL_FAILED=1"
    failures=$((failures + u2_violations))
else
    echo "PASS: All rebuild failure paths set NFTBAN_INSTALL_FAILED=1"
fi

echo ""

# =============================================================================
# SUMMARY
# =============================================================================

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ $failures -gt 0 ]]; then
    echo "FAIL: $failures update safety violation(s) found"
    exit 1
else
    echo "PASS: All update safety checks passed (U1 + U2)"
    exit 0
fi
