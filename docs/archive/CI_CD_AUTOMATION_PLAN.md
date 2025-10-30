# NFTBan v0.10.0 - CI/CD Automation Plan

**Date:** 2025-10-28
**Based on:** ChatGPT Auto-sign discussion (/tmp/Auto_sign_GIT_CHAT)
**Adapted for:** NFTBan with confirmed packaging decisions

---

## 🎯 GOAL

Automate package building, checksum generation, and GitHub Release creation using GitHub Actions.

**For v0.10.0:**
- ✅ Automated builds on tag push (`v*`)
- ✅ SHA256 checksums (NO GPG signing yet)
- ✅ Multi-distro builds (Rocky 9, Fedora 39/40, Ubuntu 22.04/24.04, Debian 12)
- ✅ Multi-architecture (x86_64, aarch64)
- ✅ MANIFEST.txt (file list)
- ✅ SBOM.spdx.json (optional software bill of materials)
- ✅ VERIFY.txt (verification instructions)
- ✅ Automatic GitHub Release creation

**For v0.10.1+ (Future):**
- ⏳ GPG package signing (blocks commented out, ready to enable)
- ⏳ COPR/PPA repository publishing

---

## 📂 DIRECTORY STRUCTURE (Adapted for NFTBan)

```
/home/gituser/nftban-v0.10.0-dev/
├── src/                        # NFTBan source files (existing)
│   ├── usr/sbin/nftban
│   ├── usr/lib/nftban/
│   └── usr/share/nftban/
│
├── go-binaries/               # Go source code (existing)
│   ├── nftban-feeds/
│   └── nftban-geoip/
│
├── scripts/                   # ✅ NEW - Build automation scripts
│   ├── build-go-binaries.sh   # Build static Go binaries
│   ├── build-rpm.sh            # Build RPM packages (Docker-based)
│   ├── build-deb.sh            # Build DEB packages (Docker-based)
│   ├── make-sha256sums.sh      # Generate SHA256SUMS
│   ├── verify-sha256sums.sh    # Verify checksums
│   ├── gen-manifest.sh         # Generate MANIFEST.txt
│   ├── gen-sbom.sh             # Generate SBOM.spdx.json (optional)
│   └── make-verify-txt.sh      # Generate VERIFY.txt
│
├── packaging/                 # ✅ NEW - Packaging metadata
│   ├── rpm/
│   │   ├── nftban.spec        # RPM spec file
│   │   ├── nftban.service     # systemd units
│   │   ├── nftban.timer
│   │   └── nftban-feeds.timer
│   └── deb/
│       ├── control            # DEB control file
│       ├── rules              # Build rules
│       ├── postinst           # Post-install script
│       ├── prerm              # Pre-remove script
│       └── postrm             # Post-remove script
│
├── dist/                      # ✅ NEW - Build output (gitignored)
│   ├── nftban-0.10.0-1.el9.x86_64.rpm
│   ├── nftban-0.10.0-1.el9.aarch64.rpm
│   ├── nftban_0.10.0-1_amd64.deb
│   ├── nftban_0.10.0-1_arm64.deb
│   ├── nftban-0.10.0-x86_64.tar.gz
│   ├── nftban-0.10.0-aarch64.tar.gz
│   ├── SHA256SUMS
│   ├── MANIFEST.txt
│   ├── SBOM.spdx.json
│   └── VERIFY.txt
│
├── .github/
│   └── workflows/
│       └── release.yml        # ✅ NEW - GitHub Actions workflow
│
├── LICENSE                    # ✅ Exists (MPL-2.0)
├── NOTICE.md                  # ✅ Exists
├── CONTRIBUTING.md            # ✅ Exists
├── TRADEMARK.md               # ✅ Exists
├── README.md                  # ✅ Exists
├── CHANGELOG.md               # ⏳ TODO - Version history
└── .gitattributes             # ⏳ TODO - Line ending normalization
```

---

## 🔄 WORKFLOW: From Code to Release

### Developer Perspective

```bash
# 1. Developer finishes feature/bugfix
git add .
git commit -m "Complete v0.10.0"

# 2. Create release tag
git tag -a v0.10.0 -m "Release v0.10.0: Package manager support"
git push origin v0.10.0

# 3. GitHub Actions automatically:
#    - Builds all packages (RPM, DEB, tarball)
#    - Generates SHA256SUMS, MANIFEST.txt, SBOM
#    - Runs tests
#    - Creates GitHub Release
#    - Uploads all artifacts

# 4. Done! Release is live at:
#    https://github.com/nftban/nftban/releases/v0.10.0
```

### User Perspective

```bash
# User visits GitHub Releases page
https://github.com/nftban/nftban/releases/v0.10.0

# Downloads package for their system
wget https://github.com/nftban/nftban/releases/download/v0.10.0/nftban-0.10.0-1.el9.x86_64.rpm

# Downloads checksums
wget https://github.com/nftban/nftban/releases/download/v0.10.0/SHA256SUMS

# Verifies integrity
sha256sum -c SHA256SUMS
# Output: nftban-0.10.0-1.el9.x86_64.rpm: OK

# Installs
sudo dnf install ./nftban-0.10.0-1.el9.x86_64.rpm

# Follows post-install instructions (services NOT auto-enabled)
sudo nftban health
sudo nftban profile
sudo systemctl enable --now nftban.timer
```

---

## 📦 ARTIFACTS SHIPPED IN EACH RELEASE

### v0.10.0 Release Bundle (16 files)

**RPM Packages (4 files):**
```
nftban-0.10.0-1.el9.x86_64.rpm          # Rocky/AlmaLinux 9 (x86_64)
nftban-0.10.0-1.el9.aarch64.rpm         # Rocky/AlmaLinux 9 (ARM64)
nftban-0.10.0-1.fc39.x86_64.rpm         # Fedora 39
nftban-0.10.0-1.fc40.x86_64.rpm         # Fedora 40
```

**DEB Packages (4 files):**
```
nftban_0.10.0-1_amd64.deb               # Ubuntu/Debian (x86_64)
nftban_0.10.0-1_arm64.deb               # Ubuntu/Debian (ARM64)
nftban_0.10.0-1~ubuntu22.04_amd64.deb   # Ubuntu 22.04 (optional)
nftban_0.10.0-1~ubuntu24.04_amd64.deb   # Ubuntu 24.04 (optional)
```

**Tarball Fallback (2 files):**
```
nftban-0.10.0-x86_64.tar.gz             # Portable (x86_64)
nftban-0.10.0-aarch64.tar.gz            # Portable (ARM64)
```

**Verification & Metadata (4 files):**
```
SHA256SUMS                              # Checksums for ALL files
MANIFEST.txt                            # File list with sizes
SBOM.spdx.json                          # Software Bill of Materials
VERIFY.txt                              # How to verify packages
```

**Documentation (2 files):**
```
RELEASE_NOTES.md                        # What's new in v0.10.0
nftban-0.10.0-source.tar.gz            # Source code archive
```

---

## 🛠️ HELPER SCRIPTS (scripts/)

### 1. scripts/make-sha256sums.sh
**Purpose:** Generate SHA256SUMS file for all artifacts

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -Eeuo pipefail

cd "${1:-dist}"
rm -f SHA256SUMS

# Generate checksums for all files except SHA256SUMS itself
tmp=$(mktemp)
ls -1 | grep -v '^SHA256SUMS$' > "$tmp"
sha256sum $(cat "$tmp") > SHA256SUMS
rm -f "$tmp"

echo "✅ Created SHA256SUMS ($(wc -l < SHA256SUMS) files)"
cat SHA256SUMS
```

---

### 2. scripts/verify-sha256sums.sh
**Purpose:** Verify integrity of all artifacts

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -Eeuo pipefail

cd "${1:-dist}"

if [[ ! -f SHA256SUMS ]]; then
    echo "❌ SHA256SUMS not found"
    exit 1
fi

sha256sum -c SHA256SUMS

if [[ $? -eq 0 ]]; then
    echo "✅ All checksums verified"
else
    echo "❌ Checksum verification FAILED"
    exit 1
fi
```

---

### 3. scripts/gen-manifest.sh
**Purpose:** Create human-readable artifact list

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -Eeuo pipefail

cd "${1:-dist}"
: > MANIFEST.txt

printf "═══════════════════════════════════════════════════════════\n" >> MANIFEST.txt
printf "  NFTBan v0.10.0 - Release Artifact Manifest\n" >> MANIFEST.txt
printf "═══════════════════════════════════════════════════════════\n\n" >> MANIFEST.txt
printf "Generated: %s\n\n" "$(date -u +"%Y-%m-%d %H:%M:%S UTC")" >> MANIFEST.txt

for f in *; do
    [[ -f "$f" ]] || continue
    size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f")
    printf "%-45s %12d bytes\n" "$f" "$size" >> MANIFEST.txt
done

total_size=$(du -sb . | awk '{print $1}')
total_mb=$(echo "scale=2; $total_size / 1024 / 1024" | bc)
printf "\n%-45s %12s MB\n" "TOTAL:" "$total_mb" >> MANIFEST.txt

echo "✅ Created MANIFEST.txt"
cat MANIFEST.txt
```

---

### 4. scripts/gen-sbom.sh
**Purpose:** Generate Software Bill of Materials (SBOM)

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -Eeuo pipefail

cd "${1:-.}"

if ! command -v syft &>/dev/null; then
    echo "⚠️  syft not found - SBOM generation skipped (optional)"
    echo "   Install: curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh"
    exit 0
fi

echo "Generating SBOM..."
syft packages dir:. -o spdx-json > dist/SBOM.spdx.json

echo "✅ Created SBOM.spdx.json"
```

---

### 5. scripts/make-verify-txt.sh
**Purpose:** Create verification instructions for users

```bash
#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
set -Eeuo pipefail

cd "${1:-dist}"

cat > VERIFY.txt <<'EOF'
═══════════════════════════════════════════════════════════════
  NFTBan v0.10.0 - Package Verification
═══════════════════════════════════════════════════════════════

VERIFY INTEGRITY:
  sha256sum -c SHA256SUMS

EXPECTED OUTPUT:
  nftban-0.10.0-1.el9.x86_64.rpm: OK
  nftban_0.10.0-1_amd64.deb: OK
  (all files should show OK)

WHAT THIS VERIFIES:
  ✓ Files were not corrupted during download
  ✓ Files were not modified by third parties
  ✓ You have authentic NFTBan packages

PACKAGE SIGNING:
  For v0.10.0, we provide SHA256 checksums only.
  GPG signatures and public key will be added in v0.10.1+
  when COPR/PPA repositories are established.

SUPPORT:
  Issues: https://github.com/nftban/nftban/issues
  Docs: https://github.com/nftban/nftban/tree/main/docs

═══════════════════════════════════════════════════════════════
EOF

echo "✅ Created VERIFY.txt"
```

---

## 🤖 GITHUB ACTIONS WORKFLOW

### .github/workflows/release.yml

```yaml
name: Build and Release Packages

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write  # Required to create/edit GitHub Releases

jobs:
  build-and-release:
    runs-on: ubuntu-latest

    steps:
      # ========================================
      # 1. CHECKOUT CODE
      # ========================================
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      # ========================================
      # 2. SETUP BUILD ENVIRONMENT
      # ========================================
      - name: Install build dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            rpm \
            dpkg-dev \
            fakeroot \
            build-essential \
            golang-go \
            curl \
            bc

      # ========================================
      # 3. BUILD GO BINARIES
      # ========================================
      - name: Build Go binaries (static)
        run: |
          echo "Building nftban-feeds and nftban-geoip..."
          bash scripts/build-go-binaries.sh

      # ========================================
      # 4. BUILD RPM PACKAGES
      # ========================================
      - name: Build RPM packages
        run: |
          echo "Building RPM packages..."
          bash scripts/build-rpm.sh rockylinux:9 x86_64
          bash scripts/build-rpm.sh rockylinux:9 aarch64
          bash scripts/build-rpm.sh fedora:39 x86_64
          bash scripts/build-rpm.sh fedora:40 x86_64

      # ========================================
      # 5. BUILD DEB PACKAGES
      # ========================================
      - name: Build DEB packages
        run: |
          echo "Building DEB packages..."
          bash scripts/build-deb.sh ubuntu:22.04 amd64
          bash scripts/build-deb.sh ubuntu:22.04 arm64
          bash scripts/build-deb.sh ubuntu:24.04 amd64
          bash scripts/build-deb.sh debian:12 amd64

      # ========================================
      # 6. BUILD TARBALL FALLBACK
      # ========================================
      - name: Build portable tarballs
        run: |
          echo "Building portable tarballs..."
          bash scripts/build-tarball.sh x86_64
          bash scripts/build-tarball.sh aarch64

      # ========================================
      # 7. GENERATE VERIFICATION FILES
      # ========================================
      - name: Generate SHA256SUMS
        run: bash scripts/make-sha256sums.sh dist

      - name: Generate MANIFEST.txt
        run: bash scripts/gen-manifest.sh dist

      - name: Generate SBOM (optional)
        run: |
          curl -sSfL https://raw.githubusercontent.com/anchore/syft/main/install.sh | sh -s -- -b /usr/local/bin
          bash scripts/gen-sbom.sh .
        continue-on-error: true

      - name: Create VERIFY.txt
        run: bash scripts/make-verify-txt.sh dist

      - name: Create source tarball
        run: |
          VERSION="${GITHUB_REF#refs/tags/v}"
          git archive --format=tar --prefix=nftban-$VERSION/ HEAD | gzip > dist/nftban-$VERSION-source.tar.gz

      # ========================================
      # 8. VERIFY BUILD
      # ========================================
      - name: Verify checksums
        run: bash scripts/verify-sha256sums.sh dist

      - name: List artifacts
        run: ls -lah dist/

      # ========================================
      # 9. CREATE GITHUB RELEASE
      # ========================================
      - name: Upload to GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: |
            dist/*.rpm
            dist/*.deb
            dist/*.tar.gz
            dist/SHA256SUMS
            dist/MANIFEST.txt
            dist/SBOM*.json
            dist/VERIFY.txt
          body: |
            # NFTBan ${{ github.ref_name }}

            ## 📦 Installation

            ### RPM (Rocky/AlmaLinux/Fedora)
            ```bash
            # Download for your distro
            wget https://github.com/nftban/nftban/releases/download/${{ github.ref_name }}/nftban-*.rpm

            # Verify
            wget https://github.com/nftban/nftban/releases/download/${{ github.ref_name }}/SHA256SUMS
            sha256sum -c SHA256SUMS

            # Install
            sudo dnf install ./nftban-*.rpm
            ```

            ### DEB (Ubuntu/Debian)
            ```bash
            # Download
            wget https://github.com/nftban/nftban/releases/download/${{ github.ref_name }}/nftban_*_amd64.deb

            # Verify
            wget https://github.com/nftban/nftban/releases/download/${{ github.ref_name }}/SHA256SUMS
            sha256sum -c SHA256SUMS

            # Install
            sudo apt install ./nftban_*_amd64.deb
            ```

            ## ⚙️ Post-Install Setup

            **IMPORTANT:** Services are DISABLED by default. Configure before enabling:

            ```bash
            # 1. Check system health
            sudo nftban health

            # 2. Select security profile
            sudo nftban profile

            # 3. Enable periodic tasks
            sudo systemctl enable --now nftban.timer

            # 4. Verify
            sudo nftban status
            ```

            ## 📋 What's New

            See [CHANGELOG.md](https://github.com/nftban/nftban/blob/main/CHANGELOG.md)

            ## 🔐 Verification

            All packages include SHA256 checksums.
            GPG signing will be added in v0.10.1+ with COPR/PPA support.
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      # ========================================
      # FUTURE: GPG SIGNING (commented out for v0.10.0)
      # ========================================
      # - name: Import GPG key
      #   if: false  # Enable when ready: change to 'true'
      #   run: |
      #     echo "$GPG_PRIVATE_KEY_B64" | base64 -d > /tmp/private.key.asc
      #     gpg --batch --yes --import /tmp/private.key.asc
      #     KEYID=$(gpg --list-secret-keys --keyid-format=long | awk '/sec/{print $2}' | sed 's|.*/||' | head -n1)
      #     echo "KEYID=$KEYID" >> $GITHUB_ENV
      #   env:
      #     GPG_PRIVATE_KEY_B64: ${{ secrets.GPG_PRIVATE_KEY_B64 }}
      #
      # - name: Sign RPM packages
      #   if: false
      #   working-directory: dist
      #   env:
      #     GPG_PASSPHRASE: ${{ secrets.GPG_PASSPHRASE }}
      #   run: |
      #     for f in *.rpm; do
      #       echo "$GPG_PASSPHRASE" | rpmsign --addsign "$f"
      #       rpm --checksig "$f"
      #     done
      #
      # - name: Sign DEB packages
      #   if: false
      #   working-directory: dist
      #   env:
      #     GPG_PASSPHRASE: ${{ secrets.GPG_PASSPHRASE }}
      #   run: |
      #     for f in *.deb; do
      #       echo "$GPG_PASSPHRASE" | dpkg-sig --batch --sign builder "$f"
      #       dpkg-sig --verify "$f"
      #     done
```

---

## 🎯 ADAPTATION SUMMARY

### What we adapted from ChatGPT discussion:

**✅ ADOPTED (v0.10.0):**
1. GitHub Actions workflow on tag push
2. SHA256 checksums (no signing)
3. Helper scripts (checksums, manifest, SBOM, verify.txt)
4. Multi-architecture builds
5. Automated GitHub Release creation
6. Source tarball generation

**⏳ PREPARED BUT DISABLED (v0.10.1+):**
1. GPG signing blocks (commented out, ready to enable)
2. Public key distribution (RELEASES.KEY, KEY.FPR)
3. COPR/PPA publishing

**✅ NFTBAN-SPECIFIC ADAPTATIONS:**
1. **Services DISABLED by default** - Added post-install instructions emphasizing manual enable
2. **NFTBan directory structure** - Adapted from generic to NFTBan's src/ layout
3. **Go binary builds** - Static CGO_ENABLED=0 for portability
4. **Multi-distro support** - Rocky 9, Fedora 39/40, Ubuntu 22.04/24.04, Debian 12
5. **Multi-architecture** - x86_64 and aarch64 (NO armhf, NO i686)
6. **SPDX compliance** - Already applied to all source files

---

## 📋 IMPLEMENTATION CHECKLIST

### Phase 1: Helper Scripts (2-3 hours)
- [ ] Create `scripts/make-sha256sums.sh`
- [ ] Create `scripts/verify-sha256sums.sh`
- [ ] Create `scripts/gen-manifest.sh`
- [ ] Create `scripts/gen-sbom.sh`
- [ ] Create `scripts/make-verify-txt.sh`
- [ ] Test all helper scripts locally

### Phase 2: Build Scripts (6-8 hours)
- [ ] Create `scripts/build-go-binaries.sh`
- [ ] Create `scripts/build-rpm.sh` (Docker-based)
- [ ] Create `scripts/build-deb.sh` (Docker-based)
- [ ] Create `scripts/build-tarball.sh`
- [ ] Test all builds locally

### Phase 3: GitHub Actions (2-3 hours)
- [ ] Create `.github/workflows/release.yml`
- [ ] Test with test tag (v0.9.99-test)
- [ ] Verify artifacts uploaded correctly
- [ ] Verify checksums work

### Phase 4: Documentation (1-2 hours)
- [ ] Create `CHANGELOG.md`
- [ ] Update `README.md` with installation instructions
- [ ] Add `.gitattributes`
- [ ] Add `.editorconfig`

### Phase 5: Testing (2-3 hours)
- [ ] Test RPM install on Rocky 9 lab server
- [ ] Test DEB install on Ubuntu 22.04 lab server
- [ ] Test tarball install on clean system
- [ ] Verify services are disabled by default
- [ ] Verify post-install instructions are shown

### Total Estimated Time: 13-19 hours

---

## 🚀 NEXT STEPS

1. **Create helper scripts** - Start with scripts/ directory
2. **Test locally** - Generate checksums, manifest for existing files
3. **Create build scripts** - Go binaries, RPM, DEB, tarball
4. **Create GitHub Actions workflow** - Automate everything
5. **Test with test tag** - v0.9.99-test
6. **Tag v0.10.0** - Real release!

---

**Status:** Ready to implement
**Blocking:** None (can start immediately)
**Estimated completion:** 2-3 work days
