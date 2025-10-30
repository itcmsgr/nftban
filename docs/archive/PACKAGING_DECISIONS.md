# NFTBan v0.10.0 - Final Packaging Decisions

**Date:** 2025-10-28
**Status:** APPROVED
**Purpose:** Document all packaging decisions for v0.10.0 release

---

## ✅ CONFIRMED DECISIONS

### 1. Package Signing

**Decision:** ❌ NO package signing for v0.10.0

**Reasoning:**
- Adds complexity (GPG key management, distribution)
- Not critical for initial GitHub Releases
- SHA256 checksums provide sufficient verification
- Will add in v0.10.1+ when setting up COPR/PPA

**Implementation:**
```bash
# For v0.10.0, provide checksums only
sha256sum nftban*.rpm nftban*.deb > SHA256SUMS

# Users verify with:
sha256sum -c SHA256SUMS
```

**Future (v0.10.1+):**
```bash
# Generate GPG key
gpg --gen-key

# Sign packages
rpmsign --addsign nftban-0.10.1-1.el9.x86_64.rpm
dpkg-sig --sign builder nftban_0.10.1-1_amd64.deb
```

---

### 2. Architecture Support

**Decision:** ✅ x86_64 and aarch64 ONLY

**Supported:**
- ✅ x86_64 (amd64) - Intel/AMD 64-bit
- ✅ aarch64 (arm64) - ARM 64-bit (Raspberry Pi 4+, cloud instances)

**NOT Supported:**
- ❌ armhf (32-bit ARM) - Raspberry Pi 3 and older
- ❌ i686 (32-bit x86) - Legacy systems

**Reasoning:**
- x86_64 and aarch64 cover 99% of modern deployments
- 32-bit systems are declining rapidly
- Simplifies build matrix
- Can add armhf later if demand exists

---

### 3. CentOS 7 Support

**Decision:** ❌ NO CentOS 7 support

**Reasoning:**
- CentOS 7 reached EOL (End of Life) on June 30, 2024
- nftables support is limited on CentOS 7 (older kernel)
- systemd version is too old (systemd 219, we need 250+)
- Supporting EOL distros creates security risks

**Supported Distributions:**
```
RPM:
- Rocky Linux 9
- AlmaLinux 9
- Fedora 39
- Fedora 40

DEB:
- Ubuntu 22.04 LTS
- Ubuntu 24.04 LTS
- Debian 12
```

---

### 4. Auto-Enable Services

**Decision:** ❌ NO auto-enable services

**Reasoning:**
- User should explicitly enable after configuration
- NFTBan requires configuration before use (profile selection, feed setup)
- Auto-enabling could lock out users if misconfigured
- Follows "secure by default" principle

**Package Behavior:**
```bash
# After package install
sudo dnf install nftban
# OR
sudo apt install nftban

# Services are installed but NOT enabled:
systemctl status nftban.timer      # disabled
systemctl status nftban-feeds.timer # disabled
```

**Post-Install Instructions (shown to user):**
```
═══════════════════════════════════════════════════════════════
  NFTBan v0.10.0 - Installation Complete
═══════════════════════════════════════════════════════════════

⚠️  IMPORTANT: NFTBan services are DISABLED by default.

You must configure NFTBan before enabling services:

STEP 1: Check system health
    sudo nftban health

STEP 2: Select security profile
    sudo nftban profile

STEP 3: Update threat feeds (optional)
    sudo nftban feeds update

STEP 4: Enable automatic updates (recommended)
    sudo systemctl enable --now nftban.timer

STEP 5: Verify everything works
    sudo nftban status

For complete setup guide:
    /usr/share/doc/nftban/quickstart.md

═══════════════════════════════════════════════════════════════
```

---

### 5. Go Binary Distribution

**Decision:** ✅ Bundle prebuilt static Go binaries

**Approach:**
- Build with `CGO_ENABLED=0` (static linking, no glibc dependency)
- Include nftban-feeds and nftban-geoip binaries in package
- Build for x86_64 and aarch64 separately

**Build Commands:**
```bash
# Build static Go binaries
cd go-binaries/nftban-feeds
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" -o ../../dist/x86_64/nftban-feeds
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" -o ../../dist/aarch64/nftban-feeds

cd ../nftban-geoip
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" -o ../../dist/x86_64/nftban-geoip
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" -o ../../dist/aarch64/nftban-geoip
```

**Why static binaries:**
- No glibc version dependency
- Works on any Linux system (RHEL 7+, Ubuntu 18.04+, etc.)
- Single binary, no runtime dependencies
- Slightly larger size but maximum portability

---

### 6. Package Repositories

**Decision for v0.10.0:** GitHub Releases ONLY

**Future (v0.10.1+):** Add COPR and PPA

**v0.10.0 Distribution:**
```
GitHub Release: https://github.com/nftban/nftban/releases/v0.10.0

Artifacts:
├── nftban-0.10.0-1.el9.x86_64.rpm         (Rocky/Alma 9)
├── nftban-0.10.0-1.fc39.x86_64.rpm        (Fedora 39)
├── nftban-0.10.0-1.fc40.x86_64.rpm        (Fedora 40)
├── nftban_0.10.0-1_amd64.deb              (Ubuntu/Debian x86_64)
├── nftban-0.10.0-1.el9.aarch64.rpm        (Rocky/Alma 9 ARM)
├── nftban_0.10.0-1_arm64.deb              (Ubuntu/Debian ARM)
├── nftban-0.10.0-x86_64.tar.gz            (Portable x86_64)
├── nftban-0.10.0-aarch64.tar.gz           (Portable ARM)
└── SHA256SUMS                              (Checksums)
```

**Installation Examples:**
```bash
# RPM (Rocky/AlmaLinux 9)
wget https://github.com/nftban/nftban/releases/download/v0.10.0/nftban-0.10.0-1.el9.x86_64.rpm
sudo dnf install ./nftban-0.10.0-1.el9.x86_64.rpm

# DEB (Ubuntu/Debian)
wget https://github.com/nftban/nftban/releases/download/v0.10.0/nftban_0.10.0-1_amd64.deb
sudo apt install ./nftban_0.10.0-1_amd64.deb

# Tarball (portable)
wget https://github.com/nftban/nftban/releases/download/v0.10.0/nftban-0.10.0-x86_64.tar.gz
tar xzf nftban-0.10.0-x86_64.tar.gz
cd nftban-0.10.0
sudo ./install.sh
```

---

### 7. Fallback Installation (Tarball)

**Decision:** ✅ Provide tar.gz with install.sh script

**Purpose:**
- Systems without package manager
- Air-gapped environments
- Custom installations
- Testing/development

**Tarball Contents:**
```
nftban-0.10.0-x86_64.tar.gz:
├── install.sh              (Installation script)
├── uninstall.sh            (Removal script)
├── usr/
│   ├── sbin/nftban         (Main CLI)
│   ├── lib/nftban/         (Libraries)
│   │   ├── cli/            (CLI handlers)
│   │   └── core/           (Core modules)
│   └── share/nftban/       (Data files)
├── etc/nftban/             (Config templates)
├── systemd/                (Systemd units)
├── LICENSE
├── README.md
└── SHA256SUMS
```

**install.sh behavior:**
```bash
#!/usr/bin/env bash
# Checks architecture
# Copies files to system locations
# Sets permissions
# Creates nftban user/group
# Installs systemd units
# Does NOT enable services (user must enable manually)
```

---

## 📋 SUMMARY COMPARISON

| Feature | v0.10.0 Decision | Future (v0.10.1+) |
|---------|-----------------|-------------------|
| Package signing | ❌ NO (checksums only) | ✅ GPG signing |
| Architectures | x86_64, aarch64 | Same (maybe add armhf) |
| CentOS 7 | ❌ NO | ❌ NO (EOL) |
| Auto-enable services | ❌ NO | ❌ NO (by design) |
| Go binaries | ✅ Bundled static | Same |
| Repository | GitHub Releases | + COPR + PPA |
| Tarball fallback | ✅ YES | ✅ YES |

---

## 🎯 PACKAGING WORKFLOW

### Phase 1: Local Testing (Developer)
```bash
# Build packages locally with Docker
./packaging/build-rpm.sh rockylinux:9 x86_64
./packaging/build-rpm.sh rockylinux:9 aarch64
./packaging/build-deb.sh ubuntu:22.04 amd64
./packaging/build-deb.sh ubuntu:22.04 arm64

# Test install on lab servers
sudo dnf install ./dist/nftban-0.10.0-1.el9.x86_64.rpm
```

### Phase 2: GitHub Actions (Automated Release)
```bash
# Trigger on tag push
git tag -a v0.10.0 -m "Release v0.10.0"
git push origin v0.10.0

# GitHub Actions workflow:
1. Build RPM packages (Rocky 9, Alma 9, Fedora 39/40) x (x86_64, aarch64)
2. Build DEB packages (Ubuntu 22.04, 24.04, Debian 12) x (amd64, arm64)
3. Build tarball fallbacks (x86_64, aarch64)
4. Generate SHA256SUMS
5. Run package tests
6. Create GitHub Release
7. Upload all artifacts
```

### Phase 3: User Installation
```bash
# User downloads from GitHub Releases
# Verifies checksum
# Installs package
# Follows post-install instructions to configure and enable
```

---

## 📝 DOCUMENTATION REQUIREMENTS

### 1. Installation Guide
**File:** `/usr/share/doc/nftban/installation.md`

Must clearly document:
- ✅ Services are DISABLED by default
- ✅ Configuration required before enabling
- ✅ Step-by-step enable process
- ✅ Supported distributions
- ✅ Architecture requirements

### 2. Post-Install Message
**Displayed after package install:**

Show clear instructions that NFTBan is disabled and requires configuration.

### 3. Systemd Service Documentation
**File:** `/usr/share/doc/nftban/services.md`

Document all systemd units:
- `nftban.timer` - Main periodic tasks
- `nftban-feeds.timer` - Threat feed updates
- What they do
- How to enable them
- How to check status

---

## 🚦 READINESS CHECKLIST

Before starting packaging implementation:

- [x] ✅ Package signing decision: NO for v0.10.0
- [x] ✅ Architecture support: x86_64, aarch64 only
- [x] ✅ CentOS 7 support: NO
- [x] ✅ Auto-enable services: NO (disabled by default)
- [x] ✅ Go binary distribution: Bundle static binaries
- [x] ✅ Repository strategy: GitHub Releases first
- [x] ✅ Tarball fallback: YES
- [x] ✅ SPDX headers: Applied to all source files
- [ ] ⏳ Installation documentation: TODO
- [ ] ⏳ Post-install script: TODO
- [ ] ⏳ RPM spec file: TODO
- [ ] ⏳ DEB control files: TODO

---

## 🎯 NEXT STEPS

1. **Update PACKAGING_PLAN_FINAL.md** with these decisions
2. **Create installation.md** documenting manual enable process
3. **Create services.md** documenting systemd units
4. **Start packaging implementation:**
   - Go binary build system
   - RPM spec file
   - DEB control files
   - Build scripts
   - GitHub Actions workflow

---

**Status:** Ready to proceed with packaging implementation
**Estimated Time:** 31 hours (as per PACKAGING_PLAN_FINAL.md)
