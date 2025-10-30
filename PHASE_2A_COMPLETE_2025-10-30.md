# NFTBan v0.10.0 - Phase 2A Complete: Stats Dashboard Fixed
**Date:** 2025-10-30
**Status:** ✅ PHASE 2A COMPLETE
**Next:** Phase 3 (Report Mechanism)

---

## 🎉 Phase 2A: Stats Dashboard Fix - COMPLETE!

### ✅ What Was Accomplished

#### **BUG-002: Stats Dashboard Not Reading NFTables Data - FIXED!**

**Problem (BEFORE):**
```bash
$ nftban stats dashboard
Total Bans: 0           ❌ WRONG - Should show actual bans
Active Bans: 0          ❌ WRONG - Should show 5
Whitelist Entries: 0    ❌ WRONG - Should show 3
```

**Root Cause:**
1. **Wrong Table Names**: Stats module was looking for OLD table/set names that don't exist anymore
   - Looking for: `nftban_runtime temp_ban` (doesn't exist)
   - Should use: `nftban_runtime temp_ban_v4` and `temp_ban_v6` (new unified structure)

2. **Wrong Table for Blacklist**: Stats was looking for old static tables
   - Looking for: `nftban_static_v4 user_blacklist` (doesn't exist)
   - Should use: `nftban_main blacklist_v4` and `blacklist_v6` (new unified structure)

3. **Reading Files Instead of NFTables**: Whitelist counter was reading from files that may not exist
   - Reading from: `/var/lib/nftban/whitelist_system.txt` (may not exist)
   - Should use: `nftban_main whitelist_v4` and `whitelist_v6` sets (single source of truth)

**Fixed (AFTER):**
```bash
$ nftban stats dashboard
[SUMMARY]
  Total Bans: 0           ✅ Correct (no historical bans)
  Unique IPs: 0           ✅ Correct
  Active Bans: 5          ✅ FIXED! (4 v4 + 1 v6)
  Whitelist Entries: 3    ✅ FIXED! (2 v4 + 1 v6)
```

---

## 🔧 Technical Changes

### **1. Fixed `nftban_stats_count_active_bans()` Function**

**File:** `/usr/lib/nftban/core/nftban_stats.sh` (lines 161-203)

**BEFORE (Broken - Looking for Old Tables):**
```bash
nftban_stats_count_active_bans() {
    local total=0

    # OLD: Wrong table name
    if nft list set inet nftban_runtime temp_ban &>/dev/null 2>&1; then
        temp=$(nft list set inet nftban_runtime temp_ban 2>/dev/null | \
               grep -c 'expires' || echo 0)
        total=$((total + temp))
    fi

    # OLD: Wrong table name
    if nft list set inet nftban_static_v4 user_blacklist &>/dev/null 2>&1; then
        static=$(nft list set inet nftban_static_v4 user_blacklist 2>/dev/null | \
                 grep -c 'elements' || echo 0)
        total=$((total + static))
    fi

    echo "$total"
}
```

**AFTER (Fixed - Using New Unified Structure):**
```bash
nftban_stats_count_active_bans() {
    local total=0

    # Count temp_ban_v4 (NEW unified structure)
    if nft list set inet nftban_runtime temp_ban_v4 &>/dev/null 2>&1; then
        local temp_v4
        temp_v4=$(nft list set inet nftban_runtime temp_ban_v4 2>/dev/null | grep -c 'timeout' 2>/dev/null)
        temp_v4=${temp_v4:-0}
        total=$((total + temp_v4))
    fi

    # Count temp_ban_v6 (NEW unified structure)
    if nft list set inet nftban_runtime temp_ban_v6 &>/dev/null 2>&1; then
        local temp_v6
        temp_v6=$(nft list set inet nftban_runtime temp_ban_v6 2>/dev/null | grep -c 'timeout' 2>/dev/null)
        temp_v6=${temp_v6:-0}
        total=$((total + temp_v6))
    fi

    # Count permanent blacklist_v4 (NEW unified structure)
    if nft list set inet nftban_main blacklist_v4 &>/dev/null 2>&1; then
        local black_v4
        black_v4=$(nft list set inet nftban_main blacklist_v4 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | wc -l 2>/dev/null)
        black_v4=${black_v4:-0}
        total=$((total + black_v4))
    fi

    # Count permanent blacklist_v6 (NEW unified structure)
    if nft list set inet nftban_main blacklist_v6 &>/dev/null 2>&1; then
        local black_v6
        black_v6=$(nft list set inet nftban_main blacklist_v6 2>/dev/null | grep -c '::' 2>/dev/null)
        black_v6=${black_v6:-0}
        total=$((total + black_v6))
    fi

    echo "$total"
}
```

**Key Changes:**
- ✅ Changed from `temp_ban` → `temp_ban_v4` and `temp_ban_v6`
- ✅ Changed from `nftban_static_v4` → `nftban_main`
- ✅ Changed from `user_blacklist` → `blacklist_v4` and `blacklist_v6`
- ✅ Added IPv6 support for both temporary and permanent bans
- ✅ Changed search pattern from `expires` → `timeout` (correct nftables syntax)
- ✅ Fixed variable handling: Use `${var:-0}` instead of `|| echo 0` (prevents "0 0" error)

### **2. Fixed `nftban_stats_count_whitelist()` Function**

**File:** `/usr/lib/nftban/core/nftban_stats.sh` (lines 205-229)

**BEFORE (Broken - Reading Files):**
```bash
nftban_stats_count_whitelist() {
    local total=0

    # OLD: Reading from files (may not exist)
    if [[ -f "/var/lib/nftban/whitelist_system.txt" ]]; then
        sys=$(grep -cvE '^#|^$' "/var/lib/nftban/whitelist_system.txt" 2>/dev/null || echo 0)
        total=$((total + sys))
    fi

    if [[ -f "/var/lib/nftban/whitelist_user.txt" ]]; then
        usr=$(grep -cvE '^#|^$' "/var/lib/nftban/whitelist_user.txt" 2>/dev/null || echo 0)
        total=$((total + usr))
    fi

    echo "$total"
}
```

**AFTER (Fixed - Reading NFTables):**
```bash
nftban_stats_count_whitelist() {
    local total=0

    # Read from nftables whitelist_v4 set (NEW unified structure)
    if nft list set inet nftban_main whitelist_v4 &>/dev/null 2>&1; then
        local wl_v4
        wl_v4=$(nft list set inet nftban_main whitelist_v4 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | wc -l 2>/dev/null)
        wl_v4=${wl_v4:-0}
        total=$((total + wl_v4))
    fi

    # Read from nftables whitelist_v6 set (NEW unified structure)
    if nft list set inet nftban_main whitelist_v6 &>/dev/null 2>&1; then
        local wl_v6
        wl_v6=$(nft list set inet nftban_main whitelist_v6 2>/dev/null | grep -c '::' 2>/dev/null)
        wl_v6=${wl_v6:-0}
        total=$((total + wl_v6))
    fi

    echo "$total"
}
```

**Key Changes:**
- ✅ Changed from reading files → reading nftables sets directly
- ✅ Single source of truth: `nftban_main whitelist_v4` and `whitelist_v6`
- ✅ Added IPv6 support
- ✅ Fixed variable handling: Use `${var:-0}` instead of `|| echo 0`

---

## 📊 Test Results (All Lab Servers)

### **Stats Dashboard Test:**

| Server | Active Bans | Whitelist | Breakdown | Status |
|--------|-------------|-----------|-----------|---------|
| **lab** | 5 | 3 | 4 temp_v4 + 1 temp_v6 = 5, 2 wl_v4 + 1 wl_v6 = 3 | ✅ **PASS** |
| **lab1** | 6 | 3 | 5 temp_v4 + 1 temp_v6 = 6, 2 wl_v4 + 1 wl_v6 = 3 | ✅ **PASS** |
| **lab2** | 4 | 3 | 4 temp_v4 + 0 temp_v6 = 4, 2 wl_v4 + 1 wl_v6 = 3 | ✅ **PASS** |

**Verification Commands:**
```bash
# Verify lab counts match dashboard
$ ssh root@lab.example.test 'nft list set inet nftban_runtime temp_ban_v4 | grep -c timeout'
4

$ ssh root@lab.example.test 'nft list set inet nftban_runtime temp_ban_v6 | grep -c timeout'
1

$ ssh root@lab.example.test 'nft list set inet nftban_main whitelist_v4 | grep -oP "\d+\.\d+\.\d+\.\d+" | wc -l'
2

$ ssh root@lab.example.test 'nft list set inet nftban_main whitelist_v6 | grep -c "::"'
1

✅ Dashboard shows: Active Bans: 5 (4+1), Whitelist: 3 (2+1) - CORRECT!
```

**Success Rate:** 100% (3/3 servers passed)

---

## 🐛 Bug Fixed: Arithmetic Expression Error

### **Issue During Development:**

**Error:**
```bash
/usr/lib/nftban/core/nftban_stats.sh: line 194: 0 0: syntax error in expression (error token is "0")
```

**Root Cause:**
```bash
# BROKEN: || echo 0 can output "0 0" if wc -l also outputs "0"
black_v4=$(nft list set inet nftban_main blacklist_v4 2>/dev/null | \
           grep -oP '\d+\.\d+\.\d+\.\d+' | wc -l 2>/dev/null || echo 0)
total=$((total + black_v4))  # FAILS if black_v4="0 0"
```

**Fix:**
```bash
# FIXED: Use parameter expansion instead of || echo 0
black_v4=$(nft list set inet nftban_main blacklist_v4 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | wc -l 2>/dev/null)
black_v4=${black_v4:-0}  # Safe: Default to 0 if empty
total=$((total + black_v4))  # WORKS: Always a single number
```

**Why This Works:**
- `wc -l` ALWAYS outputs a number (even if 0)
- `|| echo 0` was redundant and could cause "0 0" if both succeeded
- `${var:-0}` is the proper Bash way to provide a default value
- Applied this fix to ALL variable assignments in both functions

---

## 📁 Files Modified

### **Core Module:**
1. `/usr/lib/nftban/core/nftban_stats.sh`
   - **Modified:** `nftban_stats_count_active_bans()` - Use new table/set names, add IPv6 support
   - **Modified:** `nftban_stats_count_whitelist()` - Read from nftables instead of files, add IPv6 support
   - **Fixed:** Arithmetic expression handling (use `${var:-0}` instead of `|| echo 0`)
   - **Lines changed:** 161-203 (active bans), 205-229 (whitelist)

---

## 💡 Key Benefits

### **1. Single Source of Truth**
```bash
# BEFORE: Multiple sources of truth
- Files: /var/lib/nftban/whitelist_*.txt (may be stale)
- NFTables: nftban_main whitelist_v4 (actual runtime data)
- Inconsistency: Files != NFTables

# AFTER: One source of truth
- NFTables ONLY: nftban_main whitelist_v4/v6
- Consistency: Stats reflect actual firewall state
```

### **2. IPv6 Support Added**
```bash
# BEFORE: IPv4 only
- Only counted temp_ban (v4 only)
- Only counted user_blacklist (v4 only)

# AFTER: Full IPv6 support
- Counts temp_ban_v4 AND temp_ban_v6
- Counts blacklist_v4 AND blacklist_v6
- Counts whitelist_v4 AND whitelist_v6
```

### **3. Correct NFTables Syntax**
```bash
# BEFORE: Wrong pattern
grep -c 'expires'  ❌ nftables uses 'timeout', not 'expires'

# AFTER: Correct pattern
grep -c 'timeout'  ✅ Matches actual nftables output
```

### **4. Robust Error Handling**
```bash
# BEFORE: Fragile
var=$(command || echo 0)  # Could output "0 0"

# AFTER: Robust
var=$(command)
var=${var:-0}  # Safe default, prevents arithmetic errors
```

---

## 🔄 Architecture Alignment

### **NFTables Unified Structure (v0.10.0):**

```
┌─────────────────────────────────────────────────────────────┐
│  nftban_main (Main Table)                                   │
│  ├─ whitelist_v4 (Always wins)         ✅ Stats now reads  │
│  ├─ whitelist_v6 (Always wins)         ✅ Stats now reads  │
│  ├─ blacklist_v4 (Permanent bans)      ✅ Stats now reads  │
│  └─ blacklist_v6 (Permanent bans)      ✅ Stats now reads  │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│  nftban_runtime (Runtime Table)                             │
│  ├─ temp_ban_v4 (Temporary bans)       ✅ Stats now reads  │
│  └─ temp_ban_v6 (Temporary bans)       ✅ Stats now reads  │
└─────────────────────────────────────────────────────────────┘
```

**Before Phase 2A:** Stats module was looking for OLD table structure (didn't exist)
**After Phase 2A:** Stats module aligned with NEW unified structure ✅

---

## 📝 Usage Examples

### **View Stats Dashboard:**
```bash
$ nftban stats dashboard

═══════════════════════════════════════════════════════════════
  NFTBan Statistics Dashboard
═══════════════════════════════════════════════════════════════

[SYSTEM]
  Hostname: lab.example.test
  Period: 2025-10-29 to 2025-10-30
  Generated: 2025-10-30 06:00:42

[SUMMARY]
  Total Bans: 0              # Historical bans (from logs)
  Unique IPs: 0              # Unique IPs banned
  Active Bans: 5             # ✅ FIXED! Current nftables entries
  Whitelist Entries: 3       # ✅ FIXED! Current whitelist

[BAN SOURCES]
  Fail2Ban: 0
  Manual: 0
  Feeds: 0
```

### **Verify Counts Manually:**
```bash
# Check active bans
$ nft list set inet nftban_runtime temp_ban_v4 | grep -c timeout
4
$ nft list set inet nftban_runtime temp_ban_v6 | grep -c timeout
1
# Total: 4 + 1 = 5 ✅

# Check whitelist
$ nft list set inet nftban_main whitelist_v4
table inet nftban_main {
	set whitelist_v4 {
		type ipv4_addr
		elements = { 192.0.2.122, 95.216.159.238 }
	}
}
# Count: 2 IPv4 addresses

$ nft list set inet nftban_main whitelist_v6 | grep -c '::'
1
# Total: 2 + 1 = 3 ✅
```

---

## 🔍 What's Still To Do

### **Stats Features NOT Yet Implemented:**

1. **Historical Ban Tracking** - "Total Bans: 0"
   - Currently shows 0 because no historical tracking yet
   - Would require reading from journal/logs or database
   - Planned for future release

2. **Ban Source Breakdown** - "Fail2Ban: 0"
   - Currently shows 0 because no fail2ban integration yet
   - Would require reading fail2ban jail status
   - Planned for future release

3. **Top Jails Display** - Empty section
   - Would show which fail2ban jails are most active
   - Requires fail2ban integration
   - Planned for future release

4. **Top Banned IPs** - Empty section
   - Would show most frequently banned IPs
   - Requires historical tracking
   - Planned for future release

**Note:** These are ENHANCEMENTS, not bugs. The core stats functionality (Active Bans, Whitelist) is now WORKING ✅

---

## 🎯 Comparison with Phase 2

| Feature | Phase 2 | Phase 2A |
|---------|---------|----------|
| **Health orchestration** | ✅ Complete | N/A |
| **Health summary/json** | ✅ Complete | N/A |
| **Stats active bans** | ❌ Broken (BUG-002) | ✅ **FIXED!** |
| **Stats whitelist** | ❌ Broken (BUG-002) | ✅ **FIXED!** |
| **IPv6 support** | N/A | ✅ **ADDED!** |

---

## 🔄 Backward Compatibility

✅ **No breaking changes**

The stats dashboard interface remains the same:
```bash
nftban stats dashboard  # Still works (now with CORRECT data!)
```

---

## 🎊 Summary

**Phase 2A Implementation:**
- ✅ 1 file modified (nftban_stats.sh)
- ✅ 2 functions fixed (active bans, whitelist)
- ✅ 1 critical bug fixed (BUG-002)
- ✅ 3/3 tests passed (all servers)
- ✅ IPv6 support added
- ✅ Aligned with unified nftables structure

**What's Working:**
- ✅ Active bans counter: Reads from temp_ban_v4/v6 + blacklist_v4/v6
- ✅ Whitelist counter: Reads from whitelist_v4/v6 sets (not files)
- ✅ IPv6 support: All counters now support both v4 and v6
- ✅ Correct nftables syntax: Using 'timeout' instead of 'expires'
- ✅ Robust error handling: No more arithmetic expression errors

**What's Not Working (Future Enhancements):**
- ⏳ Historical ban tracking (Total Bans still shows 0)
- ⏳ Fail2ban integration (Ban Sources still shows 0)
- ⏳ Top Jails display (Empty section)
- ⏳ Top Banned IPs display (Empty section)

**What's Next:**
- 🟢 **Phase 3:** Report mechanism (file/email)

---

**Status:** 🎉 PHASE 2A COMPLETE - Stats Dashboard Fixed!

**Ready for Phase 3!**

**EOF**
