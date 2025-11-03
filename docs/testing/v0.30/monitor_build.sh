#!/bin/bash
# =============================================================================
# NFTBan v0.30.0 - Build Monitor
# =============================================================================
# Monitors GitHub Actions build progress for v0.30.0 release
# =============================================================================

VERSION="0.30.0"
TAG="v${VERSION}"
REPO="itcmsgr/nftban"

echo "════════════════════════════════════════════════════════════════════════════════"
echo "  Monitoring GitHub Actions Build for ${TAG}"
echo "════════════════════════════════════════════════════════════════════════════════"
echo ""
echo "Release URL: https://github.com/${REPO}/releases/tag/${TAG}"
echo "Actions URL: https://github.com/${REPO}/actions"
echo ""

# Check every 30 seconds
while true; do
    echo "───────────────────────────────────────────────────────────────────────────────"
    echo "⏰ $(date '+%H:%M:%S') - Checking build status..."

    # Check if release exists
    RELEASE_CHECK=$(curl -s "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" | jq -r '.tag_name // "not_found"')

    if [ "$RELEASE_CHECK" = "$TAG" ]; then
        echo "✅ Release ${TAG} is published!"
        echo ""

        # List available assets
        echo "📦 Available packages:"
        curl -s "https://api.github.com/repos/${REPO}/releases/tags/${TAG}" | \
            jq -r '.assets[] | "   \(.name) (\(.size) bytes)"'

        echo ""
        echo "🎉 BUILD COMPLETE! Packages are ready for testing."
        echo ""
        echo "Next step: Run the test script"
        echo "  bash /tmp/test_package_upgrade_labs.sh"
        echo ""
        break
    else
        echo "⏳ Build in progress... (release not published yet)"
        echo "   Waiting 30 seconds..."
    fi

    sleep 30
done
