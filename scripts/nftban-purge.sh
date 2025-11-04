#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.30.0 - Complete Purge Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Completely remove all NFTBan data including logs and config
#
# meta:name=nftban_purge
# meta:type=utility
# meta:header=NFTBan Complete Purge
# meta:version=0.30.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Completely purge NFTBan including logs and config (RPM systems)
# meta:input=User confirmation
# meta:output=Complete removal status
#
# **Usage:**
#   sudo ./nftban-purge.sh
#
# **Note:** Debian/Ubuntu users should use:
#   sudo apt-get purge nftban
# =============================================================================

set -e

RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

echo ""
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${RED}  NFTBan Complete Purge${NC}"
echo -e "${RED}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "${YELLOW}WARNING: This will permanently delete:${NC}"
echo "  - All configuration files (/etc/nftban/)"
echo "  - All state and database files (/var/lib/nftban/)"
echo "  - All log files (/var/log/nftban/)"
echo "  - All cache files (/var/cache/nftban/)"
echo ""
echo -e "${RED}This operation CANNOT be undone!${NC}"
echo ""

# Require explicit confirmation
read -p "Type 'yes-i-understand' to proceed: " confirmation
if [ "$confirmation" != "yes-i-understand" ]; then
    echo ""
    echo "Purge cancelled."
    exit 0
fi

echo ""
echo "Purging NFTBan data..."

# Check if NFTBan package is still installed
if rpm -q nftban >/dev/null 2>&1; then
    echo "  → Uninstalling NFTBan package..."
    dnf remove -y nftban || yum remove -y nftban || true
fi

# Remove all directories
echo "  → Removing configuration files..."
rm -rf /etc/nftban

echo "  → Removing state files..."
rm -rf /var/lib/nftban

echo "  → Removing log files..."
rm -rf /var/log/nftban

echo "  → Removing cache files..."
rm -rf /var/cache/nftban

echo "  → Removing runtime files..."
rm -rf /run/nftban

# Remove nftables table
echo "  → Removing nftables configuration..."
if command -v nft >/dev/null 2>&1; then
    nft list table inet nftban >/dev/null 2>&1 && nft delete table inet nftban || true
fi

echo ""
echo -e "${GREEN}✓ NFTBan purge complete!${NC}"
echo ""
echo "Note: System users and groups (nftban, nftban-cli, nftban-auditors)"
echo "      were NOT removed. They don't consume resources and may be reused"
echo "      if you reinstall NFTBan."
echo ""
