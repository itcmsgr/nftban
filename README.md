# 🛡️ NFTBan v0.10.0

**Modern, high-performance firewall management for Linux servers**

[![Version](https://img.shields.io/badge/version-0.10.0-brightgreen)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-MPL--2.0-blue)](LICENSE)
[![FHS Compliant](https://img.shields.io/badge/FHS-compliant-green)](https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html)
[![Platform](https://img.shields.io/badge/platform-Linux-success)](https://github.com/itcmsgr/nftban)
[![Status](https://img.shields.io/badge/status-beta-yellow)](https://github.com/itcmsgr/nftban)

> **⚠️ BETA SOFTWARE - ACTIVE DEVELOPMENT**: This is a major rewrite (v0.10.0) with significant architecture changes. While extensively tested on production servers, use with caution. **Always test in a non-production environment first!** We appreciate your feedback! [Report issues](https://github.com/itcmsgr/nftban/issues) | [Discussions](https://github.com/itcmsgr/nftban/discussions)

> **⚠️ BREAKING CHANGES from v0.9.x**: v0.10.0 is a complete rewrite with new directory structure, configuration format, and nftables table design. Migration from v0.9.x requires fresh installation. Backup your current configuration before upgrading!

---

## 🚀 Quick Start

### Package Installation (Recommended)

**Rocky Linux / AlmaLinux / Fedora:**

```bash
# Download latest release
wget https://github.com/nftban/nftban/releases/latest/download/nftban-0.10.0-1.el9.x86_64.rpm

# Install
sudo dnf install -y nftban-0.10.0-1.el9.x86_64.rpm

# Verify
nftban --version
```

**Ubuntu / Debian:**

```bash
# Download latest release
wget https://github.com/nftban/nftban/releases/latest/download/nftban_0.10.0-1_amd64.deb

# Install
sudo dpkg -i nftban_0.10.0-1_amd64.deb
sudo apt-get install -f  # Install dependencies if needed

# Verify
nftban --version
```

### From Source

**Install from Git repository:**

```bash
# Clone repository
git clone https://github.com/itcmsgr/nftban.git
cd nftban

# Run installer
sudo ./install.sh

# Verify
nftban --version
```

**One-line installer (review script first!):**

```bash
curl -sSL https://raw.githubusercontent.com/itcmsgr/nftban/main/install.sh | sudo bash
```

**⚠️ IMPORTANT:** After installation, **test your firewall rules** before disconnecting! The system includes commit-confirm safety, but always verify SSH access works.

**Next steps:**

```bash
# Check system health
sudo nftban health check

# Apply initial rules (with commit-confirm protection)
sudo nftban apply

# Enable automatic updates
sudo systemctl enable --now nftban.timer

# Optional: Add users to nftban-cli group for service management
sudo usermod -aG nftban-cli username
# User must re-login for group to take effect
```

See **[Quick Start Guide](docs/QUICK-START.md)** for complete setup instructions.

---

## 📚 Documentation

**Getting Started:**
- ➤ **[Quick Start Guide](docs/QUICK-START.md)** - Get started in 5 minutes ⭐
- ➤ **[Installation Guide](docs/guides/install.md)** - Complete installation instructions
- ➤ **[Security Architecture](SECURITY.md)** - Multi-layer security model and hardening guide 🛡️
- ➤ [Polkit Integration](docs/guides/polkit-integration.md) - Group-based service management (no sudo) ✨
- ➤ [CLI Quick Reference](docs/reference/cli-quick-reference.md) - Command cheat sheet

**Configuration & Features:**
- [DDOS Protection Guide](docs/guides/ddos-protection.md) - Configure DDoS protection
- [Threat Feeds Setup](docs/guides/threat-feeds.md) - Block 1M+ known malicious IPs
- [Fail2ban Integration](docs/guides/fail2ban-integration.md) - Auto-ban brute force attacks
- [Health Diagnostics](docs/guides/health-diagnostics.md) - Troubleshooting system issues

**Architecture & Design:**
- [Permission Architecture](docs/architecture/permission-architecture.md) - Understanding the security model
- [FHS Consolidation](docs/architecture/fhs-consolidation.md) - Filesystem layout explained

**For Developers:**
- [Go Binaries Guide](docs/development/GO-BINARIES.md) - Building high-performance Go binaries ⚡
- [Packaging Guide](docs/development/packaging.md) - Building RPM/DEB packages
- [Coding Standards](docs/development/coding-standards.md) - For contributors

**All documentation:** See [docs/](docs/) directory

---

## 📊 Component Status Matrix

| Component | Status | Stability | Production Ready |
|-----------|--------|-----------|------------------|
| **Core Firewall** | ✅ Complete | 90% | ✅ Yes (test first!) |
| **FHS Auto-Heal** | ✅ Complete | 85% | ✅ Yes |
| **Stats & Monitoring** | ✅ Complete | 85% | ✅ Yes |
| **DDoS Protection** | ✅ Complete | 90% | ✅ Yes (tune limits!) |
| **Port Scan Detection** | ✅ Complete | 85% | ✅ Yes |
| **Fail2Ban Integration** | ✅ Complete | 95% | ✅ Yes |
| **Whitelist/Blacklist** | ✅ Complete | 95% | ✅ Yes |
| **Health Diagnostics** | ✅ Complete | 85% | ✅ Yes |
| **Threat Feeds** | ✅ Complete | 80% | ⚠️ Beta |
| **GeoIP Blocking** | 🔄 In Progress | 60% | ⚠️ Experimental |
| **Control Panel Detection** | ✅ Complete | 90% | ✅ Yes (DirectAdmin tested) |
| **CLI & Management** | ✅ Complete | 95% | ✅ Yes |
| **Documentation** | 🔄 In Progress | 80% | ⚠️ Improving |
| **Testing Suite** | 🔄 In Progress | 70% | ⚠️ Needs expansion |

**Overall Project Stability: ~85% (Production Beta - use with caution)**

---

## ✨ What Makes NFTBan Special?

### 🛡️ Never Lock Yourself Out
- **Commit-confirm recovery** with auto-rollback
- Test firewall changes safely with 5-minute grace period
- Automatic SSH whitelist for your IP
- JunOS-style safety patterns
- **Still, always test on non-production first!**

### 🚀 Blazing Fast Performance
- **10-60x faster** than traditional bash scripts
- Go binaries for threat feed processing
- Process **1 million IPs in <1 second**
- Instant GeoIP lookups with caching

### 🔐 8 Security Layers
```
8. Recovery System     ← Auto-rollback prevents lockouts
7. Application Layer   ← App-specific protection
6. Intrusion Detection ← Fail2ban auto-banning
5. Threat Intelligence ← 1M+ known malicious IPs
4. Dynamic Blacklist   ← Manual bans & auto-detected threats
3. Port Filtering      ← Only required ports open
2. IP Whitelist        ← Trusted IPs always allowed
1. Connection State    ← Stateful firewall tracking
```

### 🎛️ 7 Security Profiles
Choose the right balance for your needs:
- **paranoid** - Maximum security (⚠️ test first - very restrictive!)
- **strict** - High security (minimal services)
- **balanced** - Recommended default ✓
- **web** - Web server optimized (HTTP/HTTPS)
- **minimal** - Basic protection only
- **dev** - Development mode (permissive)
- **disabled** - Firewall off

### 📦 Professional Design
- **FHS-compliant** directory structure
- **17 core modules** with single responsibility
- **Modular architecture** - easy to extend
- **Zero hardcoded values** - dynamic discovery

---

## 💡 Key Features

### Auto-Everything
- ✅ **Auto-detects** control panels (DirectAdmin tested, cPanel/Plesk experimental)
- ✅ **Auto-configures** required ports
- ✅ **Auto-protects** against DDoS and port scans
- ✅ **Auto-bans** attackers with Fail2ban
- ✅ **Auto-updates** threat intelligence feeds

### Built-In Protection
- **DDoS Protection** - SYN flood, connection limits, rate limiting (⚠️ tune for your traffic!)
- **Port Scan Detection** - Identify and auto-ban scanners
- **Fail2ban Integration** - Automatic intrusion response
- **Threat Feeds** - Block 1M+ known bad IPs (⚠️ beta - may have false positives)
- **GeoIP Blocking** - Country-level IP filtering (⚠️ experimental)

### Simple to Use
```bash
nftban status              # See what's happening
nftban ban 192.0.2.50      # Block an IP
nftban unban 192.0.2.50    # Unblock an IP
nftban health check        # System diagnostics
nftban profile set balanced # Change security level
nftban feeds update        # Update threat lists
```

---

## 🆕 What's New in v0.10.0

### ⚠️ BREAKING CHANGES

**This is a MAJOR rewrite. Migration from v0.9.x requires:**
- Fresh installation (in-place upgrade not supported)
- Configuration file migration (manual)
- Backup of v0.9.x config recommended
- Testing before production deployment

### Major Features

**🏥 FHS Auto-Heal System** (NEW)
- Automated filesystem hierarchy compliance
- Smart privilege-aware fixing
- Daily systemd timer for maintenance
- Zero-intervention directory management
- **Status:** Tested on 3 production servers, 21/21 compliance

**📊 Stats & Monitoring** (NEW)
- Real-time dashboard reading nftables data
- Historical tracking and trending
- Email reports and automation
- Integration with monitoring tools
- **Status:** Working, needs more field testing

**🛡️ DDoS Protection** (ENHANCED)
- Connection limiting with safe defaults (⚠️ ALL LIMITS COMMENTED - configure for your needs!)
- Per-protocol rate limits
- SYN flood protection
- ICMP rate limiting
- **Status:** Working, requires tuning per server

**🔄 Unified Health Reporting** (NEW)
- Consolidated health checks across all modules
- Single orchestration command
- Auto-fix capabilities
- Detailed diagnostic output
- **Status:** Working, 0 errors on test servers

**🔥 Enhanced Fail2ban Integration**
- Persistent offender detection (3 bans → permanent blacklist)
- Comprehensive ban tracking
- Automatic jail configuration
- **Status:** Tested and working

### Architecture Improvements

**Two-Table nftables Design**
- `nftban_runtime` - Temporary bans, active protection
- `nftban_main` - Permanent rules, persistent config
- 50% fewer rule evaluations
- Cleaner separation of concerns
- **Status:** Production tested

**Single Source of Truth**
- FHS specification in one file
- Used everywhere consistently
- No duplicate definitions
- Easy to maintain

**Smart Privilege Management**
- Privilege-aware auto-fixing
- Root vs nftban user separation
- Clear reporting of permission needs
- No silent failures

➤ **[Full Changelog](CHANGELOG.md)**

---

## ⚠️ Important Warnings & Known Issues

### Before You Install

1. **⚠️ BACKUP YOUR CURRENT FIREWALL CONFIG**
   - Save iptables/nftables rules
   - Document open ports
   - Keep access to console/KVM

2. **⚠️ TEST IN NON-PRODUCTION FIRST**
   - Use a test VM or dev server
   - Verify all services remain accessible
   - Test for at least 24 hours

3. **⚠️ HAVE CONSOLE ACCESS**
   - Don't install over SSH on production without console access
   - Use commit-confirm for safety, but don't rely on it 100%

4. **⚠️ TUNE DDOS LIMITS**
   - Default limits are COMMENTED (disabled)
   - Configure based on your actual traffic
   - Monitor for false positives

### Known Issues (v0.10.0 Beta)

- **GeoIP blocking**: Experimental, may block legitimate traffic
- **Threat feeds**: Beta status, potential false positives
- **Documentation**: Still being improved, some sections incomplete
- **cPanel/Plesk detection**: Experimental, DirectAdmin tested
- **Port optimization**: DirectAdmin bulk operations can be slow (will be optimized)

### Tested Configurations

✅ **Known Working:**
- Rocky Linux 9, AlmaLinux 9, Fedora 38+
- DirectAdmin control panel
- Web servers (Nginx, Apache)
- Mail servers (Postfix, Dovecot)
- SSH protection
- Basic DDoS protection

⚠️ **Needs More Testing:**
- cPanel, Plesk integration
- High-traffic environments (1000+ req/s)
- IPv6 in all scenarios
- Exotic control panels

---

## 📚 Documentation

### Getting Started
- 📖 [Installation Guide](docs/guides/install.md) - Detailed installation (⚠️ read before installing!)
- 🚀 [Quick Start Guide](docs/guides/quickstart.md) - 5-minute setup
- 🔧 [FHS Auto-Heal Index](docs/reference/fhs-auto-heal-index.md) - System health reference

### Common Tasks
- 🚫 [Ban System Guide](docs/guides/ban-system.md) - Block/unblock IPs
- 🛡️ [Security Profiles](docs/guides/security-profiles.md) - Choose your protection level
- 🏥 [Health Diagnostics](docs/guides/health-diagnostics.md) - System health checks
- 🐛 [Troubleshooting](docs/guides/health-diagnostics.md) - Solve common issues

### Understanding NFTBan
- 🏗️ [Architecture](docs/concepts/architecture.md) - How NFTBan works
- 💾 [Recovery System](RECOVERY_GUIDE.md) - Commit-confirm explained
- 🌐 [Threat Feeds](FEEDS_USER_GUIDE.md) - Threat intelligence
- 📜 [Changelog](CHANGELOG.md) - Version history

### Reference
- ⚙️ [CLI Quick Reference](docs/reference/cli-quick-reference.md) - All commands
- 🧩 [Service Status Reference](docs/reference/service-status.md) - Service management
- 📋 [Complete Documentation](docs/index.md) - Full doc portal

---

## 💻 System Requirements

### Minimum Requirements
- **OS**: Linux with kernel 5.10+
- **nftables**: 1.0.0+
- **Bash**: 5.0+
- **systemd**: 250+
- **RAM**: 512 MB (1 GB recommended)
- **Disk**: 100 MB

### Tested & Supported Distributions
✅ **Fully Tested:**
- Rocky Linux 9+ (primary test platform)
- AlmaLinux 9+
- Fedora 38+

✅ **Should Work (less tested):**
- Ubuntu 22.04 LTS+
- Debian 12+
- RHEL 9+, Oracle Linux 9+
- openSUSE Leap 15.5+

⚠️ **Use with Extra Caution:**
- Any distro not listed above (may work, but untested)

---

## 🎯 Quick Examples

### Ban an IP Address
```bash
# Temporary ban (1 hour)
sudo nftban ban 192.0.2.50

# Permanent ban
sudo nftban ban 192.0.2.50 --permanent

# Unban
sudo nftban unban 192.0.2.50

# List all banned IPs
sudo nftban list banned
```

### Change Security Profile
```bash
# List available profiles
sudo nftban profile list

# Set balanced (recommended)
sudo nftban profile set balanced

# Check current profile
sudo nftban profile show
```

### Update Threat Intelligence (⚠️ Beta)
```bash
# List enabled feeds
sudo nftban feeds list

# Update all feeds (may take a few minutes)
sudo nftban feeds update

# Enable a specific feed (test first!)
sudo nftban feeds enable FIREHOL_LEVEL1
```

### Check System Health
```bash
# Run health check
sudo nftban health check

# Auto-fix issues (review first!)
sudo nftban health check --fix

# FHS compliance check
sudo nftban fhs
```

### Safe Firewall Changes (ALWAYS USE THIS!)
```bash
# Apply rules with commit-confirm
sudo nftban-apply

# Test your changes (you have 5 minutes)
# Try SSH in a new terminal!

# If everything works:
sudo nftban-confirm

# If broken, wait for auto-rollback
# Or force rollback immediately:
sudo nftban-rollback --force
```

---

## 🤝 Getting Help

### Documentation
- 📚 **[Documentation Portal](docs/index.md)** - Complete documentation
- 🚀 **[Quick Start Guide](docs/guides/quickstart.md)** - Get started
- 🏗️ **[Architecture Guide](docs/concepts/architecture.md)** - How it works
- 🐛 **[Troubleshooting](docs/guides/health-diagnostics.md)** - Common issues

### Community & Support
- 🏠 **[GitHub Repository](https://github.com/itcmsgr/nftban)** - Source code
- 🐛 **[Issues](https://github.com/itcmsgr/nftban/issues)** - Bug reports (please include logs!)
- 💬 **[Discussions](https://github.com/itcmsgr/nftban/discussions)** - Q&A, ideas, feedback
- 📧 **[Email](mailto:contact@nftban.com)** - Direct support

### Reporting Bugs

**Please include:**
1. NFTBan version (`nftban version`)
2. OS and kernel version (`uname -a`)
3. Output of `nftban health check`
4. Relevant log entries from `/var/log/nftban/nftban.log`
5. Steps to reproduce

### Professional Services
**NFTBAN Project – Simplifying Linux Firewall Management**
- **Author**: Antonios Voulvoulis
- **Website**: https://nftban.com
- **Email**: contact@nftban.com

---

## 📜 License

**Mozilla Public License 2.0 (MPL-2.0)**

Copyright © 2024–2026 NFTBAN Project / Antonios Voulvoulis

✅ Free to use in personal and commercial projects
✅ Modify and customize as needed
✅ Deploy on unlimited systems
📜 Source code modifications must remain MPL-2.0
🔓 Open source, community-driven

**Patent Grant:**
Under MPL-2.0, each contributor grants a patent license for their contributions. Patent retaliation clause applies (§5.2) - if you initiate patent litigation claiming the software infringes, your license terminates.

**Important Documents:**
- 📄 [Full License Text](LICENSE) - Mozilla Public License 2.0
- 📋 [NOTICE](NOTICE.md) - Third-party attributions and legal notices
- 📝 [License Summary](README-License-Summary.md) - Quick reference for licensing
- 🏷️ [Trademark Policy](TRADEMARK.md) - Brand usage guidelines
- 🤝 [Contributing Guide](CONTRIBUTING.md) - How to contribute
- 🔒 [Security Policy](SECURITY.md) - Security reporting

### Trademark Notice

**"NFTBAN"** and the NFTBAN logo are trademarks of Antonios Voulvoulis (NFTBAN Project).

- ✅ **Code:** Licensed under MPL-2.0 (open source, free to use and modify)
- 🏷️ **Name & Brand:** Protected trademark (see usage guidelines below)

**You may:**
- Use, modify, and distribute the code under MPL-2.0
- Reference NFTBAN in documentation and tutorials
- Build commercial products using the code

**You may not (without permission):**
- Use the NFTBAN name to brand your own fork or distribution
- Present your version as "official" or "certified" NFTBAN
- Register domain names or services using the NFTBAN name

📖 **[Read Full Trademark Policy](TRADEMARK.md)** for detailed guidelines.

---

## 🌟 Contributing

We welcome contributions! **But please:**

1. **Report bugs first** - Don't fix without discussion
2. **Follow coding standards** - See [CODING_STANDARDS.md](CODING_STANDARDS.md)
3. **Test thoroughly** - On multiple distros if possible
4. **Document changes** - Update relevant docs
5. **One feature per PR** - Keep PRs focused

**How to contribute:**

1. Fork the repository
2. Create a feature branch (`git checkout -b feature/amazing-feature`)
3. Make your changes with tests
4. Commit (`git commit -m 'Add amazing feature'`)
5. Push (`git push origin feature/amazing-feature`)
6. Open a Pull Request

Please read:
- **[CONTRIBUTING.md](CONTRIBUTING.md)** - Contribution guidelines
- **[CODING_STANDARDS.md](CODING_STANDARDS.md)** - Code standards

---

## 🙏 Acknowledgments

NFTBan is built on excellent open source projects:

- **nftables** - The modern Linux firewall (part of Linux kernel; no affiliation with Linux Foundation)
- **Fail2ban** - Intrusion prevention framework (separate project by Cyril Jaquier; no affiliation)
- **FireHOL** - Threat intelligence feeds
- **MaxMind GeoIP** - IP geolocation data
- **Tux** - Penguin artwork by Larry Ewing (The GIMP), used with attribution

**Third-Party Disclaimers:**
NFTBan is an independent project. We are **not affiliated with, endorsed by, or sponsored by** Fail2Ban, nftables, the Linux Foundation, or Linus Torvalds. All referenced trademarks belong to their respective owners. See [NOTICE.md](NOTICE.md) for complete attributions.

Special thanks to:
- All contributors and testers
- The nftables development team
- The open source community

### 🤖 AI-Assisted Development

This project benefits from AI collaboration. We maintain full transparency about how AI partners contribute:

| AI Partner | Primary Contributions | Role |
|------------|----------------------|------|
| **ChatGPT** (OpenAI) | Architecture planning, roadmap development, design consultation | Strategic Planning |
| **Claude Code** (Anthropic) | Systematic refactoring, code generation, automated validation | Implementation |
| **Claude AI** (Anthropic) | Code review, optimization suggestions, comprehensive analysis | Quality Assurance |

**Specific Contributions:**
- **Architecture Design**: ChatGPT assisted with v0.10.0 complete rewrite planning and FHS architecture design
- **Code Implementation**: Claude Code performed systematic code generation, refactoring, and validation
- **Code Review**: Claude AI provided comprehensive module review and optimization suggestions
- **Documentation**: Both AI partners contributed to technical writing and documentation structure
- **Testing**: Automated validation, syntax checking, and comprehensive testing strategies
- **Packaging**: Claude Code developed complete RPM/DEB packaging infrastructure

### 🤝 AI Collaboration Policy

**Our Commitment to Transparency:**
1. **Fair Attribution**: All AI contributions are credited clearly and honestly
2. **Human Ownership**: NFTBan Project retains full ownership and decision-making authority
3. **AI as Tools**: AI partners are assistive tools, not co-owners or independent contributors
4. **Honest Disclosure**: We disclose AI involvement in architecture, code, and documentation
5. **No Hidden AI Work**: All AI-generated or AI-assisted content is marked appropriately

**What This Means:**
- AI helped design and implement features, but under human direction and review
- Final decisions, architecture choices, and quality standards are set by NFTBan Project
- AI-generated code is reviewed, tested, and validated before inclusion
- This README and all documentation accurately represent both human and AI contributions

We believe in transparency about AI collaboration and credit all our development partners fairly.

---

<p align="center">
  <b>Made with ❤️ by <a href="https://nftban.com">NFTBAN Project</a></b><br>
  <sub>Empowering system administrators with simple, powerful security tools</sub>
</p>

<p align="center">
  <a href="docs/index.md">📚 Documentation</a> •
  <a href="docs/guides/quickstart.md">🚀 Quick Start</a> •
  <a href="docs/concepts/architecture.md">🏗️ Architecture</a> •
  <a href="docs/reference/cli-quick-reference.md">📖 CLI Quick Reference</a> •
  <a href="https://github.com/itcmsgr/nftban/issues">🐛 Report Issue</a> •
  <a href="https://nftban.com">🌐 Website</a>
</p>

<p align="center">
  <sub>⚠️ BETA SOFTWARE - Test before production use!</sub><br>
  <sub>Copyright © 2024–2026 NFTBAN Project / Antonios Voulvoulis</sub>
</p>
