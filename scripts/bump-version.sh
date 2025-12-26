#!/usr/bin/env bash
# =============================================================================
# NFTBan Version Bumper
# =============================================================================
# Automatically bumps version number in the VERSION file
#
# Usage:
#   ./scripts/bump-version.sh major    # 1.0.5 -> 2.0.0
#   ./scripts/bump-version.sh minor    # 1.0.5 -> 1.1.0
#   ./scripts/bump-version.sh patch    # 1.0.5 -> 1.0.6
#   ./scripts/bump-version.sh 1.2.3    # Set to specific version
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/../VERSION"

# Read current version
CURRENT=$(cat "$VERSION_FILE" | tr -d '[:space:]')

# Parse version
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"

# Determine new version
case "${1:-patch}" in
    major)
        NEW_VERSION="$((MAJOR + 1)).0.0"
        ;;
    minor)
        NEW_VERSION="$MAJOR.$((MINOR + 1)).0"
        ;;
    patch)
        NEW_VERSION="$MAJOR.$MINOR.$((PATCH + 1))"
        ;;
    [0-9]*)
        NEW_VERSION="$1"
        ;;
    *)
        echo "Usage: $0 {major|minor|patch|X.Y.Z}"
        echo "Current version: $CURRENT"
        exit 1
        ;;
esac

echo "Bumping version: $CURRENT → $NEW_VERSION"

# Update VERSION file
echo "$NEW_VERSION" > "$VERSION_FILE"

echo "✅ VERSION file updated to $NEW_VERSION"
echo ""
echo "Next steps:"
echo "  1. Review changes: git diff VERSION"
echo "  2. Commit: git add VERSION && git commit -m \"chore: Bump version to $NEW_VERSION\""
echo "  3. Tag: git tag v$NEW_VERSION && git push origin v$NEW_VERSION"
echo ""
echo "The version will be automatically used in:"
echo "  - Go binaries (via ldflags)"
echo "  - Bash scripts (via version.sh)"
echo "  - RPM packages (via build_nftban.sh)"
echo "  - DEB packages (via build_nftban.sh)"
