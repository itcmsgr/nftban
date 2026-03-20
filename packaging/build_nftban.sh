#!/usr/bin/env bash
# =============================================================================
# NFTBan - Complete Package Builder
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
    local fatal=0

    # Check Go - required ONLY if pre-built binaries don't exist
    # CI downloads pre-built binaries, so Go is not needed in container
    # Use -f (file exists) not -x (executable) - Docker volume mounts may lose +x
    if [[ -f "${PROJECT_ROOT}/bin/nftban-core" ]] && [[ -f "${PROJECT_ROOT}/bin/nftband" ]]; then
        log_success "Pre-built binaries found in bin/ - Go not required"
    elif ! command -v go >/dev/null 2>&1; then
        log_error "╔══════════════════════════════════════════════════════════════════╗"
        log_error "║  FATAL: Go is NOT installed - CANNOT build nftband binaries!    ║"
        log_error "╠══════════════════════════════════════════════════════════════════╣"
        log_error "║  Either:                                                          ║"
        log_error "║    1. Install Go 1.21+:                                           ║"
        log_error "║       Fedora/RHEL: sudo dnf install golang                        ║"
        log_error "║       Debian/Ubuntu: sudo apt install golang-go                   ║"
        log_error "║    2. Or place pre-built binaries in bin/ directory               ║"
        log_error "╚══════════════════════════════════════════════════════════════════╝"
        fatal=1
    else
        local go_version
        go_version=$(go version | grep -oP 'go\K[0-9]+\.[0-9]+' | head -1)
        log_success "Go ${go_version} found"
    fi

    # Check build tools
    if [[ ! -x "${PROJECT_ROOT}/build.sh" ]]; then
        log_error "build.sh not found or not executable"
        fatal=1
    fi

    # Check for DEB tools
    if [[ "$build_type" =~ (deb|both) ]]; then
        command -v dpkg-deb >/dev/null || missing+=("dpkg-deb")
    fi

    # Check for RPM tools
    if [[ "$build_type" =~ (rpm|both) ]]; then
        command -v rpmbuild >/dev/null || missing+=("rpmbuild")
    fi

    # MANDATORY tools (must match CI requirements)
    # CI: dnf install --allowerasing rpm-build rpmdevtools tar gzip systemd-rpm-macros make curl
    # CI: apt install dpkg-dev build-essential file curl
    command -v curl >/dev/null || missing+=("curl")
    command -v tar >/dev/null || missing+=("tar")
    command -v gzip >/dev/null || missing+=("gzip")
    command -v file >/dev/null || missing+=("file")

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing: ${missing[*]}"
        log_info "Install (RPM): sudo dnf install rpm-build rpmdevtools tar gzip make curl file"
        log_info "Install (DEB): sudo apt install dpkg-dev build-essential curl file"
        fatal=1
    fi

    if [[ $fatal -eq 1 ]]; then
        log_error "CANNOT PROCEED - fix prerequisites above first!"
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
    local bin_dir="${PROJECT_ROOT}/bin"
    local nftban_core="${bin_dir}/nftban-core"
    local nftband="${bin_dir}/nftband"

    # Debug: Show what we're looking for
    log_info "Checking for pre-built binaries in: ${bin_dir}"
    if [[ -d "$bin_dir" ]]; then
        log_info "bin/ directory exists, contents:"
        ls -la "$bin_dir" || true
    else
        log_info "bin/ directory does not exist"
    fi

    # Check if pre-built binaries exist (from CI)
    # Use -f (file exists) not -x (executable) - Docker volume mounts may lose +x
    if [[ -f "$nftban_core" ]] && [[ -f "$nftband" ]]; then
        log_info "Found pre-built binaries, validating..."

        # Ensure binaries are executable (might be lost in Docker volume mount)
        chmod +x "$nftban_core" "$nftband" 2>/dev/null || true

        # Validate pre-built binaries are valid ELF files
        if validate_binary "$nftban_core" && validate_binary "$nftband"; then
            log_success "Using pre-built binaries from bin/ - skipping rebuild"
            # Record SHA256 hashes for debugging
            log_info "nftban-core SHA256: $(sha256sum "$nftban_core" | cut -d' ' -f1)"
            log_info "nftband SHA256: $(sha256sum "$nftband" | cut -d' ' -f1)"
            return 0
        else
            log_warn "Pre-built binaries failed validation, will rebuild"
        fi
    fi

    # No valid pre-built binaries - need to build
    log_info "Building binaries from source..."

    # Check Go is available
    if ! command -v go >/dev/null 2>&1; then
        log_error "Go is not installed and no pre-built binaries found"
        log_error "Either install Go or provide pre-built binaries in bin/"
        return 1
    fi

    cd "${PROJECT_ROOT}"
    ./build.sh || {
        log_error "Build failed"
        return 1
    }

    # Validate built binaries
    validate_binary "$nftban_core" || return 1
    validate_binary "$nftband" || return 1

    log_success "Binaries built successfully"
    log_info "nftban-core SHA256: $(sha256sum "$nftban_core" | cut -d' ' -f1)"
    log_info "nftband SHA256: $(sha256sum "$nftband" | cut -d' ' -f1)"
}

# shellcheck disable=SC2120  # $1 in heredoc is RPM scriptlet argument, not bash
create_rpm_spec_nftban_core() {
    # Validate required variables
    if [[ -z "${BUILD_DIR:-}" ]]; then
        log_error "BUILD_DIR is not set"
        return 1
    fi
    if [[ -z "${PKG_VERSION:-}" ]]; then
        log_error "PKG_VERSION is not set"
        return 1
    fi
    if [[ ! -d "${BUILD_DIR}/SPECS" ]]; then
        log_error "SPECS directory does not exist: ${BUILD_DIR}/SPECS"
        return 1
    fi

    log_info "Creating spec file at ${BUILD_DIR}/SPECS/nftban-core.spec"

    # Use explicit file descriptor to catch cat errors
    if ! cat > "${BUILD_DIR}/SPECS/nftban-core.spec" <<EOF
# Disable debuginfo for Go binary (no debug symbols)
%global debug_package %{nil}
%global _missing_build_ids_terminate_build 0

# CRITICAL: Disable ALL post-build processing that modifies binaries
# Pre-built Go binaries must remain UNCHANGED for hash verification
# Without this, rpmbuild adds .note.gnu.build-id sections (+~300 bytes)
%define _build_id_links none
%define __brp_strip %{nil}
%define __brp_strip_static_archive %{nil}
%define __brp_strip_comment_note %{nil}
%define __os_install_post %{nil}

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
Requires:       polkit
# ACL required on EL10/Fedora (not in default minimal install)
%if 0%{?fedora} || 0%{?el10}
Requires:       acl
%else
Recommends:     acl
%endif
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
# Download yq at BUILD time (supply-chain safe - not at install time)
# SHA256 verified before bundling in package
YQ_VERSION="4.44.1"
YQ_SHA256="6dc2d0cd4e0caca5aeffd0d784a48263591080e4a0895abe69f3a76eb50d1ba3"
echo "Downloading yq v\${YQ_VERSION} for bundling..."
curl -sL "https://github.com/mikefarah/yq/releases/download/v\${YQ_VERSION}/yq_linux_amd64" -o yq_linux_amd64
echo "\${YQ_SHA256}  yq_linux_amd64" | sha256sum -c - || { echo "yq checksum verification failed!"; exit 1; }

# Binaries
install -D -m 0755 bin/nftban-core %{buildroot}/usr/lib/nftban/bin/nftban-core
install -D -m 0755 bin/nftband %{buildroot}/usr/lib/nftban/bin/nftband
install -D -m 0755 yq_linux_amd64 %{buildroot}/usr/lib/nftban/bin/yq
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
install -m 0755 cli/sbin/nftban-botscan-processor %{buildroot}/usr/lib/nftban/sbin/

# Version file
install -D -m 0644 VERSION %{buildroot}/usr/lib/nftban/VERSION

# Build target file (distro detection at install time)
if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "\${ID:-unknown}:\${VERSION_ID:-0}" > %{buildroot}/usr/lib/nftban/BUILD_TARGET
else
    echo "unknown:0" > %{buildroot}/usr/lib/nftban/BUILD_TARGET
fi

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
install -D -m 0644 install/config/nftban.logrotate %{buildroot}/etc/nftban/templates/nftban.logrotate
install -D -m 0644 install/config/nftban-suricata.logrotate %{buildroot}/etc/nftban/templates/nftban-suricata.logrotate

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
# v1.23.0 (EVAL-3): nftban-login-monitor.service REMOVED from package
# Deprecated since v1.21.3, replaced by Go daemon loginmon module (pkg/loginmon)
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
install -D -m 0644 install/systemd/nftban-queue.timer %{buildroot}/usr/lib/systemd/system/nftban-queue.timer
install -D -m 0644 install/systemd/nftban-botscan.service %{buildroot}/usr/lib/systemd/system/nftban-botscan.service
install -D -m 0644 install/systemd/nftban-botscan.timer %{buildroot}/usr/lib/systemd/system/nftban-botscan.timer
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

# SELinux policy files (R39 v1.19.12) - RPM only, DEB uses AppArmor
mkdir -p %{buildroot}/usr/share/nftban/selinux
install -D -m 0644 install/selinux/nftban.te %{buildroot}/usr/share/nftban/selinux/nftban.te
install -D -m 0644 install/selinux/nftban.fc %{buildroot}/usr/share/nftban/selinux/nftban.fc
install -D -m 0644 install/selinux/Makefile %{buildroot}/usr/share/nftban/selinux/Makefile

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
mkdir -p %{buildroot}/etc/nftban/conf.d/botguard
mkdir -p %{buildroot}/var/lib/nftban/{feeds,geoip,staging,reports,botguard}
mkdir -p %{buildroot}/var/log/nftban/botguard
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
PREREQ_ERRORS=""

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

    # Check EL version matches package (prevent wrong RPM install)
    # %{release} expands at RPM build time to e.g. "1.el9" or "1.el10"
    PKG_RELEASE_TAG="%{release}"
    SYS_EL_VER="\${VERSION_ID%%%%.*}"
    case "\$ID" in
        rhel|rocky|almalinux|centos|ol)
            PKG_EL_VER=\$(echo "\$PKG_RELEASE_TAG" | sed -n 's/.*el\([0-9]*\).*/\1/p')
            if [ -n "\$PKG_EL_VER" ] && [ -n "\$SYS_EL_VER" ]; then
                if [ "\$PKG_EL_VER" != "\$SYS_EL_VER" ]; then
                    echo "[✗] ERROR: Wrong package for this system!"
                    echo "    Package built for: EL\${PKG_EL_VER}"
                    echo "    System version:    EL\${SYS_EL_VER}"
                    echo "    Use the correct package: nftban-el\${SYS_EL_VER}-x86_64.rpm"
                    PREREQ_FAILED=1
                    PREREQ_ERRORS="WRONG PACKAGE: This is an EL\${PKG_EL_VER} package but you are running EL\${SYS_EL_VER}. Download: nftban-el\${SYS_EL_VER}-x86_64.rpm"
                fi
            fi
            ;;
    esac
else
    echo "[✗] ERROR: Cannot detect OS version (/etc/os-release missing)"
    PREREQ_FAILED=1
    PREREQ_ERRORS="Cannot detect OS version (/etc/os-release missing)"
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

# NOTE: CRB/PowerTools NOT required - all NFTBan deps are in base/AppStream repos

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
    if [ -n "\$PREREQ_ERRORS" ]; then
        echo "ROOT CAUSE: \$PREREQ_ERRORS"
        echo ""
    fi
    echo "Please fix the errors above and try again."
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo ""
    # Print root cause to stderr as well (survives RPM/DNF noise)
    [ -n "\$PREREQ_ERRORS" ] && echo "NFTBan: \$PREREQ_ERRORS" >&2
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
getent group suricata >/dev/null || groupadd -r suricata

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
# Order: CVE check -> yq -> cleanup -> groups -> dirs -> perms -> polkit -> whitelist -> health -> services

# =============================================================================
# STEP 0: Security Check - CVE-2025-NFTBAN-001 (Bug #19 fix)
# =============================================================================
# Check for conflicting inet filter table that can bypass nftban blocking
if command -v nft >/dev/null 2>&1; then
    if nft list table inet filter >/dev/null 2>&1; then
        if [ "\$1" -ge 2 ] 2>/dev/null; then
            # UPGRADE: Auto-clean the conflicting table
            echo "[NFTBan WARN] Conflicting 'inet filter' table detected - auto-removing for upgrade"
            nft delete table inet filter 2>/dev/null || true
        else
            # FRESH INSTALL: Hard-fail - admin must resolve conflict first
            echo "[NFTBan ERROR] Conflicting 'inet filter' table detected!"
            echo "[NFTBan ERROR] This table will bypass nftban blocking (CVE-2025-NFTBAN-001)."
            echo "[NFTBan ERROR] Please run: nft delete table inet filter"
            echo "[NFTBan ERROR] Then re-install the package."
            exit 1
        fi
    fi
fi

# NOTE: SSH client IP protection moved to nftban_whitelist_system_sync()
# Called via: nftban whitelist-system sync --quick --protect-session
# This ensures single source of truth for session protection logic.

# =============================================================================
# STEP 0.1: Distro compatibility check (v1.22.3)
# =============================================================================
# Warn if the package was built for a different distro version than the running OS
if [ -f /usr/lib/nftban/BUILD_TARGET ] && [ -f /etc/os-release ]; then
    . /etc/os-release
    BUILD_TARGET=\$(cat /usr/lib/nftban/BUILD_TARGET 2>/dev/null || echo "unknown:0")
    BUILD_ID=\$(echo "\$BUILD_TARGET" | cut -d: -f1)
    BUILD_VER=\$(echo "\$BUILD_TARGET" | cut -d: -f2)
    RUNNING_ID="\${ID:-unknown}"
    RUNNING_VER="\${VERSION_ID:-0}"

    if [ "\$BUILD_ID" != "unknown" ] && [ "\$BUILD_ID" != "\$RUNNING_ID" ]; then
        echo "[NFTBan] WARNING: Package built for \$BUILD_ID but running on \$RUNNING_ID"
        echo "[NFTBan]   This may cause library incompatibilities"
        echo "[NFTBan]   Recommended: use the correct package for your OS"
    elif [ "\$BUILD_VER" != "0" ] && [ "\$BUILD_VER" != "\$RUNNING_VER" ]; then
        echo "[NFTBan] WARNING: Package built for \$BUILD_ID \$BUILD_VER but running on \$RUNNING_ID \$RUNNING_VER"
        echo "[NFTBan]   Use: nftban update  (auto-selects correct package for your OS)"
    fi
fi

# =============================================================================
# STEP 0.5: Link bundled yq v4 (mikefarah/yq) - REQUIRED (BUG-001 fix)
# =============================================================================
# WHY v4 IS REQUIRED:
#   - yq v3 (Python pip) is ~10x slower (0.17s vs 0.017s per call)
#   - nftban help makes 100+ yq calls, causing timeout with v3
#   - NFTBan 1.12.7+ standardized on mikefarah/yq v4 syntax
# SUPPLY-CHAIN SAFE: yq is bundled in package with SHA256 verification at build time
echo "[NFTBan] Checking yq v4 (YAML processor)..."

# Check if system yq is already v4
if command -v yq >/dev/null 2>&1; then
    YQ_VER=\$(yq --version 2>/dev/null | head -1 || echo "")
    if echo "\$YQ_VER" | grep -qE "mikefarah|version v4"; then
        echo "[NFTBan]   yq v4 found: \$YQ_VER"
    else
        # System has yq v3, use bundled v4
        if [ -x /usr/lib/nftban/bin/yq ]; then
            ln -sf /usr/lib/nftban/bin/yq /usr/bin/yq
            echo "[NFTBan]   yq v4 linked from bundled binary (replaced v3)"
        fi
    fi
else
    # No system yq, link bundled
    if [ -x /usr/lib/nftban/bin/yq ]; then
        ln -sf /usr/lib/nftban/bin/yq /usr/bin/yq
        echo "[NFTBan]   yq v4 linked from bundled binary"
    else
        echo "[NFTBan WARN] WARNING: bundled yq not found - help command may be slow"
    fi
fi

# =============================================================================
# STEP 0: Cleanup obsolete/stale files from ALL previous versions
# =============================================================================
# UNIFIED STALE CLEANUP — must match DEB postinst cleanup section
# Add new entries here when files are moved/renamed/removed between versions.
echo "[NFTBan] Cleaning up obsolete files from previous versions..."

# --- Binary paths (pre-1.8.13) ---
if [ -f "/usr/bin/nftban" ] && [ ! -L "/usr/bin/nftban" ]; then
    rm -f "/usr/bin/nftban"
    echo "[NFTBan] Removed stale: /usr/bin/nftban (migrated to /usr/sbin)"
fi

# --- Nested directories (pre-1.13.9) ---
for stale_dir in "/usr/lib/nftban/lib/nftban" "/usr/lib/nftban/etc"; do
    if [ -d "\$stale_dir" ]; then
        rm -rf "\$stale_dir"
        echo "[NFTBan] Removed stale dir: \$stale_dir"
    fi
done

# --- Relocated shell scripts (pre-1.15) ---
for stale_file in \
    "/usr/lib/nftban/core/cmd_health.sh" \
    "/usr/lib/nftban/json_output.sh" \
    "/usr/lib/nftban/cmd_ui.sh"; do
    if [ -f "\$stale_file" ]; then
        rm -f "\$stale_file"
        echo "[NFTBan] Removed stale: \$stale_file"
    fi
done

# --- Obsolete Polkit rules (pre-1.0.18) ---
for stale_polkit in \
    /etc/polkit-1/rules.d/10-nftban-core.rules \
    /etc/polkit-1/rules.d/20-nftban-suricata.rules \
    /etc/polkit-1/rules.d/50-nftban-auth.rules \
    /etc/polkit-1/rules.d/50-nftban-auth.rules.in \
    /etc/polkit-1/rules.d/50-nftban-v030.rules \
    /etc/polkit-1/rules.d/60-nftban-services.rules \
    /etc/polkit-1/rules.d/50-nftban-port-status.rules \
    /etc/polkit-1/rules.d/50-nftban-port-status.rules.in \
    /usr/share/polkit-1/rules.d/10-nftban-core.rules \
    /usr/share/polkit-1/rules.d/20-nftban-suricata.rules \
    /usr/share/polkit-1/rules.d/50-nftban-auth.rules \
    /usr/share/polkit-1/rules.d/50-nftban-v030.rules \
    /usr/share/polkit-1/rules.d/60-nftban-services.rules \
    /usr/share/polkit-1/rules.d/50-nftban-port-status.rules \
    /usr/share/polkit-1/actions/com.nftban.suricata.policy; do
    if [ -f "\$stale_polkit" ]; then
        rm -f "\$stale_polkit"
        echo "[NFTBan] Removed stale polkit: \$stale_polkit"
    fi
done

# --- Old systemd overrides (various versions) ---
rm -f /etc/systemd/system/nftban-*.service 2>/dev/null || true
rm -f /etc/systemd/system/nftban-*.timer 2>/dev/null || true
rm -rf /etc/systemd/system/nftban-*.service.d 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

# --- Suricata blocks in main logrotate (pre-1.19.6) ---
# Old versions had Suricata log blocks inline in /etc/logrotate.d/nftban
# which breaks logrotate when Suricata user doesn't exist.
# Now split to /etc/logrotate.d/nftban-suricata (conditionally installed).
if [ -f /etc/logrotate.d/nftban ]; then
    if grep -q "su suricata" /etc/logrotate.d/nftban 2>/dev/null; then
        echo "[NFTBan] Detected old Suricata blocks in /etc/logrotate.d/nftban — replacing with clean version"
        install -m 0644 /etc/nftban/templates/nftban.logrotate /etc/logrotate.d/nftban 2>/dev/null || true
    fi
fi

# --- Handle .rpmnew/.rpmsave for logrotate configs ---
# When RPM %config(noreplace) detects user modifications, it saves the new
# version as .rpmnew. Replace the old file with the shipped version to ensure
# consistent logrotate behavior.
for rpmnew_file in /etc/logrotate.d/nftban.rpmnew /etc/logrotate.d/nftban-suricata.rpmnew; do
    if [ -f "\$rpmnew_file" ]; then
        local_base="\${rpmnew_file%.rpmnew}"
        echo "[NFTBan] Found \$rpmnew_file — replacing \$local_base with shipped version"
        mv -f "\$rpmnew_file" "\$local_base" 2>/dev/null || true
    fi
done
# Clean up .rpmsave remnants
rm -f /etc/logrotate.d/nftban.rpmsave /etc/logrotate.d/nftban-suricata.rpmsave 2>/dev/null || true

echo "[NFTBan] Obsolete file cleanup complete"

# =============================================================================
# NFTBan is THE ONLY firewall - no coexistence with others
# =============================================================================
echo "[NFTBan] Checking for conflicting firewalls..."

CONFLICTS=""

# Check CSF/LFD (ConfigServer Firewall + Login Failure Daemon)
if systemctl is-active csf.service &>/dev/null 2>&1 || \
   systemctl is-active lfd.service &>/dev/null 2>&1 || \
   [[ -f /etc/csf/csf.conf ]]; then
    CONFLICTS="\${CONFLICTS}CSF "
fi

# Check cPHulk (cPanel brute force) - INFO only, designed to coexist
# cPHulk is handled during panel detection (step 10.5a), not a blocking conflict
if systemctl is-active cphulkd.service &>/dev/null 2>&1; then
    echo "[NFTBan] INFO: cPHulk detected (cPanel brute force protection)"
    echo "[NFTBan]   cPHulk will be disabled during panel setup (step 10.5a)"
fi

# Check UFW
if systemctl is-active ufw.service &>/dev/null 2>&1; then
    CONFLICTS="\${CONFLICTS}UFW "
fi

# Check firewalld
if systemctl is-active firewalld.service &>/dev/null 2>&1; then
    CONFLICTS="\${CONFLICTS}firewalld "
fi

# Check iptables service
if systemctl is-active iptables.service &>/dev/null 2>&1; then
    CONFLICTS="\${CONFLICTS}iptables "
fi

# Handle conflicts
if [[ -n "\$CONFLICTS" ]]; then
    echo ""
    echo "[NFTBan WARN] =========================================="
    echo "[NFTBan WARN]  CONFLICTING FIREWALLS DETECTED"
    echo "[NFTBan WARN] =========================================="
    echo "[NFTBan WARN] Found: \$CONFLICTS"
    echo ""

    # If NFTBAN_TAKEOVER not already set, prompt user or fail for non-interactive
    if [[ "\${NFTBAN_TAKEOVER:-0}" != "1" ]]; then
        echo "[NFTBan] NFTBan requires exclusive firewall control."
        echo "[NFTBan] You cannot run two firewalls simultaneously."
        echo ""

        # Check if we have a terminal for interactive prompt
        if [[ -t 0 ]]; then
            # Interactive mode - ask user
            echo "[NFTBan] How would you like to proceed?"
            echo ""
            echo "  [1] AUTO   - NFTBan will disable conflicting firewalls automatically"
            echo "  [2] MANUAL - You will remove them yourself (installation aborts)"
            echo ""
            read -p "[NFTBan] Enter choice [1/2]: " CONFLICT_CHOICE </dev/tty

            case "\$CONFLICT_CHOICE" in
                1|auto|AUTO|a|A)
                    echo ""
                    echo "[NFTBan] Auto-takeover selected."
                    export NFTBAN_TAKEOVER=1
                    ;;
                2|manual|MANUAL|m|M|*)
                    echo ""
                    echo "[NFTBan] Manual removal selected."
                    echo ""
                    echo "[NFTBan] Please remove the conflicting firewalls:"
                    echo "[NFTBan]   - CSF: csf -x && yum remove csf lfd"
                    echo "[NFTBan]   - UFW: ufw disable && apt remove ufw"
                    echo "[NFTBan]   - firewalld: systemctl disable --now firewalld"
                    echo "[NFTBan]   - iptables: systemctl disable --now iptables"
                    echo ""
                    echo "[NFTBan] Then reinstall NFTBan."
                    exit 1
                    ;;
            esac
        else
            # Non-interactive mode - show instructions and exit
            echo "[NFTBan ERROR] Non-interactive install detected."
            echo "[NFTBan ERROR] Options:"
            echo "[NFTBan ERROR]   1. Auto-takeover: NFTBAN_TAKEOVER=1 dnf install -y ./nftban-*.rpm"
            echo "[NFTBan ERROR]   2. Manual removal:"
            echo "[NFTBan ERROR]      - CSF: csf -x && yum remove csf lfd"
            echo "[NFTBan ERROR]      - UFW: ufw disable && apt remove ufw"
            echo "[NFTBan ERROR]      - firewalld: systemctl disable --now firewalld"
            echo "[NFTBan ERROR]      - iptables: systemctl disable --now iptables"
            echo ""
            echo "[NFTBan ERROR] Then reinstall NFTBan."
            exit 1
        fi
    fi

    # Run takeover if flag is set (either from env or user choice)
    if [[ "\${NFTBAN_TAKEOVER:-0}" == "1" ]]; then
        echo "[NFTBan] Disabling conflicting firewalls..."
        echo ""

        # Disable CSF
        if [[ "\$CONFLICTS" == *"CSF"* ]]; then
            echo "[NFTBan]   Disabling CSF..."
            csf -x 2>/dev/null || true
            systemctl disable csf lfd 2>/dev/null || true
            systemctl stop csf lfd 2>/dev/null || true
            echo "[NFTBan]   ✓ CSF disabled"
        fi

        # NOTE: cPHulk is NOT a conflict — handled in panel detection (step 10.5a)

        # Disable UFW
        if [[ "\$CONFLICTS" == *"UFW"* ]]; then
            echo "[NFTBan]   Disabling UFW..."
            ufw disable 2>/dev/null || true
            systemctl disable ufw 2>/dev/null || true
            systemctl stop ufw 2>/dev/null || true
            echo "[NFTBan]   ✓ UFW disabled"
        fi

        # Disable firewalld
        if [[ "\$CONFLICTS" == *"firewalld"* ]]; then
            echo "[NFTBan]   Disabling firewalld..."
            systemctl disable firewalld 2>/dev/null || true
            systemctl stop firewalld 2>/dev/null || true
            echo "[NFTBan]   ✓ firewalld disabled"
        fi

        # Disable iptables service
        if [[ "\$CONFLICTS" == *"iptables"* ]]; then
            echo "[NFTBan]   Disabling iptables service..."
            systemctl disable iptables ip6tables 2>/dev/null || true
            systemctl stop iptables ip6tables 2>/dev/null || true
            echo "[NFTBan]   ✓ iptables service disabled"
        fi

        # =====================================================================
        # CRITICAL: Create emergency SSH/panel protection BEFORE any flush
        # This prevents lockout during takeover (v1.17.4 fix)
        # =====================================================================
        echo "[NFTBan]   Creating emergency access protection..."

        # Detect current SSH port (v1.23.0 P1-5: multi-source detection)
        # 1. Check active listening port first (most reliable)
        EMERGENCY_SSH_PORT=\$(ss -tlnp 2>/dev/null | grep sshd | awk '{print \$4}' | sed 's/.*://' | head -1)
        # 2. Fallback: check sshd_config if ss didn't find it
        if [[ -z "\$EMERGENCY_SSH_PORT" ]]; then
            EMERGENCY_SSH_PORT=\$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print \$2}' | head -1 || true)
        fi
        # 3. Final fallback: default to 22
        EMERGENCY_SSH_PORT=\${EMERGENCY_SSH_PORT:-22}
        echo "[NFTBan]   Detected SSH on port: \$EMERGENCY_SSH_PORT"

        # Detect panel ports
        EMERGENCY_PANEL_PORTS=""
        [[ -d /usr/local/cpanel ]] && EMERGENCY_PANEL_PORTS="2082 2083 2086 2087"
        [[ -d /usr/local/directadmin ]] && EMERGENCY_PANEL_PORTS="2222"
        [[ -d /usr/local/psa ]] && EMERGENCY_PANEL_PORTS="8443 8880"
        [[ -d /usr/local/hestia ]] && EMERGENCY_PANEL_PORTS="8083"
        [[ -d /usr/local/CyberCP ]] && EMERGENCY_PANEL_PORTS="7080 8090"
        [[ -n "\$EMERGENCY_PANEL_PORTS" ]] && echo "[NFTBan]   Detected panel ports: \$EMERGENCY_PANEL_PORTS"

        # Create emergency protection table with HIGHEST priority (-500)
        # This table survives specific table flushes
        nft add table inet nftban_install_emergency 2>/dev/null || true
        nft 'add chain inet nftban_install_emergency input { type filter hook input priority -500; policy accept; }' 2>/dev/null || true
        nft add rule inet nftban_install_emergency input tcp dport \$EMERGENCY_SSH_PORT accept 2>/dev/null || true
        nft add rule inet nftban_install_emergency input ct state established,related accept 2>/dev/null || true

        # Add panel ports to emergency table
        for port in \$EMERGENCY_PANEL_PORTS; do
            nft add rule inet nftban_install_emergency input tcp dport \$port accept 2>/dev/null || true
        done
        echo "[NFTBan]   ✓ Emergency protection active"

        # Flush legacy rules (but NOT our emergency table)
        echo "[NFTBan]   Flushing legacy rules..."
        # Flush specific tables instead of entire ruleset to preserve emergency table
        for table in \$(nft list tables 2>/dev/null | grep -v nftban_install_emergency | awk '{print \$2, \$3}'); do
            nft flush table \$table 2>/dev/null || true
            nft delete table \$table 2>/dev/null || true
        done
        iptables -F 2>/dev/null || true
        iptables -X 2>/dev/null || true
        ip6tables -F 2>/dev/null || true
        ip6tables -X 2>/dev/null || true
        echo "[NFTBan]   ✓ Legacy rules flushed (emergency protection preserved)"
        echo ""
        echo "[NFTBan] ✓ All conflicts removed. NFTBan is now THE firewall."
        echo ""
    fi
else
    echo "[NFTBan] No conflicting firewalls found"
fi
echo "[NFTBan] Configuring NFTBan v%{version}..."

# STEP 1: (systemd overrides cleanup now in STEP 0 unified cleanup above)

# STEP 2: Create FHS directories
echo "[NFTBan] Creating FHS directories..."
mkdir -p /etc/nftban/{conf.d,distros,whitelist.d,blacklist.d,ports.d,rules.d,patterns.d}
mkdir -p /etc/nftban/conf.d/{ddos,portscan,login,panels,botscan,botguard,rbl}
mkdir -p /etc/nftban/patterns.d/botscan
mkdir -p /var/lib/nftban/{banned,whitelist,feeds,geoip,reports,config,state,metrics,snapshots,exports,panels,botguard,suricata}
mkdir -p /var/lib/nftban/reports/{baseline,auditors}
mkdir -p /var/log/nftban/{reports,botguard}
mkdir -p /var/cache/nftban/health
mkdir -p /run/nftban
mkdir -p /usr/share/nftban/templates/{mail,reports}

# Prometheus textfile_collector directory (BUG-009 fix)
# Required by nftban-unified-exporter.service ReadWritePaths directive
if [[ ! -d /var/lib/node_exporter/textfile_collector ]]; then
    mkdir -p /var/lib/node_exporter/textfile_collector
    chown nftban:nftban /var/lib/node_exporter/textfile_collector 2>/dev/null || true
    chmod 755 /var/lib/node_exporter/textfile_collector
    echo "[NFTBan] Created: /var/lib/node_exporter/textfile_collector"
fi

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
        find /var/lib/nftban /var/log/nftban -type f -exec chown nftban:nftban {} \; 2>/dev/null || true
        find /var/lib/nftban /var/log/nftban -type d -exec chown nftban:nftban {} \; 2>/dev/null || true
    fi
else
    echo "[NFTBan WARN] fhs-permissions.sh not found - using fallback permissions"
    # Fallback: minimal critical permissions only
    chown root:nftban /etc/nftban 2>/dev/null || true
    chmod 750 /etc/nftban 2>/dev/null || true
    find /etc/nftban/conf.d -type f -exec chown root:nftban {} \; 2>/dev/null || true
    find /etc/nftban/conf.d -type d -exec chown root:nftban {} \; 2>/dev/null || true
    find /etc/nftban/conf.d -type d -exec chmod 750 {} \; 2>/dev/null || true
    find /etc/nftban/conf.d -type f -exec chmod 640 {} \; 2>/dev/null || true
    find /var/lib/nftban /var/log/nftban /var/cache/nftban -type f -exec chown nftban:nftban {} \; 2>/dev/null || true
    find /var/lib/nftban /var/log/nftban /var/cache/nftban -type d -exec chown nftban:nftban {} \; 2>/dev/null || true
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

# STEP 4.5: Auto-Enable Detected Control Panels (BUG-HIGH-002 fix)
# Prevents admin lockout by detecting installed panels and auto-enabling
# their ports BEFORE nftables starts.
echo "[NFTBan] Detecting installed control panels..."
DETECTED_PANEL="none"

# Inline panel detection (same logic as nftban_panel_detect)
if [[ -d /usr/local/directadmin ]]; then
    DETECTED_PANEL="directadmin"
elif [[ -d /usr/local/cpanel ]]; then
    DETECTED_PANEL="cpanel"
elif [[ -d /usr/local/psa ]]; then
    DETECTED_PANEL="plesk"
elif [[ -d /usr/local/CyberCP ]]; then
    DETECTED_PANEL="cyberpanel"
elif [[ -d /usr/local/hestia ]]; then
    DETECTED_PANEL="hestia"
elif [[ -d /usr/local/vesta ]]; then
    DETECTED_PANEL="vesta"
elif [[ -d /usr/local/cwpsrv ]]; then
    DETECTED_PANEL="cwp"
elif [[ -d /usr/local/interworx ]]; then
    DETECTED_PANEL="interworx"
fi

if [[ "\$DETECTED_PANEL" != "none" ]]; then
    echo "[NFTBan]   Detected control panel: \${DETECTED_PANEL^^}"
    mkdir -p /var/lib/nftban/panels
    {
        echo "# NFTBan Panel State Configuration"
        echo "# Format: panelname=enabled|disabled"
        echo "# This file is automatically managed by 'nftban panel' commands"
        echo "# Auto-generated during install on \$(date -Iseconds)"
        echo ""
        echo "\${DETECTED_PANEL}=enabled"
    } > /var/lib/nftban/panels/enabled.conf
    echo "[NFTBan]   Panel marked as enabled - ports will be loaded into firewall"
else
    echo "[NFTBan]   No control panel detected - using generic configuration"
fi

# STEP 5: **SAFETY** Auto-whitelist system IPs
# CRITICAL: This MUST happen BEFORE enabling any firewall services
echo "[NFTBan] Auto-whitelisting system IPs (lockout prevention)..."
if command -v nftban >/dev/null 2>&1; then
    # v1.19.22: ALWAYS use --protect-session for both install AND upgrade
    # Rule: Any live nft reload/apply needs session protection (IPv4 + IPv6)
    nftban whitelist-system sync --quick --protect-session 2>/dev/null || echo "[NFTBan WARN] Auto-whitelist failed"
fi

# STEP 6: Download GeoIP database (free DB-IP version, with timeout)
echo "[NFTBan] Downloading GeoIP database..."
if [ -x /usr/lib/nftban/bin/nftban-core ]; then
    # Use timeout to prevent blocking on slow/no network (120s max)
    # DB-IP Lite is ~3.5MB compressed — 15s was too short on slow networks
    if timeout 120s /usr/lib/nftban/bin/nftban-core geoip update 2>&1; then
        echo "[NFTBan]   GeoIP database downloaded successfully"
    else
        echo "[NFTBan]   GeoIP download skipped (timeout or no network)"
        echo "[NFTBan]   Will auto-download on first timer run, or manual: nftban geoip update"
    fi
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
# NOTE: %%systemd_post macros removed due to el10 compatibility issues
# (systemd-rpm-macros 256+ causes "invalid option -- 'e'" errors)
# Using explicit systemctl commands instead - achieves same result

# BUG-R48 FIX: %%systemd_post only runs on fresh install (\$1 -eq 1), NOT upgrades.
# Timers that were disabled (manually or never enabled) stay disabled on upgrades.
# Explicit enable ensures timers work after ANY install/upgrade.
#
# Timer reconciliation (v1.21.3+):
# Respects NFTBAN_RECONCILE_CORE_TIMERS config option (default: true).
# Core timers are always enabled unless admin explicitly opts out.
NFTBAN_RECONCILE="true"
if [ -f /etc/nftban/nftban.conf ]; then
    _reconcile_val=\$(grep -m1 '^NFTBAN_RECONCILE_CORE_TIMERS=' /etc/nftban/nftban.conf 2>/dev/null | cut -d'"' -f2)
    [ -n "\$_reconcile_val" ] && NFTBAN_RECONCILE="\$_reconcile_val"
    # Check .local override
    if [ -f /etc/nftban/nftban.conf.local ]; then
        _reconcile_local=\$(grep -m1 '^NFTBAN_RECONCILE_CORE_TIMERS=' /etc/nftban/nftban.conf.local 2>/dev/null | cut -d'"' -f2)
        [ -n "\$_reconcile_local" ] && NFTBAN_RECONCILE="\$_reconcile_local"
    fi
fi

if [ "\$NFTBAN_RECONCILE" = "true" ]; then
    echo "[NFTBan] Ensuring core timers are enabled (RECONCILE_CORE_TIMERS=true)..."
    systemctl enable nftban-maintenance.timer 2>/dev/null || true
    systemctl enable nftban-health.timer 2>/dev/null || true
    systemctl enable nftban-unified-exporter.timer 2>/dev/null || true
    systemctl enable nftban-core-geoip.timer 2>/dev/null || true
    systemctl enable nftban-core-feeds.timer 2>/dev/null || true
    systemctl enable nftban-watchdog.timer 2>/dev/null || true
    systemctl enable nftban-queue.timer 2>/dev/null || true
else
    echo "[NFTBan] Timer reconciliation disabled (RECONCILE_CORE_TIMERS=false)"
fi

# Enable nftables service
systemctl enable nftables 2>/dev/null || true

# Enable and start nftband daemon socket and service (CRITICAL for CLI communication)
# BUG-002 fix: Socket activation alone is unreliable on fresh install
# BUG-MED-001 fix: Must enable nftband.service for boot persistence
echo "[NFTBan] Starting nftband daemon..."

# Ensure systemd recognizes unit files before enabling
systemctl daemon-reload 2>/dev/null || true

# Enable socket and service with retry (v1.17.3 robustness fix)
for attempt in 1 2 3; do
    systemctl enable nftband.socket 2>/dev/null && break
    sleep 1
done
for attempt in 1 2 3; do
    systemctl enable nftband.service 2>/dev/null && break
    sleep 1
done

# Verify enable succeeded, warn if not
if ! systemctl is-enabled nftband.service >/dev/null 2>&1; then
    echo "[NFTBan WARN] nftband.service not enabled (run: systemctl enable nftband.service)"
fi

# Start socket and service
systemctl start nftband.socket 2>/dev/null || true
systemctl start nftband.service 2>/dev/null || true
echo "[NFTBan]   Socket and service started"
sleep 1
if timeout 10s nftban sync >/dev/null 2>&1; then
    echo "[NFTBan]   Daemon verified via sync"
else
    sleep 2
    timeout 10s nftban sync >/dev/null 2>&1 || echo "[NFTBan WARN] Sync failed (non-critical)"
fi

# Install Suricata logrotate only if suricata user exists
if id suricata &>/dev/null; then
    install -m 0644 /etc/nftban/templates/nftban-suricata.logrotate /etc/logrotate.d/nftban-suricata 2>/dev/null || true
    echo "[NFTBan] Suricata logrotate installed"
else
    rm -f /etc/logrotate.d/nftban-suricata 2>/dev/null || true
fi

# Enable and start core timers (reconciliation already read NFTBAN_RECONCILE above)
if [ "\$NFTBAN_RECONCILE" = "true" ]; then
    echo "[NFTBan] Starting core timers..."
    systemctl enable --now nftban-maintenance.timer 2>/dev/null || true
    systemctl enable --now nftban-health.timer 2>/dev/null || true
    systemctl enable --now nftban-watchdog.timer 2>/dev/null || true
    systemctl enable --now nftban-core-geoip.timer 2>/dev/null || true
    systemctl enable --now nftban-core-feeds.timer 2>/dev/null || true
    systemctl enable --now nftban-unified-exporter.timer 2>/dev/null || true

    # Start queue timer only if unit file exists (BUG-005 fix)
    if systemctl list-unit-files nftban-queue.timer --no-legend 2>/dev/null | grep -q '^nftban-queue.timer'; then
        systemctl enable --now nftban-queue.timer 2>/dev/null || true
    else
        echo "[NFTBan WARN] nftban-queue.timer not installed (optional)"
    fi
fi

# Start botscan timer (Clock 3 — module-specific, not subject to reconciliation)
if systemctl list-unit-files nftban-botscan.timer --no-legend 2>/dev/null | grep -q '^nftban-botscan.timer'; then
    systemctl enable --now nftban-botscan.timer 2>/dev/null || true
fi

# v1.23.0 (EVAL-3): Login monitor service REMOVED from package
# Stop and disable if still present from previous versions (upgrade cleanup)
if systemctl is-active nftban-login-monitor.service >/dev/null 2>&1 || \
   systemctl is-enabled nftban-login-monitor.service >/dev/null 2>&1; then
    echo "[NFTBan] Cleaning up deprecated nftban-login-monitor.service..."
    systemctl disable --now nftban-login-monitor.service 2>/dev/null || true
    echo "[NFTBan] Login monitoring now handled by daemon loginmon module (pkg/loginmon)"
fi

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

# STEP 10: Sync whitelist.d files to nftables sets
echo "[NFTBan] Syncing whitelist files to nftables..."
SYNC_SUCCESS=0
for i in 1 2 3; do
    sleep 1
    if nftban sync >/dev/null 2>&1; then
        SYNC_SUCCESS=1
        echo "[NFTBan]   Whitelist sync completed successfully"
        break
    fi
done
if [ "\$SYNC_SUCCESS" -eq 0 ]; then
    echo "[NFTBan WARN] Whitelist sync failed (run manually: nftban sync)"
fi

# =============================================================================
# PREFLIGHT: Lockout Prevention (Detect-Only, Fail-Safe)
# =============================================================================
# CRITICAL: Never modify third-party firewall config
# CRITICAL: Never start nftables if unsafe
# CRITICAL: Always preserve SSH access
echo "[NFTBan] Preflight: Validating firewall safety..."
NFTABLES_SAFE=1

# Check 1: Detect and AUTO-FIX incompatible xt target rules (v1.17.5)
# cPanel/WHM creates iptables-nft rules with "xt target REDIRECT" that modern nftables cannot load
# This affects BOTH RPM and DEB distros when cPanel is installed
# Get distro-specific nftables config path
if [ -f /etc/sysconfig/nftables.conf ]; then
    NFT_CONFIG="/etc/sysconfig/nftables.conf"
elif [ -f /etc/nftables.conf ]; then
    NFT_CONFIG="/etc/nftables.conf"
else
    NFT_CONFIG=""
fi

if [ -n "\$NFT_CONFIG" ] && [ -f "\$NFT_CONFIG" ]; then
    NFT_CHECK=\$(nft -c -f "\$NFT_CONFIG" 2>&1 || true)
    if echo "\$NFT_CHECK" | grep -qE "xt target|xtables compat"; then
        echo ""
        echo "[NFTBan] =========================================="
        echo "[NFTBan]  INCOMPATIBLE IPTABLES-NFT RULES DETECTED"
        echo "[NFTBan] =========================================="
        echo "[NFTBan] File: \$NFT_CONFIG"
        echo "[NFTBan] Issue: Legacy xt target rules (cPanel/iptables-nft)"
        echo ""
        echo "[NFTBan] AUTO-FIXING: Backing up and replacing config..."
        cp "\$NFT_CONFIG" "\${NFT_CONFIG}.xt-backup.\$(date +%%Y%%m%%d%%H%%M%%S)"
        cat > "\$NFT_CONFIG" << 'NFTCLEAN'
#!/usr/sbin/nft -f
# NFTBan v1.17.5 - Clean nftables config
# Original backed up to *.xt-backup.* (had incompatible xt target rules)
# Load NFTBan firewall configuration
include "/etc/nftban/nftables.conf"
NFTCLEAN
        echo "[NFTBan] ✓ Config replaced with clean NFTBan loader"
        echo "[NFTBan] ✓ Original backed up to \${NFT_CONFIG}.xt-backup.*"
        echo ""
    fi
fi

# Check 2: Verify whitelist has IPs
if [ -f /etc/nftban/whitelist.d/00-system.conf ]; then
    if ! grep -qE "^[0-9]+\\.[0-9]+" /etc/nftban/whitelist.d/00-system.conf 2>/dev/null; then
        echo "[NFTBan WARN] No IPs detected in system whitelist"
        echo "[NFTBan WARN] Your SSH IP may not be protected - please verify"
    fi
fi

# Check 3: Verify nftban config is valid
# v1.24.0: Substitute __SSH_PORT__ placeholder before validation
if [ -f /etc/nftban/nftables.conf ]; then
    _SSH_PORT=22
    [ -f /var/lib/nftban/state/ssh_port_active.state ] && _SSH_PORT=\$(cat /var/lib/nftban/state/ssh_port_active.state 2>/dev/null) || true
    echo "\$_SSH_PORT" | grep -qE '^[0-9]+\$' || _SSH_PORT=22
    if grep -q '__SSH_PORT__' /etc/nftban/nftables.conf 2>/dev/null; then
        _TMP_CONF=\$(mktemp 2>/dev/null) || _TMP_CONF=""
        if [ -n "\$_TMP_CONF" ]; then
            sed "s/__SSH_PORT__/\${_SSH_PORT}/g" /etc/nftban/nftables.conf > "\$_TMP_CONF"
            if ! nft -c -f "\$_TMP_CONF" 2>/dev/null; then
                echo "[NFTBan ERROR] NFTBan nftables config validation failed"
                NFTABLES_SAFE=0
            fi
            rm -f "\$_TMP_CONF"
        fi
    else
        if ! nft -c -f /etc/nftban/nftables.conf 2>/dev/null; then
            echo "[NFTBan ERROR] NFTBan nftables config validation failed"
            NFTABLES_SAFE=0
        fi
    fi
fi

# STEP 11: Load nftables configuration
if [ "\$NFTABLES_SAFE" -eq 1 ]; then
    if systemctl is-active nftables >/dev/null 2>&1; then
        systemctl reload nftables 2>/dev/null || echo "[NFTBan WARN] nftables reload failed"
    else
        systemctl enable nftables 2>/dev/null || true
        systemctl start nftables 2>/dev/null || echo "[NFTBan WARN] nftables start failed"
    fi

    # v1.18.7: Schema migration - auto rebuild ONLY if schema changed
    CURRENT_SCHEMA="2.1"
    SCHEMA_FILE="/etc/nftban/.schema_version"
    INSTALLED_SCHEMA=\$(cat "\$SCHEMA_FILE" 2>/dev/null || echo "1.0")

    sleep 1
    if [[ "\$INSTALLED_SCHEMA" != "\$CURRENT_SCHEMA" ]]; then
        echo "[NFTBan] Schema migration: \$INSTALLED_SCHEMA -> \$CURRENT_SCHEMA"
        echo "[NFTBan] Rebuilding firewall (temp bans will be cleared)..."
        if nftban firewall rebuild >/dev/null 2>&1; then
            echo "\$CURRENT_SCHEMA" > "\$SCHEMA_FILE"
            # Sync configs to load all values (ports, whitelist, blacklist)
            nftban sync >/dev/null 2>&1 || true
            echo "[NFTBan] Schema migration complete."
        else
            echo "[NFTBan WARN] Firewall rebuild failed - run manually: nftban firewall rebuild"
        fi
    else
        # Schema unchanged - just sync (preserves temp bans)
        nftban sync >/dev/null 2>&1 || echo "[NFTBan WARN] Sync failed (non-critical)"
    fi

    # v1.18.7: Auto-detect and protect services
    echo "[NFTBan] Detecting services..."

    # Detect panel and enable ports
    DETECTED_PANEL=\$(nftban panel detect 2>/dev/null || echo "none")
    if [[ "\$DETECTED_PANEL" != "none" && -n "\$DETECTED_PANEL" ]]; then
        echo "[NFTBan] Panel detected: \$DETECTED_PANEL - enabling ports..."
        nftban panel "\$DETECTED_PANEL" enable >/dev/null 2>&1 || true
    fi

    # v1.23.0: Login monitoring handled by daemon loginmon module
    nftban login enable >/dev/null 2>&1 || true

    # Show detected services
    DETECTED_SERVICES=\$(nftban login services 2>/dev/null | grep -v "^Detected" | tr '\n' ' ' || echo "ssh")
    echo "[NFTBan] Login protection enabled for:\$DETECTED_SERVICES"

    echo "[NFTBan] Installation complete. Your IP has been auto-whitelisted."
else
    echo ""
    echo "[NFTBan WARN] =========================================="
    echo "[NFTBan WARN]  NFTABLES NOT ACTIVATED (Safety Mode)"
    echo "[NFTBan WARN] =========================================="
    echo "[NFTBan WARN] Install completed but firewall is NOT active."
    echo "[NFTBan WARN] SSH access is preserved. Fix issues above, then run:"
    echo "[NFTBan WARN]   systemctl start nftables"
    echo ""
fi
echo "[NFTBan] Essential timers started. Run 'nftban timers enable' to start all optional timers."

# Cleanup emergency protection table (v1.17.4)
# NFTBan is now fully operational, emergency protection no longer needed
if nft list table inet nftban_install_emergency >/dev/null 2>&1; then
    nft delete table inet nftban_install_emergency 2>/dev/null || true
    echo "[NFTBan] Emergency protection table cleaned up"
fi

# =============================================================================
# STEP 11.5: Auto-enable panel ports (BUG-HIGH-002 fix)
# =============================================================================
# Detect hosting panels and auto-enable their management ports
# to prevent lockout during install on panel servers.
echo "[NFTBan] Detecting hosting panels..."

PANEL_DETECTED="none"
PANEL_PORTS=""
PANEL_NAME=""

# Detect panel type (same logic as nftban_panel_detect)
if [[ -d /usr/local/cpanel ]]; then
    PANEL_DETECTED="cpanel"
    PANEL_NAME="cPanel/WHM"
    # Critical cPanel/WHM management ports (TCP inbound)
    PANEL_PORTS="2082,2083,2086,2087"

    # cPanel iptables-nft cleanup: Remove legacy xt_target rules that break nftables
    for nft_conf in /etc/sysconfig/nftables.conf /etc/nftables.conf; do
        if [[ -f "\$nft_conf" ]] && grep -q "xt target\|xtables compat" "\$nft_conf" 2>/dev/null; then
            echo "[NFTBan]   cPanel: Cleaning iptables-nft legacy rules from \$nft_conf"
            cp "\$nft_conf" "\${nft_conf}.cpanel.bak"
            cat > "\$nft_conf" << 'NFTCONF'
#!/usr/sbin/nft -f
# nftables configuration - managed by NFTBan
# cPanel legacy iptables-nft rules backed up to .cpanel.bak
flush ruleset
include "/etc/nftban/nftables.conf"
NFTCONF
            echo "[NFTBan]   cPanel: Legacy rules backed up, NFTBan config enabled"
        fi
    done
elif [[ -d /usr/local/directadmin ]]; then
    PANEL_DETECTED="directadmin"
    PANEL_NAME="DirectAdmin"
    # DirectAdmin management port (TCP inbound)
    PANEL_PORTS="2222"
elif [[ -d /usr/local/psa ]]; then
    PANEL_DETECTED="plesk"
    PANEL_NAME="Plesk"
    # Plesk management ports (TCP inbound)
    PANEL_PORTS="8443,8880"
elif [[ -d /usr/local/CyberCP ]]; then
    PANEL_DETECTED="cyberpanel"
    PANEL_NAME="CyberPanel"
    # CyberPanel management ports (TCP inbound)
    PANEL_PORTS="7080,8090"
elif [[ -d /usr/local/hestia ]]; then
    PANEL_DETECTED="hestia"
    PANEL_NAME="HestiaCP"
    # HestiaCP management port (TCP inbound)
    PANEL_PORTS="8083"
elif [[ -d /usr/local/vesta ]]; then
    PANEL_DETECTED="vesta"
    PANEL_NAME="VestaCP"
    # VestaCP management port (TCP inbound)
    PANEL_PORTS="8083"
elif [[ -d /usr/local/cwpsrv ]]; then
    PANEL_DETECTED="cwp"
    PANEL_NAME="CentOS Web Panel"
    # CWP management ports (TCP inbound)
    PANEL_PORTS="2030,2031"
elif [[ -d /usr/local/interworx ]]; then
    PANEL_DETECTED="interworx"
    PANEL_NAME="InterWorx"
    # InterWorx management ports (TCP inbound)
    PANEL_PORTS="2080,2443"
fi

if [[ "\$PANEL_DETECTED" != "none" ]]; then
    echo "[NFTBan]   Detected: \$PANEL_NAME"
    echo "[NFTBan]   Auto-enabling panel management ports: \$PANEL_PORTS"

    # Create ports.d directory if missing
    mkdir -p /etc/nftban/ports.d
    chmod 750 /etc/nftban/ports.d
    chown root:nftban /etc/nftban/ports.d 2>/dev/null || true

    # Use dedicated panel port config file (idempotent)
    PANEL_PORT_FILE="/etc/nftban/ports.d/10-panel.conf"

    # Only add if not already configured (idempotent)
    if [[ ! -f "\$PANEL_PORT_FILE" ]] || ! grep -q "^# Panel: \$PANEL_NAME" "\$PANEL_PORT_FILE" 2>/dev/null; then
        {
            echo "# ============================================="
            echo "# NFTBan Auto-Detected Panel Ports"
            echo "# Generated during install: \$(date '+%%Y-%%m-%%d %%H:%%M:%%S')"
            echo "# Panel: \$PANEL_NAME"
            echo "# ============================================="
            echo "# Format: PORT/PROTOCOL/DIRECTION"
            echo "# T=TCP, U=UDP, B=Both | I=Input, O=Output, IO=Both"
            echo ""
            # Add each port as TCP inbound (panel management ports)
            IFS=',' read -ra PORT_ARRAY <<< "\$PANEL_PORTS"
            for port in "\${PORT_ARRAY[@]}"; do
                echo "# \$PANEL_NAME port \$port (TCP inbound)"
                echo "\${port}/T/I"
            done
        } > "\$PANEL_PORT_FILE"

        chmod 640 "\$PANEL_PORT_FILE"
        chown root:nftban "\$PANEL_PORT_FILE" 2>/dev/null || true
        echo "[NFTBan]   Created: \$PANEL_PORT_FILE"
        echo "[NFTBan]   Panel ports will be active after firewall sync"
    else
        echo "[NFTBan]   Panel ports already configured (skipping)"
    fi
else
    echo "[NFTBan]   No hosting panel detected (standalone server)"
fi

# FIX v1.17.0: Final cache ownership fix (exporter runs as nftban user)
# Must be at END of post-install to catch any files created during setup
# Using find instead of chown -R for safety (no symlink traversal)
find /var/cache/nftban -type f -exec chown nftban:nftban {} \; 2>/dev/null || true
find /var/cache/nftban -type d -exec chown nftban:nftban {} \; 2>/dev/null || true

%preun
# Remove immutable flags before uninstall/upgrade
for immutable_file in /etc/nftban/nftban.conf /usr/lib/nftban/lib/nft_schema.sh; do
    if [ -f "\$immutable_file" ]; then
        chattr -i "\$immutable_file" 2>/dev/null || true
    fi
done
# FULL list of all systemd units — must match DEB prerm
# NOTE: %%systemd_preun macros removed due to el10 compatibility issues
# Using explicit systemctl commands instead (same functionality)
if [ \$1 -eq 0 ]; then
    # Complete uninstall: stop and disable all services
    for unit in nftband.socket nftband.service nftban-maintenance.service nftban-maintenance.timer \
                nftban-health.service nftban-health.timer nftban-health-fix.service \
                nftban-watchdog.service nftban-watchdog.timer nftban-login-monitor.service \
                nftban-core-geoip.service nftban-core-geoip.timer nftban-core-feeds.service \
                nftban-core-feeds.timer nftban-unified-exporter.service nftban-unified-exporter.timer \
                nftban-queue.service nftban-queue.timer nftban-botscan.service nftban-botscan.timer \
                nftban-rbl-check.service nftban-rbl-check.timer \
                nftban-rollback.service nftban-rollback.timer nftban-snapshot.service nftban-snapshot.timer \
                nftban-suricata-update.service nftban-suricata-update.timer nftban-suricata.service \
                nftban-suricata-stats.service nftban-pro-inventory.service nftban-pro-inventory.timer \
                nftban-pro-license.service nftban-pro-license.timer nftban-update.service nftban-update.timer \
                nftban-api.service nftban-firewall-init.service nftban-ui.service \
                nftban-ui-auth.socket nftban-ui-auth.service; do
        systemctl stop "\$unit" 2>/dev/null || true
        systemctl disable "\$unit" 2>/dev/null || true
    done
fi

%postun
# NOTE: %%systemd_postun_with_restart macros removed due to el10 compatibility issues
# Using explicit systemctl commands instead (same functionality)
if [ \$1 -ge 1 ]; then
    # Upgrade: restart services that were running
    systemctl try-restart nftband.service 2>/dev/null || true
fi

# =============================================================================
# Complete removal (\$1 -eq 0) — FULL CLEANUP
# Must match DEB postrm purge section
# =============================================================================
if [ \$1 -eq 0 ]; then
    echo "[NFTBan] Complete removal — cleaning up all artifacts..."

    # Remove nftables tables (CRITICAL — firewall rules persist otherwise)
    if command -v nft >/dev/null 2>&1; then
        nft delete table ip nftban 2>/dev/null || true
        nft delete table ip6 nftban 2>/dev/null || true
    fi

    # Remove runtime directories
    rm -rf /run/nftban /run/nftban-ui 2>/dev/null || true

    # Remove tmpfiles.d configuration
    rm -f /etc/tmpfiles.d/nftban.conf 2>/dev/null || true
    rm -f /usr/lib/tmpfiles.d/nftban.conf 2>/dev/null || true

    # Remove logrotate configuration
    rm -f /etc/logrotate.d/nftban 2>/dev/null || true
    rm -f /etc/logrotate.d/nftban-suricata 2>/dev/null || true

    # Remove polkit rules and actions
    rm -f /etc/polkit-1/rules.d/*nftban*.rules 2>/dev/null || true
    rm -f /usr/share/polkit-1/rules.d/*nftban*.rules 2>/dev/null || true
    rm -f /usr/share/polkit-1/actions/com.nftban.* 2>/dev/null || true

    # Remove yq symlink (only if it points to our bundled binary)
    if [ -L /usr/bin/yq ] && readlink /usr/bin/yq | grep -q nftban; then
        rm -f /usr/bin/yq 2>/dev/null || true
    fi

    # Remove NFTBan include from system nftables config (distro-aware paths)
    for nft_conf in /etc/sysconfig/nftables.conf /etc/nftables.conf; do
        if [ -f "\$nft_conf" ]; then
            sed -i '/nftban/d' "\$nft_conf" 2>/dev/null || true
        fi
    done

    # Remove ALL configuration, data, logs, cache directories
    rm -rf /etc/nftban 2>/dev/null || true
    rm -rf /var/lib/nftban 2>/dev/null || true
    rm -rf /var/log/nftban 2>/dev/null || true
    rm -rf /var/cache/nftban 2>/dev/null || true
    rm -rf /usr/share/nftban 2>/dev/null || true

    echo "[NFTBan] Complete removal finished."
    echo "[NFTBan] User accounts/groups preserved (manual: userdel nftban; groupdel nftban)."
fi

%files
/usr/sbin/nftban
/usr/sbin/nftban-ui
/usr/libexec/nftban-ui-auth
/usr/lib/nftban/bin
/usr/lib/nftban/sbin
/usr/lib/nftban/VERSION
/usr/lib/nftban/BUILD_TARGET
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
/usr/share/nftban/selinux
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
%dir %attr(750,root,nftban) /etc/nftban/conf.d/botguard
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/botguard/main.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/botguard/allowed_crawlers.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/botguard/denied_crawlers.conf
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
%dir %attr(750,root,nftban) /etc/nftban/templates
/etc/nftban/templates/nftban.logrotate
/etc/nftban/templates/nftban-suricata.logrotate
%dir %attr(750,nftban,nftban) /var/lib/nftban
%dir %attr(750,nftban,nftban) /var/lib/nftban/feeds
%dir %attr(750,nftban,nftban) /var/lib/nftban/geoip
%dir %attr(750,nftban,nftban) /var/lib/nftban/staging
%dir %attr(750,nftban,nftban) /var/lib/nftban/reports
%dir %attr(750,nftban,nftban) /var/lib/nftban/botguard
%dir %attr(750,nftban,nftban) /var/log/nftban
%dir %attr(750,nftban,nftban) /var/log/nftban/botguard
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
    then
        log_error "Failed to write spec file"
        return 1
    fi
    log_success "Spec file created"
    return 0
}

build_rpm() {
    log_info "Building RPM packages..."

    # Check if rpmbuild is available
    if ! command -v rpmbuild &>/dev/null; then
        log_warn "rpmbuild not found, skipping RPM build"
        return 0
    fi

    mkdir -p "${BUILD_DIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

    # Debug: Show key variables
    log_info "BUILD_DIR=${BUILD_DIR}"
    log_info "PKG_VERSION=${PKG_VERSION}"
    log_info "PKG_RELEASE=${PKG_RELEASE}"
    log_info "PROJECT_ROOT=${PROJECT_ROOT}"

    # Create spec file
    create_rpm_spec_nftban_core || {
        log_error "create_rpm_spec_nftban_core failed"
        return 1
    }

    # Validate spec file was created correctly
    local spec_file="${BUILD_DIR}/SPECS/nftban-core.spec"
    if [[ ! -f "$spec_file" ]]; then
        log_error "Spec file not created: $spec_file"
        return 1
    fi
    local spec_size
    spec_size=$(stat -c%s "$spec_file" 2>/dev/null || echo "0")
    if [[ $spec_size -lt 1000 ]]; then
        log_error "Spec file too small ($spec_size bytes), likely empty or corrupted"
        log_error "Content:"
        head -20 "$spec_file" || true
        return 1
    fi
    log_success "Spec file created: $spec_file ($spec_size bytes)"
    # Show first line to verify it's valid
    log_info "Spec first line: $(head -1 "$spec_file")"

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
Depends: nftables (>= 0.9.0), systemd, bash (>= 4.0), bash-completion, jq, curl, tar, gzip, libpam0g, bc, gawk, socat, acl, polkitd | policykit-1
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
PREREQ_ERRORS=""

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

    # Check distro version matches package (prevent wrong package install)
    # BUILD_DISTRO is injected at build time by CI (e.g., "ubuntu22.04", "debian12")
    PKG_BUILD_DISTRO="__BUILD_DISTRO__"
    if [ "$PKG_BUILD_DISTRO" != "__BUILD_DISTRO__" ] && [ -n "$PKG_BUILD_DISTRO" ]; then
        case "$ID" in
            ubuntu)
                SYS_DISTRO_TAG="ubuntu${VERSION_ID}"
                if [ "$PKG_BUILD_DISTRO" != "$SYS_DISTRO_TAG" ]; then
                    echo "[✗] ERROR: Wrong package for this system!"
                    echo "    Package built for: ${PKG_BUILD_DISTRO}"
                    echo "    System version:    ${SYS_DISTRO_TAG}"
                    echo "    Use the correct package: nftban-${SYS_DISTRO_TAG}-amd64.deb"
                    PREREQ_FAILED=1
                    PREREQ_ERRORS="WRONG PACKAGE: This is a ${PKG_BUILD_DISTRO} package but you are running ${SYS_DISTRO_TAG}. Download: nftban-${SYS_DISTRO_TAG}-amd64.deb"
                fi
                ;;
            debian)
                SYS_DISTRO_TAG="debian${VERSION_ID%%.*}"
                if [ "$PKG_BUILD_DISTRO" != "$SYS_DISTRO_TAG" ]; then
                    # Allow debian package on debian (different minor is OK)
                    PKG_IS_DEBIAN=$(echo "$PKG_BUILD_DISTRO" | grep -c '^debian' || echo "0")
                    if [ "$PKG_IS_DEBIAN" = "1" ]; then
                        PKG_DEB_MAJOR=$(echo "$PKG_BUILD_DISTRO" | sed -n 's/^debian\([0-9]*\).*/\1/p')
                        SYS_DEB_MAJOR="${VERSION_ID%%.*}"
                        if [ "$PKG_DEB_MAJOR" != "$SYS_DEB_MAJOR" ]; then
                            echo "[✗] ERROR: Wrong package for this system!"
                            echo "    Package built for: Debian ${PKG_DEB_MAJOR}"
                            echo "    System version:    Debian ${SYS_DEB_MAJOR}"
                            echo "    Use the correct package: nftban-debian${SYS_DEB_MAJOR}-amd64.deb"
                            PREREQ_FAILED=1
                            PREREQ_ERRORS="WRONG PACKAGE: This is a Debian ${PKG_DEB_MAJOR} package but you are running Debian ${SYS_DEB_MAJOR}. Download: nftban-debian${SYS_DEB_MAJOR}-amd64.deb"
                        fi
                    else
                        echo "[✗] ERROR: Wrong package for this system!"
                        echo "    Package built for: ${PKG_BUILD_DISTRO}"
                        echo "    System version:    ${SYS_DISTRO_TAG}"
                        echo "    Use the correct package: nftban-${SYS_DISTRO_TAG}-amd64.deb"
                        PREREQ_FAILED=1
                        PREREQ_ERRORS="WRONG PACKAGE: This is a ${PKG_BUILD_DISTRO} package but you are running ${SYS_DISTRO_TAG}. Download: nftban-${SYS_DISTRO_TAG}-amd64.deb"
                    fi
                fi
                ;;
        esac
    fi
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
    if [ -n "$PREREQ_ERRORS" ]; then
        echo "ROOT CAUSE: $PREREQ_ERRORS"
        echo ""
    fi
    echo "If missing dependencies, install using apt (not dpkg):"
    echo ""
    echo "  sudo apt update"
    echo "  sudo apt install -y ./nftban-*.deb"
    echo ""
    echo "apt will automatically install missing dependencies (nftables, curl, jq)."
    echo "════════════════════════════════════════════════════════════════════════════════"
    echo ""
    # Print root cause to stderr as well (survives dpkg/apt noise)
    [ -n "$PREREQ_ERRORS" ] && echo "NFTBan: $PREREQ_ERRORS" >&2
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

    # Inject actual version and build distro into preinst
    sed -i "s/__PKG_VERSION__/${PKG_VERSION}/g; s/v1\.0\.0/v${PKG_VERSION}/g" "${BUILD_DIR}/deb/DEBIAN/preinst"
    # BUILD_DISTRO is set by CI (e.g., "ubuntu22.04", "debian12") or auto-detected
    local build_distro="${BUILD_DISTRO:-}"
    if [[ -z "$build_distro" ]] && [[ -f /etc/os-release ]]; then
        source /etc/os-release
        case "${ID:-}" in
            ubuntu) build_distro="ubuntu${VERSION_ID}" ;;
            debian) build_distro="debian${VERSION_ID%%.*}" ;;
        esac
    fi
    if [[ -n "$build_distro" ]]; then
        sed -i "s/__BUILD_DISTRO__/${build_distro}/g" "${BUILD_DIR}/deb/DEBIAN/preinst"
    fi
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

# STEP 0: Cleanup obsolete/stale files from ALL previous versions
# UNIFIED STALE CLEANUP — must match RPM %post and DEB postinst cleanup
echo "[NFTBan] Cleaning up obsolete files from previous versions..."

# --- Binary paths (pre-1.8.13) ---
if [ -f "/usr/bin/nftban" ] && [ ! -L "/usr/bin/nftban" ]; then
    rm -f "/usr/bin/nftban"
    echo "[NFTBan] Removed stale: /usr/bin/nftban (migrated to /usr/sbin)"
fi

# --- Nested directories (pre-1.13.9) ---
for stale_dir in "/usr/lib/nftban/lib/nftban" "/usr/lib/nftban/etc"; do
    if [ -d "$stale_dir" ]; then
        rm -rf "$stale_dir"
        echo "[NFTBan] Removed stale dir: $stale_dir"
    fi
done

# --- Relocated shell scripts (pre-1.15) ---
for stale_file in \
    "/usr/lib/nftban/core/cmd_health.sh" \
    "/usr/lib/nftban/json_output.sh" \
    "/usr/lib/nftban/cmd_ui.sh"; do
    if [ -f "$stale_file" ]; then
        rm -f "$stale_file"
        echo "[NFTBan] Removed stale: $stale_file"
    fi
done

# --- Obsolete Polkit rules (pre-1.0.18) ---
for stale_polkit in \
    /etc/polkit-1/rules.d/10-nftban-core.rules \
    /etc/polkit-1/rules.d/20-nftban-suricata.rules \
    /etc/polkit-1/rules.d/50-nftban-auth.rules \
    /etc/polkit-1/rules.d/50-nftban-auth.rules.in \
    /etc/polkit-1/rules.d/50-nftban-v030.rules \
    /etc/polkit-1/rules.d/60-nftban-services.rules \
    /etc/polkit-1/rules.d/50-nftban-port-status.rules \
    /etc/polkit-1/rules.d/50-nftban-port-status.rules.in \
    /usr/share/polkit-1/rules.d/10-nftban-core.rules \
    /usr/share/polkit-1/rules.d/20-nftban-suricata.rules \
    /usr/share/polkit-1/rules.d/50-nftban-auth.rules \
    /usr/share/polkit-1/rules.d/50-nftban-v030.rules \
    /usr/share/polkit-1/rules.d/60-nftban-services.rules \
    /usr/share/polkit-1/rules.d/50-nftban-port-status.rules \
    /usr/share/polkit-1/actions/com.nftban.suricata.policy; do
    if [ -f "$stale_polkit" ]; then
        rm -f "$stale_polkit"
        echo "[NFTBan] Removed stale polkit: $stale_polkit"
    fi
done

# --- Old systemd overrides (various versions) ---
rm -f /etc/systemd/system/nftban-*.service 2>/dev/null || true
rm -f /etc/systemd/system/nftban-*.timer 2>/dev/null || true
rm -rf /etc/systemd/system/nftban-*.service.d 2>/dev/null || true
systemctl daemon-reload 2>/dev/null || true

# --- Suricata blocks in main logrotate (pre-1.19.6) ---
if [ -f /etc/logrotate.d/nftban ]; then
    if grep -q "su suricata" /etc/logrotate.d/nftban 2>/dev/null; then
        echo "[NFTBan] Detected old Suricata blocks in /etc/logrotate.d/nftban — replacing with clean version"
        install -m 0644 /etc/nftban/templates/nftban.logrotate /etc/logrotate.d/nftban 2>/dev/null || true
    fi
fi

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
mkdir -p /etc/nftban/conf.d/{ddos,portscan,login,panels,botscan,botguard,rbl}
mkdir -p /etc/nftban/patterns.d/botscan
mkdir -p /var/lib/nftban/{banned,whitelist,feeds,geoip,reports,config,state,metrics,snapshots,exports,panels,botguard,suricata}
mkdir -p /var/lib/nftban/reports/{baseline,auditors}
mkdir -p /var/log/nftban/{reports,botguard}
mkdir -p /var/cache/nftban/health
mkdir -p /run/nftban
mkdir -p /usr/share/nftban/templates/{mail,reports}

# Prometheus textfile_collector directory (BUG-009 fix)
# Required by nftban-unified-exporter.service ReadWritePaths directive
if [[ ! -d /var/lib/node_exporter/textfile_collector ]]; then
    mkdir -p /var/lib/node_exporter/textfile_collector
    chown nftban:nftban /var/lib/node_exporter/textfile_collector 2>/dev/null || true
    chmod 755 /var/lib/node_exporter/textfile_collector
fi

# STEP 4: Set permissions
chown root:nftban /etc/nftban
chmod 750 /etc/nftban
# Fix nftban.conf permissions (root:nftban 0640)
chown root:nftban /etc/nftban/nftban.conf 2>/dev/null || true
chmod 0640 /etc/nftban/nftban.conf 2>/dev/null || true
# CRITICAL: Fix conf.d permissions - services run as nftban user need group read access
find /etc/nftban/conf.d -type f -exec chown root:nftban {} \; 2>/dev/null || true
find /etc/nftban/conf.d -type d -exec chown root:nftban {} \; 2>/dev/null || true
find /etc/nftban/conf.d -type d -exec chmod 750 {} \; 2>/dev/null || true
find /etc/nftban/conf.d -type f -exec chmod 640 {} \; 2>/dev/null || true
# Fix other config subdirs
for subdir in distros whitelist.d blacklist.d ports.d rules.d suricata patterns.d; do
    if [ -d "/etc/nftban/$subdir" ]; then
        find "/etc/nftban/$subdir" -type f -exec chown root:nftban {} \; 2>/dev/null || true
        find "/etc/nftban/$subdir" -type d -exec chown root:nftban {} \; 2>/dev/null || true
        find "/etc/nftban/$subdir" -type d -exec chmod 750 {} \; 2>/dev/null || true
        find "/etc/nftban/$subdir" -type f -exec chmod 640 {} \; 2>/dev/null || true
    fi
done
find /var/lib/nftban /var/log/nftban /var/cache/nftban -type f -exec chown nftban:nftban {} \; 2>/dev/null || true
find /var/lib/nftban /var/log/nftban /var/cache/nftban -type d -exec chown nftban:nftban {} \; 2>/dev/null || true
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
    # v1.19.22: ALWAYS use --protect-session for both install AND upgrade
    # Rule: Any live nft reload/apply needs session protection (IPv4 + IPv6)
    nftban whitelist-system sync --quick --protect-session 2>/dev/null || echo "[NFTBan WARN] Auto-whitelist failed"
fi

# STEP 7: Download GeoIP database (free DB-IP version)
echo "[NFTBan] Downloading GeoIP database..."
if [ -x /usr/lib/nftban/bin/nftban-core ]; then
    timeout 120s /usr/lib/nftban/bin/nftban-core geoip update 2>&1 || echo "[NFTBan WARN] GeoIP download failed (will retry via timer)"
fi

# STEP 8: Enforce permissions and health check
if command -v nftban >/dev/null 2>&1; then
    echo "[NFTBan] Enforcing permissions..."
    nftban permissions enforce 2>/dev/null || true
    echo "[NFTBan] Running health check with auto-heal..."
    nftban health check --auto-heal --quiet 2>/dev/null || true
fi

# STEP 8.5: Cleanup rogue nftables tables before preflight
# v1.18.7: Auto-cleanup common legacy tables that block install
echo "[NFTBan] Cleaning up rogue nftables tables..."
for rogue_table in "ip filter" "ip6 filter" "inet filter" "inet nftban_install_emergency"; do
    if nft list table $rogue_table &>/dev/null; then
        echo "[NFTBan]   Removing rogue table: $rogue_table"
        nft delete table $rogue_table 2>/dev/null || true
    fi
done

# STEP 8.6: Strict Preflight Check - Gate Service Enablement
# This is the AUTHORITATIVE check that gates service enablement.
# If preflight fails, NFTBan installs but does NOT enforce.
# Uses consolidated command: nftban firewall validate --strict
echo "[NFTBan] Running strict preflight check..."

PREFLIGHT_PASSED=1
PREFLIGHT_EXIT=0

if command -v nftban >/dev/null 2>&1; then
    # Use consolidated command for strict validation
    # Exit codes: 0=OK, 10=policykit, 20=conflict, 30=collision, 40=env
    PREFLIGHT_OUTPUT=$(nftban firewall validate --strict 2>&1) || PREFLIGHT_EXIT=$?

    if [ $PREFLIGHT_EXIT -ne 0 ]; then
        PREFLIGHT_PASSED=0

        # v1.18.7: Parse actual output for accurate error message
        if echo "$PREFLIGHT_OUTPUT" | grep -q "CRITICAL:"; then
            PREFLIGHT_REASON=$(echo "$PREFLIGHT_OUTPUT" | grep "CRITICAL:" | head -1 | sed 's/.*CRITICAL: //')
        else
            # Fallback to exit code mapping
            case $PREFLIGHT_EXIT in
                10) PREFLIGHT_REASON="polkit missing (install polkitd or policykit-1)" ;;
                20) PREFLIGHT_REASON="Firewall authority conflict" ;;
                30) PREFLIGHT_REASON="NFTables hook collision" ;;
                *) PREFLIGHT_REASON="Validation failed (exit code: $PREFLIGHT_EXIT)" ;;
            esac
        fi
        PREFLIGHT_ACTION="nftban firewall validate --strict"

        echo ""
        echo "[NFTBan ERROR] Strict preflight failed - refusing to enable enforcement"
        echo "[NFTBan ERROR] Reason: $PREFLIGHT_REASON"
        echo "[NFTBan ERROR] Fix: $PREFLIGHT_ACTION"
        echo "[NFTBan ERROR] NFTBan is installed but NOT enforcing."
        echo "[NFTBan ERROR] Fix the issue and re-run installation"
        echo ""
    else
        echo "[NFTBan]   Strict preflight passed - safe to enable enforcement"
    fi
else
    echo "[NFTBan WARN] nftban command not found - skipping strict preflight"
fi

# Only enable services if preflight passed
if [ "$PREFLIGHT_PASSED" -eq 1 ]; then
# STEP 9: Enable services (AFTER whitelist is in place)
echo "[NFTBan] Enabling systemd services..."
systemctl daemon-reload
systemctl enable nftables 2>/dev/null || true

# Enable and start nftband daemon socket and service (CRITICAL for CLI communication)
# BUG-002 fix: Socket activation alone is unreliable on fresh install
# BUG-MED-001 fix: Must enable nftband.service for boot persistence
echo "[NFTBan] Starting nftband daemon..."

# Enable socket and service with retry (v1.17.3 robustness fix)
for attempt in 1 2 3; do
    systemctl enable nftband.socket 2>/dev/null && break
    sleep 1
done
for attempt in 1 2 3; do
    systemctl enable nftband.service 2>/dev/null && break
    sleep 1
done

# Verify enable succeeded, warn if not
if ! systemctl is-enabled nftband.service >/dev/null 2>&1; then
    echo "[NFTBan WARN] nftband.service not enabled (run: systemctl enable nftband.service)"
fi

# Start socket and service
systemctl start nftband.socket 2>/dev/null || true
systemctl start nftband.service 2>/dev/null || true
echo "[NFTBan]   Socket and service started"

# Verify daemon is operational via sync
sleep 1
if timeout 10s nftban sync >/dev/null 2>&1; then
    echo "[NFTBan]   Daemon verified via sync"
else
    sleep 2
    timeout 10s nftban sync >/dev/null 2>&1 || echo "[NFTBan WARN] Sync failed (non-critical)"
fi

# Install Suricata logrotate only if suricata user exists
if id suricata &>/dev/null; then
    install -m 0644 /etc/nftban/templates/nftban-suricata.logrotate /etc/logrotate.d/nftban-suricata 2>/dev/null || true
    echo "[NFTBan] Suricata logrotate installed"
else
    rm -f /etc/logrotate.d/nftban-suricata 2>/dev/null || true
fi

# Enable and start essential timers (respects RECONCILE_CORE_TIMERS)
NFTBAN_DEB_RECONCILE="true"
if [ -f /etc/nftban/nftban.conf ]; then
    _deb_reconcile=$(grep -m1 '^NFTBAN_RECONCILE_CORE_TIMERS=' /etc/nftban/nftban.conf 2>/dev/null | cut -d'"' -f2)
    [ -n "$_deb_reconcile" ] && NFTBAN_DEB_RECONCILE="$_deb_reconcile"
    if [ -f /etc/nftban/nftban.conf.local ]; then
        _deb_reconcile_local=$(grep -m1 '^NFTBAN_RECONCILE_CORE_TIMERS=' /etc/nftban/nftban.conf.local 2>/dev/null | cut -d'"' -f2)
        [ -n "$_deb_reconcile_local" ] && NFTBAN_DEB_RECONCILE="$_deb_reconcile_local"
    fi
fi

if [ "$NFTBAN_DEB_RECONCILE" = "true" ]; then
    echo "[NFTBan] Starting core timers (RECONCILE_CORE_TIMERS=true)..."
    systemctl enable --now nftban-maintenance.timer 2>/dev/null || true
    systemctl enable --now nftban-health.timer 2>/dev/null || true
    systemctl enable --now nftban-watchdog.timer 2>/dev/null || true
    systemctl enable --now nftban-core-geoip.timer 2>/dev/null || true
    systemctl enable --now nftban-core-feeds.timer 2>/dev/null || true
    systemctl enable --now nftban-unified-exporter.timer 2>/dev/null || true

    # Start queue timer only if unit file exists
    if systemctl list-unit-files nftban-queue.timer --no-legend 2>/dev/null | grep -q '^nftban-queue.timer'; then
        systemctl enable --now nftban-queue.timer 2>/dev/null || true
    fi
else
    echo "[NFTBan] Timer reconciliation disabled (RECONCILE_CORE_TIMERS=false)"
fi

# Start botscan timer (Clock 3 — module-specific, not subject to reconciliation)
if systemctl list-unit-files nftban-botscan.timer --no-legend 2>/dev/null | grep -q '^nftban-botscan.timer'; then
    systemctl enable --now nftban-botscan.timer 2>/dev/null || true
fi

# v1.23.0 (EVAL-3): Login monitor service REMOVED from package
# Stop and disable if still present from previous versions (upgrade cleanup)
if systemctl is-active nftban-login-monitor.service >/dev/null 2>&1 || \
   systemctl is-enabled nftban-login-monitor.service >/dev/null 2>&1; then
    echo "[NFTBan] Cleaning up deprecated nftban-login-monitor.service..."
    systemctl disable --now nftban-login-monitor.service 2>/dev/null || true
    echo "[NFTBan] Login monitoring now handled by daemon loginmon module (pkg/loginmon)"
fi

# PREFLIGHT: Detect and AUTO-FIX incompatible xt target rules (v1.17.5)
# cPanel/WHM creates iptables-nft rules with "xt target REDIRECT" that modern nftables cannot load
NFTABLES_SAFE=1
NFT_CONFIG=""
[ -f /etc/nftables.conf ] && NFT_CONFIG="/etc/nftables.conf"
[ -f /etc/sysconfig/nftables.conf ] && NFT_CONFIG="/etc/sysconfig/nftables.conf"
if [ -n "$NFT_CONFIG" ] && [ -f "$NFT_CONFIG" ]; then
    if nft -c -f "$NFT_CONFIG" 2>&1 | grep -qE "xt target|xtables compat"; then
        echo "[NFTBan] Incompatible xt target rules detected in $NFT_CONFIG"
        echo "[NFTBan] AUTO-FIXING: Backing up and replacing config..."
        cp "$NFT_CONFIG" "${NFT_CONFIG}.xt-backup.$(date +%Y%m%d%H%M%S)"
        cat > "$NFT_CONFIG" << 'NFTCLEAN'
#!/usr/sbin/nft -f
# NFTBan v1.17.5 - Clean nftables config
# Original backed up (had incompatible xt target rules)
include "/etc/nftban/nftables.conf"
NFTCLEAN
        echo "[NFTBan] ✓ Config replaced, original backed up"
    fi
fi

# STEP 10: Start or reload nftables ONLY IF SAFE
if [ "$NFTABLES_SAFE" -eq 1 ]; then
    if systemctl is-active nftables >/dev/null 2>&1; then
        systemctl reload nftables 2>/dev/null || true
    else
        systemctl start nftables 2>/dev/null || true
    fi

    # v1.18.7: Schema migration - auto rebuild ONLY if schema changed
    CURRENT_SCHEMA="2.1"
    SCHEMA_FILE="/etc/nftban/.schema_version"
    INSTALLED_SCHEMA=$(cat "$SCHEMA_FILE" 2>/dev/null || echo "1.0")

    sleep 1
    if [[ "$INSTALLED_SCHEMA" != "$CURRENT_SCHEMA" ]]; then
        echo "[NFTBan] Schema migration: $INSTALLED_SCHEMA -> $CURRENT_SCHEMA"
        echo "[NFTBan] Rebuilding firewall (temp bans will be cleared)..."
        if nftban firewall rebuild >/dev/null 2>&1; then
            echo "$CURRENT_SCHEMA" > "$SCHEMA_FILE"
            # Sync configs to load all values (ports, whitelist, blacklist)
            nftban sync >/dev/null 2>&1 || true
            echo "[NFTBan] Schema migration complete."
        else
            echo "[NFTBan WARN] Firewall rebuild failed - run manually: nftban firewall rebuild"
        fi
    else
        # Schema unchanged - just sync (preserves temp bans)
        nftban sync >/dev/null 2>&1 || echo "[NFTBan WARN] Sync failed (non-critical)"
    fi

    # v1.18.7: Auto-detect and protect services
    echo "[NFTBan] Detecting services..."

    # Detect panel and enable ports
    DETECTED_PANEL=$(nftban panel detect 2>/dev/null || echo "none")
    if [[ "$DETECTED_PANEL" != "none" && -n "$DETECTED_PANEL" ]]; then
        echo "[NFTBan] Panel detected: $DETECTED_PANEL - enabling ports..."
        nftban panel "$DETECTED_PANEL" enable >/dev/null 2>&1 || true
    fi

    # v1.23.0: Login monitoring handled by daemon loginmon module
    nftban login enable >/dev/null 2>&1 || true

    # Show detected services
    DETECTED_SERVICES=$(nftban login services 2>/dev/null | grep -v "^Detected" | tr '\n' ' ' || echo "ssh")
    echo "[NFTBan] Login protection enabled for:$DETECTED_SERVICES"

    echo "[NFTBan] Installation complete. Your IP has been auto-whitelisted."
else
    echo "[NFTBan WARN] NFTABLES NOT ACTIVATED (Safety Mode)"
    echo "[NFTBan WARN] Fix xt target issues, then run: systemctl start nftables"
fi
echo "[NFTBan] Essential timers started. Run 'nftban timers enable' to start all optional timers."

fi  # End of PREFLIGHT_PASSED check

# Handle preflight failure case - show final message
if [ "$PREFLIGHT_PASSED" -ne 1 ]; then
    echo ""
    echo "[NFTBan] ========================================"
    echo "[NFTBan]  NFTBan Files Installed"
    echo "[NFTBan] ========================================"
    echo "[NFTBan]"
    echo "[NFTBan] ENFORCEMENT DISABLED due to preflight failure."
    echo "[NFTBan]"
    echo "[NFTBan] To enable NFTBan after fixing conflicts:"
    echo "[NFTBan]   1. Fix the issue reported above"
    echo "[NFTBan]   2. Run: dpkg-reconfigure nftban-core"
    echo ""
fi

# =============================================================================
# STEP 10.5: Auto-enable panel ports (BUG-HIGH-002 fix)
# =============================================================================
# Detect hosting panels and auto-enable their management ports
# to prevent lockout during install on panel servers.
echo "[NFTBan] Detecting hosting panels..."

PANEL_DETECTED="none"
PANEL_PORTS=""
PANEL_NAME=""

# Detect panel type (same logic as nftban_panel_detect)
if [ -d /usr/local/cpanel ]; then
    PANEL_DETECTED="cpanel"
    PANEL_NAME="cPanel/WHM"
    PANEL_PORTS="2082,2083,2086,2087"
elif [ -d /usr/local/directadmin ]; then
    PANEL_DETECTED="directadmin"
    PANEL_NAME="DirectAdmin"
    PANEL_PORTS="2222"
elif [ -d /usr/local/psa ]; then
    PANEL_DETECTED="plesk"
    PANEL_NAME="Plesk"
    PANEL_PORTS="8443,8880"
elif [ -d /usr/local/CyberCP ]; then
    PANEL_DETECTED="cyberpanel"
    PANEL_NAME="CyberPanel"
    PANEL_PORTS="7080,8090"
elif [ -d /usr/local/hestia ]; then
    PANEL_DETECTED="hestia"
    PANEL_NAME="HestiaCP"
    PANEL_PORTS="8083"
elif [ -d /usr/local/vesta ]; then
    PANEL_DETECTED="vesta"
    PANEL_NAME="VestaCP"
    PANEL_PORTS="8083"
elif [ -d /usr/local/cwpsrv ]; then
    PANEL_DETECTED="cwp"
    PANEL_NAME="CentOS Web Panel"
    PANEL_PORTS="2030,2031"
elif [ -d /usr/local/interworx ]; then
    PANEL_DETECTED="interworx"
    PANEL_NAME="InterWorx"
    PANEL_PORTS="2080,2443"
fi

if [ "$PANEL_DETECTED" != "none" ]; then
    echo "[NFTBan]   Detected: $PANEL_NAME"
    echo "[NFTBan]   Auto-enabling panel management ports: $PANEL_PORTS"

    # =========================================================================
    # STEP 10.5a: Disable conflicting panel security tools
    # =========================================================================
    # NFTBan is THE ONLY firewall - disable redundant panel security tools

    if [ "$PANEL_DETECTED" = "cpanel" ]; then
        # Disable cphulk (cPanel brute force protection) - NFTBan handles this
        if [ -f /usr/local/cpanel/bin/cphulk ]; then
            echo "[NFTBan]   Disabling cphulk (redundant with NFTBan)..."
            /usr/local/cpanel/bin/cphulk --disable 2>/dev/null || true
            systemctl stop cphulkd 2>/dev/null || true
            systemctl disable cphulkd 2>/dev/null || true
        fi

        # Clean cPanel iptables-nft legacy rules (breaks nftables loading)
        for nft_conf in /etc/sysconfig/nftables.conf /etc/nftables.conf; do
            if [ -f "$nft_conf" ] && grep -q "xt target\|xtables compat\|XT_" "$nft_conf" 2>/dev/null; then
                echo "[NFTBan]   cPanel: Cleaning iptables-nft legacy rules from $nft_conf"
                cp "$nft_conf" "${nft_conf}.cpanel.bak"
                cat > "$nft_conf" << 'NFTCONF'
#!/usr/sbin/nft -f
# nftables configuration - managed by NFTBan
# cPanel legacy iptables-nft rules backed up to .cpanel.bak
flush ruleset
include "/etc/nftban/nftables.conf"
NFTCONF
                echo "[NFTBan]   cPanel: Legacy rules backed up, NFTBan config enabled"
            fi
        done

    elif [ "$PANEL_DETECTED" = "directadmin" ]; then
        # Disable CSF (ConfigServer Security & Firewall) - competing firewall
        if [ -f /etc/csf/csf.conf ] || [ -x /usr/sbin/csf ]; then
            echo "[NFTBan]   Disabling CSF (competing firewall)..."
            csf -x 2>/dev/null || true
            systemctl stop csf 2>/dev/null || true
            systemctl disable csf 2>/dev/null || true
            systemctl stop lfd 2>/dev/null || true
            systemctl disable lfd 2>/dev/null || true
        fi

    elif [ "$PANEL_DETECTED" = "plesk" ]; then
        # NOTE: Plesk fail2ban is left running - it's complementary (priority 0)
        # NFTBan runs at priority -100, fail2ban at 0, so NFTBan rules apply first
        echo "[NFTBan]   Plesk: fail2ban left running (complementary, priority 0)"
    fi

    # Create ports.d directory if missing
    mkdir -p /etc/nftban/ports.d
    chmod 750 /etc/nftban/ports.d
    chown root:nftban /etc/nftban/ports.d 2>/dev/null || true

    # Use dedicated panel port config file (idempotent)
    PANEL_PORT_FILE="/etc/nftban/ports.d/10-panel.conf"

    # Only add if not already configured (idempotent)
    if [ ! -f "$PANEL_PORT_FILE" ] || ! grep -q "^# Panel: $PANEL_NAME" "$PANEL_PORT_FILE" 2>/dev/null; then
        {
            echo "# ============================================="
            echo "# NFTBan Auto-Detected Panel Ports"
            echo "# Generated during install: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "# Panel: $PANEL_NAME"
            echo "# ============================================="
            echo "# Format: PORT/PROTOCOL/DIRECTION"
            echo "# T=TCP, U=UDP, B=Both | I=Input, O=Output, IO=Both"
            echo ""
            # Add each port as TCP inbound (panel management ports)
            # Use POSIX-compatible approach for portability
            echo "$PANEL_PORTS" | tr ',' '\n' | while read port; do
                echo "# $PANEL_NAME port $port (TCP inbound)"
                echo "${port}/T/I"
            done
        } > "$PANEL_PORT_FILE"

        chmod 640 "$PANEL_PORT_FILE"
        chown root:nftban "$PANEL_PORT_FILE" 2>/dev/null || true
        echo "[NFTBan]   Created: $PANEL_PORT_FILE"

        # Mark panel as enabled in state
        mkdir -p /var/lib/nftban/panels
        echo "${PANEL_DETECTED}=enabled" >> /var/lib/nftban/panels/enabled.conf
        echo "[NFTBan]   Panel ports will be active after firewall sync"
    else
        echo "[NFTBan]   Panel ports already configured (skipping)"
    fi
else
    echo "[NFTBan]   No hosting panel detected (standalone server)"
fi

# FIX v1.17.0: Final cache ownership fix (exporter runs as nftban user)
# Must be at END of post-install to catch any files created during setup
# Using find instead of chown -R for safety (no symlink traversal)
find /var/cache/nftban -type f -exec chown nftban:nftban {} \; 2>/dev/null || true
find /var/cache/nftban -type d -exec chown nftban:nftban {} \; 2>/dev/null || true

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
    for timer in nftban-maintenance.timer nftban-health.timer nftban-core-feeds.timer nftban-queue.timer nftban-botscan.timer; do
        systemctl stop "$timer" 2>/dev/null || true
    done
fi

exit 0
PRERM
    chmod 755 "${BUILD_DIR}/deb/DEBIAN/prerm"

    # P1-13 FIX: Include postrm for proper cleanup on apt-get purge
    if [[ -f "${PROJECT_ROOT}/packaging/deb/postrm" ]]; then
        cp "${PROJECT_ROOT}/packaging/deb/postrm" "${BUILD_DIR}/deb/DEBIAN/postrm"
        chmod 755 "${BUILD_DIR}/deb/DEBIAN/postrm"
    fi

    # BUG-L52 FIX: Reduced conffiles to only base config files that ship with
    # defaults. User-managed files (whitelist/blacklist) removed to avoid
    # interactive prompts during non-interactive upgrades.
    # Users should customize via .local override files (e.g., main.conf.local).
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
/etc/nftban/conf.d/botguard/main.conf
/etc/nftban/conf.d/botguard/allowed_crawlers.conf
/etc/nftban/conf.d/botguard/denied_crawlers.conf
/etc/nftban/conf.d/geoban/main.conf
/etc/nftban/conf.d/geoip/main.conf
/etc/nftban/conf.d/metrics.conf
/etc/nftban/conf.d/persistent.conf
/etc/nftban/conf.d/watchdog.conf
CONFFILES_EOF
}

build_deb() {
    log_info "Building DEB package..."

    local deb_root="${BUILD_DIR}/deb"
    rm -rf "${deb_root}"

    # Create directory structure
    # Bug #18: Debian/Ubuntu use /usr/share/polkit-1/rules.d/ for polkit rules
    mkdir -p "${deb_root}"/{DEBIAN,usr/bin,usr/sbin,usr/libexec,usr/lib/nftban/bin,usr/lib/systemd/system,etc/{nftables,nftban/{conf.d/botguard,distros,whitelist.d,blacklist.d,ports.d,rules.d}},usr/share/polkit-1/rules.d,var/{lib/nftban/{feeds,geoip,staging,reports,botguard},log/nftban/botguard,cache/nftban},run/nftban}

    # Copy binaries
    install -m 0755 "${PROJECT_ROOT}/bin/nftban-core" "${deb_root}/usr/lib/nftban/bin/"
    install -m 0755 "${PROJECT_ROOT}/bin/nftband" "${deb_root}/usr/lib/nftban/bin/"
    install -m 0755 "${PROJECT_ROOT}/cli/sbin/nftban" "${deb_root}/usr/sbin/"
    install -m 0755 "${PROJECT_ROOT}/bin/nftban-ui" "${deb_root}/usr/sbin/"
    install -m 0755 "${PROJECT_ROOT}/bin/nftban-ui-auth" "${deb_root}/usr/libexec/"

    # Download yq at BUILD time (supply-chain safe - not at install time)
    # SHA256 verified before bundling in package
    local YQ_VERSION="4.44.1"
    local YQ_SHA256="6dc2d0cd4e0caca5aeffd0d784a48263591080e4a0895abe69f3a76eb50d1ba3"
    log_info "Downloading yq v${YQ_VERSION} for bundling..."
    curl -sL "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" -o "${BUILD_DIR}/yq_linux_amd64"
    echo "${YQ_SHA256}  ${BUILD_DIR}/yq_linux_amd64" | sha256sum -c - || { log_error "yq checksum verification failed!"; exit 1; }
    install -m 0755 "${BUILD_DIR}/yq_linux_amd64" "${deb_root}/usr/lib/nftban/bin/yq"
    log_info "yq v${YQ_VERSION} bundled (SHA256 verified)"

    # Copy helper scripts to /usr/lib/nftban/sbin/
    # CRITICAL: These scripts are executed by systemd services and MUST have 755 permissions
    # Bug fix v1.9.4: Ensure sbin scripts are always installed with correct permissions
    mkdir -p "${deb_root}/usr/lib/nftban/sbin"
    local sbin_count=0
    for script in nftban-apply nftban-confirm nftban-panelctl nftban-queue-processor \
                  nftban-botscan-processor nftban-rollback nftban-service-alert; do
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

    # Write BUILD_TARGET from the build container's OS (distro detection at install time)
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release 2>/dev/null || true
        echo "${ID:-unknown}:${VERSION_ID:-0}" > "${deb_root}/usr/lib/nftban/BUILD_TARGET"
    else
        echo "unknown:0" > "${deb_root}/usr/lib/nftban/BUILD_TARGET"
    fi
    chmod 0644 "${deb_root}/usr/lib/nftban/BUILD_TARGET"

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
    # R26-R28: Add missing config files for DEB/RPM parity (v1.19.12)
    install -m 0640 "${PROJECT_ROOT}/install/config/conf.d/metrics.conf" "${deb_root}/etc/nftban/conf.d/metrics.conf"
    install -m 0640 "${PROJECT_ROOT}/install/config/conf.d/persistent.conf" "${deb_root}/etc/nftban/conf.d/persistent.conf"

    # Copy patterns.d directory (botscan patterns)
    mkdir -p "${deb_root}/etc/nftban/patterns.d/botscan"
    cp "${PROJECT_ROOT}/etc/nftban/patterns.d/botscan"/*.patterns "${deb_root}/etc/nftban/patterns.d/botscan/"

    # Install logrotate configuration
    mkdir -p "${deb_root}/etc/logrotate.d"
    install -m 0644 "${PROJECT_ROOT}/install/config/nftban.logrotate" "${deb_root}/etc/logrotate.d/nftban"
    mkdir -p "${deb_root}/etc/nftban/templates"
    install -m 0644 "${PROJECT_ROOT}/install/config/nftban.logrotate" "${deb_root}/etc/nftban/templates/nftban.logrotate"
    install -m 0644 "${PROJECT_ROOT}/install/config/nftban-suricata.logrotate" "${deb_root}/etc/nftban/templates/nftban-suricata.logrotate"

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
    # v1.23.0 (EVAL-3): nftban-login-monitor.service REMOVED from package
    # Deprecated since v1.21.3, replaced by Go daemon loginmon module (pkg/loginmon)
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
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-queue.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-botscan.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-botscan.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-health-fix.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-rbl-check.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-rbl-check.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-ui-auth.socket" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftband.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftband.socket" "${deb_root}/usr/lib/systemd/system/"

    # Copy PolicyKit rules (v1.0.19: Consolidated 6 files → 3 files)
    # Bug #18: Debian/Ubuntu use /usr/share/polkit-1/rules.d/ (not /etc/polkit-1/rules.d/)
    install -m 0644 "${PROJECT_ROOT}/packaging/polkit-1/rules.d/10-nftban-systemd.rules" "${deb_root}/usr/share/polkit-1/rules.d/"
    install -m 0644 "${PROJECT_ROOT}/packaging/polkit-1/rules.d/20-nftban-auditor.rules" "${deb_root}/usr/share/polkit-1/rules.d/"
    install -m 0644 "${PROJECT_ROOT}/packaging/polkit-1/rules.d/30-nftban-panel.rules" "${deb_root}/usr/share/polkit-1/rules.d/"

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
