# Clean Lab Testing Checklist - NFTBan v0.10.0

## Purpose

This checklist is for testing NFTBan v0.10.0 **from scratch** on a brand new, clean lab server (lab4.mywebhost.gr) to verify:
- Package installation works correctly
- All dependencies are included
- Permissions are set correctly
- Services start and run properly
- Health checks pass
- Core functionality works

---

## Pre-Testing Preparation

### 1. Provision Clean Lab Server

**Server: lab4.mywebhost.gr**

Requirements:
- Rocky Linux 9 minimal install (preferred) OR AlmaLinux 9
- Clean system (no previous NFTBan installation)
- Root SSH access
- Internet connectivity
- 1 GB RAM minimum
- 10 GB disk space minimum

### 2. Build Fresh Packages

On development machine:

```bash
cd /home/gituser/github/nftban

# Ensure latest code committed
git status

# Build RPM package
./scripts/build-rpm.sh

# Verify package created
ls -lh dist/packages/nftban-0.10.0-1.el9.x86_64.rpm

# Generate checksum
cd dist/packages
sha256sum nftban-0.10.0-1.el9.x86_64.rpm > SHA256SUMS
cat SHA256SUMS
```

### 3. Copy Package to Lab4

```bash
# Copy package
scp dist/packages/nftban-0.10.0-1.el9.x86_64.rpm root@lab4.mywebhost.gr:/tmp/

# Copy checksum (optional)
scp dist/packages/SHA256SUMS root@lab4.mywebhost.gr:/tmp/
```

---

## Testing Steps

### Phase 1: Pre-Installation Checks

```bash
# SSH to lab4
ssh root@lab4.mywebhost.gr

# Verify clean system
rpm -qa | grep nftban
# Expected: (no output)

rpm -qa | grep firewalld
# If firewalld exists: sudo dnf remove -y firewalld

# Check system info
cat /etc/redhat-release
uname -r
free -h
df -h

# Verify nftables available
nft --version
# Expected: nftables v1.0.0 or later

# Check systemd version
systemd --version
# Expected: systemd 250 or later
```

**Pre-Installation Checklist:**
- [ ] System is clean (no previous nftban)
- [ ] No conflicting firewalls (firewalld, iptables)
- [ ] nftables >= 1.0.0 installed
- [ ] systemd >= 250 installed
- [ ] Root access working
- [ ] Internet connectivity confirmed

---

### Phase 2: Package Installation

```bash
# Verify package checksum (optional but recommended)
sha256sum -c /tmp/SHA256SUMS

# Install package
sudo dnf install -y /tmp/nftban-0.10.0-1.el9.x86_64.rpm

# Watch output for errors
# Expected: Installation should complete without errors
```

**Installation Verification:**
- [ ] No dependency errors
- [ ] No file conflicts
- [ ] Installation completes successfully
- [ ] Post-install script runs (creates system.conf)
- [ ] Installation message displayed

**Expected Output:**
```
╔════════════════════════════════════════════════════════════╗
║  NFTBan v0.10.0 Installation Complete!                    ║
╚════════════════════════════════════════════════════════════╝

Next steps:
  1. Review config: /etc/nftban/nftban.conf
  2. Customize (optional): /etc/nftban/nftban.conf.local
  3. Enable service: systemctl enable --now nftban.timer
  4. Check health: nftban health check
```

---

### Phase 3: Post-Installation Verification

#### 3.1 Binary and Version

```bash
# Check binary installed
which nftban
# Expected: /usr/sbin/nftban

# Check version
nftban --version
# Expected: NFTBan v0.10.0

# Check help works
nftban --help
# Expected: Help message displayed

# Check command availability (without sudo)
nftban stats --summary 2>&1
# Expected: May fail with permissions (expected if not in nftban-cli group)
```

**Binary Checklist:**
- [ ] nftban binary at /usr/sbin/nftban
- [ ] Version shows v0.10.0
- [ ] Help command works
- [ ] Binary is executable

#### 3.2 Users and Groups

```bash
# Check nftban user created
id nftban
# Expected: uid=XXX(nftban) gid=XXX(nftban) groups=XXX(nftban)

# Check nftban-cli group created
getent group nftban-cli
# Expected: nftban-cli:x:XXX:

# Verify system.conf created and contains UID/GID
cat /var/lib/nftban/config/system.conf
# Expected: File exists with NFTBAN_UID, NFTBAN_GID, NFTBAN_CLI_GID

# Check UID/GID values match
EXPECTED_UID=$(id -u nftban)
ACTUAL_UID=$(grep NFTBAN_UID /var/lib/nftban/config/system.conf | cut -d= -f2)
echo "Expected: $EXPECTED_UID, Actual: $ACTUAL_UID"
# Expected: Should match
```

**User/Group Checklist:**
- [ ] nftban system user created
- [ ] nftban-cli group created
- [ ] system.conf exists at /var/lib/nftban/config/system.conf
- [ ] UID in system.conf matches actual UID
- [ ] GID in system.conf matches actual GID
- [ ] CLI_GID in system.conf matches actual group ID

#### 3.3 File Structure (FHS Compliance)

```bash
# Check main directories exist
ls -la /etc/nftban/
ls -la /var/lib/nftban/
ls -la /var/cache/nftban/
ls -la /var/log/nftban/
ls -la /usr/lib/nftban/

# Check subdirectories
ls -la /var/lib/nftban/state/
ls -la /var/lib/nftban/snapshots/
ls -la /var/lib/nftban/feeds/
ls -la /var/lib/nftban/keyring/
ls -la /var/lib/nftban/backup/
ls -la /var/lib/nftban/reports/
ls -la /var/lib/nftban/metrics/
ls -la /var/lib/nftban/config/

# Check Go binaries
ls -la /usr/lib/nftban/bin/
# Expected: nftban-feeds, nftban-geoip

# Check core modules
ls -la /usr/lib/nftban/core/
# Expected: Multiple .sh files

# Check CLI commands
ls -la /usr/lib/nftban/cli/
# Expected: cmd_*.sh files
```

**FHS Structure Checklist:**
- [ ] /etc/nftban/ exists with config files
- [ ] /var/lib/nftban/ exists with all subdirectories
- [ ] /var/cache/nftban/ exists
- [ ] /var/log/nftban/ exists
- [ ] /usr/lib/nftban/bin/ contains Go binaries
- [ ] /usr/lib/nftban/core/ contains core modules
- [ ] /usr/lib/nftban/cli/ contains CLI commands
- [ ] /usr/share/nftban/ exists

#### 3.4 Permissions

```bash
# Check ownership
ls -la /etc/nftban/ | head -5
# Expected: Most files owned by root or nftban

ls -la /var/lib/nftban/ | grep -v total
# Expected: All owned by nftban:nftban

ls -la /var/log/nftban/
# Expected: Owned by nftban:nftban, mode 0750

# Check sensitive directories
ls -la /etc/nftban/ | grep secrets.d
# Expected: drwx------ (0700) for secrets.d

# Run health check
sudo nftban health check
# Expected: All checks pass, 0 issues
```

**Permissions Checklist:**
- [ ] /var/lib/nftban/ owned by nftban:nftban
- [ ] /var/lib/nftban/ subdirs have 0750 permissions
- [ ] /var/log/nftban/ owned by nftban:nftban, mode 0750
- [ ] /var/cache/nftban/ has correct permissions
- [ ] /etc/nftban/secrets.d/ has 0700 permissions
- [ ] Health check passes with 0 issues

#### 3.5 Systemd Services

```bash
# Check systemd units installed
systemctl list-unit-files | grep nftban
# Expected: nftban.service, nftban.timer, nftban-health.timer, etc.

# Check timer status (should be loaded but not active yet)
systemctl status nftban.timer
# Expected: Loaded, inactive (dead)

systemctl status nftban-health.timer
# Expected: Loaded, inactive (dead)

# Check service files exist
ls -la /lib/systemd/system/nftban*
# Expected: Multiple .service and .timer files
```

**Systemd Checklist:**
- [ ] nftban.timer unit exists
- [ ] nftban-health.timer unit exists
- [ ] All service units exist (.service files)
- [ ] Units are loaded but not started
- [ ] No systemd errors in journal

---

### Phase 4: Health Check

```bash
# Run comprehensive health check
sudo nftban health check

# Expected output:
# ╔══════════════════════════════════════════╗
# ║        NFTBan Health Check v0.10.0       ║
# ╚══════════════════════════════════════════╝
#
# ✓ Binary Dependencies: OK
# ✓ FHS Path Structure: OK
# ✓ File Permissions: OK
# ✓ System Configuration: OK
# ✓ Service Status: OK
# ✓ Module Availability: OK
# ⚠ GeoIP Database: Missing (optional)
#
# Overall Status: ✓ HEALTHY
# ✓ 0 issues found
```

**If health check fails:**
```bash
# Try auto-fix
sudo nftban health fix all

# Recheck
sudo nftban health check
```

**Health Check Checklist:**
- [ ] Binary Dependencies: OK
- [ ] FHS Path Structure: OK
- [ ] File Permissions: OK
- [ ] System Configuration: OK
- [ ] Service Status: OK
- [ ] Module Availability: OK
- [ ] GeoIP Database: OK or ⚠ (optional)
- [ ] Overall: 0 issues found

---

### Phase 5: Configuration

```bash
# Check main config exists
cat /etc/nftban/nftban.conf | head -20

# Check module configs
ls -la /etc/nftban/conf.d/

# Create local override (optional)
sudo vim /etc/nftban/nftban.conf.local
```

Example local config:
```bash
# Test configuration for lab4
ALLOWED_PORTS="22 80 443"
SSH_PORT=22
LOGGING_ENABLED=1
LOG_LEVEL="INFO"
```

**Configuration Checklist:**
- [ ] /etc/nftban/nftban.conf exists and readable
- [ ] /etc/nftban/conf.d/ contains module configs
- [ ] Can create nftban.conf.local
- [ ] Configuration syntax is valid

---

### Phase 6: Functional Testing

#### 6.1 Apply Rules (WITH COMMIT-CONFIRM!)

**⚠️ CRITICAL: Keep SSH session open!**

```bash
# Apply rules with commit-confirm protection
sudo nftban apply

# Expected:
# 1. Backup created
# 2. Rules generated
# 3. Rules applied
# 4. Waiting for confirmation (5 minutes timeout)
# 5. Press Enter to confirm

# IMPORTANT: Test SSH in NEW terminal BEFORE confirming!
```

In **ANOTHER terminal**, test SSH:
```bash
ssh root@lab4.mywebhost.gr
# If successful, return to first terminal and press Enter to confirm
```

**If locked out:**
- Wait 5 minutes for auto-rollback
- Or access via console and run: `sudo nftban rollback`

**Apply Rules Checklist:**
- [ ] Backup created successfully
- [ ] Rules generated without errors
- [ ] Rules applied to nftables
- [ ] Commit-confirm prompt appears
- [ ] SSH test in new terminal succeeds
- [ ] Rules confirmed successfully

#### 6.2 Check nftables Rules

```bash
# List nftban table
sudo nft list table inet nftban

# Expected: Table exists with rules
```

**nftables Checklist:**
- [ ] inet nftban table exists
- [ ] Table contains chains
- [ ] Rules are present
- [ ] No syntax errors

#### 6.3 Test Stats

```bash
# Get summary statistics
sudo nftban stats --summary

# Expected: Stats displayed (may show 0 bans initially)
```

**Stats Checklist:**
- [ ] stats command works
- [ ] Summary displayed
- [ ] No errors

#### 6.4 Test Ban/Unban

```bash
# Ban test IP
sudo nftban ban 192.0.2.100 "Test ban on lab4"

# Check if banned
sudo nftban stats --summary
# Expected: Total Bans: 1

# Verify in nftables
sudo nft list set inet nftban banned_ips
# Expected: 192.0.2.100 in set

# Unban
sudo nftban unban 192.0.2.100

# Verify unbanned
sudo nftban stats --summary
# Expected: Total Bans: 0
```

**Ban/Unban Checklist:**
- [ ] Ban command works
- [ ] IP appears in stats
- [ ] IP appears in nftables set
- [ ] Unban command works
- [ ] IP removed from stats
- [ ] IP removed from nftables set

#### 6.5 Test Report Generation

```bash
# Generate JSON report
sudo nftban report generate --format json --output /tmp/lab4-report.json

# Check file created
ls -lh /tmp/lab4-report.json
cat /tmp/lab4-report.json

# Generate HTML report (if available)
sudo nftban report generate --format html --output /tmp/lab4-report.html
```

**Report Checklist:**
- [ ] JSON report generates without errors
- [ ] JSON file created and valid
- [ ] HTML report generates (if implemented)
- [ ] Reports contain expected data

---

### Phase 7: Service Activation

```bash
# Enable timers
sudo systemctl enable nftban.timer
sudo systemctl enable nftban-health.timer

# Start timers
sudo systemctl start nftban.timer
sudo systemctl start nftban-health.timer

# Verify running
systemctl status nftban.timer
systemctl status nftban-health.timer

# Check timer schedules
systemctl list-timers | grep nftban
# Expected: Both timers listed with next run time
```

**Service Activation Checklist:**
- [ ] nftban.timer enabled
- [ ] nftban-health.timer enabled
- [ ] Timers started successfully
- [ ] Timers show in list-timers
- [ ] No errors in systemctl status

---

### Phase 8: Runtime Testing

```bash
# Wait for timer to run (up to 5 minutes for nftban.timer)
# Or manually trigger:
sudo systemctl start nftban.service

# Check logs
sudo journalctl -u nftban.service -n 50

# Check health timer
sudo systemctl start nftban-health.service
sudo journalctl -u nftban-health.service -n 20

# Verify no errors
sudo journalctl -u nftban.service --since "5 minutes ago" | grep -i error
# Expected: No errors
```

**Runtime Checklist:**
- [ ] nftban.service runs successfully
- [ ] nftban-health.service runs successfully
- [ ] No errors in logs
- [ ] Health check passes automatically

---

### Phase 9: Package Removal Testing (Optional)

**Test package removal:**
```bash
# Stop services
sudo systemctl stop nftban.timer nftban-health.timer

# Remove package
sudo dnf remove -y nftban

# Verify removal
rpm -qa | grep nftban
# Expected: (no output)

# Check config preserved
ls -la /etc/nftban/
# Expected: Config files remain (noreplace)

# Check nftables table
sudo nft list tables
# Expected: inet nftban table still exists (not removed on upgrade)
```

**Package Removal Checklist:**
- [ ] Package removes cleanly
- [ ] Config files preserved
- [ ] nftables rules preserved (not removed)
- [ ] User/group NOT removed (correct behavior)

---

## Test Results Summary

### Lab4 Test Results

**Date:** _________________
**Tester:** _________________
**Rocky Linux Version:** _________________
**Package Version:** nftban-0.10.0-1.el9.x86_64.rpm

**Phase Results:**

| Phase | Status | Issues | Notes |
|-------|--------|--------|-------|
| Pre-Installation | ⬜ Pass / ⬜ Fail | | |
| Package Installation | ⬜ Pass / ⬜ Fail | | |
| Post-Install Verification | ⬜ Pass / ⬜ Fail | | |
| Health Check | ⬜ Pass / ⬜ Fail | | |
| Configuration | ⬜ Pass / ⬜ Fail | | |
| Functional Testing | ⬜ Pass / ⬜ Fail | | |
| Service Activation | ⬜ Pass / ⬜ Fail | | |
| Runtime Testing | ⬜ Pass / ⬜ Fail | | |
| Package Removal | ⬜ Pass / ⬜ Fail | | |

**Overall Result:** ⬜ PASS / ⬜ FAIL

**Critical Issues Found:**
1. _________________
2. _________________
3. _________________

**Minor Issues Found:**
1. _________________
2. _________________
3. _________________

**Recommendations:**
1. _________________
2. _________________
3. _________________

---

## Troubleshooting

### Common Issues

**Issue: Permission denied errors**
```bash
sudo nftban health fix all
```

**Issue: Services won't start**
```bash
sudo journalctl -xeu nftban.service
sudo nftban health check --verbose
```

**Issue: UID/GID mismatch**
```bash
sudo nftban health fix config
```

**Issue: Locked out of SSH**
- Wait 5 minutes for auto-rollback
- Access via console: `sudo nftban rollback`

---

## Sign-Off

**Tested by:** _________________
**Date:** _________________
**Signature:** _________________

**Approved for production by:** _________________
**Date:** _________________
**Signature:** _________________
