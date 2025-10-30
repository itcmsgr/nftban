# NFTBan Lab Testing Guide

## Quick Reference for Testing RPM Packages on Lab Servers

This guide is specifically for testing NFTBan RPM packages on your production lab servers (lab.mywebhost.gr, lab1.mywebhost.gr, lab2.mywebhost.gr).

---

## Prerequisites

Your lab servers should have:
- Rocky Linux 9+ or AlmaLinux 9+
- SSH root access
- nftables support (kernel 5.x+)

---

## Step 1: Build RPM Package

On your development machine:

```bash
cd /home/gituser/github/nftban

# Build RPM package
./scripts/build-rpm.sh

# Verify build output
ls -lh dist/packages/nftban-*.rpm
```

---

## Step 2: Copy Package to Lab Servers

```bash
# Copy to all three labs
for server in lab.mywebhost.gr lab1.mywebhost.gr lab2.mywebhost.gr; do
    echo "=== Copying to $server ==="
    scp dist/packages/nftban-0.10.0-1.el9.x86_64.rpm root@$server:/tmp/
done
```

---

## Step 3: Install on Lab Server

### Option A: Fresh Installation

```bash
# SSH to lab server
ssh root@lab.mywebhost.gr

# Install package (automatically installs dependencies)
sudo dnf install -y /tmp/nftban-0.10.0-1.el9.x86_64.rpm

# Verify installation
nftban --version
nftban health check
```

### Option B: Upgrade Existing Installation

```bash
# SSH to lab server
ssh root@lab.mywebhost.gr

# Backup current config (optional but recommended)
sudo cp -a /etc/nftban /etc/nftban.backup.$(date +%Y%m%d)

# Upgrade package
sudo dnf upgrade -y /tmp/nftban-0.10.0-1.el9.x86_64.rpm

# Verify upgrade
nftban --version
nftban health check
```

---

## Step 4: Post-Installation Verification

Run these commands to verify the installation:

### 1. Check Version
```bash
nftban --version
# Expected: NFTBan v0.10.0
```

### 2. Health Check
```bash
sudo nftban health check
# Expected: ✓ 0 issues found
```

### 3. Verify Users/Groups
```bash
id nftban
getent group nftban-cli
cat /var/lib/nftban/config/system.conf
```

Expected output:
```
uid=993(nftban) gid=994(nftban) groups=994(nftban)
nftban-cli:x:992:
```

### 4. Check File Permissions
```bash
ls -la /etc/nftban/
ls -la /var/lib/nftban/
ls -la /var/log/nftban/
```

All should be owned by `nftban:nftban`.

### 5. Verify Systemd Services
```bash
systemctl status nftban.timer
systemctl status nftban-health.timer
```

Both should be loaded (but not necessarily enabled yet).

### 6. Test CLI Commands
```bash
# Summary stats
sudo nftban stats --summary

# Generate report
sudo nftban report generate --format json --output /tmp/test-report.json
cat /tmp/test-report.json

# Check nftables table
sudo nft list table inet nftban
```

---

## Step 5: Enable and Start Services

```bash
# Enable timers to start on boot
sudo systemctl enable nftban.timer
sudo systemctl enable nftban-health.timer

# Start timers now
sudo systemctl start nftban.timer
sudo systemctl start nftban-health.timer

# Verify running
sudo systemctl status nftban.timer nftban-health.timer
```

---

## Step 6: Run Initial Setup (if fresh install)

```bash
# Download GeoIP database (if using geo-blocking)
sudo nftban geoip update

# Import threat feeds
sudo nftban feeds import --all

# Apply initial rules
sudo nftban apply

# Verify nftables rules applied
sudo nft list table inet nftban
```

---

## Testing Across All Lab Servers

### Automated Verification Script

```bash
#!/bin/bash
# test-all-labs.sh

for server in lab.mywebhost.gr lab1.mywebhost.gr lab2.mywebhost.gr; do
    echo "════════════════════════════════════════"
    echo "Testing $server"
    echo "════════════════════════════════════════"

    ssh root@$server "
        echo '1. Version:'
        nftban --version

        echo ''
        echo '2. Health Check:'
        nftban health check

        echo ''
        echo '3. System Config:'
        cat /var/lib/nftban/config/system.conf | grep -E '(UID|GID)'

        echo ''
        echo '4. Stats:'
        nftban stats --summary

        echo ''
    "
done
```

---

## Troubleshooting

### Issue: "dnf: command not found"

Lab server might be using older RHEL/CentOS 7:
```bash
# Use yum instead
sudo yum install -y /tmp/nftban-0.10.0-1.el9.x86_64.rpm
```

### Issue: "Conflicts with firewalld"

Remove firewalld first:
```bash
sudo systemctl stop firewalld
sudo systemctl disable firewalld
sudo dnf remove -y firewalld
sudo dnf install -y /tmp/nftban-0.10.0-1.el9.x86_64.rpm
```

### Issue: "Permission denied" on /var/lib/nftban

Run health fix:
```bash
sudo nftban health fix all
```

### Issue: Different UID/GID across servers

This is **expected and correct**. Each server assigns its own UID/GID dynamically:
- lab.mywebhost.gr: nftban=994, nftban-cli=993
- lab1.mywebhost.gr: nftban=994, nftban-cli=993
- lab2.mywebhost.gr: nftban=993, nftban-cli=992

The `system.conf` file tracks the actual IDs on each server.

### Issue: Services not starting

Check logs:
```bash
sudo journalctl -xeu nftban.service
sudo journalctl -xeu nftban-health.service
```

### Issue: SELinux denials

Check AVC denials:
```bash
sudo ausearch -m avc -ts recent | grep nftban
```

If SELinux is blocking:
```bash
# Temporary: Set to permissive
sudo setenforce 0

# Check if issue is resolved
sudo nftban health check

# If resolved, create custom SELinux policy (future work)
```

---

## Uninstallation

### Remove Package (Keep Config)

```bash
sudo systemctl stop nftban.timer nftban-health.timer
sudo dnf remove -y nftban
```

Config files remain in `/etc/nftban/`.

### Complete Purge

```bash
# Stop services
sudo systemctl stop nftban.timer nftban-health.timer

# Remove package
sudo dnf remove -y nftban

# Delete nftables rules
sudo nft delete table inet nftban

# Remove all data
sudo rm -rf /var/lib/nftban
sudo rm -rf /var/cache/nftban
sudo rm -rf /var/log/nftban
sudo rm -rf /etc/nftban

# Remove user/group (optional)
sudo userdel nftban
sudo groupdel nftban-cli
```

---

## Quick Commands Reference

### One-Liners for Lab Testing

**Install on all labs:**
```bash
for server in lab.mywebhost.gr lab1.mywebhost.gr lab2.mywebhost.gr; do
    ssh root@$server "dnf install -y /tmp/nftban-0.10.0-1.el9.x86_64.rpm"
done
```

**Health check on all labs:**
```bash
for server in lab.mywebhost.gr lab1.mywebhost.gr lab2.mywebhost.gr; do
    echo "=== $server ==="
    ssh root@$server "nftban health check"
done
```

**Stats on all labs:**
```bash
for server in lab.mywebhost.gr lab1.mywebhost.gr lab2.mywebhost.gr; do
    echo "=== $server ==="
    ssh root@$server "nftban stats --summary"
done
```

**Check UID/GID on all labs:**
```bash
for server in lab.mywebhost.gr lab1.mywebhost.gr lab2.mywebhost.gr; do
    echo "=== $server ==="
    ssh root@$server "cat /var/lib/nftban/config/system.conf | grep -E '(UID|GID)'"
done
```

---

## Testing in a New Clean Lab

To test RPM installation from scratch on a brand new Rocky Linux 9 server:

### 1. Provision New Lab VM

Requirements:
- Rocky Linux 9 minimal install
- 1 GB RAM minimum
- 10 GB disk space
- Root SSH access

### 2. Initial System Setup

```bash
# SSH to new lab
ssh root@new-lab.mywebhost.gr

# Update system
sudo dnf update -y

# Install basic tools (if minimal install)
sudo dnf install -y wget curl vim

# Verify nftables installed
nft --version
```

### 3. Copy and Install Package

```bash
# From dev machine
scp dist/packages/nftban-0.10.0-1.el9.x86_64.rpm root@new-lab.mywebhost.gr:/tmp/

# On new lab
ssh root@new-lab.mywebhost.gr
sudo dnf install -y /tmp/nftban-0.10.0-1.el9.x86_64.rpm
```

### 4. Verify Clean Install

```bash
# All these should pass
nftban --version                    # Shows v0.10.0
nftban health check                 # 0 issues
id nftban                           # User exists
getent group nftban-cli             # Group exists
systemctl status nftban.timer       # Unit loaded
ls -la /etc/nftban/                 # Config present
ls -la /var/lib/nftban/             # State dirs exist
```

### 5. Run Functional Tests

```bash
# Import feeds
sudo nftban feeds import --all

# Apply rules
sudo nftban apply

# Check nftables
sudo nft list table inet nftban

# Generate report
sudo nftban report generate --format json --output /tmp/report.json

# Enable services
sudo systemctl enable --now nftban.timer
sudo systemctl enable --now nftban-health.timer
```

---

## Docker Testing (Alternative)

If you want to test without touching production labs:

```bash
# Run Rocky Linux 9 container
docker run -it --rm --privileged \
  -v $(pwd)/dist/packages:/packages \
  rockylinux:9 /bin/bash

# Inside container
dnf install -y /packages/nftban-0.10.0-1.el9.x86_64.rpm
nftban --version
nftban health check
nftban stats --summary
```

---

## Summary Checklist

After package installation on any lab, verify:

- [ ] `nftban --version` shows correct version
- [ ] `nftban health check` shows 0 issues
- [ ] `id nftban` shows user exists with proper UID
- [ ] `getent group nftban-cli` shows group exists
- [ ] `/var/lib/nftban/config/system.conf` contains correct UID/GID
- [ ] `systemctl status nftban.timer` shows unit loaded
- [ ] `ls /etc/nftban/` shows config files present
- [ ] `ls /var/lib/nftban/` shows state directories with correct permissions
- [ ] `sudo nft list tables` shows `inet nftban` table (after apply)
- [ ] `nftban stats --summary` works without errors
- [ ] Services can be enabled with `systemctl enable nftban.timer`

---

## Additional Resources

- **Packaging Guide**: `docs/development/packaging.md`
- **Health System**: `docs/guides/health-diagnostics.md`
- **Permission Architecture**: `docs/architecture/permission-architecture.md`
- **Main Documentation**: `docs/guides/installation.md`
