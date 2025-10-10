# nftban_init.sh

**Unified installation and maintenance script for nftban firewall management system**

[![Version](https://img.shields.io/badge/version-3.1.0-blue)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-CustomMIT--NoResale-lightgrey)](./LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/itcmsgr/nftban)
[![Shell](https://img.shields.io/badge/shell-bash-green)](https://www.gnu.org/software/bash/)

A comprehensive installer that prepares your system for nftban, automatically detects control panels, creates configuration templates, and installs all required dependencies with zero manual intervention.

---

## 🎯 What's New in v3.1.0

### 🔧 Architectural Improvements

**Clear Separation of Responsibilities:**

```
┌─────────────────────────────────────────────────────────┐
│ nftban_init.sh (THIS SCRIPT)                           │
│ • Installs packages                                     │
│ • Creates directory structure                           │
│ • Detects control panel                                 │
│ • Creates configuration TEMPLATES                       │
│ • Creates EMPTY .conf.local files                       │
└─────────────────────────────────────────────────────────┘
                          ↓
┌─────────────────────────────────────────────────────────┐
│ nftban_init_nftables_conf.sh                            │
│ • Reads templates                                       │
│ • Writes system .conf files                             │
│ • Merges with .conf.local customizations                │
│ • Generates nftables rules                              │
└─────────────────────────────────────────────────────────┘
```

### 🚀 Key Changes from v3.0.3

| Change | Why |
|--------|-----|
| **No longer writes to .conf.local** | Prevents conflicts with nftban_init_nftables_conf.sh |
| **Creates ALL templates** | Templates ready for any detected panel |
| **Empty .conf.local with instructions** | Clear guidance for user customizations |
| **Better completion summary** | Shows what's done vs what's next |

---

## 🚀 What This Script Does

### Phase 1: System Preparation

✅ **Package Installation**
- nftables (firewall engine)
- fail2ban (intrusion prevention)
- whois (IP lookup utilities)
- dnsutils/bind-utils (DNS tools)
- ipcalc (IPv4 validation)
- sipcalc (IPv6 validation)

✅ **Directory Structure**
```
/etc/nftban/
├── config/                    # Configuration files
│   ├── *.conf                 # System (auto-managed)
│   └── *.conf.local           # User (your customizations)
├── templates/
│   └── control-panels/        # Panel templates
│       ├── directadmin.conf
│       ├── cpanel.conf
│       ├── plesk.conf
│       └── generic.conf
├── scripts/                   # Management scripts
├── bin/                       # nftban CLI
├── logs/                      # Log files
└── backups/                   # Configuration backups
```

### Phase 2: Control Panel Detection

✅ **Automatic Detection**
- DirectAdmin → `/usr/local/directadmin/`
- cPanel/WHM → `/var/cpanel/`
- Plesk → `/usr/local/psa/`
- Generic → Fallback for any other setup

✅ **Template Creation**
- Creates templates for ALL control panels
- Detects which one is installed
- Templates include required ports for each panel

### Phase 3: Configuration Setup

✅ **Empty .conf.local Files**
- Created with helpful headers
- Include format examples
- Clear instructions for customization
- **Never overwritten** on re-runs

✅ **Ready for Next Step**
- All templates in place
- Directory structure complete
- User customization files ready
- Next: Run `nftban_init_nftables_conf.sh`

---

## 📋 Installation Methods

### Method 1: GitHub (Recommended)

**Advantages:**
- Always latest version
- Full script suite
- Easy updates
- Git history tracking

```bash
# Quick install
sudo ./nftban_init.sh --github -y

# With auto-update (keeps system current)
sudo ./nftban_init.sh --github -y --enable-auto-update

# Auto-update daily at 3:30 AM
sudo ./nftban_init.sh --github -y --enable-auto-update --daily-time "03:30"
```

### Method 2: ZIP Download

**Advantages:**
- Faster download
- No git dependency
- Works behind firewalls

```bash
# Basic ZIP install
sudo ./nftban_init.sh --zip -y

# ZIP with custom path
sudo ./nftban_init.sh --zip -y --target /opt/nftban
```

### Method 3: Local/Offline

**Advantages:**
- No internet required
- Basic functionality
- Manual configuration

```bash
# Local install (no repository sync)
sudo ./nftban_init.sh -y

# You'll need to manually configure everything
```

---

## 🎛️ Command-Line Options

### Installation Options

```bash
--github                 Clone/sync from GitHub repository
--zip                    Download and extract ZIP archive
--target DIR             Installation directory (default: /etc/nftban)
--branch NAME            Git branch to use (default: main)
-y                       Non-interactive mode (assume yes to all prompts)
```

### Control Panel Options

```bash
--skip-cp-detect         Skip automatic control panel detection
```

### Auto-Update Options

```bash
--enable-auto-update     Set up cron job for automatic updates
--remove-auto-update     Remove auto-update cron job
--auto-update-status     Show current auto-update configuration
--daily-time HH:MM       Schedule daily update at specific time
```

### Status & Information

```bash
--status                 Show installation status
--status --json          Show status in JSON format
--version                Show script version
-h, --help               Display help message
```

### Uninstall Options

```bash
--uninstall              Remove nftban installation
--uninstall --purge      Remove nftban + all logs and data
```

### Advanced Options

```bash
--beginner               More verbose, beginner-friendly output
--no-color               Disable colored output
--no-unicode             Use ASCII instead of Unicode icons
--quiet                  Suppress informational messages
--dry-run                Simulate actions without applying changes
```

---

## 💡 Usage Examples

### First-Time Installation

```bash
# Recommended: GitHub with auto-update
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | sudo bash -s -- --github -y --enable-auto-update

# Or download first
wget https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh
chmod +x nftban_init.sh
sudo ./nftban_init.sh --github -y
```

### Installation with DirectAdmin

```bash
# Install (DirectAdmin will be auto-detected)
sudo ./nftban_init.sh --github -y

# Output will show:
# ✅ DirectAdmin detected
# ✅ DirectAdmin template created
# ✅ Ready for nftban_init_nftables_conf.sh
```

### Installation with cPanel/WHM

```bash
# Install (cPanel will be auto-detected)
sudo ./nftban_init.sh --github -y

# Output will show:
# ✅ cPanel/WHM detected
# ✅ cPanel template created
# ✅ Ready for nftban_init_nftables_conf.sh
```

### Custom Installation Path

```bash
# Install to /opt/nftban instead of /etc/nftban
sudo ./nftban_init.sh --github -y --target /opt/nftban
```

### Offline/Air-Gapped Installation

```bash
# Download on internet-connected machine
wget https://github.com/itcmsgr/nftban/archive/refs/heads/main.zip

# Transfer to offline machine, then:
sudo ./nftban_init.sh --zip -y
```

### Update Existing Installation

```bash
# Re-run to update (safe - preserves your .conf.local files)
sudo ./nftban_init.sh --github -y

# Your customizations in .conf.local files are preserved
```

### Check Installation Status

```bash
# Human-readable status
sudo ./nftban_init.sh --status

# JSON output (for scripting)
sudo ./nftban_init.sh --status --json
```

### Auto-Update Management

```bash
# Enable auto-update (every 12 hours)
sudo ./nftban_init.sh --enable-auto-update

# Schedule daily at 3:30 AM
sudo ./nftban_init.sh --enable-auto-update --daily-time "03:30"

# Check auto-update status
sudo ./nftban_init.sh --auto-update-status

# Disable auto-update
sudo ./nftban_init.sh --remove-auto-update
```

### Uninstallation

```bash
# Remove nftban (keep logs)
sudo ./nftban_init.sh --uninstall -y

# Complete removal (including logs)
sudo ./nftban_init.sh --uninstall --purge -y
```

---

## 🎯 Complete Workflow Guide

### Step 1: Run nftban_init.sh (This Script)

```bash
sudo ./nftban_init.sh --github -y
```

**What happens:**
1. ✅ Installs all required packages
2. ✅ Creates directory structure
3. ✅ Detects control panel (e.g., DirectAdmin)
4. ✅ Creates templates for all panels
5. ✅ Creates empty .conf.local files
6. ✅ System is PREPARED but NOT YET CONFIGURED

**Result:**
```
Templates created:
  /etc/nftban/templates/control-panels/directadmin.conf
  /etc/nftban/templates/control-panels/cpanel.conf
  /etc/nftban/templates/control-panels/plesk.conf
  /etc/nftban/templates/control-panels/generic.conf

Empty user files created:
  /etc/nftban/config/*.conf.local (awaiting your customizations)
```

### Step 2: (Optional) Add Custom Ports

```bash
# Add custom application port
echo "8080T" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Add custom IP to whitelist
echo "192.168.1.100" >> /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local
```

### Step 3: Run nftban_init_nftables_conf.sh

```bash
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

**What happens:**
1. ✅ Detects control panel again
2. ✅ Reads template from `templates/control-panels/`
3. ✅ Writes system ports to `.conf` files
4. ✅ Reads your customizations from `.conf.local` files
5. ✅ Merges both sources
6. ✅ Generates nftables rules
7. ✅ Applies firewall configuration

**Result:**
```
System configured with:
  - DirectAdmin ports (from template)
  - Your custom ports (from .conf.local)
  - Firewall active and protecting your server
```

### Step 4: Configure fail2ban

```bash
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh
```

---

## 📁 File Structure Explained

### Configuration File Hierarchy

```
System Files (Auto-Managed)          User Files (Your Customizations)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
.conf (from control panel template) → .conf.local (preserved forever)
                                              ↓
                                    Merged by nftban_init_nftables_conf.sh
```

### Templates Directory

```
/etc/nftban/templates/control-panels/
├── directadmin.conf    # DirectAdmin: Ports 2222, 35000-35999, email, etc.
├── cpanel.conf         # cPanel/WHM: Ports 2082-2096, 3306, etc.
├── plesk.conf          # Plesk: Ports 8443, 8880, databases, etc.
└── generic.conf        # Generic: SSH, HTTP, HTTPS, DNS only
```

### Configuration Directory

```
/etc/nftban/config/
├── nftban-configuration-ipv4-ports-input-allow.conf         # System (auto)
├── nftban-configuration-ipv4-ports-input-allow.conf.local   # User
├── nftban-configuration-ipv4-ports-output-allow.conf        # System (auto)
├── nftban-configuration-ipv4-ports-output-allow.conf.local  # User
├── nftban-configuration-ipv6-ports-input-allow.conf         # System (auto)
├── nftban-configuration-ipv6-ports-input-allow.conf.local   # User
├── nftban-configuration-ipv6-ports-output-allow.conf        # System (auto)
├── nftban-configuration-ipv6-ports-output-allow.conf.local  # User
├── nftban-configuration-user-whitelist_ips.conf.local       # User IPs
└── nftban-configuration-user-blacklist_ips.conf.local       # User IPs
```

### Other Important Directories

```
/etc/nftban/
├── bin/nftban          # Command-line interface
├── scripts/            # Management scripts
│   ├── nftban_init_nftables_conf.sh
│   ├── nftban_init_fail2ban_conf.sh
│   └── nftban_auto_update.sh
├── logs/               # Symlink to /var/log/nftban
└── backups/            # Configuration backups
```

---

## 🎛️ Control Panel Support

### Pre-configured Panels

#### DirectAdmin

**Auto-detected at:** `/usr/local/directadmin/`

**Default Ports:**
- Web Interface: 2222
- FTP: 20-21, 35000-35999 (passive)
- Email: 25, 110, 143, 465, 587, 993, 995
- DNS: 53

**Template:** `directadmin.conf`

#### cPanel/WHM

**Auto-detected at:** `/var/cpanel/`

**Default Ports:**
- cPanel: 2082 (HTTP), 2083 (HTTPS)
- WHM: 2086 (HTTP), 2087 (HTTPS)
- Webmail: 2095 (HTTP), 2096 (HTTPS)
- Services: 2077, 2078, 2089
- MySQL: 3306
- Email: Standard ports

**Template:** `cpanel.conf`

#### Plesk

**Auto-detected at:** `/usr/local/psa/`

**Default Ports:**
- Plesk Panel: 8443 (HTTPS), 8880 (HTTP)
- MySQL: 3306
- PostgreSQL: 5432
- Email: Standard ports
- FTP: 20-21

**Template:** `plesk.conf`

#### Generic (No Panel)

**Used when:** No panel detected

**Default Ports:**
- SSH: 22 (auto-detected)
- HTTP: 80
- HTTPS: 443
- SMTP: 25
- DNS: 53

**Template:** `generic.conf`

### Customizing Templates

```bash
# Edit template before first configuration
sudo nano /etc/nftban/templates/control-panels/directadmin.conf

# Change ports in template
TCP_IN = "20,21,22,25,53,80,443,2222,8080,35000-35999"

# Then run nftban_init_nftables_conf.sh to apply
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

---

## 🔧 Configuration Examples

### Example 1: Adding Custom Web Server Port

```bash
# Add port 8080 for custom application
echo "8080T" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Apply changes
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

### Example 2: Whitelisting Office IP

```bash
# Add your office IP to whitelist
echo "203.0.113.100" >> /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local
echo "# Office IP" >> /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local

# Apply changes
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

### Example 3: Opening Port Range for Application

```bash
# Open ports 3000-3010 for development
cat >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local <<EOF
# Development servers
3000T
3001T
3002T
3003T
3004T
3005T
EOF

# Apply changes
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

### Example 4: Mixed Protocols

```bash
# Custom application using both TCP and UDP
echo "9000B" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Apply changes
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

---

## 🛠️ Troubleshooting

### Installation Issues

#### Package Manager Not Detected

```bash
# Manually install dependencies first
# Debian/Ubuntu
sudo apt-get install -y nftables fail2ban whois dnsutils ipcalc

# RHEL/CentOS/Rocky/AlmaLinux
sudo dnf install -y epel-release
sudo dnf install -y nftables fail2ban whois bind-utils ipcalc sipcalc

# Then run installer
sudo ./nftban_init.sh --github -y
```

#### GitHub Connection Failed

```bash
# Test GitHub connectivity
curl -I https://github.com

# If blocked, use ZIP method instead
sudo ./nftban_init.sh --zip -y
```

#### EPEL Repository Issues (RHEL-based)

```bash
# Manually install EPEL
sudo dnf install -y epel-release

# Or download directly
sudo dnf install -y https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm

# Then re-run installer
sudo ./nftban_init.sh --github -y
```

#### Permission Denied

```bash
# Must run as root
sudo ./nftban_init.sh --github -y

# Check you are root
id
# Should show: uid=0(root)
```

### Control Panel Detection Issues

#### Wrong Panel Detected

```bash
# Skip auto-detection and configure manually
sudo ./nftban_init.sh --github -y --skip-cp-detect

# Then edit the appropriate template
sudo nano /etc/nftban/templates/control-panels/generic.conf
```

#### Panel Not Detected

```bash
# Check panel installation
ls -la /usr/local/directadmin/  # DirectAdmin
ls -la /var/cpanel/             # cPanel
ls -la /usr/local/psa/          # Plesk

# If panel exists but not detected, file an issue
# Manual workaround: edit generic.conf
sudo nano /etc/nftban/templates/control-panels/generic.conf
```

### Configuration Issues

#### .conf.local Files Not Found

```bash
# Re-run installer to recreate them
sudo ./nftban_init.sh --github -y

# Files should be in:
ls -la /etc/nftban/config/*.conf.local
```

#### Changes Not Applied

```bash
# After editing .conf.local, always run:
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Verify changes
sudo nft list ruleset | grep -i dport
```

#### Template Changes Not Working

```bash
# 1. Edit template
sudo nano /etc/nftban/templates/control-panels/directadmin.conf

# 2. MUST re-run nftables init to apply
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Templates are read every time by nftban_init_nftables_conf.sh
```

### Auto-Update Issues

#### Cron Not Running

```bash
# Check cron service
sudo systemctl status cron     # Debian/Ubuntu
sudo systemctl status crond    # RHEL/CentOS

# Start if not running
sudo systemctl start cron
sudo systemctl enable cron

# Verify cron entry
crontab -l | grep nftban
```

#### Updates Not Happening

```bash
# Check auto-update status
sudo ./nftban_init.sh --auto-update-status

# Manually test update script
sudo /etc/nftban/scripts/nftban_auto_update.sh

# Check logs
sudo tail -f /var/log/nftban/nftban_init_*.log
```

### Common Errors

#### "Another instance is already running"

This is from nftban_init_nftables_conf.sh, not this script.

```bash
# Remove lock file
sudo rm -f /var/run/nftban_init.lock

# Then retry
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

#### "nftban command not found"

```bash
# Check symlink
ls -la /usr/local/bin/nftban

# Recreate if missing
sudo ln -sf /etc/nftban/bin/nftban /usr/local/bin/nftban

# Verify PATH
echo $PATH | grep -q /usr/local/bin || export PATH=$PATH:/usr/local/bin
```

#### Port Already in Use

```bash
# Check what's using the port
sudo netstat -tulpn | grep :2222

# Or with ss
sudo ss -tulpn | grep :2222

# Adjust configuration as needed
```

---

## 📊 Auto-Update System

### How Auto-Update Works

```
Cron Job Schedule
       ↓
Runs: /etc/nftban/scripts/nftban_auto_update.sh
       ↓
Git Pull Latest Changes
       ↓
Updates Scripts, Templates, CLI
       ↓
Your .conf.local Files Untouched
```

### Auto-Update Schedules

#### Every 12 Hours (Default)

```bash
sudo ./nftban_init.sh --enable-auto-update

# Cron entry created:
# 0 */12 * * * /etc/nftban/scripts/nftban_auto_update.sh
```

#### Daily at Specific Time

```bash
# Update daily at 3:30 AM
sudo ./nftban_init.sh --enable-auto-update --daily-time "03:30"

# Cron entry created:
# 30 3 * * * /etc/nftban/scripts/nftban_auto_update.sh
```

### Managing Auto-Update

```bash
# Check status
sudo ./nftban_init.sh --auto-update-status

# Example output:
# Auto-update via crontab: ENABLED (1 entry)
#   • 0 */12 * * * /etc/nftban/scripts/nftban_auto_update.sh

# Disable auto-update
sudo ./nftban_init.sh --remove-auto-update

# Re-enable with different schedule
sudo ./nftban_init.sh --enable-auto-update --daily-time "02:00"
```

### Manual Update

```bash
# Update manually anytime
cd /etc/nftban
sudo git pull
```

---

## 🔍 Verification & Testing

### Verify Installation

```bash
# Check installation status
sudo ./nftban_init.sh --status

# Expected output:
# nftban path: /etc/nftban
# nftables: v1.0.x
# fail2ban: v1.0.x

# Check directory structure
tree -L 2 /etc/nftban

# Check templates
ls -la /etc/nftban/templates/control-panels/

# Check configuration files
ls -la /etc/nftban/config/*.conf.local
```

### Verify Control Panel Detection

```bash
# View installation log
sudo tail -50 /var/log/nftban/nftban_init_*.log | grep -i "detected"

# Should show something like:
# [INFO] DirectAdmin detected
# [INFO] DirectAdmin template ready
```

### Verify Packages

```bash
# Check installed packages
nft --version
fail2ban-client --version
whois --version

# Check package installation
dpkg -l | grep -E 'nftables|fail2ban|whois'  # Debian/Ubuntu
rpm -qa | grep -E 'nftables|fail2ban|whois'  # RHEL/CentOS
```

### Test nftban CLI

```bash
# Test basic command
nftban --help

# Should show help message
# If not, check symlink:
ls -la /usr/local/bin/nftban
```

---

## ⚙️ Technical Details

**Script Version:** 3.1.0  
**Shell:** Bash 4.0+  
**Dependencies:** `bash`, `curl` or `wget`, `git` (optional)  
**Privileges:** Must run as root (sudo)

### Compatibility Matrix

| Distribution | Version | Package Manager | Status |
|--------------|---------|-----------------|--------|
| Debian | 10+ | apt-get | ✅ Fully Supported |
| Ubuntu | 20.04+ | apt-get | ✅ Fully Supported |
| CentOS | 8+ | dnf/yum | ✅ Fully Supported |
| AlmaLinux | 8+ | dnf | ✅ Fully Supported |
| Rocky Linux | 8+ | dnf | ✅ Fully Supported |
| RHEL | 8+ | dnf/yum | ✅ Fully Supported |
| Fedora | 35+ | dnf | ✅ Fully Supported |
| openSUSE | Leap 15+ | zypper | ✅ Fully Supported |
| Alpine Linux | 3.15+ | apk | ✅ Fully Supported |

### Package Dependencies

**Core Requirements:**
- nftables (firewall engine)
- fail2ban (intrusion prevention)
- whois (IP information)
- ipcalc (IPv4 validation)

**Optional but Recommended:**
- sipcalc (IPv6 validation)
- dnsutils or bind-utils (DNS tools)
- git (for GitHub installation method)

### Performance Characteristics

- **Installation time**: 30-120 seconds (depends on internet speed)
- **Disk usage**: ~50 MB (with full repository)
- **Memory usage**: < 10 MB during installation
- **CPU usage**: Minimal

### Security Considerations

- ✅ All installations logged to `/var/log/nftban/`
- ✅ Automatic backups before any changes
- ✅ Lock file prevents concurrent runs
- ✅ No services auto-started (manual control)
- ✅ Root privileges required (prevents unauthorized changes)
- ✅ SELinux compatible (auto-sets contexts)

---

## 🔄 Upgrade Path

### From v3.0.x to v3.1.0

```bash
# Simply re-run the installer
sudo ./nftban_init.sh --github -y

# Your customizations are safe:
# ✅ .conf.local files preserved
# ✅ Backups created automatically
# ✅ Can rollback if needed
```

### Version Compatibility

| nftban_init.sh | nftban_init_nftables_conf.sh | Compatible? |
|----------------|------------------------------|-------------|
| v3.1.0 | v2.3.0 | ✅ Yes (Recommended) |
| v3.1.0 | v2.2.0 | ⚠️ Partial (may have conflicts) |
| v3.0.3 | v2.3.0 | ❌ No (conflicts with .conf.local) |

**Recommendation:** Always use matching versions.

---

## 📜 License

**Custom MIT-NoResale License v1.1**

```
MIT License with Non-Commercial Restriction

Copyright (c) 2024 Antonios Voulvoulis - ITCMS Team

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to use
the Software for personal or commercial purposes, subject to the following:

✅ Use (personal and commercial)
✅ Copy
✅ Modify
✅ Merge
✅ Publish
✅ Distribute

With the following conditions:

1. Attribution: The above copyright notice and this permission notice shall be
   included in all copies or substantial portions of the Software.

2. Non-Resale: The Software, or any modified version, may NOT be sold,
   sublicensed, or offered as a paid product without explicit written
   permission from the copyright holder.

3. No Warranty: THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND.
```

**SPDX:** `LicenseRef-CustomMIT-NoResale-1.1`

See [LICENSE.md](./LICENSE.md) for full legal text.

---

## 🤝 Contributing

We welcome contributions!

### Reporting Issues

**Before reporting:**
1. Check [existing issues](https://github.com/itcmsgr/nftban/issues)
2. Review troubleshooting section
3. Collect relevant information

**Required information:**
- Operating system and version
- Control panel (if applicable)
- Script version (`./nftban_init.sh --version`)
- Installation method (GitHub/ZIP/local)
- Complete error message
- Installation log (`/var/log/nftban/nftban_init_*.log`)

### Pull Requests

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Test on at least 2 different distributions
4. Test with and without control panels
5. Update documentation
6. Commit with clear messages
7. Submit pull request

### Adding New Control Panel Support

To add support for a new panel:

1. **Create detection logic:**
```bash
# In detect_control_panel() function
elif [ -d "/path/to/newpanel/" ]; then
  log INFO "NewPanel detected"
  echo "newpanel"
  return 0
```

2. **Create template file:**
```bash
# Create: /etc/nftban/templates/control-panels/newpanel.conf
TCP_IN = "22,80,443,12345"
TCP_OUT = "22,80,443"
# ... etc
```

3. **Test thoroughly:**
- Fresh installation
- Update existing installation
- Template application
- Port validation

4. **Submit PR with:**
- Detection code
- Template file
- Documentation updates
- Test results

---

## 📞 Support

### Community Support

- **Issues:** [GitHub Issues](https://github.com/itcmsgr/nftban/issues)
- **Discussions:** [GitHub Discussions](https://github.com/itcmsgr/nftban/discussions)
- **Wiki:** [GitHub Wiki](https://github.com/itcmsgr/nftban/wiki)

### Professional Support

- **Author:** Antonios Voulvoulis (ITCMS Team)
- **Email:** support@itcms.gr
- **Website:** [https://itcms.gr](https://itcms.gr)

### Useful Resources

- [nftables Wiki](https://wiki.nftables.org/)
- [Fail2ban Documentation](https://fail2ban.readthedocs.io/)
- [DirectAdmin Forums](https://forum.directadmin.com/)
- [cPanel Documentation](https://docs.cpanel.net/)
- [Plesk Documentation](https://docs.plesk.com/)

---

## 🔗 Related Scripts

This is part of the **nftban** toolkit:

| Script | Purpose | Documentation |
|--------|---------|---------------|
| **nftban_init.sh** | **This script** - System preparation and template creation | This file |
| nftban_init_nftables_conf.sh | Firewall configuration and rule generation | [README_nftban_init_nftables_conf.md](README_nftban_init_nftables_conf.md) |
| nftban_init_fail2ban_conf.sh | Fail2ban integration setup | [README_fail2ban.md](README_fail2ban.md) |
| nftban | Main CLI for ban/unban operations | [README_nftban_cli.md](README_nftban_cli.md) |

---

## 📚 Additional Documentation

- [Architecture Overview](docs/ARCHITECTURE.md)
- [Two-Step Installation Process](docs/INSTALLATION.md)
- [Control Panel Integration](docs/CONTROL_PANELS.md)
- [Configuration File Format](docs/CONFIGURATION.md)
- [Troubleshooting Guide](docs/TROUBLESHOOTING.md)
- [Migration from v3.0.x](docs/MIGRATION.md)

---

## 🎓 Tutorials

### Quick Start Guides

1. [Installing nftban on Fresh Server](tutorials/01-fresh-install.md)
2. [DirectAdmin + nftban Setup](tutorials/02-directadmin.md)
3. [cPanel/WHM + nftban Setup](tutorials/03-cpanel.md)
4. [Adding Custom Ports](tutorials/04-custom-ports.md)
5. [Setting Up Auto-Update](tutorials/05-auto-update.md)

### Video Guides (Coming Soon)

- Complete installation walkthrough
- Control panel detection explained
- Customizing configurations
- Troubleshooting common issues

---

## ⭐ Star History

If you find this useful, please ⭐ star the repository!

[![Star History Chart](https://api.star-history.com/svg?repos=itcmsgr/nftban&type=Date)](https://star-history.com/#itcmsgr/nftban&Date)

---

## 📊 Statistics

![GitHub stars](https://img.shields.io/github/stars/itcmsgr/nftban?style=social)
![GitHub forks](https://img.shields.io/github/forks/itcmsgr/nftban?style=social)
![GitHub issues](https://img.shields.io/github/issues/itcmsgr/nftban)
![GitHub pull requests](https://img.shields.io/github/issues-pr/itcmsgr/nftban)
![GitHub last commit](https://img.shields.io/github/last-commit/itcmsgr/nftban)
![GitHub downloads](https://img.shields.io/github/downloads/itcmsgr/nftban/total)

---

## 🎯 Frequently Asked Questions

### Does this script configure my firewall?

**No.** This script only **prepares** your system:
- Installs packages
- Creates directory structure
- Detects control panel
- Creates templates

You must run `nftban_init_nftables_conf.sh` to actually configure the firewall.

### Will my custom ports be overwritten?

**No.** Your `.conf.local` files are **never overwritten**. They are for your customizations and are preserved forever.

### Can I run this script multiple times?

**Yes.** It's safe to re-run. Your customizations are preserved, and backups are created automatically.

### Does this work without a control panel?

**Yes.** If no panel is detected, a generic template is used with basic ports (SSH, HTTP, HTTPS).

### Do I need internet access?

- **GitHub method:** Yes (downloads from GitHub)
- **ZIP method:** Yes (downloads ZIP file)
- **Local method:** No (but limited functionality)

### Will services start automatically?

**No.** This script does NOT start or enable any services. You control when services start.

### Can I use this in production?

**Yes.** This script is production-ready and battle-tested. However, always test in a staging environment first.

---

<p align="center">
  <b>Made with ❤️ by <a href="https://itcms.gr">ITCMS Team</a></b><br>
  <sub>System preparation and template management for nftban</sub>
</p>

<p align="center">
  <a href="https://github.com/itcmsgr/nftban">🏠 Home</a> •
  <a href="https://github.com/itcmsgr/nftban/issues">🐛 Report Bug</a> •
  <a href="https://github.com/itcmsgr/nftban/discussions">💬 Discuss</a> •
  <a href="https://itcms.gr">🌐 Website</a>
</p>
