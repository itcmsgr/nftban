# NFTBan v0.9.2 - Critical Security Fixes + Mail Detection

**Release Date:** October 22, 2025
**Type:** Security & Feature Release
**Status:** Stable

## Overview

This release addresses **CRITICAL security vulnerabilities** related to IPv6 visibility and whitelist synchronization, plus adds comprehensive mail service detection and management. **Immediate upgrade recommended.**

---

## 🔴 CRITICAL Security Fixes

### BUG60: IPv6 Set Statistics Not Displayed (CRITICAL)
- **Severity:** CRITICAL
- **Issue:** IPv6 firewall sets were completely invisible in status output
  - Servers with IPv6 addresses appeared unmonitored
  - IPv6 protection status could not be verified
  - Caused by grep failing on empty sets in strict mode
- **Impact:** Both IPv4 and IPv6 servers affected
- **Fix:** Rewrote set counting to safely handle empty sets
- **Result:** All IPv4 and IPv6 sets now visible in `nftban status`

**Example:**
```bash
# Before: Only showed IPv4
Sets (IPv4 - nftban_v4):
  whitelist: 1 IPs
# (IPv6 section missing!)

# After: Shows both IPv4 and IPv6
Sets (IPv4 - nftban_v4):
  whitelist: 3 IPs
  temp_ban: 0 IPs
  user_blacklist: 0 IPs
  system_blacklist: 0 IPs
  feeds: 0 IPs

Sets (IPv6 - nftban_v6):
  whitelist: 2 IPs
  temp_ban: 0 IPs
  user_blacklist: 0 IPs
  system_blacklist: 0 IPs
  feeds: 0 IPs
```

---

### BUG61: Whitelist Sync Fails - Server Self-Ban Risk (CRITICAL SECURITY)
- **Severity:** CRITICAL SECURITY
- **Issue:** Whitelist sync to nftables was failing silently
  - Server IPs were in configuration files but **NOT in nftables**
  - Server could **ban its own IP addresses** (127.0.0.1, public IPs)
  - Admin could be **completely locked out**
  - Caused by arithmetic increment `((count++))` in strict mode
- **Impact:** All servers at risk of self-lockout
- **Fix:** Replaced all `((count++))` with safe arithmetic `count=$((count + 1))`
- **Result:** All server IPs now properly protected in nftables

**Danger Before Fix:**
```bash
# Config files (looked correct)
$ cat /etc/nftban/config/whitelist-system.conf
127.0.0.1       # Localhost
95.216.159.238  # Server IP
2a01:4f9:c010:b0b5::1  # Server IPv6

# But nftables (NOT protected!)
$ nft list set ip nftban_v4 whitelist
elements = { 1.2.3.4 }  # Wrong! Only test IP, NOT server IP!

# IPv6 completely empty!
$ nft list set ip6 nftban_v6 whitelist
elements = { }  # EMPTY! No IPv6 protection!
```

**Safe After Fix:**
```bash
$ nftban whitelist sync
[SUCCESS] Synced to nftables: 3 IPv4, 2 IPv6

$ nft list set ip nftban_v4 whitelist
elements = { 127.0.0.1, 95.216.159.238, 62.38.150.122 }  ✓

$ nft list set ip6 nftban_v6 whitelist
elements = { ::1, 2a01:4f9:c010:b0b5::1 }  ✓
```

---

## 🛡️ Additional Security Fixes

### BUG51: Strict Mode Added to All Shell Scripts
- Added `set -Eeuo pipefail` to all 17+ shell scripts
- Prevents silent failures and undefined variable usage
- Enhances overall security posture

### BUG52: Fixed log_debug Undefined in Utils Library
- Removed undefined function call
- Eliminated error messages during library loading

### BUG58: Fixed Arithmetic Increment in Strict Mode
- Same root cause as BUG61 but in display functions
- Mail panel was failing to display

### BUG59: Fixed IFS Array Parsing in Strict Mode
- Array parsing failed in subshell contexts
- Mail service detection was broken
- Switched to parameter expansion for reliability

---

## 🆕 New Features

### Mail Service Detection & Management

**Comprehensive Mail Detection:**
- Detects **Postfix**, **Exim**, **Sendmail** (SMTP servers)
- Detects **Dovecot** (IMAP/POP3 server)
- Auto-detects mail command (mail, mailx, sendmail)
- Identifies service types (SMTP vs IMAP/POP3)
- Conflict detection for multiple SMTP services
- OS-specific installation recommendations

**New CLI Command: `nftban mail`**
```bash
# Show detailed mail service status
nftban mail status

# Quick check (exit codes for scripts)
nftban mail check

# Show raw detection output
nftban mail detect
```

**Example Output:**
```
═══════════════════════════════════════════════════════
  Mail Service Status
═══════════════════════════════════════════════════════

Mail Command:
  ✓ Found: sendmail
    Path: /usr/sbin/sendmail

Mail Services:
  Service: postfix (SMTP)
  Status: ● ACTIVE

  Service: dovecot (IMAP/POP3)
  Status: ● ACTIVE

Email Functionality:
  ✓ READY - Email notifications can be sent
```

**Smart Conflict Detection:**
- Warns if multiple SMTP servers are running
- Dovecot (IMAP/POP3) can run alongside any SMTP server without conflict
- Provides commands to disable conflicting services

---

## ✨ Improvements

### IPv4 and IPv6 Visibility
- Both IPv4 and IPv6 sets now fully visible in all commands
- Status displays complete firewall state
- No more hidden IPv6 protection

### Server IP Auto-Protection Enhanced
- All server IPs automatically protected (IPv4 + IPv6)
- Localhost (127.0.0.1, ::1) always protected
- Link-local IPv6 addresses properly handled
- Public IPs detected and protected

### Whitelist Sync Reliability
- Sync now completes successfully every time
- Proper error handling and logging
- Verification tools to ensure sync worked

---

## 📋 Testing

**Tested on:**
- ✅ lab.mywebhost.gr (CentOS 9, Postfix)
- ✅ lab2/65.21.157.15 (CentOS 10, Postfix)

**Verified:**
- ✅ All server IPs protected (IPv4 + IPv6)
- ✅ No self-ban risk
- ✅ IPv6 fully visible and functional
- ✅ Mail detection working
- ✅ Whitelist sync reliable

---

## 📦 Installation & Upgrade

### Fresh Installation
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/itcmsgr/nftban/main/install.sh)
```

### Upgrade from v0.9.0 or v0.9.1
```bash
sudo nftban update
```

### Verify Installation
```bash
nftban --version
# Should show: nftban version 0.9.2

nftban status
# Should show both IPv4 and IPv6 sets

nftban whitelist list
# Should show all protected IPs
```

---

## ⚠️ Upgrade Notes

**CRITICAL - Immediate Action Required:**

If you're running v0.9.0 or v0.9.1, you should upgrade immediately due to the critical security issues.

**After upgrading:**

1. **Verify whitelist sync:**
```bash
sudo nftban whitelist sync
```

2. **Check IPv6 protection:**
```bash
nftban status
# Verify you see "Sets (IPv6 - nftban_v6)" section
```

3. **Verify server IPs are protected:**
```bash
nftban whitelist list
# Check that your server IPs are listed
```

4. **Test mail detection (optional):**
```bash
nftban mail status
```

---

## 🔗 Links

- [Full Changelog](https://github.com/itcmsgr/nftban/compare/v0.9.1...v0.9.2)
- [Documentation](https://github.com/itcmsgr/nftban)
- [Report Issues](https://github.com/itcmsgr/nftban/issues)
- [Security Policy](https://github.com/itcmsgr/nftban/security)

---

## 📝 Commits Included

- `57b23ec` Fix BUG61: Whitelist sync fails (CRITICAL SECURITY)
- `07117c0` Fix BUG60: IPv6 set statistics not displayed (CRITICAL)
- `000c7c1` Add Dovecot detection and mail CLI command
- `b76d8b1` Add mail service detection + fix BUG52/BUG58/BUG59
- `29639c8` Complete CLI refactoring

---

## 🙏 Credits

Special thanks to the testing team for identifying these critical issues on production servers.

---

**This is a critical security release. Upgrade immediately to ensure your server cannot ban itself and to restore IPv6 visibility.**
