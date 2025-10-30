# NFTBan v0.10.0 Documentation

**Modern, high-performance firewall management for Linux servers**

[![Version](https://img.shields.io/badge/version-0.10.0-brightgreen)](https://github.com/nftban/nftban)
[![License](https://img.shields.io/badge/License-MPL--2.0-blue)](../LICENSE)
[![FHS Compliant](https://img.shields.io/badge/FHS-compliant-green)](https://refspecs.linuxfoundation.org/FHS_3.0/fhs/index.html)

---

## Quick Start

<div class="grid cards" markdown>

-   :rocket: **[5-Minute Quick Start](guides/quickstart.md)**

    Get NFTBan running in 5 minutes with automatic setup

-   :shield: **[Ban System Guide](guides/ban-system.md)**

    Learn how banning works: whitelist, temp bans, permanent bans

-   :lock: **[Security Profiles](guides/security-profiles.md)**

    Choose from 7 security profiles (paranoid → disabled)

-   :hospital: **[Health Diagnostics](guides/health-diagnostics.md)**

    Check system health with auto-fix capability

</div>

---

## What's New in v0.10.0

### Major Improvements

**🚀 Performance Boost**
- **Go binaries** for feed parsing: **10-60x faster** (1M IPs in <1s)
- **GeoIP lookups** with caching: **Instant** vs 2-5s
- **Split nftables tables**: 50% fewer rule evaluations

**🛡️ Enhanced Security**
- **8 security layers** (added recovery system)
- **7 security profiles** (paranoid, strict, balanced, web, minimal, dev, disabled)
- **Port scan detection** with auto-ban
- **DDoS protection** (SYN, UDP, ICMP, connection limits)

**🔧 Better Operations**
- **Commit-confirm recovery**: Cannot lock yourself out!
- **Health diagnostics** with auto-fix
- **FHS compliance**: Standard Linux directory structure
- **Dynamic discovery**: No hardcoded arrays

**📦 Modular Design**
- **17 core modules** (single responsibility)
- **15 CLI commands** (clean interface)
- **Automatic module loading**
- **Extensible architecture**

---

## Common Tasks

### Installation & Setup

```bash
# Quick install (recommended)
curl -sSL https://nftban.com/install.sh | sudo bash

# Or clone from Git
git clone https://github.com/nftban/nftban.git
cd nftban
sudo ./install.sh
```

[Full Installation Guide →](guides/install.md)

### Ban an IP

```bash
# Temporary ban (1 hour, default)
sudo nftban ban 192.0.2.50

# Permanent ban
sudo nftban ban 192.0.2.50 --permanent

# Ban with reason
sudo nftban ban 192.0.2.50 --reason "SSH brute force"
```

[Ban System Guide →](guides/ban-system.md)

### Check System Health

```bash
# Run health check
sudo nftban health check

# With auto-fix
sudo nftban health check --fix

# Detailed report
sudo nftban health check --verbose
```

[Health Diagnostics Guide →](guides/health-diagnostics.md)

### Set Security Profile

```bash
# List available profiles
sudo nftban profile list

# Set profile
sudo nftban profile set paranoid

# Show current profile
sudo nftban profile show
```

[Security Profiles Guide →](guides/security-profiles.md)

### Update Threat Feeds

```bash
# Update all enabled feeds
sudo nftban feeds update

# List feeds
sudo nftban feeds list

# Enable specific feed
sudo nftban feeds enable SPAMHAUS_DROP
```

[Threat Feeds Guide →](guides/feeds.md)

### Apply Rules Safely

```bash
# Apply rules with commit-confirm (5-minute grace period)
sudo nftban-apply

# Test connectivity...
# If OK:
sudo nftban-confirm

# If broken:
# Wait 5 minutes → auto-rollback
# Or force rollback:
sudo nftban-rollback --force
```

[Recovery Guide →](../RECOVERY_GUIDE.md)

---

## Documentation Structure

### Guides (Task-Based)

Learn how to accomplish specific tasks:

- **[Quick Start](guides/quickstart.md)** - 5-minute setup
- **[Installation](guides/install.md)** - Detailed installation
- **[Ban System](guides/ban-system.md)** - How banning works
- **[Security Profiles](guides/security-profiles.md)** - 7 profiles explained
- **[Health Diagnostics](guides/health-diagnostics.md)** - System health checks
- **[Threat Feeds](guides/feeds.md)** - Threat intelligence integration
- **[Fail2ban Integration](guides/fail2ban.md)** - Intrusion detection
- **[Troubleshooting](guides/troubleshoot.md)** - Common issues

### Concepts (Understanding NFTBan)

Understand how NFTBan works internally:

- **[Architecture](concepts/architecture.md)** - System design (flow diagrams!)
- **[nftables Model](concepts/nftables-model.md)** - 3-table structure
- **[Defense Layers](concepts/defense-layers.md)** - 8 security layers
- **[Recovery System](concepts/recovery-system.md)** - Commit-confirm pattern

### Reference (Technical Details)

Technical specifications and API reference:

- **[CLI Reference](reference/cli.md)** - All 15 commands
- **[Module Reference](reference/modules.md)** - All 17 core modules
- **[nftables Reference](reference/nftables.md)** - Table structure, sets, rules
- **[Configuration Reference](reference/configuration.md)** - All config options

### Recipes (Copy-Paste Examples)

Ready-to-use examples for common scenarios:

- **[Common Tasks](recipes/common-tasks.md)** - Everyday operations
- **[Web Server Setup](recipes/web-server.md)** - Nginx/Apache hardening
- **[SSH Hardening](recipes/ssh-hardening.md)** - Secure SSH configuration
- **[Mail Server](recipes/mail-server.md)** - Postfix/Dovecot setup

---

## Key Features

### Commit-Confirm Recovery

**Never lock yourself out again!**

```
┌─────────────────────────────────────────────────────┐
│  1. Apply rules (active immediately)                │
│  2. Test for 5 minutes                              │
│  3. Confirm if OK, or wait for auto-rollback        │
└─────────────────────────────────────────────────────┘

Result: CANNOT permanently lock out!
```

[Learn more →](concepts/recovery-system.md)

### Ultra-Fast Feed Parsing

**Go binary = 10-60x faster than bash**

```
OLD (bash): 14 feeds × 5s each = 70 seconds
NEW (Go):   Parallel parsing = <1 second

Tested: 1,000,000 IPs parsed in <1 second!
```

[Learn more →](guides/feeds.md)

### 8 Security Layers

**Defense in depth protects at every level**

```
8. Recovery System     ← CANNOT lock out!
7. Application Layer   ← App-specific security
6. Intrusion Detection ← Fail2ban auto-banning
5. Threat Intelligence ← 1M+ known bad IPs
4. Dynamic Blacklist   ← Manual bans
3. Port Filtering      ← Only required ports
2. IP Whitelist        ← Trusted IPs (highest priority)
1. Connection State    ← Stateful firewall
```

[Learn more →](concepts/defense-layers.md)

### 7 Security Profiles

**One command to change security posture**

```bash
paranoid  # Maximum security (DDoS ON, portscan STRICT)
strict    # High security
balanced  # Recommended default ✓
web       # Web server optimized
minimal   # Basic protection
dev       # Development mode
disabled  # Firewall off
```

[Learn more →](guides/security-profiles.md)

---

## System Requirements

### Minimum Requirements

- **OS**: Linux kernel 5.10+ (any distro)
- **nftables**: 1.0.0+
- **Bash**: 5.0+
- **systemd**: 250+
- **RAM**: 512 MB (1 GB recommended)
- **Disk**: 100 MB

### Supported Distributions

✅ **Tested & Supported:**
- Rocky Linux 9+
- AlmaLinux 9+
- Fedora 38+
- Ubuntu 22.04+
- Debian 12+
- openSUSE Leap 15.5+

✅ **Should Work:**
- Any modern Linux with nftables 1.0.0+

---

## Getting Help

### Documentation

- 📚 **[Guides](guides/quickstart.md)** - Step-by-step tutorials
- 🧠 **[Concepts](concepts/architecture.md)** - How NFTBan works
- 📖 **[Reference](reference/cli.md)** - Technical specs
- 🍳 **[Recipes](recipes/common-tasks.md)** - Copy-paste examples

### Community

- 🏠 **[GitHub](https://github.com/nftban/nftban)** - Source code
- 🐛 **[Issues](https://github.com/nftban/nftban/issues)** - Bug reports & feature requests
- 💬 **[Discussions](https://github.com/nftban/nftban/discussions)** - Q&A, ideas, feedback

### Professional Support

**NFTBAN Project – Simplifying Linux Firewall Management**
- **Author**: Antonios Voulvoulis
- **Email**: contact@nftban.com
- **Website**: https://nftban.com

---

## Quick Reference

### Essential Commands

```bash
# Ban/unban
nftban ban <IP>                  # Temporary ban (1h)
nftban ban <IP> --permanent      # Permanent ban
nftban unban <IP>                # Remove ban

# Lists
nftban list banned               # Show all banned IPs
nftban list whitelist            # Show whitelisted IPs
nftban list feeds                # Show feed IPs

# Health
nftban health check              # System health check
nftban health check --fix        # Auto-fix issues

# Profiles
nftban profile list              # List profiles
nftban profile set <name>        # Set profile

# Feeds
nftban feeds update              # Update all feeds
nftban feeds enable <name>       # Enable feed

# Fail2ban
nftban fail2ban status           # Show jail status
nftban fail2ban sync             # Sync configuration

# Recovery
nftban-apply                     # Apply rules (commit-confirm)
nftban-confirm                   # Confirm rules
nftban-rollback                  # Rollback to backup
```

### Configuration Files

```bash
/etc/nftban/
├── nftban.conf                  # Main config
├── nftban.conf.local            # Your overrides (NEVER touched!)
└── conf.d/                      # Module configs
    ├── feeds.conf
    ├── security.conf
    ├── ddos.conf
    └── *.conf.local             # Module overrides
```

### Log Files

```bash
/var/log/nftban/
├── operations.log               # All operations
├── health.log                   # Health checks
├── feeds.log                    # Feed updates
└── recovery.log                 # Recovery events
```

---

## License

**Mozilla Public License 2.0 (MPL-2.0)**

Copyright © 2024–2026 NFTBAN Project / Antonios Voulvoulis

✅ Use in personal/commercial projects
✅ Modify and customize
✅ Deploy on unlimited systems
📜 Source code must remain MPL-2.0

[Full License Text](../LICENSE)

---

<p align="center">
  <b>Made with ❤️ by <a href="https://nftban.com">NFTBan Team</a></b><br>
  <sub>Empowering system administrators with simple, powerful security tools</sub>
</p>

<p align="center">
  <a href="https://github.com/nftban/nftban">🏠 Home</a> •
  <a href="guides/quickstart.md">🚀 Quick Start</a> •
  <a href="concepts/architecture.md">🏗️ Architecture</a> •
  <a href="reference/cli.md">📖 CLI Reference</a> •
  <a href="https://github.com/nftban/nftban/issues">🐛 Report Issue</a> •
  <a href="https://nftban.com">🌐 Website</a>
</p>
