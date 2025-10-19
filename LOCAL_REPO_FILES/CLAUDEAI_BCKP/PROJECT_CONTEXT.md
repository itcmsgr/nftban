# nftban Project - Quick Context for Claude Code

**If PC crashes and you start fresh, read this file first!**

---

## Project Overview

**Name:** nftban
**Version:** v0.9.0 (BETA)
**Purpose:** Linux firewall management system (nftables + Fail2Ban)
**License:** ITCMS Custom License (can use commercially, cannot resell)
**Repository:** https://github.com/itcmsgr/nftban

---

## Current Status (2025-10-19)

### What's Working ✅
- Fresh installation on CentOS Stream 9
- Module loading (20 modules)
- Ban/unban operations
- Whitelist operations
- Split table architecture (IPv4/IPv6 separate)
- nftables integration

### Known Issues ⚠️
- Issue #14: Permanent blacklist command hangs
- Issue #15: Validation system hangs
- Issue #16: Smoke test hangs

### Recent Work
- Fixed 13 bugs during comprehensive testing
- Last 2 critical bugs: #12 (grep -c) and #13 (parameter order)
- Tested on CentOS Stream 9 lab server
- All tests documented in LOCAL_REPO_FILES/testreports/

---

## Important Files to Know

### Core Files
- **`CLAUDE.md`** - Complete project instructions (READ THIS!)
- **`README.md`** - User documentation
- **`lib/nftban_core.sh`** - Core module (loads all others)
- **`lib/nftban_main_cli.sh`** - Main CLI entry point
- **`bin/nftban`** - CLI wrapper

### Configuration Files
```
config/
├── nftban.conf              # Main config
├── ddos_protection.conf     # DDoS settings
└── portscan.conf           # Port scan detection

templates/control-panels/
├── cpanel.conf             # cPanel ports
├── directadmin.conf        # DirectAdmin ports
└── generic.conf            # Generic server ports
```

### Private Files (LOCAL_REPO_FILES/)
```
LOCAL_REPO_FILES/
├── CLAUDEAI_BCKP/          # This folder - recovery guides
├── testreports/            # Test reports (CONFIDENTIAL)
├── archives/               # Old module backups
└── *.md                    # Documentation
```

---

## Architecture Overview

### Split Table Design (v0.9.0)
- **IPv4 Table:** `ip nftban_v4`
- **IPv6 Table:** `ip6 nftban_v6`
- Separate tables for better performance

### nftables Sets
Each table has:
- `whitelist` - Protected IPs (highest priority)
- `temp_ban` - Temporary bans (with timeout)
- `user_blacklist` - Manual permanent bans
- `system_blacklist` - Auto permanent bans
- `feeds` - Threat intelligence feeds

### Module System
20 modules, loaded by `nftban_core.sh`:
1. Core module (base functions)
2. Safety module (lockout prevention)
3. nftables module (firewall rules)
4. Whitelist module
5. Blacklist module
6. Port module
7. Fail2Ban module
8. Statistics module
9. Search module
10. Cloudflare module
11. GeoIP module
12. DDoS protection module
13. Port scan detection module
14. Login monitor module
15. Feeds module
16. Update module
17. Maintenance module
18. Smoketest module
19. Diagnostics module
20. Validator GitHub module

---

## Common Commands

### Installation
```bash
# Install nftban
sudo bash lib/installer/installer_main.sh install

# Initialize
sudo nftban init
```

### Daily Operations
```bash
# Ban IP
sudo nftban ban 1.2.3.4 "Reason"

# Unban IP
sudo nftban unban 1.2.3.4

# Whitelist IP
sudo nftban whitelist add 1.2.3.4

# Check status
sudo nftban status
```

### Testing
```bash
# Quick test
sudo nftban test quick

# Full test
sudo nftban test full

# Validate installation
sudo nftban validate status
```

---

## Development Workflow

### Making Changes
1. Edit files
2. Test locally
3. Commit: `git add -A && git commit -m "Description"`
4. Push: `git push`

### Testing Changes
1. Test on lab server (CentOS Stream 9)
2. Run smoke tests
3. Verify nftables rules
4. Check logs: `/var/log/nftban/`

### Before Committing
- Run shellcheck on modified .sh files
- Test changed functionality
- Update CLAUDE.md if architecture changed
- Update this work log

---

## Critical Patterns to Remember

### Bash Strict Mode
All scripts use: `set -euo pipefail`

**Important:** Arithmetic expansions must use `|| :` not `|| true`
```bash
# CORRECT:
((counter++)) || :

# WRONG:
((counter++)) || true  # Fails in strict mode!
```

### Function Parameter Order
Always document function signatures:
```bash
# function_name <param1> <param2>
# @param $1 - IP address (required)
# @param $2 - Jail name (optional, default: "manual")
# @param $3 - Ban time (optional, default: 3600)
function_name() {
    local ip="$1"
    local jail="${2:-manual}"
    local ban_time="${3:-3600}"
    # ...
}
```

### Configuration File Pattern
Two-file pattern:
- `.conf` - Base config (managed by updates)
- `.conf.local` - User overrides (never overwritten)

---

## Bug Fix History

### Recent Bugs (v0.9.0)
1-11. Arithmetic expansion strict mode issues
12. grep -c return value causing syntax error
13. Parameter order mismatch in ban command

**All fixed and pushed to GitHub** ✅

---

## Testing Notes

### Tested Platforms
- ✅ CentOS Stream 9 (comprehensive testing done)
- ⏸️ Debian 11/12 (pending)
- ⏸️ Ubuntu 20/22/24 (pending)

### Test Lab
- **Server:** lab.mywebhost.gr
- **Access:** SSH root access
- **Purpose:** Testing new features before release

---

## Next Priorities

1. Fix 3 hanging issues (#14, #15, #16)
2. Add timeout infrastructure to all long operations
3. Test on Debian/Ubuntu
4. Release v0.9.0 as BETA
5. Plan v0.9.1 with hanging fixes

---

## Quick Reference

### File Locations
```
/etc/nftban/               # Installation directory
/var/log/nftban/           # Log files
/usr/local/bin/nftban      # CLI command
```

### Git Commands
```bash
git status                 # Check status
git diff                   # See changes
git log --oneline -10      # Recent commits
git add -A                 # Stage all
git commit -m "Msg"        # Commit
git push                   # Push to GitHub
```

### Recovery Commands
```bash
git clone https://github.com/itcmsgr/nftban.git
cd nftban
# Everything is here, including LOCAL_REPO_FILES/
```

---

## Important Contacts

- **GitHub:** https://github.com/itcmsgr/nftban
- **Author:** Antonios Voulvoulis (ITCMS Team)
- **Contact:** contact@itcms.gr
- **Website:** https://itcms.gr

---

## Tips for Claude Code

When starting a new session:
1. Read `CLAUDE.md` for full details
2. Read this file for current status
3. Check `WORK_SESSION_LOG.md` for recent work
4. Review latest git commits: `git log -5`

**Everything you need is in the files!** 📁

---

**Last Updated:** 2025-10-19
**Version:** 1.0
**Location:** LOCAL_REPO_FILES/CLAUDEAI_BCKP/PROJECT_CONTEXT.md
