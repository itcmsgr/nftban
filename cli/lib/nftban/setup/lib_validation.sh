#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# meta:name="lib_validation"
# meta:type="setup"
# meta:version="1.54.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Shared validation utilities for setup validation scripts"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""

# Strict mode (required by NFTBan coding standards)
set -Eeuo pipefail

# Guard against double-loading
[[ -n "${_LIB_VALIDATION_LOADED:-}" ]] && return 0
readonly _LIB_VALIDATION_LOADED=1

# =============================================================================
# SHARED COLORS
# =============================================================================

readonly _VAL_RED='\033[0;31m'
readonly _VAL_GREEN='\033[0;32m'
readonly _VAL_YELLOW='\033[0;33m'
readonly _VAL_BLUE='\033[0;34m'
readonly _VAL_NC='\033[0m'

# =============================================================================
# SHARED TEST COUNTERS
# =============================================================================

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
WARNING_TESTS=0

# =============================================================================
# SHARED FUNCTIONS
# =============================================================================

# Print colored message
print_color() {
    local color="$1"
    shift
    echo -e "${color}$*${_VAL_NC}"
}

# Print test header
test_header() {
    echo ""
    print_color "$_VAL_BLUE" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    print_color "$_VAL_BLUE" "TEST: $*"
    print_color "$_VAL_BLUE" "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Print test result
test_result() {
    local status="$1"
    local message="$2"

    TOTAL_TESTS=$((TOTAL_TESTS + 1))

    case "$status" in
        PASS)
            print_color "$_VAL_GREEN" "✓ PASS: $message"
            PASSED_TESTS=$((PASSED_TESTS + 1))
            ;;
        FAIL)
            print_color "$_VAL_RED" "✗ FAIL: $message"
            FAILED_TESTS=$((FAILED_TESTS + 1))
            ;;
        WARN)
            print_color "$_VAL_YELLOW" "⚠ WARN: $message"
            WARNING_TESTS=$((WARNING_TESTS + 1))
            ;;
    esac
}
