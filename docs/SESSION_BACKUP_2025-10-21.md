# NFTBan v0.9.2 Session Backup
**Date:** 2025-10-21
**Session:** Lab Server Protection Setup & Testing
**Status:** READY FOR DEPLOYMENT AND TESTING

---

## SESSION SUMMARY

This session completed the lab server protection setup for nftban v0.9.2. All files have been created, committed, and pushed to the repository. The system is ready for deployment to lab servers and attack simulation testing.

---

## COMPLETED TASKS

### 1. Configuration Updates ✓
- [x] Updated `config/nftban.conf` with all new configuration sections
- [x] Added NFTBAN_ENABLED master switch
- [x] Added Login Monitoring section (12 settings)
- [x] Added SSH Connection Management (5 settings)
- [x] Added Reboot Safety section (9 settings)
- [x] Set safe defaults (all reboot safety = "false" for production)
- [x] Fixed case-insensitive boolean support (TRUE/true, FALSE/false)

### 2. Port Protection Templates ✓
- [x] Created `templates/ports/ssh.conf` - SSH port 22 protection
- [x] Created `templates/ports/mail.conf` - Mail ports (25, 587, 465, 993, 995)

### 3. Lab Server Configurations ✓
- [x] Created `templates/lab-configs/lab-server-1.conf.local`
  - Email: lab1-admin@yourdomain.com
  - SSH protection enabled (5 failures → 1 hour ban)
  - Mail protection enabled (3 failures → 2 hour ban)
  - Login monitoring enabled
  - Reboot safety enabled (lab testing)

- [x] Created `templates/lab-configs/lab-server-2.conf.local`
  - Email: lab2-admin@yourdomain.com
  - Same protection settings as lab1

- [x] Created `templates/lab-configs/lab-server-3.conf.local`
  - Email: lab3-admin@yourdomain.com
  - Same protection settings as lab1

### 4. Automated Setup Script ✓
- [x] Created `scripts/setup_lab_protection.sh`
  - Auto-detects lab server (1/2/3)
  - Installs server-specific configuration
  - Enables SSH + mail port protection
  - Sets up login monitoring service
  - Creates attack visibility tools
  - Verifies protection setup

### 5. Attack Simulation Test ✓
- [x] Created `scripts/test_ssh_attack_protection.sh`
  - Simulates SSH brute force attack
  - Runs from lab-server-2 targeting lab-server-1
  - Generates 7 failed login attempts (exceeds threshold of 5)
  - Verifies fail2ban detection and banning
  - Tests firewall blocking
  - Provides pass/fail results
  - Includes cleanup/unban option

### 6. Documentation ✓
- [x] Created `docs/v0.9.2_LAB_DEPLOYMENT.md`
- [x] Created `scripts/collect_logs_for_analysis.sh`
- [x] All files committed and pushed to repository

---

## FILES CREATED THIS SESSION

### Configuration Files
```
templates/ports/ssh.conf                        # SSH port protection
templates/ports/mail.conf                       # Mail port protection
templates/lab-configs/lab-server-1.conf.local   # Lab server 1 config
templates/lab-configs/lab-server-2.conf.local   # Lab server 2 config
templates/lab-configs/lab-server-3.conf.local   # Lab server 3 config
```

### Scripts
```
scripts/setup_lab_protection.sh                 # Automated protection setup
scripts/test_ssh_attack_protection.sh           # Attack simulation test
scripts/collect_logs_for_analysis.sh            # Log collection utility
```

### Documentation
```
docs/v0.9.2_LAB_DEPLOYMENT.md                   # Deployment guide
docs/SESSION_BACKUP_2025-10-21.md               # This file
```

### Modified Files
```
config/nftban.conf                              # Added new config sections
lib/nftban_core.sh                              # Boolean case normalization
```

---

## GIT STATUS

**Current Branch:** main
**Last Commit:** bb33c4f - "Add SSH attack protection test script (v0.9.2)"
**Status:** All changes committed and pushed

**Recent Commits:**
```
bb33c4f - Add SSH attack protection test script (v0.9.2)
cdfe393 - Add SSH and mail port protection for lab servers (v0.9.2)
97e77dd - chore: update SHA256SUMS.txt (automated)
72a3333 - Add case-insensitive boolean config support (v0.9.2)
```

---

## NEXT STEPS FOR TOMORROW

### DEPLOYMENT PHASE

#### Step 1: Deploy to Lab-Server-1
```bash
# SSH to lab-server-1
ssh root@lab-server-1

# Navigate to nftban directory (adjust path as needed)
cd /path/to/nftban

# Pull latest changes
git pull origin main

# Run protection setup
sudo ./scripts/setup_lab_protection.sh

# Follow prompts:
# 1. Confirm server detection (lab-server-1)
# 2. Customize email address if needed
# 3. Wait for setup to complete

# Verify setup
sudo nftban status
sudo fail2ban-client status sshd
sudo systemctl status nftban-login-monitor.timer
```

#### Step 2: Deploy to Lab-Server-2
```bash
# SSH to lab-server-2
ssh root@lab-server-2

# Navigate to nftban directory
cd /path/to/nftban

# Pull latest changes
git pull origin main

# Run protection setup
sudo ./scripts/setup_lab_protection.sh

# Verify setup
sudo nftban status
sudo fail2ban-client status sshd
```

#### Step 3: Deploy to Lab-Server-3 (Optional)
```bash
# Same steps as lab-server-2
ssh root@lab-server-3
cd /path/to/nftban
git pull origin main
sudo ./scripts/setup_lab_protection.sh
```

---

### TESTING PHASE

#### Test 1: SSH Attack Simulation (Lab2 → Lab1)
```bash
# On lab-server-2 (attacker)
sudo ./scripts/test_ssh_attack_protection.sh

# This will:
# 1. Verify lab-server-1 is reachable
# 2. Simulate 7 failed SSH login attempts
# 3. Wait for fail2ban to process (30 seconds)
# 4. Verify IP ban is applied
# 5. Verify connection is blocked
# 6. Show pass/fail results
```

#### Test 2: Verify Attack Visibility on Lab-Server-1
```bash
# On lab-server-1 (victim/target)
view-attacks                                    # Quick attack summary
sudo fail2ban-client status sshd                # Check banned IPs
sudo nft list set inet nftban_v4 temp_ban       # Check firewall ban set
tail -f /var/log/nftban/ban-history.log         # Live ban events
tail -f /var/log/nftban/login-alerts.log        # Live login alerts
```

#### Test 3: Check Email Alerts
- Verify email alerts were sent to lab1-admin@yourdomain.com
- Check alert contains attacker IP, timestamp, and ban details
- Verify daily report is scheduled (cron)

#### Test 4: Verify Automatic Unban (After 1 Hour)
```bash
# Wait 1 hour, then on lab-server-1:
sudo fail2ban-client status sshd                # Should show 0 banned IPs
sudo nft list set inet nftban_v4 temp_ban       # Should be empty

# Try to connect from lab-server-2:
ssh root@lab-server-1                           # Should succeed
```

#### Test 5: Manual Unban (If Needed)
```bash
# On lab-server-1 (to unban lab-server-2):
sudo fail2ban-client set sshd unbanip <lab2-ip>

# Or use the test script's cleanup option
```

---

### LOG COLLECTION PHASE

After 24 hours of testing, collect logs for analysis:

```bash
# On each lab server:
sudo /path/to/scripts/collect_logs_for_analysis.sh

# This creates: /tmp/nftban-logs-{hostname}-{timestamp}.tar.gz
# Download logs from each server for analysis
```

---

## EXPECTED TEST RESULTS

### Successful Attack Detection
✓ 7 failed SSH login attempts logged in auth.log
✓ Fail2ban detects threshold breach (5+ failures)
✓ Attacker IP (lab-server-2) banned within 30 seconds
✓ Ban recorded in /var/log/nftban/ban-history.log
✓ Alert recorded in /var/log/nftban/login-alerts.log
✓ Email alert sent to lab1-admin@yourdomain.com

### Successful Connection Blocking
✓ SSH connection from lab-server-2 to lab-server-1 times out
✓ Firewall blocks at nftables level
✓ Ban visible in: `nft list set inet nftban_v4 temp_ban`
✓ Ban visible in: `fail2ban-client status sshd`

### Successful Logging
✓ Ban events logged with timestamp, IP, and reason
✓ Login alerts show failed attempts
✓ Daily report tool works
✓ Attack viewer tool works

---

## PROTECTION SETTINGS

### SSH Protection (All Lab Servers)
- **Port:** 22 (TCP INPUT)
- **Jail:** sshd
- **Threshold:** 5 failed attempts in 10 minutes
- **Ban Time:** 3600 seconds (1 hour)
- **Filter:** sshd
- **Log Path:** /var/log/auth.log

### Mail Protection (All Lab Servers)
- **Ports:** 25, 587, 465 (SMTP), 993 (IMAP), 995 (POP3)
- **Jails:** postfix, dovecot
- **Threshold:** 3 failed attempts in 10 minutes
- **Ban Time:** 7200 seconds (2 hours)
- **Log Path:** /var/log/mail.log

### Login Monitoring (All Lab Servers)
- **Enabled:** true
- **Root Login Alerts:** true
- **SSH Login Alerts:** true
- **Failed Login Threshold:** 3
- **Check Interval:** 60 seconds
- **Alert Cooldown:** 300 seconds (5 minutes)

### Reboot Safety (Lab Servers ONLY)
- **Enabled:** true (LAB TESTING MODE)
- **Reset on Boot:** true
- **Grace Period:** 300 seconds
- **Auto Sync:** true

**WARNING:** Production servers must set reboot safety to "false"!

---

## IMPORTANT NOTES

### Email Configuration
Each lab server has a different email recipient:
- lab-server-1: lab1-admin@yourdomain.com
- lab-server-2: lab2-admin@yourdomain.com
- lab-server-3: lab3-admin@yourdomain.com

**ACTION REQUIRED:** Update these email addresses during setup to actual addresses.

### Reboot Safety Warning
Lab server configs have reboot safety **ENABLED** for testing purposes. This means:
- Firewall rules reset on reboot
- Prevents permanent SSH lockout during testing
- **NOT SUITABLE FOR PRODUCTION**

Production deployments must set:
```bash
NFTBAN_REBOOT_SAFETY_ENABLED="false"
NFTBAN_RESET_ON_BOOT="false"
NFTBAN_INSTALL_REBOOT_CRON="false"
```

### SSH Access During Testing
When running the attack test from lab-server-2:
- Lab-server-2 IP will be banned on lab-server-1
- Ban lasts 1 hour (auto-expires)
- Manual unban: `fail2ban-client set sshd unbanip <ip>`
- Or use test script's cleanup option

### Attack Visibility Tools
After deployment, these commands are available on lab servers:
```bash
view-attacks              # Quick attack summary
daily-attack-report       # Detailed daily report (+ email)
```

Daily reports are scheduled at 8:00 AM via cron.

---

## TROUBLESHOOTING

### Protection Not Working
```bash
# Check nftban status
sudo nftban status

# Check fail2ban service
sudo systemctl status fail2ban
sudo fail2ban-client status

# Check SSH jail
sudo fail2ban-client status sshd

# Check login monitor
sudo systemctl status nftban-login-monitor.timer
sudo systemctl status nftban-login-monitor.service
```

### Logs Not Created
```bash
# Check log directory
ls -la /var/log/nftban/

# Check permissions
sudo chown -R root:root /var/log/nftban/
sudo chmod 755 /var/log/nftban/

# Manually trigger login monitor
sudo /usr/local/bin/nftban login check
```

### Email Alerts Not Sending
```bash
# Check mail configuration
sudo tail -f /var/log/mail.log

# Test email
echo "Test" | mail -s "Test Alert" your-email@example.com

# Check postfix/sendmail is running
sudo systemctl status postfix
```

### Ban Not Applied
```bash
# Check fail2ban logs
sudo tail -f /var/log/fail2ban.log

# Check auth.log for failed attempts
sudo grep "Failed password" /var/log/auth.log | tail -20

# Manually ban an IP (testing)
sudo fail2ban-client set sshd banip 1.2.3.4

# Manually unban an IP
sudo fail2ban-client set sshd unbanip 1.2.3.4
```

---

## SECURITY BUGS FIXED (v0.9.2)

This session is part of nftban v0.9.2 release which fixed:

- **BUG47:** CIDR whitelist bypass vulnerability
- **BUG50:** Race conditions with atomic imports + flock
- **BUG51:** Strict mode missing in shell scripts
- **BUG52:** IPv6 selector issues (already fixed)
- **BUG53:** curl hardening and security
- **BUG54:** Configuration validation issues

All security fixes have been tested and are ready for deployment.

---

## REPOSITORY INFORMATION

**Repository:** https://github.com/itcmsgr/nftban
**Branch:** main
**Version:** 0.9.2
**Working Directory:** /home/gituser/github/nftban

**Clone Command:**
```bash
git clone https://github.com/itcmsgr/nftban.git
cd nftban
```

---

## CONTACT INFORMATION

**Author:** ITCMS Team (Antonios Voulvoulis)
**Contact:** contact@itcms.gr
**Website:** https://itcms.gr

---

## SESSION END STATUS

**All tasks completed:** ✓
**All files committed:** ✓
**All files pushed:** ✓
**Ready for deployment:** ✓
**Ready for testing:** ✓

**Next action:** Deploy to lab servers and run attack simulation test.

---

## RESUME INSTRUCTIONS FOR TOMORROW

When resuming tomorrow:

1. **Pull latest changes:**
   ```bash
   cd /home/gituser/github/nftban
   git pull origin main
   ```

2. **Review this backup:**
   ```bash
   cat docs/SESSION_BACKUP_2025-10-21.md
   ```

3. **Check git status:**
   ```bash
   git status
   git log --oneline -5
   ```

4. **Begin deployment** (see NEXT STEPS section above)

5. **Run attack test** (see TESTING PHASE section above)

6. **Collect logs after 24 hours** for stability analysis

---

**END OF SESSION BACKUP**
**Session saved:** 2025-10-21
**Ready to resume:** YES
