#!/bin/bash
# Release develop to production
set -Eeuo pipefail

if [ -z "$1" ]; then
    echo "Usage: ./scripts/release-to-production.sh <version>"
    echo "Example: ./scripts/release-to-production.sh 0.32.21"
    exit 1
fi

VERSION=$1

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           Releasing v$VERSION to Production                       ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""

# Ensure we're on develop and it's up to date
echo "📥 Updating develop branch..."
git checkout develop
git pull origin develop
echo ""

# Merge to main
echo "🔀 Merging to main..."
git checkout main
git pull origin main
git merge develop --no-ff -m "Release v$VERSION from develop"
echo ""

# Update version files
echo "📝 Updating version files..."
echo "$VERSION" > VERSION
echo "$VERSION" > .version
git add VERSION .version
git commit -m "chore: Bump version to $VERSION"
echo ""

# Create tag
echo "🏷️  Creating release tag..."
git tag -a "v$VERSION" -m "NFTBan v$VERSION - Production Release"
echo ""

# Push everything
echo "📤 Pushing to production..."
git push origin main
git push origin "v$VERSION"
echo ""

# Merge back to develop
echo "🔄 Merging back to develop..."
git checkout develop
git merge main
git push origin develop
echo ""

echo "╔════════════════════════════════════════════════════════════════════╗"
echo "║           ✅ Released v$VERSION to Production!                     ║"
echo "╚════════════════════════════════════════════════════════════════════╝"
echo ""
echo "Release URL: https://github.com/itcmsgr/nftban/releases/tag/v$VERSION"
