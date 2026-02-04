#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Enable Development Mode Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="enable_dev_mode"
# meta:type="installer"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-10-26"
# meta:description="Configures nftban-ui for development with disk-served files"
# meta:input="None"
# meta:output="Development mode configuration applied"
# meta:depends="systemd"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units="nftban-ui.service"
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
# WARNING: Only use this on development servers, NEVER in production!
# =============================================================================

set -Eeuo pipefail

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${YELLOW}🔧 Enabling Development Mode for nftban-ui${NC}"
echo ""

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}❌ This script must be run as root${NC}"
   exit 1
fi

# Service file path
SERVICE_FILE="/etc/systemd/system/nftban-ui.service"
OVERRIDE_DIR="/etc/systemd/system/nftban-ui.service.d"
DEV_OVERRIDE_FILE="$OVERRIDE_DIR/dev-mode.conf"

# Check if service exists
if [[ ! -f "$SERVICE_FILE" ]]; then
    echo -e "${RED}❌ Service file not found: $SERVICE_FILE${NC}"
    exit 1
fi

# Create override directory if it doesn't exist
mkdir -p "$OVERRIDE_DIR"

# Get source directory (default to /root/nftban-dev for backwards compatibility)
DEV_SOURCE_DIR="${NFTBAN_DEV_SOURCE_DIR:-/root/nftban-dev}"

# Create dev mode override
cat > "$DEV_OVERRIDE_FILE" <<EOF
[Service]
# Development mode: serve files from disk (no rebuild needed for HTML/JS/CSS)
WorkingDirectory=$DEV_SOURCE_DIR/cmd/nftban-ui
ExecStart=
ExecStart=$DEV_SOURCE_DIR/cmd/nftban-ui/nftban-ui --dev

# Log dev mode startup
StandardOutput=journal
StandardError=journal
EOF

echo -e "${GREEN}✅ Created dev mode override: $DEV_OVERRIDE_FILE${NC}"

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
echo -e "${GREEN}🎉 Development mode enabled!${NC}"
echo ""
echo -e "${YELLOW}Now you can:${NC}"
echo "  1. Edit Templ templates in $DEV_SOURCE_DIR/cmd/nftban-ui/templates/"
echo "  2. Run 'templ generate' to regenerate Go code"
echo "  3. Rebuild binary to see changes (GOTH GUI compiles templates into binary)"
echo ""
echo -e "${YELLOW}To check logs:${NC}"
echo "  journalctl -u nftban-ui -f"
echo ""
echo -e "${RED}⚠️  WARNING: This is for DEVELOPMENT ONLY - Never use in production!${NC}"
