#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Binary Download with SLSA Verification
# =============================================================================
# meta:name="download_binaries"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Download and verify NFTBan Go binaries from GitHub releases"
# meta:inventory.files=""
# meta:inventory.binaries="nftban-core, nftband, nftban-ui, nftban-ui-auth"
# meta:inventory.env_vars="DOWNLOAD_DIR, INSTALL_DIR, SKIP_INSTALL"
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network="GitHub API"
# meta:inventory.privileges="root"
# =============================================================================
# Usage: ./download-binaries.sh [VERSION]
#        VERSION: Tag like v1.0.0 (default: latest)
#
# Features:
#   - Downloads binaries from GitHub releases
#   - Verifies SLSA Level 3 provenance (cryptographic proof)
#   - Falls back to SHA256 if SLSA verifier not available
#   - Supports amd64 and arm64 architectures
# =============================================================================

set -Eeuo pipefail

# Configuration
GITHUB_REPO="itcmsgr/nftban"
GITHUB_API="https://api.github.com/repos/${GITHUB_REPO}"
GITHUB_RELEASES="https://github.com/${GITHUB_REPO}/releases/download"
VERSION="${1:-latest}"

# Directories
DOWNLOAD_DIR="${DOWNLOAD_DIR:-/tmp/nftban-binaries}"
INSTALL_DIR="${INSTALL_DIR:-/usr/lib/nftban/bin}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${BLUE}[DOWNLOAD]${NC} $*" >&2; }
ok()    { echo -e "${GREEN}[  OK    ]${NC} $*" >&2; }
warn()  { echo -e "${YELLOW}[ WARN   ]${NC} $*" >&2; }
error() { echo -e "${RED}[ ERROR  ]${NC} $*" >&2; exit 1; }

# =============================================================================
# FUNCTIONS
# =============================================================================

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *)       error "Unsupported architecture: $arch" ;;
    esac
}

detect_os() {
    # Returns: ubuntu22.04, ubuntu24.04, debian12, debian13, el9, el10
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "$ID" in
            ubuntu)
                echo "ubuntu${VERSION_ID}"
                ;;
            debian)
                local major="${VERSION_ID%%.*}"
                echo "debian${major}"
                ;;
            rhel|centos|rocky|almalinux|ol)
                local major="${VERSION_ID%%.*}"
                echo "el${major}"
                ;;
            fedora)
                echo "el10"  # Fedora uses el10 compatible packages
                ;;
            *)
                echo "unknown"
                ;;
        esac
    else
        echo "unknown"
    fi
}

get_package_type() {
    if command -v dpkg &>/dev/null; then
        echo "deb"
    elif command -v rpm &>/dev/null; then
        echo "rpm"
    else
        echo "none"
    fi
}

download_package() {
    local version="$1"
    local os="$2"
    local arch="$3"
    local pkg_type="$4"

    local filename=""
    local url=""

    case "$pkg_type" in
        deb)
            filename="nftban-${os}-${arch}.deb"
            ;;
        rpm)
            # RPM uses x86_64 instead of amd64
            local rpm_arch="$arch"
            [[ "$arch" == "amd64" ]] && rpm_arch="x86_64"
            filename="nftban-${os}-${rpm_arch}.rpm"
            ;;
    esac

    url="${GITHUB_RELEASES}/${version}/${filename}"

    log "Attempting to download package: $filename"

    if curl -fsSL -o "$DOWNLOAD_DIR/$filename" "$url" 2>/dev/null; then
        ok "Downloaded: $filename"
        echo "$DOWNLOAD_DIR/$filename"
        return 0
    else
        warn "Package not found: $filename"
        return 1
    fi
}

install_package() {
    local pkg_path="$1"
    local pkg_type="$2"

    log "Installing package: $(basename "$pkg_path")"

    case "$pkg_type" in
        deb)
            if dpkg -i "$pkg_path"; then
                ok "Package installed successfully"
                return 0
            else
                error "Failed to install DEB package"
                return 1
            fi
            ;;
        rpm)
            if rpm -Uvh "$pkg_path"; then
                ok "Package installed successfully"
                return 0
            else
                error "Failed to install RPM package"
                return 1
            fi
            ;;
    esac
    return 1
}

get_latest_version() {
    log "Fetching latest release version..."
    local latest
    latest=$(curl -fsSL "${GITHUB_API}/releases/latest" | jq -r '.tag_name' 2>/dev/null)
    if [[ -z "$latest" || "$latest" == "null" ]]; then
        error "Failed to get latest version from GitHub API"
    fi
    echo "$latest"
}

install_slsa_verifier() {
    log "Installing SLSA verifier..."

    # Check if Go is available
    if command -v go &>/dev/null; then
        go install github.com/slsa-framework/slsa-verifier/v2/cli/slsa-verifier@latest
        local gopath
        gopath=$(go env GOPATH)
        export PATH="$PATH:${gopath}/bin"
        return 0
    fi

    # Download pre-built binary
    local arch
    arch=$(detect_arch)
    local verifier_version="v2.6.0"
    local verifier_url="https://github.com/slsa-framework/slsa-verifier/releases/download/${verifier_version}/slsa-verifier-linux-${arch}"

    log "Downloading slsa-verifier ${verifier_version}..."
    curl -fsSL -o "$DOWNLOAD_DIR/slsa-verifier" "$verifier_url"
    chmod +x "$DOWNLOAD_DIR/slsa-verifier"
    export PATH="$PATH:$DOWNLOAD_DIR"

    return 0
}

verify_slsa() {
    local binary="$1"
    local provenance="${binary}.intoto.jsonl"
    local tag="$2"

    if [[ ! -f "$provenance" ]]; then
        warn "Provenance file not found: $provenance"
        return 1
    fi

    log "Verifying SLSA provenance for $(basename "$binary")..."

    if slsa-verifier verify-artifact "$binary" \
        --provenance-path "$provenance" \
        --source-uri "github.com/${GITHUB_REPO}" \
        --source-tag "$tag" 2>&1; then
        ok "SLSA verification PASSED: $(basename "$binary")"
        return 0
    else
        error "SLSA verification FAILED: $(basename "$binary")"
        return 1
    fi
}

verify_sha256() {
    local binary="$1"
    local sums_file="$2"

    if [[ ! -f "$sums_file" ]]; then
        warn "SHA256SUMS file not found"
        return 2  # Not found (soft failure)
    fi

    local basename
    basename=$(basename "$binary")
    local expected
    # Use || true to handle grep returning 1 when no match (pipefail would cause exit)
    expected=$(grep "$basename" "$sums_file" 2>/dev/null | awk '{print $1}' || true)

    if [[ -z "$expected" ]]; then
        warn "No SHA256 entry for $basename (skipping verification)"
        return 2  # Not found (soft failure)
    fi

    local actual
    actual=$(sha256sum "$binary" | awk '{print $1}')

    if [[ "$expected" == "$actual" ]]; then
        ok "SHA256 verification PASSED: $basename"
        return 0
    else
        # Hard failure - hash mismatch is a security issue
        echo -e "${RED}[ ERROR  ]${NC} SHA256 verification FAILED: $basename" >&2
        echo -e "${RED}[ ERROR  ]${NC} Expected: $expected" >&2
        echo -e "${RED}[ ERROR  ]${NC} Got:      $actual" >&2
        return 1  # Verification failed (hard failure)
    fi
}

download_binary() {
    local name="$1"
    local arch="$2"
    local version="$3"
    local filename="${name}-linux-${arch}"
    local url="${GITHUB_RELEASES}/${version}/${filename}"

    log "Downloading $filename..."

    # Download binary
    if ! curl -fsSL -o "$DOWNLOAD_DIR/$filename" "$url"; then
        warn "Failed to download $filename"
        return 1
    fi

    # Download provenance
    log "Downloading provenance for $filename..."
    curl -fsSL -o "$DOWNLOAD_DIR/${filename}.intoto.jsonl" "${url}.intoto.jsonl" 2>/dev/null || true

    ok "Downloaded: $filename"
    return 0
}

download_all() {
    local version="$1"
    local arch="$2"

    log "Downloading NFTBan binaries ${version} for ${arch}..."

    # Download main binaries
    download_binary "nftban-core" "$arch" "$version"
    download_binary "nftband" "$arch" "$version"
    download_binary "nftban-ui" "$arch" "$version"

    # nftban-ui-auth is amd64 only (CGO)
    if [[ "$arch" == "amd64" ]]; then
        download_binary "nftban-ui-auth" "$arch" "$version"
    else
        warn "nftban-ui-auth not available for $arch (requires CGO)"
    fi

    # Download SHA256SUMS
    log "Downloading SHA256SUMS..."
    curl -fsSL -o "$DOWNLOAD_DIR/SHA256SUMS" "${GITHUB_RELEASES}/${version}/SHA256SUMS" 2>/dev/null || true
}

verify_all() {
    local version="$1"
    local arch="$2"
    local method="$3"

    local binaries=("nftban-core-linux-${arch}" "nftband-linux-${arch}" "nftban-ui-linux-${arch}" "nftban-ui-auth-linux-${arch}")

    local verified=0
    local skipped=0
    local failed=0

    for binary in "${binaries[@]}"; do
        local path="$DOWNLOAD_DIR/$binary"
        [[ ! -f "$path" ]] && continue

        local result=0
        case "$method" in
            slsa)
                verify_slsa "$path" "$version" || result=$?
                ;;
            sha256)
                verify_sha256 "$path" "$DOWNLOAD_DIR/SHA256SUMS" || result=$?
                ;;
        esac

        case $result in
            0) verified=$((verified + 1)) ;;   # Success
            2) skipped=$((skipped + 1)) ;;     # Not found (soft failure)
            *) failed=$((failed + 1)) ;;       # Verification failed (hard failure)
        esac
    done

    # Hard failures (hash mismatch) are security issues - always fail
    if [[ $failed -gt 0 ]]; then
        error "Verification FAILED for $failed binary(ies). DO NOT USE!"
        return 1
    fi

    # Report results
    if [[ $verified -gt 0 ]]; then
        ok "Verified $verified binary(ies)"
    fi
    if [[ $skipped -gt 0 ]]; then
        warn "Skipped verification for $skipped binary(ies) (no checksums available)"
    fi

    return 0
}

install_binaries() {
    local arch="$1"

    log "Installing binaries to $INSTALL_DIR..."

    mkdir -p "$INSTALL_DIR"

    # Install nftban-core
    if [[ -f "$DOWNLOAD_DIR/nftban-core-linux-${arch}" ]]; then
        cp -f "$DOWNLOAD_DIR/nftban-core-linux-${arch}" "$INSTALL_DIR/nftban-core"
        chmod 755 "$INSTALL_DIR/nftban-core"
        ok "Installed: $INSTALL_DIR/nftban-core"
    fi

    # Install nftband (daemon)
    if [[ -f "$DOWNLOAD_DIR/nftband-linux-${arch}" ]]; then
        cp -f "$DOWNLOAD_DIR/nftband-linux-${arch}" "$INSTALL_DIR/nftband"
        chmod 755 "$INSTALL_DIR/nftband"
        ok "Installed: $INSTALL_DIR/nftband"
    fi

    # Install nftban-ui
    if [[ -f "$DOWNLOAD_DIR/nftban-ui-linux-${arch}" ]]; then
        cp -f "$DOWNLOAD_DIR/nftban-ui-linux-${arch}" /usr/sbin/nftban-ui
        chmod 755 /usr/sbin/nftban-ui
        ok "Installed: /usr/sbin/nftban-ui"
    fi

    # Install nftban-ui-auth
    if [[ -f "$DOWNLOAD_DIR/nftban-ui-auth-linux-${arch}" ]]; then
        cp -f "$DOWNLOAD_DIR/nftban-ui-auth-linux-${arch}" /usr/libexec/nftban-ui-auth
        chmod 755 /usr/libexec/nftban-ui-auth
        ok "Installed: /usr/libexec/nftban-ui-auth"
    fi

    ok "Binaries installed successfully"
}

show_usage() {
    cat << EOF
NFTBan Binary Download with SLSA Verification

Usage:
  $0 [VERSION]

Arguments:
  VERSION    Release tag (e.g., v1.0.0). Default: latest

Options:
  --help     Show this help

Environment Variables:
  DOWNLOAD_DIR   Directory for downloaded files (default: /tmp/nftban-binaries)
  INSTALL_DIR    Directory for installed binaries (default: /usr/lib/nftban/bin)
  SKIP_INSTALL   Set to 1 to download only, don't install

Examples:
  $0                    # Download and install latest version
  $0 v1.0.0            # Download specific version
  SKIP_INSTALL=1 $0    # Download only, don't install

Security:
  This script verifies binaries using SLSA Level 3 provenance.
  If verification fails, binaries will NOT be installed.

  Learn more: https://slsa.dev/

EOF
}

# =============================================================================
# MAIN
# =============================================================================

# Handle help
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    show_usage
    exit 0
fi

# Check root for installation
if [[ "${SKIP_INSTALL:-0}" != "1" && $EUID -ne 0 ]]; then
    error "Root required for installation. Use sudo or set SKIP_INSTALL=1"
fi

echo ""
echo "================================================"
echo "  NFTBan Binary Download with SLSA Verification"
echo "================================================"
echo ""

# Setup
ARCH=$(detect_arch)
OS=$(detect_os)
PKG_TYPE=$(get_package_type)
mkdir -p "$DOWNLOAD_DIR"

log "Architecture: $ARCH"
log "OS: $OS"
log "Package type: $PKG_TYPE"
log "Download dir: $DOWNLOAD_DIR"
echo ""

# Get version
if [[ "$VERSION" == "latest" ]]; then
    VERSION=$(get_latest_version)
fi
log "Version: $VERSION"
echo ""

# Try package-based installation first (preferred)
PKG_INSTALLED=0
if [[ "$PKG_TYPE" != "none" && "$OS" != "unknown" ]]; then
    log "Attempting package-based installation..."
    if pkg_path=$(download_package "$VERSION" "$OS" "$ARCH" "$PKG_TYPE"); then
        if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
            if install_package "$pkg_path" "$PKG_TYPE"; then
                PKG_INSTALLED=1
                ok "NFTBan installed via $PKG_TYPE package"
                echo ""
                echo "================================================"
                echo "  Installation Complete!"
                echo "================================================"
                echo ""
                echo "Run: nftban version"
                echo ""
                exit 0
            fi
        else
            ok "Package downloaded to: $pkg_path"
            exit 0
        fi
    fi
    echo ""
    log "Package not available, falling back to binary download..."
    echo ""
fi

# Fallback: Download raw binaries
download_all "$VERSION" "$ARCH"
echo ""

# Check for SLSA verifier
VERIFY_METHOD="sha256"
if command -v slsa-verifier &>/dev/null; then
    VERIFY_METHOD="slsa"
    log "SLSA verifier found"
else
    log "SLSA verifier not found, attempting to install..."
    if install_slsa_verifier; then
        if command -v slsa-verifier &>/dev/null; then
            VERIFY_METHOD="slsa"
            ok "SLSA verifier installed"
        fi
    fi
fi

# Check if provenance files exist (required for SLSA verification)
if [[ "$VERIFY_METHOD" == "slsa" ]]; then
    # Check if any provenance file exists
    _has_provenance=0
    for _binary in nftban-core nftband nftban-ui nftban-ui-auth; do
        if [[ -f "$DOWNLOAD_DIR/${_binary}-linux-${ARCH}.intoto.jsonl" ]]; then
            _has_provenance=1
            break
        fi
    done

    if [[ $_has_provenance -eq 0 ]]; then
        warn "No provenance files found in release, falling back to SHA256"
        VERIFY_METHOD="sha256"
    fi
fi

if [[ "$VERIFY_METHOD" == "slsa" ]]; then
    log "Using SLSA Level 3 verification (recommended)"
else
    log "Using SHA256 verification"
fi
echo ""

# Verify all binaries
verify_all "$VERSION" "$ARCH" "$VERIFY_METHOD"
echo ""

# Install binaries
if [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
    install_binaries "$ARCH"
    echo ""
fi

# Cleanup with safety guards (prevents catastrophic rm -rf accidents)
# Skip cleanup if SKIP_INSTALL is set (caller wants to keep binaries)
if [[ "${KEEP_DOWNLOADS:-0}" != "1" ]] && [[ "${SKIP_INSTALL:-0}" != "1" ]]; then
    # Safety Guard 1: Path must not be empty
    if [[ -z "$DOWNLOAD_DIR" ]]; then
        error "CRITICAL: DOWNLOAD_DIR is empty, refusing to delete"
    fi

    # Safety Guard 2: Path must not be root directory
    if [[ "$DOWNLOAD_DIR" == "/" ]]; then
        error "CRITICAL: DOWNLOAD_DIR is root (/), refusing to delete"
    fi

    # Safety Guard 3: Enforce safe prefix (must be under /tmp or /var/tmp)
    if [[ "$DOWNLOAD_DIR" != /tmp/* ]] && [[ "$DOWNLOAD_DIR" != /var/tmp/* ]]; then
        error "CRITICAL: DOWNLOAD_DIR ($DOWNLOAD_DIR) is outside safe paths (/tmp, /var/tmp)"
    fi

    # Safety Guard 4: Path must not contain directory traversal
    if [[ "$DOWNLOAD_DIR" == *..* ]]; then
        error "CRITICAL: DOWNLOAD_DIR contains directory traversal: $DOWNLOAD_DIR"
    fi

    # All guards passed - safe to delete
    rm -rf "$DOWNLOAD_DIR"
fi

echo ""
ok "Download and verification complete!"
echo ""
echo "Verification method: $VERIFY_METHOD"
echo "Version installed:   $VERSION"
echo ""
echo "Next steps:"
echo "  nftban version        # Check installation"
echo "  nftban health         # Run health check"
echo ""
