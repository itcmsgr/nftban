#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.84 — G2-3: Schema Version Guard Test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="test_schema_version_guard"
# meta:type="test"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2026-04-15"
# meta:description="Verify schema version in Go validator matches CLI expectations"
# meta:inventory.files="cli/lib/nftban/tests/test_schema_version_guard.sh"
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Checks that the Go validator's schema_version field matches the
# expected version hardcoded in CLI wrappers. Prevents silent breakage
# from mismatched binary/shell versions.
# =============================================================================
set -Eeuo pipefail

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
echo "G2-3: Schema Version Guard Test"
echo "=========================================================="

# Extract expected schema from Go source (types.go)
TYPES_FILE="internal/validator/types.go"
if [[ ! -f "$TYPES_FILE" ]]; then
    # Try repo root
    TYPES_FILE="${0%cli/lib/nftban/tests/*}internal/validator/types.go"
fi

if [[ -f "$TYPES_FILE" ]]; then
    GO_SCHEMA=$(grep 'SchemaVersionCurrent' "$TYPES_FILE" | grep -oP '"[0-9]+\.[0-9]+\.[0-9]+"' | tr -d '"')
    echo "Go source schema: $GO_SCHEMA"
else
    echo "SKIP: Cannot find $TYPES_FILE (run from repo root)"
    exit 0
fi

# Extract expected schema from CLI (cmd_status.sh)
STATUS_FILE="cli/lib/nftban/cli/cmd_status.sh"
if [[ ! -f "$STATUS_FILE" ]]; then
    STATUS_FILE="${0%cli/lib/nftban/tests/*}cli/lib/nftban/cli/cmd_status.sh"
fi

if [[ -f "$STATUS_FILE" ]]; then
    CLI_SCHEMA=$(grep '_expected_schema=' "$STATUS_FILE" | grep -oP '"[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | tr -d '"')
    echo "CLI expected schema: $CLI_SCHEMA"
    check "go-matches-cli-status" "$GO_SCHEMA" "$CLI_SCHEMA"
else
    echo "  SKIP  cmd_status.sh not found"
fi

# Extract expected schema from CLI (cmd_health.sh)
HEALTH_FILE="cli/lib/nftban/cli/cmd_health.sh"
if [[ ! -f "$HEALTH_FILE" ]]; then
    HEALTH_FILE="${0%cli/lib/nftban/tests/*}cli/lib/nftban/cli/cmd_health.sh"
fi

if [[ -f "$HEALTH_FILE" ]]; then
    HEALTH_SCHEMA=$(grep '_expected_schema=' "$HEALTH_FILE" | grep -oP '"[0-9]+\.[0-9]+\.[0-9]+"' | head -1 | tr -d '"')
    echo "Health expected schema: $HEALTH_SCHEMA"
    check "go-matches-cli-health" "$GO_SCHEMA" "$HEALTH_SCHEMA"
else
    echo "  SKIP  cmd_health.sh not found"
fi

echo ""
echo "=========================================================="
echo "Results: $PASS passed, $FAIL failed"
echo "=========================================================="

if [[ $FAIL -gt 0 ]]; then
    echo "FAIL: Schema version mismatch — binary and CLI disagree"
    exit 1
fi
exit 0
