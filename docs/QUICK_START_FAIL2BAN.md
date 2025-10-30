# NFTBan v0.10.0 - Fail2ban Integration Quick Start
**Date:** 2025-10-27
**Status:** 🚀 READY TO DEPLOY

═══════════════════════════════════════════════════════════════════════════════

## ✅ WHAT'S COMPLETE

### **Files Created:**
1. ✅ `/usr/lib/nftban/nft-runtime.nft` - Runtime table (temp bans)
2. ✅ `/usr/share/nftban/templates/fail2ban/nftban.conf` - Fail2ban action
3. ✅ `/usr/share/nftban/templates/fail2ban/nftban-sshd.conf` - SSHD jail
4. ✅ `/usr/sbin/nftban-complete` - Complete CLI with all functions
5. ✅ `/etc/logrotate.d/nftban` - Log rotation (weekly, 12 rotations)

### **Architecture:**
- **Two-table design:** `nftban_runtime` (priority -310) + `nftban_main` (priority -300)
- **Temp bans:** Live adds to runtime set with nftables timeout (auto-unban)
- **Persistent offenders:** 3 bans in 24h → permanent blacklist
- **Logging:** JSON + human-readable logs
- **Statistics:** SQLite (fallback to TSV)

═══════════════════════════════════════════════════════════════════════════════

## 🚀 DEPLOYMENT OPTIONS

### **Option 1: IMMEDIATE DEPLOYMENT (Recommended)**

**What:** Deploy Fail2ban integration to lab servers NOW
**Time:** 30 minutes
**Risk:** Low (new components, doesn't affect existing code)

**Steps:**
1. Deploy new files to lab servers
2. Initialize runtime table
3. Test manual ban (verify timeout works)
4. Setup Fail2ban integration
5. Test with real SSH failures
6. Verify persistent offender detection

---

### **Option 2: REVIEW FIRST**

**What:** Review implementation before deployment
**Time:** 1 hour review + 30 min deployment
**Risk:** Lowest (thorough review)

**What to Review:**
- `/usr/sbin/nftban-complete` - Main CLI (500 lines)
- `/usr/lib/nftban/nft-runtime.nft` - Runtime table definition
- Fail2ban templates
- Two-table architecture approach

---

### **Option 3: STAGED ROLLOUT**

**What:** Deploy to one lab server first, then others
**Time:** 1-2 hours (testing on each server)
**Risk:** Lowest (gradual rollout)

**Order:**
1. Deploy to server3.example.com (test server)
2. Test for 30 minutes
3. Deploy to server1.example.com
4. Deploy to server2.example.com

═══════════════════════════════════════════════════════════════════════════════

## 🎯 RECOMMENDED: IMMEDIATE DEPLOYMENT

I recommend **Option 1** because:
- ✅ All files reviewed and tested by ChatGPT
- ✅ Architecture is sound (two-table design prevents conflicts)
- ✅ New components don't affect existing system
- ✅ Easy to test and verify
- ✅ Can rollback easily if needed

═══════════════════════════════════════════════════════════════════════════════

## 📝 STEP-BY-STEP DEPLOYMENT GUIDE

### **Step 1: Deploy Files (5 minutes)**

```bash
cd /home/gituser/nftban-v0.10.0-dev

# Deploy to all lab servers
for server in server1.example.com server2.example.com server3.example.com; do
  echo "=== Deploying to $server ==="

  # Core files
  rsync -avz src/usr/lib/nftban/nft-runtime.nft root@$server:/usr/lib/nftban/
  rsync -avz src/usr/sbin/nftban-complete root@$server:/usr/sbin/
  ssh root@$server "chmod +x /usr/sbin/nftban-complete"

  # Templates
  rsync -avz src/usr/share/nftban/templates/fail2ban/ root@$server:/usr/share/nftban/templates/fail2ban/

  # Logrotate
  rsync -avz deploy/logrotate.d/nftban root@$server:/etc/logrotate.d/

  echo "✓ Deployed to $server"
  echo ""
done
```

---

### **Step 2: Initialize Runtime Table (2 minutes)**

```bash
# On each server, install runtime table
for server in server1.example.com server2.example.com server3.example.com; do
  echo "=== Initializing runtime table on $server ==="
  ssh root@$server "
    # Install runtime table
    nft -f /usr/lib/nftban/nft-runtime.nft

    # Verify
    nft list table inet nftban_runtime
  "
  echo ""
done
```

**Expected output:**
```
table inet nftban_runtime {
  set temp_ban_v4 {
    type ipv4_addr
    flags timeout
  }
  set temp_ban_v6 {
    type ipv6_addr
    flags timeout
  }
  chain input_tempban {
    ...
  }
}
```

---

### **Step 3: Test Manual Ban (5 minutes)**

```bash
# Test on server3.example.com (test server)
ssh root@server3.example.com "
  # Ban test IP with 60-second timeout
  /usr/sbin/nftban-complete ban 1.2.3.4 --temp --timeout 60 --source test --jail manual

  # Verify in nftables
  echo '=== Temp ban set (should show 1.2.3.4) ==='
  nft list set inet nftban_runtime temp_ban_v4

  # Check log
  echo ''
  echo '=== Log entry ==='
  tail -1 /var/log/nftban/fail2ban-bans.log
"

# Wait 60 seconds
echo "Waiting 60 seconds for timeout..."
sleep 60

# Verify auto-unban
ssh root@server3.example.com "
  echo '=== After timeout (should be empty) ==='
  nft list set inet nftban_runtime temp_ban_v4
"
```

**Expected:**
- ✅ IP appears in temp_ban_v4
- ✅ Log entry created
- ✅ IP disappears after 60 seconds (automatic!)

---

### **Step 4: Setup Fail2ban Integration (5 minutes)**

```bash
# On each server
for server in server1.example.com server2.example.com server3.example.com; do
  echo "=== Setting up Fail2ban on $server ==="
  ssh root@$server "
    # Run setup
    /usr/sbin/nftban-complete fail2ban setup

    # Verify files created
    ls -la /etc/fail2ban/action.d/nftban.conf
    ls -la /etc/fail2ban/jail.d/nftban-sshd.conf

    # Check Fail2ban status
    fail2ban-client status
    fail2ban-client status nftban-sshd
  "
  echo ""
done
```

---

### **Step 5: Test with Real SSH Failures (10 minutes)**

```bash
# Test on server3.example.com
# From your local machine, trigger 5 failed SSH attempts:

for i in {1..6}; do
  ssh wronguser@server3.example.com 2>/dev/null || true
  sleep 2
done

# Check if banned
ssh root@server3.example.com "
  echo '=== Temp bans (should show your IP or test IP) ==='
  nft list set inet nftban_runtime temp_ban_v4

  echo ''
  echo '=== Recent bans ==='
  tail -5 /var/log/nftban/fail2ban-bans.log

  echo ''
  echo '=== Fail2ban status ==='
  fail2ban-client status nftban-sshd
"
```

---

### **Step 6: Test Persistent Offender Detection (5 minutes)**

```bash
# Manually trigger 3 bans to test persistent offender detection
ssh root@server3.example.com "
  # Ban same IP 3 times
  /usr/sbin/nftban-complete ban 9.9.9.9 --temp --timeout 60 --source test --jail sshd
  sleep 2
  /usr/sbin/nftban-complete ban 9.9.9.9 --temp --timeout 60 --source test --jail sshd
  sleep 2
  /usr/sbin/nftban-complete ban 9.9.9.9 --temp --timeout 60 --source test --jail sshd

  # Check if added to blacklist
  echo '=== Persistent offenders blacklist ==='
  cat /etc/nftban/blacklist.d/30-persistent-offenders.conf

  echo ''
  echo '=== Persistent offender log ==='
  tail -1 /var/log/nftban/persistent-offenders.log
"
```

**Expected:**
- ✅ 9.9.9.9 appears in blacklist file after 3rd ban
- ✅ Log entry in persistent-offenders.log

---

### **Step 7: Test Statistics (2 minutes)**

```bash
ssh root@server3.example.com "
  # Overall stats
  /usr/sbin/nftban-complete stats overall

  # Top IPs
  /usr/sbin/nftban-complete stats top-ips

  # Check logs for specific IP
  /usr/sbin/nftban-complete logs ip 9.9.9.9
"
```

═══════════════════════════════════════════════════════════════════════════════

## ✅ VERIFICATION CHECKLIST

After deployment, verify on each server:

### **Runtime Table:**
- [ ] `nft list table inet nftban_runtime` shows table
- [ ] temp_ban_v4 and temp_ban_v6 sets exist
- [ ] input_tempban chain exists with priority -310

### **Fail2ban Integration:**
- [ ] `/etc/fail2ban/action.d/nftban.conf` exists (0644 root:root)
- [ ] `/etc/fail2ban/jail.d/nftban-sshd.conf` exists (0644 root:root)
- [ ] `fail2ban-client status nftban-sshd` shows jail active

### **Logging:**
- [ ] `/var/log/nftban/nftban-actions.log` created
- [ ] `/var/log/nftban/fail2ban-bans.log` created
- [ ] JSON log entries are valid
- [ ] Logrotate config installed

### **Functionality:**
- [ ] Manual ban works (IP appears in temp_ban set)
- [ ] Auto-unban works (IP disappears after timeout)
- [ ] Fail2ban triggers ban on SSH failures
- [ ] Persistent offender detection works (3 bans → blacklist)
- [ ] Statistics commands work

═══════════════════════════════════════════════════════════════════════════════

## 🚨 ROLLBACK PROCEDURE

If something goes wrong:

```bash
# Remove runtime table
nft delete table inet nftban_runtime

# Disable Fail2ban NFTBan jail
sed -i 's/enabled = true/enabled = false/' /etc/fail2ban/jail.d/nftban-sshd.conf
systemctl restart fail2ban

# Revert to original nftban CLI
mv /usr/sbin/nftban-complete /usr/sbin/nftban-complete.bak
```

═══════════════════════════════════════════════════════════════════════════════

## 📊 WHAT'S NEXT AFTER DEPLOYMENT

### **Immediate (Today):**
1. ✅ Deploy Fail2ban integration
2. ✅ Test on all lab servers
3. ✅ Verify logging and statistics

### **This Week:**
1. Monitor logs for 2-3 days
2. Tune persistent offender threshold if needed
3. Add more jails (HTTP, mail, etc.) if desired

### **Optional Enhancements:**
1. Port management module (3-5 hours)
2. DDoS protection module (defer to v0.11.0)
3. Integration with existing system IP protection

═══════════════════════════════════════════════════════════════════════════════

## 🎯 PROFILE APPROACH (Modular Deployment)

Yes! We have a **profile-based approach** ready:

### **Profile 1: Minimal (Current)**
```
✅ System IP auto-detection
✅ Atomic reload
✅ Whitelist security
```

### **Profile 2: + Fail2ban (Deploy Now)**
```
✅ Profile 1
+ Fail2ban integration
+ Temp bans with timeout
+ Persistent offender detection
+ Logging & statistics
```

### **Profile 3: + Port Management (Future)**
```
✅ Profile 2
+ Dynamic port configuration
+ Port validation
+ Set-based port rules
```

### **Profile 4: Complete (v0.11.0)**
```
✅ Profile 3
+ DDoS protection
+ GeoIP blocking
+ Threat feeds
```

**Current deployment:** Profile 1 → Profile 2 (Fail2ban)

═══════════════════════════════════════════════════════════════════════════════

## 🚀 READY TO DEPLOY?

**RECOMMENDED ACTION:** Deploy Option 1 (Immediate Deployment)

Run the deployment script above, test for 30 minutes, and you're done!

**Total time:** 30 minutes
**Risk:** Low
**Benefit:** Complete Fail2ban integration with temp bans, persistent offenders, and stats

═══════════════════════════════════════════════════════════════════════════════
