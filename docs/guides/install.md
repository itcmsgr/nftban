# Installation Guide

**Complete installation instructions for NFTBan v0.10.0**

This guide covers all installation methods, platform-specific instructions, post-install verification, and troubleshooting.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Install (Recommended)](#quick-install-recommended)
- [From Source (Git)](#from-source-git)
- [Manual Installation](#manual-installation)
- [Platform-Specific Instructions](#platform-specific-instructions)
- [Post-Install Verification](#post-install-verification)
- [Configuration](#configuration)
- [Uninstallation](#uninstallation)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

Before installing NFTBan, ensure your system meets these requirements:

### Operating System

NFTBan v0.10.0 requires a modern Linux distribution with:

- **Linux Kernel**: 5.10 or higher (5.15+ recommended)
- **Supported Distributions**:
  - Rocky Linux 9+
  - AlmaLinux 9+
  - Fedora 38+
  - Ubuntu 22.04 LTS+
  - Debian 12 (Bookworm)+
  - openSUSE Leap 15.5+
  - Other modern Linux distributions with kernel 5.10+

### Required Packages

NFTBan requires these packages to be installed:

| Package | Minimum Version | Purpose |
|---------|----------------|---------|
| **nftables** | 1.0.0+ | Modern firewall (replaces iptables) |
| **systemd** | 250+ | Service management and timers |
| **bash** | 5.0+ | Shell scripting |
| **jq** | 1.6+ | JSON processing |
| **curl** or **wget** | Latest | Feed downloads |
| **fail2ban** | 0.11+ | Intrusion prevention (optional but recommended) |

### System Requirements

- **CPU**: Any modern CPU (x86_64, ARM64 supported)
- **RAM**: 512 MB minimum (1 GB+ recommended)
- **Disk Space**: 100 MB for installation + 500 MB for feeds and logs
- **Privileges**: Root or sudo access required
- **Network**: Internet connection for installation and feed updates

### Check Your System

Run this command to verify your system meets the requirements:

```bash
# Check kernel version (need 5.10+)
uname -r

# Check nftables (need 1.0.0+)
nft --version

# Check systemd (need 250+)
systemctl --version | head -1

# Check bash (need 5.0+)
bash --version | head -1
```

**Example output:**
```
5.15.0-89-generic           ✓ Kernel 5.15+
nftables v1.0.5             ✓ nftables 1.0.5
systemd 252 (252.4-1)       ✓ systemd 252
GNU bash, version 5.2.15    ✓ bash 5.2
```

---

## Quick Install (Recommended)

The fastest way to install NFTBan is using the official installer script.

### One-Line Install

```bash
curl -sSL https://nftban.com/install.sh | sudo bash
```

**What this does:**
1. Downloads the latest stable NFTBan v0.10.0
2. Installs all required dependencies
3. Creates FHS-compliant directory structure
4. Installs all modules and CLI commands
5. Sets up systemd services
6. Configures initial security profile

**Expected output:**
```
Installing NFTBan v0.10.0...
✓ Created system user: nftban
✓ Created group: nftban-cli
✓ Directories created
✓ Code installed
✓ Installed nftban.conf
✓ Configuration installed (permissions set for nftban-cli group)
✓ Systemd integration installed
  Enable with: systemctl enable nftban.timer
✓ Logrotate configured
✓ Bash completion installed

╔════════════════════════════════════════════════════════════╗
║  NFTBan v0.10.0 Installation Complete!                    ║
╚════════════════════════════════════════════════════════════╝

Next steps:
  1. Review config: /etc/nftban/nftban.conf
  2. Customize (optional): /etc/nftban/nftban.conf.local
  3. Enable service: systemctl enable --now nftban.timer
  4. Check status: nftban status
```

**Installation time**: 30-60 seconds

### Verify Install Script First (Security Best Practice)

If you want to review the installer before running it:

```bash
# Download the installer
curl -sSL https://nftban.com/install.sh -o /tmp/nftban-install.sh

# Review it
less /tmp/nftban-install.sh

# Run it when satisfied
sudo bash /tmp/nftban-install.sh
```

---

## From Source (Git)

Install from the official Git repository for the latest development version or to contribute.

### Step 1: Clone Repository

```bash
# Clone the repository
git clone https://github.com/nftban/nftban.git
cd nftban

# Switch to stable branch (recommended)
git checkout v0.10.0

# Or use development branch (latest features, may be unstable)
git checkout main
```

### Step 2: Review the Installer

```bash
# Read the installer script
cat install.sh

# Check what will be installed
grep -E "^(install|cp)" install.sh
```

### Step 3: Run Installer

```bash
sudo ./install.sh
```

**Expected output:** Same as quick install above.

### Step 4: Verify Installation

```bash
# Check NFTBan is installed
which nftban
nftban --version

# Run health check
sudo nftban health check
```

---

## Manual Installation

For advanced users who want full control over the installation process.

### Step 1: Create System User and Group

```bash
# Create nftban system user
sudo useradd -r -s /usr/sbin/nologin -d /nonexistent nftban

# Create nftban-cli group
sudo groupadd nftban-cli

# Add your user to nftban-cli group (optional, for CLI access)
sudo usermod -aG nftban-cli $(whoami)
```

### Step 2: Create Directory Structure

```bash
# /usr directories (code)
sudo install -d -o root -g root -m 0755 /usr/lib/nftban
sudo install -d -o root -g root -m 0755 /usr/share/nftban

# /etc directories (configuration)
sudo install -d -o root -g root -m 0750 /etc/nftban
sudo install -d -o root -g root -m 0750 /etc/nftban/{conf.d,feeds.d,rules.d}
sudo install -d -o root -g root -m 0700 /etc/nftban/secrets.d

# /var directories (data)
sudo install -d -o nftban -g nftban -m 0750 /var/lib/nftban/{state,snapshots,feeds,keyring,backup,reports,metrics}
sudo install -d -o nftban -g nftban -m 0750 /var/cache/nftban/{geoip,tmp}
sudo install -d -o nftban -g adm -m 0750 /var/log/nftban

# /run directory (runtime)
sudo install -d -o nftban -g nftban -m 0755 /run/nftban
```

### Step 3: Install Files

```bash
cd nftban/src

# Install CLI
sudo install -m 0755 -o root -g root usr/sbin/nftban /usr/sbin/nftban

# Install libraries and modules
sudo cp -a usr/lib/nftban/* /usr/lib/nftban/

# Install shared data
sudo cp -a usr/share/nftban/* /usr/share/nftban/
```

### Step 4: Install Configuration

```bash
# Main configuration
sudo install -m 0640 -o root -g root etc/nftban/nftban.conf /etc/nftban/nftban.conf

# Module configs
sudo cp -a etc/nftban/conf.d/* /etc/nftban/conf.d/

# User template
sudo install -m 0644 -o root -g root etc/nftban/nftban.conf.local.example /etc/nftban/nftban.conf.local.example

# Fix permissions for nftban-cli group
sudo chgrp -R nftban-cli /etc/nftban
sudo chmod 0750 /etc/nftban
sudo chmod 0640 /etc/nftban/nftban.conf
sudo chmod 0750 /etc/nftban/conf.d
sudo chmod 0640 /etc/nftban/conf.d/*.conf
sudo chmod 0750 /etc/nftban/{feeds.d,rules.d}
sudo chmod 0700 /etc/nftban/secrets.d
```

### Step 5: Install Systemd Integration

```bash
# Install systemd units
sudo cp usr/lib/systemd/system/*.service /usr/lib/systemd/system/
sudo cp usr/lib/systemd/system/*.timer /usr/lib/systemd/system/

# Install sysusers.d (creates user on boot)
sudo install -d -m 0755 /usr/lib/sysusers.d
sudo install -m 0644 packaging/sysusers.d/nftban.conf /usr/lib/sysusers.d/nftban.conf

# Install tmpfiles.d (creates /run/nftban on boot)
sudo install -d -m 0755 /usr/lib/tmpfiles.d
sudo install -m 0644 packaging/tmpfiles.d/nftban.conf /usr/lib/tmpfiles.d/nftban.conf

# Reload systemd
sudo systemctl daemon-reload
```

### Step 6: Install Logrotate

```bash
sudo install -m 0644 etc/logrotate.d/nftban /etc/logrotate.d/nftban
```

### Step 7: Install Polkit Rules

```bash
# Install Polkit authorization for nftban-cli group
sudo install -d -m 0755 /usr/share/polkit-1/rules.d
sudo install -m 0644 packaging/polkit-1/rules.d/60-nftban-cli.rules \
    /usr/share/polkit-1/rules.d/60-nftban-cli.rules

# Reload Polkit (usually automatic)
sudo systemctl restart polkit 2>/dev/null || true
```

**What this enables:**
- Members of `nftban-cli` group can manage nftables and fail2ban services
- No sudo required for service management
- See [Polkit Integration Guide](polkit-integration.md) for details

### Step 8: Install Shell Completions

```bash
# Bash completion
if [ -d /usr/share/bash-completion/completions ]; then
    sudo install -m 0644 usr/share/nftban/completions/nftban.bash \
        /usr/share/bash-completion/completions/nftban
fi

# Zsh completion
if [ -d /usr/share/zsh/site-functions ]; then
    sudo install -m 0644 usr/share/nftban/completions/_nftban \
        /usr/share/zsh/site-functions/_nftban
fi

# Fish completion
if [ -d /usr/share/fish/vendor_completions.d ]; then
    sudo install -m 0644 usr/share/nftban/completions/nftban.fish \
        /usr/share/fish/vendor_completions.d/nftban.fish
fi
```

### Step 9: SELinux Relabeling (if present)

```bash
# Only needed if SELinux is enabled
if command -v restorecon >/dev/null 2>&1; then
    sudo restorecon -Rv /etc/nftban /usr/sbin/nftban /usr/lib/nftban \
        /var/lib/nftban /var/log/nftban 2>/dev/null || true
fi
```

---

## Platform-Specific Instructions

### Rocky Linux / AlmaLinux / CentOS Stream

```bash
# Install required packages
sudo dnf install -y nftables systemd bash jq curl fail2ban

# Enable nftables
sudo systemctl enable --now nftables

# Install NFTBan
curl -sSL https://nftban.com/install.sh | sudo bash

# Configure firewalld integration (optional)
# If using firewalld, disable it first:
# sudo systemctl disable --now firewalld
```

### Fedora

```bash
# Install required packages
sudo dnf install -y nftables systemd bash jq curl fail2ban

# Enable nftables
sudo systemctl enable --now nftables

# Install NFTBan
curl -sSL https://nftban.com/install.sh | sudo bash
```

### Ubuntu / Debian

```bash
# Update package list
sudo apt update

# Install required packages
sudo apt install -y nftables systemd bash jq curl wget fail2ban

# Enable nftables
sudo systemctl enable --now nftables

# Disable ufw if present (conflicts with nftables)
sudo systemctl disable --now ufw

# Install NFTBan
curl -sSL https://nftban.com/install.sh | sudo bash
```

### openSUSE Leap

```bash
# Install required packages
sudo zypper install -y nftables systemd bash jq curl fail2ban

# Enable nftables
sudo systemctl enable --now nftables

# Install NFTBan
curl -sSL https://nftban.com/install.sh | sudo bash
```

### Arch Linux

```bash
# Install required packages
sudo pacman -S nftables systemd bash jq curl wget fail2ban

# Enable nftables
sudo systemctl enable --now nftables

# Install NFTBan (from AUR or source)
git clone https://github.com/nftban/nftban.git
cd nftban
sudo ./install.sh
```

---

## Post-Install Verification

After installation, verify everything is working correctly.

### Step 1: Check Installation Integrity

```bash
sudo nftban health check
```

**Expected output:**
```
NFTBan Health Check v0.10.0
═══════════════════════════

Running health checks...

✓ Binary Dependencies       PASS
  - nft (1.0.5): OK
  - systemctl (252): OK
  - jq (1.6): OK
  - curl (7.88.1): OK

✓ FHS Path Structure        PASS
  - /etc/nftban: OK
  - /usr/lib/nftban: OK
  - /usr/share/nftban: OK
  - /var/lib/nftban: OK
  - /var/log/nftban: OK

✓ File Permissions          PASS
  - nftban user exists: OK
  - nftban-cli group exists: OK
  - /etc/nftban ownership: OK

✓ Service Status            PASS
  - nftables.service: active
  - fail2ban.service: active

✓ Module Availability       PASS
  - 17/17 core modules found

✓ GeoIP Database            PASS
  - MaxMind GeoLite2: OK

══════════════════════════════════════
Overall Health: HEALTHY ✓
══════════════════════════════════════
```

If any checks fail, run with auto-fix:
```bash
sudo nftban health check --fix
```

### Step 2: Verify CLI Commands

```bash
# Check version
nftban --version

# List available commands
nftban help

# Check current profile
sudo nftban profile show
```

### Step 3: Check Module Installation

```bash
# List all modules
ls -la /usr/lib/nftban/core/

# Verify count (should be 17 modules)
ls /usr/lib/nftban/core/nftban_*.sh | wc -l
```

**Expected:** 17 modules

### Step 4: Check nftables Structure

```bash
# List nftables tables
sudo nft list tables

# Should show:
# inet nftban_runtime
# ip nftban_v4
# ip6 nftban_v6
```

### Step 5: Enable Systemd Services

```bash
# Enable the timer (periodic tasks)
sudo systemctl enable --now nftban.timer

# Check status
sudo systemctl status nftban.timer
```

---

## Configuration

### Initial Configuration

After installation, you may want to customize NFTBan:

#### 1. Choose Security Profile

Select a profile that matches your server type:

```bash
# List available profiles
sudo nftban profile list

# Apply a profile
sudo nftban profile set mixed  # Recommended default
```

See [Security Profiles Guide](security-profiles.md) for details on each profile.

#### 2. Create User Configuration

Create your own configuration file to override defaults:

```bash
# Copy the example
sudo cp /etc/nftban/nftban.conf.local.example /etc/nftban/nftban.conf.local

# Edit with your settings
sudo nano /etc/nftban/nftban.conf.local
```

**Example user config:**
```bash
# /etc/nftban/nftban.conf.local

# Enable DDoS protection
DDOS_SYNFLOOD_ENABLED="true"
DDOS_SYNFLOOD_RATE="100/second"

# Custom connection limits
CONNECTION_LIMIT_SSH="5"
CONNECTION_LIMIT_HTTP="100"

# Port scan detection
PORTSCAN_ENABLED="true"
PORTSCAN_THRESHOLD="5"
PORTSCAN_WINDOW="60"

# Logging
LOG_LEVEL="info"
LOG_BANNED_IPS="true"
```

#### 3. Whitelist Your IPs

Whitelist your management IPs to prevent accidental lockout:

```bash
# Whitelist your current IP
sudo nftban whitelist add $(curl -s ifconfig.me)

# Whitelist a range
sudo nftban whitelist add 203.0.113.0/24

# List whitelisted IPs
sudo nftban whitelist list
```

#### 4. Update Threat Feeds

Download the latest threat intelligence feeds:

```bash
sudo nftban feeds update
```

This downloads 14+ threat feeds and processes them with the Go binary (10-60x faster than bash).

#### 5. Apply Firewall Rules

Apply the firewall rules with commit-confirm safety:

```bash
sudo nftban-apply
```

Wait for the prompt, test connectivity, then confirm:
```bash
sudo nftban-confirm
```

See [Quick Start Guide](quickstart.md) for detailed first-time setup.

---

## Uninstallation

### Standard Uninstall (Preserve Data)

Remove NFTBan but keep configuration and data:

```bash
cd /path/to/nftban
sudo ./uninstall.sh
```

**What's removed:**
- Binaries (`/usr/sbin/nftban`)
- Libraries (`/usr/lib/nftban`)
- Shared data (`/usr/share/nftban`)
- Systemd units
- Cron jobs
- Logrotate config
- Shell completions

**What's preserved:**
- Configuration (`/etc/nftban/`)
- State data (`/var/lib/nftban/`)
- Logs (`/var/log/nftban/`)
- User and group

**Output:**
```
Uninstalling NFTBan v0.10.0...
✓ Services stopped
✓ Code removed
✓ Configuration and data preserved
  (Use --purge to remove everything)

╔════════════════════════════════════════════════════════════╗
║  NFTBan v0.10.0 Uninstalled (Data Preserved)              ║
╚════════════════════════════════════════════════════════════╝

Preserved:
  - Configuration: /etc/nftban/
  - State data: /var/lib/nftban/
  - Logs: /var/log/nftban/

To remove everything: ./uninstall.sh --purge
```

### Complete Removal (Purge)

Remove everything including configuration and data:

```bash
cd /path/to/nftban
sudo ./uninstall.sh --purge
```

**⚠️  WARNING**: This removes all configuration, bans, whitelists, and logs. Cannot be undone!

**What's removed:**
- Everything from standard uninstall
- Configuration (`/etc/nftban/`)
- State data (`/var/lib/nftban/`)
- Cache (`/var/cache/nftban/`)
- Logs (`/var/log/nftban/`)
- Runtime data (`/run/nftban/`)
- User and group (`nftban`, `nftban-cli`)

**Output:**
```
Uninstalling NFTBan v0.10.0...
Purging all data...
✓ Services stopped
✓ Code removed
✓ All data purged

╔════════════════════════════════════════════════════════════╗
║  NFTBan v0.10.0 Completely Removed (Purged)               ║
╚════════════════════════════════════════════════════════════╝
```

### Manual Cleanup (if uninstaller not available)

```bash
# Stop services
sudo systemctl disable --now nftban.timer nftban.service

# Remove files
sudo rm -f /usr/sbin/nftban
sudo rm -rf /usr/lib/nftban /usr/share/nftban
sudo rm -f /usr/lib/systemd/system/nftban*
sudo rm -f /etc/cron.d/nftban
sudo rm -f /etc/logrotate.d/nftban
sudo rm -f /usr/share/bash-completion/completions/nftban

# Remove data (optional)
sudo rm -rf /etc/nftban
sudo rm -rf /var/lib/nftban
sudo rm -rf /var/log/nftban
sudo rm -rf /var/cache/nftban

# Remove user/group (optional)
sudo userdel nftban
sudo groupdel nftban-cli

# Reload systemd
sudo systemctl daemon-reload
```

---

## Troubleshooting

### Issue: "nft: command not found"

**Cause**: nftables not installed

**Solution**:
```bash
# Rocky/AlmaLinux/Fedora
sudo dnf install -y nftables

# Ubuntu/Debian
sudo apt install -y nftables

# Enable nftables
sudo systemctl enable --now nftables
```

### Issue: "nftban: command not found"

**Cause**: NFTBan not in PATH or not installed

**Solution**:
```bash
# Check if installed
ls -la /usr/sbin/nftban

# If installed but not in PATH
sudo ln -sf /usr/sbin/nftban /usr/local/bin/nftban

# If not installed, reinstall
curl -sSL https://nftban.com/install.sh | sudo bash
```

### Issue: Health check fails with permission errors

**Cause**: Incorrect file ownership or permissions

**Solution**:
```bash
# Run health check with auto-fix
sudo nftban health check --fix

# Or manually fix permissions
sudo chown -R nftban:nftban /var/lib/nftban
sudo chown -R nftban:adm /var/log/nftban
sudo chgrp -R nftban-cli /etc/nftban
```

### Issue: Systemd service fails to start

**Cause**: Service file not found or systemd not reloaded

**Solution**:
```bash
# Check service file exists
ls -la /usr/lib/systemd/system/nftban*

# Reload systemd
sudo systemctl daemon-reload

# Try starting again
sudo systemctl start nftban.timer
sudo systemctl status nftban.timer
```

### Issue: Installation fails on SELinux systems

**Cause**: SELinux blocking installation

**Solution**:
```bash
# Temporarily set SELinux to permissive
sudo setenforce 0

# Run installation
sudo ./install.sh

# Restore SELinux enforcing
sudo setenforce 1

# Relabel files
sudo restorecon -Rv /etc/nftban /usr/sbin/nftban /usr/lib/nftban \
    /var/lib/nftban /var/log/nftban
```

### Issue: Conflict with firewalld or ufw

**Cause**: Multiple firewall managers running

**Solution**:
```bash
# Disable firewalld (Rocky/AlmaLinux/Fedora)
sudo systemctl disable --now firewalld

# Disable ufw (Ubuntu/Debian)
sudo systemctl disable --now ufw
sudo ufw disable

# Then install NFTBan
```

### Issue: Missing dependencies on minimal systems

**Cause**: Base packages not installed

**Solution**:
```bash
# Install all dependencies
# Rocky/AlmaLinux/Fedora
sudo dnf install -y nftables systemd bash jq curl wget fail2ban git

# Ubuntu/Debian
sudo apt install -y nftables systemd bash jq curl wget fail2ban git

# Then retry installation
```

### Issue: Go binaries not working (architecture mismatch)

**Cause**: Pre-built Go binaries not compatible with your architecture

**Solution**:
```bash
# Check your architecture
uname -m

# If using ARM or other non-x86_64, rebuild Go binaries
cd /path/to/nftban/src/usr/share/nftban/go-binaries
sudo go build -o nftban-feeds nftban-feeds.go
sudo go build -o nftban-geoip nftban-geoip.go
```

### Issue: Kernel too old

**Cause**: Kernel version < 5.10

**Solution**:
```bash
# Check kernel version
uname -r

# Upgrade system (distribution-specific)
# Rocky/AlmaLinux/Fedora
sudo dnf update kernel

# Ubuntu/Debian
sudo apt update && sudo apt upgrade

# Reboot to new kernel
sudo reboot
```

### Issue: Cannot create /run/nftban directory

**Cause**: tmpfiles.d not configured

**Solution**:
```bash
# Manually create runtime directory
sudo install -d -o nftban -g nftban -m 0755 /run/nftban

# Or install tmpfiles.d properly
sudo install -m 0644 packaging/tmpfiles.d/nftban.conf /usr/lib/tmpfiles.d/nftban.conf
sudo systemd-tmpfiles --create
```

---

## Directory Structure

After installation, NFTBan uses this FHS-compliant directory structure:

```
/
├── usr/
│   ├── sbin/
│   │   └── nftban                          # Main CLI command
│   │
│   ├── lib/
│   │   └── nftban/
│   │       ├── core/                       # 17 core modules
│   │       │   ├── nftban_banner.sh
│   │       │   ├── nftban_cloudflare.sh
│   │       │   ├── nftban_ddos.sh
│   │       │   ├── nftban_fail2ban.sh
│   │       │   ├── nftban_feeds.sh
│   │       │   ├── nftban_geoip.sh
│   │       │   ├── nftban_health.sh
│   │       │   ├── nftban_mail.sh
│   │       │   ├── nftban_module.sh
│   │       │   ├── nftban_nftables.sh
│   │       │   ├── nftban_port.sh
│   │       │   ├── nftban_portscan.sh
│   │       │   ├── nftban_profile.sh
│   │       │   ├── nftban_recovery.sh
│   │       │   ├── nftban_report.sh
│   │       │   ├── nftban_utils.sh
│   │       │   └── nftban_whitelist.sh
│   │       │
│   │       ├── cli/                        # 15 CLI commands
│   │       │   ├── cmd_ban.sh
│   │       │   ├── cmd_cloudflare.sh
│   │       │   ├── cmd_ddos.sh
│   │       │   ├── cmd_fail2ban.sh
│   │       │   ├── cmd_feeds.sh
│   │       │   ├── cmd_fhs.sh
│   │       │   ├── cmd_geoip.sh
│   │       │   ├── cmd_health.sh
│   │       │   ├── cmd_mail.sh
│   │       │   ├── cmd_module.sh
│   │       │   ├── cmd_nftables.sh
│   │       │   ├── cmd_port.sh
│   │       │   ├── cmd_portscan.sh
│   │       │   ├── cmd_profile.sh
│   │       │   └── cmd_whitelist.sh
│   │       │
│   │       ├── nft-runtime.nft             # Runtime table (temp bans)
│   │       └── vendor/                     # Third-party libraries
│   │
│   ├── share/
│   │   └── nftban/
│   │       ├── profiles/                   # 6 security profiles
│   │       │   ├── maximum.conf
│   │       │   ├── web-server.conf
│   │       │   ├── mail-server.conf
│   │       │   ├── database.conf
│   │       │   ├── mixed.conf
│   │       │   └── development.conf
│   │       │
│   │       ├── feeds/                      # Feed definitions
│   │       ├── go-binaries/                # Go binaries
│   │       │   ├── nftban-feeds            # Feed processor (10-60x faster)
│   │       │   └── nftban-geoip            # GeoIP lookup (instant)
│   │       │
│   │       ├── completions/                # Shell completions
│   │       │   ├── nftban.bash
│   │       │   ├── _nftban                 # Zsh
│   │       │   └── nftban.fish
│   │       │
│   │       └── docs/                       # Documentation
│   │
│   └── lib/systemd/system/
│       ├── nftban.service                  # Main service
│       └── nftban.timer                    # Periodic tasks
│
├── etc/
│   └── nftban/
│       ├── nftban.conf                     # Main config (don't edit)
│       ├── nftban.conf.local               # User overrides (edit this)
│       ├── baseline.nft                    # Emergency safe ruleset
│       │
│       ├── conf.d/                         # Module configs
│       │   ├── ddos.conf
│       │   ├── feeds.conf
│       │   ├── geoip.conf
│       │   ├── mail.conf
│       │   └── portscan.conf
│       │
│       ├── feeds.d/                        # Feed configs
│       ├── rules.d/                        # Custom rules
│       └── secrets.d/                      # API keys (mode 0700)
│
├── var/
│   ├── lib/nftban/                         # State data
│   │   ├── state/                          # Current state
│   │   ├── snapshots/                      # nftables snapshots
│   │   ├── feeds/                          # Downloaded feeds
│   │   ├── backup/                         # Backups
│   │   ├── reports/                        # Generated reports
│   │   └── metrics/                        # Metrics data
│   │
│   ├── cache/nftban/                       # Cache
│   │   ├── geoip/                          # MaxMind database
│   │   └── tmp/                            # Temporary files
│   │
│   └── log/nftban/                         # Logs
│       ├── nftban.log                      # Main log
│       ├── banned.log                      # Ban log
│       └── health.log                      # Health check log
│
└── run/nftban/                             # Runtime data (tmpfs)
    ├── nftban.pid                          # PID file
    └── locks/                              # Lock files
```

---

## Installation Verification Checklist

Use this checklist to verify your installation:

- [ ] System meets prerequisites (kernel 5.10+, nftables 1.0+, systemd 250+)
- [ ] NFTBan installed successfully (no errors during install)
- [ ] `nftban --version` shows v0.10.0
- [ ] `nftban help` shows all commands
- [ ] `sudo nftban health check` shows HEALTHY
- [ ] All 17 modules present in `/usr/lib/nftban/core/`
- [ ] All 3 nftables tables created (runtime, v4, v6)
- [ ] Security profile applied (`sudo nftban profile show`)
- [ ] Threat feeds updated (`sudo nftban feeds update`)
- [ ] Firewall rules applied (`sudo nftban-apply` + `sudo nftban-confirm`)
- [ ] Fail2Ban integrated (`sudo nftban fail2ban sync`)
- [ ] Systemd timer enabled (`systemctl status nftban.timer`)
- [ ] SSH still works (NOT locked out)
- [ ] Logs being written to `/var/log/nftban/`

---

## Next Steps

After installation, continue with:

1. **[Quick Start Guide](quickstart.md)** - Get NFTBan running in 5 minutes
2. **[Security Profiles](security-profiles.md)** - Choose and customize your security profile
3. **[Ban System Guide](ban-system.md)** - Learn how to ban/unban IPs
4. **[Threat Feeds](feeds.md)** - Manage threat intelligence feeds
5. **[Fail2Ban Integration](fail2ban.md)** - Set up automatic intrusion prevention
6. **[Health Diagnostics](health-diagnostics.md)** - Monitor system health

---

## Support

**Need help?**

- **Documentation**: [Full documentation](../index.md)
- **Troubleshooting**: [Common issues](troubleshoot.md)
- **GitHub Issues**: https://github.com/nftban/nftban/issues
- **Community**: https://nftban.com/community

---

**Installation complete!** → Continue to [Quick Start Guide](quickstart.md)
