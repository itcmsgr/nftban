#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - Go Binaries Build Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Compile Go binaries for NFTBan (nftban-feeds, nftban-geoip)
# Usage: ./build-go-binaries.sh [--all|--feeds|--geoip]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Output directory for compiled binaries
OUTPUT_DIR="${SCRIPT_DIR}/src/usr/lib/nftban/bin"

# =============================================================================
# FUNCTIONS
# =============================================================================

print_header() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  NFTBan v0.10.0 - Go Binaries Build Script"
    echo "════════════════════════════════════════════════════════════"
    echo ""
}

check_go() {
    if ! command -v go &>/dev/null; then
        echo -e "${RED}ERROR: Go compiler not found${NC}"
        echo ""
        echo "Please install Go 1.19 or higher:"
        echo "  - Rocky/AlmaLinux/Fedora: sudo dnf install golang"
        echo "  - Ubuntu/Debian: sudo apt install golang"
        echo "  - Or download from: https://go.dev/dl/"
        echo ""
        exit 1
    fi

    local go_version=$(go version | awk '{print $3}' | sed 's/go//')
    echo "✓ Found Go: $go_version"
}

create_output_dir() {
    if [[ ! -d "$OUTPUT_DIR" ]]; then
        mkdir -p "$OUTPUT_DIR"
        echo "✓ Created output directory: $OUTPUT_DIR"
    fi
}

build_feeds() {
    echo ""
    echo "Building nftban-feeds..."
    echo "─────────────────────────────────────────────────────────────"

    local feeds_dir="${SCRIPT_DIR}/go-feeds"
    if [[ ! -d "$feeds_dir" ]]; then
        echo -e "${RED}ERROR: go-feeds directory not found: $feeds_dir${NC}"
        return 1
    fi

    cd "$feeds_dir"

    # Build for current platform
    echo "Compiling for $(uname -s)/$(uname -m)..."
    go build -o "${OUTPUT_DIR}/nftban-feeds" \
        -ldflags="-s -w" \
        ./cmd/nftban-feeds/main.go

    if [[ $? -eq 0 ]]; then
        chmod +x "${OUTPUT_DIR}/nftban-feeds"
        local size=$(du -h "${OUTPUT_DIR}/nftban-feeds" | cut -f1)
        echo -e "${GREEN}✓ Built nftban-feeds (${size})${NC}"
        echo "  Location: ${OUTPUT_DIR}/nftban-feeds"
    else
        echo -e "${RED}✗ Failed to build nftban-feeds${NC}"
        return 1
    fi

    cd "$SCRIPT_DIR"
}

build_geoip() {
    echo ""
    echo "Building nftban-geoip..."
    echo "─────────────────────────────────────────────────────────────"

    local geoip_dir="${SCRIPT_DIR}/go-geoip"
    if [[ ! -d "$geoip_dir" ]]; then
        echo -e "${RED}ERROR: go-geoip directory not found: $geoip_dir${NC}"
        return 1
    fi

    cd "$geoip_dir"

    # Build for current platform
    echo "Compiling for $(uname -s)/$(uname -m)..."
    go build -o "${OUTPUT_DIR}/nftban-geoip" \
        -ldflags="-s -w" \
        ./cmd/nftban-geoip/main.go

    if [[ $? -eq 0 ]]; then
        chmod +x "${OUTPUT_DIR}/nftban-geoip"
        local size=$(du -h "${OUTPUT_DIR}/nftban-geoip" | cut -f1)
        echo -e "${GREEN}✓ Built nftban-geoip (${size})${NC}"
        echo "  Location: ${OUTPUT_DIR}/nftban-geoip"
    else
        echo -e "${RED}✗ Failed to build nftban-geoip${NC}"
        return 1
    fi

    cd "$SCRIPT_DIR"
}

test_binaries() {
    echo ""
    echo "Testing binaries..."
    echo "─────────────────────────────────────────────────────────────"

    if [[ -x "${OUTPUT_DIR}/nftban-feeds" ]]; then
        local feeds_version=$("${OUTPUT_DIR}/nftban-feeds" --version 2>&1 || echo "unknown")
        echo "✓ nftban-feeds: $feeds_version"
    else
        echo -e "${YELLOW}⚠  nftban-feeds not found or not executable${NC}"
    fi

    if [[ -x "${OUTPUT_DIR}/nftban-geoip" ]]; then
        local geoip_version=$("${OUTPUT_DIR}/nftban-geoip" --version 2>&1 || echo "unknown")
        echo "✓ nftban-geoip: $geoip_version"
    else
        echo -e "${YELLOW}⚠  nftban-geoip not found or not executable${NC}"
    fi
}

# =============================================================================
# MAIN
# =============================================================================

print_header

# Check for Go compiler
check_go

# Create output directory
create_output_dir

# Determine what to build
BUILD_TARGET="${1:-all}"

case "$BUILD_TARGET" in
    --all|all)
        build_feeds
        build_geoip
        ;;
    --feeds|feeds)
        build_feeds
        ;;
    --geoip|geoip)
        build_geoip
        ;;
    *)
        echo -e "${RED}ERROR: Unknown build target: $BUILD_TARGET${NC}"
        echo ""
        echo "Usage: $0 [--all|--feeds|--geoip]"
        echo ""
        echo "Options:"
        echo "  --all     Build all binaries (default)"
        echo "  --feeds   Build only nftban-feeds"
        echo "  --geoip   Build only nftban-geoip"
        exit 1
        ;;
esac

# Test built binaries
test_binaries

# Summary
echo ""
echo "════════════════════════════════════════════════════════════"
echo "  Build Complete!"
echo "════════════════════════════════════════════════════════════"
echo ""
echo "Binaries installed to: $OUTPUT_DIR"
echo ""
echo "Next step:"
echo "  sudo ./install.sh"
echo ""
