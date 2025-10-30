# NFTBan v0.10.0 - Atomic Reload Fix (Duplicate Rules Bug)
**Date:** 2025-10-30
**Severity:** 🔴 CRITICAL
**Bug ID:** #6
**Status:** ✅ FIXED AND DEPLOYED

═══════════════════════════════════════════════════════════════════

## 🐛 BUG #6: Duplicate Rules on Reload (CRITICAL)

### Problem Discovery

**Reported By:** User (avoulvoulis)
**Discovery Date:** 2025-10-30
**Affected Servers:** All 3 labs (lab, lab1, lab2)

### Symptoms

When checking `nft list chain inet nftban_main input_main`, the same rules appeared **8 times**:

```nft
chain input_main {
    type filter hook input priority raw; policy accept;
    ct state established,related accept    # ← Rule 1
    iif "lo" accept
    ip saddr @whitelist_v4 accept
    ...
    ct state established,related accept    # ← Rule 2 (DUPLICATE!)
    iif "lo" accept
    ip saddr @whitelist_v4 accept
    ...
    ct state established,related accept    # ← Rule 3 (DUPLICATE!)
    ...
    # (repeated 8 times total!)
}
```

**Impact:**
- **Performance degradation** - Every packet processed 8x
- **Memory waste** - 8x more rules than needed
- **Confusion** - Hard to debug firewall issues
- **Growing problem** - Each reload adds more duplicates

---

## 🔍 ROOT CAUSE ANALYSIS

### Architecture Understanding (2-Table Design)

NFTBan v0.10.0 uses a **two-table architecture**:

1. **`inet nftban_runtime`** - Temporary bans (fail2ban)
   - Sets with timeout
   - Modified by fail2ban actions
   - Never rebuilt from scratch

2. **`inet nftban_main`** - Permanent rules
   - Whitelist/blacklist/ports
   - Built from `/etc/nftban/*.d/*.conf` files
   - **Atomically reloaded** when configs change

### The Bug

**File:** `src/usr/sbin/nftban-complete`
**Function:** `nftban_build_main()`
**Lines:** 262-268 (before fix)

**Problematic Code:**
```bash
# ---- Apply the rules ----------------------------------------------------

nft -c -f "$OUT" || { echo "ERROR: nftables validation failed!"; cat "$OUT"; return 1; }
nft -f "$OUT"   # ← BUG: This ADDS rules to existing chain!

nftban_log_json info reload '"message":"Reloaded nftban_main from configs"'
echo "✓ nftban_main applied from $OUT"
```

**Why It Failed:**

The generated file `/run/nftban/nftban_main.nft` contains:

```nft
table inet nftban_main {
  set whitelist_v4 { ... }
  set whitelist_v6 { ... }
  ...

  chain input_main {
    type filter hook input priority -300; policy accept;

    ct state established,related accept    # ← These rules
    iif lo accept                           # ← are defined
    ip saddr @whitelist_v4 accept           # ← in the chain
    ...
  }
}
```

When you run `nft -f file.nft`:
1. **If table doesn't exist:** Creates table + sets + chain + rules ✅
2. **If table EXISTS:** nftables does:
   - Table already exists → skip creation
   - Sets already exist → **merge elements**
   - Chain already exists → **ADD rules to existing chain** ❌

**Result:** Every time you reload, it **ADDS** another copy of all rules!

---

## ✅ THE FIX

### Correct Atomic Reload Pattern

The correct pattern for atomic reload is:

1. **Validate** new config
2. **Flush table** (remove rules but keep sets)
3. **Load** new rules

**Why flush instead of delete?**

- `delete table` → **Destroys everything** (sets lose data)
- `flush table` → **Keeps sets with data, removes rules** ✅

### Implementation

**File:** `src/usr/sbin/nftban-complete`
**Lines:** 262-275 (after fix)

```bash
# ---- Apply the rules ----------------------------------------------------

nft -c -f "$OUT" || { echo "ERROR: nftables validation failed!"; cat "$OUT"; return 1; }

# ATOMIC RELOAD: Flush all rules/chains but keep sets (preserves data)
if nft list table inet nftban_main >/dev/null 2>&1; then
  nft flush table inet nftban_main
fi

# Now load the new rules (no duplicates because we flushed first)
nft -f "$OUT"

nftban_log_json info reload '"message":"Reloaded nftban_main from configs"'
echo "✓ nftban_main applied from $OUT"
```

**What This Does:**

1. **`nft -c -f "$OUT"`** - Validate syntax (fail early if bad config)
2. **`if nft list table ...`** - Check if table exists
3. **`nft flush table inet nftban_main`** - Remove ALL rules/chains but **KEEP SETS**
4. **`nft -f "$OUT"`** - Load fresh rules (no duplicates!)

### What Gets Preserved

After `flush table`:

**REMOVED (cleaned):**
- All rules in chains ✓
- Chain definitions ✗ (recreated by nft -f)

**PRESERVED (kept):**
- All sets (whitelist_v4, whitelist_v6, etc.) ✓
- Set elements (IP addresses, ports) ✓
- Set timeouts (for temp_ban sets) ✓

**Result:** Clean reload, no data loss!

---

## 📊 BEFORE vs AFTER

### Before Fix

```bash
# First reload
$ nftban-complete nftables reload
$ nft list chain inet nftban_main input_main | grep -c 'ct state established'
1   # OK

# Second reload
$ nftban-complete nftables reload
$ nft list chain inet nftban_main input_main | grep -c 'ct state established'
2   # DUPLICATE!

# Third reload
$ nftban-complete nftables reload
$ nft list chain inet nftban_main input_main | grep -c 'ct state established'
3   # MORE DUPLICATES!

# On server1.example.com (after 8 reloads)
$ nft list chain inet nftban_main input_main | grep -c 'ct state established'
8   # 8 COPIES OF EVERY RULE!
```

### After Fix

```bash
# First reload
$ nftban-complete nftables reload
✓ nftban_main applied from /run/nftban/nftban_main.nft
$ nft list chain inet nftban_main input_main | grep -c 'ct state established'
1   # OK

# Second reload
$ nftban-complete nftables reload
✓ nftban_main applied from /run/nftban/nftban_main.nft
$ nft list chain inet nftban_main input_main | grep -c 'ct state established'
1   # STILL 1! ✅

# Third reload
$ nftban-complete nftables reload
✓ nftban_main applied from /run/nftban/nftban_main.nft
$ nft list chain inet nftban_main input_main | grep -c 'ct state established'
1   # STILL 1! ✅

# Can reload 1000 times, always clean!
```

---

## 🧪 TESTING RESULTS

### Test Environment

**Servers Tested:**
- server1.example.com (CentOS Stream 9)
- server2.example.com (Ubuntu 24.04)
- server3.example.com (CentOS Stream 10)

### Test Procedure

```bash
# 1. Deploy fixed version
scp nftban-complete root@lab:/usr/sbin/nftban-complete
ssh root@lab "chmod +x /usr/sbin/nftban-complete"

# 2. Test reload (should flush and clean)
ssh root@lab "/usr/sbin/nftban-complete nftables reload"

# 3. Count rules (should be 1 per rule type)
ssh root@lab "nft list chain inet nftban_main input_main | grep -c 'ct state established'"
```

### Results

| Server | Before Fix | After Fix | Status |
|--------|------------|-----------|--------|
| **lab** | 8 duplicates | 1 rule | ✅ FIXED |
| **lab1** | 8 duplicates | 1 rule | ✅ FIXED |
| **lab2** | 8 duplicates | 1 rule | ✅ FIXED |

### Verification Commands

```bash
# Check for duplicates on all servers
for server in server1.example.com server2.example.com server3.example.com; do
  echo "=== $server ==="
  ssh root@$server "nft list chain inet nftban_main input_main | grep -c 'ct state established'"
done

# Expected output:
# === server1.example.com ===
# 1
# === server2.example.com ===
# 1
# === server3.example.com ===
# 1
```

**Result:** ✅ All servers showing **1** rule (no duplicates)

---

## 📁 FILES MODIFIED

| File | Change | Lines |
|------|--------|-------|
| `src/usr/sbin/nftban-complete` | Added flush table before reload | 262-275 |

### Exact Changes

```diff
--- a/src/usr/sbin/nftban-complete
+++ b/src/usr/sbin/nftban-complete
@@ -262,7 +262,14 @@ nftban_build_main() {
   # ---- Apply the rules ----------------------------------------------------

   nft -c -f "$OUT" || { echo "ERROR: nftables validation failed!"; cat "$OUT"; return 1; }
+
+  # ATOMIC RELOAD: Flush all rules/chains but keep sets (preserves data)
+  if nft list table inet nftban_main >/dev/null 2>&1; then
+    nft flush table inet nftban_main
+  fi
+
+  # Now load the new rules (no duplicates because we flushed first)
   nft -f "$OUT"

   nftban_log_json info reload '"message":"Reloaded nftban_main from configs"'
   echo "✓ nftban_main applied from $OUT"
```

---

## 🎓 LESSONS LEARNED

### 1. Read the Documentation FIRST

**What Happened:**
- Initial fix attempt was to add `delete table` before reload
- User correctly stopped me and said "READ DOCS ABOUT 2-TABLE ATOMIC RELOAD"
- After reading docs, discovered the correct pattern was `flush table`

**Lesson:** Always understand the architecture before fixing bugs!

### 2. nftables Table Operations

**Three operations, different effects:**

| Command | Sets | Chains | Rules | Use Case |
|---------|------|--------|-------|----------|
| `delete table` | ❌ Lost | ❌ Lost | ❌ Lost | Complete removal |
| `flush table` | ✅ Kept | ❌ Removed | ❌ Removed | **Atomic reload** ✅ |
| `flush chain` | ✅ Kept | ✅ Kept | ❌ Removed | Single chain reload |

**For atomic reload:** Use `flush table` to preserve data!

### 3. Test Edge Cases

**What We Missed:**
- Tested initial creation ✓
- Didn't test repeated reloads ✗

**Result:** Bug only appeared after multiple reloads

**Lesson:** Always test operations multiple times in sequence!

### 4. Two-Table Architecture Benefits

**Why use two tables?**

1. **`nftban_runtime`** (temporary bans)
   - Modified by fail2ban (live updates)
   - Never fully rebuilt
   - Sets with timeout

2. **`nftban_main`** (permanent rules)
   - Built from config files
   - Atomically reloaded
   - No timeout

**Benefit:** Can reload main table without affecting runtime bans!

---

## 🚀 DEPLOYMENT STATUS

### Deployed To

✅ **server1.example.com** (CentOS Stream 9)
- Deployed: 2025-10-30
- Verified: Clean rules, no duplicates
- Status: WORKING

✅ **server2.example.com** (Ubuntu 24.04)
- Deployed: 2025-10-30
- Verified: Clean rules, no duplicates
- Status: WORKING

✅ **server3.example.com** (CentOS Stream 10)
- Deployed: 2025-10-30
- Verified: Clean rules, no duplicates
- Status: WORKING

### Deployment Commands

```bash
# Deploy to all labs
for server in server1.example.com server2.example.com server3.example.com; do
  echo "=== Deploying to $server ==="
  scp /home/gituser/nftban-v0.10.0-dev/src/usr/sbin/nftban-complete \
      root@$server:/usr/sbin/nftban-complete
  ssh root@$server "chmod +x /usr/sbin/nftban-complete"
  ssh root@$server "/usr/sbin/nftban-complete nftables reload"
done
```

---

## 🔍 VERIFICATION CHECKLIST

After applying this patch, verify:

```bash
# 1. Check rules are clean (should be 1)
nft list chain inet nftban_main input_main | grep -c 'ct state established'

# 2. Check sets are preserved
nft list set inet nftban_main whitelist_v4
nft list set inet nftban_main whitelist_v6

# 3. Test reload multiple times
/usr/sbin/nftban-complete nftables reload
/usr/sbin/nftban-complete nftables reload
/usr/sbin/nftban-complete nftables reload

# 4. Verify still only 1 rule
nft list chain inet nftban_main input_main | grep -c 'ct state established'

# 5. Verify SSH still works
ssh root@server "echo 'SSH works!'"

# 6. Verify fail2ban still works
fail2ban-client status sshd
```

**Expected Results:**
- ✅ Always 1 rule (no duplicates)
- ✅ Sets keep their elements
- ✅ SSH connection works
- ✅ fail2ban bans still active

---

## 📝 RELATED DOCUMENTATION

This fix relates to:

1. **Two-Table Architecture**
   - `docs/architecture/NFTBAN_NFTABLES_HLD.md`
   - Explains priority order and table separation

2. **Atomic Reload Design**
   - `docs/architecture/MAIN_TABLE_EXPLANATION.md`
   - Explains why we use flush instead of delete

3. **Complete Architecture Review**
   - `docs/architecture/COMPLETE_NFTBAN_ARCHITECTURE_REVIEW.md`
   - Full system design documentation

---

## 🐛 BUG SUMMARY TABLE

| Bug # | Name | Severity | Status | Fix Date |
|-------|------|----------|--------|----------|
| #1 | LOCKOUT BUG (policy drop) | 🔴 CRITICAL | ✅ FIXED | 2025-10-29 |
| #2 | Arithmetic Bug (silent exit) | 🟠 HIGH | ✅ FIXED | 2025-10-29 |
| #3 | Hardcoded SSH Port | 🟡 MEDIUM | ✅ FIXED | 2025-10-29 |
| #4 | Systemd Boot Hang | 🟠 HIGH | ✅ FIXED | 2025-10-29 |
| #5 | Cross-OS Path Issues | 🟠 HIGH | ✅ FIXED | 2025-10-29 |
| **#6** | **Duplicate Rules on Reload** | 🔴 **CRITICAL** | ✅ **FIXED** | **2025-10-30** |

---

## ✅ BOTTOM LINE

**Problem:** `nft -f` was adding duplicate rules on every reload

**Root Cause:** Missing `flush table` before loading new rules

**Fix:** Add `nft flush table inet nftban_main` before `nft -f`

**Result:**
- ✅ Clean rules on every reload
- ✅ Sets preserved (no data loss)
- ✅ Tested on all 3 servers
- ✅ Production ready

**Acknowledgment:** Thank you to user (avoulvoulis) for:
1. Discovering the bug
2. Stopping incorrect fix attempt
3. Directing to read documentation
4. Understanding 2-table atomic reload architecture

**This is a perfect example of why understanding architecture is critical before fixing bugs!**

---

**Document Version:** 1.0
**Created:** 2025-10-30
**Status:** ✅ COMPLETE - BUG FIXED AND DEPLOYED
**Tested:** 3 servers (all passing)

═══════════════════════════════════════════════════════════════════
