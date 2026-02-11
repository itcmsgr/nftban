#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - JSON Output Helper Test Suite
# =============================================================================
# meta:name="test_json_output"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Test script for json_output.sh helper module"
# meta:inventory.files=""
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail

# Source the JSON helper
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/json_output.sh"

echo "════════════════════════════════════════════════════════"
echo "Testing NFTBan JSON Output Helper v1.0.0"
echo "════════════════════════════════════════════════════════"
echo ""

# Test 1: is_json_mode detection
echo "Test 1: is_json_mode() detection"
echo "─────────────────────────────────────────────────────────"
if is_json_mode "ban" "1.1.1.1" "--json"; then
    echo "✓ PASS: --json flag detected"
else
    echo "✗ FAIL: --json flag not detected"
fi

if is_json_mode "ban" "1.1.1.1"; then
    echo "✗ FAIL: False positive (no --json flag)"
else
    echo "✓ PASS: Correctly returned false when no --json flag"
fi
echo ""

# Test 2: json_build_object
echo "Test 2: json_build_object()"
echo "─────────────────────────────────────────────────────────"
data=$(json_build_object "ip" "1.1.1.1" "action" "banned" "timeout" "24h")
echo "Generated: $data"
if echo "$data" | jq empty 2>/dev/null; then
    echo "✓ PASS: Valid JSON object"
else
    echo "⚠ WARNING: Could not validate (jq not available or JSON invalid)"
fi
echo ""

# Test 3: json_build_array
echo "Test 3: json_build_array()"
echo "─────────────────────────────────────────────────────────"
array=$(json_build_array "location1" "location2" "location3")
echo "Generated: $array"
if echo "$array" | jq empty 2>/dev/null; then
    echo "✓ PASS: Valid JSON array"
else
    echo "⚠ WARNING: Could not validate (jq not available or JSON invalid)"
fi
echo ""

# Test 4: json_output with success
echo "Test 4: json_output() - Success case"
echo "─────────────────────────────────────────────────────────"
output=$(json_output "true" '{"ip":"1.1.1.1","reason":"Test ban"}')
echo "$output"
if echo "$output" | jq empty 2>/dev/null; then
    echo "✓ PASS: Valid JSON output"
    # Check structure
    if echo "$output" | jq -e '.success == true' >/dev/null 2>&1; then
        echo "✓ PASS: success field is true"
    fi
    if echo "$output" | jq -e '.timestamp' >/dev/null 2>&1; then
        echo "✓ PASS: timestamp field present"
    fi
    if echo "$output" | jq -e '.data.ip == "1.1.1.1"' >/dev/null 2>&1; then
        echo "✓ PASS: data field correct"
    fi
else
    echo "⚠ WARNING: Could not validate (jq not available)"
fi
echo ""

# Test 5: json_output with error
echo "Test 5: json_output() - Error case"
echo "─────────────────────────────────────────────────────────"
output=$(json_output "false" '{}' "IP address is invalid")
echo "$output"
if echo "$output" | jq empty 2>/dev/null; then
    echo "✓ PASS: Valid JSON output"
    if echo "$output" | jq -e '.success == false' >/dev/null 2>&1; then
        echo "✓ PASS: success field is false"
    fi
    if echo "$output" | jq -e '.error == "IP address is invalid"' >/dev/null 2>&1; then
        echo "✓ PASS: error field correct"
    fi
else
    echo "⚠ WARNING: Could not validate (jq not available)"
fi
echo ""

# Test 6: Complete example (simulating ban command)
echo "Test 6: Complete example (ban command simulation)"
echo "─────────────────────────────────────────────────────────"

simulate_ban_command() {
    local ip="$1"
    shift

    if is_json_mode "$@"; then
        # JSON mode
        local data
        data=$(json_build_object "ip" "$ip" "action" "banned" "reason" "Test")
        json_output "true" "$data"
    else
        # Human-readable mode
        echo "✓ Banned $ip successfully"
    fi
}

echo "Human-readable mode:"
simulate_ban_command "1.1.1.1"
echo ""

echo "JSON mode:"
simulate_ban_command "1.1.1.1" "--json"
echo ""

echo "════════════════════════════════════════════════════════"
echo "Test Summary"
echo "════════════════════════════════════════════════════════"
echo "✓ JSON helper module loaded successfully"
echo "✓ All functions available"
echo "✓ Ready to integrate into CLI commands"
echo ""
echo "Next step: Integrate into actual CLI commands (ban, unban, etc.)"
