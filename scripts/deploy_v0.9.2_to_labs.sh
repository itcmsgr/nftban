#!/usr/bin/env bash

# =============================================================================
# NFTBan v0.9.2 Lab Deployment & Testing Script
# =============================================================================
# This script deploys v0.9.2 to lab servers and tests all security fixes
#
# Security Fixes in v0.9.2:
#   - BUG47: Whitelist bypass via CIDR feeds (HIGH)
#   - BUG50: Race conditions in feed imports (HIGH)
#   - BUG51: Strict mode in all scripts (HIGH)
#   - BUG52: IPv6 port module selector (MEDIUM)
#   - BUG53: curl hardening (MEDIUM)
#
# Usage:
#   Run this script ON EACH LAB SERVER as root
#   sudo bash deploy_v0.9.2_to_labs.sh
# =============================================================================

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Trusted commit SHA for v0.9.2 (verify on GitHub before using!)
readonly TRUSTED_COMMIT_SHA="8ad1406a1c3fbbefdc114d2267ad0c8052a5a153"
readonly TARGET_VERSION="v0.9.2"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $*"
}

test_result() {
    local test_name="$1"
    local result="$2"  # 0 = pass, 1 = fail

    ((TESTS_TOTAL++))

    if [[ $result -eq 0 ]]; then
        echo -e "${GREEN}✓${NC} PASS: $test_name"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}✗${NC} FAIL: $test_name"
        ((TESTS_FAILED++))
    fi
}

# =============================================================================
# PRE-DEPLOYMENT CHECKS
# =============================================================================

pre_deployment_checks() {
    echo ""
    echo "========================================================================"
    echo "PRE-DEPLOYMENT CHECKS"
    echo "========================================================================"
    echo ""

    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root (use sudo)"
        exit 1
    fi
    log_success "Running as root"

    # Check if nftban is installed
    if [[ ! -f "/usr/local/bin/nftban" ]]; then
        log_error "nftban not found - is it installed?"
        exit 1
    fi
    log_success "nftban binary found"

    # Check current version
    local current_version
    if [[ -f "/usr/local/share/nftban/.version" ]]; then
        current_version=$(cat /usr/local/share/nftban/.version)
        log_info "Current version: $current_version"
    else
        current_version="unknown"
        log_warning "Version file not found"
    fi

    # Check network connectivity
    if ping -c 1 -W 2 8.8.8.8 &>/dev/null; then
        log_success "Network connectivity OK"
    else
        log_error "No network connectivity"
        exit 1
    fi

    # Check GitHub connectivity
    if curl -s --connect-timeout 5 https://github.com &>/dev/null; then
        log_success "GitHub connectivity OK"
    else
        log_error "Cannot reach GitHub"
        exit 1
    fi

    echo ""
    log_info "Hostname: $(hostname -f)"
    log_info "IP Address: $(hostname -I | awk '{print $1}')"
    log_info "Timestamp: $(date '+%Y-%m-%d %H:%M:%S')"
    echo ""
}

# =============================================================================
# DEPLOYMENT PHASE
# =============================================================================

deploy_update() {
    echo ""
    echo "========================================================================"
    echo "DEPLOYMENT PHASE - UPDATING TO v0.9.2"
    echo "========================================================================"
    echo ""

    # Step 1: Pin the trusted commit SHA
    log_info "Step 1/4: Setting commit pin..."
    log_info "Trusted commit: $TRUSTED_COMMIT_SHA"
    log_info "Verify on GitHub: https://github.com/itcmsgr/nftban/commit/$TRUSTED_COMMIT_SHA"
    echo ""
    read -p "Have you verified this commit on GitHub? [y/N] " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_error "Commit verification required - deployment aborted"
        exit 1
    fi

    # Set the pin
    if nftban update pin "$TRUSTED_COMMIT_SHA" --force; then
        log_success "Commit pin configured"
    else
        log_error "Failed to set commit pin"
        exit 1
    fi

    echo ""

    # Step 2: Check for updates
    log_info "Step 2/4: Checking for updates..."
    if nftban update check; then
        log_success "Update check completed"
    else
        log_warning "Update check completed with warnings (may already be latest)"
    fi

    echo ""

    # Step 3: Create backup
    log_info "Step 3/4: Creating backup before update..."
    if [[ -d "/usr/local/share/nftban" ]]; then
        local backup_dir="/root/nftban_backup_$(date +%Y%m%d_%H%M%S)"
        cp -a /usr/local/share/nftban "$backup_dir"
        log_success "Backup created: $backup_dir"
    fi

    echo ""

    # Step 4: Perform update
    log_info "Step 4/4: Performing update..."
    if nftban update perform --yes; then
        log_success "Update completed successfully"
    else
        log_error "Update failed - check logs"
        exit 1
    fi

    echo ""

    # Verify new version
    local new_version
    if [[ -f "/usr/local/share/nftban/.version" ]]; then
        new_version=$(cat /usr/local/share/nftban/.version)
        if [[ "$new_version" == "$TARGET_VERSION" ]]; then
            log_success "Version verified: $new_version"
        else
            log_error "Version mismatch: expected $TARGET_VERSION, got $new_version"
            exit 1
        fi
    fi

    echo ""
}

# =============================================================================
# TESTING PHASE
# =============================================================================

test_bug47_cidr_whitelist() {
    echo ""
    echo "------------------------------------------------------------------------"
    echo "TEST: BUG47 - CIDR-aware Whitelist Checking"
    echo "------------------------------------------------------------------------"
    echo ""

    log_info "Testing CIDR-aware whitelist functionality..."

    # This requires the feeds module to be properly configured
    # We'll test that the is_whitelisted function exists and has CIDR logic

    if grep -q "ip_in_cidr" /usr/local/share/nftban/lib/nftban_feeds_lib.sh 2>/dev/null; then
        test_result "BUG47: CIDR helper function exists" 0
    else
        test_result "BUG47: CIDR helper function exists" 1
    fi

    if grep -q "BUG47 FIX" /usr/local/share/nftban/lib/nftban_feeds_lib.sh 2>/dev/null; then
        test_result "BUG47: Fix marker present in code" 0
    else
        test_result "BUG47: Fix marker present in code" 1
    fi

    # Check for the enhanced is_whitelisted function
    if grep -A5 "is_whitelisted()" /usr/local/share/nftban/lib/nftban_feeds_lib.sh 2>/dev/null | grep -q "CIDR"; then
        test_result "BUG47: Enhanced is_whitelisted() function" 0
    else
        test_result "BUG47: Enhanced is_whitelisted() function" 1
    fi
}

test_bug50_race_conditions() {
    echo ""
    echo "------------------------------------------------------------------------"
    echo "TEST: BUG50 - Race Condition Prevention"
    echo "------------------------------------------------------------------------"
    echo ""

    log_info "Testing atomic feed imports and flock protection..."

    # Check for atomic import implementation
    if grep -q "BUG50 FIX.*atomic" /usr/local/share/nftban/lib/nftban_feeds_lib.sh 2>/dev/null; then
        test_result "BUG50: Atomic import implementation" 0
    else
        test_result "BUG50: Atomic import implementation" 1
    fi

    # Check for flock usage
    if grep -q "flock" /usr/local/share/nftban/lib/nftban_feeds_lib.sh 2>/dev/null; then
        test_result "BUG50: flock protection implemented" 0
    else
        test_result "BUG50: flock protection implemented" 1
    fi

    # Check for transaction file usage
    if grep -q "nft_txn_file" /usr/local/share/nftban/lib/nftban_feeds_lib.sh 2>/dev/null; then
        test_result "BUG50: Transaction file method" 0
    else
        test_result "BUG50: Transaction file method" 1
    fi
}

test_bug51_strict_mode() {
    echo ""
    echo "------------------------------------------------------------------------"
    echo "TEST: BUG51 - Strict Mode in All Scripts"
    echo "------------------------------------------------------------------------"
    echo ""

    log_info "Checking for strict mode in all shell scripts..."

    local missing_strict=0
    local total_checked=0

    for script in /usr/local/share/nftban/lib/*.sh; do
        [[ -f "$script" ]] || continue
        ((total_checked++))

        if ! grep -q "set -Eeuo pipefail" "$script" 2>/dev/null; then
            log_warning "Missing strict mode: $(basename "$script")"
            ((missing_strict++))
        fi
    done

    log_info "Checked $total_checked scripts, $missing_strict missing strict mode"

    if [[ $missing_strict -eq 0 ]]; then
        test_result "BUG51: All scripts have strict mode" 0
    else
        test_result "BUG51: All scripts have strict mode" 1
    fi
}

test_bug52_ipv6_selector() {
    echo ""
    echo "------------------------------------------------------------------------"
    echo "TEST: BUG52 - IPv6 Port Module Selector"
    echo "------------------------------------------------------------------------"
    echo ""

    log_info "Checking for correct IPv6 meta nfproto selector..."

    if grep -q "meta nfproto ipv6" /usr/local/share/nftban/lib/nftban_port_module.sh 2>/dev/null; then
        test_result "BUG52: Correct IPv6 selector (meta nfproto)" 0
    else
        test_result "BUG52: Correct IPv6 selector (meta nfproto)" 1
    fi

    # Check for the BUG52 fix marker
    if grep -q "BUG52 FIX" /usr/local/share/nftban/lib/nftban_port_module.sh 2>/dev/null; then
        test_result "BUG52: Fix marker present" 0
    else
        test_result "BUG52: Fix marker present" 1
    fi
}

test_bug53_curl_hardening() {
    echo ""
    echo "------------------------------------------------------------------------"
    echo "TEST: BUG53 - curl Hardening"
    echo "------------------------------------------------------------------------"
    echo ""

    log_info "Checking for safe_curl implementation..."

    # Check for safe_curl function
    if grep -q "safe_curl()" /usr/local/share/nftban/lib/nftban_utils_lib.sh 2>/dev/null; then
        test_result "BUG53: safe_curl() function exists" 0
    else
        test_result "BUG53: safe_curl() function exists" 1
    fi

    # Check for HTTPS-only enforcement
    if grep -A10 "safe_curl()" /usr/local/share/nftban/lib/nftban_utils_lib.sh 2>/dev/null | grep -q "proto.*https"; then
        test_result "BUG53: HTTPS-only enforcement" 0
    else
        test_result "BUG53: HTTPS-only enforcement" 1
    fi

    # Check for TLS version enforcement
    if grep -A10 "safe_curl()" /usr/local/share/nftban/lib/nftban_utils_lib.sh 2>/dev/null | grep -q "tlsv1.2"; then
        test_result "BUG53: TLS 1.2+ enforcement" 0
    else
        test_result "BUG53: TLS 1.2+ enforcement" 1
    fi

    # Check if feeds use safe_curl
    if grep -q "safe_curl" /usr/local/share/nftban/lib/nftban_feeds_lib.sh 2>/dev/null; then
        test_result "BUG53: Feeds module uses safe_curl" 0
    else
        test_result "BUG53: Feeds module uses safe_curl" 1
    fi
}

test_update_mechanism() {
    echo ""
    echo "------------------------------------------------------------------------"
    echo "TEST: Update Mechanism Security"
    echo "------------------------------------------------------------------------"
    echo ""

    log_info "Testing update mechanism security features..."

    # Check commit pinning
    if [[ -f "/etc/nftban/config/update-pins.conf" ]]; then
        test_result "Update: Commit pin file exists" 0

        local pinned_sha
        pinned_sha=$(grep -v "^#" /etc/nftban/config/update-pins.conf | grep -v "^$" | head -1 | tr -d '[:space:]')

        if [[ "$pinned_sha" == "$TRUSTED_COMMIT_SHA" ]]; then
            test_result "Update: Correct commit SHA pinned" 0
        else
            test_result "Update: Correct commit SHA pinned" 1
        fi
    else
        test_result "Update: Commit pin file exists" 1
    fi

    # Check update module has security features
    if grep -q "TOCTOU" /usr/local/share/nftban/lib/nftban_update_module.sh 2>/dev/null; then
        test_result "Update: TOCTOU mitigation documented" 0
    else
        test_result "Update: TOCTOU mitigation documented" 1
    fi

    if grep -q "_nftban_update_validate_path" /usr/local/share/nftban/lib/nftban_update_module.sh 2>/dev/null; then
        test_result "Update: Path validation function" 0
    else
        test_result "Update: Path validation function" 1
    fi

    if grep -q "_nftban_update_validate_url" /usr/local/share/nftban/lib/nftban_update_module.sh 2>/dev/null; then
        test_result "Update: URL validation function" 0
    else
        test_result "Update: URL validation function" 1
    fi
}

test_nftables_functionality() {
    echo ""
    echo "------------------------------------------------------------------------"
    echo "TEST: nftables Functionality"
    echo "------------------------------------------------------------------------"
    echo ""

    log_info "Testing nftables integration..."

    # Check if nftables is running
    if systemctl is-active nftables &>/dev/null || command -v nft &>/dev/null; then
        test_result "nftables: Service available" 0
    else
        test_result "nftables: Service available" 1
    fi

    # Check if nftban tables exist
    if nft list tables 2>/dev/null | grep -q "nftban"; then
        test_result "nftables: nftban tables exist" 0
    else
        test_result "nftables: nftban tables exist" 1
    fi

    # Check whitelist set exists
    if nft list sets 2>/dev/null | grep -q "whitelist"; then
        test_result "nftables: whitelist set exists" 0
    else
        test_result "nftables: whitelist set exists" 1
    fi
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================

main() {
    echo ""
    echo "========================================================================"
    echo "NFTBan v0.9.2 - Lab Deployment & Testing"
    echo "========================================================================"
    echo ""
    echo "This script will:"
    echo "  1. Verify pre-deployment requirements"
    echo "  2. Deploy nftban v0.9.2 with commit pinning"
    echo "  3. Test all security fixes (BUG47, 50, 51, 52, 53)"
    echo "  4. Verify update mechanism security"
    echo "  5. Test nftables functionality"
    echo ""
    read -p "Continue with deployment? [y/N] " -n 1 -r
    echo ""

    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "Deployment cancelled by user"
        exit 0
    fi

    # Execute deployment phases
    pre_deployment_checks
    deploy_update

    echo ""
    echo "========================================================================"
    echo "TESTING PHASE - VERIFYING ALL SECURITY FIXES"
    echo "========================================================================"

    # Run all tests
    test_bug47_cidr_whitelist
    test_bug50_race_conditions
    test_bug51_strict_mode
    test_bug52_ipv6_selector
    test_bug53_curl_hardening
    test_update_mechanism
    test_nftables_functionality

    # Print summary
    echo ""
    echo "========================================================================"
    echo "TEST SUMMARY"
    echo "========================================================================"
    echo ""
    echo "Total Tests: $TESTS_TOTAL"
    echo -e "Passed:      ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed:      ${RED}$TESTS_FAILED${NC}"
    echo ""

    if [[ $TESTS_FAILED -eq 0 ]]; then
        log_success "========================================================"
        log_success "  ALL TESTS PASSED - DEPLOYMENT SUCCESSFUL"
        log_success "  nftban v0.9.2 is now running on this server"
        log_success "========================================================"
        echo ""
        return 0
    else
        log_error "========================================================"
        log_error "  SOME TESTS FAILED - REVIEW REQUIRED"
        log_error "  $TESTS_FAILED out of $TESTS_TOTAL tests failed"
        log_error "========================================================"
        echo ""
        return 1
    fi
}

# Run main function
main "$@"
