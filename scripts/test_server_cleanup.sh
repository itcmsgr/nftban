#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Test Server Cleanup Script
# =============================================================================
# meta:name="test_server_cleanup"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Removes NFTBan completely from test server for clean reinstall"
# meta:inventory.files=""
# meta:inventory.binaries="systemctl,nft,userdel,groupdel"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="root"
# =============================================================================
# Usage: ssh root@server 'bash -s' < scripts/test_server_cleanup.sh
#        OR: ./scripts/test_server_cleanup.sh (run on server directly)
# =============================================================================

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()  { echo -e "${GREEN}[CLEANUP]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; }

echo "=============================================="
echo "NFTBan Test Server Cleanup"
echo "=============================================="
echo ""

# Check root
if [[ $EUID -ne 0 ]]; then
    err "Must run as root"
    exit 1
fi

# Stop services
log "Stopping services..."
systemctl stop nftban-ui 2>/dev/null || true
systemctl stop nftban-health.timer 2>/dev/null || true
systemctl stop nftban 2>/dev/null || true
systemctl disable nftban-ui 2>/dev/null || true
systemctl disable nftban-health.timer 2>/dev/null || true
systemctl disable nftban 2>/dev/null || true

# Remove nftables rules
log "Removing nftables rules..."
nft delete table ip nftban 2>/dev/null || true
nft delete table ip6 nftban 2>/dev/null || true

# Remove binaries
log "Removing binaries..."
rm -f /usr/sbin/nftban
rm -f /usr/sbin/nftban-ui
rm -f /usr/sbin/nftban-core
rm -f /usr/libexec/nftban-ui-auth
rm -rf /usr/lib/nftban/bin/

# Remove libraries
log "Removing libraries..."
rm -rf /usr/lib/nftban/

# Remove configs (backup first)
log "Backing up and removing configs..."
if [[ -d /etc/nftban ]]; then
    cp -r /etc/nftban "/etc/nftban.backup.$(date +%Y%m%d_%H%M%S)" 2>/dev/null || true
    rm -rf /etc/nftban
fi

# Remove data directories
log "Removing data directories..."
rm -rf /var/lib/nftban
rm -rf /var/log/nftban
rm -rf /var/cache/nftban
rm -rf /run/nftban

# Remove systemd files
log "Removing systemd files..."
rm -f /etc/systemd/system/nftban*.service
rm -f /etc/systemd/system/nftban*.timer
rm -f /usr/lib/systemd/system/nftban*.service
rm -f /usr/lib/systemd/system/nftban*.timer
rm -f /etc/tmpfiles.d/nftban.conf
rm -f /usr/lib/tmpfiles.d/nftban.conf

# Remove polkit
log "Removing polkit rules..."
rm -f /usr/share/polkit-1/actions/com.nftban.*
rm -f /usr/share/polkit-1/rules.d/*nftban*
rm -f /etc/polkit-1/rules.d/*nftban*

# Remove bash completion
log "Removing bash completion..."
rm -f /usr/share/bash-completion/completions/nftban
rm -f /etc/bash_completion.d/nftban

# Remove user/group (optional - comment out if you want to keep)
log "Removing nftban user/group..."
userdel nftban 2>/dev/null || true
groupdel nftban 2>/dev/null || true
groupdel nftban-auditor 2>/dev/null || true
groupdel nftban-auditors 2>/dev/null || true  # legacy group name
# Legacy cleanup (v0.x had nftban-web group)
groupdel nftban-web 2>/dev/null || true

# Reload systemd
log "Reloading systemd..."
systemctl daemon-reload

# Remove test repo if exists
log "Removing test repo..."
rm -rf /root/nftban-dev
rm -rf /root/nftban-v1.0-dev
rm -rf /tmp/nftban*

echo ""
echo "=============================================="
echo "Cleanup complete!"
echo "=============================================="
echo ""
echo "Server is clean. Ready for fresh install test."
echo ""
echo "To test install:"
echo "  git clone <repo> /path/to/nftban"
echo "  cd /path/to/nftban"
echo "  ./install.sh cli    # or: ./install.sh all"
echo ""
