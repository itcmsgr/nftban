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
#   - nftban-all      - Meta-package (depends on all above)
#
# v1.100.1b.A (GOTH PR-D4 stage 1): nftban-ui Web GUI no longer
# packaged. nftban-ui + nftban-ui-auth binaries + service files
# excluded from RPM and DEB outputs. Transitional handling for
# upgrade-from-prior-installs is provided via postinst/post triggers.
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
    local nftban_validate="${bin_dir}/nftban-validate"
    local nftban_installer="${bin_dir}/nftban-installer"

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
    if [[ -f "$nftban_core" ]] && [[ -f "$nftband" ]] && [[ -f "$nftban_validate" ]] && [[ -f "$nftban_installer" ]]; then
        log_info "Found pre-built binaries, validating..."

        # Ensure binaries are executable (might be lost in Docker volume mount)
        chmod +x "$nftban_core" "$nftband" "$nftban_validate" "$nftban_installer" 2>/dev/null || true

        # Validate pre-built binaries are valid ELF files
        if validate_binary "$nftban_core" && validate_binary "$nftband" && validate_binary "$nftban_validate" && validate_binary "$nftban_installer"; then
            log_success "Using pre-built binaries from bin/ - skipping rebuild"
            # Record SHA256 hashes for debugging
            log_info "nftban-core SHA256: $(sha256sum "$nftban_core" | cut -d' ' -f1)"
            log_info "nftband SHA256: $(sha256sum "$nftband" | cut -d' ' -f1)"
            log_info "nftban-validate SHA256: $(sha256sum "$nftban_validate" | cut -d' ' -f1)"
            log_info "nftban-installer SHA256: $(sha256sum "$nftban_installer" | cut -d' ' -f1)"
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
    validate_binary "$nftban_validate" || return 1
    validate_binary "$nftban_installer" || return 1

    log_success "Binaries built successfully"
    log_info "nftban-core SHA256: $(sha256sum "$nftban_core" | cut -d' ' -f1)"
    log_info "nftband SHA256: $(sha256sum "$nftband" | cut -d' ' -f1)"
    log_info "nftban-validate SHA256: $(sha256sum "$nftban_validate" | cut -d' ' -f1)"
    log_info "nftban-installer SHA256: $(sha256sum "$nftban_installer" | cut -d' ' -f1)"
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
Source1:        nftban-files.inc

BuildRequires:  systemd-rpm-macros

Requires:       nftables >= 0.9.0
Requires:       systemd
Requires:       bash >= 4.0
Requires:       bash-completion
Requires:       jq
Requires:       curl
Requires:       tar
Requires:       gzip
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
Recommends:     netmask
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
install -D -m 0755 bin/nftban-validate %{buildroot}/usr/lib/nftban/bin/nftban-validate
install -D -m 0755 bin/nftban-installer %{buildroot}/usr/lib/nftban/bin/nftban-installer
install -D -m 0755 yq_linux_amd64 %{buildroot}/usr/lib/nftban/bin/yq
# NB-5: privileged binaries ship 0750 (root:nftban), not 0755 (root:root).
# Canonical ownership set declaratively via %attr() in %files below.
install -D -m 0750 cli/sbin/nftban %{buildroot}/usr/sbin/nftban
# v1.100.1b.A: nftban-ui + nftban-ui-auth binaries no longer installed.

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

# Nftables config (pre-rendered with safe defaults, boot-safe)
install -D -m 0644 install/nftables/nftables.conf %{buildroot}/etc/nftban/nftables.conf

# v1.50.0: Template with placeholders (always overwritten on upgrade, not %config)
install -D -m 0644 install/nftables/nftables.conf.tpl %{buildroot}/usr/lib/nftban/templates/nftables.conf.tpl

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

# BotGuard v2 profiles (v1.79.0 - disabled by default)
install -D -m 0644 etc/nftban/conf.d/botguard/profiles/generic.yaml %{buildroot}/etc/nftban/conf.d/botguard/profiles/generic.yaml
install -D -m 0644 etc/nftban/conf.d/botguard/profiles/wordpress.yaml %{buildroot}/etc/nftban/conf.d/botguard/profiles/wordpress.yaml

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
# Deprecated since v1.21.3, replaced by Go daemon loginmon module (internal/loginmon)
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
# v1.100.1b.A: nftban-ui + nftban-ui-auth service/socket files no longer installed.
install -D -m 0644 install/systemd/nftban-queue.service %{buildroot}/usr/lib/systemd/system/nftban-queue.service
install -D -m 0644 install/systemd/nftban-queue.timer %{buildroot}/usr/lib/systemd/system/nftban-queue.timer
install -D -m 0644 install/systemd/nftban-botscan.service %{buildroot}/usr/lib/systemd/system/nftban-botscan.service
install -D -m 0644 install/systemd/nftban-botscan.timer %{buildroot}/usr/lib/systemd/system/nftban-botscan.timer
install -D -m 0644 install/systemd/nftban-health-fix.service %{buildroot}/usr/lib/systemd/system/nftban-health-fix.service
install -D -m 0644 install/systemd/nftban-rbl-check.service %{buildroot}/usr/lib/systemd/system/nftban-rbl-check.service
install -D -m 0644 install/systemd/nftban-rbl-check.timer %{buildroot}/usr/lib/systemd/system/nftban-rbl-check.timer
install -D -m 0644 install/systemd/nftban-tunnel.service %{buildroot}/usr/lib/systemd/system/nftban-tunnel.service
install -D -m 0644 install/systemd/nftban-tunnel.timer %{buildroot}/usr/lib/systemd/system/nftban-tunnel.timer
install -D -m 0644 install/systemd/nftband.service %{buildroot}/usr/lib/systemd/system/nftband.service
install -D -m 0644 install/systemd/nftband.socket %{buildroot}/usr/lib/systemd/system/nftband.socket
# v1.41.0: Report timer + community stats
install -D -m 0644 install/systemd/nftban-report-daily.service %{buildroot}/usr/lib/systemd/system/nftban-report-daily.service
install -D -m 0644 install/systemd/nftban-report-daily.timer %{buildroot}/usr/lib/systemd/system/nftban-report-daily.timer
install -D -m 0644 install/systemd/nftban-community-stats.service %{buildroot}/usr/lib/systemd/system/nftban-community-stats.service
install -D -m 0644 install/systemd/nftban-community-stats.timer %{buildroot}/usr/lib/systemd/system/nftban-community-stats.timer
# v1.71.0: Split update units (check=unprivileged, apply=gated)
install -D -m 0644 install/systemd/nftban-update-check.service %{buildroot}/usr/lib/systemd/system/nftban-update-check.service
install -D -m 0644 install/systemd/nftban-update-check.timer %{buildroot}/usr/lib/systemd/system/nftban-update-check.timer
install -D -m 0644 install/systemd/nftban-update-apply.service %{buildroot}/usr/lib/systemd/system/nftban-update-apply.service
install -D -m 0644 install/systemd/nftban-update-apply.timer %{buildroot}/usr/lib/systemd/system/nftban-update-apply.timer
# v1.98.1: Soak validation timer (opt-in, staggered off HH:00)
install -D -m 0644 install/systemd/nftban-soak.service %{buildroot}/usr/lib/systemd/system/nftban-soak.service
install -D -m 0644 install/systemd/nftban-soak.timer %{buildroot}/usr/lib/systemd/system/nftban-soak.timer

# Sysctl tuning profile (v1.38.0)
install -D -m 0644 install/sysctl/90-nftban.conf %{buildroot}/etc/sysctl.d/90-nftban.conf

# v1.47.0 DEPLOY-006: tmpfiles.d for /run/nftban ownership (prevents root revert on restart)
install -D -m 0644 install/systemd/tmpfiles.d/nftban.conf %{buildroot}/usr/lib/tmpfiles.d/nftban.conf

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
# v1.98.1: Soak validation script (invoked by nftban-soak.service)
install -m 0755 scripts/nftban-soak-check.sh %{buildroot}/usr/lib/nftban/scripts/nftban-soak-check.sh

# Documentation moved to wiki (v1.0.20+)
# See: https://github.com/itcmsgr/nftban/wiki

# Test scripts
mkdir -p %{buildroot}/usr/lib/nftban/tests
find cli/lib/nftban/tests -type f -name "*.sh" -exec install -m 0755 {} %{buildroot}/usr/lib/nftban/tests/ \;

# Config directories (must match %files section)
mkdir -p %{buildroot}/etc/nftban/{conf.d,distros,whitelist.d,blacklist.d,ports.d,rules.d,access.d}
mkdir -p %{buildroot}/etc/nftban/conf.d/botguard
mkdir -p %{buildroot}/etc/nftban/conf.d/botguard/profiles
mkdir -p %{buildroot}/var/lib/nftban/{feeds,geoip,staging,reports,botguard,community}
# v1.41.0: Community stats config default
install -m 0644 install/config/conf.d/community_stats.conf.default %{buildroot}/etc/nftban/conf.d/community_stats.conf.default
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
# v1.39.0: If this fails with dependency errors, use dnf/yum instead:
#   dnf install ./nftban-core-*.rpm    (auto-resolves dependencies)
echo ""
echo "════════════════════════════════════════════════════════════════════════════════"
echo "  NFTBan v%{version} - Installation Prerequisite Checks"
echo "════════════════════════════════════════════════════════════════════════════════"
echo "  TIP: Use 'dnf install ./nftban-core-*.rpm' for automatic dependency resolution"
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
# NFTBan v1.73.0 - Go-based installer (replaces shell %post)
# =============================================================================
# The Go binary handles: detection, rendering, switchop, services, validation.
# This thin wrapper just determines install mode and calls the binary.

NFTBAN_INSTALLER="/usr/lib/nftban/bin/nftban-installer"
NFTBAN_VERSION="${PKG_VERSION}"

# Determine install mode from RPM scriptlet argument
# \$1 == 1: fresh install, \$1 >= 2: upgrade
if [ "\$1" -ge 2 ] 2>/dev/null; then
    INSTALL_MODE="upgrade"
else
    INSTALL_MODE="install"
fi

# =============================================================================
# STEP 0: yq link (must happen before Go installer, used by CLI commands)
# =============================================================================
if command -v yq >/dev/null 2>&1; then
    YQ_VER=\$(yq --version 2>/dev/null | head -1 || true)
    if echo "\$YQ_VER" | grep -qE "mikefarah|version v4" >/dev/null 2>&1; then
        true  # yq v4 already available
    else
        if [ -x /usr/lib/nftban/bin/yq ]; then
            ln -sf /usr/lib/nftban/bin/yq /usr/bin/yq
            echo "[NFTBan]   yq v4 linked from bundled binary"
        fi
    fi
else
    if [ -x /usr/lib/nftban/bin/yq ]; then
        ln -sf /usr/lib/nftban/bin/yq /usr/bin/yq
        echo "[NFTBan]   yq v4 linked from bundled binary"
    fi
fi

# =============================================================================
# STEP 1: Run Go-based installer
# =============================================================================
if [ -x "\$NFTBAN_INSTALLER" ]; then
    echo "[NFTBan] Running nftban-installer (mode=\$INSTALL_MODE)..."

    # Run the Go installer — it handles everything:
    #   - SSH port detection (4 sources)
    #   - Panel detection (8 panels)
    #   - Conflict detection + takeover
    #   - Authority classification
    #   - FHS directory creation + permissions
    #   - nftables.conf rendering + validation
    #   - Ghost table cleanup
    #   - nftables enable + rebuild (FATAL on failure)
    #   - Daemon start (nftband socket+service)
    #   - Timer reconciliation (8 core + optional)
    #   - Stale file cleanup
    #   - Whitelist sync
    #   - Panel + login enable
    #   - Post-install assertions (8 checks)
    #   - Authority + history file writes
    #   - Full installer log at /var/log/nftban/installer.log
    "\$NFTBAN_INSTALLER" --rpm --mode="\$INSTALL_MODE"
    INSTALLER_EXIT=\$?

    if [ \$INSTALLER_EXIT -eq 0 ]; then
        echo "[NFTBan] ========================================"
        echo "[NFTBan]  NFTBan v\${NFTBAN_VERSION} — COMMITTED"
        echo "[NFTBan] ========================================"
    elif [ \$INSTALLER_EXIT -eq 1 ]; then
        echo "[NFTBan] ========================================"
        echo "[NFTBan]  NFTBan v\${NFTBAN_VERSION} — DEGRADED"
        echo "[NFTBan] ========================================"
        echo "[NFTBan] Some post-install checks failed."
        echo ""
        echo "[NFTBan] Run:"
        echo "[NFTBan]   nftban support"
        echo "[NFTBan] to generate a diagnostic bundle for review."
        echo ""
        echo "[NFTBan] To fix: nftban-installer --repair"
    elif [ \$INSTALLER_EXIT -eq 3 ]; then
        echo "[NFTBan] ========================================"
        echo "[NFTBan]  NFTBan v\${NFTBAN_VERSION} — ABORTED"
        echo "[NFTBan] ========================================"
        echo "[NFTBan] Conflicting firewalls detected, takeover not approved."
        echo "[NFTBan] To takeover: NFTBAN_TAKEOVER=1 nftban-installer --rpm --mode=\$INSTALL_MODE"
    else
        echo "[NFTBan] ========================================"
        echo "[NFTBan]  NFTBan v\${NFTBAN_VERSION} — FAILED"
        echo "[NFTBan] ========================================"
        echo "[NFTBan] See log: /var/log/nftban/installer.log"
        echo "[NFTBan] To retry: /usr/lib/nftban/bin/nftban-installer --repair"
        echo "[NFTBan] Or: nftban firewall rebuild"
    fi
else
    echo "[NFTBan ERROR] Installer binary not found: \$NFTBAN_INSTALLER"
    echo "[NFTBan ERROR] Package may be corrupt. Try reinstalling."
    echo "[NFTBan] Files have been installed but firewall is NOT active."
fi

# Final cache ownership fix (must be after installer runs)
find /var/cache/nftban -type f -exec chown nftban:nftban {} \; 2>/dev/null || true
find /var/cache/nftban -type d -exec chown nftban:nftban {} \; 2>/dev/null || true

# Send minimal anonymous install result (fire-and-forget, one-time)
# Reuses nftban_pro.sh infrastructure. Failure is silent.
# INVARIANT: this is a MINIMAL signal, NOT enrollment. See state-separation invariant.
if [ -f "/usr/lib/nftban/lib/nftban_pro.sh" ]; then
    (
        source "/usr/lib/nftban/lib/nftban_pro.sh" 2>/dev/null || true
        nftban_send_install_result 2>/dev/null || true
    ) &
fi

# Ensure %post exits 0 (RPM treats non-zero as scriptlet failure)
exit 0

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
                nftban-tunnel.service nftban-tunnel.timer \
                nftban-rollback.service nftban-rollback.timer nftban-snapshot.service nftban-snapshot.timer \
                nftban-suricata-update.service nftban-suricata-update.timer nftban-suricata.service \
                nftban-suricata-stats.service nftban-pro-inventory.service nftban-pro-inventory.timer \
                nftban-pro-license.service nftban-pro-license.timer \
                nftban-update-check.service nftban-update-check.timer \
                nftban-update-apply.service nftban-update-apply.timer \
                nftban-api.service nftban-firewall-init.service \
                nftban-ui.service nftban-ui-auth.socket nftban-ui-auth.service; do
        # v1.100.1b.A transitional: nftban-ui.* units may exist from a prior
        # install. Stop + disable + mask + remove their unit files so they
        # don't try to restart after upgrade.
        systemctl stop "\$unit" 2>/dev/null || true
        systemctl disable "\$unit" 2>/dev/null || true
        case "\$unit" in
            nftban-ui*.service|nftban-ui*.socket)
                systemctl mask "\$unit" 2>/dev/null || true
                rm -f "/usr/lib/systemd/system/\$unit" 2>/dev/null || true
                ;;
        esac
    done
    systemctl daemon-reload 2>/dev/null || true
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
# v1.38.0: Added config backup, proper nft cleanup sequence, sysctl removal
# =============================================================================
if [ \$1 -eq 0 ]; then
    echo "[NFTBan] Complete removal — cleaning up all artifacts..."

    # STEP 1: Backup user configuration before removal
    BACKUP_DIR="/var/tmp/nftban-config-backup-\$(date +%%Y%%m%%d-%%H%%M%%S)"
    if [ -d /etc/nftban ]; then
        echo "[NFTBan] Backing up user configuration to \${BACKUP_DIR} ..."
        mkdir -p "\$BACKUP_DIR" 2>/dev/null || true
        cp -a /etc/nftban "\$BACKUP_DIR/" 2>/dev/null || true
        if [ -d /var/lib/nftban/state ]; then
            cp -a /var/lib/nftban/state "\$BACKUP_DIR/" 2>/dev/null || true
        fi
        echo "[NFTBan] Config backup saved. Restore with: cp -a \${BACKUP_DIR}/nftban /etc/"
    fi

    # STEP 2: Remove runtime directories
    rm -rf /run/nftban /run/nftban-ui 2>/dev/null || true

    # STEP 3: Remove NFTBan include from nftables.conf BEFORE table deletion
    for nft_conf in /etc/sysconfig/nftables.conf /etc/nftables.conf; do
        if [ -f "\$nft_conf" ]; then
            sed -i '/nftban/d' "\$nft_conf" 2>/dev/null || true
        fi
    done

    # STEP 4: Flush and delete nftables tables (CRITICAL — rules persist otherwise)
    if command -v nft >/dev/null 2>&1; then
        nft flush table ip nftban 2>/dev/null || true
        nft flush table ip6 nftban 2>/dev/null || true
        nft delete table ip nftban 2>/dev/null || true
        nft delete table ip6 nftban 2>/dev/null || true
    fi

    # Reload nftables.service so it picks up config without our includes
    systemctl reload nftables.service 2>/dev/null || true

    # STEP 5: Remove auxiliary config files
    rm -f /etc/tmpfiles.d/nftban.conf 2>/dev/null || true
    rm -f /usr/lib/tmpfiles.d/nftban.conf 2>/dev/null || true
    rm -f /etc/sysctl.d/90-nftban.conf 2>/dev/null || true
    sysctl --system >/dev/null 2>&1 || true
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

    # STEP 6: Remove ALL configuration, data, logs, cache directories
    # (user config already backed up in STEP 1)
    rm -rf /etc/nftban 2>/dev/null || true
    rm -rf /var/lib/nftban 2>/dev/null || true
    rm -rf /var/log/nftban 2>/dev/null || true
    rm -rf /var/cache/nftban 2>/dev/null || true
    rm -rf /usr/share/nftban 2>/dev/null || true

    echo "[NFTBan] Complete removal finished."
    echo "[NFTBan] Config backup at: \${BACKUP_DIR}"
    echo "[NFTBan] User accounts/groups preserved (manual: userdel nftban; groupdel nftban)."
fi

%files
# MFST-C0a: directory ownership comes from generator (build/fhs-spec.yaml -> nftban-files.inc).
# Tmpfiles-managed runtime dirs (/var/lib, /var/log, /var/cache, /run) are created by
# /usr/lib/tmpfiles.d/nftban.conf at boot and intentionally NOT listed here (Option 4a).
%include %{_sourcedir}/nftban-files.inc
# Binary entry point (explicit attr; NOT a directory)
%attr(0750,root,nftban) /usr/sbin/nftban
# Package payload trees (bare paths -> recursive include of files within generator-owned dirs)
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
# v1.50.0: template with placeholders (always replaced on upgrade, NOT %config)
/usr/lib/nftban/templates/nftables.conf.tpl
# Main config files
%attr(640,root,nftban) %config(noreplace) /etc/nftban/nftban.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/nftables.conf
%config(noreplace) /etc/logrotate.d/nftban
%config(noreplace) /etc/sysctl.d/90-nftban.conf
/usr/lib/tmpfiles.d/nftban.conf
# Systemd unit globs (Layer 1 — MFST-C1 will replace these with nftban-systemd-install.inc)
/usr/lib/systemd/system/*.service
/usr/lib/systemd/system/*.socket
/usr/lib/systemd/system/*.timer
# Polkit rules
/etc/polkit-1/rules.d/10-nftban-systemd.rules
/etc/polkit-1/rules.d/20-nftban-auditor.rules
/etc/polkit-1/rules.d/30-nftban-panel.rules
# Shared data
/usr/share/nftban/specs/structure_default.json
/usr/share/nftban/templates
/usr/share/nftban/selinux
/usr/share/man/man8/nftban.8*
/usr/share/bash-completion/completions/nftban
%attr(644,root,nftban) %config(noreplace) /etc/nftban/commands.registry.yml
/usr/lib/nftban/scripts/generate-help.sh
/usr/lib/nftban/scripts/generate-wiki-operator.sh
/usr/lib/nftban/scripts/generate-wiki-auditor.sh
/usr/lib/nftban/scripts/nftban-soak-check.sh
# Config file payloads (%config(noreplace) for operator-edited; dirs come from %include)
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/*.conf
%attr(640,root,nftban) /etc/nftban/conf.d/*.conf.default
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/ddos/*.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/login/*.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/portscan/*.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/suricata/interfaces.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/rbl/*
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/tunnel/main.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/directadmin/*.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/cpanel/*.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/cwp/*.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/cyberpanel/*.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/interworx/*.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/vesta/*.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/generic/*.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/panels/plesk/*.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/botscan/*.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/botguard/main.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/botguard/allowed_crawlers.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/botguard/denied_crawlers.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/botguard/profiles/*.yaml
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/geoban/main.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/conf.d/geoip/main.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/patterns.d/botscan/*.patterns
%attr(644,root,nftban) /etc/nftban/distros/*.conf
%attr(640,root,nftban) %config(noreplace) /etc/nftban/suricata/profiles/*.yaml
%config(noreplace) %attr(664,root,nftban) /etc/nftban/suricata/config/profile.conf
%config(noreplace) %attr(640,root,nftban) /etc/nftban/whitelist.d/99-manual.conf
%config(noreplace) %attr(640,root,nftban) /etc/nftban/blacklist.d/99-manual.conf
/etc/nftban/templates/nftban.logrotate
/etc/nftban/templates/nftban-suricata.logrotate

%changelog
* Mon Mar 24 2026 NFTBan Team <noreply@nftban.com> - 1.39.0-1
- v1.39.0 Bug Fixes + UX Hardening + Security Quick Wins
- CIDR ban/unban routing fix, emulate blacklist_manual coverage
- Install auto-takeover on panel servers
- health --strict, --no-banner, deprecated subcommand removal
- Security: GeoIP temp dir, Grafana password, panel cleanup trap

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

    # MFST-C0a: stage Layer-0 generated %dir manifest into SOURCES/ for spec %include.
    local files_inc_src="${PROJECT_ROOT}/install/packaging/rpm/nftban-files.inc"
    if [[ ! -f "$files_inc_src" ]]; then
        log_error "nftban-files.inc not found at $files_inc_src; run 'bash build/generate-fhs-outputs.sh' first"
        return 1
    fi
    cp "$files_inc_src" "${BUILD_DIR}/SOURCES/nftban-files.inc"
    log_success "Staged nftban-files.inc ($(wc -l < "${BUILD_DIR}/SOURCES/nftban-files.inc") lines)"

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
Depends: nftables (>= 0.9.0), systemd, bash (>= 4.0), bash-completion, jq, curl, tar, gzip, bc, gawk, socat, acl, polkitd | policykit-1
Recommends: dnsutils, mailutils, netmask, whiptail
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
    cp "${PROJECT_ROOT}/packaging/deb/postinst" "${BUILD_DIR}/deb/DEBIAN/postinst"

    # Inject actual version into postinst
    sed -i "s/v1\.0\.[0-9]*/v${PKG_VERSION}/g" "${BUILD_DIR}/deb/DEBIAN/postinst"
    chmod 0755 "${BUILD_DIR}/deb/DEBIAN/postinst"

    # v1.38.0: Use canonical prerm from packaging/deb/prerm (FULL unit list)
    if [[ -f "${PROJECT_ROOT}/packaging/deb/prerm" ]]; then
        cp "${PROJECT_ROOT}/packaging/deb/prerm" "${BUILD_DIR}/deb/DEBIAN/prerm"
    else
        # Fallback: generate inline prerm
        cat > "${BUILD_DIR}/deb/DEBIAN/prerm" << 'PRERM'
#!/bin/sh
set -e
for f in /etc/nftban/nftban.conf /usr/lib/nftban/lib/nft_schema.sh; do
    [ -f "$f" ] && chattr -i "$f" 2>/dev/null || true
done
case "$1" in
    remove|deconfigure)
        for unit in nftband.socket nftband.service \
            nftban-maintenance.timer nftban-maintenance.service \
            nftban-health.timer nftban-health.service nftban-health-fix.service \
            nftban-watchdog.timer nftban-watchdog.service \
            nftban-login-monitor.service \
            nftban-core-geoip.timer nftban-core-geoip.service \
            nftban-core-feeds.timer nftban-core-feeds.service \
            nftban-unified-exporter.timer nftban-unified-exporter.service \
            nftban-queue.timer nftban-queue.service \
            nftban-rbl-check.timer nftban-rbl-check.service \
            nftban-rollback.timer nftban-rollback.service \
            nftban-snapshot.timer nftban-snapshot.service \
            nftban-suricata-update.timer nftban-suricata-update.service \
            nftban-suricata.service nftban-suricata-stats.service \
            nftban-pro-inventory.timer nftban-pro-inventory.service \
            nftban-pro-license.timer nftban-pro-license.service \
            nftban-update-check.timer nftban-update-check.service \
            nftban-update-apply.timer nftban-update-apply.service \
            nftban-api.service nftban-firewall-init.service \
            nftban-ui.service nftban-ui-auth.socket nftban-ui-auth.service; do
            # v1.100.1b.A transitional: nftban-ui.* units may exist from a prior
            # install; stop + disable + mask + remove their unit files.
            deb-systemd-invoke stop "$unit" >/dev/null 2>&1 || true
            case "$unit" in
                nftban-ui*.service|nftban-ui*.socket)
                    systemctl disable "$unit" 2>/dev/null || true
                    systemctl mask "$unit" 2>/dev/null || true
                    rm -f "/lib/systemd/system/$unit" 2>/dev/null || true
                    ;;
            esac
        done
        systemctl daemon-reload 2>/dev/null || true
        ;;
esac
exit 0
PRERM
    fi
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
/etc/nftban/conf.d/botguard/profiles/generic.yaml
/etc/nftban/conf.d/botguard/profiles/wordpress.yaml
/etc/nftban/conf.d/tunnel/main.conf
/etc/nftban/conf.d/geoban/main.conf
/etc/nftban/conf.d/geoip/main.conf
/etc/nftban/conf.d/metrics.conf
/etc/nftban/conf.d/persistent.conf
/etc/nftban/conf.d/watchdog.conf
/etc/nftban/conf.d/community_stats.conf.default
CONFFILES_EOF
}

build_deb() {
    log_info "Building DEB package..."

    local deb_root="${BUILD_DIR}/deb"
    rm -rf "${deb_root}"

    # Create directory structure
    # Bug #18: Debian/Ubuntu use /usr/share/polkit-1/rules.d/ for polkit rules
    mkdir -p "${deb_root}"/{DEBIAN,usr/bin,usr/sbin,usr/libexec,usr/lib/nftban/bin,usr/lib/systemd/system,etc/{nftables,nftban/{conf.d/{botguard/profiles,tunnel},distros,whitelist.d,blacklist.d,ports.d,rules.d,access.d}},usr/share/polkit-1/rules.d,var/{lib/nftban/{feeds,geoip,staging,reports,botguard,tunnel,community},log/nftban/botguard,cache/nftban},run/nftban}

    # Copy binaries
    install -m 0755 "${PROJECT_ROOT}/bin/nftban-core" "${deb_root}/usr/lib/nftban/bin/"
    install -m 0755 "${PROJECT_ROOT}/bin/nftband" "${deb_root}/usr/lib/nftban/bin/"
    install -m 0755 "${PROJECT_ROOT}/bin/nftban-validate" "${deb_root}/usr/lib/nftban/bin/"
    # NB-5: privileged binaries ship 0750 in .deb payload; postinst converges
    # ownership to root:nftban after the group is created.
    install -m 0750 "${PROJECT_ROOT}/cli/sbin/nftban" "${deb_root}/usr/sbin/"
    # v1.100.1b.A: nftban-ui + nftban-ui-auth binaries no longer installed
    # in DEB payload (GOTH PR-D4 stage 1).
    install -m 0755 "${PROJECT_ROOT}/bin/nftban-installer" "${deb_root}/usr/lib/nftban/bin/"

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

    # Copy VERSION file (WARN-005: ensure it's non-empty)
    if [[ -s "${PROJECT_ROOT}/VERSION" ]]; then
        install -m 0644 "${PROJECT_ROOT}/VERSION" "${deb_root}/usr/lib/nftban/VERSION"
    else
        echo "${PKG_VERSION}" > "${deb_root}/usr/lib/nftban/VERSION"
        chmod 0644 "${deb_root}/usr/lib/nftban/VERSION"
        log_warn "VERSION file was empty, wrote PKG_VERSION=${PKG_VERSION}"
    fi

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

    # Copy nftables config (pre-rendered with safe defaults, boot-safe)
    install -m 0644 "${PROJECT_ROOT}/install/nftables/nftables.conf" "${deb_root}/etc/nftban/nftables.conf"

    # v1.50.0: Template with placeholders (always overwritten on upgrade)
    mkdir -p "${deb_root}/usr/lib/nftban/templates"
    install -m 0644 "${PROJECT_ROOT}/install/nftables/nftables.conf.tpl" "${deb_root}/usr/lib/nftban/templates/nftables.conf.tpl"

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

    # BotGuard v2 profiles (v1.79.0 - disabled by default)
    install -m 0644 "${PROJECT_ROOT}/etc/nftban/conf.d/botguard/profiles/generic.yaml" "${deb_root}/etc/nftban/conf.d/botguard/profiles/"
    install -m 0644 "${PROJECT_ROOT}/etc/nftban/conf.d/botguard/profiles/wordpress.yaml" "${deb_root}/etc/nftban/conf.d/botguard/profiles/"

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
    # Deprecated since v1.21.3, replaced by Go daemon loginmon module (internal/loginmon)
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
    # v1.100.1b.A: nftban-ui.service + nftban-ui-auth.service + nftban-ui-auth.socket
    # no longer installed in DEB payload (GOTH PR-D4 stage 1). Transitional postinst
    # cleans up any prior install via deb_root postinst handlers.
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-queue.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-queue.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-botscan.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-botscan.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-health-fix.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-rbl-check.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-rbl-check.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-tunnel.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-tunnel.timer" "${deb_root}/usr/lib/systemd/system/"
    # v1.100.1b.A: nftban-ui-auth.socket no longer installed.
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftband.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftband.socket" "${deb_root}/usr/lib/systemd/system/"
    # v1.41.0: Report timer + community stats
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-report-daily.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-report-daily.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-community-stats.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-community-stats.timer" "${deb_root}/usr/lib/systemd/system/"
    # v1.71.0: Split update units (check=unprivileged, apply=gated)
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-update-check.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-update-check.timer" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-update-apply.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-update-apply.timer" "${deb_root}/usr/lib/systemd/system/"
    # v1.98.1: Soak validation timer (opt-in, staggered off HH:00)
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-soak.service" "${deb_root}/usr/lib/systemd/system/"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/nftban-soak.timer" "${deb_root}/usr/lib/systemd/system/"
    # v1.41.0: Community stats config default
    install -m 0644 "${PROJECT_ROOT}/install/config/conf.d/community_stats.conf.default" "${deb_root}/etc/nftban/conf.d/"

    # Sysctl tuning profile (v1.38.0)
    mkdir -p "${deb_root}/etc/sysctl.d"
    install -m 0644 "${PROJECT_ROOT}/install/sysctl/90-nftban.conf" "${deb_root}/etc/sysctl.d/"

    # v1.47.0 DEPLOY-006: tmpfiles.d for /run/nftban ownership
    mkdir -p "${deb_root}/usr/lib/tmpfiles.d"
    install -m 0644 "${PROJECT_ROOT}/install/systemd/tmpfiles.d/nftban.conf" "${deb_root}/usr/lib/tmpfiles.d/"

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
    # v1.98.1: Soak validation script (invoked by nftban-soak.service)
    install -m 0755 "${PROJECT_ROOT}/scripts/nftban-soak-check.sh" "${deb_root}/usr/lib/nftban/scripts/"

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
