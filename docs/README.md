# NFTBan Documentation

**Version:** v0.9.0+  
**Last Updated:** 2025-10-19

This directory contains all documentation for the NFTBan firewall management system.

---

## 📚 Core Documentation

### Architecture & Design
- **[ARCHITECTURE.md](ARCHITECTURE.md)** - Complete system architecture, technical deep-dive, v0.9.0 split-table design
- **[SECURITY.md](SECURITY.md)** - Security features, best practices, threat model
- **[MIGRATION_v0.9.0.md](MIGRATION_v0.9.0.md)** - Migration guide from v0.8.5 to v0.9.0

### Implementation Documentation

#### Threat Feeds System (v4.0.0)
- **[FEEDS_SYSTEM_COMPLETE.md](FEEDS_SYSTEM_COMPLETE.md)** - Complete implementation summary (1,261 lines, 9 feeds)
- **[FEEDS_SYSTEM_DESIGN.md](FEEDS_SYSTEM_DESIGN.md)** - Design specification and decisions
- **[FEEDS_IMPLEMENTATION_PROGRESS.md](FEEDS_IMPLEMENTATION_PROGRESS.md)** - Implementation progress tracker

#### Installer System (v7.0.0)
- **[INSTALLER_MECHANISMS_ANALYSIS.md](INSTALLER_MECHANISMS_ANALYSIS.md)** - Analysis of install/uninstall mechanisms
- **[INSTALLER_IMPLEMENTATION_PLAN.md](INSTALLER_IMPLEMENTATION_PLAN.md)** - Implementation planning document
- **[INSTALLER_IMPLEMENTATION_SUMMARY.md](INSTALLER_IMPLEMENTATION_SUMMARY.md)** - Implementation completion summary

### Planning & Roadmap
- **[TODO_REPO_HEALTH.md](TODO_REPO_HEALTH.md)** - Repository health, security improvements, CI/CD roadmap

---

## 🎯 Quick Links

### For Users
- **Getting Started:** See [../README.md](../README.md)
- **Installation:** See [../README.md#installation](../README.md#installation)
- **CLI Reference:** See [ARCHITECTURE.md#cli-system](ARCHITECTURE.md)
- **Security:** See [SECURITY.md](SECURITY.md)

### For Developers
- **Architecture:** See [ARCHITECTURE.md](ARCHITECTURE.md)
- **Contributing:** See [../CLAUDE.md](../CLAUDE.md) for development guide
- **Threat Feeds:** See [FEEDS_SYSTEM_DESIGN.md](FEEDS_SYSTEM_DESIGN.md)
- **Installer:** See [INSTALLER_MECHANISMS_ANALYSIS.md](INSTALLER_MECHANISMS_ANALYSIS.md)

### For System Administrators
- **Migration:** See [MIGRATION_v0.9.0.md](MIGRATION_v0.9.0.md)
- **Security Hardening:** See [SECURITY.md](SECURITY.md)
- **Threat Intelligence:** See [FEEDS_SYSTEM_COMPLETE.md](FEEDS_SYSTEM_COMPLETE.md)

---

## 📊 Documentation Structure

```
docs/
├── README.md                              # This file
├── ARCHITECTURE.md                         # System architecture (v0.9.0+)
├── SECURITY.md                            # Security documentation
├── MIGRATION_v0.9.0.md                    # Migration guide
│
├── FEEDS_SYSTEM_COMPLETE.md               # Threat feeds completion summary
├── FEEDS_SYSTEM_DESIGN.md                 # Threat feeds design spec
├── FEEDS_IMPLEMENTATION_PROGRESS.md       # Threat feeds progress
│
├── INSTALLER_MECHANISMS_ANALYSIS.md       # Installer analysis
├── INSTALLER_IMPLEMENTATION_PLAN.md       # Installer planning
├── INSTALLER_IMPLEMENTATION_SUMMARY.md    # Installer completion
│
├── TODO_REPO_HEALTH.md                    # Roadmap & improvements
└── nftban_diagram_actions.png             # Architecture diagram
```

---

## 🔍 Search Guide

**Looking for:**

- **How nftables works?** → [ARCHITECTURE.md](ARCHITECTURE.md)
- **How feeds work?** → [FEEDS_SYSTEM_COMPLETE.md](FEEDS_SYSTEM_COMPLETE.md)
- **How to install?** → [../README.md](../README.md)
- **How to migrate from v0.8.5?** → [MIGRATION_v0.9.0.md](MIGRATION_v0.9.0.md)
- **Security features?** → [SECURITY.md](SECURITY.md)
- **Development guide?** → [../CLAUDE.md](../CLAUDE.md)

---

## 📝 Version History

| Version | Date | Major Changes |
|---------|------|---------------|
| **v0.9.0** | 2025-10-18 | Split-table architecture (ip nftban_v4 + ip6 nftban_v6) |
| **v0.8.5** | 2024-XX-XX | Single-table architecture (inet nftban_global) - ARCHIVED |

See [../CHANGELOG.md](../CHANGELOG.md) for detailed version history.

---

## 🆘 Need Help?

- **Issues:** https://github.com/itcmsgr/nftban/issues
- **Discussions:** https://github.com/itcmsgr/nftban/discussions
- **Email:** contact@itcms.gr
- **Website:** https://itcms.gr

---

**Copyright © 2025 Antonios Voulvoulis – ITCMS. All rights reserved.**
