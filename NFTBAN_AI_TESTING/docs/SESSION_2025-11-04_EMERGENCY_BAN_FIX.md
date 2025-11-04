# NFTBan v0.30.0 - EMERGENCY FIX - Ban Command Security

**Date:** 2025-11-04 (Evening)
**Type:** 🚨 CRITICAL SECURITY FIX
**Status:** ✅ FIXED AND DEPLOYED
**AI Assistant:** Claude (Anthropic)

---

## 🚨 EMERGENCY SITUATION

### Incident Report

**Time:** 2025-11-04 23:15 UTC
**Severity:** CRITICAL
**Impact:** User accidentally banned server's own IPv6 address

**User Command:**
```bash
[root@lab ~]# nftban ban 2a01:4f9:c010:b0b5::1
[root@lab ~]# # Command succeeded - NO WARNING!
```

**Server IPs:**
- IPv4: `95.216.159.238`
- IPv6: `2a01:4f9:c010:b0b5::1` ← **BANNED BY MISTAKE!**

**Result:** User almost locked out of server via IPv6

---

## 🔍 Root Cause Analysis

### Critical Bug Discovered

**Problem:** `nftban ban` command does NOT check if IP is whitelisted before banning!

**Evidence:**
1. Server IPv6 was whitelisted in `/etc/nftban/whitelist.d/00-system.conf`
2. Ban command still accepted and executed the ban
3. IP was added to `temp_ban_v6` set with 1-hour timeout
4. **Whitelist protection FAILED**

### Why Whitelist Didn't Protect

**nftables Table Priority Order:**
```
table inet nftban_runtime {
  chain input_tempban {
    priority raw - 10;    # ← Checked FIRST
    ip6 saddr @temp_ban_v6 drop
  }
}

table inet nftban_main {
  chain input {
    priority 0;            # ← Checked SECOND
    ip6 saddr @whitelist_v6 accept
  }
}
```

**Result:** Ban rules run **BEFORE** whitelist rules!

**User was LUCKY:** Still connected because:
- Ban had 1-hour timeout (not permanent)
- IPv4 still worked
- No active IPv6-only connections

---

## ✅ FIXES APPLIED

### 1. Ban Command Whitelist Check

**Added Pre-Ban Validation:**
```bash
# CRITICAL: Check if IP is whitelisted
if grep -qr "^${ip}\s*$\|^${ip}\s*#" "$WL_DIR"/*.conf 2>/dev/null; then
  local wl_file
  wl_file=$(grep -lr "^${ip}\s*$\|^${ip}\s*#" "$WL_DIR"/*.conf 2>/dev/null | head -1)
  echo "ERROR: Cannot ban whitelisted IP: $ip" >&2
  echo "" >&2
  echo "This IP is protected in: $wl_file" >&2
  echo "" >&2
  echo "⚠️  SECURITY WARNING:" >&2
  echo "Banning whitelisted IPs could LOCK YOU OUT of the server!" >&2
  echo "" >&2
  echo "To ban this IP anyway:" >&2
  echo "  1. Remove from whitelist: sudo nano $wl_file" >&2
  echo "  2. Reload firewall: sudo nftban firewall reload" >&2
  echo "  3. Then ban: sudo nftban ban $ip" >&2
  return 1
fi
```

### 2. Fixed ban/unban No-Args Crash

**Before:**
```bash
$ nftban ban
/usr/sbin/nftban-complete: line 293: $1: unbound variable
```

**After:**
```bash
$ nftban ban
ERROR: IP address required
Usage: nftban ban <IP> [reason]
   or: nftban ban <IP> --timeout <time> [--reason <text>]
```

**Fix:**
```bash
# Before: ip="$1"; shift
# After:  ip="${1:-}"; shift || true

if [[ -z "$ip" ]]; then
  echo "ERROR: IP address required" >&2
  echo "Usage: nftban ban <IP> [reason]" >&2
  return 1
fi
```

### 3. Fixed ban help Command

**Before:**
```bash
$ nftban ban help
Error: Could not resolve hostname: Name or service not known
add element inet nftban_runtime temp_ban_v4 { help timeout 3600s }
```

**After:**
```bash
$ nftban ban help
Usage: nftban ban <IP> [reason]

Options:
  --timeout <time>   Ban duration (default: 1h)
  --reason <text>    Ban reason/comment
  --source <name>    Ban source (default: manual)
  --jail <name>      Jail name (for fail2ban)

Examples:
  nftban ban 203.0.113.1
  nftban ban 203.0.113.1 'Brute force attack'
  nftban ban 203.0.113.1 --timeout 24h --reason 'Repeated violations'
```

### 4. Added unban help Command

**New Feature:**
```bash
$ nftban unban help
Usage: nftban unban <IP>

Removes an IP from both temporary and permanent ban lists.

Examples:
  nftban unban 203.0.113.1
  nftban unban 2001:db8::1
```

---

## 🧪 Testing Results

### Test 1: Whitelist Protection

```bash
$ nftban ban 2a01:4f9:c010:b0b5::1 'test whitelist protection'
ERROR: Cannot ban whitelisted IP: 2a01:4f9:c010:b0b5::1

This IP is protected in: /etc/nftban/whitelist.d/00-system.conf

⚠️  SECURITY WARNING:
Banning whitelisted IPs could LOCK YOU OUT of the server!

To ban this IP anyway:
  1. Remove from whitelist: sudo nano /etc/nftban/whitelist.d/00-system.conf
  2. Reload firewall: sudo nftban firewall reload
  3. Then ban: sudo nftban ban 2a01:4f9:c010:b0b5::1
```

✅ **PASS** - Correctly blocks banning whitelisted IP

### Test 2: ban help

```bash
$ nftban ban help
Usage: nftban ban <IP> [reason]
(full help text displayed)
```

✅ **PASS** - Shows help instead of trying to ban "help"

### Test 3: ban No Args

```bash
$ nftban ban
ERROR: IP address required
Usage: nftban ban <IP> [reason]
   or: nftban ban <IP> --timeout <time> [--reason <text>]
```

✅ **PASS** - Shows usage instead of crashing

### Test 4: unban help

```bash
$ nftban unban help
Usage: nftban unban <IP>
(help text displayed)
```

✅ **PASS** - Help command working

---

## 🚀 Deployment

### Servers Updated

| Server | Status | Verified |
|--------|--------|----------|
| lab.mywebhost.gr | ✅ Deployed | ✅ Tested |
| lab1.mywebhost.gr | ✅ Deployed | ✅ Verified |
| lab2.mywebhost.gr | ✅ Deployed | ✅ Verified |
| lab3.mywebhost.gr | ✅ Deployed | ✅ Verified |
| lab4.mywebhost.gr | ✅ Deployed | ✅ Verified |

**Deployment Method:**
```bash
scp src/usr/sbin/nftban-complete root@SERVER:/usr/sbin/nftban-complete
ssh root@SERVER "chmod 755 /usr/sbin/nftban-complete"
```

**All 5 servers now protected!** ✅

---

## 📝 Git Commit

**Commit:** d68f5e0
**Message:** CRITICAL: Fix ban command to prevent banning whitelisted IPs

**Files Changed:**
- `src/usr/sbin/nftban-complete` (59 insertions, 3 deletions)

**Pushed to:** GitHub main branch

---

## ⚠️ Remaining Issue (Architecture)

### nftables Table Priority Problem

**Issue:** Ban table has higher priority than whitelist table

**Current Order:**
1. `nftban_runtime` (priority: raw - 10) ← **Ban rules** checked FIRST
2. `nftban_main` (priority: 0) ← **Whitelist rules** checked SECOND

**Problem:** Even with the ban command fix, if someone manually adds IPs to ban sets via nft command, whitelisted IPs can still be blocked.

**Solution Needed:**
- Change `nftban_runtime` priority to be AFTER `nftban_main`
- Or move whitelist check into `nftban_runtime` table

**Status:** ⏳ Deferred to next session (requires architecture change)

---

## 📊 Summary

### Bugs Fixed (4)

1. ✅ **CRITICAL:** Ban command bypassed whitelist protection
2. ✅ **HIGH:** ban/unban crash with no arguments
3. ✅ **MEDIUM:** ban help tries to ban IP "help"
4. ✅ **LOW:** unban help command missing

### Impact

**Before Fix:**
- ❌ Admins could accidentally lock themselves out
- ❌ No warning when banning whitelisted IPs
- ❌ Commands crash with bad input
- ❌ Help commands don't work

**After Fix:**
- ✅ Clear error message prevents server lockout
- ✅ Whitelist protection enforced in ban command
- ✅ Graceful error handling
- ✅ Help commands working properly

### Deployment Status

- ✅ All 5 lab servers updated
- ✅ Fix tested and verified
- ✅ Code committed to GitHub
- ✅ Production safe

---

## 🎯 Lessons Learned

1. **Defense in Depth:** Whitelist should be checked in MULTIPLE places:
   - ✅ Ban command (now fixed)
   - ⏳ nftables table priority (needs fix)

2. **User Input Validation:** Always validate ALL user inputs:
   - ✅ Empty arguments
   - ✅ Help keywords
   - ✅ Special values (whitelisted IPs)

3. **Clear Error Messages:** Users need actionable error messages:
   - ✅ What went wrong
   - ✅ Why it's dangerous
   - ✅ How to fix it

4. **Testing Critical Paths:** Need automated tests for:
   - Banning whitelisted IPs
   - No-args cases
   - Help commands

---

## 📋 Next Steps

### High Priority
1. ⏳ Fix nftables table priority (architecture change)
2. ⏳ Add automated tests for ban/unban commands
3. ⏳ Document whitelist protection in user docs

### Medium Priority
4. ⏳ Fix feeds enable performance (hangs CLI)
5. ⏳ Add progress indicator for long operations

### Low Priority
6. ⏳ Clean up old timer files
7. ⏳ Improve error messages further

---

## 👥 Contributors

- **User (itcmsgr):** Discovered bug by accidentally banning server IP
- **Claude (Anthropic):** Emergency fix, testing, deployment

---

## ✅ EMERGENCY RESOLVED

**Status:** 🎉 **FIXED AND DEPLOYED**

All 5 lab servers now have ban command protection against accidental lockout.

**Incident closed successfully.** ✅

---

**Document Status:** Emergency Session Closure
**Last Updated:** 2025-11-04 23:45 UTC
**Next Review:** Table priority architecture fix
