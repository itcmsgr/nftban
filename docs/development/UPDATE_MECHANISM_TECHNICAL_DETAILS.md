# NFTBan Update Mechanism - Technical Implementation Details

**Document Type:** Developer / Maintenance Guide
**Version:** 1.0.0
**Date:** 2025-10-21
**Author:** ITCMS Team (Antonios Voulvoulis)
**Purpose:** Detailed technical analysis of update mechanism implementation, bugs discovered, and maintenance guide

---

## Table of Contents

1. [Overview](#overview)
2. [Architecture](#architecture)
3. [Critical Bugs Discovered](#critical-bugs-discovered)
4. [Function Flow Analysis](#function-flow-analysis)
5. [Return Code Conventions](#return-code-conventions)
6. [Commit PIN Security Mechanism](#commit-pin-security-mechanism)
7. [SSH Non-Interactive Mode Handling](#ssh-non-interactive-mode-handling)
8. [Troubleshooting Guide](#troubleshooting-guide)
9. [Developer Notes](#developer-notes)

---

## Overview

The NFTBan update mechanism is a critical security component that safely updates NFTBan installations from GitHub releases. It implements a multi-stage workflow with security hardening, validation checks, and atomic operations.

### Key Design Principles

1. **Fail-Closed Security** - Errors block updates, preventing compromised installations
2. **Atomic Operations** - Updates complete fully or rollback completely (no partial state)
3. **Three-Way Return Codes** - Functions return 0 (success), 1 (error), or 2 (special condition)
4. **Terminal Detection** - Automatically adapts to interactive vs. non-interactive execution
5. **Commit Pinning** - Optional SHA verification to prevent malicious updates

---

## Architecture

### Update Flow State Machine

```
┌─────────────────┐
│  User Invokes   │
│ nftban update   │
└────────┬────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│ STEP 1: Pre-flight Checks                           │
│ - Check dependencies (curl/wget, sha256sum)         │
│ - Verify network connectivity                       │
│ - Ensure running as root                            │
└────────┬────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│ STEP 2: Version Detection (THREE-WAY LOGIC)         │
│                                                      │
│  nftban_update_check()                              │
│    ├─ Get local version (.version file)             │
│    ├─ Get remote version (GitHub API)               │
│    └─ Compare versions                              │
│                                                      │
│  RETURNS:                                            │
│    0 = Already up-to-date (EXIT)                    │
│    1 = Network error / Cannot check (EXIT)          │
│    2 = Update available (CONTINUE)                  │
└────────┬────────────────────────────────────────────┘
         │
         │ (return code 2 only)
         ▼
┌─────────────────────────────────────────────────────┐
│ STEP 3: Commit PIN Verification (SECURITY)          │
│                                                      │
│  IF pin file exists:                                │
│    ├─ Fetch remote commit SHA                       │
│    ├─ Compare with pinned SHA                       │
│    └─ MISMATCH → BLOCK UPDATE (security)            │
│                                                      │
│  FAIL-CLOSED: Mismatches prevent updates            │
└────────┬────────────────────────────────────────────┘
         │
         │ (PIN matched or not set)
         ▼
┌─────────────────────────────────────────────────────┐
│ STEP 4: User Confirmation                           │
│                                                      │
│  IF interactive (stdin is terminal):                │
│    └─ Prompt: "Proceed with update? [y/N]"          │
│  ELSE (SSH / pipe / --skip-confirmation):           │
│    └─ Auto-proceed                                  │
└────────┬────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│ STEP 5: Staging Phase                               │
│  ├─ Create /etc/nftban/.update_tmp (700 perms)      │
│  ├─ Download all files to staging                   │
│  │   ├─ lib/*.sh (all modules)                      │
│  │   ├─ .version                                    │
│  │   ├─ CHANGELOG.md                                │
│  │   └─ SHA256SUMS.txt                              │
│  └─ Path validation (prevent traversal)             │
└────────┬────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│ STEP 6: Validation Phase                            │
│  ├─ SHA256 checksum validation                      │
│  │   └─ Compare downloaded vs. expected             │
│  ├─ Syntax validation (bash -n)                     │
│  │   └─ Detect parse errors before apply            │
│  └─ Version file validation                         │
│      └─ Ensure .version exists and valid            │
│                                                      │
│  ANY FAILURE → Abort and clean staging              │
└────────┬────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│ STEP 7: Backup Phase                                │
│  ├─ Create timestamped backup dir                   │
│  ├─ Backup lib/ directory                           │
│  ├─ Backup .version and CHANGELOG.md                │
│  ├─ Backup config files (exclude *.local)           │
│  └─ Save backup path to .last_backup                │
└────────┬────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│ STEP 8: Apply Phase (ATOMIC)                        │
│  ├─ rsync (atomic) or cp (fallback)                 │
│  ├─ Replace lib/ directory                          │
│  ├─ Update .version file                            │
│  ├─ Update CHANGELOG.md                             │
│  ├─ Set permissions (755 dirs, +x .sh)              │
│  └─ Sync filesystem (flush writes)                  │
│                                                      │
│  ON ERROR → Auto-rollback from backup               │
└────────┬────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────┐
│ STEP 9: Cleanup Phase                               │
│  ├─ Remove staging directory                        │
│  ├─ Log to /var/log/nftban/update.log               │
│  ├─ Send email notification (if configured)         │
│  └─ Display success message                         │
└─────────────────────────────────────────────────────┘
```

---

## Critical Bugs Discovered

### BUG31: Update Mechanism Complete Hang (CRITICAL - BLOCKER)

**Severity:** CRITICAL
**Impact:** Completely blocks ALL updates system-wide
**Discovered:** 2025-10-21
**Fixed In:** v0.9.1 (commit 9923aa1caa8567a67000bcebf2446e382a88d59c)
**File:** `lib/nftban_update_module.sh`
**Line:** 1023

#### Symptom

When running `nftban update perform` or `nftban update auto`, the command would hang indefinitely after displaying:

```
[INFO] Checking for updates...

Current version:  0.9.0
Available version: 0.9.1

[SUCCESS] Update available: 0.9.0 → 0.9.1
```

No further output. Process hung. Update never proceeded.

#### Root Cause Analysis

**The Broken Code:**

```bash
# Line 1023-1026 (BEFORE FIX)
nftban_log_info "Step 2/7: Checking for updates..."
if ! nftban_update_check "true"; then
    return 1
fi
```

**What's Wrong:**

The `nftban_update_check()` function uses a **three-way return code system**:
- `0` = Already up-to-date (no update needed)
- `1` = Error (network failure, cannot check)
- `2` = Update available (proceed with update)

The negation operator `!` in bash treats **ANY non-zero return code as failure**. This means:

```bash
# When update is available:
nftban_update_check "true"  # Returns 2
echo $?                      # 2

# With negation:
if ! nftban_update_check "true"; then  # 2 is non-zero, so ! makes it "true"
    return 1                            # EXITS FUNCTION (wrong!)
fi
```

**The Logic Error:**

```
Return Code 0 (up-to-date):
  ! 0 = 1 (false) → if block SKIPS → Continues (CORRECT, but then later code fails)

Return Code 1 (error):
  ! 1 = 0 (true) → if block EXECUTES → return 1 (CORRECT)

Return Code 2 (update available):
  ! 2 = 0 (true) → if block EXECUTES → return 1 (WRONG! Should continue!)
```

**Why It Hangs:**

After the `nftban_update_check()` call exits early (return 1), the next code section at line 1028 tries to check again:

```bash
# Line 1028-1032 (AFTER the broken check)
nftban_update_compare_versions "$(nftban_update_get_local_version)" "$(nftban_update_get_remote_version)"
if [[ $? -ne 2 ]]; then
    nftban_log_info "No update needed"
    return 0
fi
```

But this code **never executes** because the function already returned at line 1024. The hang occurs because the calling process is waiting for output that never comes.

#### The Fix

**Correct Code (v0.9.1):**

```bash
# Line 1023-1036 (AFTER FIX)
nftban_log_info "Step 2/7: Checking for updates..."
nftban_update_check "true"
local check_result=$?

# Three-way handling: 0=up-to-date, 1=error, 2=update-available
if [[ $check_result -eq 1 ]]; then
    nftban_log_error "Update check failed (network error)"
    return 1
elif [[ $check_result -eq 0 ]]; then
    nftban_log_info "No update needed - already on latest version"
    return 0
fi

# If we reach here, check_result=2 (update available)
# Continue with update process...
nftban_log_info "Update available - proceeding..."
```

**Why This Works:**

1. **Capture return code explicitly**: `local check_result=$?`
2. **Check each condition separately**:
   - `1` → Error, abort
   - `0` → Up-to-date, exit gracefully
   - `2` → Update available, **continue** (don't exit!)
3. **No negation operator** - Explicit checks prevent logic errors

#### Verification

**Test Case 1: No Update Available**

```bash
nftban update perform
# Expected:
[INFO] Step 2/7: Checking for updates...
[INFO] No update needed - already on latest version
# (exits cleanly)
```

**Test Case 2: Update Available**

```bash
nftban update perform
# Expected:
[INFO] Step 2/7: Checking for updates...
[INFO] Update available - proceeding...
[INFO] Step 3/7: User confirmation...
# (continues with update)
```

**Test Case 3: Network Error**

```bash
# Disconnect network
nftban update perform
# Expected:
[INFO] Step 2/7: Checking for updates...
[ERROR] Update check failed (network error)
# (exits with error)
```

#### Impact Assessment

**Before Fix:**
- 100% of update attempts blocked
- Users cannot receive security updates
- Manual intervention required for every update
- Update mechanism completely non-functional

**After Fix:**
- Updates proceed normally
- Three-way return codes handled correctly
- All update paths functional

---

### BUG30: Update Pin Command Hangs via SSH (HIGH PRIORITY)

**Severity:** HIGH
**Impact:** Blocks remote PIN management, requires manual workarounds
**Discovered:** 2025-10-21
**Fixed In:** v0.9.1 (commit 9923aa1caa8567a67000bcebf2446e382a88d59c)
**File:** `lib/nftban_update_module.sh`
**Line:** 320-326
**Related Documentation:** `docs/BUG30_update_pin_ssh_failure.md`

#### Symptom

When running `nftban update pin <commit-sha>` remotely via SSH:

```bash
# From local workstation:
ssh root@server "nftban update pin 9923aa1caa8567a67000bcebf2446e382a88d59c"

# Output:
[WARNING] Updating commit pin:
[WARNING]   From: c90cb1125871341f88c2763dfba071ef7eb09da1
[WARNING]   To:   9923aa1caa8567a67000bcebf2446e382a88d59c
# (HANGS INDEFINITELY - no prompt, no response)
```

The command never completes. User must Ctrl+C to abort.

#### Root Cause Analysis

**The Broken Code:**

```bash
# Line 320-331 (BEFORE FIX)
if [[ -n "$current_pin" ]]; then
    nftban_log_warning "Updating commit pin:"
    nftban_log_warning "  From: $current_pin"
    nftban_log_warning "  To:   $new_sha"

    read -p "Are you sure? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        nftban_log_info "Pin update cancelled"
        return 1
    fi
fi
```

**What's Wrong:**

The `read -p` command **requires a terminal** (TTY) to read user input. When executing via SSH without a terminal, the command hangs waiting for input that will never arrive.

**SSH Execution Modes:**

```bash
# Interactive SSH (allocates TTY):
ssh root@server
root@server# nftban update pin <sha>
# (Works - terminal available)

# Non-interactive SSH (NO TTY):
ssh root@server "nftban update pin <sha>"
# (Hangs - no terminal, read waits forever)

# Pipe input (NO TTY):
echo "y" | nftban update pin <sha>
# (Hangs - stdin is pipe, not terminal)
```

**Terminal Detection in Bash:**

```bash
# Check if stdin (file descriptor 0) is a terminal:
[[ -t 0 ]]  # Returns 0 (true) if terminal, 1 (false) if not

# Examples:
[[ -t 0 ]] && echo "Interactive"     # Prints in terminal
echo "test" | { [[ -t 0 ]] && echo "Interactive"; }  # Doesn't print (pipe)
ssh root@host "[[ -t 0 ]] && echo 'Interactive'"    # Doesn't print (no TTY)
```

#### The Fix

**Correct Code (v0.9.1):**

```bash
# Line 320-336 (AFTER FIX)
if [[ -n "$current_pin" ]]; then
    nftban_log_warning "Updating commit pin:"
    nftban_log_warning "  From: $current_pin"
    nftban_log_warning "  To:   $new_sha"

    # BUG30 FIX: Only prompt if stdin is a terminal (not via SSH/pipe)
    if [[ -t 0 ]] && [[ "$force" != "true" ]]; then
        # Interactive mode - prompt user
        read -p "Are you sure? [y/N] " -n 1 -r
        echo ""
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            nftban_log_info "Pin update cancelled"
            return 1
        fi
    else
        # Non-interactive mode (SSH/pipe) or force mode - auto-confirm
        nftban_log_info "Auto-confirming pin update (non-interactive mode)"
    fi
fi
```

**How This Works:**

1. **Terminal Detection**: `[[ -t 0 ]]` checks if stdin is a TTY
2. **Force Flag Check**: `[[ "$force" != "true" ]]` allows override
3. **Conditional Prompting**:
   - **Terminal + Not Forced**: Prompt user (interactive)
   - **No Terminal OR Forced**: Auto-confirm (non-interactive)

**Decision Matrix:**

| Scenario | `[[ -t 0 ]]` | `force` | Behavior |
|----------|--------------|---------|----------|
| Interactive shell | true | false | Prompt user |
| SSH remote command | false | false | Auto-confirm |
| Piped input | false | false | Auto-confirm |
| Interactive + force | true | true | Auto-confirm |
| Automation script | false | false | Auto-confirm |

#### Verification

**Test Case 1: Interactive Terminal (should prompt)**

```bash
# From server console:
nftban update pin 9923aa1caa8567a67000bcebf2446e382a88d59c

# Expected output:
[WARNING] Updating commit pin:
[WARNING]   From: c90cb1125871341f88c2763dfba071ef7eb09da1
[WARNING]   To:   9923aa1caa8567a67000bcebf2446e382a88d59c
Are you sure? [y/N] █  # (waits for input)
```

**Test Case 2: SSH Remote Command (should auto-confirm)**

```bash
# From workstation:
ssh root@server "nftban update pin 9923aa1caa8567a67000bcebf2446e382a88d59c"

# Expected output:
[WARNING] Updating commit pin:
[WARNING]   From: c90cb1125871341f88c2763dfba071ef7eb09da1
[WARNING]   To:   9923aa1caa8567a67000bcebf2446e382a88d59c
[INFO] Auto-confirming pin update (non-interactive mode)
[SUCCESS] Commit SHA pinned: 9923aa1caa8567a67000bcebf2446e382a88d59c
```

**Test Case 3: Piped Input (should auto-confirm)**

```bash
echo "irrelevant" | nftban update pin 9923aa1caa8567a67000bcebf2446e382a88d59c

# Expected output:
# (same as Test Case 2 - auto-confirms, ignores piped input)
```

**Test Case 4: Force Mode (should auto-confirm even in terminal)**

```bash
# From server console:
nftban update pin 9923aa1caa8567a67000bcebf2446e382a88d59c --force

# Expected output:
[WARNING] Updating commit pin:
[WARNING]   From: c90cb1125871341f88c2763dfba071ef7eb09da1
[WARNING]   To:   9923aa1caa8567a67000bcebf2446e382a88d59c
[INFO] Auto-confirming pin update (non-interactive mode)
[SUCCESS] Commit SHA pinned: 9923aa1caa8567a67000bcebf2446e382a88d59c
```

#### Security Implications

**Is Auto-Confirm Safe?**

YES - In non-interactive modes (SSH, automation), the assumption is:
1. User has already made the decision to run the command
2. Prompting is impossible (no terminal)
3. Command will hang without auto-confirm (worse UX)

**Security is maintained by:**
- Requiring explicit commit SHA argument (user must know what to pin)
- Logging the pin change (audit trail)
- Root-only access (already requires elevated privileges)

**For Extra Security:**

If interactive confirmation is required even via SSH, use:

```bash
# Force interactive mode (will fail if no TTY):
ssh -t root@server "nftban update pin <sha>"
# The -t flag allocates a pseudo-TTY, enabling read -p
```

#### Impact Assessment

**Before Fix:**
- PIN management via SSH: **BLOCKED**
- Automation scripts: **BLOCKED**
- Required manual PIN file editing (error-prone)
- Workaround: SSH in, then run command (slow, non-scalable)

**After Fix:**
- PIN management via SSH: **WORKING**
- Automation scripts: **WORKING**
- Auto-detects terminal presence
- Falls back gracefully to auto-confirm

---

## Function Flow Analysis

### nftban_update_perform() - Main Update Orchestrator

**Purpose:** Coordinates entire update process from check to completion

**Function Signature:**
```bash
nftban_update_perform() {
    local skip_confirmation="${1:-false}"
    # ...
}
```

**Parameters:**
- `$1` (optional): `skip_confirmation` - If "true", skip user confirmation prompt

**Return Codes:**
- `0` - Update completed successfully
- `1` - Update failed (error occurred)

**Execution Flow:**

```
nftban_update_perform()
  │
  ├─ Step 1/7: Header display
  │    └─ Log: "Starting nftban update process..."
  │
  ├─ Step 2/7: Version check (THREE-WAY LOGIC)
  │    ├─ Call: nftban_update_check "true"
  │    ├─ Capture: check_result=$?
  │    ├─ If 1 (error):    return 1 (abort)
  │    ├─ If 0 (up-to-date): return 0 (exit gracefully)
  │    └─ If 2 (update available): CONTINUE
  │
  ├─ Step 3/7: Commit PIN verification
  │    ├─ Check: Does /etc/nftban/data/.commit_pin exist?
  │    ├─ If YES:
  │    │    ├─ Read pinned SHA from file
  │    │    ├─ Fetch remote commit SHA (GitHub API)
  │    │    ├─ Compare: pinned_sha == remote_sha
  │    │    └─ If MISMATCH:
  │    │         ├─ Log: ERROR with security warning
  │    │         ├─ Log: GitHub verification URL
  │    │         └─ return 1 (BLOCK UPDATE - fail-closed security)
  │    └─ If NO PIN: Continue (pin optional)
  │
  ├─ Step 4/7: User confirmation
  │    ├─ If skip_confirmation="true": SKIP
  │    ├─ Else:
  │    │    ├─ Prompt: "Proceed with update? [y/N]"
  │    │    └─ If not 'y': return 0 (user cancelled)
  │    └─ Continue
  │
  ├─ Step 5/7: Initialize staging
  │    ├─ Call: nftban_update_staging_init
  │    ├─ Creates: /etc/nftban/.update_tmp/ (700 perms)
  │    └─ If fails: return 1
  │
  ├─ Step 6/7: Download to staging
  │    ├─ Call: nftban_update_download_to_staging
  │    ├─ Downloads all files from GitHub
  │    └─ If fails: Clean staging, return 1
  │
  ├─ Step 7/7: Validate staging
  │    ├─ Call: nftban_update_validate_staging
  │    ├─ Checks: SHA256, syntax, version file
  │    └─ If fails: Clean staging, return 1
  │
  ├─ Create backup
  │    ├─ Call: nftban_update_create_backup
  │    ├─ Creates: /var/lib/nftban/backups/pre_update_TIMESTAMP/
  │    └─ If fails: Clean staging, return 1
  │
  ├─ Apply update
  │    ├─ Call: nftban_update_apply
  │    ├─ Replaces: lib/, .version, CHANGELOG.md
  │    ├─ If fails: Rollback + Clean staging, return 1
  │    └─ Success: Continue
  │
  ├─ Cleanup
  │    ├─ Call: nftban_update_staging_clean
  │    ├─ Remove: /etc/nftban/.update_tmp/
  │    └─ Log: Success message
  │
  ├─ Notifications
  │    ├─ Call: nftban_update_send_notification (if configured)
  │    └─ Email: Update success notification
  │
  └─ Return 0 (SUCCESS)
```

**Error Handling:**

At each step, if an error occurs:
1. Log detailed error message
2. Clean staging directory (if created)
3. Rollback (if in apply phase)
4. Return 1 (propagate error)

**Trap Handlers:**

```bash
# Ensure cleanup on script exit/error
trap 'nftban_update_staging_clean' EXIT ERR
```

---

### nftban_update_check() - Update Detection

**Purpose:** Check if update is available (three-way return code)

**Function Signature:**
```bash
nftban_update_check() {
    local show_output="${1:-true}"
    # ...
}
```

**Parameters:**
- `$1` (optional): `show_output` - If "true", display version comparison

**Return Codes (THREE-WAY):**
- `0` - Already up-to-date (local == remote)
- `1` - Error (network failure, cannot determine)
- `2` - Update available (local < remote)

**Execution Flow:**

```
nftban_update_check()
  │
  ├─ Get local version
  │    ├─ Call: nftban_update_get_local_version
  │    ├─ Read: /etc/nftban/.version
  │    └─ Store: local_version
  │
  ├─ Get remote version
  │    ├─ Call: nftban_update_get_remote_version
  │    ├─ Fetch: https://raw.githubusercontent.com/.../main/.version
  │    ├─ If fails: return 1 (NETWORK ERROR)
  │    └─ Store: remote_version
  │
  ├─ Compare versions
  │    ├─ Call: nftban_update_compare_versions "$local_version" "$remote_version"
  │    └─ Capture: compare_result=$?
  │         ├─ 0: local == remote
  │         ├─ 1: local > remote (shouldn't happen)
  │         └─ 2: local < remote (update available)
  │
  ├─ If show_output="true":
  │    ├─ Display: Current version: $local_version
  │    ├─ Display: Available version: $remote_version
  │    └─ Display: Comparison result
  │
  └─ Return compare_result
       ├─ 0: return 0 (up-to-date)
       ├─ 1: return 0 (local > remote, treat as up-to-date)
       └─ 2: return 2 (UPDATE AVAILABLE)
```

**Usage Examples:**

```bash
# Example 1: Check and handle result
nftban_update_check "true"
result=$?
if [[ $result -eq 2 ]]; then
    echo "Update available!"
elif [[ $result -eq 0 ]]; then
    echo "Up-to-date"
else
    echo "Error checking"
fi

# Example 2: WRONG - Will fail with update available (BUG31)
if ! nftban_update_check "true"; then
    echo "Check failed or update available"  # AMBIGUOUS!
fi

# Example 3: Correct three-way handling
nftban_update_check "true"
case $? in
    0) echo "Up-to-date" ;;
    1) echo "Error" ;;
    2) echo "Update available" ;;
esac
```

---

## Return Code Conventions

### Standard Three-Way Pattern

Many NFTBan update functions use a **three-way return code system** instead of binary success/failure:

```
0 = Success / No action needed
1 = Error / Failure
2 = Special condition / Action needed
```

**Functions Using Three-Way Returns:**

| Function | 0 | 1 | 2 |
|----------|---|---|---|
| `nftban_update_check()` | Up-to-date | Error | Update available |
| `nftban_update_compare_versions()` | Equal | v1 > v2 | v1 < v2 |

### Correct Handling Pattern

**CORRECT ✓:**

```bash
nftban_update_check "true"
local result=$?

if [[ $result -eq 1 ]]; then
    # Handle error
    return 1
elif [[ $result -eq 0 ]]; then
    # Handle up-to-date
    return 0
fi

# If we reach here, result=2 (update available)
# Continue with update...
```

**WRONG ✗ (BUG31 pattern):**

```bash
# This treats return code 2 as failure!
if ! nftban_update_check "true"; then
    return 1  # WRONG: Exits when update available
fi
```

**WRONG ✗ (Implicit zero-check):**

```bash
# This fails for both 1 and 2
if nftban_update_check "true"; then
    # Only executes for return code 0
fi
# What about codes 1 and 2? Unhandled!
```

### Migration Guide: Binary to Three-Way

**Before (Binary):**

```bash
if some_check; then
    echo "Success"
else
    echo "Failure"
fi
```

**After (Three-Way):**

```bash
some_check
local result=$?

if [[ $result -eq 0 ]]; then
    echo "Success"
elif [[ $result -eq 1 ]]; then
    echo "Failure"
elif [[ $result -eq 2 ]]; then
    echo "Special condition"
fi
```

---

## Commit PIN Security Mechanism

### Purpose

Prevent malicious updates by pinning to a specific trusted commit SHA. If enabled, updates will **ONLY** install from the pinned commit, rejecting all others (even legitimate updates).

### Design: Fail-Closed Security

**Philosophy:** When in doubt, block the update.

```
┌──────────────────────────────────────────┐
│  Update Attempt                          │
└────────────┬─────────────────────────────┘
             │
             ▼
      ┌──────────────┐
      │ PIN file     │
      │ exists?      │
      └──┬────────┬──┘
         │ NO     │ YES
         │        │
         ▼        ▼
    ┌────────┐ ┌──────────────────────────┐
    │ALLOW   │ │ Fetch remote commit SHA  │
    │update  │ │ from GitHub API          │
    └────────┘ └────────┬─────────────────┘
                        │
                        ▼
                 ┌──────────────┐
                 │ Compare:     │
                 │ pin == remote│
                 └──┬────────┬──┘
                    │ MATCH  │ MISMATCH
                    │        │
                    ▼        ▼
               ┌────────┐ ┌──────────────┐
               │ALLOW   │ │BLOCK update  │
               │update  │ │(security)    │
               └────────┘ └──────────────┘
                             │
                             ▼
                          ┌──────────────────────┐
                          │ Log error:           │
                          │ - PIN mismatch       │
                          │ - Security warning   │
                          │ - GitHub verify URL  │
                          └──────────────────────┘
```

### PIN File Location

```bash
PIN_FILE="/etc/nftban/data/.commit_pin"
```

### PIN File Format

Plain text file containing single line with full 40-character commit SHA:

```
9923aa1caa8567a67000bcebf2446e382a88d59c
```

**Not Allowed:**
- Short SHAs (9923aa1)
- Multiple lines
- Comments
- Prefixes (commit: ...)

### Creating a PIN

**Method 1: Using nftban update pin command**

```bash
# Pin to specific commit (prompts for confirmation in terminal)
nftban update pin 9923aa1caa8567a67000bcebf2446e382a88d59c

# Pin via SSH (auto-confirms, no prompt)
ssh root@server "nftban update pin 9923aa1caa8567a67000bcebf2446e382a88d59c"

# Force mode (auto-confirms even in terminal)
nftban update pin 9923aa1caa8567a67000bcebf2446e382a88d59c --force
```

**Method 2: Manual PIN file creation**

```bash
# Create PIN file manually
echo "9923aa1caa8567a67000bcebf2446e382a88d59c" > /etc/nftban/data/.commit_pin

# Verify
cat /etc/nftban/data/.commit_pin
```

### Removing a PIN

```bash
# Using nftban command
nftban update pin --remove

# Manual removal
rm /etc/nftban/data/.commit_pin
```

### Security Validation Flow

**When update attempt occurs:**

```bash
# 1. Check if PIN exists
if [[ -f "$PIN_FILE" ]]; then
    # 2. Read pinned SHA
    pinned_sha=$(cat "$PIN_FILE" | tr -d '[:space:]')

    # 3. Fetch remote commit SHA from GitHub API
    remote_sha=$(curl -s "https://api.github.com/repos/itcmsgr/nftban/commits/main" | \
                 jq -r '.sha' 2>/dev/null)

    # 4. Compare
    if [[ "$pinned_sha" != "$remote_sha" ]]; then
        # MISMATCH - BLOCK UPDATE
        nftban_log_error "Update DENIED: Commit SHA mismatch"
        nftban_log_error "  Pinned:  $pinned_sha"
        nftban_log_error "  Remote:  $remote_sha"
        nftban_log_error ""
        nftban_log_error "This could indicate:"
        nftban_log_error "  1. New version available (update pin file after verifying)"
        nftban_log_error "  2. Man-in-the-middle attack (DO NOT UPDATE)"
        nftban_log_error "  3. Repository compromise (DO NOT UPDATE)"
        nftban_log_error ""
        nftban_log_error "Verify the commit on GitHub first:"
        nftban_log_error "  https://github.com/itcmsgr/nftban/commit/$remote_sha"
        nftban_log_error "Update ABORTED: Commit verification failed"
        return 1
    fi

    # MATCH - Allow update
    nftban_log_info "Commit PIN verified: $pinned_sha"
fi
```

### Use Cases

**When to Use PIN:**

1. **High-Security Environments**
   - Production servers with strict change control
   - Compliance requirements (audit trail)
   - Need to verify updates before deployment

2. **Staged Rollout**
   - Test update on dev server first
   - Pin to tested commit
   - Roll out to production with same commit

3. **Prevent Auto-Updates**
   - Control when updates occur
   - Review changelog before updating
   - Schedule maintenance windows

**When NOT to Use PIN:**

1. **Development/Testing** - Frequent updates needed
2. **Auto-Update Environments** - PIN blocks automation
3. **Low-Risk Systems** - Overhead not justified

### Updating PIN After New Release

**Workflow:**

```bash
# 1. Check for new version
nftban update check

# Output:
# Current version:  0.9.0
# Available version: 0.9.1
# Update available

# 2. Update attempt blocked by PIN
nftban update perform
# [ERROR] Update DENIED: Commit SHA mismatch
# [ERROR]   Pinned:  abc123...
# [ERROR]   Remote:  def456...
# [ERROR] Verify: https://github.com/itcmsgr/nftban/commit/def456...

# 3. Verify commit on GitHub
# - Visit URL in browser
# - Review changes
# - Verify author
# - Check signatures (if GPG signed)

# 4. Update PIN to new commit (if verified safe)
nftban update pin def456789...

# 5. Retry update (now allowed)
nftban update perform
# [INFO] Commit PIN verified: def456789...
# [SUCCESS] Update completed
```

### Attack Scenarios Prevented

**Scenario 1: Man-in-the-Middle Attack**

```
Attacker intercepts update request
  ↓
Serves malicious code instead of genuine update
  ↓
PIN check: remote SHA != pinned SHA
  ↓
UPDATE BLOCKED ✓
```

**Scenario 2: Repository Compromise**

```
Attacker gains access to GitHub repo
  ↓
Pushes malicious commit to main branch
  ↓
PIN check: remote SHA changed
  ↓
UPDATE BLOCKED ✓
Admin must manually review and re-pin
```

**Scenario 3: Typosquatting / Wrong Repo**

```
User misconfigures GITHUB_URL to attacker's fork
  ↓
Update fetches from malicious repo
  ↓
PIN check: remote SHA doesn't exist in real repo
  ↓
UPDATE BLOCKED ✓
```

---

## SSH Non-Interactive Mode Handling

### Terminal Detection

**The Core Check:**

```bash
[[ -t 0 ]]  # Returns true if file descriptor 0 (stdin) is a terminal
```

**How It Works:**

```
File Descriptor 0 (stdin):
  ├─ Interactive shell: Terminal TTY (keyboard input)
  ├─ SSH with command: Pipe (no TTY unless -t flag)
  ├─ Piped input: Pipe (echo "data" | script)
  └─ Redirected file: File (script < input.txt)

[[ -t 0 ]] returns:
  ├─ 0 (true): stdin is a terminal
  └─ 1 (false): stdin is NOT a terminal
```

### SSH Execution Modes

**Mode 1: Interactive SSH (TTY allocated)**

```bash
# Connect to server interactively
ssh root@server

# Now on server, run command
root@server# nftban update pin abc123...

# Result: [[ -t 0 ]] = true (terminal available)
# Behavior: Prompts user for confirmation
```

**Mode 2: Non-Interactive SSH (No TTY)**

```bash
# Execute command remotely (no shell)
ssh root@server "nftban update pin abc123..."

# Result: [[ -t 0 ]] = false (no terminal)
# Behavior: Auto-confirms (cannot prompt)
```

**Mode 3: SSH with Forced TTY**

```bash
# Force pseudo-TTY allocation with -t flag
ssh -t root@server "nftban update pin abc123..."

# Result: [[ -t 0 ]] = true (pseudo-TTY created)
# Behavior: Prompts user for confirmation
```

### Adaptation Logic

**Pattern Used in NFTBan:**

```bash
if [[ -t 0 ]] && [[ "$force" != "true" ]]; then
    # INTERACTIVE MODE
    # - Terminal is available (user can respond)
    # - Force mode not enabled
    # ACTION: Prompt for confirmation

    read -p "Are you sure? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Operation cancelled"
        return 1
    fi
else
    # NON-INTERACTIVE MODE
    # - No terminal (SSH remote command, pipe, file redirect)
    # - OR force mode enabled
    # ACTION: Auto-confirm (cannot prompt)

    echo "Auto-confirming (non-interactive mode)"
fi

# Continue with operation...
```

**Decision Table:**

| Terminal (`-t 0`) | Force Flag | Behavior |
|-------------------|------------|----------|
| true | false | **Prompt** user |
| true | true | **Auto-confirm** (force override) |
| false | false | **Auto-confirm** (can't prompt) |
| false | true | **Auto-confirm** (can't prompt) |

### Use Cases

**Use Case 1: Automation Scripts**

```bash
#!/bin/bash
# Automated deployment script

# This runs non-interactively (no TTY)
# Auto-confirms without prompting
for server in web-01 web-02 web-03; do
    ssh root@$server "nftban update pin $VERIFIED_COMMIT_SHA"
done
```

**Use Case 2: Ansible / Configuration Management**

```yaml
# Ansible playbook
- name: Update nftban commit PIN
  command: nftban update pin {{ verified_commit }}
  # Runs non-interactively, auto-confirms
```

**Use Case 3: Manual Remote Execution**

```bash
# Quick remote command (no need to SSH in first)
ssh root@production-server "nftban update pin abc123def456..."
# Auto-confirms, completes immediately
```

**Use Case 4: Piped Input (Batch Operations)**

```bash
# Process list of servers
cat servers.txt | while read server; do
    ssh root@$server "nftban update pin $COMMIT_SHA"
done
# Each execution auto-confirms (stdin is pipe)
```

### Testing Terminal Detection

**Test Script:**

```bash
#!/bin/bash
# test_terminal_detection.sh

if [[ -t 0 ]]; then
    echo "TERMINAL: stdin is a terminal"
    echo "  - Running in interactive shell"
    echo "  - Can use 'read -p' safely"
else
    echo "NO TERMINAL: stdin is NOT a terminal"
    echo "  - Running via SSH, pipe, or redirect"
    echo "  - Cannot use 'read -p' (would hang)"
fi
```

**Test Cases:**

```bash
# Test 1: Interactive shell
./test_terminal_detection.sh
# Output: "TERMINAL: stdin is a terminal"

# Test 2: Piped input
echo "data" | ./test_terminal_detection.sh
# Output: "NO TERMINAL: stdin is NOT a terminal"

# Test 3: SSH remote
ssh root@server "./test_terminal_detection.sh"
# Output: "NO TERMINAL: stdin is NOT a terminal"

# Test 4: SSH with -t flag
ssh -t root@server "./test_terminal_detection.sh"
# Output: "TERMINAL: stdin is a terminal"
```

---

## Troubleshooting Guide

### Symptom: Update Hangs After "Update available" Message

**Diagnosis:**

```
[INFO] Checking for updates...
Current version:  0.9.0
Available version: 0.9.1
[SUCCESS] Update available: 0.9.0 → 0.9.1
(hangs forever - no further output)
```

**Cause:** BUG31 (three-way return code mishandling)

**Check Version:**

```bash
grep -n "if ! nftban_update_check" /etc/nftban/lib/nftban_update_module.sh
# If found at line 1023: BUG31 present
```

**Fix:** Update to v0.9.1 or apply patch manually

**Manual Patch:**

```bash
# Edit update module
nano /etc/nftban/lib/nftban_update_module.sh

# Find line 1023-1026:
# if ! nftban_update_check "true"; then
#     return 1
# fi

# Replace with:
nftban_update_check "true"
local check_result=$?

if [[ $check_result -eq 1 ]]; then
    nftban_log_error "Update check failed (network error)"
    return 1
elif [[ $check_result -eq 0 ]]; then
    nftban_log_info "No update needed - already on latest version"
    return 0
fi

# Save and retry update
```

---

### Symptom: PIN Update Hangs via SSH

**Diagnosis:**

```bash
ssh root@server "nftban update pin abc123..."
# Output:
[WARNING] Updating commit pin:
[WARNING]   From: old_sha
[WARNING]   To:   new_sha
(hangs forever - waiting for input)
```

**Cause:** BUG30 (missing terminal detection)

**Check Version:**

```bash
ssh root@server "grep -A3 'Are you sure?' /etc/nftban/lib/nftban_update_module.sh | grep -c '\-t 0'"
# If returns 0: BUG30 present (missing terminal check)
# If returns 1+: BUG30 fixed (has terminal check)
```

**Workaround (Temporary):**

```bash
# Option 1: Use interactive SSH (allocate TTY)
ssh -t root@server "nftban update pin abc123..."
# Now can respond to prompt

# Option 2: Manually create PIN file
ssh root@server "echo 'abc123...' > /etc/nftban/data/.commit_pin"
```

**Fix:** Update to v0.9.1 or apply patch manually

**Manual Patch:**

```bash
ssh root@server
# On server:

nano /etc/nftban/lib/nftban_update_module.sh

# Find the "Are you sure?" prompt section (~line 325)
# Wrap the read -p in terminal check:

# BEFORE:
# read -p "Are you sure? [y/N] " -n 1 -r
# echo ""

# AFTER:
if [[ -t 0 ]] && [[ "$force" != "true" ]]; then
    read -p "Are you sure? [y/N] " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        nftban_log_info "Pin update cancelled"
        return 1
    fi
else
    nftban_log_info "Auto-confirming pin update (non-interactive mode)"
fi

# Save and retry
```

---

### Symptom: Update Blocked by PIN Mismatch

**Diagnosis:**

```
[ERROR] Update DENIED: Commit SHA mismatch
[ERROR]   Pinned:  abc123...
[ERROR]   Remote:  def456...
[ERROR] Update ABORTED: Commit verification failed
```

**Cause:** PIN mechanism working correctly (fail-closed security)

**This is NOT a bug** - This is expected behavior when:
1. New version released (remote commit changed)
2. PIN file manually edited (typo or outdated)
3. GitHub repo changed (legitimate or attack)

**Resolution Steps:**

```bash
# 1. Verify remote commit on GitHub
# Visit the URL shown in error message
# https://github.com/itcmsgr/nftban/commit/def456...

# 2. Review commit details:
#    - Author (should be trusted maintainer)
#    - Changes (review diff for malicious code)
#    - Signatures (GPG verification if available)

# 3. If commit verified safe, update PIN:
nftban update pin def456...

# 4. Retry update:
nftban update perform
```

**If commit looks suspicious:**

```bash
# DO NOT UPDATE PIN
# DO NOT PROCEED WITH UPDATE

# Instead:
# 1. Report to security team
# 2. Check GitHub for security advisories
# 3. Verify repository URL is correct
# 4. Check for MITM attack (DNS poisoning, etc.)
```

---

## Developer Notes

### Adding New Update Steps

**Pattern to Follow:**

```bash
nftban_log_info "Step N/7: Description..."

# Call function
if ! some_operation; then
    nftban_log_error "Step N failed: Details"
    nftban_update_staging_clean
    return 1
fi

nftban_log_success "Step N completed"
```

**Important:**
- Always clean staging on error
- Always log success/failure
- Always return proper exit code

### Return Code Best Practices

**When to Use Three-Way Returns:**

Use three-way (0, 1, 2) when function has **three distinct outcomes**:

- **0**: Success / No action needed / Already done
- **1**: Error / Failure / Cannot proceed
- **2**: Special condition / Action needed / Proceed differently

**Examples:**

```bash
# Good: Three distinct outcomes
check_for_updates() {
    # ...
    # return 0: up-to-date
    # return 1: error
    # return 2: update available
}

# Bad: Only two outcomes (use binary)
validate_file() {
    # ...
    # return 0: valid
    # return 1: invalid
    # (No third outcome - use binary)
}
```

**Handling Three-Way Returns:**

```bash
# ALWAYS capture return code first
function_call
local result=$?

# THEN handle each case explicitly
if [[ $result -eq 0 ]]; then
    # Handle success
elif [[ $result -eq 1 ]]; then
    # Handle error
elif [[ $result -eq 2 ]]; then
    # Handle special condition
fi
```

**NEVER use negation with three-way returns:**

```bash
# WRONG:
if ! three_way_function; then
    # Ambiguous: Is this error (1) or special (2)?
fi

# RIGHT:
three_way_function
case $? in
    0) handle_success ;;
    1) handle_error ;;
    2) handle_special ;;
esac
```

### Terminal Detection Patterns

**Standard Pattern:**

```bash
if [[ -t 0 ]]; then
    # Interactive mode - can prompt user
    read -p "Question? " answer
else
    # Non-interactive - auto-decide
    answer="default"
fi
```

**With Force Flag:**

```bash
if [[ -t 0 ]] && [[ "$force" != "true" ]]; then
    # Interactive AND not forced - prompt
    read -p "Question? " answer
else
    # Non-interactive OR forced - auto-decide
    answer="default"
fi
```

**Multi-Level Verbosity:**

```bash
if [[ -t 0 ]]; then
    # Interactive - full output
    echo "Detailed progress information..."
    show_progress_bar
else
    # Non-interactive - minimal output (parseable)
    echo "STATUS: processing"
fi
```

### Security Considerations

**Path Validation:**

```bash
# ALWAYS validate paths from external sources
_nftban_update_validate_path() {
    local path="$1"

    # Reject absolute paths
    [[ "$path" =~ ^/ ]] && return 1

    # Reject path traversal
    [[ "$path" =~ \.\. ]] && return 1

    # Reject dangerous characters
    [[ "$path" =~ [\$\`\;\|\&\<\>] ]] && return 1

    # Only allow safe characters
    [[ ! "$path" =~ ^[a-zA-Z0-9._/-]+$ ]] && return 1

    return 0
}
```

**Command Injection Prevention:**

```bash
# WRONG - Command injection possible:
sha256sum $file

# RIGHT - Use -- and quotes:
sha256sum -- "$file"
```

**HTTPS Enforcement:**

```bash
# WRONG - Accepts HTTP:
curl -o file "$url"

# RIGHT - Validate HTTPS first:
[[ "$url" =~ ^https:// ]] || return 1
curl --fail -o file "$url"
```

### Testing Checklist

Before releasing update module changes:

- [ ] Test with update available (return code 2)
- [ ] Test with no update (return code 0)
- [ ] Test with network error (return code 1)
- [ ] Test PIN verification (match)
- [ ] Test PIN verification (mismatch - should block)
- [ ] Test via interactive SSH
- [ ] Test via non-interactive SSH
- [ ] Test with piped input
- [ ] Test with force flag
- [ ] Test rollback mechanism
- [ ] Test syntax validation (valid files)
- [ ] Test syntax validation (broken file - should abort)
- [ ] Test SHA256 validation (valid checksums)
- [ ] Test SHA256 validation (mismatch - should abort)

---

## Appendix: Commit History

### v0.9.1 Update Mechanism Fixes

**Commit:** 9923aa1caa8567a67000bcebf2446e382a88d59c
**Date:** 2025-10-21
**Changes:**

1. **BUG31 Fix** (lib/nftban_update_module.sh:1023-1036)
   - Replaced negation check with explicit three-way handling
   - Added detailed return code comments
   - Prevented update hang when update available

2. **BUG30 Fix** (lib/nftban_update_module.sh:320-336)
   - Added terminal detection using `[[ -t 0 ]]`
   - Implemented auto-confirmation for non-interactive mode
   - Enabled remote PIN management via SSH

**Files Modified:**
- `lib/nftban_update_module.sh` (2 critical bug fixes)

**Testing:**
- CentOS 9: lab.mywebhost.gr ✓
- Ubuntu 24.04: lab1.mywebhost.gr ✓
- CentOS 10: 65.21.157.15 ✓

---

**End of Technical Documentation**

For user-facing documentation, see: `docs/nftban_update_doc.md`
For bug reports, see: `docs/BUG30_update_pin_ssh_failure.md`
