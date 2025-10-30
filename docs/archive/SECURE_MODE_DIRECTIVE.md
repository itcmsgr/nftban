# NFTBan Secure Mode Directive - Developer Guide

**Auto-Apply Security to ANY Script - One Line!**

---

## 🎯 CONCEPT

Add **ONE line** to your script to automatically secure ALL file writes:

```bash
#!/usr/bin/env bash
source /usr/lib/nftban/core/nftban_secure_mode.sh

# Now ALL file writes are automatically validated!
# - Path traversal blocked
# - Symlink attacks prevented
# - /tmp writes require explicit flag
# - /etc, /usr, /boot ALWAYS blocked
# - Audit logging automatic
```

---

## 🚀 QUICK START

### Before (Insecure):

```bash
#!/usr/bin/env bash
# Old insecure script

generate_report() {
    local output="$1"  # User input - DANGER!

    echo "<html>Report</html>" > "$output"
    #                              ^^^^^^^ NO VALIDATION!
    # User can set output="/etc/passwd" → COMPROMISED!
}

generate_report "$USER_INPUT"
```

**Problems:**
- Path traversal: `../../etc/passwd`
- Symlink attack: `/tmp/report → /etc/shadow`
- Overwrite system files: `/usr/bin/nftban`

---

### After (Secure):

```bash
#!/usr/bin/env bash
source /usr/lib/nftban/core/nftban_secure_mode.sh

generate_report() {
    local output="$1"

    # Get safe path (automatically validated)
    local safe_path
    safe_path=$(nftban_get_output_path "$output") || return 1
    #          ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
    #          All validation happens HERE automatically!

    # Write to safe path
    nftban_write_safe "$safe_path" "<html>Report</html>"

    echo "[SUCCESS] Report: $safe_path"
}

generate_report "$USER_INPUT"
```

**Security:**
- ✅ Path validation automatic
- ✅ Symlink attack prevention
- ✅ Forbidden directories blocked
- ✅ Audit logging enabled
- ✅ User-friendly error messages

---

## 📖 DEVELOPER API

### 1. Get Safe Output Path

**MOST COMMON - Use this for user-provided paths:**

```bash
# Signature:
safe_path=$(nftban_get_output_path "user_input" ["default_dir"] ["extension"])

# Example 1: User provides path
user_path="/tmp/report.html"
safe_path=$(nftban_get_output_path "$user_path") || exit 1
# → BLOCKED: /tmp requires --unsafe-allow-tmp
# → User sees clear error with alternatives

# Example 2: User provides filename only
user_path="myreport.html"
safe_path=$(nftban_get_output_path "$user_path")
# → /var/lib/nftban/reports/myreport.html

# Example 3: Empty = use default
safe_path=$(nftban_get_output_path "")
# → /var/lib/nftban/reports/report-20251029-142530.html

# Example 4: Custom default directory
safe_path=$(nftban_get_output_path "$user_path" "/var/lib/nftban/exports" ".json")
# → /var/lib/nftban/exports/export-20251029-142530.json
```

---

### 2. Write to Safe File

```bash
# Write content to file (validates path automatically)
nftban_write_safe "/var/lib/nftban/reports/test.html" "content"

# Or combine with path validation:
safe_path=$(nftban_get_output_path "$user_input") || return 1
nftban_write_safe "$safe_path" "$content"
```

---

### 3. Append to Safe File

```bash
# Append to log file
nftban_append_safe "/var/log/nftban/custom.log" "Log entry: $(date)"

# Append user data
safe_path=$(nftban_get_output_path "$log_file") || return 1
nftban_append_safe "$safe_path" "$log_entry"
```

---

### 4. Copy Files Securely

```bash
# Copy with destination validation
nftban_secure_copy "/tmp/source.txt" "/var/lib/nftban/reports/dest.txt"
```

---

### 5. Pipe with Validation

```bash
# Secure tee
cat data.txt | nftban_secure_tee "/var/lib/nftban/reports/output.txt"
```

---

## 🎨 PRACTICAL EXAMPLES

### Example 1: Report Generator

```bash
#!/usr/bin/env bash
source /usr/lib/nftban/core/nftban_secure_mode.sh

generate_html_report() {
    local user_output="$1"
    local report_title="$2"

    # Validate and get safe path
    local safe_path
    safe_path=$(nftban_get_output_path "$user_output" "/var/lib/nftban/reports" ".html") || {
        echo "ERROR: Invalid output path" >&2
        return 1
    }

    # Generate HTML
    local html="<html><head><title>$report_title</title></head><body>..."

    # Write securely
    nftban_write_safe "$safe_path" "$html" || {
        echo "ERROR: Failed to write report" >&2
        return 1
    }

    echo "[SUCCESS] Report generated: $safe_path"
    return 0
}

# Usage examples:
generate_html_report "myreport.html" "Daily Stats"
#   → /var/lib/nftban/reports/myreport.html

generate_html_report "" "Auto Report"
#   → /var/lib/nftban/reports/report-TIMESTAMP.html

generate_html_report "/tmp/bad.html" "Test"
#   → ERROR: /tmp requires --unsafe-allow-tmp
```

---

### Example 2: Data Exporter

```bash
#!/usr/bin/env bash
source /usr/lib/nftban/core/nftban_secure_mode.sh

export_data() {
    local format="$1"  # json, csv, xml
    local output="$2"  # User-provided path

    # Get safe path with format-specific extension
    local ext=".${format}"
    local safe_path
    safe_path=$(nftban_get_output_path "$output" "/var/lib/nftban/exports" "$ext") || return 1

    # Generate data
    local data
    case "$format" in
        json) data='{"key": "value"}' ;;
        csv)  data='key,value\nfoo,bar' ;;
        xml)  data='<root><key>value</key></root>' ;;
        *) echo "ERROR: Unknown format: $format" >&2; return 1 ;;
    esac

    # Write securely
    nftban_write_safe "$safe_path" "$data"

    echo "[SUCCESS] Export ($format): $safe_path"
}

# Usage:
export_data json "stats.json"
#   → /var/lib/nftban/exports/stats.json

export_data csv ""
#   → /var/lib/nftban/exports/export-TIMESTAMP.csv
```

---

### Example 3: Log Aggregator

```bash
#!/usr/bin/env bash
source /usr/lib/nftban/core/nftban_secure_mode.sh

aggregate_logs() {
    local output_log="$1"

    # Get safe log path
    local safe_path
    safe_path=$(nftban_get_output_path "$output_log" "/var/log/nftban" ".log") || return 1

    # Aggregate from multiple sources
    for source in /var/log/nftban/*.log; do
        echo "=== $(basename "$source") ===" | nftban_secure_tee -a "$safe_path"
        tail -100 "$source" | nftban_secure_tee -a "$safe_path"
    done

    echo "[SUCCESS] Aggregated logs: $safe_path"
}
```

---

### Example 4: Configuration Generator

```bash
#!/usr/bin/env bash
source /usr/lib/nftban/core/nftban_secure_mode.sh

generate_config() {
    local template="$1"
    local output="$2"

    # Configs always go to /etc/nftban/conf.d/ (safe hardcoded path)
    local config_dir="/etc/nftban/conf.d"
    local safe_path
    safe_path=$(nftban_get_output_path "$output" "$config_dir" ".conf") || return 1

    # Load template
    local content
    content=$(cat "$template")

    # Write config
    nftban_write_safe "$safe_path" "$content"

    echo "[SUCCESS] Config generated: $safe_path"
}
```

---

## ⚙️ CONFIGURATION

### Environment Variables:

```bash
# Enable/disable secure mode (default: enabled)
export NFTBAN_SECURE_MODE_ENABLED=1

# Strict mode: fail on violations (default: yes)
export NFTBAN_SECURE_MODE_STRICT=1

# Allow unsafe operations (default: no)
export NFTBAN_SECURE_MODE_ALLOW_UNSAFE=""

# Enable audit logging (default: yes)
export NFTBAN_SECURE_MODE_AUDIT=1
```

---

### Runtime Control:

```bash
# Enable secure mode
nftban_secure_mode_enable

# Disable (not recommended)
nftban_secure_mode_disable

# Allow /tmp writes (temporary)
nftban_secure_mode_allow_unsafe
# ... do unsafe operation ...
nftban_secure_mode_disallow_unsafe
```

---

## 🛡️ WHAT GETS BLOCKED?

### ❌ ALWAYS BLOCKED (FORBIDDEN):

```bash
/etc/passwd              # System files
/boot/vmlinuz            # Boot files
/usr/bin/bash            # System binaries
/root/.ssh/authorized_keys  # Root home
/var/log/messages        # System logs
```

**Result:** `ERROR: Writing to /etc is FORBIDDEN for security`

---

### ⚠️ BLOCKED BY DEFAULT (RESTRICTED):

```bash
/tmp/report.html         # Symlink attack risk
/var/tmp/data.json       # Race condition risk
```

**Result:** `ERROR: Writing to /tmp requires --unsafe-allow-tmp`

**Workaround (not recommended):**
```bash
export NFTBAN_SECURE_MODE_ALLOW_UNSAFE="allow-unsafe"
# or
nftban_secure_mode_allow_unsafe
```

---

### ✅ ALWAYS ALLOWED (SAFE):

```bash
/var/lib/nftban/reports/*
/var/lib/nftban/metrics/*
/var/lib/nftban/exports/*
/var/lib/nftban/snapshots/*
/var/cache/nftban/*
```

---

## 🔍 AUDIT LOGGING

All path validation decisions are logged to `/var/log/nftban/security-audit.log`:

```
2025-10-29 14:25:30 [ALLOWED] pid=12345 user=admin safe_path path=/var/lib/nftban/reports/test.html
2025-10-29 14:26:15 [DENIED] pid=12346 user=admin restricted_tmp path=/tmp/bad.html
2025-10-29 14:27:00 [WARNING] pid=12347 user=admin unsafe_tmp_allowed path=/tmp/test.html
2025-10-29 14:28:30 [DENIED] pid=12348 user=admin forbidden_dir path=/etc/passwd
2025-10-29 14:29:00 [WRITE] pid=12349 user=admin secure_write path=/var/lib/nftban/reports/report.html size=12345
```

---

## 📋 INTEGRATION CHECKLIST

When adding secure mode to existing scripts:

- [ ] Add `source /usr/lib/nftban/core/nftban_secure_mode.sh` at top
- [ ] Replace all user-provided paths with `nftban_get_output_path()`
- [ ] Use `nftban_write_safe()` instead of `echo > "$file"`
- [ ] Use `nftban_append_safe()` instead of `echo >> "$file"`
- [ ] Use `nftban_secure_copy()` instead of `cp`
- [ ] Handle errors: `safe_path=$(nftban_get_output_path "$input") || return 1`
- [ ] Test with forbidden paths: `/etc/test`, `../../etc/passwd`
- [ ] Test with restricted paths: `/tmp/test`
- [ ] Test with safe paths: `/var/lib/nftban/reports/test`
- [ ] Verify audit log: `tail -f /var/log/nftban/security-audit.log`

---

## 🧪 TESTING YOUR SCRIPT

```bash
# Test script with secure mode
./your_script.sh --output "safe.html"
#   → Should succeed

./your_script.sh --output "/var/lib/nftban/reports/safe.html"
#   → Should succeed

./your_script.sh --output "/tmp/test.html"
#   → Should FAIL with clear error

./your_script.sh --output "../../etc/passwd"
#   → Should FAIL (path traversal blocked)

# Check audit log
tail -20 /var/log/nftban/security-audit.log
```

---

## ❓ FAQ

### Q: Do I need to change all my scripts?
**A:** Only scripts that accept user-provided file paths. Scripts with hardcoded safe paths are already secure.

### Q: What if I need to write to /tmp for testing?
**A:** Use `nftban_secure_mode_allow_unsafe` temporarily, or better: use `/var/lib/nftban/` for testing too.

### Q: Does this slow down my script?
**A:** Minimal overhead (~1ms per path validation). Path is validated once, then used normally.

### Q: Can I disable secure mode?
**A:** Yes, but not recommended: `export NFTBAN_SECURE_MODE_ENABLED=0`

### Q: What if user wants to write to their home directory?
**A:** Use `--stdout` and let user redirect: `script --stdout > ~/report.html`

---

## 📚 RELATED DOCUMENTATION

- `SECURITY_PATH_VALIDATION.md` - Detailed security architecture
- `nftban_path_security.sh` - Low-level path validation module
- `nftban_secure_mode.sh` - This directive (source code)

---

## ✅ DEPLOYMENT

1. **Copy module:**
   ```bash
   cp nftban_secure_mode.sh /usr/lib/nftban/core/
   chmod 644 /usr/lib/nftban/core/nftban_secure_mode.sh
   ```

2. **Update existing scripts:**
   ```bash
   # Add to top of each script accepting user paths:
   source /usr/lib/nftban/core/nftban_secure_mode.sh
   ```

3. **Test:**
   ```bash
   # Test with safe path
   nftban report generate --output test.html

   # Test with forbidden path
   nftban report generate --output /etc/test.html
   ```

---

**Remember:** Security is a process, not a product. Use secure mode consistently across ALL user-facing scripts!

**Contact:** contact@nftban.com
**Website:** https://nftban.com
