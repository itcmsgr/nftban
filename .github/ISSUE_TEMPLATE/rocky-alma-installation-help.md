---
name: Rocky/AlmaLinux Installation Help
about: Having trouble installing NFTBan on Rocky Linux or AlmaLinux?
title: '[Rocky/Alma] Installation issue: '
labels: rocky-linux, almalinux, installation, help-wanted
assignees: ''
---

## System Information

**Operating System:** (Rocky Linux 9/10 / AlmaLinux 9/10)
**NFTBan Version:** (e.g., 1.17.0)

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
cat /etc/os-release | grep -E "^NAME|^VERSION"

# 2. Check nftables
rpm -q nftables

# 3. Check systemd
systemctl --version | head -1
```

**Paste output here:**
```
[paste here]
```

## Installation Steps

NFTBan v1.17.0+ uses **pre-compiled binaries** - no CRB/PowerTools needed!

```bash
# Download
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-el9-x86_64.rpm

# Install (all deps are in base repos)
sudo dnf install -y ./nftban-el9-x86_64.rpm

# Enable
sudo nftban enable
```

## Common Issues

### "Unable to find a match: nftban"
Use local file install: `dnf install -y ./nftban-*.rpm` (note the `./`)

### "nftables not available"
Install nftables: `dnf install -y nftables`

### Panel server (cPanel/Plesk/DirectAdmin)
NFTBan auto-detects panels and enables coexist mode.

---

## Additional Context

Add any other context about the problem here.
