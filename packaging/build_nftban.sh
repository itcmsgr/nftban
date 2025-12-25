#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Complete Package Builder
# =============================================================================
# Builds RPM and DEB packages for NFTBan core components
#
# Usage:
#   ./build_nftban.sh [deb|rpm|both]
#
# Packages created:
#   - nftban-core     - Core binaries (nftban-core, nftban CLI)
#   - nftban-libs     - Shell libraries
#   - nftban-ui       - Web GUI
#   - nftban-all      - Meta-package (depends on all above)
#
# =============================================================================

set -Eeuo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Package metadata
readonly PKG_VERSION="1.0.0"
readonly PKG_RELEASE="1"

# Paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PROJECT_ROOT
readonly BUILD_DIR="${PROJECT_ROOT}/build/packages"

# Functions
log_info() { echo -e "${BLUE}[INFO]${NC} $*"; }
log_success() { echo -e "${GREEN}[✓]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

check_dependencies() {
    local build_type="$1"
    local missing=()

    # Check build tools
    if [[ ! -x "${PROJECT_ROOT}/build.sh" ]]; then
        log_error "build.sh not found or not executable"
        return 1
    fi

    # Check for DEB tools
    if [[ "$build_type" =~ (deb|both) ]]; then
        command -v dpkg-deb >/dev/null || missing+=("dpkg-deb")
    fi

    # Check for RPM tools
    if [[ "$build_type" =~ (rpm|both) ]]; then
        command -v rpmbuild >/dev/null || missing+=("rpmbuild")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing: ${missing[*]}"
        log_info "Install: sudo dnf install rpm-build dpkg-dev"
        return 1
    fi

    return 0
}

build_binaries() {
    # Check if pre-built binaries exist (from CI)
    if [[ -x "${PROJECT_ROOT}/bin/nftban-core" ]]; then
        log_info "Using pre-built binaries from bin/"
        ls -la "${PROJECT_ROOT}/bin/"
        return 0
    fi

    log_info "Building binaries..."

    cd "${PROJECT_ROOT}"
    ./build.sh || {
        log_error "Build failed"
        return 1
    }

    log_success "Binaries built successfully"
}

create_rpm_spec_nftban_core() {
    cat > "${BUILD_DIR}/SPECS/nftban-core.spec" <<'EOF'
# Disable debuginfo for Go binary (no debug symbols)
%global debug_package %{nil}

Name:           nftban-core
Version:        1.0.0
Release:        1%{?dist}
Summary:        NFTBan Core - Adaptive firewall with threat intelligence

License:        GPL-3.0-or-later
URL:            https://github.com/itcmsgr/nftban-dev
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  systemd-rpm-macros

Requires:       nftables >= 0.9.0
Requires:       systemd
Requires:       bash >= 4.0
Requires:       jq
Requires:       curl
Requires(pre):  shadow-utils

%description
NFTBan is an adaptive firewall system with threat intelligence integration.
Features nftables v1.0 dual-table architecture (ip nftban + ip6 nftban).

%prep
%autosetup

%build
# Binary is pre-built by CI and included in tarball
echo "Using pre-built nftban-core binary"
ls -la bin/

%install
# Binaries
install -D -m 0755 bin/nftban-core %{buildroot}/usr/lib/nftban/bin/nftban-core
install -D -m 0755 cli/sbin/nftban %{buildroot}/usr/bin/nftban

# Libraries
mkdir -p %{buildroot}/usr/lib/nftban/lib
cp -r cli/lib/nftban/* %{buildroot}/usr/lib/nftban/

# Nftables config
install -D -m 0644 install/nftables/nftables.conf %{buildroot}/etc/nftban/nftables.conf

# Systemd units (actual files that exist)
install -D -m 0644 install/systemd/nftban-maintenance.service %{buildroot}/usr/lib/systemd/system/nftban-maintenance.service
install -D -m 0644 install/systemd/nftban-maintenance.timer %{buildroot}/usr/lib/systemd/system/nftban-maintenance.timer
install -D -m 0644 install/systemd/nftban-health.service %{buildroot}/usr/lib/systemd/system/nftban-health.service
install -D -m 0644 install/systemd/nftban-health.timer %{buildroot}/usr/lib/systemd/system/nftban-health.timer
install -D -m 0644 install/systemd/nftban-login-monitor.service %{buildroot}/usr/lib/systemd/system/nftban-login-monitor.service
install -D -m 0644 install/systemd/nftban-core-geoip.service %{buildroot}/usr/lib/systemd/system/nftban-core-geoip.service
install -D -m 0644 install/systemd/nftban-core-geoip.timer %{buildroot}/usr/lib/systemd/system/nftban-core-geoip.timer
install -D -m 0644 install/systemd/nftban-core-feeds.service %{buildroot}/usr/lib/systemd/system/nftban-core-feeds.service
install -D -m 0644 install/systemd/nftban-core-feeds.timer %{buildroot}/usr/lib/systemd/system/nftban-core-feeds.timer
install -D -m 0644 install/systemd/nftban-metrics-exporter.service %{buildroot}/usr/lib/systemd/system/nftban-metrics-exporter.service
install -D -m 0644 install/systemd/nftban-metrics-exporter.timer %{buildroot}/usr/lib/systemd/system/nftban-metrics-exporter.timer
install -D -m 0644 install/systemd/nftban-watchdog.service %{buildroot}/usr/lib/systemd/system/nftban-watchdog.service
install -D -m 0644 install/systemd/nftban-watchdog.timer %{buildroot}/usr/lib/systemd/system/nftban-watchdog.timer
install -D -m 0644 install/systemd/nftban-snapshot.service %{buildroot}/usr/lib/systemd/system/nftban-snapshot.service
install -D -m 0644 install/systemd/nftban-snapshot.timer %{buildroot}/usr/lib/systemd/system/nftban-snapshot.timer
install -D -m 0644 install/systemd/nftban-rollback.service %{buildroot}/usr/lib/systemd/system/nftban-rollback.service
install -D -m 0644 install/systemd/nftban-rollback.timer %{buildroot}/usr/lib/systemd/system/nftban-rollback.timer
install -D -m 0644 install/systemd/nftban-suricata-update.service %{buildroot}/usr/lib/systemd/system/nftban-suricata-update.service
install -D -m 0644 install/systemd/nftban-suricata-update.timer %{buildroot}/usr/lib/systemd/system/nftban-suricata-update.timer

# PolicyKit rules
install -D -m 0644 cmd/nftban-core/polkit/10-nftban-core.rules %{buildroot}/etc/polkit-1/rules.d/10-nftban-core.rules

# Man page
install -D -m 0644 docs/man/man8/nftban.8 %{buildroot}/usr/share/man/man8/nftban.8

# Config directories (must match %files section)
mkdir -p %{buildroot}/etc/nftban/{conf.d,distros,whitelist.d,blacklist.d,ports.d}
mkdir -p %{buildroot}/var/lib/nftban/{feeds,geoip,staging,reports}
mkdir -p %{buildroot}/var/log/nftban
mkdir -p %{buildroot}/var/cache/nftban

%pre
# =============================================================================
# STEP 1: Create system groups
# =============================================================================
# NFTBan v1.0 uses 2-group model:
#   nftban: All operators (CLI + Web GUI)
#   nftban-auditors: Read-only audit access
getent group nftban >/dev/null || groupadd -r nftban
getent group nftban-auditors >/dev/null || groupadd -r nftban-auditors
getent passwd nftban >/dev/null || useradd -r -g nftban -d /var/lib/nftban -s /usr/sbin/nologin -c "NFTBan system user" nftban

# Add root to nftban group for CLI access
usermod -a -G nftban root 2>/dev/null || true

%post
# =============================================================================
# NFTBan v1.0.0 - SAFE INSTALL FLOW
# =============================================================================
# Order: groups -> dirs -> perms -> polkit -> whitelist -> health -> services
# This prevents lockout by ensuring whitelist is in place BEFORE firewall is active.

echo "[NFTBan] Configuring NFTBan v1.0.0..."

# STEP 1: Remove old systemd overrides (prevent conflicts with new package files)
echo "[NFTBan] Removing old systemd overrides..."
rm -f /etc/systemd/system/nftban-*.service 2>/dev/null || true
rm -f /etc/systemd/system/nftban-*.timer 2>/dev/null || true
rm -rf /etc/systemd/system/nftban-*.service.d 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

# STEP 2: Create FHS directories
echo "[NFTBan] Creating FHS directories..."
mkdir -p /etc/nftban/{conf.d,distros,whitelist.d,blacklist.d,ports.d}
mkdir -p /var/lib/nftban/{banned,whitelist,feeds,geoip,reports,config,state,metrics,snapshots,exports}
mkdir -p /var/lib/nftban/reports/{baseline,auditors}
mkdir -p /var/log/nftban/reports
mkdir -p /var/cache/nftban/health
mkdir -p /run/nftban
mkdir -p /usr/share/nftban/templates/{mail,reports}

# STEP 3: Set permissions
echo "[NFTBan] Setting permissions..."
chown root:nftban /etc/nftban 2>/dev/null || true
chmod 750 /etc/nftban 2>/dev/null || true
chown -R nftban:nftban /var/lib/nftban /var/log/nftban /var/cache/nftban 2>/dev/null || true
chmod 750 /var/lib/nftban /var/log/nftban 2>/dev/null || true
chmod 755 /var/cache/nftban 2>/dev/null || true

# Set executable on shell scripts
find /usr/lib/nftban -name "*.sh" -exec chmod 755 {} \; 2>/dev/null || true

# Set capabilities for nftban-core (allows non-root nftables operations)
if [ -x /usr/lib/nftban/bin/nftban-core ]; then
    setcap 'cap_net_admin+ep' /usr/lib/nftban/bin/nftban-core 2>/dev/null || \
        echo "[NFTBan WARN] Could not set CAP_NET_ADMIN on nftban-core"
fi

# Set capabilities for nft binary (required for CLI fallback operations)
if [ -x /usr/sbin/nft ]; then
    setcap 'cap_net_admin+ep' /usr/sbin/nft 2>/dev/null || \
        echo "[NFTBan WARN] Could not set CAP_NET_ADMIN on nft"
fi

# STEP 4: Polkit
echo "[NFTBan] Installing polkit policies..."
mkdir -p /usr/share/polkit-1/rules.d /etc/polkit-1/rules.d
systemctl restart polkit 2>/dev/null || true

# STEP 5: **SAFETY** Auto-whitelist system IPs
# CRITICAL: This MUST happen BEFORE enabling any firewall services
echo "[NFTBan] Auto-whitelisting system IPs (lockout prevention)..."
if command -v nftban >/dev/null 2>&1; then
    nftban whitelist-system sync 2>/dev/null || echo "[NFTBan WARN] Auto-whitelist failed"
fi

# STEP 6: Download GeoIP database (free DB-IP version)
echo "[NFTBan] Downloading GeoIP database..."
if [ -x /usr/lib/nftban/bin/nftban-core ]; then
    /usr/lib/nftban/bin/nftban-core geoip update 2>/dev/null || echo "[NFTBan WARN] GeoIP download failed (will retry via timer)"
fi

# STEP 7: Health check
if command -v nftban >/dev/null 2>&1; then
    nftban health check --quiet 2>/dev/null || true
fi

# STEP 8: Enable services (AFTER whitelist is in place)
echo "[NFTBan] Enabling systemd services..."
%systemd_post nftban-maintenance.service nftban-maintenance.timer nftban-health.service nftban-health.timer nftban-login-monitor.service nftban-core-geoip.timer nftban-core-feeds.timer

# Enable nftables
systemctl enable nftables 2>/dev/null || true

# Enable and start essential timers
echo "[NFTBan] Starting essential timers..."
systemctl enable --now nftban-maintenance.timer 2>/dev/null || true
systemctl enable --now nftban-health.timer 2>/dev/null || true
systemctl enable --now nftban-core-geoip.timer 2>/dev/null || true
systemctl enable --now nftban-core-feeds.timer 2>/dev/null || true
systemctl enable --now nftban-queue.timer 2>/dev/null || true

# Enable and start login monitor
systemctl enable --now nftban-login-monitor.service 2>/dev/null || true

# Reload nftables
systemctl reload nftables 2>/dev/null || true

echo "[NFTBan] Installation complete. Your IP has been auto-whitelisted."
echo "[NFTBan] Essential timers started. Run 'nftban timers enable' to start all optional timers."

%preun
%systemd_preun nftban-maintenance.service nftban-maintenance.timer nftban-health.service nftban-health.timer nftban-login-monitor.service nftban-core-geoip.service nftban-core-geoip.timer nftban-core-feeds.service nftban-core-feeds.timer

%postun
%systemd_postun_with_restart nftban-maintenance.service nftban-health.service nftban-login-monitor.service nftban-core-geoip.service nftban-core-feeds.service

# Inform user about leftover files on complete removal
if [ $1 -eq 0 ]; then
    echo "nftban: Configuration files in /etc/nftban/ have been preserved."
    echo "nftban: Log files in /var/log/nftban/ have been preserved."
    echo "nftban: User accounts and groups have NOT been removed."
fi

%files
/usr/lib/nftban/bin/nftban-core
/usr/bin/nftban
/usr/lib/nftban/
%config(noreplace) /etc/nftban/nftables.conf
/usr/lib/systemd/system/*.service
/usr/lib/systemd/system/*.timer
/etc/polkit-1/rules.d/10-nftban-core.rules
/usr/share/man/man8/nftban.8*
%dir /etc/nftban
%dir /etc/nftban/conf.d
%dir /etc/nftban/distros
%dir /etc/nftban/whitelist.d
%dir /etc/nftban/blacklist.d
%dir /etc/nftban/ports.d
%dir %attr(750,nftban,nftban) /var/lib/nftban
%dir %attr(750,nftban,nftban) /var/lib/nftban/feeds
%dir %attr(750,nftban,nftban) /var/lib/nftban/geoip
%dir %attr(750,nftban,nftban) /var/lib/nftban/staging
%dir %attr(750,nftban,nftban) /var/lib/nftban/reports
%dir %attr(750,nftban,nftban) /var/log/nftban
%dir %attr(755,root,root) /var/cache/nftban

%changelog
* Mon Dec 09 2024 NFTBan Team <noreply@nftban.com> - 1.0.0-1
- NFTBan v1.0.0 release
- SAFE INSTALL FLOW: Auto-whitelist before enabling firewall
- FHS compliant directory structure
- 2-group security model (nftban, nftban-auditors)
- Polkit policies for service management
- Built-in login monitor (no fail2ban dependency)

* Thu Nov 28 2024 NFTBan Team <noreply@nftban.com> - 0.7.3-1
- NFT Schema v0.7.3 dual-table architecture
- Fixed rule order (blacklist before established)
- Added helper chains (ddos_protection, portscan_detection)
- Removed hardcoded table names
EOF
}

build_rpm() {
    log_info "Building RPM packages..."

    # Check if rpmbuild is available
    if ! command -v rpmbuild &>/dev/null; then
        log_warn "rpmbuild not found, skipping RPM build"
        return 0
    fi

    mkdir -p "${BUILD_DIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

    # Create spec file
    create_rpm_spec_nftban_core

    # Create source tarball
    local tarball="nftban-core-${PKG_VERSION}.tar.gz"
    tar czf "${BUILD_DIR}/SOURCES/${tarball}" \
        --transform "s,^,nftban-core-${PKG_VERSION}/," \
        -C "${PROJECT_ROOT}" \
        bin/ cli/ cmd/ pkg/ install/ etc/ docs/

    # Build RPM
    if rpmbuild --define "_topdir ${BUILD_DIR}" \
        -bb "${BUILD_DIR}/SPECS/nftban-core.spec" 2>&1; then
        log_success "RPM built: ${BUILD_DIR}/RPMS/x86_64/nftban-core-${PKG_VERSION}-${PKG_RELEASE}.*.rpm"
        ls -la "${BUILD_DIR}/RPMS/" 2>/dev/null || true
    else
        log_error "RPM build failed"
        return 1
    fi
}

create_deb_control() {
    mkdir -p "${BUILD_DIR}/deb/DEBIAN"

    cat > "${BUILD_DIR}/deb/DEBIAN/control" <<EOF
Package: nftban-core
Version: ${PKG_VERSION}
Section: net
Priority: optional
Architecture: amd64
Depends: nftables (>= 0.9.0), systemd, bash (>= 4.0), jq, curl
Maintainer: NFTBan Team <noreply@nftban.com>
Description: NFTBan Core - Adaptive firewall with threat intelligence
 NFTBan is an adaptive firewall system with threat intelligence integration.
 Features nftables v1.0 dual-table architecture (ip nftban + ip6 nftban).
 .
 This package includes:
  - nftban-core binary (Go)
  - nftban CLI
  - Shell libraries
  - NFT Schema v1.0 configuration
  - Systemd units
  - PolicyKit rules
EOF

    # Use the comprehensive postinst from packaging/deb/postinst
    if [[ -f "${PROJECT_ROOT}/packaging/deb/postinst" ]]; then
        cp "${PROJECT_ROOT}/packaging/deb/postinst" "${BUILD_DIR}/deb/DEBIAN/postinst"
    else
        # Fallback inline postinst with SAFE INSTALL FLOW
        cat > "${BUILD_DIR}/deb/DEBIAN/postinst" <<'EOF'
#!/bin/bash
# NFTBan v1.0.0 - SAFE INSTALL FLOW
set -e

echo "[NFTBan] Configuring NFTBan v1.0.0..."

# STEP 0: Remove old systemd overrides (prevent conflicts with new package files)
echo "[NFTBan] Removing old systemd overrides..."
rm -f /etc/systemd/system/nftban-*.service 2>/dev/null || true
rm -f /etc/systemd/system/nftban-*.timer 2>/dev/null || true
rm -rf /etc/systemd/system/nftban-*.service.d 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

# STEP 1: Create groups
if ! getent group nftban >/dev/null; then
    addgroup --system nftban
fi
if ! getent group nftban-auditors >/dev/null; then
    addgroup --system nftban-auditors
fi

# STEP 2: Create user
if ! getent passwd nftban >/dev/null; then
    adduser --system --ingroup nftban --home /var/lib/nftban --no-create-home --shell /usr/sbin/nologin nftban
fi

# Add root to nftban group
usermod -a -G nftban root 2>/dev/null || true

# STEP 3: Create FHS directories
mkdir -p /etc/nftban/{conf.d,distros,whitelist.d,blacklist.d,ports.d}
mkdir -p /var/lib/nftban/{banned,whitelist,feeds,geoip,reports,config,state,metrics,snapshots,exports}
mkdir -p /var/lib/nftban/reports/{baseline,auditors}
mkdir -p /var/log/nftban/reports
mkdir -p /var/cache/nftban/health
mkdir -p /run/nftban
mkdir -p /usr/share/nftban/templates/{mail,reports}

# STEP 4: Set permissions
chown root:nftban /etc/nftban
chmod 750 /etc/nftban
chown -R nftban:nftban /var/lib/nftban /var/log/nftban /var/cache/nftban
chmod 750 /var/lib/nftban /var/log/nftban
chmod 755 /var/cache/nftban

# Set executable on shell scripts
find /usr/lib/nftban -name "*.sh" -exec chmod 755 {} \; 2>/dev/null || true

# STEP 5: Polkit
mkdir -p /usr/share/polkit-1/rules.d /etc/polkit-1/rules.d
systemctl restart polkit 2>/dev/null || true

# STEP 6: **SAFETY** Auto-whitelist system IPs
echo "[NFTBan] Auto-whitelisting system IPs (lockout prevention)..."
if command -v nftban >/dev/null 2>&1; then
    nftban whitelist-system sync 2>/dev/null || echo "[NFTBan WARN] Auto-whitelist failed"
fi

# STEP 7: Download GeoIP database (free DB-IP version)
echo "[NFTBan] Downloading GeoIP database..."
if [ -x /usr/lib/nftban/bin/nftban-core ]; then
    /usr/lib/nftban/bin/nftban-core geoip update 2>/dev/null || echo "[NFTBan WARN] GeoIP download failed (will retry via timer)"
fi

# STEP 8: Health check
if command -v nftban >/dev/null 2>&1; then
    nftban health check --quiet 2>/dev/null || true
fi

# STEP 9: Enable services (AFTER whitelist is in place)
echo "[NFTBan] Enabling systemd services..."
systemctl daemon-reload
systemctl enable nftables 2>/dev/null || true

# Enable and start essential timers
echo "[NFTBan] Starting essential timers..."
systemctl enable --now nftban-maintenance.timer 2>/dev/null || true
systemctl enable --now nftban-health.timer 2>/dev/null || true
systemctl enable --now nftban-core-geoip.timer 2>/dev/null || true
systemctl enable --now nftban-core-feeds.timer 2>/dev/null || true
systemctl enable --now nftban-queue.timer 2>/dev/null || true

# Enable and start login monitor
systemctl enable --now nftban-login-monitor.service 2>/dev/null || true

# STEP 10: Reload nftables
systemctl reload nftables 2>/dev/null || true

echo "[NFTBan] Installation complete. Your IP has been auto-whitelisted."
echo "[NFTBan] Essential timers started. Run 'nftban timers enable' to start all optional timers."
exit 0
EOF
    fi

    chmod 0755 "${BUILD_DIR}/deb/DEBIAN/postinst"
}

build_deb() {
    log_info "Building DEB package..."

    local deb_root="${BUILD_DIR}/deb"
    rm -rf "${deb_root}"

    # Create directory structure
    mkdir -p "${deb_root}"/{DEBIAN,usr/bin,usr/lib/nftban/bin,usr/lib/systemd/system,etc/{nftables,polkit-1/rules.d,nftban/blacklist.d},var/{lib/nftban/{feeds,geoip,staging},log/nftban}}

    # Copy binaries
    install -m 0755 "${PROJECT_ROOT}/bin/nftban-core" "${deb_root}/usr/lib/nftban/bin/"
    install -m 0755 "${PROJECT_ROOT}/cli/sbin/nftban" "${deb_root}/usr/bin/"

    # Copy libraries
    cp -r "${PROJECT_ROOT}/cli/lib/nftban"/* "${deb_root}/usr/lib/nftban/"

    # Copy nftables config (to nftban dir to avoid conflict with system nftables package)
    mkdir -p "${deb_root}/etc/nftban"
    install -m 0644 "${PROJECT_ROOT}/install/nftables/nftables.conf" "${deb_root}/etc/nftban/nftables.conf"

    # Copy all systemd units
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-maintenance.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-maintenance.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-health.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-health.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-login-monitor.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-core-geoip.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-core-geoip.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-core-feeds.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-core-feeds.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-metrics-exporter.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-metrics-exporter.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-watchdog.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-watchdog.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-snapshot.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-snapshot.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-rollback.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-rollback.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-suricata-update.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-suricata-update.timer" "${deb_root}/usr/lib/systemd/system/"

    # Copy PolicyKit rules
    install -m 0644 "${PROJECT_ROOT}/cmd/nftban-core/polkit/10-nftban-core.rules" "${deb_root}/etc/polkit-1/rules.d/"

    # Copy man page
    mkdir -p "${deb_root}/usr/share/man/man8"
    install -m 0644 "${PROJECT_ROOT}/docs/man/man8/nftban.8" "${deb_root}/usr/share/man/man8/"

    # Create control file
    create_deb_control

    # Build DEB
    dpkg-deb --build "${deb_root}" "${BUILD_DIR}/nftban-core_${PKG_VERSION}_amd64.deb"

    log_success "DEB built: ${BUILD_DIR}/nftban-core_${PKG_VERSION}_amd64.deb"
}

main() {
    local build_type="${1:-both}"

    # Validate
    if [[ ! "$build_type" =~ ^(deb|rpm|both)$ ]]; then
        log_error "Invalid argument: $build_type"
        echo "Usage: $0 [deb|rpm|both]"
        exit 1
    fi

    # Check dependencies
    check_dependencies "$build_type" || exit 1

    # Build binaries first
    build_binaries || exit 1

    # Create build directory
    mkdir -p "${BUILD_DIR}"

    log_info "Building NFTBan v${PKG_VERSION} packages (${build_type})"
    echo ""

    # Build packages
    if [[ "$build_type" =~ (rpm|both) ]]; then
        build_rpm || {
            log_error "RPM build failed"
            exit 1
        }
        echo ""
    fi

    if [[ "$build_type" =~ (deb|both) ]]; then
        build_deb || {
            log_error "DEB build failed"
            exit 1
        }
        echo ""
    fi

    # Show results
    log_success "Build complete!"
    echo ""
    log_info "Generated packages:"
    ls -lh "${BUILD_DIR}"/*.{deb,rpm} 2>/dev/null || ls -lh "${BUILD_DIR}/RPMS"/*/*.rpm 2>/dev/null || true
    echo ""
    log_info "To install on lab servers:"
    echo "  DEB: sudo dpkg -i ${BUILD_DIR}/nftban-core_${PKG_VERSION}_amd64.deb"
    echo "  RPM: sudo rpm -ivh ${BUILD_DIR}/RPMS/x86_64/nftban-core-${PKG_VERSION}-${PKG_RELEASE}.*.rpm"
}

main "$@"
