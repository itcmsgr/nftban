#!/usr/bin/env bash
# Build NFTBan GeoIP binary
# SPDX-License-Identifier: MPL-2.0

set -Eeuo pipefail

echo "Building nftban-geoip..."
echo

cd "$(dirname "$0")"

# Check Go installation
if ! command -v go >/dev/null 2>&1; then
    echo "Error: Go not installed" >&2
    echo "Install: dnf install golang OR apt install golang" >&2
    exit 1
fi

echo "Go version: $(go version)"
echo

# Build binary
echo "Compiling..."
go build -o nftban-geoip \
    -ldflags "-s -w" \
    main.go

if [[ -f nftban-geoip ]]; then
    echo "✓ Build successful"
    echo
    echo "Binary: $(pwd)/nftban-geoip"
    echo "Size: $(du -h nftban-geoip | cut -f1)"
    echo
    echo "Test:"
    echo "  ./nftban-geoip --version"
    echo "  ./nftban-geoip --lookup 8.8.8.8"
    echo
    echo "Install:"
    echo "  sudo install -m 0755 nftban-geoip /usr/lib/nftban/bin/"
else
    echo "✗ Build failed" >&2
    exit 1
fi
