# 🐛 How to Report Bugs in NFTBan

Thank you for helping improve NFTBan! This guide will help you submit effective bug reports.

---

## 📍 Where to Report Bugs

We have **two channels** for bug reports:

### 1. 🔴 GitHub Issues (For Confirmed Bugs)

**Use GitHub Issues when:**
- You've confirmed it's actually a bug (not a configuration issue)
- You can provide reproduction steps
- You've checked it's not already reported

**Create an issue:** https://github.com/itcmsgr/nftban/issues/new/choose

### 2. 💬 GitHub Discussions (For Questions/Help)

**Use Discussions when:**
- You're not sure if it's a bug or configuration issue
- You need help troubleshooting
- You want community input first

**Start a discussion:** https://github.com/itcmsgr/nftban/discussions/categories/q-a

---

## ✅ Before You Report

**Check these first:**

1. **Search existing issues:** https://github.com/itcmsgr/nftban/issues
   - Your bug might already be reported
   - You can add your +1 or additional info

2. **Search discussions:** https://github.com/itcmsgr/nftban/discussions
   - Others might have found a workaround

3. **Check the documentation:**
   - README: https://github.com/itcmsgr/nftban#readme
   - Man page: `man nftban`
   - Docs: https://github.com/itcmsgr/nftban/tree/main/docs

4. **Run health check:**
   ```bash
   nftban health check --auto-heal
   ```
   - This fixes common issues automatically

---

## 📝 What Makes a Good Bug Report

### Required Information

When creating an issue, please include:

#### 1. Environment
```bash
# Run this command and paste output:
nftban health check --json > health-report.json
cat health-report.json

# Also include:
cat /etc/os-release
uname -a
nftban --version
```

#### 2. Bug Description
- **What happened?** (actual behavior)
- **What did you expect?** (expected behavior)
- **When did it start?** (after update? fresh install?)

#### 3. Reproduction Steps
```
Step-by-step instructions:
1. Run command X
2. Do action Y
3. Observe error Z
```

#### 4. Logs
```bash
# Get recent logs
sudo journalctl -u nftban-main.service -n 100 --no-pager

# Or specific error logs
sudo tail -100 /var/log/nftban/nftban.log
```

#### 5. Configuration
```bash
# Show your config (redact sensitive info!)
cat /etc/nftban/nftban.conf
```

---

## 🎯 Bug Report Template

Use this template when creating an issue:

```markdown
## Environment

- **OS:** (Rocky 9 / Ubuntu 24.04 / etc)
- **NFTBan Version:** (run `nftban --version`)
- **Architecture:** (x86_64 / aarch64)
- **Installation Method:** (RPM / DEB / from source)

## Bug Description

**What happened:**


**What I expected:**


## Reproduction Steps

1.
2.
3.

## Logs

<details>
<summary>Click to expand logs</summary>

\`\`\`
Paste logs here
\`\`\`

</details>

## Configuration

<details>
<summary>Click to expand config</summary>

\`\`\`bash
Paste config here (redact secrets!)
\`\`\`

</details>

## Additional Context

(Screenshots, network setup, etc.)
```

---

## 🚨 Critical/Security Bugs

**For security vulnerabilities:**

**DO NOT** create a public issue!

Instead:
1. Email: contact@nftban.com
2. Subject: "SECURITY: NFTBan Vulnerability Report"
3. Include:
   - Vulnerability description
   - Impact assessment
   - Proof of concept (if applicable)
   - Your contact info

We'll respond within 48 hours.

See: https://github.com/itcmsgr/nftban/blob/main/SECURITY.md

---

## 🏷️ Issue Labels

When creating an issue, select the appropriate template:

| Label | When to Use |
|-------|-------------|
| 🐛 **Bug Report** | Something isn't working correctly |
| ⚡ **Performance** | Slow performance or resource issues |
| 📦 **Package/Install** | RPM/DEB installation problems |
| 🔒 **Security** | Security-related issues |
| 📚 **Documentation** | Docs are wrong or unclear |
| 💡 **Enhancement** | Feature request or improvement |

---

## 💬 Getting Help

**Not sure if it's a bug?** Ask in Discussions first!

- **Q&A:** https://github.com/itcmsgr/nftban/discussions/categories/q-a
- **Ideas:** https://github.com/itcmsgr/nftban/discussions/categories/ideas
- **General:** https://github.com/itcmsgr/nftban/discussions/categories/general

---

## ⚡ Common Issues & Solutions

### Issue: "Permission denied"
```bash
# Add yourself to nftban group (v1.0 uses unified group for CLI + Web GUI)
sudo usermod -aG nftban $USER

# Re-login for changes to take effect
exit
# SSH back in
```

### Issue: "Service not found"
```bash
# Reload systemd
sudo systemctl daemon-reload

# Check if service exists
systemctl list-unit-files | grep nftban
```

### Issue: "nftables ruleset not found"
```bash
# Run initial setup
sudo nftban system setup

# Verify nftables
sudo nft list ruleset
```

### Issue: "Go binary not found"
```bash
# Check binary location
ls -la /usr/lib/nftban/bin/.real/

# Check wrapper scripts
ls -la /usr/lib/nftban/bin/

# Verify architecture
uname -m
```

---

## 📊 After You Report

**What happens next:**

1. **Triage** - Maintainers review within 24-48 hours
2. **Labels** - Issue gets labeled for tracking
3. **Response** - Maintainers may ask for more info
4. **Fix** - If confirmed, bug gets fixed in next release
5. **Notification** - You'll be notified when fixed

**You can help by:**
- Responding to questions promptly
- Testing proposed fixes
- Confirming when bug is resolved

---

## 🙏 Thank You!

Every bug report helps make NFTBan better for everyone!

**Community is the foundation of open source.**

---

**Last Updated:** November 5, 2025
**NFTBan Version:** v0.32.6
**License:** MPL-2.0
