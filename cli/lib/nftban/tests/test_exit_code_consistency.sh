#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.84 — G7-3: Exit Code Consistency Test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="test_exit_code_consistency"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-15"
# meta:description="Verify exit code contract: 0=PROTECTED/IDLE, 1=DEGRADED, 2=DOWN"
# meta:inventory.files="cli/lib/nftban/tests/test_exit_code_consistency.sh"
# meta:inventory.binaries="nftban-validate,jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# Exit code contract (from CLI Reference + Glossary):
#   0 = PROTECTED or IDLE
#   1 = DEGRADED
#   2 = DOWN
#
# This test verifies that nftban-validate exit codes match this contract.
# =============================================================================
set -Eeuo pipefail

VALIDATOR_BIN="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-validate"
PASS=0
FAIL=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS  $name: exit=$actual"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name: expected=$expected actual=$actual"
        FAIL=$((FAIL + 1))
    fi
}

echo "=========================================================="
echo "G7-3: Exit Code Consistency Test"
echo "=========================================================="

# Skip if validator not installed
if [[ ! -x "$VALIDATOR_BIN" ]]; then
    echo "SKIP: Go validator not found at $VALIDATOR_BIN"
    exit 0
fi

# Get validator status and exit code
VAL_EXIT=0
VAL_JSON=$("$VALIDATOR_BIN" --json 2>/dev/null) || VAL_EXIT=$?
VAL_STATUS=$(echo "$VAL_JSON" | jq -r '.status // "unknown"' 2>/dev/null)

echo ""
echo "Validator: status=$VAL_STATUS exit=$VAL_EXIT"
echo ""

# Verify exit code matches status
case "$VAL_STATUS" in
    protected|idle)
        check "exit-code-for-$VAL_STATUS" "0" "$VAL_EXIT"
        ;;
    degraded)
        check "exit-code-for-degraded" "1" "$VAL_EXIT"
        ;;
    down)
        check "exit-code-for-down" "2" "$VAL_EXIT"
        ;;
    *)
        echo "  FAIL  unknown status: $VAL_STATUS (exit=$VAL_EXIT)"
        FAIL=$((FAIL + 1))
        ;;
esac

# Verify exit code is in valid range (0-2)
if [[ $VAL_EXIT -ge 0 && $VAL_EXIT -le 2 ]]; then
    check "exit-code-range" "valid" "valid"
else
    check "exit-code-range" "valid" "out-of-range:$VAL_EXIT"
fi

# Verify JSON output is valid regardless of status
if echo "$VAL_JSON" | jq . >/dev/null 2>&1; then
    check "json-valid" "valid" "valid"
else
    check "json-valid" "valid" "invalid-json"
fi

# Verify required JSON fields
for field in status schema_version service_state modules findings; do
    if echo "$VAL_JSON" | jq -e ".$field" >/dev/null 2>&1; then
        check "field-$field" "present" "present"
    else
        check "field-$field" "present" "missing"
    fi
done

echo ""
echo "=========================================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================================="

if [[ $FAIL -gt 0 ]]; then
    echo "FAIL: Exit code contract violated"
    exit 1
fi
exit 0
