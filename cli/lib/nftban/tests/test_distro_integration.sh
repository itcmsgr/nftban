#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
# =============================================================================
# NFTBan - Distro Config Integration Test
# =============================================================================
# meta:name="test_distro_integration"
# meta:type="test"
# meta:version="1.39.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Test parser module with distribution configs"
# meta:inventory.files=""
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_DISTRO_CONF_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Purpose: Test parser module with distribution configs
# Usage: ./test_distro_integration.sh [parser_path] [config_dir]
#
# Tests:
# - Parser loading
# - Config file detection
# - Package name lookups
# - Service name lookups
# - Path lookups
# - Function execution
# =============================================================================

set -Eeuo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
# v1.230.0 PR-5a-2 (TEST-SUBJECT-REACHABILITY instance): the defaults were
# ../track1/nftban_distro_config.sh and ../track2 -- a repository layout that no
# longer exists, so every run tested NOTHING and reported "Parser file not found".
# Resolved with the same seam already applied to test_distro_config.sh:225,
# anchored on BASH_SOURCE rather than on the caller's working directory.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSER_PATH="${1:-$SCRIPT_DIR/../lib/nftban_distro_config.sh}"
# Fixture dir: repo checkout first, installed tree second. No production hook is
# introduced -- both are real locations the parser already uses.
if [[ -n "${2:-}" ]]; then
    CONFIG_DIR="$2"
elif [[ -d "$SCRIPT_DIR/../../../../etc/nftban/distros" ]]; then
    CONFIG_DIR="$(cd "$SCRIPT_DIR/../../../../etc/nftban/distros" && pwd)"
else
    CONFIG_DIR="/etc/nftban/distros"
fi

# PRECONDITION ASSERTED BEFORE ANY CAPABILITY TEST. A missing subject or fixture is
# a FAILED RUN, never a quiet skip: a test that cannot reach its subject must not
# be able to report success.
if [[ ! -f "$PARSER_PATH" ]]; then
    echo "FAIL: parser subject not reachable: $PARSER_PATH" >&2
    exit 1
fi
if [[ ! -d "$CONFIG_DIR" ]] || [[ -z "$(find "$CONFIG_DIR" -name '*.conf' -type f -print -quit 2>/dev/null)" ]]; then
    echo "FAIL: distro fixture population is empty or absent: $CONFIG_DIR" >&2
    exit 1
fi
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# =============================================================================
# TEST FRAMEWORK
# =============================================================================

print_header() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  NFTBan Distro Config Integration Tests"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
}

print_summary() {
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "  Test Results"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo -e "${GREEN}✓ Passed: ${TESTS_PASSED}${NC}"
    echo -e "${RED}✗ Failed: ${TESTS_FAILED}${NC}"
    echo -e "${YELLOW}⊘ Skipped: ${TESTS_SKIPPED}${NC}"
    echo ""

    local total=$((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))
    local pass_rate=0
    if [[ $total -gt 0 ]]; then
        pass_rate=$((TESTS_PASSED * 100 / total))
    fi

    echo "Pass rate: ${pass_rate}%"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "${GREEN}All tests passed!${NC}"
        return 0
    else
        echo -e "${RED}${TESTS_FAILED} test(s) failed${NC}"
        return 1
    fi
}

test_assert_equal() {
    local expected="$1"
    local actual="$2"
    local test_name="$3"

    if [[ "$expected" == "$actual" ]]; then
        echo -e "${GREEN}  ✓ $test_name${NC}"
        # v1.19.20 FIX
        ((TESTS_PASSED++)) || true
        return 0
    else
        echo -e "${RED}  ✗ $test_name${NC}"
        echo -e "${RED}    Expected: '$expected'${NC}"
        echo -e "${RED}    Got:      '$actual'${NC}"
        # v1.19.20 FIX
        ((TESTS_FAILED++)) || true
        return 1
    fi
}

test_assert_not_empty() {
    local value="$1"
    local test_name="$2"

    if [[ -n "$value" ]]; then
        echo -e "${GREEN}  ✓ $test_name${NC}"
        # v1.19.20 FIX
        ((TESTS_PASSED++)) || true
        return 0
    else
        echo -e "${RED}  ✗ $test_name (value is empty)${NC}"
        # v1.19.20 FIX
        ((TESTS_FAILED++)) || true
        return 1
    fi
}

test_assert_function_exists() {
    local func_name="$1"

    if declare -F "$func_name" &>/dev/null; then
        echo -e "${GREEN}  ✓ Function $func_name exists${NC}"
        # v1.19.20 FIX
        ((TESTS_PASSED++)) || true
        return 0
    else
        echo -e "${RED}  ✗ Function $func_name not found${NC}"
        # v1.19.20 FIX
        ((TESTS_FAILED++)) || true
        return 1
    fi
}

# =============================================================================
# INTEGRATION TESTS
# =============================================================================

test_parser_loading() {
    echo ""
    echo -e "${BLUE}Test Suite: Parser Loading${NC}"
    echo "───────────────────────────────────────────────────────────"

    # Test 1: Parser file exists
    if [[ -f "$PARSER_PATH" ]]; then
        echo -e "${GREEN}  ✓ Parser file exists${NC}"
        # v1.19.20 FIX
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}  ✗ Parser file not found: $PARSER_PATH${NC}"
        # v1.19.20 FIX
        ((TESTS_FAILED++)) || true
        return 1
    fi

    # Test 2: Parser can be sourced
    # shellcheck source=/dev/null
    if source "$PARSER_PATH" 2>/dev/null; then
        echo -e "${GREEN}  ✓ Parser loads without errors${NC}"
        # v1.19.20 FIX
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}  ✗ Parser failed to load${NC}"
        # v1.19.20 FIX
        ((TESTS_FAILED++)) || true
        return 1
    fi

    # Test 3: Required functions exist
    test_assert_function_exists "nftban_distro_detect"
    test_assert_function_exists "nftban_distro_find_config"
    test_assert_function_exists "nftban_distro_parse_config"
    test_assert_function_exists "nftban_distro_get_package"
    test_assert_function_exists "nftban_distro_get_service"
    test_assert_function_exists "nftban_distro_get_path"
    test_assert_function_exists "nftban_distro_install_packages"
    test_assert_function_exists "nftban_distro_restart_service"
    test_assert_function_exists "nftban_distro_is_package_installed"
}

test_config_detection() {
    echo ""
    echo -e "${BLUE}Test Suite: Config File Detection${NC}"
    echo "───────────────────────────────────────────────────────────"

    # Override config dir for testing
    # v1.230.0 PR-5a-2: this exported NFTBAN_DISTRO_CONFIG_DIR, which has exactly ONE
    # occurrence in the whole tree -- this line. The parser reads NFTBAN_DISTRO_CONF_DIR
    # (nftban_distro_config.sh:20), so the test steered nothing and the parser silently
    # used /etc/nftban/distros. GUARD SUBJECT MUST EQUAL GUARD INPUT.
    export NFTBAN_DISTRO_CONF_DIR="$CONFIG_DIR"

    # v1.230.0 PR-5a-2: this exported MOCK_OS_ID/MOCK_OS_VERSION_ID and then called
    # nftban_distro_find_config with NO ARGUMENTS. Neither worked:
    #   - the parser never reads MOCK_OS_* (zero occurrences in nftban_distro_config.sh),
    #     so the "centos 9" scenario was never actually selected;
    #   - find_config REQUIRES a detection string (nftban_distro_config.sh:79-81,
    #     `local detection="$1"`), so under `set -u` the bare call died with
    #     "$1: unbound variable" and errexit aborted the whole run at this line.
    # Fixed by using the DOCUMENTED interface, exactly as the production caller does
    # at nftban_distro_config.sh:216 -- no test hook is added to production code.
    local detection="centos:9"

    local config_file
    config_file=$(nftban_distro_find_config "$detection" 2>/dev/null) || config_file=""

    if [[ -n "$config_file" ]]; then
        echo -e "${GREEN}  ✓ Config file detected: $(basename "$config_file")${NC}"
        # v1.19.20 FIX
        ((TESTS_PASSED++)) || true
    else
        echo -e "${YELLOW}  ⊘ No config file found (expected if not on test system)${NC}"
        # v1.19.20 FIX
        ((TESTS_SKIPPED++)) || true
    fi
}

test_config_parsing() {
    echo ""
    echo -e "${BLUE}Test Suite: Config Parsing${NC}"
    echo "───────────────────────────────────────────────────────────"

    # Find a config file to test with
    local test_config
    test_config=$(find "$CONFIG_DIR" -name "*.conf" -type f | head -1)

    if [[ -z "$test_config" ]]; then
        echo -e "${YELLOW}  ⊘ No config files found for testing${NC}"
        # v1.19.20 FIX
        ((TESTS_SKIPPED++)) || true
        return 0
    fi

    echo "  Using: $(basename "$test_config")"

    # Parse the config
    if nftban_distro_parse_config "$test_config" 2>/dev/null; then
        echo -e "${GREEN}  ✓ Config parsed successfully${NC}"
        # v1.19.20 FIX
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}  ✗ Config parsing failed${NC}"
        # v1.19.20 FIX
        ((TESTS_FAILED++)) || true
        return 1
    fi

    # Verify data was loaded
    if [[ ${#DISTRO_INFO[@]} -gt 0 ]]; then
        echo -e "${GREEN}  ✓ DISTRO_INFO populated (${#DISTRO_INFO[@]} entries)${NC}"
        # v1.19.20 FIX
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}  ✗ DISTRO_INFO is empty${NC}"
        # v1.19.20 FIX
        ((TESTS_FAILED++)) || true
    fi

    if [[ ${#DISTRO_PACKAGES[@]} -gt 0 ]]; then
        echo -e "${GREEN}  ✓ DISTRO_PACKAGES populated (${#DISTRO_PACKAGES[@]} entries)${NC}"
        # v1.19.20 FIX
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}  ✗ DISTRO_PACKAGES is empty${NC}"
        # v1.19.20 FIX
        ((TESTS_FAILED++)) || true
    fi

    if [[ ${#DISTRO_SERVICES[@]} -gt 0 ]]; then
        echo -e "${GREEN}  ✓ DISTRO_SERVICES populated (${#DISTRO_SERVICES[@]} entries)${NC}"
        # v1.19.20 FIX
        ((TESTS_PASSED++)) || true
    else
        echo -e "${RED}  ✗ DISTRO_SERVICES is empty${NC}"
        # v1.19.20 FIX
        ((TESTS_FAILED++)) || true
    fi
}

test_package_lookups() {
    echo ""
    echo -e "${BLUE}Test Suite: Package Name Lookups${NC}"
    echo "───────────────────────────────────────────────────────────"

    # Find and parse a config
    local test_config
    test_config=$(find "$CONFIG_DIR" -name "*.conf" -type f | head -1)

    if [[ -z "$test_config" ]]; then
        echo -e "${YELLOW}  ⊘ No config files found${NC}"
        # v1.19.20 FIX
        ((TESTS_SKIPPED++)) || true
        return 0
    fi

    nftban_distro_parse_config "$test_config" 2>/dev/null || true

    # Test common packages
    local pkg
    # v2.1: fail2ban removed - use native login monitoring
    for pkg in nftables curl bash systemd mail golang; do
        local result
        result=$(nftban_distro_get_package "$pkg" 2>/dev/null || echo "")
        test_assert_not_empty "$result" "Package lookup: $pkg"
    done
}

test_service_lookups() {
    echo ""
    echo -e "${BLUE}Test Suite: Service Name Lookups${NC}"
    echo "───────────────────────────────────────────────────────────"

    # Find and parse a config
    local test_config
    test_config=$(find "$CONFIG_DIR" -name "*.conf" -type f | head -1)

    if [[ -z "$test_config" ]]; then
        echo -e "${YELLOW}  ⊘ No config files found${NC}"
        # v1.19.20 FIX
        ((TESTS_SKIPPED++)) || true
        return 0
    fi

    nftban_distro_parse_config "$test_config" 2>/dev/null || true

    # Test common services
    local svc
    # v2.1: fail2ban removed - use native login monitoring
    for svc in cron rsyslog nftables sshd; do
        local result
        result=$(nftban_distro_get_service "$svc" 2>/dev/null || echo "")
        test_assert_not_empty "$result" "Service lookup: $svc"
    done
}

test_path_lookups() {
    echo ""
    echo -e "${BLUE}Test Suite: Path Lookups${NC}"
    echo "───────────────────────────────────────────────────────────"

    # Find and parse a config
    local test_config
    test_config=$(find "$CONFIG_DIR" -name "*.conf" -type f | head -1)

    if [[ -z "$test_config" ]]; then
        echo -e "${YELLOW}  ⊘ No config files found${NC}"
        # v1.19.20 FIX
        ((TESTS_SKIPPED++)) || true
        return 0
    fi

    nftban_distro_parse_config "$test_config" 2>/dev/null || true

    # Test common paths
    local path_key
    for path_key in nft systemctl journalctl; do
        local result
        result=$(nftban_distro_get_path "$path_key" 2>/dev/null || echo "")
        test_assert_not_empty "$result" "Path lookup: $path_key"
    done
}

test_all_configs() {
    echo ""
    echo -e "${BLUE}Test Suite: All Config Files${NC}"
    echo "───────────────────────────────────────────────────────────"

    local config_files=()
    while IFS= read -r -d '' file; do
        config_files+=("$file")
    done < <(find "$CONFIG_DIR" -name "*.conf" -type f -print0 2>/dev/null)

    if [[ ${#config_files[@]} -eq 0 ]]; then
        echo -e "${YELLOW}  ⊘ No config files found${NC}"
        # v1.19.20 FIX
        ((TESTS_SKIPPED++)) || true
        return 0
    fi

    echo "  Testing ${#config_files[@]} config file(s)"
    echo ""

    for config in "${config_files[@]}"; do
        local filename
        filename=$(basename "$config")
        if nftban_distro_parse_config "$config" 2>/dev/null; then
            echo -e "${GREEN}  ✓ $filename parses successfully${NC}"
            # v1.19.20 FIX
            ((TESTS_PASSED++)) || true
        else
            echo -e "${RED}  ✗ $filename failed to parse${NC}"
            # v1.19.20 FIX
            ((TESTS_FAILED++)) || true
        fi
    done
}

# =============================================================================
# MAIN
# =============================================================================

print_header

echo "Parser: $PARSER_PATH"
echo "Config Dir: $CONFIG_DIR"

# Run test suites
test_parser_loading
test_config_detection
test_config_parsing
test_package_lookups
test_service_lookups
test_path_lookups
test_all_configs

# Print summary
print_summary
