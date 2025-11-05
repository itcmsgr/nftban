#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - System Uninstaller
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Remove NFTBan from system
# Usage: sudo ./uninstall.sh [--purge]

set -Eeuo pipefail

PURGE="${1:-}"

echo "Uninstalling NFTBan v0.10.0..."

# =============================================================================
# 1. STOP AND DISABLE SERVICES
# =============================================================================
if command -v systemctl >/dev/null 2>&1; then
    echo "Stopping systemd services..."
    systemctl disable --now nftban.timer 2>/dev/null || true
    systemctl disable --now nftban.service 2>/dev/null || true
    echo "✓ Services stopped"
fi

# =============================================================================
# 2. REMOVE CODE
# =============================================================================
echo "Removing files..."

# Binaries
rm -f /usr/sbin/nftban

# Libraries
rm -rf /usr/lib/nftban

# Shared data
rm -rf /usr/share/nftban

# License files (FHS: /usr/share/licenses/<package>/)
rm -rf /usr/share/licenses/nftban

# Systemd units
rm -f /usr/lib/systemd/system/nftban-*.service
rm -f /usr/lib/systemd/system/nftban-*.timer
rm -f /usr/lib/systemd/system/nftban.service
rm -f /usr/lib/systemd/system/nftban.timer

# Sysusers/tmpfiles
rm -f /usr/lib/sysusers.d/nftban.conf
rm -f /usr/lib/tmpfiles.d/nftban.conf

# Cron
rm -f /etc/cron.d/nftban

# Logrotate
rm -f /etc/logrotate.d/nftban

# Completions
rm -f /usr/share/bash-completion/completions/nftban
rm -f /usr/share/zsh/site-functions/_nftban
rm -f /usr/share/fish/vendor_completions.d/nftban.fish

echo "✓ Code removed"

# =============================================================================
# 3. PURGE DATA (if --purge)
# =============================================================================
if [[ "$PURGE" == "--purge" ]]; then
    echo "Purging all data..."

    # Configuration
    rm -rf /etc/nftban

    # State data
    rm -rf /var/lib/nftban

    # Cache
    rm -rf /var/cache/nftban

    # Logs
    rm -rf /var/log/nftban

    # Runtime
    rm -rf /run/nftban

    # Remove user and groups
    userdel nftban 2>/dev/null || true
    groupdel nftban-cli 2>/dev/null || true
    groupdel nftban-auditors 2>/dev/null || true

    echo "✓ All data purged"
else
    echo "✓ Configuration and data preserved"
    echo "  (Use --purge to remove everything)"
fi

# =============================================================================
# 4. RELOAD SYSTEMD (if present)
# =============================================================================
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload
    echo "✓ Systemd reloaded"
fi

# =============================================================================
# UNINSTALLATION COMPLETE
# =============================================================================
echo ""
if [[ "$PURGE" == "--purge" ]]; then
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  NFTBan v0.10.0 Completely Removed (Purged)               ║"
    echo "╚════════════════════════════════════════════════════════════╝"
else
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  NFTBan v0.10.0 Uninstalled (Data Preserved)              ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Preserved:"
    echo "  - Configuration: /etc/nftban/"
    echo "  - State data: /var/lib/nftban/"
    echo "  - Logs: /var/log/nftban/"
    echo ""
    echo "To remove everything: ./uninstall.sh --purge"
fi
echo ""
