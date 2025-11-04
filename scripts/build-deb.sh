#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - DEB Package Builder
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# meta:name=build-deb.sh
# meta:type=tool
# meta:header=DEB Package Builder
# meta:version=0.10.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
# meta:description=Builds DEB packages for Ubuntu 22.04+, Debian 12+
# meta:depends=dpkg-deb,debhelper,fakeroot
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# =============================================================================
# CONSTANTS
# =============================================================================
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
readonly BUILD_DIR="$PROJECT_ROOT/dist/build/deb"
readonly PACKAGE_DIR="$PROJECT_ROOT/dist/packages"
readonly VERSION="0.10.0"
readonly RELEASE="1"

# =============================================================================
# FUNCTIONS
# =============================================================================

log_info() {
    echo "[INFO] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_success() {
    echo "[SUCCESS] $*" >&2
}

die() {
    log_error "$*"
    exit 1
}

check_dependencies() {
    local deps=(dpkg-deb debhelper fakeroot)
    local missing=()

    for dep in "${deps[@]}"; do
        # Check if command exists OR package is installed
        local found=false
        if command -v "$dep" >/dev/null 2>&1; then
            found=true
        elif dpkg -l "$dep" 2>/dev/null | grep -q "^ii"; then
            found=true
        fi

        if [ "$found" = false ]; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        die "Missing dependencies: ${missing[*]}\nInstall with: sudo apt-get install dpkg-dev debhelper fakeroot"
    fi
}

clean_build_dir() {
    log_info "Cleaning build directory..."
    rm -rf "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
    mkdir -p "$PACKAGE_DIR"
}

prepare_source() {
    log_info "Preparing source tree..."

    # Copy source files
    cp -a "$PROJECT_ROOT/src" "$BUILD_DIR/"
    cp -a "$PROJECT_ROOT/packaging" "$BUILD_DIR/"
    cp -a "$PROJECT_ROOT/README.md" "$BUILD_DIR/"
    cp -a "$PROJECT_ROOT/CHANGELOG.md" "$BUILD_DIR/"

    # Copy licenses directory (FHS-compliant)
    mkdir -p "$BUILD_DIR/licenses"
    cp -a "$PROJECT_ROOT/licenses/"* "$BUILD_DIR/licenses/"

    # Copy debian packaging directory
    mkdir -p "$BUILD_DIR/debian"
    cp "$PROJECT_ROOT/packaging/deb/control" "$BUILD_DIR/debian/"
    cp "$PROJECT_ROOT/packaging/deb/changelog" "$BUILD_DIR/debian/"
    cp "$PROJECT_ROOT/packaging/deb/rules" "$BUILD_DIR/debian/"
    cp "$PROJECT_ROOT/packaging/deb/postinst" "$BUILD_DIR/debian/"
    cp "$PROJECT_ROOT/packaging/deb/prerm" "$BUILD_DIR/debian/"
    cp "$PROJECT_ROOT/packaging/deb/postrm" "$BUILD_DIR/debian/"

    # Create compat file
    echo "13" > "$BUILD_DIR/debian/compat"

    # Make rules executable
    chmod +x "$BUILD_DIR/debian/rules"
}

build_package() {
    log_info "Building DEB package..."

    cd "$BUILD_DIR"

    # Build using debhelper
    if ! dpkg-buildpackage -us -uc -b; then
        die "DEB package build failed"
    fi

    # Move built packages to package directory
    log_info "Moving packages to $PACKAGE_DIR..."
    mv "$PROJECT_ROOT/dist/build"/*.deb "$PACKAGE_DIR/" 2>/dev/null || true
    mv "$PROJECT_ROOT/dist/build"/*.buildinfo "$PACKAGE_DIR/" 2>/dev/null || true
    mv "$PROJECT_ROOT/dist/build"/*.changes "$PACKAGE_DIR/" 2>/dev/null || true

    cd "$PROJECT_ROOT"
}

show_results() {
    log_success "DEB packages built successfully!"
    echo ""
    echo "Packages available in: $PACKAGE_DIR"
    echo ""
    ls -lh "$PACKAGE_DIR"/*.deb 2>/dev/null || true
    echo ""
    echo "To install:"
    echo "  sudo dpkg -i $PACKAGE_DIR/nftban_${VERSION}-${RELEASE}_*.deb"
    echo "  sudo apt-get install -f  # Install dependencies if needed"
    echo ""
    echo "To test in a clean environment:"
    echo "  docker run -it --rm -v $PACKAGE_DIR:/packages ubuntu:22.04"
    echo "  apt-get update && apt-get install -y /packages/nftban_${VERSION}-${RELEASE}_*.deb"
    echo ""
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    log_info "NFTBan DEB Package Builder v$VERSION"
    log_info "========================================="

    check_dependencies
    clean_build_dir
    prepare_source
    build_package
    show_results
}

main "$@"
