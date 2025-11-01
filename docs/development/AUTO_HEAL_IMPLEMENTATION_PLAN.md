# NFTBan Auto-Heal Implementation Plan
**Version:** 1.0.0
**Date:** 2025-11-01
**Status:** 🟡 IN PROGRESS
**Priority:** P0 - CRITICAL (Blocking v0.10.0 Release)

---

## 📋 Executive Summary

Implementing the `--auto-heal` flag for `nftban health check` command as specified in TODO.md BUG-NEW-005. This feature will automatically fix detected issues when enabled, supporting both manual execution and timer-based automated healing.

**Related:** `docs/TODO.md` Line 50-143 (BUG-NEW-005)

---

## 🎯 Requirements

### Functional Requirements

1. **FR-1:** `nftban health check --auto-heal` must actually fix issues (not just report)
2. **FR-2:** Auto-heal must respect Polkit permissions (root or nftban-cli group)
3. **FR-3:** Auto-heal must show clear "Auto-healing..." messages during execution
4. **FR-4:** All fixes must be logged to `/var/lib/nftban/permissions_audit.log`
5. **FR-5:** Timer-based auto-heal must run daily at 03:00 AM
6. **FR-6:** Must support `--quiet` flag for timer/cron usage
7. **FR-7:** Must consolidate duplicate timers (health vs permissions-audit)

### Non-Functional Requirements

1. **NFR-1:** Must maintain backward compatibility with existing `nftban health check`
2. **NFR-2:** Must not break existing health check functionality
3. **NFR-3:** Code must follow existing nftban coding standards (headers, exports, error handling)
4. **NFR-4:** Documentation must be updated alongside code changes

---

## 🔍 Current State Analysis

### What EXISTS ✅

1. **Health Check System** (`src/usr/lib/nftban/core/nftban_health.sh`)
   - `nftban_health_check_all()` - Runs all checks
   - `nftban_health_fix_permissions()` - Fixes permissions
   - `nftban_health_fix_directories()` - Creates missing dirs
   - `nftban_health_fix_services()` - Restarts services
   - `nftban_health_fix_system_config()` - Updates system config

2. **CLI Handler** (`src/usr/lib/nftban/cli/cmd_health.sh`)
   - ✅ **PARTIALLY IMPLEMENTED:** `--auto-heal` flag parsing added (Step 1 complete)
   - ❌ **MISSING:** Integration with health check function
   - `nftban_health_cmd_fix()` - Manual fix command

3. **Timers** (`src/usr/lib/systemd/system/`)
   - `nftban-health.timer` + `.service` - Daily 03:00 AM, runs `nftban health fix all`
   - `nftban-permissions-audit.timer` + `.service` - Weekly Sunday 02:00 AM, runs `nftban permissions check`

4. **Permissions Module** (`src/usr/lib/nftban/core/nftban_permissions.sh`)
   - `nftban_permissions_enforce_all()` - Comprehensive permission enforcement
   - `perms_log_audit()` - Audit logging function

5. **Polkit Integration** (`packaging/polkit-1/rules.d/60-nftban-cli.rules`)
   - Group-based authorization for nftban-cli members
   - Currently: systemd service management only (nftables, fail2ban)

### What's MISSING ❌

1. **Auto-heal logic in `nftban_health_check_all()`**
   - Does NOT accept `$auto_heal` parameter
   - Does NOT call fix functions when issues detected
   - Does NOT re-check after fixes

2. **Permission checks for auto-heal**
   - No root/Polkit verification before attempting fixes

3. **Audit logging integration**
   - Fix functions don't log to audit trail

4. **Duplicate timer consolidation**
   - Two timers doing overlapping work

5. **Help text documentation**
   - `--auto-heal` flag not documented in help output

---

## 📐 Implementation Design

### Architecture

```
User Input: nftban health check --auto-heal
     ↓
cmd_health.sh:nftban_health_cmd_check()
     ├─ Parse --auto-heal flag ✅ (DONE - Step 1)
     ├─ Parse --quiet flag ✅ (DONE - Step 1)
     └─ Call nftban_health_check_all($auto_heal)
           ↓
nftban_health.sh:nftban_health_check_all()
     ├─ Run all health checks
     ├─ Collect errors/warnings
     ├─ IF auto_heal=1 AND issues found:
     │    ├─ Check user permissions (root or nftban-cli)
     │    ├─ Call nftban_health_fix_directories()
     │    ├─ Call nftban_health_fix_permissions()
     │    ├─ Call nftban_health_fix_system_config()
     │    ├─ Call nftban_health_fix_services()
     │    └─ Re-run checks to verify fixes
     └─ Return overall status
           ↓
cmd_health.sh renders results
```

### Timer Consolidation Strategy

**BEFORE (Duplicate Timers):**
```
nftban-health.timer (daily 03:00) → nftban health fix all
nftban-permissions-audit.timer (weekly Sun 02:00) → nftban permissions check
```

**AFTER (Single Consolidated Timer):**
```
nftban-health.timer (daily 03:00) → nftban health check --auto-heal --quiet
```

**Rationale:**
- `health check --auto-heal` includes permission checks AND fixes
- Daily execution catches issues faster than weekly
- Eliminates redundancy
- Simpler maintenance

---

## 🚀 Implementation Steps

### ✅ Step 1: Implement --auto-heal Flag Parsing (COMPLETED)

**File:** `src/usr/lib/nftban/cli/cmd_health.sh:88-143`

**Status:** ✅ DONE

**Changes Made:**
- Added `local auto_heal=0` and `local quiet=0` variables
- Added argument parsing loop for `--auto-heal` and `--quiet`
- Pass `$auto_heal` parameter to `nftban_health_check_all()`
- Show "Auto-heal: ENABLED" message when flag is used
- Support quiet mode for timer/cron usage

**Verification:**
```bash
# Test flag parsing (should not error)
nftban health check --auto-heal 2>&1 | grep -q "Auto-heal: ENABLED"
```

---

### 🔄 Step 2: Add Auto-Heal Logic to Health Check Function

**File:** `src/usr/lib/nftban/core/nftban_health.sh:531-670`

**Status:** ⏳ PENDING

**Function Signature Change:**
```bash
# BEFORE:
nftban_health_check_all() {
    # Run all health checks
    # Returns: 0=Healthy, 1=Warnings, 2=Errors, 3=Critical

# AFTER:
nftban_health_check_all() {
    # Run all health checks (ORCHESTRATES existing report modules!)
    # Args: $1 = auto_heal (0=check only, 1=auto-fix issues)
    # Returns: 0=Healthy, 1=Warnings, 2=Errors, 3=Critical

    local auto_heal="${1:-0}"
```

**Logic to Add (after line 669, before `return $overall_status`):**
```bash
    # =========================================================================
    # AUTO-HEAL EXECUTION (if enabled and issues found)
    # =========================================================================

    if [[ $auto_heal -eq 1 ]] && [[ $overall_status -gt $HEALTH_OK ]]; then
        echo ""
        echo "═══════════════════════════════════════════════════════════"
        echo "  Auto-Heal Activated"
        echo "═══════════════════════════════════════════════════════════"
        echo ""

        # Check user has permissions (root required for chown/chmod)
        if [[ $EUID -ne 0 ]]; then
            echo "⚠️  Auto-heal requires root privileges" >&2
            echo "   Run: sudo nftban health check --auto-heal" >&2
            return 2
        fi

        # Log auto-heal start
        if declare -f perms_log_audit >/dev/null 2>&1; then
            perms_log_audit "Auto-heal started by ${SUDO_USER:-root}"
        fi

        # Execute fix functions
        local fixes_applied=0

        if [[ ${#NFTBAN_HEALTH_ERRORS[@]} -gt 0 ]] || [[ ${#NFTBAN_HEALTH_WARNINGS[@]} -gt 0 ]]; then
            echo "→ Fixing directories..."
            nftban_health_fix_directories && ((fixes_applied++))

            echo "→ Fixing permissions..."
            nftban_health_fix_permissions && ((fixes_applied++))

            echo "→ Fixing system config..."
            nftban_health_fix_system_config && ((fixes_applied++))

            echo "→ Fixing services..."
            nftban_health_fix_services && ((fixes_applied++))

            echo ""
            echo "✅ Auto-heal complete ($fixes_applied fixes applied)"
            echo ""

            # Log auto-heal completion
            if declare -f perms_log_audit >/dev/null 2>&1; then
                perms_log_audit "Auto-heal completed: $fixes_applied fixes applied"
            fi

            # Re-run checks to verify fixes worked
            echo "→ Re-checking system health..."
            echo ""

            # Clear previous results
            overall_status=$HEALTH_OK
            NFTBAN_HEALTH_ERRORS=()
            NFTBAN_HEALTH_WARNINGS=()
            declare -gA NFTBAN_HEALTH_RESULTS=()
            declare -gA NFTBAN_HEALTH_ISSUES=()

            # Re-check (without auto-heal to avoid infinite loop)
            nftban_health_check_all 0 || overall_status=$?
        fi
    fi

    return $overall_status
}
```

**Verification:**
```bash
# Create test issue
sudo chmod 777 /etc/nftban

# Run auto-heal
sudo nftban health check --auto-heal

# Expected output:
# ═══════════════════════════════════════════════════════════
#   Auto-Heal Activated
# ═══════════════════════════════════════════════════════════
# → Fixing permissions...
# ✅ Auto-heal complete (1 fixes applied)
```

---

### 🔄 Step 3: Consolidate Duplicate Timers

**Status:** ⏳ PENDING

#### 3a. Remove Permissions Audit Timer Files

**Files to DELETE:**
- `src/usr/lib/systemd/system/nftban-permissions-audit.timer`
- `src/usr/lib/systemd/system/nftban-permissions-audit.service`

#### 3b. Update Health Timer Service

**File:** `src/usr/lib/systemd/system/nftban-health.service`

**Current:**
```ini
[Service]
Type=oneshot
User=nftban
Group=nftban
ExecStart=/usr/sbin/nftban health fix all
```

**New:**
```ini
[Service]
Type=oneshot
User=root
Group=root
ExecStart=/usr/sbin/nftban health check --auto-heal --quiet
```

**Changes:**
- User: `nftban` → `root` (needed for chown/chmod)
- Command: `health fix all` → `health check --auto-heal --quiet`
- Added `--quiet` flag to minimize log noise

#### 3c. Update Health Timer Description

**File:** `src/usr/lib/systemd/system/nftban-health.timer`

**Update Description:**
```ini
[Unit]
Description=NFTBan Daily Health Check Timer (with Auto-Heal)
Documentation=man:nftban(8) https://nftban.com
```

**Verification:**
```bash
# After deployment
systemctl daemon-reload
systemctl list-units 'nftban-*' --all

# Should see:
# nftban-health.timer         loaded active waiting
# nftban-health.service       loaded inactive dead

# Should NOT see:
# nftban-permissions-audit.*  (should not exist)
```

---

### 🔄 Step 4: Add Audit Logging Integration

**Status:** ⏳ PENDING

**File:** `src/usr/lib/nftban/core/nftban_health.sh`

**Changes Needed:**

1. **In `nftban_health_fix_permissions()` (line 676):**
```bash
# Before line 690
if [[ -f "/usr/lib/nftban/core/nftban_permissions.sh" ]]; then
    if source /usr/lib/nftban/core/nftban_permissions.sh 2>/dev/null; then
        # ADD THIS:
        if declare -f perms_log_audit >/dev/null 2>&1; then
            perms_log_audit "Health auto-fix: Starting permission enforcement"
        fi

        echo "  Using enhanced permission enforcement module"
        nftban_permissions_enforce_all
        return $?
    fi
fi
```

2. **In `nftban_health_fix_directories()` (line 823):**
```bash
# After successfully creating directory (line 876)
if mkdir -p "$dir" 2>/dev/null; then
    # ... existing code ...
    echo "  ✓ Created $dir (${perms} ${owner}:${group})"
    ((fixed_count++))

    # ADD THIS:
    if declare -f perms_log_audit >/dev/null 2>&1; then
        perms_log_audit "Health auto-fix: Created directory $dir ($perms $owner:$group)"
    fi
else
```

**Verification:**
```bash
# Run auto-heal
sudo nftban health check --auto-heal

# Check audit log
cat /var/lib/nftban/permissions_audit.log | tail -20

# Expected format:
# [2025-11-01 15:30:45] [root] Health auto-fix: Starting permission enforcement
# [2025-11-01 15:30:45] [root] Health auto-fix: Created directory /var/lib/nftban/exports (750 nftban:nftban)
```

---

### 🔄 Step 5: Update RPM Spec

**Status:** ⏳ PENDING

**File:** `packaging/rpm/nftban.spec`

**Changes:**

1. **Remove from %post section (line ~217):**
```bash
# DELETE THIS LINE:
systemctl enable --now nftban-permissions-audit.timer 2>/dev/null || true
```

2. **Update %post message (line ~217):**
```bash
# CHANGE FROM:
echo "  3. Enable NFTBan timers:"
echo "     systemctl enable --now nftban-health.timer"

# TO:
echo "  3. Enable NFTBan health timer (includes auto-heal):"
echo "     systemctl enable --now nftban-health.timer"
```

3. **Remove from %preun section (line ~225):**
```bash
# CHANGE FROM:
%systemd_preun nftban.timer nftban-health.timer nftban-permissions-audit.timer

# TO:
%systemd_preun nftban.timer nftban-health.timer
```

4. **Remove from %postun section (line ~228):**
```bash
# CHANGE FROM:
%systemd_postun_with_restart nftban.timer nftban-health.timer nftban-permissions-audit.timer

# TO:
%systemd_postun_with_restart nftban.timer nftban-health.timer
```

5. **Verify %files section (line ~294):**
```bash
# Should include:
%{_unitdir}/*.service
%{_unitdir}/*.timer

# This wildcard pattern will automatically:
# - Include: nftban-health.timer, nftban-health.service
# - Exclude: nftban-permissions-audit.* (deleted files)
```

**Verification:**
```bash
# Build RPM
./scripts/build-rpm.sh

# Check contents
rpm -qpl dist/nftban-0.10.0-*.rpm | grep timer

# Expected output:
# /usr/lib/systemd/system/nftban.timer
# /usr/lib/systemd/system/nftban-health.timer

# Should NOT include:
# nftban-permissions-audit.timer
```

---

### 📝 Step 6: Update Documentation

**Status:** ⏳ PENDING

#### 6a. Update Help Text

**File:** `src/usr/lib/nftban/cli/cmd_health.sh:528-612`

**Add to COMMANDS section (after line 536):**
```
    check [--auto-heal] [--quiet]
                            Run comprehensive health check
                            --auto-heal: Automatically fix detected issues (requires root)
                            --quiet: Minimal output (for cron/timer use)
```

**Add to EXAMPLES section (after line 571):**
```
    # Auto-heal during check (combines check + fix)
    sudo nftban health check --auto-heal

    # Quiet mode for cron/timer
    nftban health check --auto-heal --quiet
```

#### 6b. Update HEALTH_CHECK_SYSTEM.md

**File:** `docs/HEALTH_CHECK_SYSTEM.md`

**Add new section after line 217:**
```markdown
### Auto-Heal Mode

```bash
# Run health check with automatic fixing
sudo nftban health check --auto-heal

# Output:
Running NFTBan system health check...
Auto-heal: ENABLED

... (health checks run) ...

═══════════════════════════════════════════════════════════
  Auto-Heal Activated
═══════════════════════════════════════════════════════════

→ Fixing directories...
  ✓ Created /var/lib/nftban/exports (750 nftban:nftban)

→ Fixing permissions...
  ✓ Fixed /etc/nftban → 750 root:nftban

→ Fixing system config...
  ✓ Updated /var/lib/nftban/config/system.conf

→ Fixing services...
  ✓ All services already running

✅ Auto-heal complete (3 fixes applied)

→ Re-checking system health...

... (verification checks run) ...

Overall Status: ✅ OK
```

**Requirements:**
- Must run as root (requires chown/chmod privileges)
- Logs all fixes to `/var/lib/nftban/permissions_audit.log`
- Re-checks system after fixes to verify success
- Use `--quiet` flag for cron/timer usage
```

#### 6c. Update auto-heal-implementation.md

**File:** `docs/guides/auto-heal-implementation.md`

**Update "What Was IMPLEMENTED" section (line 28):**
```markdown
### 2. Enhanced Auto-Heal Functions
**Files:**
- `/usr/lib/nftban/core/nftban_health.sh` - Core auto-heal logic
- `/usr/lib/nftban/cli/cmd_health.sh` - CLI flag parsing

**Implementation:**
- ✅ `--auto-heal` flag parsing in CLI handler
- ✅ Auto-heal logic in `nftban_health_check_all()`
- ✅ Permission checking (root required)
- ✅ Audit logging integration
- ✅ Post-fix verification (re-check)

**Usage:**
```bash
# Manual auto-heal
sudo nftban health check --auto-heal

# Timer auto-heal (daily at 03:00)
systemctl enable --now nftban-health.timer
```
```

**Update "Timer Consolidation" section (line 200):**
```markdown
### Timer Schedule

```
Timer: nftban-health.timer
├─ Runs: Daily at 03:00 AM
├─ Random delay: 0-30 minutes
├─ Persistent: Yes (catches up after downtime)
├─ Service: nftban-health.service
└─ Command: nftban health check --auto-heal --quiet
```

**CONSOLIDATION:**
- ❌ REMOVED: `nftban-permissions-audit.timer` (redundant)
- ✅ KEPT: `nftban-health.timer` (includes permission checks)

**Rationale:**
- `health check --auto-heal` includes ALL fixes (directories, permissions, services, config)
- Daily execution catches issues faster than weekly
- Eliminates duplicate timer maintenance
- Simpler for users to understand
```

---

## 🧪 Testing Plan

### Test 1: Manual Auto-Heal (Root)

```bash
# Setup: Create test issue
sudo chmod 777 /etc/nftban

# Execute: Run auto-heal
sudo nftban health check --auto-heal

# Verify:
# - "Auto-heal: ENABLED" message shown
# - "Auto-Heal Activated" section shown
# - Permission fix messages appear
# - "Auto-heal complete" message shown
# - Re-check runs automatically
# - /etc/nftban permissions restored to 750

# Check audit log
tail -5 /var/lib/nftban/permissions_audit.log
# Expected: Log entry for permission fix
```

**Expected Output:**
```
Running NFTBan system health check...
Auto-heal: ENABLED

... checks ...

═══════════════════════════════════════════════════════════
  Auto-Heal Activated
═══════════════════════════════════════════════════════════

→ Fixing permissions...
  ✓ Fixed /etc/nftban → 750 root:nftban

✅ Auto-heal complete (1 fixes applied)

→ Re-checking system health...

Overall Status: ✅ OK
```

### Test 2: Manual Auto-Heal (Non-root)

```bash
# Execute: Run as regular user
nftban health check --auto-heal

# Verify:
# - Error message: "Auto-heal requires root privileges"
# - Suggests: "Run: sudo nftban health check --auto-heal"
# - Exit code: 2
```

**Expected Output:**
```
Running NFTBan system health check...
Auto-heal: ENABLED

... checks ...

⚠️  Auto-heal requires root privileges
   Run: sudo nftban health check --auto-heal
```

### Test 3: Timer-Based Auto-Heal

```bash
# Setup: Enable timer
sudo systemctl enable --now nftban-health.timer

# Verify timer is active
systemctl list-timers nftban-health.timer

# Expected:
# NEXT                        LEFT     LAST PASSED UNIT
# Sat 2025-11-02 03:15:22 UTC 11h left -    -      nftban-health.timer

# Manually trigger service
sudo systemctl start nftban-health.service

# Check logs
journalctl -u nftban-health.service -n 50 --no-pager

# Verify:
# - Service ran successfully
# - Auto-heal logic executed
# - Fixes applied (if issues found)
# - No errors in logs
```

### Test 4: Quiet Mode

```bash
# Execute: Run with --quiet
sudo nftban health check --auto-heal --quiet

# Verify:
# - Minimal output
# - Only shows summary if issues found
# - No detailed check messages
# - Auto-heal still runs
```

**Expected Output (no issues):**
```
(no output - silent success)
```

**Expected Output (issues found):**
```
Health: WARNING (auto-healed 2 issues)
```

### Test 5: Audit Log Verification

```bash
# Run auto-heal multiple times
sudo nftban health check --auto-heal

# Check audit log
cat /var/lib/nftban/permissions_audit.log

# Verify:
# - Timestamps for each run
# - User attribution (root or SUDO_USER)
# - Detailed fix descriptions
# - No duplicate entries
```

**Expected Format:**
```
[2025-11-01 15:30:45] [root] Auto-heal started by antonis
[2025-11-01 15:30:45] [root] Health auto-fix: Starting permission enforcement
[2025-11-01 15:30:46] [root] Health auto-fix: Fixed /etc/nftban permissions to 750
[2025-11-01 15:30:46] [root] Auto-heal completed: 1 fixes applied
```

### Test 6: RPM Package Verification

```bash
# Build RPM
./scripts/build-rpm.sh

# Install on clean system
sudo rpm -i dist/nftban-0.10.0-*.rpm

# Verify:
# 1. nftban-health.timer exists and is enabled
systemctl status nftban-health.timer

# 2. nftban-permissions-audit.timer does NOT exist
systemctl status nftban-permissions-audit.timer
# Expected: "Unit nftban-permissions-audit.timer could not be found"

# 3. Health check works
nftban health check

# 4. Auto-heal works
sudo nftban health check --auto-heal

# 5. Timer will run tonight
systemctl list-timers nftban-health.timer
```

---

## 📊 Acceptance Criteria

### Must Have (P0)

- [ ] `nftban health check --auto-heal` actually fixes issues
- [ ] Root permission checking works correctly
- [ ] Non-root users see helpful error message
- [ ] Auto-heal shows progress messages during execution
- [ ] Post-fix verification runs automatically
- [ ] Audit logging captures all fixes
- [ ] `--quiet` flag suppresses verbose output
- [ ] Timer consolidation complete (only 1 timer)
- [ ] Timer service uses `--auto-heal --quiet`
- [ ] RPM spec updated (no references to old timer)
- [ ] Help text documents `--auto-heal` flag
- [ ] All tests pass

### Should Have (P1)

- [ ] Documentation updated (HEALTH_CHECK_SYSTEM.md)
- [ ] Documentation updated (auto-heal-implementation.md)
- [ ] Example outputs in documentation
- [ ] Troubleshooting guide

### Nice to Have (P2)

- [ ] Performance metrics for auto-heal
- [ ] Success/failure statistics
- [ ] Email notifications on failures

---

## 🚧 Implementation Tracking

| Step | Description | Status | Files Changed |
|------|-------------|--------|---------------|
| 1 | Flag parsing | ✅ DONE | `cmd_health.sh` |
| 2 | Auto-heal logic | ⏳ PENDING | `nftban_health.sh` |
| 3 | Timer consolidation | ⏳ PENDING | systemd units |
| 4 | Audit logging | ⏳ PENDING | `nftban_health.sh` |
| 5 | RPM spec update | ⏳ PENDING | `nftban.spec` |
| 6 | Documentation | ⏳ PENDING | Multiple docs |
| 7 | Testing | ⏳ PENDING | Manual + automated |

---

## 📁 Files to Modify

### Core Implementation
- ✅ `src/usr/lib/nftban/cli/cmd_health.sh` (Step 1 complete)
- ⏳ `src/usr/lib/nftban/core/nftban_health.sh` (Step 2)

### Systemd Units
- ⏳ DELETE: `src/usr/lib/systemd/system/nftban-permissions-audit.timer` (Step 3)
- ⏳ DELETE: `src/usr/lib/systemd/system/nftban-permissions-audit.service` (Step 3)
- ⏳ MODIFY: `src/usr/lib/systemd/system/nftban-health.service` (Step 3)
- ⏳ MODIFY: `src/usr/lib/systemd/system/nftban-health.timer` (Step 3)

### Packaging
- ⏳ `packaging/rpm/nftban.spec` (Step 5)

### Documentation
- ⏳ `docs/HEALTH_CHECK_SYSTEM.md` (Step 6)
- ⏳ `docs/guides/auto-heal-implementation.md` (Step 6)
- ⏳ `docs/TODO.md` (Mark BUG-NEW-005 as fixed)

---

## 🔗 Related Issues

- **TODO.md:** Line 50-143 (BUG-NEW-005: Auto-heal Not Implemented)
- **TRACKING.md:** Bug tracking for auto-heal functionality
- **Polkit:** May need extended rules for non-root auto-heal (future)

---

## 📌 Notes

### Design Decisions

1. **Why root-only for auto-heal?**
   - `chown` and `chmod` require root privileges
   - Polkit can't grant these capabilities to regular users safely
   - Simpler security model: root=full fix, non-root=read-only check

2. **Why consolidate timers?**
   - `health check --auto-heal` includes ALL fixes
   - Daily is better than weekly for catching issues
   - Reduces systemd unit file count
   - Easier for users to understand ("one timer does everything")

3. **Why re-check after fixes?**
   - Verifies fixes actually worked
   - Catches cascading issues
   - Provides confidence to users
   - Logs final state for audit

### Future Enhancements

1. **Email Notifications**
   - Send email if auto-heal fails
   - Weekly summary of fixes applied
   - Alert on repeated failures

2. **Dry-Run Mode**
   - `--dry-run` flag to show what would be fixed
   - No actual changes made
   - Useful for testing

3. **Selective Auto-Heal**
   - `--auto-heal=permissions` (only fix permissions)
   - `--auto-heal=directories` (only create dirs)
   - Granular control

---

## ✅ Definition of Done

- [ ] All code changes implemented
- [ ] All tests pass
- [ ] Documentation updated
- [ ] RPM builds successfully
- [ ] Deployed to lab servers
- [ ] Tested on lab servers
- [ ] Git commit with proper message
- [ ] TODO.md updated (BUG-NEW-005 marked complete)

---

**Status:** 🟡 IN PROGRESS - Step 1 complete, Steps 2-6 pending
**Next Action:** Implement Step 2 (Auto-heal logic in health check function)
**Blocker:** None
**ETA:** 6-8 hours remaining (8 hours total, 1 hour spent)

**EOF**
