# NFTBan v0.32.16 - Quick Start Guide

**The Linux firewall that AUTOMATICALLY protects you - Get running in 2 commands!**

---

## 🚀 For Impatient Users (The Fast Way)

**NFTBan is designed to be installed and used successfully without reading 50 pages of documentation.**

**What makes NFTBan different:**
- ✅ **AUTOMATIC SSH protection** - Detects your SSH port instantly
- ✅ **AUTOMATIC system IP whitelisting** - No manual configuration
- ✅ **AUTOMATIC fail2ban integration** - Brute force protection enabled
- ✅ **AUTOMATIC maintenance** - Timer keeps everything updated

### Rocky Linux / AlmaLinux / Fedora
```bash
# 1. Install
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm
sudo dnf install -y nftban-x86_64.rpm

# 2. Run setup wizard
sudo nftban setup

# That's it! 🎉
```

### Ubuntu / Debian
```bash
# 1. Install
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-amd64.deb
sudo dpkg -i nftban-amd64.deb
sudo apt-get install -f

# 2. Run setup wizard
sudo nftban setup

# That's it! 🎉
```

**The interactive wizard automatically:**
- ✅ Fixes all permissions
- ✅ Creates missing directories
- ✅ Verifies system health
- ✅ Enables SSH protection (fail2ban)
- ✅ Blocks bad IPs automatically
- ✅ Protects your system

**Then you're DONE! Go to sleep! 😴**

---

## 📋 Prerequisites

- Linux server (Rocky 9+, AlmaLinux 9+, Fedora 38+, Ubuntu 24.04+, Debian 12+)
- Root or sudo access
- Internet connection (for package download)

---

## 📦 Installation Methods

### Method 1: One-Line Install (Recommended)

**RHEL/Rocky/Alma/Fedora (x86_64):**
```bash
curl -LO https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm && sudo dnf install -y nftban-x86_64.rpm && sudo nftban setup
```

**Ubuntu/Debian (amd64):**
```bash
curl -LO https://github.com/itcmsgr/nftban/releases/latest/download/nftban-amd64.deb && sudo dpkg -i nftban-amd64.deb && sudo nftban setup
```

### Method 2: Available Architectures

| Platform | Architecture | Download Link |
|----------|-------------|---------------|
| **RHEL / Rocky / Alma / Fedora** | x86_64 | [nftban-x86_64.rpm](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-x86_64.rpm) |
| **RHEL / Rocky / Alma / Fedora** | aarch64 (ARM64) | [nftban-aarch64.rpm](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-aarch64.rpm) |
| **Ubuntu 24.04+ / Debian 12+** | amd64 | [nftban-amd64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-amd64.deb) |
| **Ubuntu 24.04+ / Debian 12+** | arm64 | [nftban-arm64.deb](https://github.com/itcmsgr/nftban/releases/latest/download/nftban-arm64.deb) |

After installation, run: `sudo nftban setup`

---

## 🎯 The Setup Wizard (Interactive)

The `nftban setup` command provides a guided, step-by-step setup experience:

```bash
sudo nftban setup
```

**What happens:**

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🚀 NFTBan First-Time Setup Wizard
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

This wizard will:
  ✓ Fix all permissions
  ✓ Create missing directories
  ✓ Verify system configuration
  ✓ Enable NFTBan (optional)

Continue? (y/n) [y]:

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 1/4: Fixing Permissions
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✅ Permissions fixed

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 2/4: Creating Missing Directories
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✅ All directories created

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 3/4: Running Health Check
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  ✅ System health: PERFECT

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Step 4/4: Enable NFTBan Firewall
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Enable now? (y/n) [n]: y

  ✅ NFTBan enabled and running!

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🎉 Setup Complete!
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

✅ NFTBan is now protecting your server!

Next steps:
  • Check status: nftban status
  • View logs: journalctl -u nftban -f
  • Test GeoBan: nftban geoban help
```

### Non-Interactive Mode

For automation/scripts:
```bash
sudo nftban setup --auto
```

---

## 🎓 Basic Usage (After Setup)

### Check Status
```bash
nftban status
```

### Ban an IP
```bash
sudo nftban ban 192.0.2.100
```

### Block a Country (GeoBan)
```bash
sudo nftban geoban ban CN     # Block China
sudo nftban geoban ban RU     # Block Russia
```

### Whitelist a Country
```bash
sudo nftban geoban whitelist US    # Never block USA
```

### Add a Custom Port
```bash
sudo nftban port add 8080 tcp
sudo nftban port search 8080
```

### Health Check
```bash
nftban health check
```

### Get Help
```bash
nftban help
nftban geoban help
man nftban
```

---

## 🔧 Manual Setup (Advanced Users)

If you prefer manual setup instead of the wizard:

### 1. Fix Permissions
```bash
sudo nftban permissions enforce
```

### 2. Create Directories
```bash
sudo nftban health check --auto-heal
```

### 3. Initialize Firewall
```bash
sudo nftban firewall init
```

### 4. Enable NFTBan
```bash
sudo nftban enable
```

### 5. Verify
```bash
nftban status
nftban health check
```

---

## 📖 Key Features in v0.32.6

### 🎯 Interactive Setup Wizard
- **One command:** `nftban setup` does everything
- **Guided process:** Clear steps with progress indicators
- **Smart healing:** Automatically fixes common issues
- **Optional enable:** Choose when to start firewall

### 🌍 GeoBan Country Blocking
- **Block countries:** `nftban geoban ban CN`
- **Whitelist countries:** `nftban geoban whitelist US`
- **Atomic operations:** Zero-downtime updates
- **RIR data sources:** ARIN, RIPE, APNIC, LACNIC, AFRINIC

### ⚡ Atomic Port Management
- **Add ports:** `nftban port add 8080 tcp`
- **Remove ports:** `nftban port remove 8080`
- **Search ports:** `nftban port search 22`
- **SSH protection:** System ports can't be accidentally removed

### 🔄 Go-Powered Performance
- **10-60x faster:** Go binaries for feeds and GeoIP
- **Atomic operations:** Direct netlink communication
- **Safety limits:** CPU/RAM monitoring prevents overload
- **Intelligent caching:** ETag-based HTTP caching

### 🛠️ Auto-Heal System
- **Smart detection:** Identifies specific issues
- **Actionable fixes:** Shows exact commands to run
- **27 FHS directories:** All required paths auto-created
- **Permission enforcement:** Correct ownership/modes

---

## 📚 Configuration

NFTBan works out-of-the-box with sensible defaults. Configuration is optional.

### Main Config
```bash
# View current config
cat /etc/nftban/nftban.conf

# Customize (optional)
sudo vi /etc/nftban/nftban.conf
```

### Module Configs
```bash
# List available modules
ls /etc/nftban/conf.d/

# Edit module config
sudo vi /etc/nftban/conf.d/feeds.conf
```

### GeoBan Config
```bash
# View banned/whitelisted countries
nftban geoban list

# View GeoBan configuration
nftban geoban config
```

---

## 🔐 User Management (Optional)

### Add Users to nftban-cli Group

Allow users to manage firewall without sudo:

```bash
# Add user
sudo usermod -aG nftban-cli username

# User must re-login
su - username

# Now user can:
systemctl restart nftables    # No password needed
systemctl restart fail2ban    # No password needed
```

**Security:**
- Scope-limited: Only nftables & fail2ban
- Audit trail: All actions logged
- Group-based: Easy to revoke access

### Add Users to nftban-auditors Group

Read-only access for security auditors:

```bash
# Add auditor
sudo usermod -aG nftban-auditors auditor_username

# Auditor can:
nftban stats              # View statistics
nftban health check       # View health
nftban list              # View ban lists
# CANNOT restart services or modify firewall
```

---

## 🧪 Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                    NFTBan v0.32.6                           │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  🎯 Interactive Setup Wizard (NEW!)                        │
│  └─ nftban setup → Guides users through setup             │
│                                                             │
│  🐧 Bash Shell Scripts (Core Logic)                        │
│  ├─ /usr/sbin/nftban           Main CLI                    │
│  ├─ /usr/lib/nftban/core/*.sh  Core modules               │
│  └─ /usr/lib/nftban/cli/*.sh   CLI commands               │
│                                                             │
│  ⚡ Go Binaries (High Performance)                          │
│  ├─ nftban-feeds   10-60x faster feed processing          │
│  └─ nftban-geoip   GeoBan country blocking                │
│                                                             │
│  🌍 GeoBan (Country Blocking)                              │
│  ├─ Ban countries: nftban geoban ban CN                   │
│  ├─ Whitelist: nftban geoban whitelist US                 │
│  └─ Atomic netlink operations                             │
│                                                             │
│  🔐 Polkit Integration                                      │
│  ├─ nftban-cli → Full firewall management                 │
│  └─ nftban-auditors → Read-only access                    │
│                                                             │
│  🛠️ Auto-Healing System                                     │
│  ├─ Smart error detection                                 │
│  ├─ Actionable fix commands                               │
│  └─ 27 FHS directories autocreated                        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

---

## 🆘 Troubleshooting

### Issue: Just installed, not sure what to do

**Solution:** Run the setup wizard!
```bash
sudo nftban setup
```

### Issue: Health check shows errors

**Solution:** Let auto-heal fix it
```bash
sudo nftban health check --auto-heal
```

Or use the setup wizard:
```bash
sudo nftban setup
```

### Issue: Permission errors

**Solution:**
```bash
sudo nftban permissions enforce
```

### Issue: GeoBan not working

**Solution:** Check if nftban-geoip binary exists
```bash
ls -la /usr/lib/nftban/bin/.real/nftban-geoip
nftban geoban help
```

### Issue: Port management not working

**Solution:** Check if ports.d directory exists
```bash
ls -la /etc/nftban/ports.d/
nftban port search 22
```

---

## 🎓 Learning Resources

### Command-Line Help
```bash
# General help
nftban help

# Command-specific help
nftban geoban help
nftban port help
nftban health help
```

### Man Page
```bash
man nftban
```

### Documentation
- **ARCHITECTURE.md** - Technical design
- **GEOBAN_FEATURE.md** - GeoBan guide
- **GO_COMPILATION_GUIDE.md** - Go binary details
- **README.md** - Project overview

**Location:** `/usr/share/nftban/docs/` or https://github.com/itcmsgr/nftban/tree/main/docs

---

## 🚀 Next Steps

### 1. Try GeoBan
```bash
# Block a country
sudo nftban geoban ban CN

# Check status
nftban geoban list

# Unblock
sudo nftban geoban unban CN
```

### 2. Enable Threat Feeds
```bash
# See available feeds
nftban feeds list

# Enable a feed
sudo nftban feeds enable greensnow

# Update feeds
sudo nftban feeds update
```

### 3. Add Custom Ports
```bash
# Add application port
sudo nftban port add 8080 tcp

# Verify
nftban port search 8080
```

### 4. Set Up Monitoring
```bash
# Watch logs
journalctl -u nftban -f

# Check stats
nftban stats

# Generate report
nftban report generate
```

---

## 💡 Philosophy

**Documentation Approach:**
1. **CLI teaches you:** `nftban help`
2. **Need details:** `man nftban`
3. **Want to understand:** Read `ARCHITECTURE.md`
4. **Want to hack:** Code is open, explore!

**Why NFTBan Succeeds Where Linux Fails:**

- **Microsoft:** Grandma clicks "Next, Next, Finish"
- **Linux:** "RTFM" attitude alienates users
- **NFTBan:** `nftban setup` → Anyone succeeds

**If users can deploy it successfully without extensive training, we've built something great for everyone.**

---

## 🔑 Key Locations

| Path | Purpose |
|------|---------|
| `/usr/sbin/nftban` | Main CLI binary |
| `/usr/lib/nftban/` | Application code and Go binaries |
| `/usr/lib/nftban/bin/.real/` | Go binaries (architecture-specific) |
| `/etc/nftban/` | Configuration files |
| `/etc/nftban/geoban.d/` | GeoBan country configs |
| `/etc/nftban/ports.d/` | Port configurations |
| `/var/lib/nftban/` | Runtime data and state |
| `/var/lib/nftban/geoban/` | GeoBan country data |
| `/var/cache/nftban/` | Cache (feeds, geoban) |
| `/var/log/nftban/` | Log files |
| `/usr/share/nftban/docs/` | Documentation |

---

## 📞 Getting Help

- **CLI Help:** `nftban help`
- **Man Page:** `man nftban`
- **Documentation:** https://github.com/itcmsgr/nftban/tree/main/docs
- **Issues:** https://github.com/itcmsgr/nftban/issues
- **Discussions:** https://github.com/itcmsgr/nftban/discussions

---

## 🔒 Security Notes

✅ **Safe by Design**
- No sudo required for nftban-cli members
- Scope-limited service management
- File permissions enforced automatically
- Auto-healing monitors permissions
- SSH port protected from accidental removal

⚠️ **Best Practices**
- Add only trusted users to nftban-cli group
- Review Polkit logs: `journalctl -u polkit`
- Monitor permission changes
- Test GeoBan on non-production first
- Keep backups of custom configs

---

**Version:** 0.31.0
**Last Updated:** 2025-11-06
**License:** MPL-2.0

**🎉 Congratulations! You now have a production-grade firewall running with minimal effort!**
