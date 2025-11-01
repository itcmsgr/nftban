# =============================================================================
# NFTBan v0.10.0 - RPM Spec File
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: RPM package specification for Red Hat-based distributions
# Supported: Rocky Linux 9+, AlmaLinux 9+, Fedora 38+
# =============================================================================

# Disable debuginfo package generation (shell scripts don't need debug symbols)
%global debug_package %{nil}

Name:           nftban
Version:        0.10.0
Release:        1%{?dist}
Summary:        Modern nftables firewall management with commit-confirm recovery

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
Requires:       jq >= 1.6
Requires:       curl
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
NFTBan is a modern, high-performance firewall management system for Linux
servers using nftables. Features include:

NOTE: For fail2ban installation on Rocky/AlmaLinux:
1. Enable EPEL: dnf install -y epel-release
2. Enable CRB: crb enable
3. Install: dnf install -y fail2ban-server

fail2ban-server is recommended (not fail2ban) to avoid firewalld conflict.

- Commit-confirm recovery (prevents lockout)
- Go binaries for 10-60x faster feed processing
- 8 security layers (DDoS, port scan, geo-blocking, threat feeds)
- FHS-compliant with auto-healing health system
- Integration with Fail2Ban for automatic banning
- Stats & metrics with HTML/JSON/CSV reporting

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

# Install Go binaries
install -d -m 0755 %{buildroot}/usr/lib/nftban/bin
install -m 0755 src/usr/lib/nftban/bin/nftban-feeds %{buildroot}/usr/lib/nftban/bin/
install -m 0755 src/usr/lib/nftban/bin/nftban-geoip %{buildroot}/usr/lib/nftban/bin/

# Install core and CLI modules
install -d -m 0755 %{buildroot}/usr/lib/nftban/core
install -m 0644 src/usr/lib/nftban/core/*.sh %{buildroot}/usr/lib/nftban/core/

install -d -m 0755 %{buildroot}/usr/lib/nftban/cli
install -m 0644 src/usr/lib/nftban/cli/cmd_*.sh %{buildroot}/usr/lib/nftban/cli/

# Install help system
install -m 0644 src/usr/lib/nftban/nftban_help.sh %{buildroot}/usr/lib/nftban/

# Install cron runner
install -d -m 0755 %{buildroot}/usr/lib/nftban/cron
install -m 0755 src/usr/lib/nftban/cron/run.sh %{buildroot}/usr/lib/nftban/cron/

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

# Install Polkit rules
install -d -m 0755 %{buildroot}%{_datadir}/polkit-1/rules.d
install -m 0644 packaging/polkit-1/rules.d/60-nftban-cli.rules \
    %{buildroot}%{_datadir}/polkit-1/rules.d/60-nftban-cli.rules

%pre
# Create nftban user and nftban-cli group (via sysusers.d)
%sysusers_create_compat packaging/sysusers.d/nftban.conf

%post
# Generate system.conf with UID/GID
NFTBAN_UID=$(id -u nftban)
NFTBAN_GID=$(id -g nftban)
NFTBAN_CLI_GID=$(getent group nftban-cli | cut -d: -f3)

mkdir -p /var/lib/nftban/config
cat > /var/lib/nftban/config/system.conf <<EOF
# =============================================================================
# NFTBan System Configuration (AUTO-GENERATED - DO NOT EDIT)
# =============================================================================
# Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
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
EOF

chmod 0644 /var/lib/nftban/config/system.conf

# Reload systemd
%systemd_post nftban.timer nftban-health.timer nftban-permissions-audit.timer

# Print installation message
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║  NFTBan v0.10.0 Installation Complete!                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Next steps:"
echo "  1. Install fail2ban (recommended):"
echo "     Rocky/Alma: dnf install -y epel-release && crb enable"
echo "                 dnf install -y fail2ban-server"
echo "     Fedora:     dnf install -y fail2ban"
echo ""
echo "  2. Enable services:"
echo "     systemctl enable --now nftables"
echo "     systemctl enable --now fail2ban"
echo ""
echo "  3. Enable NFTBan health timer (includes auto-heal):"
echo "     systemctl enable --now nftban-health.timer"
echo ""
echo "  4. Check health: nftban health check"
echo ""
echo "Documentation: /usr/share/nftban/docs/"
echo ""

%preun
%systemd_preun nftban.timer nftban-health.timer

%postun
%systemd_postun_with_restart nftban.timer nftban-health.timer

# Only remove nftables config if package is being completely removed (not upgraded)
if [ $1 -eq 0 ]; then
    # Remove nftables table if empty
    nft list table inet nftban >/dev/null 2>&1 && nft delete table inet nftban || true
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

# Libraries and modules
/usr/lib/nftban/core/*.sh
/usr/lib/nftban/cli/*.sh
/usr/lib/nftban/cron/run.sh
/usr/lib/nftban/nft-runtime.nft
/usr/lib/nftban/nftban_help.sh

# Shared data and documentation
/usr/share/nftban/
%doc /usr/share/nftban/docs/LICENSE
%doc /usr/share/nftban/docs/NOTICE.md
%doc /usr/share/nftban/docs/TRADEMARK.md
%doc /usr/share/nftban/docs/CONTRIBUTING.md
%doc /usr/share/nftban/docs/README-License-Summary.md

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

# Runtime directories (created by tmpfiles.d)
%dir %attr(0755,nftban,nftban) /var/lib/nftban
%dir %attr(0750,nftban,nftban) /var/lib/nftban/*
%dir %attr(0755,nftban,nftban) /var/cache/nftban
%dir %attr(0750,nftban,nftban) /var/log/nftban

# Documentation
%doc README.md CHANGELOG.md
%license LICENSE

%changelog
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
