# NFTBan Update Module

**File:** `lib/nftban_update_module.sh`  
**Version:** 1.1.0 (Security Hardening)  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Safe update/upgrade system with security hardening and atomic operations

---

## Overview

The Update Module provides a secure, automated system for updating NFTBan to newer versions from GitHub. It implements a multi-stage workflow with staging directories, checksum validation, syntax verification, automatic backups, and atomic apply with rollback capability.

Version 1.1.0 introduces comprehensive security hardening including path traversal prevention, command injection protection in SHA256 validation, HTTPS-only downloads with certificate validation, safe temporary directory creation, input sanitization for all external data, and strict validation of all file paths and URLs.

Key features include version detection and comparison (semantic versioning), staging directory workflow (download → validate → apply), SHA256 checksum validation (command injection protected), atomic file replacement with rollback, automatic pre-update backups, syntax validation before apply, email notifications on completion, and dry-run mode for testing.

---

## Key Functions

### Public Functions

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_update_get_local_version()` | Get installed version | None | Version string |
| `nftban_update_get_remote_version()` | Get latest GitHub version | None | Version string or 1 on error |
| `nftban_update_compare_versions()` | Compare two versions | `$1` - version1<br>`$2` - version2 | 0=equal, 1=v1>v2, 2=v1<v2 |
| `nftban_update_check()` | Check for available updates | `$1` - show_output (default: true) | 0=up-to-date, 1=error, 2=update available |
| `nftban_update_perform()` | Perform full update | `$1` - skip_confirmation (default: false) | 0 on success, 1 on error |
| `nftban_update_create_backup()` | Create pre-update backup | None | Backup directory path |
| `nftban_update_rollback()` | Rollback to backup | `$1` - backup_dir (optional) | 0 on success, 1 on error |
| `nftban_update_staging_init()` | Initialize staging directory | None | 0 on success, 1 on error |
| `nftban_update_staging_clean()` | Clean staging directory | None | Always 0 |
| `nftban_update_download_to_staging()` | Download files to staging | None | 0 on success, 1 on error |
| `nftban_update_validate_staging()` | Validate staged files | `$1` - staging_dir (optional) | 0 on success, 1 on error |
| `nftban_update_apply()` | Apply update atomically | `$1` - staging_dir (optional) | 0 on success, 1 on error |

### Internal Security Functions (Private)

| Function | Purpose | Notes |
|----------|---------|-------|
| `_nftban_update_validate_path()` | Validate file path (prevent traversal) | Rejects ../, absolute paths, dangerous chars |
| `_nftban_update_validate_url()` | Validate URL (HTTPS-only from GitHub) | Prevents non-HTTPS, non-GitHub URLs |
| `_nftban_update_safe_sha256()` | Safe SHA256 calculation | Prevents command injection |
| `nftban_update_download_file()` | Secure file download | Uses validated paths and URLs |
| `nftban_update_validate_checksums()` | Validate file integrity | SHA256 verification |
| `nftban_update_validate_syntax()` | Validate shell script syntax | Bash -n check |
| `nftban_update_send_notification()` | Send email notification | Optional, if configured |

---

## Configuration Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_UPDATE_GITHUB_RAW` | `https://raw.githubusercontent.com/itcmsgr/nftban/main` | GitHub raw content URL |
| `NFTBAN_UPDATE_GITHUB_API` | `https://api.github.com/repos/itcmsgr/nftban` | GitHub API URL |
| `NFTBAN_UPDATE_STAGING_DIR` | `${NFTBAN_BASE_DIR}/.update_tmp` | Temporary staging directory |
| `NFTBAN_UPDATE_BACKUP_DIR` | `${NFTBAN_DATA_DIR}/backups` | Backup storage directory |
| `NFTBAN_VERSION_FILE` | `${NFTBAN_BASE_DIR}/.version` | Version file location |
| `NFTBAN_CHANGELOG_FILE` | `${NFTBAN_BASE_DIR}/CHANGELOG.md` | Changelog file location |
| `NFTBAN_UPDATE_LOG` | `${NFTBAN_LOG_DIR}/update.log` | Update activity log |

---

## Dependencies

**Required Commands:**
- `curl` or `wget` - Download files (required)
- `sha256sum` or `shasum` - Checksum validation (required)
- `rsync` - Atomic file copy (recommended, falls back to cp)
- `bash` - Syntax validation (required)

**Optional:**
- `mail` or `sendmail` - Email notifications (optional)

---

## Usage Examples

### Example 1: Check for Updates
```bash
nftban update check

# Expected output:
# [INFO] Checking for updates...
#
# Current version:  0.9.0
# Available version: 0.9.1
#
# [SUCCESS] Update available: 0.9.0 → 0.9.1
```

### Example 2: Perform Update (Interactive)
```bash
nftban update perform

# Expected output:
# [INFO] Starting nftban update process...
#
# [INFO] Checking for updates...
#
# Current version:  0.9.0
# Available version: 0.9.1
#
# [SUCCESS] Update available: 0.9.0 → 0.9.1
#
# Do you want to proceed with the update? [y/N] y
#
# [INFO] Initializing staging directory...
# [SUCCESS] Staging directory ready: /etc/nftban/.update_tmp
# [INFO] Downloading update files to staging...
# .........................
# [SUCCESS] Downloaded 23 files successfully
# [INFO] Running validation checks...
#
# [INFO] Validating file integrity...
# [SUCCESS] File integrity validated (23 files)
# [INFO] Validating script syntax...
# [SUCCESS] Syntax validation passed (23 scripts)
#
# [SUCCESS] All validation checks passed ✓
# [INFO] Applying update...
# [INFO] Creating backup: /var/lib/nftban/backups/pre_update_20251020_143215
# [SUCCESS] Backup created successfully
# [INFO] Copying files from staging to production...
# [SUCCESS] Updated lib directory
# [SUCCESS] Updated version file
# [SUCCESS] Updated changelog
# [SUCCESS] Update applied successfully
#
# ═══════════════════════════════════════════════
#   Update completed successfully!
#   Version: 0.9.1
# ═══════════════════════════════════════════════
```

### Example 3: Automated Update (No Confirmation)
```bash
# For use in scripts/automation
nftban update perform --skip-confirmation

# Or using the function directly
nftban_update_perform true
```

### Example 4: Manual Rollback
```bash
# Rollback to last backup
nftban update rollback

# Expected output:
# [WARNING] Rolling back to backup: /var/lib/nftban/backups/pre_update_20251020_143215
# [INFO] Restored lib directory
# [SUCCESS] Rollback completed

# Rollback to specific backup
nftban update rollback /var/lib/nftban/backups/pre_update_20251015_100530
```

### Example 5: Get Version Information
```bash
# Local version
nftban_update_get_local_version
# Output: 0.9.0

# Remote version
nftban_update_get_remote_version
# Output: 0.9.1

# Compare versions
nftban_update_compare_versions "0.9.0" "0.9.1"
echo $?
# Output: 2 (local < remote, update available)
```

---

## Update Workflow (Step-by-Step)

### Phase 1: Check
```
User runs: nftban update perform
    ↓
1. Get local version from .version file
2. Fetch remote version from GitHub
3. Compare versions (semantic versioning)
4. If update available, proceed
   If up-to-date, exit
```

### Phase 2: Staging
```
5. Initialize staging directory
   - Create /etc/nftban/.update_tmp
   - Set restrictive permissions (700)
   - Verify ownership (root)
    ↓
6. Download files to staging
   - All core modules (.sh files)
   - Version file (.version)
   - Changelog (CHANGELOG.md)
   - SHA256SUMS.txt (if available)
```

### Phase 3: Validation
```
7. SHA256 checksum validation
   - Download SHA256SUMS.txt
   - Verify each file's integrity
   - Command injection protected
    ↓
8. Syntax validation
   - Run bash -n on all .sh files
   - Detect syntax errors before apply
    ↓
9. Version file validation
   - Ensure .version exists in staging
```

### Phase 4: Backup
```
10. Create pre-update backup
    - Backup lib/ directory
    - Backup .version and CHANGELOG.md
    - Backup config files (not .local)
    - Store in /var/lib/nftban/backups/pre_update_TIMESTAMP
    - Save backup path to .last_backup
```

### Phase 5: Apply
```
11. Atomic file replacement
    - Use rsync (atomic) or cp (fallback)
    - Replace lib/ directory
    - Update .version file
    - Update CHANGELOG.md
    - Set correct permissions (755 for directories, +x for .sh)
    - Sync filesystem (ensure writes flushed)
```

### Phase 6: Cleanup
```
12. Remove staging directory
13. Log update to update.log
14. Send email notification (if configured)
15. Display success message
```

---

## Security Features (v1.1.0)

### 1. Path Traversal Prevention

**Protection:** `_nftban_update_validate_path()`

**Blocks:**
- `../../../etc/passwd` (parent directory traversal)
- `/etc/passwd` (absolute paths)
- `file;rm -rf /` (command injection via filenames)
- Paths with dangerous characters: `` $`; |&<> ``

**Allows:**
- `lib/nftban_core.sh` (relative paths)
- `config/whitelist.conf` (alphanumeric with slashes)

**Implementation:**
```bash
# Reject absolute paths
[[ "$path" =~ ^/ ]] && return 1

# Reject path traversal
[[ "$path" =~ \.\. ]] && return 1

# Reject dangerous characters
[[ "$path" =~ [\$\`\;\ \|\&\<\>] ]] && return 1

# Only allow safe characters
[[ ! "$path" =~ ^[a-zA-Z0-9._/-]+$ ]] && return 1
```

---

### 2. Command Injection Prevention

**Attack Vector:** SHA256 calculation with malicious filenames

**Vulnerable Code (OLD):**
```bash
# DANGEROUS - Command injection possible
sha256sum $file_path | awk '{print $1}'

# Attack: file_path="file.sh; rm -rf /"
# Executes: sha256sum file.sh; rm -rf / | awk ...
```

**Protected Code (NEW):**
```bash
# SAFE - Uses -- to prevent option injection
sha256sum -- "$file_path" 2>/dev/null | awk '{print $1}'

# Attack fails - filename treated as literal argument
```

**Additional Protection:**
- File path validation before SHA256 calculation
- File existence and readability checks
- Error handling with proper exit codes

---

### 3. HTTPS-Only Downloads

**Enforcement:** `_nftban_update_validate_url()`

**Blocks:**
- `http://...` (unencrypted)
- `ftp://...` (insecure protocol)
- `https://malicious.com/...` (not GitHub)
- `https://github.com%00evil.com/...` (NULL byte injection)

**Allows Only:**
- `https://raw.githubusercontent.com/...`
- `https://api.github.com/...`

**Download Security:**
```bash
# curl: NO -k/--insecure flag (would skip cert validation)
curl --fail --silent --show-error --location \
     --connect-timeout 10 --max-time 30 \
     -o "$file" "$url"

# wget: NO --no-check-certificate (would skip cert validation)
wget --quiet --timeout=10 --tries=3 \
     -O "$file" "$url"
```

---

### 4. Secure Staging Directory

**Permissions:** 700 (rwx------)
- Only root can read/write/execute
- Other users cannot access staged files
- Prevents tampering during update

**Ownership Verification:**
```bash
if [[ $(stat -c '%U' "$STAGING_DIR") != "root" ]]; then
    # Warning: potential security issue
fi
```

**Cleanup:**
- Always removed after update (success or failure)
- Fresh creation for each update
- No persistent staging data

---

### 5. Input Sanitization

**All External Data Validated:**
- File paths from GitHub
- URLs from configuration
- Version strings from remote
- Checksums from SHA256SUMS.txt

**Validation Pattern:**
```bash
# 1. Sanitize input
input="${input#"${input%%[![:space:]]*}"}"  # Trim leading
input="${input%"${input##*[![:space:]]}"}"  # Trim trailing

# 2. Validate format
[[ "$input" =~ ^[allowed_chars]+$ ]] || return 1

# 3. Check for attacks
[[ "$input" =~ dangerous_pattern ]] && return 1

# 4. Use validated value
process "$input"
```

---

## File Operations

### Reads from:
- `$NFTBAN_VERSION_FILE` - Current version
- `${NFTBAN_BASE_DIR}/lib/*.sh` - Current modules (for backup)
- `$NFTBAN_CHANGELOG_FILE` - Current changelog (for backup)
- `${NFTBAN_CONFIG_DIR}/*.conf` - Config files (for backup, excludes *.local)

### Writes to:
- `$NFTBAN_UPDATE_STAGING_DIR/*` - Temporary staged files
- `${NFTBAN_UPDATE_BACKUP_DIR}/pre_update_*/*` - Pre-update backups
- `${NFTBAN_DATA_DIR}/.last_backup` - Last backup path reference
- `$NFTBAN_UPDATE_LOG` - Update activity log
- `$NFTBAN_VERSION_FILE` - Updated version (after apply)
- `${NFTBAN_BASE_DIR}/lib/*` - Updated modules (after apply)
- `$NFTBAN_CHANGELOG_FILE` - Updated changelog (after apply)

### Downloads from:
- `${NFTBAN_UPDATE_GITHUB_RAW}/.version` - Version file
- `${NFTBAN_UPDATE_GITHUB_RAW}/lib/*.sh` - Module files
- `${NFTBAN_UPDATE_GITHUB_RAW}/CHANGELOG.md` - Changelog
- `${NFTBAN_UPDATE_GITHUB_RAW}/SHA256SUMS.txt` - Checksums (optional)

---

## Backup Structure

### Pre-Update Backup Contents

```
/var/lib/nftban/backups/pre_update_20251020_143215/
├── lib/                          # All modules
│   ├── nftban_core.sh
│   ├── nftban_main_cli.sh
│   ├── nftban_update_module.sh
│   └── ... (all other modules)
├── config/                       # Config files (not .local)
│   ├── whitelist_ips.conf
│   ├── blacklist_ips.conf
│   └── ... (system configs)
├── .version                      # Version file
├── CHANGELOG.md                  # Changelog
└── backup_info.txt               # Metadata
```

### Backup Metadata (backup_info.txt)

```
Backup Created: 2025-10-20 14:32:15
Hostname: web-server-01.example.com
Version: 0.9.0
Purpose: Pre-update backup
```

---

## Version Comparison Logic

### Semantic Versioning Format

**Supported:** `X.Y.Z[-suffix]`
- X = Major version
- Y = Minor version
- Z = Patch version
- suffix = Optional (e.g., -beta, -alpha, -rc1)

**Examples:**
- `0.9.0`
- `1.0.0-beta`
- `1.2.3-rc1`

### Comparison Algorithm

```bash
nftban_update_compare_versions "0.9.0" "0.9.1"
# Returns: 2 (0.9.0 < 0.9.1)

nftban_update_compare_versions "1.0.0" "0.9.9"
# Returns: 1 (1.0.0 > 0.9.9)

nftban_update_compare_versions "1.2.3" "1.2.3"
# Returns: 0 (equal)
```

**Comparison Steps:**
1. Remove 'v' prefix if present (`v1.0.0` → `1.0.0`)
2. Split by `-` to separate version from suffix
3. Split version by `.` into [major, minor, patch]
4. Compare major, then minor, then patch
5. Ignore suffix for now (future: proper pre-release handling)

---

## Validation Checks

### 1. SHA256 Checksum Validation

**Source:** `SHA256SUMS.txt` from GitHub

**Format:**
```
a1b2c3d4... lib/nftban_core.sh
e5f6g7h8... lib/nftban_main_cli.sh
... (all files)
```

**Process:**
1. Download SHA256SUMS.txt
2. For each file in checksums:
   - Validate path (prevent traversal)
   - Calculate actual SHA256
   - Compare with expected checksum
   - Log mismatches as errors

**Result:**
- All match: Continue
- Any mismatch: Abort update

---

### 2. Syntax Validation

**Command:** `bash -n file.sh`

**Checks:**
- Syntax errors (missing braces, quotes, etc.)
- Invalid bash constructs
- Parse errors

**Does NOT Check:**
- Logic errors
- Runtime errors
- Command availability

**Process:**
1. Find all `.sh` files in staging
2. Run `bash -n` on each
3. Count successes and failures
4. If any failures: Abort update

---

### 3. Version File Validation

**Checks:**
- `.version` file exists in staging
- File is readable
- Contains valid version string

**Critical:** Without version file, cannot determine what was installed

---

## Rollback Procedure

### Automatic Rollback

**Triggered When:**
- Apply phase fails (file copy error)
- Permissions setting fails
- Critical error during update

**Process:**
```bash
1. Detect failure during apply
2. Log error
3. Call nftban_update_rollback()
4. Restore from last backup
5. Clean staging
6. Report failure to user
```

### Manual Rollback

**When to Use:**
- Update completed but system unstable
- New version has bugs
- Need to revert to known-good state

**Command:**
```bash
# Rollback to last backup
nftban update rollback

# Rollback to specific backup
nftban update rollback /var/lib/nftban/backups/pre_update_20251020_143215
```

**What Gets Restored:**
- All module files (lib/)
- Version file (.version)
- Changelog (CHANGELOG.md)
- System config files (not .local - user configs preserved)

**What's NOT Restored:**
- User configuration (.local files)
- User whitelist/blacklist
- Data files (ban logs, statistics)
- nftables active rules

---

## Troubleshooting

### Problem: Update Check Fails

**Error:** "Cannot check for updates (network issue)"

**Diagnostic:**
```bash
# Test network connectivity
ping -c 3 raw.githubusercontent.com

# Test GitHub API
curl -I https://api.github.com

# Test specific file
curl -I https://raw.githubusercontent.com/itcmsgr/nftban/main/.version

# Check DNS
nslookup raw.githubusercontent.com
```

**Solution:**
```bash
# Check firewall
iptables -L OUTPUT -v | grep -E "80|443"

# Check proxy settings
echo $http_proxy
echo $https_proxy

# Retry update
nftban update check
```

---

### Problem: SHA256 Validation Fails

**Error:** "Checksum mismatch: lib/nftban_core.sh"

**Cause:**
- Network corruption during download
- GitHub CDN cache issue
- Man-in-the-middle attack (rare)

**Solution:**
```bash
# Clean staging and retry
rm -rf /etc/nftban/.update_tmp
nftban update perform

# If persists, check network security
# Verify HTTPS certificate
openssl s_client -connect raw.githubusercontent.com:443 -showcerts
```

---

### Problem: Syntax Validation Fails

**Error:** "Syntax error in: lib/nftban_xxx_module.sh"

**Cause:**
- Incomplete download (network interruption)
- Corrupted file
- Actual syntax error in remote file (rare)

**Solution:**
```bash
# Check specific file manually
bash -n /etc/nftban/.update_tmp/lib/nftban_xxx_module.sh

# View error details
bash -n /etc/nftban/.update_tmp/lib/nftban_xxx_module.sh 2>&1

# Clean and retry
rm -rf /etc/nftban/.update_tmp
nftban update perform
```

---

### Problem: Apply Phase Fails

**Error:** "Update failed - attempting rollback..."

**Automatic Action:** Rollback initiated

**Post-Rollback Verification:**
```bash
# Check version restored
nftban --version

# Check modules present
ls -l /etc/nftban/lib/

# Check system health
nftban maintenance health

# Review update log
tail -50 /var/log/nftban/update.log
```

---

### Problem: Rollback Needed After Successful Update

**Scenario:** Update completed but system behaves unexpectedly

**Solution:**
```bash
# Find last backup
ls -lt /var/lib/nftban/backups/ | head -5

# Rollback to pre-update state
nftban update rollback /var/lib/nftban/backups/pre_update_20251020_143215

# Verify rollback
nftban --version
nftban validate status

# Report issue
# (Create GitHub issue with details)
```

---

## Best Practices

### ✅ DO:

1. **Check for updates regularly** (weekly/monthly)
2. **Review changelog** before updating
3. **Create manual backup** before critical updates
4. **Test in staging environment** first (if available)
5. **Monitor logs** after update
6. **Keep backups** for 30+ days
7. **Update during maintenance window** (low traffic)
8. **Verify system health** after update
9. **Read release notes** on GitHub
10. **Enable email notifications** for update alerts

### ❌ DON'T:

1. **Don't skip backups** (automatic, but verify)
2. **Don't update during peak hours** (risk downtime)
3. **Don't ignore validation errors** (abort if fail)
4. **Don't disable HTTPS validation** (security risk)
5. **Don't modify staging files** manually
6. **Don't delete backups immediately** (wait 30 days)
7. **Don't update without testing first** (if critical system)
8. **Don't skip changelog review** (breaking changes?)
9. **Don't panic if rollback needed** (designed for this)
10. **Don't use insecure download methods** (HTTP, no certs)

---

## Automated Update (Cron)

### Setup Weekly Update Check

```bash
# Add to crontab
crontab -e

# Check for updates every Monday at 3 AM
0 3 * * 1 /usr/local/bin/nftban update check >> /var/log/nftban/update-check.log 2>&1

# Or check daily
0 3 * * * /usr/local/bin/nftban update check >> /var/log/nftban/update-check.log 2>&1
```

### Automated Update (With Email)

```bash
#!/bin/bash
# /usr/local/bin/nftban-auto-update.sh

# Enable email notifications
NFTBAN_EMAIL_RECIPIENT="admin@example.com"

# Check for updates
if nftban update check --quiet; then
    echo "No updates available"
    exit 0
fi

# Check if update available
nftban_update_compare_versions \
    "$(nftban_update_get_local_version)" \
    "$(nftban_update_get_remote_version)"

if [[ $? -eq 2 ]]; then
    # Update available - perform it
    nftban update perform --skip-confirmation
    
    if [[ $? -eq 0 ]]; then
        echo "Update successful"
    else
        echo "Update failed - rollback performed"
        # Alert admin
        echo "NFTBan update failed on $(hostname)" | \
            mail -s "ALERT: NFTBan Update Failed" admin@example.com
    fi
fi

# Add to cron (Sunday 3 AM)
# 0 3 * * 0 /usr/local/bin/nftban-auto-update.sh
```

---

## Change Log

### Version 1.1.0 (2025-10-20) - Security Hardening
- **Added:** Path traversal prevention (`_nftban_update_validate_path`)
- **Added:** Command injection prevention in SHA256 (`_nftban_update_safe_sha256`)
- **Added:** URL validation (HTTPS-only from GitHub)
- **Added:** Safe temporary directory creation (mktemp, 700 perms)
- **Added:** Input sanitization for all external data
- **Improved:** Download security (no -k/--insecure flags)
- **Improved:** Error handling and validation
- **Fixed:** Potential security vulnerabilities in file operations

### Version 1.0.0 - Initial Release
- Version detection and comparison
- Staging directory workflow
- SHA256 validation
- Atomic apply with rollback
- Email notifications
- Dry-run validation

---

## See Also

**Related Modules:**
- `nftban_maintenance_module.sh` - Maintenance and health checks
- `nftban_core.sh` - Core logging and utilities

**Related Documentation:**
- GitHub Repository: https://github.com/itcmsgr/nftban
- Release Notes: https://github.com/itcmsgr/nftban/releases
- CHANGELOG.md: Version history and breaking changes

---

## Summary

The Update Module provides secure, automated updates with comprehensive security hardening (v1.1.0), multi-stage validation (checksums, syntax, version), atomic operations with automatic rollback, pre-update backups, and optional email notifications. Essential for keeping NFTBan current with latest security fixes and features.