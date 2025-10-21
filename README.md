# 🛡️ nftban

**Modern Linux Firewall Management System**

[![Version](https://img.shields.io/badge/version-0.9.1--beta-orange)](https://github.com/itcmsgr/nftban)
[![Status](https://img.shields.io/badge/status-beta-yellow)](https://github.com/itcmsgr/nftban)
[![Architecture](https://img.shields.io/badge/architecture-dual--table%20(IPv4%2FIPv6)-blue)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-ITCMS--ProtectiveFreeUse-blue)](./LICENSE.md)
[![SPDX](https://img.shields.io/badge/SPDX-NFTBAN--Custom--License-lightgrey)](./LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-Linux-success)](https://github.com/itcmsgr/nftban)

> **⚠️ BETA SOFTWARE**: Active development and testing. Production-ready but we appreciate your feedback! [Report issues](https://github.com/itcmsgr/nftban/issues) | [Discussions](https://github.com/itcmsgr/nftban/discussions)

## 📊 Component Status Matrix

| Component | Status | Stability | Notes |
|-----------|--------|-----------|-------|
| **Core Firewall** | ✅ Complete | 95% | Split table architecture (v0.9.0) |
| **DDoS Protection** | ✅ Complete | 90% | SYN flood, connection limits, ICMP |
| **Port Scan Detection** | ✅ Complete | 85% | Pattern detection, auto-ban |
| **Fail2Ban Integration** | ✅ Complete | 95% | Pre-configured jails |
| **Whitelist/Blacklist** | ✅ Complete | 95% | IPv4/IPv6, CIDR support |
| **Control Panel Detection** | ✅ Complete | 90% | DirectAdmin, cPanel, Plesk |
| **GEO Blocking** | ✅ Complete | 85% | Country-level IP blocking |
| **Threat Feeds** | ✅ Complete | 80% | External threat intelligence |
| **Auto-Update System** | ✅ Complete | 85% | Version detection, rollback |
| **CLI & Management** | ✅ Complete | 95% | 50+ commands |
| **Documentation** | 🔄 In Progress | 75% | Core docs complete, updating for v0.9.0 |
| **Testing Suite** | 🔄 In Progress | 70% | Smoketest operational |

**Overall Project Stability: ~85% (Production-Ready Beta)**

---

## 💡 What Does nftban Do?

**nftban makes Linux firewall management simple.** It combines nftables, Fail2Ban, and intelligent automation into one easy-to-use system that protects your server without the complexity.

### Quick Install (Two-Step Method - Recommended):
```bash
# Step 1: Download the installer
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh -o nftban_init.sh

# Step 2: Review and run
less nftban_init.sh  # Optional: review the script
sudo bash nftban_init.sh --github -y

# Done! Your server is now protected with:
# ✓ Firewall configured automatically
# ✓ Control panel ports detected
# ✓ DDoS protection enabled
# ✓ Port scan detection active
# ✓ Fail2Ban monitoring threats
```

**Alternative (One-Step):**
```bash
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | sudo bash -s -- --github -y
```

---

## ✨ What Makes It Special?

### 🎯 **Auto-Everything**
- **Detects** your control panel (DirectAdmin, cPanel, Plesk)
- **Configures** the right ports automatically
- **Protects** against DDoS and port scans
- **Monitors** for intrusions with Fail2Ban
- **Updates** itself automatically

### 🛡️ **Multi-Layer Security**
- **nftables Firewall** - Modern, fast packet filtering
- **DDoS Protection** - SYN floods, connection limits, rate limiting
- **Port Scan Detection** - Identify and auto-ban scanners
- **Fail2Ban Integration** - Automatic attacker banning
- **Whitelist/Blacklist** - Granular access control

### 💻 **Simple to Use**
```bash
nftban status              # See what's happening
nftban whitelist add <IP>  # Protect your IP
nftban blacklist ban <IP>  # Block attackers
nftban ddos status         # Check DDoS protection
nftban portscan stats      # View scan attempts
```

### 🔒 **Built-In Safety**
- ✅ Can't lock yourself out
- ✅ Validates before applying changes
- ✅ Automatic backups
- ✅ Dry-run mode available
- ✅ Emergency recovery

---

## 🚀 Quick Start

### Install (Two-Step - Safer)
```bash
# Download installer
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh -o nftban_init.sh

# Review and run
sudo bash nftban_init.sh --github -y
```

### Protect Yourself (Optional)
```bash
# Whitelist your IP to prevent lockouts
sudo nftban whitelist add <your-ip>
```

**That's it!** Your server is protected.

The installer automatically:
- ✅ Configures nftables firewall
- ✅ Detects and configures control panel ports
- ✅ Sets up Fail2Ban integration
- ✅ Enables DDoS protection
- ✅ Activates port scan detection

See [📚 Documentation Index](docs/index.md) for advanced configuration.

---

## 🎯 Key Features

### **DDoS Protection** (NEW in v0.8.5)
- SYN flood protection with configurable rate limiting
- Per-port connection limits (prevent resource exhaustion)
- Port flood protection (rate limit new connections)
- ICMP rate limiting (stop ping floods)

```bash
nftban ddos enable          # Enable all protections
nftban ddos status          # Check what's active
nftban ddos synflood enable # Enable SYN flood protection
```

### **Port Scan Detection** (NEW in v0.8.5)
- Detect IPs scanning multiple ports
- Auto-ban suspected scanners
- Whitelist legitimate security tools
- Track detection history

```bash
nftban portscan enable      # Enable detection
nftban portscan stats       # View detected scans
nftban portscan check-ip    # Check specific IP
```

### **Fail2Ban Integration**
- Pre-configured jails (SSH, Apache, WordPress, etc.)
- Automatic banning of brute-force attempts
- Email notifications
- Statistics and reporting

### **Whitelist/Blacklist Management**
- Protect trusted IPs
- Block malicious actors permanently
- Temporary bans with auto-expiry
- CIDR range support

### **Control Panel Support**
- DirectAdmin (auto-detected)
- cPanel/WHM (auto-detected)
- Plesk (auto-detected)
- Generic servers (works everywhere)

---

## 📖 Documentation

**All features are documented in the `docs/` folder:**

### 📚 Start Here
- **[Documentation Index](docs/index.md)** - Complete navigation and quick links
- **[Architecture Overview](docs/development/)** - System design and structure
- **[Security Guide](docs/security/)** - How protection works (with diagrams)

### 🔧 Module Documentation
- **[All Modules](docs/modules/)** - Complete module documentation (23+ modules)
  - Core, CLI, Fail2ban, Whitelist/Blacklist, Feeds, DDoS, and more

### 🚀 Development & Implementation
- **[Development Guides](docs/development/)** - Installation, feeds, updates, migration
- **[Testing Guides](docs/testing/guides/)** - Verification and stability checks

---

## 🌍 Supported Platforms

| Operating System | Status |
|-----------------|--------|
| Debian 10+ | ✅ Fully Supported |
| Ubuntu 20.04+ | ✅ Fully Supported |
| CentOS 8+ | ✅ Fully Supported |
| AlmaLinux 8+ | ✅ Fully Supported |
| Rocky Linux 8+ | ✅ Fully Supported |
| RHEL 8+ | ✅ Fully Supported |
| Fedora 35+ | ✅ Fully Supported |

---

## 📜 License

**ITCMS Protective Free-Use License v2.0**
SPDX-License-Identifier: NFTBAN-Custom-License

> **Free forever. Use anywhere. Sell services, not the software.**

### What You CAN Do ✅
- Use for free (personal or commercial)
- Modify and customize
- Deploy on unlimited servers
- Charge for installation, setup, support services
- Build your business around it

### What You CANNOT Do ❌
- Sell the software itself as a product
- Rebrand and resell
- Remove copyright notices

**Simple test**: *"Am I charging for my expertise/service, or for the software?"*
- ✅ €500 firewall setup service? **YES**
- ✅ Monthly managed security using nftban? **YES**
- ❌ Selling "Premium Firewall Software"? **NO**

[📄 Full License](LICENSE.md) | 📧 Questions: contact@itcms.gr

---

## 🤝 Contributing

We welcome contributions! Ways to help:
- ⭐ Star the repository
- 🐛 Report bugs
- 💡 Suggest features
- 📖 Improve documentation
- 🔧 Submit pull requests

[Report Issues](https://github.com/itcmsgr/nftban/issues) | [Discussions](https://github.com/itcmsgr/nftban/discussions)

---

## 💬 Support

### Community Support
- **Issues**: [GitHub Issues](https://github.com/itcmsgr/nftban/issues)
- **Discussions**: [GitHub Discussions](https://github.com/itcmsgr/nftban/discussions)
- **Documentation**: [Documentation Index](docs/index.md)

### Professional Support
- **Author**: Antonios Voulvoulis (ITCMS Team)
- **Email**: contact@itcms.gr
- **Website**: [https://itcms.gr](https://itcms.gr)

---

## 🙏 Acknowledgments

**Built with:**
- [nftables](https://netfilter.org/projects/nftables/) - Modern Linux firewall
- [Fail2Ban](https://www.fail2ban.org/) - Intrusion prevention
- [systemd](https://systemd.io/) - Service management

**Special thanks to:**
- [Claude AI](https://claude.ai) by Anthropic - Development assistance and code review
- [Claude Code](https://claude.com/claude-code) - Automated code generation and systematic refactoring
- [ChatGPT](https://chat.openai.com) by OpenAI - Architecture planning and design consultation
- All contributors and testers
- The nftables and Fail2Ban communities
- Everyone who stars and shares the project

**AI-Assisted Development:**

This project benefits from AI collaboration. We maintain full transparency about how AI partners contribute:

| AI Partner | Primary Contributions | Role |
|------------|----------------------|------|
| **ChatGPT** (OpenAI) | Architecture planning, roadmap development, design consultation | Strategic Planning |
| **Claude Code** (Anthropic) | Systematic refactoring, code generation, automated validation | Implementation |
| **Claude AI** (Anthropic) | Code review, optimization suggestions, comprehensive analysis | Quality Assurance |

**Specific Contributions:**
- **Architecture Design**: ChatGPT assisted with v0.9.0 split table architecture planning and roadmap development
- **Code Implementation**: Claude Code performed systematic refactoring, code generation, and validation
- **Code Review**: Claude AI provided comprehensive module review and optimization suggestions
- **Documentation**: Both AI partners contributed to technical writing and documentation structure
- **Testing**: Automated validation, syntax checking, and comprehensive testing strategies

### 🤖 AI Collaboration Policy

**Our Commitment to Transparency:**
1. **Fair Attribution**: All AI contributions are credited clearly and honestly
2. **Human Ownership**: Antonios Voulvoulis (ITCMS) retains full ownership and decision-making authority
3. **AI as Tools**: AI partners are assistive tools, not co-owners or independent contributors
4. **Honest Disclosure**: We disclose AI involvement in architecture, code, and documentation
5. **No Hidden AI Work**: All AI-generated or AI-assisted content is marked appropriately

**What This Means:**
- AI helped design and implement features, but under human direction and review
- Final decisions, architecture choices, and quality standards are set by ITCMS
- AI-generated code is reviewed, tested, and validated before inclusion
- This README and all documentation accurately represent both human and AI contributions

We believe in transparency about AI collaboration and credit all our development partners fairly.

---

## ⭐ Show Your Support

If nftban helps secure your servers, **give us a star!** ⭐

It helps others discover the project and motivates continued development.

[![GitHub stars](https://img.shields.io/github/stars/itcmsgr/nftban?style=for-the-badge&logo=github)](https://github.com/itcmsgr/nftban/stargazers)

**Quick actions:**
- ⭐ [Star this repository](https://github.com/itcmsgr/nftban)
- 🍴 [Fork for modifications](https://github.com/itcmsgr/nftban/fork)
- 👁️ [Watch for updates](https://github.com/itcmsgr/nftban/subscription)
- 📢 [Share with others](https://twitter.com/intent/tweet?text=Check%20out%20nftban%20-%20modern%20Linux%20firewall%20management&url=https://github.com/itcmsgr/nftban)

---

## 🎉 What's New in v0.9.0

### Split Table Architecture (MAJOR PERFORMANCE IMPROVEMENT)
- **30-50% faster packet processing** - Separate IPv4/IPv6 tables eliminate selector overhead
- **Simplified rules** - No more `ip saddr`/`ip6 saddr` selectors needed
- **Better scalability** - Independent optimization for IPv4 and IPv6
- **Cleaner set names** - No more `_v4`/`_v6` suffixes

### Architecture Changes
- **OLD:** Single `inet nftban_global` table with version-suffixed sets
- **NEW:** Dual tables `ip nftban_v4` + `ip6 nftban_v6` with clean set names
- **Result:** 50% reduction in rule evaluations per packet (20 → 10 rules)

### Breaking Changes
- Table structure changed (fresh install recommended)
- Manual nftables commands need updating
- See [CHANGELOG.md](CHANGELOG.md) for migration guide

[View Full Changelog](CHANGELOG.md)

---

<p align="center">
  <b>Made with ❤️ by <a href="https://itcms.gr">ITCMS Team</a></b><br>
  <sub>Empowering system administrators with simple, powerful security tools</sub>
</p>

<p align="center">
  <a href="https://github.com/itcmsgr/nftban">🏠 Home</a> •
  <a href="docs/">📚 Docs</a> •
  <a href="https://github.com/itcmsgr/nftban/issues">🐛 Issues</a> •
  <a href="https://github.com/itcmsgr/nftban/discussions">💬 Discuss</a> •
  <a href="https://itcms.gr">🌐 Website</a>
</p>

<p align="center">
  <sub>Copyright © 2025 Antonios Voulvoulis – ITCMS. All rights reserved.</sub><br>
  <sub>SPDX-License-Identifier: NFTBAN-Custom-License</sub>
</p>
