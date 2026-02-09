# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2025 NFTBan Development Team

Name:           nftban
Version:        1.12.0
Release:        1%{?dist}
Summary:        NFTBAN - Next-generation Linux firewall using nftables

License:        MPL-2.0
URL:            https://nftban.com
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  bash
BuildRequires:  systemd-rpm-macros

# Runtime requirements - Core dependencies
Requires:       nftables >= 1.0.0
Requires:       systemd >= 250
Requires:       bash >= 5.0
Requires:       bash-completion
Requires:       jq >= 1.6
Requires:       curl
Requires:       wget

# NOTE: yq is installed via pip in %post since not all distros have it packaged
# See %post section for: pip3 install yq
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
Requires:       socat
Requires:       git
Requires:       polkit
Recommends:     logrotate

%description
NFTBAN is an enterprise-grade firewall management engine built on Linux nftables.
It replaces legacy firewall scripts with a modern architecture featuring atomic
rule updates, strict privilege separation via Polkit, and AI-assisted threat
intelligence.

Named for NFTables BAN actions, NFTBAN provides deterministic, high-performance
packet filtering at the kernel level. Moving beyond traditional iptables-based
tools, it delivers a resilient, self-healing network defense layer.

Features: Atomic updates, Polkit security, threat intelligence feeds, GeoIP
blocking, port scan/DDoS detection, hosting panel integration, and full
observability via Prometheus/Grafana.

%prep
%setup -q

%install
# Installation handled by install.sh during build

%pretrans -p <lua>
-- ==========================================================================
-- PRETRANS: Remove immutable flag before upgrade (runs FIRST, before old pkg)
-- ==========================================================================
-- Required when upgrading from old versions that don't have chattr -i in %preun.
-- The nft_schema.sh file is protected with chattr +i for security.
-- Without this, RPM fails: "cpio: rename failed - No data available"
local schema_file = "/usr/lib/nftban/lib/nft_schema.sh"
local f = io.open(schema_file, "r")
if f then
    f:close()
    -- Try multiple paths for chattr (PATH may be minimal during RPM transactions)
    os.execute("/usr/bin/chattr -i " .. schema_file .. " 2>/dev/null")
    os.execute("/bin/chattr -i " .. schema_file .. " 2>/dev/null")
    os.execute("chattr -i " .. schema_file .. " 2>/dev/null")
    -- Also remove from entire lib dir in case other files are immutable
    os.execute("/usr/bin/chattr -i -R /usr/lib/nftban 2>/dev/null")
end

%pre
# Pre-install: Create user and group via systemd-sysusers
# Uses /usr/lib/sysusers.d/nftban.conf (generated from build/fhs-spec.yaml)
#
# NFTBan 3-Group Security Model:
#   nftban:         Admin/Operator (full access)
#   nftban-auditor: Read-only (reports, logs)
#   nftban-panel:   Panel Operator (ban/unban, NO config)
#
if [ -f /usr/lib/sysusers.d/nftban.conf ]; then
    systemd-sysusers /usr/lib/sysusers.d/nftban.conf 2>/dev/null || {
        # Fallback for systems without systemd-sysusers
        getent group nftban >/dev/null || groupadd -r nftban
        getent group nftban-auditor >/dev/null || groupadd -r nftban-auditor
        getent group nftban-panel >/dev/null || groupadd -r nftban-panel
        getent group suricata >/dev/null || groupadd -r suricata
        getent passwd nftban >/dev/null || \
            useradd -r -g nftban -G nftban-auditor -d /var/lib/nftban \
            -s /sbin/nologin -c "NFTBan Service Account" nftban
    }
else
    # Fallback if sysusers.d file not yet installed
    getent group nftban >/dev/null || groupadd -r nftban
    getent group nftban-auditor >/dev/null || groupadd -r nftban-auditor
    getent group nftban-panel >/dev/null || groupadd -r nftban-panel
    getent group suricata >/dev/null || groupadd -r suricata
    getent passwd nftban >/dev/null || \
        useradd -r -g nftban -G nftban-auditor -d /var/lib/nftban \
        -s /sbin/nologin -c "NFTBan Service Account" nftban
fi
exit 0

%post
# Post-install: Configure and enable services
#
# NOTE: Directory creation is handled by:
#   - systemd-tmpfiles (runtime directories via /usr/lib/tmpfiles.d/nftban.conf)
#   - RPM %files section (package directories)

# ==========================================================================
# STEP 0: Install yq for documentation generation
# ==========================================================================
echo "Installing yq (YAML processor) for documentation generation..."
if ! command -v yq &>/dev/null; then
    pip3 install yq >/dev/null 2>&1 || {
        echo "WARNING: Failed to install yq - documentation generation may not work"
        echo "  Manual install: pip3 install yq"
    }
    if command -v yq &>/dev/null; then
        echo "yq installed successfully"
    fi
else
    echo "yq already installed"
fi

# ==========================================================================
# DIRECTADMIN PANEL: Add nftban to mysyslog group for logger access
# ==========================================================================
# DirectAdmin uses 'mysyslog' group for /dev/log socket permissions.
# Without this, nftban-login-monitor fails with:
#   logger: socket /dev/log: Permission denied
# Ref: /run/systemd/journal/dev-log is owned by root:mysyslog (srw-rw----)
if [ -d /usr/local/directadmin ]; then
    if getent group mysyslog >/dev/null 2>&1; then
        if ! id -nG nftban 2>/dev/null | grep -qw mysyslog; then
            usermod -a -G mysyslog nftban 2>/dev/null && \
                echo "DirectAdmin: Added nftban to mysyslog group (syslog access)"
        fi
    fi
fi

# ==========================================================================
# STEP 1: Check for Conflicting Firewalls
# ==========================================================================
echo "Checking for conflicting firewalls..."

CONFLICTS_FOUND=0
FIREWALL_ISSUES=""

# Check firewalld
if command -v firewall-cmd >/dev/null 2>&1; then
    if systemctl is-active --quiet firewalld 2>/dev/null; then
        FIREWALL_ISSUES="${FIREWALL_ISSUES}firewalld (ACTIVE) "
        CONFLICTS_FOUND=1
    elif systemctl is-enabled --quiet firewalld 2>/dev/null; then
        FIREWALL_ISSUES="${FIREWALL_ISSUES}firewalld (ENABLED) "
        CONFLICTS_FOUND=1
    fi
fi

# Check iptables service
if systemctl is-active --quiet iptables 2>/dev/null || \
   systemctl is-active --quiet iptables.service 2>/dev/null || \
   systemctl is-active --quiet ip6tables.service 2>/dev/null; then
    FIREWALL_ISSUES="${FIREWALL_ISSUES}iptables-services (ACTIVE) "
    CONFLICTS_FOUND=1
fi

# Check ufw
if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        FIREWALL_ISSUES="${FIREWALL_ISSUES}ufw (ACTIVE) "
        CONFLICTS_FOUND=1
    fi
fi

if [ $CONFLICTS_FOUND -eq 1 ]; then
    echo ""
    echo "=========================================="
    echo " ERROR: CONFLICTING FIREWALL(S) DETECTED!"
    echo "=========================================="
    echo ""
    echo "NFTBan cannot coexist with: ${FIREWALL_ISSUES}"
    echo ""
    echo "These firewalls will cause:"
    echo "  - Duplicate filtering rules"
    echo "  - Unpredictable blocking behavior"
    echo "  - NFTBan blocks may not work"
    echo ""
    echo "Please disable conflicting firewalls:"
    echo ""

    if echo "$FIREWALL_ISSUES" | grep -q "firewalld"; then
        echo "  systemctl stop firewalld"
        echo "  systemctl disable firewalld"
        echo ""
    fi

    if echo "$FIREWALL_ISSUES" | grep -q "iptables"; then
        echo "  systemctl stop iptables"
        echo "  systemctl disable iptables"
        echo "  systemctl stop ip6tables"
        echo "  systemctl disable ip6tables"
        echo ""
    fi

    if echo "$FIREWALL_ISSUES" | grep -q "ufw"; then
        echo "  ufw disable"
        echo "  systemctl stop ufw"
        echo "  systemctl disable ufw"
        echo ""
    fi

    echo "Then re-install: dnf reinstall nftban"
    echo ""
    exit 1
fi

echo "  No conflicting firewalls detected"

# ==========================================================================
# STEP 0.5: Ensure EPEL and CRB Repositories (RHEL Family)
# ==========================================================================
echo "Ensuring required repositories..."

# Detect RHEL version
if [ -f /etc/os-release ]; then
    . /etc/os-release
    VERSION_ID_MAJOR="${VERSION_ID%%.*}"
fi

# Determine CRB/PowerTools name based on version
if [ "${VERSION_ID_MAJOR}" -ge 9 ]; then
    CRB_NAME="crb"
else
    CRB_NAME="powertools"
fi

# Install EPEL if not present
if ! rpm -qa | grep -q epel-release; then
    echo "  Installing EPEL repository..."
    dnf install -y epel-release 2>/dev/null || yum install -y epel-release 2>/dev/null || true
    echo "  EPEL repository installed"
else
    echo "  EPEL repository already installed"
fi

# Enable CRB/PowerTools repository
if command -v dnf &>/dev/null; then
    if ! dnf repolist enabled 2>/dev/null | grep -q "${CRB_NAME}"; then
        echo "  Enabling ${CRB_NAME} repository..."
        dnf config-manager --set-enabled "${CRB_NAME}" 2>/dev/null || true
        echo "  ${CRB_NAME} repository enabled"
    else
        echo "  ${CRB_NAME} repository already enabled"
    fi
elif command -v yum &>/dev/null; then
    if ! yum repolist enabled 2>/dev/null | grep -q "${CRB_NAME}"; then
        echo "  Enabling ${CRB_NAME} repository..."
        yum-config-manager --enable "${CRB_NAME}" 2>/dev/null || true
        echo "  ${CRB_NAME} repository enabled"
    else
        echo "  ${CRB_NAME} repository already enabled"
    fi
fi

# Disable conflicting testing repositories
for repo in epel-testing epel-modular epel-next epel-next-testing; do
    if dnf repolist enabled 2>/dev/null | grep -q "$repo" || yum repolist enabled 2>/dev/null | grep -q "$repo"; then
        dnf config-manager --set-disabled "$repo" 2>/dev/null || yum-config-manager --disable "$repo" 2>/dev/null || true
    fi
done

echo "  Repository setup complete"

# ==========================================================================
# STEP 2: Create runtime directories via systemd-tmpfiles
# ==========================================================================
# Uses /usr/lib/tmpfiles.d/nftban.conf (generated from build/fhs-spec.yaml)
if [ -f /usr/lib/tmpfiles.d/nftban.conf ]; then
    echo "Creating runtime directories..."
    systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf 2>/dev/null || {
        echo "Warning: systemd-tmpfiles failed, directories may need manual creation"
    }
fi

# ==========================================================================
# STEP 2b: Set file permissions via FHS spec (single source of truth)
# ==========================================================================
# Uses generated script from build/fhs-spec.yaml
if [ -f %{_libdir}/nftban/setup/fhs-permissions.sh ]; then
    echo "Setting file permissions via FHS spec..."
    # shellcheck source=/dev/null
    source %{_libdir}/nftban/setup/fhs-permissions.sh
    nftban_install_set_file_permissions
    echo "  File permissions set via FHS spec"
else
    echo "Warning: FHS permissions script not found"
fi

# Auto-detect SSH port
SSH_PORT="22"
if [ -f /etc/ssh/sshd_config ]; then
    DETECTED=$(grep -E "^Port[[:space:]]+" /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1)
    if [ -n "$DETECTED" ]; then
        SSH_PORT="$DETECTED"
    fi
fi

# Create SSH port whitelist if not exists
if [ ! -f /etc/nftban/ports.d/00-ssh.conf ]; then
    cat > /etc/nftban/ports.d/00-ssh.conf << EOF
# Auto-generated SSH port whitelist
# Created by: NFTBan RPM package
[ssh]
port=$SSH_PORT
protocol=tcp
direction=input
EOF
    chmod 644 /etc/nftban/ports.d/00-ssh.conf
    chown root:nftban /etc/nftban/ports.d/00-ssh.conf 2>/dev/null || true
    echo "SSH port whitelisted: $SSH_PORT/tcp"
fi

# Auto-whitelist system IP (prevents lockout)
SYSTEM_IP=$(ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
if [ -z "$SYSTEM_IP" ]; then
    SYSTEM_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
fi
if [ -n "$SYSTEM_IP" ]; then
    if [ ! -f /etc/nftban/whitelist.d/00-system-ip.conf ]; then
        cat > /etc/nftban/whitelist.d/00-system-ip.conf << EOF
# Auto-generated system IP whitelist
# Created by: NFTBan RPM package
# Purpose: Prevent lockout from this server
$SYSTEM_IP
EOF
        chmod 644 /etc/nftban/whitelist.d/00-system-ip.conf
        chown root:nftban /etc/nftban/whitelist.d/00-system-ip.conf 2>/dev/null || true
        echo "System IP whitelisted: $SYSTEM_IP"
    fi
fi

systemctl daemon-reload >/dev/null 2>&1 || true

# ==========================================================================
# AUTO-ENABLE DEFAULT FEATURES (aligned with install.sh)
# ==========================================================================

# 1. Download FREE GeoIP database (DB-IP)
GEOIP_DIR="/var/lib/nftban/geoip"
GEOIP_FILE="${GEOIP_DIR}/dbip-country-lite.mmdb"
GEOIP_URL="https://download.db-ip.com/free/dbip-country-lite-$(date +%Y-%m).mmdb.gz"

mkdir -p "$GEOIP_DIR"
chown nftban:nftban "$GEOIP_DIR" 2>/dev/null || true

if [ ! -f "$GEOIP_FILE" ]; then
    echo "Downloading FREE GeoIP database..."
    if curl -fsSL "$GEOIP_URL" -o "${GEOIP_FILE}.gz" 2>/dev/null; then
        gunzip -f "${GEOIP_FILE}.gz" 2>/dev/null || true
        chown nftban:nftban "$GEOIP_FILE" 2>/dev/null || true
        chmod 644 "$GEOIP_FILE"
        echo "GeoIP database downloaded"
    else
        echo "GeoIP download failed (will retry on first use)"
    fi
fi

# 2. Enable Login Monitoring
if [ -f /etc/nftban/nftban.conf ]; then
    sed -i 's/^NFTBAN_LOGIN_ALERT_ENABLED=.*/NFTBAN_LOGIN_ALERT_ENABLED="true"/' /etc/nftban/nftban.conf 2>/dev/null || true
    sed -i 's/^NFTBAN_LOGIN_ALERT_SSH=.*/NFTBAN_LOGIN_ALERT_SSH="true"/' /etc/nftban/nftban.conf 2>/dev/null || true
fi
systemctl enable nftban-login-monitor.service >/dev/null 2>&1 || true
systemctl start nftban-login-monitor.service >/dev/null 2>&1 || true

# 3. Enable GeoIP Blocking
if [ -f /etc/nftban/nftban.conf ]; then
    sed -i 's/^NFTBAN_GEOIP_ENABLED=.*/NFTBAN_GEOIP_ENABLED="true"/' /etc/nftban/nftban.conf 2>/dev/null || true
fi

# 4. Enable core timers (health, maintenance)
for timer in nftban-health.timer nftban-maintenance.timer; do
    systemctl enable "$timer" >/dev/null 2>&1 || true
    systemctl start "$timer" >/dev/null 2>&1 || true
done

echo ""
echo "NFTBan installed successfully!"
echo ""
echo "Auto-enabled:"
echo "  - Login monitoring (SSH alerts)"
echo "  - GeoIP blocking"
echo "  - Core timers (health, maintenance)"
echo ""
echo "Enable optional features:"
echo "  nftban feeds enable      # Threat intel feeds"
echo "  nftban portscan enable   # Port scan detection"
echo "  nftban ddos enable       # DDoS protection"
echo "  nftban gui enable        # Web GUI"
echo "  nftban metrics enable    # Metrics collection"

# ==========================================================================
# SECURITY: Protect nft_schema.sh from modification (P0 CRITICAL)
# ==========================================================================
# Make nft_schema.sh immutable to prevent command injection attacks
# This file defines the canonical nftables schema used by all components
if [ -f %{_libdir}/nftban/lib/nft_schema.sh ]; then
    chmod 444 %{_libdir}/nftban/lib/nft_schema.sh
    chattr +i %{_libdir}/nftban/lib/nft_schema.sh 2>/dev/null || true
    echo "Security: nft_schema.sh protected (immutable)"
fi

%preun
# Pre-uninstall: Stop all services

# ==========================================================================
# SECURITY: Remove immutable flag before uninstall/upgrade
# ==========================================================================
# Remove immutable flag to allow RPM to replace/remove the file
# This runs on BOTH uninstall ($1=0) and upgrade ($1=1)
if [ -f %{_libdir}/nftban/lib/nft_schema.sh ]; then
    chattr -i %{_libdir}/nftban/lib/nft_schema.sh 2>/dev/null || true
fi

if [ $1 -eq 0 ]; then
    echo "Stopping NFTBan services..."

    # Stop all timers (complete list from install.sh)
    for timer in nftban-health.timer nftban-maintenance.timer \
                 nftban-watchdog.timer nftban-snapshot.timer \
                 nftban-rollback.timer nftban-unified-exporter.timer \
                 nftban-suricata-update.timer nftban-queue.timer \
                 nftban-core-geoip.timer nftban-core-feeds.timer; do
        systemctl stop "$timer" >/dev/null 2>&1 || true
        systemctl disable "$timer" >/dev/null 2>&1 || true
    done

    # Stop login monitor
    systemctl stop nftban-login-monitor.service >/dev/null 2>&1 || true
    systemctl disable nftban-login-monitor.service >/dev/null 2>&1 || true

    # Stop core services
    for svc in nftban-ui.service nftban.service; do
        systemctl stop "$svc" >/dev/null 2>&1 || true
        systemctl disable "$svc" >/dev/null 2>&1 || true
    done
fi

%postun
# Post-uninstall: Cleanup
systemctl daemon-reload >/dev/null 2>&1 || true

if [ $1 -eq 0 ]; then
    # Full removal (not upgrade)
    echo "NFTBan removed. Config files preserved in /etc/nftban"
    echo "Run 'rm -rf /etc/nftban /var/lib/nftban /var/log/nftban' to purge all data"
fi

if [ $1 -ge 1 ]; then
    # Upgrade - restart running services (DEB parity)
    echo "Restarting NFTBan services after upgrade..."
    systemctl try-restart nftband.service >/dev/null 2>&1 || true
    systemctl try-restart nftban-login-monitor.service >/dev/null 2>&1 || true
fi

%posttrans
# Post-transaction: Run after all RPM operations complete (safety check)
# This ensures health check runs even if %post was interrupted

# Re-apply immutable flag (may have been removed during upgrade)
if [ -f %{_libdir}/nftban/lib/nft_schema.sh ]; then
    chmod 444 %{_libdir}/nftban/lib/nft_schema.sh 2>/dev/null || true
    chattr +i %{_libdir}/nftban/lib/nft_schema.sh 2>/dev/null || true
fi

# Run health check with auto-heal to ensure system is in good state
if command -v nftban >/dev/null 2>&1; then
    nftban health check --auto-heal --quiet >/dev/null 2>&1 || true
fi

%files
# ==========================================================================
# BINARIES & CLI
# ==========================================================================
%{_bindir}/nftban
%dir %{_libdir}/nftban
%dir %{_libdir}/nftban/setup
%attr(755,root,root) %{_libdir}/nftban/setup/*.sh
%dir %{_libdir}/nftban/sbin
%attr(755,root,nftban) %{_libdir}/nftban/sbin/nftban-apply
%attr(755,root,nftban) %{_libdir}/nftban/sbin/nftban-confirm
%attr(755,root,nftban) %{_libdir}/nftban/sbin/nftban-panelctl
%attr(755,root,nftban) %{_libdir}/nftban/sbin/nftban-queue-processor
%attr(755,root,nftban) %{_libdir}/nftban/sbin/nftban-rollback
%attr(755,root,nftban) %{_libdir}/nftban/sbin/nftban-service-alert
%{_libdir}/nftban/*

# ==========================================================================
# SYSTEMD UNITS
# ==========================================================================
%{_unitdir}/nftban*.service
%{_unitdir}/nftban*.timer
%{_unitdir}/nftban*.socket

# ==========================================================================
# SYSUSERS AND TMPFILES (generated from build/fhs-spec.yaml)
# ==========================================================================
%{_prefix}/lib/sysusers.d/nftban.conf
%{_prefix}/lib/tmpfiles.d/nftban.conf

# ==========================================================================
# CONFIGURATION (package-created, root:nftban)
# Note: Data/log/runtime dirs are created by tmpfiles, not listed here
# ==========================================================================
%dir %attr(750,root,nftban) /etc/nftban
%config(noreplace) /etc/nftban/nftban.conf
%config(noreplace) /etc/nftban/update.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d
%dir %attr(750,root,nftban) /etc/nftban/conf.d/ddos
%dir %attr(750,root,nftban) /etc/nftban/conf.d/portscan
%dir %attr(750,root,nftban) /etc/nftban/conf.d/login
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/cpanel
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/cwp
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/cyberpanel
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/directadmin
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/generic
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/interworx
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/plesk
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/vesta
%dir %attr(750,root,nftban) /etc/nftban/conf.d/rbl
%dir %attr(750,root,nftban) /etc/nftban/conf.d/botscan
%dir %attr(750,root,nftban) /etc/nftban/conf.d/geoban
%dir %attr(750,root,nftban) /etc/nftban/conf.d/geoip
%config(noreplace) /etc/nftban/conf.d/*.conf
%config(noreplace) /etc/nftban/conf.d/ddos/*.conf
%config(noreplace) /etc/nftban/conf.d/portscan/*.conf
%config(noreplace) /etc/nftban/conf.d/login/*.conf
# Central whitelist (SINGLE SOURCE OF TRUTH - all modules use whitelist.d/)
%config(noreplace) /etc/nftban/whitelist.d/*.conf
%config(noreplace) /etc/nftban/conf.d/botscan/*
%config(noreplace) /etc/nftban/conf.d/geoban/main.conf
%config(noreplace) /etc/nftban/conf.d/geoip/main.conf
%config(noreplace) /etc/nftban/conf.d/rbl/*
%config(noreplace) /etc/nftban/conf.d/panels/cpanel/*
%config(noreplace) /etc/nftban/conf.d/panels/cwp/*
%config(noreplace) /etc/nftban/conf.d/panels/cyberpanel/*
%config(noreplace) /etc/nftban/conf.d/panels/directadmin/*
%config(noreplace) /etc/nftban/conf.d/panels/generic/*
%config(noreplace) /etc/nftban/conf.d/panels/interworx/*
%config(noreplace) /etc/nftban/conf.d/panels/plesk/*
%config(noreplace) /etc/nftban/conf.d/panels/vesta/*
%dir %attr(750,root,nftban) /etc/nftban/suricata
%dir %attr(750,root,nftban) /etc/nftban/suricata/profiles
%dir %attr(750,root,nftban) /etc/nftban/suricata/config
%dir %attr(775,root,nftban) /etc/nftban/suricata/rules
%dir %attr(750,root,nftban) /etc/nftban/suricata/cache
%dir %attr(770,root,nftban) /etc/nftban/suricata/state
%dir %attr(770,root,nftban) /etc/nftban/suricata/state/last-good
%config(noreplace) /etc/nftban/suricata/profiles/*
%config(noreplace) %attr(664,root,nftban) /etc/nftban/suricata/rules/disable.conf
%config(noreplace) %attr(664,root,nftban) /etc/nftban/suricata/rules/enable.conf
%config(noreplace) %attr(664,root,nftban) /etc/nftban/suricata/rules/categories.enabled
%config(noreplace) %attr(664,root,nftban) /etc/nftban/suricata/rules/local.rules
%config(noreplace) %attr(664,root,nftban) /etc/nftban/suricata/suricata.yaml.overlay
# Suricata interface configuration (v1.12.0)
%dir %attr(750,root,nftban) /etc/nftban/conf.d/suricata
%config(noreplace) %attr(640,root,nftban) /etc/nftban/conf.d/suricata/interfaces.conf
%dir %attr(750,root,nftban) /etc/nftban/connectors
%dir %attr(750,root,nftban) /etc/nftban/patterns.d
%dir %attr(750,root,nftban) /etc/nftban/patterns.d/botscan
%config(noreplace) /etc/nftban/patterns.d/botscan/*
%dir %attr(750,root,nftban) /etc/nftban/whitelist.d
%dir %attr(750,root,nftban) /etc/nftban/blacklist.d
%dir %attr(750,root,nftban) /etc/nftban/ports.d
%dir %attr(750,root,nftban) /etc/nftban/rules.d
%dir %attr(750,root,nftban) /etc/nftban/nftables.d
%dir %attr(755,root,root) /etc/nftban/distros
%config(noreplace) /etc/nftban/distros/*

# Note: /var/lib/nftban, /var/log/nftban, /var/cache/nftban, /run/nftban
# are created by systemd-tmpfiles from /usr/lib/tmpfiles.d/nftban.conf
# and are NOT listed here to avoid conflicts

# ==========================================================================
# SHARED DATA (templates, specs)
# ==========================================================================
%dir /usr/share/nftban
%dir /usr/share/nftban/templates
%dir /usr/share/nftban/templates/mail
%dir /usr/share/nftban/templates/reports
%dir /usr/share/nftban/templates/zabbix
%dir /usr/share/nftban/dashboards
%dir /usr/share/nftban/dashboards/grafana
/usr/share/nftban/templates/mail/*
/usr/share/nftban/templates/reports/*
/usr/share/nftban/templates/zabbix/*
/usr/share/nftban/dashboards/grafana/*
%dir /usr/share/nftban/specs
/usr/share/nftban/specs/*

# ==========================================================================
# BASH COMPLETION
# ==========================================================================
/usr/share/bash-completion/completions/nftban

# ==========================================================================
# POLKIT
# ==========================================================================
%config(noreplace) /etc/polkit-1/rules.d/*-nftban*.rules

# ==========================================================================
# LOGROTATE
# ==========================================================================
%config(noreplace) /etc/logrotate.d/nftban

# ==========================================================================
# MAN PAGES
# ==========================================================================
%{_mandir}/man8/nftban.8*
%{_mandir}/man8/nftban-suricata.8*

# ==========================================================================
# HOSTING PANELS (optional)
# ==========================================================================
%dir /etc/nftban/conf.d/panels
%dir /usr/local/directadmin/plugins/nftban
/usr/local/directadmin/plugins/nftban/*
%dir /usr/local/cpanel/whostmgr/docroot/cgi/nftban
/usr/local/cpanel/whostmgr/docroot/cgi/nftban/*
%dir /usr/local/cwpsrv/htdocs/resources/admin/modules/nftban
/usr/local/cwpsrv/htdocs/resources/admin/modules/nftban/*
%dir /usr/local/psa/admin/htdocs/modules/nftban
/usr/local/psa/admin/htdocs/modules/nftban/*

%changelog
* Tue Feb 04 2026 NFTBan Team <contact@nftban.com> - 1.9.4-1
- Consolidated: Single central whitelist in whitelist.d/ (SINGLE SOURCE OF TRUTH)
- Removed: Per-module whitelist.txt files (ddos, portscan, login)
- Added: nftban_is_whitelisted() and nftban_is_blacklisted() functions

* Tue Feb 04 2026 NFTBan Team <contact@nftban.com> - 1.9.3-1
- Fixed: RPM packaging for whitelist.txt files in conf.d subdirectories
- Fixed: Version alignment across all package scripts

* Sun Feb 02 2026 NFTBan Team <contact@nftban.com> - 1.9.1-1
- Suricata Smart Management Phase 2: Rules UX
- New CLI: nftban suricata rules status/rollback/list-backups/apply
- New CLI: nftban suricata category list/enable/disable
- New CLI: nftban suricata sid enable/disable/list
- New CLI: nftban suricata local list/add/remove/edit
- New shared helper: suricata_rules.sh (16 functions)
- New shared helper: nftban_mode.sh for portscan/ddos mode management
- Fixed: DDoS mode argument passing aligned with portscan
- Fixed: Duplicate code removed from cmd_suricata.sh
- Added: Suricata config files to package (rules, state, overlay)

* Wed Jan 28 2026 NFTBan Team <contact@nftban.com> - 1.7.0-1
- Dependency architecture redesign: minimal core install, feature-gated prerequisites
- Shared prereq library (nftban_prereq.sh) with distro-aware package suggestions
- Removed suricata, prometheus, node_exporter, ncat, ipset, python3-pip from required
- Core contract: nftables, jq, socat, curl, wget, git only
- Enable-time prereq checks for geoban, rbl, login commands

* Wed Jan 22 2026 NFTBan Team <contact@nftban.com> - 1.3.0-1
- Native Zabbix integration with multi-target support and failover
- Low-Level Discovery (LLD) for modules, interfaces, countries, feeds, timers
- Generic connectors: Elasticsearch, Kafka, NDJSON file export
- Zabbix templates for 5.x (XML) and 6.x+ (YAML)
- 85+ metrics with comprehensive daemon, bans, events, feeds coverage
- TLS/PSK encryption support for Zabbix trapper protocol
- New CLI commands: nftban zabbix, nftban connector

* Tue Dec 17 2024 NFTBan Team <contact@nftban.com> - 1.0.0-1
- Initial release
- Modular architecture with Go binaries
- GeoIP blocking, threat feeds, login monitoring
- Suricata IDS integration
- Web GUI with Prometheus metrics
