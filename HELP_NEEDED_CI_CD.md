# 🧩 HELP_NEEDED_CI_CD.md
**Project:** [nftban](https://github.com/itcmsgr/nftban)
**Maintainer:** itcmsgr
**Version under test:** `v0.30.0`
**Build target:** Rocky Linux 9 (containerized)
**Focus:** CI/CD pipeline reliability and packaging (RPM + DEB)

---

## ⚡ Quick Summary

| Item | Detail |
|------|--------|
| **Repository** | [https://github.com/itcmsgr/nftban](https://github.com/itcmsgr/nftban) |
| **Workflow file** | `.github/workflows/release.yml` |
| **Current status** | ❌ CI fails during RPM packaging stage (after Go binaries build successfully) |
| **Target environments** | Rocky Linux 9/10, AlmaLinux 9/10 (RPM) / Ubuntu 22.04+, Debian 12+ (DEB) |
| **Artifacts** | RPM and DEB packages with nftban binaries |
| **Last workflow run** | Failed on "Build RPM packages in Rocky Linux container" step |

---

## 🚨 Problem Description

The CI pipeline fails in the **RPM packaging stage**, specifically when building inside a Rocky Linux 9 container. The failure occurs after:
- ✅ Go binaries build successfully on Ubuntu runner
- ✅ Binaries copied to `src/usr/lib/nftban/bin/`
- ❌ Docker container started for RPM build
- ❌ Build script executed inside container

**Current error status:**
```
Step: Build RPM packages in Rocky Linux container
Conclusion: failure
Status: completed
```

**Workflow run:** https://github.com/itcmsgr/nftban/actions/workflows/release.yml

**What we know:**
- DEB build works fine on Ubuntu runner
- RPM build script works perfectly on actual Rocky/CentOS servers (tested on lab, lab2, lab3, lab4)
- Container approach: `docker run --rm -v "$(pwd):/workspace" -w /workspace rockylinux:9`
- Cannot access detailed logs via API (authentication issues)

**Suspected issues:**
1. File permissions between Ubuntu runner and Rocky container
2. Volume mount not accessible inside container
3. Missing dependencies in container
4. rpmbuild working directory issues

---

## 📦 Package Requirements

**Expected output:**

**RPM Package (for Rocky/AlmaLinux/CentOS/Fedora):**
- Versioned: `nftban-0.30.0-1.el*.x86_64.rpm`
- Standard name: `nftban.el9.x86_64.rpm` (copy for easy downloads)
- Download URL: `https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.x86_64.rpm`

**DEB Package (for Ubuntu/Debian):**
- Versioned: `nftban_0.30.0-1_amd64.deb`
- Standard name: `nftban.ubuntu.amd64.deb` (copy for easy downloads)
- Download URL: `https://github.com/itcmsgr/nftban/releases/latest/download/nftban.ubuntu.amd64.deb`

**SHA256 checksums:** Generated for all packages

---

## 🧰 Installation / Uninstallation Requirements

### System Components

| Component | Requirement |
|------------|-------------|
| **Groups** | `nftban`, `nftban-cli`, `nftban-auditors` |
| **User** | `nftban` (system user, nologin shell) |
| **Directories** | `/etc/nftban/`, `/var/lib/nftban/`, `/var/log/nftban/`, `/var/cache/nftban/` |
| **System config** | `/var/lib/nftban/config/system.conf` (auto-generated with UID/GID values) |
| **Services** | `nftban.service`, `nftban.timer`, `nftban-health.timer` (systemd) |
| **Binaries** | `/usr/sbin/nftban`, `/usr/lib/nftban/bin/{nftban-feeds,nftban-geoip}` |

### Uninstall Behavior (CRITICAL)

**RPM (`dnf remove nftban`):**
- ✅ **PRESERVES** `/var/log/nftban/` (logs for audit/forensics)
- ✅ **PRESERVES** `/etc/nftban/` (configs as .rpmsave)
- ✅ **PRESERVES** `/var/lib/nftban/` (state for reinstall)
- ❌ **REMOVES** `/var/cache/nftban/` (temporary data)
- ✅ Creates `README.uninstalled` in logs directory

**DEB (`apt-get remove nftban`):**
- ✅ **PRESERVES** `/var/log/nftban/` (logs for audit)
- ✅ **PRESERVES** `/etc/nftban/` (configs - marked as conffiles)
- ✅ **PRESERVES** `/var/lib/nftban/` (state)
- ❌ **REMOVES** `/var/cache/nftban/` (temporary data)
- ✅ Creates `README.removed` in logs directory

**DEB (`apt-get purge nftban`):**
- ❌ **REMOVES EVERYTHING** including logs, config, state
- This is explicit destructive action by user

**Rationale:** Logs are evidence. Deleting them on uninstall breaks audits and post-mortems. Standard practice for security/audit compliance.

---

## ⚙️ Current Workflow Implementation

**Full workflow:** `.github/workflows/release.yml`

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

      # ❌ THIS STEP FAILS
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

          # Find and copy RPM (el9 or el10)
          if ls nftban-*.el*.x86_64.rpm 1> /dev/null 2>&1; then
            RPM_FILE=$(ls nftban-*.el*.x86_64.rpm | head -n1)
            cp "$RPM_FILE" nftban.el9.x86_64.rpm
            echo "✓ Created nftban.el9.x86_64.rpm from $RPM_FILE"
          fi

          # Find and copy DEB (amd64)
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

## 🧩 Build Scripts

### 1. Go Binaries Build (CRITICAL – runs first)

**Script:** `scripts/build-go-binaries.sh`
**Version:** 0.30.0 ✅ (recently fixed)
**Purpose:** Builds Go binaries that get packaged into RPM/DEB

**What it does:**
1. Builds `nftban-feeds` (Go binary for feed processing - 10-60x faster than bash)
2. Builds `nftban-geoip` (Go binary for GeoIP lookups)
3. Builds for both x86_64 and aarch64
4. Copies binaries to `src/usr/lib/nftban/bin/` for packaging

**Requirements:**
- Go 1.21+ (provided by `actions/setup-go@v5`)
- Source directories: `go-feeds/`, `go-geoip/`
- Output: `dist/x86_64/nftban-{feeds,geoip}`, `dist/aarch64/nftban-{feeds,geoip}`

**Build command:**
```bash
export VERSION=0.30.0
chmod +x scripts/build-go-binaries.sh
./scripts/build-go-binaries.sh
```

**Container considerations:**
- Go binaries built BEFORE RPM step (on Ubuntu runner)
- Binaries already compiled when container starts
- RPM just packages pre-built binaries
- No Go compilation needed inside Rocky container

---

### 2. RPM Build Script

**Script:** `scripts/build-rpm.sh`
**Version:** 0.30.0 ✅
**Container:** Rocky Linux 9

**What it does:**
1. Creates RPM build directories: `dist/rpm-build/{BUILD,RPMS,SOURCES,SPECS,SRPMS}`
2. Creates source tarball: `nftban-0.30.0.tar.gz` (includes pre-built Go binaries)
3. Runs: `rpmbuild -ba packaging/rpm/nftban.spec`
4. Outputs: `dist/packages/nftban-0.30.0-1.el*.x86_64.rpm`

**Dependencies required in container:**
```bash
dnf install -y rpm-build rpmdevtools tar gzip which
```

**Potential issues:**
- Volume mount permissions between Ubuntu host and Rocky container
- Pre-built Go binaries not accessible inside container?
- Tarball creation fails due to path issues?
- rpmbuild `%{_topdir}` not set correctly?

---

### 3. DEB Build Script

**Script:** `scripts/build-deb.sh`
**Version:** 0.30.0 ✅
**Environment:** Ubuntu runner (native)

**What it does:**
1. Creates `dist/build/deb/`
2. Copies source and debian/ files
3. Runs: `dpkg-buildpackage -us -uc -b`
4. Outputs: `dist/packages/nftban_0.30.0-1_amd64.deb`

**Dependencies:**
```bash
dpkg-dev debhelper fakeroot build-essential devscripts rsync
```

**Status:** ✅ Works correctly (no container needed)

---

## 📜 Package Specifications

### RPM Spec File: `packaging/rpm/nftban.spec`

**Key sections:**

```spec
Name:           nftban
Version:        0.30.0
Release:        1%{?dist}
Summary:        Modern nftables firewall with self-healing inventory monitoring

# Dependencies
Requires:       nftables >= 1.0.0
Requires:       systemd >= 250
Requires:       bash >= 5.0
Requires:       python3
Conflicts:      firewalld iptables iptables-services

%pre
# Create groups
getent group nftban >/dev/null || groupadd -r nftban
getent group nftban-cli >/dev/null || groupadd -r nftban-cli
getent group nftban-auditors >/dev/null || groupadd -r nftban-auditors

# Create user
getent passwd nftban >/dev/null || useradd -r -g nftban -d /var/lib/nftban -s /sbin/nologin nftban

%post
# Generate system.conf with actual UID/GID values
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

%postun
# Only on complete removal ($1 = 0), not on upgrade ($1 = 1)
if [ $1 -eq 0 ]; then
    # PRESERVE logs and config (standard RPM practice)
    # - Logs: /var/log/nftban/ - kept for audit/forensics
    # - Config: /etc/nftban/ - kept as .rpmsave files automatically
    # - State: /var/lib/nftban/ - kept for potential reinstall

    # Remove cache only
    rm -rf /var/cache/nftban

    # Leave informational note
    cat > /var/log/nftban/README.uninstalled <<'EOFMSG'
NFTBan has been uninstalled, but logs have been preserved for audit purposes.
EOFMSG

    # Remove groups and user
    userdel nftban 2>/dev/null || true
    groupdel nftban-cli 2>/dev/null || true
    groupdel nftban-auditors 2>/dev/null || true
    groupdel nftban 2>/dev/null || true
fi
```

**Files included in RPM:**
- Go binaries: `/usr/lib/nftban/bin/{nftban-feeds,nftban-geoip}`
- Main CLI: `/usr/sbin/nftban`
- Libraries: `/usr/lib/nftban/core/*.sh`
- Systemd units: `/usr/lib/systemd/system/*.{service,timer}`
- Config: `/etc/nftban/nftban.conf`

---

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
         jq (>= 1.6),
         curl | wget,
         bash-completion,
         adduser
Conflicts: firewalld, iptables, iptables-persistent
Description: Modern nftables firewall with self-healing inventory monitoring (v0.30)
```

**`packaging/deb/postinst`:**
```bash
#!/bin/bash
set -e

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
NFTBAN_GROUP="nftban"
NFTBAN_GID=${NFTBAN_GID}
NFTBAN_CLI_GROUP="nftban-cli"
NFTBAN_CLI_GID=${NFTBAN_CLI_GID}
NFTBAN_AUDITORS_GROUP="nftban-auditors"
NFTBAN_AUDITORS_GID=${NFTBAN_AUDITORS_GID}
EOF

#DEBHELPER#
```

**`packaging/deb/postrm`:**
```bash
#!/bin/bash
set -e

case "$1" in
    remove)
        # Preserve logs and config for audit/forensics
        rm -rf /run/nftban
        rm -rf /var/cache/nftban

        # Leave informational note
        cat > /var/log/nftban/README.removed <<'EOF'
NFTBan has been removed, but logs have been preserved for audit purposes.

To completely purge all NFTBan data including logs:
  sudo apt-get purge nftban
EOF
        ;;

    purge)
        # Remove EVERYTHING including logs (explicit user action)
        rm -rf /var/lib/nftban
        rm -rf /var/cache/nftban
        rm -rf /var/log/nftban
        rm -rf /etc/nftban
        rm -rf /run/nftban

        # Remove groups and user
        deluser --system nftban 2>/dev/null || true
        delgroup --system nftban-cli 2>/dev/null || true
        delgroup --system nftban-auditors 2>/dev/null || true
        delgroup --system nftban 2>/dev/null || true
        ;;
esac

#DEBHELPER#
exit 0
```

**`packaging/deb/rules`:**
```makefile
#!/usr/bin/make -f

%:
	dh $@

override_dh_auto_install:
	install -d debian/nftban
	# Copy everything except systemd directory
	rsync -a --exclude='usr/lib/systemd' src/ debian/nftban/

	# DEB uses /lib/systemd/system (not /usr/lib)
	install -d -m 0755 debian/nftban/lib/systemd/system
	install -m 0644 src/usr/lib/systemd/system/*.service debian/nftban/lib/systemd/system/
	install -m 0644 src/usr/lib/systemd/system/*.timer debian/nftban/lib/systemd/system/

	# Create FHS directories
	install -d -m 0755 debian/nftban/var/lib/nftban/reports/baseline
	install -d -m 0700 debian/nftban/etc/nftban/keys
	...
```

---

## 🧩 What We've Already Fixed

| # | Fix Summary | Status |
|---|-------------|--------|
| 1 | Build script versions updated to 0.30.0 | ✅ |
| 2 | Go binaries build script VERSION fixed | ✅ |
| 3 | RPM spec: removed non-existent timer reference | ✅ |
| 4 | DEB packaging: removed obsolete dh-systemd | ✅ |
| 5 | DEB packaging: fixed systemd paths (/lib vs /usr/lib) | ✅ |
| 6 | All 3 groups added to system.conf (RPM & DEB) | ✅ |
| 7 | Log retention policy implemented correctly | ✅ |
| 8 | Workflow: added rsync dependency | ✅ |
| 9 | Workflow: changed to Rocky Linux 9 container for RPM | ✅ |
| 10 | Workflow: added standard package name copies | ✅ |

---

## 💬 Questions for ChatGPT

### Primary Questions

1. **Is the Rocky Linux container approach correct?**
   - Current: `docker run --rm -v "$(pwd):/workspace" -w /workspace rockylinux:9`
   - Should we use a different base image?
   - Are there volume mount issues between Ubuntu host and Rocky container?

2. **What dependencies are missing in the container?**
   - Current: `dnf install -y rpm-build rpmdevtools tar gzip which`
   - Is this sufficient for rpmbuild?
   - Does rpmbuild need additional environment variables?

3. **Should we use a pre-built GitHub Action instead?**
   - Options: `rpmbuild-action`, `build-rpm-action`, custom container action
   - Pros/cons vs current Docker approach?
   - Examples of successful RPM builds in GitHub Actions?

4. **Cross-platform build best practices?**
   - RPM in Rocky Linux container
   - DEB on Ubuntu runner
   - Is there a better approach (build matrix, fpm, etc.)?

### Specific Technical Questions

1. **File permissions in Docker volume mounts?**
   - Does the container have proper permissions to write to `dist/packages/`?
   - User mapping issues between host (UID 1001) and container (UID 0)?
   - Should we use `--user` flag in docker run?

2. **Go binaries accessibility in RPM build?**
   - Go binaries built BEFORE RPM step (on Ubuntu with Go 1.21)
   - Binaries copied to `src/usr/lib/nftban/bin/`
   - Are these accessible inside the Rocky container?
   - Does the tarball include them correctly?

3. **Tarball creation location?**
   - Build script creates tarball in `dist/rpm-build/SOURCES/`
   - Is this path accessible in the container?
   - Does `tar` command work correctly with mounted volumes?

4. **rpmbuild environment variables?**
   - Does rpmbuild need specific env vars in container?
   - `%{_topdir}` properly set?
   - HOME directory issues in container?
   - Buildroot permissions?

5. **Go modules in container?**
   - Go binaries already built before RPM step
   - RPM just packages pre-built binaries
   - No Go compilation needed in Rocky container
   - But Go source directories (`go-feeds/`, `go-geoip/`) are included in tarball
   - Could this cause issues?

6. **Alternative approaches?**
   - Build matrix with separate Rocky/Ubuntu runners?
   - Use GitHub-hosted Rocky Linux runners (if available)?
   - Multi-stage Docker builds?
   - Build RPM on Ubuntu with `fpm` tool instead?
   - Use `rpmbuild` action from GitHub Marketplace?

---

## 🧪 Testing Requirements

### Lab Servers

| Server | OS | Purpose |
|--------|-----|---------|
| lab | CentOS Stream 9 | RPM testing |
| lab1 | Ubuntu 24.04 | DEB testing |
| lab2 | CentOS Stream 10 | RPM testing |
| lab3 | AlmaLinux 10.0 | RPM testing |
| lab4 | Rocky Linux 10 | RPM testing |

### Test Procedure: RPM Installation

**Test on lab2 (CentOS Stream 10):**
```bash
# Download from GitHub Release
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.x86_64.rpm

# Check package info before installing
rpm -qp --info nftban.el9.x86_64.rpm | grep Version
rpm -qp --info nftban.el9.x86_64.rpm | grep Release

# Install (should handle iptables conflicts automatically with --allowerasing)
sudo dnf install -y --allowerasing nftban.el9.x86_64.rpm

# Verify installation
cat /var/lib/nftban/config/system.conf
getent group | grep nftban
# Expected: nftban, nftban-cli, nftban-auditors

getent passwd nftban
# Expected: nftban:x:UID:GID::/var/lib/nftban:/sbin/nologin

systemctl status nftban.timer
systemctl status nftban-health.timer

ls -la /usr/lib/nftban/bin/
# Expected: nftban-feeds, nftban-geoip

# Test uninstall (keeps logs)
sudo dnf remove -y nftban

# Verify cleanup
getent group | grep nftban  # Should be gone
ls /var/cache/nftban         # Should be gone
ls /var/lib/nftban           # Should exist (preserved)
ls /etc/nftban               # Should exist (preserved as .rpmsave)
ls /var/log/nftban           # Should exist with README.uninstalled

cat /var/log/nftban/README.uninstalled
```

### Test Procedure: DEB Installation

**Test on lab1 (Ubuntu 24.04):**
```bash
# Download from GitHub Release
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.ubuntu.amd64.deb

# Check package info before installing
dpkg --info nftban.ubuntu.amd64.deb | grep Version
dpkg --info nftban.ubuntu.amd64.deb | grep Architecture

# Install (should handle conffile prompts with defaults)
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  -o Dpkg::Options::="--force-confold" \
  -o Dpkg::Options::="--force-confdef" \
  ./nftban.ubuntu.amd64.deb

# Verify installation
cat /var/lib/nftban/config/system.conf
getent group | grep nftban
# Expected: nftban, nftban-cli, nftban-auditors

getent passwd nftban
# Expected: nftban:x:UID:GID::/var/lib/nftban:/usr/sbin/nologin

systemctl status nftban.timer
systemctl status nftban-health.timer

ls -la /usr/lib/nftban/bin/
# Expected: nftban-feeds, nftban-geoip

# Test remove (keeps logs and config)
sudo apt-get remove -y nftban

# Verify
ls /etc/nftban           # Should exist (conffiles preserved)
ls /var/lib/nftban       # Should exist (state preserved)
ls /var/log/nftban       # Should exist with README.removed
cat /var/log/nftban/README.removed

# Test purge (removes everything)
sudo apt-get purge -y nftban

# Verify complete removal
ls /etc/nftban           # Should be gone
ls /var/lib/nftban       # Should be gone
ls /var/log/nftban       # Should be gone
getent group | grep nftban  # Should be gone
```

---

## ✅ Verification Checklist

After successful package installation, verify:

- [ ] All 3 groups exist: `nftban`, `nftban-cli`, `nftban-auditors`
- [ ] User `nftban` exists with correct home directory (`/var/lib/nftban`)
- [ ] File `/var/lib/nftban/config/system.conf` exists with all 6 variables:
  - `NFTBAN_USER`, `NFTBAN_UID`, `NFTBAN_GROUP`, `NFTBAN_GID`
  - `NFTBAN_CLI_GROUP`, `NFTBAN_CLI_GID`
  - `NFTBAN_AUDITORS_GROUP`, `NFTBAN_AUDITORS_GID`
- [ ] Systemd units installed and working:
  - `nftban.timer` exists
  - `nftban-health.timer` exists
  - `nftban.service` exists
- [ ] Binary `/usr/sbin/nftban` is executable
- [ ] Go binaries exist:
  - `/usr/lib/nftban/bin/nftban-feeds` (executable)
  - `/usr/lib/nftban/bin/nftban-geoip` (executable)
- [ ] Directories exist with correct permissions:
  - `/etc/nftban/` (0750, root:nftban)
  - `/var/lib/nftban/` (0750, nftban:nftban)
  - `/var/log/nftban/` (0750, nftban:adm on DEB, nftban:nftban on RPM)
  - `/var/cache/nftban/` (0750, nftban:nftban)
- [ ] Uninstall preserves logs:
  - `/var/log/nftban/` still exists after `dnf remove` / `apt remove`
  - `README.uninstalled` / `README.removed` created
- [ ] Purge removes everything (DEB only):
  - All directories gone after `apt purge`
  - All groups and users removed

---

## 🌐 Expected CI/CD Flow

**Successful workflow should:**

1. ✅ Trigger on tag push (`v0.30.0`)
2. ✅ Checkout repository with full history
3. ✅ Set up Go 1.21
4. ✅ Install packaging dependencies (rpm, dpkg-dev, debhelper, rsync)
5. ✅ Build Go binaries (nftban-feeds, nftban-geoip) for x86_64 and aarch64
6. ❌ Build RPM package in Rocky Linux 9 container **← FAILS HERE**
7. ✅ Build DEB package on Ubuntu runner
8. ✅ Create standard-named package copies
9. ✅ Generate SHA256SUMS
10. ✅ Upload to GitHub Release at `/releases/download/v0.30.0/`

**Download URLs should work:**

```bash
# RPM (works on Rocky, Alma, CentOS, Fedora)
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.x86_64.rpm

# DEB (works on Ubuntu, Debian)
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.ubuntu.amd64.deb
```

---

## 🧭 Contributing to CI/CD

If you're assisting with CI/CD debugging:

```bash
# Clone repository
git clone https://github.com/itcmsgr/nftban.git
cd nftban

# Test RPM build locally in Rocky container
docker run -it --rm -v $(pwd):/workspace -w /workspace rockylinux:9 bash
dnf install -y rpm-build rpmdevtools tar gzip which golang
chmod +x scripts/build-go-binaries.sh scripts/build-rpm.sh
./scripts/build-go-binaries.sh
./scripts/build-rpm.sh

# Test DEB build locally on Ubuntu
sudo apt-get install -y dpkg-dev debhelper fakeroot build-essential devscripts rsync golang
chmod +x scripts/build-go-binaries.sh scripts/build-deb.sh
./scripts/build-go-binaries.sh
./scripts/build-deb.sh
```

**Key files to review:**
- `.github/workflows/release.yml` - Main CI/CD workflow
- `scripts/build-go-binaries.sh` - Go binary compilation
- `scripts/build-rpm.sh` - RPM build script
- `scripts/build-deb.sh` - DEB build script
- `packaging/rpm/nftban.spec` - RPM specification
- `packaging/deb/control` - DEB package metadata
- `packaging/deb/rules` - DEB build rules

---

## 🔍 Related Issues

- CI/CD build failure during RPM packaging in GitHub Actions
- Docker volume mount permissions between Ubuntu runner and Rocky container
- Pre-built Go binaries not being packaged correctly in RPM

---

## 🧠 Action Needed

- [ ] Review failing workflow step and permissions
- [ ] Confirm Go binaries are accessible inside Rocky container
- [ ] Verify volume mount works correctly (write test file in container)
- [ ] Check if rpmbuild needs additional environment variables
- [ ] Test alternative approaches (GitHub Actions from marketplace, fpm, etc.)
- [ ] Re-run CI/CD with debug logging enabled (`set -x` in build scripts)

---

**Document maintained by:** itcmsgr
**Last updated:** 2025-11-04
**Status:** 🚨 CI/CD broken - RPM build failing in Rocky container
**Priority:** HIGH - blocking v0.30.0 release

---

## Additional Context

### Project Information
- **Name:** NFTBan
- **Version:** 0.30.0
- **Type:** nftables firewall management system with self-healing inventory
- **License:** MPL-2.0
- **Languages:** Bash, Go (for performance-critical components)
- **Target OS:** Rocky/Alma/CentOS 9+, Ubuntu 22.04+, Debian 12+

### Recent Changes (v0.30.0)
- Added self-healing health system
- Added inventory monitoring (processes, packages, firewall state)
- Added baseline management with drift detection
- Added 3-group system (nftban, nftban-cli, nftban-auditors)
- Added Polkit integration for group-based service management
- Added cryptographic verification and signing
- Go binaries for 10-60x faster feed processing

### Why This Matters
Users download packages from GitHub Releases and install via package managers (`dnf install`, `apt install`). The CI/CD must work reliably so every tag push creates working packages that:
1. Install cleanly without manual intervention
2. Create all required system users/groups
3. Generate proper system.conf for application use
4. Handle conflicts (iptables, conffiles) automatically
5. Uninstall/purge correctly (preserve logs on uninstall)
6. Work across all major Linux distributions

**Thank you for your help! 🙏**
