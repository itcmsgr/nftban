#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Build RPM Packages
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Build RPM packages for x86_64 and aarch64
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

echo "=== Building RPM packages ==="

# Get version from tag or default
VERSION="${GITHUB_REF#refs/tags/v}"
VERSION="${VERSION:-1.0.0}"

# Create dist/packages if not exists
mkdir -p dist/packages

# Use packaging script if available
if [[ -x packaging/build_nftban.sh ]]; then
    cd packaging
    ./build_nftban.sh rpm
    cd ..

    # Move RPMs to dist/packages
    find . -name "*.rpm" -path "*/RPMS/*" -exec mv {} dist/packages/ \; 2>/dev/null || true
    find . -name "*.rpm" -path "*build*" -exec mv {} dist/packages/ \; 2>/dev/null || true
else
    echo "WARNING: packaging/build_nftban.sh not found, using rpmbuild directly"

    # Setup rpmbuild structure
    mkdir -p ~/rpmbuild/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

    # Copy spec file
    cp packaging/rpm/nftban.spec ~/rpmbuild/SPECS/

    # Create tarball
    tar czf ~/rpmbuild/SOURCES/nftban-${VERSION}.tar.gz \
        --transform "s,^,nftban-${VERSION}/," \
        --exclude='.git' \
        --exclude='dist' \
        .

    # Build RPM
    rpmbuild -bb ~/rpmbuild/SPECS/nftban.spec \
        --define "version ${VERSION}" \
        --define "_topdir $HOME/rpmbuild"

    # Copy to dist/packages
    find ~/rpmbuild/RPMS -name "*.rpm" -exec cp {} dist/packages/ \;
fi

echo "=== RPM packages built ==="
ls -lh dist/packages/*.rpm 2>/dev/null || echo "No RPM packages found"
