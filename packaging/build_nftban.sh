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

    # MFST-C3: load generated %preun systemd cleanup snippet for heredoc interpolation.
    local rpm_preun_body
    local rpm_preun_src="${PROJECT_ROOT}/install/packaging/rpm/nftban-preun-systemd-cleanup.inc"
    if [[ ! -f "$rpm_preun_src" ]]; then
        log_error "RPM preun cleanup snippet not found at $rpm_preun_src; run 'bash build/generate-systemd-maintainer-scripts.sh' first"
        return 1
    fi
    rpm_preun_body=$(cat "$rpm_preun_src")

    # v108-item7c: load generated %pre deprecated-unit cleanup snippet (NEW-package-side,
    # runs on install + upgrade, deprecated-only, never touches active units).
    # Closes srv1-class stale nftban-ui.service residue from pre-v1.100.1b.A hosts.
    local rpm_pre_deprecated_body
    local rpm_pre_deprecated_src="${PROJECT_ROOT}/install/packaging/rpm/nftban-pre-deprecated-cleanup.inc"
    if [[ ! -f "$rpm_pre_deprecated_src" ]]; then
        log_error "RPM %pre deprecated-cleanup snippet not found at $rpm_pre_deprecated_src; run 'bash build/generate-systemd-maintainer-scripts.sh' first"
        return 1
    fi
    rpm_pre_deprecated_body=$(cat "$rpm_pre_deprecated_src")

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
Source2:        nftban-systemd-install.list

BuildRequires:  systemd-rpm-macros
# v1.147-A: compile the SELinux policy module (.pp) at build via the refpolicy
# devel Makefile. checkmodule alone cannot resolve refpolicy interfaces
# (init_daemon_domain, logging_log_file, ...) used by nftban.te.
BuildRequires:  selinux-policy-devel
BuildRequires:  make

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
# v1.137 (log-durability): logrotate is the rotation mechanism for
# /etc/logrotate.d/nftban*. Previously undeclared, so a minimal host without it
# never rotated nftban logs → disk-fill. Make the system rotator a hard dependency.
Requires:       logrotate
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
# MFST-HOTFIX-B1: pre-create all package-owned directories declared in
# install/packaging/rpm/nftban-files.inc (staged as Source1 by build_rpm()).
# Symmetric to DEB build_deb()'s nftban.dirs while-read loop. Idempotent —
# mkdir -p on an already-existing dir is a no-op, so this does not conflict
# with subsequent install/cp -r operations. Without this, dirs declared as
# %dir in nftban-files.inc but having no source content (e.g. /usr/lib/nftban/
# modules, /etc/nftban/connectors, /usr/share/nftban/dashboards) cause
# rpmbuild to fail at "Processing files" with "Directory not found".
while IFS= read -r dir_line; do
    case "\$dir_line" in
        ''|\#*) continue ;;
        '%dir '*)
            dir_path=\$(echo "\$dir_line" | sed -E 's|^%dir[[:space:]]+%attr\([^)]+\)[[:space:]]+||')
            mkdir -p "%{buildroot}\${dir_path}"
            ;;
    esac
done < %{_sourcedir}/nftban-files.inc

# Download yq at BUILD time (supply-chain safe - not at install time)
# SHA256 verified before bundling in package.
# v1.157 PR-A: hardened fetch (retry + fail-fast + bounded timeouts + atomic
# write + checksum verify). Identical behaviour to packaging/lib/fetch_verified.sh
# but inlined here because this runs inside the rpmbuild install scriptlet where the
# helper file is not staged/sourceable. A transient blip no longer leaves a
# bad/partial body that the SHA pin then hard-fails on.
YQ_VERSION="4.44.1"
YQ_SHA256="6dc2d0cd4e0caca5aeffd0d784a48263591080e4a0895abe69f3a76eb50d1ba3"
echo "Downloading yq v\${YQ_VERSION} for bundling..."
yq_tmp=\$(mktemp ./.yq_fetch.XXXXXX)
curl --fail --location --retry 5 --retry-all-errors --retry-delay 3 \\
     --connect-timeout 10 --max-time 120 -sS \\
     -o "\${yq_tmp}" \\
     "https://github.com/mikefarah/yq/releases/download/v\${YQ_VERSION}/yq_linux_amd64" \\
     || { echo "yq download failed!"; rm -f "\${yq_tmp}"; exit 1; }
echo "\${YQ_SHA256}  \${yq_tmp}" | sha256sum -c - \\
     || { echo "yq checksum verification failed!"; rm -f "\${yq_tmp}"; exit 1; }
mv -f "\${yq_tmp}" yq_linux_amd64

# Binaries
install -D -m 0755 bin/nftban-core %{buildroot}/usr/lib/nftban/bin/nftban-core
install -D -m 0755 bin/nftband %{buildroot}/usr/lib/nftban/bin/nftband
install -D -m 0755 bin/nftban-validate %{buildroot}/usr/lib/nftban/bin/nftban-validate
install -D -m 0755 bin/nftban-detect-ssh-ports %{buildroot}/usr/lib/nftban/bin/nftban-detect-ssh-ports
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
# v1.148: never ship .conf.local (operator override surface) — parity with the
# Go installer's recursive walker, which skips them. Honors the negative rule.
find %{buildroot}/etc/nftban/conf.d -name '*.conf.local' -delete 2>/dev/null || true
install -D -m 0640 install/config/feeds.conf %{buildroot}/etc/nftban/conf.d/feeds.conf
# v1.148 (5-A): watchdog/metrics/persistent.conf moved into canonical
# etc/nftban/conf.d/ and are now staged by the cp -r above; explicit lines removed.

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

# MFST-C1: systemd units come from generator (install/systemd glob -> nftban-systemd-install.list).
# Closes D1 install-list drift. File presence does NOT auto-enable units; the Go installer
# (/usr/lib/nftban/bin/nftban-installer) owns enablement per PR-22B safety contract.
while IFS= read -r unit; do
    [ -z "\$unit" ] && continue
    case "\$unit" in '#'*) continue ;; esac
    install -D -m 0644 "install/systemd/\$unit" "%{buildroot}/usr/lib/systemd/system/\$unit"
done < %{_sourcedir}/nftban-systemd-install.list

# v1.107.1: ship boot-delay helper referenced by nftban-firewall-init.service ExecStart=
# (matches source-install staging at internal/installer/payload/payload.go install/helpers entry)
install -D -m 0755 install/helpers/firewall-init-with-delay.sh %{buildroot}/usr/lib/nftban/helpers/firewall-init-with-delay.sh

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
install -D -m 0644 packaging/polkit-1/rules.d/10-nftban-systemd.rules %{buildroot}/etc/polkit-1/rules.d/10-nftban-systemd.rules
install -D -m 0644 packaging/polkit-1/rules.d/20-nftban-auditor.rules %{buildroot}/etc/polkit-1/rules.d/20-nftban-auditor.rules

# SELinux policy files (R39 v1.19.12) - RPM only, DEB uses AppArmor
mkdir -p %{buildroot}/usr/share/nftban/selinux
install -D -m 0644 install/selinux/nftban.te %{buildroot}/usr/share/nftban/selinux/nftban.te
install -D -m 0644 install/selinux/nftban.fc %{buildroot}/usr/share/nftban/selinux/nftban.fc
install -D -m 0644 install/selinux/nftban.if %{buildroot}/usr/share/nftban/selinux/nftban.if
install -D -m 0644 install/selinux/Makefile %{buildroot}/usr/share/nftban/selinux/Makefile
# v1.147-A: compile the policy module (.pp) at build so %post can semodule -i it
# without requiring selinux-policy-devel on the target. MUST use the refpolicy
# devel Makefile — checkmodule alone errors on policy_module()/init_daemon_domain
# (refpolicy m4 interfaces). Guarded: if the devel Makefile is absent the .pp is
# simply not shipped and %post falls back to compile-on-target (or no-ops).
if [ -f /usr/share/selinux/devel/Makefile ]; then
    ( cd install/selinux && make -f /usr/share/selinux/devel/Makefile nftban.pp ) \
        && install -D -m 0644 install/selinux/nftban.pp %{buildroot}/usr/share/nftban/selinux/nftban.pp \
        || echo "[NFTBan build] SELinux .pp compile failed; %post will compile on target"
fi

# Validator spec file
install -D -m 0644 install/share/nftban/specs/structure_default.json %{buildroot}/usr/share/nftban/specs/structure_default.json

# Templates (mail, reports, email, partials)
find install/share/nftban/templates -type f -name "*.html" | while read -r tmpl; do
    rel_path="\${tmpl#install/share/nftban/templates/}"
    install -D -m 0644 "\$tmpl" "%{buildroot}/usr/share/nftban/templates/\$rel_path"
done

# Man page deliberately not shipped (registry-canonical since v1.95.0).
# PR #646 deleted the source files; V123 B-1 residual-refs PR completed
# the surrounding cleanup across DEB+RPM symmetrically — see build_deb()
# comment for the long-form rationale. CLI docs: commands.registry.yml +
# nftban help.

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
# v1.148 (5-A): community_stats.conf.default moved into canonical etc/nftban/conf.d/
# (staged by the cp -r above); explicit line removed.
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
-- v1.107.2: strip +i from /etc/nftban/nftban.conf before cpio extracts the
-- new conffile. SetImmutableFlags (internal/installer/validate/authority.go)
-- sets +i on this file post-install/repair, and %preun runs too late to help
-- because cpio extraction happens first. _remove_immutable_flags in the CLI
-- handles this for nftban update callers; this block aligns the direct
-- dnf upgrade / rpm -Uvh path with the same lifecycle invariant.
local nftban_conf = "/etc/nftban/nftban.conf"
local g = io.open(nftban_conf, "r")
if g then
    g:close()
    os.execute("/usr/bin/chattr -i " .. nftban_conf .. " 2>/dev/null")
    os.execute("/bin/chattr -i " .. nftban_conf .. " 2>/dev/null")
    os.execute("chattr -i " .. nftban_conf .. " 2>/dev/null")
end

%pre
# =============================================================================
# v108-item7c: Deprecated nftban-ui / GOTH GUI unit cleanup (NEW-package-side)
# =============================================================================
# Runs on install + upgrade. Touches ONLY deprecated units (build/deprecated-units.yaml).
# Idempotent. Silent on absence. Closes srv1-class stale residue from hosts upgrading
# from packages that pre-date v1.100.1b.A (GOTH PR-D4 stage 1).
# Generated content (DO NOT EDIT here — edit build/generate-systemd-maintainer-scripts.sh):
${rpm_pre_deprecated_body}
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
# NFTBan v1.0.19 uses 2-group model (nftban-panel group retired v1.137):
#   nftban: All operators (CLI + full service management)
#   nftban-auditor: Read-only audit access (systemd status queries)
getent group nftban >/dev/null || groupadd -r nftban
getent group nftban-auditor >/dev/null || groupadd -r nftban-auditor
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
# v1.147-A: load the nftban SELinux policy module (D-NFTBAN-EL-SELINUX-DAEMON-NETLINK)
# =============================================================================
# The .te/.fc shipped since v1.19.12 but were never compiled or loaded, so on
# SELinux Enforcing the daemon ran unlabeled (init_t) and its netlink socket was
# denied ("failed to list tables: socket: permission denied"). Load the module
# (enforcing nftband_t domain; NOT permissive) and relabel BEFORE the Go
# installer starts the daemon, so nftband transitions to nftband_t on first
# start. Prefer the build-shipped nftban.pp; fall back to compile-on-target.
# Guarded + idempotent + strict no-op on SELinux Disabled/absent.
if command -v semodule >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
    _nftban_sel=/usr/share/nftban/selinux
    if [ -f "\$_nftban_sel/nftban.pp" ]; then
        semodule -i "\$_nftban_sel/nftban.pp" 2>/dev/null || true
    elif [ -f /usr/share/selinux/devel/Makefile ]; then
        ( cd "\$_nftban_sel" && make -f /usr/share/selinux/devel/Makefile nftban.pp 2>/dev/null \
            && semodule -i nftban.pp 2>/dev/null ) || true
    fi
    restorecon -R /usr/sbin/nftban /usr/lib/nftban/bin /etc/nftban /var/lib/nftban /var/log/nftban /run/nftban /var/cache/nftban 2>/dev/null || true
    unset _nftban_sel
fi

# =============================================================================
# v1.146 Phase-D: CVE-2025-NFTBAN-001 inet-filter classify-then-act
# =============================================================================
# Drift-checked twin of packaging/deb/postinst:_nftban_classify_inet_filter
# (RPM previously had NO inet-filter guard at all). Empty/default distro
# skeleton -> auto-remove (both modes; it would shadow nftban). Populated,
# operator-owned table -> never delete: fresh install prints the runbook and
# SKIPS activation via exit 0 (rpm %post cannot cleanly abort; a non-zero exit
# leaves a confusing scriptlet-failed-but-installed state); upgrade warns and
# continues.
_nftban_classify_inet_filter() {
    command -v nft >/dev/null 2>&1 || { echo NONE; return 0; }
    nft list table inet filter >/dev/null 2>&1 || { echo NONE; return 0; }
    _rules=\$(nft list table inet filter 2>/dev/null \
        | grep -vE '^[[:space:]]*(table|chain|type |policy|[}]|#)' \
        | grep -cE '[^[:space:]]' || true)
    if [ "\${_rules:-0}" -eq 0 ]; then
        nft delete table inet filter 2>/dev/null || true
        echo REMOVED; return 0
    fi
    # Explicit opt-in NFTBAN_ALLOW_REMOVE_INET_FILTER=1 authorises a high-risk
    # removal of a populated/operator-owned table (deterministic + logged; no
    # interactive prompt — rpm installs run non-interactively).
    if [ "\${NFTBAN_ALLOW_REMOVE_INET_FILTER:-0}" = "1" ]; then
        nft delete table inet filter 2>/dev/null || true
        echo REMOVED_OVERRIDE; return 0
    fi
    echo POPULATED; return 0
}
_ifverdict=\$(_nftban_classify_inet_filter)
case "\$_ifverdict" in
    REMOVED)
        echo "[NFTBan] Removed default accept-all inet filter skeleton due to CVE-2025-NFTBAN-001 guard." ;;
    REMOVED_OVERRIDE)
        echo "[NFTBan WARN] HIGH-RISK: removed a POPULATED operator-owned 'inet filter' table because NFTBAN_ALLOW_REMOVE_INET_FILTER=1 was set (explicit opt-in). Any rules it held are gone." >&2 ;;
    POPULATED)
        if [ "\$1" -ge 2 ] 2>/dev/null; then
            echo "[NFTBan WARN] Populated 'inet filter' table present - NOT removed (operator-owned)." >&2
            echo "[NFTBan WARN] It may shadow nftban blocking (CVE-2025-NFTBAN-001)." >&2
        else
            echo "[NFTBan ERROR] nftban installed but firewall activation was skipped because an operator-owned inet filter table exists. Remove or migrate the conflicting table, then run: nftban-installer --repair" >&2
            exit 0
        fi ;;
esac

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
# STEP 0.5: Defensive systemd-tmpfiles --create (v1.114 mirror of v1.112.2 DEB)
# =============================================================================
# RPM already ships /var/cache/nftban as a package-owned directory via the
# generated spec's install-time directory creation and packaged files list, so
# the V112.2 status=226/NAMESPACE failure (Failed to set up mount namespacing)
# was reproduced 0/5 on RPM during V112.2 validation. This call is
# defense-in-depth — protects against any future regression where the package
# payload's mkdir entry is removed, and provides symmetric behavior with the
# v1.112.2 DEB-postinst fix at packaging/deb/postinst:196-203.
# systemd-tmpfiles --create is idempotent (only creates missing entries) and
# silenced with 2>/dev/null || true to never fail the scriptlet.
if [ -f /usr/lib/tmpfiles.d/nftban.conf ]; then
    systemd-tmpfiles --create /usr/lib/tmpfiles.d/nftban.conf 2>/dev/null || true
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
        echo "[NFTBan] To fix: /usr/lib/nftban/bin/nftban-installer --repair"
    elif [ \$INSTALLER_EXIT -eq 3 ]; then
        # V126.2 UX hotfix: FAILED_AUTHORITY_ABORT block is now emitted by the Go
        # installer (cmd/nftban-installer/main.go report() StateFailedAbort case)
        # as the single source of truth. Postinst MUST NOT duplicate the message.
        # Prior message advised "NFTBAN_TAKEOVER=1 nftban-installer --rpm --mode=\$INSTALL_MODE"
        # which required operator to know \$INSTALL_MODE value and the --rpm flag.
        # New canonical command is sudo-safe and unified across DEB/RPM:
        #   sudo NFTBAN_TAKEOVER=1 /usr/lib/nftban/bin/nftban-installer --repair
        # See AUDIT_190_LIFECYCLE/V126_2_INSTALL_ABORT_UX_HOTFIX_SCOPE.md (REV 4).
        :
    else
        echo "[NFTBan] ========================================"
        echo "[NFTBan]  NFTBan v\${NFTBAN_VERSION} — FAILED"
        echo "[NFTBan] ========================================"
        echo "[NFTBan] See log: /var/log/nftban/installer.log"
        echo "[NFTBan] To retry: /usr/lib/nftban/bin/nftban-installer --repair"
        echo "[NFTBan] Or: nftban firewall rebuild"
    fi

    # --- v1.145 PR-A.1: upgrade-path SSH rate-limit migration ---
    # On upgrade the installer's rebuild path (switchop.Rebuild ->
    # \`nftban firewall rebuild\`) rebuilds from the v1.145 template
    # (/usr/lib/nftban/templates/nftables.conf.tpl) and atomically applies the
    # set-driven SSH brute-force rule (tcp dport @ssh_ports ct count) via
    # nft -f. This explicit reload is a defense-in-depth guarantee that an
    # existing v1.142-1.144 install — whose LIVE kernel still carries the OLD
    # literal \`tcp dport <port> ct count\` rule — is migrated to the set-driven
    # form with NO operator action required.
    #
    # Gated: runs ONLY on upgrade (\$1 -ge 2 above sets INSTALL_MODE=upgrade),
    # and ONLY when the installer COMMITTED (0) or DEGRADED (1). Skipped on
    # authority-abort (3) and hard-fail so it never overrides a deliberate
    # safe/handoff state. \`nftban firewall reload\` is atomic (nft -f — the
    # kernel never sees an empty/partial ruleset) and this call is NON-FATAL:
    # a reload failure is warned and the package upgrade continues.
    if [ "\$INSTALL_MODE" = "upgrade" ] && [ "\${INSTALLER_EXIT:-0}" -le 1 ] && [ -x /usr/sbin/nftban ]; then
        echo "[NFTBan] v1.145: re-applying set-driven SSH rate-limit rule (atomic firewall reload)..."
        if /usr/sbin/nftban firewall reload --quiet >/dev/null 2>&1; then
            echo "[NFTBan] v1.145: SSH brute-force rule migrated to @ssh_ports (set-driven)."
        else
            echo "[NFTBan] WARN: v1.145 firewall reload did not complete; previous ruleset retained — upgrade continues."
            echo "[NFTBan] WARN: to finish the migration manually, run: nftban firewall reload"
        fi
    fi
else
    echo "[NFTBan ERROR] Installer binary not found: \$NFTBAN_INSTALLER"
    echo "[NFTBan ERROR] Package may be corrupt. Try reinstalling."
    echo "[NFTBan] Files have been installed but firewall is NOT active."
fi

# Final cache ownership fix (must be after installer runs)
find /var/cache/nftban -type f -exec chown nftban:nftban {} \; 2>/dev/null || true
find /var/cache/nftban -type d -exec chown nftban:nftban {} \; 2>/dev/null || true

# v1.122 B-10a: quarantine RPM-generated config sidecars.
# RPM writes /etc/nftban/<path>.rpmnew when an operator-edited file marked
# %config(noreplace) is shipped with a newer default in a package upgrade.
# Active operator config is never touched. This sweep moves each *.rpmnew
# under /etc/nftban/ into /var/lib/nftban/state/rpmnew-archive/<UTC-ts>/
# preserving the relative path so operators can diff at leisure. Idempotent
# (no-op when nothing matches); non-fatal (never breaks install/upgrade).
_nftban_rpmnew_quarantine() (
    ts=\$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || echo unknown)
    arch="/var/lib/nftban/state/rpmnew-archive/\${ts}"
    count=0
    # shellcheck disable=SC2044
    for sidecar in \$(find /etc/nftban -type f -name '*.rpmnew' 2>/dev/null); do
        if [ ! -f "\$sidecar" ]; then continue; fi
        rel="\${sidecar#/etc/nftban/}"
        reldir=\$(dirname -- "\$rel")
        dst="\${arch}/\${reldir}"
        if ! mkdir -p "\$dst" 2>/dev/null; then
            echo "[NFTBan] WARN: rpmnew-quarantine cannot create \$dst -- skipping \$sidecar"
            continue
        fi
        if mv -- "\$sidecar" "\${dst}/" 2>/dev/null; then
            echo "[NFTBan] Quarantined RPM config sidecar: \$sidecar -> \${dst}/"
            count=\$((count + 1))
        else
            echo "[NFTBan] WARN: rpmnew-quarantine cannot move \$sidecar"
        fi
    done
    if [ "\$count" -gt 0 ]; then
        echo "[NFTBan] B-10a: \$count RPM config sidecar(s) quarantined under \${arch}/"
        echo "[NFTBan] B-10a: review with: diff -u /etc/nftban/<path> \${arch}/<path>"
    fi
)
_nftban_rpmnew_quarantine || true

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
# MFST-C3: systemd stop/disable/mask cleanup is generated from
#   install/packaging/systemd/nftban-systemd-install.list (active units)
#   build/deprecated-units.yaml                            (deprecated units)
# via build/generate-systemd-maintainer-scripts.sh. The mask_if_exists()
# helper inside the snippet only modifies /etc/systemd/system/\$unit when its
# existing symlink targets /dev/null (operator-created custom aliases preserved).
# Cleanup runs only on complete uninstall (\$1 -eq 0), not on upgrade.
if [ \$1 -eq 0 ]; then
${rpm_preun_body}
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

    # v1.147-A: remove the nftban SELinux policy module on final erase
    # (guarded, idempotent, no-op on SELinux Disabled/absent).
    if command -v semodule >/dev/null 2>&1 && selinuxenabled 2>/dev/null; then
        semodule -r nftban 2>/dev/null || true
    fi

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
    # v1.146 Phase-D fenced remover — drift-checked twin of
    # packaging/deb/postrm:_nftban_strip_conf_include and Go
    # render.stripNftbanInclude. The marker strings below MUST match
    # render.IncludeBeginMarker/IncludeEndMarker byte-for-byte (enforced by
    # cli_nftables_include_idempotency_v146_test.sh). Replaces the pre-v1.146
    # loose, case-sensitive \`sed -i '/nftban/d'\` that orphaned the capitalised
    # legacy comment.
    _nftban_strip_conf_include() {
        _f="\$1"
        [ -f "\$_f" ] || return 0
        _tmp="\${_f}.nftban-strip.\$\$"
        awk '
            \$0 == "# >>> nftban firewall include (managed; do not edit between markers) >>>" { infence=1; next }
            \$0 == "# <<< nftban firewall include (managed) <<<" { infence=0; next }
            infence { next }
            \$0 == "# NFTBan firewall configuration" { next }
            index(\$0, "\"/etc/nftban/nftables.conf\"") > 0 { next }
            { print }
        ' "\$_f" > "\$_tmp" 2>/dev/null || { rm -f "\$_tmp" 2>/dev/null || true; return 0; }
        if [ -s "\$_tmp" ] || [ ! -s "\$_f" ]; then
            cat "\$_tmp" > "\$_f" 2>/dev/null || true
        fi
        rm -f "\$_tmp" 2>/dev/null || true
    }
    for nft_conf in /etc/sysconfig/nftables.conf /etc/nftables.conf; do
        _nftban_strip_conf_include "\$nft_conf"
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
# Shared data
/usr/share/nftban/specs/structure_default.json
/usr/share/nftban/templates
/usr/share/nftban/selinux
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
* Tue Mar 24 2026 NFTBan Team <noreply@nftban.com> - 1.39.0-1
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

    # MFST-C1: stage Layer-1 generated systemd install list into SOURCES/ for spec %install loop.
    local systemd_list_src="${PROJECT_ROOT}/install/packaging/systemd/nftban-systemd-install.list"
    if [[ ! -f "$systemd_list_src" ]]; then
        log_error "nftban-systemd-install.list not found at $systemd_list_src; run 'bash build/generate-systemd-install-list.sh' first"
        return 1
    fi
    cp "$systemd_list_src" "${BUILD_DIR}/SOURCES/nftban-systemd-install.list"
    log_success "Staged nftban-systemd-install.list ($(grep -cvE '^#|^$' "${BUILD_DIR}/SOURCES/nftban-systemd-install.list") units)"

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
Depends: nftables (>= 0.9.0), systemd, bash (>= 4.0), bash-completion, jq, curl, tar, gzip, bc, gawk, socat, acl, logrotate, polkitd | policykit-1
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

    # Create preinst script (v108-item7c: now staged from packaging/deb/preinst,
    # mirroring prerm/postinst. Includes BEGIN GENERATED deprecated-unit cleanup
    # sentinel region populated by build/generate-systemd-maintainer-scripts.sh).
    if [[ -f "${PROJECT_ROOT}/packaging/deb/preinst" ]]; then
        cp "${PROJECT_ROOT}/packaging/deb/preinst" "${BUILD_DIR}/deb/DEBIAN/preinst"
    else
        log_error "packaging/deb/preinst not found; this file ships preinst content + generator-populated deprecated-unit cleanup sentinel region"
        return 1
    fi

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

    # MFST-C0b: directory creation comes from generator (build/fhs-spec.yaml -> nftban.dirs).
    # Tmpfiles-managed runtime dirs (/var/lib/nftban, /var/log/nftban, /var/cache/nftban,
    # /run/nftban) are intentionally NOT listed in nftban.dirs and NOT created here
    # (Option 4a — owned by /usr/lib/tmpfiles.d/nftban.conf at boot).
    local nftban_dirs="${PROJECT_ROOT}/install/packaging/deb/nftban.dirs"
    if [[ ! -f "$nftban_dirs" ]]; then
        log_error "nftban.dirs not found at $nftban_dirs; run 'bash build/generate-fhs-outputs.sh' first"
        return 1
    fi

    # Bucket 2 — DEB metadata + FHS system dirs (NOT package-territory; not in generator).
    # Bug #18: Debian/Ubuntu use /usr/share/polkit-1/rules.d/ for polkit rules.
    mkdir -p "${deb_root}/DEBIAN" \
             "${deb_root}/etc/logrotate.d" \
             "${deb_root}/etc/nftables" \
             "${deb_root}/etc/sysctl.d" \
             "${deb_root}/usr/bin" \
             "${deb_root}/usr/sbin" \
             "${deb_root}/usr/libexec" \
             "${deb_root}/usr/lib/systemd/system" \
             "${deb_root}/usr/lib/tmpfiles.d" \
             "${deb_root}/usr/share/bash-completion/completions" \
             "${deb_root}/usr/share/polkit-1/rules.d"

    # Package-territory dirs — consume generator output (closes D-NEW-1 DEB-side).
    while IFS= read -r path; do
        [[ -z "$path" || "$path" =~ ^[[:space:]]*# ]] && continue
        mkdir -p "${deb_root}${path}"
    done < "$nftban_dirs"

    # Copy binaries
    install -m 0755 "${PROJECT_ROOT}/bin/nftban-core" "${deb_root}/usr/lib/nftban/bin/"
    install -m 0755 "${PROJECT_ROOT}/bin/nftband" "${deb_root}/usr/lib/nftban/bin/"
    install -m 0755 "${PROJECT_ROOT}/bin/nftban-validate" "${deb_root}/usr/lib/nftban/bin/"
    install -m 0755 "${PROJECT_ROOT}/bin/nftban-detect-ssh-ports" "${deb_root}/usr/lib/nftban/bin/"
    # NB-5: privileged binaries ship 0750 in .deb payload; postinst converges
    # ownership to root:nftban after the group is created.
    install -m 0750 "${PROJECT_ROOT}/cli/sbin/nftban" "${deb_root}/usr/sbin/"
    # v1.100.1b.A: nftban-ui + nftban-ui-auth binaries no longer installed
    # in DEB payload (GOTH PR-D4 stage 1).
    install -m 0755 "${PROJECT_ROOT}/bin/nftban-installer" "${deb_root}/usr/lib/nftban/bin/"

    # Download yq at BUILD time (supply-chain safe - not at install time)
    # SHA256 verified before bundling in package.
    # v1.157 PR-A: use the shared fetch_verified helper (retry + fail-fast +
    # atomic write + checksum verify) so a transient blip no longer leaves a
    # bad/partial body that the SHA pin then hard-fails on.
    local YQ_VERSION="4.44.1"
    local YQ_SHA256="6dc2d0cd4e0caca5aeffd0d784a48263591080e4a0895abe69f3a76eb50d1ba3"
    log_info "Downloading yq v${YQ_VERSION} for bundling..."
    # shellcheck source=packaging/lib/fetch_verified.sh
    . "${SCRIPT_DIR}/lib/fetch_verified.sh"
    fetch_verified \
        "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_amd64" \
        "${YQ_SHA256}" \
        "${BUILD_DIR}/yq_linux_amd64" \
        || { log_error "yq checksum verification failed!"; exit 1; }
    install -m 0755 "${BUILD_DIR}/yq_linux_amd64" "${deb_root}/usr/lib/nftban/bin/yq"
    log_info "yq v${YQ_VERSION} bundled (SHA256 verified)"

    # Copy helper scripts to /usr/lib/nftban/sbin/
    # CRITICAL: These scripts are executed by systemd services and MUST have 755 permissions
    # Bug fix v1.9.4: Ensure sbin scripts are always installed with correct permissions
    local sbin_count=0
    for script in nftban-apply nftban-confirm nftban-queue-processor \
                  nftban-botscan-processor nftban-rollback nftban-service-alert; do
        if [[ -f "${PROJECT_ROOT}/cli/sbin/${script}" ]]; then
            install -m 0755 "${PROJECT_ROOT}/cli/sbin/${script}" "${deb_root}/usr/lib/nftban/sbin/"
            ((sbin_count++))
        else
            log_warn "Missing sbin script: ${script}"
        fi
    done
    log_info "Installed ${sbin_count} sbin helper scripts"

    # v1.147-A: AppArmor profile for the nftband daemon (DEB only; complain mode).
    # Loaded by postinst when AppArmor is present; no-op otherwise. Shipped under
    # /etc/apparmor.d/ so dpkg treats it as a conffile (auto-removed on purge).
    install -D -m 0644 "${PROJECT_ROOT}/install/apparmor/usr.lib.nftban.bin.nftband" \
        "${deb_root}/etc/apparmor.d/usr.lib.nftban.bin.nftband"
    log_info "Installed AppArmor profile (complain mode)"

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
    install -m 0640 "${PROJECT_ROOT}/install/config/nftban.conf" "${deb_root}/etc/nftban/nftban.conf"

    # Copy nftables config (pre-rendered with safe defaults, boot-safe)
    install -m 0644 "${PROJECT_ROOT}/install/nftables/nftables.conf" "${deb_root}/etc/nftban/nftables.conf"

    # v1.50.0: Template with placeholders (always overwritten on upgrade)
    install -m 0644 "${PROJECT_ROOT}/install/nftables/nftables.conf.tpl" "${deb_root}/usr/lib/nftban/templates/nftables.conf.tpl"

    # Copy conf.d directory with subdirectories
    # NOTE: Central whitelist moved to whitelist.d/ - per-module whitelist.txt files removed
    cp -r "${PROJECT_ROOT}/etc/nftban/conf.d"/* "${deb_root}/etc/nftban/conf.d/"
    # Remove any stale whitelist.txt files (consolidated to whitelist.d/)
    find "${deb_root}/etc/nftban/conf.d" -name 'whitelist.txt' -delete 2>/dev/null || true
    # v1.148: never ship .conf.local (operator override surface) — parity with the
    # Go installer's recursive walker, which skips them. Honors the negative rule.
    find "${deb_root}/etc/nftban/conf.d" -name '*.conf.local' -delete 2>/dev/null || true
    install -m 0640 "${PROJECT_ROOT}/install/config/feeds.conf" "${deb_root}/etc/nftban/conf.d/feeds.conf"
    # v1.148 (5-A): watchdog/metrics/persistent.conf moved into canonical
    # etc/nftban/conf.d/ and staged by the cp -r above; explicit parity lines removed.

    # Copy patterns.d directory (botscan patterns)
    cp "${PROJECT_ROOT}/etc/nftban/patterns.d/botscan"/*.patterns "${deb_root}/etc/nftban/patterns.d/botscan/"

    # Install logrotate configuration
    install -m 0644 "${PROJECT_ROOT}/install/config/nftban.logrotate" "${deb_root}/etc/logrotate.d/nftban"
    install -m 0644 "${PROJECT_ROOT}/install/config/nftban.logrotate" "${deb_root}/etc/nftban/templates/nftban.logrotate"
    install -m 0644 "${PROJECT_ROOT}/install/config/nftban-suricata.logrotate" "${deb_root}/etc/nftban/templates/nftban-suricata.logrotate"

    # Copy Suricata profile templates
    install -m 0644 "${PROJECT_ROOT}/etc/nftban/suricata/profiles/minimal.yaml" "${deb_root}/etc/nftban/suricata/profiles/"
    install -m 0644 "${PROJECT_ROOT}/etc/nftban/suricata/profiles/standard.yaml" "${deb_root}/etc/nftban/suricata/profiles/"
    install -m 0644 "${PROJECT_ROOT}/etc/nftban/suricata/profiles/maximum.yaml" "${deb_root}/etc/nftban/suricata/profiles/"
    install -m 0664 "${PROJECT_ROOT}/etc/nftban/suricata/config/profile.conf" "${deb_root}/etc/nftban/suricata/config/"

    # BotGuard v2 profiles (v1.79.0 - disabled by default)
    install -m 0644 "${PROJECT_ROOT}/etc/nftban/conf.d/botguard/profiles/generic.yaml" "${deb_root}/etc/nftban/conf.d/botguard/profiles/"
    install -m 0644 "${PROJECT_ROOT}/etc/nftban/conf.d/botguard/profiles/wordpress.yaml" "${deb_root}/etc/nftban/conf.d/botguard/profiles/"

    # Copy distro configuration files (CRITICAL for distro-aware paths)
    cp "${PROJECT_ROOT}/etc/nftban/distros"/*.conf "${deb_root}/etc/nftban/distros/"

    # Manual whitelist/blacklist files (user-managed, preserved on upgrade)
    install -m 0640 "${PROJECT_ROOT}/etc/nftban/whitelist.d/99-manual.conf" "${deb_root}/etc/nftban/whitelist.d/"
    install -m 0640 "${PROJECT_ROOT}/etc/nftban/blacklist.d/99-manual.conf" "${deb_root}/etc/nftban/blacklist.d/"

    # MFST-C1: systemd units come from generator (install/systemd glob -> nftban-systemd-install.list).
    # Closes D1 install-list drift; the list is canonical and re-checked by CI --check.
    # File presence here does NOT auto-enable any unit; enablement is owned by
    # /usr/lib/nftban/bin/nftban-installer (PR-22B safety contract).
    local systemd_install_list="${PROJECT_ROOT}/install/packaging/systemd/nftban-systemd-install.list"
    if [[ ! -f "$systemd_install_list" ]]; then
        log_error "nftban-systemd-install.list not found at $systemd_install_list; run 'bash build/generate-systemd-install-list.sh' first"
        return 1
    fi
    while IFS= read -r unit; do
        [[ -z "$unit" || "$unit" =~ ^[[:space:]]*# ]] && continue
        install -m 0644 "${PROJECT_ROOT}/install/systemd/${unit}" "${deb_root}/usr/lib/systemd/system/"
    done < "$systemd_install_list"

    # v1.107.1: ship boot-delay helper referenced by nftban-firewall-init.service ExecStart=
    # (matches source-install staging at internal/installer/payload/payload.go install/helpers entry)
    install -m 0755 "${PROJECT_ROOT}/install/helpers/firewall-init-with-delay.sh" "${deb_root}/usr/lib/nftban/helpers/"

    # v1.148 (5-A): community_stats.conf.default moved into canonical etc/nftban/conf.d/
    # (staged by the cp -r above); explicit line removed.

    # Sysctl tuning profile (v1.38.0)
    install -m 0644 "${PROJECT_ROOT}/install/sysctl/90-nftban.conf" "${deb_root}/etc/sysctl.d/"

    # v1.47.0 DEPLOY-006: tmpfiles.d for /run/nftban ownership
    install -m 0644 "${PROJECT_ROOT}/install/systemd/tmpfiles.d/nftban.conf" "${deb_root}/usr/lib/tmpfiles.d/"

    # Copy PolicyKit rules (v1.0.19: Consolidated 6 files → 3 files)
    # Bug #18: Debian/Ubuntu use /usr/share/polkit-1/rules.d/ (not /etc/polkit-1/rules.d/)
    install -m 0644 "${PROJECT_ROOT}/packaging/polkit-1/rules.d/10-nftban-systemd.rules" "${deb_root}/usr/share/polkit-1/rules.d/"
    install -m 0644 "${PROJECT_ROOT}/packaging/polkit-1/rules.d/20-nftban-auditor.rules" "${deb_root}/usr/share/polkit-1/rules.d/"

    # Copy validator spec
    install -m 0644 "${PROJECT_ROOT}/install/share/nftban/specs/structure_default.json" "${deb_root}/usr/share/nftban/specs/"

    # Copy templates (mail, reports, email, partials)
    find "${PROJECT_ROOT}/install/share/nftban/templates" -type f -name "*.html" | while read -r tmpl; do
        rel_path="${tmpl#${PROJECT_ROOT}/install/share/nftban/templates/}"
        install -D -m 0644 "$tmpl" "${deb_root}/usr/share/nftban/templates/$rel_path"
    done

    # Man page deliberately not shipped (registry-canonical since v1.95.0).
    # CLI documentation lives in `commands.registry.yml` + `nftban help`
    # (registry-driven, current). PR #646 deleted the source files
    # (install/man/man8/nftban.8 + nftban-suricata.8); V123 B-1 residual-refs
    # PR completed the surrounding installer/uninstall/script/CI cleanup
    # across DEB+RPM symmetrically. Historical note (preserved for context):
    # PKG-EFFECTIVE-PARITY Slot 5a Phase 6 dpkg --verify previously failed on
    # ubuntu22.04/24.04 because the shipped man page interacted unpredictably
    # with mandb post-install; not shipping it removed that failure mode
    # without weakening L6.

    # Copy bash completion
    install -m 0644 "${PROJECT_ROOT}/install/bash-completion/nftban" "${deb_root}/usr/share/bash-completion/completions/"

    # Copy commands registry (v1.0.16 - single source of truth)
    install -m 0644 "${PROJECT_ROOT}/commands.registry.yml" "${deb_root}/etc/nftban/"

    # Copy documentation generators (v1.0.16)
    install -m 0755 "${PROJECT_ROOT}/scripts/generate-help.sh" "${deb_root}/usr/lib/nftban/scripts/"
    install -m 0755 "${PROJECT_ROOT}/scripts/generate-wiki-operator.sh" "${deb_root}/usr/lib/nftban/scripts/"
    install -m 0755 "${PROJECT_ROOT}/scripts/generate-wiki-auditor.sh" "${deb_root}/usr/lib/nftban/scripts/"
    # v1.98.1: Soak validation script (invoked by nftban-soak.service)
    install -m 0755 "${PROJECT_ROOT}/scripts/nftban-soak-check.sh" "${deb_root}/usr/lib/nftban/scripts/"

    # Documentation moved to wiki (v1.0.20+)
    # See: https://github.com/itcmsgr/nftban/wiki

    # Copy test scripts
    find "${PROJECT_ROOT}/cli/lib/nftban/tests" -type f -name "*.sh" -exec install -m 0755 {} "${deb_root}/usr/lib/nftban/tests/" \;

    # Create control file
    create_deb_control

    # PKG-EFFECTIVE-PARITY Slot 5a (row 14) — DEB ownership authority moved to postinst.
    # Per V107_PKG_EFFECTIVE_PARITY_DEB_POSTINST_OWNERSHIP_SCOPE.md (Option α + Option A):
    # the .deb archive ships with root:root metadata only; postinst chown + chmod +
    # dpkg-statoverride converge ownership to root:nftban / nftban:nftban after the
    # nftban identities exist on the target host. Build-time fakeroot per-directory
    # ownership baking was structurally wrong for DEB because dpkg archives store
    # numeric UID/GID, not portable names — on a target host without matching numeric
    # IDs, /etc/nftban resolved to root:systemd-journal (or root:UNKNOWN). RPM is
    # unaffected because %attr() in nftban-files.inc is a name-based directive
    # re-applied at install time. The attrs list is shipped inside the DEB at
    # /usr/share/nftban/packaging/nftban-dir-attrs.list so postinst can consume it.
    local nftban_dir_attrs="${PROJECT_ROOT}/install/packaging/deb/nftban-dir-attrs.list"
    if [[ ! -f "$nftban_dir_attrs" ]]; then
        log_error "nftban-dir-attrs.list not found at $nftban_dir_attrs; run 'bash build/generate-fhs-outputs.sh' first"
        return 1
    fi
    install -D -m 0644 "$nftban_dir_attrs" \
        "${deb_root}/usr/share/nftban/packaging/nftban-dir-attrs.list"

    # PKG-EFFECTIVE-PARITY Slot 5a — chmod-only mode convergence at build time.
    # Numeric modes are portable across hosts (unlike numeric UID/GID which
    # broke ownership baking pre-Slot-5a), so it is safe and correct to apply
    # the per-path mode column from nftban-dir-attrs.list during the build.
    # Postinst still converges OWNERSHIP (and re-applies mode for symmetry +
    # statoverride registration), but the DEB archive layer (L3) now ships
    # the directories at their final mode (typically 0750) so L3 cross-
    # packager parity reports the documented end state. Owner/group columns
    # are intentionally NOT used here — this loop is chmod-only.
    local _chmod_count=0 _chmod_skipped=0
    while IFS='|' read -r _mc_path _mc_mode _mc_owner _mc_group; do
        [[ -z "$_mc_path" || "$_mc_path" =~ ^[[:space:]]*# ]] && continue
        local _mc_target="${deb_root}${_mc_path}"
        if [[ -d "$_mc_target" ]]; then
            chmod "$_mc_mode" "$_mc_target"
            _chmod_count=$((_chmod_count + 1))
        else
            _chmod_skipped=$((_chmod_skipped + 1))
        fi
    done < "$nftban_dir_attrs"
    log_info "DEB build-time chmod convergence: ${_chmod_count} dirs chmod'd, ${_chmod_skipped} skipped (missing in deb_root)"
    unset _chmod_count _chmod_skipped _mc_path _mc_mode _mc_owner _mc_group _mc_target

    log_info "Building DEB with root:root archive metadata (postinst converges ownership)..."
    local deb_out="${BUILD_DIR}/nftban-core_${PKG_VERSION}_amd64.deb"
    if ! fakeroot -- bash -ec '
        deb_root="$1"; deb_out="$2"

        # Baseline: own everything as root:root. Postinst applies per-path
        # ownership for the 41 paths in nftban-dir-attrs.list after target-host
        # nftban / nftban-auditor identities exist; statoverride keeps dpkg DB
        # in sync so dpkg --verify stays clean.
        find "$deb_root/usr" -type f -exec chown root:root {} +
        find "$deb_root/usr" -type d -exec chown root:root {} +
        find "$deb_root/etc" -type f -exec chown root:root {} +
        find "$deb_root/etc" -type d -exec chown root:root {} +
        find "$deb_root/var" -type d -exec chown root:root {} + 2>/dev/null || true

        dpkg-deb --build "$deb_root" "$deb_out"
    ' _ "$deb_root" "$deb_out"; then
        log_error "DEB build failed inside fakeroot session (see output above)"
        return 1
    fi

    # Verify the artifact actually exists. build_deb is invoked as
    # `build_deb || { ... }` in main(), which disables errexit inside the
    # function (Bash gotcha) — without this explicit check, a fakeroot
    # session that printed errors but exited 0 anyway would still reach
    # log_success and produce the misleading "DEB built" log line that
    # PKG-EFFECTIVE-PARITY caught in CI.
    if [[ ! -s "$deb_out" ]]; then
        log_error "DEB build did not produce ${deb_out}"
        return 1
    fi

    log_success "DEB built: ${deb_out}"
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
