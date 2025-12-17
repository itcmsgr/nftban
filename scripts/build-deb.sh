#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Build DEB Packages
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Build DEB packages for amd64 and arm64
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

echo "=== Building DEB packages ==="

# Get version from tag or default
VERSION="${GITHUB_REF#refs/tags/v}"
VERSION="${VERSION:-1.0.0}"

# Create dist/packages if not exists
mkdir -p dist/packages

# Use packaging script if available
if [[ -x packaging/build_nftban.sh ]]; then
    cd packaging
    ./build_nftban.sh deb
    cd ..

    # Move DEBs to dist/packages
    find . -name "*.deb" -exec mv {} dist/packages/ \; 2>/dev/null || true
else
    echo "WARNING: packaging/build_nftban.sh not found, building manually"

    # Create build directory
    BUILD_DIR=$(mktemp -d)
    PKG_DIR="$BUILD_DIR/nftban_${VERSION}_amd64"

    mkdir -p "$PKG_DIR/DEBIAN"
    mkdir -p "$PKG_DIR/usr/bin"
    mkdir -p "$PKG_DIR/usr/lib/nftban"
    mkdir -p "$PKG_DIR/etc/nftban"

    # Create control file
    cat > "$PKG_DIR/DEBIAN/control" <<EOF
Package: nftban
Version: ${VERSION}
Section: admin
Priority: optional
Architecture: amd64
Depends: bash (>= 4.0), nftables
Maintainer: NFTBan Project <nftban@nftban.com>
Description: Intelligent Linux Firewall Management
 NFTBan is a comprehensive security platform that simplifies
 nftables configuration and provides intelligent protection.
EOF

    # Copy files
    cp -r cli/* "$PKG_DIR/usr/lib/nftban/"
    cp dist/x86_64/nftban-core "$PKG_DIR/usr/bin/" 2>/dev/null || true
    cp dist/x86_64/nftban-api-server "$PKG_DIR/usr/bin/" 2>/dev/null || true

    # Build package
    dpkg-deb --build "$PKG_DIR"
    mv "$BUILD_DIR"/*.deb dist/packages/

    # Cleanup
    rm -rf "$BUILD_DIR"
fi

echo "=== DEB packages built ==="
ls -lh dist/packages/*.deb 2>/dev/null || echo "No DEB packages found"
