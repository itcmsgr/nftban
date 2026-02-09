#!/bin/bash
# shellcheck disable=SC2155  # Readonly assignments are safe
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: Copyright (c) 2024-2025 NFTBan Development Team
#
# meta:name="build_packages"
# meta:type="packaging"
# meta:description="Build script for nftban-metrics DEB and RPM packages"
# meta:inventory.files=""
# meta:inventory.binaries=""
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges=""
#
# Build script for nftban-metrics DEB and RPM packages
#
# Usage:
#   ./build_packages.sh [deb|rpm|both]
#
# Examples:
#   ./build_packages.sh         # Build both DEB and RPM
#   ./build_packages.sh deb     # Build DEB only
#   ./build_packages.sh rpm     # Build RPM only

set -Eeuo pipefail

# Colors for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Package metadata
readonly PKG_NAME="nftban-metrics"
readonly PKG_VERSION="$(cat "${PROJECT_ROOT}/VERSION" 2>/dev/null | tr -d '[:space:]' || echo 'unknown')"
readonly PKG_RELEASE="1"

# Paths
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
readonly BUILD_DIR="${PROJECT_ROOT}/build"

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

check_dependencies() {
    local missing_deps=()

    if [[ "$1" == "deb" || "$1" == "both" ]]; then
        if ! command -v dpkg-deb >/dev/null 2>&1; then
            missing_deps+=("dpkg-deb")
        fi
    fi

    if [[ "$1" == "rpm" || "$1" == "both" ]]; then
        if ! command -v rpmbuild >/dev/null 2>&1; then
            missing_deps+=("rpmbuild (rpm-build package)")
        fi
    fi

    if [ ${#missing_deps[@]} -gt 0 ]; then
        log_error "Missing dependencies: ${missing_deps[*]}"
        log_info "Install dependencies:"
        log_info "  Debian/Ubuntu: sudo apt install dpkg-dev rpm"
        log_info "  RHEL/Fedora: sudo dnf install rpm-build dpkg"
        return 1
    fi

    return 0
}

build_deb() {
    log_info "Building DEB package..."

    local deb_build_dir="${BUILD_DIR}/deb/${PKG_NAME}-${PKG_VERSION}"

    # Clean and create build directory
    rm -rf "${deb_build_dir}"
    mkdir -p "${deb_build_dir}/DEBIAN"

    # Create directory structure
    mkdir -p "${deb_build_dir}/usr/lib/nftban"/{exporters,setup}
    mkdir -p "${deb_build_dir}/usr/lib/systemd/system/node_exporter.service.d"
    mkdir -p "${deb_build_dir}/usr/share/nftban/prometheus/alerts"
    mkdir -p "${deb_build_dir}/usr/share/nftban/grafana/dashboards"
    mkdir -p "${deb_build_dir}/usr/share/doc/nftban/metrics"

    # Copy DEBIAN control files
    cp "${SCRIPT_DIR}/deb/control" "${deb_build_dir}/DEBIAN/"
    cp "${SCRIPT_DIR}/deb/postinst" "${deb_build_dir}/DEBIAN/"
    cp "${SCRIPT_DIR}/deb/prerm" "${deb_build_dir}/DEBIAN/"
    cp "${SCRIPT_DIR}/deb/postrm" "${deb_build_dir}/DEBIAN/"

    chmod 0755 "${deb_build_dir}/DEBIAN"/{postinst,prerm,postrm}

    # Copy Track 1: Core Metrics Exporter
    cp "${PROJECT_ROOT}/work/track1/nftban_prometheus_exporter.sh" \
        "${deb_build_dir}/usr/lib/nftban/exporters/"
    cp "${PROJECT_ROOT}/install/systemd/nftban-unified-exporter.service" \
        "${deb_build_dir}/usr/lib/systemd/system/"
    cp "${PROJECT_ROOT}/install/systemd/nftban-unified-exporter.timer" \
        "${deb_build_dir}/usr/lib/systemd/system/"

    # Copy Track 2: Node Exporter Setup
    cp "${PROJECT_ROOT}/cli/lib/nftban/setup/install_node_exporter.sh" \
        "${deb_build_dir}/usr/lib/nftban/setup/"
    cp "${PROJECT_ROOT}/cli/lib/nftban/setup/validate_node_exporter.sh" \
        "${deb_build_dir}/usr/lib/nftban/setup/"
    cp "${PROJECT_ROOT}/install/systemd/node_exporter.service.d/textfile-collector.conf" \
        "${deb_build_dir}/usr/lib/systemd/system/node_exporter.service.d/"
    cp "${PROJECT_ROOT}/install/systemd/node_exporter.service.d/hardening.conf" \
        "${deb_build_dir}/usr/lib/systemd/system/node_exporter.service.d/"

    if [ -f "${PROJECT_ROOT}/docs/metrics/NODE_EXPORTER_SETUP.md" ]; then
        cp "${PROJECT_ROOT}/docs/metrics/NODE_EXPORTER_SETUP.md" \
            "${deb_build_dir}/usr/share/doc/nftban/metrics/"
    fi

    # Copy Track 3: Grafana Dashboards
    cp "${PROJECT_ROOT}/install/grafana/dashboards"/*.json \
        "${deb_build_dir}/usr/share/nftban/grafana/dashboards/"

    # Copy Track 4: Prometheus Configuration
    cp "${PROJECT_ROOT}/cli/lib/nftban/setup/install_prometheus.sh" \
        "${deb_build_dir}/usr/lib/nftban/setup/"
    cp "${PROJECT_ROOT}/cli/lib/nftban/setup/validate_prometheus.sh" \
        "${deb_build_dir}/usr/lib/nftban/setup/"
    cp "${PROJECT_ROOT}/install/prometheus"/*.example \
        "${deb_build_dir}/usr/share/nftban/prometheus/"
    cp "${PROJECT_ROOT}/install/prometheus/alerts/nftban-metrics.yml" \
        "${deb_build_dir}/usr/share/nftban/prometheus/alerts/"

    if [ -f "${PROJECT_ROOT}/docs/metrics/PROMETHEUS_SETUP.md" ]; then
        cp "${PROJECT_ROOT}/docs/metrics/PROMETHEUS_SETUP.md" \
            "${deb_build_dir}/usr/share/doc/nftban/metrics/"
    fi

    # Copy Track 10: Security
    cp "${PROJECT_ROOT}/install/firewall/metrics-firewall-rules.sh" \
        "${deb_build_dir}/usr/lib/nftban/setup/"

    # Note: Security documentation moved to wiki
    # See: https://github.com/itcmsgr/nftban/wiki/Security-Operations-Guide

    # Set permissions
    chmod 0755 "${deb_build_dir}/usr/lib/nftban/exporters"/*.sh
    chmod 0755 "${deb_build_dir}/usr/lib/nftban/setup"/*.sh

    # Build DEB package
    dpkg-deb --build "${deb_build_dir}"

    # Move to output directory
    mv "${deb_build_dir}.deb" "${BUILD_DIR}/${PKG_NAME}_${PKG_VERSION}_all.deb"

    log_success "DEB package built: ${BUILD_DIR}/${PKG_NAME}_${PKG_VERSION}_all.deb"
}

build_rpm() {
    log_info "Building RPM package..."

    local rpm_build_dir="${BUILD_DIR}/rpm"
    local rpmbuild_root="${rpm_build_dir}/rpmbuild"

    # Clean and create rpmbuild structure
    rm -rf "${rpmbuild_root}"
    mkdir -p "${rpmbuild_root}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

    # Create source tarball
    local tarball_name="${PKG_NAME}-${PKG_VERSION}.tar.gz"
    local temp_dir=$(mktemp -d)
    local pkg_dir="${temp_dir}/${PKG_NAME}-${PKG_VERSION}"

    mkdir -p "${pkg_dir}"

    # Copy all source files
    cp -r "${PROJECT_ROOT}/work" "${pkg_dir}/"
    cp -r "${PROJECT_ROOT}/cli" "${pkg_dir}/"
    cp -r "${PROJECT_ROOT}/install" "${pkg_dir}/"
    cp -r "${PROJECT_ROOT}/docs" "${pkg_dir}/" 2>/dev/null || true

    # Create tarball
    tar czf "${rpmbuild_root}/SOURCES/${tarball_name}" \
        -C "${temp_dir}" "${PKG_NAME}-${PKG_VERSION}"

    # Clean up temp directory
    rm -rf "${temp_dir}"

    # Copy spec file
    cp "${SCRIPT_DIR}/rpm/nftban-metrics.spec" "${rpmbuild_root}/SPECS/"

    # Build RPM
    rpmbuild --define "_topdir ${rpmbuild_root}" \
        -ba "${rpmbuild_root}/SPECS/nftban-metrics.spec"

    # Move RPMs to output directory
    find "${rpmbuild_root}/RPMS" -name "*.rpm" -exec mv {} "${BUILD_DIR}/" \;
    find "${rpmbuild_root}/SRPMS" -name "*.rpm" -exec mv {} "${BUILD_DIR}/" \;

    log_success "RPM packages built in: ${BUILD_DIR}/"
}

show_usage() {
    cat <<EOF
Usage: $(basename "$0") [deb|rpm|both]

Build NFTBan metrics packages (DEB and/or RPM).

Arguments:
  deb     Build DEB package only
  rpm     Build RPM package only
  both    Build both DEB and RPM packages (default)

Examples:
  $(basename "$0")         # Build both packages
  $(basename "$0") deb     # Build DEB only
  $(basename "$0") rpm     # Build RPM only

Output:
  Packages will be created in: ${BUILD_DIR}/

EOF
}

main() {
    local build_type="${1:-both}"

    # Validate argument
    if [[ ! "$build_type" =~ ^(deb|rpm|both)$ ]]; then
        log_error "Invalid argument: $build_type"
        show_usage
        exit 1
    fi

    # Check dependencies
    if ! check_dependencies "$build_type"; then
        exit 1
    fi

    # Create build directory
    mkdir -p "${BUILD_DIR}"

    log_info "Building NFTBan Metrics v${PKG_VERSION}"
    log_info "Build type: ${build_type}"
    echo ""

    # Build packages
    if [[ "$build_type" == "deb" || "$build_type" == "both" ]]; then
        build_deb
        echo ""
    fi

    if [[ "$build_type" == "rpm" || "$build_type" == "both" ]]; then
        build_rpm
        echo ""
    fi

    # Show results
    log_success "Build complete!"
    echo ""
    log_info "Generated packages:"
    ls -lh "${BUILD_DIR}"/*.{deb,rpm} 2>/dev/null || true
    echo ""
    log_info "To install:"
    log_info "  DEB: sudo dpkg -i ${BUILD_DIR}/${PKG_NAME}_${PKG_VERSION}_all.deb"
    log_info "  RPM: sudo rpm -ivh ${BUILD_DIR}/${PKG_NAME}-${PKG_VERSION}-${PKG_RELEASE}.*.noarch.rpm"
}

main "$@"
