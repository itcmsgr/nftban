#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.10.0 - VERIFY.txt Generator
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: Create verification instructions for end users
#
# Usage: ./make-verify-txt.sh [directory]
#   Default directory: dist/
#
# Example:
#   ./make-verify-txt.sh dist/

set -Eeuo pipefail
IFS=$'\n\t'

# Change to target directory
TARGET_DIR="${1:-dist}"
cd "$TARGET_DIR"

echo "═══════════════════════════════════════════════════════════"
echo "  NFTBan - Generating VERIFY.txt"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Create verification instructions
cat > VERIFY.txt <<'EOF'
═══════════════════════════════════════════════════════════════
  NFTBan v0.10.0 - Package Verification Guide
═══════════════════════════════════════════════════════════════

## VERIFY PACKAGE INTEGRITY

After downloading packages from GitHub Releases, verify them:

### Step 1: Download SHA256SUMS
wget https://github.com/itcmsgr/nftban/releases/download/v0.10.0/SHA256SUMS

### Step 2: Verify checksums
sha256sum -c SHA256SUMS

### Expected Output:
nftban-0.10.0-1.el9.x86_64.rpm: OK
nftban-0.10.0-1.el9.aarch64.rpm: OK
nftban-0.10.0-1.fc39.x86_64.rpm: OK
nftban-0.10.0-1.fc40.x86_64.rpm: OK
nftban_0.10.0-1_amd64.deb: OK
nftban_0.10.0-1_arm64.deb: OK
... (all files show OK)

### What This Verifies:
✓ Files were not corrupted during download
✓ Files were not modified by third parties
✓ You have authentic NFTBan packages from official source

───────────────────────────────────────────────────────────────

## PACKAGE SIGNING (v0.10.1+)

### Current Status (v0.10.0):
- ✅ SHA256 checksums provided (integrity verification)
- ❌ GPG signatures not yet available
- ℹ️  Checksums are sufficient for initial release

### Future (v0.10.1+):
When COPR/PPA repositories are established, we will add:
- GPG package signing
- Public key distribution (RELEASES.KEY)
- Automated trust verification

───────────────────────────────────────────────────────────────

## INSTALLATION AFTER VERIFICATION

### RPM (Rocky/AlmaLinux/Fedora):
sudo dnf install ./nftban-0.10.0-1.el9.x86_64.rpm

### DEB (Ubuntu/Debian):
sudo apt install ./nftban_0.10.0-1_amd64.deb

### From Source (Development):
git clone https://github.com/itcmsgr/nftban.git
cd nftban
./scripts/build-rpm.sh  # or ./scripts/build-deb.sh
sudo dnf install dist/packages/nftban-*.rpm

───────────────────────────────────────────────────────────────

## POST-INSTALL CONFIGURATION

⚠️  IMPORTANT: NFTBan services are DISABLED by default.
You must configure NFTBan before enabling services.

### Step 1: Check system health
sudo nftban health

### Step 2: Select security profile
sudo nftban profile

### Step 3: Enable periodic tasks (optional)
sudo systemctl enable --now nftban.timer

### Step 4: Verify everything works
sudo nftban status

Full documentation: https://github.com/itcmsgr/nftban/tree/main/docs

───────────────────────────────────────────────────────────────

## SUPPORT & ISSUES

- Issues: https://github.com/itcmsgr/nftban/issues
- Documentation: https://github.com/itcmsgr/nftban/tree/main/docs
- Security: See SECURITY.md in repository

═══════════════════════════════════════════════════════════════
EOF

echo "✅ Created VERIFY.txt"
echo ""
echo "File: $(pwd)/VERIFY.txt"
