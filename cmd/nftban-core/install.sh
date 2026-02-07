#!/bin/bash
# =============================================================================
# NFTBan v1.0.0 - Core Go Binary Installer
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="install"
# meta:type="installer"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-10-26"
# meta:description="Installs systemd services, PolicyKit rules, and permissions"
# meta:input="None"
# meta:output="Installed nftban-core binary and services"
# meta:depends="systemd"
# meta:inventory.files=""
# meta:inventory.binaries="nftban-core"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-core.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail

# Colors for output
RED='\033[0.31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}NFTBan Core v1.0.0 - Installation${NC}"
echo "========================================"
echo

# Check if running as root
if [ "$EUID" -ne 0 ]; then
   echo -e "${RED}Error: This script must be run as root${NC}"
   echo "Usage: sudo ./install.sh"
   exit 1
fi

# Detect script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BINARY_PATH="${SCRIPT_DIR}/nftban-core"

# Check if binary exists
if [ ! -f "$BINARY_PATH" ]; then
    echo -e "${RED}Error: nftban-core binary not found at ${BINARY_PATH}${NC}"
    echo "Please build the binary first: go build -o nftban-core"
    exit 1
fi

# Step 1: Install binary
echo -e "${YELLOW}[1/6]${NC} Installing nftban-core binary..."
install -m 0755 "$BINARY_PATH" /usr/local/bin/nftban-core
echo -e "${GREEN}✓${NC} Binary installed to /usr/local/bin/nftban-core"
echo

# Step 2: Create nftban group
echo -e "${YELLOW}[2/6]${NC} Creating nftban group..."
if ! getent group nftban > /dev/null 2>&1; then
    groupadd -r nftban
    echo -e "${GREEN}✓${NC} Group 'nftban' created"
else
    echo -e "${GREEN}✓${NC} Group 'nftban' already exists"
fi
echo

# Step 3: Create directories with correct ownership (no -R needed for fresh dirs)
echo -e "${YELLOW}[3/6]${NC} Creating required directories..."
install -d -o root -g nftban -m 0750 /etc/nftban
install -d -o root -g nftban -m 0750 /etc/nftban/whitelist.d
install -d -o root -g nftban -m 0750 /etc/nftban/blacklist.d
install -d -o root -g nftban -m 0750 /etc/nftban/ports.d
install -d -o root -g nftban -m 0750 /var/lib/nftban
install -d -o root -g nftban -m 0750 /var/lib/nftban/feeds
echo -e "${GREEN}✓${NC} Directories created with proper permissions"
echo

# Step 4: Install systemd service files
echo -e "${YELLOW}[4/6]${NC} Installing systemd service files..."
install -m 0644 "${SCRIPT_DIR}/systemd/nftban-core.service" /etc/systemd/system/
install -m 0644 "${SCRIPT_DIR}/systemd/nftban-core-feeds.service" /etc/systemd/system/
install -m 0644 "${SCRIPT_DIR}/systemd/nftban-core-feeds.timer" /etc/systemd/system/
systemctl daemon-reload
echo -e "${GREEN}✓${NC} Systemd services installed"
echo

# Step 5: Install PolicyKit rules
echo -e "${YELLOW}[5/6]${NC} Installing PolicyKit rules..."
if [ -d /etc/polkit-1/rules.d ]; then
    install -m 0644 "${SCRIPT_DIR}/polkit/10-nftban-core.rules" /etc/polkit-1/rules.d/
    echo -e "${GREEN}✓${NC} PolicyKit rules installed"
else
    echo -e "${YELLOW}⚠${NC}  PolicyKit directory not found - skipping (PolicyKit may not be installed)"
fi
echo

# Step 6: Enable services
echo -e "${YELLOW}[6/6]${NC} Enabling services..."
read -p "Enable nftban-core.service on boot? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    systemctl enable nftban-core.service
    echo -e "${GREEN}✓${NC} nftban-core.service enabled"
fi

read -p "Enable automatic daily feed updates? (y/N) " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    systemctl enable nftban-core-feeds.timer
    systemctl start nftban-core-feeds.timer
    echo -e "${GREEN}✓${NC} nftban-core-feeds.timer enabled and started"
fi
echo

# Summary
echo "========================================"
echo -e "${GREEN}Installation Complete!${NC}"
echo
echo "Next steps:"
echo "  1. Add users to nftban group: usermod -aG nftban <username>"
echo "  2. Initialize NFTBan: sudo nftban-core init"
echo "  3. Start the service: sudo systemctl start nftban-core"
echo "  4. Check status: systemctl status nftban-core"
echo
echo "For non-root users in the nftban group, services can be managed with:"
echo "  systemctl start nftban-core.service"
echo "  systemctl stop nftban-core.service"
echo "  systemctl status nftban-core.service"
echo
echo "Feed updates run daily at 3:00 AM (if timer is enabled)"
echo "Manual update: sudo systemctl start nftban-core-feeds.service"
echo
