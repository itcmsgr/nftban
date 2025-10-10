# nftban

**Modular Linux Firewall Management System based on nftables & Fail2Ban**

[![Version](https://img.shields.io/badge/version-3.6.0-blue)](https://github.com/itcmsgr/nftban)
[![License](https://img.shields.io/badge/License-CustomMIT--NoResale-lightgrey)](./LICENSE.md)
[![Platform](https://img.shields.io/badge/platform-Linux-blue)](https://github.com/itcmsgr/nftban)
[![Shell](https://img.shields.io/badge/shell-bash-green)](https://www.gnu.org/software/bash/)

Transform complex firewall management into simple commands. nftban combines nftables (modern Linux firewall) with Fail2Ban (intrusion prevention) to provide enterprise-grade security with a user-friendly interface.

```bash
# Install in 30 seconds
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | sudo bash -s -- --github -y

# Configure firewall
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Setup intrusion prevention
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh setup

# Start protecting your server
sudo nftban --add-ip                           # Whitelist your IP
sudo nftban --temp-ban 192.0.2.50 "Attacker"  # Ban malicious IP
```

---

## 🎯 What is nftban?

nftban is a **complete firewall management ecosystem** that makes advanced network security accessible to everyone. It automatically detects your control panel, configures appropriate ports, integrates Fail2Ban with nftables, and provides a simple CLI for daily operations.

### Why nftban?

| Traditional Approach | nftban |
|---------------------|---------|
| Hours of manual configuration | 5-minute automated setup |
| Complex nftables syntax | Simple commands |
| Manual control panel port discovery | Automatic detection |
| Separate firewall and IPS management | Unified system |
| Easy to lock yourself out | Built-in safety mechanisms |
| Configuration drift over time | Version-controlled templates |

---

## ✨ Key Features

### 🛡️ Multi-Layer Security

- **nftables Firewall** - Modern, efficient packet filtering
- **Fail2Ban Integration** - Automatic attacker banning
- **Login Monitoring** - Track SSH, sudo, and root access
- **Whitelist/Blacklist Management** - IP-based access control
- **Rate Limiting** - Prevent abuse and DOS attacks

### 🎛️ Control Panel Support

- **DirectAdmin** - Full support with auto-detection
- **cPanel/WHM** - Complete port configuration
- **Plesk** - Ready to use out of the box
- **Generic** - Works on any server (with or without panel)

### 💻 User-Friendly Management

- **Simple CLI** - Ban/unban IPs with one command
- **Status Monitoring** - Real-time system visibility
- **Email Alerts** - Get notified of security events
- **Auto-Update** - Keep system current automatically
- **Configuration Validation** - Prevent mistakes before applying

### 🔒 Safety First

- ✅ Cannot ban your own IP
- ✅ Whitelist protection
- ✅ Automatic backups before changes
- ✅ Configuration validation
- ✅ Dry-run mode available
- ✅ Emergency recovery procedures

---

## 🚀 Quick Start

### Prerequisites

- Linux server (Debian/Ubuntu/RHEL/CentOS/Rocky/AlmaLinux/Fedora/openSUSE/Alpine)
- Root access (sudo)
- Internet connection

### Installation (3 Steps)

```bash
# Step 1: Install nftban (prepares system)
sudo ./nftban_init.sh --github -y

# Step 2: Configure firewall (applies rules)
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Step 3: Setup intrusion prevention (configures Fail2Ban)
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh setup
sudo systemctl restart fail2ban
```

**Done!** Your server is now protected.

### Quick Operations

```bash
# Check system status
sudo nftban status

# Whitelist your IP (prevents lockout)
sudo nftban --add-ip

# Temporarily ban an attacker (1 hour)
sudo nftban --temp-ban 192.0.2.50 "SSH brute-force"

# Permanently ban confirmed attacker
sudo nftban --perm-ban 192.0.2.50 "Malicious actor"

# View all bans
sudo nftban --view-banned

# Remove ban
sudo nftban --remove-ip 192.0.2.50

# Check where an IP exists
sudo nftban --verify-ip 192.0.2.50

# Validate configuration
sudo nftban --validate-sync

# Reload from config files
sudo nftban --sync
```

---

## 📁 System Architecture

```
┌─────────────────────────────────────────────────────────┐
│                      nftban System                      │
│                                                         │
│  ┌────────────────────────────────────────────────┐   │
│  │  nftban_init.sh                                │   │
│  │  System Preparation & Package Installation     │   │
│  └────────────────┬───────────────────────────────┘   │
│                   ↓                                     │
│  ┌────────────────────────────────────────────────┐   │
│  │  nftban_init_nftables_conf.sh                  │   │
│  │  Firewall Configuration & Rule Generation      │   │
│  └────────────────┬───────────────────────────────┘   │
│                   ↓                                     │
│  ┌────────────────────────────────────────────────┐   │
│  │  nftban_init_fail2ban_conf.sh                  │   │
│  │  Intrusion Prevention & Login Monitoring       │   │
│  └────────────────┬───────────────────────────────┘   │
│                   ↓                                     │
│  ┌────────────────────────────────────────────────┐   │
│  │  nftban CLI                                     │   │
│  │  Daily Management & Operations                 │   │
│  └────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────┘
```

---

## 📖 Documentation

**For detailed information, see the `docs/` folder:**

### Core Documentation

- **[Complete Guide](docs/README_COMPLETE.md)** - Comprehensive 60+ page documentation covering everything
- **[System Preparation](docs/README_nftban_init.md)** - nftban_init.sh detailed guide
- **[Firewall Configuration](docs/README_nftban_init_nftables_conf.md)** - nftban_init_nftables_conf.sh detailed guide
- **[Intrusion Prevention](docs/README_nftban_fail2ban.md)** - nftban_init_fail2ban_conf.sh detailed guide
- **[CLI Reference](docs/README_nftban_cli.md)** - nftban command-line tool complete guide

### Additional Resources

- **[Installation Guide](docs/INSTALLATION.md)** - Step-by-step installation for all scenarios
- **[Configuration Guide](docs/CONFIGURATION.md)** - Complete configuration reference
- **[Control Panel Integration](docs/CONTROL_PANELS.md)** - Panel-specific guides
- **[Troubleshooting](docs/TROUBLESHOOTING.md)** - Common issues and solutions
- **[Architecture Overview](docs/ARCHITECTURE.md)** - System design and data flow
- **[Security Best Practices](docs/SECURITY.md)** - Hardening and optimization

### Quick References

- **[Quick Start Guide](docs/QUICKSTART.md)** - Get running in 5 minutes
- **[Command Cheatsheet](docs/CHEATSHEET.md)** - Common commands at a glance
- **[FAQ](docs/FAQ.md)** - Frequently asked questions
- **[Migration Guide](docs/MIGRATION.md)** - Upgrading from older versions

---

## 🎯 Use Cases

### For System Administrators

```bash
# Protect a new server
sudo nftban_init.sh --github -y
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
sudo nftban --add-ip  # Whitelist your IP

# Add custom application port
echo "8080T" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local
sudo nftban --sync

# Monitor security
sudo nftban status
sudo nftban --view-banned
sudo nftban --fail2ban-jails
```

### For Hosting Providers

```bash
# Automatic control panel detection
sudo nftban_init.sh --github -y
# Detects DirectAdmin/cPanel/Plesk automatically

# Deploy to multiple servers
# Templates ensure consistency
# Auto-update keeps systems current

# Client-safe operations
# Built-in whitelist protection
# Cannot lock out administrators
```

### For Security Engineers

```bash
# Enable comprehensive monitoring
sudo nftban_init_fail2ban_conf.sh login-monitor enable hybrid
sudo nano /etc/nftban/config/nftban.conf.local
# Configure alerts and thresholds

# Custom jails for your applications
# Integration with SIEM systems
# Detailed logging and statistics

# Validate security posture
sudo nftban --validate-sync
sudo nftban_init_fail2ban_conf.sh stats
```

---

## 🛠️ Components

nftban consists of four main components that work together:

### 1. nftban_init.sh - System Preparation

**Purpose**: Bootstrap the system

**What it does**:
- Installs required packages (nftables, fail2ban, utilities)
- Creates directory structure
- Detects control panel automatically
- Creates configuration templates
- Sets up auto-update (optional)

**When to use**: First-time setup, new server installation

[📚 Detailed Documentation](docs/README_nftban_init.md)

### 2. nftban_init_nftables_conf.sh - Firewall Configuration

**Purpose**: Configure and manage nftables firewall

**What it does**:
- Reads control panel template + your customizations
- Generates nftables rules
- Creates global table structure with sets
- Applies firewall configuration
- Validates before applying

**When to use**: After init, when changing configuration

[📚 Detailed Documentation](docs/README_nftban_init_nftables_conf.md)

### 3. nftban_init_fail2ban_conf.sh - Intrusion Prevention

**Purpose**: Configure Fail2Ban with nftables backend

**What it does**:
- Sets up Fail2Ban jails (SSH, WordPress, etc.)
- Configures email alerts
- Installs login monitoring (3 modes)
- Manages ban/unban actions
- Provides statistics and reporting

**When to use**: After firewall setup, for security monitoring

[📚 Detailed Documentation](docs/README_nftban_fail2ban.md)

### 4. nftban CLI - Daily Operations

**Purpose**: User-friendly interface for daily management

**What it does**:
- Ban/unban IP addresses
- Manage whitelist/blacklist
- Check system status
- Validate configuration sync
- View statistics and logs

**When to use**: Daily operations, incident response

[📚 Detailed Documentation](docs/README_nftban_cli.md)

---

## 🎓 Examples

### Example 1: New Server Setup

```bash
# Install on fresh server
curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/nftban_init.sh | sudo bash -s -- --github -y

# Configure firewall (DirectAdmin detected automatically)
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final

# Add your IP to whitelist
sudo nftban --add-ip

# Setup fail2ban
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh setup
sudo systemctl restart fail2ban

# Check status
sudo nftban status
```

### Example 2: Handle Brute Force Attack

```bash
# View attack in real-time
sudo tail -f /var/log/auth.log

# Manually ban attacker
sudo nftban --temp-ban 192.0.2.50 "SSH brute-force from unknown country"

# Check if banned
sudo nftban --list-temp

# Make permanent if attack continues
sudo nftban --perm-ban 192.0.2.50 "Persistent attacker"

# View all current bans
sudo nftban --view-banned
```

### Example 3: Add Custom Application

```bash
# Application requires ports 8080, 9000, 5432
cat >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local <<EOF
8080T    # Application HTTP
9000T    # Application API
5432T    # PostgreSQL
EOF

# Apply changes
sudo nftban --sync

# Verify
sudo nft list ruleset | grep -E '8080|9000|5432'
```

### Example 4: Monitor Security

```bash
# Check system status
sudo nftban status

# View ban statistics
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh stats

# Check fail2ban jails
sudo nftban --fail2ban-jails

# View banned IPs in SSH jail
sudo nftban --fail2ban-banned sshd

# Comprehensive IP check
sudo nftban --verify-ip 192.0.2.50
```

---

## 🔧 Configuration

nftban uses a **two-file configuration pattern**:

```
Base Configuration (.conf)          User Configuration (.conf.local)
─────────────────────────────       ────────────────────────────────
• Auto-managed by scripts           • Your customizations
• Updated on upgrades               • Never overwritten
• Reference defaults                • Override base settings
• Can be regenerated                • Survive updates
```

### Configuration Files

```
/etc/nftban/config/
├── nftban-configuration-ipv4-ports-input-allow.conf        # Base (auto)
├── nftban-configuration-ipv4-ports-input-allow.conf.local  # User (yours)
├── nftban-configuration-user-whitelist_ips.conf.local      # Your IPs
├── nftban-configuration-user-blacklist_ips.conf.local      # Banned IPs
├── nftban.conf                                              # Fail2Ban base
└── nftban.conf.local                                        # Fail2Ban user
```

### Adding Custom Ports

```bash
# TCP port 8080
echo "8080T" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# UDP port 53
echo "53U" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Both TCP and UDP port 3306
echo "3306B" >> /etc/nftban/config/nftban-configuration-ipv4-ports-input-allow.conf.local

# Apply
sudo nftban --sync
```

### Whitelisting IPs

```bash
# Single IP
echo "203.0.113.100" >> /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local

# Subnet
echo "192.168.1.0/24" >> /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local

# IPv6
echo "2001:db8::1" >> /etc/nftban/config/nftban-configuration-user-whitelist_ips.conf.local

# Apply
sudo nftban --sync
```

[📚 Full Configuration Guide](docs/CONFIGURATION.md)

---

## 🎛️ Control Panel Support

nftban automatically detects and configures for:

| Panel | Detection | Status | Pre-configured Ports |
|-------|-----------|--------|---------------------|
| **DirectAdmin** | `/usr/local/directadmin/` | ✅ Full Support | 2222, FTP (21, 35000-35999), Email, DNS |
| **cPanel/WHM** | `/var/cpanel/` | ✅ Full Support | 2082-2087, 2095-2096, MySQL, Email, DNS |
| **Plesk** | `/usr/local/psa/` | ✅ Full Support | 8443, 8880, MySQL, PostgreSQL, Email |
| **Generic** | No panel found | ✅ Full Support | SSH, HTTP, HTTPS, SMTP, DNS |

[📚 Control Panel Integration Guide](docs/CONTROL_PANELS.md)

---

## 📊 System Requirements

### Supported Operating Systems

| Distribution | Versions | Package Manager | Status |
|--------------|----------|-----------------|--------|
| Debian | 10+ | apt-get | ✅ Fully Supported |
| Ubuntu | 20.04+ | apt-get | ✅ Fully Supported |
| CentOS | 8+ | dnf/yum | ✅ Fully Supported |
| AlmaLinux | 8+ | dnf | ✅ Fully Supported |
| Rocky Linux | 8+ | dnf | ✅ Fully Supported |
| RHEL | 8+ | dnf/yum | ✅ Fully Supported |
| Fedora | 35+ | dnf | ✅ Fully Supported |
| openSUSE | Leap 15+ | zypper | ✅ Fully Supported |
| Alpine | 3.15+ | apk | ✅ Fully Supported |

### Minimum Requirements

- **CPU**: 1 core
- **RAM**: 512 MB
- **Disk**: 1 GB free space
- **Network**: Internet connection (for installation)
- **System**: systemd

### Recommended Requirements

- **CPU**: 2+ cores
- **RAM**: 2 GB
- **Disk**: 5 GB free space (SSD preferred)

---

## 🛡️ Security Features

### Multi-Layer Protection

```
Layer 1: Whitelist (Highest Priority)
  ├─ User whitelist
  ├─ System whitelist
  └─ Action: ACCEPT unconditionally

Layer 2: Temporary Bans
  ├─ Fail2Ban automatic bans
  ├─ Manual temp-ban commands
  └─ Action: DROP with timeout (default 1 hour)

Layer 3: Permanent Bans
  ├─ User blacklist
  ├─ System blacklist
  └─ Action: DROP permanently

Layer 4: Port Rules
  ├─ Control panel ports
  ├─ User-defined ports
  └─ Action: ACCEPT if allowed

Layer 5: Default Policy
  └─ Action: DROP all other traffic
```

### Built-in Protections

- ✅ **Self-Protection**: Cannot ban your own IP
- ✅ **Whitelist Protection**: Cannot ban whitelisted IPs
- ✅ **Input Validation**: All IPs validated before processing
- ✅ **Rate Limiting**: Prevent ban storms (max 10/minute)
- ✅ **Automatic Backups**: Before every change (30-day retention)
- ✅ **Configuration Validation**: Syntax check before applying
- ✅ **Dry-Run Mode**: Preview changes without applying

[📚 Security Best Practices](docs/SECURITY.md)

---

## 🔍 Troubleshooting

### Common Issues

**Cannot SSH after installation**:
```bash
# From console or VNC
sudo nft flush ruleset
sudo /etc/nftban/scripts/nftban_init_nftables_conf.sh --install-final
```

**Fail2Ban not banning**:
```bash
sudo systemctl status fail2ban
sudo fail2ban-client status
sudo nano /etc/nftban/config/nftban.conf.local
# Set NFTBAN_F2B_SSH_JAIL="true"
sudo systemctl restart fail2ban
```

**Configuration not applied**:
```bash
sudo nftban --validate-sync
sudo nftban --sync
```

**Email alerts not working**:
```bash
sudo apt-get install postfix  # Debian/Ubuntu
sudo dnf install postfix      # RHEL/CentOS
sudo /etc/nftban/scripts/nftban_init_fail2ban_conf.sh test-mail admin@example.com
```

[📚 Complete Troubleshooting Guide](docs/TROUBLESHOOTING.md)

---

## 🤝 Contributing

We welcome contributions! Here's how you can help:

### Ways to Contribute

- 🐛 Report bugs
- 💡 Suggest features
- 📖 Improve documentation
- 🔧 Submit pull requests
- ⭐ Star the repository
- 📢 Spread the word

### Development Process

1. Fork the repository
2. Create feature branch (`git checkout -b feature/amazing-feature`)
3. Test on multiple distributions
4. Update documentation
5. Commit changes (`git commit -m 'Add amazing feature'`)
6. Push to branch (`git push origin feature/amazing-feature`)
7. Open Pull Request

### Reporting Issues

Please include:
- Operating system and version
- Control panel (if any)
- nftban version (`nftban version`)
- Steps to reproduce
- Expected vs actual behavior
- Relevant logs from `/var/log/nftban/`

[GitHub Issues](https://github.com/itcmsgr/nftban/issues)

---

## 📜 License

**ITCMS Custom License – No Resale v1.2**  
SPDX-License-Identifier: LicenseRef-CustomMIT-NoResale-1.2

Copyright © 2025 **Antonios Voulvoulis – ITCMS**  
https://itcms.gr

### Quick Summary

✅ **You CAN**:
- Use for personal or commercial projects
- Modify and customize
- Deploy on unlimited systems
- Charge for services using nftban
- Include in managed service offerings

❌ **You CANNOT**:
- Sell the software itself
- Sublicense or resell
- Distribute as a paid product
- Remove copyright notices

### The Simple Test

**Ask**: *"Am I charging for the software itself, or for my service using the software?"*

- ✅ **OK**: $500 setup fee for configuring nftban on client server
- ✅ **OK**: $100/month managed security service including nftban
- ❌ **NOT OK**: Selling "nftban Pro Edition" for $299
- ❌ **NOT OK**: Charging $50 to download the software

### Need Permission?

📧 **Email**: contact@itcms.gr  
🌐 **Web**: https://itcms.gr

We're open to partnership and commercial licensing discussions!

[📚 Full License Text](LICENSE.md)

---

## 📞 Support

### Community Support

- **Issues**: [GitHub Issues](https://github.com/itcmsgr/nftban/issues)
- **Discussions**: [GitHub Discussions](https://github.com/itcmsgr/nftban/discussions)
- **Documentation**: [Complete Guide](docs/README_COMPLETE.md)
- **Wiki**: [GitHub Wiki](https://github.com/itcmsgr/nftban/wiki)

### Professional Support

- **Author**: Antonios Voulvoulis (ITCMS Team)
- **Company**: IT Consulting Managed Services
- **Email**: support@itcms.gr
- **Website**: [https://itcms.gr](https://itcms.gr)

### Useful Resources

- [nftables Wiki](https://wiki.nftables.org/)
- [Fail2ban Documentation](https://fail2ban.readthedocs.io/)
- [systemd Documentation](https://www.freedesktop.org/software/systemd/man/)

---

## 🎓 Learning Resources

### Getting Started

- [Quick Start Guide](docs/QUICKSTART.md) - Get running in 5 minutes
- [Installation Guide](docs/INSTALLATION.md) - Detailed setup instructions
- [First Steps Tutorial](docs/tutorials/first-steps.md) - Your first 10 minutes with nftban

### Advanced Topics

- [Architecture Overview](docs/ARCHITECTURE.md) - How nftban works internally
- [Security Hardening](docs/SECURITY.md) - Best practices and optimization
- [Custom Jails](docs/tutorials/custom-jails.md) - Create your own Fail2Ban rules
- [Integration Guide](docs/tutorials/integration.md) - Connect with monitoring systems

### Video Tutorials (Coming Soon)

- Complete installation walkthrough
- Control panel detection explained
- Custom configuration tutorial
- Troubleshooting common issues

---

## 🌟 Why Choose nftban?

### vs. Manual Configuration

- ⏱️ **Time**: 5 minutes vs. hours
- 🎯 **Accuracy**: Automated vs. error-prone
- 🔄 **Updates**: Automatic vs. manual
- 📊 **Monitoring**: Built-in vs. DIY
- 🛡️ **Safety**: Protected vs. risky

### vs. Other Firewall Tools

- 🚀 **Modern**: nftables (not iptables)
- 🎛️ **Integrated**: Firewall + IPS unified
- 🎨 **User-Friendly**: Simple CLI
- 🏢 **Panel-Aware**: Auto-detection
- 📚 **Documented**: Comprehensive guides

### vs. Commercial Solutions

- 💰 **Cost**: Free (open source)
- 🔓 **Freedom**: Fully customizable
- 👥 **Community**: Active support
- 🔒 **Privacy**: Your data stays yours
- ⚖️ **License**: Use in business

---

## 📈 Project Stats

![GitHub stars](https://img.shields.io/github/stars/itcmsgr/nftban?style=social)
![GitHub forks](https://img.shields.io/github/forks/itcmsgr/nftban?style=social)
![GitHub issues](https://img.shields.io/github/issues/itcmsgr/nftban)
![GitHub pull requests](https://img.shields.io/github/issues-pr/itcmsgr/nftban)
![GitHub last commit](https://img.shields.io/github/last-commit/itcmsgr/nftban)
![GitHub downloads](https://img.shields.io/github/downloads/itcmsgr/nftban/total)

---

## 🎯 Roadmap

### Current Version (3.6.0)

- ✅ Multi-layer security
- ✅ Control panel auto-detection
- ✅ Fail2Ban integration
- ✅ Login monitoring
- ✅ Email alerts
- ✅ Auto-update system
- ✅ Comprehensive CLI

### Upcoming Features

- 🔄 Web-based dashboard
- 🌍 GeoIP blocking rules
- 📊 Advanced statistics and graphs
- 🔔 Webhook integrations
- 📱 Mobile app notifications
- 🤖 AI-powered threat detection
- 🔐 Two-factor authentication support
- 📦 Docker containerization

### Community Requests

Vote for features on [GitHub Discussions](https://github.com/itcmsgr/nftban/discussions)

---

## 🏆 Testimonials

> *"nftban saved me hours of configuration. Set it up in 5 minutes on my DirectAdmin server and it just works!"*  
> — **System Administrator, Hosting Company**

> *"Best firewall management tool I've used. The automatic control panel detection is brilliant."*  
> — **DevOps Engineer**

> *"Finally, a modern firewall tool that doesn't require a PhD to operate. The CLI is intuitive and the documentation is excellent."*  
> — **Security Consultant**

---

## 🎉 Quick Links

### Essential

- 📚 [Complete Documentation](docs/README_COMPLETE.md)
- 🚀 [Quick Start](docs/QUICKSTART.md)
- 📖 [Installation Guide](docs/INSTALLATION.md)
- 🔧 [Configuration Guide](docs/CONFIGURATION.md)

### Components

- 🏗️ [System Preparation](docs/README_nftban_init.md)
- 🛡️ [Firewall Setup](docs/README_nftban_init_nftables_conf.md)
- 🔐 [Intrusion Prevention](docs/README_nftban_fail2ban.md)
- 💻 [CLI Reference](docs/README_nftban_cli.md)

### Support

- 🐛 [Report Issue](https://github.com/itcmsgr/nftban/issues)
- 💬 [Discussions](https://github.com/itcmsgr/nftban/discussions)
- 📧 [Email Support](mailto:support@itcms.gr)
- 🌐 [ITCMS Website](https://itcms.gr)

---

## 💝 Acknowledgments

Built with love using:
- [nftables](https://netfilter.org/projects/nftables/) - Modern Linux firewall
- [Fail2Ban](https://www.fail2ban.org/) - Intrusion prevention system
- [systemd](https://systemd.io/) - System and service manager

Special thanks to:
- All contributors and testers
- The nftables and Fail2Ban communities
- Users who provided feedback

---

## ⭐ Star History

If you find nftban useful, please consider giving it a star!

[![Star History Chart](https://api.star-history.com/svg?repos=itcmsgr/nftban&type=Date)](https://star-history.com/#itcmsgr/nftban&Date)

---

<p align="center">
  <b>Made with ❤️ by <a href="https://itcms.gr">ITCMS Team</a></b><br>
  <sub>Empowering system administrators with simple, powerful security tools</sub>
</p>

<p align="center">
  <a href="https://github.com/itcmsgr/nftban">🏠 Home</a> •
  <a href="docs/README_COMPLETE.md">📚 Docs</a> •
  <a href="https://github.com/itcmsgr/nftban/issues">🐛 Issues</a> •
  <a href="https://github.com/itcmsgr/nftban/discussions">💬 Discuss</a> •
  <a href="https://itcms.gr">🌐 Website</a>
</p>

<p align="center">
  <sub>Copyright © 2025 Antonios Voulvoulis – ITCMS. All rights reserved.</sub>
</p>
