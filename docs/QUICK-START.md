# NFTBan v0.10.0 - Quick Start Guide

**Get NFTBan running in 5 minutes**

---

## For Impatient Users

```bash
# Rocky Linux / AlmaLinux / Fedora
sudo dnf install -y nftban-0.10.0-1.el9.x86_64.rpm
sudo systemctl enable --now nftban-health.timer

# Ubuntu / Debian
sudo apt install ./nftban_0.10.0-1_amd64.deb
sudo systemctl enable --now nftban-health.timer

# Check health
nftban health check

# Done! 🎉
```

---

## Prerequisites

- Linux server (Rocky 9+, AlmaLinux 9+, Fedora 38+, Ubuntu 22.04+, Debian 12+)
- Root or sudo access
- Internet connection (for package download)

---

## Installation Methods

### Method 1: RPM Package (Recommended for RHEL-based)

```bash
# Download latest release
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.el9.x86_64.rpm

# Install
sudo dnf install -y ./nftban-0.10.0-1.el9.x86_64.rpm

# Enable auto-healing
sudo systemctl enable --now nftban-health.timer
```

### Method 2: DEB Package (Recommended for Debian-based)

```bash
# Download latest release
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban.ubuntu.amd64.deb

# Install
sudo apt install ./nftban_0.10.0-1_amd64.deb

# Enable auto-healing
sudo systemctl enable --now nftban-health.timer
```

### Method 3: From Source (Developers)

```bash
# Clone repository
git clone https://github.com/itcmsgr/nftban.git
cd nftban

# Build Go binaries (optional, for performance)
sudo dnf install golang  # or: sudo apt install golang-go
./scripts/build-go-binaries.sh

# Install from source
cd src
sudo ./install.sh
```

---

## Post-Installation Setup

### 1. Add Users to nftban-cli Group

Allow users to manage firewall services without sudo:

```bash
# Add user to nftban-cli group
sudo usermod -aG nftban-cli username

# User must re-login for group to take effect
```

**What this enables:**
- `systemctl start/stop/restart nftables` (no password)
- `systemctl start/stop/restart fail2ban` (no password)
- Security-scoped: Cannot manage other services

### 2. Enable Timers (Recommended)

```bash
# Auto-healing health checks (every hour)
sudo systemctl enable --now nftban-health.timer

# Permission audit (weekly, Sundays 02:00 AM)
sudo systemctl enable --now nftban-permissions-audit.timer
```

### 3. Verify Installation

```bash
# Check health
nftban health check

# Expected output:
# ✅ Binaries:      OK
# ✅ Permissions:   OK
# ✅ Services:      OK
# ✅ Modules:       OK
# ✅ Config:        OK
```

---

## Basic Usage

### Health Checks

```bash
# Full health check
nftban health check

# Fix issues automatically
nftban health fix all
```

### FHS Compliance

```bash
# Check filesystem hierarchy
nftban fhs check

# Fix permissions
nftban permissions enforce
```

### Service Management (as nftban-cli member)

```bash
# Manage nftables
systemctl start nftables
systemctl stop nftables
systemctl restart nftables

# Manage fail2ban
systemctl start fail2ban
systemctl restart fail2ban
```

---

## Configuration

### Main Config

**Location:** `/etc/nftban/nftban.conf`

```bash
# View config
sudo cat /etc/nftban/nftban.conf

# Customize (optional)
sudo cp /etc/nftban/nftban.conf /etc/nftban/nftban.conf.local
sudo vi /etc/nftban/nftban.conf.local
```

### Module Configs

**Location:** `/etc/nftban/conf.d/*.conf`

```bash
# List available modules
ls -la /etc/nftban/conf.d/

# Edit module config
sudo vi /etc/nftban/conf.d/ddos.conf
```

---

## Next Steps

### Optional: GeoIP Blocking

```bash
# Download GeoLite2 database
sudo mkdir -p /var/lib/nftban/geoip
cd /var/lib/nftban/geoip

# Get MaxMind license key from: https://www.maxmind.com/en/geolite2/signup
# Download GeoLite2-City.mmdb

# Test
/usr/lib/nftban/bin/nftban-geoip \
  --database /var/lib/nftban/geoip/GeoLite2-City.mmdb \
  --ip 8.8.8.8
```

### Optional: Threat Feeds

```bash
# Configure feed sources
sudo vi /etc/nftban/conf.d/feeds.conf

# Test feed processing
/usr/lib/nftban/bin/nftban-feeds \
  --input /tmp/threat-feed.txt \
  --output /tmp/processed.nft \
  --format nftables
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    NFTBan v0.10.0                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  🐧 Bash Shell Scripts (Core Logic)                        │
│  ├─ /usr/sbin/nftban           Main CLI                    │
│  ├─ /usr/lib/nftban/core/*.sh  Core modules               │
│  └─ /usr/lib/nftban/cli/*.sh   CLI commands               │
│                                                             │
│  ⚡ Go Binaries (High Performance)                          │
│  ├─ nftban-feeds   10-60x faster feed processing          │
│  └─ nftban-geoip   10-60x faster GeoIP lookups            │
│                                                             │
│  🔐 Polkit Integration (Group-Based Access)                │
│  └─ nftban-cli group → Manage nftables & fail2ban         │
│                                                             │
│  📊 Auto-Healing System                                     │
│  ├─ Health checks (hourly)                                │
│  ├─ Permission audit (weekly)                             │
│  └─ FHS compliance monitoring                             │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## Troubleshooting

### Issue: Health check shows permission errors

```bash
# Fix permissions automatically
sudo nftban permissions enforce

# Verify
nftban fhs check
```

### Issue: Cannot manage services as nftban-cli member

```bash
# Verify group membership
id username | grep nftban-cli

# If not in group, add user
sudo usermod -aG nftban-cli username

# User MUST re-login
su - username

# Test
systemctl restart nftables
```

### Issue: Go binaries not working

```bash
# Check if binaries exist
ls -la /usr/lib/nftban/bin/

# Test binaries
/usr/lib/nftban/bin/nftban-feeds --version
/usr/lib/nftban/bin/nftban-geoip --version

# If missing, reinstall package
sudo dnf reinstall nftban
```

---

## Key Locations

| Path | Purpose |
|------|---------|
| `/usr/sbin/nftban` | Main CLI binary |
| `/usr/lib/nftban/` | Application code and Go binaries |
| `/etc/nftban/` | Configuration files |
| `/var/lib/nftban/` | Runtime data and state |
| `/var/log/nftban/` | Log files |
| `/usr/share/polkit-1/rules.d/60-nftban-cli.rules` | Polkit authorization |

---

## Getting Help

- **Documentation:** https://github.com/itcmsgr/nftban/tree/main/docs
- **Issues:** https://github.com/itcmsgr/nftban/issues
- **Polkit Guide:** https://github.com/itcmsgr/nftban/blob/main/docs/guides/polkit-integration.md
- **Go Binaries:** https://github.com/itcmsgr/nftban/blob/main/docs/development/GO-BINARIES.md

---

## Security Notes

✅ **Safe Defaults**
- No sudo required for nftban-cli members
- Scope-limited service management (only nftables & fail2ban)
- File permissions enforced (root owns code/config)
- Auto-healing system monitors permissions

⚠️ **Important**
- Add only trusted users to nftban-cli group
- Review Polkit logs regularly: `journalctl -u polkit`
- Monitor permission changes: `journalctl -u nftban-permissions-audit.service`

---

**Version:** 0.10.0
**Last Updated:** 2025-10-30
**License:** MPL-2.0
