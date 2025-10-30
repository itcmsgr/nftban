# NFTBan v0.10.0 - Testing Guide for Tomorrow
**Deployed:** 2025-10-27 21:43
**Status:** ✅ READY FOR TESTING

═══════════════════════════════════════════════════════════════════════════════

## ✅ WHAT'S DEPLOYED

Successfully deployed to **ALL 3 lab servers:**
- ✅ server1.example.com
- ✅ server2.example.com
- ✅ server3.example.com

**Components:**
- ✅ Runtime nftables table (temp bans with timeouts)
- ✅ Complete CLI (`/usr/sbin/nftban-complete`)
- ✅ Fail2ban integration (SSHD jail ACTIVE)
- ✅ Logging (JSON + human-readable)
- ✅ SQLite tracking (with TSV fallback)
- ✅ Persistent offender detection (3 bans in 24h → blacklist)

**Test ban verified:**
- ✅ Manual ban created (192.0.2.1)
- ✅ Appeared in temp_ban_v4 set
- ✅ Auto-expired after 30 seconds
- ✅ Log entry created

═══════════════════════════════════════════════════════════════════════════════

## 🧪 TESTING FOR TOMORROW

### **Test 1: Trigger Fail2ban SSH Ban**

**From your local machine:**
```bash
# Attempt 6 failed SSH logins to trigger ban (maxretry=5)
for i in {1..6}; do
  ssh wronguser@server1.example.com
  sleep 2
done
```

**Expected result:**
- After 5th failed attempt: IP banned for 1 hour
- Your IP added to temp_ban_v4 set
- Log entry in `/var/log/nftban/fail2ban-bans.log`

**Verify:**
```bash
# Check if you're banned
ssh root@server1.example.com "nft list set inet nftban_runtime temp_ban_v4"

# Check log
ssh root@server1.example.com "tail -5 /var/log/nftban/fail2ban-bans.log"

# Check Fail2ban status
ssh root@server1.example.com "fail2ban-client status nftban-sshd"
```

---

### **Test 2: Verify Auto-Unban (1 hour later)**

**After 1 hour, check:**
```bash
# Your IP should be gone from temp_ban set
ssh root@server1.example.com "nft list set inet nftban_runtime temp_ban_v4"

# You should be able to SSH again
ssh root@server1.example.com "echo 'Auto-unban worked!'"
```

---

### **Test 3: Persistent Offender Detection**

**Simulate 3 bans of same IP:**
```bash
ssh root@server1.example.com "
  # Ban test IP 3 times
  /usr/sbin/nftban-complete ban 9.9.9.9 --temp --timeout 60 --source test --jail sshd
  sleep 2
  /usr/sbin/nftban-complete ban 9.9.9.9 --temp --timeout 60 --source test --jail sshd
  sleep 2
  /usr/sbin/nftban-complete ban 9.9.9.9 --temp --timeout 60 --source test --jail sshd

  # Should be in blacklist now
  echo '=== Persistent Offenders Blacklist ==='
  cat /etc/nftban/blacklist.d/30-persistent-offenders.conf

  echo ''
  echo '=== Persistent Offender Log ==='
  tail -1 /var/log/nftban/persistent-offenders.log
"
```

**Expected:**
- After 3rd ban: 9.9.9.9 added to blacklist file
- Log entry in persistent-offenders.log

---

### **Test 4: Statistics & Logs**

**View statistics:**
```bash
ssh root@server1.example.com "
  # Overall stats
  /usr/sbin/nftban-complete stats overall

  # Top banned IPs
  /usr/sbin/nftban-complete stats top-ips

  # Top jails
  /usr/sbin/nftban-complete stats top-jails
"
```

**View logs:**
```bash
# All logs for specific IP
ssh root@server1.example.com "/usr/sbin/nftban-complete logs ip YOUR_IP"

# Recent bans
ssh root@server1.example.com "/usr/sbin/nftban-complete logs tail fail2ban-bans.log 50"

# JSON action log
ssh root@server1.example.com "/usr/sbin/nftban-complete logs tail nftban-actions.log 20"
```

═══════════════════════════════════════════════════════════════════════════════

## 📊 MONITORING COMMANDS

### **Check Current Temp Bans:**
```bash
ssh root@server1.example.com "nft list set inet nftban_runtime temp_ban_v4"
```

### **Check Recent Bans (last 10):**
```bash
ssh root@server1.example.com "tail -10 /var/log/nftban/fail2ban-bans.log"
```

### **Check Fail2ban Status:**
```bash
ssh root@server1.example.com "fail2ban-client status nftban-sshd"
```

### **Check Persistent Offenders:**
```bash
ssh root@server1.example.com "cat /etc/nftban/blacklist.d/30-persistent-offenders.conf"
```

### **Statistics Dashboard:**
```bash
ssh root@server1.example.com "
  echo '=== NFTBan Statistics ==='
  /usr/sbin/nftban-complete stats overall
  echo ''
  echo '=== Top 10 Banned IPs ==='
  /usr/sbin/nftban-complete stats top-ips
  echo ''
  echo '=== Today'\''s Bans ==='
  /usr/sbin/nftban-complete stats today
"
```

═══════════════════════════════════════════════════════════════════════════════

## ✅ VERIFICATION CHECKLIST

Tomorrow, verify:

### **Fail2ban Integration:**
- [ ] SSH failures trigger bans (test IP appears in temp_ban_v4)
- [ ] Bans expire after 1 hour (test IP disappears automatically)
- [ ] Logs created in `/var/log/nftban/fail2ban-bans.log`
- [ ] Fail2ban status shows banned IPs: `fail2ban-client status nftban-sshd`

### **Persistent Offenders:**
- [ ] 3 bans of same IP → added to blacklist file
- [ ] Log entry in `/var/log/nftban/persistent-offenders.log`
- [ ] Blacklist file created: `/etc/nftban/blacklist.d/30-persistent-offenders.conf`

### **Logging:**
- [ ] JSON logs in `/var/log/nftban/nftban-actions.log`
- [ ] Human logs in `/var/log/nftban/fail2ban-bans.log`
- [ ] Logs are structured and parseable

### **Statistics:**
- [ ] `nftban-complete stats overall` shows data
- [ ] `nftban-complete stats top-ips` shows banned IPs
- [ ] `nftban-complete stats today` shows today's bans
- [ ] SQLite database created at `/var/lib/nftban/nftban.db`

### **Architecture:**
- [ ] Runtime table exists: `nft list table inet nftban_runtime`
- [ ] Temp bans have timeout: `nft list set inet nftban_runtime temp_ban_v4`
- [ ] Priority correct: runtime (-310) before main (-300)

═══════════════════════════════════════════════════════════════════════════════

## 🐛 TROUBLESHOOTING

### **If Fail2ban doesn't ban:**
```bash
# Check Fail2ban logs
ssh root@server1.example.com "tail -50 /var/log/fail2ban.log | grep nftban"

# Check jail status
ssh root@server1.example.com "fail2ban-client status nftban-sshd"

# Restart Fail2ban
ssh root@server1.example.com "systemctl restart fail2ban"
```

### **If bans don't appear in nftables:**
```bash
# Check runtime table exists
ssh root@server1.example.com "nft list table inet nftban_runtime"

# Check CLI logs
ssh root@server1.example.com "tail -20 /var/log/nftban/nftban-actions.log"

# Test manual ban
ssh root@server1.example.com "/usr/sbin/nftban-complete ban 1.2.3.4 --temp --timeout 60 --source test --jail manual"
```

### **If logs are empty:**
```bash
# Check directory permissions
ssh root@server1.example.com "ls -la /var/log/nftban/"

# Check log files
ssh root@server1.example.com "ls -lh /var/log/nftban/*.log"
```

═══════════════════════════════════════════════════════════════════════════════

## 📈 WHAT TO EXPECT TOMORROW

### **Normal Operation:**
1. Fail2ban monitors SSH auth log via systemd journal
2. After 5 failed attempts within 10 minutes → ban IP for 1 hour
3. Ban added to `temp_ban_v4` set with 1h timeout
4. Log entry created in `fail2ban-bans.log`
5. Ban count tracked in SQLite database
6. After 1 hour → nftables automatically removes IP (no unban action needed!)

### **Persistent Offender Detection:**
1. If same IP gets banned 3+ times within 24 hours
2. IP added to `/etc/nftban/blacklist.d/30-persistent-offenders.conf`
3. Log entry in `persistent-offenders.log`
4. Next atomic reload → permanent ban (not just temporary)

### **Expected Log Entries:**

**fail2ban-bans.log:**
```
2025-10-28 08:15:23 [BAN] ip=1.2.3.4 jail=sshd timeout=3600s source=fail2ban
2025-10-28 08:20:45 [BAN] ip=5.6.7.8 jail=sshd timeout=3600s source=fail2ban
2025-10-28 09:12:08 [BAN] ip=1.2.3.4 jail=sshd timeout=3600s source=fail2ban
2025-10-28 10:05:19 [BAN] ip=1.2.3.4 jail=sshd timeout=3600s source=fail2ban
2025-10-28 10:05:19 [PERSISTENT] ip=1.2.3.4 jail=sshd action=blacklist reason="3 bans in 24h" count=3
```

**nftban-actions.log (JSON):**
```json
{"ts":"2025-10-28T08:15:23Z","level":"info","event":"ban","ip":"1.2.3.4","family":"ipv4","type":"temp","timeout":"3600s","source":"fail2ban","jail":"sshd","result":"success"}
{"ts":"2025-10-28T10:05:19Z","level":"info","event":"persistent","ip":"1.2.3.4","reason":"3_in_24h","count":"3","action":"blacklist_file_append"}
```

═══════════════════════════════════════════════════════════════════════════════

## 🎯 SUCCESS CRITERIA

Fail2ban integration is working if:
- ✅ SSH failures trigger bans within 10 minutes
- ✅ Banned IPs appear in nftables temp_ban set
- ✅ Bans expire automatically after 1 hour
- ✅ Logs are created and structured
- ✅ Persistent offenders get blacklisted
- ✅ Statistics commands show data
- ✅ No errors in Fail2ban or nftables logs

═══════════════════════════════════════════════════════════════════════════════

## 📞 QUICK REFERENCE

**Test SSH ban:**
```bash
for i in {1..6}; do ssh wronguser@server1.example.com; sleep 2; done
```

**Check if banned:**
```bash
ssh root@server1.example.com "nft list set inet nftban_runtime temp_ban_v4"
```

**View logs:**
```bash
ssh root@server1.example.com "/usr/sbin/nftban-complete logs tail fail2ban-bans.log"
```

**View stats:**
```bash
ssh root@server1.example.com "/usr/sbin/nftban-complete stats top-ips"
```

═══════════════════════════════════════════════════════════════════════════════

**READY FOR TESTING TOMORROW!** 🚀

Check logs tomorrow and let me know how it goes!
