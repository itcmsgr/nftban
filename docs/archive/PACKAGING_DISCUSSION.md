# NFTBan v0.10.0 - Packaging Discussion

**Date:** 2025-10-28
**Purpose:** Understand packaging requirements for RPM and DEB distribution
**Status:** Planning phase - Need decisions before implementation

---

## 🎯 GOAL

Create automated RPM and DEB packages for NFTBan v0.10.0 that:
- Install on all supported distributions (Rocky/AlmaLinux/Fedora for RPM, Ubuntu/Debian for DEB)
- Handle dependencies correctly
- Set up systemd services
- Create required users/groups
- Follow FHS structure
- Can be built automatically via GitHub Actions

---

## 📦 CURRENT INSTALLATION METHOD

**Current:** Manual installation via `install.sh`

```bash
# Current install process
git clone https://github.com/nftban/nftban.git
cd nftban
sudo ./install.sh
```

**Problems with current approach:**
- ❌ Requires Git
- ❌ Users must run script manually
- ❌ No version tracking
- ❌ No automatic updates
- ❌ No dependency verification
- ❌ Not enterprise-friendly

**Desired:** Package manager installation

```bash
# RPM (Rocky/AlmaLinux/Fedora)
sudo dnf install nftban

# DEB (Ubuntu/Debian)
sudo apt install nftban
```

---

## ❓ QUESTIONS TO ANSWER

### 1. Package Names & Versioning

**Q: What should the package be called?**

Options:
- `nftban` (simple, matches project name) ← **RECOMMENDED**
- `nftban-firewall` (descriptive)
- `nftban-core` (distinguishes from potential Pro version)

**Q: How to handle versioning?**

Current: `v0.10.0`

Package version format:
- RPM: `nftban-0.10.0-1.el9.x86_64.rpm`
- DEB: `nftban_0.10.0-1_amd64.deb`

**Q: Release number convention?**
- Start at `-1` for each version?
- Increment for packaging fixes only?

### 2. Dependencies

**Q: What dependencies should be in the package spec?**

**Required (MUST install):**
- nftables >= 1.0.0
- systemd >= 250
- bash >= 5.0
- jq >= 1.6
- curl OR wget

**Recommended (install but not required):**
- fail2ban >= 0.11
- go >= 1.19 (for rebuilding binaries - optional)

**Q: Should we bundle Go binaries or require Go for compilation?**

Options:
1. **Bundle pre-compiled binaries** (recommended)
   - Include nftban-feeds and nftban-geoip in package
   - Works on all systems
   - Larger package size
   - Need to build for multiple architectures

2. **Compile during package install**
   - Requires Go on target system
   - Always matches target architecture
   - Smaller package
   - Slower installation

**Recommendation:** Bundle pre-compiled binaries for x86_64 and aarch64

### 3. Architecture Support

**Q: Which architectures to support?**

Options:
- ✅ x86_64 (Intel/AMD 64-bit) - MUST HAVE
- ✅ aarch64 (ARM 64-bit for Pi, cloud) - SHOULD HAVE
- ❓ i686 (32-bit x86) - needed?
- ❓ armhf (ARM 32-bit) - needed?

**Recommendation:** Start with x86_64 and aarch64

### 4. Package Structure

**Q: Single package or multiple packages?**

Options:
1. **Single monolithic package** (recommended for v0.10.0)
   ```
   nftban-0.10.0-1.el9.x86_64.rpm
   ```
   - Everything in one package
   - Simpler to maintain
   - Easier for users

2. **Split packages** (future consideration)
   ```
   nftban-core-0.10.0-1.el9.x86_64.rpm     # Core system
   nftban-feeds-0.10.0-1.el9.x86_64.rpm    # Threat feeds
   nftban-fail2ban-0.10.0-1.el9.noarch.rpm # Fail2Ban integration
   ```
   - Modular installation
   - More complex
   - Better for Pro version split

**Recommendation:** Single package for v0.10.0

### 5. Configuration Management

**Q: How to handle existing configuration during upgrades?**

**Scenario:** User has `/etc/nftban/nftban.conf` with custom settings, then upgrades package.

Options:
1. **Never overwrite** (RPM/DEB standard)
   - Mark config files with `%config(noreplace)`
   - New version saved as `.rpmnew` or `.dpkg-new`
   - User must merge manually

2. **Backup and replace**
   - Backup to `.backup`
   - Install new version
   - Risk losing user changes

**Recommendation:** Never overwrite (standard practice)

**Q: Should nftban.conf.local be created automatically?**
- Create empty template?
- Create with profile=mixed by default?
- Don't create, leave example only?

### 6. Systemd Services

**Q: Which services should be enabled by default?**

Available services:
- `nftban.timer` - Periodic tasks (feeds update, health checks)
- `nftban.service` - Main service (if we have a daemon)
- `nftban-feeds.timer` - Feed updates only

Options:
1. **Enable nothing** (user must enable manually)
   - Safe, no surprises
   - User must know what to do

2. **Enable timer only** (recommended)
   - Auto-updates feeds
   - Non-intrusive
   - Follows "configure, then enable" pattern

3. **Enable everything**
   - Convenience
   - May break existing setups

**Recommendation:** Enable nothing by default, show post-install instructions

### 7. Pre/Post Installation Scripts

**Q: What should happen during install?**

**Pre-install (%pre):**
- Check for conflicting packages (firewalld, ufw)?
- Warn if nftables not available?

**Post-install (%post):**
- Create nftban user/group (via sysusers.d)
- Create directories (via tmpfiles.d)
- Set permissions
- Show instructions to user
- Enable systemd service?
- Apply default profile?

**Pre-uninstall (%preun):**
- Stop services
- Backup configuration?

**Post-uninstall (%postun):**
- Remove user/group?
- Remove data directories? (NO - keep by default)

**Q: Should we auto-apply a security profile during install?**
- Apply `mixed` profile by default? (safest)
- Leave unconfigured?
- Ask user during install? (not possible for non-interactive)

### 8. File Locations (FHS Compliance)

**Q: Are our paths correct for packaging?**

Current structure:
```
/usr/sbin/nftban                 # CLI binary
/usr/lib/nftban/                 # Libraries & modules
/usr/share/nftban/               # Shared data (profiles, feeds)
/etc/nftban/                     # Configuration
/var/lib/nftban/                 # State data
/var/cache/nftban/               # Cache
/var/log/nftban/                 # Logs
/run/nftban/                     # Runtime data (tmpfs)
```

**Verification needed:**
- ✅ `/usr/sbin` for admin commands - CORRECT
- ✅ `/usr/lib/nftban` for modules - CORRECT
- ✅ `/usr/share/nftban` for data - CORRECT
- ✅ `/etc/nftban` for config - CORRECT
- ✅ `/var/*` for data - CORRECT
- ❓ Should Go binaries be in `/usr/lib/nftban/bin` or `/usr/libexec/nftban`?

**Recommendation:** Keep current structure, FHS compliant

### 9. Build System

**Q: How to build packages?**

Options:
1. **Local builds** (developer workstation)
   ```bash
   ./packaging/build-rpm.sh
   ./packaging/build-deb.sh
   ```
   - Simple for testing
   - Not reproducible
   - Different results per developer

2. **Docker builds** (recommended)
   ```bash
   docker run --rm -v $(pwd):/build rockylinux:9 /build/packaging/build-rpm.sh
   ```
   - Reproducible
   - Clean environment
   - Can build for multiple distros

3. **GitHub Actions** (automation)
   - Triggered on release tag
   - Builds for all distros
   - Uploads to GitHub Releases
   - Can push to repositories

**Recommendation:** Docker builds locally + GitHub Actions for releases

### 10. Distribution

**Q: How do users get the packages?**

Options:
1. **GitHub Releases only**
   - Simple
   - Users download .rpm/.deb manually
   - No automatic updates
   - ```bash
     wget https://github.com/nftban/nftban/releases/download/v0.10.0/nftban-0.10.0-1.el9.x86_64.rpm
     sudo rpm -ivh nftban-0.10.0-1.el9.x86_64.rpm
     ```

2. **Package repository** (COPR for RPM, PPA for DEB)
   - Users add repository once
   - Get updates automatically
   - Professional
   - More setup required

3. **Official distro repos** (future)
   - EPEL for RHEL derivatives
   - Universe for Ubuntu
   - Takes time to get accepted

**Recommendation for v0.10.0:** GitHub Releases (step 1)
**Future:** Add COPR and PPA

### 11. Testing

**Q: How to test packages before release?**

**Test matrix:**
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

**Tests needed:**
1. Package installs cleanly
2. All files in correct locations
3. Services can be enabled
4. nftban command works
5. Health check passes
6. Can apply profile
7. Can update feeds
8. Package upgrades cleanly
9. Package removes cleanly
10. No files left behind after purge

**Q: Manual testing or automated?**
- Use lab servers for manual testing?
- Create test VM images?
- Use GitHub Actions with containers?

### 12. Release Process

**Q: What's the workflow for releasing a new version?**

Proposed workflow:
```
1. Developer: Tag release
   git tag -a v0.10.0 -m "Release v0.10.0"
   git push origin v0.10.0

2. GitHub Actions: Build packages
   - Detect new tag
   - Build RPM packages (Rocky 9, Alma 9, Fedora 39/40)
   - Build DEB packages (Ubuntu 22.04/24.04, Debian 12)
   - Run tests on each
   - Create checksums
   - Sign packages (optional)

3. GitHub Actions: Create release
   - Create GitHub Release
   - Upload all packages
   - Upload checksums
   - Upload CHANGELOG

4. User: Install
   - Download from GitHub Releases
   - Verify checksum
   - Install package
```

**Q: Should packages be signed?**
- GPG signing for RPM
- GPG signing for DEB
- Requires private key management
- Good practice for security

---

## 📋 RECOMMENDED DECISIONS

Based on best practices and NFTBan requirements:

| Question | Recommendation | Reason |
|----------|---------------|---------|
| Package name | `nftban` | Simple, matches project |
| Versioning | `0.10.0-1` | Standard semver + release |
| Dependencies | Bundle Go binaries | Works everywhere |
| Architecture | x86_64, aarch64 | Covers 99% of use cases |
| Package type | Single monolithic | Simpler for v0.10.0 |
| Config handling | Never overwrite | Standard practice |
| Services | Enable nothing | Show instructions instead |
| Post-install | Create user, show instructions | Safe approach |
| Build system | Docker + GitHub Actions | Reproducible + automated |
| Distribution | GitHub Releases first | Simple, add repos later |
| Testing | Automated in CI | Reliable |
| Signing | Not for v0.10.0, add later | Keep simple initially |

---

## 🛠️ IMPLEMENTATION PLAN

### Phase 1: Create RPM Spec (6-8 hours)

**File:** `packaging/rpm/nftban.spec`

**Sections to write:**
1. Package metadata (Name, Version, Release, Summary, License)
2. Dependencies (Requires, BuildRequires)
3. Description
4. Prep section (%prep)
5. Build section (%build) - compile Go binaries if needed
6. Install section (%install) - copy files to buildroot
7. Pre/post scripts (%pre, %post, %preun, %postun)
8. Files list (%files) - what goes in the package
9. Changelog (%changelog)

### Phase 2: Create DEB Package (4-6 hours)

**Files:**
- `packaging/deb/control` - Package metadata
- `packaging/deb/rules` - Build rules
- `packaging/deb/postinst` - Post-install script
- `packaging/deb/prerm` - Pre-remove script
- `packaging/deb/postrm` - Post-remove script

### Phase 3: Build Scripts (2-3 hours)

**Files:**
- `packaging/build-rpm.sh` - Build RPM locally/Docker
- `packaging/build-deb.sh` - Build DEB locally/Docker
- `packaging/build-all.sh` - Build everything

### Phase 4: GitHub Actions (3-4 hours)

**File:** `.github/workflows/build-packages.yml`

**Workflow:**
```yaml
name: Build Packages
on:
  push:
    tags:
      - 'v*'
jobs:
  build-rpm:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        distro: [rockylinux:9, almalinux:9, fedora:39, fedora:40]
    steps:
      - Build RPM for distro
      - Run tests
      - Upload artifacts

  build-deb:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        distro: [ubuntu:22.04, ubuntu:24.04, debian:12]
    steps:
      - Build DEB for distro
      - Run tests
      - Upload artifacts

  create-release:
    needs: [build-rpm, build-deb]
    steps:
      - Download all artifacts
      - Create GitHub Release
      - Upload packages
```

### Phase 5: Testing & Documentation (2-3 hours)

- Test on lab servers
- Update installation documentation
- Create packaging documentation

**Total estimated time:** 17-24 hours (3-4 work days)

---

## 🚀 NEXT STEPS

**Before starting implementation, we need to decide:**

1. ✅ Package name: `nftban`
2. ✅ Bundle Go binaries or compile during install?
3. ✅ Architectures: x86_64 + aarch64?
4. ✅ Auto-enable services or not?
5. ✅ Auto-apply security profile or not?
6. ✅ Build system: Docker + GitHub Actions?
7. ❓ Sign packages now or later?
8. ❓ Any other special requirements?

**Questions for discussion:**

1. Do you want packages signed from v0.10.0 release?
2. Should we create COPR/PPA repositories immediately or later?
3. Are there any enterprise-specific requirements (RHEL compatibility, etc.)?
4. Should we support CentOS 7 (EOL but still used)?
5. Do we need armhf (32-bit ARM) support?

---

## 📖 REFERENCE MATERIALS

**RPM Packaging:**
- RPM spec file guide: https://rpm-packaging-guide.github.io/
- Fedora packaging guidelines: https://docs.fedoraproject.org/en-US/packaging-guidelines/
- COPR build service: https://copr.fedorainfracloud.org/

**DEB Packaging:**
- Debian packaging guide: https://www.debian.org/doc/manuals/maint-guide/
- Ubuntu packaging guide: https://packaging.ubuntu.com/html/
- PPA guide: https://help.launchpad.net/Packaging/PPA

**Both:**
- FHS 3.0: https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html
- Systemd packaging: https://www.freedesktop.org/software/systemd/man/daemon.html

---

**Status:** Ready for discussion
**Next:** Make decisions, then start implementation
