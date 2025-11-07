---
name: Rocky/AlmaLinux Installation Help
about: Having trouble installing NFTBan on Rocky Linux or AlmaLinux?
title: '[Rocky/Alma] Installation issue: '
labels: rocky-linux, almalinux, installation, help-wanted
assignees: ''
---

## System Information

**Operating System:** (Rocky Linux 9 / AlmaLinux 9 / Rocky Linux 8 / AlmaLinux 8)
**NFTBan Version:** (e.g., 0.32.5)

## Installation Command You Tried

```bash
# Paste the exact command you ran here
```

## Error Message

```
# Paste the FULL error message here
```

## Pre-Installation Checks

Before opening this issue, please run these commands and paste the output:

```bash
# 1. Check OS version
cat /etc/os-release

# 2. Check enabled repositories
dnf repolist enabled | grep -E 'epel|crb|powertools'

# 3. Check for conflicting repos
dnf repolist enabled | grep -E 'testing|modular|next'

# 4. Check for manual Go installation
ls -la /usr/local/go 2>/dev/null || echo "No manual Go found"

# 5. Check golang package
rpm -qa | grep golang
```

**Paste output here:**
```
[paste here]
```

## Have You Read the Installation Guide?

- [ ] Yes, I have read `docs/ROCKY-ALMA-INSTALL.md`
- [ ] No, I haven't seen it yet

## Common Solutions (Try These First!)

### Solution 1: Enable EPEL + CRB Repos

**For Rocky/Alma 9:**
```bash
sudo dnf clean all
sudo dnf install -y epel-release
sudo dnf config-manager --set-enabled crb
sudo dnf distro-sync -y
sudo dnf install -y nftban-x86_64.rpm
```

**For Rocky/Alma 8:**
```bash
sudo dnf clean all
sudo dnf install -y epel-release
sudo dnf config-manager --set-enabled powertools
sudo dnf distro-sync -y
sudo dnf install -y nftban-x86_64.rpm
```

### Solution 2: Disable Conflicting Testing Repos

```bash
sudo dnf config-manager --set-disabled epel-testing epel-modular epel-next epel-next-testing
sudo dnf distro-sync -y
```

### Solution 3: Remove Manual Go Installation

```bash
sudo rm -rf /usr/local/go
sudo dnf install -y golang
```

### Solution 4: Fix Package Version Mismatches

```bash
sudo dnf clean all
sudo rm -rf /var/cache/dnf
sudo dnf distro-sync -y
```

---

## Additional Context

Add any other context about the problem here.

**Did any of the common solutions above work?**
- [ ] Yes, Solution #___ fixed it
- [ ] No, still having issues
