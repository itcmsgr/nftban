#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Installation Test Script
# =============================================================================
# meta:name="test_installation"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Tests that installation completed correctly"
# meta:inventory.files=""
# meta:inventory.binaries="bash,systemctl,nft,nftban"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-health.timer"
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Usage: ./scripts/test_installation.sh [mode]
#        mode: cli (default), gui, all
# =============================================================================

set -Eeuo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

MODE="${1:-cli}"
ERRORS=0
WARNINGS=0
TESTS=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; ((TESTS++)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; ((ERRORS++)); ((TESTS++)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; ((WARNINGS++)); }
info() { echo -e "${BLUE}[INFO]${NC} $*"; }

check_file() {
    local file="$1"
    local desc="${2:-$file}"
    if [[ -f "$file" ]]; then
        pass "$desc exists"
        return 0
    else
        fail "$desc MISSING"
        return 1
    fi
}

check_dir() {
    local dir="$1"
    local desc="${2:-$dir}"
    if [[ -d "$dir" ]]; then
        pass "$desc exists"
        return 0
    else
        fail "$desc MISSING"
        return 1
    fi
}

check_command() {
    local cmd="$1"
    local desc="${2:-$cmd}"
    if command -v "$cmd" &>/dev/null; then
        pass "$desc available"
        return 0
    else
        fail "$desc NOT FOUND"
        return 1
    fi
}

check_service() {
    local svc="$1"
    if systemctl is-enabled "$svc" &>/dev/null; then
        pass "Service $svc enabled"
    else
        warn "Service $svc not enabled"
    fi
}

echo "=============================================="
echo "NFTBan Installation Verification"
echo "=============================================="
echo "Mode: $MODE"
echo "Date: $(date)"
echo ""

# -----------------------------------------------------------------------------
# 1. BINARIES
# -----------------------------------------------------------------------------
info "=== Checking Binaries ==="

check_file "/usr/sbin/nftban" "Main CLI"

if [[ "$MODE" == "all" || "$MODE" == "gui" ]]; then
    check_file "/usr/lib/nftban/bin/nftban-core" "nftban-core binary"
fi

if [[ "$MODE" == "gui" ]]; then
    check_file "/usr/sbin/nftban-ui" "nftban-ui binary"
fi

echo ""

# -----------------------------------------------------------------------------
# 2. LIBRARIES
# -----------------------------------------------------------------------------
info "=== Checking Libraries ==="

check_dir "/usr/lib/nftban" "Library directory"
check_dir "/usr/lib/nftban/cli" "CLI handlers"
check_dir "/usr/lib/nftban/core" "Core modules"
check_dir "/usr/lib/nftban/helpers" "Helper scripts"
check_dir "/usr/lib/nftban/lib" "Shared libs"

# Count CLI commands
CLI_COUNT=$(ls -1 /usr/lib/nftban/cli/cmd_*.sh 2>/dev/null | wc -l)
if [[ $CLI_COUNT -ge 40 ]]; then
    pass "CLI commands: $CLI_COUNT (expected 43)"
else
    fail "CLI commands: $CLI_COUNT (expected 43)"
fi

echo ""

# -----------------------------------------------------------------------------
# 3. CONFIGURATION
# -----------------------------------------------------------------------------
info "=== Checking Configuration ==="

check_dir "/etc/nftban" "Config directory"
check_file "/etc/nftban/nftban.conf" "Main config"
check_dir "/etc/nftban/conf.d" "Config drop-in"

echo ""

# -----------------------------------------------------------------------------
# 4. DATA DIRECTORIES
# -----------------------------------------------------------------------------
info "=== Checking Data Directories ==="

check_dir "/var/lib/nftban" "Data directory"
check_dir "/var/log/nftban" "Log directory"
check_dir "/var/cache/nftban" "Cache directory"

echo ""

# -----------------------------------------------------------------------------
# 5. USER/GROUP
# -----------------------------------------------------------------------------
info "=== Checking User/Group ==="

if id nftban &>/dev/null; then
    pass "User 'nftban' exists"
else
    fail "User 'nftban' MISSING"
fi

if getent group nftban &>/dev/null; then
    pass "Group 'nftban' exists"
else
    fail "Group 'nftban' MISSING"
fi

# v1.0.19+: 3-group model - nftban, nftban-auditor, nftban-panel
if getent group nftban-auditor &>/dev/null; then
    pass "Group 'nftban-auditor' exists"
else
    warn "Group 'nftban-auditor' missing (auditors only)"
fi

echo ""

# -----------------------------------------------------------------------------
# 6. NFTABLES
# -----------------------------------------------------------------------------
info "=== Checking NFTables ==="

if nft list table ip nftban &>/dev/null; then
    pass "Table 'ip nftban' exists"
else
    fail "Table 'ip nftban' MISSING"
fi

if nft list table ip6 nftban &>/dev/null; then
    pass "Table 'ip6 nftban' exists"
else
    warn "Table 'ip6 nftban' missing (optional)"
fi

echo ""

# -----------------------------------------------------------------------------
# 7. SYSTEMD
# -----------------------------------------------------------------------------
info "=== Checking Systemd ==="

check_service "nftban-health.timer"

if [[ "$MODE" == "gui" ]]; then
    check_service "nftban-ui"
fi

echo ""

# -----------------------------------------------------------------------------
# 8. CLI FUNCTIONALITY
# -----------------------------------------------------------------------------
info "=== Testing CLI ==="

if nftban version &>/dev/null; then
    VERSION=$(nftban version 2>/dev/null | grep -oP 'v?\d+\.\d+\.\d+' | head -1 || echo "unknown")
    pass "nftban version: $VERSION"
else
    fail "nftban version FAILED"
fi

if nftban help &>/dev/null; then
    pass "nftban help works"
else
    fail "nftban help FAILED"
fi

# Quick smoke test
if timeout 10 nftban health summary &>/dev/null; then
    pass "nftban health summary works"
else
    warn "nftban health summary failed or timed out"
fi

echo ""

# -----------------------------------------------------------------------------
# 9. PERMISSIONS
# -----------------------------------------------------------------------------
info "=== Checking Permissions ==="

# Check /etc/nftban ownership
CONF_OWNER=$(stat -c '%U:%G' /etc/nftban 2>/dev/null || echo "unknown")
if [[ "$CONF_OWNER" == "root:nftban" ]]; then
    pass "/etc/nftban ownership: $CONF_OWNER"
else
    warn "/etc/nftban ownership: $CONF_OWNER (expected root:nftban)"
fi

# Check /var/lib/nftban ownership
DATA_OWNER=$(stat -c '%U:%G' /var/lib/nftban 2>/dev/null || echo "unknown")
if [[ "$DATA_OWNER" == "nftban:nftban" ]]; then
    pass "/var/lib/nftban ownership: $DATA_OWNER"
else
    warn "/var/lib/nftban ownership: $DATA_OWNER (expected nftban:nftban)"
fi

echo ""

# -----------------------------------------------------------------------------
# SUMMARY
# -----------------------------------------------------------------------------
echo "=============================================="
echo "VERIFICATION SUMMARY"
echo "=============================================="
echo ""
echo "Tests:    $TESTS"
echo "Passed:   $((TESTS - ERRORS))"
echo "Failed:   $ERRORS"
echo "Warnings: $WARNINGS"
echo ""

if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}SUCCESS: Installation verified!${NC}"
    echo ""
    echo "Next steps:"
    echo "  nftban status"
    echo "  nftban selftest --quick"
    exit 0
else
    echo -e "${RED}FAILED: $ERRORS errors found${NC}"
    echo ""
    echo "Please fix the errors and re-run verification."
    exit 1
fi
