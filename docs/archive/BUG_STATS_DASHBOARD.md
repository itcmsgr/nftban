# BUG: Stats Dashboard Not Reading NFTables Data
**Date:** 2025-10-30
**Priority:** 🔴 HIGH
**Status:** 🐛 CONFIRMED BUG
**Phase:** Phase 2+ Enhancement

---

## 🐛 Problem Statement

`nftban stats dashboard` shows all zeros even though nftables has active data:

### Current (BROKEN):
```bash
$ nftban stats dashboard
[SUMMARY]
  Total Bans: 0              ❌ WRONG - Should be 10
  Unique IPs: 0              ❌ WRONG
  Active Bans: 0             ❌ WRONG - Should be 10
  Whitelist Entries: 0       ❌ WRONG - Should be 3
```

### Actual NFTables Data:
```bash
$ nft list ruleset
table inet nftban_runtime {
    set temp_ban_v4 {
        elements = { 10 IPs with timeout }  ✅ 10 ACTIVE BANS
    }
}
table inet nftban_main {
    set whitelist_v4 {
        elements = { 2 IPs }                ✅ 2 WHITELISTED
    }
    set whitelist_v6 {
        elements = { 1 IP }                 ✅ 1 WHITELISTED
    }
    set blacklist_v4 { }
    set blacklist_v6 { }
}
```

---

## 🔍 Root Cause Analysis

### Issue 1: **Outdated Table/Set Names**

**File:** `/usr/lib/nftban/core/nftban_stats.sh:171`

**Current Code (BROKEN):**
```bash
# Line 171-176
if nft list set inet nftban_runtime temp_ban &>/dev/null 2>&1; then
    local temp
    temp=$(nft list set inet nftban_runtime temp_ban 2>/dev/null | \
           grep -c 'expires' || echo 0)
    total=$((total + temp))
fi
```

**Problem:**
- ❌ Looking for: `nftban_runtime temp_ban` (OLD NAME - doesn't exist)
- ✅ Should be: `nftban_runtime temp_ban_v4` and `temp_ban_v6` (NEW UNIFIED STRUCTURE)

### Issue 2: **Wrong Static Table Names**

**File:** `/usr/lib/nftban/core/nftban_stats.sh:179-192`

**Current Code (BROKEN):**
```bash
# Line 179-192
if nft list set inet nftban_static_v4 user_blacklist &>/dev/null 2>&1; then
    user_v4=$(nft list set inet nftban_static_v4 user_blacklist 2>/dev/null | \
             grep -oP '\d+\.\d+\.\d+\.\d+' | wc -l || echo 0)
    total=$((total + user_v4))
fi
```

**Problem:**
- ❌ Looking for: `nftban_static_v4` and `nftban_static_v6` tables (OLD)
- ✅ Should be: `nftban_main` table with sets `blacklist_v4`/`blacklist_v6` (NEW)

### Issue 3: **Whitelist Not Reading from NFTables**

**File:** `/usr/lib/nftban/core/nftban_stats.sh:197-226`

**Current Code (BROKEN):**
```bash
# Line 205-223
# Only reads from files, not from nftables sets!
if [[ -f "/var/lib/nftban/whitelist_system.txt" ]]; then
    sys=$(grep -cvE '^#|^$' "/var/lib/nftban/whitelist_system.txt" 2>/dev/null || echo 0)
    total=$((total + sys))
fi
```

**Problem:**
- ❌ Only reads from **files** (which may not exist)
- ✅ Should read from **nftables sets**: `whitelist_v4` and `whitelist_v6`

---

## ✅ Required Fixes

### Fix 1: Update Active Bans Counter

**Location:** `nftban_stats.sh:163-195`

```bash
nftban_stats_count_active_bans() {
    # Count currently active bans in nftables (FIXED VERSION)
    local total=0

    # Count temp_ban_v4 (NEW NAME)
    if nft list set inet nftban_runtime temp_ban_v4 &>/dev/null 2>&1; then
        local temp_v4
        temp_v4=$(nft list set inet nftban_runtime temp_ban_v4 2>/dev/null | \
                  grep -c 'timeout' || echo 0)
        total=$((total + temp_v4))
    fi

    # Count temp_ban_v6 (NEW NAME)
    if nft list set inet nftban_runtime temp_ban_v6 &>/dev/null 2>&1; then
        local temp_v6
        temp_v6=$(nft list set inet nftban_runtime temp_ban_v6 2>/dev/null | \
                  grep -c 'timeout' || echo 0)
        total=$((total + temp_v6))
    fi

    # Count permanent blacklist_v4 (NEW TABLE)
    if nft list set inet nftban_main blacklist_v4 &>/dev/null 2>&1; then
        local black_v4
        black_v4=$(nft list set inet nftban_main blacklist_v4 2>/dev/null | \
                   grep -oP '\d+\.\d+\.\d+\.\d+' | wc -l || echo 0)
        total=$((total + black_v4))
    fi

    # Count permanent blacklist_v6 (NEW TABLE)
    if nft list set inet nftban_main blacklist_v6 &>/dev/null 2>&1; then
        local black_v6
        black_v6=$(nft list set inet nftban_main blacklist_v6 2>/dev/null | \
                   grep -c '::' || echo 0)
        total=$((total + black_v6))
    fi

    echo "$total"
}
```

### Fix 2: Update Whitelist Counter

**Location:** `nftban_stats.sh:197-226`

```bash
nftban_stats_count_whitelist() {
    # Count whitelist entries from nftables (FIXED VERSION)
    local total=0

    # Read from nftables whitelist_v4 set
    if nft list set inet nftban_main whitelist_v4 &>/dev/null 2>&1; then
        local wl_v4
        wl_v4=$(nft list set inet nftban_main whitelist_v4 2>/dev/null | \
                grep -oP '\d+\.\d+\.\d+\.\d+' | wc -l || echo 0)
        total=$((total + wl_v4))
    fi

    # Read from nftables whitelist_v6 set
    if nft list set inet nftban_main whitelist_v6 &>/dev/null 2>&1; then
        local wl_v6
        wl_v6=$(nft list set inet nftban_main whitelist_v6 2>/dev/null | \
                grep -c '::' || echo 0)
        total=$((total + wl_v6))
    fi

    echo "$total"
}
```

---

## 🎯 Enhanced Dashboard Requirements

Based on user request, the stats dashboard should show:

### **NEW: Unified NFTables + Fail2ban Dashboard**

```bash
$ nftban stats dashboard

════════════════════════════════════════════════════════════════
  NFTBan Statistics Dashboard
════════════════════════════════════════════════════════════════

[SYSTEM]
  Hostname: server2.example.com
  Period: Last 24 hours
  Generated: 2025-10-30 05:32:30

[SUMMARY]
  Total Bans: 10 (10 temp, 0 permanent)
  Unique IPs: 10
  Whitelist Entries: 3 (2 IPv4, 1 IPv6)
  Fail2ban Jails: 2 active

[NFTABLES STATUS]
  Runtime Bans:
    • temp_ban_v4: 10 IPs (with expiry times)
    • temp_ban_v6: 0 IPs

  Permanent:
    • blacklist_v4: 0 IPs
    • blacklist_v6: 0 IPs

  Whitelist:
    • whitelist_v4: 2 IPs
    • whitelist_v6: 1 IP

[FAIL2BAN STATUS]
  Active Jails:
    • nftban-sshd: 5 banned, 1 failed
    • sshd: 5 banned, 0 failed

[TOP BANNED IPs]
  1. 193.46.255.217  (expires in 55m)  [RU] fail2ban:nftban-sshd
  2. 193.46.255.99   (expires in 35m)  [RU] fail2ban:nftban-sshd
  3. 193.46.255.33   (expires in 20m)  [RU] fail2ban:nftban-sshd
  ...

[WHITELISTED IPs]
  1. 46.62.231.184     [GR] System whitelist
  2. 192.0.2.122     [GR] User whitelist
  3. 2a01:4f9:c013:31fe::1  [DE] Cloudflare

════════════════════════════════════════════════════════════════
```

### **Key Enhancements Needed:**

1. **✅ Read from NFTables directly** (not from files)
2. **✅ Integrate with fail2ban** - Show jail status
3. **✅ Show expiry times** for temp bans
4. **✅ Show GeoIP location** (if available)
5. **✅ Show source** (fail2ban jail, manual, feed)
6. **✅ List whitelisted IPs** with source
7. **✅ Real-time data** (not cached/outdated)

---

## 📋 Implementation Tasks

### Phase 2 Tasks (Core Fixes):

1. **Fix nftban_stats_count_active_bans()** - Use new table/set names
2. **Fix nftban_stats_count_whitelist()** - Read from nftables sets
3. **Add fail2ban integration** - Query jail status
4. **Add whitelist display** - Show all whitelisted IPs
5. **Test on all lab servers** - Verify counts match nft output

### Phase 3 Tasks (Enhanced Dashboard):

6. **Add GeoIP integration** - Show country codes
7. **Add expiry time display** - Parse timeout values
8. **Add ban source tracking** - Identify fail2ban jail
9. **Add real-time mode** - Auto-refresh dashboard
10. **Add export functionality** - JSON/CSV output

### Phase 4 Tasks (Advanced Features):

11. **Historical analytics** - Trending over time
12. **Attack pattern detection** - Identify scan patterns
13. **Automated reporting** - Daily/weekly email reports
14. **Integration with web UI** - REST API for dashboard data

---

## 🧪 Test Cases

### Test 1: Active Bans Count

**Setup:**
```bash
# Add test bans via fail2ban
fail2ban-client set nftban-sshd banip 1.2.3.4
fail2ban-client set nftban-sshd banip 5.6.7.8
```

**Expected:**
```bash
$ nftban stats dashboard
Total Bans: 2
Active Bans: 2
```

**Verify:**
```bash
$ nft list set inet nftban_runtime temp_ban_v4
# Should show 2 IPs
```

### Test 2: Whitelist Count

**Setup:**
```bash
# Whitelist already exists in nftables
$ nft list set inet nftban_main whitelist_v4
elements = { 46.62.231.184, 192.0.2.122 }
```

**Expected:**
```bash
$ nftban stats dashboard
Whitelist Entries: 3 (2 IPv4, 1 IPv6)
```

### Test 3: Fail2ban Integration

**Expected:**
```bash
$ nftban stats dashboard
[FAIL2BAN STATUS]
  • nftban-sshd: 10 banned
  • sshd: 0 banned
```

---

## 🔗 Related Files

- `/usr/lib/nftban/core/nftban_stats.sh` - Stats engine (needs fixes)
- `/usr/lib/nftban/cli/cmd_stats.sh` - CLI handler
- `/usr/lib/nftban/core/nftban_fail2ban.sh` - Fail2ban integration
- `/usr/lib/nftban/core/nftban_geoip_go.sh` - GeoIP lookups

---

## 📊 Priority Ranking

| Task | Priority | Effort | Impact |
|------|----------|--------|--------|
| Fix active bans counter | 🔴 CRITICAL | Small | High |
| Fix whitelist counter | 🔴 CRITICAL | Small | High |
| Add fail2ban integration | 🟠 HIGH | Medium | High |
| Show whitelisted IPs | 🟠 HIGH | Small | Medium |
| Add GeoIP display | 🟡 MEDIUM | Small | Medium |
| Add expiry times | 🟡 MEDIUM | Medium | Medium |
| Real-time mode | 🟢 LOW | Large | Low |

---

**Recommendation:** Implement **Phase 2 fixes** (tasks 1-5) immediately as they are critical bugs affecting basic functionality. Enhanced features (Phase 3-4) can be added incrementally.

**EOF**
