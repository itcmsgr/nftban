#!/usr/bin/env bash
# =============================================================================
# NFTBan Repository Setup - AlmaLinux
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Configure repositories for AlmaLinux 8/9
# Package Manager: dnf
# =============================================================================

set -Eeuo pipefail

# Colors
# RED unused - removed for ShellCheck
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly NC='\033[0m'

# Detect version
# shellcheck source=/dev/null
source /etc/os-release
VER=${VERSION_ID%%.*}

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "AlmaLinux $VER Repository Setup"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# Determine correct repo names
if [[ "$VER" -ge 9 ]]; then
    CRB_NAME="crb"
else
    CRB_NAME="powertools"
fi

echo "Step 1: Update package manager cache"
echo "-------------------------------------"
dnf clean all
dnf makecache
echo -e "${GREEN}✓ Package manager updated${NC}"
echo ""

echo "Step 2: Install EPEL repository"
echo "--------------------------------"
if rpm -qa | grep -q epel-release; then
    echo "✓ EPEL already installed"
else
    dnf install -y epel-release
    echo -e "${GREEN}✓ EPEL installed${NC}"
fi
echo ""

echo "Step 3: Enable CRB/PowerTools repository"
echo "-----------------------------------------"
dnf config-manager --set-enabled "$CRB_NAME"
echo -e "${GREEN}✓ $CRB_NAME enabled${NC}"
echo ""

echo "Step 4: Disable conflicting testing repositories"
echo "-------------------------------------------------"
DISABLED_COUNT=0
for repo in epel-testing epel-modular epel-next epel-next-testing; do
    if dnf repolist enabled 2>/dev/null | grep -q "$repo"; then
        dnf config-manager --set-disabled "$repo" 2>/dev/null || true
        echo "  Disabled: $repo"
        # BUG-001: Safe arithmetic - do not use ((DISABLED_COUNT++)) with set -e
        DISABLED_COUNT=$((DISABLED_COUNT + 1))
    fi
done

if [[ $DISABLED_COUNT -eq 0 ]]; then
    echo "✓ No conflicting repos found"
else
    echo -e "${GREEN}✓ Disabled $DISABLED_COUNT conflicting repos${NC}"
fi
echo ""

echo "Step 5: Remove manual Go installations (if any)"
echo "------------------------------------------------"
if [[ -d /usr/local/go ]]; then
    echo -e "${YELLOW}⚠️  Found manual Go installation at /usr/local/go${NC}"
    echo "   This conflicts with distro golang package."
    rm -rf /usr/local/go
    echo -e "${GREEN}✓ Removed manual Go installation${NC}"
else
    echo "✓ No manual Go installation found"
fi
echo ""

echo "Step 6: Synchronize packages (fix version mismatches)"
echo "------------------------------------------------------"
dnf distro-sync -y
echo -e "${GREEN}✓ Package synchronization complete${NC}"
echo ""

echo "Step 7: Verify configuration"
echo "-----------------------------"
echo "Enabled repositories:"
dnf repolist enabled | grep -E "epel[^-]|$CRB_NAME" || echo "  (checking...)"
echo ""

echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}✓ AlmaLinux $VER configured for NFTBan${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "You can now install NFTBan:"
echo "  wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm"
echo "  sudo dnf install -y nftban-x86_64.rpm"
echo ""
