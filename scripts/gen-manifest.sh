#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - Manifest Generator
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Create human-readable artifact manifest
#
# Usage: ./gen-manifest.sh [directory]
#   Default directory: dist/
#
# Example:
#   ./gen-manifest.sh dist/

set -Eeuo pipefail
IFS=$'\n\t'

# Change to target directory
TARGET_DIR="${1:-dist}"
cd "$TARGET_DIR"

echo "═══════════════════════════════════════════════════════════"
echo "  NFTBan - Generating MANIFEST.txt"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Create manifest
: > MANIFEST.txt

# Header
cat >> MANIFEST.txt <<EOF
═══════════════════════════════════════════════════════════════
  NFTBan v0.10.0 - Release Artifact Manifest
═══════════════════════════════════════════════════════════════

Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")
Location: $(pwd)

Artifacts:
───────────────────────────────────────────────────────────────

EOF

# List all files with sizes
for f in *; do
    [[ -f "$f" ]] || continue
    # Get file size (Linux stat vs macOS stat)
    if stat -c%s "$f" &>/dev/null; then
        size=$(stat -c%s "$f")
    else
        size=$(stat -f%z "$f")
    fi

    # Format: filename (40 chars) + size (right-aligned)
    printf "%-50s %12d bytes\n" "$f" "$size" >> MANIFEST.txt
done

# Calculate total size
total_size=$(du -sb . 2>/dev/null | awk '{print $1}' || du -sk . | awk '{print $1*1024}')
total_mb=$(echo "scale=2; $total_size / 1024 / 1024" | bc)

cat >> MANIFEST.txt <<EOF

───────────────────────────────────────────────────────────────
TOTAL SIZE:                                       ${total_mb} MB

═══════════════════════════════════════════════════════════════

Verification:
  - All files include SHA256 checksums (SHA256SUMS)
  - Verify: sha256sum -c SHA256SUMS
  - GPG signatures will be added in v0.10.1+

Support:
  - Issues: https://github.com/itcmsgr/nftban/issues
  - Documentation: https://github.com/itcmsgr/nftban/tree/main/docs

═══════════════════════════════════════════════════════════════
EOF

# Display result
echo "✅ Created MANIFEST.txt"
echo ""
echo "Contents:"
echo "───────────────────────────────────────────────────────────"
cat MANIFEST.txt
echo ""
echo "✅ Done! File: $(pwd)/MANIFEST.txt"
