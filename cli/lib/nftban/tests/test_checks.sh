#!/usr/bin/env bash
# =============================================================================
# NFTBan Check Functions Smoke Test
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Unit tests for nftban_checks.sh shared functions
#
# meta:name="checks_smoke"
# meta:type="test"
# meta:version="1.0.0"
# meta:description="Smoke tests for shared check functions library"
#
# meta:inventory.files=""
# meta:inventory.binaries="bash,jq"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
#
# Usage: ./tests/checks_smoke.sh [--verbose]
#
# Exit codes:
#   0 - All tests passed
#   1 - Some tests failed
#   2 - Test setup failed
# =============================================================================

set -Eeuo pipefail

# =============================================================================
# TEST CONFIGURATION
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# tests/ is inside cli/lib/nftban/, so parent is the nftban lib dir
NFTBAN_LIB="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source the library under test
LIB_PATH="$NFTBAN_LIB/lib/nftban_checks.sh"

VERBOSE=0
PASSED=0
FAILED=0
SKIPPED=0

# Parse arguments
for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=1 ;;
        --help|-h)
            echo "Usage: $0 [--verbose]"
            echo "  --verbose  Show detailed output for each test"
            exit 0
            ;;
    esac
done

# =============================================================================
# TEST UTILITIES
# =============================================================================

_log() {
    [[ $VERBOSE -eq 1 ]] && echo "  $*"
}

_pass() {
    local test_name="$1"
    ((++PASSED))
    echo "✅ PASS: $test_name"
}

_fail() {
    local test_name="$1"
    local reason="${2:-}"
    ((++FAILED))
    echo "❌ FAIL: $test_name"
    [[ -n "$reason" ]] && echo "   Reason: $reason"
}

_skip() {
    local test_name="$1"
    local reason="${2:-}"
    ((++SKIPPED))
    echo "⏭️  SKIP: $test_name"
    [[ -n "$reason" ]] && echo "   Reason: $reason"
}

# Validate JSON structure has required fields
_validate_json_contract() {
    local json="$1"
    local test_name="$2"

    # Check required top-level fields
    local ok checked_at data error

    ok=$(echo "$json" | jq -r '.ok // "missing"' 2>/dev/null)
    checked_at=$(echo "$json" | jq -r '.checked_at // "missing"' 2>/dev/null)
    data=$(echo "$json" | jq -r '.data // "missing"' 2>/dev/null)
    error=$(echo "$json" | jq -r '.error // "missing"' 2>/dev/null)

    local valid=true
    local issues=""

    if [[ "$ok" == "missing" ]]; then
        valid=false
        issues+="missing 'ok' field; "
    elif [[ "$ok" != "true" && "$ok" != "false" ]]; then
        valid=false
        issues+="'ok' must be boolean, got: $ok; "
    fi

    if [[ "$checked_at" == "missing" ]]; then
        valid=false
        issues+="missing 'checked_at' field; "
    elif [[ ! "$checked_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
        valid=false
        issues+="'checked_at' not ISO8601Z format: $checked_at; "
    fi

    if [[ "$data" == "missing" ]]; then
        valid=false
        issues+="missing 'data' field; "
    fi

    if [[ "$error" == "missing" ]]; then
        valid=false
        issues+="missing 'error' field; "
    fi

    if [[ "$valid" == "true" ]]; then
        return 0
    else
        echo "$issues"
        return 1
    fi
}

# =============================================================================
# SETUP
# =============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  NFTBan Check Functions Smoke Test"
echo "═══════════════════════════════════════════════════════════════"
echo ""

# Check jq is available
if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required for JSON validation"
    exit 2
fi

# Source the library
if [[ ! -f "$LIB_PATH" ]]; then
    echo "ERROR: Library not found: $LIB_PATH"
    exit 2
fi

# shellcheck source=/dev/null
source "$LIB_PATH"

if [[ -z "${_NFTBAN_CHECKS_LOADED:-}" ]]; then
    echo "ERROR: Library failed to load (guard variable not set)"
    exit 2
fi

echo "Library loaded: $LIB_PATH"
echo ""

# =============================================================================
# TEST: JSON Contract Validation
# =============================================================================

echo "--- JSON Contract Tests ---"

test_suricata_json_contract() {
    local result
    result=$(nftban_check_suricata_status)
    local exit_code=$?

    _log "Output: $result"
    _log "Exit code: $exit_code"

    if [[ $exit_code -ne 0 ]]; then
        _fail "suricata_json_contract" "Function returned non-zero: $exit_code"
        return
    fi

    local issues
    if issues=$(_validate_json_contract "$result" "suricata"); then
        _pass "suricata_json_contract"
    else
        _fail "suricata_json_contract" "$issues"
    fi
}

test_service_metrics_json_contract() {
    local result
    result=$(nftban_check_service_metrics "nftables.service")
    local exit_code=$?

    _log "Output: $result"
    _log "Exit code: $exit_code"

    if [[ $exit_code -ne 0 ]]; then
        _fail "service_metrics_json_contract" "Function returned non-zero: $exit_code"
        return
    fi

    local issues
    if issues=$(_validate_json_contract "$result" "service_metrics"); then
        _pass "service_metrics_json_contract"
    else
        _fail "service_metrics_json_contract" "$issues"
    fi
}

test_timer_status_json_contract() {
    local result
    result=$(nftban_check_timer_status "nftban-health.timer")
    local exit_code=$?

    _log "Output: $result"
    _log "Exit code: $exit_code"

    if [[ $exit_code -ne 0 ]]; then
        _fail "timer_status_json_contract" "Function returned non-zero: $exit_code"
        return
    fi

    local issues
    if issues=$(_validate_json_contract "$result" "timer_status"); then
        _pass "timer_status_json_contract"
    else
        _fail "timer_status_json_contract" "$issues"
    fi
}

test_binary_integrity_json_contract() {
    local result
    result=$(nftban_check_binary_integrity "/usr/lib/nftban/bin/nftban-core")
    local exit_code=$?

    _log "Output: $result"
    _log "Exit code: $exit_code"

    if [[ $exit_code -ne 0 ]]; then
        _fail "binary_integrity_json_contract" "Function returned non-zero: $exit_code"
        return
    fi

    local issues
    if issues=$(_validate_json_contract "$result" "binary_integrity"); then
        _pass "binary_integrity_json_contract"
    else
        _fail "binary_integrity_json_contract" "$issues"
    fi
}

test_config_exists_json_contract() {
    local result
    result=$(nftban_check_config_exists "/etc/nftban/nftban.conf")
    local exit_code=$?

    _log "Output: $result"
    _log "Exit code: $exit_code"

    if [[ $exit_code -ne 0 ]]; then
        _fail "config_exists_json_contract" "Function returned non-zero: $exit_code"
        return
    fi

    local issues
    if issues=$(_validate_json_contract "$result" "config_exists"); then
        _pass "config_exists_json_contract"
    else
        _fail "config_exists_json_contract" "$issues"
    fi
}

test_dns_json_contract() {
    local result
    result=$(nftban_check_dns "localhost")
    local exit_code=$?

    _log "Output: $result"
    _log "Exit code: $exit_code"

    if [[ $exit_code -ne 0 ]]; then
        _fail "dns_json_contract" "Function returned non-zero: $exit_code"
        return
    fi

    local issues
    if issues=$(_validate_json_contract "$result" "dns"); then
        _pass "dns_json_contract"
    else
        _fail "dns_json_contract" "$issues"
    fi
}

# Run contract tests
test_suricata_json_contract
test_service_metrics_json_contract
test_timer_status_json_contract
test_binary_integrity_json_contract
test_config_exists_json_contract
test_dns_json_contract

echo ""

# =============================================================================
# TEST: Parameter Validation
# =============================================================================

echo "--- Parameter Validation Tests ---"

test_service_metrics_missing_param() {
    local result
    result=$(nftban_check_service_metrics "")
    local exit_code=$?

    _log "Output: $result"
    _log "Exit code: $exit_code"

    # Should return non-zero when required param is missing
    if [[ $exit_code -ne 0 ]]; then
        # Check error message in JSON
        local error_msg
        error_msg=$(echo "$result" | jq -r '.error // ""' 2>/dev/null)
        if [[ "$error_msg" == *"required"* ]]; then
            _pass "service_metrics_missing_param"
        else
            _fail "service_metrics_missing_param" "Error message doesn't mention 'required'"
        fi
    else
        _fail "service_metrics_missing_param" "Should return non-zero for missing param"
    fi
}

test_timer_status_missing_param() {
    local result
    result=$(nftban_check_timer_status "")
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        _pass "timer_status_missing_param"
    else
        _fail "timer_status_missing_param" "Should return non-zero for missing param"
    fi
}

test_binary_integrity_missing_param() {
    local result
    result=$(nftban_check_binary_integrity "")
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        _pass "binary_integrity_missing_param"
    else
        _fail "binary_integrity_missing_param" "Should return non-zero for missing param"
    fi
}

test_config_exists_missing_param() {
    local result
    result=$(nftban_check_config_exists "")
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        _pass "config_exists_missing_param"
    else
        _fail "config_exists_missing_param" "Should return non-zero for missing param"
    fi
}

# Run param tests
test_service_metrics_missing_param
test_timer_status_missing_param
test_binary_integrity_missing_param
test_config_exists_missing_param

echo ""

# =============================================================================
# TEST: Data Field Validation
# =============================================================================

echo "--- Data Field Validation Tests ---"

test_suricata_data_fields() {
    local result
    result=$(nftban_check_suricata_status)
    local data
    data=$(echo "$result" | jq '.data' 2>/dev/null)

    # Check required fields exist
    local required_fields=("installed" "service_active" "eve_exists" "eve_fresh" "status")
    local missing=""

    for field in "${required_fields[@]}"; do
        local val
        val=$(echo "$data" | jq -r ".$field // \"MISSING\"" 2>/dev/null)
        if [[ "$val" == "MISSING" ]]; then
            missing+="$field "
        fi
    done

    if [[ -z "$missing" ]]; then
        _pass "suricata_data_fields"
    else
        _fail "suricata_data_fields" "Missing fields: $missing"
    fi
}

test_service_metrics_data_fields() {
    local result
    result=$(nftban_check_service_metrics "nftables.service")
    local data
    data=$(echo "$result" | jq '.data' 2>/dev/null)

    local required_fields=("unit" "exists" "active" "enabled" "status")
    local missing=""

    for field in "${required_fields[@]}"; do
        local val
        val=$(echo "$data" | jq -r ".$field // \"MISSING\"" 2>/dev/null)
        if [[ "$val" == "MISSING" ]]; then
            missing+="$field "
        fi
    done

    if [[ -z "$missing" ]]; then
        _pass "service_metrics_data_fields"
    else
        _fail "service_metrics_data_fields" "Missing fields: $missing"
    fi
}

test_timer_data_fields() {
    local result
    result=$(nftban_check_timer_status "nftban-health.timer")
    local data
    data=$(echo "$result" | jq '.data' 2>/dev/null)

    local required_fields=("timer" "exists" "active" "enabled" "status")
    local missing=""

    for field in "${required_fields[@]}"; do
        local val
        val=$(echo "$data" | jq -r ".$field // \"MISSING\"" 2>/dev/null)
        if [[ "$val" == "MISSING" ]]; then
            missing+="$field "
        fi
    done

    if [[ -z "$missing" ]]; then
        _pass "timer_data_fields"
    else
        _fail "timer_data_fields" "Missing fields: $missing"
    fi
}

test_binary_data_fields() {
    local result
    result=$(nftban_check_binary_integrity "/usr/bin/bash")
    local data
    data=$(echo "$result" | jq '.data' 2>/dev/null)

    local required_fields=("path" "exists" "is_elf" "status")
    local missing=""

    for field in "${required_fields[@]}"; do
        local val
        val=$(echo "$data" | jq -r ".$field // \"MISSING\"" 2>/dev/null)
        if [[ "$val" == "MISSING" ]]; then
            missing+="$field "
        fi
    done

    if [[ -z "$missing" ]]; then
        _pass "binary_data_fields"
    else
        _fail "binary_data_fields" "Missing fields: $missing"
    fi
}

# Run data field tests
test_suricata_data_fields
test_service_metrics_data_fields
test_timer_data_fields
test_binary_data_fields

echo ""

# =============================================================================
# TEST: Edge Cases
# =============================================================================

echo "--- Edge Case Tests ---"

test_nonexistent_service() {
    local result
    result=$(nftban_check_service_metrics "this-service-does-not-exist-12345.service")
    local exit_code=$?

    _log "Output: $result"

    # Should still return 0 (check executed) but with exists=false
    if [[ $exit_code -eq 0 ]]; then
        local exists
        exists=$(echo "$result" | jq -r '.data.exists' 2>/dev/null)
        if [[ "$exists" == "false" ]]; then
            _pass "nonexistent_service"
        else
            _fail "nonexistent_service" "exists should be false, got: $exists"
        fi
    else
        _fail "nonexistent_service" "Should return 0 even for nonexistent service"
    fi
}

test_nonexistent_binary() {
    local result
    result=$(nftban_check_binary_integrity "/this/path/does/not/exist/binary")
    local exit_code=$?

    _log "Output: $result"

    if [[ $exit_code -eq 0 ]]; then
        local exists status
        exists=$(echo "$result" | jq -r '.data.exists' 2>/dev/null)
        status=$(echo "$result" | jq -r '.data.status' 2>/dev/null)
        if [[ "$exists" == "false" && "$status" == "missing" ]]; then
            _pass "nonexistent_binary"
        else
            _fail "nonexistent_binary" "exists=$exists, status=$status"
        fi
    else
        _fail "nonexistent_binary" "Should return 0 for nonexistent file"
    fi
}

test_nonexistent_config() {
    local result
    result=$(nftban_check_config_exists "/etc/nftban/this-does-not-exist.conf")
    local exit_code=$?

    _log "Output: $result"

    if [[ $exit_code -eq 0 ]]; then
        local exists status
        exists=$(echo "$result" | jq -r '.data.exists' 2>/dev/null)
        status=$(echo "$result" | jq -r '.data.status' 2>/dev/null)
        if [[ "$exists" == "false" && "$status" == "missing" ]]; then
            _pass "nonexistent_config"
        else
            _fail "nonexistent_config" "exists=$exists, status=$status"
        fi
    else
        _fail "nonexistent_config" "Should return 0 for nonexistent file"
    fi
}

test_valid_binary_detection() {
    # /usr/bin/bash should be a valid ELF
    local result
    result=$(nftban_check_binary_integrity "/usr/bin/bash")
    local exit_code=$?

    _log "Output: $result"

    if [[ $exit_code -eq 0 ]]; then
        local is_elf status
        is_elf=$(echo "$result" | jq -r '.data.is_elf' 2>/dev/null)
        status=$(echo "$result" | jq -r '.data.status' 2>/dev/null)
        if [[ "$is_elf" == "true" && "$status" == "valid" ]]; then
            _pass "valid_binary_detection"
        else
            _fail "valid_binary_detection" "/usr/bin/bash should be ELF, got is_elf=$is_elf"
        fi
    else
        _fail "valid_binary_detection" "Check failed with exit code $exit_code"
    fi
}

test_text_file_not_elf() {
    # /etc/passwd should not be ELF
    local result
    result=$(nftban_check_binary_integrity "/etc/passwd")
    local exit_code=$?

    _log "Output: $result"

    if [[ $exit_code -eq 0 ]]; then
        local is_elf status
        is_elf=$(echo "$result" | jq -r '.data.is_elf' 2>/dev/null)
        status=$(echo "$result" | jq -r '.data.status' 2>/dev/null)
        if [[ "$is_elf" == "false" && "$status" == "corrupted" ]]; then
            _pass "text_file_not_elf"
        else
            _fail "text_file_not_elf" "/etc/passwd should not be ELF, got is_elf=$is_elf"
        fi
    else
        _fail "text_file_not_elf" "Check failed with exit code $exit_code"
    fi
}

# Run edge case tests
test_nonexistent_service
test_nonexistent_binary
test_nonexistent_config
test_valid_binary_detection
test_text_file_not_elf

echo ""

# =============================================================================
# TEST: Firewall Conflict Detection
# =============================================================================

echo "--- Firewall Conflict Tests ---"

test_firewall_conflict_fail2ban() {
    local result
    result=$(nftban_check_firewall_conflict "fail2ban")
    local exit_code=$?

    if [[ $exit_code -eq 0 ]]; then
        local issues
        if issues=$(_validate_json_contract "$result" "firewall_conflict"); then
            _pass "firewall_conflict_fail2ban"
        else
            _fail "firewall_conflict_fail2ban" "$issues"
        fi
    else
        _fail "firewall_conflict_fail2ban" "Exit code: $exit_code"
    fi
}

test_firewall_conflict_unknown() {
    local result
    result=$(nftban_check_firewall_conflict "unknown_firewall_xyz")
    local exit_code=$?

    # Should return non-zero for unknown firewall
    if [[ $exit_code -ne 0 ]]; then
        _pass "firewall_conflict_unknown"
    else
        _fail "firewall_conflict_unknown" "Should reject unknown firewall"
    fi
}

# Run firewall tests
test_firewall_conflict_fail2ban
test_firewall_conflict_unknown

echo ""

# =============================================================================
# SUMMARY
# =============================================================================

echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "  Results: $PASSED passed, $FAILED failed, $SKIPPED skipped"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo "  ✅ All tests passed!"
    echo ""
    exit 0
else
    echo "  ❌ Some tests failed"
    echo ""
    exit 1
fi
