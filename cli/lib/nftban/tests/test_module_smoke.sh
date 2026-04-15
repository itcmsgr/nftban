#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.85 — G8-4: Cross-Surface Module Smoke Test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="test_module_smoke"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-15"
# meta:description="Verify validator and health CLI agree on module inventory"
# meta:inventory.files="cli/lib/nftban/tests/test_module_smoke.sh"
# meta:inventory.binaries="nftban-validate,jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
#
# G8-4: Cross-surface smoke gate.
# Compares module lists from nftban-validate --json and nftban health --json.
# Module lists must match exactly. Any drift = FAIL.
#
# This test requires a deployed system with nftban-validate binary.
# =============================================================================
set -Eeuo pipefail

VALIDATOR_BIN="${NFTBAN_LIB_DIR:-/usr/lib/nftban}/bin/nftban-validate"
PASS=0
FAIL=0

check() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS  $name"
        PASS=$((PASS + 1))
    else
        echo "  FAIL  $name"
        echo "    expected: $expected"
        echo "    actual:   $actual"
        FAIL=$((FAIL + 1))
    fi
}

echo "=========================================================="
echo "G8-4: Cross-Surface Module Smoke Test"
echo "=========================================================="

# Skip if validator not installed
if [[ ! -x "$VALIDATOR_BIN" ]]; then
    echo "SKIP: Go validator not found at $VALIDATOR_BIN"
    exit 0
fi

# Skip if jq not available
if ! command -v jq >/dev/null 2>&1; then
    echo "SKIP: jq not found"
    exit 0
fi

# Get validator module list
VAL_JSON=$("$VALIDATOR_BIN" --json 2>/dev/null || true)
if [[ -z "$VAL_JSON" ]]; then
    echo "FAIL: Validator returned empty output"
    exit 1
fi

VAL_MODULES=$(echo "$VAL_JSON" | jq -r '.modules | keys[]' 2>/dev/null | sort)
echo ""
echo "Validator modules: $(echo "$VAL_MODULES" | tr '\n' ' ')"

# Get health module list (if nftban CLI available)
if command -v nftban >/dev/null 2>&1; then
    HEALTH_JSON=$(nftban health --json 2>/dev/null || true)
    if [[ -n "$HEALTH_JSON" ]]; then
        HEALTH_MODULES=$(echo "$HEALTH_JSON" | jq -r '.modules | keys[]' 2>/dev/null | sort)
        echo "Health modules:    $(echo "$HEALTH_MODULES" | tr '\n' ' ')"
        echo ""

        # Compare module lists
        check "module-list-match" "$VAL_MODULES" "$HEALTH_MODULES"

        # Per-module status agreement
        for mod in $VAL_MODULES; do
            VAL_STATUS=$(echo "$VAL_JSON" | jq -r ".modules.${mod}.config // .modules.${mod}.manual.state // \"present\"" 2>/dev/null)
            HEALTH_STATUS=$(echo "$HEALTH_JSON" | jq -r ".modules.${mod}.config // .modules.${mod}.manual.state // \"present\"" 2>/dev/null)
            check "module-${mod}-config-match" "$VAL_STATUS" "$HEALTH_STATUS"
        done
    else
        echo "  SKIP  health --json not available"
    fi
else
    echo "  SKIP  nftban CLI not available (runtime test only)"
fi

# Verify all CORE modules are present in validator output
CORE_MODULES="blacklist botguard ddos loginmon portscan"
echo ""
echo "CORE module presence check:"
for mod in $CORE_MODULES; do
    if echo "$VAL_MODULES" | grep -q "^${mod}$"; then
        check "core-present-${mod}" "present" "present"
    else
        check "core-present-${mod}" "present" "MISSING"
    fi
done

# Verify validator status is valid
VAL_STATUS=$(echo "$VAL_JSON" | jq -r '.status' 2>/dev/null)
case "$VAL_STATUS" in
    protected|idle|degraded|down)
        check "validator-status-valid" "valid" "valid"
        ;;
    *)
        check "validator-status-valid" "valid" "INVALID:$VAL_STATUS"
        ;;
esac

echo ""
echo "=========================================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================================="

if [[ $FAIL -gt 0 ]]; then
    echo "FAIL: Cross-surface module smoke failed"
    exit 1
fi
exit 0
