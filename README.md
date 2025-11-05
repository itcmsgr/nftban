# 🛡️ NFTBan v0.30.1

**Modern, high-performance firewall management for Linux servers**

[![Version](https://img.shields.io/badge/version-0.30.1-brightgreen)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-MPL--2.0-blue)](LICENSE)
[![FHS Compliant](https://img.shields.io/badge/FHS-compliant-green)](https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html)
[![Platform](https://img.shields.io/badge/platform-Linux-success)](https://github.com/itcmsgr/nftban)
[![Status](https://img.shields.io/badge/status-stable-brightgreen)](https://github.com/itcmsgr/nftban)

> **✅ PRODUCTION READY**: NFTBan v0.30.1 is stable and deployed on production servers. Includes critical security fix for rule order (CVE-2024-NFTBAN-001). [Security Advisory](SECURITY.md)

---

## 🚀 Quick Start

### Install from Packages (Recommended)

**Rocky Linux / AlmaLinux / RHEL / Fedora:**
```bash
# Download latest release
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban-0.30.1-1.el9.x86_64.rpm

# Install
sudo dnf install -y nftban-0.30.1-1.el9.x86_64.rpm

# Verify
nftban --version
```

**Ubuntu / Debian:**
```bash
# Download latest release
wget https://github.com/itcmsgr/nftban/releases/latest/download/nftban_0.30.1-1_amd64.deb

# Install
sudo dpkg -i nftban_0.30.1-1_amd64.deb
sudo apt-get install -f  # Install dependencies if needed

# Verify
nftban --version
```

### First Steps
```bash
# Check system health
nftban health check

# View firewall status
nftban firewall status

# Get help
nftban help
```

**See full documentation:** [docs/README.md](docs/README.md)

---

## 📚 Documentation

### Quick Access

**Philosophy:**
1. **CLI teaches you:** `nftban help`
2. **Need details:** `man nftban`
3. **Want to understand:** Read [ARCHITECTURE.md](docs/ARCHITECTURE.md)
4. **Want to hack:** Code is open, explore!

### Essential Documents

| Document | Purpose |
|----------|---------|
| [docs/README.md](docs/README.md) | Documentation guide and learning paths |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Technical architecture and design |
| `man nftban` | Complete command reference |
| [SECURITY.md](SECURITY.md) | Security policy and CVE advisories |
| [CHANGELOG.md](CHANGELOG.md) | Version history |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute |

---

## ✨ What Makes NFTBan Special?

### 🛡️ Never Lock Yourself Out
- **Auto-whitelist system** - Your IP is protected
- **SSH port auto-detection** - Always accessible
- **Whitelist-first design** - Safety built-in
- **Auto-heal system** - Fixes common issues automatically

### 🚀 Blazing Fast
- **10ms operations** - Add/remove IPs instantly
- **O(1) lookups** - Handle 10,000+ IPs with zero performance impact
- **Atomic updates** - Zero packet loss during reloads
- **Go binaries** - Ultra-fast GeoIP and feed processing

### 🔐 Multi-Layer Security
```
8. Auto-Heal System    ← Automatic recovery and fixes
7. Application Layer   ← App-specific protection
6. Intrusion Detection ← Fail2ban auto-banning
5. Threat Intelligence ← Blacklist feeds
4. Dynamic Blacklist   ← Manual and auto-detected bans
3. Port Filtering      ← Only required ports open
2. IP Whitelist        ← Trusted IPs always allowed
1. Connection State    ← Stateful firewall tracking
```

### 📦 Professional Design
- **FHS-compliant** - Standard Linux directory structure
- **Modular architecture** - Easy to extend and maintain
- **25 CLI commands** - Comprehensive management interface
- **Zero hardcoded values** - Dynamic discovery and auto-configuration

---

## 💡 Key Features

### Core Firewall Management
```bash
nftban status                # System overview
nftban firewall status       # Firewall state
nftban health check          # System diagnostics
```

### IP Management
```bash
nftban ban 192.0.2.50        # Block an IP (checks whitelist first!)
nftban unban 192.0.2.50      # Unblock an IP
nftban search 192.0.2.50     # Find IP in all sets
nftban whitelist add <ip>    # Protect an IP
```

### Built-In Protection
- **DDoS Protection** - SYN flood, connection limits, rate limiting
- **Port Scan Detection** - Identify and auto-ban scanners
- **Fail2ban Integration** - Automatic intrusion response
- **Threat Feeds** - Block known malicious IPs (optional)
- **Auto-Heal** - Automatic permission and directory fixes

### Simple to Use
- Intuitive CLI with `--help` everywhere
- Comprehensive man page (`man nftban`)
- Clear error messages with solutions
- Tab completion for all commands

---

## 🆕 What's New in v0.30.1

### 🚨 Critical Security Release

**CVE-2024-NFTBAN-001 FIXED** - Rule order vulnerability that allowed blacklisted IPs to bypass firewall.

**The Fix:** Blacklist checks now run BEFORE port checks (as they should).

```nft
# v0.30.0 (VULNERABLE):
tcp dport @tcp_ports accept    ← Port 22 accepted FIRST
ip saddr @blacklist_v4 drop    ← NEVER REACHED!

# v0.30.1 (SECURE):
ip saddr @blacklist_v4 counter drop    ← Check blacklist FIRST
tcp dport @tcp_ports counter accept    ← Then allow ports
```

**Impact:** Blacklisted attackers could access SSH and all services in v0.30.0.

**Upgrade immediately** if running v0.30.0 or earlier!

### Additional Fixes
- ✅ Chain renamed: `input_main` → `input` (consistency)
- ✅ Numeric priorities: `-5, 0` (not `-310, -300`)
- ✅ Default policy: `drop` (secure by default)
- ✅ Counters added: All rules now have packet counters
- ✅ Set name typo fixed: `whitelist_ipv4` → `whitelist_v4`
- ✅ nftables syntax fixed: `counter` before `accept/drop`

**Full details:** [SECURITY.md](SECURITY.md) | [CHANGELOG.md](CHANGELOG.md)

---

## 💻 System Requirements

### Minimum Requirements
- **OS**: Linux with kernel 5.10+
- **nftables**: 1.0.0+
- **Bash**: 5.0+
- **systemd**: 250+
- **RAM**: 512 MB (1 GB recommended)
- **Disk**: 100 MB

### Tested & Supported
✅ **Fully Tested:**
- Rocky Linux 9-10
- AlmaLinux 9-10
- Fedora 38-42
- Ubuntu 24.04 LTS
- Debian 12+

✅ **Should Work:**
- RHEL 9+
- CentOS Stream 9-10
- Oracle Linux 9+
- openSUSE Leap 15.5+

---

## 🎯 Common Operations

### Enable/Disable
```bash
nftban firewall init     # Initialize firewall (first time)
nftban enable            # Activate NFTBan
nftban disable           # Deactivate (config preserved)
nftban status            # Check current state
```

### Firewall Management
```bash
nftban firewall reload   # Reload from config
nftban firewall status   # Show tables/sets/chains
nftban firewall check    # Verify firewall health
```

### IP Operations
```bash
# Ban an IP (whitelist protection built-in!)
nftban ban 192.0.2.50

# Unban an IP
nftban unban 192.0.2.50

# Search for an IP
nftban search 192.0.2.50

# Whitelist your IP (protection from accidents)
nftban whitelist add 192.0.2.1
```

### Protection Modules
```bash
nftban portscan enable   # Detect port scans
nftban ddos enable       # Enable DDoS protection
nftban feeds enable      # Enable threat feeds
nftban fail2ban setup    # Configure Fail2ban integration
```

### Monitoring
```bash
nftban stats             # Statistics dashboard
nftban stats top         # Top blocked IPs
nftban report            # Generate report
nftban health check      # System diagnostics
```

---

## ⚠️ Security Notice

### v0.30.0 Users - UPGRADE IMMEDIATELY

If you're running v0.30.0, **upgrade to v0.30.1 now**. The rule order bug (CVE-2024-NFTBAN-001) allowed blacklisted IPs to bypass firewall protections.

```bash
# Check your version
nftban --version

# If v0.30.0, upgrade now:
# Download v0.30.1 package and install
# Then verify the fix:
nftban firewall check
nft list chain inet nftban_main input
```

### Lockout Prevention

NFTBan includes multiple safety features:
- ✅ **Whitelist-first** - Your IP is protected
- ✅ **Ban command checks whitelist** - Won't ban whitelisted IPs
- ✅ **SSH auto-detection** - SSH port always protected
- ✅ **Auto-heal** - Fixes common issues automatically

**Still, always test on non-production first!**

---

## 📖 Learning Resources

### Getting Started (30 minutes)
1. `nftban help` - Browse all commands
2. `nftban status` - See current state
3. `nftban health check` - System diagnostics
4. Try commands with `--help`

### System Administration (2 hours)
1. `man nftban` - Complete reference
2. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - Understand design
3. Explore `/etc/nftban/` - Configuration
4. Read [SECURITY.md](SECURITY.md) - Security model

### Development (4-8 hours)
1. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) - Deep dive
2. Study `/usr/lib/nftban/` - Source code
3. [CONTRIBUTING.md](CONTRIBUTING.md) - Contribute
4. `nft list tables` - Explore nftables

**Full learning paths:** [docs/README.md](docs/README.md)

---

## 🤝 Getting Help

### Built-In Help
```bash
nftban help              # All commands
nftban <command> help    # Command-specific help
man nftban              # Complete reference
nftban health check     # System diagnostics
```

### Documentation
- **Quick Start:** This README
- **Architecture:** [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
- **Man Page:** `man nftban`
- **Doc Guide:** [docs/README.md](docs/README.md)

### Community & Support
- 🏠 **GitHub:** https://github.com/itcmsgr/nftban
- 🐛 **Issues:** https://github.com/itcmsgr/nftban/issues
- 💬 **Discussions:** https://github.com/itcmsgr/nftban/discussions
- 📧 **Email:** contact@nftban.com
- 🌐 **Website:** https://nftban.com

### Reporting Bugs

Please include:
1. NFTBan version (`nftban --version`)
2. OS and kernel (`uname -a`)
3. Output of `nftban health check`
4. Relevant logs from `/var/log/nftban/`
5. Steps to reproduce

---

## 📜 License

**Mozilla Public License 2.0 (MPL-2.0)**

Copyright © 2024–2026 NFTBAN Project / Antonios Voulvoulis

✅ Free to use in personal and commercial projects
✅ Modify and customize as needed
✅ Deploy on unlimited systems
📜 Source code modifications must remain MPL-2.0
🔓 Open source, community-driven

**Important Documents:**
- [LICENSE](LICENSE) - Full license text
- [NOTICE.md](NOTICE.md) - Third-party attributions
- [TRADEMARK.md](TRADEMARK.md) - Brand usage guidelines
- [CONTRIBUTING.md](CONTRIBUTING.md) - How to contribute
- [SECURITY.md](SECURITY.md) - Security policy

### Trademark Notice

**"NFTBAN"** and the NFTBAN logo are trademarks of Antonios Voulvoulis (NFTBAN Project).

- ✅ **Code:** Licensed under MPL-2.0 (free to use and modify)
- 🏷️ **Name & Brand:** Protected trademark (see [TRADEMARK.md](TRADEMARK.md))

---

## 🌟 Contributing

We welcome contributions!

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes with tests
4. Commit (`git commit -s -m 'Add amazing feature'`)
5. Push (`git push origin feature/amazing-feature`)
6. Open a Pull Request

**Read:** [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

## 🙏 Acknowledgments

NFTBan is built on excellent open source projects:
- **nftables** - Modern Linux firewall
- **Fail2ban** - Intrusion prevention
- **FireHOL** - Threat intelligence feeds
- **MaxMind GeoIP** - IP geolocation

**See:** [NOTICE.md](NOTICE.md) for complete attributions.

### 🤖 AI-Assisted Development

This project benefits from AI collaboration:

| AI Partner | Role |
|------------|------|
| **ChatGPT** (OpenAI) | Architecture planning, design consultation |
| **Claude Code** (Anthropic) | Implementation, testing, validation |
| **Claude AI** (Anthropic) | Code review, optimization |

All AI contributions are transparently credited in Git commits.

---

<p align="center">
  <b>Made with ❤️ by <a href="https://nftban.com">NFTBAN Project</a></b><br>
  <sub>Empowering system administrators with simple, powerful security tools</sub>
</p>

<p align="center">
  <a href="docs/README.md">📚 Documentation</a> •
  <a href="docs/ARCHITECTURE.md">🏗️ Architecture</a> •
  <a href="SECURITY.md">🔒 Security</a> •
  <a href="CHANGELOG.md">📝 Changelog</a> •
  <a href="https://github.com/itcmsgr/nftban/issues">🐛 Report Issue</a> •
  <a href="https://nftban.com">🌐 Website</a>
</p>

<p align="center">
  <sub>✅ Production Ready - v0.30.1 includes critical security fix</sub><br>
  <sub>Copyright © 2024–2026 NFTBAN Project / Antonios Voulvoulis</sub>
</p>
