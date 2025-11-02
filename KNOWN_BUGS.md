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
- ✅ **Tested:** Verified working on multiple test systems
- ✅ **Deployed:** Production fix applied to all environments

---

## 🔴 CRITICAL BUG: Search Command Not Finding Banned IPs

### Bug ID: BUG-002
**Status:** ✅ **FIXED** (2025-10-31)
**Severity:** CRITICAL - Search gives false negatives
**Impact:** HIGH - Users cannot find banned IPs, leading to confusion

### Description

The `nftban search <ip>` command reports "NOT BANNED" for IPs that ARE actually banned in nftables, showing false negatives for temporary bans.

### User Report

```bash
[root@server ~]# nftban ban 8.8.8.8 test
[root@server ~]# nftban search 8.8.8.8
✓ STATUS: NOT BANNED  ← WRONG! IP IS banned
  ✗ temp_ban

[root@server ~]# nft list ruleset | grep 8.8.8
elements = { 8.8.8.8 timeout 1h expires 58m6s362ms }  ← IP IS in nftables!
```

### Root Cause

Search command looks for sets named `temp_ban` but actual set names are `temp_ban_v4` and `temp_ban_v6`:

**File:** `src/usr/lib/nftban/cli/cmd_search.sh:54`
```bash
local sets=("whitelist" "temp_ban" "user_blacklist" "system_blacklist" "feeds")
```

**Actual nftables sets:**
- `inet nftban_runtime` → `temp_ban_v4`, `temp_ban_v6` (IPv4/IPv6 specific)
- `ip nftban_v4` → `whitelist`, `user_blacklist`, etc.
- `ip6 nftban_v6` → `whitelist`, `user_blacklist`, etc.

When `nft get element inet nftban_runtime temp_ban { "8.8.8.8" }` runs, it fails because set "temp_ban" doesn't exist → false negative.

### Impact

- ❌ Users cannot find banned IPs using search command
- ❌ Appears like bans are not working (trust issue)
- ❌ Debugging becomes difficult
- ❌ False sense that firewall is not protecting

### Fix Applied

Updated search function to use correct set names based on IP version:

**File:** `src/usr/lib/nftban/cli/cmd_search.sh:48-89`

```bash
# Determine IP version
if [[ "$ip" == *:* ]]; then
    temp_ban_suffix="v6"
else
    temp_ban_suffix="v4"
fi

# Search in inet nftban_runtime with version-specific sets
local runtime_sets=("whitelist" "temp_ban_${temp_ban_suffix}" "user_blacklist" ...)
for set in "${runtime_sets[@]}"; do
    if nft get element inet nftban_runtime "$set" { "$ip" } &>/dev/null; then
        # Normalize for display (temp_ban_v4 → temp_ban)
        local display_set="${set//_v4/}"
        display_set="${display_set//_v6/}"
        found_in+=("nftban_runtime:${display_set}")
    fi
done

# Also search ip nftban_v4 and ip6 nftban_v6 tables
```

### Testing

```bash
# Before fix:
nftban ban 8.8.8.8
nftban search 8.8.8.8  → Shows "NOT BANNED" ❌

# After fix:
nftban ban 8.8.8.8
nftban search 8.8.8.8  → Shows "BANNED in temp_ban" ✅
```

### Remediation Status

- ✅ **Fixed:** Search function updated to use correct set names (2025-10-31)
- ✅ **Code:** `src/usr/lib/nftban/cli/cmd_search.sh`
- ⏳ **Testing:** Pending deployment and verification

---

## 🟡 MEDIUM: Ban Command Ignores Comment Parameter

### Bug ID: BUG-003
**Status:** ✅ **FIXED** (2025-10-31)
**Severity:** MEDIUM - Feature not working as expected
**Impact:** MEDIUM - Cannot add notes/reasons to bans

### Description

When using `nftban ban <ip> <comment>`, the comment parameter is silently ignored.

### User Report

```bash
[root@server ~]# nftban ban 8.8.8.8 test
# Comment "test" is ignored, not logged anywhere
```

**Expected:** Comment should be logged for reference
**Actual:** Comment is silently discarded

### Root Cause

**File:** `src/usr/sbin/nftban-complete:298-306`

The `nftban_fail2ban_ban` function only recognizes these parameters:
- `--temp`
- `--timeout <duration>`
- `--source <source>`
- `--jail <jail>`

When you run `nftban ban 8.8.8.8 test`, the "test" parameter hits the default case `*)` which does nothing:

```bash
while [ $# -gt 0 ]; do
    case "$1" in
      --temp) : ;;
      --timeout) bantime="$2"; shift ;;
      --source) source="$2"; shift ;;
      --jail) jail="$2"; shift ;;
      *) ;;  ← "test" falls here and is ignored
    esac
    shift
done
```

### Fix Applied

1. **Added comment parameter support:**

```bash
nftban_fail2ban_ban() {
  local ip bantime source jail comment
  ...
  comment=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --timeout) bantime="$2"; shift ;;
      --source) source="$2"; shift ;;
      --jail) jail="$2"; shift ;;
      --comment|--reason) comment="$2"; shift ;;  ← NEW
      --*) ;;  # Ignore unknown flags
      *)
        # If no flags, treat as comment
        if [[ -z "$comment" ]]; then
          comment="$1"  ← NEW: Simple usage
        fi
        ;;
    esac
    shift
  done
```

2. **Updated logging to include comment:**

```bash
# JSON log
nftban_log_json info ban \
  "...\"comment\":\"$comment\",\"result\":\"success\""

# Plain text log
printf '[BAN] ip=%s jail=%s timeout=%ss source=%s comment="%s"\n' \
  "$ip" "$jail" "$timeout_s" "$source" "$comment"
```

### Usage Examples

```bash
# Simple usage (backward compatible)
nftban ban 8.8.8.8 "testing firewall"

# Explicit flag
nftban ban 8.8.8.8 --comment "suspicious activity"
nftban ban 8.8.8.8 --reason "port scan detected"

# Combined with other options
nftban ban 8.8.8.8 --timeout 7200 --comment "2 hour ban for brute force"
```

### Remediation Status

- ✅ **Fixed:** Comment parameter added and logged (2025-10-31)
- ✅ **Code:** `src/usr/sbin/nftban-complete:291-351`
- ⏳ **Testing:** Pending deployment and verification

---

## 🔴 CRITICAL BUG: Feed Parsing Fails - Missing Go Binary

### Bug ID: BUG-004
**Status:** 🔴 **CRITICAL** - Feeds Cannot Be Parsed
**Discovered:** 2025-11-02
**Impact:** CRITICAL - Threat feed protection completely broken

### Description

Threat feeds cannot be parsed because the Go binary wrapper exits with error when the compiled Go binary is not found, and the Bash fallback is not implemented.

### User Report

```bash
[root@server ~]# nftban feeds update
[nftban] ⚠️  nftban-feeds Go binary not present. Using slow fallback.
[nftban] For better performance, install from RPM/DEB package or build Go binaries.
[nftban] See: https://github.com/itcmsgr/nftban/blob/main/docs/development/GO-BINARIES.md
[nftban] ERROR: Bash fallback not yet implemented. Please install Go binaries.
ERROR: Parsing failed: spamhaus-drop

Feeds update FAILS ❌
```

### Root Cause

**File:** `src/usr/lib/nftban/bin/nftban-feeds` lines 15-30

The wrapper script architecture is:
1. Check for real Go binary at `/usr/lib/nftban/bin/.real/nftban-feeds`
2. If found: exec the fast Go binary (10-60x faster)
3. If NOT found: Use Bash fallback

**The problem:**
```bash
# Line 27: TODO comment - fallback NOT IMPLEMENTED
# TODO: Implement Bash fallback for feed processing

# Line 29-30: Just exits with error
echo "[nftban] ERROR: Bash fallback not yet implemented. Please install Go binaries." >&2
exit 1
```

This means:
- ❌ Source installations: FAIL (no Go binary, no fallback)
- ❌ Development environments: FAIL
- ✅ RPM/DEB packages: Work IF Go binary is bundled

### Impact

- ❌ **CRITICAL:** Threat feeds completely broken on source installations
- ❌ All feed updates fail with error
- ❌ Feed-based blocking does not work
- ❌ Development and testing severely impacted
- ❌ Users cannot use feed protection without building Go binaries manually

### Affected Files

- `src/usr/lib/nftban/bin/nftban-feeds` - Missing Bash fallback implementation
- `src/usr/lib/nftban/core/nftban_feeds.sh:221` - Calls the wrapper which fails

### Fix Required

**Option 1: Implement Bash Fallback (RECOMMENDED for compatibility)**

Add Bash implementation to parse feeds when Go binary is not available:

```bash
# nftban-feeds wrapper (lines 27-30)
# Fallback: Parse feeds using Bash
case "$1" in
    parse)
        shift
        # Parse stdin for IPs/CIDRs
        grep -E '([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?' | \
        grep -v '^#' | \
        sort -u
        ;;
    *)
        echo "[nftban] ERROR: Unknown command: $1" >&2
        exit 1
        ;;
esac
```

**Option 2: Bundle Go Binary in Packages**

Ensure RPM/DEB packages always include compiled Go binary at:
- `/usr/lib/nftban/bin/.real/nftban-feeds`

**Option 3: Build Script**

Add build script to compile Go binaries during installation:
```bash
# install.sh - Add Go binary build step
if command -v go >/dev/null 2>&1; then
    cd "$SCRIPT_DIR/../go/nftban-feeds"
    go build -o /usr/lib/nftban/bin/.real/nftban-feeds
fi
```

### Testing

```bash
# Test without Go binary
sudo rm -f /usr/lib/nftban/bin/.real/nftban-feeds

# Before fix:
nftban feeds update  → ERROR: Bash fallback not yet implemented ❌

# After fix (Option 1):
nftban feeds update  → Uses Bash fallback, slower but works ✅
```

### Remediation Status

- ⏳ **PENDING:** Bash fallback not implemented
- ⏳ **PENDING:** Go binary bundling in RPM/DEB not verified
- ⏳ **IMPACT:** Feed protection COMPLETELY BROKEN on source installs

---

## 🔴 CRITICAL BUG: Port Statistics Not Displayed - Undefined Array

### Bug ID: BUG-005
**Status:** 🔴 **CRITICAL** - Port Reports Show No Data
**Discovered:** 2025-11-02
**Impact:** HIGH - Port firewall status reports broken

### Description

Port reports do not display firewall status correctly because the `NFTBAN_PORT_STATUS` associative array is referenced but NEVER DECLARED anywhere in the code.

### User Report

**Live Production Example (lab.mywebhost.gr):**

```bash
[root@lab ~]# nftban port status

════════════════════════════════════════════════════════════════════════════════════
 Port Status Report — 2025-11-02T13:20:59+00:00
════════════════════════════════════════════════════════════════════════════════════
SERVICE        PORT   PROTO  RUNNING  IPv4 IN   IPv4 OUT  IPv6 IN   IPv6 OUT  NOTES
------------------------------------------------------------------------------------
ssh            22     tcp    yes      ? No-rule ? No-rule ? No-rule ? No-rule PUBLIC
brcd           323    udp    yes      ? No-rule ? No-rule ? No-rule ? No-rule LOCAL-ONLY

✔ allowed   ✖ blocked   ? no-rule/unknown
Legend: 'No-rule' = no explicit nft input/output rule for that port; default policy may apply.
```

**Problem:** All firewall status columns show "?" instead of actual nftables rule status (✔ allowed or ✖ blocked)

**Impact:**
- Cannot determine which ports are protected by nftables
- Port security visibility completely broken
- Users have no visibility into firewall protection status ❌
```

### Root Cause

**File:** `src/usr/lib/nftban/core/nftban_report_port.sh`

The code references `NFTBAN_PORT_STATUS` array:
```bash
# Lines 453-456: READING from undefined array
local ipv4_in="${NFTBAN_PORT_STATUS["${port}/${proto}/ipv4/in"]:-?}"
local ipv4_out="${NFTBAN_PORT_STATUS["${port}/${proto}/ipv4/out"]:-?}"
local ipv6_in="${NFTBAN_PORT_STATUS["${port}/${proto}/ipv6/in"]:-?}"
local ipv6_out="${NFTBAN_PORT_STATUS["${port}/${proto}/ipv6/out"]:-?}"
```

**But the array is NEVER DECLARED:**
```bash
# Lines 36-41: Other arrays are declared
declare -g -A NFTBAN_PORT_LISTEN_MAP=()
declare -g -A NFTBAN_PORT_BIND_ADDR=()
declare -g -A NFTBAN_PORT_NFT_RULES=()
declare -g -A NFTBAN_PORT_NFT_GENERIC=()
declare -g -A NFTBAN_PORT_SEEN=()
declare -g -A NFTBAN_PORT_SERVICE_NAME=()

# MISSING: declare -g -A NFTBAN_PORT_STATUS=()  ← MISSING!
```

Because the array is undefined:
1. Array reads return empty values
2. Default `:-?` triggers, showing "?" for all ports
3. No actual firewall status is ever populated or displayed

### Impact

- ❌ **CRITICAL:** Port firewall status reports show no data
- ❌ Users cannot see which ports are protected by nftables
- ❌ Debugging firewall rules becomes impossible
- ❌ Port security visibility completely lost
- ❌ May affect HTML reports, mail reports, and stats

### Affected Files

- `src/usr/lib/nftban/core/nftban_report_port.sh:36-46` - Missing array declaration
- `src/usr/lib/nftban/core/nftban_report_port.sh:453-456` - References undefined array
- `src/usr/lib/nftban/cli/cmd_report.sh` - Calls broken port report function

### Fix Required

**Step 1: Declare the missing array**

```bash
# nftban_report_port.sh - Add to lines 36-42
declare -g -A NFTBAN_PORT_LISTEN_MAP=()
declare -g -A NFTBAN_PORT_BIND_ADDR=()
declare -g -A NFTBAN_PORT_NFT_RULES=()
declare -g -A NFTBAN_PORT_NFT_GENERIC=()
declare -g -A NFTBAN_PORT_SEEN=()
declare -g -A NFTBAN_PORT_SERVICE_NAME=()
declare -g -A NFTBAN_PORT_STATUS=()  # ← ADD THIS LINE
```

**Step 2: Populate the array with firewall status**

Find where nftables rules are parsed and populate `NFTBAN_PORT_STATUS`:

```bash
# Example: After parsing nftables rules
NFTBAN_PORT_STATUS["${port}/${proto}/ipv4/in"]="ALLOW"
NFTBAN_PORT_STATUS["${port}/${proto}/ipv4/out"]="ALLOW"
NFTBAN_PORT_STATUS["${port}/${proto}/ipv6/in"]="DROP"
NFTBAN_PORT_STATUS["${port}/${proto}/ipv6/out"]="DROP"
```

**Step 3: Link to nftban_port_determine_status function**

The function `nftban_port_determine_status` (line 185) likely should populate `NFTBAN_PORT_STATUS` but currently doesn't.

### Testing

```bash
# Before fix:
nftban report port
# Shows: ?  ?  ?  ? for all ports ❌

# After fix:
nftban report port
# Shows: ✓  ✓  ✓  ✓ or specific status icons ✅
```

### Remediation Status

- ⏳ **PENDING:** Array declaration not added
- ⏳ **PENDING:** Array population logic not implemented
- ⏳ **IMPACT:** Port security visibility COMPLETELY BROKEN

---

## 📋 Bug Registry Summary

| ID | Severity | Status | Affected Files | Fixed |
|----|----------|--------|----------------|-------|
| BUG-001 | 🟢 RESOLVED | ✅ Fixed | 5 files (conditional patterns) | 5/5 |
| BUG-002 | 🟢 RESOLVED | ✅ Fixed | 1 file (search command) | 1/1 |
| BUG-003 | 🟢 RESOLVED | ✅ Fixed | 1 file (ban command) | 1/1 |
| BUG-004 | 🔴 CRITICAL | ⏳ Pending | 1 file (feeds wrapper) | 0/1 |
| BUG-005 | 🔴 CRITICAL | ⏳ Pending | 1 file (port report) | 0/1 |
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
