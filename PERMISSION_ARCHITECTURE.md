# NFTBan Permission Architecture
**Version:** 1.0
**Last Updated:** 2025-10-30
**Status:** Production Ready
**Purpose:** Clear explanation of who owns what and who is responsible

**Related Documentation:**
- [Documentation Index](FHS_AUTO_HEAL_INDEX.md) - Quick reference to all docs
- [Complete Summary](FHS_AUTO_HEAL_COMPLETE_SUMMARY.md) - Full implementation guide
- [Architecture](FHS_AUTO_HEAL_ARCHITECTURE.md) - Design decisions and principles
- [FHS Consolidation](FHS_CONSOLIDATION_COMPLETE.md) - Single source of truth
- [Auto-Heal Implementation](AUTO_HEAL_COMPLETE.md) - Implementation details

---

## 🎯 CORE PRINCIPLE: SEPARATION OF CONCERNS

### Two Users, Two Responsibilities

```
┌─────────────────────────────────────────────────────────────┐
│                                                               │
│  ROOT                        │  NFTBAN USER                  │
│  Manages system              │  Manages runtime              │
│  Owns code/config            │  Owns data/logs               │
│  Rarely needed               │  Daily operations             │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

---

## 👤 ROOT - System Administrator

### What ROOT Owns

```
/usr/sbin/nftban                 755 root:root    ← Main binary
/usr/lib/nftban/                 755 root:root    ← Application code
  ├── core/                      755 root:root    ← Core modules
  ├── cli/                       755 root:root    ← CLI handlers
  └── bin/                       755 root:root    ← Helper binaries

/usr/share/nftban/               755 root:root    ← Read-only data
  └── templates/                 755 root:root    ← Templates

/etc/nftban/                     750 root:nftban  ← Configuration
  └── conf.d/                    750 root:nftban  ← Module configs
```

### ROOT is Responsible For

**System-level tasks:**
- ✅ Installing/updating nftban software
- ✅ Deploying code to `/usr/lib/nftban`
- ✅ Creating system users/groups
- ✅ Managing configuration files
- ✅ Initial setup and bootstrap

**When needed:**
- ⚠️ When deployment copies wrong ownership
- ⚠️ When system directories missing
- ⚠️ When timer reports "need root"

**How to fix:**
```bash
# When journal shows root needed
sudo nftban health fix all
```

### Why ROOT Ownership?

**Security:**
- Application code can't be modified by nftban user
- Configuration protected (read-only for nftban user)
- Prevents privilege escalation

**Example attack prevented:**
```bash
# If nftban owned /usr/lib/nftban:
# Attacker compromises nftban user
# Attacker modifies /usr/lib/nftban/core/nftban_health.sh
# Next time root runs: sudo nftban health fix
# Attacker's code runs as root! ← PREVENTED by root ownership
```

---

## 🤖 NFTBAN USER - Application Service

### What NFTBAN USER Owns

```
/var/lib/nftban/                 755 nftban:nftban ← Application data
  ├── reports/                   750 nftban:nftban ← Generated reports
  ├── metrics/                   750 nftban:nftban ← Statistics DB
  ├── snapshots/                 750 nftban:nftban ← Hourly snapshots
  └── exports/                   750 nftban:nftban ← User exports

/var/log/nftban/                 750 nftban:nftban ← Log files
  └── reports/                   750 nftban:nftban ← Report logs

/var/cache/nftban/               755 nftban:nftban ← Cache files
/run/nftban/                     755 nftban:nftban ← Runtime data
```

### NFTBAN USER is Responsible For

**Daily operations:**
- ✅ Writing logs
- ✅ Creating reports
- ✅ Storing metrics
- ✅ Managing cache
- ✅ Creating runtime files
- ✅ Maintaining its own directories

**Auto-fix capabilities:**
- ✅ Create subdirectories in owned paths
- ✅ Fix permissions on owned files
- ✅ Clean up old data
- ✅ Restart services (via systemd)

**Cannot do (needs root):**
- ❌ Modify system code
- ❌ Change configuration
- ❌ Create system directories
- ❌ Change ownership of files

### Why NFTBAN USER Ownership?

**Principle of least privilege:**
- Service doesn't need root for daily operations
- Limits damage if compromised
- Follows standard Unix security model

**Example:**
```bash
# Normal operation (no root needed)
nftban-service writes → /var/log/nftban/access.log  ✅
nftban-service creates → /var/lib/nftban/reports/daily.json  ✅
nftban-service caches → /var/cache/nftban/temp.dat  ✅

# These would require root (correctly blocked)
nftban-service writes → /usr/lib/nftban/core/module.sh  ❌
nftban-service modifies → /etc/nftban/config.conf  ❌
```

---

## 🔐 SPECIAL CASE: root:nftban

### What Uses root:nftban

```
/etc/nftban/                     750 root:nftban
  └── conf.d/                    750 root:nftban

/var/lib/nftban/geoip/           750 root:nftban
```

### Why This Ownership?

**Configuration (`/etc/nftban`):**
```
Owner: root        ← Only root can write (security)
Group: nftban      ← nftban can read (functionality)
Perms: 750         ← Owner RWX, group R-X, other ---
```

**Result:**
- ✅ root can edit config
- ✅ nftban can read config (needs to work!)
- ❌ nftban cannot modify config (security)
- ❌ others cannot even read (security)

**GeoIP database (`/var/lib/nftban/geoip`):**
```
Owner: root        ← Only root updates DB (from official source)
Group: nftban      ← nftban can read DB (for lookups)
Perms: 750         ← Owner RWX, group R-X, other ---
```

**Result:**
- ✅ root updates GeoIP database (weekly timer)
- ✅ nftban reads GeoIP database (for IP lookups)
- ❌ nftban cannot corrupt database
- ❌ others cannot access database

---

## 🔄 PERMISSION MECHANISMS

### 1. Ownership Check (chmod/chown)

**Rule:** Only owner (or root) can change permissions

```bash
# Directory owned by nftban:nftban
/var/lib/nftban  → 750 nftban:nftban

# What nftban user can do:
chmod 755 /var/lib/nftban  ✅  # Change permissions (owner)
mkdir /var/lib/nftban/new  ✅  # Create children (owner)

# What nftban user CANNOT do:
chown root:root /var/lib/nftban  ❌  # Change ownership (need root)
```

```bash
# Directory owned by root:nftban
/etc/nftban  → 750 root:nftban

# What nftban user can do:
ls /etc/nftban           ✅  # Read (group has R-X)
cat /etc/nftban/foo.conf ✅  # Read files (group has R)

# What nftban user CANNOT do:
chmod 755 /etc/nftban           ❌  # Not owner
vi /etc/nftban/foo.conf         ❌  # No write permission
mkdir /etc/nftban/new.d         ❌  # No write permission
```

### 2. Parent Directory Control (mkdir)

**Rule:** Must have write permission on parent to create children

```bash
# nftban user wants to create /var/lib/nftban/new_feature/

Parent: /var/lib/nftban
Owner: nftban:nftban
Perms: 755 (owner has write)

Check: Am I the owner? YES ✅
Check: Do I have write perm? YES ✅
Result: mkdir succeeds ✅
```

```bash
# nftban user wants to create /usr/lib/nftban/new_module/

Parent: /usr/lib/nftban
Owner: root:root
Perms: 755 (others don't have write)

Check: Am I the owner? NO ❌
Check: Do I have write perm? NO ❌
Result: mkdir fails ❌
```

### 3. Group Permissions (read access)

**Rule:** Members of group get group permissions

```bash
# File: /etc/nftban/ddos.conf
Owner: root
Group: nftban
Perms: 640 (owner RW, group R, other ---)

# nftban user (member of nftban group):
cat /etc/nftban/ddos.conf  ✅  # Group has read

# other user (not in nftban group):
cat /etc/nftban/ddos.conf  ❌  # No permissions
```

---

## 🏗️ ARCHITECTURE ENFORCEMENT MECHANISMS

### Mechanism 1: Single FHS Specification

**File:** `/usr/lib/nftban/core/nftban_fhs_spec.sh`

**Defines:** All paths, ownership, permissions

```bash
NFTBAN_FHS_DIRECTORIES["/usr/lib/nftban"]="755|root|root|..."
NFTBAN_FHS_DIRECTORIES["/var/lib/nftban"]="755|nftban|nftban|..."
NFTBAN_FHS_DIRECTORIES["/etc/nftban"]="750|root|nftban|..."
```

**All modules source this:**
```bash
source /usr/lib/nftban/core/nftban_fhs_spec.sh
```

**Result:** Everyone agrees on correct ownership/permissions

---

### Mechanism 2: FHS Compliance Checker

**Command:** `nftban fhs`

**What it does:**
- Reads FHS spec (expected values)
- Checks actual filesystem (current values)
- Reports mismatches

**Output:**
```
/usr/lib/nftban     755 root:root    755 root:root    ✔ OK
/var/lib/nftban     755 nftban:nftban 750 nftban:nftban ✖ ERROR
                    ↑ Expected        ↑ Actual
```

**Architecture enforcement:**
- ✅ Detects wrong ownership
- ✅ Detects wrong permissions
- ✅ Reports 21/21 status
- ⚠️ Alerts when something wrong

---

### Mechanism 3: Smart Auto-Fix

**Functions:** `nftban_health_fix_*`

**Intelligence:**
```bash
function fix_directory(path):
    expected = get_from_fhs_spec(path)

    if path_is_missing:
        if can_create_as_current_user:
            create_it()
            report("✓ Created $path")
        else:
            report("⚠️ Cannot create (need root)")

    if permissions_wrong:
        if am_owner OR am_root:
            fix_permissions()
            report("✓ Fixed perms")
        else:
            report("⚠️ Cannot fix (need root)")

    if ownership_wrong:
        if am_root:
            fix_ownership()
            report("✓ Fixed owner")
        else:
            report("⚠️ Cannot fix (need root)")
```

**Architecture enforcement:**
- ✅ Fixes what current user can
- ⚠️ Reports what needs root
- ❌ Never fails silently
- 💡 Always shows solution

---

### Mechanism 4: Periodic Health Timer

**Timer:** Runs daily at 03:00 AM

**As:** nftban user (not root!)

**Does:**
```
1. Run: nftban health fix all
2. Fix: What nftban can (its directories)
3. Report: What needs root (system directories)
4. Log: Everything to journal
```

**Architecture enforcement:**
- ✅ Maintains nftban-owned directories automatically
- ⚠️ Alerts admin when root needed
- 🔄 Continuous compliance checking
- 📊 Logged for audit

---

### Mechanism 5: Deployment Validation

**Before deployment:**
```bash
# Check source files
ls -la /home/gituser/nftban-v0.10.0-dev/src/usr/lib/nftban/

# Problem: Owned by gituser (UID 1002)
drwxr-xr-x gituser gituser ...
```

**After deployment (wrong):**
```bash
# scp preserves UID
ssh root@server 'ls -la /usr/lib/nftban/'

# Problem: UID 1002 doesn't exist on server
drwxr-xr-x 1002 1002 ...      ← Shows as UNKNOWN:UNKNO
```

**Auto-fix detects and reports:**
```bash
# Timer runs
nftban health fix all

# Reports:
⚠️  Cannot fix /usr/lib/nftban ownership
    Current: 1002:1002
    Expected: root:root
    Need root to run chown

# Admin fixes:
sudo nftban health fix all
✓ Fixed /usr/lib/nftban → root:root
```

**Architecture enforcement:**
- ✅ Detects deployment mistakes
- ⚠️ Reports to admin
- 🔧 Provides fix command
- ✅ Corrects to spec

---

## 📊 PERMISSION MATRIX

### Directory Permission Table

| Directory | Owner | Group | Perms | Read | Write | Execute |
|-----------|-------|-------|-------|------|-------|---------|
| `/usr/lib/nftban` | root | root | 755 | all | root | all |
| `/usr/share/nftban` | root | root | 755 | all | root | all |
| `/etc/nftban` | root | nftban | 750 | root,nftban | root | root,nftban |
| `/var/lib/nftban` | nftban | nftban | 755 | all | nftban | all |
| `/var/lib/nftban/reports` | nftban | nftban | 750 | nftban | nftban | nftban |
| `/var/log/nftban` | nftban | nftban | 750 | nftban | nftban | nftban |
| `/var/cache/nftban` | nftban | nftban | 755 | all | nftban | all |

### User Capability Matrix

| Action | root | nftban user | other users |
|--------|------|-------------|-------------|
| Read `/usr/lib/nftban` | ✅ | ✅ | ✅ |
| Write `/usr/lib/nftban` | ✅ | ❌ | ❌ |
| Read `/etc/nftban` | ✅ | ✅ | ❌ |
| Write `/etc/nftban` | ✅ | ❌ | ❌ |
| Read `/var/lib/nftban` | ✅ | ✅ | ✅ |
| Write `/var/lib/nftban` | ✅ | ✅ | ❌ |
| Create `/var/lib/nftban/*` | ✅ | ✅ | ❌ |
| chown any file | ✅ | ❌ | ❌ |

---

## 🛡️ SECURITY MODEL

### Defense in Depth

**Layer 1: File Ownership**
- System code owned by root
- Runtime data owned by nftban
- **Attack:** Compromise nftban user
- **Blocked:** Cannot modify system code

**Layer 2: File Permissions**
- Read-only for non-owners
- Write only for owner
- **Attack:** Read sensitive config as random user
- **Blocked:** 750 permissions prevent access

**Layer 3: Group Isolation**
- nftban group for necessary access
- Other users not in group
- **Attack:** Access nftban data as www-data user
- **Blocked:** Not in nftban group

**Layer 4: Monitoring**
- Daily FHS compliance check
- Journal logging
- **Attack:** Subtle permission changes
- **Detected:** FHS report shows mismatch

**Layer 5: Auto-Correction**
- Periodic auto-heal
- Manual fix available
- **Attack aftermath:** Permission drift
- **Corrected:** Auto-heal restores proper state

---

## ✅ RESPONSIBILITY SUMMARY

### ROOT Responsibilities

**Setup & Deployment:**
- ✅ Initial installation
- ✅ Code updates
- ✅ System directory creation
- ✅ User/group creation

**Maintenance:**
- ✅ Fix deployment errors (wrong ownership)
- ✅ Create missing system directories
- ✅ Update configuration files
- ✅ Review journal for "need root" alerts

**When Needed:**
- ⚠️ When timer logs "need root"
- ⚠️ After deployments
- ⚠️ When FHS shows errors on system paths

**Command:**
```bash
sudo nftban health fix all
```

---

### NFTBAN USER Responsibilities

**Daily Operations:**
- ✅ Write logs
- ✅ Generate reports
- ✅ Store metrics
- ✅ Manage cache
- ✅ Create runtime files

**Auto-Maintenance:**
- ✅ Create missing subdirectories
- ✅ Fix permissions on owned files
- ✅ Clean old data
- ✅ Maintain directory structure

**Automatic (Timer):**
- ✅ Daily health check
- ✅ Auto-fix owned directories
- ✅ Report issues to journal

**Cannot Do:**
- ❌ Modify system code
- ❌ Change config
- ❌ Create system directories
- ❌ Fix root-owned files

---

### ADMIN Workflow

**Normal (Zero Interaction):**
```
Daily → Timer runs → nftban fixes own directories → Done
```

**When Root Needed:**
```
Daily → Timer runs → Can't fix system dirs → Logs to journal
    ↓
Admin checks: journalctl -u nftban-health.service
    ↓
Admin sees: "⚠️ Cannot fix X (need root)"
    ↓
Admin runs: sudo nftban health fix all
    ↓
System fixed → Back to normal
```

**Frequency:**
- Normal operations: Never
- After deployment: Once
- After updates: Occasionally
- System errors: Rare

---

## 🎯 VERIFICATION COMMANDS

### Check Ownership

```bash
# System directories (should be root:root)
stat -c "%U:%G %n" /usr/lib/nftban
# Expected: root:root /usr/lib/nftban

# Runtime directories (should be nftban:nftban)
stat -c "%U:%G %n" /var/lib/nftban
# Expected: nftban:nftban /var/lib/nftban

# Config directories (should be root:nftban)
stat -c "%U:%G %n" /etc/nftban
# Expected: root:nftban /etc/nftban
```

### Check Permissions

```bash
# System directories (should be 755)
stat -c "%a %n" /usr/lib/nftban
# Expected: 755 /usr/lib/nftban

# Config directories (should be 750)
stat -c "%a %n" /etc/nftban
# Expected: 750 /etc/nftban

# Runtime directories (varies)
stat -c "%a %n" /var/lib/nftban
# Expected: 755 /var/lib/nftban
```

### Test nftban User Can Create

```bash
# Test subdirectory creation
sudo -u nftban mkdir /var/lib/nftban/test_dir
# Expected: SUCCESS

sudo -u nftban rmdir /var/lib/nftban/test_dir
# Expected: SUCCESS

# Test system directory (should fail)
sudo -u nftban mkdir /usr/lib/nftban/test_dir
# Expected: FAIL (permission denied)
```

### Verify FHS Compliance

```bash
# Complete check
nftban fhs
# Expected: 21/21 OK

# Check specific path
nftban fhs | grep /var/lib/nftban
# Expected: ✔ OK
```

---

## 📝 FINAL ANSWER TO YOUR QUESTIONS

### "HOW WORKS PERM ROOT NFTBAN?"

**Answer:**
- **root** owns system files (code, config) - 755 or 750
- **nftban** owns runtime data (logs, cache) - 755 or 750
- **root:nftban** for shared access (nftban reads, root writes)

**Mechanism:**
- Unix file ownership + permissions
- Group membership for shared access
- Enforced by kernel (can't bypass)

### "WHO IS RESPONSIBLE FOR WHAT?"

**Answer:**
- **root** → System (code, config, initial setup)
- **nftban user** → Runtime (logs, data, daily operations)
- **Timer** → Monitoring and auto-fix (as nftban user)
- **Admin** → Manual fixes when timer reports "need root"

### "ALL THE MECHANISM TO ENSURE ARCHITECTURE?"

**Answer - 5 Mechanisms:**
1. **FHS Spec** - Single source of truth
2. **FHS Checker** - Detects wrong ownership/perms
3. **Smart Auto-Fix** - Fixes what it can, reports what it can't
4. **Daily Timer** - Runs as nftban, maintains directories
5. **Admin Alerts** - Journal logs when root needed

**Result:** Architecture self-enforcing

---

**Status:** ✅ Architecture documented and enforced

**Key Takeaway:** Two users, clear responsibilities, self-healing system

**EOF**
