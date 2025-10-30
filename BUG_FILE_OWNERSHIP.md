# BUG: File Ownership - UNKNOWN:UNKNO in FHS Report
**Date:** 2025-10-30
**Severity:** 🟡 MEDIUM
**Status:** 🐛 IDENTIFIED - Need Fix

---

## 🐛 PROBLEM DESCRIPTION

FHS report shows directories/files as "UNKNOWN:UNKNO":

```
/usr/lib/nftban          755 root:root      755 UNKNOWN:UNKNO  ✖ ERROR
/usr/lib/nftban/cli      755 root:root      755 UNKNOWN:UNKNO  ✖ ERROR
/usr/lib/nftban/core     755 root:root      755 UNKNOWN:UNKNO  ✖ ERROR
/usr/share/nftban        755 root:root      755 UNKNOWN:UNKNO  ✖ ERROR
```

---

## 🔍 ROOT CAUSE

**What's happening:**
```bash
# On dev system:
$ ls -ldn /home/gituser/nftban-v0.10.0-dev/src/usr/lib/nftban
drwxr-xr-x 8 1002 1002 ...
# Owned by gituser (UID=1002, GID=1002)

# When copied with scp/rsync:
$ scp -r src/usr/lib/nftban root@lab1:/usr/lib/
# Preserves numeric UID/GID 1002

# On lab1 server:
$ ls -ldn /usr/lib/nftban
drwxr-xr-x 8 1002 1002 ...
# Still shows 1002, but user doesn't exist!

$ ls -ld /usr/lib/nftban
drwxr-xr-x 8 1002 1002 ...  # Shows numeric IDs
# Can't resolve to names → "UNKNOWN:UNKNO"

$ getent passwd 1002
# (no output - user doesn't exist on lab1)
```

**Why it happens:**
- `scp` preserves ownership by numeric UID/GID
- Dev system: UID 1002 = gituser
- Lab servers: UID 1002 doesn't exist
- FHS checker can't resolve numeric ID to names

---

## 📊 AFFECTED FILES

**All files copied from dev system:**
```
/usr/lib/nftban/              (entire tree)
/usr/share/nftban/            (entire tree)
/etc/nftban/                  (some files)
```

**Expected ownership:**
```
/usr/lib/nftban/      → root:root (system library)
/usr/share/nftban/    → root:root (shared data)
/etc/nftban/          → root:nftban (config)
/var/lib/nftban/      → nftban:nftban (runtime data)
/var/log/nftban/      → nftban:nftban (logs)
```

---

## ✅ SOLUTIONS

### Solution 1: Fix Deployment Script (BEST)

**Add ownership fixing to deployment:**
```bash
# After scp/rsync, fix ownership
for server in lab.mywebhost.gr lab1.mywebhost.gr lab2.mywebhost.gr; do
    echo "=== Deploying to $server ==="

    # Copy files
    rsync -av src/usr/lib/nftban/ root@$server:/usr/lib/nftban/

    # Fix ownership (NEW!)
    ssh root@$server 'chown -R root:root /usr/lib/nftban'
    ssh root@$server 'chown -R root:root /usr/share/nftban'
    ssh root@$server 'chown -R root:nftban /etc/nftban'
    ssh root@$server 'chown -R nftban:nftban /var/lib/nftban'
    ssh root@$server 'chown -R nftban:nftban /var/log/nftban'
done
```

### Solution 2: Use rsync --chown (ALTERNATIVE)

```bash
# rsync with ownership override
rsync -av --chown=root:root \
    src/usr/lib/nftban/ \
    root@$server:/usr/lib/nftban/
```

### Solution 3: Create Proper Deployment Script

**File:** `deploy_to_labs.sh`
```bash
#!/bin/bash
# Proper deployment with ownership fixing

set -e

SERVERS=(
    "lab.mywebhost.gr"
    "lab1.mywebhost.gr"
    "lab2.mywebhost.gr"
)

SOURCE_DIR="/home/gituser/nftban-v0.10.0-dev/src"

for server in "${SERVERS[@]}"; do
    echo "════════════════════════════════════════"
    echo "Deploying to: $server"
    echo "════════════════════════════════════════"

    # 1. Copy system libraries
    echo "→ Copying /usr/lib/nftban..."
    rsync -av --delete \
        "$SOURCE_DIR/usr/lib/nftban/" \
        "root@$server:/usr/lib/nftban/"

    ssh root@$server 'chown -R root:root /usr/lib/nftban'
    ssh root@$server 'chmod -R 755 /usr/lib/nftban'

    # 2. Copy shared data
    echo "→ Copying /usr/share/nftban..."
    rsync -av --delete \
        "$SOURCE_DIR/usr/share/nftban/" \
        "root@$server:/usr/share/nftban/"

    ssh root@$server 'chown -R root:root /usr/share/nftban'
    ssh root@$server 'chmod -R 755 /usr/share/nftban'

    # 3. Copy main binary
    echo "→ Copying /usr/sbin/nftban..."
    rsync -av \
        "$SOURCE_DIR/usr/sbin/nftban" \
        "root@$server:/usr/sbin/nftban"

    ssh root@$server 'chown root:root /usr/sbin/nftban'
    ssh root@$server 'chmod 755 /usr/sbin/nftban'

    # 4. Copy configs (preserve existing)
    echo "→ Copying configs..."
    rsync -av --ignore-existing \
        "$SOURCE_DIR/etc/nftban/" \
        "root@$server:/etc/nftban/"

    ssh root@$server 'chown -R root:nftban /etc/nftban'
    ssh root@$server 'chmod 750 /etc/nftban'
    ssh root@$server 'chmod 750 /etc/nftban/conf.d'

    # 5. Ensure runtime directories exist with correct ownership
    echo "→ Setting up runtime directories..."
    ssh root@$server '
        # Create if missing
        mkdir -p /var/lib/nftban/{metrics,reports,snapshots,exports}
        mkdir -p /var/log/nftban/reports
        mkdir -p /var/cache/nftban
        mkdir -p /run/nftban

        # Fix ownership
        chown -R nftban:nftban /var/lib/nftban
        chown -R nftban:nftban /var/log/nftban
        chown -R nftban:nftban /var/cache/nftban
        chown -R nftban:nftban /run/nftban

        # Fix permissions
        chmod 755 /var/lib/nftban
        chmod 750 /var/lib/nftban/{metrics,reports,snapshots,exports}
        chmod 750 /var/log/nftban
        chmod 750 /var/log/nftban/reports
        chmod 755 /var/cache/nftban
        chmod 755 /run/nftban
    '

    echo "✅ Deployment to $server complete!"
    echo ""
done

echo "════════════════════════════════════════"
echo "✅ All servers deployed successfully!"
echo "════════════════════════════════════════"
echo ""
echo "Verify FHS compliance:"
echo "  ssh root@lab1.mywebhost.gr 'nftban fhs'"
```

---

## 🔧 IMMEDIATE FIX

**Quick fix for current servers:**
```bash
for server in lab.mywebhost.gr lab1.mywebhost.gr lab2.mywebhost.gr; do
    ssh root@$server '
        # Fix system libraries
        chown -R root:root /usr/lib/nftban
        chown -R root:root /usr/share/nftban
        chown root:root /usr/sbin/nftban

        # Fix configs
        chown -R root:nftban /etc/nftban

        # Fix runtime dirs
        chown -R nftban:nftban /var/lib/nftban
        chown -R nftban:nftban /var/log/nftban
        chown -R nftban:nftban /var/cache/nftban
        chown -R nftban:nftban /run/nftban 2>/dev/null || true

        echo "✅ Fixed ownership on $server"
    '
done
```

---

## 🧪 TESTING

**After fix, verify:**
```bash
# 1. Check FHS report
ssh root@lab1.mywebhost.gr 'nftban fhs'

# Expected: No "UNKNOWN:UNKNO", all correct owners

# 2. Check specific directories
ssh root@lab1.mywebhost.gr 'ls -ld /usr/lib/nftban'
# Expected: drwxr-xr-x root root

ssh root@lab1.mywebhost.gr 'ls -ld /var/lib/nftban'
# Expected: drwxr-xr-x nftban nftban

# 3. Verify files are readable/executable
ssh root@lab1.mywebhost.gr 'nftban module'
# Expected: Works without permission errors
```

---

## 📝 LONG-TERM FIX

**Create proper deployment tooling:**

1. **Package-based deployment** (RPM/DEB)
   - Package manager handles ownership automatically
   - Proper permissions set in spec file

2. **Install script with ownership**
   - `make install` that sets correct ownership
   - Part of build process

3. **Deployment script** (current approach)
   - Use provided `deploy_to_labs.sh` above
   - Always fixes ownership after copy

---

## ⚠️ RELATED ISSUES

**Other ownership issues in FHS report:**

1. `/etc/nftban` expected `root:nftban`, actual `nftban:nftban`
   - Configs should be owned by root, readable by nftban group

2. `/var/log/nftban` expected `nftban:nftban`, actual `nftban:adm`
   - Group mismatch (minor)

3. Permission mismatches (750 vs 755)
   - Some directories have wrong permissions

**Fix all together:**
```bash
# Comprehensive fix
ssh root@SERVER '
    # System files: root:root, 755
    chown -R root:root /usr/lib/nftban /usr/share/nftban /usr/sbin/nftban
    chmod -R 755 /usr/lib/nftban /usr/share/nftban
    chmod 755 /usr/sbin/nftban

    # Configs: root:nftban, 750
    chown -R root:nftban /etc/nftban
    chmod 750 /etc/nftban /etc/nftban/conf.d

    # Runtime: nftban:nftban, 750 or 755
    chown -R nftban:nftban /var/lib/nftban /var/log/nftban /var/cache/nftban
    chmod 755 /var/lib/nftban /var/cache/nftban
    chmod 750 /var/lib/nftban/{metrics,reports,snapshots,exports}
    chmod 750 /var/log/nftban
'
```

---

## ✅ ACTION ITEMS

- [ ] Run immediate fix on all lab servers
- [ ] Create `deploy_to_labs.sh` script
- [ ] Test FHS compliance after fix
- [ ] Update deployment documentation
- [ ] Add ownership check to FHS report (already works!)
- [ ] Consider RPM/DEB packaging for production

---

**Priority:** MEDIUM (cosmetic issue, doesn't break functionality)

**Impact:** FHS report shows errors, files work fine but ownership is wrong

**Time to fix:** 15 minutes (run immediate fix + create deploy script)

---

**EOF**
