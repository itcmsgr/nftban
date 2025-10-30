# NFTBan v0.10.0 - Unified Reporting Proposal
**Date:** 2025-10-30
**Status:** 🔴 PROPOSAL - Awaiting Approval
**Priority:** HIGH

---

## 🎯 Problem Statement

Currently we have **DUPLICATION** and **CONFUSION** across reporting commands:

### Current Situation (PROBLEMS):

```bash
nftban module              # Shows module inventory
nftban fhs                 # Shows FHS compliance
nftban services            # Shows service status

nftban health check        # ❌ DUPLICATES above + returns wrong exit code!
nftban health services     # Same as 'nftban services' but different format
nftban health modules      # Same as checking modules
nftban health permissions  # Same as FHS permissions check
```

### Issues Identified:

1. **❌ DUPLICATION:** `health services` vs `services`, `health modules` vs `module`
2. **❌ WRONG EXIT CODES:** `nftban health check` returns 0 even with warnings (should return 1)
3. **❌ NO REPORT MECHANISM:** No way to save output to file or email daily reports
4. **❌ INCONSISTENT FORMATS:** Health uses different format than module/fhs/services
5. **❌ MISSING SHORT VERSION:** No quick "ok/not ok" summary for scripts
6. **❌ NO DETAIL LEVELS:** Can't choose summary vs detailed output

---

## ✅ PROPOSAL: Unified Smart Reporting System

### Core Philosophy:

**ONE TRUTH - Multiple Views**

- **Single source** for each type of check (module, fhs, services, etc.)
- **Multiple output formats** (summary, detailed, json, html, email)
- **Proper exit codes** for automation
- **Save to file** capability
- **Email reports** mechanism

---

## 🏗️ Proposed Architecture

### Level 1: Core Report Modules (Data Collection)

These **ONLY** collect data, no duplication:

```
/usr/lib/nftban/core/
├── nftban_report_module.sh      ✅ EXISTS - Module inventory
├── nftban_report_fhs.sh          ✅ EXISTS - FHS compliance
├── nftban_report_services.sh     ✅ EXISTS - Services status
└── nftban_report_health.sh       🆕 NEW - Orchestrates all above
```

### Level 2: CLI Commands (User Interface)

Smart commands with **detail levels**:

```bash
# Individual Reports (detailed by default)
nftban module [summary|detailed|json]
nftban fhs [summary|detailed|json]
nftban services [summary|detailed|json]

# Unified Health (orchestrates all)
nftban health [summary|detailed|json]
  ↳ Calls: module + fhs + services + permissions + binaries
```

### Level 3: Report Output (Save/Email)

```bash
# Save to file
nftban report generate [--output FILE] [--format json|html]

# Email report
nftban report email [--to EMAIL] [--daily|weekly]

# Schedule daily
nftban report schedule daily
```

---

## 📋 Detailed Design

### 1. Output Levels

Every command supports 3 levels:

#### A) **summary** (Quick, scriptable)
```bash
$ nftban module summary
Modules: 23 OK, 0 errors

$ nftban fhs summary
FHS: 5 OK, 12 errors, 3 missing

$ nftban services summary
Services: 2/2 running, 4/4 tools

$ nftban health summary
Health: WARNING (2 warnings, 0 errors)
```

**Exit codes:**
- 0 = All OK
- 1 = Warnings
- 2 = Errors
- 3 = Critical

#### B) **detailed** (Current FHS-style table - DEFAULT)
```bash
$ nftban module          # Shows full table (current behavior)
$ nftban module detailed # Same as above
```

#### C) **json** (Machine readable)
```bash
$ nftban module json
{
  "timestamp": "2025-10-30T05:30:00+00:00",
  "total": 23,
  "enabled": 23,
  "disabled": 0,
  "modules": [...]
}
```

---

### 2. Unified Health Check (Smart Orchestrator)

```bash
nftban health [summary|detailed|json]
```

**What it does:**
1. Calls `nftban_report_module.sh` (module check)
2. Calls `nftban_report_fhs.sh` (FHS check)
3. Calls `nftban_report_services.sh` (services check)
4. Calls `nftban_report_permissions.sh` (permissions - new)
5. Calls `nftban_report_binaries.sh` (binaries - new)
6. **Aggregates** results
7. Returns **highest severity** exit code

**Example summary output:**
```bash
$ nftban health summary
══════════════════════════════════════════════
 NFTBan System Health - 2025-10-30 05:30:00
══════════════════════════════════════════════
✅ Modules:      23 OK, 0 errors
⚠️  FHS:          5 OK, 12 errors, 3 missing
✅ Services:     2/2 running, 4/4 tools
✅ Permissions:  All correct
⚠️  Binaries:     git missing (optional)

Overall: ⚠️  WARNING (2 warnings)
══════════════════════════════════════════════
Exit code: 1
```

**Example detailed output:**
```bash
$ nftban health detailed
# Shows full tables from:
#   - nftban module (full table)
#   - nftban fhs (full table)
#   - nftban services (full table)
#   - Binary checks
#   - Permission checks
```

---

### 3. Report Generation & Email

#### New command: `nftban report`

```bash
# Generate report to file
nftban report generate --output /tmp/nftban-report.html --format html

# Email report
nftban report email --to admin@example.com --subject "Daily Health"

# Schedule daily report
nftban report schedule daily --email admin@example.com --format html

# List scheduled reports
nftban report list

# Disable scheduled report
nftban report unschedule daily
```

**Report includes:**
- Timestamp
- All health checks (module, fhs, services, permissions, binaries)
- Summary at top
- Detailed tables below
- Warnings/Errors highlighted
- Exit code

**Formats:**
- **HTML** - Email-friendly with CSS
- **JSON** - Machine readable
- **Markdown** - Documentation
- **Terminal** - ANSI colors

---

## 🔧 Implementation Plan

### Phase 1: Fix Current Issues (IMMEDIATE)

**Priority:** 🔴 CRITICAL

1. **Fix health check exit codes**
   - File: `/usr/lib/nftban/core/nftban_health.sh`
   - Problem: Returns 0 with warnings
   - Fix: Return proper exit code (0=OK, 1=Warning, 2=Error, 3=Critical)

2. **Add summary mode to existing commands**
   - `nftban module summary`
   - `nftban fhs summary`
   - `nftban services summary`

### Phase 2: Unify Health Command (MEDIUM)

1. **Refactor `nftban health`** to orchestrate existing reports
2. Remove duplicated check functions
3. Make it call: module + fhs + services + new checks
4. Add summary/detailed/json modes

### Phase 3: Report Mechanism (LATER)

1. Create `nftban_report_engine.sh`
2. Add file output support
3. Add email support
4. Add scheduling (cron integration)

---

## 📊 Comparison: Before vs After

### BEFORE (Current - Confusing):

```bash
nftban module                  # Module check
nftban health modules          # ❌ DUPLICATE - Same check, different format

nftban fhs                     # FHS check
nftban health permissions      # ❌ DUPLICATE - Subset of FHS

nftban services                # Services check
nftban health services         # ❌ DUPLICATE - Same check

nftban health check            # All checks but wrong exit code ❌
```

### AFTER (Proposed - Clean):

```bash
# Individual detailed reports (FHS-style tables)
nftban module [summary|detailed|json]
nftban fhs [summary|detailed|json]
nftban services [summary|detailed|json]

# Unified health (orchestrates all)
nftban health summary          # Quick: "WARNING (2 warnings)"
nftban health detailed         # Full: All tables combined
nftban health json             # Machine: JSON output

# NEW: Report mechanism
nftban report generate --output report.html
nftban report email --to admin@domain.com
nftban report schedule daily
```

**Result:**
- ✅ No duplication
- ✅ Consistent formats
- ✅ Proper exit codes
- ✅ Multiple detail levels
- ✅ Save to file
- ✅ Email capability

---

## 💾 Report File Examples

### Daily Health Report (HTML):

```html
<!DOCTYPE html>
<html>
<head>
    <title>NFTBan Health Report - 2025-10-30</title>
    <style>
        .ok { color: green; }
        .warning { color: orange; }
        .error { color: red; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #ddd; padding: 8px; text-align: left; }
    </style>
</head>
<body>
    <h1>NFTBan System Health Report</h1>
    <p>Generated: 2025-10-30 05:30:00</p>
    <p>Server: lab.example.test</p>

    <h2 class="warning">Overall Status: WARNING (2 warnings)</h2>

    <h3>Summary</h3>
    <ul>
        <li class="ok">✅ Modules: 23 OK, 0 errors</li>
        <li class="error">⚠️ FHS: 5 OK, 12 errors, 3 missing</li>
        <li class="ok">✅ Services: 2/2 running, 4/4 tools</li>
        <li class="warning">⚠️ Binaries: git missing (optional)</li>
    </ul>

    <h3>Detailed Module Inventory</h3>
    <table>
        <!-- Full module table -->
    </table>

    <h3>Detailed FHS Compliance</h3>
    <table>
        <!-- Full FHS table -->
    </table>

    <h3>Detailed Services Status</h3>
    <table>
        <!-- Full services table -->
    </table>
</body>
</html>
```

### Daily Health Report (JSON):

```json
{
  "timestamp": "2025-10-30T05:30:00+00:00",
  "server": "lab.example.test",
  "overall_status": "warning",
  "exit_code": 1,
  "summary": {
    "modules": {"ok": 23, "errors": 0},
    "fhs": {"ok": 5, "errors": 12, "missing": 3},
    "services": {"running": 2, "total": 2, "tools_installed": 4, "tools_total": 4},
    "binaries": {"ok": 5, "missing": ["git"]}
  },
  "detailed": {
    "modules": [...],
    "fhs": [...],
    "services": [...],
    "binaries": [...]
  },
  "warnings": [
    "FHS: 12 directories have permission/ownership issues",
    "Binaries: git not installed (optional)"
  ],
  "errors": []
}
```

---

## 🔀 Migration Path

### For Users:

**Old commands still work** (backward compatible):

```bash
nftban module              # Still works (detailed mode)
nftban fhs                 # Still works (detailed mode)
nftban services            # Still works (detailed mode)
nftban health check        # Still works (but now with correct exit codes)
```

**New capabilities added:**

```bash
nftban module summary      # NEW: Quick summary
nftban health summary      # NEW: Unified quick check
nftban report generate     # NEW: Save to file
nftban report email        # NEW: Email reports
```

**Deprecated (show warning, redirect):**

```bash
nftban health modules      # DEPRECATED: Use 'nftban module'
nftban health services     # DEPRECATED: Use 'nftban services'
nftban health permissions  # DEPRECATED: Use 'nftban fhs'
```

---

## 📝 File Changes Required

### Files to Modify:

1. **`/usr/lib/nftban/core/nftban_health.sh`**
   - Fix exit code bug
   - Make it orchestrate other reports
   - Remove duplicate check code

2. **`/usr/lib/nftban/core/nftban_report_module.sh`**
   - Add summary mode
   - Add json mode

3. **`/usr/lib/nftban/core/nftban_report_fhs.sh`**
   - Add summary mode
   - Add json mode

4. **`/usr/lib/nftban/core/nftban_report_services.sh`**
   - Add summary mode
   - Add json mode

### Files to Create:

5. **`/usr/lib/nftban/core/nftban_report_engine.sh`** (NEW)
   - Handle file output
   - Handle HTML generation
   - Handle JSON generation
   - Handle email sending

6. **`/usr/lib/nftban/cli/cmd_report.sh`** (NEW)
   - `report generate`
   - `report email`
   - `report schedule`

---

## ✅ Benefits of This Approach

1. **✅ No Duplication** - Single source of truth for each check
2. **✅ Consistent** - All commands follow same pattern
3. **✅ Flexible** - Choose detail level (summary/detailed/json)
4. **✅ Scriptable** - Proper exit codes
5. **✅ Auditable** - Save reports to files
6. **✅ Automated** - Schedule daily/weekly emails
7. **✅ Backward Compatible** - Old commands still work
8. **✅ Extensible** - Easy to add new checks

---

## 🎯 Next Steps

### Decision Required:

**Do you approve this unified approach?**

If YES, implement in this order:

1. ✅ **Phase 1** (IMMEDIATE): Fix health exit codes + add summary modes
2. ✅ **Phase 2** (MEDIUM): Refactor health to orchestrate
3. ✅ **Phase 3** (LATER): Add report mechanism

If NO, please provide feedback on:
- Which parts you want different
- Which features to prioritize
- Alternative approaches

---

## 📞 Questions for Clarification

1. **Email system**: Should we use existing `nftban_mail.sh` or create separate report mailer?
2. **Scheduling**: Integrate with systemd timers or use cron?
3. **Report storage**: Where to save reports? `/var/lib/nftban/reports/`?
4. **Retention**: How many days to keep old reports?
5. **Format priority**: Which format is most important? (HTML/JSON/Markdown)

---

**Status:** 🔴 AWAITING APPROVAL
**Author:** Claude Code
**Date:** 2025-10-30

**EOF**
