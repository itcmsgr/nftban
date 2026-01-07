#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Disable Development Mode Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="disable_dev_mode"
# meta:type="installer"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-10-26"
# meta:description="Removes dev mode configuration and restores production mode"
# meta:input="None"
# meta:output="Production mode configuration restored"
# meta:depends="systemd"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-ui.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================

set -Eeuo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🔒 Disabling Development Mode for nftban-ui${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ This script must be run as root${NC}"
   exit 1
fi

# Service file path
DEV_OVERRIDE_FILE="/etc/systemd/system/nftban-ui.service.d/dev-mode.conf"

# Remove dev mode override if it exists
if [[ -f "$DEV_OVERRIDE_FILE" ]]; then
    rm "$DEV_OVERRIDE_FILE"
    echo -e "${GREEN}✅ Removed dev mode override: $DEV_OVERRIDE_FILE${NC}"
else
    echo -e "${YELLOW}ℹ️  Dev mode override not found (already disabled)${NC}"
fi

# Reload systemd
systemctl daemon-reload
echo -e "${GREEN}✅ Reloaded systemd daemon${NC}"

# Restart service
systemctl restart nftban-ui
echo -e "${GREEN}✅ Restarted nftban-ui service${NC}"

# Show status
echo ""
echo -e "${YELLOW}📊 Service Status:${NC}"
systemctl status nftban-ui --no-pager -l | head -15

echo ""
echo -e "${GREEN}🎉 Production mode restored!${NC}"
echo ""
echo -e "${YELLOW}Service is now using:${NC}"
echo "  - Embedded files (compiled into binary)"
echo "  - Standard ExecStart: /usr/sbin/nftban-ui"
echo "  - No --dev flag"
