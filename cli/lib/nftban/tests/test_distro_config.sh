#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Distribution Configuration Parser Test Suite
# =============================================================================
# meta:name="test_distro_config"
# meta:type="test"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Test all functions of nftban_distro_config.sh"
# meta:inventory.files=""
# meta:inventory.binaries="bash"
# meta:inventory.env_vars="NFTBAN_DISTRO_AUTO_INIT,NFTBAN_DEBUG_MODE,NFTBAN_DISTRO_CONF_DIR"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Usage: ./test_distro_config.sh
# =============================================================================

set -Eeuo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
# shellcheck disable=SC2034  # Reserved for warning messages
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# =============================================================================
# TEST FRAMEWORK
# =============================================================================

test_start() {
    local test_name="$1"
    # v1.19.20 FIX
    ((TESTS_RUN++)) || true
    echo -e "${BLUE}[TEST $TESTS_RUN]${NC} $test_name"
}

test_pass() {
    # v1.19.20 FIX
    ((TESTS_PASSED++)) || true
    echo -e "${GREEN}  ✓ PASS${NC}"
    echo ""
}

test_fail() {
    local reason="$1"
    # v1.19.20 FIX
    ((TESTS_FAILED++)) || true
    echo -e "${RED}  ✗ FAIL${NC}: $reason"
    echo ""
}

assert_equals() {
    local expected="$1"
    local actual="$2"
    local description="$3"

    if [[ "$expected" == "$actual" ]]; then
        echo -e "  ${GREEN}✓${NC} $description"
        echo "    Expected: $expected"
        echo "    Got: $actual"
        return 0
    else
        echo -e "  ${RED}✗${NC} $description"
        echo "    Expected: $expected"
        echo "    Got: $actual"
        return 1
    fi
}

assert_not_empty() {
    local value="$1"
    local description="$2"

    if [[ -n "$value" ]]; then
        echo -e "  ${GREEN}✓${NC} $description"
        echo "    Value: $value"
        return 0
    else
        echo -e "  ${RED}✗${NC} $description"
        echo "    Value is empty"
        return 1
    fi
}

# =============================================================================
# SETUP
# =============================================================================

echo "═══════════════════════════════════════════════════════════"
echo "  NFTBan Distribution Configuration Parser - Test Suite"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Create temporary test directory
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

echo "Test directory: $TEST_DIR"
echo "Script directory: $SCRIPT_DIR"
echo ""

# Create test config directory
mkdir -p "$TEST_DIR/distros"

# =============================================================================
# CREATE TEST CONFIGURATION FILES
# =============================================================================

echo "Creating test configuration files..."

# Test config for CentOS
cat > "$TEST_DIR/distros/centos-9.conf" << 'EOF'
# Test configuration for CentOS Stream 9

[distro]
id = centos
name = CentOS Stream
version = 9
family = rhel

[package_manager]
type = dnf
install_cmd = dnf install -y
update_cmd = dnf update -y

[packages]
golang = golang
mail = s-nail
nftables = nftables
curl = curl

[services]
cron = crond
nftables = nftables
rsyslog = rsyslog

[paths]
nft = /usr/sbin/nft
systemctl = /usr/bin/systemctl

[repository]
epel_required = true
epel_package = epel-release

[features]
systemd_support = true
firewalld_default = true
EOF

# Test config for Debian
cat > "$TEST_DIR/distros/debian-12.conf" << 'EOF'
# Test configuration for Debian 12

[distro]
id = debian
name = Debian
version = 12
family = debian

[package_manager]
type = apt
install_cmd = apt-get install -y
update_cmd = apt-get update

[packages]
golang = golang-go
mail = mailutils
nftables = nftables
curl = curl

[services]
cron = cron
nftables = nftables
rsyslog = rsyslog

[paths]
nft = /usr/sbin/nft
systemctl = /bin/systemctl

[repository]
epel_required = false
epel_package =

[features]
systemd_support = true
firewalld_default = false
EOF

echo "✓ Test configs created"
echo ""

# =============================================================================
# LOAD MODULE
# =============================================================================

echo "Loading nftban_distro_config.sh module..."

# Disable auto-init for testing
export NFTBAN_DISTRO_AUTO_INIT=false
export NFTBAN_DEBUG_MODE=false
export NFTBAN_DISTRO_CONF_DIR="$TEST_DIR/distros"

# Source the module
# shellcheck source=/dev/null
source "$SCRIPT_DIR/nftban_distro_config.sh" || {
    echo -e "${RED}FATAL: Failed to load module${NC}"
    exit 1
}

echo "✓ Module loaded successfully"
echo ""

# =============================================================================
# TEST 1: Distribution Detection
# =============================================================================

test_start "Distribution Detection"

if detection=$(nftban_distro_detect); then
    assert_not_empty "$detection" "Detection returns value" && \
    echo "  Detected: $detection" && \
    test_pass
else
    test_fail "nftban_distro_detect failed"
fi

# =============================================================================
# TEST 2: Config File Discovery
# =============================================================================

test_start "Config File Discovery - CentOS"

# Mock CentOS detection
detection="centos:9"

if config_file=$(nftban_distro_find_config "$detection"); then
    assert_equals "$TEST_DIR/distros/centos-9.conf" "$config_file" "Found correct config file" && \
    test_pass
else
    test_fail "Failed to find CentOS config"
fi

# =============================================================================
# TEST 3: Config File Discovery - Debian
# =============================================================================

test_start "Config File Discovery - Debian"

detection="debian:12"

if config_file=$(nftban_distro_find_config "$detection"); then
    assert_equals "$TEST_DIR/distros/debian-12.conf" "$config_file" "Found correct config file" && \
    test_pass
else
    test_fail "Failed to find Debian config"
fi

# =============================================================================
# TEST 4: INI Parsing - CentOS
# =============================================================================

test_start "INI Config Parsing - CentOS"

config_file="$TEST_DIR/distros/centos-9.conf"

if nftban_distro_parse_config "$config_file"; then
    assert_equals "centos" "${DISTRO_INFO[id]}" "Parsed distro.id" && \
    assert_equals "dnf" "${DISTRO_PKGMGR[type]}" "Parsed package_manager.type" && \
    assert_equals "golang" "${DISTRO_PACKAGES[golang]}" "Parsed packages.golang" && \
    assert_equals "crond" "${DISTRO_SERVICES[cron]}" "Parsed services.cron" && \
    assert_equals "/usr/sbin/nft" "${DISTRO_PATHS[nft]}" "Parsed paths.nft" && \
    assert_equals "true" "${DISTRO_REPOSITORY[epel_required]}" "Parsed repository.epel_required" && \
    assert_equals "true" "${DISTRO_FEATURES[systemd_support]}" "Parsed features.systemd_support" && \
    test_pass
else
    test_fail "Failed to parse CentOS config"
fi

# =============================================================================
# TEST 5: INI Parsing - Debian
# =============================================================================

test_start "INI Config Parsing - Debian"

# Clear arrays first
unset DISTRO_INFO DISTRO_PKGMGR DISTRO_PACKAGES DISTRO_SERVICES DISTRO_PATHS DISTRO_REPOSITORY DISTRO_FEATURES
declare -gA DISTRO_INFO DISTRO_PKGMGR DISTRO_PACKAGES DISTRO_SERVICES DISTRO_PATHS DISTRO_REPOSITORY DISTRO_FEATURES

config_file="$TEST_DIR/distros/debian-12.conf"

if nftban_distro_parse_config "$config_file"; then
    assert_equals "debian" "${DISTRO_INFO[id]}" "Parsed distro.id" && \
    assert_equals "apt" "${DISTRO_PKGMGR[type]}" "Parsed package_manager.type" && \
    assert_equals "golang-go" "${DISTRO_PACKAGES[golang]}" "Parsed packages.golang (debian variant)" && \
    assert_equals "cron" "${DISTRO_SERVICES[cron]}" "Parsed services.cron (debian variant)" && \
    assert_equals "/bin/systemctl" "${DISTRO_PATHS[systemctl]}" "Parsed paths.systemctl" && \
    assert_equals "false" "${DISTRO_REPOSITORY[epel_required]}" "Parsed repository.epel_required" && \
    test_pass
else
    test_fail "Failed to parse Debian config"
fi

# =============================================================================
# TEST 6: Full Initialization
# =============================================================================

test_start "Full Module Initialization"

# Clear arrays
unset DISTRO_INFO DISTRO_PKGMGR DISTRO_PACKAGES DISTRO_SERVICES DISTRO_PATHS DISTRO_REPOSITORY DISTRO_FEATURES
declare -gA DISTRO_INFO DISTRO_PKGMGR DISTRO_PACKAGES DISTRO_SERVICES DISTRO_PATHS DISTRO_REPOSITORY DISTRO_FEATURES

if nftban_distro_init; then
    assert_not_empty "${DISTRO_INFO[id]:-}" "Distro ID populated" && \
    assert_not_empty "${DISTRO_PKGMGR[type]:-}" "Package manager type populated" && \
    test_pass
else
    test_fail "Initialization failed"
fi

# =============================================================================
# TEST 7: Helper Function - Get Package
# =============================================================================

test_start "Helper Function - Get Package Name"

# Re-init with CentOS config
unset DISTRO_INFO DISTRO_PKGMGR DISTRO_PACKAGES DISTRO_SERVICES DISTRO_PATHS DISTRO_REPOSITORY DISTRO_FEATURES
declare -gA DISTRO_INFO DISTRO_PKGMGR DISTRO_PACKAGES DISTRO_SERVICES DISTRO_PATHS DISTRO_REPOSITORY DISTRO_FEATURES
nftban_distro_parse_config "$TEST_DIR/distros/centos-9.conf"

if pkg=$(nftban_distro_get_package "golang"); then
    assert_equals "golang" "$pkg" "Got correct package name for CentOS" && \
    test_pass
else
    test_fail "Failed to get package name"
fi

# =============================================================================
# TEST 8: Helper Function - Get Service
# =============================================================================

test_start "Helper Function - Get Service Name"

if svc=$(nftban_distro_get_service "cron"); then
    assert_equals "crond" "$svc" "Got correct service name for CentOS (crond)" && \
    test_pass
else
    test_fail "Failed to get service name"
fi

# =============================================================================
# TEST 9: Helper Function - Get Path
# =============================================================================

test_start "Helper Function - Get Binary Path"

if path=$(nftban_distro_get_path "nft"); then
    assert_equals "/usr/sbin/nft" "$path" "Got correct binary path" && \
    test_pass
else
    test_fail "Failed to get binary path"
fi

# =============================================================================
# TEST 10: Helper Function - Get Package Manager Command
# =============================================================================

test_start "Helper Function - Get Package Manager Command"

if result=$(nftban_distro_get_pkgmgr_cmd "install_cmd"); then
    assert_equals "dnf install -y" "$result" "Got correct install command" && \
    test_pass
else
    test_fail "Failed to get package manager command"
fi

# =============================================================================
# TEST 11: Show Config Function
# =============================================================================

test_start "Diagnostic - Show Config"

if output=$(nftban_distro_show_config); then
    assert_not_empty "$output" "Show config returns output" && \
    echo "  Config output length: ${#output} bytes" && \
    test_pass
else
    test_fail "Show config failed"
fi

# =============================================================================
# TEST 12: Invalid Config Handling
# =============================================================================

test_start "Error Handling - Non-existent Config"

detection="invalid:99"

if nftban_distro_find_config "$detection" 2>/dev/null; then
    test_fail "Should have failed for invalid distro"
else
    echo -e "  ${GREEN}✓${NC} Correctly failed for non-existent config"
    test_pass
fi

# =============================================================================
# TEST 13: Comments and Empty Lines
# =============================================================================

test_start "INI Parser - Comments and Empty Lines"

# Create config with comments and empty lines
cat > "$TEST_DIR/distros/test-comments.conf" << 'EOF'
# This is a comment

[distro]
# Another comment
id = test

# Empty line above

[packages]
test_package = test-pkg  # inline comment

EOF

# Clear arrays
unset DISTRO_INFO DISTRO_PKGMGR DISTRO_PACKAGES DISTRO_SERVICES DISTRO_PATHS DISTRO_REPOSITORY DISTRO_FEATURES
declare -gA DISTRO_INFO DISTRO_PKGMGR DISTRO_PACKAGES DISTRO_SERVICES DISTRO_PATHS DISTRO_REPOSITORY DISTRO_FEATURES

if nftban_distro_parse_config "$TEST_DIR/distros/test-comments.conf"; then
    assert_equals "test" "${DISTRO_INFO[id]}" "Parsed with comments present" && \
    assert_equals "test-pkg" "${DISTRO_PACKAGES[test_package]}" "Handled inline comment" && \
    test_pass
else
    test_fail "Failed to parse config with comments"
fi

# =============================================================================
# TEST SUMMARY
# =============================================================================

echo "═══════════════════════════════════════════════════════════"
echo "  Test Summary"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Tests Run:    $TESTS_RUN"
echo -e "Tests Passed: ${GREEN}$TESTS_PASSED${NC}"
echo -e "Tests Failed: ${RED}$TESTS_FAILED${NC}"
echo ""

if [[ $TESTS_FAILED -eq 0 ]]; then
    echo -e "${GREEN}✓ ALL TESTS PASSED${NC}"
    echo ""
    exit 0
else
    echo -e "${RED}✗ SOME TESTS FAILED${NC}"
    echo ""
    exit 1
fi
