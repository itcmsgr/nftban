# NFTBan Repository Setup Guide

**Purpose:** Documentation for enabling required repositories on different Linux distributions

---

## Overview

NFTBan requires certain packages that may not be in default repositories. This guide covers repository setup for all supported distributions.

---

## Rocky Linux / AlmaLinux (RHEL-based)

### Rocky Linux 9 / AlmaLinux 9

**Required Repositories:**
1. **Default Repositories** (enabled by default)
   - BaseOS
   - AppStream
2. **EPEL** (Extra Packages for Enterprise Linux) - **REQUIRED for fail2ban**
3. **CRB** (CodeReady Builder) - **REQUIRED by EPEL packages**

**Setup Commands:**

```bash
# Install EPEL
sudo dnf install -y epel-release

# Enable CRB (CodeReady Builder)
sudo crb enable

# Verify repositories
sudo dnf repolist
```

**Expected Output:**
```
repo id                    repo name
baseos                     Rocky Linux 9 - BaseOS
appstream                  Rocky Linux 9 - AppStream
crb                        Rocky Linux 9 - CRB
epel                       Extra Packages for Enterprise Linux 9
```

### Rocky Linux 10 / AlmaLinux 10

**Required Repositories:**
1. **Default Repositories** (enabled by default)
   - BaseOS
   - AppStream
2. **EPEL** (Extra Packages for Enterprise Linux) - **REQUIRED for fail2ban**
3. **CRB** (CodeReady Builder) - **REQUIRED by EPEL packages**

**Setup Commands:**

```bash
# Install EPEL
sudo dnf install -y epel-release

# Enable CRB (CodeReady Builder) - IMPORTANT!
sudo crb enable

# Verify repositories
sudo dnf repolist
```

**Expected Output:**
```
repo id                    repo name
baseos                     Rocky Linux 10 - BaseOS
appstream                  Rocky Linux 10 - AppStream
extras                     Rocky Linux 10 - Extras
crb                        Rocky Linux 10 - CRB
epel                       Extra Packages for Enterprise Linux 10
```

**⚠️ IMPORTANT:** Without CRB, fail2ban installation will fail because fail2ban depends on packages in CRB.

### Fedora

**Required Repositories:**
- Default repositories (no additional setup needed)

```bash
# All required packages in default repos
sudo dnf install -y nftables fail2ban
```

---

## Ubuntu / Debian

### Ubuntu 22.04 / 24.04

**Required Repositories:**
- Default repositories (universe enabled)

```bash
# Enable universe repository (if not already enabled)
sudo add-apt-repository universe
sudo apt update

# Install packages
sudo apt install -y nftables fail2ban
```

### Debian 12

**Required Repositories:**
- Default repositories (no additional setup needed)

```bash
# Update package lists
sudo apt update

# Install packages
sudo apt install -y nftables fail2ban
```

---

## Package Dependencies

### Core Requirements (All Distributions)

| Package | Purpose | Repository |
|---------|---------|------------|
| nftables | Firewall framework | Default (BaseOS/main) |
| systemd | Service manager | Default (BaseOS/main) |
| bash | Shell scripting | Default (BaseOS/main) |
| jq | JSON processing | Default (AppStream/universe) |
| curl or wget | HTTP client | Default |

### Recommended Packages

| Package | Purpose | Repository |
|---------|---------|------------|
| fail2ban | Automatic IP banning | **EPEL** (Rocky/Alma), Default (Ubuntu/Debian) |
| logrotate | Log rotation | Default |
| polkit | Authorization framework | Default |

### Optional Packages

| Package | Purpose | Repository |
|---------|---------|------------|
| golang | Build Go binaries | Default (AppStream/universe) |
| git | Version control | Default |
| mail/sendmail | Email notifications | Default |

---

## Distribution-Specific Issues

### Rocky Linux 10 / AlmaLinux 10

#### Issue: fail2ban Conflicts with firewalld

**Problem:**
```bash
$ sudo dnf install fail2ban
Error:
 Problem: package fail2ban-firewalld requires firewalld
  - package nftban conflicts with firewalld
```

**Root Cause:**
- fail2ban package depends on fail2ban-firewalld
- fail2ban-firewalld requires firewalld
- NFTBan conflicts with firewalld (by design)

**Solution 1: Install fail2ban-server only (Recommended)**
```bash
sudo dnf install -y fail2ban-server
```

**Solution 2: Install with --setopt=install_weak_deps=False**
```bash
sudo dnf install -y --setopt=install_weak_deps=False fail2ban-server
```

**What Gets Installed:**
- `fail2ban-server` (core daemon)
- `fail2ban-selinux` (SELinux policies)
- `policycoreutils-python-utils` (dependency)

**What Does NOT Get Installed:**
- `fail2ban-firewalld` (not needed with nftables)
- `firewalld` (conflicts with NFTBan)

**Result:** fail2ban works perfectly with nftables, no firewalld needed.

#### Issue: CRB Repository Required

**Problem:**
```bash
$ sudo dnf install epel-release
# ... EPEL installed ...
$ sudo dnf install fail2ban
Error: Unable to find a match: fail2ban
```

**Root Cause:**
- EPEL packages depend on CRB (CodeReady Builder) packages
- CRB is disabled by default

**Solution:**
```bash
# Enable CRB
sudo crb enable

# Now install from EPEL
sudo dnf install -y fail2ban-server
```

**Verification:**
```bash
# Check CRB is enabled
sudo dnf repolist | grep crb

# Expected output:
# crb    Rocky Linux 10 - CRB
```

---

## Complete Installation Procedure

### Rocky Linux 10 (Example from lab4.mywebhost.gr)

```bash
# Step 1: Enable repositories
sudo dnf install -y epel-release
sudo crb enable

# Step 2: Install NFTBan
sudo dnf install -y nftban-0.10.0-1.el10.x86_64.rpm

# Step 3: Install fail2ban (without firewalld)
sudo dnf install -y fail2ban-server

# Step 4: Verify installations
nft --version          # nftables v1.1.1
fail2ban-server --version  # Fail2Ban v1.1.0

# Step 5: Enable services
sudo systemctl enable --now nftables
sudo systemctl enable --now fail2ban

# Step 6: Verify services
sudo systemctl is-active nftables fail2ban
# Expected: active (for both)

# Step 7: Enable NFTBan timers
sudo systemctl enable --now nftban-health.timer
sudo systemctl enable --now nftban-permissions-audit.timer
```

**Result:** Complete NFTBan installation with all components working.

---

## Automated Repository Setup

### Script: scripts/setup-repositories.sh

```bash
#!/usr/bin/env bash
# Automatically detect distro and enable required repositories

set -Eeuo pipefail

# Detect distribution
if [[ -f /etc/rocky-release ]]; then
    DISTRO="rocky"
    VERSION=$(rpm -E %{rhel})
elif [[ -f /etc/almalinux-release ]]; then
    DISTRO="alma"
    VERSION=$(rpm -E %{rhel})
elif [[ -f /etc/fedora-release ]]; then
    DISTRO="fedora"
    VERSION=$(rpm -E %{fedora})
elif [[ -f /etc/lsb-release ]]; then
    DISTRO="ubuntu"
    VERSION=$(lsb_release -sr)
elif [[ -f /etc/debian_version ]]; then
    DISTRO="debian"
    VERSION=$(cat /etc/debian_version)
else
    echo "Unknown distribution"
    exit 1
fi

echo "Detected: $DISTRO $VERSION"

# Setup repositories based on distro
case $DISTRO in
    rocky|alma)
        echo "Installing EPEL..."
        dnf install -y epel-release

        echo "Enabling CRB..."
        crb enable

        echo "Verifying repositories..."
        dnf repolist | grep -E "(epel|crb)"
        ;;

    fedora)
        echo "No additional repositories needed for Fedora"
        ;;

    ubuntu)
        echo "Enabling universe repository..."
        add-apt-repository -y universe
        apt update
        ;;

    debian)
        echo "No additional repositories needed for Debian"
        apt update
        ;;
esac

echo "✓ Repositories configured successfully"
```

---

## Troubleshooting

### Issue: "Unable to find a match: fail2ban"

**Check:**
```bash
# Is EPEL installed?
dnf repolist | grep epel

# Is CRB enabled?
dnf repolist | grep crb
```

**Fix:**
```bash
dnf install -y epel-release
crb enable
dnf clean all
dnf makecache
```

### Issue: "package nftban conflicts with firewalld"

**This is NORMAL.** NFTBan uses nftables directly and conflicts with firewalld by design.

**Solution:** Install fail2ban-server instead of fail2ban
```bash
dnf install -y fail2ban-server
```

### Issue: "crb: command not found"

**Rocky Linux 8:**
```bash
# Use dnf config-manager instead
dnf config-manager --set-enabled powertools
```

**Rocky Linux 9/10:**
```bash
# Use crb command
crb enable
```

---

## Repository Documentation

### EPEL (Extra Packages for Enterprise Linux)

**Website:** https://docs.fedoraproject.org/en-US/epel/

**Purpose:**
- Provides additional packages not in RHEL/Rocky/AlmaLinux default repos
- Required for: fail2ban, many Python packages, development tools

**Installation:**
```bash
dnf install -y epel-release
```

### CRB (CodeReady Builder)

**Purpose:**
- Development libraries and headers
- Required by many EPEL packages as dependencies
- Contains build tools and devel packages

**Enable:**
```bash
crb enable
```

**Verify:**
```bash
dnf repolist | grep crb
```

---

## Summary

### Rocky Linux 10 / AlmaLinux 10

✅ **Required Steps:**
1. Install EPEL: `dnf install -y epel-release`
2. Enable CRB: `crb enable`
3. Install fail2ban: `dnf install -y fail2ban-server`

⚠️ **Common Mistakes:**
- ❌ Forgetting to enable CRB
- ❌ Trying to install `fail2ban` instead of `fail2ban-server`
- ❌ Not understanding firewalld conflict is normal

### Ubuntu / Debian

✅ **Required Steps:**
1. Enable universe (Ubuntu): `add-apt-repository universe`
2. Update: `apt update`
3. Install: `apt install nftables fail2ban`

---

**Last Updated:** 2025-10-30
**Tested On:**
- Rocky Linux 10.0 (Red Quartz) ✅
- Rocky Linux 9.x ✅
- AlmaLinux 9.x ✅
- Ubuntu 22.04/24.04 ✅
- Debian 12 ✅
