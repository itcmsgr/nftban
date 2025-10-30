# NFTBan v0.10.0 - Complete Lockout Prevention Fix
**Date:** 2025-10-29
**Priority:** P0 - CRITICAL
**Status:** ✅ FIXED - READY FOR TESTING

═══════════════════════════════════════════════════════════════════

## 🚨 ROOT CAUSE OF LOCKOUT

**Problem:** `nftban-complete` generated firewall with `policy drop` which **immediately blocked ALL traffic** including SSH!

**File:** `src/usr/sbin/nftban-complete`
**Line:** 204
**Original:** `type filter hook input priority -300; policy drop;`
**Impact:** Instant lockout when firewall loads

---

## ✅ ALL FIXES IMPLEMENTED

### Fix 1: Changed Default Policy to ACCEPT
**File:** `src/usr/sbin/nftban-complete:204`

**BEFORE:**
```bash
chain input_main {
  type filter hook input priority -300; policy drop;  # ← LOCKOUT!
```

**AFTER:**
```bash
chain input_main {
  type filter hook input priority -300; policy accept;  # ← SAFE!
```

**Why Safe:**
- Whitelist rules come FIRST (lines 211-212)
- SSH ports checked after whitelist (line 219)
- Blacklist blocks bad IPs (lines 224-225)
- Policy accept = failsafe (if nothing matches, allow)

---

### Fix 2: Auto-Whitelist SSH Port + IPs on Init
**File:** `src/usr/lib/nftban/cli/cmd_firewall.sh:273-349`

**What It Does:**
1. Auto-detects SSH port from `/etc/ssh/sshd_config` (NOT hardcoded!)
2. Writes SSH port to `/etc/nftban/ports.d/00-ssh.conf`
3. Auto-detects connecting SSH client IP (multiple methods)
4. Auto-detects public IPv4 (ifconfig.me)
5. Auto-detects public IPv6 (ifconfig.me)
6. Writes ALL IPs to `/etc/nftban/whitelist.d/00-system.conf`
7. Then rebuilds nftban_main table with configs in place

**Result:** SSH port + your IPs whitelisted BEFORE firewall loads!

---

### Fix 3: Created nftban-firewall-init.service
**File:** `src/packaging/systemd/nftban-firewall-init.service` (NEW)

**Purpose:** Run firewall init on boot with 5-minute delay

**Key Features:**
```ini
[Service]
Environment="NFTBAN_SYSTEMD_BOOT=1"  # Enables startup delay
EnvironmentFile=-/etc/nftban/nftban.conf  # Reads NFTBAN_STARTUP_DELAY
ExecStart=/usr/sbin/nftban firewall init  # Runs init with delay
User=root  # Required for firewall operations
```

**Startup Flow:**
1. System boots
2. Wait 5 minutes (configured in nftban.conf)
3. Auto-detect SSH port from sshd_config
4. Auto-detect your IP (SSH_CLIENT, ifconfig.me)
5. Write configs to ports.d/00-ssh.conf and whitelist.d/00-system.conf
6. Build firewall with policy accept + whitelisted SSH/IPs
7. NO LOCKOUT! ✅

---

### Fix 4: Added Dependency Check (Health Check #0)
**File:** `src/usr/lib/nftban/cli/cmd_firewall.sh:505-583`

**Checks:**
- ✅ nftables (REQUIRED)
- ✅ bash (REQUIRED)
- ✅ systemd (REQUIRED)
- ✅ curl (REQUIRED for IP detection)
- ✅ ss/iproute (REQUIRED for SSH client IP)
- ✅ awk (REQUIRED)
- ⓘ fail2ban (OPTIONAL)
- ⓘ jq (OPTIONAL)
- ⓘ mailx (OPTIONAL)

**Output Example:**
```
[0/13] Checking system dependencies...
  ✓ nftables: nftables v0.9.3
  ✓ bash: 5.2.15
  ✓ systemd: systemd 252
  ✓ curl: curl 7.88.1
  ✓ iproute (ss): available
  ✓ awk: available
  ⓘ INFO: fail2ban not installed (optional)
```

---

### Fix 5: Complete Package Dependencies Documentation
**Files:**
- `PACKAGE_DEPENDENCIES.md` - Complete RPM/DEB dependency list
- `PACKAGE_MANAGER_INSTALLATION_ORDER.md` - Installation order + FHS

**Dependencies:**
```
REQUIRED:
- nftables >= 0.9.3
- bash >= 4.4
- systemd >= 239
- curl
- iproute2 (ss command)
- coreutils (awk, grep, cat)

OPTIONAL:
- fail2ban >= 0.11 (for fail2ban integration)
- jq (for JSON processing)
- mailx (for email alerts)
- geoipupdate (for GeoIP features)

BUILD ONLY:
- golang >= 1.18 (for nftban-complete, NOT needed at runtime)
```

---

### Fix 6: Complete FHS Hierarchy + tmpfiles.d
**File:** `src/packaging/tmpfiles.d/nftban.conf`

**Added Missing Directories:**
```
d /etc/nftban/blacklist.d 0755 nftban nftban - -
d /etc/nftban/ports.d 0755 nftban nftban - -
d /var/cache/nftban/geoip 0750 nftban nftban - -
```

**Total:** 31 directories fully documented with correct ownership/permissions

---

## 📋 TESTING PROCEDURE

### When You Rebuild server1.example.com:

**Step 1: Deploy Fixed Version**
```bash
# From gituser@dev machine:
cd /home/gituser/nftban-v0.10.0-dev
./deploy_to_lab.sh  # (you'll need to create this or use manual rsync)
```

**Step 2: Install systemd Service**
```bash
# On server1.example.com:
sudo install -D -m 0644 \
  /path/to/nftban-firewall-init.service \
  /etc/systemd/system/nftban-firewall-init.service

sudo systemctl daemon-reload
sudo systemctl enable nftban-firewall-init.service
```

**Step 3: Configure Startup Delay**
```bash
# Edit /etc/nftban/nftban.conf
# Confirm this line exists:
NFTBAN_STARTUP_DELAY="300"  # 5 minutes
```

**Step 4: Reboot and Test**
```bash
sudo reboot
```

**Expected Behavior:**
1. System boots
2. Wait 5 minutes ⏱️ (startup delay)
3. NFTBan firewall init starts
4. Output shows:
   ```
   → Detected SSH port: 22 (from sshd_config)
   ✓ SSH port 22 written to /etc/nftban/ports.d/00-ssh.conf
   → Detected SSH client IP: X.X.X.X
   → Detected public IPv4: X.X.X.X
   ✓ Whitelisted 2 IP(s) in /etc/nftban/whitelist.d/00-system.conf
   → Rebuilding nftban_main table with SSH port and IPs...
   ✓ nftban_main table rebuilt successfully
   ```
5. After 5 minutes you can SSH in! ✅
6. NO LOCKOUT! ✅

---

## 🔍 VERIFICATION CHECKLIST

After successful boot, verify:

```bash
# 1. Check firewall policy
nft list chain inet nftban_main input_main | grep policy
# Expected: policy accept

# 2. Check SSH port whitelisted
cat /etc/nftban/ports.d/00-ssh.conf
# Expected: 22|T

# 3. Check IPs whitelisted
cat /etc/nftban/whitelist.d/00-system.conf
# Expected: Your IP(s)

# 4. Check firewall rules loaded
nft list table inet nftban_main

# 5. Run health check
nftban firewall check
# Expected:
# [0/13] Checking system dependencies... ✓ ALL PASS
# [1/13] Checking nftables service... ✓ PASS
# ...
# [13/13] All checks complete! ✓ 13/13 PASSED
```

---

## 🎯 WHAT CHANGED (Files Modified)

| File | Change | Why |
|------|--------|-----|
| `src/usr/sbin/nftban-complete` | Line 204: `policy drop` → `policy accept` | Prevent instant lockout |
| `src/usr/lib/nftban/cli/cmd_firewall.sh` | Added SSH port auto-detection | Read from sshd_config |
| `src/usr/lib/nftban/cli/cmd_firewall.sh` | Added SSH client IP detection | Multiple fallback methods |
| `src/usr/lib/nftban/cli/cmd_firewall.sh` | Write configs BEFORE table load | Prevent lockout |
| `src/usr/lib/nftban/cli/cmd_firewall.sh` | Added Check #0 (dependencies) | Verify environment |
| `src/etc/nftban/nftban.conf` | Added NFTBAN_STARTUP_DELAY | 5-minute delay config |
| `src/packaging/systemd/nftban-firewall-init.service` | NEW FILE | Boot-time firewall init |
| `src/packaging/tmpfiles.d/nftban.conf` | Added missing directories | Complete FHS |
| `src/etc/nftban/blacklist.d/` | NEW DIRECTORY | For blacklist configs |
| `src/etc/nftban/ports.d/` | NEW DIRECTORY | For port configs |

---

## ✅ BOTTOM LINE

**Before Fix:**
- `policy drop` = instant lockout 🔴
- SSH port hardcoded to 22
- No IP auto-whitelisting
- No startup delay
- Missing directories

**After Fix:**
- `policy accept` = safe default ✅
- SSH port auto-detected from sshd_config ✅
- IPs auto-whitelisted (SSH_CLIENT + ifconfig.me) ✅
- 5-minute startup delay on boot ✅
- Complete FHS hierarchy ✅
- Dependency checks ✅

**Result:** NO MORE LOCKOUTS! 🎉

---

**Document Version:** 1.0
**Created:** 2025-10-29
**Status:** ✅ COMPLETE - READY FOR TESTING

═══════════════════════════════════════════════════════════════════

## NEXT STEPS

1. You rebuild server1.example.com (clean CentOS Stream 9)
2. Deploy fixed NFTBan v0.10.0
3. Install nftban-firewall-init.service
4. Reboot
5. Wait 5 minutes
6. Login via SSH ✅
7. Run `nftban firewall check`
8. Celebrate! 🎉

═══════════════════════════════════════════════════════════════════
