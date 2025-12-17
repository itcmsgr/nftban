#!/usr/bin/env bash
# =============================================================================
# NFTBan v1.0.0 - Build Go Binaries
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Build Go binaries for multiple architectures
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_ROOT"

echo "=== Building Go binaries ==="

# Create dist directories
mkdir -p dist/x86_64 dist/aarch64

# Build for x86_64 (amd64)
echo "Building for x86_64..."
GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" \
    -o dist/x86_64/nftban-core ./cmd/nftban-core

GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" \
    -o dist/x86_64/nftban-ui ./cmd/nftban-ui

# Build for aarch64 (arm64)
echo "Building for aarch64..."
GOOS=linux GOARCH=arm64 go build -trimpath -ldflags "-s -w" \
    -o dist/aarch64/nftban-core ./cmd/nftban-core

GOOS=linux GOARCH=arm64 go build -trimpath -ldflags "-s -w" \
    -o dist/aarch64/nftban-ui ./cmd/nftban-ui

echo "=== Go binaries built ==="
ls -lh dist/x86_64/
ls -lh dist/aarch64/
