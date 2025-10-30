#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - SPDX Header Application Script
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Apply SPDX license headers to all source files
# Usage: ./apply-spdx-headers.sh [--check|--apply]

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# SPDX header template
SPDX_HEADER="# SPDX-License-Identifier: MPL-2.0"

# Count files
TOTAL=0
MISSING=0
HAS_SPDX=0

# =============================================================================
# FUNCTIONS
# =============================================================================

check_file() {
    local file="$1"
    ((TOTAL++))

    if head -n 10 "$file" | grep -q "SPDX-License-Identifier"; then
        ((HAS_SPDX++))
        return 0
    else
        ((MISSING++))
        echo "MISSING: $file"
        return 1
    fi
}

apply_header() {
    local file="$1"

    # Check if already has SPDX
    if head -n 10 "$file" | grep -q "SPDX-License-Identifier"; then
        return 0
    fi

    # Determine where to insert
    # If file starts with shebang, insert after it
    if head -n 1 "$file" | grep -q "^#!/"; then
        # Insert after shebang
        sed -i "2i\\
# =============================================================================\\
# NFTBan v0.10.0\\
# =============================================================================\\
$SPDX_HEADER" "$file"
    else
        # Insert at beginning
        sed -i "1i\\
# =============================================================================\\
# NFTBan v0.10.0\\
# =============================================================================\\
$SPDX_HEADER\\
" "$file"
    fi

    echo "APPLIED: $file"
}

# =============================================================================
# MAIN
# =============================================================================

MODE="${1:---check}"

echo "═══════════════════════════════════════════════════════════════"
echo "  NFTBan v0.10.0 - SPDX Header Application"
echo "═══════════════════════════════════════════════════════════════"
echo ""

case "$MODE" in
    --check)
        echo "MODE: Check only (no changes)"
        echo ""

        # Check all shell scripts in src/
        while IFS= read -r -d '' file; do
            check_file "$file"
        done < <(find src -type f -name "*.sh" -print0)

        # Check main CLI
        if [[ -f "src/usr/sbin/nftban" ]]; then
            check_file "src/usr/sbin/nftban"
        fi

        echo ""
        echo "───────────────────────────────────────────────────────────────"
        echo "Summary:"
        echo "  Total files: $TOTAL"
        echo "  Has SPDX: $HAS_SPDX"
        echo "  Missing: $MISSING"
        echo "───────────────────────────────────────────────────────────────"

        if [[ $MISSING -gt 0 ]]; then
            echo ""
            echo "Run with --apply to add SPDX headers to missing files"
            exit 1
        fi
        ;;

    --apply)
        echo "MODE: Apply headers (WILL MODIFY FILES)"
        echo ""
        read -p "Continue? [y/N] " confirm
        if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
            echo "Cancelled."
            exit 0
        fi

        echo ""

        # Apply to all shell scripts in src/
        while IFS= read -r -d '' file; do
            apply_header "$file"
        done < <(find src -type f -name "*.sh" -print0)

        # Apply to main CLI
        if [[ -f "src/usr/sbin/nftban" ]]; then
            apply_header "src/usr/sbin/nftban"
        fi

        echo ""
        echo "✓ SPDX headers applied"
        echo ""
        echo "Run with --check to verify"
        ;;

    *)
        echo "ERROR: Unknown mode: $MODE"
        echo ""
        echo "Usage: $0 [--check|--apply]"
        echo ""
        echo "  --check   Check which files are missing SPDX headers (default)"
        echo "  --apply   Apply SPDX headers to files missing them"
        exit 1
        ;;
esac
