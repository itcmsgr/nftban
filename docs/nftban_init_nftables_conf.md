# nftban_init_nftables_conf.sh

**Single-table nftables configuration with automated control panel detection and Fail2ban integration**

[![Version](https://img.shields.io/badge/version-2.3.0-blue)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-CustomMIT--NoResale-lightgrey)](./LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/itcmsgr/nftban)
[![Shell](https://img.shields.io/badge/shell-bash-green)](https://www.gnu.org/software/bash/)

A production-ready Bash script that initializes a simplified, single-table nftables firewall architecture with **automatic control panel detection**, built-in support for Fail2ban integration, IP whitelisting/blacklisting, and automated validation.

---

## 🎯 What's New in v2.3.0

### 🎛️ Automatic Control Panel Detection

The script now **automatically detects and configures** popular control panels:

| Control Panel | Ports Auto-Configured | Detection Method |
|---------------|----------------------|------------------|
| **DirectAdmin** | Web (2222), FTP (20-21, 35000-35999), Email, DNS | `/usr/local/directadmin` |
| **cPanel/WHM** | cPanel (2082-2083), WHM (2086-2087), Webmail (2095-2096) | `/usr/local/cpanel` |
| **Plesk** | Plesk (8443, 8880), Email, FTP, Database | `/usr/local/psa` or `plesk` command |
| **Generic** | Basic services (SSH, HTTP/S, SMTP, DNS) | Fallback |

### 🔄 Smart Port Management

```
┌─────────────────────────────────────────────────────────┐
│ Control Panel Template → System .conf (auto-managed)    │
│            +                                             │
│ User Customizations    → .conf.local (preserved)        │
│            ↓                                             │
│        Final nftables Rules (merged)                    │
└─────────────────────────────────────────────────────────┘
```

- **System files** (.conf): Auto-generated from control panel templates on every run
- **User files** (.conf.local): Your custom ports/rules, never overwritten
- **Automatic merging**: Both sources combined seamlessly

---

## 🚀 What This Script Does

Creates and manages a **single nftables table** (`inet nftban_global`) with:

| Component | Purpose |
|-----------|---------|
| **8 IP Sets** | Whitelists, blacklists (user/system), and temporary bans (Fail2ban) |
| **2 Chains** | Input filtering (priority -150) and optional output filtering |
| **Control Panel Integration** | Auto-detects DirectAdmin, cPanel, Plesk and configures required ports |
| **Validation** | Multi-tier IP/port validation (ipcalc/sipcalc → nft -c → regex) |
| **Safety** | Auto-whitelists your IPs, SSH protection, rollback support |
| **Testing** | Built-in unit tests and dry-run modes |

### Created nftables Objects

```
table inet nftban_global {
  set whitelist_v4        # Never ban these IPv4 addresses
  set whitelist_v6        # Never ban these IPv6 addresses
  set user_blacklist_v4   # Manual permanent IPv4 bans
  set user_blacklist_v6   # Manual permanent IPv6 bans
  set system_blacklist_v4 # Bulk IPv4 bans (countries, ranges)
  set system_blacklist_v6 # Bulk IPv6 bans (countries, ranges)
  set temp_ban_v4         # Fail2ban temporary IPv4 bans (with timeout)
  set temp_ban_v6         # Fail2ban temporary IPv6 bans (with timeout)
  
  chain input { ... }     # Processes incoming traffic
  chain output { ... }    # Optional outbound filtering
}
```

**Priority order (input chain):**
1. Loopback → accept
2. Whitelist → accept
3. Blacklists → drop
4. Temp bans (Fail2ban) → drop
5. Established/related → accept
6. SSH → accept
7. User-defined ports (system + user merged) → accept
8. Custom CT rules → process

---

## 🚀 Quick Start

### Prerequisites

**Debian/Ubuntu:**
```bash
sudo apt install -y nftables ipcalc sipcalc fail2ban
sudo systemctl enable --now nftables
```

**RHEL/CentOS/AlmaLinux/Rocky/Fedora:**
```bash
sudo dnf install -y epel-release
sudo dnf install -y nftables ipcalc sipcalc fail2ban
sudo systemctl enable --now nftables
```

### Basic Usage

```bash
# Download script
curl -fsSL -O https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init_nftables_conf.sh
chmod +x nftban_init_nftables_conf.sh

# Run interactively (auto-detects control panel)
sudo ./nftban_init_nftables_conf.sh

# Or apply directly
sudo ./nftban_init_nftables_conf.sh --install-final
```

The script will:
1. ✅ **Detect** your control panel automatically
2. ✅ **Load** appropriate port configuration
3. ✅ **Merge** with your custom settings
4. ✅ **Validate** all entries
5. ✅ **Generate** optimized nftables rules

---

## 📋 Command-Line Options

```bash
Usage: nftban_init_nftables_conf.sh [options]

Configuration:
  --cloudflare [yes|no|auto]  Include Cloudflare IPs in whitelist (default: auto)
  --yes-cloudflare            Shortcut for --cloudflare yes
  --no-cloudflare             Shortcut for --cloudflare no
  -y                          Non-interactive mode (assume yes)

Execution:
  --install-final             Apply config to /etc/nftables.conf and activate
  --silent-auto               Silent mode with auto-confirmation
  
Validation & Testing:
  --validate-only             Validate config files without applying
  --dry-run                   Preview generated config without applying
  --test                      Syntax check only (nft -c), no changes
  --run-tests                 Run built-in unit tests and exit

Control Panel:
  --create-panel-templates    Create/update control panel configuration templates

Fail2ban:
  --generate-f2b-action       Generate Fail2ban action configuration

Help:
  -h, --help                  Show help message
```

---

## 💡 Usage Examples

### First-Time Setup

```bash
# Auto-detect control panel and apply configuration
sudo ./nftban_init_nftables_conf.sh --install-final -y

# The script will detect your control panel and configure everything automatically
```

### Control Panel Management

```bash
# Create example templates for all control panels
sudo ./nftban_init_nftables_conf.sh --create-panel-templates

# Edit your control panel's template
sudo nano /etc/nftban/config/templates/control-panels/directadmin.conf

# Re-run to apply changes
sudo ./nftban_init_nftables_conf.sh --install-final
```

### Test & Validate

```bash
# Run unit tests
sudo ./nftban_init_nftables_conf.sh --run-tests

# Validate existing configuration
sudo ./nftban_init_nftables_conf.sh --validate-only

# Syntax check only (no apply)
sudo ./nftban_init_nftables_conf.sh --test

# Preview generated config
sudo ./nftban_init_nftables_conf.sh --dry-run
```

### Generate & Apply

```bash
# Interactive mode
sudo ./nftban_init_nftables_conf.sh

# Apply without prompts
sudo ./nftban_init_nftables_conf.sh --install-final -y

# Silent install with Cloudflare IPs
sudo ./nftban_init_nftables_conf.sh --silent-auto --yes-cloudflare --install-final
```

### Fail2ban Integration

```bash
# Generate Fail2ban action files
sudo ./nftban_init_nftables_conf.sh --generate-f2b-action

# This creates:
# /etc/fail2ban/action.d/nftban-global.conf
# /etc/fail2ban/action.d/nftban-global-jail-example.conf
```

Then configure jails in `/etc/fail2ban/jail.local`:
```ini
[sshd]
enabled = true
banaction = nftban-global[name=sshd, set="temp_ban_v4"]

[nginx-http-auth]
enabled = true
banaction = nftban-global[name=nginx-auth, set="temp_ban_v4"]
```

---

## 🎛️ Control Panel Configuration

### How It Works

1. **Detection Phase**: Script checks for DirectAdmin, cPanel, or Plesk installations
2. **Template Loading**: Reads port configuration from `/etc/nftban/config/templates/control-panels/{panel}.conf`
3. **Conversion**: Converts comma-separated ports to nftban format
4. **Merging**: Combines with user customizations from `.conf.local` files
5. **Validation**: Ensures all ports are valid before inclusion

### Template File Format

Control panel templates use a simple key-value format:

```bash
# /etc/nftban/config/templates/control-panels/directadmin.conf

# TCP Input Ports (IPv4)
TCP_IN = "20,21,22,25,53,80,110,143,443,465,587,993,995,2222,35000-35999"

# TCP Output Ports (IPv4)
TCP_OUT = "20,21,22,25,53,80,110,113,443,587,993,995,2222"

# TCP Input Ports (IPv6)
TCP6_IN = "20,21,22,25,53,80,110,143,443,465,587,993,995,2222,35000-35999"

# TCP Output Ports (IPv6)
TCP6_OUT = "20,21,22,25,53,80,110,113,443,587,993,995,2222"

# UDP Input Ports (IPv4)
UDP_IN = "53"

# UDP Output Ports (IPv4)
UDP_OUT = "53"

# UDP Input Ports (IPv6)
UDP6_IN = "53"

# UDP Output Ports (IPv6)
UDP6_OUT = "53"

# Control Panel IP Addresses (optional, comma-separated)
IP_ADDRESS = "192.168.1.100,2001:db8::1"
```

### Pre-configured Templates

#### DirectAdmin
- Web interface: 2222
- FTP: 20-21, 35000-35999 (passive)
- Email: 25, 110, 143, 465, 587, 993, 995
- DNS: 53

#### cPanel/WHM
- cPanel: 2082 (HTTP), 2083 (HTTPS)
- WHM: 2086 (HTTP), 2087 (HTTPS)
- Webmail: 2095 (HTTP), 2096 (HTTPS)
- Additional: 2077, 2078, 2089
- Database: 3306 (MySQL)
- Email: Standard ports

#### Plesk
- Plesk Panel: 8443 (HTTPS), 8880 (HTTP)
- Database: 3306 (MySQL), 5432 (PostgreSQL)
- Email: Standard ports
- FTP: 20-21

#### Generic (Fallback)
- Basic services: SSH (22), HTTP (80), HTTPS (443), SMTP (25), DNS (53)

### Customizing Control Panel Configuration

```bash
# 1. Create templates if they don't exist
sudo ./nftban_init_nftables_conf.sh --create-panel-templates

# 2. Edit your panel's template
sudo nano /etc/nftban/config/templates/control-panels/directadmin.conf

# 3. Add custom ports (example: custom web server on 8080)
# Modify TCP_IN line:
TCP_IN = "20,21,22,25,53,80,110,143,443,465,587,993,995,2222,8080,35000-35999"

# 4. Re-run the script to apply
sudo ./nftban_init_nftables_conf.sh --install-final
```

---

## 📧 Configuration Files

### File Hierarchy

```
System Files (Auto-managed)          User Files (Your customizations)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━        ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
.conf (from control panel template) → .conf.local (preserved across runs)
                                              ↓
                                    Final merged nftables rules
```

### Configuration Files in `/etc/nftban/config/`

#### System Files (Auto-Generated, DO NOT EDIT)

| File | Purpose | Source |
|------|---------|--------|
| `nftban-configuration-ipv4-ports-input-allow.conf` | IPv4 input ports | Control panel template |
| `nftban-configuration-ipv4-ports-output-allow.conf` | IPv4 output ports | Control panel template |
| `nftban-configuration-ipv6-ports-input-allow.conf` | IPv6 input ports | Control panel template |
| `nftban-configuration-ipv6-ports-output-allow.conf` | IPv6 output ports | Control panel template |
| `nftban-configuration-system_whitelist_ips.conf` | System whitelist base | Control panel IPs + auto-detected |

#### User Files (Your Customizations, Preserved)

| File | Purpose |
|------|---------|
| `nftban-configuration-ipv4-ports-input-allow.conf.local` | Your custom IPv4 input ports |
| `nftban-configuration-ipv4-ports-output-allow.conf.local` | Your custom IPv4 output ports |
| `nftban-configuration-ipv6-ports-input-allow.conf.local` | Your custom IPv6 input ports |
| `nftban-configuration-ipv6-ports-output-allow.conf.local` | Your custom IPv6 output ports |
| `nftban-configuration-user-whitelist_ips.conf.local` | User-defined whitelist |
| `nftban-configuration-user-blacklist_ips.conf.local` | User-defined blacklist |
| `nftban-configuration-ipv4-blacklist_ips.conf.local` | System IPv4 blacklist |
| `nftban-configuration-ipv6-blacklist_ips.conf.local` | System IPv6 blacklist |
| `nftban-configuration-system_whitelist_ips.conf.local` | Auto-generated system whitelist |
| `nftban-nfttables-ct-ipv4.conf.local` | Custom IPv4 connection tracking rules |
| `nftban-nfttables-ct-ipv6.conf.local` | Custom IPv6 connection tracking rules |

#### Generated Files

| File | Purpose |
|------|---------|
| `nft_rules.conf.local` | Complete generated nftables configuration |
| `nftban-fail2ban-ip-whitelist.conf.local` | Combined whitelist for Fail2ban |

### Port Configuration Format

```bash
# Format: PORTRANGE?PROTOCOL
# Protocol: T=TCP, U=UDP, B=Both

22T            # TCP port 22 (SSH)
80-443B        # TCP+UDP ports 80-443
53U            # UDP port 53 (DNS)
3000-3010T     # TCP ports 3000-3010
8080B          # TCP+UDP port 8080
```

**Examples:**
```bash
# Web servers
80T            # HTTP
443T           # HTTPS
8080T          # Alternative HTTP

# Email
25T            # SMTP
110T           # POP3
143T           # IMAP
465T           # SMTPS
587T           # Submission
993T           # IMAPS
995T           # POP3S

# DNS
53U            # DNS queries
53T            # DNS zone transfers

# FTP
20T            # FTP data
21T            # FTP control
35000-35999T   # Passive FTP range

# Databases
3306T          # MySQL
5432T          # PostgreSQL

# Monitoring
161U           # SNMP
```

### IP Configuration Format

```bash
# IPv4
192.168.1.10              # Single IP
192.168.1.0/24            # CIDR notation
192.168.1.1-192.168.1.254 # Range (use with caution)

# IPv6
2001:db8::1               # Single IP
2001:db8::/48             # CIDR notation
2001:db8::1-2001:db8::ff  # Range
```

---

## 🧪 Features

### Multi-Tier IP Validation

The script uses a three-tier validation strategy:

1. **External tools** (preferred):
   - `ipcalc` for IPv4 validation
   - `sipcalc` for IPv6 validation
2. **nft -c validation**: Syntax check via nftables compiler (most reliable)
3. **Regex + bounds**: Strict fallback validation with RFC compliance

This ensures maximum compatibility while maintaining strict validation.

### Auto-Whitelisting

The script automatically adds to whitelist:
- ✅ All server interface IPs (IPv4/IPv6)
- ✅ Server's public IP (if detectable via external services)
- ✅ Current SSH connection IP (prevents lockout)
- ✅ Cloudflare IPs (optional)
- ✅ Control panel IPs (from template configuration)

### Safety Features

- 🔒 **Lock file**: Prevents concurrent runs
- 💾 **Automatic backups**: Before any changes
- ✅ **Syntax validation**: Before applying rules
- 🔄 **Rollback support**: Automatic on failure
- 🔑 **SSH protection**: Auto-detection of SSH port
- 🛡️ **Lockout prevention**: Your IP always whitelisted

### Testing & Validation

- **Unit tests**: Test IP/port validators and rule generators
- **Syntax check**: `nft -c` validation without applying
- **Dry run**: Preview generated configuration
- **Config validation**: Check all config files for errors
- **Detailed logging**: All operations logged to `/etc/nftban/logs/`

---

## 📊 Manual IP Management

### Adding IPs to Sets

```bash
# Whitelist IP (never ban)
sudo nft add element inet nftban_global whitelist_v4 { 192.168.1.10 }
sudo nft add element inet nftban_global whitelist_v6 { 2001:db8::1 }

# Whitelist CIDR range
sudo nft add element inet nftban_global whitelist_v4 { 192.168.1.0/24 }

# Blacklist IP (permanent)
sudo nft add element inet nftban_global user_blacklist_v4 { 203.0.113.45 }

# Temporary ban (1 hour)
sudo nft add element inet nftban_global temp_ban_v4 { 203.0.113.88 timeout 1h }

# Temporary ban (24 hours)
sudo nft add element inet nftban_global temp_ban_v4 { 203.0.113.99 timeout 24h }
```

### Removing IPs from Sets

```bash
# Remove from whitelist
sudo nft delete element inet nftban_global whitelist_v4 { 192.168.1.10 }

# Remove from blacklist
sudo nft delete element inet nftban_global user_blacklist_v4 { 203.0.113.45 }

# Remove temporary ban (unban immediately)
sudo nft delete element inet nftban_global temp_ban_v4 { 203.0.113.88 }
```

### Viewing Sets

```bash
# List all sets in the table
sudo nft list sets inet nftban_global

# View specific set contents
sudo nft list set inet nftban_global whitelist_v4
sudo nft list set inet nftban_global temp_ban_v4
sudo nft list set inet nftban_global user_blacklist_v4

# View sets with timeout information
sudo nft -a list set inet nftban_global temp_ban_v4
```

### Bulk Operations

```bash
# Flush temporary bans (unban all)
sudo nft flush set inet nftban_global temp_ban_v4
sudo nft flush set inet nftban_global temp_ban_v6

# Add multiple IPs at once
sudo nft add element inet nftban_global whitelist_v4 { 192.168.1.10, 192.168.1.11, 192.168.1.12 }

# Add with comments (nftables 0.9.3+)
sudo nft add element inet nftban_global temp_ban_v4 { 203.0.113.88 timeout 1h comment "\"Brute force attempt\"" }
```

---

## 🔍 Verification

### View Complete Configuration

```bash
# View entire nftban_global table
sudo nft list table inet nftban_global

# View with handle numbers (for deletion)
sudo nft -a list table inet nftban_global

# View in JSON format
sudo nft -j list table inet nftban_global
```

### View Specific Components

```bash
# View input chain rules
sudo nft list chain inet nftban_global input

# View output chain rules
sudo nft list chain inet nftban_global output

# Check if table exists
sudo nft list tables | grep nftban_global
```

### Monitoring Active Bans

```bash
# Count banned IPs
echo "IPv4 temp bans: $(sudo nft list set inet nftban_global temp_ban_v4 | grep -c 'expires')"
echo "IPv6 temp bans: $(sudo nft list set inet nftban_global temp_ban_v6 | grep -c 'expires')"

# List all active temporary bans with expiration
sudo nft list set inet nftban_global temp_ban_v4 | grep expires

# Watch for changes in real-time
watch -n 5 'sudo nft list set inet nftban_global temp_ban_v4'
```

### Control Panel Detection Verification

```bash
# Check which control panel was detected
sudo grep "Detected control panel" /etc/nftban/logs/validation_*.log | tail -1

# View loaded control panel configuration
sudo cat /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf | head -20
```

---

## 🛠️ Troubleshooting

### Script locked

```bash
# Remove lock file
sudo rm -f /var/run/nftban_init.lock

# Then retry
sudo ./nftban_init_nftables_conf.sh --install-final
```

### Missing dependencies

```bash
# Debian/Ubuntu
sudo apt update
sudo apt install -y nftables ipcalc sipcalc curl

# RHEL/CentOS/Fedora
sudo dnf install -y epel-release
sudo dnf install -y nftables ipcalc sipcalc curl
```

### Configuration not persisting after reboot

```bash
# Enable nftables service
sudo systemctl enable nftables

# Verify it's active
sudo systemctl status nftables

# Manually save current ruleset (if needed)
sudo nft list ruleset > /etc/nftables.conf
```

### Wrong control panel detected

```bash
# 1. Create custom template
sudo ./nftban_init_nftables_conf.sh --create-panel-templates

# 2. Edit the generic template or create your own
sudo nano /etc/nftban/config/templates/control-panels/generic.conf

# 3. The script will use your custom configuration
sudo ./nftban_init_nftables_conf.sh --install-final
```

### Control panel ports not working

```bash
# 1. Check if ports were merged
sudo cat /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf

# 2. Validate the configuration
sudo ./nftban_init_nftables_conf.sh --validate-only

# 3. Check for syntax errors in template
sudo cat /etc/nftban/config/templates/control-panels/directadmin.conf

# 4. View generated rules
sudo nft list chain inet nftban_global input | grep dport
```

### Ports from .conf.local not appearing

```bash
# Verify file format
sudo cat /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Should look like:
# 22T
# 80T
# 443T

# Check validation log for errors
sudo tail -50 /etc/nftban/logs/validation_$(date +%F).log
```

### Locked out after applying rules

**Prevention:** The script auto-whitelists your IP, but if locked out:

1. **Access via console** (KVM/IPMI/Physical access)
2. **Restore backup:**
   ```bash
   sudo nft -f /etc/nftables.conf.backup
   ```
3. **Or flush all rules:**
   ```bash
   sudo nft flush ruleset
   sudo systemctl restart nftables
   ```
4. **Emergency SSH access:**
   ```bash
   # From console, temporarily allow all SSH
   sudo nft add rule inet nftban_global input tcp dport 22 accept
   ```

### Fail2ban not banning IPs

```bash
# 1. Check if action file exists
ls -la /etc/fail2ban/action.d/nftban-global.conf

# 2. Generate if missing
sudo ./nftban_init_nftables_conf.sh --generate-f2b-action

# 3. Test ban manually
sudo fail2ban-client set sshd banip 192.0.2.1

# 4. Check if IP appears in set
sudo nft list set inet nftban_global temp_ban_v4 | grep 192.0.2.1

# 5. View fail2ban log
sudo tail -50 /var/log/fail2ban.log

# 6. Unban for testing
sudo fail2ban-client set sshd unbanip 192.0.2.1
```

### Validation errors

```bash
# View detailed validation log
sudo cat /etc/nftban/logs/validation_$(date +%F).log

# Check syntax of generated config
sudo nft -c -f /etc/nftban/config/nft_rules.conf.local

# Run validation on all config files
sudo ./nftban_init_nftables_conf.sh --validate-only
```

---

## 📁 Directory Structure

```
/etc/nftban/
├── config/
│   ├── templates/
│   │   └── control-panels/
│   │       ├── directadmin.conf      # DirectAdmin port template
│   │       ├── cpanel.conf           # cPanel/WHM port template
│   │       ├── plesk.conf            # Plesk port template
│   │       └── generic.conf          # Generic/fallback template
│   ├── nftban-configuration-ipv4-ports-input-allow.conf        # System (auto)
│   ├── nftban-configuration-ipv4-ports-input-allow.conf.local  # User (preserved)
│   ├── nftban-configuration-ipv4-ports-output-allow.conf       # System (auto)
│   ├── nftban-configuration-ipv4-ports-output-allow.conf.local # User (preserved)
│   ├── nftban-configuration-ipv6-ports-input-allow.conf        # System (auto)
│   ├── nftban-configuration-ipv6-ports-input-allow.conf.local  # User (preserved)
│   ├── nftban-configuration-ipv6-ports-output-allow.conf       # System (auto)
│   ├── nftban-configuration-ipv6-ports-output-allow.conf.local # User (preserved)
│   ├── nftban-configuration-user-whitelist_ips.conf.local
│   ├── nftban-configuration-user-blacklist_ips.conf.local
│   ├── nftban-configuration-ipv4-blacklist_ips.conf.local
│   ├── nftban-configuration-ipv6-blacklist_ips.conf.local
│   ├── nftban-configuration-system_whitelist_ips.conf.local
│   ├── nftban-configuration-system_whitelist_ips.conf          # Base (auto)
│   ├── nftban-nfttables-ct-ipv4.conf.local
│   ├── nftban-nfttables-ct-ipv6.conf.local
│   ├── nft_rules.conf.local                                    # Generated
│   └── nftban-fail2ban-ip-whitelist.conf.local                 # Generated
├── templates/                         # Script templates (if any)
├── backups/                           # Automatic backups
│   └── *.backup.YYYYMMDDHHMMSS
└── logs/                              # Validation & operation logs
    ├── validation_YYYY-MM-DD.log
    └── nftables_final_YYYYMMDD-HHMMSS.conf
```

---

## ⚙️ Technical Details

**Script Version:** 2.3.0  
**Shell:** Bash (requires Bash 4.0+)  
**Dependencies:** `nft`, `ip`, `awk`, `grep`, `sed`, `flock`  
**Optional:** `ipcalc`, `sipcalc`, `curl`, `wget`

**Compatibility:**
- ✅ Debian 10+
- ✅ Ubuntu 20.04+
- ✅ CentOS 8+
- ✅ AlmaLinux 8+
- ✅ Rocky Linux 8+
- ✅ Fedora 35+
- ✅ RHEL 8+

**Control Panel Compatibility:**
- ✅ DirectAdmin (all versions)
- ✅ cPanel/WHM 11.x
- ✅ Plesk Obsidian 18.x
- ✅ Generic (any other setup)

**Kernel Requirements:** Linux 4.18+ (for full nftables features)

### Performance Characteristics

- **Execution time**: 1-5 seconds (depending on config size)
- **Memory usage**: < 10 MB
- **CPU usage**: Minimal (validation is the heaviest operation)
- **Rule generation**: O(n) where n = number of configured ports/IPs

### Security Considerations

- ✅ All validation logs stored securely in `/etc/nftban/logs/`
- ✅ Lock file prevents race conditions
- ✅ Automatic whitelist of current connection prevents lockout
- ✅ Rollback mechanism on failure
- ✅ No external dependencies for core functionality
- ✅ Fail2ban integration uses timeout-based temporary bans

---

## 🔄 Workflow Example

### Initial Setup on DirectAdmin Server

```bash
# 1. Download script
cd /root
curl -fsSL -O https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init_nftables_conf.sh
chmod +x nftban_init_nftables_conf.sh

# 2. Run first time (creates templates, detects DirectAdmin)
sudo ./nftban_init_nftables_conf.sh --install-final

# Output:
# [INFO] Detected control panel: DirectAdmin
# [INFO] Loading control panel config: /etc/nftban/config/templates/control-panels/directadmin.conf
# [INFO] Adding TCP_IN ports: 20,21,22,25,53,80,110,143,443,465,587,993,995,2222,35000-35999
# ...
# [OK] Ruleset applied successfully!

# 3. Verify DirectAdmin ports are open
sudo nft list chain inet nftban_global input | grep 2222  # DirectAdmin
sudo nft list chain inet nftban_global input | grep 35000 # Passive FTP
```

### Adding Custom Application

```bash
# 1. Add custom port for application on port 8080
echo "8080T" | sudo tee -a /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# 2. Regenerate and apply
sudo ./nftban_init_nftables_conf.sh --install-final

# 3. Verify
sudo nft list chain inet nftban_global input | grep 8080
```

### Regular Maintenance

```bash
# Weekly: Regenerate rules (picks up any control panel updates)
sudo ./nftban_init_nftables_conf.sh --install-final -y

# Monthly: Clean old backups (script auto-keeps last 10)
ls -lh /etc/nftban/backups/

# As needed: Review banned IPs
sudo nft list set inet nftban_global temp_ban_v4
```

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

We welcome contributions! Here's how:

### Reporting Issues

1. Check existing [GitHub Issues](https://github.com/itcmsgr/nftban/issues)
2. Include:
   - Operating system and version
   - Control panel (if applicable)
   - Script version
   - Error messages or logs
   - Steps to reproduce

### Pull Requests

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Test on both Debian and RHEL-based systems
4. Test with at least one control panel
5. Update documentation if needed
6. Commit with clear messages
7. Push to your fork
8. Submit a pull request

### Adding Control Panel Support

To add support for a new control panel:

1. Create template: `/etc/nftban/config/templates/control-panels/yourpanel.conf`
2. Add detection logic in `detect_control_panel()` function
3. Test thoroughly
4. Submit PR with documentation

### Testing Checklist

- [ ] Runs without errors on Debian 11
- [ ] Runs without errors on Rocky Linux 8
- [ ] Unit tests pass (`--run-tests`)
- [ ] Validation works (`--validate-only`)
- [ ] Dry run shows correct output (`--dry-run`)
- [ ] Control panel detection works
- [ ] Fail2ban integration works
- [ ] Rollback works on error
- [ ] Documentation updated

---

## 📞 Support

### Community Support

- **Issues:** [GitHub Issues](https://github.com/itcmsgr/nftban/issues)
- **Discussions:** [GitHub Discussions](https://github.com/itcmsgr/nftban/discussions)
- **Documentation:** [GitHub Wiki](https://github.com/itcmsgr/nftban/wiki)

### Professional Support

- **Author:** Antonios Voulvoulis (ITCMS Team)
- **Email:** support@itcms.gr
- **Website:** [https://itcms.gr](https://itcms.gr)

### Useful Resources

- [nftables Wiki](https://wiki.nftables.org/)
- [Fail2ban Manual](https://fail2ban.readthedocs.io/)
- [DirectAdmin Forums](https://forum.directadmin.com/)
- [cPanel Forums](https://forums.cpanel.net/)

---

## 🔗 Related Scripts

This is part of the **nftban** toolkit:

| Script | Purpose |
|--------|---------|
| `nftban` | Main management CLI for ban/unban operations |
| `nftban_init_nftables_conf.sh` | This script - firewall initialization |
| `nftban_init.sh` | nftban system installation and setup |
| `fail2ban-init.sh` | Fail2ban installation and integration |

Each script has focused documentation. See the [main repository](https://github.com/itcmsgr/nftban) for complete toolkit.

---

## 📚 Additional Documentation

- [Architecture Overview](docs/ARCHITECTURE.md)
- [Control Panel Integration Guide](docs/CONTROL_PANELS.md)
- [Fail2ban Integration Guide](docs/FAIL2BAN.md)
- [Troubleshooting Guide](docs/TROUBLESHOOTING.md)
- [API Reference](docs/API.md)
- [Migration Guide](docs/MIGRATION.md)

---

## 🎓 Learn More

### Tutorials

1. [First-Time Setup Guide](tutorials/01-first-time-setup.md)
2. [DirectAdmin Integration](tutorials/02-directadmin.md)
3. [cPanel/WHM Integration](tutorials/03-cpanel.md)
4. [Custom Port Configuration](tutorials/04-custom-ports.md)
5. [Advanced Fail2ban Setup](tutorials/05-fail2ban-advanced.md)

### Video Guides (Coming Soon)

- Installing nftban on DirectAdmin server
- Customizing firewall rules
- Integrating with Fail2ban
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

---

<p align="center">
  <b>Made with ❤️ by <a href="https://itcms.gr">ITCMS Team</a></b><br>
  <sub>Protecting servers since 2024</sub>
</p>

<p align="center">
  <a href="https://github.com/itcmsgr/nftban">🏠 Home</a> •
  <a href="https://github.com/itcmsgr/nftban/issues">🐛 Report Bug</a> •
  <a href="https://github.com/itcmsgr/nftban/discussions">💬 Discuss</a> •
  <a href="https://itcms.gr">🌐 Website</a>
</p>
