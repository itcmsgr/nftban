#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - SHA256SUMS Generator
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Generate SHA256SUMS file for all release artifacts
#
# Usage: ./make-sha256sums.sh [directory]
#   Default directory: dist/
#
# Example:
#   ./make-sha256sums.sh dist/

set -Eeuo pipefail
IFS=$'\n\t'

# Change to target directory
TARGET_DIR="${1:-dist}"
cd "$TARGET_DIR"

echo "═══════════════════════════════════════════════════════════"
echo "  NFTBan - Generating SHA256SUMS"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Remove old SHA256SUMS if exists
rm -f SHA256SUMS

# Get list of all files except SHA256SUMS itself
tmp=$(mktemp)
ls -1 | grep -v '^SHA256SUMS$' > "$tmp" || true

if [[ ! -s "$tmp" ]]; then
    echo "❌ No files found to checksum"
    rm -f "$tmp"
    exit 1
fi

# Generate checksums
echo "Generating checksums for $(wc -l < "$tmp") files..."
sha256sum $(cat "$tmp") > SHA256SUMS
rm -f "$tmp"

# Display results
echo ""
echo "✅ Created SHA256SUMS with $(wc -l < SHA256SUMS) entries"
echo ""
echo "Contents:"
echo "───────────────────────────────────────────────────────────"
cat SHA256SUMS
echo "───────────────────────────────────────────────────────────"
echo ""
echo "✅ Done! File: $(pwd)/SHA256SUMS"
