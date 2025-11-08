# NFTBan Bash Coding Standards

📋 **Overview**

- **Purpose**: Mandatory coding standards for all NFTBan bash scripts
- **Status**: REQUIRED — All code must comply
- **Last Updated**: November 8, 2025
- **Version**: 0.32.19

**Core Principle**: Security is built-in from day one, not added later. Every script must follow strict safety standards to prevent bugs from hiding and ensure production reliability.

---

## 📚 Table of Contents

1. [Critical Rules (MUST FOLLOW)](#critical-rules-must-follow)
2. [Error Handling (set -Eeuo pipefail)](#error-handling-set--eeuo-pipefail)
3. [Arithmetic Expressions (Critical!)](#arithmetic-expressions-critical)
4. [Variable Naming](#variable-naming)
5. [Safe Coding Patterns](#safe-coding-patterns)
6. [Input Validation](#input-validation)
7. [Privilege Separation](#privilege-separation)
8. [Logging & Output Standards](#logging--output-standards)
9. [User Communication Standards](#user-communication-standards)
10. [Cross-Distribution Compatibility](#cross-distribution-compatibility)
11. [Package Manager Integration](#package-manager-integration)
12. [Documentation Requirements](#documentation-requirements)
13. [Enforcement](#enforcement)

---

## 🔒 Critical Rules (MUST FOLLOW)

### Rule #1: Script Headers — REQUIRED

**MANDATORY**

Every bash script MUST include this exact header structure:

```bash
#!/usr/bin/env bash
# =============================================================================
# NFTBan v0.32.19 - [Component Name]
# =============================================================================
# SPDX-License-Identifier: MPL-2.0
# Purpose: [Brief description]
#
# meta:name=[script_name]
# meta:type=[cli|core|tool|cron|exporter]
# meta:header=[Display Name]
# meta:version=0.32.19
# meta:owner="Antonios Voulvoulis <contact@nftban.com>"
# meta:homepage=https://nftban.com
#
# **Description & Purpose**
# meta:description=[Detailed description]
# meta:input=[What the script accepts]
# meta:output=[What the script produces]
#
# **Inventory & Requirements**
# meta:depends=[comma,separated,dependencies]
#
# meta:created_date=YYYY-MM-DD

set -Eeuo pipefail
```

**Why this matters:**

- ✅ Ensures proper licensing (MPL-2.0)
- ✅ Provides metadata for inventory and tracking
- ✅ Documents dependencies clearly
- ✅ Makes scripts self-documenting
- ✅ Enables automated validation

### Rule #2: Error Handling — set -Eeuo pipefail is MANDATORY

**MANDATORY**

ALL scripts MUST use:

```bash
set -Eeuo pipefail
```

**What each flag means:**

| Flag | Full Name | What It Does |
|------|-----------|--------------|
| `-E` | errtrace | ERR trap is inherited by shell functions, command substitutions, and subshells |
| `-e` | errexit | Exit immediately if any command exits with non-zero status |
| `-u` | nounset | Exit if script tries to use undefined variable |
| `-o pipefail` | pipefail option | Return exit code of rightmost command to exit with non-zero status in pipeline |

**Result**: Bugs cannot hide. Errors are caught immediately. No silent failures.

---

## 🔢 Arithmetic Expressions (CRITICAL!)

### ⚠️ CRITICAL: The `((counter++))` Trap

**COMMON BUG**

**Problem**: With `set -e`, the expression `((counter++))` returns exit code 1 when `counter=0`, causing the script to exit immediately!

#### ❌ NEVER DO THIS:

```bash
# WRONG - Will exit script when counter=0
counter=0
[[ condition ]] && ((counter++))

# WRONG - Silent failure risk
some_command && ((count++))
```

#### ✅ ALWAYS DO THIS:

```bash
# CORRECT - Safe arithmetic assignment
counter=0
[[ condition ]] && counter=$((counter + 1))

# CORRECT - Standalone increment (not chained)
if [[ condition ]]; then
    ((counter++))
fi

# CORRECT - Add || true if you must use ((...))
[[ condition ]] && ((counter++)) || true
```

**Test Case Example:**

```bash
# This FAILS - exits immediately
set -e
x=0
[[ true ]] && ((x++))
echo "never reached"  # Script exits here!

# This WORKS - completes successfully
set -e
x=0
[[ true ]] && x=$((x + 1))
echo "SUCCESS: x=$x"  # Prints: SUCCESS: x=1
```

**Reference**: See `KNOWN_BUGS.md` BUG-001 for complete details.

---

## 📝 Variable Naming

### Naming Rules

| Variable Type | Convention | Example |
|---------------|------------|---------|
| Global constants | `UPPER_CASE` with `readonly` | `readonly NFTBAN_VERSION="0.32.19"` |
| Environment variables | `UPPER_CASE` with `export` | `export NFTBAN_CONFIG_DIR="/etc/nftban"` |
| Local variables | `lower_case` or `snake_case` | `local count=0` |
| Function names | Prefix with `nftban_` | `nftban_check_health()` |
| Private functions | Prefix with `_nftban_` | `_nftban_internal_helper()` |

**Example:**

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

# Global constants (readonly)
readonly NFTBAN_VERSION="0.32.19"
readonly NFTBAN_LIB_DIR="/usr/lib/nftban"

# Environment variables (exported)
export NFTBAN_CONFIG_DIR="${NFTBAN_CONFIG_DIR:-/etc/nftban}"

# Function with local variables
nftban_process_data() {
    local input_file="$1"
    local output_dir="$2"
    local count=0

    # Process data...
    count=$((count + 1))

    echo "Processed $count items"
}

# Private helper function
_nftban_internal_validate() {
    local value="$1"
    # Internal validation logic
}
```

---

## 🛡️ Safe Coding Patterns

### Counter Increments (Safe Patterns)

```bash
# Initialize counters
count=0
errors=0
success=0

# ✅ Safe increment patterns (ALWAYS USE THESE)
count=$((count + 1))
errors=$((errors + 1))
success=$((success + 1))

# ✅ Safe conditional increment
if [[ condition ]]; then
    count=$((count + 1))
fi

# ✅ Safe decrement
count=$((count - 1))

# ✅ Safe arithmetic operations
total=$((count * 2))
average=$((total / count))
```

### Variable Quoting

**Rule**: Always quote variables to prevent word splitting and globbing.

```bash
# ❌ WRONG - Unquoted variables
if [ -f $file ]; then
    echo $message
fi

# ✅ CORRECT - Quoted variables
if [[ -f "$file" ]]; then
    echo "$message"
fi

# ✅ CORRECT - Array expansion
for item in "${array[@]}"; do
    echo "$item"
done

# ✅ CORRECT - Command substitution
result="$(some_command)"
```

### Path Validation

```bash
# ✅ CORRECT - Always validate paths before use
validate_path() {
    local path="$1"

    # Check if path exists
    if [[ ! -e "$path" ]]; then
        echo "ERROR: Path does not exist: $path" >&2
        return 1
    fi

    # Check if readable
    if [[ ! -r "$path" ]]; then
        echo "ERROR: Path not readable: $path" >&2
        return 1
    fi

    return 0
}

# Use validation before accessing
if validate_path "$config_file"; then
    source "$config_file"
fi
```

---

## ✅ Input Validation

### Sanitize ALL User Input

**SECURITY CRITICAL**

**Rule**: Never trust user input. Always validate and sanitize.

```bash
# ✅ CORRECT - Validate IP address
validate_ip() {
    local ip="$1"
    local pattern='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

    if [[ ! "$ip" =~ $pattern ]]; then
        echo "ERROR: Invalid IP address: $ip" >&2
        return 1
    fi

    # Check each octet is 0-255
    local IFS='.'
    local -a octets=($ip)
    for octet in "${octets[@]}"; do
        if ((octet > 255)); then
            echo "ERROR: Invalid IP octet: $octet" >&2
            return 1
        fi
    done

    return 0
}

# ✅ CORRECT - Validate port number
validate_port() {
    local port="$1"

    if [[ ! "$port" =~ ^[0-9]+$ ]]; then
        echo "ERROR: Port must be numeric" >&2
        return 1
    fi

    if ((port < 1 || port > 65535)); then
        echo "ERROR: Port must be 1-65535" >&2
        return 1
    fi

    return 0
}

# ✅ CORRECT - Sanitize filename
sanitize_filename() {
    local filename="$1"

    # Remove path separators
    filename="${filename//\//}"

    # Remove null bytes
    filename="${filename//\0/}"

    # Limit to alphanumeric, dash, underscore, dot
    filename="$(echo "$filename" | tr -cd '[:alnum:]._-')"

    echo "$filename"
}
```

---

## 🔐 Privilege Separation

### Run as Non-Root User

**Principle**: Code runs as `nftban` user (non-root) whenever possible.

```bash
# ✅ CORRECT - Check if running as correct user
check_user() {
    local expected_user="nftban"
    local current_user="$(id -un)"

    if [[ "$current_user" != "$expected_user" ]]; then
        echo "ERROR: Must run as $expected_user user" >&2
        echo "Current user: $current_user" >&2
        return 1
    fi

    return 0
}

# ✅ CORRECT - Use capabilities instead of root
# File ownership: root:root (immutable code)
# Runtime user: nftban (data access)
# Capabilities: CAP_NET_ADMIN (systemd-scoped)

# See nftban_security.sh for capability checking
```

**File Ownership Strategy:**

| Path | Owner | Group | Mode | Reason |
|------|-------|-------|------|--------|
| `/usr/lib/nftban/` | root | root | 0755 | Immutable code |
| `/etc/nftban/` | root | nftban | 0750 | Admin config |
| `/var/lib/nftban/` | nftban | nftban | 0755 | Runtime data |
| `/var/log/nftban/` | nftban | nftban | 0755 | Log files |

---

## 🔍 Logging & Output Standards

### Rule: NEVER Suppress Errors Silently

**CRITICAL BUG PATTERN** *(Learned from v0.32.19 feeds bug)*

Never use `&>/dev/null` or `2>/dev/null` to hide errors from background processes.

#### ❌ WRONG - Silent failures

```bash
# WRONG - User never knows if download failed
(download_feed "$feed" &>/dev/null) &
disown
```

#### ✅ CORRECT - Logged output

```bash
# CORRECT - Errors logged, user can debug
download_feed "$feed" >> /var/log/nftban/feeds.log 2>&1 &
disown
```

### Logging Decision Tree

1. **User-initiated command**: Show output directly
2. **Background task**: Log to `/var/log/nftban/*.log`
3. **Cron/timer**: Log with severity level
4. **Error condition**: ALWAYS log to stderr AND file

### Log File Standards

```bash
# Standard log format
log_message() {
    local level="$1"
    local message="$2"
    local log_file="/var/log/nftban/$(basename "$0" .sh).log"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message" | tee -a "$log_file"
}

# Usage
log_message "INFO" "Feed download started"
log_message "ERROR" "Feed download failed: timeout"
```

**Log File Standards:**
- All logs go to `/var/log/nftban/`
- Use descriptive filenames: `feeds.log`, `firewall.log`, `health.log`
- Include timestamps: `[$(date '+%Y-%m-%d %H:%M:%S')]`
- Log levels: `[DEBUG]`, `[INFO]`, `[WARNING]`, `[ERROR]`

---

## 💬 User Communication Standards

### Rule: Messages Must Match Reality

**RECENT BUG** *(v0.32.19)*: User saw "Downloading in background..." but download was failing silently.

#### ❌ WRONG - Misleading messages

```bash
echo "✓ Feed enabled"
echo "⏳ Downloading in background..."
# MISLEADING - If download fails silently, user thinks it worked!
(download_feed &>/dev/null) &
```

#### ✅ CORRECT - Honest communication

```bash
echo "✓ Feed enabled"
echo ""
echo "📥 Downloading feed in background..."
echo "   Progress: tail -f /var/log/nftban/feeds.log"
echo "   Status:   nftban feeds status"
echo ""
download_feed >> /var/log/nftban/feeds.log 2>&1 &
```

### Communication Principles

1. **Be Specific**: Don't say "updating" if you mean "downloading"
2. **Show Next Steps**: Tell user how to check progress
3. **Admit Failures**: If something fails, say so immediately
4. **No False Promises**: Don't say "done" if it's still processing
5. **Provide Context**: Tell user what to do if something goes wrong

**Examples:**

```bash
# ✅ CORRECT - Clear, actionable messages
echo "✓ Configuration updated"
echo "  Next step: nftban firewall reload"

# ✅ CORRECT - Honest about failures
echo "❌ Download failed: timeout after 30s"
echo "  Retry with: nftban feeds update FEED_NAME"

# ✅ CORRECT - Progress indicators
echo "⏳ Processing 1000 IPs..."
echo "   This may take 2-3 minutes"
echo "   Progress: tail -f /var/log/nftban/feeds.log"
```

---

## 🐧 Cross-Distribution Compatibility

### Rule: Never Assume Distribution-Specific Paths or Names

**RECENT BUG** *(v0.32.18)*: Assumed `polkitd.service` on Ubuntu, but all distros use `polkit.service`.

#### ❌ WRONG - Assumes service name

```bash
# WRONG - polkitd.service doesn't exist on Ubuntu!
systemctl is-active polkitd
```

#### ✅ CORRECT - Researched and verified

```bash
# CORRECT - polkit.service is universal across all distros
systemctl is-active polkit
```

### Distribution Testing Checklist

Before assuming anything, verify across:

- ☐ **Debian**: 11, 12
- ☐ **Ubuntu**: 20.04, 22.04, 24.04
- ☐ **RHEL/Rocky/AlmaLinux**: 8, 9
- ☐ **Fedora**: Latest stable
- ☐ **CentOS Stream**: 9, 10

### Common Pitfalls

| Assumption | Reality |
|------------|---------|
| Service is `polkitd` | Actually `polkit.service` on ALL distros |
| Binary at `/usr/bin/` | Could be `/usr/sbin/` or `/usr/libexec/` |
| Package named `geoip` | Doesn't exist on RHEL 9+ (removed) |
| Config in `/etc/sysconfig/` | Debian uses `/etc/default/` |
| Python is `python` | Could be `python3` only |
| Init system is systemd | Could be SysV, OpenRC (rare but possible) |

### Detection Pattern

```bash
# ✅ CORRECT - Detect with fallbacks
detect_binary() {
    local binary_name="$1"
    local search_paths=(/usr/bin /usr/sbin /usr/local/bin /usr/libexec)

    for path in "${search_paths[@]}"; do
        if [[ -x "$path/$binary_name" ]]; then
            echo "$path/$binary_name"
            return 0
        fi
    done

    return 1
}

# ✅ CORRECT - Detect package manager
detect_package_manager() {
    if command -v dpkg >/dev/null 2>&1; then
        echo "deb"
    elif command -v rpm >/dev/null 2>&1; then
        echo "rpm"
    else
        echo "unknown"
    fi
}
```

### Distribution-Specific Paths

```bash
# ✅ CORRECT - Use variables for paths
case "$(detect_package_manager)" in
    deb)
        SYSTEMD_UNIT_DIR="/lib/systemd/system"
        CONFIG_DIR="/etc/default"
        ;;
    rpm)
        SYSTEMD_UNIT_DIR="/usr/lib/systemd/system"
        CONFIG_DIR="/etc/sysconfig"
        ;;
esac
```

---

## 📦 Package Manager Integration

### Rule: Protect User Configuration

**RECENT BUG** *(v0.32.16)*: Missing `%config(noreplace)` caused configs to be deleted on upgrade.

### RPM Spec Files

```spec
# ✅ CORRECT - Protects user configs
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/feeds.conf
%config(noreplace) %attr(0640,root,nftban) /etc/nftban/conf.d/geoip.conf
%config(noreplace) %attr(0640,root,nftban) /etc/fail2ban/jail.d/nftban-sshd.conf

# ✅ CORRECT - Date format escaping in RPM (double %%)
BACKUP_DIR="/var/lib/nftban/backup-$(date +%%Y%%m%%d-%%H%%M%%S)"
```

### DEB Packages

Create `packaging/deb/conffiles`:

```
# ✅ CORRECT - conffiles list
/etc/nftban/nftban.conf
/etc/nftban/conf.d/feeds.conf
/etc/nftban/conf.d/geoip.conf
/etc/fail2ban/jail.d/nftban-sshd.conf
/etc/fail2ban/action.d/nftban.conf
```

### Configuration File Rules

1. **ALL user-editable files** must be marked as config
2. **Use `%config(noreplace)`** (RPM) or **conffiles** (DEB)
3. **Backup on uninstall**: Offer to save configs
4. **Restore on reinstall**: Detect and offer to restore backups
5. **Interactive prompts**: Ask user what to do with configs

### Backup/Restore Pattern

```bash
# ✅ CORRECT - Backup configuration on uninstall
backup_config() {
    local backup_dir="/var/lib/nftban/config-backup-$(date +%Y%m%d-%H%M%S)"

    mkdir -p "$backup_dir"

    # Backup configs
    cp -a /etc/nftban/conf.d "$backup_dir/" 2>/dev/null || true

    # Save metadata
    cat > "$backup_dir/metadata.txt" <<EOF
Backup Date: $(date)
NFTBan Version: $(cat /var/lib/nftban/config/nftban.version)
Hostname: $(hostname)
Reason: Uninstall
EOF

    echo "✓ Configuration backed up to: $backup_dir"
}

# ✅ CORRECT - Restore on reinstall
restore_config() {
    local latest_backup="$(ls -t /var/lib/nftban/config-backup-* 2>/dev/null | head -1)"

    if [[ -n "$latest_backup" && -d "$latest_backup" ]]; then
        echo "Found previous configuration backup"
        echo "Location: $latest_backup"

        read -p "Restore previous settings? (yes/no) [yes]: " RESTORE
        RESTORE="${RESTORE:-yes}"

        if [[ "$RESTORE" == "yes" ]]; then
            cp -a "$latest_backup/conf.d"/* /etc/nftban/conf.d/
            echo "✓ Configuration restored"
        fi
    fi
}
```

---

## 📖 Documentation Requirements

### Function Documentation

```bash
# ✅ CORRECT - Document all functions
# Function: nftban_process_feed
# Purpose: Downloads and processes threat intelligence feed
# Args:
#   $1 - Feed name (string)
#   $2 - Feed URL (string)
#   $3 - Output file (path)
# Returns:
#   0 - Success
#   1 - Download failed
#   2 - Validation failed
# Example:
#   nftban_process_feed "spamhaus" "https://..." "/tmp/feed.txt"
nftban_process_feed() {
    local feed_name="$1"
    local feed_url="$2"
    local output_file="$3"

    # Validate inputs
    [[ -z "$feed_name" ]] && return 1
    [[ -z "$feed_url" ]] && return 1
    [[ -z "$output_file" ]] && return 1

    # Implementation...
}
```

### Inline Comments

**Rule**: Comment WHY, not WHAT. Code should be self-explanatory for WHAT.

```bash
# ❌ WRONG - Comments state the obvious
# Set count to zero
count=0
# Increment count
count=$((count + 1))

# ✅ CORRECT - Comments explain WHY
# Start from zero to track new bans only (exclude existing)
count=0

# Increment for each successful ban (failures don't count)
count=$((count + 1))
```

### Bug References

```bash
# ✅ CORRECT - Reference known bugs when fixing
# FIX for BUG-001: Avoid ((counter++)) with set -e
# Use safe arithmetic assignment instead
counter=$((counter + 1))

# WORKAROUND for polkit service detection (v0.32.18 bug)
# All distros use polkit.service, not polkitd.service
systemctl is-active polkit
```

---

## ⚖️ Enforcement

All code MUST comply with these standards before merging.

### Automated Checks:

- ✅ ShellCheck linting
- ✅ Header validation (grep for metadata)
- ✅ `set -Eeuo pipefail` verification
- ✅ Syntax validation (`bash -n`)
- ✅ No `&>/dev/null` in background tasks
- ✅ Config files marked in package specs

### Manual Review:

- ✅ Proper error handling
- ✅ Input validation present
- ✅ No `((counter++))` in conditionals
- ✅ Variables properly quoted
- ✅ Functions documented
- ✅ User messages match reality
- ✅ Cross-distro compatibility verified
- ✅ Logging to files, not /dev/null

### Consequences of Non-Compliance:

- ❌ Code will NOT be merged
- ❌ Pull request will be rejected
- ❌ Must fix before resubmission

---

## 📋 Quick Reference Checklist

Before submitting code, verify:

**Required:**
- ☐ Includes proper header with metadata
- ☐ Has `set -Eeuo pipefail` on line after header
- ☐ No `((counter++))` in conditionals or with `&&`
- ☐ All variables quoted: `"$variable"`
- ☐ All user input validated
- ☐ All paths validated before use

**Functions:**
- ☐ Functions use `nftban_` prefix
- ☐ Functions documented with purpose, args, returns
- ☐ Return codes used correctly (0=success, 1+=error)

**Output & Logging:**
- ☐ Error messages go to stderr: `>&2`
- ☐ Background tasks log to files (not `&>/dev/null`)
- ☐ User messages match reality
- ☐ Progress indicators show how to check status

**Security & Compatibility:**
- ☐ No hardcoded paths (use variables/FHS spec)
- ☐ Cross-distro compatibility verified
- ☐ Privilege separation enforced
- ☐ No silent failures

**Testing:**
- ☐ Passes ShellCheck with no warnings
- ☐ Passes `bash -n` syntax check
- ☐ Tested on Debian/Ubuntu and RHEL/Rocky
- ☐ Package manager configs marked correctly

**Documentation:**
- ☐ New `.md` files added to package managers
- ☐ Index/README updated under `/docs`
- ☐ Installer/uninstaller reference new docs

---

## 🔄 Version Management

### Rule: Single Source of Truth for Version Numbers

**Problem**: Version scattered across 8+ files - easy to miss updates

**Solution**: Maintain version in these files ONLY:

```bash
# Core version files (MUST update for every release)
.version                                    # Machine-readable
VERSION                                     # Human-readable
README.md                                   # Badge display
src/usr/sbin/nftban                        # CLI --version
packaging/rpm/nftban.spec                  # RPM package
packaging/deb/postinst                     # DEB post-install
packaging/deb/prerm                        # DEB pre-remove
src/usr/share/nftban/docs/QUICK-START.md  # Documentation
```

### Version Update Script Pattern

```bash
# ✅ CORRECT - Update all version references
update_version() {
    local old_version="$1"
    local new_version="$2"

    local files=(
        ".version"
        "VERSION"
        "README.md"
        "src/usr/sbin/nftban"
        "packaging/rpm/nftban.spec"
        "packaging/deb/postinst"
        "packaging/deb/prerm"
        "src/usr/share/nftban/docs/QUICK-START.md"
    )

    for file in "${files[@]}"; do
        sed -i "s/${old_version}/${new_version}/g" "$file"
        echo "✓ Updated: $file"
    done
}

# Usage
update_version "0.32.18" "0.32.19"
```

### Semantic Versioning

NFTBan uses **Semantic Versioning 2.0.0**:

```
MAJOR.MINOR.PATCH

Examples:
- 0.32.19 → 0.32.20  (patch: bug fix)
- 0.32.20 → 0.33.0   (minor: new feature, backwards compatible)
- 0.33.0 → 1.0.0     (major: breaking change)
```

---

## 🔀 Git Workflow Standards

### Rule: Protect Main Branch

**CRITICAL**: Main branch has protection rules:
- ❌ No force-push allowed
- ❌ No amend + force-push
- ✅ Use rebase for conflicts
- ✅ Create new commits instead

#### ❌ WRONG - Force push

```bash
# WRONG - Will be rejected by GitHub
git commit --amend
git push --force
# ERROR: Cannot force-push to this branch
```

#### ✅ CORRECT - New commit

```bash
# CORRECT - Create new commit
git add .
git commit -m "fix: Correct implementation"
git push
```

### Commit Message Standards

```bash
# Format: <type>: <description>
#
# <optional body>
#
# 🤖 Generated with Claude Code (https://claude.com/claude-code)
#
# Co-Authored-By: Claude <noreply@anthropic.com>

# Types:
feat:     New feature
fix:      Bug fix
docs:     Documentation only
style:    Formatting, missing semi colons, etc
refactor: Code change that neither fixes bug nor adds feature
test:     Adding tests
chore:    Updating build tasks, package manager configs, etc
```

### Example Commit

```bash
git commit -m "$(cat <<'EOF'
fix: Feeds download automatically in background with logged output

PROBLEM:
User runs: nftban feeds enable FEED
Says: "Downloading in background..."
Reality: Output suppressed (&>/dev/null) - silent failures

FIX:
Changed: (download &>/dev/null) &
To:      download >> /var/log/nftban/feeds.log 2>&1 &

RESULT:
- Downloads run in background (no hang)
- Output logged (no silent failures)
- User told how to monitor: tail -f /var/log/nftban/feeds.log

🤖 Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>
EOF
)"
```

---

## 🏗️ Build & Release Standards

### Rule: Monitor Builds to Completion

**Lesson**: Always verify build succeeds before releasing

```bash
# ✅ CORRECT - Monitor build progress
monitor_build() {
    local run_id="$1"
    local max_wait=600  # 10 minutes

    for ((i=0; i<max_wait; i+=30)); do
        status=$(gh run view "$run_id" --json status --jq '.status')

        if [[ "$status" == "completed" ]]; then
            conclusion=$(gh run view "$run_id" --json conclusion --jq '.conclusion')

            if [[ "$conclusion" == "success" ]]; then
                echo "✅ BUILD SUCCESS"
                return 0
            else
                echo "❌ BUILD FAILED: $conclusion"
                return 1
            fi
        fi

        echo "Build in progress... ($i seconds elapsed)"
        sleep 30
    done

    echo "⏱️  BUILD TIMEOUT"
    return 1
}
```

### GitHub Actions Workflow Standards

```yaml
# ✅ CORRECT - Token usage
- name: Push changes
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
  run: |
    git config user.name "github-actions[bot]"
    git config user.email "github-actions[bot]@users.noreply.github.com"
    git push

# ✅ CORRECT - Conditional execution
- name: Upload artifacts
  if: success()  # Only if previous steps succeeded
  uses: actions/upload-artifact@v4

# ✅ CORRECT - Fail-fast strategy
strategy:
  fail-fast: false  # Continue other builds if one fails
  matrix:
    os: [ubuntu-latest, debian-12]
```

---

## 🧪 Testing & Quality Assurance

### Rule: Test on ALL Supported Distributions

**NFTBan Test Lab:**

| Lab | OS | Version | Purpose |
|-----|-----|---------|---------|
| lab1 | Ubuntu | 24.04 LTS | DEB testing |
| lab2 | Debian | 12 (Bookworm) | DEB testing |
| lab3 | Fedora | Latest | RPM testing |
| lab4 | Rocky Linux | 9 | RHEL clone testing |
| lab5 | AlmaLinux | 9 | RHEL clone testing |

### Testing Checklist

```bash
# ✅ CORRECT - Full testing workflow
test_release() {
    local version="$1"

    echo "Testing v$version across all labs..."

    # Test DEB on Ubuntu & Debian
    ssh lab1 "wget https://github.com/.../nftban-amd64.deb && \
              sudo dpkg -i nftban-amd64.deb && \
              nftban health check"

    ssh lab2 "wget https://github.com/.../nftban-amd64.deb && \
              sudo dpkg -i nftban-amd64.deb && \
              nftban health check"

    # Test RPM on Fedora, Rocky, AlmaLinux
    ssh lab3 "wget https://github.com/.../nftban-x86_64.rpm && \
              sudo dnf install -y nftban-x86_64.rpm && \
              nftban health check"

    ssh lab4 "wget https://github.com/.../nftban-x86_64.rpm && \
              sudo dnf install -y nftban-x86_64.rpm && \
              nftban health check"

    ssh lab5 "wget https://github.com/.../nftban-x86_64.rpm && \
              sudo dnf install -y nftban-x86_64.rpm && \
              nftban health check"

    echo "✅ All labs tested successfully"
}
```

### Health Check Validation

```bash
# ✅ CORRECT - Automated health validation
validate_health() {
    local output
    output=$(nftban health check 2>&1)

    # Check for critical errors
    if echo "$output" | grep -q "❌.*Binaries"; then
        echo "FAIL: Binary check failed"
        return 1
    fi

    if echo "$output" | grep -q "❌.*Polkit"; then
        echo "FAIL: Polkit check failed"
        return 1
    fi

    if echo "$output" | grep -q "❌.*Databases"; then
        echo "FAIL: Database check failed"
        return 1
    fi

    echo "PASS: Health check OK"
    return 0
}
```

---

## 📊 Background Process Management

### Rule: Proper Disown Pattern

**Problem**: Zombies processes or hung scripts if background tasks not properly disowned

#### ✅ CORRECT - Background task pattern

```bash
# Pattern 1: Log output, disown process
download_feed "$feed" >> /var/log/nftban/feeds.log 2>&1 &
disown

# Pattern 2: Capture PID for monitoring
download_feed "$feed" >> /var/log/nftban/feeds.log 2>&1 &
DOWNLOAD_PID=$!
disown

# Pattern 3: Wait for completion with timeout
timeout 300 download_feed "$feed" >> /var/log/nftban/feeds.log 2>&1 &
wait $! || echo "Download timed out or failed"
```

#### ❌ WRONG - Missing disown

```bash
# WRONG - Parent process must wait for child
download_feed "$feed" &
# If parent exits, child becomes orphan or zombie
```

### Background Task Monitoring

```bash
# ✅ CORRECT - Monitor background tasks
monitor_background_task() {
    local log_file="$1"
    local task_name="$2"
    local timeout=300

    echo "Task '$task_name' running in background"
    echo "Monitor: tail -f $log_file"

    # Optional: Wait with timeout
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if tail -1 "$log_file" | grep -q "COMPLETE\|SUCCESS\|DONE"; then
            echo "✓ Task completed successfully"
            return 0
        fi

        if tail -1 "$log_file" | grep -q "ERROR\|FAILED"; then
            echo "❌ Task failed - check $log_file"
            return 1
        fi

        sleep 5
        elapsed=$((elapsed + 5))
    done

    echo "⏱️ Task still running after ${timeout}s"
    return 0
}
```

---

## 🐛 Lessons Learned (Real Bugs)

### v0.32.16: Config Files Lost on Upgrade
**Bug**: Missing `%config(noreplace)` directive
**Impact**: All user configs deleted on package upgrade
**Fix**: Added to 22 config files in RPM spec and DEB conffiles
**Lesson**: ALL user-editable files MUST be marked as config

### v0.32.18: Polkit Service Detection Failed
**Bug**: Checked for `polkitd.service` on Debian/Ubuntu
**Impact**: Health check failed - service doesn't exist
**Fix**: Use `polkit.service` (universal across all distros)
**Lesson**: Research service names across ALL distributions

### v0.32.19: Silent Feed Download Failures
**Bug**: Used `&>/dev/null` to suppress background download output
**Impact**: Downloads failed silently - users never knew
**Fix**: Log to `/var/log/nftban/feeds.log` instead
**Lesson**: NEVER suppress errors - always log them

---

## 📚 Additional Resources

- [KNOWN_BUGS.md](KNOWN_BUGS.md) - Detailed bug database
- [FHS.md](FHS.md) - Filesystem Hierarchy Standard compliance
- [CONTRIBUTING.md](../CONTRIBUTING.md) - Contribution guidelines
- [ShellCheck Wiki](https://www.shellcheck.net/wiki/) - Shell scripting best practices

---

**Version History:**
- v0.32.19 (2025-11-08): Added logging, UX, cross-distro, package manager standards
- v0.10.0 (2025-11-04): Initial coding standards

**Maintained by**: NFTBan Development Team
**License**: MPL-2.0
