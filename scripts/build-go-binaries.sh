#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - Go Binary Build Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Build static Go binaries for x86_64 and aarch64
#
# meta:name=build-go-binaries.sh
# meta:type=tool
# meta:header=Go Binary Builder
# meta:version=0.32.0
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=Builds static Go binaries (nftban-feeds, nftban-geoip) for x86_64 and aarch64
# meta:input=None (reads from go-feeds/ and go-geoip/ directories)
# meta:output=Binaries in dist/{x86_64,aarch64}/ and src/usr/lib/nftban/bin/
#
# **Inventory & Requirements**
# meta:depends=go
#
# meta:created_date=2025-10-30
# =============================================================================

set -Eeuo pipefail
IFS=$'\n\t'
umask 027

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Configuration
VERSION="${VERSION:-0.32.0}"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${PROJECT_ROOT}/dist"
SRC_DIR="${PROJECT_ROOT}/src/usr/lib/nftban/bin"

# Check Go is installed
if ! command -v go >/dev/null 2>&1; then
    echo -e "${RED}ERROR: Go is not installed${NC}"
    echo "Install Go from https://go.dev/dl/"
    exit 1
fi

GO_VERSION=$(go version | awk '{print $3}')
echo -e "${GREEN}Using Go version: ${GO_VERSION}${NC}"
echo ""

# Create output directories
mkdir -p "${DIST_DIR}"/{x86_64,aarch64}
mkdir -p "${SRC_DIR}"
mkdir -p "${SRC_DIR}/.real"

# =============================================================================
# Build nftban-feeds
# =============================================================================

echo "═══════════════════════════════════════════════════════════"
echo "Building nftban-feeds"
echo "═══════════════════════════════════════════════════════════"

cd "${PROJECT_ROOT}/go-feeds"

# Check dependencies
echo "  → Downloading dependencies..."
go mod download || {
    echo -e "${RED}ERROR: Failed to download go-feeds dependencies${NC}"
    exit 1
}

# Build x86_64
echo "  → Building x86_64 binary..."
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
    -ldflags "-s -w -X main.version=${VERSION}" \
    -o "${DIST_DIR}/x86_64/nftban-feeds" \
    ./cmd/nftban-feeds || {
    echo -e "${RED}ERROR: Failed to build nftban-feeds for x86_64${NC}"
    exit 1
}

# Build aarch64
echo "  → Building aarch64 binary..."
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build \
    -ldflags "-s -w -X main.version=${VERSION}" \
    -o "${DIST_DIR}/aarch64/nftban-feeds" \
    ./cmd/nftban-feeds || {
    echo -e "${RED}ERROR: Failed to build nftban-feeds for aarch64${NC}"
    exit 1
}

# Verify binaries
x86_size=$(stat -c%s "${DIST_DIR}/x86_64/nftban-feeds" 2>/dev/null || echo 0)
arm_size=$(stat -c%s "${DIST_DIR}/aarch64/nftban-feeds" 2>/dev/null || echo 0)

echo -e "${GREEN}  ✓ x86_64:  $(numfmt --to=iec-i --suffix=B $x86_size)${NC}"
echo -e "${GREEN}  ✓ aarch64: $(numfmt --to=iec-i --suffix=B $arm_size)${NC}"
echo ""

# =============================================================================
# Build nftban-geoip
# =============================================================================

echo "═══════════════════════════════════════════════════════════"
echo "Building nftban-geoip"
echo "═══════════════════════════════════════════════════════════"

cd "${PROJECT_ROOT}/go-geoip"

# Check dependencies
echo "  → Downloading dependencies..."
go mod download || {
    echo -e "${RED}ERROR: Failed to download go-geoip dependencies${NC}"
    exit 1
}

# Build x86_64
echo "  → Building x86_64 binary..."
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build \
    -ldflags "-s -w -X main.version=${VERSION}" \
    -o "${DIST_DIR}/x86_64/nftban-geoip" \
    ./cmd/nftban-geoip || {
    echo -e "${RED}ERROR: Failed to build nftban-geoip for x86_64${NC}"
    exit 1
}

# Build aarch64
echo "  → Building aarch64 binary..."
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build \
    -ldflags "-s -w -X main.version=${VERSION}" \
    -o "${DIST_DIR}/aarch64/nftban-geoip" \
    ./cmd/nftban-geoip || {
    echo -e "${RED}ERROR: Failed to build nftban-geoip for aarch64${NC}"
    exit 1
}

# Verify binaries
x86_size=$(stat -c%s "${DIST_DIR}/x86_64/nftban-geoip" 2>/dev/null || echo 0)
arm_size=$(stat -c%s "${DIST_DIR}/aarch64/nftban-geoip" 2>/dev/null || echo 0)

echo -e "${GREEN}  ✓ x86_64:  $(numfmt --to=iec-i --suffix=B $x86_size)${NC}"
echo -e "${GREEN}  ✓ aarch64: $(numfmt --to=iec-i --suffix=B $arm_size)${NC}"
echo ""

# =============================================================================
# Copy binaries to src/ (for packaging)
# =============================================================================

echo "═══════════════════════════════════════════════════════════"
echo "Copying binaries to src/"
echo "═══════════════════════════════════════════════════════════"

# Detect current architecture
CURRENT_ARCH=$(uname -m)
if [[ "$CURRENT_ARCH" == "x86_64" ]]; then
    ARCH_DIR="x86_64"
elif [[ "$CURRENT_ARCH" == "aarch64" || "$CURRENT_ARCH" == "arm64" ]]; then
    ARCH_DIR="aarch64"
else
    echo -e "${YELLOW}WARNING: Unknown architecture: $CURRENT_ARCH${NC}"
    echo "  Using x86_64 binaries as default"
    ARCH_DIR="x86_64"
fi

echo "  → Detected architecture: ${CURRENT_ARCH}"
echo "  → Using binaries from: dist/${ARCH_DIR}/"
echo ""

cp "${DIST_DIR}/${ARCH_DIR}/nftban-feeds" "${SRC_DIR}/.real/"
cp "${DIST_DIR}/${ARCH_DIR}/nftban-geoip" "${SRC_DIR}/.real/"

chmod +x "${SRC_DIR}/.real/nftban-feeds"
chmod +x "${SRC_DIR}/.real/nftban-geoip"

echo -e "${GREEN}  ✓ nftban-feeds → ${SRC_DIR}/.real/nftban-feeds${NC}"
echo -e "${GREEN}  ✓ nftban-geoip → ${SRC_DIR}/.real/nftban-geoip${NC}"
echo ""

# =============================================================================
# Summary
# =============================================================================

echo "═══════════════════════════════════════════════════════════"
echo "Build Complete"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Binaries built for:"
echo "  - x86_64  (${DIST_DIR}/x86_64/)"
echo "  - aarch64 (${DIST_DIR}/aarch64/)"
echo ""
echo "Binaries copied to:"
echo "  - ${SRC_DIR}/ (for packaging)"
echo ""
echo -e "${GREEN}✓ All binaries built successfully!${NC}"
echo ""
