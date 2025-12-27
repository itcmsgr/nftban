#!/usr/bin/env bash
# =============================================================================
# Enable Development Mode for nftban-ui.service
# =============================================================================
# This script configures the nftban-ui systemd service to run in development
# mode, which serves files from disk instead of embedded FS.
#
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
echo "  1. Edit HTML/JS/CSS files in $DEV_SOURCE_DIR/cmd/nftban-ui/web/"
echo "  2. Refresh your browser (Ctrl+Shift+R)"
echo "  3. See changes immediately - NO REBUILD NEEDED!"
echo ""
echo -e "${YELLOW}To check logs:${NC}"
echo "  journalctl -u nftban-ui -f"
echo ""
echo -e "${RED}⚠️  WARNING: This is for DEVELOPMENT ONLY - Never use in production!${NC}"
