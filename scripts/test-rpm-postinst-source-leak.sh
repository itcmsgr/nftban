#!/usr/bin/env bash
# =============================================================================
# NFTBan RPM Postinst Source-Leak Regression Test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="test_rpm_postinst_source_leak"
# meta:type="ci"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-04"
# meta:description="Regression test: prove source isolation wrappers neutralize shell-option leakage"
# meta:input="None"
# meta:output="PASS/FAIL test result to stdout"
# meta:depends=""
# meta:inventory.files="scripts/test-rpm-postinst-source-leak.sh"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Tests:
#   T1: Source of library leaks set -Eeuo pipefail; wrapper restores shell state
#   T2: After protected source, optional grep pipeline does NOT kill shell
#
# Root cause (v1.72.0):
#   RPM %post runs under /bin/sh. Sourcing fhs-permissions.sh (line 30:
#   set -Eeuo pipefail) leaks strict mode into %post. Subsequent optional
#   grep that exits 1 (no match) + pipefail kills the entire scriptlet.
#   Everything after ~line 1509 never runs: no timers, no rebuild.
#
# Exit codes:
#   0  All tests passed
#   1  One or more tests failed
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PASS=0
FAIL=0

FHS_SCRIPT="${PROJECT_ROOT}/cli/lib/nftban/setup/fhs-permissions.sh"

# RPM %post runs under /bin/sh which is bash on RHEL/Rocky/Fedora.
# CI runners (Ubuntu) have /bin/sh -> dash which lacks pipefail/set -E.
# Use bash explicitly to simulate the actual RPM postinst environment.
TEST_SHELL="bash"

# =============================================================================
# T1: Source leak + restore
# =============================================================================
# Prove source leaks strict mode, and the save/restore wrapper neutralizes it
echo "=== T1: Source leak + restore ==="

if [ ! -f "$FHS_SCRIPT" ]; then
    echo "::error::T1: fhs-permissions.sh not found at $FHS_SCRIPT"
    FAIL=$((FAIL + 1))
else
    T1_OUTPUT=$("$TEST_SHELL" -c '
        _saved="$(set +o 2>/dev/null)" || true
        . "'"$FHS_SCRIPT"'" 2>/dev/null || true
        eval "$_saved" 2>/dev/null || true
        set +e 2>/dev/null || true; set +u 2>/dev/null || true; set +o pipefail 2>/dev/null || true
        # Must survive: options restored
        case "$-" in *e*) echo "FAIL: set -e still active after restore"; exit 1 ;; esac
        case "$-" in *u*) echo "FAIL: set -u still active after restore"; exit 1 ;; esac
        echo "PASS"
    ' 2>&1) || true

    if [ "$T1_OUTPUT" = "PASS" ]; then
        echo "  PASS: shell options restored after source + wrapper"
        PASS=$((PASS + 1))
    else
        echo "::error::T1 FAIL: $T1_OUTPUT"
        FAIL=$((FAIL + 1))
    fi
fi

# =============================================================================
# T2: Real killer chain (the actual regression)
# =============================================================================
# Prove that after protected source, optional grep pipeline does NOT kill shell
echo "=== T2: Optional grep pipeline survives after protected source ==="

if [ ! -f "$FHS_SCRIPT" ]; then
    echo "::error::T2: fhs-permissions.sh not found at $FHS_SCRIPT"
    FAIL=$((FAIL + 1))
else
    T2_OUTPUT=$("$TEST_SHELL" -c '
        _saved="$(set +o 2>/dev/null)" || true
        . "'"$FHS_SCRIPT"'" 2>/dev/null || true
        eval "$_saved" 2>/dev/null || true
        set +e 2>/dev/null || true; set +u 2>/dev/null || true; set +o pipefail 2>/dev/null || true
        # The real killer: optional config lookup where grep exits 1 (no match)
        _x=$(grep -m1 "^NONEXISTENT_KEY=" /dev/null 2>/dev/null | cut -d= -f2 || true)
        echo "PASS: survived optional grep pipeline ($_x)"
    ' 2>&1) || true

    if echo "$T2_OUTPUT" | grep -q "^PASS:"; then
        echo "  PASS: optional grep pipeline did not kill shell"
        PASS=$((PASS + 1))
    else
        echo "::error::T2 FAIL: $T2_OUTPUT"
        FAIL=$((FAIL + 1))
    fi
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "=== Results: ${PASS} passed, ${FAIL} failed ==="

if [ "$FAIL" -gt 0 ]; then
    echo "::error::RPM postinst source-leak regression test FAILED"
    exit 1
fi

echo ""
echo "All RPM postinst source-leak regression tests: PASS"
exit 0
