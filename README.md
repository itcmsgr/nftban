# 🛡️ nftban

**Modern Linux Firewall Management System**

[![Version](https://img.shields.io/badge/version-0.8.5--beta-orange)](https://github.com/itcmsgr/nftban)
[![Status](https://img.shields.io/badge/status-beta-yellow)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-ITCMS--ProtectiveFreeUse-blue)](./LICENSE.md)
[![SPDX](https://img.shields.io/badge/SPDX-NFTBAN--Custom--License-lightgrey)](./LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-Linux-success)](https://github.com/itcmsgr/nftban)

> **⚠️ BETA SOFTWARE**: Active development and testing. Production-ready but we appreciate your feedback! [Report issues](https://github.com/itcmsgr/nftban/issues) | [Discussions](https://github.com/itcmsgr/nftban/discussions)

---

## 💡 What Does nftban Do?

**nftban makes Linux firewall management simple.** It combines nftables, Fail2Ban, and intelligent automation into one easy-to-use system that protects your server without the complexity.

### In 30 Seconds:
```bash
# Install and protect your server
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | sudo bash -s -- --github -y

# Done! Your server is now protected with:
# ✓ Firewall configured automatically
# ✓ Control panel ports detected
# ✓ DDoS protection enabled
# ✓ Port scan detection active
# ✓ Fail2Ban monitoring threats
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

### Install
```bash
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | sudo bash -s -- --github -y
```

### Configure
```bash
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

### Protect Yourself
```bash
sudo nftban whitelist add <your-ip>
```

**That's it!** Your server is protected. See [📚 Complete Documentation](docs/) for more.

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

### Core Guides
- **[Complete Guide](docs/README_COMPLETE.md)** - Everything in one place
- **[Quick Start](docs/QUICKSTART.md)** - Get running in 5 minutes
- **[Security Guide](docs/SECURITY.md)** - How protection works (with diagrams)

### Feature Guides
- **[DDoS Protection](docs/DDOS_PROTECTION.md)** - Detailed DDoS configuration
- **[Port Scan Detection](docs/PORT_SCAN_DETECTION.md)** - Scanner detection guide
- **[CLI Reference](docs/README_nftban_cli.md)** - All commands explained
- **[Configuration](docs/CONFIGURATION.md)** - Customize everything

### Setup Guides
- **[Installation](docs/README_nftban.md)** - Step-by-step install
- **[Firewall Setup](docs/README_nftban_init_nftables_conf.md)** - nftables configuration
- **[Fail2Ban Setup](docs/README_nftban_fail2ban.md)** - Intrusion prevention
- **[Control Panels](docs/CONTROL_PANELS.md)** - Panel-specific guides

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
- **Documentation**: [Complete Guide](docs/README_COMPLETE.md)

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
- [Claude AI](https://claude.ai) by Anthropic - Development assistance
- [Claude Code](https://claude.com/claude-code) - Automated code generation and review
- All contributors and testers
- The nftables and Fail2Ban communities
- Everyone who stars and shares the project

**With support from AI:**
- Code review and optimization
- Documentation generation
- Test case development
- Architecture design assistance

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

## 🎉 What's New in v0.8.5

### DDoS Protection Module
- SYN flood protection with rate limiting
- Connection limits per port
- Port flood detection and mitigation
- ICMP rate limiting and PCI compliance

### Port Scan Detection
- Automatic detection of port scanners
- Threshold-based identification (10 ports in 300s)
- Auto-ban functionality
- Separate whitelist for security tools

### Enhanced License
- Clearer usage terms
- Better protection against unauthorized resale
- Service-friendly for MSPs and consultants
- Commercial licensing pathway

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
