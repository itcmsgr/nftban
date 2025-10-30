# Current vs Proposed: Quick Comparison

## 🔴 CURRENT (Problems)

```
┌─────────────────────────────────────────────────────────────┐
│  DUPLICATION & CONFUSION                                    │
└─────────────────────────────────────────────────────────────┘

nftban module             →  Module inventory (FHS-style table)
nftban health modules     →  ❌ DUPLICATE! Same data, different format

nftban fhs                →  FHS compliance (FHS-style table)
nftban health permissions →  ❌ DUPLICATE! Subset of FHS

nftban services           →  Services status (FHS-style table)
nftban health services    →  ❌ DUPLICATE! Same data

nftban health check       →  ❌ WRONG EXIT CODE! Returns 0 with warnings
                             ❌ NO DETAIL LEVELS! Only one output
                             ❌ NO SAVE TO FILE!
                             ❌ NO EMAIL REPORTS!
```

---

## ✅ PROPOSED (Clean & Smart)

```
┌─────────────────────────────────────────────────────────────┐
│  UNIFIED & CONSISTENT                                       │
└─────────────────────────────────────────────────────────────┘

╔═══════════════════════════════════════════════════════════════╗
║  INDIVIDUAL REPORTS (Detailed by default)                    ║
╚═══════════════════════════════════════════════════════════════╝

nftban module [summary|detailed|json]
├─ summary:   "Modules: 23 OK, 0 errors"
├─ detailed:  Full FHS-style table (current behavior)
└─ json:      {"total": 23, "enabled": 23, ...}

nftban fhs [summary|detailed|json]
├─ summary:   "FHS: 5 OK, 12 errors, 3 missing"
├─ detailed:  Full FHS-style table (current behavior)
└─ json:      {"ok": 5, "errors": 12, ...}

nftban services [summary|detailed|json]
├─ summary:   "Services: 2/2 running, 4/4 tools"
├─ detailed:  Full FHS-style table (current behavior)
└─ json:      {"systemd": {...}, "binaries": {...}}

╔═══════════════════════════════════════════════════════════════╗
║  UNIFIED HEALTH (Orchestrates all above)                     ║
╚═══════════════════════════════════════════════════════════════╝

nftban health [summary|detailed|json]
├─ summary:   Quick status of ALL checks
│             ✅ Modules: 23 OK
│             ⚠️  FHS: 12 errors
│             ✅ Services: 2/2 running
│             Overall: ⚠️ WARNING (exit 1)
│
├─ detailed:  ALL full tables combined
│             (module table + fhs table + services table)
│
└─ json:      Complete JSON with all data

╔═══════════════════════════════════════════════════════════════╗
║  REPORT MECHANISM (NEW)                                       ║
╚═══════════════════════════════════════════════════════════════╝

nftban report generate --output report.html --format html
nftban report email --to admin@example.com
nftban report schedule daily --email admin@example.com
```

---

## 📊 Exit Codes

### CURRENT (BROKEN):

```bash
$ nftban health check
# Shows: "⚠️ HEALTHY (2 warnings)"
# Returns: 0  ❌ WRONG! Should return 1
```

### PROPOSED (FIXED):

```bash
$ nftban health summary
# Shows: "⚠️ WARNING (2 warnings)"
# Returns: 1  ✅ CORRECT!

Exit Codes:
  0 = All OK
  1 = Warnings (optional stuff missing)
  2 = Errors (required stuff broken)
  3 = Critical (system unusable)
```

---

## 🎯 Use Cases

### Use Case 1: Quick Script Check

**CURRENT (Wrong):**
```bash
if nftban health check; then
    echo "OK"
else
    echo "Problem"
fi
# ❌ WRONG: Returns OK even with warnings!
```

**PROPOSED (Correct):**
```bash
if nftban health summary; then
    echo "All OK"
else
    echo "Issues detected (exit code: $?)"
fi
# ✅ CORRECT: Returns proper exit code
```

### Use Case 2: Daily Email Report

**CURRENT:**
```bash
# ❌ NOT POSSIBLE
```

**PROPOSED:**
```bash
# ✅ EASY:
nftban report email --to admin@example.com

# Or schedule it:
nftban report schedule daily --email admin@example.com
```

### Use Case 3: Monitoring Dashboard

**CURRENT:**
```bash
# Need to parse verbose output
nftban module | grep "Total"
nftban fhs | grep "Total"
nftban services | grep "Services"
# ❌ MESSY
```

**PROPOSED:**
```bash
# Clean summary mode or JSON
nftban health summary
# Output: "WARNING (2 warnings)" + exit 1

# Or JSON for parsing:
nftban health json | jq '.overall_status'
# Output: "warning"
```

---

## 📁 File Structure Comparison

### CURRENT:

```
Duplicate checks spread across:
- nftban_health.sh (has its own module/service/permission checks)
- nftban_report_module.sh (module inventory)
- nftban_report_fhs.sh (FHS compliance)
- nftban_report_services.sh (service status)

❌ Problem: Same check done in multiple places!
```

### PROPOSED:

```
Single source of truth:
- nftban_report_module.sh (ONLY source for module data)
- nftban_report_fhs.sh (ONLY source for FHS data)
- nftban_report_services.sh (ONLY source for service data)
- nftban_health.sh (orchestrates all above, NO duplicate checks)
- nftban_report_engine.sh (NEW: handles output/email)

✅ Solution: Each check exists ONCE, health orchestrates!
```

---

## 🔄 Migration

### Backward Compatibility:

```bash
# Old commands STILL WORK:
nftban module              ✅ Works (defaults to detailed)
nftban fhs                 ✅ Works (defaults to detailed)
nftban services            ✅ Works (defaults to detailed)
nftban health check        ✅ Works (but fixed exit codes)

# New capabilities:
nftban module summary      🆕 NEW
nftban health summary      🆕 NEW
nftban report generate     🆕 NEW
nftban report email        🆕 NEW

# Deprecated (show warning, redirect):
nftban health modules      ⚠️  DEPRECATED → Use 'nftban module'
nftban health services     ⚠️  DEPRECATED → Use 'nftban services'
```

---

## 🎨 Visual Output Examples

### Summary Mode (NEW):

```bash
$ nftban health summary

══════════════════════════════════════════════
 NFTBan System Health - 2025-10-30 05:30:00
══════════════════════════════════════════════
✅ Modules:      23 OK, 0 errors
⚠️  FHS:          5 OK, 12 errors, 3 missing
✅ Services:     2/2 running, 4/4 tools
⚠️  Binaries:     git missing (optional)

Overall: ⚠️  WARNING (2 warnings)
══════════════════════════════════════════════
Exit code: 1
```

### Detailed Mode (Current behavior):

```bash
$ nftban health detailed

[Shows all full tables:]
- Module inventory table
- FHS compliance table
- Services status table
- Binary checks
- Permission checks
```

### JSON Mode (NEW):

```bash
$ nftban health json | jq .

{
  "overall_status": "warning",
  "exit_code": 1,
  "summary": {
    "modules": {"ok": 23, "errors": 0},
    "fhs": {"ok": 5, "errors": 12, "missing": 3},
    "services": {"running": 2, "total": 2}
  }
}
```

---

**Recommendation:** ✅ APPROVE PROPOSAL

This fixes all identified problems and provides clean, consistent interface!

**EOF**
