# =============================================================================
# NFTBan v0.30.1 - RPM Spec File
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: RPM package specification for Red Hat-based distributions
# Supported: Rocky Linux 9+, AlmaLinux 9+, Fedora 38+
# =============================================================================

# Disable debuginfo package generation (shell scripts don't need debug symbols)
%global debug_package %{nil}

Name:           nftban
Version:        0.30.1
Release:        1%{?dist}
Summary:        Modern nftables firewall with self-healing inventory monitoring

License:        MPL-2.0
URL:            https://nftban.com
Source0:        %{name}-%{version}.tar.gz

# Build requirements
BuildArch:      x86_64 aarch64
BuildRequires:  systemd-rpm-macros

# Runtime requirements - Core dependencies
Requires:       nftables >= 1.0.0
Requires:       systemd >= 250
Requires:       bash >= 5.0
Requires:       bash-completion
Requires:       jq >= 1.6
Requires:       curl
Requires:       python3
Requires:       shadow-utils
Requires:       coreutils
Requires:       gzip
Requires:       tar
Requires:       grep
Requires:       sed
Requires:       gawk
Requires:       findutils
Requires:       util-linux
Requires:       iproute
Requires:       ipset
Requires:       git
Requires:       polkit
Recommends:     fail2ban-server >= 0.11
Recommends:     logrotate

# Conflicts
Conflicts:      firewalld
Conflicts:      iptables-services
Conflicts:      iptables

%description
NFTBan v0.30 is a modern, high-performance firewall management system for Linux
servers using nftables with advanced self-healing and inventory monitoring.

Features include:
- Commit-confirm recovery (prevents lockout)
- Go binaries for 10-60x faster feed processing
- 8 security layers (DDoS, port scan, geo-blocking, threat feeds)
- FHS-compliant with auto-healing health system
- Integration with Fail2Ban for automatic banning
- Stats & metrics with HTML/JSON/CSV reporting
- Advanced inventory system (processes, packages, firewall state)
- Baseline management with drift detection
- Cryptographic verification and signing
- Smart mail adapter (auto-detects best transport)

NOTE: For fail2ban installation on Rocky/AlmaLinux:
1. Enable EPEL: dnf install -y epel-release
2. Enable CRB: crb enable
3. Install: dnf install -y fail2ban-server

fail2ban-server is recommended (not fail2ban) to avoid firewalld conflict.

%prep
%setup -q

%build
# Go binaries are prebuilt and included in source tarball
# No compilation needed

%install
# Install binaries
install -d -m 0755 %{buildroot}/usr/sbin
install -m 0755 src/usr/sbin/nftban %{buildroot}/usr/sbin/
install -m 0755 src/usr/sbin/nftban-complete %{buildroot}/usr/sbin/
install -m 0755 src/usr/sbin/nftban-apply %{buildroot}/usr/sbin/
install -m 0755 src/usr/sbin/nftban-confirm %{buildroot}/usr/sbin/
install -m 0755 src/usr/sbin/nftban-rollback %{buildroot}/usr/sbin/

# Install Go binaries (wrappers + real binaries in .real/)
install -d -m 0755 %{buildroot}/usr/lib/nftban/bin
install -d -m 0755 %{buildroot}/usr/lib/nftban/bin/.real
install -m 0755 src/usr/lib/nftban/bin/nftban-feeds %{buildroot}/usr/lib/nftban/bin/
install -m 0755 src/usr/lib/nftban/bin/nftban-geoip %{buildroot}/usr/lib/nftban/bin/
install -m 0755 src/usr/lib/nftban/bin/.real/nftban-feeds %{buildroot}/usr/lib/nftban/bin/.real/
install -m 0755 src/usr/lib/nftban/bin/.real/nftban-geoip %{buildroot}/usr/lib/nftban/bin/.real/

# Install core and CLI modules
install -d -m 0755 %{buildroot}/usr/lib/nftban/core
install -m 0644 src/usr/lib/nftban/core/*.sh %{buildroot}/usr/lib/nftban/core/

install -d -m 0755 %{buildroot}/usr/lib/nftban/cli
install -m 0644 src/usr/lib/nftban/cli/cmd_*.sh %{buildroot}/usr/lib/nftban/cli/

# Install help system
install -m 0644 src/usr/lib/nftban/nftban_help.sh %{buildroot}/usr/lib/nftban/

# Install cron scripts (run.sh, maintenance.sh)
install -d -m 0755 %{buildroot}/usr/lib/nftban/cron
install -m 0755 src/usr/lib/nftban/cron/*.sh %{buildroot}/usr/lib/nftban/cron/

# Install helpers (autoheal, etc.)
install -d -m 0755 %{buildroot}/usr/lib/nftban/helpers
install -m 0755 src/usr/lib/nftban/helpers/*.sh %{buildroot}/usr/lib/nftban/helpers/

# Install nft runtime
install -m 0644 src/usr/lib/nftban/nft-runtime.nft %{buildroot}/usr/lib/nftban/

# Install shared data
install -d -m 0755 %{buildroot}/usr/share/nftban
cp -a src/usr/share/nftban/* %{buildroot}/usr/share/nftban/

# Install configuration files
install -d -m 0750 %{buildroot}/etc/nftban
install -d -m 0750 %{buildroot}/etc/nftban/conf.d
install -d -m 0750 %{buildroot}/etc/nftban/feeds.d
install -d -m 0750 %{buildroot}/etc/nftban/rules.d
install -d -m 0700 %{buildroot}/etc/nftban/secrets.d

install -m 0640 src/etc/nftban/nftban.conf %{buildroot}/etc/nftban/
install -m 0640 src/etc/nftban/baseline.nft %{buildroot}/etc/nftban/
install -m 0640 src/etc/nftban/conf.d/*.conf %{buildroot}/etc/nftban/conf.d/
install -m 0640 src/etc/nftban/conf.d/health.conf %{buildroot}/etc/nftban/conf.d/
install -m 0640 src/etc/nftban/feeds.d/.gitkeep %{buildroot}/etc/nftban/feeds.d/
install -m 0640 src/etc/nftban/rules.d/.gitkeep %{buildroot}/etc/nftban/rules.d/
install -m 0644 src/etc/nftban/secrets.d/.gitkeep %{buildroot}/etc/nftban/secrets.d/

# Install fail2ban integration files
install -d -m 0755 %{buildroot}/etc/fail2ban/action.d
install -d -m 0755 %{buildroot}/etc/fail2ban/filter.d
install -d -m 0755 %{buildroot}/etc/fail2ban/jail.d

install -m 0644 src/etc/fail2ban/action.d/nftban.conf %{buildroot}/etc/fail2ban/action.d/
install -m 0644 src/etc/fail2ban/filter.d/nftban-*.conf %{buildroot}/etc/fail2ban/filter.d/
install -m 0644 src/etc/fail2ban/jail.d/nftban-*.conf %{buildroot}/etc/fail2ban/jail.d/

# Create FHS directories
install -d -m 0755 %{buildroot}/var/lib/nftban/{state,snapshots,feeds,keyring,backup,reports,metrics,config,geoip}
install -d -m 0755 %{buildroot}/var/cache/nftban/{geoip,tmp}
install -d -m 0750 %{buildroot}/var/log/nftban
install -d -m 0755 %{buildroot}/run/nftban

# Install systemd units
install -d -m 0755 %{buildroot}%{_unitdir}
install -m 0644 src/usr/lib/systemd/system/*.service %{buildroot}%{_unitdir}/
install -m 0644 src/usr/lib/systemd/system/*.timer %{buildroot}%{_unitdir}/

# Install sysusers.d
install -d -m 0755 %{buildroot}%{_sysusersdir}
install -m 0644 packaging/sysusers.d/nftban.conf %{buildroot}%{_sysusersdir}/nftban.conf

# Install tmpfiles.d
install -d -m 0755 %{buildroot}%{_tmpfilesdir}
install -m 0644 packaging/tmpfiles.d/nftban.conf %{buildroot}%{_tmpfilesdir}/nftban.conf

# Install logrotate
install -d -m 0755 %{buildroot}%{_sysconfdir}/logrotate.d
install -m 0644 src/etc/logrotate.d/nftban %{buildroot}%{_sysconfdir}/logrotate.d/nftban

# Install bash completion
install -d -m 0755 %{buildroot}%{_datadir}/bash-completion/completions
install -m 0644 src/usr/share/nftban/completions/nftban.bash \
    %{buildroot}%{_datadir}/bash-completion/completions/nftban

# Install man page
install -d -m 0755 %{buildroot}%{_mandir}/man1
install -m 0644 docs/nftban.1 %{buildroot}%{_mandir}/man1/nftban.1

# Install Polkit rules
install -d -m 0755 %{buildroot}%{_datadir}/polkit-1/rules.d
install -m 0644 packaging/polkit-1/rules.d/60-nftban-cli.rules \
    %{buildroot}%{_datadir}/polkit-1/rules.d/60-nftban-cli.rules

# ============================================================================
# Inventory & Health Monitoring System
# ============================================================================
# NOTE: NFTBAN_AI_TESTING directory removed (was development-only directory)
#       All inventory/health/mail features are integrated in main src/ tree

# Install Polkit rules for nftban-auditors group
install -m 0644 packaging/polkit-1/rules.d/50-nftban-v030.rules \
    %{buildroot}%{_datadir}/polkit-1/rules.d/50-nftban-v030.rules

# Create inventory directories
install -d -m 0755 %{buildroot}/var/lib/nftban/reports/baseline
install -d -m 0770 %{buildroot}/var/lib/nftban/reports/auditors
install -d -m 0700 %{buildroot}/etc/nftban/keys

# Install license files
install -d -m 0755 %{buildroot}/usr/share/licenses/nftban
install -m 0644 licenses/MPL-2.0.txt %{buildroot}/usr/share/licenses/nftban/
install -m 0644 licenses/NFTBAN-Pro-Commercial.md %{buildroot}/usr/share/licenses/nftban/
install -m 0644 licenses/NFTBAN-Docs.txt %{buildroot}/usr/share/licenses/nftban/

# Install project documentation to /usr/share/nftban/docs/
mkdir -p %{buildroot}/usr/share/nftban/docs
install -m 0644 NOTICE.md %{buildroot}/usr/share/nftban/docs/
install -m 0644 TRADEMARK.md %{buildroot}/usr/share/nftban/docs/
install -m 0644 CONTRIBUTING.md %{buildroot}/usr/share/nftban/docs/

%pre
# Create nftban user and nftban-cli group (via sysusers.d)
%sysusers_create_compat packaging/sysusers.d/nftban.conf

%post
# Generate system.conf with UID/GID
NFTBAN_UID=$(id -u nftban)
NFTBAN_GID=$(id -g nftban)
NFTBAN_CLI_GID=$(getent group nftban-cli | cut -d: -f3)
NFTBAN_AUDITORS_GID=$(getent group nftban-auditors | cut -d: -f3)

mkdir -p /var/lib/nftban/config
cat > /var/lib/nftban/config/system.conf <<EOF
# =============================================================================
# NFTBan System Configuration (AUTO-GENERATED - DO NOT EDIT)
# =============================================================================
# Generated: $(date -u +"%Y-%m-%d %H:%M:%%S UTC")
# Hostname: $(hostname)
#
# ⚠️  WARNING: DO NOT EDIT THIS FILE MANUALLY
# This file MUST stay aligned with actual system UID/GID values.
# =============================================================================

NFTBAN_USER="nftban"
NFTBAN_UID=${NFTBAN_UID}
NFTBAN_GROUP="nftban"
NFTBAN_GID=${NFTBAN_GID}
NFTBAN_CLI_GROUP="nftban-cli"
NFTBAN_CLI_GID=${NFTBAN_CLI_GID}
NFTBAN_AUDITORS_GROUP="nftban-auditors"
NFTBAN_AUDITORS_GID=${NFTBAN_AUDITORS_GID}
EOF

chmod 0644 /var/lib/nftban/config/system.conf

# Create log directory (NOT owned by package - preserved on uninstall)
mkdir -p /var/log/nftban
chown nftban:nftban /var/log/nftban
chmod 0750 /var/log/nftban

# Create nftban-auditors group for inventory helpers (if doesn't exist)
groupadd -f nftban-auditors 2>/dev/null || true

# Remove old bash completion file (was in /etc, now in /usr/share)
rm -f /etc/bash_completion.d/nftban 2>/dev/null || true

# Run autoheal to ensure everything is configured correctly
/usr/lib/nftban/helpers/autoheal.sh

# Dedicated directory for nftban-auditors group (explicit ownership)
if [ -d /var/lib/nftban/reports/auditors ]; then
    chown root:nftban-auditors /var/lib/nftban/reports/auditors
    chmod 0770 /var/lib/nftban/reports/auditors
fi

# Auto-detect and whitelist SSH port (LOCKOUT PREVENTION)
SSH_PORT=22
if [ -f "/etc/ssh/sshd_config" ]; then
    DETECTED_PORT=$(grep -E '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    if [ -n "$DETECTED_PORT" ] && [ "$DETECTED_PORT" -eq "$DETECTED_PORT" ] 2>/dev/null; then
        SSH_PORT=$DETECTED_PORT
    fi
fi

mkdir -p /etc/nftban/ports.d
cat > /etc/nftban/ports.d/00-ssh.conf <<SSHEOF
# SSH port auto-added during installation ($(date '+%%Y-%%m-%%d %%H:%%M:%%S'))
# DO NOT DELETE - LOCKOUT RISK!
# Port format: PORT|PROTO where PROTO = T(tcp), U(udp), B(both)
$SSH_PORT|T
SSHEOF
chmod 644 /etc/nftban/ports.d/00-ssh.conf

# Run health check to validate installation
if command -v nftban >/dev/null 2>&1; then
    nftban health check --quiet 2>/dev/null || true
fi

# Reload systemd and enable maintenance timer (ALWAYS enabled)
%systemd_post nftban.timer nftban-maintenance.timer

# Enable and start maintenance timer (runs even if NFTBan disabled)
systemctl enable nftban-maintenance.timer 2>/dev/null || true
systemctl start nftban-maintenance.timer 2>/dev/null || true

# Print installation message
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  NFTBan v0.30.0 Installation Complete!                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "✅ Auto-heal completed - all systems configured"
echo "✅ SSH port $SSH_PORT whitelisted (lockout prevention)"
echo ""
echo "Next steps:"
echo "  1. Install fail2ban (recommended):"
echo "     Rocky/Alma: dnf install -y epel-release && crb enable"
echo "                 dnf install -y fail2ban-server"
echo "     Fedora:     dnf install -y fail2ban"
echo ""
echo "  2. Review config: /etc/nftban/nftban.conf"
echo "  3. Initialize firewall: nftban firewall init"
echo "  4. Enable NFTBan: nftban enable"
echo "  5. Check status: nftban status"
echo ""
echo "⚠️  NOTE: NFTBan is NOT auto-enabled. Run 'nftban enable' when ready."
echo ""
echo "Advanced:"
echo "  • Manual health check: nftban health check"
echo "  • Try inventory: nftban-health --inventory | jq ."
echo "  • Create baseline: nftban-baseline-save"
echo ""
echo "Documentation: /usr/share/nftban/docs/"
echo "Architecture: /usr/share/doc/nftban/architecture/"
echo ""

%preun
# =============================================================================
# NFTBan v0.30.0 - RPM Pre-Uninstall Script
# =============================================================================
# Only run on uninstall (not upgrade)
# $1 = 0 means uninstall, $1 = 1 means upgrade
if [ $1 -eq 0 ]; then
    echo ""
    echo "╔════════════════════════════════════════════════════════════╗"
    echo "║  NFTBan Uninstallation                                     ║"
    echo "╚════════════════════════════════════════════════════════════╝"
    echo ""

    # Ask user if they want to disable NFTBan before removal
    echo "⚠️  NFTBan is being removed from your system."
    echo ""
    echo "Do you want to disable NFTBan services before removal?"
    echo "  • yes - Stop and disable nftban.timer and fail2ban.service"
    echo "  • no  - Keep services running (if you're upgrading)"
    echo ""

    # In non-interactive mode (like automated installs), default to yes
    if [ -t 0 ]; then
        read -p "Disable NFTBan services? (yes/no) [yes]: " DISABLE_SERVICES
        DISABLE_SERVICES=${DISABLE_SERVICES:-yes}
    else
        DISABLE_SERVICES="yes"
        echo "Non-interactive mode: Disabling services automatically"
    fi

    if [ "$DISABLE_SERVICES" = "yes" ]; then
        echo ""
        echo "Disabling NFTBan services..."

        # Stop and disable nftban.timer
        if systemctl is-active --quiet nftban.timer 2>/dev/null; then
            systemctl stop nftban.timer || true
            echo "  ✓ Stopped: nftban.timer"
        fi

        if systemctl is-enabled --quiet nftban.timer 2>/dev/null; then
            systemctl disable nftban.timer || true
            echo "  ✓ Disabled: nftban.timer"
        fi

        # Stop and disable nftban-health.timer (legacy)
        if systemctl is-active --quiet nftban-health.timer 2>/dev/null; then
            systemctl stop nftban-health.timer || true
            echo "  ✓ Stopped: nftban-health.timer (legacy)"
        fi

        # Stop and disable nftban-maintenance.timer
        if systemctl is-active --quiet nftban-maintenance.timer 2>/dev/null; then
            systemctl stop nftban-maintenance.timer || true
            echo "  ✓ Stopped: nftban-maintenance.timer"
        fi

        if systemctl is-enabled --quiet nftban-maintenance.timer 2>/dev/null; then
            systemctl disable nftban-maintenance.timer || true
            echo "  ✓ Disabled: nftban-maintenance.timer"
        fi

        # Stop and disable fail2ban if it was enabled by NFTBan
        if systemctl is-active --quiet fail2ban.service 2>/dev/null; then
            echo ""
            echo "⚠️  fail2ban.service is running."
            echo ""
            if [ -t 0 ]; then
                read -p "Stop fail2ban.service? (yes/no) [no]: " STOP_FAIL2BAN
                STOP_FAIL2BAN=${STOP_FAIL2BAN:-no}
            else
                STOP_FAIL2BAN="no"
                echo "Non-interactive mode: Leaving fail2ban.service running"
            fi

            if [ "$STOP_FAIL2BAN" = "yes" ]; then
                systemctl stop fail2ban.service || true
                systemctl disable fail2ban.service || true
                echo "  ✓ Stopped and disabled: fail2ban.service"
            else
                echo "  ⊘ Leaving fail2ban.service running"
            fi
        fi

        echo ""
        echo "✅ NFTBan services disabled"
    else
        echo ""
        echo "⊘ Keeping services enabled (upgrade mode)"

        # Still stop the timers to prevent them running during package removal
        systemctl stop nftban.timer || true
        systemctl stop nftban-health.timer || true
        systemctl stop nftban-maintenance.timer || true
    fi

    echo ""
    echo "⚠️  NOTE: Firewall rules (nftables) remain active."
    echo "   To remove firewall rules: nftban firewall stop"
    echo ""
    echo "⚠️  NOTE: Configuration files preserved in /etc/nftban/"
    echo "   To remove completely: dnf remove nftban (or yum remove nftban)"
    echo ""
else
    # Upgrade mode - just stop the timer
    %systemd_preun nftban.timer
fi

%postun
%systemd_postun_with_restart nftban.timer

# Only perform cleanup if package is being completely removed (not upgraded)
# $1 = 0 means uninstall, $1 = 1 means upgrade
if [ $1 -eq 0 ]; then
    # Remove nftables table if empty
    nft list table inet nftban >/dev/null 2>&1 && nft delete table inet nftban || true

    # Remove runtime directories
    rm -rf /run/nftban

    # Remove cache (not needed after uninstall)
    rm -rf /var/cache/nftban

    # PRESERVE logs and config (standard RPM practice)
    # - Logs: /var/log/nftban/ - kept for audit/forensics
    # - Config: /etc/nftban/ - kept as .rpmsave files automatically
    # - State: /var/lib/nftban/ - kept for potential reinstall

    # Change ownership to root to avoid unknown UID/GID after user removal
    if [ -d /var/log/nftban ]; then
        chown -R root:root /var/log/nftban
    fi
    if [ -d /var/lib/nftban ]; then
        chown -R root:root /var/lib/nftban
    fi

    # Leave informational note in logs directory
    cat > /var/log/nftban/README.uninstalled <<'EOF'
NFTBan has been uninstalled, but logs have been preserved for audit purposes.

To completely remove all NFTBan data including logs:
  sudo rm -rf /var/log/nftban
  sudo rm -rf /var/lib/nftban
  sudo rm -rf /etc/nftban

Configuration files were saved as /etc/nftban/*.rpmsave
EOF
fi

%files
# Binaries
/usr/sbin/nftban
/usr/sbin/nftban-complete
/usr/sbin/nftban-apply
/usr/sbin/nftban-confirm
/usr/sbin/nftban-rollback
/usr/lib/nftban/bin/nftban-feeds
/usr/lib/nftban/bin/nftban-geoip
/usr/lib/nftban/bin/.real/nftban-feeds
/usr/lib/nftban/bin/.real/nftban-geoip

# Libraries and modules
/usr/lib/nftban/core/*.sh
/usr/lib/nftban/cli/*.sh
/usr/lib/nftban/cron/*.sh
/usr/lib/nftban/helpers/*.sh
/usr/lib/nftban/nft-runtime.nft
/usr/lib/nftban/nftban_help.sh

# Shared data and documentation
/usr/share/nftban/
%doc /usr/share/nftban/docs/NOTICE.md
%doc /usr/share/nftban/docs/TRADEMARK.md
%doc /usr/share/nftban/docs/CONTRIBUTING.md

# License files (FHS: /usr/share/licenses/<package>/)
%license /usr/share/licenses/nftban/MPL-2.0.txt
%license /usr/share/licenses/nftban/NFTBAN-Pro-Commercial.md
%license /usr/share/licenses/nftban/NFTBAN-Docs.txt

# Man page
%{_mandir}/man1/nftban.1*

# Configuration
%dir %attr(0750,root,nftban) /etc/nftban
%dir %attr(0750,root,nftban) /etc/nftban/conf.d
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/nftban.conf
%attr(0640,root,nftban) /etc/nftban/baseline.nft
%attr(0640,root,nftban) /etc/nftban/conf.d/*.conf
%dir %attr(0750,root,nftban) /etc/nftban/feeds.d
%attr(0640,root,nftban) /etc/nftban/feeds.d/.gitkeep
%dir %attr(0750,root,nftban) /etc/nftban/rules.d
%attr(0640,root,nftban) /etc/nftban/rules.d/.gitkeep
%dir %attr(0700,root,root) /etc/nftban/secrets.d
/etc/nftban/secrets.d/.gitkeep

# Fail2ban Integration
/etc/fail2ban/action.d/nftban.conf

# Fail2ban Filters (all with nftban- prefix)
/etc/fail2ban/filter.d/nftban-apache-scan.conf
/etc/fail2ban/filter.d/nftban-apache-wp-login.conf
/etc/fail2ban/filter.d/nftban-apache-xmlrpc.conf
/etc/fail2ban/filter.d/nftban-dovecot-custom.conf
/etc/fail2ban/filter.d/nftban-modsecurity.conf
/etc/fail2ban/filter.d/nftban-persistent-offenders.conf

# Fail2ban Jails (all with nftban- prefix)
/etc/fail2ban/jail.d/nftban-sshd.conf
/etc/fail2ban/jail.d/nftban-exim.conf
/etc/fail2ban/jail.d/nftban-exim-spam.conf
/etc/fail2ban/jail.d/nftban-directadmin.conf
/etc/fail2ban/jail.d/nftban-pure-ftpd.conf
/etc/fail2ban/jail.d/nftban-roundcube.conf
/etc/fail2ban/jail.d/nftban-dovecot.conf
/etc/fail2ban/jail.d/nftban-modsecurity.conf
/etc/fail2ban/jail.d/nftban-apache-xmlrpc.conf
/etc/fail2ban/jail.d/nftban-apache-wp-login.conf
/etc/fail2ban/jail.d/nftban-apache-scan.conf
/etc/fail2ban/jail.d/nftban-persistent-offenders.conf

# Systemd units
%{_unitdir}/*.service
%{_unitdir}/*.timer

# Sysusers and tmpfiles
%{_sysusersdir}/nftban.conf
%{_tmpfilesdir}/nftban.conf

# Logrotate
/etc/logrotate.d/nftban

# Bash completion
/usr/share/bash-completion/completions/nftban

# Polkit rules
/usr/share/polkit-1/rules.d/60-nftban-cli.rules
/usr/share/polkit-1/rules.d/50-nftban-v030.rules

# Runtime directories (created by tmpfiles.d)
%dir %attr(0755,nftban,nftban) /var/lib/nftban
%dir %attr(0750,nftban,nftban) /var/lib/nftban/*
%dir %attr(0755,nftban,nftban) /var/cache/nftban
# Log directory NOT owned by package - preserved on uninstall
# Created in %post, managed by systemd-tmpfiles

# Inventory directories (inventory/health features integrated in main src/ tree)
%dir %attr(0755,nftban,nftban) /var/lib/nftban/reports/baseline
%dir %attr(0770,root,nftban-auditors) /var/lib/nftban/reports/auditors
%dir %attr(0700,root,root) /etc/nftban/keys

# Documentation
%doc README.md CHANGELOG.md

%changelog
* Sun Nov 03 2025 Antonios Voulvoulis <contact@nftban.com> - 0.30.0-1
- Major release: NFTBan v0.30 with self-healing inventory monitoring
- Add advanced inventory system (processes, packages, firewall state)
- Add baseline management with drift detection and cryptographic signing
- Add smart mail adapter (auto-detects v0.10 module, sendmail, msmtp, curl)
- Add 4 inventory helpers (procnet, pkgs, verify, firewall)
- Add 3 health commands (nftban-health, baseline-save, verify-signature)
- Add Polkit rules for nftban-auditors group (non-root execution)
- Add comprehensive documentation (MODULAR_ARCHITECTURE, INTEGRATION_SUMMARY)
- Integrate v0.30 health checks into existing nftban_health.sh
- Smart adaptation: uses existing systems, graceful fallbacks
- Maintain full backward compatibility with v0.10
- All features from v0.10.0 included and enhanced

* Wed Oct 30 2025 Antonios Voulvoulis <contact@nftban.com> - 0.10.0-1
- Complete rewrite for v0.10.0
- Add commit-confirm recovery system
- Add Go binaries for 10-60x faster processing
- Add FHS-compliant structure with auto-healing
- Add stats & metrics system
- Add dynamic UID/GID tracking
- Add Polkit integration for group-based service management
- Add permission hardening system with audit logging
- Improve security with 8 protection layers
