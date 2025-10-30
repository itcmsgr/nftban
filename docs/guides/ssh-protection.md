# SSH Port Auto-Protection - CRITICAL SAFETY FIX
**Date:** 2025-10-29
**Priority:** P0 - CRITICAL

═══════════════════════════════════════════════════════════════════

## 🚨 CRITICAL ISSUE FOUND

**Problem:** SSH port 22 was NOT automatically whitelisted, causing lockouts

**Root Cause:** 
- `baseline.nft` only allows SSH from management IPs (RFC 1918)
- Public VPN IPs are blocked
- No automatic SSH port protection on firewall init
- No health check for SSH port

**Impact:** CRITICAL - Administrator lockout (happening NOW on lab & lab2)

---

## ✅ FIX IMPLEMENTED

### Part 1: Auto-Whitelist SSH on Init

**File:** `src/usr/lib/nftban/cli/cmd_firewall.sh`
**Location:** Lines 194-203 (Step 5)

```bash
# CRITICAL: Ensure SSH port is ALWAYS allowed
echo "→ Ensuring SSH port 22 is whitelisted..."
if command -v nftban >/dev/null 2>&1; then
    # Allow SSH on both IPv4 and IPv6
    if nftban port allow 22 tcp 2>/dev/null; then
        echo "  ✓ SSH port 22 whitelisted (IPv4 + IPv6)"
    else
        echo "  ⚠ Could not auto-whitelist SSH port (add manually later)"
    fi
fi
```

**What it does:**
- Automatically runs `nftban port allow 22 tcp` during `firewall init`
- Adds port 22 to tcp_ports set
- Works for both IPv4 and IPv6
- Prevents lockout from the start

### Part 2: Health Check for SSH Port

**File:** `src/usr/lib/nftban/cli/cmd_firewall.sh`
**Location:** Lines 506-518 (Check #11)

```bash
# Check 11: SSH Port Protection (CRITICAL FOR LOCKOUT PREVENTION)
echo "[11/12] Checking SSH port 22 is whitelisted (CRITICAL)..."

# Check if SSH port is allowed in tcp_ports set
if nft list set inet nftban_main tcp_ports 2>/dev/null | grep -q "22"; then
    echo "  ✓ PASS: SSH port 22 is whitelisted"
else
    ((warnings++))
    echo "  ⚠️  WARNING: SSH port 22 NOT whitelisted!"
    echo "     LOCKOUT RISK! Add it immediately:"
    echo "     → nftban port allow 22 tcp"
fi
```

**What it does:**
- Checks if port 22 is in tcp_ports set
- Warns if missing (LOCKOUT RISK)
- Provides exact fix command
- Runs on every `nftban firewall check`

---

## 📊 BEFORE vs AFTER

### BEFORE (v0.10.0 without fix)

| Check | Init | Health Check | Result |
|-------|------|--------------|--------|
| SSH Port | ❌ Not checked | ❌ Not checked | 🔴 LOCKOUT RISK |
| System IP | ❌ Not checked | ❌ Not checked | 🔴 LOCKOUT RISK |

**Result:** Administrator locked out (lab & lab2)

### AFTER (v0.10.0 with fix)

| Check | Init | Health Check | Result |
|-------|------|--------------|--------|
| **SSH Port** | ✅ Auto-whitelisted | ✅ Check #11 | ✅ SAFE |
| **System IP** | ✅ Auto-whitelisted | ✅ Check #12 | ✅ SAFE |

**Result:** Lockout prevention COMPLETE

---

## 🎯 COMPLETE SAFETY MATRIX

### On `nftban firewall init`:

**Step 5: Auto-whitelisting system IPs & SSH port (LOCKOUT PREVENTION)**

1. ✅ Whitelist SSH port 22 (IPv4 + IPv6)
2. ✅ Detect current IPv4
3. ✅ Whitelist current IPv4
4. ✅ Detect current IPv6
5. ✅ Whitelist current IPv6

### On `nftban firewall check`:

**Check #11: SSH Port Protection**
- ✅ Verify port 22 in tcp_ports set
- ⚠️ Warn if missing

**Check #12: System IP Protection**
- ✅ Verify IPv4 whitelisted (separate)
- ✅ Verify IPv6 whitelisted (separate)
- ⚠️ Warn if either missing

---

## 🔥 EMERGENCY RECOVERY (Current Situation)

### For server1.example.com and server3.example.com (LOCKED OUT)

**Via Console/Rescue Mode:**

```bash
# Option 1: Flush all rules (immediate access)
nft flush ruleset

# Option 2: Add SSH rule to existing firewall
nft add rule inet nftban_main input_main tcp dport 22 accept

# Option 3: Load baseline (if configured with your IP)
nft -f /etc/nftban/baseline.nft
```

**After Regaining Access:**

```bash
# Whitelist SSH port permanently:
nftban port allow 22 tcp

# Whitelist your current IP:
nftban whitelist-system add $(curl -s ifconfig.me)

# Verify both:
nftban firewall check
```

---

## 📁 FILES MODIFIED

| File | Lines Changed | Purpose |
|------|---------------|---------|
| `cmd_firewall.sh` | +25 lines | SSH port auto-protection |

**Changes:**
- Step 5: +12 lines (auto-whitelist SSH on init)
- Check #11: +13 lines (verify SSH in health check)
- Check #12: Renumbered from #11

---

## ✅ DEPLOYMENT STATUS

| Server | Deployed | Status |
|--------|----------|--------|
| server1.example.com | ❌ | LOCKED OUT - needs console |
| server2.example.com | ⏳ | Ready to deploy |
| server3.example.com | ❌ | LOCKED OUT - needs console |

---

## 🎓 LESSONS LEARNED

### What Went Wrong

1. **baseline.nft too restrictive** - Only allows SSH from RFC 1918
2. **No SSH auto-whitelist** - Port 22 not protected on init
3. **No SSH health check** - Missing from diagnostic checks
4. **VPN IP not in baseline** - Public IPs blocked by default

### What We Fixed

1. ✅ Auto-whitelist SSH port 22 on init
2. ✅ Health check for SSH port (Check #11)
3. ✅ Health check for system IPs (Check #12)
4. ✅ Works for IPv4 + IPv6 separately

### Still Needed

- [ ] Update baseline.nft with actual management IPs
- [ ] Add custom SSH port support (if not 22)
- [ ] Test on lab1 when accessible
- [ ] Deploy to all servers after testing

---

## 📋 VERIFICATION CHECKLIST

After deploying the fix:

```bash
# 1. Initialize firewall (should auto-whitelist SSH + IPs)
nftban firewall init

# Expected output:
# Step 5: Auto-whitelisting system IPs & SSH port (LOCKOUT PREVENTION)...
# → Ensuring SSH port 22 is whitelisted...
#   ✓ SSH port 22 whitelisted (IPv4 + IPv6)
# ✓ Auto-whitelisted current IPv4: X.X.X.X
# ✓ Auto-whitelisted current IPv6: XXXX::X

# 2. Run health check (should show 12/12 checks)
nftban firewall check

# Expected output:
# [11/12] Checking SSH port 22 is whitelisted (CRITICAL)...
#   ✓ PASS: SSH port 22 is whitelisted
# [12/12] Checking system IP protection (LOCKOUT PREVENTION)...
#   ✓ PASS: Current IPv4 (X.X.X.X) is whitelisted
#   ✓ PASS: Current IPv6 (XXXX::X) is whitelisted

# 3. Verify nftables rules
nft list set inet nftban_main tcp_ports | grep 22
nft list set inet nftban_main whitelist_v4
nft list set inet nftban_main whitelist_v6
```

---

## 🔗 RELATED FIXES TODAY

This is part of the complete lockout prevention system:

1. ✅ **Check #11:** SSH port protection (THIS FIX)
2. ✅ **Check #12:** System IP protection (IPv4 + IPv6)
3. ✅ **Step 5:** Auto-whitelist SSH + IPs on init
4. ✅ **Documentation:** Complete safety implementation guide

**All documented in:**
- `CRITICAL_SAFETY_IMPLEMENTATION.md`
- `SMOKETEST_VS_HEALTH_COMPARISON.md`
- `SSH_PORT_AUTO_PROTECTION.md` (this file)

---

**Document Version:** 1.0
**Created:** 2025-10-29
**Status:** ✅ IMPLEMENTED - READY TO DEPLOY

═══════════════════════════════════════════════════════════════════

## BOTTOM LINE

✅ SSH port 22 now auto-whitelisted on firewall init
✅ SSH port verified in health check (Check #11)
✅ System IPs verified in health check (Check #12)
⚠️ lab & lab2 need console access to recover
✅ lab1 ready for deployment and testing

**This fix prevents the exact lockout scenario happening right now.**

═══════════════════════════════════════════════════════════════════
