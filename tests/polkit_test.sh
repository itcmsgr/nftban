#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0 - Polkit Authorization Test Suite
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Verify Polkit rules grant correct permissions without privilege escalation
# Usage: sudo bash tests/polkit_test.sh [username]
# =============================================================================

set -euo pipefail

# Colors
readonly GREEN='\033[0;32m'
readonly RED='\033[0;31m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_pass() { echo -e "${GREEN}[PASS]${NC} $*"; }
log_fail() { echo -e "${RED}[FAIL]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_fail "Must run as root to test polkit authorization"
    exit 1
fi

# Get test user (default: first user in nftban group)
TEST_USER="${1:-}"
if [ -z "$TEST_USER" ]; then
    TEST_USER=$(getent group nftban | cut -d: -f4 | cut -d, -f1)
    if [ -z "$TEST_USER" ]; then
        log_fail "No users found in nftban group. Please specify test user."
        exit 1
    fi
fi

log_info "================================================================="
log_info "NFTBan v1.0 Polkit Authorization Test Suite"
log_info "================================================================="
log_info "Test User: $TEST_USER"
log_info ""

# =============================================================================
# Test 1: Verify Polkit rules are installed
# =============================================================================
log_info "Test 1: Verifying Polkit rules installation..."

# NFTBan v1.0 simplified polkit rules (nftban group for all operators)
RULES=(
    "/etc/polkit-1/rules.d/10-nftban-core.rules"
    "/etc/polkit-1/rules.d/20-nftban-suricata.rules"
    "/etc/polkit-1/rules.d/50-nftban-auth.rules"
    "/etc/polkit-1/rules.d/60-nftban-services.rules"
)

for rule in "${RULES[@]}"; do
    if [ -f "$rule" ]; then
        log_pass "Found: $rule"
    else
        log_warn "Missing: $rule"
    fi
done

echo ""

# =============================================================================
# Test 2: Verify group memberships
# =============================================================================
log_info "Test 2: Verifying group memberships for $TEST_USER..."

# NFTBan v1.0 simplified 2-group model
GROUPS=(
    "nftban"
    "nftban-auditors"
)

for group in "${GROUPS[@]}"; do
    if id -nG "$TEST_USER" | grep -qw "$group"; then
        log_pass "User '$TEST_USER' is in group: $group"
    else
        log_warn "User '$TEST_USER' NOT in group: $group"
    fi
done

echo ""

# =============================================================================
# Test 3: Test nftban-core service management (10-nftban-core.rules)
# =============================================================================
log_info "Test 3: Testing nftban-core service management..."

CORE_UNITS=(
    "nftban-core.service"
    "nftban-suricata.service"
    "nftban-login-monitor.service"
    "nftban.timer"
)

for unit in "${CORE_UNITS[@]}"; do
    if systemctl list-unit-files "$unit" &>/dev/null; then
        # Test as nftban group member
        if su - "$TEST_USER" -c "systemctl status $unit" &>/dev/null; then
            log_pass "✓ $TEST_USER can query: $unit"
        else
            log_fail "✗ $TEST_USER CANNOT query: $unit"
        fi

        # Test restart (dry-run via pkcheck)
        if pkcheck --action-id org.freedesktop.systemd1.manage-units \
                   --process "$(pgrep -u "$TEST_USER" | head -1)" \
                   --allow-user-interaction 2>/dev/null; then
            log_pass "✓ $TEST_USER authorized to manage: $unit"
        else
            log_warn "✗ $TEST_USER NOT authorized to manage: $unit"
        fi
    else
        log_warn "Unit not installed: $unit"
    fi
done

echo ""

# =============================================================================
# Test 4: Test Suricata direct management (20-nftban-suricata.rules)
# =============================================================================
log_info "Test 4: Testing direct Suricata service management..."

SURICATA_UNITS=(
    "suricata.service"
    "suricata-update.service"
)

for unit in "${SURICATA_UNITS[@]}"; do
    if systemctl list-unit-files "$unit" &>/dev/null; then
        if su - "$TEST_USER" -c "systemctl status $unit" &>/dev/null; then
            log_pass "✓ $TEST_USER can query: $unit"
        else
            log_fail "✗ $TEST_USER CANNOT query: $unit"
        fi
    else
        log_warn "Suricata not installed: $unit"
    fi
done

echo ""

# =============================================================================
# Test 5: Test auth helper (50-nftban-auth.rules)
# =============================================================================
log_info "Test 5: Testing auth helper access..."

AUTH_HELPER="/usr/libexec/nftban-auth-helper"
if [ -f "$AUTH_HELPER" ]; then
    # Check ownership and permissions
    OWNER=$(stat -c '%U:%G' "$AUTH_HELPER")
    PERMS=$(stat -c '%a' "$AUTH_HELPER")

    if [ "$OWNER" = "root:root" ]; then
        log_pass "✓ Auth helper owned by root:root"
    else
        log_fail "✗ Auth helper owned by: $OWNER (should be root:root)"
    fi

    if [ "$PERMS" = "755" ] || [ "$PERMS" = "750" ]; then
        log_pass "✓ Auth helper permissions: $PERMS"
    else
        log_warn "Auth helper permissions: $PERMS (should be 755 or 750)"
    fi
else
    log_warn "Auth helper not found: $AUTH_HELPER"
fi

echo ""

# =============================================================================
# Test 6: Test nftables isolation (should FAIL for non-root)
# =============================================================================
log_info "Test 6: Testing nftables isolation (should deny non-root)..."

if su - "$TEST_USER" -c "nft list tables" &>/dev/null; then
    log_fail "✗ SECURITY ISSUE: $TEST_USER can run 'nft' directly!"
else
    log_pass "✓ nftables properly isolated (user cannot run 'nft')"
fi

echo ""

# =============================================================================
# Test 7: Test systemd daemon-reload
# =============================================================================
log_info "Test 7: Testing systemd daemon-reload authorization..."

if pkcheck --action-id org.freedesktop.systemd1.reload-daemon \
           --process "$(pgrep -u "$TEST_USER" | head -1)" \
           --allow-user-interaction 2>/dev/null; then
    log_pass "✓ $TEST_USER authorized for daemon-reload"
else
    log_warn "✗ $TEST_USER NOT authorized for daemon-reload"
fi

echo ""

# =============================================================================
# Test 8: Verify nftban-core runs with correct capabilities
# =============================================================================
log_info "Test 8: Verifying nftban-core systemd service capabilities..."

if systemctl show nftban-suricata.service -p User | grep -q "User=root"; then
    log_pass "✓ nftban-suricata runs as root"
else
    log_warn "nftban-suricata NOT running as root"
fi

if systemctl show nftban-suricata.service -p SupplementaryGroups | grep -q "suricata"; then
    log_pass "✓ nftban-suricata has supplementary group: suricata"
else
    log_warn "nftban-suricata missing supplementary group: suricata"
fi

if systemctl show nftban-suricata.service -p SupplementaryGroups | grep -q "nftban"; then
    log_pass "✓ nftban-suricata has supplementary group: nftban"
else
    log_warn "nftban-suricata missing supplementary group: nftban"
fi

echo ""

# =============================================================================
# Summary
# =============================================================================
log_info "================================================================="
log_info "Test Summary"
log_info "================================================================="
log_info "Polkit rules tested for user: $TEST_USER"
log_info ""
log_info "Expected Results:"
log_info "  ✓ User CAN manage nftban-* services (via 10-nftban-core.rules)"
log_info "  ✓ User CAN manage suricata services (via 20-nftban-suricata.rules)"
log_info "  ✓ User CANNOT run 'nft' directly (nftables isolated)"
log_info "  ✓ nftban-suricata runs as root with CAP_NET_ADMIN"
log_info ""
log_info "Manual Testing Commands (run as $TEST_USER):"
log_info "  systemctl status nftban-suricata.service   # Should work"
log_info "  systemctl restart nftban-suricata.service  # Should work without sudo"
log_info "  systemctl status suricata.service          # Should work"
log_info "  nft list tables                            # Should FAIL (permission denied)"
log_info ""
log_info "================================================================="

exit 0
