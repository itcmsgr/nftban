# NFTBan Documentation

**Version:** 0.31.0
**Last Updated:** 2025-11-05

---

## 📖 How Documentation is Organized

**Philosophy:**
1. **CLI teaches you:** `nftban help`
2. **Need details:** `man nftban`
3. **Want to understand:** Read `ARCHITECTURE.md`
4. **Want to hack:** Code is open, explore!

---

## 🎯 Quick Navigation

### For Users
```bash
# Start here - CLI is your friend
nftban help
nftban <command> help

# Need comprehensive reference
man nftban
```

### For System Administrators
1. **CLI Quick Start:** `nftban help` - Learn commands interactively
2. **Architecture Guide:** [ARCHITECTURE.md](ARCHITECTURE.md) - Understand how NFTBan works
3. **Man Page:** `man nftban` - Complete command reference

### For Developers
1. **Architecture:** [ARCHITECTURE.md](ARCHITECTURE.md) - System design and components
2. **Source Code:** `/usr/lib/nftban/` - Read the code (it's open!)
3. **Contributing:** [../CONTRIBUTING.md](../CONTRIBUTING.md) - How to contribute

---

## 📚 Available Documentation

### In This Directory (`docs/`)

| Document | Purpose | Audience |
|----------|---------|----------|
| **README.md** | This file - Documentation guide | Everyone |
| **ARCHITECTURE.md** | Technical architecture and design | Admins, Developers |
| **nftban.1** | Man page (view with `man nftban`) | Users, Admins |

### In Root Directory

| Document | Purpose |
|----------|---------|
| [README.md](../README.md) | Project overview and quick start |
| [SECURITY.md](../SECURITY.md) | Security policy and CVE advisories |
| [CHANGELOG.md](../CHANGELOG.md) | Version history and changes |
| [CONTRIBUTING.md](../CONTRIBUTING.md) | Contribution guidelines |
| [TRADEMARK.md](../TRADEMARK.md) | Trademark policy |
| [NOTICE.md](../NOTICE.md) | Legal notices and attributions |

---

## 🚀 Getting Started

### 1. Install NFTBan
See [README.md](../README.md) for installation instructions.

### 2. Learn the CLI
```bash
# Get help
nftban help

# Check status
nftban status

# View health
nftban health check

# Get command-specific help
nftban firewall help
nftban ban help
```

### 3. Read the Man Page
```bash
man nftban
```

### 4. Understand Architecture (Optional)
Read [ARCHITECTURE.md](ARCHITECTURE.md) to understand:
- Two-table nftables design
- Rule processing order
- Set-based filtering
- Directory structure
- Configuration system

### 5. Explore the Code (Optional)
```bash
# Code is in /usr/lib/nftban/
ls -la /usr/lib/nftban/

# CLI commands
ls -la /usr/lib/nftban/cli/

# Core libraries
ls -la /usr/lib/nftban/core/
```

---

## 🔍 Finding Information

### "How do I...?"
**Answer:** Use the CLI help system
```bash
nftban help                    # All commands
nftban <command> help          # Specific command help
```

### "What does this command do?"
**Answer:** Check the man page
```bash
man nftban
```

### "How does NFTBan work internally?"
**Answer:** Read the architecture guide
```bash
# View online
cat /usr/share/doc/nftban/ARCHITECTURE.md

# Or from repository
cat docs/ARCHITECTURE.md
```

### "I want to modify NFTBan"
**Answer:** Read the code
```bash
# Main CLI dispatcher
less /usr/sbin/nftban

# Backend rule generator
less /usr/sbin/nftban-complete

# CLI commands (25 commands)
ls /usr/lib/nftban/cli/

# Core modules
ls /usr/lib/nftban/core/
```

---

## 💡 Documentation Philosophy

### Less is More
We believe in:
- **Good CLI** with helpful messages
- **Comprehensive man page** for reference
- **Clean architecture docs** for understanding
- **Open source code** for deep exploration

### What We Don't Do
- ❌ Duplicate information in multiple places
- ❌ Write documentation that gets outdated
- ❌ Create guides when `--help` is better
- ❌ Hide information - code is open!

### What We Do
- ✅ Excellent CLI help text
- ✅ Complete man page
- ✅ Architecture explanation
- ✅ Readable, well-commented code

---

## 🎓 Learning Path

### Beginner (CLI User)
**Time:** 30 minutes

1. `nftban help` - Browse available commands
2. `nftban status` - See current state
3. `nftban firewall help` - Learn firewall commands
4. Try basic commands with `--help`

### Intermediate (System Admin)
**Time:** 2 hours

1. Complete Beginner path
2. `man nftban` - Read complete reference
3. Read [ARCHITECTURE.md](ARCHITECTURE.md) - Understand design
4. Explore `/etc/nftban/` - Configuration files

### Advanced (Developer)
**Time:** 4-8 hours

1. Complete Intermediate path
2. Read [ARCHITECTURE.md](ARCHITECTURE.md) - Deep dive
3. Study `/usr/lib/nftban/` - Source code
4. Read [CONTRIBUTING.md](../CONTRIBUTING.md) - Contribute
5. Explore nftables design - `nft list tables`

---

## 📖 Man Page

The NFTBan man page is your complete reference guide.

### View Man Page
```bash
man nftban
```

### Man Page Sections
- **NAME** - Brief description
- **SYNOPSIS** - Command syntax
- **DESCRIPTION** - What NFTBan does
- **COMMANDS** - All 25 CLI commands
- **OPTIONS** - Global options
- **CONFIGURATION** - Config files and locations
- **DIRECTORY STRUCTURE** - FHS layout
- **EXAMPLES** - Common usage patterns
- **FILES** - Important file locations
- **EXIT STATUS** - Return codes
- **SECURITY** - Security considerations
- **SEE ALSO** - Related documentation

---

## 🏗️ Architecture Guide

[ARCHITECTURE.md](ARCHITECTURE.md) explains NFTBan's design:

### Key Topics Covered
- **Two-Table Design** - Runtime vs Main tables
- **Rule Processing Order** - Critical security fix (v0.31.0)
- **Set-Based Filtering** - O(1) performance
- **Atomic Operations** - Zero-downtime updates
- **Directory Structure** - FHS-compliant layout
- **CLI Architecture** - 25 commands explained
- **Configuration System** - .conf vs .conf.local
- **Integration Points** - Fail2ban, feeds, GeoIP
- **Security Features** - Lockout prevention, auto-heal
- **Troubleshooting** - Common issues and fixes

### When to Read
- Setting up production deployment
- Troubleshooting complex issues
- Planning customizations
- Contributing code
- Understanding security model

---

## 🔗 External Resources

### Official Links
- **GitHub:** https://github.com/itcmsgr/nftban
- **Website:** https://nftban.com
- **Issues:** https://github.com/itcmsgr/nftban/issues

### Related Documentation
- **nftables:** https://nftables.org/
- **Fail2ban:** https://www.fail2ban.org/
- **FHS Standard:** https://refspecs.linuxfoundation.org/FHS_3.0/

---

## 🆘 Getting Help

### Built-in Help
```bash
nftban help              # All commands
nftban <cmd> help        # Command help
man nftban              # Complete reference
nftban health check     # System diagnostics
```

### Documentation
1. This README - Documentation overview
2. [ARCHITECTURE.md](ARCHITECTURE.md) - Technical details
3. Man page - Complete reference

### Community
- **Issues:** Report bugs at https://github.com/itcmsgr/nftban/issues
- **Discussions:** https://github.com/itcmsgr/nftban/discussions

### Support
- **Email:** contact@nftban.com
- **Website:** https://nftban.com

---

## ✅ Documentation Quality

Our documentation follows these principles:

### Accuracy
- ✅ All commands tested on production servers
- ✅ Examples verified to work
- ✅ Version-specific information clearly marked

### Completeness
- ✅ Every command documented in man page
- ✅ Architecture fully explained
- ✅ All features have CLI help

### Maintainability
- ✅ Minimal duplication
- ✅ Single source of truth
- ✅ Easy to update

### Accessibility
- ✅ Clear language
- ✅ Practical examples
- ✅ Multiple learning paths

---

**NFTBan v0.31.0** - Simple, Secure, Powerful

Copyright © 2024–2026 NFTBAN Project / Antonios Voulvoulis
