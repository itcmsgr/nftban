# FHS Specification Consolidation - Complete Report
**Version:** 1.0
**Last Updated:** 2025-10-30
**Status:** Production Ready
**Purpose:** Single source of truth for all FHS paths, ownership, and permissions

**Related Documentation:**
- [Documentation Index](FHS_AUTO_HEAL_INDEX.md) - Quick reference to all docs
- [Permission Architecture](PERMISSION_ARCHITECTURE.md) - Who owns what
- [Complete Summary](FHS_AUTO_HEAL_COMPLETE_SUMMARY.md) - Full implementation guide
- [Architecture](FHS_AUTO_HEAL_ARCHITECTURE.md) - Design decisions and principles
- [Auto-Heal Implementation](AUTO_HEAL_COMPLETE.md) - Implementation details

---

## 🎯 PROBLEM

Previously, FHS paths/permissions were defined in MULTIPLE places:
- `nftban_report_fhs.sh` - FHS checking
- `nftban_health.sh` - Auto-fix functions
- `deploy/install.sh` - Installation script
- `nftban_portscan.sh` - Module-specific directories
- `nftban_security.sh` - Security-related directories
- Various deployment scripts

**Result:** Inconsistencies, difficult to maintain, easy to miss updates

---

## ✅ SOLUTION: Single Source of Truth

Created **`/usr/lib/nftban/core/nftban_fhs_spec.sh`** as THE ONLY place defining FHS specifications.

All other modules now SOURCE this file instead of defining paths themselves.

---

## 📋 FHS SPECIFICATION (Canonical)

Located in: `/usr/lib/nftban/core/nftban_fhs_spec.sh`

```bash
# System Directories (root:root, 755)
/usr/sbin                              755|root|root
/usr/lib/nftban                        755|root|root
/usr/lib/nftban/core                   755|root|root
/usr/lib/nftban/cli                    755|root|root
/usr/lib/nftban/bin                    755|root|root

# Configuration (root:nftban, 750)
/etc/nftban                            750|root|nftban
/etc/nftban/conf.d                     750|root|nftban

# Variable Data (nftban:nftban, 755 or 750)
/var/lib/nftban                        755|nftban|nftban
/var/lib/nftban/reports                750|nftban|nftban
/var/lib/nftban/metrics                750|nftban|nftban
/var/lib/nftban/snapshots              750|nftban|nftban
/var/lib/nftban/exports                750|nftban|nftban
/var/lib/nftban/geoip                  750|root|nftban

# Logs (nftban:nftban, 750)
/var/log/nftban                        750|nftban|nftban
/var/log/nftban/reports                750|nftban|nftban

# Cache/Runtime (nftban:nftban, 755)
/var/cache/nftban                      755|nftban|nftban
/run/nftban                            755|nftban|nftban

# Shared Data (root:root, 755)
/usr/share/nftban                      755|root|root
/usr/share/nftban/templates            755|root|root
/usr/share/nftban/templates/mail       755|root|root
/usr/share/nftban/templates/reports    755|root|root
```

---

## 🔄 FILES UPDATED TO USE SHARED SPEC

### ✅ Core Modules (UPDATED)

1. **`/usr/lib/nftban/core/nftban_fhs_spec.sh`** - NEW FILE
   - Canonical specification
   - Single source of truth
   - Provides helper functions

2. **`/usr/lib/nftban/core/nftban_report_fhs.sh`** - UPDATED
   - Now sources `nftban_fhs_spec.sh`
   - Removed duplicate definitions
   - Uses `NFTBAN_FHS_DIRECTORIES` from spec

3. **`/usr/lib/nftban/core/nftban_health.sh`** - UPDATED
   - `nftban_health_fix_permissions()` uses shared spec
   - `nftban_health_fix_directories()` uses shared spec
   - No more hardcoded paths

---

## 📦 FILES THAT NEED TO BE UPDATED

### 🔴 HIGH PRIORITY - Installation/Packaging

#### 1. `/deploy/install.sh`
**Current State:** Has hardcoded paths and permissions
```bash
# Lines 48-66 - Hardcoded directory creation
install -d -m 0755 /etc/nftban
install -d -m 0755 /etc/nftban/whitelist.d
install -d -m 0750 -o nftban -g nftban /var/lib/nftban
```

**Needs:** Source `nftban_fhs_spec.sh` and use spec dynamically

**Action Required:**
```bash
# Replace hardcoded paths with:
source /usr/lib/nftban/core/nftban_fhs_spec.sh

for dir in "${!NFTBAN_FHS_DIRECTORIES[@]}"; do
    IFS='|' read -r perms owner group _ <<< "${NFTBAN_FHS_DIRECTORIES[$dir]}"
    install -d -m "$perms" -o "$owner" -g "$group" "$dir" 2>/dev/null || true
done
```

#### 2. `/install.sh` (root level)
**Current State:** Has chmod commands (lines 96-100)
```bash
chmod 0750 /etc/nftban
chmod 0750 /etc/nftban/conf.d
```

**Action Required:** Use shared spec or call `nftban health fix all`

#### 3. `/deploy/tmpfiles.d/nftban.conf`
**Check:** Verify tmpfiles.d definitions match FHS spec

#### 4. `/deploy/sysusers.d/nftban.conf`
**Check:** Verify user/group creation matches FHS spec

---

### 🟡 MEDIUM PRIORITY - Modules Creating Directories

#### 5. `/usr/lib/nftban/core/nftban_portscan.sh`
**Current State:** Creates directories directly
```bash
mkdir -p "$NFTBAN_PORTSCAN_DATA_DIR"      # /var/lib/nftban/portscan
mkdir -p "$NFTBAN_PORTSCAN_CACHE_DIR"     # /var/cache/nftban/portscan
mkdir -p "$(dirname "$NFTBAN_PORTSCAN_LOG_FILE")"  # /var/log/nftban
```

**Issue:** Doesn't set ownership/permissions

**Action Required:** Use `nftban_health_fix_directories` or source spec

#### 6. `/usr/lib/nftban/core/nftban_security.sh`
**Current State:** Creates audit directory
```bash
mkdir -p /etc/audit/rules.d
```

**Note:** This is an external path (not nftban-specific), OK to keep

#### 7. `/usr/lib/nftban/cli/cmd_firewall.sh`
**Check:** May have directory creation logic

---

### 🟢 LOW PRIORITY - Deployment Scripts

These are temporary deployment scripts, not part of production:
- `/DEPLOY_TO_LAB.sh`
- `/deploy-v0.10.0-to-lab.sh`
- `/deploy_stats_to_labs.sh`
- `/deploy-test-to-lab.sh`
- `/DEPLOY_FAIL2BAN.sh`
- `/fix_nftban_permissions.sh`

**Action:** Document that they should call `nftban health fix all` instead

---

### 📚 DOCUMENTATION UPDATES NEEDED

#### 8. Installation Guides
- `/docs/guides/install.md`
- `/docs/DEPLOYMENT_GUIDE.md`
- `/docs/deployment/FINAL_DEPLOYMENT_REPORT_v0.10.0.md`

**Action:** Update to reference:
1. FHS spec location
2. `nftban health fix all` command
3. `nftban fhs` command to verify

#### 9. Package Manager Docs
- `/PACKAGE_MANAGER_GUIDE.md`
- `/PACKAGE_MANAGER_INSTALLATION_ORDER.md`
- `/FHS_PACKAGE_MANAGER_UPDATE.md`
- `/PACKAGING_PLAN_FINAL.md`

**Action:** Update RPM/DEB spec files to use FHS spec

---

## 🚀 USAGE: How to Use Shared FHS Spec

### In Bash Scripts

```bash
#!/usr/bin/env bash

# Load FHS specification
source /usr/lib/nftban/core/nftban_fhs_spec.sh || {
    echo "ERROR: Failed to load FHS spec" >&2
    exit 1
}

# Use the spec
for path in "${!NFTBAN_FHS_DIRECTORIES[@]}"; do
    IFS='|' read -r perms owner group purpose <<< "${NFTBAN_FHS_DIRECTORIES[$path]}"
    echo "$path: $perms $owner:$group ($purpose)"
done

# Get spec for specific path
spec=$(nftban_fhs_get_spec "/var/lib/nftban")
echo "Spec: $spec"

# Get all paths
nftban_fhs_get_all_paths | while read -r path; do
    echo "Path: $path"
done
```

### In Commands

```bash
# Fix all FHS compliance issues
sudo nftban health fix all

# Check FHS compliance
nftban fhs

# Fix only permissions
sudo nftban health fix permissions

# Fix only directories
sudo nftban health fix directories
```

---

## 🎯 BENEFITS

### Before (Multiple Definitions)

```
nftban_report_fhs.sh:  NFTBAN_FHS_DIRECTORIES["/etc/nftban"]="750|root|nftban|..."
nftban_health.sh:      fhs_dirs["/etc/nftban"]="750|root|nftban"
deploy/install.sh:     install -d -m 0755 /etc/nftban  # ❌ WRONG!
```

**Problem:** Three places with THREE different values!

### After (Single Source)

```
nftban_fhs_spec.sh:    NFTBAN_FHS_DIRECTORIES["/etc/nftban"]="750|root|nftban|..."

ALL other files:       source /usr/lib/nftban/core/nftban_fhs_spec.sh
```

**Result:** ONE definition, used everywhere!

---

## ✅ BENEFITS SUMMARY

1. ✅ **Consistency** - One place defines all paths
2. ✅ **Maintainability** - Update once, applies everywhere
3. ✅ **Correctness** - No more conflicting definitions
4. ✅ **Auto-fix** - `nftban health fix all` uses correct spec
5. ✅ **Auditing** - `nftban fhs` checks against correct spec
6. ✅ **Documentation** - One canonical reference

---

## 🔧 AUTO-HEAL FUNCTIONALITY

Enhanced `nftban health fix` command:

```bash
# Fix everything
sudo nftban health fix all

# Creates:
- Missing directories
- Correct ownership (root:root for system, nftban:nftban for runtime)
- Correct permissions (750 for config, 755 for libs, etc.)

# Fixes:
- Wrong ownership (e.g., 1002:1002 → root:root)
- Wrong permissions (e.g., 755 → 750 for /etc/nftban)
- Missing subdirectories (exports, geoip, etc.)
```

---

## 📊 DEPLOYMENT STATUS

### ✅ Deployed to All Lab Servers

```bash
lab.mywebhost.gr    ✅ nftban_fhs_spec.sh deployed
lab1.mywebhost.gr   ✅ nftban_fhs_spec.sh deployed
lab2.mywebhost.gr   ✅ nftban_fhs_spec.sh deployed
```

All servers now have:
- Shared FHS specification
- Enhanced health fix functions
- Updated FHS report module

---

## 🎯 NEXT STEPS

### Immediate (HIGH PRIORITY)

1. [ ] Update `/deploy/install.sh` to use shared spec
2. [ ] Update `/install.sh` to use shared spec
3. [ ] Test installation with new spec

### Soon (MEDIUM PRIORITY)

4. [ ] Update `nftban_portscan.sh` to use spec for dir creation
5. [ ] Review all modules for hardcoded paths
6. [ ] Test on fresh installation

### Future (LOW PRIORITY)

7. [ ] Update all documentation
8. [ ] Update package manager specs (RPM/DEB)
9. [ ] Add to CI/CD validation

---

## 🧪 TESTING

### Test Auto-Fix

```bash
# On lab1
ssh root@lab1.mywebhost.gr

# Check current FHS status
nftban fhs

# Run auto-fix
nftban health fix all

# Verify
nftban fhs
```

**Expected Result:** All directories exist with correct ownership/permissions

### Test Spec Loading

```bash
# Test from command line
bash -c 'source /usr/lib/nftban/core/nftban_fhs_spec.sh; nftban_fhs_get_all_paths'

# Should output all paths in sorted order
```

---

## 📝 SUMMARY

**Created:** `/usr/lib/nftban/core/nftban_fhs_spec.sh` (Single source of truth)

**Updated:**
- `/usr/lib/nftban/core/nftban_health.sh` (Uses shared spec)
- `/usr/lib/nftban/core/nftban_report_fhs.sh` (Uses shared spec)

**Needs Update:**
- `/deploy/install.sh` (Installation script)
- `/install.sh` (Root installer)
- Module initialization functions (portscan, etc.)
- Documentation

**Benefits:**
- ONE place to update FHS paths
- Consistent across all modules
- Auto-heal works correctly
- Easy to maintain

---

**Status:** ✅ Core functionality complete, deployment scripts need update

**EOF**
