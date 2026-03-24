#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Validation Library Test Suite
# =============================================================================
# meta:name="test_validation"
# meta:type="test"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Test NFTBan validation library functions"
# meta:inventory.files=""
# meta:inventory.binaries="bash"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load validation library
source "$PROJECT_ROOT/cli/lib/nftban/lib/validation.sh" || return 1

pass_count=0
fail_count=0

test_validation() {
    local test_name="$1"
    local expected_result="$2"  # "pass" or "fail"
    shift 2
    local cmd=("$@")

    if "${cmd[@]}" >/dev/null 2>&1; then
        actual="pass"
    else
        actual="fail"
    fi

    if [[ "$actual" == "$expected_result" ]]; then
        echo "✅ $test_name"
        # v1.19.20 FIX
        ((pass_count++)) || true
    else
        echo "❌ $test_name (expected: $expected_result, got: $actual)"
        # v1.19.20 FIX
        ((fail_count++)) || true
    fi
}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "NFTBan Validation Library Tests"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "=== IPv4 Validation ==="
test_validation "Valid IPv4" pass nftban_validate_ipv4 "192.168.1.1"
test_validation "Valid IPv4 (0.0.0.0)" pass nftban_validate_ipv4 "0.0.0.0"
test_validation "Valid IPv4 (255.255.255.255)" pass nftban_validate_ipv4 "255.255.255.255"
test_validation "Invalid IPv4 (256.1.1.1)" fail nftban_validate_ipv4 "256.1.1.1"
test_validation "Invalid IPv4 (text)" fail nftban_validate_ipv4 "not.an.ip.address"
test_validation "Invalid IPv4 (incomplete)" fail nftban_validate_ipv4 "192.168.1"
echo ""

echo "=== IPv6 Validation ==="
test_validation "Valid IPv6" pass nftban_validate_ipv6 "2001:0db8:85a3:0000:0000:8a2e:0370:7334"
test_validation "Valid IPv6 (compressed)" pass nftban_validate_ipv6 "2001:db8::1"
test_validation "Valid IPv6 (::1)" pass nftban_validate_ipv6 "::1"
test_validation "Invalid IPv6 (too many groups)" fail nftban_validate_ipv6 "2001:0db8:85a3:0000:0000:8a2e:0370:7334:1234"
echo ""

echo "=== CIDR Validation ==="
test_validation "Valid CIDR IPv4" pass nftban_validate_cidr "192.168.1.0/24"
test_validation "Valid CIDR IPv4 (/32)" pass nftban_validate_cidr "192.168.1.1/32"
test_validation "Valid CIDR IPv6" pass nftban_validate_cidr "2001:db8::/32"
test_validation "Invalid CIDR (bad prefix)" fail nftban_validate_cidr "192.168.1.0/33"
test_validation "Invalid CIDR (bad IP)" fail nftban_validate_cidr "256.1.1.0/24"
echo ""

echo "=== Port Validation ==="
test_validation "Valid port (80)" pass nftban_validate_port "80"
test_validation "Valid port (1)" pass nftban_validate_port "1"
test_validation "Valid port (65535)" pass nftban_validate_port "65535"
test_validation "Invalid port (0)" fail nftban_validate_port "0"
test_validation "Invalid port (65536)" fail nftban_validate_port "65536"
test_validation "Invalid port (text)" fail nftban_validate_port "http"
echo ""

echo "=== Port Range Validation ==="
test_validation "Valid range" pass nftban_validate_port_range "80-443"
test_validation "Valid range (same)" pass nftban_validate_port_range "8080-8080"
test_validation "Invalid range (reversed)" fail nftban_validate_port_range "443-80"
test_validation "Invalid range (bad format)" fail nftban_validate_port_range "80:443"
echo ""

echo "=== Protocol Validation ==="
test_validation "Valid protocol (tcp)" pass nftban_validate_protocol "tcp"
test_validation "Valid protocol (UDP)" pass nftban_validate_protocol "UDP"
test_validation "Valid protocol (icmp)" pass nftban_validate_protocol "icmp"
test_validation "Invalid protocol" fail nftban_validate_protocol "invalid"
echo ""

echo "=== Duration Validation ==="
test_validation "Valid duration (1h)" pass nftban_validate_duration "1h"
test_validation "Valid duration (30m)" pass nftban_validate_duration "30m"
test_validation "Valid duration (7d)" pass nftban_validate_duration "7d"
test_validation "Invalid duration (1000d)" fail nftban_validate_duration "1000d"
test_validation "Invalid duration (1x)" fail nftban_validate_duration "1x"
echo ""

echo "=== Path Validation ==="
test_validation "Valid path" pass nftban_validate_path "/var/log/nftban"
test_validation "Path traversal" fail nftban_validate_path "/var/log/../../../etc/passwd"
test_validation "Path traversal (Windows)" fail nftban_validate_path "C:\\Windows\\..\\..\\etc\\passwd"
echo ""

echo "=== Filename Validation ==="
test_validation "Valid filename" pass nftban_validate_filename "nftban.log"
test_validation "Valid filename (dash)" pass nftban_validate_filename "nftban-errors.log"
test_validation "Invalid filename (slash)" fail nftban_validate_filename "../etc/passwd"
test_validation "Invalid filename (dot)" fail nftban_validate_filename "."
test_validation "Invalid filename (special)" fail nftban_validate_filename "file\$name"
echo ""

echo "=== Country Code Validation ==="
test_validation "Valid country (US)" pass nftban_validate_country_code "US"
test_validation "Valid country (GB)" pass nftban_validate_country_code "GB"
test_validation "Invalid country (lowercase)" fail nftban_validate_country_code "us"
test_validation "Invalid country (too long)" fail nftban_validate_country_code "USA"
echo ""

echo "=== Integer Validation ==="
test_validation "Valid integer" pass nftban_validate_integer "42"
test_validation "Valid integer (negative)" pass nftban_validate_integer "-10"
test_validation "Integer in range" pass nftban_validate_integer "50" "0" "100"
test_validation "Integer out of range" fail nftban_validate_integer "150" "0" "100"
test_validation "Invalid integer (text)" fail nftban_validate_integer "abc"
echo ""

echo "=== Boolean Validation ==="
test_validation "Valid boolean (true)" pass nftban_validate_boolean "true"
test_validation "Valid boolean (yes)" pass nftban_validate_boolean "yes"
test_validation "Valid boolean (1)" pass nftban_validate_boolean "1"
test_validation "Invalid boolean" fail nftban_validate_boolean "maybe"
echo ""

echo "=== Sanitization Tests ==="
# Test shell sanitization
dangerous_input='$(rm -rf /)'
safe_output=$(nftban_sanitize_shell "$dangerous_input")
if [[ "$safe_output" == '\$(rm -rf /)' ]]; then
    echo "✅ Shell sanitization prevents command injection"
    # v1.19.20 FIX
    ((pass_count++)) || true
else
    echo "❌ Shell sanitization failed (got: $safe_output)"
    # v1.19.20 FIX
    ((fail_count++)) || true
fi

# Test HTML sanitization
xss_input='<script>alert("XSS")</script>'
safe_html=$(nftban_sanitize_html "$xss_input")
if [[ "$safe_html" != *'<script>'* ]]; then
    echo "✅ HTML sanitization prevents XSS"
    # v1.19.20 FIX
    ((pass_count++)) || true
else
    echo "❌ HTML sanitization failed"
    # v1.19.20 FIX
    ((fail_count++)) || true
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Test Results:"
echo "  ✅ Passed: $pass_count"
echo "  ❌ Failed: $fail_count"
echo "  Total:  $((pass_count + fail_count))"

if [[ $fail_count -eq 0 ]]; then
    echo ""
    echo "✅ All tests passed!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 0
else
    echo ""
    echo "❌ Some tests failed"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    exit 1
fi
