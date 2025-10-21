#!/usr/bin/env bash
# =============================================================================
# BUG41-44 Fix Script
# =============================================================================
# Fixes all bugs discovered during debug testing
#
# BUG41: DDoS module unbound variable - FIXED in code
# BUG42: Portscan module unbound variable - FIXED in code
# BUG43: Ubuntu nftables tables not created - FIX HERE
# BUG44: Login monitor timer missing - FIX HERE
#
# Author: ITCMS Team
# Version: 0.9.1
# =============================================================================

set -euo pipefail

echo "╔═══════════════════════════════════════════════════════╗"
echo "║      BUG41-44 Fix & Verification Script              ║"
echo "╚═══════════════════════════════════════════════════════╝"
echo ""

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ERRORS=0

# BUG43: Fix nftables table creation
echo -e "${BLUE}[BUG43]${NC} Checking nftables tables..."

if ! nft list table ip nftban_v4 &>/dev/null; then
    echo -e "${YELLOW}→${NC} IPv4 table missing, creating..."

    # Source the nftables module to create tables
    if [[ -f /etc/nftban/lib/nftban_nftables_module.sh ]]; then
        source /etc/nftban/lib/nftban_core.sh 2>/dev/null || true
        source /etc/nftban/lib/nftban_nftables_module.sh 2>/dev/null || true

        if command -v nftban_nftables_create_structure >/dev/null 2>&1; then
            nftban_nftables_create_structure 2>&1 | grep -v "DEBUG" || true
            echo -e "${GREEN}✓${NC} nftables structure created"
        else
            echo -e "${RED}✗${NC} Cannot find create function"
            ((ERRORS++))
        fi
    else
        echo -e "${RED}✗${NC} nftables module not found"
        ((ERRORS++))
    fi
else
    echo -e "${GREEN}✓${NC} nftables tables exist"
fi

# Verify tables exist now
if nft list table ip nftban_v4 &>/dev/null && nft list table ip6 nftban_v6 &>/dev/null; then
    echo -e "${GREEN}✓${NC} Both IPv4 and IPv6 tables verified"
else
    echo -e "${RED}✗${NC} Tables still missing!"
    ((ERRORS++))
fi

echo ""

# BUG44: Create login monitor timer
echo -e "${BLUE}[BUG44]${NC} Checking login monitor systemd timer..."

TIMER_FILE="/etc/systemd/system/nftban-login-monitor.timer"
SERVICE_FILE="/etc/systemd/system/nftban-login-monitor.service"

if [[ ! -f "$TIMER_FILE" ]]; then
    echo -e "${YELLOW}→${NC} Timer file missing, creating..."

    cat > "$TIMER_FILE" <<'EOF'
[Unit]
Description=nftban Login Monitor Timer
Documentation=https://github.com/itcmsgr/nftban

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

    echo -e "${GREEN}✓${NC} Timer file created"
else
    echo -e "${GREEN}✓${NC} Timer file exists"
fi

if [[ ! -f "$SERVICE_FILE" ]]; then
    echo -e "${YELLOW}→${NC} Service file missing, creating..."

    cat > "$SERVICE_FILE" <<'EOF'
[Unit]
Description=nftban Login Monitor Service
Documentation=https://github.com/itcmsgr/nftban
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nftban login run
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nftban-login-monitor

[Install]
WantedBy=multi-user.target
EOF

    echo -e "${GREEN}✓${NC} Service file created"
else
    echo -e "${GREEN}✓${NC} Service file exists"
fi

# Reload systemd
echo -e "${YELLOW}→${NC} Reloading systemd..."
systemctl daemon-reload

# Enable and start timer
echo -e "${YELLOW}→${NC} Enabling and starting timer..."
systemctl enable nftban-login-monitor.timer 2>/dev/null || true
systemctl start nftban-login-monitor.timer 2>/dev/null || true

# Verify timer is active
if systemctl is-active nftban-login-monitor.timer &>/dev/null; then
    echo -e "${GREEN}✓${NC} Login monitor timer is active"
else
    echo -e "${YELLOW}⚠${NC} Timer exists but not active (may need manual start)"
fi

echo ""

# Comprehensive verification
echo "═══════════════════════════════════════════════════════"
echo "  Final Verification"
echo "═══════════════════════════════════════════════════════"
echo ""

echo "1. nftables Tables:"
nft list tables 2>&1 | grep nftban || echo "  No nftban tables found!"

echo ""
echo "2. DDoS Module Status:"
if nftban ddos status 2>&1 | head -5 | grep -q "Global Status"; then
    echo -e "  ${GREEN}✓${NC} DDoS module functional"
else
    echo -e "  ${RED}✗${NC} DDoS module has issues"
    ((ERRORS++))
fi

echo ""
echo "3. Portscan Module Status:"
if nftban portscan status 2>&1 | head -5 | grep -q "Port Scan Detection"; then
    echo -e "  ${GREEN}✓${NC} Portscan module functional"
else
    echo -e "  ${RED}✗${NC} Portscan module has issues"
    ((ERRORS++))
fi

echo ""
echo "4. Login Monitor Timer:"
systemctl list-timers | grep nftban-login-monitor || echo "  Timer not in list"

echo ""
echo "═══════════════════════════════════════════════════════"

if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}✓ All bugs fixed successfully!${NC}"
    exit 0
else
    echo -e "${RED}✗ $ERRORS error(s) found${NC}"
    exit 1
fi
