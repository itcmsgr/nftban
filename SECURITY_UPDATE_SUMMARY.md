# NFTBan v0.10.0 - Security Update Summary

**Date:** 2025-10-29
**Update:** Path Validation & Write Security
**Status:** ✅ READY FOR DEPLOYMENT

---

## 📋 WHAT WAS ADDED

### New Security Modules (3 files):

1. **`/usr/lib/nftban/core/nftban_path_security.sh`** (470 lines)
   - Low-level path validation functions
   - Three-tier security model (Allowed/Restricted/Forbidden)
   - Symlink attack prevention
   - Path traversal blocking
   - Audit logging

2. **`/usr/lib/nftban/core/nftban_secure_mode.sh`** (380 lines)
   - High-level security directive
   - Auto-apply security to any script
   - Developer-friendly API
   - Safe file write wrappers

3. **Security Documentation:**
   - `SECURITY_PATH_VALIDATION.md` - Complete security architecture
   - `SECURE_MODE_DIRECTIVE.md` - Developer guide

---

## 🔧 MODIFIED FILES

### Updated CLI Modules (2 files):

1. **`/usr/lib/nftban/cli/cmd_report.sh`**
   - Added path security module loading
   - Updated `nftban_report_cmd_generate()` to use `nftban_path_get_safe_output()`
   - Added `--unsafe-allow-tmp` flag
   - Added security notices for users

2. **`/usr/lib/nftban/cli/cmd_stats.sh`**
   - Added path security module loading
   - Updated `nftban_stats_cmd_export()` to use `nftban_path_get_safe_output()`
   - Added `--unsafe-allow-tmp` flag
   - Added security notices for users

---

## 🛡️ SECURITY IMPROVEMENTS

### Before (v0.9.x):
```bash
# User input DIRECTLY used - DANGEROUS!
nftban report generate --output "$USER_INPUT"
echo "$report" > "$USER_INPUT"  # NO VALIDATION!

# Vulnerabilities:
# - Path traversal: --output ../../etc/passwd
# - Symlink attack: /tmp/report → /etc/shadow
# - Overwrite system files: --output /usr/bin/nftban
```

### After (v0.10.0):
```bash
# Path automatically validated
nftban report generate --output "$USER_INPUT"
safe_path=$(nftban_path_get_safe_output "$USER_INPUT") || return 1
echo "$report" > "$safe_path"  # SECURE!

# Protection:
# ✅ Path traversal blocked
# ✅ Symlink attack prevented
# ✅ System files protected
# ✅ Audit logged
# ✅ User-friendly errors
```

---

## 📊 SECURITY MODEL

### Three-Tier Path Classification:

| Tier | Directories | Flag Required | Use Case |
|------|-------------|--------------|----------|
| **✅ ALLOWED** | `/var/lib/nftban/*`<br>`/var/cache/nftban/*` | None | Default (recommended) |
| **⚠️ RESTRICTED** | `/tmp/`<br>`/var/tmp/` | `--unsafe-allow-tmp` | Testing only (not recommended) |
| **❌ FORBIDDEN** | `/etc/`, `/usr/`, `/boot/`, `/root/`<br>`/bin/`, `/sbin/`, `/lib/`, `/var/log/` | Never allowed | System protection |

---

## 💡 USER-FACING CHANGES

### New Behavior:

#### 1. Default (no --output) - NO CHANGE
```bash
nftban report generate
# ✅ Works as before → /var/lib/nftban/reports/report-TIMESTAMP.html
```

#### 2. Filename only - NO CHANGE
```bash
nftban report generate --output myreport.html
# ✅ Works as before → /var/lib/nftban/reports/myreport.html
```

#### 3. Safe full path - NO CHANGE
```bash
nftban report generate --output /var/lib/nftban/reports/custom.html
# ✅ Works as before → /var/lib/nftban/reports/custom.html
```

#### 4. /tmp path - **NEW BEHAVIOR**
```bash
nftban report generate --output /tmp/report.html
# ❌ NOW BLOCKED (was allowed before)
# Error: Writing to /tmp requires --unsafe-allow-tmp
#
# Alternatives shown:
#   1. Use default: nftban report generate
#   2. Use filename: --output report.html
#   3. Use safe path: --output /var/lib/nftban/reports/report.html
#
# Override (not recommended):
#   nftban report generate --output /tmp/report.html --unsafe-allow-tmp
```

#### 5. System paths - **NEW BEHAVIOR**
```bash
nftban report generate --output /etc/test.html
# ❌ NOW BLOCKED (was potentially dangerous before)
# Error: Writing to /etc is FORBIDDEN for security
```

---

## 🎯 AFFECTED COMMANDS

### Commands Now Protected:

| Command | Old Behavior | New Behavior |
|---------|-------------|--------------|
| `nftban report generate --output PATH` | No validation | Path validated |
| `nftban stats export --output PATH` | No validation | Path validated |

### Flags Added:

- `--unsafe-allow-tmp` - Allow /tmp writes (shows security warning)

---

## 📖 EXAMPLES

### ✅ Example 1: Safe Default (Recommended)
```bash
$ nftban report generate

[SUCCESS] Report: /var/lib/nftban/reports/report-20251029-142530.html
```

### ✅ Example 2: Filename Only
```bash
$ nftban report generate --output daily-stats.html

[SECURITY] Output path validation enabled - only approved directories allowed
[INFO] Approved locations: /var/lib/nftban/* (reports, metrics, exports)
[SUCCESS] Report: /var/lib/nftban/reports/daily-stats.html
```

### ❌ Example 3: /tmp Blocked
```bash
$ nftban report generate --output /tmp/test.html

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
❌ ERROR: Writing to /tmp REQUIRES --unsafe-allow-tmp
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Attempted path: /tmp/test.html

  SECURITY RISKS:
    • Symlink attacks - attacker creates /tmp/test.html → /etc/passwd
    • Race conditions - file created between check and write
    • Information disclosure - other users can read files
    • Privilege escalation - if run as root with user-controlled paths

  RECOMMENDED ALTERNATIVES (safer):
    1. Use default location (automatic):
       nftban report generate
       → /var/lib/nftban/reports/report-YYYYMMDD-HHMMSS.html

    2. Use filename only (writes to safe directory):
       nftban report generate --output test.html
       → /var/lib/nftban/reports/test.html

  UNSAFE OPTION (not recommended):
    nftban report generate --output /tmp/test.html --unsafe-allow-tmp
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## 🚀 DEPLOYMENT CHECKLIST

- [x] Created `nftban_path_security.sh`
- [x] Created `nftban_secure_mode.sh`
- [x] Updated `cmd_report.sh` with path security
- [x] Updated `cmd_stats.sh` with path security
- [x] Created `SECURITY_PATH_VALIDATION.md`
- [x] Created `SECURE_MODE_DIRECTIVE.md`
- [x] Created `SECURITY_UPDATE_SUMMARY.md`
- [ ] Deploy to lab servers (lab, lab1, lab2)
- [ ] Test on lab servers
- [ ] Update FHS module
- [ ] Update main documentation

---

## 📦 FILES TO DEPLOY

### New Files:
```
src/usr/lib/nftban/core/nftban_path_security.sh
src/usr/lib/nftban/core/nftban_secure_mode.sh
```

### Modified Files:
```
src/usr/lib/nftban/cli/cmd_report.sh
src/usr/lib/nftban/cli/cmd_stats.sh
```

### Documentation:
```
SECURITY_PATH_VALIDATION.md
SECURE_MODE_DIRECTIVE.md
SECURITY_UPDATE_SUMMARY.md
```

---

## 🧪 TESTING PROCEDURE

```bash
# Test 1: Default (should work)
ssh root@lab.example.test "nftban report generate"

# Test 2: Filename only (should work)
ssh root@lab.example.test "nftban report generate --output test.html"

# Test 3: /tmp (should fail)
ssh root@lab.example.test "nftban report generate --output /tmp/test.html"

# Test 4: /tmp with flag (should warn but work)
ssh root@lab.example.test "nftban report generate --output /tmp/test.html --unsafe-allow-tmp"

# Test 5: /etc (should fail)
ssh root@lab.example.test "nftban report generate --output /etc/test.html"

# Test 6: Path traversal (should fail)
ssh root@lab.example.test "nftban report generate --output ../../etc/passwd"

# Test 7: Check audit log
ssh root@lab.example.test "tail -20 /var/log/nftban/security-audit.log"
```

---

## 📞 SUPPORT

**Email:** contact@nftban.com
**Website:** https://nftban.com

---

**Security Notice:** This update significantly improves NFTBan's security posture by preventing common file write vulnerabilities. No breaking changes for users following best practices (using default paths or safe directories).
