# GitHub Actions CI/CD Help Needed - RPM Build Failure

## Quick Summary
NFTBan v0.30.0 GitHub Actions workflow fails on RPM build step. Need help debugging container-based RPM building on Ubuntu runners.

**Repository:** https://github.com/itcmsgr/nftban
**Branch:** main
**Tag:** v0.30.0
**Workflow File:** `.github/workflows/release.yml`

---

## Problem Description

### Current Issue
- **Workflow:** Release Packages (`.github/workflows/release.yml`)
- **Trigger:** Push to tag `v0.30.0`
- **Status:** ❌ FAILING on "Build RPM packages" step
- **Attempt Count:** 3 times with different fixes
- **DEB Build:** ✅ Works fine
- **RPM Build:** ❌ Fails consistently

### Error Details
```
Step: Build RPM packages
Conclusion: failure
Status: completed
```

Cannot access detailed logs via API (authentication issues).

---

## What We're Trying to Build

### Package Output Requirements

1. **RPM Package (for Rocky/AlmaLinux/CentOS/Fedora)**
   - Versioned: `nftban-0.30.0-1.el*.x86_64.rpm`
   - Standard name: `nftban.el9.x86_64.rpm` (copy for easy downloads)
   - Download URL: `https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.x86_64.rpm`

2. **DEB Package (for Ubuntu/Debian)**
   - Versioned: `nftban_0.30.0-1_amd64.deb`
   - Standard name: `nftban.ubuntu.amd64.deb` (copy for easy downloads)
   - Download URL: `https://github.com/itcmsgr/nftban/releases/latest/download/nftban.ubuntu.amd64.deb`

### Installation Requirements

Both packages must:
- ✅ Create 3 system groups: `nftban`, `nftban-cli`, `nftban-auditors`
- ✅ Create system user: `nftban`
- ✅ Generate `/var/lib/nftban/config/system.conf` with UID/GID values
- ✅ Install systemd units: `nftban.timer`, `nftban-health.timer`
- ✅ Create FHS-compliant directories
- ✅ Handle conflicts (iptables for RPM, conffiles for DEB)

### Uninstallation Requirements

**RPM Uninstall (`dnf remove nftban`):**
- Remove binaries and libraries
- Preserve config files in /etc/nftban
- Preserve logs in /var/log/nftban
- Remove cache in /var/cache/nftban
- Keep state in /var/lib/nftban
- Remove system groups and user

**DEB Uninstall (`apt-get remove nftban`):**
- Remove binaries and libraries
- Keep config files (marked as conffiles)

**DEB Purge (`apt-get purge nftban`):**
- Remove everything including config files
- Remove logs, cache, state
- Remove system groups and user

---

## Current Workflow Implementation

### Workflow File: `.github/workflows/release.yml`

```yaml
name: Release Packages

on:
  push:
    tags:
      - "v*"

permissions:
  contents: write

jobs:
  build-and-release:
    runs-on: ubuntu-latest

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Set up Go
        uses: actions/setup-go@v5
        with:
          go-version: '1.21'

      - name: Install packaging dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y \
            rpm \
            dpkg-dev \
            fakeroot \
            build-essential \
            debhelper \
            devscripts \
            rsync

          # Verify rpmbuild is available (comes with rpm package on Ubuntu)
          which rpmbuild || (echo "ERROR: rpmbuild not found" && exit 1)

      - name: Build Go binaries (x86_64 and aarch64)
        run: |
          chmod +x scripts/build-go-binaries.sh
          ./scripts/build-go-binaries.sh

          echo "=== Verify binaries were built ==="
          ls -lh dist/x86_64/
          ls -lh dist/aarch64/

      # THIS STEP FAILS ❌
      - name: Build RPM packages in Rocky Linux container
        run: |
          docker run --rm -v "$(pwd):/workspace" -w /workspace rockylinux:9 bash -c "
            dnf install -y rpm-build rpmdevtools tar gzip which
            chmod +x scripts/build-rpm.sh
            ./scripts/build-rpm.sh
          "

      - name: Verify RPM packages built
        run: |
          echo "=== RPM packages built ==="
          ls -lh dist/packages/*.rpm

      - name: Build DEB packages
        run: |
          chmod +x scripts/build-deb.sh
          ./scripts/build-deb.sh

          echo "=== DEB packages built ==="
          ls -lh dist/packages/*.deb

      - name: Generate SHA256SUMS
        run: |
          cd dist/packages
          rm -f SHA256SUMS
          if ls *.rpm *.deb 1> /dev/null 2>&1; then
            sha256sum *.rpm *.deb > SHA256SUMS
            echo "=== SHA256SUMS ==="
            cat SHA256SUMS
          fi

      - name: Create standard package names
        run: |
          cd dist/packages

          # Find and link RPM (el9 or el10)
          if ls nftban-*.el*.x86_64.rpm 1> /dev/null 2>&1; then
            RPM_FILE=$(ls nftban-*.el*.x86_64.rpm | head -n1)
            cp "$RPM_FILE" nftban.el9.x86_64.rpm
            echo "✓ Created nftban.el9.x86_64.rpm from $RPM_FILE"
          fi

          # Find and link DEB (amd64)
          if ls nftban_*_amd64.deb 1> /dev/null 2>&1; then
            DEB_FILE=$(ls nftban_*_amd64.deb | head -n1)
            cp "$DEB_FILE" nftban.ubuntu.amd64.deb
            echo "✓ Created nftban.ubuntu.amd64.deb from $DEB_FILE"
          fi

      - name: Upload to GitHub Release
        uses: softprops/action-gh-release@v2
        with:
          files: |
            dist/packages/*.rpm
            dist/packages/*.deb
            dist/packages/SHA256SUMS
          draft: false
          prerelease: false
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

---

## Build Scripts

### Go Binaries Build Script: `scripts/build-go-binaries.sh`

**CRITICAL:** This must run BEFORE RPM/DEB builds! It builds the Go binaries that get packaged.

**What it does:**
1. Builds `nftban-feeds` (Go binary for feed processing - 10-60x faster than bash)
2. Builds `nftban-geoip` (Go binary for GeoIP lookups)
3. Builds for both x86_64 and aarch64
4. Copies binaries to `src/usr/lib/nftban/bin/` for packaging

**Requirements:**
- Go 1.21+ installed
- Source directories: `go-feeds/`, `go-geoip/`
- Output: `dist/x86_64/` and `dist/aarch64/`

**Build Command:**
```bash
export VERSION=0.30.0
chmod +x scripts/build-go-binaries.sh
./scripts/build-go-binaries.sh
```

**Version Issue:** Script has VERSION=0.10.0 hardcoded - should be 0.30.0!

**Dependencies in Container:**
```bash
# Rocky Linux container needs:
dnf install -y golang
# Or use Go from actions/setup-go@v5 (already in workflow)
```

### RPM Build Script: `scripts/build-rpm.sh`

**Key Points:**
- Uses `rpmbuild` command
- VERSION=0.30.0
- Creates tarball from source
- Uses spec file: `packaging/rpm/nftban.spec`

**Dependencies Required:**
```bash
rpmbuild --version  # Must be available
tar --version       # For creating source tarball
gzip --version      # For compressing tarball
```

**Build Process:**
1. Creates `dist/rpm-build/{BUILD,RPMS,SOURCES,SPECS,SRPMS}`
2. Creates source tarball: `nftban-0.30.0.tar.gz`
3. Runs: `rpmbuild -ba packaging/rpm/nftban.spec`
4. Outputs to: `dist/packages/nftban-0.30.0-1.el*.x86_64.rpm`

### DEB Build Script: `scripts/build-deb.sh`

**Key Points:**
- Uses `dpkg-buildpackage`
- VERSION=0.30.0
- debhelper-compat=13

**Dependencies Required:**
```bash
dpkg-buildpackage  # From dpkg-dev
debhelper          # Build system
fakeroot          # For building as non-root
rsync             # For file copying in rules
```

**Build Process:**
1. Creates `dist/build/deb/`
2. Copies source and debian/ files
3. Runs: `dpkg-buildpackage -us -uc -b`
4. Outputs to: `dist/packages/nftban_0.30.0-1_amd64.deb`

---

## Package Specifications

### RPM Spec File: `packaging/rpm/nftban.spec`

**Important Sections:**

```spec
Name:           nftban
Version:        0.30.0
Release:        1%{?dist}

# Groups created in %pre
%pre
getent group nftban >/dev/null || groupadd -r nftban
getent group nftban-cli >/dev/null || groupadd -r nftban-cli
getent group nftban-auditors >/dev/null || groupadd -r nftban-auditors
getent passwd nftban >/dev/null || useradd -r -g nftban -d /var/lib/nftban -s /sbin/nologin nftban

# System.conf created in %post
%post
NFTBAN_UID=$(id -u nftban)
NFTBAN_GID=$(id -g nftban)
NFTBAN_CLI_GID=$(getent group nftban-cli | cut -d: -f3)
NFTBAN_AUDITORS_GID=$(getent group nftban-auditors | cut -d: -f3)

mkdir -p /var/lib/nftban/config
cat > /var/lib/nftban/config/system.conf <<EOF
NFTBAN_USER="nftban"
NFTBAN_UID=${NFTBAN_UID}
NFTBAN_GROUP="nftban"
NFTBAN_GID=${NFTBAN_GID}
NFTBAN_CLI_GROUP="nftban-cli"
NFTBAN_CLI_GID=${NFTBAN_CLI_GID}
NFTBAN_AUDITORS_GROUP="nftban-auditors"
NFTBAN_AUDITORS_GID=${NFTBAN_AUDITORS_GID}
EOF

%systemd_post nftban.timer nftban-health.timer

# Cleanup in %postun
%postun
if [ $1 -eq 0 ]; then
    getent passwd nftban >/dev/null && userdel nftban 2>/dev/null || true
    getent group nftban-cli >/dev/null && groupdel nftban-cli 2>/dev/null || true
    getent group nftban-auditors >/dev/null && groupdel nftban-auditors 2>/dev/null || true
    getent group nftban >/dev/null && groupdel nftban 2>/dev/null || true
    rm -rf /var/cache/nftban
fi
```

### DEB Control Files

**`packaging/deb/control`:**
```debian
Package: nftban
Architecture: amd64 arm64
Depends: ${misc:Depends},
         nftables (>= 1.0.0),
         systemd (>= 250),
         bash (>= 5.0),
         python3,
         ...
Conflicts: firewalld, iptables, iptables-persistent
```

**`packaging/deb/postinst`:**
```bash
# Create groups
addgroup --system nftban || true
addgroup --system nftban-cli || true
addgroup --system nftban-auditors || true

# Create user
adduser --system --ingroup nftban --home /var/lib/nftban --no-create-home nftban || true

# Generate system.conf
NFTBAN_UID=$(id -u nftban)
NFTBAN_GID=$(id -g nftban)
NFTBAN_CLI_GID=$(getent group nftban-cli | cut -d: -f3)
NFTBAN_AUDITORS_GID=$(getent group nftban-auditors | cut -d: -f3)

mkdir -p /var/lib/nftban/config
cat > /var/lib/nftban/config/system.conf <<EOF
NFTBAN_USER="nftban"
NFTBAN_UID=${NFTBAN_UID}
...
EOF
```

**`packaging/deb/postrm`:**
```bash
case "$1" in
    purge)
        # Remove users and groups
        deluser --system nftban 2>/dev/null || true
        delgroup --system nftban-cli 2>/dev/null || true
        delgroup --system nftban-auditors 2>/dev/null || true
        delgroup --system nftban 2>/dev/null || true

        # Remove all data
        rm -rf /var/lib/nftban
        rm -rf /var/cache/nftban
        rm -rf /var/log/nftban
        rm -rf /etc/nftban
        ;;
    remove)
        # Keep config files
        ;;
esac
```

**`packaging/deb/rules`:**
```makefile
#!/usr/bin/make -f

%:
	dh $@

override_dh_auto_install:
	install -d debian/nftban
	rsync -a --exclude='usr/lib/systemd' src/ debian/nftban/

	# DEB uses /lib/systemd/system (not /usr/lib)
	install -d -m 0755 debian/nftban/lib/systemd/system
	install -m 0644 src/usr/lib/systemd/system/*.service debian/nftban/lib/systemd/system/
	install -m 0644 src/usr/lib/systemd/system/*.timer debian/nftban/lib/systemd/system/
	...
```

---

## What We've Already Fixed

### ✅ Completed Fixes

1. **Build Script Versions**
   - Updated `scripts/build-rpm.sh` VERSION: 0.10.0 → 0.30.0
   - Updated `scripts/build-deb.sh` VERSION: 0.10.0 → 0.30.0

2. **RPM Spec File**
   - Removed non-existent `nftban-permissions-audit.timer` from `%systemd_post`
   - Added all 3 groups to system.conf generation

3. **DEB Packaging**
   - Removed obsolete `dh-systemd` dependencies
   - Fixed systemd unit paths (/lib vs /usr/lib for DEB)
   - Added all 3 groups to postinst script

4. **Workflow Enhancements**
   - Added step to create standard-named package copies
   - Added rsync to dependencies
   - Changed to Rocky Linux 9 container for RPM building

---

## Questions for ChatGPT

### Primary Questions

1. **Is the Rocky Linux container approach correct?**
   - Current: `docker run --rm -v "$(pwd):/workspace" -w /workspace rockylinux:9`
   - Should we use a different base image?
   - Are there volume mount issues?

2. **What dependencies are missing in the container?**
   - Current: `dnf install -y rpm-build rpmdevtools tar gzip which`
   - Need: rpmbuild, tar, gzip, spec file processor
   - Missing: ???

3. **Should we use a pre-built GitHub Action instead?**
   - Options: `rpmbuild-action`, `build-rpm-action`, custom container action
   - Pros/cons vs current approach?

4. **Cross-platform build best practices?**
   - RPM on Rocky Linux container
   - DEB on Ubuntu runner
   - Is there a better approach?

### Specific Technical Questions

1. **File permissions in Docker volume mounts?**
   - Does the container have proper permissions to write to `dist/packages/`?
   - User mapping issues between host and container?
   - UID/GID mismatch between Ubuntu runner and Rocky container?

2. **Go binaries in RPM build?**
   - Go binaries built BEFORE RPM step (on Ubuntu with Go 1.21)
   - Binaries copied to `src/usr/lib/nftban/bin/`
   - Are these accessible inside the Rocky container?
   - Does the RPM spec file properly include them?

3. **Tarball creation location?**
   - Build script creates tarball in `dist/rpm-build/SOURCES/`
   - Is this path accessible in the container?
   - Does `tar` command work inside container with mounted volumes?

4. **rpmbuild environment variables?**
   - Does rpmbuild need specific env vars in container?
   - `%{_topdir}` properly set?
   - HOME directory issues in container?

5. **Go modules in container?**
   - Go binaries already built before RPM step
   - RPM just packages pre-built binaries
   - No Go compilation needed in Rocky container
   - But Go source directories (`go-feeds/`, `go-geoip/`) are included in tarball

6. **Alternative approaches?**
   - Build matrix with separate RPM/DEB runners?
   - Use GitHub-hosted Rocky Linux runners?
   - Multi-stage Docker builds?
   - Build RPM on Ubuntu with `fpm` tool instead of native rpmbuild?

---

## Testing Requirements

### Installation Testing (after packages are built)

**Test on Rocky Linux 10 (lab2.example.test):**
```bash
# Download from GitHub Release
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.x86_64.rpm

# Check package info before installing
rpm -qp --info nftban.el9.x86_64.rpm | grep Version

# Install (should handle iptables conflicts automatically)
sudo dnf install -y nftban.el9.x86_64.rpm

# Verify installation
cat /var/lib/nftban/config/system.conf
getent group | grep nftban
# Expected: nftban, nftban-cli, nftban-auditors

# Test uninstall
sudo dnf remove -y nftban

# Verify cleanup
getent group | grep nftban  # Should be gone
ls /var/cache/nftban         # Should be gone
ls /var/lib/nftban           # Should exist (preserved)
ls /etc/nftban               # Should exist (preserved)
```

**Test on Ubuntu 24.04 (lab1.example.test):**
```bash
# Download from GitHub Release
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.ubuntu.amd64.deb

# Check package info before installing
dpkg --info nftban.ubuntu.amd64.deb | grep Version

# Install (should handle conffile prompts with defaults)
sudo apt-get install -y ./nftban.ubuntu.amd64.deb

# Verify installation
cat /var/lib/nftban/config/system.conf
getent group | grep nftban
# Expected: nftban, nftban-cli, nftban-auditors

# Test remove (keeps config)
sudo apt-get remove -y nftban
ls /etc/nftban  # Should exist

# Test purge (removes everything)
sudo apt-get purge -y nftban
ls /etc/nftban           # Should be gone
ls /var/lib/nftban       # Should be gone
getent group | grep nftban  # Should be gone
```

### Verification Checklist

After successful package installation, verify:

- [ ] All 3 groups exist: `nftban`, `nftban-cli`, `nftban-auditors`
- [ ] User `nftban` exists with correct home directory
- [ ] File `/var/lib/nftban/config/system.conf` exists with all 6 variables:
  - `NFTBAN_USER`, `NFTBAN_UID`, `NFTBAN_GROUP`, `NFTBAN_GID`
  - `NFTBAN_CLI_GROUP`, `NFTBAN_CLI_GID`
  - `NFTBAN_AUDITORS_GROUP`, `NFTBAN_AUDITORS_GID`
- [ ] Systemd units installed: `nftban.timer`, `nftban-health.timer`
- [ ] Binary `/usr/sbin/nftban` is executable
- [ ] Directories exist with correct permissions:
  - `/etc/nftban/` (0750, root:nftban)
  - `/var/lib/nftban/` (0750, nftban:nftban)
  - `/var/log/nftban/` (0750, nftban:adm on DEB, nftban:nftban on RPM)
  - `/var/cache/nftban/` (0750, nftban:nftban)

---

## Expected CI/CD Flow

### Successful Workflow Should:

1. ✅ Trigger on tag push (`v0.30.0`)
2. ✅ Checkout repository
3. ✅ Build Go binaries (x86_64, aarch64)
4. ✅ Build RPM package in Rocky Linux 9 container
5. ✅ Build DEB package on Ubuntu runner
6. ✅ Create standard-named copies
7. ✅ Generate SHA256SUMS
8. ✅ Upload to GitHub Release at `/releases/download/v0.30.0/`

### Download URLs Should Work:

```bash
# RPM (works on Rocky, Alma, CentOS, Fedora)
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.x86_64.rpm

# DEB (works on Ubuntu, Debian)
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.ubuntu.amd64.deb
```

---

## Additional Context

### Project Information
- **Name:** NFTBan
- **Version:** 0.30.0
- **Type:** nftables firewall management system
- **License:** MPL-2.0
- **Languages:** Bash, Go (for helper binaries)
- **Target OS:** Rocky/Alma/CentOS 9+, Ubuntu 22.04+, Debian 12+

### Recent Changes (v0.30.0)
- Added self-healing health system
- Added inventory monitoring (processes, packages, firewall state)
- Added baseline management with drift detection
- Added 3-group system (nftban, nftban-cli, nftban-auditors)
- Added Polkit integration for group-based service management
- Added cryptographic verification and signing

### Why This Matters
Users download packages from GitHub Releases and install via package managers. The CI/CD must work reliably so every tag push creates working packages that:
1. Install cleanly without manual intervention
2. Create all required system users/groups
3. Generate proper system.conf for GUI/application use
4. Handle conflicts (iptables, conffiles) automatically
5. Uninstall/purge correctly

---

## Help Requested

**@ChatGPT:** Please review this document and help us:

1. **Identify why the RPM build is failing in the Rocky Linux container**
2. **Suggest fixes to the workflow file**
3. **Recommend best practices for cross-platform package building in GitHub Actions**
4. **Review our package specifications (RPM spec, DEB control/postinst/postrm) for any issues**

Thank you for your help! 🙏

---

## Contact & Repository

- **Repository:** https://github.com/itcmsgr/nftban
- **Workflow File:** `.github/workflows/release.yml`
- **Current Tag:** v0.30.0
- **Status:** CI/CD broken, blocking release

**Last Updated:** 2025-11-04 16:25 UTC
