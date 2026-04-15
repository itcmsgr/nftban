#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.84 — G2-1: Truth Consistency Test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="test_truth_consistency"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-15"
# meta:description="Verify CLI truth surfaces agree with Go validator (INV-CONS-001)"
# meta:inventory.files="cli/lib/nftban/tests/test_truth_consistency.sh"
# meta:inventory.binaries="nftban-validate,jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# Enforces: no split-brain between validator, status, and health commands.
# This test requires the Go validator binary to be installed.
# =============================================================================
set -Eeuo pipefail

VALIDATOR_BIN="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-validate"
PASS=0
FAIL=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS  $name: $actual"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name: expected=$expected actual=$actual"
        FAIL=$((FAIL + 1))
    fi
}

echo "=========================================================="
echo "G2-1: Truth Consistency Test (INV-CONS-001)"
echo "=========================================================="

# Skip if validator not installed (CI container without binary)
if [[ ! -x "$VALIDATOR_BIN" ]]; then
    echo "SKIP: Go validator not found at $VALIDATOR_BIN"
    echo "This test requires a deployed system with nftban-validate."
    exit 0
fi

# Get validator truth
VAL_JSON=$("$VALIDATOR_BIN" --json 2>/dev/null || true)
if [[ -z "$VAL_JSON" ]]; then
    echo "FAIL: Validator returned empty output"
    exit 1
fi

VAL_STATUS=$(echo "$VAL_JSON" | jq -r '.status' 2>/dev/null)
VAL_SCHEMA=$(echo "$VAL_JSON" | jq -r '.schema_version' 2>/dev/null)

echo ""
echo "Validator truth: status=$VAL_STATUS schema=$VAL_SCHEMA"
echo ""

# G2-1a: Validator status is a known value
case "$VAL_STATUS" in
    protected|idle|degraded|down)
        check "validator-status-valid" "valid" "valid"
        ;;
    *)
        check "validator-status-valid" "valid" "UNKNOWN:$VAL_STATUS"
        ;;
esac

# G2-1b: Schema version is present and non-empty
if [[ -n "$VAL_SCHEMA" && "$VAL_SCHEMA" != "null" ]]; then
    check "schema-version-present" "present" "present"
else
    check "schema-version-present" "present" "missing"
fi

# G2-1c: Health truth matches validator (if health command available)
if command -v nftban >/dev/null 2>&1; then
    HEALTH_JSON=$(nftban health --json 2>/dev/null || true)
    if [[ -n "$HEALTH_JSON" ]]; then
        HEALTH_STATUS=$(echo "$HEALTH_JSON" | jq -r '.status' 2>/dev/null)
        check "health-matches-validator" "$VAL_STATUS" "$HEALTH_STATUS"
    else
        echo "  SKIP  health --json not available"
    fi
fi

echo ""
echo "=========================================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================================="

if [[ $FAIL -gt 0 ]]; then
    echo "FAIL: Truth consistency violated (INV-CONS-001)"
    exit 1
fi
exit 0
