# ⚠️ CRITICAL: Remember Atomic Reload Pattern!
**IMPORTANT FOR FUTURE DEVELOPMENT**

═══════════════════════════════════════════════════════════════════

## 🚨 ALWAYS REMEMBER

When working with nftables table reloads in NFTBan:

**NEVER do this:**
```bash
nft -f file.nft   # ← WRONG! Adds duplicate rules!
```

**ALWAYS do this:**
```bash
# 1. Flush table first (keeps sets, removes rules)
nft flush table inet nftban_main

# 2. Then load new rules
nft -f file.nft   # ← CORRECT! No duplicates
```

---

## 📚 Why This Matters

### The Problem

When you use `nft -f file.nft` and the table already exists:

- **Sets:** Elements are MERGED (good!)
- **Chains:** Rules are **ADDED** to existing chains (BAD!)

**Result:** Every reload adds duplicate rules!

### The Solution

Use `nft flush table` before `nft -f`:

```bash
if nft list table inet nftban_main >/dev/null 2>&1; then
  nft flush table inet nftban_main  # Remove ALL rules/chains
fi
nft -f "$OUT"  # Load fresh rules
```

### What Gets Kept vs Removed

| Item | `flush table` Effect |
|------|---------------------|
| **Sets** | ✅ **KEPT** (with elements!) |
| **Set Elements** | ✅ **KEPT** (no data loss) |
| **Set Timeouts** | ✅ **KEPT** (temp bans stay) |
| **Chains** | ❌ **REMOVED** (recreated by nft -f) |
| **Rules** | ❌ **REMOVED** (no duplicates!) |
| **Table** | ✅ **KEPT** (just flushed) |

**Key Point:** `flush table` is perfect for atomic reload because it cleans rules but preserves data!

---

## 🏗️ NFTBan Architecture

### Two-Table Design

```
┌─────────────────────────────────────┐
│ inet nftban_runtime                 │
│ ─────────────────────────────       │
│ • Temporary bans (fail2ban)         │
│ • Modified by fail2ban actions      │
│ • Sets with timeout                 │
│ • NEVER fully rebuilt               │
└─────────────────────────────────────┘

┌─────────────────────────────────────┐
│ inet nftban_main                    │
│ ─────────────────────────────       │
│ • Permanent rules                   │
│ • Built from /etc/nftban/*.conf     │
│ • Atomically reloaded               │
│ • THIS ONE needs flush table!       │
└─────────────────────────────────────┘
```

### Why Two Tables?

1. **Runtime table** - Live updates (fail2ban bans/unbans)
2. **Main table** - Config-based (reloaded when configs change)

**Benefit:** Can reload main table without affecting runtime bans!

---

## 💻 Code Location

### Where This Is Implemented

**File:** `src/usr/sbin/nftban-complete`
**Function:** `nftban_build_main()`
**Lines:** 262-275

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

### When This Gets Called

- `nftban-complete nftables reload` - Manual reload
- `nftban firewall init` - During initialization (step 3 + step 5)
- `nftban firewall reload` - User command
- After config changes in `/etc/nftban/*.d/*.conf`

---

## 🧪 How to Test

### Verify No Duplicates

```bash
# 1. Reload multiple times
nftban-complete nftables reload
nftban-complete nftables reload
nftban-complete nftables reload

# 2. Count rules (should always be 1)
nft list chain inet nftban_main input_main | grep -c 'ct state established'

# Expected: 1 (not 2, 3, 4...)
```

### Verify Sets Are Preserved

```bash
# 1. Add some IPs to whitelist
echo "1.2.3.4" > /etc/nftban/whitelist.d/test.conf
nftban-complete nftables reload

# 2. Verify IP is in set
nft list set inet nftban_main whitelist_v4 | grep 1.2.3.4

# 3. Reload again
nftban-complete nftables reload

# 4. Verify IP still there
nft list set inet nftban_main whitelist_v4 | grep 1.2.3.4

# Expected: IP is still in the set (data preserved!)
```

---

## 📖 Related Documentation

1. **ATOMIC_RELOAD_FIX_PATCH.md** - Complete bug fix details
2. **DEPLOYMENT_SUMMARY_2025-10-30.md** - Bug #6 documentation
3. **docs/architecture/NFTBAN_NFTABLES_HLD.md** - Architecture design
4. **docs/architecture/MAIN_TABLE_EXPLANATION.md** - Table concepts

---

## ⚡ Quick Reference

### Three nftables Operations

```bash
# 1. Delete table (NEVER use for reload!)
nft delete table inet nftban_main
# ❌ Destroys EVERYTHING (sets, data, chains, rules)

# 2. Flush table (USE THIS for atomic reload!)
nft flush table inet nftban_main
# ✅ Keeps sets with data, removes chains/rules

# 3. Flush chain (for single chain reload)
nft flush chain inet nftban_main input_main
# ✅ Keeps chain, removes only rules in that chain
```

### When to Use Each

| Operation | Use Case | Sets | Data |
|-----------|----------|------|------|
| `delete table` | Complete removal | ❌ Lost | ❌ Lost |
| **`flush table`** | **Atomic reload** | ✅ **Kept** | ✅ **Kept** |
| `flush chain` | Single chain reload | ✅ Kept | ✅ Kept |

**For NFTBan main table reload:** Always use `flush table`!

---

## 🎓 Lesson Learned

### The Bug (2025-10-30)

**What Happened:**
- Used `nft -f file.nft` without flushing first
- Every reload added duplicate rules
- After 8 reloads: 8 copies of every rule!
- Performance degraded, debugging was confused

**The Fix:**
- Added `nft flush table inet nftban_main` before `nft -f`
- Now reloads cleanly every time
- Sets preserved, no data loss

**Key Takeaway:**
> "When reloading nftables tables, ALWAYS flush first to avoid duplicate rules. The flush operation preserves sets but removes chains/rules, making it perfect for atomic reloads."

---

## ✅ Checklist for Future Changes

When modifying `nftban_build_main()` or any table reload code:

- [ ] Does it use `nft flush table` before `nft -f`?
- [ ] Does it check if table exists first?
- [ ] Does it validate config with `nft -c -f` before applying?
- [ ] Does it preserve sets (no `delete table`)?
- [ ] Did you test multiple reloads in a row?
- [ ] Did you verify sets keep their elements?
- [ ] Did you count rules to ensure no duplicates?

**If you answered NO to any of these, review this document!**

---

## 🔗 Quick Links

- **Bug Report:** ATOMIC_RELOAD_FIX_PATCH.md
- **Code Location:** src/usr/sbin/nftban-complete:262-275
- **Test Command:** `nft list chain inet nftban_main input_main | grep -c 'ct state established'`
- **Expected Result:** Always `1` (never more!)

---

**Created:** 2025-10-30
**Priority:** 🔴 CRITICAL - DO NOT FORGET THIS!
**Status:** ✅ IMPLEMENTED AND DOCUMENTED

═══════════════════════════════════════════════════════════════════

## 🚨 FINAL REMINDER

```
┌────────────────────────────────────────────┐
│                                             │
│   BEFORE: nft -f file.nft                  │
│                                             │
│   AFTER:  nft flush table inet nftban_main │
│           nft -f file.nft                  │
│                                             │
│   This simple change prevents duplicate    │
│   rules and ensures atomic reload works!   │
│                                             │
└────────────────────────────────────────────┘
```

**NEVER FORGET THIS PATTERN!**
