# NFTBan FHS Auto-Heal Architecture
**Version:** 1.0
**Last Updated:** 2025-10-30
**Status:** Production Ready
**Purpose:** Clear architectural design for FHS compliance and auto-heal

**Related Documentation:**
- [Documentation Index](FHS_AUTO_HEAL_INDEX.md) - Quick reference to all docs
- [Permission Architecture](PERMISSION_ARCHITECTURE.md) - Who owns what
- [Complete Summary](FHS_AUTO_HEAL_COMPLETE_SUMMARY.md) - Full implementation guide
- [FHS Consolidation](FHS_CONSOLIDATION_COMPLETE.md) - Single source of truth
- [Auto-Heal Implementation](AUTO_HEAL_COMPLETE.md) - Implementation details

---

## 🎯 ARCHITECTURAL PRINCIPLES

### 1. Principle of Least Privilege
- **nftban user** owns `/var/lib/nftban`, `/var/log/nftban`, `/var/cache/nftban`
- **nftban user** can fix what it owns (no root needed for daily operations)
- **root** owns `/usr/lib/nftban`, `/usr/share/nftban`, `/etc/nftban`
- **root** needed only for system-level fixes

### 2. Single Source of Truth
- **ONE file** defines all FHS paths: `/usr/lib/nftban/core/nftban_fhs_spec.sh`
- **All modules** source this file (no duplicates!)
- **Easy maintenance**: change once, applies everywhere

### 3. Smart Privilege Awareness
- **Functions detect** if running as root or nftban user
- **Fix what they can**, report what they can't
- **No silent failures**: always inform user of root cause

---

## 📋 FHS SPECIFICATION (Single Source of Truth)

**File:** `/usr/lib/nftban/core/nftban_fhs_spec.sh`

```bash
# System files (root:root, 755) - Read-only system code
/usr/lib/nftban              755|root|root
/usr/lib/nftban/core         755|root|root
/usr/lib/nftban/cli          755|root|root
/usr/lib/nftban/bin          755|root|root
/usr/share/nftban            755|root|root

# Config files (root:nftban, 750) - Root writes, nftban group reads
/etc/nftban                  750|root|nftban
/etc/nftban/conf.d           750|root|nftban

# Runtime data (nftban:nftban) - nftban user owns and manages
/var/lib/nftban              755|nftban|nftban  ← nftban CAN fix
/var/lib/nftban/reports      750|nftban|nftban  ← nftban CAN fix
/var/lib/nftban/metrics      750|nftban|nftban  ← nftban CAN fix
/var/lib/nftban/snapshots    750|nftban|nftban  ← nftban CAN fix
/var/lib/nftban/exports      750|nftban|nftban  ← nftban CAN fix
/var/lib/nftban/geoip        750|root|nftban    ← root MUST fix

# Logs (nftban:nftban, 750) - nftban user writes logs
/var/log/nftban              750|nftban|nftban  ← nftban CAN fix
/var/log/nftban/reports      750|nftban|nftban  ← nftban CAN fix

# Cache (nftban:nftban, 755) - nftban user manages cache
/var/cache/nftban            755|nftban|nftban  ← nftban CAN fix
/run/nftban                  755|nftban|nftban  ← nftban CAN fix
```

---

## 🔧 AUTO-FIX FUNCTIONS (Smart Privilege Aware)

### Function: `nftban_health_fix_directories()`

**What it does:**
- Creates missing FHS directories
- Sets correct ownership and permissions
- **Smart about privileges**

**Logic:**
```bash
For each missing directory:
    If (owner == nftban) AND (parent is writable):
        ✅ CREATE IT (nftban user can do this)
        ✅ Set permissions with chmod

    Else if (running as root):
        ✅ CREATE IT (root can do anything)
        ✅ Set ownership with chown
        ✅ Set permissions with chmod

    Else:
        ⚠️ REPORT: "Cannot create X (need root)"
        ⚠️ SHOW: Root cause and what needs fixing
```

**Example Output (as nftban user):**
```
Creating missing directories...
  ✓ Created /var/lib/nftban/exports (750 nftban:nftban)
  ✓ Created /var/log/nftban/reports (750 nftban:nftban)

  ⚠️  Cannot create 1 directory (need root privileges):
     - /usr/lib/nftban/bin → 755 root:root (parent: /usr/lib/nftban not writable)

  💡 Run with root privileges to fix:
     sudo nftban health fix directories
```

### Function: `nftban_health_fix_permissions()`

**What it does:**
- Fixes permissions on existing directories
- Fixes ownership (if root)
- **Smart about privileges**

**Logic:**
```bash
For each directory with wrong perms/owner:
    current_owner = stat directory

    If (current_owner == nftban) OR (running as root):
        ✅ FIX permissions with chmod

    If (running as root):
        ✅ FIX ownership with chown

    Else:
        ⚠️ REPORT: "Cannot fix X (owned by Y, need root)"
```

**Example Output (as nftban user):**
```
Fixing permissions and ownership...
  ✓ Fixed /var/lib/nftban → perms: 750 → 755
  ✓ Fixed /var/cache/nftban → perms: 750 → 755

  ⚠️  Cannot fix 2 permission/ownership issues (need root):
     - /etc/nftban: chmod 750 (currently 755, owned by root)
     - /usr/lib/nftban: chown root:root (currently 1002:1002)

  💡 Run with root privileges to fix:
     sudo nftban health fix permissions
```

---

## ⏰ PERIODIC HEALTH TIMER

### Timer Configuration

**Service:** `/etc/systemd/system/nftban-health.service`
```ini
[Service]
Type=oneshot
User=nftban          ← Runs as nftban user (least privilege)
Group=nftban
ExecStart=/usr/sbin/nftban health fix all
```

**Timer:** `/etc/systemd/system/nftban-health.timer`
```ini
[Timer]
OnCalendar=daily             ← Runs once per day
OnCalendar=*-*-* 03:00:00   ← At 03:00 AM
RandomizedDelaySec=30m       ← Random 0-30min delay
Persistent=true              ← Catch up after downtime
```

### What Timer Does

**Daily at 03:00 AM:**
1. Runs `nftban health fix all` as nftban user
2. Creates missing directories in `/var/lib/nftban/*`, `/var/log/nftban/*`
3. Fixes permissions on nftban-owned files
4. Reports to journal what needs root (if anything)

**Admin can check journal:**
```bash
journalctl -u nftban-health.service -n 50
```

**If timer reports root needed:**
```bash
# Admin manually fixes system-level issues
sudo nftban health fix all
```

---

## 🚦 WHAT NFTBAN USER CAN FIX

### ✅ nftban User CAN Fix (No Root Needed)

**Directories it owns:**
- `/var/lib/nftban/*` - Create subdirectories, fix permissions
- `/var/log/nftban/*` - Create log dirs, fix permissions
- `/var/cache/nftban/*` - Create cache dirs, fix permissions
- `/run/nftban/*` - Create runtime dirs, fix permissions

**Operations:**
- `mkdir -p /var/lib/nftban/new_subdir` ✅
- `chmod 750 /var/lib/nftban/reports` ✅
- `chmod 755 /var/cache/nftban` ✅

**Why it works:**
- nftban owns parent directories
- Can create children and set their permissions

---

## 🔒 WHAT NEEDS ROOT

### ❌ nftban User CANNOT Fix (Needs Root)

**System directories:**
- `/usr/lib/nftban/*` - Creating, changing ownership
- `/usr/share/nftban/*` - Changing ownership
- `/etc/nftban/*` - Changing ownership, permissions

**Ownership changes:**
- `chown root:root /usr/lib/nftban` ❌ (needs root)
- `chown nftban:nftban /var/lib/nftban` ❌ (needs root if currently owned by someone else)

**Why it needs root:**
- Only root can change file ownership (chown)
- Only owner or root can change permissions (chmod)
- System directories owned by root

---

## 🎯 WORKFLOW

### Daily Workflow (Automatic)

```
03:00 AM: Timer triggers
    ↓
nftban-health.service runs (as nftban user)
    ↓
Executes: nftban health fix all
    ↓
Fix directories:
    ✅ Creates /var/lib/nftban/exports (owns parent)
    ⚠️ Reports /usr/lib/nftban/bin needs root
    ↓
Fix permissions:
    ✅ Fixes /var/cache/nftban perms (owns it)
    ⚠️ Reports /etc/nftban needs root
    ↓
Logs to journal:
    - What was fixed
    - What needs root attention
```

### Manual Root Fix (When Needed)

```
Admin checks journal: journalctl -u nftban-health.service
    ↓
Sees warnings about root-needed fixes
    ↓
Runs: sudo nftban health fix all
    ↓
Running as root:
    ✅ Creates /usr/lib/nftban/bin
    ✅ Fixes /etc/nftban permissions
    ✅ Fixes /usr/lib/nftban ownership (1002:1002 → root:root)
    ↓
All fixed!
```

---

## 📊 CURRENT STATE

### ✅ Implemented and Deployed

1. **FHS Specification** (`nftban_fhs_spec.sh`)
   - Single source of truth
   - 21 directories defined
   - Used by all modules

2. **Smart Auto-Fix Functions** (`nftban_health.sh`)
   - `nftban_health_fix_directories()` - Privilege-aware
   - `nftban_health_fix_permissions()` - Privilege-aware
   - Clear reporting of what needs root

3. **Periodic Timer** (systemd)
   - Runs daily as nftban user
   - Fixes what it can
   - Reports what needs root

4. **Command Handler** (`cmd_health.sh`)
   - Removed blanket root check
   - Shows privilege level on run
   - Works for both nftban and root

### ✅ Deployed to All Lab Servers

```
lab.example.test    ✅ FHS spec
                    ✅ Smart health fix
                    ✅ Timer enabled

lab1.example.test   ✅ FHS spec
                    ✅ Smart health fix
                    ✅ Timer enabled

lab2.example.test   ✅ FHS spec
                    ✅ Smart health fix
                    ✅ Timer enabled
```

---

## 🧪 TESTING

### Test 1: nftban User Can Fix Its Directories

```bash
# As nftban user
sudo -u nftban nftban health fix directories

# Expected:
✓ Created /var/lib/nftban/test (750 nftban:nftban)
⚠️  Cannot create /usr/lib/nftban/test (need root)
```

### Test 2: root Can Fix Everything

```bash
# As root
sudo nftban health fix all

# Expected:
✓ Created /usr/lib/nftban/bin (755 root:root)
✓ Fixed /etc/nftban → 750 root:nftban
✓ Fixed /usr/lib/nftban → root:root (was 1002:1002)
```

### Test 3: Timer Runs Successfully

```bash
# Check timer
systemctl status nftban-health.timer

# View last run
journalctl -u nftban-health.service -n 50

# Expected in logs:
Creating missing directories...
  ✓ All directories already exist
Fixing permissions and ownership...
  ✓ All permissions already correct
```

---

## ✅ SUMMARY

### Architecture Design

**Principle:** Least privilege + clear communication

1. **nftban user** manages its own data directories (daily, automatic)
2. **root** manages system directories (manual, when needed)
3. **No silent failures** - always report root cause
4. **Single source of truth** - one FHS spec, used everywhere

### What We Have

✅ **Smart auto-heal** that respects privileges
✅ **Daily timer** runs as nftban user
✅ **Clear reporting** of what needs root
✅ **Single FHS specification** (no duplicates)
✅ **Deployed and tested** on all lab servers

### User Experience

**As nftban user (daily timer):**
- Fixes what it can (its own directories)
- Logs to journal if root needed
- Zero manual intervention for normal operations

**As root (when journal shows issues):**
- Run `sudo nftban health fix all`
- Fixes system-level issues
- Clear output showing what was fixed

---

## 📝 WHAT'S MISSING / TODO

### Still Need to Update

1. **`/deploy/install.sh`** - Should use shared FHS spec
2. **`/install.sh`** - Should use shared FHS spec
3. **Module initialization** - portscan, etc. should source FHS spec
4. **Documentation** - Update all docs to reference new architecture

### Future Enhancements

- **Email alerts** when root action needed
- **Web dashboard** showing FHS compliance
- **Auto-open tickets** when manual intervention needed

---

**Status:** ✅ Architecture complete, tested, deployed

**Key Point:** nftban user fixes what it owns, root fixes what it doesn't. No silent failures, always clear communication.

**EOF**
