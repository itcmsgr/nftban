# NFTBan Release Filename Strategy
**Date:** November 1, 2025
**Status:** ✅ APPROVED

---

## 📦 Generic Filenames for /latest/ URLs

### Problem with Version-Specific Names
```bash
# BAD - URL breaks when you release v0.10.1
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-0.10.0-1.el9.x86_64.rpm
# Error 404 after releasing v0.10.1!
```

### Solution: Generic Filenames
```bash
# GOOD - URL never changes!
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.x86_64.rpm
# Always gets latest version automatically!
```

---

## 📋 Standard Filename Convention

### RPM Packages (Red Hat Family)

| Architecture | Filename | Target OS |
|--------------|----------|-----------|
| x86_64 | `nftban.el9.x86_64.rpm` | RHEL 9, Rocky 9, AlmaLinux 9, CentOS Stream 9 |
| aarch64 | `nftban.el9.aarch64.rpm` | ARM64 servers |

### DEB Packages (Debian Family)

| Architecture | Filename | Target OS |
|--------------|----------|-----------|
| amd64 | `nftban.ubuntu.amd64.deb` | Ubuntu 22.04+, Debian 12+ |
| arm64 | `nftban.ubuntu.arm64.deb` | ARM64 servers |

### Go Binaries

| Binary | Architecture | Filename |
|--------|--------------|----------|
| nftban-feeds | amd64 | `nftban-feeds-amd64` |
| nftban-feeds | arm64 | `nftban-feeds-arm64` |
| nftban-geoip | amd64 | `nftban-geoip-amd64` |
| nftban-geoip | arm64 | `nftban-geoip-arm64` |

---

## 🔄 GitHub Release Upload Process

### When Creating Release v0.10.0

Upload assets with **generic names**:
```bash
# Build RPMs with version in metadata, but upload with generic name
mv nftban-0.10.0-1.el9.x86_64.rpm nftban.el9.x86_64.rpm
mv nftban-0.10.0-1.el9.aarch64.rpm nftban.el9.aarch64.rpm

# Build DEBs with version in metadata, but upload with generic name
mv nftban_0.10.0-1_amd64.deb nftban.ubuntu.amd64.deb
mv nftban_0.10.0-1_arm64.deb nftban.ubuntu.arm64.deb

# Upload to GitHub Release
gh release upload v0.10.0 \
  nftban.el9.x86_64.rpm \
  nftban.el9.aarch64.rpm \
  nftban.ubuntu.amd64.deb \
  nftban.ubuntu.arm64.deb \
  nftban-feeds-amd64 \
  nftban-feeds-arm64 \
  nftban-geoip-amd64 \
  nftban-geoip-arm64 \
  SHA256SUMS \
  SHA256SUMS.asc
```

---

## ✅ Benefits

### 1. Documentation Never Needs Updates
```markdown
# This line NEVER changes, even when releasing v0.10.1, v0.11.0, etc.
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.x86_64.rpm
```

### 2. Users Always Get Latest
- No confusion about which version to download
- `/latest/` automatically redirects to newest release
- Works for automated deployment scripts

### 3. Consistent URLs Across Docs
- README.md
- Quick Start guides
- Installation guides
- Blog posts
- Third-party tutorials

All use the SAME URL forever!

---

## 🔍 How Users Verify Version

### Before Installing

**RPM:**
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.x86_64.rpm

# Check what version was downloaded
rpm -qp nftban.el9.x86_64.rpm
# Output: nftban-0.10.0-1.el9.x86_64

# Or show detailed info
rpm -qp --info nftban.el9.x86_64.rpm | grep Version
# Output: Version     : 0.10.0
```

**DEB:**
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.ubuntu.amd64.deb

# Check what version was downloaded
dpkg --info nftban.ubuntu.amd64.deb | grep Version
# Output:  Version: 0.10.0-1
```

### After Installing

```bash
# NFTBan built-in version command
nftban version
# Output: NFTBan v0.10.0

# Package manager query
rpm -q nftban           # RPM systems
dpkg -l nftban          # DEB systems
```

### From GitHub API

```bash
# Check latest release tag
curl -s https://api.github.com/repos/itcmsgr/nftban/releases/latest | grep '"tag_name"'
# Output: "tag_name": "v0.10.0",
```

---

## 📝 Package Metadata Contains Real Version

Even though the **filename** is generic, the **package metadata** contains the actual version:

### RPM Metadata
```bash
$ rpm -qp --info nftban.el9.x86_64.rpm
Name        : nftban
Version     : 0.10.0
Release     : 1.el9
Architecture: x86_64
Install Date: (not installed)
Group       : System Environment/Daemons
Size        : 1234567
License     : MPL-2.0
Signature   : (none)
Source RPM  : nftban-0.10.0-1.el9.src.rpm
Build Date  : Fri 01 Nov 2025 10:00:00 PM UTC
Build Host  : github-runner
Summary     : Modern Linux Firewall Management
Description :
NFTBan is a modern Linux firewall management system that simplifies
nftables and fail2ban integration...
```

### DEB Metadata
```bash
$ dpkg --info nftban.ubuntu.amd64.deb
 new Debian package, version 2.0.
 size 1234567 bytes: control archive=5678 bytes.
     500 bytes,    12 lines      control
     123 bytes,     2 lines      md5sums
 Package: nftban
 Version: 0.10.0-1
 Architecture: amd64
 Maintainer: NFTBan Project <contact@nftban.com>
 Installed-Size: 5000
 Depends: nftables, fail2ban, ...
 Section: admin
 Priority: optional
 Homepage: https://nftban.com
 Description: Modern Linux Firewall Management
  NFTBan is a modern Linux firewall management system...
```

---

## 🚀 Release Workflow Example

### Creating v0.10.1 Release

```bash
# 1. Update version in code
sed -i 's/NFTBAN_VERSION="0.10.0"/NFTBAN_VERSION="0.10.1"/' src/usr/sbin/nftban
sed -i 's/Version:        0.10.0/Version:        0.10.1/' packaging/rpm/nftban.spec

# 2. Commit and tag
git commit -am "chore: Bump version to 0.10.1"
git tag v0.10.1
git push origin main --tags

# 3. Build packages (version 0.10.1 is in metadata)
./scripts/build-rpm.sh
# Creates: nftban-0.10.1-1.el9.x86_64.rpm

# 4. Rename to generic filename for upload
mv dist/packages/nftban-0.10.1-1.el9.x86_64.rpm nftban.el9.x86_64.rpm

# 5. Upload to GitHub Release
gh release create v0.10.1 \
  --title "NFTBan v0.10.1" \
  --notes "Bug fixes and improvements" \
  nftban.el9.x86_64.rpm \
  nftban.el9.aarch64.rpm \
  nftban.ubuntu.amd64.deb \
  nftban.ubuntu.arm64.deb

# 6. Done! All docs still work with same URLs
# https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.x86_64.rpm
# Now automatically serves v0.10.1!
```

---

## 📚 Documentation Updates

### What Stays the Same (NEVER UPDATE)
- Installation URLs in README.md
- Download URLs in Quick Start guides
- URLs in blog posts and tutorials

### What Changes (UPDATE ONCE)
- Version badges in README.md
- Man page header (.TH line)
- CHANGELOG.md entries

---

## 🎯 Verification Checklist

Before each release, verify:

- [ ] Package metadata contains correct version
  ```bash
  rpm -qp nftban.el9.x86_64.rpm | grep "0.10.X"
  ```

- [ ] Generic filename is correct
  ```bash
  # Not: nftban-0.10.X-1.el9.x86_64.rpm
  # But: nftban.el9.x86_64.rpm
  ```

- [ ] /latest/ URL works
  ```bash
  curl -I https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.x86_64.rpm
  # Should return: 302 redirect to versioned URL
  ```

- [ ] Version verification works
  ```bash
  rpm -qp --info nftban.el9.x86_64.rpm | grep Version
  # Should show: Version     : 0.10.X
  ```

---

## 🔗 References

**GitHub Releases Documentation:**
- https://docs.github.com/en/repositories/releasing-projects-on-github/about-releases

**Latest Release URL Pattern:**
```
https://github.com/{owner}/{repo}/releases/latest/download/{filename}
```

**How it Works:**
1. GitHub redirects `/latest/` to the newest release tag
2. Downloads the file matching `{filename}` from that release
3. Same filename works across all releases (0.10.0, 0.10.1, 0.11.0, etc.)

---

**Strategy:** ✅ APPROVED
**Implementation:** Ready for v0.10.0 release
**Documentation:** Complete

🤖 Generated with [Claude Code](https://claude.com/claude-code)
