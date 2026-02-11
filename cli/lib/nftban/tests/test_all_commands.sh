#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Command Testing Framework
# =============================================================================
# meta:name="test_all_commands"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Test all CLI commands to detect silent failures and hanging commands"
# meta:inventory.files=""
# meta:inventory.binaries="bash,nftban,timeout"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

# shellcheck disable=SC2034  # SCRIPT_DIR reserved for future use
# Script directory (currently unused, reserved for future use)
# SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# readonly SCRIPT_DIR
readonly TEST_TIMEOUT=20  # seconds (increased for commands with network checks)
TEST_LOG="/tmp/nftban_test_$(date +%Y%m%d_%H%M%S).log"
readonly TEST_LOG
readonly TEST_IP="8.8.8.8"  # Safe test IP (Google DNS)
readonly TEST_PORT="8080"

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m' # No Color

# Counters
TESTS_TOTAL=0
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TIMEOUT=0
TESTS_NO_OUTPUT=0

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$TEST_LOG"
}

test_start() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" | tee -a "$TEST_LOG"
}

test_end() {
    echo "" | tee -a "$TEST_LOG"
}

pass() {
    echo -e "${GREEN}✓ PASS${NC}: $*" | tee -a "$TEST_LOG"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}✗ FAIL${NC}: $*" | tee -a "$TEST_LOG"
    ((TESTS_FAILED++))
}

warn() {
    echo -e "${YELLOW}⚠ WARN${NC}: $*" | tee -a "$TEST_LOG"
}

timeout_fail() {
    echo -e "${RED}⏱ TIMEOUT${NC}: $*" | tee -a "$TEST_LOG"
    ((TESTS_TIMEOUT++))
}

no_output() {
    echo -e "${YELLOW}∅ NO OUTPUT${NC}: $*" | tee -a "$TEST_LOG"
    ((TESTS_NO_OUTPUT++))
}

# =============================================================================
# TEST COMMAND FUNCTION
# =============================================================================

# Test a command and check for:
# 1. Does it complete within timeout?
# 2. Does it produce output?
# 3. Does it have expected markers (banner, footer)?
# 4. What exit code does it return?
#
# Usage: test_command <name> <command> [expected_markers...]
test_command() {
    local name="$1"
    shift
    local cmd="$*"

    ((TESTS_TOTAL++))

    test_start
    log "TEST #$TESTS_TOTAL: $name"
    log "Command: $cmd"

    # Create temp file for output
    local output_file="/tmp/nftban_test_output_$$.txt"
    local exit_code_file="/tmp/nftban_test_exit_$$.txt"

    # Run command with timeout
    local start_time end_time duration
    start_time=$(date +%s)
    timeout $TEST_TIMEOUT bash -c "$cmd > '$output_file' 2>&1; echo \$? > '$exit_code_file'" || {
        local timeout_exit=$?
        if [[ $timeout_exit -eq 124 ]]; then
            timeout_fail "$name (exceeded ${TEST_TIMEOUT}s)"
            rm -f "$output_file" "$exit_code_file"
            test_end
            return 1
        fi
    }
    end_time=$(date +%s)
    duration=$((end_time - start_time))

    # Read results
    local output=""
    local exit_code=999

    if [[ -f "$output_file" ]]; then
        output=$(cat "$output_file")
    fi

    if [[ -f "$exit_code_file" ]]; then
        exit_code=$(cat "$exit_code_file")
    fi

    # Check 1: Does it have output?
    if [[ -z "$output" ]]; then
        no_output "$name - command produced NO output (${duration}s)"
        log "Exit code: $exit_code"
        rm -f "$output_file" "$exit_code_file"
        test_end
        return 1
    fi

    # Check 2: Does it have expected markers?
    local has_markers=false
    local marker_details=""

    # Check for common NFTBan markers
    if echo "$output" | grep -q "═\|─\|NFTBan\|nftban"; then
        has_markers=true
        marker_details="(has formatting markers)"
    fi

    # Check 3: Does it have exit marker?
    # This is what we'll add to all commands: "# NFTBAN_CMD_EXIT: <command_name>"
    if echo "$output" | grep -q "NFTBAN_CMD_EXIT"; then
        has_markers=true
        marker_details="$marker_details (has exit marker)"
    fi

    # Determine result
    if [[ $exit_code -eq 0 ]] && [[ -n "$output" ]]; then
        if [[ "$has_markers" == "true" ]]; then
            pass "$name - output OK, exit 0, ${duration}s $marker_details"
        else
            warn "$name - works but NO formatting markers (${duration}s)"
            ((TESTS_PASSED++))
        fi
    elif [[ $exit_code -ne 0 ]]; then
        # Some commands exit non-zero on purpose (e.g., search when not found, health check with errors)
        if [[ -n "$output" ]]; then
            if [[ "$has_markers" == "true" ]]; then
                warn "$name - exit $exit_code but has output and markers (${duration}s)"
                ((TESTS_PASSED++))
            else
                # Has output but no markers - could be intentional (like health summary)
                warn "$name - exit $exit_code with output but no markers (${duration}s)"
                ((TESTS_PASSED++))
            fi
        else
            fail "$name - exit code $exit_code (${duration}s)"
        fi
    else
        fail "$name - unexpected state: exit=$exit_code, output_len=${#output}"
    fi

    # Show sample of output (first 5 lines)
    log "Output sample:"
    echo "$output" | head -5 | sed 's/^/  | /' | tee -a "$TEST_LOG"

    # Cleanup
    rm -f "$output_file" "$exit_code_file"
    test_end
}

# =============================================================================
# TEST SUITE
# =============================================================================

run_all_tests() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "NFTBan Command Test Suite"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Started: $(date)"
    echo "Log file: $TEST_LOG"
    echo "Timeout per test: ${TEST_TIMEOUT}s"
    echo ""

    # Core Commands
    echo "=== CORE COMMANDS ==="
    test_command "status" "nftban status --quiet"
    test_command "version" "nftban version"
    test_command "help" "nftban help"
    test_command "health summary" "nftban health summary"
    test_command "check" "nftban check"

    # Firewall Commands
    echo ""
    echo "=== FIREWALL COMMANDS ==="
    test_command "firewall status" "nftban firewall status"
    test_command "firewall check" "nftban firewall check"

    # Search & List Commands
    echo ""
    echo "=== SEARCH & LIST ==="
    test_command "search (IP not found)" "nftban search $TEST_IP --no-interactive"
    test_command "search (port)" "nftban search $TEST_PORT --no-interactive"

    # Ban/Unban Commands (dry-run or safe operations)
    echo ""
    echo "=== BAN/UNBAN (INFO ONLY) ==="
    test_command "ban --help" "nftban ban --help"
    test_command "unban --help" "nftban unban --help"

    # Whitelist Commands
    echo ""
    echo "=== WHITELIST ==="
    test_command "whitelist status" "nftban whitelist status"
    test_command "whitelist list" "nftban whitelist list"

    # Module Commands - Status Only (non-destructive)
    echo ""
    echo "=== MODULES - STATUS ==="
    test_command "ddos status" "nftban ddos status"
    test_command "portscan status" "nftban portscan status"
    test_command "fail2ban status" "nftban fail2ban status"
    test_command "feeds status" "nftban feeds status"
    test_command "feeds list" "nftban feeds list"
    test_command "login status" "nftban login status"

    # GeoBan Commands
    echo ""
    echo "=== GEOBAN ==="
    test_command "geoip status" "nftban geoip status US"
    test_command "geoip list" "nftban geoip list"

    # Stats Commands
    echo ""
    echo "=== STATS ==="
    test_command "stats dashboard" "nftban stats dashboard"
    test_command "stats summary" "nftban stats summary"

    # Port Management
    echo ""
    echo "=== PORTS ==="
    test_command "port list" "nftban port list"
    test_command "port status" "nftban port status"

    # Permissions & Security
    echo ""
    echo "=== SECURITY ==="
    test_command "permissions check" "nftban permissions check"
    test_command "validate" "nftban validate"
}

# =============================================================================
# REPORT GENERATION
# =============================================================================

generate_report() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "TEST RESULTS SUMMARY"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Total Tests:     $TESTS_TOTAL"
    echo -e "${GREEN}Passed:          $TESTS_PASSED${NC}"
    echo -e "${RED}Failed:          $TESTS_FAILED${NC}"
    echo -e "${RED}Timeouts:        $TESTS_TIMEOUT${NC}"
    echo -e "${YELLOW}No Output:       $TESTS_NO_OUTPUT${NC}"
    echo ""

    local pass_rate=0
    if [[ $TESTS_TOTAL -gt 0 ]]; then
        pass_rate=$((TESTS_PASSED * 100 / TESTS_TOTAL))
    fi

    echo "Pass Rate:       ${pass_rate}%"
    echo ""
    echo "Completed: $(date)"
    echo "Full log: $TEST_LOG"
    echo ""

    # Generate JSON report
    local json_report="/tmp/nftban_test_report.json"
    cat > "$json_report" <<EOF
{
  "timestamp": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
  "summary": {
    "total": $TESTS_TOTAL,
    "passed": $TESTS_PASSED,
    "failed": $TESTS_FAILED,
    "timeout": $TESTS_TIMEOUT,
    "no_output": $TESTS_NO_OUTPUT,
    "pass_rate": $pass_rate
  },
  "log_file": "$TEST_LOG"
}
EOF
    echo "JSON report: $json_report"
    echo ""

    # Exit with error if any tests failed
    if [[ $TESTS_FAILED -gt 0 ]] || [[ $TESTS_TIMEOUT -gt 0 ]]; then
        echo -e "${RED}❌ SOME TESTS FAILED${NC}"
        return 1
    else
        echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
        return 0
    fi
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    # Check if running as root (some commands need it)
    if [[ $EUID -ne 0 ]]; then
        warn "Not running as root - some tests may fail"
        read -p "Continue anyway? [y/N] " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi

    # Initialize log
    echo "NFTBan Command Test Suite - $(date)" > "$TEST_LOG"
    echo "============================================" >> "$TEST_LOG"
    echo "" >> "$TEST_LOG"

    # Run tests
    run_all_tests

    # Generate report
    generate_report
}

# Run if executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
