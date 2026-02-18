#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.9.3 - Complete Package Builder
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name="build_nftban"
# meta:type="installer"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:created_date="2025-10-26"
# meta:description="Builds RPM and DEB packages for NFTBan core components"
# meta:input="deb, rpm, or both (default)"
# meta:output="RPM and/or DEB packages"
# meta:depends="rpmbuild, dpkg-deb, go"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Usage:
#   ./build_nftban.sh [deb|rpm|both]
#
# Packages created:
#   - nftban-core     - Core binaries (nftban-core, nftban CLI)
#   - nftban-libs     - Shell libraries
#   - nftban-ui       - Web GUI
#   - nftban-all      - Meta-package (depends on all above)
# =============================================================================

set -Eeuo pipefail

# Colors
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m'

# Package metadata - Read from VERSION file (single source of truth)
PKG_VERSION=$(cat "${BASH_SOURCE[0]%/*}/../VERSION" 2>/dev/null || echo "unknown")
readonly PKG_VERSION
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

# Validate binaries are real ELF files
validate_binary() {
    local binary="$1"
    if [[ ! -f "$binary" ]]; then
        log_error "Binary not found: $binary"
        return 1
    fi

    # Check ELF magic bytes (0x7f 'E' 'L' 'F')
    # Use file command if available, otherwise check magic bytes directly
    local is_elf=0
    if command -v file >/dev/null 2>&1; then
        local file_type
        file_type=$(file -b "$binary")
        if [[ "$file_type" == *"ELF"* ]]; then
            is_elf=1
        fi
    else
        # Fallback: Check ELF magic bytes directly (7f 45 4c 46 = \x7fELF)
        local magic
        magic=$(od -A n -t x1 -N 4 "$binary" 2>/dev/null | tr -d ' ')
        if [[ "$magic" == "7f454c46" ]]; then
            is_elf=1
        fi
    fi

    if [[ $is_elf -ne 1 ]]; then
        log_error "Invalid binary (not ELF): $binary"
        return 1
    fi

    local size
    size=$(stat -c%s "$binary")
    if [[ $size -lt 100000 ]]; then
        log_error "Binary suspiciously small: $binary ($size bytes)"
        return 1
    fi

    log_success "Validated: $binary ($size bytes, ELF)"
    return 0
}

build_binaries() {
    # Check if pre-built binaries exist (from CI)
    if [[ -x "${PROJECT_ROOT}/bin/nftban-core" ]] && [[ -x "${PROJECT_ROOT}/bin/nftband" ]]; then
        log_info "Using pre-built binaries from bin/"
        ls -la "${PROJECT_ROOT}/bin/"

        # Validate pre-built binaries
        validate_binary "${PROJECT_ROOT}/bin/nftban-core" || return 1
        validate_binary "${PROJECT_ROOT}/bin/nftband" || return 1

        return 0
    fi

    log_info "Building binaries..."

    cd "${PROJECT_ROOT}"
    ./build.sh || {
        log_error "Build failed"
        return 1
    }

    # Validate built binaries
    validate_binary "${PROJECT_ROOT}/bin/nftban-core" || return 1
    validate_binary "${PROJECT_ROOT}/bin/nftband" || return 1

    log_success "Binaries built successfully"
}

create_rpm_spec_nftban_core() {
    cat > "${BUILD_DIR}/SPECS/nftban-core.spec" <<EOF
# Disable debuginfo for Go binary (no debug symbols)
%global debug_package %{nil}
%global _missing_build_ids_terminate_build 0

Name:           nftban-core
Version:        ${PKG_VERSION}
Release:        ${PKG_RELEASE}%{?dist}
Summary:        Open-source Linux IPS and nftables firewall manager

License:        GPL-3.0-or-later
URL:            https://nftban.com
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  systemd-rpm-macros

Requires:       nftables >= 0.9.0
Requires:       systemd
Requires:       bash >= 4.0
Requires:       bash-completion
Requires:       jq
Requires:       curl
Requires:       tar
Requires:       gzip
Requires:       pam
Requires:       bc
Requires:       gawk
Requires:       socat
Recommends:     bind-utils
Recommends:     mailx
Recommends:     newt
Requires(pre):  shadow-utils

%description
NFTBan is an open-source Linux Intrusion Prevention System (IPS) and
nftables firewall manager built for modern server and DevOps environments.

It uses a Go-based netlink daemon for asynchronous enforcement, applying
security rules directly through the Linux kernel for low-latency threat
response.

Key features include:

 * Native nftables integration designed for Linux 5.x+ systems,
   ensuring predictable rule evaluation and efficient kernel execution.

 * Dual-table architecture (ip nftban and ip6 nftban) providing
   clean IPv4 and IPv6 isolation.

 * Automated protection against SSH brute-force attacks,
   login abuse, port scans, and DDoS activity.

 * Support for real-time threat intelligence feeds and
   geographic IP blocking (Geo-IP).

 * Asynchronous rule management to maintain responsiveness
   even under high traffic conditions.

%prep
%autosetup

%build
# Binary is pre-built by CI and included in tarball
echo "Using pre-built nftban-core binary"
ls -la bin/

%install
# Binaries
install -D -m 0755 bin/nftban-core %{buildroot}/usr/lib/nftban/bin/nftban-core
install -D -m 0755 bin/nftband %{buildroot}/usr/lib/nftban/bin/nftband
install -D -m 0755 cli/sbin/nftban %{buildroot}/usr/sbin/nftban
install -D -m 0755 bin/nftban-ui %{buildroot}/usr/sbin/nftban-ui
install -D -m 0755 bin/nftban-ui-auth %{buildroot}/usr/libexec/nftban-ui-auth

# Helper scripts (queue processor, rollback, alerts, etc.)
mkdir -p %{buildroot}/usr/lib/nftban/sbin
install -m 0755 cli/sbin/nftban-apply %{buildroot}/usr/lib/nftban/sbin/
install -m 0755 cli/sbin/nftban-confirm %{buildroot}/usr/lib/nftban/sbin/
install -m 0755 cli/sbin/nftban-panelctl %{buildroot}/usr/lib/nftban/sbin/
install -m 0755 cli/sbin/nftban-queue-processor %{buildroot}/usr/lib/nftban/sbin/
install -m 0755 cli/sbin/nftban-rollback %{buildroot}/usr/lib/nftban/sbin/
install -m 0755 cli/sbin/nftban-service-alert %{buildroot}/usr/lib/nftban/sbin/

# Version file
install -D -m 0644 VERSION %{buildroot}/usr/lib/nftban/VERSION

# Main configuration file
install -D -m 0640 install/config/nftban.conf %{buildroot}/etc/nftban/nftban.conf

# Libraries
mkdir -p %{buildroot}/usr/lib/nftban/lib
cp -r cli/lib/nftban/* %{buildroot}/usr/lib/nftban/

# CRITICAL: Set executable permissions on all shell scripts
# (cp -r doesn't preserve permissions from source)
find %{buildroot}/usr/lib/nftban -name "*.sh" -exec chmod 755 {} \;

# Nftables config
install -D -m 0644 install/nftables/nftables.conf %{buildroot}/etc/nftban/nftables.conf

# Configuration files (conf.d with subdirectories)
# NOTE: Central whitelist moved to whitelist.d/ - per-module whitelist.txt files removed
mkdir -p %{buildroot}/etc/nftban/conf.d
cp -r etc/nftban/conf.d/* %{buildroot}/etc/nftban/conf.d/
# Remove any stale whitelist.txt files (consolidated to whitelist.d/)
find %{buildroot}/etc/nftban/conf.d -name 'whitelist.txt' -delete 2>/dev/null || true
install -D -m 0640 install/config/feeds.conf %{buildroot}/etc/nftban/conf.d/feeds.conf
install -D -m 0640 install/config/conf.d/watchdog.conf %{buildroot}/etc/nftban/conf.d/watchdog.conf
install -D -m 0640 install/config/conf.d/metrics.conf %{buildroot}/etc/nftban/conf.d/metrics.conf
install -D -m 0640 install/config/conf.d/persistent.conf %{buildroot}/etc/nftban/conf.d/persistent.conf

# Pattern files (patterns.d for botscan)
mkdir -p %{buildroot}/etc/nftban/patterns.d/botscan
cp etc/nftban/patterns.d/botscan/*.patterns %{buildroot}/etc/nftban/patterns.d/botscan/

# Logrotate configuration
install -D -m 0644 install/config/nftban.logrotate %{buildroot}/etc/logrotate.d/nftban

# Suricata profile templates and config directories
mkdir -p %{buildroot}/etc/nftban/suricata/profiles
mkdir -p %{buildroot}/etc/nftban/suricata/config
mkdir -p %{buildroot}/etc/nftban/suricata/rules
mkdir -p %{buildroot}/etc/nftban/suricata/cache
install -D -m 0644 etc/nftban/suricata/profiles/minimal.yaml %{buildroot}/etc/nftban/suricata/profiles/minimal.yaml
install -D -m 0644 etc/nftban/suricata/profiles/standard.yaml %{buildroot}/etc/nftban/suricata/profiles/standard.yaml
install -D -m 0644 etc/nftban/suricata/profiles/maximum.yaml %{buildroot}/etc/nftban/suricata/profiles/maximum.yaml
install -D -m 0664 etc/nftban/suricata/config/profile.conf %{buildroot}/etc/nftban/suricata/config/profile.conf

# Distro configuration files (CRITICAL for distro-aware paths)
mkdir -p %{buildroot}/etc/nftban/distros
cp etc/nftban/distros/*.conf %{buildroot}/etc/nftban/distros/

# Manual whitelist/blacklist files (user-managed, noreplace)
mkdir -p %{buildroot}/etc/nftban/whitelist.d
mkdir -p %{buildroot}/etc/nftban/blacklist.d
install -m 0640 etc/nftban/whitelist.d/99-manual.conf %{buildroot}/etc/nftban/whitelist.d/99-manual.conf
install -m 0640 etc/nftban/blacklist.d/99-manual.conf %{buildroot}/etc/nftban/blacklist.d/99-manual.conf

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
install -D -m 0644 install/systemd/nftban-unified-exporter.service %{buildroot}/usr/lib/systemd/system/nftban-unified-exporter.service
install -D -m 0644 install/systemd/nftban-unified-exporter.timer %{buildroot}/usr/lib/systemd/system/nftban-unified-exporter.timer
install -D -m 0644 install/systemd/nftban-watchdog.service %{buildroot}/usr/lib/systemd/system/nftban-watchdog.service
install -D -m 0644 install/systemd/nftban-watchdog.timer %{buildroot}/usr/lib/systemd/system/nftban-watchdog.timer
install -D -m 0644 install/systemd/nftban-snapshot.service %{buildroot}/usr/lib/systemd/system/nftban-snapshot.service
install -D -m 0644 install/systemd/nftban-snapshot.timer %{buildroot}/usr/lib/systemd/system/nftban-snapshot.timer
install -D -m 0644 install/systemd/nftban-rollback.service %{buildroot}/usr/lib/systemd/system/nftban-rollback.service
install -D -m 0644 install/systemd/nftban-rollback.timer %{buildroot}/usr/lib/systemd/system/nftban-rollback.timer
install -D -m 0644 install/systemd/nftban-suricata-update.service %{buildroot}/usr/lib/systemd/system/nftban-suricata-update.service
install -D -m 0644 install/systemd/nftban-suricata-update.timer %{buildroot}/usr/lib/systemd/system/nftban-suricata-update.timer
install -D -m 0644 install/systemd/nftban-suricata.service %{buildroot}/usr/lib/systemd/system/nftban-suricata.service
install -D -m 0644 install/systemd/nftban-suricata-stats.service %{buildroot}/usr/lib/systemd/system/nftban-suricata-stats.service
install -D -m 0644 install/systemd/nftban-ui.service %{buildroot}/usr/lib/systemd/system/nftban-ui.service
install -D -m 0644 install/systemd/nftban-ui-auth.service %{buildroot}/usr/lib/systemd/system/nftban-ui-auth.service
install -D -m 0644 install/systemd/nftban-queue.service %{buildroot}/usr/lib/systemd/system/nftban-queue.service
install -D -m 0644 install/systemd/nftban-health-fix.service %{buildroot}/usr/lib/systemd/system/nftban-health-fix.service
install -D -m 0644 install/systemd/nftban-rbl-check.service %{buildroot}/usr/lib/systemd/system/nftban-rbl-check.service
install -D -m 0644 install/systemd/nftban-rbl-check.timer %{buildroot}/usr/lib/systemd/system/nftban-rbl-check.timer
install -D -m 0644 install/systemd/nftband.service %{buildroot}/usr/lib/systemd/system/nftband.service
install -D -m 0644 install/systemd/nftband.socket %{buildroot}/usr/lib/systemd/system/nftband.socket

# PolicyKit rules (v1.0.19: Consolidated 6 files → 3 files)
# Removed: com.nftban.suricata.policy (unused custom actions)
# Removed: 50-nftban-auth.rules (auth-helper never existed)
# Removed: 50-nftban-v030.rules (auditor placeholder)
# Removed: 60-nftban-services.rules (unsafe wildcard pattern)
# Consolidated: 10-nftban-core + 20-nftban-suricata → 10-nftban-systemd
# Added: 20-nftban-auditor.rules (auditor group)
# Added: 30-nftban-panel.rules (panel group)
install -D -m 0644 packaging/polkit-1/rules.d/10-nftban-systemd.rules %{buildroot}/etc/polkit-1/rules.d/10-nftban-systemd.rules
install -D -m 0644 packaging/polkit-1/rules.d/20-nftban-auditor.rules %{buildroot}/etc/polkit-1/rules.d/20-nftban-auditor.rules
install -D -m 0644 packaging/polkit-1/rules.d/30-nftban-panel.rules %{buildroot}/etc/polkit-1/rules.d/30-nftban-panel.rules

# Validator spec file
install -D -m 0644 install/share/nftban/specs/structure_default.json %{buildroot}/usr/share/nftban/specs/structure_default.json

# Templates (mail, reports, email, partials)
find install/share/nftban/templates -type f -name "*.html" | while read -r tmpl; do
    rel_path="\${tmpl#install/share/nftban/templates/}"
    install -D -m 0644 "\$tmpl" "%{buildroot}/usr/share/nftban/templates/\$rel_path"
done

# Man page
install -D -m 0644 install/man/man8/nftban.8 %{buildroot}/usr/share/man/man8/nftban.8

# Bash completion
install -D -m 0644 install/bash-completion/nftban %{buildroot}/usr/share/bash-completion/completions/nftban

# Commands Registry (v1.0.16 - single source of truth)
install -D -m 0644 commands.registry.yml %{buildroot}/etc/nftban/commands.registry.yml

# Documentation generators (v1.0.16)
mkdir -p %{buildroot}/usr/lib/nftban/scripts
install -m 0755 scripts/generate-help.sh %{buildroot}/usr/lib/nftban/scripts/generate-help.sh
install -m 0755 scripts/generate-wiki-operator.sh %{buildroot}/usr/lib/nftban/scripts/generate-wiki-operator.sh
install -m 0755 scripts/generate-wiki-auditor.sh %{buildroot}/usr/lib/nftban/scripts/generate-wiki-auditor.sh

# Documentation moved to wiki (v1.0.20+)
# See: https://github.com/itcmsgr/nftban/wiki

# Test scripts
mkdir -p %{buildroot}/usr/lib/nftban/tests
find cli/lib/nftban/tests -type f -name "*.sh" -exec install -m 0755 {} %{buildroot}/usr/lib/nftban/tests/ \;

# Config directories (must match %files section)
mkdir -p %{buildroot}/etc/nftban/{conf.d,distros,whitelist.d,blacklist.d,ports.d,rules.d}
mkdir -p %{buildroot}/var/lib/nftban/{feeds,geoip,staging,reports}
mkdir -p %{buildroot}/var/log/nftban
mkdir -p %{buildroot}/var/cache/nftban
mkdir -p %{buildroot}/run/nftban

%pretrans -p <lua>
-- Remove immutable flag before upgrade (runs FIRST, before old pkg scripts)
-- The nft_schema.sh file is protected with chattr +i for security.
-- Without this, RPM fails: "cpio: rename failed - No data available"
local schema_file = "/usr/lib/nftban/lib/nft_schema.sh"
local f = io.open(schema_file, "r")
if f then
    f:close()
    os.execute("/usr/bin/chattr -i " .. schema_file .. " 2>/dev/null")
    os.execute("/bin/chattr -i " .. schema_file .. " 2>/dev/null")
    os.execute("chattr -i " .. schema_file .. " 2>/dev/null")
    os.execute("/usr/bin/chattr -i -R /usr/lib/nftban 2>/dev/null")
end

%pre
# =============================================================================
# NFTBan - PREREQUISITE CHECKS
# =============================================================================
echo ""
echo "════════════════════════════════════════════════════════════════════════════════"
echo "  NFTBan v%{version} - Installation Prerequisite Checks"
echo "════════════════════════════════════════════════════════════════════════════════"
echo ""

PREREQ_FAILED=0

# -----------------------------------------------------------------------------
# CHECK 1: Operating System Version
# -----------------------------------------------------------------------------
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "[✓] Operating System: \$PRETTY_NAME"

    # Check for supported OS
    case "\$ID" in
        rhel|rocky|almalinux|centos|fedora)
            echo "[✓] Supported OS family: RHEL/Rocky/AlmaLinux/CentOS/Fedora"
            ;;
        *)
            echo "[!] Warning: Untested OS: \$ID (may work, but not officially supported)"
            ;;
    esac
else
    echo "[✗] ERROR: Cannot detect OS version (/etc/os-release missing)"
    PREREQ_FAILED=1
fi

# -----------------------------------------------------------------------------
# CHECK 2: Required Commands
# -----------------------------------------------------------------------------
echo ""
echo "Checking required commands..."

# Critical commands (must be present)
for cmd in nft systemctl curl jq tar; do
    if command -v \$cmd >/dev/null 2>&1; then
        echo "[✓] Found: \$cmd"
    else
        echo "[✗] MISSING: \$cmd (CRITICAL)"
        PREREQ_FAILED=1
    fi
done

# Optional commands (nice to have, but not critical)
if command -v ip >/dev/null 2>&1; then
    echo "[✓] Found: ip (iproute2)"
else
    echo "[i] Info: ip command not found (optional, will use fallback methods)"
fi

# Check for other firewall tools
echo ""
echo "Checking for other firewall tools..."
LEGACY_FOUND=0

if command -v iptables >/dev/null 2>&1 || command -v ip6tables >/dev/null 2>&1; then
    # Differentiate iptables-nft (conflicts) vs iptables-legacy (co-exists)
    IPT_VERSION=\$(iptables --version 2>/dev/null || echo "")
    if echo "\$IPT_VERSION" | grep -q "nf_tables"; then
        echo "[!] WARNING: iptables-nft detected (iptables-over-nftables wrapper)"
        echo "    iptables-nft translates iptables rules into nftables and may"
        echo "    create conflicting tables (e.g. 'ip filter')."
        echo "    Recommended: switch to iptables-legacy or remove iptables-nft"
        LEGACY_FOUND=1
    else
        echo "[i] INFO: iptables detected (co-exists with nftables)"
        echo "    iptables-legacy uses a separate kernel API from nftables."
        echo "    Both can run simultaneously. NFTBan uses its own 'nftban' table."
        echo "    cPanel/WHM and other hosting panels may require iptables."
    fi
fi

if command -v ufw >/dev/null 2>&1; then
    echo "[!] WARNING: ufw installed (manages nftables/iptables backend)"
    echo "    NFTBan manages nftables directly. ufw may conflict."
    echo "    Recommended: dnf remove ufw"
    LEGACY_FOUND=1
fi

if command -v firewall-cmd >/dev/null 2>&1; then
    echo "[!] WARNING: firewalld installed (conflicts with nftables)"
    echo "    NFTBan manages nftables directly. firewalld should be removed."
    echo "    Recommended: dnf remove firewalld"
    LEGACY_FOUND=1
fi

if [ \$LEGACY_FOUND -eq 0 ]; then
    echo "[✓] No conflicting firewall tools detected"
fi

# -----------------------------------------------------------------------------
# CHECK 3: Kernel nftables Support
# -----------------------------------------------------------------------------
echo ""
echo "Checking kernel nftables support..."

if [ -d /proc/sys/net/netfilter ]; then
    echo "[✓] Netfilter subsystem available"
else
    echo "[✗] ERROR: Netfilter not available in kernel"
    PREREQ_FAILED=1
fi

# Check if nft can list rulesets (indicates kernel support)
if nft list ruleset >/dev/null 2>&1; then
    echo "[✓] nftables kernel modules loaded"
else
    echo "[!] Warning: nftables modules not loaded (will auto-load on first use)"
fi

# -----------------------------------------------------------------------------
# CHECK 4: Conflicting Firewall Services
# -----------------------------------------------------------------------------
echo ""
echo "Checking for conflicting firewall services..."

CONFLICTS_FOUND=0

# Check firewalld
if systemctl is-active firewalld >/dev/null 2>&1; then
    echo "[!] WARNING: firewalld is ACTIVE"
    echo "    NFTBan manages nftables directly and may conflict with firewalld."
    echo "    Recommended action:"
    echo "      systemctl stop firewalld"
    echo "      systemctl disable firewalld"
    echo ""
    CONFLICTS_FOUND=1
fi

# Check ufw
if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "[!] WARNING: ufw is ACTIVE"
        echo "    NFTBan manages nftables directly and may conflict with ufw."
        echo "    Recommended action:"
        echo "      ufw disable"
        echo ""
        CONFLICTS_FOUND=1
    fi
fi

# Check iptables services - differentiate iptables-nft (conflict) vs iptables-legacy (OK)
for svc in iptables ip6tables; do
    if systemctl is-active \$svc >/dev/null 2>&1; then
        IPT_SVC_VERSION=\$(iptables --version 2>/dev/null || echo "")
        if echo "\$IPT_SVC_VERSION" | grep -q "nf_tables"; then
            echo "[!] WARNING: \$svc service is ACTIVE (iptables-nft backend)"
            echo "    iptables-nft creates nftables tables that may conflict with NFTBan."
            echo "    Recommended action:"
            echo "      systemctl stop \$svc"
            echo "      systemctl disable \$svc"
            echo ""
            CONFLICTS_FOUND=1
        else
            echo "[i] INFO: \$svc service is ACTIVE (iptables-legacy backend)"
            echo "    iptables-legacy co-exists with nftables (separate kernel APIs)."
            echo "    cPanel/WHM, CSF/LFD, and cPHulk may require this service."
        fi
    fi
done

if [ \$CONFLICTS_FOUND -eq 0 ]; then
    echo "[✓] No conflicting firewall services detected"
fi

# -----------------------------------------------------------------------------
# CHECK 5: Required Repositories (Information Only)
# -----------------------------------------------------------------------------
echo ""
echo "Checking available repositories..."

# Check for EPEL (informational - not critical)
if dnf repolist enabled 2>/dev/null | grep -q epel; then
    echo "[✓] EPEL repository: enabled"
else
    echo "[i] Info: EPEL repository not enabled"
    echo "    Some optional packages may require EPEL."
    echo "    To enable: dnf install -y epel-release"
    echo ""
fi

# Check for CRB/PowerTools (informational)
if dnf repolist enabled 2>/dev/null | grep -qE 'crb|powertools|codeready'; then
    echo "[✓] CRB/PowerTools repository: enabled"
else
    echo "[i] Info: CRB repository not enabled (usually not needed)"
    echo "    To enable: dnf config-manager --set-enabled crb"
    echo ""
fi

# -----------------------------------------------------------------------------
# CHECK 6: Network Connectivity (for GeoIP download)
# -----------------------------------------------------------------------------
echo ""
echo "Checking network connectivity..."

if curl -sI --connect-timeout 5 https://github.com >/dev/null 2>&1; then
    echo "[✓] Internet connectivity: OK (github.com reachable)"
else
    echo "[!] Warning: Cannot reach github.com"
    echo "    GeoIP database download may fail."
    echo "    You can manually download later: nftban-core geoip update"
    echo ""
fi

# -----------------------------------------------------------------------------
# FINAL RESULT
# -----------------------------------------------------------------------------
echo ""
echo "════════════════════════════════════════════════════════════════════════════════"

if [ \$PREREQ_FAILED -eq 1 ]; then
    echo "[✗] PREREQUISITE CHECK FAILED"
    echo ""
    echo "Critical requirements are missing. Please fix the errors above and try again."
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo ""
    exit 1
fi

if [ \$CONFLICTS_FOUND -eq 1 ]; then
    echo "[!] WARNING: Firewall conflicts detected"
    echo ""
    echo "NFTBan can still be installed, but conflicts may cause issues."
    echo "Recommended: Disable conflicting firewalls before continuing."
    echo ""
    echo "To proceed anyway, you can ignore this warning."
    echo "To abort installation, press Ctrl+C now (waiting 10 seconds)..."
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo ""
    sleep 10
fi

echo "[✓] All critical prerequisites satisfied"
echo "════════════════════════════════════════════════════════════════════════════════"
echo ""

# =============================================================================
# STEP 1: Create system groups
# =============================================================================
# NFTBan v1.0.19 uses 3-group model:
#   nftban: All operators (CLI + full service management)
#   nftban-auditor: Read-only audit access (systemd status queries)
#   nftban-panel: Panel integration (limited reload access)
getent group nftban >/dev/null || groupadd -r nftban
getent group nftban-auditor >/dev/null || groupadd -r nftban-auditor
getent group nftban-panel >/dev/null || groupadd -r nftban-panel

# Backward compatibility: nftban-auditor → nftban-auditor (renamed in v1.0.19)
if getent group nftban-auditor >/dev/null 2>&1; then
    echo "[NFTBan] Migrating nftban-auditor → nftban-auditor group..."
    # Copy members from old group to new group
    for member in \$(getent group nftban-auditor | cut -d: -f4 | tr ',' ' '); do
        usermod -a -G nftban-auditor "\$member" 2>/dev/null || true
    done
fi

# Create system user
getent passwd nftban >/dev/null || useradd -r -g nftban -d /var/lib/nftban -s /usr/sbin/nologin -c "NFTBan system user" nftban

# Add root to nftban group for CLI access
usermod -a -G nftban root 2>/dev/null || true

%post
# =============================================================================
# NFTBan v1.0.19 - SAFE INSTALL/UPGRADE FLOW
# =============================================================================
# Order: cleanup -> groups -> dirs -> perms -> polkit -> whitelist -> health -> services

# =============================================================================
# STEP 0: Cleanup obsolete files from previous versions
# =============================================================================
echo "[NFTBan] Cleaning up obsolete files from previous versions..."

# Remove obsolete Polkit rules (v1.0.18 and earlier)
rm -f /etc/polkit-1/rules.d/10-nftban-core.rules 2>/dev/null || true
rm -f /etc/polkit-1/rules.d/20-nftban-suricata.rules 2>/dev/null || true
rm -f /etc/polkit-1/rules.d/50-nftban-auth.rules 2>/dev/null || true
rm -f /etc/polkit-1/rules.d/50-nftban-auth.rules.in 2>/dev/null || true
rm -f /etc/polkit-1/rules.d/50-nftban-v030.rules 2>/dev/null || true
rm -f /etc/polkit-1/rules.d/60-nftban-services.rules 2>/dev/null || true
rm -f /usr/share/polkit-1/rules.d/10-nftban-core.rules 2>/dev/null || true
rm -f /usr/share/polkit-1/rules.d/20-nftban-suricata.rules 2>/dev/null || true
rm -f /usr/share/polkit-1/rules.d/50-nftban-auth.rules 2>/dev/null || true
rm -f /usr/share/polkit-1/rules.d/50-nftban-v030.rules 2>/dev/null || true
rm -f /usr/share/polkit-1/rules.d/60-nftban-services.rules 2>/dev/null || true

# Remove obsolete Polkit actions
rm -f /usr/share/polkit-1/actions/com.nftban.suricata.policy 2>/dev/null || true

# Remove obsolete port-status rules (v1.0.15 and earlier - security risk)
rm -f /etc/polkit-1/rules.d/50-nftban-port-status.rules 2>/dev/null || true
rm -f /etc/polkit-1/rules.d/50-nftban-port-status.rules.in 2>/dev/null || true
rm -f /usr/share/polkit-1/rules.d/50-nftban-port-status.rules 2>/dev/null || true

# Remove stale nested directories from previous versions (v1.13.9 and earlier)
if [ -d "/usr/lib/nftban/lib/nftban" ]; then
    rm -rf "/usr/lib/nftban/lib/nftban"
    echo "[NFTBan] Removed stale: /usr/lib/nftban/lib/nftban/"
fi
if [ -d "/usr/lib/nftban/etc" ]; then
    rm -rf "/usr/lib/nftban/etc"
    echo "[NFTBan] Removed stale: /usr/lib/nftban/etc/"
fi

echo "[NFTBan] Obsolete file cleanup complete"

# =============================================================================
# Rest of install flow continues below...
# =============================================================================
# This prevents lockout by ensuring whitelist is in place BEFORE firewall is active.

echo "[NFTBan] Configuring NFTBan v%{version}..."

# STEP 1: Remove old systemd overrides (prevent conflicts with new package files)
echo "[NFTBan] Removing old systemd overrides..."
rm -f /etc/systemd/system/nftban-*.service 2>/dev/null || true
rm -f /etc/systemd/system/nftban-*.timer 2>/dev/null || true
rm -rf /etc/systemd/system/nftban-*.service.d 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

# STEP 2: Create FHS directories
echo "[NFTBan] Creating FHS directories..."
mkdir -p /etc/nftban/{conf.d,distros,whitelist.d,blacklist.d,ports.d,rules.d,patterns.d}
mkdir -p /etc/nftban/conf.d/{ddos,portscan,login,panels,botscan,rbl}
mkdir -p /etc/nftban/patterns.d/botscan
mkdir -p /var/lib/nftban/{banned,whitelist,feeds,geoip,reports,config,state,metrics,snapshots,exports,panels}
mkdir -p /var/lib/nftban/reports/{baseline,auditors}
mkdir -p /var/log/nftban/reports
mkdir -p /var/cache/nftban/health
mkdir -p /run/nftban
mkdir -p /usr/share/nftban/templates/{mail,reports}

# =============================================================================
# STEP 3: Set permissions via FHS spec (single source of truth - DEB parity)
# =============================================================================
# Uses the same centralized permission function as DEB postinst.
# This ensures identical behavior across packaging formats and includes:
# - Directory ownership and modes
# - Auditor group ACLs
# - Capability settings
echo "[NFTBan] Setting permissions via FHS spec..."

if [ -f /usr/lib/nftban/setup/fhs-permissions.sh ]; then
    # Source the central permissions script
    . /usr/lib/nftban/setup/fhs-permissions.sh

    # Call the single source-of-truth permission function
    if declare -f nftban_install_set_file_permissions >/dev/null 2>&1; then
        nftban_install_set_file_permissions
        echo "[NFTBan] FHS permissions and ACLs configured"
    else
        echo "[NFTBan WARN] Permission function not found in fhs-permissions.sh"
        # Fallback: minimal critical permissions
        chown root:nftban /etc/nftban 2>/dev/null || true
        chmod 750 /etc/nftban 2>/dev/null || true
        chown -R nftban:nftban /var/lib/nftban /var/log/nftban 2>/dev/null || true
    fi
else
    echo "[NFTBan WARN] fhs-permissions.sh not found - using fallback permissions"
    # Fallback: minimal critical permissions only
    chown root:nftban /etc/nftban 2>/dev/null || true
    chmod 750 /etc/nftban 2>/dev/null || true
    chown -R root:nftban /etc/nftban/conf.d 2>/dev/null || true
    find /etc/nftban/conf.d -type d -exec chmod 750 {} \; 2>/dev/null || true
    find /etc/nftban/conf.d -type f -exec chmod 640 {} \; 2>/dev/null || true
    chown -R nftban:nftban /var/lib/nftban /var/log/nftban /var/cache/nftban 2>/dev/null || true
    chmod 750 /var/lib/nftban /var/log/nftban 2>/dev/null || true
fi

# Set executable on shell scripts (always needed after cp -r)
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

# STEP 7: Enforce permissions and health check
if command -v nftban >/dev/null 2>&1; then
    echo "[NFTBan] Enforcing permissions..."
    nftban permissions enforce 2>/dev/null || true
    echo "[NFTBan] Running health check with auto-heal..."
    nftban health check --auto-heal --quiet 2>/dev/null || true
fi

# STEP 8: Enable services (AFTER whitelist is in place)
echo "[NFTBan] Enabling systemd services..."
%systemd_post nftban-maintenance.service nftban-maintenance.timer nftban-health.service nftban-health.timer nftban-login-monitor.service nftban-core-geoip.timer nftban-core-feeds.timer nftban-unified-exporter.timer

# Enable nftables
systemctl enable nftables 2>/dev/null || true

# Enable and start nftband daemon socket (CRITICAL for CLI communication)
echo "[NFTBan] Starting nftband daemon..."
systemctl enable --now nftband.socket 2>/dev/null || true

# Enable and start essential timers
echo "[NFTBan] Starting essential timers..."
systemctl enable --now nftban-maintenance.timer 2>/dev/null || true
systemctl enable --now nftban-health.timer 2>/dev/null || true
systemctl enable --now nftban-core-geoip.timer 2>/dev/null || true
systemctl enable --now nftban-core-feeds.timer 2>/dev/null || true
systemctl enable --now nftban-queue.timer 2>/dev/null || true

# Enable and start login monitor
systemctl enable --now nftban-login-monitor.service 2>/dev/null || true

# STEP 9: Configure nftables to load NFTBan config (distro-aware)
echo "[NFTBan] Configuring nftables service..."
# Source distro config library to get correct paths
if [ -f /usr/lib/nftban/lib/nftban_distro_config.sh ]; then
    source /usr/lib/nftban/lib/nftban_distro_config.sh 2>/dev/null || true

    # Get distro-specific nftables.conf path
    nftban_distro_load_config 2>/dev/null || true
    SYSTEM_NFT_CONF=\$(nftban_distro_get_path "nftables_conf" 2>/dev/null)

    if [ -n "\$SYSTEM_NFT_CONF" ] && [ -f "\$SYSTEM_NFT_CONF" ]; then
        # Check if already configured
        if ! grep -q "/etc/nftban/nftables.conf" "\$SYSTEM_NFT_CONF" 2>/dev/null; then
            echo "# NFTBan firewall configuration" >> "\$SYSTEM_NFT_CONF"
            echo "include \\"/etc/nftban/nftables.conf\\"" >> "\$SYSTEM_NFT_CONF"
            echo "[NFTBan] Added NFTBan config to \$SYSTEM_NFT_CONF"
        fi
    fi
fi

# STEP 10: Sync whitelist.d files to nftables sets BEFORE starting nftables
# ROOT CAUSE FIX: Previously nftables started with DROP policy BEFORE whitelist
# sync, causing SSH lockout. Now we sync FIRST, then start nftables.
# The nftables template has only default IPs, this loads the actual detected system IPs
echo "[NFTBan] Syncing whitelist files to nftables..."
# Wait for nftband daemon to be ready (socket activation)
SYNC_SUCCESS=0
for i in 1 2 3; do
    sleep 1
    # Use nftban CLI sync command (connects to nftband daemon)
    if nftban sync >/dev/null 2>&1; then
        SYNC_SUCCESS=1
        echo "[NFTBan]   Whitelist sync completed successfully"
        break
    fi
done
if [ "\$SYNC_SUCCESS" -eq 0 ]; then
    echo "[NFTBan WARN] Whitelist sync failed (run manually: nftban sync)"
fi

# STEP 11: Load nftables configuration AFTER whitelist is synced
# This ensures DROP policy only takes effect when SSH whitelist is in place
if systemctl is-active nftables >/dev/null 2>&1; then
    systemctl reload nftables 2>/dev/null || echo "[NFTBan WARN] nftables reload failed"
else
    systemctl enable nftables 2>/dev/null || true
    systemctl start nftables 2>/dev/null || echo "[NFTBan WARN] nftables start failed"
fi

echo "[NFTBan] Installation complete. Your IP has been auto-whitelisted."
echo "[NFTBan] Essential timers started. Run 'nftban timers enable' to start all optional timers."

%preun
# Remove immutable flag before uninstall/upgrade to allow RPM to replace/remove files
if [ -f /usr/lib/nftban/lib/nft_schema.sh ]; then
    chattr -i /usr/lib/nftban/lib/nft_schema.sh 2>/dev/null || true
fi
%systemd_preun nftban-maintenance.service nftban-maintenance.timer nftban-health.service nftban-health.timer nftban-login-monitor.service nftban-core-geoip.service nftban-core-geoip.timer nftban-core-feeds.service nftban-core-feeds.timer nftban-unified-exporter.service nftban-unified-exporter.timer

%postun
%systemd_postun_with_restart nftban-maintenance.service nftban-health.service nftban-login-monitor.service nftban-core-geoip.service nftban-core-feeds.service nftban-unified-exporter.service

# Inform user about leftover files on complete removal
if [ \$1 -eq 0 ]; then
    echo "nftban: Configuration files in /etc/nftban/ have been preserved."
    echo "nftban: Log files in /var/log/nftban/ have been preserved."
    echo "nftban: User accounts and groups have NOT been removed."
fi

%files
/usr/sbin/nftban
/usr/sbin/nftban-ui
/usr/libexec/nftban-ui-auth
/usr/lib/nftban/bin
/usr/lib/nftban/sbin
/usr/lib/nftban/VERSION
/usr/lib/nftban/cli
/usr/lib/nftban/core
/usr/lib/nftban/lib
/usr/lib/nftban/cron
/usr/lib/nftban/helpers
/usr/lib/nftban/setup
/usr/lib/nftban/exporters
/usr/lib/nftban/tests
/usr/lib/nftban/data
/usr/lib/nftban/health
/usr/lib/nftban/*.sh
%doc /usr/lib/nftban/README.md
# Main config files - root:nftban so services can read configs
%attr(640,root,nftban) %config(noreplace) /etc/nftban/nftban.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/nftables.conf
%config(noreplace) /etc/logrotate.d/nftban
/usr/lib/systemd/system/*.service
/usr/lib/systemd/system/*.socket
/usr/lib/systemd/system/*.timer
/etc/polkit-1/rules.d/10-nftban-systemd.rules
/etc/polkit-1/rules.d/20-nftban-auditor.rules
/etc/polkit-1/rules.d/30-nftban-panel.rules
/usr/share/nftban/specs/structure_default.json
/usr/share/nftban/templates
/usr/share/man/man8/nftban.8*
/usr/share/bash-completion/completions/nftban
%attr(644,root,nftban) %config(noreplace) /etc/nftban/commands.registry.yml
/usr/lib/nftban/scripts/generate-help.sh
/usr/lib/nftban/scripts/generate-wiki-operator.sh
/usr/lib/nftban/scripts/generate-wiki-auditor.sh
# Config directories - root:nftban so services can read configs
%dir %attr(750,root,nftban) /etc/nftban
%dir %attr(750,root,nftban) /etc/nftban/conf.d
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/*.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/ddos
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/ddos/*.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/login
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/login/*.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/portscan
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/portscan/*.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/suricata
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/suricata/interfaces.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/rbl
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/rbl/*
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/directadmin
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/directadmin/*.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/cpanel
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/cpanel/*.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/cwp
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/cwp/*.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/cyberpanel
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/cyberpanel/*.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/interworx
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/interworx/*.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/vesta
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/vesta/*.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/generic
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/generic/*.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/panels/plesk
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/plesk/*.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/botscan
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/botscan/*.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/geoban
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/geoban/main.conf
%dir %attr(750,root,nftban) /etc/nftban/conf.d/geoip
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/geoip/main.conf
%dir %attr(750,root,nftban) /etc/nftban/patterns.d
%dir %attr(750,root,nftban) /etc/nftban/patterns.d/botscan
%attr(640,root,nftban) %config(noreplace) /etc/nftban/patterns.d/botscan/*.patterns
%dir %attr(750,root,nftban) /etc/nftban/distros
%attr(644,root,nftban) /etc/nftban/distros/*.conf
%dir %attr(750,root,nftban) /etc/nftban/suricata
%dir %attr(750,root,nftban) /etc/nftban/suricata/profiles
%attr(640,root,nftban) %config(noreplace) /etc/nftban/suricata/profiles/*.yaml
%dir %attr(750,root,nftban) /etc/nftban/suricata/config
%config(noreplace) %attr(664,root,nftban) /etc/nftban/suricata/config/profile.conf
%dir %attr(750,root,nftban) /etc/nftban/suricata/rules
%dir %attr(750,root,nftban) /etc/nftban/suricata/cache
%dir %attr(750,root,nftban) /etc/nftban/whitelist.d
%config(noreplace) %attr(640,root,nftban) /etc/nftban/whitelist.d/99-manual.conf
%dir %attr(750,root,nftban) /etc/nftban/blacklist.d
%config(noreplace) %attr(640,root,nftban) /etc/nftban/blacklist.d/99-manual.conf
%dir %attr(750,root,nftban) /etc/nftban/ports.d
%dir %attr(750,root,nftban) /etc/nftban/rules.d
%dir %attr(750,nftban,nftban) /var/lib/nftban
%dir %attr(750,nftban,nftban) /var/lib/nftban/feeds
%dir %attr(750,nftban,nftban) /var/lib/nftban/geoip
%dir %attr(750,nftban,nftban) /var/lib/nftban/staging
%dir %attr(750,nftban,nftban) /var/lib/nftban/reports
%dir %attr(750,nftban,nftban) /var/log/nftban
%dir %attr(755,root,root) /var/cache/nftban
%dir %attr(755,nftban,nftban) /run/nftban

%changelog
* Mon Dec 09 2024 NFTBan Team <noreply@nftban.com> - 1.0.0-1
- NFTBan v1.0.0 release
- SAFE INSTALL FLOW: Auto-whitelist before enabling firewall
- FHS compliant directory structure
- 2-group security model (nftban, nftban-auditor)
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

    # Verify all required directories exist before creating tarball
    log_info "Verifying source directories for tarball..."
    local missing_dirs=()
    for dir in bin cli cmd pkg install etc internal packaging scripts docs; do
        if [[ ! -d "${PROJECT_ROOT}/${dir}" ]]; then
            missing_dirs+=("${dir}")
        fi
    done

    if [[ ${#missing_dirs[@]} -gt 0 ]]; then
        log_error "Missing required directories: ${missing_dirs[*]}"
        log_error "PROJECT_ROOT=${PROJECT_ROOT}"
        ls -la "${PROJECT_ROOT}/" || true
        return 1
    fi

    # Create tarball with error checking
    log_info "Creating source tarball: ${tarball}"
    if ! tar czf "${BUILD_DIR}/SOURCES/${tarball}" \
        --transform "s,^,nftban-core-${PKG_VERSION}/," \
        -C "${PROJECT_ROOT}" \
        bin/ cli/ cmd/ pkg/ install/ etc/ internal/ packaging/ scripts/ docs/ \
        VERSION go.mod go.sum LICENSE README.md commands.registry.yml; then
        log_error "Failed to create source tarball"
        log_error "tar command failed with exit code $?"
        return 1
    fi

    # Verify tarball was created
    if [[ ! -f "${BUILD_DIR}/SOURCES/${tarball}" ]]; then
        log_error "Tarball not found after creation: ${BUILD_DIR}/SOURCES/${tarball}"
        log_error "Contents of ${BUILD_DIR}/SOURCES/:"
        ls -la "${BUILD_DIR}/SOURCES/" || true
        return 1
    fi

    log_success "Tarball created: ${tarball} ($(stat -c%s "${BUILD_DIR}/SOURCES/${tarball}" 2>/dev/null || echo 'unknown') bytes)"

    # Build RPM (version from VERSION file)
    if rpmbuild --define "_topdir ${BUILD_DIR}" \
        --define "pkg_version ${PKG_VERSION}" \
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
Depends: nftables (>= 0.9.0), systemd, bash (>= 4.0), bash-completion, jq, curl, tar, gzip, libpam0g, bc, gawk, socat
Recommends: dnsutils, mailutils, whiptail
Maintainer: NFTBan Team <noreply@nftban.com>
Description: Open-source Linux IPS and nftables firewall manager
 NFTBan is an open-source Linux Intrusion Prevention System (IPS) and
 nftables firewall manager built for modern server and DevOps environments.
 .
 It uses a Go-based netlink daemon for asynchronous enforcement, applying
 security rules directly through the Linux kernel for low-latency threat
 response.
 .
 Key features include:
  * Native nftables integration designed for Linux 5.x+ systems,
    ensuring predictable rule evaluation and efficient kernel execution.
  * Dual-table architecture (ip nftban and ip6 nftban) providing
    clean IPv4 and IPv6 isolation.
  * Automated protection against SSH brute-force attacks,
    login abuse, port scans, and DDoS activity.
  * Support for real-time threat intelligence feeds and
    geographic IP blocking (Geo-IP).
  * Asynchronous rule management to maintain responsiveness
    even under high traffic conditions.
 .
 This package includes:
  - nftban-core binary (Go daemon)
  - nftban CLI (Bash)
  - Shell libraries (/usr/lib/nftban)
  - NFT Schema v1.0 configuration
  - Systemd units and timers
  - PolicyKit rules for privilege management
EOF

    # Create preinst script for prerequisite checks
    cat > "${BUILD_DIR}/deb/DEBIAN/preinst" <<'PREINST_EOF'
#!/bin/bash
# NFTBan - PREREQUISITE CHECKS (DEB)
set -e

# Remove immutable flag from nft_schema.sh before upgrade (security protection)
# The file is protected with chattr +i to prevent command injection attacks.
# dpkg cannot create backup links of immutable files, so we MUST remove the flag.
if [ -f /usr/lib/nftban/lib/nft_schema.sh ]; then
    chattr -i /usr/lib/nftban/lib/nft_schema.sh 2>/dev/null || true
    # Verify the flag was actually removed (chattr may not be available)
    if command -v lsattr >/dev/null 2>&1; then
        if lsattr /usr/lib/nftban/lib/nft_schema.sh 2>/dev/null | grep -q -- '----i'; then
            echo "[!] WARNING: Could not remove immutable flag from nft_schema.sh"
            echo "    Run: chattr -i /usr/lib/nftban/lib/nft_schema.sh"
            echo "    Then retry the installation."
            exit 1
        fi
    fi
fi

echo ""
echo "════════════════════════════════════════════════════════════════════════════════"
echo "  NFTBan v__PKG_VERSION__ - Installation Prerequisite Checks"
echo "════════════════════════════════════════════════════════════════════════════════"
echo ""

PREREQ_FAILED=0

# -----------------------------------------------------------------------------
# CHECK 1: Operating System Version
# -----------------------------------------------------------------------------
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "[✓] Operating System: $PRETTY_NAME"

    # Check for supported OS
    case "$ID" in
        ubuntu|debian|linuxmint)
            echo "[✓] Supported OS family: Debian/Ubuntu"
            IS_DEBIAN_FAMILY=1
            ;;
        *)
            echo "[!] Warning: Untested OS: $ID (may work, but not officially supported)"
            IS_DEBIAN_FAMILY=0
            ;;
    esac
else
    echo "[✗] ERROR: Cannot detect OS version (/etc/os-release missing)"
    PREREQ_FAILED=1
    IS_DEBIAN_FAMILY=0
fi

# -----------------------------------------------------------------------------
# CHECK 2: Check for missing dependencies
# -----------------------------------------------------------------------------
# NOTE: We cannot install packages here because dpkg holds the database lock.
# Dependencies are handled by apt when using: apt install ./package.deb
echo ""

echo "Checking required commands..."

# Critical commands (must be present)
for cmd in nft systemctl curl jq tar; do
    if command -v $cmd >/dev/null 2>&1; then
        echo "[✓] Found: $cmd"
    else
        echo "[✗] MISSING: $cmd (CRITICAL)"
        PREREQ_FAILED=1
    fi
done

# Optional commands (nice to have, but not critical)
if command -v ip >/dev/null 2>&1; then
    echo "[✓] Found: ip (iproute2)"
else
    echo "[i] Info: ip command not found (optional, will use fallback methods)"
fi

# Check for other firewall tools
echo ""
echo "Checking for other firewall tools..."
LEGACY_FOUND=0

if command -v iptables >/dev/null 2>&1 || command -v ip6tables >/dev/null 2>&1; then
    # Differentiate iptables-nft (conflicts) vs iptables-legacy (co-exists)
    IPT_VERSION=$(iptables --version 2>/dev/null || echo "")
    if echo "$IPT_VERSION" | grep -q "nf_tables"; then
        echo "[!] WARNING: iptables-nft detected (iptables-over-nftables wrapper)"
        echo "    iptables-nft translates iptables rules into nftables and may"
        echo "    create conflicting tables (e.g. 'ip filter')."
        echo "    Recommended: switch to iptables-legacy or remove iptables-nft"
        LEGACY_FOUND=1
    else
        echo "[i] INFO: iptables detected (co-exists with nftables)"
        echo "    iptables-legacy uses a separate kernel API from nftables."
        echo "    Both can run simultaneously. NFTBan uses its own 'nftban' table."
        echo "    cPanel/WHM and other hosting panels may require iptables."
    fi
fi

if command -v ufw >/dev/null 2>&1; then
    echo "[!] WARNING: ufw installed (manages nftables/iptables backend)"
    echo "    NFTBan manages nftables directly. ufw may conflict."
    echo "    Recommended: apt remove ufw"
    LEGACY_FOUND=1
fi

if command -v firewall-cmd >/dev/null 2>&1; then
    echo "[!] WARNING: firewalld installed (conflicts with nftables)"
    echo "    NFTBan manages nftables directly. firewalld should be removed."
    echo "    Recommended: apt remove firewalld"
    LEGACY_FOUND=1
fi

if [ $LEGACY_FOUND -eq 0 ]; then
    echo "[✓] No conflicting firewall tools detected"
fi

# -----------------------------------------------------------------------------
# CHECK 3: Kernel nftables Support
# -----------------------------------------------------------------------------
echo ""
echo "Checking kernel nftables support..."

if [ -d /proc/sys/net/netfilter ]; then
    echo "[✓] Netfilter subsystem available"
else
    echo "[✗] ERROR: Netfilter not available in kernel"
    PREREQ_FAILED=1
fi

# Check if nft can list rulesets (indicates kernel support)
if nft list ruleset >/dev/null 2>&1; then
    echo "[✓] nftables kernel modules loaded"
else
    echo "[!] Warning: nftables modules not loaded (will auto-load on first use)"
fi

# -----------------------------------------------------------------------------
# CHECK 4: Conflicting Firewall Services
# -----------------------------------------------------------------------------
echo ""
echo "Checking for conflicting firewall services..."

CONFLICTS_FOUND=0

# Check ufw (common on Ubuntu/Debian)
if command -v ufw >/dev/null 2>&1; then
    if ufw status 2>/dev/null | grep -q "Status: active"; then
        echo "[!] WARNING: ufw is ACTIVE"
        echo "    NFTBan manages nftables directly and may conflict with ufw."
        echo "    Recommended action:"
        echo "      ufw disable"
        echo ""
        CONFLICTS_FOUND=1
    fi
fi

# Check firewalld (rare on Debian but possible)
if systemctl is-active firewalld >/dev/null 2>&1; then
    echo "[!] WARNING: firewalld is ACTIVE"
    echo "    NFTBan manages nftables directly and may conflict with firewalld."
    echo "    Recommended action:"
        echo "      systemctl stop firewalld"
        echo "      systemctl disable firewalld"
    echo ""
    CONFLICTS_FOUND=1
fi

# Check iptables-persistent service - differentiate iptables-nft (conflict) vs legacy (OK)
if systemctl is-active iptables-persistent >/dev/null 2>&1 || systemctl is-active netfilter-persistent >/dev/null 2>&1; then
    IPT_SVC_VERSION=$(iptables --version 2>/dev/null || echo "")
    if echo "$IPT_SVC_VERSION" | grep -q "nf_tables"; then
        echo "[!] WARNING: iptables-persistent/netfilter-persistent is ACTIVE (iptables-nft backend)"
        echo "    iptables-nft creates nftables tables that may conflict with NFTBan."
        echo "    Recommended action:"
        echo "      systemctl stop netfilter-persistent"
        echo "      systemctl disable netfilter-persistent"
        echo ""
        CONFLICTS_FOUND=1
    else
        echo "[i] INFO: iptables-persistent/netfilter-persistent is ACTIVE (legacy backend)"
        echo "    iptables-legacy co-exists with nftables (separate kernel APIs)."
        echo "    cPanel/WHM, CSF/LFD, and cPHulk may require this service."
    fi
fi

if [ $CONFLICTS_FOUND -eq 0 ]; then
    echo "[✓] No conflicting firewall services detected"
fi

# -----------------------------------------------------------------------------
# CHECK 5: Network Connectivity (for GeoIP download)
# -----------------------------------------------------------------------------
echo ""
echo "Checking network connectivity..."

if curl -sI --connect-timeout 5 https://github.com >/dev/null 2>&1; then
    echo "[✓] Internet connectivity: OK (github.com reachable)"
else
    echo "[!] Warning: Cannot reach github.com"
    echo "    GeoIP database download may fail."
    echo "    You can manually download later: nftban-core geoip update"
    echo ""
fi

# -----------------------------------------------------------------------------
# FINAL RESULT
# -----------------------------------------------------------------------------
echo ""
echo "════════════════════════════════════════════════════════════════════════════════"

if [ $PREREQ_FAILED -eq 1 ]; then
    echo "[✗] PREREQUISITE CHECK FAILED"
    echo ""
    echo "Critical requirements are missing. Please install using apt (not dpkg):"
    echo ""
    echo "  sudo apt update"
    echo "  sudo apt install -y ./nftban-*.deb"
    echo ""
    echo "apt will automatically install missing dependencies (nftables, curl, jq)."
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo ""
    exit 1
fi

if [ $CONFLICTS_FOUND -eq 1 ]; then
    echo "[!] WARNING: Firewall conflicts detected"
    echo ""
    echo "NFTBan can still be installed, but conflicts may cause issues."
    echo "Recommended: Disable conflicting firewalls before continuing."
    echo ""
    echo "To proceed anyway, you can ignore this warning."
    echo "To abort installation, press Ctrl+C now (waiting 10 seconds)..."
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo ""
    sleep 10
fi

echo "[✓] All critical prerequisites satisfied"
echo "════════════════════════════════════════════════════════════════════════════════"
echo ""

exit 0
PREINST_EOF

    # Inject actual version into preinst (replace placeholder and any remaining v1.0.0)
    sed -i "s/__PKG_VERSION__/${PKG_VERSION}/g; s/v1\.0\.0/v${PKG_VERSION}/g" "${BUILD_DIR}/deb/DEBIAN/preinst"
    chmod 755 "${BUILD_DIR}/deb/DEBIAN/preinst"

    # Use the comprehensive postinst from packaging/deb/postinst
    if [[ -f "${PROJECT_ROOT}/packaging/deb/postinst" ]]; then
        cp "${PROJECT_ROOT}/packaging/deb/postinst" "${BUILD_DIR}/deb/DEBIAN/postinst"
    else
        # Fallback inline postinst with SAFE INSTALL FLOW
        cat > "${BUILD_DIR}/deb/DEBIAN/postinst" <<'EOF'
#!/bin/bash
# NFTBan v1.0.0 - SAFE INSTALL FLOW
set -e

echo "[NFTBan] Configuring NFTBan v1.0.19..."

# STEP 0: Cleanup obsolete files from previous versions
echo "[NFTBan] Cleaning up obsolete files from previous versions..."

# Remove obsolete Polkit rules (v1.0.18 and earlier)
rm -f /etc/polkit-1/rules.d/10-nftban-core.rules 2>/dev/null || true
rm -f /etc/polkit-1/rules.d/20-nftban-suricata.rules 2>/dev/null || true
rm -f /etc/polkit-1/rules.d/50-nftban-auth.rules 2>/dev/null || true
rm -f /etc/polkit-1/rules.d/50-nftban-auth.rules.in 2>/dev/null || true
rm -f /etc/polkit-1/rules.d/50-nftban-v030.rules 2>/dev/null || true
rm -f /etc/polkit-1/rules.d/60-nftban-services.rules 2>/dev/null || true
rm -f /usr/share/polkit-1/rules.d/10-nftban-core.rules 2>/dev/null || true
rm -f /usr/share/polkit-1/rules.d/20-nftban-suricata.rules 2>/dev/null || true
rm -f /usr/share/polkit-1/rules.d/50-nftban-auth.rules 2>/dev/null || true
rm -f /usr/share/polkit-1/rules.d/50-nftban-v030.rules 2>/dev/null || true
rm -f /usr/share/polkit-1/rules.d/60-nftban-services.rules 2>/dev/null || true

# Remove obsolete Polkit actions
rm -f /usr/share/polkit-1/actions/com.nftban.suricata.policy 2>/dev/null || true

# Remove obsolete port-status rules (v1.0.15 and earlier - security risk)
rm -f /etc/polkit-1/rules.d/50-nftban-port-status.rules 2>/dev/null || true
rm -f /etc/polkit-1/rules.d/50-nftban-port-status.rules.in 2>/dev/null || true
rm -f /usr/share/polkit-1/rules.d/50-nftban-port-status.rules 2>/dev/null || true

# Remove old systemd overrides (prevent conflicts with new package files)
echo "[NFTBan] Removing old systemd overrides..."
rm -f /etc/systemd/system/nftban-*.service 2>/dev/null || true
rm -f /etc/systemd/system/nftban-*.timer 2>/dev/null || true
rm -rf /etc/systemd/system/nftban-*.service.d 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

echo "[NFTBan] Obsolete file cleanup complete"

# STEP 1: Create groups (v1.0.19: 3-group model)
if ! getent group nftban >/dev/null; then
    addgroup --system nftban
fi
if ! getent group nftban-auditor >/dev/null; then
    addgroup --system nftban-auditor
fi
if ! getent group nftban-panel >/dev/null; then
    addgroup --system nftban-panel
fi

# Backward compatibility: nftban-auditor → nftban-auditor (renamed in v1.0.19)
if getent group nftban-auditor >/dev/null 2>&1; then
    echo "[NFTBan] Migrating nftban-auditor → nftban-auditor group..."
    for user in $(getent group nftban-auditor | cut -d: -f4 | tr ',' ' '); do
        usermod -a -G nftban-auditor "$user" 2>/dev/null || true
    done
fi

# STEP 2: Create user
if ! getent passwd nftban >/dev/null; then
    adduser --system --ingroup nftban --home /var/lib/nftban --no-create-home --shell /usr/sbin/nologin nftban
fi

# Add root to nftban group
usermod -a -G nftban root 2>/dev/null || true

# STEP 3: Create FHS directories
mkdir -p /etc/nftban/{conf.d,distros,whitelist.d,blacklist.d,ports.d,rules.d,patterns.d}
mkdir -p /etc/nftban/conf.d/{ddos,portscan,login,panels,botscan,rbl}
mkdir -p /etc/nftban/patterns.d/botscan
mkdir -p /var/lib/nftban/{banned,whitelist,feeds,geoip,reports,config,state,metrics,snapshots,exports}
mkdir -p /var/lib/nftban/reports/{baseline,auditors}
mkdir -p /var/log/nftban/reports
mkdir -p /var/cache/nftban/health
mkdir -p /run/nftban
mkdir -p /usr/share/nftban/templates/{mail,reports}

# STEP 4: Set permissions
chown root:nftban /etc/nftban
chmod 750 /etc/nftban
# Fix nftban.conf permissions (root:nftban 0640)
chown root:nftban /etc/nftban/nftban.conf 2>/dev/null || true
chmod 0640 /etc/nftban/nftban.conf 2>/dev/null || true
# CRITICAL: Fix conf.d permissions - services run as nftban user need group read access
chown -R root:nftban /etc/nftban/conf.d 2>/dev/null || true
find /etc/nftban/conf.d -type d -exec chmod 750 {} \; 2>/dev/null || true
find /etc/nftban/conf.d -type f -exec chmod 640 {} \; 2>/dev/null || true
# Fix other config subdirs
for subdir in distros whitelist.d blacklist.d ports.d rules.d suricata patterns.d; do
    if [ -d "/etc/nftban/\$subdir" ]; then
        chown -R root:nftban "/etc/nftban/\$subdir" 2>/dev/null || true
        find "/etc/nftban/\$subdir" -type d -exec chmod 750 {} \; 2>/dev/null || true
        find "/etc/nftban/\$subdir" -type f -exec chmod 640 {} \; 2>/dev/null || true
    fi
done
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

# STEP 8: Enforce permissions and health check
if command -v nftban >/dev/null 2>&1; then
    echo "[NFTBan] Enforcing permissions..."
    nftban permissions enforce 2>/dev/null || true
    echo "[NFTBan] Running health check with auto-heal..."
    nftban health check --auto-heal --quiet 2>/dev/null || true
fi

# STEP 9: Enable services (AFTER whitelist is in place)
echo "[NFTBan] Enabling systemd services..."
systemctl daemon-reload
systemctl enable nftables 2>/dev/null || true

# Enable and start nftband daemon socket (CRITICAL for CLI communication)
echo "[NFTBan] Starting nftband daemon..."
systemctl enable --now nftband.socket 2>/dev/null || true

# Enable and start essential timers
echo "[NFTBan] Starting essential timers..."
systemctl enable --now nftban-maintenance.timer 2>/dev/null || true
systemctl enable --now nftban-health.timer 2>/dev/null || true
systemctl enable --now nftban-core-geoip.timer 2>/dev/null || true
systemctl enable --now nftban-core-feeds.timer 2>/dev/null || true
systemctl enable --now nftban-queue.timer 2>/dev/null || true

# Enable and start login monitor
systemctl enable --now nftban-login-monitor.service 2>/dev/null || true

# STEP 10: Start or reload nftables
if systemctl is-active nftables >/dev/null 2>&1; then
    systemctl reload nftables 2>/dev/null || true
else
    systemctl start nftables 2>/dev/null || true
fi

echo "[NFTBan] Installation complete. Your IP has been auto-whitelisted."
echo "[NFTBan] Essential timers started. Run 'nftban timers enable' to start all optional timers."
exit 0
EOF
    fi

    # Inject actual version into postinst (for fallback inline postinst)
    sed -i "s/v1\.0\.[0-9]*/v${PKG_VERSION}/g" "${BUILD_DIR}/deb/DEBIAN/postinst"
    chmod 0755 "${BUILD_DIR}/deb/DEBIAN/postinst"

    # Create prerm script to handle immutable files and stop services before removal
    cat > "${BUILD_DIR}/deb/DEBIAN/prerm" << 'PRERM'
#!/bin/bash
set -e

# Remove immutable flag before upgrade/remove (security protection on nft_schema.sh)
if [ -f /usr/lib/nftban/lib/nft_schema.sh ]; then
    chattr -i /usr/lib/nftban/lib/nft_schema.sh 2>/dev/null || true
fi

# Stop services on removal (not upgrade)
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    # Stop all nftban services
    for unit in nftband.service nftban-core.service nftban-ui.service; do
        systemctl stop "$unit" 2>/dev/null || true
    done
    # Stop timers
    for timer in nftban-maintenance.timer nftban-health.timer nftban-core-feeds.timer nftban-queue.timer; do
        systemctl stop "$timer" 2>/dev/null || true
    done
fi

exit 0
PRERM
    chmod 755 "${BUILD_DIR}/deb/DEBIAN/prerm"

    # Create conffiles to mark user configuration files (preserved on upgrade)
    cat > "${BUILD_DIR}/deb/DEBIAN/conffiles" <<'CONFFILES_EOF'
/etc/nftban/nftban.conf
/etc/nftban/conf.d/feeds.conf
/etc/nftban/conf.d/rbl/main.conf
/etc/nftban/conf.d/rbl/rbls.conf
/etc/nftban/conf.d/rbl/custom.conf
/etc/nftban/conf.d/ddos/main.conf
/etc/nftban/conf.d/portscan/main.conf
/etc/nftban/conf.d/login/main.conf
/etc/nftban/conf.d/suricata/interfaces.conf
/etc/nftban/conf.d/botscan/main.conf
/etc/nftban/conf.d/geoban/main.conf
/etc/nftban/conf.d/geoip/main.conf
/etc/nftban/whitelist.d/99-manual.conf
/etc/nftban/blacklist.d/99-manual.conf
CONFFILES_EOF
}

build_deb() {
    log_info "Building DEB package..."

    local deb_root="${BUILD_DIR}/deb"
    rm -rf "${deb_root}"

    # Create directory structure
    mkdir -p "${deb_root}"/{DEBIAN,usr/bin,usr/sbin,usr/libexec,usr/lib/nftban/bin,usr/lib/systemd/system,etc/{nftables,polkit-1/rules.d,nftban/{blacklist.d,rules.d}},var/{lib/nftban/{feeds,geoip,staging},log/nftban,cache/nftban},run/nftban}

    # Copy binaries
    install -m 0755 "${PROJECT_ROOT}/bin/nftban-core" "${deb_root}/usr/lib/nftban/bin/"
    install -m 0755 "${PROJECT_ROOT}/bin/nftband" "${deb_root}/usr/lib/nftban/bin/"
    install -m 0755 "${PROJECT_ROOT}/cli/sbin/nftban" "${deb_root}/usr/sbin/"
    install -m 0755 "${PROJECT_ROOT}/bin/nftban-ui" "${deb_root}/usr/sbin/"
    install -m 0755 "${PROJECT_ROOT}/bin/nftban-ui-auth" "${deb_root}/usr/libexec/"

    # Copy helper scripts to /usr/lib/nftban/sbin/
    # CRITICAL: These scripts are executed by systemd services and MUST have 755 permissions
    # Bug fix v1.9.4: Ensure sbin scripts are always installed with correct permissions
    mkdir -p "${deb_root}/usr/lib/nftban/sbin"
    local sbin_count=0
    for script in nftban-apply nftban-confirm nftban-panelctl nftban-queue-processor \
                  nftban-rollback nftban-service-alert; do
        if [[ -f "${PROJECT_ROOT}/cli/sbin/${script}" ]]; then
            install -m 0755 "${PROJECT_ROOT}/cli/sbin/${script}" "${deb_root}/usr/lib/nftban/sbin/"
            ((sbin_count++))
        else
            log_warn "Missing sbin script: ${script}"
        fi
    done
    log_info "Installed ${sbin_count} sbin helper scripts"

    # Copy VERSION file
    install -m 0644 "${PROJECT_ROOT}/VERSION" "${deb_root}/usr/lib/nftban/VERSION"

    # Copy libraries
    cp -r "${PROJECT_ROOT}/cli/lib/nftban"/* "${deb_root}/usr/lib/nftban/"

    # CRITICAL: Set executable permissions on all shell scripts
    # (cp -r doesn't preserve permissions from source)
    find "${deb_root}/usr/lib/nftban" -name "*.sh" -exec chmod 755 {} \;

    # Copy main configuration file
    mkdir -p "${deb_root}/etc/nftban"
    install -m 0640 "${PROJECT_ROOT}/install/config/nftban.conf" "${deb_root}/etc/nftban/nftban.conf"

    # Copy nftables config (to nftban dir to avoid conflict with system nftables package)
    install -m 0644 "${PROJECT_ROOT}/install/nftables/nftables.conf" "${deb_root}/etc/nftban/nftables.conf"

    # Copy conf.d directory with subdirectories
    # NOTE: Central whitelist moved to whitelist.d/ - per-module whitelist.txt files removed
    mkdir -p "${deb_root}/etc/nftban/conf.d"
    cp -r "${PROJECT_ROOT}/etc/nftban/conf.d"/* "${deb_root}/etc/nftban/conf.d/"
    # Remove any stale whitelist.txt files (consolidated to whitelist.d/)
    find "${deb_root}/etc/nftban/conf.d" -name 'whitelist.txt' -delete 2>/dev/null || true
    install -m 0640 "${PROJECT_ROOT}/install/config/feeds.conf" "${deb_root}/etc/nftban/conf.d/feeds.conf"
    install -m 0640 "${PROJECT_ROOT}/install/config/conf.d/watchdog.conf" "${deb_root}/etc/nftban/conf.d/watchdog.conf"

    # Copy patterns.d directory (botscan patterns)
    mkdir -p "${deb_root}/etc/nftban/patterns.d/botscan"
    cp "${PROJECT_ROOT}/etc/nftban/patterns.d/botscan"/*.patterns "${deb_root}/etc/nftban/patterns.d/botscan/"

    # Install logrotate configuration
    mkdir -p "${deb_root}/etc/logrotate.d"
    install -m 0644 "${PROJECT_ROOT}/install/config/nftban.logrotate" "${deb_root}/etc/logrotate.d/nftban"

    # Copy Suricata profile templates and create config directories
    mkdir -p "${deb_root}/etc/nftban/suricata/profiles"
    mkdir -p "${deb_root}/etc/nftban/suricata/config"
    mkdir -p "${deb_root}/etc/nftban/suricata/rules"
    mkdir -p "${deb_root}/etc/nftban/suricata/cache"
    install -m 0644 "${PROJECT_ROOT}/etc/nftban/suricata/profiles/minimal.yaml" "${deb_root}/etc/nftban/suricata/profiles/"
    install -m 0644 "${PROJECT_ROOT}/etc/nftban/suricata/profiles/standard.yaml" "${deb_root}/etc/nftban/suricata/profiles/"
    install -m 0644 "${PROJECT_ROOT}/etc/nftban/suricata/profiles/maximum.yaml" "${deb_root}/etc/nftban/suricata/profiles/"
    install -m 0664 "${PROJECT_ROOT}/etc/nftban/suricata/config/profile.conf" "${deb_root}/etc/nftban/suricata/config/"

    # Copy distro configuration files (CRITICAL for distro-aware paths)
    mkdir -p "${deb_root}/etc/nftban/distros"
    cp "${PROJECT_ROOT}/etc/nftban/distros"/*.conf "${deb_root}/etc/nftban/distros/"

    # Manual whitelist/blacklist files (user-managed, preserved on upgrade)
    mkdir -p "${deb_root}/etc/nftban/whitelist.d"
    mkdir -p "${deb_root}/etc/nftban/blacklist.d"
    install -m 0640 "${PROJECT_ROOT}/etc/nftban/whitelist.d/99-manual.conf" "${deb_root}/etc/nftban/whitelist.d/"
    install -m 0640 "${PROJECT_ROOT}/etc/nftban/blacklist.d/99-manual.conf" "${deb_root}/etc/nftban/blacklist.d/"

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
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-unified-exporter.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-unified-exporter.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-watchdog.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-watchdog.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-snapshot.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-snapshot.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-rollback.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-rollback.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-suricata-update.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-suricata-update.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-suricata.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-suricata-stats.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-ui.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-ui-auth.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-queue.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-health-fix.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftband.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftband.socket" "${deb_root}/usr/lib/systemd/system/"

    # Copy PolicyKit rules (v1.0.19: Consolidated 6 files → 3 files)
    install -m 0644 "${PROJECT_ROOT}/packaging/polkit-1/rules.d/10-nftban-systemd.rules" "${deb_root}/etc/polkit-1/rules.d/"
    install -m 0644 "${PROJECT_ROOT}/packaging/polkit-1/rules.d/20-nftban-auditor.rules" "${deb_root}/etc/polkit-1/rules.d/"
    install -m 0644 "${PROJECT_ROOT}/packaging/polkit-1/rules.d/30-nftban-panel.rules" "${deb_root}/etc/polkit-1/rules.d/"

    # Copy validator spec
    mkdir -p "${deb_root}/usr/share/nftban/specs"
    install -m 0644 "${PROJECT_ROOT}/install/share/nftban/specs/structure_default.json" "${deb_root}/usr/share/nftban/specs/"

    # Copy templates (mail, reports, email, partials)
    mkdir -p "${deb_root}/usr/share/nftban/templates"
    find "${PROJECT_ROOT}/install/share/nftban/templates" -type f -name "*.html" | while read -r tmpl; do
        rel_path="${tmpl#${PROJECT_ROOT}/install/share/nftban/templates/}"
        install -D -m 0644 "$tmpl" "${deb_root}/usr/share/nftban/templates/$rel_path"
    done

    # Copy man page
    mkdir -p "${deb_root}/usr/share/man/man8"
    install -m 0644 "${PROJECT_ROOT}/install/man/man8/nftban.8" "${deb_root}/usr/share/man/man8/"

    # Copy bash completion
    mkdir -p "${deb_root}/usr/share/bash-completion/completions"
    install -m 0644 "${PROJECT_ROOT}/install/bash-completion/nftban" "${deb_root}/usr/share/bash-completion/completions/"

    # Copy commands registry (v1.0.16 - single source of truth)
    install -m 0644 "${PROJECT_ROOT}/commands.registry.yml" "${deb_root}/etc/nftban/"

    # Copy documentation generators (v1.0.16)
    mkdir -p "${deb_root}/usr/lib/nftban/scripts"
    install -m 0755 "${PROJECT_ROOT}/scripts/generate-help.sh" "${deb_root}/usr/lib/nftban/scripts/"
    install -m 0755 "${PROJECT_ROOT}/scripts/generate-wiki-operator.sh" "${deb_root}/usr/lib/nftban/scripts/"
    install -m 0755 "${PROJECT_ROOT}/scripts/generate-wiki-auditor.sh" "${deb_root}/usr/lib/nftban/scripts/"

    # Documentation moved to wiki (v1.0.20+)
    # See: https://github.com/itcmsgr/nftban/wiki

    # Copy test scripts
    mkdir -p "${deb_root}/usr/lib/nftban/tests"
    find "${PROJECT_ROOT}/cli/lib/nftban/tests" -type f -name "*.sh" -exec install -m 0755 {} "${deb_root}/usr/lib/nftban/tests/" \;

    # Create control file
    create_deb_control

    # Fix ownership before building (FHS: /usr/lib/nftban = root:root)
    # Without this, files keep the builder's UID which breaks systemd services
    log_info "Setting package file ownership to root:root..."
    fakeroot find "${deb_root}/usr" -type f -exec chown root:root {} \;
    fakeroot find "${deb_root}/usr" -type d -exec chown root:root {} \;
    fakeroot find "${deb_root}/etc" -type f -exec chown root:root {} \;
    fakeroot find "${deb_root}/etc" -type d -exec chown root:root {} \;

    # Build DEB
    fakeroot dpkg-deb --build "${deb_root}" "${BUILD_DIR}/nftban-core_${PKG_VERSION}_amd64.deb"

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
