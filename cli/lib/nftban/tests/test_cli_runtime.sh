#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.87 — CLI Runtime Smoke Gate
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="test_cli_runtime"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-15"
# meta:description="Verify all primary CLI commands execute without bash runtime errors"
# meta:inventory.files="cli/lib/nftban/tests/test_cli_runtime.sh"
# meta:inventory.binaries="nftban"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# This test runs on deployed hosts (not CI containers).
# It verifies crash-free execution — not semantic correctness.
# Nonzero exit codes are allowed for commands with valid contract meanings
# (e.g., health diagnostics exit 2 = errors found).
#
# What this catches:
# - bad array subscript (empty variable in associative array)
# - unbound variable (set -u violations)
# - syntax errors
# - command not found
# - shell runtime crashes
#
# What this does NOT check:
# - output correctness (that's validator/health tests)
# - exit code semantics (that's test_exit_code_consistency.sh)
# =============================================================================
set -Eeuo pipefail

PASS=0
FAIL=0
TOTAL=0

echo "=========================================================="
echo "CLI Runtime Smoke Gate"
echo "=========================================================="

# Skip if nftban not installed
if ! command -v nftban >/dev/null 2>&1; then
    echo "SKIP: nftban not found"
    exit 0
fi

# run_safe: execute command, check for bash runtime errors (not exit code)
run_safe() {
    local cmd="$1"
    TOTAL=$((TOTAL + 1))
    local output
    output=$(eval "$cmd" 2>&1) || true
    # Check for bash runtime errors in stderr output
    if echo "$output" | grep -qE "bad array subscript|unbound variable|syntax error|command not found|: line [0-9]+:.*Error"; then
        echo "  FAIL  $cmd"
        echo "$output" | grep -E "bad array|unbound variable|syntax error|command not found|: line [0-9]" | head -2 | sed 's/^/         /'
        FAIL=$((FAIL + 1))
    else
        echo "  OK    $cmd"
        PASS=$((PASS + 1))
    fi
}

echo ""
echo "Core Commands"
echo "────────────────────────────────────────"
run_safe "nftban version"
run_safe "nftban status"
run_safe "nftban status --brief"
run_safe "nftban status --json"
run_safe "nftban health"
run_safe "nftban health --json"
run_safe "nftban health truth"
run_safe "nftban health diagnostics --quiet"

echo ""
echo "Module Commands"
echo "────────────────────────────────────────"
run_safe "nftban ddos status"
run_safe "nftban portscan status"
run_safe "nftban login status"
run_safe "nftban botguard status"
run_safe "nftban blacklist list"
run_safe "nftban feeds list"
run_safe "nftban geoban status"
run_safe "nftban tunnel status"

echo ""
echo "Firewall & Services"
echo "────────────────────────────────────────"
run_safe "nftban firewall validate"
run_safe "nftban services"
run_safe "nftban timers"

echo ""
echo "Search & List"
echo "────────────────────────────────────────"
run_safe "nftban list banned"
run_safe "nftban list whitelist"
run_safe "nftban search 127.0.0.1"

echo ""
echo "Metrics"
echo "────────────────────────────────────────"
run_safe "nftban metrics status"

echo ""
echo "Health Diagnostics"
echo "────────────────────────────────────────"
run_safe "nftban health binaries"
run_safe "nftban health config"
run_safe "nftban health install"
run_safe "nftban health posture"

echo ""
echo "=========================================================="
echo "Results: $PASS passed, $FAIL failed, $TOTAL total"
echo "=========================================================="

if [[ $FAIL -gt 0 ]]; then
    echo "FAIL: $FAIL CLI command(s) have bash runtime errors"
    exit 1
fi
exit 0
