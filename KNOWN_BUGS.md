# NFTBan v0.10.0 - Known Bugs & Issues

> **Purpose:** Central registry of all known bugs, their impact, and remediation status.
> **Audience:** Developers and maintainers
> **Last Updated:** 2025-10-30

---

## 🔴 CRITICAL BUG: Arithmetic Expressions with `set -Eeuo pipefail`

### Bug ID: BUG-001
**Status:** 🔴 **CRITICAL** - Causes Silent Script Failure
**Discovered:** 2025-10-30
**Impact:** HIGH - Scripts exit prematurely without error messages

### Description

When using `set -Eeuo pipefail` (which is enabled in all NFTBan scripts), arithmetic expressions like `((var++))` used with conditional operators (`&&` or `||`) can cause the script to exit silently when the arithmetic result is 0 (false).

### Root Cause

In bash:
- `((expression))` returns exit code 0 if the expression evaluates to non-zero (success)
- `((expression))` returns exit code 1 if the expression evaluates to zero (failure)
- With `set -e` (exit on error), a return code of 1 causes immediate script termination
- `((var++))` post-increments, so when `var=0`, the expression evaluates to 0, returns exit code 1, and the script exits

### Example of Broken Code

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

fhs_issues=0

# ❌ BROKEN: This will exit the script when fhs_issues=0
[[ ! -d /some/missing/dir ]] && ((fhs_issues++))

# Script never reaches here if fhs_issues was 0
echo "This line never executes"
```

### Correct Fix

```bash
#!/usr/bin/env bash
set -Eeuo pipefail

fhs_issues=0

# ✅ CORRECT: Use $((var + 1)) assignment instead
[[ ! -d /some/missing/dir ]] && fhs_issues=$((fhs_issues + 1))

# Script continues normally
echo "This line executes correctly"
```

### Alternative Fixes

```bash
# Option 1: Use || true to ignore exit code
[[ ! -d /some/dir ]] && ((fhs_issues++)) || true

# Option 2: Standalone arithmetic (not chained with && or ||)
if [[ ! -d /some/dir ]]; then
    ((fhs_issues++))
fi

# Option 3: Use let (same issue as (()), not recommended)
[[ ! -d /some/dir ]] && let "fhs_issues++" || true
```

### Affected Files (77 occurrences in 11 files)

**CLI Commands (4 files):**
- `src/usr/lib/nftban/cli/cmd_feeds.sh` - 3 occurrences
- `src/usr/lib/nftban/cli/cmd_firewall.sh` - 1 occurrence
- `src/usr/lib/nftban/cli/cmd_port.sh` - 35+ occurrences ⚠️ HIGHEST RISK
- `src/usr/lib/nftban/cli/cmd_profile.sh` - 1 occurrence

**Core Modules (7 files):**
- `src/usr/lib/nftban/core/nftban_feeds.sh`
- `src/usr/lib/nftban/core/nftban_report_fhs.sh` - Contains conditional arithmetic
- `src/usr/lib/nftban/core/nftban_report_module.sh` - Contains conditional arithmetic ⚠️
- `src/usr/lib/nftban/core/nftban_report_port.sh` - Contains conditional arithmetic ⚠️
- `src/usr/lib/nftban/core/nftban_stats.sh`
- `src/usr/lib/nftban/core/nftban_system_ip.sh`
- `src/usr/lib/nftban/core/path_validator.sh`

### High Priority Fixes Required

Files with **conditional arithmetic** (most dangerous):

1. **cmd_port.sh** - 2 instances:
   ```bash
   [[ "$added_any" == "false" ]] && ((rules_skipped++))
   ```

2. **nftban_report_port.sh** - 1 instance:
   ```bash
   [[ "$bind" != "-" ]] && ((running_services++)) || true
   ```

3. **nftban_report_module.sh** - 2 instances:
   ```bash
   [[ "$status" == "ENABLED" ]] && ((enabled_modules++)) || ((disabled_modules++))
   [[ "$type" == "core" ]] && ((core_modules++)) || true
   ```

### Detection Command

```bash
# Find all conditional arithmetic expressions
grep -rE "(\&\&|\|\|).*\(\(.*\+\+\)\)" --include="*.sh" src/

# Find all arithmetic expressions (may include safe ones)
grep -r "((.*++))" --include="*.sh" src/
```

### Testing Strategy

1. **Reproduce the bug:**
   ```bash
   # This script will exit at line 4
   bash -c 'set -Eeuo pipefail; x=0; [[ true ]] && ((x++)); echo "never reached"'
   ```

2. **Verify the fix:**
   ```bash
   # This script completes successfully
   bash -c 'set -Eeuo pipefail; x=0; [[ true ]] && x=$((x+1)); echo "SUCCESS: x=$x"'
   ```

### Remediation Status

- ✅ **Fixed:** All dangerous conditional arithmetic patterns (2025-10-30)
- ✅ **Verified:** Remaining 11 occurrences are safe (standalone in if-else blocks)
- ✅ **Files fixed:**
  - `src/usr/sbin/nftban` (main CLI)
  - `src/usr/lib/nftban/cli/cmd_port.sh` (2 occurrences)
  - `src/usr/lib/nftban/core/nftban_report_port.sh` (1 occurrence)
  - `src/usr/lib/nftban/core/nftban_report_module.sh` (2 occurrences)

### Prevention Guidelines

**ALWAYS follow these rules when writing NFTBan bash scripts:**

1. ✅ **DO:** Use `var=$((var + 1))` for conditional arithmetic
2. ✅ **DO:** Use standalone `((var++))` in loops or sequential code
3. ❌ **DON'T:** Use `&& ((var++))` or `|| ((var++))`
4. ⚠️ **CAUTION:** Remember that `set -Eeuo pipefail` is enabled globally

### Related Issues

- None currently

### References

- Bash Manual: [Arithmetic Expansion](https://www.gnu.org/software/bash/manual/html_node/Arithmetic-Expansion.html)
- set -e behavior: https://mywiki.wooledge.org/BashFAQ/105

---

## 🟡 MEDIUM: Debug Output in Systemd Journal

### Bug ID: BUG-006
**Status:** ✅ **RESOLVED** (2025-10-30)
**Severity:** MEDIUM - Cosmetic issue causing service failures
**Impact:** nftban-health.service exits with code 1

### Description

The `nftban_fhs_spec.sh` file contained a debug line `declare -p NFTBAN_FHS_DIRECTORIES` on line 143 that was printing the entire associative array to stdout. This caused unwanted output in systemd journal logs and potentially interfered with strict mode error handling.

### Root Cause

Line 143 in `/usr/lib/nftban/core/nftban_fhs_spec.sh`:
```bash
declare -p NFTBAN_FHS_DIRECTORIES 2>/dev/null || true
```

This was likely added during development to debug array exports, but was never removed for production.

### Impact

- ❌ Cluttered systemd journal logs with 2000+ character debug output
- ❌ Made debugging actual issues difficult
- ❌ On some systems with strict permissions (lab2), caused the health service to exit with code 1

### Affected Files

- `src/usr/lib/nftban/core/nftban_fhs_spec.sh` - Line 143

### Fix Applied

Removed the debug line and added explanatory comment:

```bash
# Export the associative array (bash 4.3+)
# NOTE: declare -p removed - was causing debug output in systemd journals (BUG-006)
# The array is already exported via declare -g -A on line 33
```

### Detection

Check systemd journal for the debug output:
```bash
journalctl -u nftban-health.service | grep "declare -A NFTBAN_FHS_DIRECTORIES"
```

### Verification

After fix, journal output should show clean logs:
```bash
Oct 30 12:05:15 server nftban-health[67920]: Creating missing directories...
Oct 30 12:05:15 server nftban-health[67920]:   ✓ All directories already exist
Oct 30 12:05:15 server nftban-health[67920]: Fixing permissions and ownership...
Oct 30 12:05:15 server nftban-health[67920]:   ✓ All permissions already correct
Oct 30 12:05:15 server nftban-health[67920]: ✓ Fix complete!
```

### Remediation Status

- ✅ **Fixed:** Debug line removed from nftban_fhs_spec.sh (2025-10-30)
- ✅ **Tested:** All 3 lab servers (lab, lab1, lab2) verified working
- ✅ **Deployed:** Production fix applied to all lab environments

---

## 📋 Bug Registry Summary

| ID | Severity | Status | Affected Files | Fixed |
|----|----------|--------|----------------|-------|
| BUG-001 | 🟢 RESOLVED | ✅ Fixed | 5 files (conditional patterns) | 5/5 |
| BUG-006 | 🟢 RESOLVED | ✅ Fixed | 1 file (debug output) | 1/1 |

**Note:** 11 remaining `((var++))` occurrences are safe standalone statements in if-else blocks, not chained with `&&` or `||`.

---

## 📝 How to Report New Bugs

1. Add entry to this file under appropriate severity section
2. Assign unique Bug ID (BUG-XXX)
3. Include: Description, Root Cause, Affected Files, Fix, Status
4. Update Bug Registry Summary table
5. Create fix implementation plan

---

**EOF**
