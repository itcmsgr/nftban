#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# =============================================================================
# NFTBan v1.0.0 - Version Bumper Script
# =============================================================================
# meta:name="bump-version"
# meta:type="script"
# meta:version="1.0.0"
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:description="Automatically bumps version number in the VERSION file"
# meta:inventory.files="VERSION, VERSION_DATE"
# meta:inventory.binaries="bash"
# meta:inventory.env_vars=""
# meta:inventory.config_files=""
# meta:inventory.systemd_units=""
# meta:inventory.network=""
# meta:inventory.privileges="none"
# =============================================================================
# Usage:
#   ./scripts/bump-version.sh major    # 1.0.5 -> 2.0.0
#   ./scripts/bump-version.sh minor    # 1.0.5 -> 1.1.0
#   ./scripts/bump-version.sh patch    # 1.0.5 -> 1.0.6
#   ./scripts/bump-version.sh 1.2.3    # Set to specific version
# =============================================================================

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/../VERSION"
VERSION_DATE_FILE="$SCRIPT_DIR/../VERSION_DATE"

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

# Update the per-release date artifact (strict ISO YYYY-MM-DD). Defaults to the
# actual release day (UTC); pass VERSION_DATE=YYYY-MM-DD to pin it for a
# reproducible re-cut. This is the RELEASE date, not a build timestamp.
NEW_VERSION_DATE="${VERSION_DATE:-$(date -u +%F)}"
if ! [[ "$NEW_VERSION_DATE" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    echo "FATAL: VERSION_DATE override is not strict ISO YYYY-MM-DD: '$NEW_VERSION_DATE'" >&2
    exit 1
fi
echo "$NEW_VERSION_DATE" > "$VERSION_DATE_FILE"
echo "✅ VERSION_DATE updated to $NEW_VERSION_DATE"
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
