# NFTBan Installation Guide

Complete installation instructions for all supported platforms.

---

## Table of Contents

1. [System Requirements](#system-requirements)
2. [Pre-Installation](#pre-installation)
3. [Installation Methods](#installation-methods)
   - [Package Manager (Recommended)](#package-manager-recommended)
   - [From Source](#from-source)
4. [Post-Installation Setup](#post-installation-setup)
5. [Verification](#verification)
6. [Troubleshooting](#troubleshooting)

---

## System Requirements

### Supported Operating Systems

**Enterprise Linux:**
- Rocky Linux 9 or later
- AlmaLinux 9 or later
- Fedora 38 or later
- RHEL 9 or later (compatible)

**Debian-based:**
- Ubuntu 22.04 LTS or later
- Debian 12 (Bookworm) or later

### Hardware Requirements

**Minimum:**
- CPU: 1 core
- RAM: 1 GB
- Disk: 10 GB free space
- Network: Internet connection (for threat feeds)

**Recommended:**
- CPU: 2+ cores
- RAM: 2+ GB
- Disk: 20+ GB free space
- SSD storage (for faster feed processing)

### Software Requirements

**Automatically installed as dependencies:**
- nftables 1.0.0 or later
- systemd 250 or later
- bash 5.0 or later
- jq 1.6 or later
- curl or wget
- Standard utilities (coreutils, gzip, tar, grep, sed, gawk)

**Optional but recommended:**
- fail2ban 0.11 or later (for automatic IP banning)
- logrotate (for log management)

### Network Requirements

**Outbound access required for:**
- GitHub (https://github.com) - Downloading releases
- MaxMind (https://www.maxmind.com) - GeoIP database
- Threat feed providers - Various URLs (configurable)

**Firewall considerations:**
- NFTBan manages nftables directly
- Incompatible with: firewalld, iptables, ufw
- Must have root/sudo access

---

## Pre-Installation

### 1. Update System

**Rocky/AlmaLinux/Fedora:**
```bash
sudo dnf update -y
```

**Ubuntu/Debian:**
```bash
sudo apt-get update
sudo apt-get upgrade -y
```

### 2. Remove Conflicting Software

NFTBan uses nftables and conflicts with other firewall managers.

**Remove firewalld (if installed):**
```bash
# Rocky/AlmaLinux/Fedora
sudo systemctl stop firewalld
sudo systemctl disable firewalld
sudo dnf remove -y firewalld

# Ubuntu/Debian
sudo systemctl stop firewalld
sudo systemctl disable firewalld
sudo apt-get remove -y firewalld
```

**Remove iptables (if using iptables-persistent):**
```bash
# Rocky/AlmaLinux/Fedora
sudo systemctl stop iptables
sudo systemctl disable iptables
sudo dnf remove -y iptables-services

# Ubuntu/Debian
sudo systemctl stop netfilter-persistent
sudo systemctl disable netfilter-persistent
sudo apt-get remove -y iptables-persistent
```

**Remove ufw (Ubuntu):**
```bash
sudo ufw disable
sudo apt-get remove -y ufw
```

### 3. Verify nftables Installed

```bash
nft --version
```

Expected output: `nftables v1.0.0` or later

If not installed:
```bash
# Rocky/AlmaLinux/Fedora
sudo dnf install -y nftables

# Ubuntu/Debian
sudo apt-get install -y nftables
```

### 4. Enable nftables Service

```bash
sudo systemctl enable nftables.service
sudo systemctl start nftables.service
sudo systemctl status nftables.service
```

---

## Installation Methods

### Package Manager (Recommended)

This is the recommended method as it:
- Installs all dependencies automatically
- Manages systemd services
- Creates users and groups
- Sets up correct permissions
- Enables easy updates

#### Rocky Linux / AlmaLinux / Fedora

**Step 1: Download latest release**

```bash
cd /tmp
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.x86_64.rpm
```

Or for ARM64:
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.aarch64.rpm
```

**Step 2: Verify checksum (optional but recommended)**

```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS 2>&1 | grep nftban-0.10.0-1.el9.x86_64.rpm
```

Expected: `nftban-0.10.0-1.el9.x86_64.rpm: OK`

**Step 3: Install package**

```bash
sudo dnf install -y nftban-0.10.0-1.el9.x86_64.rpm
```

This automatically:
- Installs all required dependencies
- Creates `nftban` system user and `nftban-cli` group
- Sets up systemd services
- Creates FHS-compliant directory structure
- Sets proper permissions

**Step 4: Verify installation**

```bash
nftban --version
```

Expected: `NFTBan v0.10.0`

#### Ubuntu / Debian

**Step 1: Download latest release**

```bash
cd /tmp
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.ubuntu.amd64.deb
```

Or for ARM64:
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.ubuntu.arm64.deb
```

**Step 2: Verify checksum (optional but recommended)**

```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS 2>&1 | grep nftban_0.10.0-1_amd64.deb
```

Expected: `nftban_0.10.0-1_amd64.deb: OK`

**Step 3: Install package**

```bash
sudo dpkg -i nftban_0.10.0-1_amd64.deb
```

If dependencies missing:
```bash
sudo apt-get install -f
```

This automatically:
- Installs all required dependencies
- Creates `nftban` system user and `nftban-cli` group
- Sets up systemd services
- Creates FHS-compliant directory structure
- Sets proper permissions

**Step 4: Verify installation**

```bash
nftban --version
```

Expected: `NFTBan v0.10.0`

### From Source

For development, testing, or unsupported distributions.

**Step 1: Clone repository**

```bash
cd ~
git clone https://github.com/itcmsgr/nftban.git
cd nftban
```

**Step 2: Checkout stable release**

```bash
git checkout v0.10.0
```

**Step 3: Run installer**

```bash
sudo ./install.sh
```

The installer:
- Checks for required dependencies
- Creates `nftban` user and `nftban-cli` group
- Copies files to FHS-compliant locations
- Sets up systemd services
- Configures permissions
- Generates `system.conf` with UID/GID

**Step 4: Verify installation**

```bash
nftban --version
sudo nftban health check
```

---

## Post-Installation Setup

### 1. Run Health Check

```bash
sudo nftban health check
```

This verifies:
- ✓ Binary dependencies (nft, systemctl, jq, etc.)
- ✓ FHS path structure
- ✓ File permissions
- ✓ System configuration (UID/GID)
- ✓ Service status
- ✓ Module availability
- ✓ GeoIP database (optional)

**Expected output:**
```
╔══════════════════════════════════════════╗
║        NFTBan Health Check v0.10.0       ║
╚══════════════════════════════════════════╝

✓ Binary Dependencies: OK
✓ FHS Path Structure: OK
✓ File Permissions: OK
✓ System Configuration: OK
✓ Service Status: OK
✓ Module Availability: OK
⚠ GeoIP Database: Missing (optional)

Overall Status: ✓ HEALTHY
✓ 0 issues found
```

If issues found:
```bash
sudo nftban health fix all
```

### 2. Review Default Configuration

```bash
sudo cat /etc/nftban/nftban.conf
```

**Important settings:**

```bash
# Enable NFTBan
ENABLED=1

# Commit-confirm timeout (seconds) - prevents lockout
COMMIT_CONFIRM_TIMEOUT=300

# Default action for blocked IPs
DEFAULT_ACTION="drop"

# Allowed ports (always open)
ALLOWED_PORTS="22 80 443"

# SSH port (if non-standard)
SSH_PORT=22

# Enable logging
LOGGING_ENABLED=1
LOG_LEVEL="INFO"
```

### 3. Create Local Configuration Override

To preserve custom settings during upgrades, use local override file:

```bash
sudo vim /etc/nftban/nftban.conf.local
```

Example:
```bash
# Local configuration overrides
# This file won't be overwritten during upgrades

# Allow additional ports
ALLOWED_PORTS="22 80 443 8080 3306"

# Non-standard SSH port
SSH_PORT=2222

# Enable geo-blocking
GEOBLOCK_SSH_ENABLED=1
GEOBLOCK_SSH_ALLOW="US,CA,GB,FR,DE"

# DDoS protection
DDOS_PROTECTION_ENABLED=1
DDOS_CONN_LIMIT=100
DDOS_RATE_LIMIT=50

# Email notifications
EMAIL_ENABLED=1
EMAIL_TO="admin@example.com"
EMAIL_FROM="nftban@$(hostname)"
```

### 4. Configure Threat Feeds (Optional)

Review available feeds:
```bash
sudo nftban feeds list
```

Edit feed configuration:
```bash
sudo vim /etc/nftban/feeds.d/custom.conf
```

Enable/disable feeds:
```bash
# Spamhaus DROP list
SPAMHAUS_DROP_ENABLED=1

# Abuse.ch threat feeds
ABUSE_CH_ENABLED=1

# Emerging Threats IPs
EMERGING_THREATS_ENABLED=1
```

### 5. Download GeoIP Database (if using geo-blocking)

```bash
# Requires MaxMind license key (free tier available)
sudo vim /etc/nftban/secrets.d/maxmind.conf
```

Add:
```bash
MAXMIND_LICENSE_KEY="your_license_key_here"
```

Download database:
```bash
sudo nftban geoip update
```

### 6. Apply Initial Rules

```bash
sudo nftban apply
```

**IMPORTANT:** This starts commit-confirm mode.

1. Rules are applied
2. SSH session remains open
3. You have 5 minutes to confirm rules work
4. Press **Enter** to confirm
5. If no confirmation, rules auto-rollback (prevents lockout!)

**Test in another terminal:**
```bash
# Open NEW SSH session to verify connectivity
ssh user@your-server
```

If successful, return to original terminal and press **Enter** to confirm.

### 7. Enable Automatic Updates

```bash
# Enable timers
sudo systemctl enable nftban.timer
sudo systemctl enable nftban-health.timer

# Start timers
sudo systemctl start nftban.timer
sudo systemctl start nftban-health.timer

# Verify status
sudo systemctl status nftban.timer nftban-health.timer
```

**What these do:**
- `nftban.timer` - Updates feeds and reapplies rules every 5 minutes
- `nftban-health.timer` - Runs health check hourly, auto-fixes issues

### 8. Add Your User to nftban-cli Group (Optional)

To run `nftban` commands without sudo:

```bash
sudo usermod -aG nftban-cli $USER
```

Log out and back in for group to take effect.

Now you can run:
```bash
nftban stats --summary
nftban feeds list
```

(Most commands still require sudo for security)

---

## Verification

### Verify Installation

```bash
# Check version
nftban --version

# Check health
sudo nftban health check

# View configuration
sudo nftban config show

# Check services
systemctl status nftban.timer
systemctl status nftban-health.timer

# View nftables rules
sudo nft list table inet nftban
```

### Verify Users and Groups

```bash
# Check nftban user
id nftban

# Check nftban-cli group
getent group nftban-cli

# View system configuration
cat /var/lib/nftban/config/system.conf
```

Expected:
```
NFTBAN_USER="nftban"
NFTBAN_UID=993
NFTBAN_GROUP="nftban"
NFTBAN_GID=994
NFTBAN_CLI_GROUP="nftban-cli"
NFTBAN_CLI_GID=992
```

(UID/GID values may differ - they're dynamically assigned)

### Verify File Permissions

```bash
# Check directories
ls -la /etc/nftban/
ls -la /var/lib/nftban/
ls -la /var/log/nftban/

# Run permission check
sudo nftban health check --category permissions
```

All files should be owned by `nftban:nftban` with appropriate permissions.

### Verify Functionality

```bash
# Generate test report
sudo nftban report generate --format json --output /tmp/test-report.json
cat /tmp/test-report.json

# View statistics
sudo nftban stats --summary

# Test ban/unban
sudo nftban ban 192.0.2.100 "Test ban"
sudo nftban stats --summary
sudo nftban unban 192.0.2.100
```

---

## Troubleshooting

### Installation Issues

**Issue: Package not found**

Verify you downloaded the correct package for your architecture:
```bash
uname -m
# x86_64 = amd64/x86_64
# aarch64 = arm64/aarch64
```

**Issue: Dependency conflicts**

Remove conflicting packages:
```bash
# RPM
sudo dnf remove firewalld iptables-services

# DEB
sudo apt-get remove firewalld iptables-persistent ufw
```

**Issue: Permission denied**

Ensure you're using sudo:
```bash
sudo dnf install nftban-0.10.0-1.el9.x86_64.rpm
```

### Post-Installation Issues

**Issue: Health check fails**

Run auto-fix:
```bash
sudo nftban health fix all
```

View specific issue:
```bash
sudo nftban health check --verbose
```

**Issue: Services not starting**

Check logs:
```bash
sudo journalctl -xeu nftban.service
sudo journalctl -xeu nftban-health.service
```

Restart services:
```bash
sudo systemctl restart nftban.service
sudo systemctl restart nftban-health.service
```

**Issue: Locked out of SSH**

If you didn't confirm rules:
1. Wait 5 minutes for auto-rollback
2. Or access via console and run: `sudo nftban rollback`

Prevent lockout:
- Always test in commit-confirm mode
- Keep SSH session open during apply
- Test new session before confirming
- Whitelist your management IP

**Issue: nftban command not found**

Verify installation:
```bash
which nftban
ls -la /usr/sbin/nftban
```

Check PATH:
```bash
echo $PATH
# Should include /usr/sbin
```

Add to PATH if needed:
```bash
export PATH="/usr/sbin:$PATH"
```

### SELinux Issues (Rocky/AlmaLinux/RHEL)

Check SELinux status:
```bash
getenforce
```

If enforcing and having issues:
```bash
# Check denials
sudo ausearch -m avc -ts recent | grep nftban

# Temporary: Set permissive
sudo setenforce 0

# Test if issue resolved
sudo nftban health check

# If resolved, create custom SELinux policy (future feature)
# For now, you can keep permissive mode for nftban
```

---

## Next Steps

After successful installation:

1. **[Quick Start Guide](quick-start.md)** - Get started in 5 minutes
2. **[User Guide](user-guide.md)** - Complete feature documentation
3. **[Configuration Reference](configuration.md)** - All config options
4. **[CLI Reference](cli-reference.md)** - Complete command reference
5. **[Security Best Practices](security-best-practices.md)** - Hardening tips

---

## Upgrading

See [Upgrade Guide](upgrade-guide.md) for detailed upgrade instructions.

Quick upgrade:

**RPM:**
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-0.11.0-1.el9.x86_64.rpm
sudo dnf upgrade -y nftban-0.11.0-1.el9.x86_64.rpm
nftban --version
```

**DEB:**
```bash
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban_0.11.0-1_amd64.deb
sudo dpkg -i nftban_0.11.0-1_amd64.deb
nftban --version
```

Configuration files are preserved during upgrades!

---

## Uninstallation

See [Uninstallation Guide](uninstallation.md) for detailed instructions.

Quick uninstall:

**RPM:**
```bash
sudo systemctl stop nftban.timer nftban-health.timer
sudo dnf remove nftban
```

**DEB:**
```bash
sudo systemctl stop nftban.timer nftban-health.timer
sudo apt-get remove nftban
# Or to purge config: sudo apt-get purge nftban
```

---

## Support

- **Documentation**: https://docs.nftban.com
- **GitHub Issues**: https://github.com/itcmsgr/nftban/issues
- **Discussions**: https://github.com/itcmsgr/nftban/discussions
- **Email**: support@nftban.com
