# NFTBan v0.10.0 - Path Validation & Write Security

**Date:** 2025-10-29
**Module:** `nftban_path_security.sh`
**Status:** ✅ IMPLEMENTED & DEPLOYED

---

## 🎯 SECURITY CONCEPT

NFTBan v0.10.0 implements **strict path validation** for all file write operations to prevent:

- **Path Traversal Attacks** (`../../etc/passwd`)
- **Symlink Attacks** (attacker creates `/tmp/report.html → /etc/shadow`)
- **Privilege Escalation** (user-controlled paths when running as root)
- **Information Disclosure** (writing to world-readable `/tmp`)
- **Race Conditions (TOCTOU)** (Time-of-check to time-of-use)
- **Server Compromise** (overwriting system files)

---

## 🔒 SECURITY MODEL

### Three-Tier Path Classification:

#### 1. **ALLOWED** (Default - No Warning)
**Directories:**
- `/var/lib/nftban/reports/` - Generated reports
- `/var/lib/nftban/metrics/` - Statistics database
- `/var/lib/nftban/snapshots/` - Hourly snapshots
- `/var/lib/nftban/exports/` - User exports
- `/var/cache/nftban/` - Temporary cache

**Why Safe:**
- FHS compliant (Filesystem Hierarchy Standard)
- Proper ownership (`nftban:nftban`)
- Correct permissions (750/640)
- Predictable locations for backup/audit
- No risk to system files

#### 2. **RESTRICTED** (Requires `--unsafe-allow-tmp`)
**Directories:**
- `/tmp/`
- `/var/tmp/`

**Why Restricted:**
- **Symlink Attack Risk:** Other users can create symlinks before you
- **Race Conditions:** File can be created/modified between check and write
- **Information Disclosure:** World-readable by default (mode 1777)
- **Persistence Issues:** May survive reboots or be cleaned unexpectedly

**When to Allow:**
- Only for testing/debugging
- Never in production automation
- User explicitly acknowledges risks with `--unsafe-allow-tmp`

#### 3. **FORBIDDEN** (Never Allowed)
**Directories:**
- `/etc/` - System configuration
- `/boot/` - Boot files
- `/root/` - Root home directory
- `/usr/` - System binaries
- `/bin/`, `/sbin/`, `/lib/`, `/lib64/` - Critical system files
- `/sys/`, `/proc/`, `/dev/` - Kernel interfaces
- `/var/log/` - System logs (managed by logrotate, not user exports)

**Why Forbidden:**
- **Critical System Files:** Corruption = system failure
- **Privilege Escalation:** Overwriting binaries/configs as root
- **No Legitimate Use Case:** Reports/exports never belong here

---

## 📝 USAGE EXAMPLES

### ✅ SAFE: Default Location (Recommended)

```bash
# Writes to /var/lib/nftban/reports/report-YYYYMMDD-HHMMSS.html
nftban report generate --format html

# Writes to /var/lib/nftban/exports/stats-YYYYMMDD-HHMMSS.json
nftban stats export --format json
```

**Output:**
```
[SUCCESS] Report: /var/lib/nftban/reports/report-20251029-142530.html
```

---

### ✅ SAFE: Filename Only (Recommended)

```bash
# Writes to /var/lib/nftban/reports/myreport.html
nftban report generate --output myreport.html

# Writes to /var/lib/nftban/exports/mystats.json
nftban stats export --output mystats.json
```

**Output:**
```
[SECURITY] Output path validation enabled - only approved directories allowed
[INFO] Approved locations: /var/lib/nftban/* (reports, metrics, exports)
[SUCCESS] Report: /var/lib/nftban/reports/myreport.html
```

**Security:** Filename is sanitized (path separators removed), then placed in safe directory.

---

### ✅ SAFE: Full Path in Allowed Directory

```bash
# Writes to /var/lib/nftban/reports/monthly/january-2025.html
nftban report generate --output /var/lib/nftban/reports/monthly/january-2025.html
```

**Output:**
```
[SECURITY] Output path validation enabled - only approved directories allowed
[INFO] Approved locations: /var/lib/nftban/* (reports, metrics, exports)
[SUCCESS] Report: /var/lib/nftban/reports/monthly/january-2025.html
```

---

### ⚠️ RESTRICTED: /tmp (Not Recommended)

```bash
# BLOCKED by default
nftban report generate --output /tmp/report.html
```

**Output:**
```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
❌ ERROR: Writing to /tmp REQUIRES --unsafe-allow-tmp
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Attempted path: /tmp/report.html

  SECURITY RISKS:
    • Symlink attacks - attacker creates /tmp/report.html → /etc/passwd
    • Race conditions - file created between check and write
    • Information disclosure - other users can read files
    • Privilege escalation - if run as root with user-controlled paths

  RECOMMENDED ALTERNATIVES (safer):
    1. Use default location (automatic):
       nftban report generate
       → /var/lib/nftban/reports/report-YYYYMMDD-HHMMSS.html

    2. Use filename only (writes to safe directory):
       nftban report generate --output myreport.html
       → /var/lib/nftban/reports/myreport.html

    3. Use --stdout and redirect (you control destination):
       nftban report generate --stdout > ~/report.html

  UNSAFE OPTION (not recommended):
    nftban report generate --output /tmp/report.html --unsafe-allow-tmp
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

### ⚠️ ALLOWED: /tmp with --unsafe-allow-tmp (Use with Caution)

```bash
# Explicitly acknowledge risks
nftban report generate --output /tmp/report.html --unsafe-allow-tmp
```

**Output:**
```
[SECURITY] Output path validation enabled - only approved directories allowed
[INFO] Approved locations: /var/lib/nftban/* (reports, metrics, exports)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
⚠️  SECURITY WARNING: Writing to /tmp
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  Path: /tmp/report.html

  RISKS:
    • Symlink attacks (attacker creates symlink before you)
    • Race conditions (TOCTOU)
    • Information disclosure (world-readable by default)
    • Temporary files may be preserved across reboots

  This operation proceeds because --unsafe-allow-tmp was used.
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
[SUCCESS] Report: /tmp/report.html
```

---

### ❌ FORBIDDEN: System Directories (Always Blocked)

```bash
# ALWAYS BLOCKED, even with --unsafe-allow-tmp
nftban report generate --output /etc/nftban/report.html --unsafe-allow-tmp
```

**Output:**
```
ERROR: Writing to /etc is FORBIDDEN for security
  Attempted path: /etc/nftban/report.html
  Reason: System directory - potential compromise
```

**Same for:** `/boot/`, `/usr/`, `/bin/`, `/root/`, etc.

---

### ❌ BLOCKED: Path Traversal

```bash
nftban report generate --output ../../etc/passwd
```

**Output:**
```
ERROR: Path traversal detected (..) - FORBIDDEN
  Path: /home/user/../../etc/passwd
```

---

## 🛡️ SECURITY FEATURES

### 1. Path Traversal Prevention
```bash
# Blocked
/var/lib/nftban/reports/../../etc/passwd
../../../etc/shadow
```

**Detection:** Regex pattern `\.\.` in canonicalized path.

### 2. Symlink Attack Prevention
```bash
# Before write, check:
if [[ -L "$path" ]]; then
    echo "ERROR: Target is a symbolic link - REFUSING to write"
    return 1
fi
```

**Protection:** Refuse to write if target is a symlink.

### 3. Filename Sanitization
```bash
# Input: "../../etc/passwd"
# Output: ".._.._etc_passwd" (in safe directory)

# Input: "my report.html"
# Output: "my_report.html"
```

**Sanitization:** Remove path separators, null bytes, control characters.

### 4. Canonicalization
```bash
# Resolve symlinks and relative paths
realpath -m "$path"
```

**Before:** `/var/lib/nftban/../../../etc/passwd`
**After:** `/etc/passwd` (then blocked as forbidden)

### 5. Audit Logging
All path validation decisions are logged to `/var/log/nftban/security-audit.log`:

```
2025-10-29 14:25:30 [ALLOWED] pid=12345 ppid=12344 user=admin safe_path path=/var/lib/nftban/reports/report.html allowed_dir=/var/lib/nftban/reports
2025-10-29 14:26:15 [DENIED] pid=12346 ppid=12344 user=admin restricted_tmp path=/tmp/report.html missing_unsafe_flag=true
2025-10-29 14:27:00 [WARNING] pid=12347 ppid=12344 user=admin unsafe_tmp_allowed path=/tmp/test.html
2025-10-29 14:28:30 [DENIED] pid=12348 ppid=12344 user=admin forbidden_dir path=/etc/passwd forbidden=/etc
2025-10-29 14:29:00 [DENIED] pid=12349 ppid=12344 user=admin path_traversal path=/var/lib/../../etc/passwd
```

---

## 📊 AFFECTED COMMANDS

### Commands with Path Security Enabled:

| Command | Module | Default Directory | Supports `--output` | Supports `--unsafe-allow-tmp` |
|---------|--------|------------------|--------------------|-----------------------------|
| `nftban report generate` | cmd_report.sh | `/var/lib/nftban/reports/` | ✅ | ✅ |
| `nftban stats export` | cmd_stats.sh | `/var/lib/nftban/exports/` | ✅ | ✅ |

### Commands with Hardcoded Safe Paths (No User Control):

| Command | Module | Fixed Path | User Control |
|---------|--------|-----------|--------------|
| `nftban profile apply` | cmd_profile.sh | `/var/lib/nftban/profile.current` | ❌ None (hardcoded) |
| Internal logs | core modules | `/var/log/nftban/*.log` | ❌ None (hardcoded) |
| Metrics cache | nftban_stats.sh | `/var/lib/nftban/metrics/` | ❌ None (hardcoded) |

---

## 🔧 IMPLEMENTATION DETAILS

### Module: `nftban_path_security.sh`

**Location:** `/usr/lib/nftban/core/nftban_path_security.sh`

**Key Functions:**

#### 1. `nftban_path_validate_write(path, allow_unsafe)`
- Validates path against allowed/restricted/forbidden lists
- Returns 0 if safe, 1 if blocked
- Prints detailed error messages to stderr

#### 2. `nftban_path_get_safe_output(user_path, default_dir, allow_unsafe, default_ext)`
- Main entry point for path handling
- Handles three cases:
  1. Empty path → use default
  2. Filename only → place in default directory
  3. Full path → validate and use if safe
- Returns safe path or exits with error

#### 3. `nftban_path_sanitize_filename(filename)`
- Removes path separators (`/`)
- Removes null bytes, newlines, control characters
- Removes leading dots (prevents hidden files)
- Returns sanitized filename

#### 4. `nftban_path_create_file_safe(path)`
- Creates file with symlink attack prevention
- Checks if target is symlink BEFORE writing
- Uses `set -C` (noclobber) to prevent race conditions
- Creates parent directories safely

#### 5. `nftban_path_audit_log(event_type, message)`
- Logs all path validation decisions
- Format: `timestamp [TYPE] pid=PID ppid=PPID user=USER message`
- Logged to: `/var/log/nftban/security-audit.log`

---

## 🧪 TESTING

### Test Script

```bash
#!/bin/bash
# Test path security

echo "=== Test 1: Default location (should succeed) ==="
nftban report generate --format html

echo ""
echo "=== Test 2: Filename only (should succeed) ==="
nftban report generate --output test-report.html

echo ""
echo "=== Test 3: Safe full path (should succeed) ==="
nftban report generate --output /var/lib/nftban/reports/custom/test.html

echo ""
echo "=== Test 4: /tmp without flag (should FAIL) ==="
nftban report generate --output /tmp/report.html || echo "✓ Correctly blocked"

echo ""
echo "=== Test 5: /tmp with --unsafe-allow-tmp (should warn but succeed) ==="
nftban report generate --output /tmp/report.html --unsafe-allow-tmp

echo ""
echo "=== Test 6: /etc (should FAIL even with --unsafe-allow-tmp) ==="
nftban report generate --output /etc/test.html --unsafe-allow-tmp || echo "✓ Correctly blocked"

echo ""
echo "=== Test 7: Path traversal (should FAIL) ==="
nftban report generate --output ../../etc/passwd || echo "✓ Correctly blocked"

echo ""
echo "=== Test 8: Check audit log ==="
tail -10 /var/log/nftban/security-audit.log
```

---

## 📚 INTEGRATION WITH EXISTING MODULES

### cmd_report.sh Integration

```bash
# Load security module
source /usr/lib/nftban/core/nftban_path_security.sh

# In generate function
nftban_report_cmd_generate() {
    local output=""
    local allow_unsafe=""

    # Parse --output and --unsafe-allow-tmp
    # ...

    # Security notice
    if [[ -n "$output" ]]; then
        echo "[SECURITY] Output path validation enabled"
    fi

    # Get safe path
    local safe_output
    safe_output=$(nftban_path_get_safe_output "$output" \
        "/var/lib/nftban/reports" "$allow_unsafe" ".html") || return 1

    # Use safe path
    nftban_report_generate_html "$safe_output" "$since" "$until"
}
```

### cmd_stats.sh Integration

```bash
# Load security module
source /usr/lib/nftban/core/nftban_path_security.sh

# In export function
nftban_stats_cmd_export() {
    local output=""
    local allow_unsafe=""

    # Parse options
    # ...

    # Get safe path
    local safe_output
    safe_output=$(nftban_path_get_safe_output "$output" \
        "/var/lib/nftban/exports" "$allow_unsafe" ".json") || return 1

    # Use safe path
    nftban_stats_export_json "$safe_output" "$since" "$until"
}
```

---

## 🔒 BEST PRACTICES

### For Users:

1. **Use default locations** - Most secure, no path validation needed
2. **Use filename only** - Second best, automatic safe directory placement
3. **Avoid /tmp** - Use only for testing/debugging, never in automation
4. **Never use --unsafe-allow-tmp in cron jobs** - Security risk

### For Developers:

1. **Always load `nftban_path_security.sh`** before accepting user paths
2. **Always use `nftban_path_get_safe_output()`** - Never trust raw user input
3. **Always check return codes** - `|| return 1` to propagate errors
4. **Always use `nftban_path_create_file_safe()`** - Prevents symlink attacks
5. **Log security events** - Use `nftban_path_audit_log()`
6. **Provide clear error messages** - Explain risks and alternatives

---

## 📖 REFERENCES

### Related Security Modules:

- **`nftban_security.sh`** - Whitelist hardening, auditd monitoring
- **`nftban_path_security.sh`** - Path validation (this document)

### Related Documentation:

- `SECURITY.md` - Overall security architecture
- `FHS_COMPLIANCE.md` - Filesystem layout
- `DEPLOYMENT_GUIDE.md` - Secure deployment practices

### Standards:

- **FHS 3.0** - Filesystem Hierarchy Standard
- **CWE-22** - Improper Limitation of a Pathname to a Restricted Directory ('Path Traversal')
- **CWE-59** - Improper Link Resolution Before File Access ('Link Following')
- **CWE-367** - Time-of-check Time-of-use (TOCTOU) Race Condition

---

## 🛠️ TROUBLESHOOTING

### Error: "Path not in allowed write directories"

**Cause:** Trying to write outside `/var/lib/nftban/*`

**Solution:**
1. Use default: `nftban report generate`
2. Use filename only: `--output report.html`
3. If you need custom location, use redirect: `--stdout > ~/report.html` (future feature)

### Error: "Writing to /tmp requires --unsafe-allow-tmp"

**Cause:** Security protection against symlink/race attacks

**Solution:**
1. **Recommended:** Use `/var/lib/nftban/reports/` instead
2. **For testing only:** Add `--unsafe-allow-tmp` flag

### Error: "Target is a symbolic link - refusing to write"

**Cause:** Symlink attack prevention

**Solution:** Remove the symlink, use regular file or safe directory

---

## ✅ DEPLOYMENT CHECKLIST

- [x] `nftban_path_security.sh` deployed to `/usr/lib/nftban/core/`
- [x] `cmd_report.sh` updated to use path security
- [x] `cmd_stats.sh` updated to use path security
- [x] Security audit log created: `/var/log/nftban/security-audit.log`
- [x] FHS module updated with `/var/lib/nftban/exports/` directory
- [x] Documentation created (this file)
- [x] Deployed to all lab servers (lab, lab1, lab2)

---

**Security Notice:** This path validation system is part of NFTBan's defense-in-depth strategy. It prevents common file write vulnerabilities but should be combined with proper permissions, least privilege, and regular security audits.

**Contact:** contact@nftban.com
**Website:** https://nftban.com
