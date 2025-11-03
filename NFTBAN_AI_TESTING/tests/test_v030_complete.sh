#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.30 - Comprehensive Test Suite
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Test all v0.30 components
#
# Usage: ./test_v030_complete.sh
# =============================================================================

set -Eeuo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

PASSED=0
FAILED=0
SKIPPED=0

test_result() {
    local name="$1"
    local status="$2"
    local message="${3:-}"

    case "$status" in
        PASS)
            echo -e "${GREEN}✓${NC} $name"
            PASSED=$((PASSED + 1))
            ;;
        FAIL)
            echo -e "${RED}✗${NC} $name"
            [[ -n "$message" ]] && echo "  Error: $message"
            FAILED=$((FAILED + 1))
            ;;
        SKIP)
            echo -e "${YELLOW}⊘${NC} $name (skipped)"
            SKIPPED=$((SKIPPED + 1))
            ;;
    esac
}

run_test() {
    local name="$1"
    shift

    if "$@" &>/tmp/test_output.txt; then
        test_result "$name" "PASS"
        return 0
    else
        test_result "$name" "FAIL" "$(head -3 /tmp/test_output.txt)"
        return 1
    fi
}

echo "═══════════════════════════════════════════════════════════"
echo "  NFTBan v0.30 Comprehensive Test Suite"
echo "═══════════════════════════════════════════════════════════"
echo

# =============================================================================
# PHASE 1: FILE EXISTENCE
# =============================================================================
echo "📦 Phase 1: File Existence Checks"
echo

[[ -x ../helpers/nftban-procnet ]] && test_result "Helper: nftban-procnet exists" "PASS" || test_result "Helper: nftban-procnet exists" "FAIL"
[[ -x ../helpers/nftban-pkgs ]] && test_result "Helper: nftban-pkgs exists" "PASS" || test_result "Helper: nftban-pkgs exists" "FAIL"
[[ -x ../helpers/nftban-verify ]] && test_result "Helper: nftban-verify exists" "PASS" || test_result "Helper: nftban-verify exists" "FAIL"
[[ -x ../helpers/nftban-firewall ]] && test_result "Helper: nftban-firewall exists" "PASS" || test_result "Helper: nftban-firewall exists" "FAIL"

[[ -x ../health/nftban-health ]] && test_result "Health: nftban-health exists" "PASS" || test_result "Health: nftban-health exists" "FAIL"
[[ -x ../health/nftban-baseline-save ]] && test_result "Health: nftban-baseline-save exists" "PASS" || test_result "Health: nftban-baseline-save exists" "FAIL"
[[ -x ../health/nftban-verify-signature ]] && test_result "Health: nftban-verify-signature exists" "PASS" || test_result "Health: nftban-verify-signature exists" "FAIL"

[[ -f ../mail/nftban_mail_v030.sh ]] && test_result "Mail: nftban_mail_v030.sh exists" "PASS" || test_result "Mail: nftban_mail_v030.sh exists" "FAIL"

[[ -f ../geoip/main.go ]] && test_result "GeoIP: main.go exists" "PASS" || test_result "GeoIP: main.go exists" "FAIL"
[[ -x ../geoip/BUILD.sh ]] && test_result "GeoIP: BUILD.sh exists" "PASS" || test_result "GeoIP: BUILD.sh exists" "FAIL"

echo

# =============================================================================
# PHASE 2: HELPER EXECUTION
# =============================================================================
echo "🔧 Phase 2: Helper Execution Tests"
echo

# Test procnet
if python3 -c "import json" 2>/dev/null; then
    run_test "Execute: nftban-procnet" ../helpers/nftban-procnet
    if ../helpers/nftban-procnet 2>/dev/null | python3 -m json.tool >/dev/null 2>&1; then
        test_result "Output: nftban-procnet JSON valid" "PASS"
    else
        test_result "Output: nftban-procnet JSON valid" "FAIL"
    fi
else
    test_result "Execute: nftban-procnet" "SKIP" "python3 not available"
fi

# Test pkgs
run_test "Execute: nftban-pkgs" ../helpers/nftban-pkgs

# Test firewall
run_test "Execute: nftban-firewall" ../helpers/nftban-firewall

echo

# =============================================================================
# PHASE 3: HEALTH CHECKS
# =============================================================================
echo "🏥 Phase 3: Health Check Tests"
echo

# These require polkit, may need sudo
if command -v pkexec >/dev/null 2>&1; then
    echo "Note: Health checks require polkit/sudo for full testing"
    echo "Skipping interactive tests in automated mode"
    test_result "Health checks" "SKIP" "Requires polkit setup"
else
    test_result "Health checks" "SKIP" "pkexec not available"
fi

echo

# =============================================================================
# PHASE 4: MAIL SYSTEM
# =============================================================================
echo "📧 Phase 4: Mail System Tests"
echo

# Test mail adapter loading
if source ../mail/nftban_mail_v030.sh 2>/dev/null; then
    test_result "Load: nftban_mail_v030.sh" "PASS"

    # Test detection
    if declare -f nftban_v030_mail_info >/dev/null 2>&1; then
        test_result "Function: nftban_v030_mail_info" "PASS"
    else
        test_result "Function: nftban_v030_mail_info" "FAIL"
    fi
else
    test_result "Load: nftban_mail_v030.sh" "FAIL"
fi

echo

# =============================================================================
# PHASE 5: GEOIP
# =============================================================================
echo "🌍 Phase 5: GeoIP Tests"
echo

if [[ -f ../geoip/nftban-geoip ]]; then
    run_test "GeoIP: Binary exists" test -x ../geoip/nftban-geoip
    run_test "GeoIP: Version check" ../geoip/nftban-geoip --version
    run_test "GeoIP: Lookup test" ../geoip/nftban-geoip --lookup 8.8.8.8
else
    test_result "GeoIP: Binary" "SKIP" "Not built yet (run: cd geoip && ./BUILD.sh)"
fi

echo

# =============================================================================
# PHASE 6: INTEGRATION
# =============================================================================
echo "🔗 Phase 6: Integration Tests"
echo

# Check if v0.10 mail exists
if [[ -f /usr/lib/nftban/core/nftban_mail.sh ]]; then
    test_result "Integration: v0.10 mail module detected" "PASS"
else
    test_result "Integration: v0.10 mail module" "SKIP" "Not installed"
fi

# Check config
if [[ -f /etc/nftban/conf.d/mail.conf ]]; then
    test_result "Integration: mail.conf exists" "PASS"
else
    test_result "Integration: mail.conf" "SKIP" "Not installed"
fi

echo

# =============================================================================
# SUMMARY
# =============================================================================
echo "═══════════════════════════════════════════════════════════"
echo "  Test Summary"
echo "═══════════════════════════════════════════════════════════"
echo -e "${GREEN}✓ Passed:${NC}  $PASSED"
echo -e "${RED}✗ Failed:${NC}  $FAILED"
echo -e "${YELLOW}⊘ Skipped:${NC} $SKIPPED"
echo "Total: $((PASSED + FAILED + SKIPPED))"
echo

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}🎉 ALL CRITICAL TESTS PASSED!${NC}"
    exit 0
else
    echo -e "${RED}⚠️  SOME TESTS FAILED - Review output above${NC}"
    exit 1
fi
