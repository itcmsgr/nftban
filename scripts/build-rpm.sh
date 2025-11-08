#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - RPM Package Builder
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Build RPM packages for Red Hat-based distributions
# Usage: ./scripts/build-rpm.sh
#
# meta:name=build-rpm.sh
# meta:type=tool
# meta:header=RPM Package Builder
# meta:version=0.32.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Builds RPM packages for Rocky 9, AlmaLinux 9, Fedora
# meta:input=Source tree and packaging/rpm/nftban.spec
# meta:output=RPM packages in dist/packages/
#
# **Inventory & Requirements**
# meta:depends=rpmbuild,rpmdevtools
#
# meta:created_date=2025-10-30
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

# Configuration
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Read version from VERSION file (single source of truth)
if [[ -f "${PROJECT_ROOT}/VERSION" ]]; then
    VERSION="$(tr -d '[:space:]' < "${PROJECT_ROOT}/VERSION")"
else
    echo "ERROR: VERSION file not found"
    exit 1
fi

RELEASE="${RELEASE:-1}"
BUILD_DIR="${PROJECT_ROOT}/dist/rpm-build"
OUTPUT_DIR="${PROJECT_ROOT}/dist/packages"

echo "═══════════════════════════════════════════════════════════"
echo "NFTBan RPM Package Builder v${VERSION}"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Check for rpmbuild
if ! command -v rpmbuild >/dev/null 2>&1; then
    echo -e "${RED}ERROR: rpmbuild not found${NC}"
    echo "Install with: sudo dnf install rpm-build rpmdevtools"
    exit 1
fi

# Check for golang >= 1.21 (required for building Go components)
if ! command -v go >/dev/null 2>&1; then
    echo -e "${RED}ERROR: golang not found${NC}"
    echo ""
    echo "Build dependencies are required. Install with:"
    echo ""
    if command -v dnf >/dev/null 2>&1; then
        echo "  # Install build dependencies (matches .github/workflows/release.yml)"
        echo "  sudo dnf install -y golang systemd-rpm-macros gcc"
        echo ""
        echo "  # Or use dnf builddep to install all BuildRequires from spec:"
        echo "  sudo dnf builddep -y packaging/rpm/nftban.spec"
    elif command -v yum >/dev/null 2>&1; then
        echo "  # Install build dependencies (matches .github/workflows/release.yml)"
        echo "  sudo yum install -y golang systemd-rpm-macros gcc"
        echo ""
        echo "  # Or use yum-builddep to install all BuildRequires from spec:"
        echo "  sudo yum-builddep -y packaging/rpm/nftban.spec"
    else
        echo "  Install golang >= 1.21, systemd-rpm-macros, and gcc manually"
    fi
    echo ""
    echo "See: .github/workflows/release.yml for complete build workflow"
    echo ""
    exit 1
fi

# Verify golang version
GO_VERSION=$(go version | grep -oP 'go\K[0-9.]+' || echo "0.0")
GO_MAJOR=$(echo "$GO_VERSION" | cut -d. -f1)
GO_MINOR=$(echo "$GO_VERSION" | cut -d. -f2)
if [[ "$GO_MAJOR" -lt 1 ]] || [[ "$GO_MAJOR" -eq 1 && "$GO_MINOR" -lt 21 ]]; then
    echo -e "${RED}ERROR: golang version $GO_VERSION is too old (need >= 1.21)${NC}"
    echo ""
    echo "Please upgrade golang:"
    if command -v dnf >/dev/null 2>&1; then
        echo "  sudo dnf upgrade golang"
    elif command -v yum >/dev/null 2>&1; then
        echo "  sudo yum upgrade golang"
    fi
    echo ""
    exit 1
fi
echo "✓ golang $GO_VERSION found"

# Create build directories
echo "Creating build directories..."
mkdir -p "${BUILD_DIR}"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}
mkdir -p "${OUTPUT_DIR}"

# Copy spec file
echo "Copying RPM spec file..."
cp "${PROJECT_ROOT}/packaging/rpm/nftban.spec" "${BUILD_DIR}/SPECS/"

# Create source tarball
echo "Creating source tarball..."
TARBALL="nftban-${VERSION}.tar.gz"

cd "${PROJECT_ROOT}"
tar czf "${BUILD_DIR}/SOURCES/${TARBALL}" \
    --transform "s|^|nftban-${VERSION}/|" \
    --exclude='.git' \
    --exclude='dist' \
    --exclude='.archive' \
    --exclude='*.swp' \
    --exclude='*.tmp' \
    src/ \
    go-geoip/ \
    go-feeds/ \
    packaging/ \
    licenses/ \
    docs/ \
    scripts/ \
    README.md \
    CHANGELOG.md \
    TRADEMARK.md \
    NOTICE.md \
    CONTRIBUTING.md

echo "  ✓ Created ${TARBALL}"

# Build RPM
echo ""
echo "Building RPM package..."
rpmbuild \
    --define "_topdir ${BUILD_DIR}" \
    --define "version ${VERSION}" \
    --define "release ${RELEASE}" \
    -ba "${BUILD_DIR}/SPECS/nftban.spec"

# Copy built packages to output directory
echo ""
echo "Copying packages to ${OUTPUT_DIR}..."

# Find and copy x86_64 RPMs
if [ -d "${BUILD_DIR}/RPMS/x86_64" ]; then
    cp "${BUILD_DIR}/RPMS/x86_64"/*.rpm "${OUTPUT_DIR}/" 2>/dev/null || true
fi

# Find and copy aarch64 RPMs
if [ -d "${BUILD_DIR}/RPMS/aarch64" ]; then
    cp "${BUILD_DIR}/RPMS/aarch64"/*.rpm "${OUTPUT_DIR}/" 2>/dev/null || true
fi

# Find and copy noarch RPMs
if [ -d "${BUILD_DIR}/RPMS/noarch" ]; then
    cp "${BUILD_DIR}/RPMS/noarch"/*.rpm "${OUTPUT_DIR}/" 2>/dev/null || true
fi

# Copy SRPM
if [ -d "${BUILD_DIR}/SRPMS" ]; then
    cp "${BUILD_DIR}/SRPMS"/*.src.rpm "${OUTPUT_DIR}/" 2>/dev/null || true
fi

# List built packages
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "Built RPM Packages"
echo "═══════════════════════════════════════════════════════════"
ls -lh "${OUTPUT_DIR}"/*.rpm 2>/dev/null || echo "No RPM packages found"

echo ""
echo -e "${GREEN}✓ RPM build complete!${NC}"
echo ""
echo "Packages available in: ${OUTPUT_DIR}"
echo ""
