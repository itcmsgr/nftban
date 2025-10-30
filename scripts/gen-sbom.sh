#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - SBOM Generator
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Generate Software Bill of Materials (SBOM) in SPDX format
#
# Usage: ./gen-sbom.sh [project-directory]
#   Default directory: current directory
#   Output: dist/SBOM.spdx.json
#
# Requirements:
#   - syft (https://github.com/anchore/syft)
#   Install: curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh
#
# Example:
#   ./gen-sbom.sh .

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="${1:-.}"

echo "═══════════════════════════════════════════════════════════"
echo "  NFTBan - Generating SBOM (Software Bill of Materials)"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Check if syft is installed
if ! command -v syft &>/dev/null; then
    echo "⚠️  syft not found - SBOM generation skipped (optional)"
    echo ""
    echo "SBOM (Software Bill of Materials) provides transparency about"
    echo "dependencies and components in NFTBan. While optional for v0.10.0,"
    echo "it's recommended for security compliance and supply chain visibility."
    echo ""
    echo "To install syft:"
    echo "  curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin"
    echo ""
    echo "Continuing without SBOM..."
    exit 0
fi

# Create dist directory if not exists
mkdir -p dist

echo "Analyzing project: $PROJECT_DIR"
echo "Generating SPDX-format SBOM..."
echo ""

# Generate SBOM
syft packages "dir:$PROJECT_DIR" -o spdx-json > dist/SBOM.spdx.json

SBOM_SIZE=$(stat -c%s dist/SBOM.spdx.json 2>/dev/null || stat -f%z dist/SBOM.spdx.json)

echo ""
echo "✅ Created SBOM.spdx.json ($SBOM_SIZE bytes)"
echo ""
echo "SBOM includes:"
echo "  - All dependencies and their versions"
echo "  - License information"
echo "  - Package sources"
echo "  - SPDX-compliant format"
echo ""
echo "File: $(pwd)/dist/SBOM.spdx.json"
