#!/usr/bin/env bash
# NFTBan v0.10.0 - Lab Server Cleanup Script
# Removes v0.9.5 installation and prepares for v0.10.0

set -Eeuo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Usage
usage() {
    cat <<EOF
NFTBan v0.9.5 Cleanup Script - Prepare for v0.10.0

Usage: $0 <server> [user@server]

Examples:
  $0 lab.mywebhost.gr
  $0 lab1.mywebhost.gr root
  $0 lab2.mywebhost.gr

This script will:
  1. Stop fail2ban service
  2. Stop nftables service
  3. Backup /etc/nftban → /etc/nftban_0.9.5
  4. Remove old nftban installation
  5. Clean up cron jobs
  6. Prepare for fresh v0.10.0 installation

⚠️  WARNING: This will stop firewall services!
    Make sure you have alternative access to the server.

EOF
    exit 1
}

# Check arguments
if [[ $# -lt 1 ]]; then
    usage
fi

SERVER="$1"
REMOTE_USER="${2:-root}"
TARGET="${REMOTE_USER}@${SERVER}"

echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
echo -e "${BLUE}NFTBan v0.9.5 Cleanup - Prepare for v0.10.0${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
echo -e "Target: ${GREEN}${TARGET}${NC}"
echo -e "${YELLOW}WARNING:${NC} This will stop firewall services!"
echo ""

# Confirmation
read -p "Continue with cleanup on ${SERVER}? (yes/no): " CONFIRM
if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborted."
    exit 0
fi

echo ""

# Step 1: Stop services
echo -e "${BLUE}[1/7]${NC} Stopping services..."

ssh "$TARGET" bash <<'REMOTE_SCRIPT'
set -e

# Stop fail2ban
if systemctl is-active --quiet fail2ban; then
    systemctl stop fail2ban
    echo "  ✓ Stopped fail2ban"
else
    echo "  ℹ fail2ban not running"
fi

# Disable fail2ban from auto-start
if systemctl is-enabled --quiet fail2ban; then
    systemctl disable fail2ban
    echo "  ✓ Disabled fail2ban"
fi

# Stop nftables
if systemctl is-active --quiet nftables; then
    systemctl stop nftables
    echo "  ✓ Stopped nftables"
else
    echo "  ℹ nftables not running"
fi

# Disable nftables from auto-start
if systemctl is-enabled --quiet nftables; then
    systemctl disable nftables
    echo "  ✓ Disabled nftables"
fi

# Flush nftables rules
nft flush ruleset 2>/dev/null || true
echo "  ✓ Flushed nftables rules"
REMOTE_SCRIPT

echo -e "${GREEN}✓${NC} Services stopped"
echo ""

# Step 2: Backup /etc/nftban
echo -e "${BLUE}[2/7]${NC} Backing up /etc/nftban → /etc/nftban_0.9.5..."

ssh "$TARGET" bash <<'REMOTE_SCRIPT'
set -e

if [[ -d /etc/nftban ]]; then
    # Remove old backup if exists
    if [[ -d /etc/nftban_0.9.5 ]]; then
        echo "  ⚠ Removing old backup: /etc/nftban_0.9.5"
        rm -rf /etc/nftban_0.9.5
    fi

    # Move current to backup
    mv /etc/nftban /etc/nftban_0.9.5
    echo "  ✓ Backed up: /etc/nftban → /etc/nftban_0.9.5"

    # Show backup size
    du -sh /etc/nftban_0.9.5 | sed 's/^/  Size: /'
else
    echo "  ℹ /etc/nftban not found (already clean)"
fi
REMOTE_SCRIPT

echo -e "${GREEN}✓${NC} Configuration backed up"
echo ""

# Step 3: Remove old nftban installation
echo -e "${BLUE}[3/7]${NC} Removing old nftban installation..."

ssh "$TARGET" bash <<'REMOTE_SCRIPT'
set -e

# Remove nftban script from common locations
for path in /usr/local/bin/nftban /usr/bin/nftban /opt/nftban/nftban; do
    if [[ -f "$path" ]]; then
        rm -f "$path"
        echo "  ✓ Removed: $path"
    fi
done

# Remove old nftban lib directory
if [[ -d /opt/nftban ]]; then
    echo "  ℹ Backing up: /opt/nftban → /opt/nftban_0.9.5"
    if [[ -d /opt/nftban_0.9.5 ]]; then
        rm -rf /opt/nftban_0.9.5
    fi
    mv /opt/nftban /opt/nftban_0.9.5
    echo "  ✓ Backed up: /opt/nftban → /opt/nftban_0.9.5"
fi

# Remove old lib directories if they exist
for dir in /usr/local/lib/nftban /etc/lib/nftban; do
    if [[ -d "$dir" ]]; then
        echo "  ✓ Removed: $dir"
        rm -rf "$dir"
    fi
done

echo "  ✓ Old installation removed"
REMOTE_SCRIPT

echo -e "${GREEN}✓${NC} Old installation removed"
echo ""

# Step 4: Clean up cron jobs
echo -e "${BLUE}[4/7]${NC} Cleaning up cron jobs..."

ssh "$TARGET" bash <<'REMOTE_SCRIPT'
set -e

# Remove cron entries for nftban
crontab -l 2>/dev/null | grep -v nftban | crontab - 2>/dev/null || true
echo "  ✓ Removed nftban cron entries"

# Remove cron file if exists
if [[ -f /etc/cron.d/nftban ]]; then
    rm -f /etc/cron.d/nftban
    echo "  ✓ Removed /etc/cron.d/nftban"
fi

# Remove monitoring scripts
if [[ -f /usr/local/bin/nftban_48h_monitor.sh ]]; then
    rm -f /usr/local/bin/nftban_48h_monitor.sh
    echo "  ✓ Removed monitoring script"
fi

# Kill any running monitoring processes
pkill -f nftban_48h_monitor || true
pkill -f nftban || true
echo "  ✓ Stopped any running nftban processes"
REMOTE_SCRIPT

echo -e "${GREEN}✓${NC} Cron jobs cleaned"
echo ""

# Step 5: Remove ALL symlinks and clean up logs
echo -e "${BLUE}[5/7]${NC} Removing symlinks and backing up logs..."

ssh "$TARGET" bash <<'REMOTE_SCRIPT'
set -e

# Find and remove ALL nftban-related symlinks
echo "  ℹ Searching for nftban symlinks..."
find /usr /var /etc -type l -name "*nftban*" 2>/dev/null | while read -r link; do
    rm -f "$link"
    echo "  ✓ Removed symlink: $link"
done || true

# Backup logs
if [[ -d /var/log/nftban ]]; then
    # Remove old backup if exists
    if [[ -d /var/log/nftban_0.9.5 ]]; then
        rm -rf /var/log/nftban_0.9.5
    fi
    mv /var/log/nftban /var/log/nftban_0.9.5
    echo "  ✓ Backed up: /var/log/nftban → /var/log/nftban_0.9.5"
fi

# Backup state data
if [[ -d /var/lib/nftban ]]; then
    if [[ -d /var/lib/nftban_0.9.5 ]]; then
        rm -rf /var/lib/nftban_0.9.5
    fi
    mv /var/lib/nftban /var/lib/nftban_0.9.5
    echo "  ✓ Backed up: /var/lib/nftban → /var/lib/nftban_0.9.5"
fi

# Remove cache (completely, not backed up)
if [[ -d /var/cache/nftban ]]; then
    rm -rf /var/cache/nftban
    echo "  ✓ Removed: /var/cache/nftban (cache not backed up)"
fi

# Remove runtime (completely, not backed up)
if [[ -d /run/nftban ]]; then
    rm -rf /run/nftban
    echo "  ✓ Removed: /run/nftban (runtime not backed up)"
fi

# Remove any leftover nftban files in /tmp
find /tmp -name "*nftban*" -exec rm -rf {} + 2>/dev/null || true
echo "  ✓ Cleaned /tmp"

# Remove any nftban-related files in /var/tmp
find /var/tmp -name "*nftban*" -exec rm -rf {} + 2>/dev/null || true
echo "  ✓ Cleaned /var/tmp"
REMOTE_SCRIPT

echo -e "${GREEN}✓${NC} Symlinks removed, data backed up and cleaned"
echo ""

# Step 6: Clean up systemd (if any v0.9.5 services exist)
echo -e "${BLUE}[6/7]${NC} Cleaning up systemd services..."

ssh "$TARGET" bash <<'REMOTE_SCRIPT'
set -e

# Check for old nftban systemd services
for service in /etc/systemd/system/nftban*.service /etc/systemd/system/nftban*.timer; do
    if [[ -f "$service" ]]; then
        systemctl stop "$(basename "$service")" 2>/dev/null || true
        systemctl disable "$(basename "$service")" 2>/dev/null || true
        rm -f "$service"
        echo "  ✓ Removed: $service"
    fi
done

# Reload systemd
systemctl daemon-reload
echo "  ✓ Reloaded systemd"
REMOTE_SCRIPT

echo -e "${GREEN}✓${NC} Systemd cleaned"
echo ""

# Step 7: Verification
echo -e "${BLUE}[7/7]${NC} Verification..."

ssh "$TARGET" bash <<'REMOTE_SCRIPT'
set -e

echo ""
echo "Service Status:"
echo "  fail2ban: $(systemctl is-active fail2ban 2>/dev/null || echo 'stopped')"
echo "  nftables: $(systemctl is-active nftables 2>/dev/null || echo 'stopped')"

echo ""
echo "Backups Created:"
[[ -d /etc/nftban_0.9.5 ]] && echo "  ✓ /etc/nftban_0.9.5 ($(du -sh /etc/nftban_0.9.5 2>/dev/null | cut -f1))" || echo "  - No config backup"
[[ -d /opt/nftban_0.9.5 ]] && echo "  ✓ /opt/nftban_0.9.5 ($(du -sh /opt/nftban_0.9.5 2>/dev/null | cut -f1))" || echo "  - No install backup"
[[ -d /var/log/nftban_0.9.5 ]] && echo "  ✓ /var/log/nftban_0.9.5 ($(du -sh /var/log/nftban_0.9.5 2>/dev/null | cut -f1))" || echo "  - No log backup"
[[ -d /var/lib/nftban_0.9.5 ]] && echo "  ✓ /var/lib/nftban_0.9.5 ($(du -sh /var/lib/nftban_0.9.5 2>/dev/null | cut -f1))" || echo "  - No data backup"

echo ""
echo "Removed (should not exist):"
[[ ! -f /usr/local/bin/nftban ]] && echo "  ✓ /usr/local/bin/nftban removed" || echo "  ✗ /usr/local/bin/nftban still exists!"
[[ ! -d /etc/nftban ]] && echo "  ✓ /etc/nftban removed" || echo "  ✗ /etc/nftban still exists!"
[[ ! -d /var/log/nftban ]] && echo "  ✓ /var/log/nftban removed" || echo "  ✗ /var/log/nftban still exists!"
[[ ! -d /var/lib/nftban ]] && echo "  ✓ /var/lib/nftban removed" || echo "  ✗ /var/lib/nftban still exists!"
[[ ! -d /var/cache/nftban ]] && echo "  ✓ /var/cache/nftban removed" || echo "  ✗ /var/cache/nftban still exists!"

echo ""
echo "Nftables Rules:"
nft list ruleset | head -5 || echo "  (empty - expected)"
REMOTE_SCRIPT

echo ""
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
echo -e "${GREEN}✓ CLEANUP COMPLETE${NC}"
echo -e "${BLUE}═══════════════════════════════════════════════${NC}"
echo ""
echo -e "${YELLOW}Server ${SERVER} is now clean and ready for v0.10.0${NC}"
echo ""
echo -e "${BLUE}Backups preserved:${NC}"
echo "  - /etc/nftban_0.9.5 (configuration)"
echo "  - /opt/nftban_0.9.5 (installation)"
echo "  - /var/log/nftban_0.9.5 (logs)"
echo "  - /var/lib/nftban_0.9.5 (data)"
echo ""
echo -e "${BLUE}Next step:${NC}"
echo -e "  ${YELLOW}./deploy-to-lab.sh ${SERVER}${NC}"
echo ""
