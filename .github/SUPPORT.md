# Getting Support for NFTBan

Thank you for using NFTBan! This document will help you get the support you need.

## 📖 Documentation First

Before asking for help, please check our documentation:

### Quick Help

```bash
# CLI help system (fastest!)
nftban help                  # All commands
nftban <command> help        # Specific command

# Man page (complete reference)
man nftban

# System diagnostics
nftban health check
```

### Documentation Resources

| Resource | Purpose | Link |
|----------|---------|------|
| **README** | Project overview and quick start | [README.md](../README.md) |
| **Documentation Guide** | How to find information | [docs/README.md](../docs/README.md) |
| **Architecture** | Technical design and internals | [docs/ARCHITECTURE.md](../docs/ARCHITECTURE.md) |
| **Security** | Security model and CVE advisories | [SECURITY.md](../SECURITY.md) |
| **Changelog** | Version history and changes | [CHANGELOG.md](../CHANGELOG.md) |
| **Contributing** | How to contribute | [CONTRIBUTING.md](../CONTRIBUTING.md) |

## 🐛 Reporting Bugs

Found a bug? The fastest way to get help:

```bash
# Generate a support bundle (recommended)
sudo nftban support
# Attach /tmp/nftban-support-*.tar.gz to your issue
```

Then use our bug report template:

1. Go to [Issues](https://github.com/itcmsgr/nftban/issues/new/choose)
2. Select "🐛 Bug Report"
3. Attach your support bundle OR fill in ALL required fields:
   - NFTBan version (`nftban version`)
   - OS and kernel (`uname -a`)
   - Output of `nftban health check`
   - Relevant logs from `/var/log/nftban/`
   - Steps to reproduce

**Important:** The support bundle automatically redacts secrets, but always review before posting!

## 💡 Feature Requests

Have an idea? We'd love to hear it!

1. Go to [Issues](https://github.com/itcmsgr/nftban/issues/new/choose)
2. Select "💡 Feature Request"
3. Describe:
   - What problem does it solve?
   - Who would benefit?
   - How should it work?

## 💬 Questions and Discussions

For general questions, discussions, or community help:

**GitHub Discussions** (Recommended)
- [Start a Discussion](https://github.com/itcmsgr/nftban/discussions)
- Categories:
  - **Q&A** - Ask questions
  - **Ideas** - Share ideas and feedback
  - **Show and tell** - Share your NFTBan setup

## 🔒 Security Vulnerabilities

**DO NOT** report security vulnerabilities publicly!

Instead:
1. Email: **security@nftban.com**
2. Include:
   - Vulnerability description
   - Steps to reproduce
   - Potential impact
   - Suggested fix (if any)

We will respond within 48 hours and work with you on a fix.

See [SECURITY.md](../SECURITY.md) for our full security policy.

## 📧 Email Support

For other inquiries:
- **General:** contact@nftban.com
- **Security:** security@nftban.com

## ⏱️ Response Times

We strive to respond within:
- **Security issues:** 48 hours
- **Critical bugs:** 72 hours
- **Other issues:** 7 days
- **Feature requests:** 14 days

**Note:** NFTBan is maintained by volunteers. Response times may vary.

## 🚀 Commercial Support

Need priority support, custom features, or professional services?

Contact us at: **contact@nftban.com**

We offer:
- Priority bug fixes
- Custom feature development
- Professional installation and configuration
- Training and consulting
- SLA-backed support

## 🤝 Community Guidelines

When asking for help:

✅ **DO:**
- Search existing issues first
- Provide complete information
- Be patient and respectful
- Follow up on your issues
- Thank helpers
- Share solutions that worked

❌ **DON'T:**
- Demand immediate responses
- Post the same question multiple times
- Share sensitive data publicly
- Be rude or aggressive
- Ignore requested information

## 📚 Self-Help Resources

### Common Issues

**"I locked myself out!"**
```bash
# If you have console access:
sudo nftban firewall status
sudo nft list tables
# Check whitelist configuration
```

**"Firewall not working"**
```bash
# Run health check
nftban health check

# Check service status
systemctl status nftban
journalctl -u nftban -n 50
```

**"Ban command not working"**
```bash
# Check if IP is whitelisted
nftban search <ip>
nftban whitelist list
```

### Support Bundle (Recommended)

The fastest way to collect all diagnostic information:

```bash
# Generate support bundle (auto-collects everything, redacts secrets)
sudo nftban support

# Output: /tmp/nftban-support-YYYYMMDD-HHMMSS.tar.gz
# Attach this file to your GitHub issue
```

The support bundle includes:
- Version info and git commit
- OS and kernel info
- nftables ruleset and sets
- Config files (secrets redacted)
- Last 24h of logs
- Health check output
- Service status

### Manual Diagnostic Commands

```bash
# System health
nftban health check

# Quick diagnostics (no file output)
sudo nftban support --quick

# Firewall status
nftban firewall status
nft list tables
nft list table inet nftban_main

# Logs
journalctl -u nftban -n 100
tail -f /var/log/nftban/*.log

# Version info
nftban version
nft --version
uname -a
```

## 🌐 External Resources

- **Website:** https://nftban.com
- **GitHub:** https://github.com/itcmsgr/nftban
- **nftables Wiki:** https://wiki.nftables.org/
- **Fail2ban Docs:** https://fail2ban.readthedocs.io/

## 🎓 Learning Resources

**For Users:**
1. Read [README.md](../README.md) - 30 minutes
2. Try `nftban help` - Interactive learning
3. Read `man nftban` - Complete reference

**For Admins:**
1. Read [ARCHITECTURE.md](../docs/ARCHITECTURE.md) - 2 hours
2. Study [SECURITY.md](../SECURITY.md) - Security model
3. Explore `/usr/lib/nftban/` - Source code

## 📊 Issue Priority

We prioritize issues based on:

1. **Critical:** Security vulnerabilities, data loss, system crashes
2. **High:** Major functionality broken, production impact
3. **Medium:** Feature not working as expected
4. **Low:** Minor bugs, cosmetic issues
5. **Enhancement:** New features, improvements

## ✅ What Makes a Good Issue?

**Good Example:**
```
Title: [BUG] Ban command crashes when no arguments provided

NFTBan Version: 0.31.1
OS: Rocky Linux 9.3
Kernel: 6.1.0

Steps to reproduce:
1. Run: nftban ban
2. Expected: Usage message
3. Actual: unbound variable error

Output: [paste error]
Health check: [paste output]
```

**Bad Example:**
```
Title: not working

it doesnt work help
```

## 🙏 Thank You!

Your questions, bug reports, and feedback help make NFTBan better for everyone.

We appreciate your time and patience! 🎉

---

**NFTBan Project** — Open-source Linux IPS and nftables firewall manager

Copyright © 2024–2026 NFTBAN Project / Antonios Voulvoulis
