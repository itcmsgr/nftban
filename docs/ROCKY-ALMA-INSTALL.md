# NFTBan Installation Guide for Rocky Linux & AlmaLinux

**Version:** 0.32.5
**Last Updated:** 2025-11-07
**Applies to:** Rocky Linux 8/9, AlmaLinux 8/9, CentOS 8/9

---

## ⚠️ Important: Repository Requirements

Rocky Linux and AlmaLinux have **different default repositories** than Fedora. NFTBan requires specific packages that are **only available in EPEL and CRB/PowerTools repositories**.

### What NFTBan Needs

NFTBan requires the following packages to install and build:

| Package | Purpose | Repository |
|---------|---------|------------|
| `nftables` | Firewall backend | BaseOS |
| `fail2ban-server` | Intrusion prevention | **EPEL** |
| `golang` | Build Go binaries | AppStream or **CRB** |
| `systemd` | Service management | BaseOS |
| `bash` | Shell scripts | BaseOS |

**The problem:** `fail2ban-server` and `golang` dependencies are **NOT in default Rocky/Alma repos**.

---

## 🚨 Common Installation Failures

### Error 1: Missing EPEL Repository

```
❌ ERROR: EPEL repository is NOT enabled

NFTBan requires fail2ban, which is only available in EPEL.
```

**Cause:** EPEL repository not installed or not enabled.

### Error 2: Missing CRB/PowerTools Repository

```
❌ ERROR: CRB/PowerTools repository is NOT enabled

NFTBan requires fail2ban dependencies from CRB/PowerTools.
```

**Cause:** CRB (Rocky/Alma 9) or PowerTools (Rocky/Alma 8) repository not enabled.

### Error 3: Package Conflicts

```
Error:
 Problem: conflicting requests
  - nothing provides golang needed by nftban
  - package golang-1.18.0 conflicts with golang-1.21.0 from /usr/local/go
```

**Cause:**
- Conflicting testing repos enabled (epel-testing, epel-modular, epel-next)
- Manual Go installation in `/usr/local/go` conflicting with distro golang
- Package version mismatches between repos (mirror skew)

---

## ✅ Step-by-Step Installation Guide

### Rocky Linux 9 / AlmaLinux 9

```bash
# 1. Clean any cached metadata
sudo dnf clean all

# 2. Install EPEL repository
sudo dnf install -y epel-release

# 3. Enable CRB repository
sudo dnf config-manager --set-enabled crb

# 4. Disable conflicting testing repos (if enabled)
sudo dnf config-manager --set-disabled epel-testing epel-modular epel-next epel-next-testing || true

# 5. Remove manual Go installations (if exists)
if [ -d /usr/local/go ]; then
    sudo rm -rf /usr/local/go
    echo "Removed manual Go installation from /usr/local/go"
fi

# 6. Sync all packages to consistent versions (IMPORTANT!)
sudo dnf distro-sync -y

# 7. Download NFTBan
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm

# 8. Install NFTBan
sudo dnf install -y nftban-x86_64.rpm

# 9. Enable NFTBan
sudo nftban enable
```

### Rocky Linux 8 / AlmaLinux 8

```bash
# 1. Clean any cached metadata
sudo dnf clean all

# 2. Install EPEL repository
sudo dnf install -y epel-release

# 3. Enable PowerTools repository (EL8 name for CRB)
sudo dnf config-manager --set-enabled powertools

# 4. Disable conflicting testing repos (if enabled)
sudo dnf config-manager --set-disabled epel-testing epel-modular || true

# 5. Remove manual Go installations (if exists)
if [ -d /usr/local/go ]; then
    sudo rm -rf /usr/local/go
    echo "Removed manual Go installation from /usr/local/go"
fi

# 6. Sync all packages to consistent versions (IMPORTANT!)
sudo dnf distro-sync -y

# 7. Download NFTBan
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm

# 8. Install NFTBan
sudo dnf install -y nftban-x86_64.rpm

# 9. Enable NFTBan
sudo nftban enable
```

---

## 🔍 Pre-Installation Check Script

Before installing, you can verify your system is ready:

```bash
#!/bin/bash
# Check if system is ready for NFTBan

echo "=== NFTBan Pre-Installation Check ==="
echo ""

# Detect OS version
source /etc/os-release
VER=${VERSION_ID%%.*}

echo "OS: $PRETTY_NAME"
echo ""

# Check EPEL
if dnf repolist enabled 2>/dev/null | grep -q 'epel[^-]'; then
    echo "✅ EPEL: enabled"
else
    echo "❌ EPEL: NOT enabled"
fi

# Check CRB/PowerTools
if [ "$VER" -ge 9 ]; then
    REPO_NAME="crb"
else
    REPO_NAME="powertools"
fi

if dnf repolist enabled 2>/dev/null | grep -q "$REPO_NAME"; then
    echo "✅ $REPO_NAME: enabled"
else
    echo "❌ $REPO_NAME: NOT enabled"
fi

# Check for conflicting repos
CONFLICTS=""
for repo in epel-testing epel-modular epel-next epel-next-testing; do
    if dnf repolist enabled 2>/dev/null | grep -q "$repo"; then
        CONFLICTS="$CONFLICTS $repo"
    fi
done

if [ -n "$CONFLICTS" ]; then
    echo "⚠️  Conflicting repos:$CONFLICTS"
else
    echo "✅ No conflicting repos"
fi

# Check for manual Go
if [ -d /usr/local/go ]; then
    echo "⚠️  Manual Go installation found at /usr/local/go"
else
    echo "✅ No conflicting Go installations"
fi

echo ""
echo "Run the installation commands above to fix any ❌ or ⚠️ issues."
```

---

## 🧹 Troubleshooting: "Messy System" Recovery

If you have a system with mixed repos, failed upgrades, or package conflicts:

```bash
# Nuclear option: Clean everything and start fresh

# 1. Remove all cached metadata
sudo dnf clean all
sudo rm -rf /var/cache/dnf

# 2. Remove manual Go installations
sudo rm -rf /usr/local/go

# 3. Reset all module streams (if using EL8)
sudo dnf -y module reset '*'

# 4. Install EPEL
sudo dnf install -y epel-release

# 5. Enable CRB/PowerTools
# For EL9:
sudo dnf config-manager --set-enabled crb
# For EL8:
# sudo dnf config-manager --set-enabled powertools

# 6. Disable all testing repos
sudo dnf config-manager --set-disabled epel-testing epel-modular epel-next epel-next-testing || true

# 7. Force synchronization of ALL packages to consistent versions
sudo dnf distro-sync -y

# 8. Try NFTBan installation again
sudo dnf install -y nftban-x86_64.rpm
```

---

## 📝 Why These Steps Are Required

### Background: Rocky/Alma Repository Structure

Unlike Fedora (where all packages are in default repos), Rocky Linux and AlmaLinux follow RHEL's repository model:

- **BaseOS**: Essential system packages (nftables, systemd, bash)
- **AppStream**: Additional applications (some golang packages)
- **EPEL**: Extra Packages for Enterprise Linux (fail2ban, many dependencies)
- **CRB/PowerTools**: CodeReady Builder - development tools and libraries (golang build dependencies)

**NFTBan requires packages from ALL of these.**

### Why `dnf distro-sync`?

Rocky/Alma use **multiple mirror servers**. Sometimes mirrors are out-of-sync, causing:
```
Error: conflicting requests
  - package glibc-2.34-60.el9.x86_64 requires glibc-devel-2.34-60.el9
  - available glibc-devel-2.34-83.el9.x86_64 (from AppStream mirror A)
```

`dnf distro-sync` forces all packages to match their repository versions, fixing mirror skew.

### Why Remove `/usr/local/go`?

Many users install Go manually from golang.org:
```bash
wget https://go.dev/dl/go1.21.0.linux-amd64.tar.gz
sudo tar -C /usr/local -xzf go1.21.0.linux-amd64.tar.gz
```

This conflicts with the distro `golang` package that NFTBan requires for building Go binaries during RPM installation.

**Solution:** Use distro golang only. Remove manual installations.

---

## 💡 NFTBan Philosophy on Repositories

**From the NFTBan maintainers:**

> We check what WE NEED. If YOUR distro's repositories have conflicts, that's YOUR problem to fix. We don't manage vendor repositories - that's your responsibility.
>
> We provide clear error messages showing EXACTLY what's needed. Following official Rocky/Alma documentation to enable EPEL and CRB is your job, not ours.

**What this means:**
- ✅ NFTBan tells you what packages it needs
- ✅ NFTBan tells you which repos are required
- ✅ NFTBan gives you exact commands to fix your system
- ❌ NFTBan does NOT auto-enable repos (you control your system)
- ❌ NFTBan does NOT fix repo conflicts (follow distro docs)

---

## 📚 Official Documentation References

- **Rocky Linux Documentation**: https://docs.rockylinux.org/
  - EPEL setup: https://docs.rockylinux.org/guides/package_manager/epel/
  - CRB repository: https://wiki.rockylinux.org/rocky/repo/#notes-on-crb

- **AlmaLinux Documentation**: https://wiki.almalinux.org/
  - EPEL setup: https://wiki.almalinux.org/repos/AlmaLinux.html#epel
  - PowerTools/CRB: https://wiki.almalinux.org/repos/AlmaLinux.html#crb

- **EPEL Documentation**: https://docs.fedoraproject.org/en-US/epel/

---

## ✅ Verification After Installation

After successful installation, verify everything is working:

```bash
# Check NFTBan version
nftban --version

# Check system health
nftban health check

# Check if fail2ban is available
rpm -q fail2ban-server

# Check if golang is available
go version

# Check enabled repositories
dnf repolist enabled
```

**Expected output:**
```
NFTBan v0.32.6
✅ All health checks passed
fail2ban-server-1.1.0-6.el9.noarch
go version go1.21.0 linux/amd64
epel                 Extra Packages for Enterprise Linux 9
crb                  CRB Repository
```

---

## 🆘 Still Having Issues?

1. **Check the pre-installation script output** - It will show exactly what's wrong
2. **Run `dnf distro-sync -y`** - Fixes 90% of package conflict issues
3. **Check enabled repos**: `dnf repolist enabled | grep -E 'epel|crb|powertools'`
4. **Check for manual Go**: `ls -la /usr/local/go`
5. **Open an issue**: https://github.com/itcmsgr/nftban/issues

**Include in your issue:**
```bash
# Run this and paste output
cat /etc/os-release
dnf repolist enabled
rpm -qa | grep -E 'golang|epel|nftban'
ls -la /usr/local/go 2>/dev/null || echo "No manual Go"
```

---

## 📌 Quick Reference

**Rocky/Alma 9:**
```bash
sudo dnf clean all && \
sudo dnf install -y epel-release && \
sudo dnf config-manager --set-enabled crb && \
sudo dnf config-manager --set-disabled epel-testing epel-modular epel-next || true && \
sudo dnf distro-sync -y && \
sudo dnf install -y nftban-x86_64.rpm
```

**Rocky/Alma 8:**
```bash
sudo dnf clean all && \
sudo dnf install -y epel-release && \
sudo dnf config-manager --set-enabled powertools && \
sudo dnf config-manager --set-disabled epel-testing epel-modular || true && \
sudo dnf distro-sync -y && \
sudo dnf install -y nftban-x86_64.rpm
```

---

**Document Version:** 1.0
**Last Updated:** 2025-11-07
**Maintainer:** NFTBan Team
**License:** MPL-2.0
