# NFTBan v0.10.0 - Final Packaging Plan

**Date:** 2025-10-28
**Updated:** 2025-10-28 (with final decisions)
**Based on:** ChatGPT discussion + NFTBan requirements
**Decision:** Bundle prebuilt Go binaries, ship DEB/RPM + tar.gz fallback

**📋 FINAL DECISIONS:** See PACKAGING_DECISIONS.md for all confirmed decisions including:
- ❌ NO package signing for v0.10.0 (add in v0.10.1+)
- ✅ x86_64 and aarch64 only (NO armhf, NO i686)
- ❌ NO CentOS 7 support (EOL)
- ❌ NO auto-enable services (user must configure first)
- ✅ Bundle static Go binaries (CGO_ENABLED=0)
- ✅ GitHub Releases only for v0.10.0 (COPR/PPA in v0.10.1+)

---

## 🎯 WHAT ARE COPR AND PPA?

### COPR (Cool Other Package Repo)
**For:** Fedora, RHEL, CentOS, Rocky, AlmaLinux

**What it is:**
- Fedora's community package build service
- Like "Fedora's PPA"
- Automatically builds RPMs for multiple distros
- Provides a YUM/DNF repository

**How users use it:**
```bash
# One-time setup
sudo dnf copr enable nftban/nftban

# Install (gets updates automatically)
sudo dnf install nftban

# Updates work like normal packages
sudo dnf update
```

**vs. GitHub Releases:**
```bash
# Manual download each time
wget https://github.com/nftban/nftban/releases/download/v0.10.0/nftban-0.10.0-1.el9.x86_64.rpm
sudo rpm -ivh nftban-0.10.0-1.el9.x86_64.rpm

# No automatic updates
# Must download new RPM for each version
```

### PPA (Personal Package Archive)
**For:** Ubuntu, Debian (Ubuntu only officially)

**What it is:**
- Ubuntu's Launchpad build service
- Automatically builds DEBs for multiple Ubuntu versions
- Provides an APT repository

**How users use it:**
```bash
# One-time setup
sudo add-apt-repository ppa:nftban/stable
sudo apt update

# Install (gets updates automatically)
sudo apt install nftban

# Updates work like normal packages
sudo apt update && sudo apt upgrade
```

**vs. GitHub Releases:**
```bash
# Manual download each time
wget https://github.com/nftban/nftban/releases/download/v0.10.0/nftban_0.10.0-1_amd64.deb
sudo dpkg -i nftban_0.10.0-1_amd64.deb

# No automatic updates
# Must download new DEB for each version
```

### Summary: COPR/PPA = Package Repositories

**With COPR/PPA:**
- ✅ Users: `dnf install nftban` / `apt install nftban`
- ✅ Automatic updates via package manager
- ✅ Professional appearance
- ✅ Easy for enterprises
- ❌ More setup initially
- ❌ Requires maintaining build configs

**Without COPR/PPA (GitHub Releases only):**
- ✅ Simple to set up
- ✅ Full control
- ❌ Users must download manually
- ❌ No automatic updates
- ❌ Less professional for enterprises

**DECISION:** Start with GitHub Releases, add COPR/PPA in v0.10.1+

---

## 📦 FINAL PACKAGING APPROACH

Based on ChatGPT discussion, here's the plan:

### 1. Build Strategy

**Bundle prebuilt Go binaries (STATIC)**
```bash
# nftban-feeds binary
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" \
  -o dist/linux_amd64/nftban-feeds ./go-feeds/cmd/nftban-feeds/main.go

CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" \
  -o dist/linux_arm64/nftban-feeds ./go-feeds/cmd/nftban-feeds/main.go

# nftban-geoip binary
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" \
  -o dist/linux_amd64/nftban-geoip ./go-geoip/cmd/nftban-geoip/main.go

CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" \
  -o dist/linux_arm64/nftban-geoip ./go-geoip/cmd/nftban-geoip/main.go
```

**Why static (CGO_ENABLED=0)?**
- ✅ No glibc dependency
- ✅ Works on any Linux (old or new)
- ✅ No "version GLIBC_2.XX not found" errors
- ✅ Simpler packaging

### 2. Package Artifacts (Per Architecture)

**For x86_64:**
```
nftban-0.10.0-1.el9.x86_64.rpm         # Rocky/AlmaLinux 9
nftban-0.10.0-1.el8.x86_64.rpm         # Rocky/AlmaLinux 8
nftban-0.10.0-1.fc39.x86_64.rpm        # Fedora 39
nftban-0.10.0-1.fc40.x86_64.rpm        # Fedora 40
nftban_0.10.0-1_amd64.deb              # Ubuntu/Debian
nftban-0.10.0-linux-amd64.tar.gz       # Fallback tarball
```

**For aarch64:**
```
nftban-0.10.0-1.el9.aarch64.rpm        # Rocky/AlmaLinux 9 ARM
nftban-0.10.0-1.fc39.aarch64.rpm       # Fedora 39 ARM
nftban_0.10.0-1_arm64.deb              # Ubuntu/Debian ARM
nftban-0.10.0-linux-arm64.tar.gz       # Fallback tarball
```

**Total:** ~8-10 packages per release

### 3. Package Contents

**What goes in every package:**
```
/usr/sbin/nftban                       # Main CLI
/usr/lib/nftban/                       # All modules
/usr/lib/nftban/bin/nftban-feeds       # Go binary (bundled)
/usr/lib/nftban/bin/nftban-geoip       # Go binary (bundled)
/usr/share/nftban/                     # Profiles, templates
/etc/nftban/                           # Configuration
/usr/lib/systemd/system/*.service      # Systemd units
/usr/lib/systemd/system/*.timer
/etc/logrotate.d/nftban
/usr/share/bash-completion/completions/nftban
```

**What gets created at install (via scripts):**
```
/var/lib/nftban/                       # State data
/var/cache/nftban/                     # Cache
/var/log/nftban/                       # Logs
/run/nftban/                           # Runtime (via tmpfiles.d)
```

### 4. Dependencies

**RPM (.spec):**
```spec
# Required at runtime
Requires: nftables >= 1.0.0
Requires: systemd >= 250
Requires: bash >= 5.0
Requires: jq >= 1.6
Requires: curl
Requires: shadow-utils

# Recommended (not required)
Recommends: fail2ban >= 0.11
Recommends: ca-certificates

# Build dependencies (only for building package)
BuildRequires: golang >= 1.19
```

**DEB (control):**
```
Package: nftban
Depends: nftables (>= 1.0.0), systemd (>= 250), bash (>= 5.0), jq (>= 1.6), curl, adduser
Recommends: fail2ban (>= 0.11), ca-certificates
```

**Note:** Since Go binaries are static, we DON'T need:
- ❌ `glibc >= X.XX`
- ❌ Any shared libraries
- ❌ Go runtime on user's system

### 5. Installation Scripts

**RPM %pre (before install):**
```bash
# Check architecture
arch=$(uname -m)
case "$arch" in
    x86_64|aarch64) ;;
    *) echo "ERROR: Unsupported architecture: $arch"
       echo "NFTBan supports x86_64 and aarch64 only"
       exit 1 ;;
esac

# Check nftables is available
if ! command -v nft &>/dev/null; then
    echo "WARNING: nftables not found. Install with: dnf install nftables"
fi
```

**RPM %post (after install):**
```bash
# Create user (if not exists)
if ! id nftban &>/dev/null 2>&1; then
    useradd -r -s /usr/sbin/nologin -d /nonexistent nftban
fi

# Create group
if ! getent group nftban-cli &>/dev/null; then
    groupadd nftban-cli
fi

# Reload systemd
systemctl daemon-reload || true

# Show instructions
cat <<EOF

╔════════════════════════════════════════════════════════════╗
║  NFTBan v0.10.0 Installed Successfully!                   ║
╚════════════════════════════════════════════════════════════╝

Next steps:

1. Choose a security profile:
   nftban profile list
   sudo nftban profile set mixed

2. Update threat feeds:
   sudo nftban feeds update

3. Enable automatic updates (optional):
   sudo systemctl enable --now nftban.timer

4. Check system health:
   sudo nftban health check

Documentation: https://nftban.com/docs

EOF
```

**DEB postinst (similar):**
```bash
#!/bin/sh
set -e

# Create user via adduser
if ! id nftban >/dev/null 2>&1; then
    adduser --system --group --no-create-home nftban
fi

# Create CLI group
if ! getent group nftban-cli >/dev/null; then
    addgroup --system nftban-cli
fi

# Reload systemd
systemctl daemon-reload || true

# Show same instructions as RPM
```

**DON'T auto-enable services** - let user decide when to activate

### 6. Configuration Handling

**On install:**
```bash
# Install main config if not exists
if [ ! -f /etc/nftban/nftban.conf ]; then
    install -m 0640 /etc/nftban/nftban.conf
fi
```

**On upgrade:**
```bash
# NEVER overwrite existing config
# Mark config files as noreplace
```

**RPM:**
```spec
%config(noreplace) /etc/nftban/nftban.conf
%config(noreplace) /etc/nftban/nftban.conf.local
```

**DEB:**
```
conffiles
/etc/nftban/nftban.conf
/etc/nftban/nftban.conf.local
```

**Result:** User's config never lost, new version saved as `.rpmnew` or `.dpkg-dist`

### 7. Tarball Fallback (No Package Manager)

**For users who can't use RPM/DEB:**

**Contents of `nftban-0.10.0-linux-amd64.tar.gz`:**
```
nftban-0.10.0/
├── install.sh              # Idempotent installer
├── uninstall.sh            # Clean removal
├── nftban                  # Main CLI binary
├── nftban-feeds            # Go binary
├── nftban-geoip            # Go binary
├── lib/                    # All modules
├── share/                  # Profiles, templates
├── etc/                    # Config templates
├── systemd/                # Unit files
├── LICENSE
├── README.md
├── CHANGELOG.md
└── checksums.txt
```

**install.sh (simplified):**
```bash
#!/usr/bin/env bash
set -euo pipefail

# Check architecture
arch=$(uname -m)
case "$arch" in
    x86_64) ;;
    aarch64) ;;
    *) echo "ERROR: Unsupported architecture: $arch"; exit 1 ;;
esac

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: Must run as root (use sudo)"
   exit 1
fi

# Install files
install -d /usr/lib/nftban/bin
install -m 0755 nftban /usr/sbin/nftban
install -m 0755 nftban-feeds /usr/lib/nftban/bin/
install -m 0755 nftban-geoip /usr/lib/nftban/bin/
cp -a lib/* /usr/lib/nftban/
cp -a share/* /usr/share/nftban/
cp -a etc/* /etc/nftban/ (if not exists)
cp systemd/*.service /usr/lib/systemd/system/
cp systemd/*.timer /usr/lib/systemd/system/

# Create user
useradd -r -s /usr/sbin/nologin -d /nonexistent nftban || true

# Reload systemd
systemctl daemon-reload || true

echo "✓ NFTBan installed to /usr/sbin/nftban"
echo "Run: nftban health check"
```

---

## 🏗️ BUILD SYSTEM

### Docker-Based Builds (Reproducible)

**Why Docker?**
- ✅ Clean environment every time
- ✅ Same result on any developer machine
- ✅ Can build for all distros
- ✅ Easy to automate

**Build script: `packaging/build-all.sh`**
```bash
#!/usr/bin/env bash
set -euo pipefail

VERSION="0.10.0"
RELEASE="1"

# Build Go binaries first (host machine or Docker)
./packaging/build-go-binaries.sh

# Build RPM packages
for distro in rockylinux:9 rockylinux:8 fedora:39 fedora:40; do
    docker run --rm \
        -v $(pwd):/build \
        -w /build \
        $distro \
        bash -c "
            dnf install -y rpm-build rpmdevtools
            rpmbuild -bb packaging/rpm/nftban.spec \
                --define '_version $VERSION' \
                --define '_release $RELEASE'
        "
done

# Build DEB packages
for distro in ubuntu:22.04 ubuntu:24.04 debian:12; do
    docker run --rm \
        -v $(pwd):/build \
        -w /build \
        $distro \
        bash -c "
            apt-get update
            apt-get install -y build-essential debhelper
            dpkg-buildpackage -b -uc -us
        "
done

# Build tarballs
./packaging/build-tarball.sh

# Generate checksums
cd dist/
sha256sum *.rpm *.deb *.tar.gz > SHA256SUMS
```

### GitHub Actions (Automated Releases)

**.github/workflows/release.yml:**
```yaml
name: Build Release Packages

on:
  push:
    tags:
      - 'v*'

jobs:
  build-go-binaries:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        goos: [linux]
        goarch: [amd64, arm64]
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-go@v4
        with:
          go-version: '1.23'

      - name: Build nftban-feeds
        run: |
          CGO_ENABLED=0 GOOS=${{ matrix.goos }} GOARCH=${{ matrix.goarch }} \
          go build -ldflags "-s -w" \
          -o dist/${{ matrix.goos }}_${{ matrix.goarch }}/nftban-feeds \
          ./go-feeds/cmd/nftban-feeds/main.go

      - name: Build nftban-geoip
        run: |
          CGO_ENABLED=0 GOOS=${{ matrix.goos }} GOARCH=${{ matrix.goarch }} \
          go build -ldflags "-s -w" \
          -o dist/${{ matrix.goos }}_${{ matrix.goarch }}/nftban-geoip \
          ./go-geoip/cmd/nftban-geoip/main.go

      - uses: actions/upload-artifact@v4
        with:
          name: go-binaries-${{ matrix.goarch }}
          path: dist/

  build-rpm:
    needs: build-go-binaries
    runs-on: ubuntu-latest
    strategy:
      matrix:
        distro:
          - rockylinux:9
          - rockylinux:8
          - fedora:39
          - fedora:40
        arch: [x86_64, aarch64]
    steps:
      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4

      - name: Build RPM
        run: |
          docker run --rm -v $(pwd):/build ${{ matrix.distro }} \
          bash /build/packaging/build-rpm.sh ${{ matrix.arch }}

      - uses: actions/upload-artifact@v4
        with:
          name: rpm-${{ matrix.distro }}-${{ matrix.arch }}
          path: dist/*.rpm

  build-deb:
    needs: build-go-binaries
    runs-on: ubuntu-latest
    strategy:
      matrix:
        distro:
          - ubuntu:22.04
          - ubuntu:24.04
          - debian:12
        arch: [amd64, arm64]
    steps:
      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4

      - name: Build DEB
        run: |
          docker run --rm -v $(pwd):/build ${{ matrix.distro }} \
          bash /build/packaging/build-deb.sh ${{ matrix.arch }}

      - uses: actions/upload-artifact@v4
        with:
          name: deb-${{ matrix.distro }}-${{ matrix.arch }}
          path: dist/*.deb

  build-tarball:
    needs: build-go-binaries
    runs-on: ubuntu-latest
    strategy:
      matrix:
        arch: [amd64, arm64]
    steps:
      - uses: actions/checkout@v4

      - uses: actions/download-artifact@v4

      - name: Build tarball
        run: ./packaging/build-tarball.sh ${{ matrix.arch }}

      - uses: actions/upload-artifact@v4
        with:
          name: tarball-${{ matrix.arch }}
          path: dist/*.tar.gz

  create-release:
    needs: [build-rpm, build-deb, build-tarball]
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4

      - name: Generate checksums
        run: |
          cd artifacts/
          find . -name "*.rpm" -o -name "*.deb" -o -name "*.tar.gz" | \
          xargs sha256sum > SHA256SUMS

      - name: Create Release
        uses: softprops/action-gh-release@v1
        with:
          files: |
            artifacts/**/*.rpm
            artifacts/**/*.deb
            artifacts/**/*.tar.gz
            artifacts/SHA256SUMS
          body_path: CHANGELOG.md
```

---

## 📋 IMPLEMENTATION CHECKLIST

### Phase 1: Go Binary Build System (4 hours)
- [x] Create `packaging/build-go-binaries.sh`
- [ ] Test building for x86_64
- [ ] Test building for aarch64
- [ ] Verify binaries are static (ldd shows "not a dynamic executable")
- [ ] Create version embedding in Go binaries

### Phase 2: RPM Packaging (8 hours)
- [ ] Create `packaging/rpm/nftban.spec`
- [ ] Write %pre/%post/%preun/%postun scripts
- [ ] Test build in Docker (Rocky 9)
- [ ] Test install/upgrade/remove
- [ ] Test on lab servers

### Phase 3: DEB Packaging (6 hours)
- [ ] Create `packaging/deb/control`
- [ ] Create `packaging/deb/rules`
- [ ] Create postinst/prerm/postrm scripts
- [ ] Test build in Docker (Ubuntu 22.04)
- [ ] Test install/upgrade/remove

### Phase 4: Tarball Fallback (3 hours)
- [ ] Create `packaging/build-tarball.sh`
- [ ] Create `packaging/install.sh` (for tarball)
- [ ] Create `packaging/uninstall.sh`
- [ ] Test manual installation

### Phase 5: GitHub Actions (4 hours)
- [ ] Create `.github/workflows/release.yml`
- [ ] Test on feature branch
- [ ] Test tag trigger
- [ ] Verify all artifacts build

### Phase 6: Testing (6 hours)
- [ ] Test on Rocky Linux 9 (x86_64)
- [ ] Test on Ubuntu 22.04 (x86_64)
- [ ] Test on ARM server (if available)
- [ ] Test upgrade path
- [ ] Test tarball installation
- [ ] Document any issues

**Total:** ~31 hours (4-5 work days)

---

## 🎯 DECISIONS MADE

| Question | Decision | Reason |
|----------|----------|--------|
| Bundle Go binaries? | ✅ YES (prebuilt static) | No user dependency on Go |
| Architectures | x86_64, aarch64 | Covers 99% use cases |
| Static or dynamic? | STATIC (CGO_ENABLED=0) | Maximum portability |
| Single or split packages? | Single `nftban` package | Simpler for v0.10.0 |
| Auto-enable services? | NO | User choice |
| COPR/PPA now? | NO (v0.10.1+) | Start simple, add later |
| Tarball fallback? | ✅ YES | Safety net |
| Sign packages? | Later (v0.10.1+) | Keep simple initially |
| Support CentOS 7? | NO | EOL, old glibc issues |

---

## 🚀 NEXT STEPS

**Immediate:**
1. Review this plan
2. Confirm decisions
3. Start Phase 1 (Go binary build)

**Questions?**
- Any enterprise-specific requirements?
- Need to support any other architectures?
- Want package signing from v0.10.0 or later?

---

**Status:** Ready to implement
**Estimated time:** 31 hours (4-5 days)
**Blocker:** None - can start immediately
