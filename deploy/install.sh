#!/usr/bin/env bash
# NFTBan v0.10.0 - Deployment Script
# Installs systemd units, tmpfiles, sysusers, logrotate, and auditd configs

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Files from repo root
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "═══════════════════════════════════════════════════════════"
echo "NFTBan v0.10.0 - Deployment Script"
echo "═══════════════════════════════════════════════════════════"
echo

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run as root" >&2
   exit 1
fi

echo "[1/8] Installing systemd units..."
install -D -m 0644 "$ROOT/deploy/systemd/nftban.service"            /etc/systemd/system/nftban.service
install -D -m 0644 "$ROOT/deploy/systemd/nftban.path"               /etc/systemd/system/nftban.path
install -D -m 0644 "$ROOT/deploy/systemd/nftban-geoip-update.service" /etc/systemd/system/nftban-geoip-update.service
install -D -m 0644 "$ROOT/deploy/systemd/nftban-geoip-update.timer"   /etc/systemd/system/nftban-geoip-update.timer
install -D -m 0644 "$ROOT/deploy/systemd/nftban-backup.service"     /etc/systemd/system/nftban-backup.service
install -D -m 0644 "$ROOT/deploy/systemd/nftban-backup.timer"       /etc/systemd/system/nftban-backup.timer
echo "    ✓ Installed 6 systemd units"

echo "[2/8] Installing tmpfiles.d config..."
install -D -m 0644 "$ROOT/deploy/tmpfiles.d/nftban.conf"            /etc/tmpfiles.d/nftban.conf
echo "    ✓ Installed tmpfiles.d/nftban.conf"

echo "[3/8] Installing sysusers.d config..."
install -D -m 0644 "$ROOT/deploy/sysusers.d/nftban.conf"            /etc/sysusers.d/nftban.conf
echo "    ✓ Installed sysusers.d/nftban.conf"

echo "[4/8] Installing logrotate config..."
install -D -m 0644 "$ROOT/deploy/logrotate.d/nftban"                /etc/logrotate.d/nftban
echo "    ✓ Installed logrotate.d/nftban"

echo "[5/8] Installing auditd rules..."
install -D -m 0644 "$ROOT/deploy/auditd/nftban_whitelist.rules"     /etc/audit/rules.d/nftban_whitelist.rules
echo "    ✓ Installed audit/rules.d/nftban_whitelist.rules"

echo "[6/8] Creating system directories..."

# Apply sysusers first to create nftban user
systemd-sysusers /etc/sysusers.d/nftban.conf 2>/dev/null || true

# Source FHS specification (single source of truth)
if [[ -f "$ROOT/src/usr/lib/nftban/core/nftban_fhs_spec.sh" ]]; then
    source "$ROOT/src/usr/lib/nftban/core/nftban_fhs_spec.sh"
    nftban_fhs_load_spec

    # Create all FHS directories
    for dir in "${!NFTBAN_FHS_DIRECTORIES[@]}"; do
        IFS='|' read -r perms owner group _ <<< "${NFTBAN_FHS_DIRECTORIES[$dir]}"
        install -d -m "$perms" -o "$owner" -g "$group" "$dir" 2>/dev/null || true
    done

    # Create additional config subdirectories
    install -d -m 0750 -o root -g nftban /etc/nftban/whitelist.d 2>/dev/null || true
    install -d -m 0750 -o root -g nftban /etc/nftban/blacklist.d 2>/dev/null || true
    install -d -m 0750 -o root -g nftban /etc/nftban/feeds.d 2>/dev/null || true
    install -d -m 0750 -o root -g nftban /etc/nftban/geoip.d 2>/dev/null || true
    install -d -m 0750 -o root -g nftban /etc/nftban/ports.d 2>/dev/null || true

    # Create legacy compiled directory (deprecated, but keep for compatibility)
    install -d -m 0750 -o nftban -g nftban /var/lib/nftban/compiled 2>/dev/null || true

    # Create backups directory (not in FHS spec, system-specific)
    install -d -m 0750 -o root -g root /var/backups/nftban 2>/dev/null || true

    echo "    ✓ Created directories using FHS specification"
else
    # Fallback to hardcoded values if FHS spec not found
    echo "    ⚠️  FHS spec not found, using hardcoded values"
    install -d -m 0750 -o root -g nftban /etc/nftban 2>/dev/null || true
    install -d -m 0750 -o root -g nftban /etc/nftban/conf.d 2>/dev/null || true
    install -d -m 0750 -o root -g nftban /etc/nftban/whitelist.d 2>/dev/null || true
    install -d -m 0750 -o root -g nftban /etc/nftban/blacklist.d 2>/dev/null || true
    install -d -m 0750 -o root -g nftban /etc/nftban/feeds.d 2>/dev/null || true
    install -d -m 0750 -o root -g nftban /etc/nftban/geoip.d 2>/dev/null || true
    install -d -m 0750 -o root -g nftban /etc/nftban/ports.d 2>/dev/null || true
    install -d -m 0755 -o nftban -g nftban /var/lib/nftban 2>/dev/null || true
    install -d -m 0750 -o nftban -g nftban /var/lib/nftban/compiled 2>/dev/null || true
    install -d -m 0750 -o nftban -g nftban /var/log/nftban 2>/dev/null || true
    install -d -m 0755 -o nftban -g nftban /run/nftban 2>/dev/null || true
    install -d -m 0750 -o root -g root /var/backups/nftban 2>/dev/null || true
    echo "    ✓ Created directories with correct permissions"
fi

echo "[7/8] Applying tmpfiles configuration..."
systemd-tmpfiles --create /etc/tmpfiles.d/nftban.conf
echo "    ✓ Applied tmpfiles.d config"

echo "[8/8] Reloading systemd and enabling services..."
systemctl daemon-reload
systemctl enable --now nftban.path
systemctl enable --now nftban-geoip-update.timer
systemctl enable --now nftban-backup.timer
echo "    ✓ Enabled nftban.path (config watcher)"
echo "    ✓ Enabled nftban-geoip-update.timer (weekly)"
echo "    ✓ Enabled nftban-backup.timer (daily)"

echo
echo "═══════════════════════════════════════════════════════════"
echo "✅ NFTBan v0.10.0 deployment complete!"
echo "═══════════════════════════════════════════════════════════"
echo
echo "Next steps:"
echo "  1. Configure /etc/nftban/ files (whitelist.d, blacklist.d, etc.)"
echo "  2. Test atomic reload: systemctl start nftban.service"
echo "  3. Monitor logs: journalctl -u nftban.service -f"
echo "  4. Check status: systemctl status nftban.path"
echo
echo "Security hardening:"
echo "  • Whitelist directory is root-only write"
echo "  • auditd monitoring enabled (view: ausearch -k nftban_whitelist)"
echo "  • Logrotate configured (14 days retention)"
echo
