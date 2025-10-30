#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - Deploy First Module to Lab for Testing
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Deploy banner module to lab servers for shellcheck and testing
#
# meta:name=deploy_test_to_lab
# meta:type=tool
# meta:header=Lab Deployment & Test Script
# meta:version=1.0.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Deploys first module to lab servers, runs shellcheck, and executes tests
# meta:input=No arguments required
# meta:output=Test results from all lab servers
#
# **Inventory & Requirements**
# meta:depends=ssh,scp,rsync
#
# meta:created_date=2025-10-26

set -Eeuo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

LAB_SERVERS=(
    "lab.mywebhost.gr"
    "lab1.mywebhost.gr"
    "lab2.mywebhost.gr"
)

LAB_USER="root"
LAB_TEST_DIR="/tmp/nftban-v0.10.0-test"

LOCAL_SRC_DIR="/home/gituser/nftban-v0.10.0-dev/src"
LOCAL_TEST_SCRIPT="/home/gituser/nftban-v0.10.0-dev/test-banner.sh"

# Colors
COLOR_GREEN='\033[32m'
COLOR_YELLOW='\033[33m'
COLOR_RED='\033[31m'
COLOR_CYAN='\033[36m'
COLOR_RESET='\033[0m'

# =============================================================================
# FUNCTIONS
# =============================================================================

log_info() {
    echo -e "${COLOR_CYAN}[INFO]${COLOR_RESET} $*"
}

log_success() {
    echo -e "${COLOR_GREEN}[SUCCESS]${COLOR_RESET} $*"
}

log_warning() {
    echo -e "${COLOR_YELLOW}[WARNING]${COLOR_RESET} $*"
}

log_error() {
    echo -e "${COLOR_RED}[ERROR]${COLOR_RESET} $*"
}

# =============================================================================
# MAIN DEPLOYMENT
# =============================================================================

echo "============================================================================="
echo "NFTBan v0.10.0 - First Module Lab Deployment & Test"
echo "============================================================================="
echo ""

log_info "Deploying to ${#LAB_SERVERS[@]} lab servers..."
echo ""

for server in "${LAB_SERVERS[@]}"; do
    echo "-----------------------------------------------------------------------------"
    log_info "Server: $server"
    echo "-----------------------------------------------------------------------------"

    # Check connectivity
    if ! ssh -o ConnectTimeout=5 "${LAB_USER}@${server}" "echo 'Connected'" &>/dev/null; then
        log_error "Cannot connect to $server - skipping"
        echo ""
        continue
    fi
    log_success "Connected to $server"

    # Create test directory
    log_info "Creating test directory..."
    ssh "${LAB_USER}@${server}" "mkdir -p ${LAB_TEST_DIR}/{etc/nftban/conf.d,usr/lib/nftban/core}"

    # Deploy files
    log_info "Deploying banner.conf..."
    scp -q "${LOCAL_SRC_DIR}/etc/nftban/conf.d/banner.conf" \
        "${LAB_USER}@${server}:${LAB_TEST_DIR}/etc/nftban/conf.d/"

    log_info "Deploying nftban_output.sh..."
    scp -q "${LOCAL_SRC_DIR}/usr/lib/nftban/core/nftban_output.sh" \
        "${LAB_USER}@${server}:${LAB_TEST_DIR}/usr/lib/nftban/core/"

    log_info "Deploying test-banner.sh..."
    scp -q "${LOCAL_TEST_SCRIPT}" \
        "${LAB_USER}@${server}:${LAB_TEST_DIR}/"

    # Make scripts executable
    ssh "${LAB_USER}@${server}" "chmod +x ${LAB_TEST_DIR}/*.sh ${LAB_TEST_DIR}/usr/lib/nftban/core/*.sh"

    log_success "Files deployed"
    echo ""

    # =============================================================================
    # RUN SHELLCHECK
    # =============================================================================

    echo "--- ShellCheck Validation ---"
    echo ""

    log_info "Running shellcheck on nftban_output.sh..."
    if ssh "${LAB_USER}@${server}" "command -v shellcheck >/dev/null 2>&1"; then
        # Run shellcheck
        if ssh "${LAB_USER}@${server}" "shellcheck ${LAB_TEST_DIR}/usr/lib/nftban/core/nftban_output.sh"; then
            log_success "ShellCheck PASSED (nftban_output.sh)"
        else
            log_warning "ShellCheck found issues (nftban_output.sh)"
        fi
        echo ""

        log_info "Running shellcheck on test-banner.sh..."
        if ssh "${LAB_USER}@${server}" "shellcheck ${LAB_TEST_DIR}/test-banner.sh"; then
            log_success "ShellCheck PASSED (test-banner.sh)"
        else
            log_warning "ShellCheck found issues (test-banner.sh)"
        fi
    else
        log_warning "ShellCheck not installed on $server"
    fi
    echo ""

    # =============================================================================
    # RUN BASH SYNTAX CHECK
    # =============================================================================

    echo "--- Bash Syntax Check ---"
    echo ""

    log_info "Checking bash syntax (nftban_output.sh)..."
    if ssh "${LAB_USER}@${server}" "bash -n ${LAB_TEST_DIR}/usr/lib/nftban/core/nftban_output.sh"; then
        log_success "Bash syntax OK (nftban_output.sh)"
    else
        log_error "Bash syntax error (nftban_output.sh)"
    fi

    log_info "Checking bash syntax (test-banner.sh)..."
    if ssh "${LAB_USER}@${server}" "bash -n ${LAB_TEST_DIR}/test-banner.sh"; then
        log_success "Bash syntax OK (test-banner.sh)"
    else
        log_error "Bash syntax error (test-banner.sh)"
    fi
    echo ""

    # =============================================================================
    # RUN FUNCTIONAL TESTS
    # =============================================================================

    echo "--- Functional Tests ---"
    echo ""

    log_info "Running banner test (simple mode, info level)..."
    ssh "${LAB_USER}@${server}" "cd ${LAB_TEST_DIR} && ./test-banner.sh simple info false" 2>&1 | tail -20
    echo ""

    log_info "Running banner test (debug mode)..."
    ssh "${LAB_USER}@${server}" "cd ${LAB_TEST_DIR} && ./test-banner.sh full debug true" 2>&1 | head -30
    echo ""

    log_success "Tests completed on $server"
    echo ""
done

echo "============================================================================="
log_success "Lab deployment and testing complete!"
echo "============================================================================="
echo ""

log_info "Next steps:"
echo "  1. Review shellcheck output above"
echo "  2. Fix any issues found"
echo "  3. Apply security validation"
echo "  4. Update install.sh"
echo "  5. Document first module completion"
echo ""
