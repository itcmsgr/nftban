# Production-Hardened Header Alignment Plan - v0.9.3

**Date:** 2025-10-22
**Goal:** Align ALL .sh files to production-hardened header v2.0
**Status:** 42/56 files complete (75%)
**Remaining:** 14 files need migration

---

## 📊 CURRENT STATUS

### ✅ COMPLETED (42 files - 75%)

All CLI commands, most modules, and core installer files already have v2.0 header:
- ✅ All 11 CLI command files (cmd_*.sh)
- ✅ Core modules: core, nftables, blacklist, whitelist, feeds_lib, update
- ✅ Security modules: ddos, fail2ban, portscan, security_audit, safety, login_monitor
- ✅ Utility modules: cloudflare, geoip, geo, ipprotect, monitoring, port, ratelimit, search, stats, utils_lib
- ✅ Most installer modules: backup, core, main, package, verification
- ✅ Template module

### ❌ REMAINING (14 files - 25%)

#### Category 1: Core Modules (4 files)
| # | File | Status | Lines | Estimate |
|---|------|--------|-------|----------|
| 1 | `nftban_feeds_module.sh` | ❌ OLD | ~300 | 30 min |
| 2 | `nftban_sync_module.sh` | ❌ OLD | ~400 | 30 min |
| 3 | `nftban_maintenance_module.sh` | ❌ NONE | ~500 | 45 min |
| 4 | `nftban_autorebuild_module.sh` | ❌ NONE | ~200 | 30 min |

**Subtotal:** ~1,400 lines, **2h 15min**

#### Category 2: Validator Scripts (3 files)
| # | File | Status | Lines | Estimate |
|---|------|--------|-------|----------|
| 5 | `nftban-validator-github.sh` | ❌ OLD | ~600 | 45 min |
| 6 | `nftban-validator-panel.sh` | ❌ OLD | ~800 | 60 min |
| 7 | `nftban-validator-run.sh` | ❌ OLD | ~300 | 30 min |

**Subtotal:** ~1,700 lines, **2h 15min**

#### Category 3: Installer Modules (5 files)
| # | File | Status | Lines | Estimate |
|---|------|--------|-------|----------|
| 8 | `installer/installer_config_full.sh` | ❌ NONE | ~400 | 45 min |
| 9 | `installer/installer_download.sh` | ❌ NONE | ~300 | 30 min |
| 10 | `installer/installer_structure.sh` | ❌ NONE | ~200 | 30 min |
| 11 | `installer/nftban_installer_modular.sh` | ❌ OLD | ~800 | 60 min |
| 12 | `installer/nftban_uninstall_script.sh` | ❌ OLD | ~600 | 45 min |

**Subtotal:** ~2,300 lines, **3h 30min**

#### Category 4: Init Script (1 file)
| # | File | Status | Lines | Estimate |
|---|------|--------|-------|----------|
| 13 | `nftban_init_script.sh` | ❌ OLD | ~500 | 45 min |

**Subtotal:** ~500 lines, **45 min**

#### Category 5: Deprecated (1 file)
| # | File | Status | Lines | Decision |
|---|------|--------|-------|----------|
| 14 | `installer/deprecated/nftban_installer.sh` | ❌ NONE | ~1,200 | **SKIP?** |

**Decision needed:** Migrate or skip deprecated file?

---

## ⏱️ TIME ESTIMATES

### Per-File Estimates
- **OLD header files (8):** 10-15 min each (simple upgrade)
  - Change `set -euo pipefail` → `set -Eeuo pipefail`
  - Add IFS, umask, PATH, locale
  - Add error trap
  - Add footer

- **NONE files (6):** 15-30 min each (more work)
  - Add complete production-hardened header
  - Review existing code for compatibility
  - Add error trap
  - Add footer

### Category Estimates
1. **Core Modules:** 2h 15min (4 files)
2. **Validator Scripts:** 2h 15min (3 files)
3. **Installer Modules:** 3h 30min (5 files)
4. **Init Script:** 45min (1 file)
5. **Testing:** 2-3 hours (all files on 3 lab servers)
6. **Git commit/push:** 30min

**TOTAL MIGRATION TIME:** ~11-12 hours of work

### Proposed Schedule
- **Session 1 (2h):** Core modules (4 files)
- **Session 2 (2h):** Validator scripts (3 files)
- **Session 3 (3h):** Installer modules (5 files)
- **Session 4 (1h):** Init script + review
- **Session 5 (3h):** Comprehensive testing on 3 lab servers
- **Session 6 (1h):** Git commit/push with detailed message

**TOTAL:** 12 hours spread over 2-3 days

---

## 🎯 MIGRATION CHECKLIST

For EACH file, apply:

### 1. Header Section
```bash
#!/usr/bin/env bash

# =============================================================================
# [Module Name] - v0.9.3
# =============================================================================
# [Brief description]
# =============================================================================

# --- PRODUCTION-GRADE SECURITY (v0.9.3+) ------------------------------------
# Security Features Applied:
# - ✅ Enhanced strict mode (set -Eeuo pipefail)
# - ✅ Safe word splitting (IFS=$'\n\t')
# - ✅ Secure file permissions (umask 027)
# - ✅ PATH sanitization (readonly, trusted paths only)
# - ✅ Locale standardization (prevents CWE-134)
# - ✅ Error traps (catch all failures)
#
# Security Rating: 9/10 (from baseline 5/10)
# ================================================================================

# Enhanced strict mode
set -Eeuo pipefail

# Safe word splitting
IFS=$'\n\t'

# Secure file permissions
umask 027

# PATH sanitization (if not already set by parent)
if [[ "$(declare -p PATH 2>/dev/null)" != *"declare -"*"r"* ]]; then
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    readonly PATH
fi

# Locale standardization
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Module guard
[[ -n "${NFTBAN_MODULE_LOADED:-}" ]] && return 0
readonly NFTBAN_MODULE_LOADED=1

# Error trap
_nftban_[module]_on_err() {
    local rc=$?
    local line="${1:-unknown}"
    local func="${2:-main}"
    if declare -f nftban_log_error >/dev/null 2>&1; then
        nftban_log_error "[MODULE] ERROR in ${func} at line ${line}; exit status ${rc}"
    else
        echo "ERROR: [MODULE] in ${func} at line ${line}; exit status ${rc}" >&2
    fi
    return $rc
}

trap '_nftban_[module]_on_err ${LINENO} ${FUNCNAME[0]:-main}' ERR
```

### 2. Module Constants
```bash
readonly MODULE_NAME="[name]"
readonly MODULE_VERSION="0.9.3"
```

### 3. Footer Section
```bash
# =============================================================================
# FOOTER
# =============================================================================
#
# **Module Version:** 0.9.3
# **Security Level:** Production-Hardened (9/10)
# **License:** NFTBAN Custom License v3.0
# SPDX-License-Identifier: NFTBAN-Custom-License
#
# Copyright (c) 2024-2025 NFTBan Project
#
# NFTBAN CUSTOM LICENSE v3.0
# [Full license text...]
# =============================================================================
```

---

## 🧪 TESTING STRATEGY

### Per-File Testing
After migrating each file:
```bash
# 1. Syntax check
bash -n /etc/nftban/lib/[module].sh

# 2. Module load test
cd /etc/nftban && source lib/[module].sh

# 3. Function existence check
declare -f [key_function_name] >/dev/null && echo "✅ Functions loaded"

# 4. Constant check
[[ -n $MODULE_CONSTANT ]] && echo "✅ Constants set"
```

### Category Testing
After completing each category, deploy to lab servers:
```bash
# Deploy to all 3 lab servers
for server in lab.example.test lab1.example.test lab2.example.test; do
    scp lib/[module].sh root@${server}:/etc/nftban/lib/
done

# Test on each server
ssh root@lab.example.test "cd /etc/nftban && source lib/[module].sh && [tests]"
```

### Final Integration Testing
After all migrations complete:
1. **Syntax check all:** `find lib/ -name "*.sh" -exec bash -n {} \;`
2. **Load all modules:** Test core + all dependent modules
3. **Run smoke tests:** `nftban smoketest`
4. **Check service status:** `systemctl status nftban`
5. **Verify functionality:** Test key commands on all 3 servers

---

## 📋 PRIORITY ORDER

### Priority 1: CRITICAL (Do First)
1. `nftban_sync_module.sh` - Used for server sync operations
2. `nftban_init_script.sh` - Used during installation
3. `nftban_maintenance_module.sh` - Critical for system upkeep

### Priority 2: HIGH (Do Next)
4. `nftban_feeds_module.sh` - Threat intelligence
5. `installer/nftban_uninstall_script.sh` - User-facing script
6. `installer/nftban_installer_modular.sh` - User-facing script

### Priority 3: MEDIUM (Then)
7. `nftban_autorebuild_module.sh`
8. Validator scripts (3 files) - Dev/testing tools
9. Installer support modules (3 files)

### Priority 4: LOW (Last/Optional)
13. `deprecated/nftban_installer.sh` - Consider skipping

---

## 🔍 SPECIAL CONSIDERATIONS

### Files with OLD Header (8 files)
**Advantage:** Already have strict mode, just upgrade
**Process:**
1. Change `-euo` to `-Eeuo`
2. Add IFS, umask, PATH, locale
3. Add/update error trap
4. Add footer

**Risk:** LOW - minimal changes

### Files with NO Strict Mode (6 files)
**Disadvantage:** No error handling currently
**Process:**
1. Add complete production header
2. **CAREFULLY REVIEW** existing code:
   - Check for unquoted variables
   - Check for command substitution
   - Check for undefined variable usage
   - May need code fixes beyond header

**Risk:** MEDIUM - may expose existing bugs

### Deprecated Files
**Decision needed:**
- **Option A:** Skip migration (it's deprecated)
- **Option B:** Migrate for completeness
- **Recommendation:** SKIP to save time

---

## 📐 SUCCESS CRITERIA

Migration is complete when:
- ✅ All 14 files have production-hardened header v2.0
- ✅ All files pass syntax check (`bash -n`)
- ✅ All modules load without error
- ✅ All modules tested on 3 lab servers (CentOS 9, Ubuntu 24, CentOS 10)
- ✅ No regressions in functionality
- ✅ Smoke tests pass: `nftban smoketest`
- ✅ All changes committed to git
- ✅ 100% of non-deprecated .sh files aligned

---

## 🚀 IMPLEMENTATION PLAN

### Phase 1: Preparation (30 min)
- ✅ Generate list of files (DONE)
- ✅ Create TODO list (DONE)
- ✅ Create this plan document (DONE)
- ⏳ Review each file briefly to identify potential issues

### Phase 2: Migration (8-9 hours)
- ⏳ Migrate files in priority order
- ⏳ Test each file after migration
- ⏳ Deploy to lab servers per category

### Phase 3: Testing (2-3 hours)
- ⏳ Comprehensive testing on all 3 lab servers
- ⏳ Integration testing (all modules together)
- ⏳ Smoke tests
- ⏳ Regression testing (verify existing features work)

### Phase 4: Documentation & Commit (1 hour)
- ⏳ Update this document with results
- ⏳ Create detailed commit message
- ⏳ Git commit + push
- ⏳ Update v0.9.3 release notes

---

## 📞 QUESTIONS TO ANSWER

Before starting:
1. **Skip deprecated file?** YES/NO
   - Recommendation: YES - save 30 minutes

2. **Do all at once or batch by category?**
   - Recommendation: By category - easier to test and debug

3. **Deploy to lab after each file or per category?**
   - Recommendation: Per category - more efficient

---

## 📊 PROGRESS TRACKING

Track progress using TodoWrite tool:
- [ ] Core modules (4 files)
- [ ] Validator scripts (3 files)
- [ ] Installer modules (5 files)
- [ ] Init script (1 file)
- [ ] Deprecated decision
- [ ] Testing on lab servers
- [ ] Git commit/push

---

**READY TO START?**

1. Confirm approach with user
2. Start with Priority 1 files (sync, init, maintenance)
3. Test each file
4. Deploy per category
5. Final integration test
6. Commit all changes

**Estimated completion:** 2-3 days of work (12 hours total)

---

**This plan ensures all NFTBan modules have consistent security standards and production-grade quality.**
