# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2025 NFTBan Development Team

Name:           nftban
Version:        1.0.0
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
Requires:       python3-pip
Requires:       curl
Requires:       python3

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
Requires:       ipset
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

%pre
# Pre-install: Create user and group
getent group nftban >/dev/null || groupadd -r nftban
getent group nftban-auditors >/dev/null || groupadd -r nftban-auditors
getent passwd nftban >/dev/null || \
    useradd -r -g nftban -G nftban-auditors -d /var/lib/nftban \
    -s /sbin/nologin -c "NFTBan Service Account" nftban
exit 0

%post
# Post-install: Configure and enable services

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
    echo "  • Duplicate filtering rules"
    echo "  • Unpredictable blocking behavior"
    echo "  • NFTBan blocks may not work"
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

# Create directories
install -d -m 750 -o root -g nftban /etc/nftban/ports.d 2>/dev/null || true
install -d -m 750 -o root -g nftban /etc/nftban/whitelist.d 2>/dev/null || true
install -d -m 750 -o nftban -g nftban /var/log/nftban 2>/dev/null || true
install -d -m 750 -o nftban -g nftban /var/log/nftban/watchdog 2>/dev/null || true
install -d -m 750 -o nftban -g nftban /var/lib/nftban/stats 2>/dev/null || true
install -d -m 750 -o nftban -g nftban /var/lib/nftban/stats/history 2>/dev/null || true
install -d -m 750 -o nftban -g nftban /var/lib/nftban/stats/profiles 2>/dev/null || true

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
                 nftban-rollback.timer nftban-metrics-exporter.timer \
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

%files
# File list generated during build

%changelog
* Tue Dec 17 2024 NFTBan Team <contact@nftban.com> - 1.0.0-1
- Initial release
- Modular architecture with Go binaries
- GeoIP blocking, threat feeds, login monitoring
- Suricata IDS integration
- Web GUI with Prometheus metrics
