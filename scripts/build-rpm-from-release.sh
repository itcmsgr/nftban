#!/usr/bin/env bash
# =============================================================================
# NFTBan - RPM Builder from GitHub Release Assets
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Build RPM package with Go binaries from GitHub Releases
# Usage: ./scripts/build-rpm-from-release.sh v0.10.0 [x86_64|aarch64]
# =============================================================================

set -euo pipefail

# Usage: scripts/build-rpm-from-release.sh v0.10.0
VERSION="${1:?tag like v0.10.0}"
ARCH="${2:-$(uname -m)}"   # x86_64 or aarch64
REPO="github.com/itcmsgr/nftban"
BASE="https://$REPO/releases/download/$VERSION"

# Map uname -m to Go/release arch suffix
case "$ARCH" in
  x86_64|amd64)   RELARCH=amd64;   RPMARCH=x86_64 ;;
  aarch64|arm64)  RELARCH=arm64;   RPMARCH=aarch64 ;;
  *) echo "Unsupported arch: $ARCH"; exit 2 ;;
esac

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

pushd "$WORKDIR" >/dev/null
curl -fsSLO "$BASE/nftban-feeds-$RELARCH"
curl -fsSLO "$BASE/nftban-geoip-$RELARCH"
curl -fsSLO "$BASE/SHA256SUMS"
# Try optional signature; do not fail if missing
curl -fsSL -o SHA256SUMS.asc "$BASE/SHA256SUMS.asc" || true

# Verify GPG signature if available
if [ -f SHA256SUMS.asc ]; then
    echo "Verifying GPG signature..."
    gpg --batch --verify SHA256SUMS.asc SHA256SUMS
fi

# Verify SHA256 checksums
sha256sum -c <(grep "$RELARCH$" SHA256SUMS)  # verifies only lines ending with -$RELARCH

# Prepare rpmbuild tree
RPMTOP=${RPMTOP:-"$HOME/rpmbuild"}
mkdir -p "$RPMTOP"/{SOURCES,SPECS,BUILD,RPMS,SRPMS}
cp nftban-feeds-$RELARCH "$RPMTOP/SOURCES/nftban-feeds"
cp nftban-geoip-$RELARCH "$RPMTOP/SOURCES/nftban-geoip"
cp SHA256SUMS "$RPMTOP/SOURCES/SHA256SUMS"
[ -s SHA256SUMS.asc ] && cp SHA256SUMS.asc "$RPMTOP/SOURCES/SHA256SUMS.asc" || true

# Copy spec
repo_root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cp "$repo_root/packaging/rpm/nftban.spec" "$RPMTOP/SPECS/"

# Build
rpmbuild \
  --define "_topdir $RPMTOP" \
  --define "_version ${VERSION#v}" \
  --define "_relarch $RELARCH" \
  --define "_rpmarch $RPMARCH" \
  -bb "$RPMTOP/SPECS/nftban.spec"

popd >/dev/null

echo "✓ RPM built successfully"
echo "Location: $RPMTOP/RPMS/$RPMARCH/"
ls -1 "$RPMTOP/RPMS/$RPMARCH/"nftban-*.rpm
