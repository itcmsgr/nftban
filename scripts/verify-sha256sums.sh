#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - SHA256SUMS Verifier
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Verify integrity of all release artifacts
#
# Usage: ./verify-sha256sums.sh [directory]
#   Default directory: dist/
#
# Example:
#   ./verify-sha256sums.sh dist/

set -Eeuo pipefail
IFS=$'\n\t'

# Change to target directory
TARGET_DIR="${1:-dist}"
cd "$TARGET_DIR"

echo "═══════════════════════════════════════════════════════════"
echo "  NFTBan - Verifying SHA256SUMS"
echo "═══════════════════════════════════════════════════════════"
echo ""

if [[ ! -f SHA256SUMS ]]; then
    echo "❌ SHA256SUMS not found in $(pwd)"
    exit 1
fi

echo "Verifying checksums..."
echo ""

# Run verification
if sha256sum -c SHA256SUMS; then
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "✅ All checksums verified successfully!"
    echo "═══════════════════════════════════════════════════════════"
    exit 0
else
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo "❌ Checksum verification FAILED"
    echo "═══════════════════════════════════════════════════════════"
    echo ""
    echo "⚠️  One or more files have been modified or corrupted"
    echo ""
    exit 1
fi
