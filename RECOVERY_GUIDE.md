# NFTBan Emergency Recovery Guide
**NFTBan v0.10.0 - Protecting Your Access & Recovering from Lockouts**

## Table of Contents
- [Overview](#overview)
- [Quick Start](#quick-start)
- [How It Works](#how-it-works)
- [Daily Usage](#daily-usage)
- [Emergency Recovery](#emergency-recovery)
- [Console/IPMI Access](#consoleipmi-access)
- [Advanced Recovery](#advanced-recovery)
- [Troubleshooting](#troubleshooting)
- [Best Practices](#best-practices)

---

## Overview

### The Problem

Firewall misconfigurations can lock you out of your server permanently:
- Wrong SSH port blocked
- Wrong IP whitelisted
- Typo in firewall rules
- Testing rules that break connectivity

**Old solution**: Boot in safe mode, mount disk, edit config, reboot (slow, complex, requires console access)

**New solution**: Automatic commit-confirm with rollback timer ✓

### The Solution: Commit-Confirm Pattern

NFTBan v0.10.0 implements a **JunOS-style commit-confirm system**:

1. **Apply** rules → They activate immediately
2. **Test** connectivity → Verify SSH/services work
3. **Confirm** → Keep rules permanently
4. **Don't confirm** → Automatic rollback to last-known-good

**Result**: You can NEVER permanently lock yourself out!

---

## Quick Start

### Basic Workflow

```bash
# 1. Apply new rules (with safety)
sudo nftban-apply

# Output:
#   ✓ Rules applied successfully
#   ✓ Rollback timer armed (300 seconds)
#   ✓ SSH test passed
#
#   You must confirm within 300 seconds!
#   To KEEP: sudo nftban-confirm
#   To ROLLBACK: sudo nftban-rollback --force

# 2. Test connectivity (open new SSH session)
ssh user@yourserver.com
# If this works, you're good!

# 3. Confirm rules (within 5 minutes)
sudo nftban-confirm

# Output:
#   ✓ Rules confirmed
#   ✓ Rollback timer disarmed
#   ✓ Rules are now permanent
```

### If You Don't Confirm

Simply **wait**. After the grace period (default 300 seconds):
- Rules automatically rollback
- Previous firewall state restored
- SSH access restored
- No permanent damage

---

## How It Works

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    nftban-apply                             │
│  1. Validate new rules (syntax check)                       │
│  2. Backup current rules → /var/lib/nftban/backup.rules     │
│  3. Apply new rules atomically                              │
│  4. Start rollback timer (300s)                             │
│  5. Test SSH connectivity (optional)                        │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
                    Grace Period Active
                       (300 seconds)
                            │
                ┌───────────┴───────────┐
                │                       │
                ▼                       ▼
        User Confirms          Timer Expires
       (nftban-confirm)     (auto-rollback)
                │                       │
                ▼                       ▼
        Rules Permanent         Rules Rolled Back
        Timer Disarmed         Previous State Restored
```

### Components

**1. nftban-apply**
- Applies new rules with safety checks
- Creates backup of current rules
- Arms rollback timer
- Tests SSH connectivity

**2. nftban-confirm**
- Confirms new rules are good
- Disarms rollback timer
- Makes rules permanent

**3. nftban-rollback**
- Checks rollback deadline
- Restores backup rules if deadline passed
- Can be forced manually for emergency

**4. systemd timer**
- Checks every 15 seconds
- Triggers rollback when deadline reached
- Runs automatically in background

**5. Backup storage**
- Location: `/var/lib/nftban/backup.rules`
- Contains last-known-good ruleset
- Updated before each apply
- Used for rollback

---

## Daily Usage

### Scenario 1: Deploying New Rules (Production)

```bash
# Step 1: Generate or edit rules
sudo nftban ddos enable
sudo nftban profile balanced

# Step 2: Apply with safety
sudo nftban-apply

# Step 3: Test from ANOTHER terminal (important!)
ssh user@yourserver.com
# Try all critical services:
#   - SSH works?
#   - Web server accessible?
#   - Database reachable?
#   - Monitoring can connect?

# Step 4: If everything works, confirm
sudo nftban-confirm

# Done! Rules are now permanent.
```

### Scenario 2: Testing Rules (Lab Server)

```bash
# Apply rules
sudo nftban-apply

# Test thoroughly
# If something's wrong, just wait 5 minutes
# Automatic rollback will restore access

# If everything's good, confirm
sudo nftban-confirm
```

### Scenario 3: Multiple Changes

```bash
# Make several changes
sudo nftban feeds enable SPAMHAUS_DROP
sudo nftban portscan enable
sudo nftban cloudflare update

# Apply once with all changes
sudo nftban-apply

# Test everything
# Confirm if good
sudo nftban-confirm
```

### Scenario 4: Urgent Rollback

```bash
# Something's wrong, rollback immediately
sudo nftban-rollback --force

# Previous rules restored instantly
# SSH access restored
```

---

## Emergency Recovery

### I'm Locked Out - What Now?

**DON'T PANIC!** NFTBan has multiple recovery paths.

### Recovery Path 1: Wait for Auto-Rollback

**If you recently applied rules:**

1. **Wait 5 minutes** (default grace period)
2. Rules will automatically rollback
3. SSH access will be restored
4. No action needed!

**When to use**: You just ran `nftban-apply` and got locked out.

### Recovery Path 2: Console/IPMI Access

**If you have console access:**

1. Access server console (see [Console/IPMI Access](#consoleipmi-access))
2. Log in as root
3. Run immediate rollback:
   ```bash
   sudo nftban-rollback --force
   ```
4. SSH should work now

**When to use**: Can't wait for auto-rollback, need immediate access.

### Recovery Path 3: Flush All Rules

**Emergency nuclear option:**

1. Access console
2. Flush all firewall rules:
   ```bash
   nft flush ruleset
   ```
3. SSH will work (but NO firewall protection!)
4. Fix rules, re-apply carefully

**When to use**: Rollback failed, backup corrupted, desperate measures.

### Recovery Path 4: Boot with Kill-Switch

**Disable NFTBan entirely at boot:**

1. Reboot server
2. At GRUB menu, press `e` to edit boot entry
3. Add to kernel command line:
   ```
   nftban=disabled
   ```
4. Press `Ctrl+X` to boot
5. NFTBan will not start
6. Fix rules, reboot normally

**When to use**: Rules persist across reboots and break SSH every time.

---

## Console/IPMI Access

### Getting Console Access

Different platforms have different console access methods:

#### Dedicated Servers

**IPMI/iDRAC/iLO:**
- **Dell**: iDRAC → Remote Console → "Launch Virtual Console"
- **HP**: iLO → Remote Console → "HTML5 Console"
- **Supermicro**: IPMI → Remote Control → "iKVM/HTML5"

**Serial over LAN (SOL):**
```bash
ipmitool -I lanplus -H <ipmi-ip> -U <user> -P <pass> sol activate
```

#### VPS/Cloud Servers

**DigitalOcean:**
- Dashboard → Droplet → Access → "Launch Droplet Console"

**Linode:**
- Dashboard → Linode → Launch LISH Console → "Glish (Graphical)"

**Vultr:**
- Dashboard → Server → View Console

**AWS EC2:**
```bash
aws ec2-instance-connect send-serial-console-ssh-public-key \
    --instance-id i-xxxxx
```
- Then: EC2 Console → Instance → Actions → Monitor and troubleshoot → "EC2 Serial Console"

**Google Cloud:**
```bash
gcloud compute instances get-serial-port-output <instance>
```
- Or: Console → VM Instance → "Connect to serial console"

**Azure:**
- Portal → VM → Help → "Serial console"

#### Local Servers/VMs

**Physical server:**
- Attach keyboard/monitor directly

**VMware ESXi:**
- vSphere Client → VM → "Open Console"

**Proxmox:**
- Web UI → VM → Console

**KVM/libvirt:**
```bash
virsh console <vm-name>
```

### Once You Have Console Access

```bash
# 1. Log in
# (use root or admin account)

# 2. Check current rules
nft list ruleset

# 3. Emergency rollback
sudo nftban-rollback --force

# 4. Verify SSH works
systemctl status sshd
ss -tulpn | grep :22

# 5. Test SSH from external terminal
# (open another window and try SSH)

# 6. If still broken, flush everything
nft flush ruleset

# 7. SSH should work now
# Fix the rules properly before re-applying
```

---

## Advanced Recovery

### Creating a GRUB Menu Entry (Kill-Switch)

Add a permanent "Safe Boot" entry to GRUB:

**CentOS/RHEL/Rocky:**

1. Edit `/etc/grub.d/40_custom`:
   ```bash
   sudo vim /etc/grub.d/40_custom
   ```

2. Add safe boot entry:
   ```bash
   menuentry 'CentOS Stream (nftban disabled)' {
       set root='hd0,msdos1'
       linux /vmlinuz-<version> root=/dev/sda1 ro nftban=disabled
       initrd /initramfs-<version>.img
   }
   ```

3. Regenerate GRUB config:
   ```bash
   sudo grub2-mkconfig -o /boot/grub2/grub.cfg
   ```

4. Next reboot, choose "nftban disabled" entry

**Ubuntu/Debian:**

1. Edit `/etc/default/grub`:
   ```bash
   sudo vim /etc/default/grub
   ```

2. Add to `GRUB_CMDLINE_LINUX`:
   ```bash
   GRUB_CMDLINE_LINUX="nftban=disabled"
   ```

3. Update GRUB:
   ```bash
   sudo update-grub
   ```

### Baseline Ruleset (Minimal Safe Rules)

Create a minimal "always safe" baseline:

**File**: `/etc/nftban/baseline.nft`

```nft
#!/usr/sbin/nft -f
# NFTBan Baseline - Minimal Safe Ruleset
# Emergency fallback that ALWAYS allows SSH

flush ruleset

table inet filter {
    # Management IPs (CHANGE THESE!)
    set mgmt_ipv4 {
        type ipv4_addr
        flags interval
        elements = {
            192.0.2.0/24,      # Your office/home network
            198.51.100.10      # Your VPN IP
        }
    }

    set mgmt_ipv6 {
        type ipv6_addr
        flags interval
        elements = {
            2001:db8::/48      # Your IPv6 range
        }
    }

    chain input {
        type filter hook input priority 0
        policy drop

        # Allow established connections
        ct state established,related accept

        # Allow loopback
        iif lo accept

        # Allow SSH from management IPs
        tcp dport 22 ip saddr @mgmt_ipv4 accept
        tcp dport 22 ip6 saddr @mgmt_ipv6 accept

        # Allow ICMP
        icmp type { echo-request, echo-reply } accept
        icmpv6 type { echo-request, echo-reply } accept

        # Log and drop everything else
        log prefix "baseline-drop: " drop
    }

    chain forward {
        type filter hook forward priority 0
        policy drop
    }

    chain output {
        type filter hook output priority 0
        policy accept
    }
}
```

**Usage**:
```bash
# Load baseline in emergency
sudo nft -f /etc/nftban/baseline.nft
```

### Out-of-Band Monitoring

Set up external monitoring that can alert/reboot if SSH fails:

**Simple cron checker** (on external server):

```bash
#!/bin/bash
# File: /usr/local/bin/check-ssh.sh
# Run on EXTERNAL monitoring server

SERVER="yourserver.com"
PORT="22"

if ! timeout 5 ssh -o ConnectTimeout=3 -p "$PORT" "user@$SERVER" "exit" 2>/dev/null; then
    echo "SSH failed on $SERVER"

    # Send alert
    echo "SSH lockout detected on $SERVER" | \
        mail -s "ALERT: $SERVER SSH Failed" admin@yourdomain.com

    # Optional: Trigger IPMI reboot
    # ipmitool -H <ipmi-ip> -U <user> -P <pass> power cycle
fi
```

**Crontab** (check every 5 minutes):
```cron
*/5 * * * * /usr/local/bin/check-ssh.sh
```

---

## Troubleshooting

### Problem: "No candidate ruleset found"

**Error**:
```
ERROR: No candidate ruleset found at /etc/nftban/compiled.nft
```

**Solution**:
```bash
# Generate rules first
sudo nftban compile
# Or configure and sync
sudo nftban sync
```

### Problem: "Rollback timer not starting"

**Check**:
```bash
# Verify systemd timer
systemctl status nftban-rollback.timer

# Enable if not running
sudo systemctl enable --now nftban-rollback.timer

# Check timer list
systemctl list-timers | grep nftban
```

**Manual check**:
```bash
# Run rollback check manually
sudo /usr/sbin/nftban-rollback
```

### Problem: "Backup ruleset missing"

**Error**:
```
ERROR: No backup ruleset found at /var/lib/nftban/backup.rules
```

**Solution**:
```bash
# Create backup from current rules
sudo nft list ruleset > /var/lib/nftban/backup.rules

# Or load baseline
sudo nft -f /etc/nftban/baseline.nft
```

### Problem: "SSH test passes but still can't connect"

**Possible causes**:
- Firewall on different server blocking
- ISP/router blocking
- Wrong SSH port
- SSH daemon not running
- Different network path (test from server, connect from remote)

**Debug**:
```bash
# Check SSH daemon
systemctl status sshd

# Check SSH port
ss -tulpn | grep sshd

# Check from external IP
curl -v telnet://yourserver.com:22

# Check nftables rules
nft list ruleset | grep -A 10 "chain input"
```

### Problem: "Rules confirmed but lost after reboot"

**Check persistence**:
```bash
# Verify nftables save
nft list ruleset > /etc/nftables.conf

# Enable nftables service
sudo systemctl enable nftables

# Check after reboot
systemctl status nftables
```

---

## Best Practices

### Before Enabling Recovery System

**1. Whitelist your management IPs**:
```bash
# Add your office/home IP
sudo nftban whitelist-system add <your-ip>

# Add monitoring services
sudo nftban whitelist-system add <monitoring-ip>

# Verify whitelist
nftban whitelist-system list
```

**2. Create baseline ruleset**:
```bash
# Create minimal safe rules
sudo vim /etc/nftban/baseline.nft
# (See example above)

# Test it works
sudo nft -f /etc/nftban/baseline.nft
# Try SSH
# Restore normal rules
```

**3. Test console access**:
```bash
# Verify you CAN access console/IPMI
# Log in via console at least once
# Test you can run commands
```

**4. Document your setup**:
```bash
# Create recovery notes
sudo vim /root/RECOVERY_NOTES.txt

# Include:
#   - Console/IPMI URL and credentials
#   - Management IP addresses
#   - SSH port if non-standard
#   - Emergency contact info
```

### Daily Operations

**Always use commit-confirm**:
```bash
# Good:
sudo nftban-apply       # Safety enabled
sudo nftban-confirm     # Explicit confirmation

# Bad:
# Direct nft commands (no safety!)
```

**Test in new terminal**:
```bash
# Step 1: Apply rules
sudo nftban-apply

# Step 2: Open NEW terminal, test SSH
ssh user@server
# DON'T close old terminal until confirmed!

# Step 3: Confirm from either terminal
sudo nftban-confirm
```

**Adjust grace period for your needs**:
```bash
# Edit /etc/nftban/conf.d/recovery.conf
NFTBAN_REBOOT_GRACE_PERIOD="600"  # 10 minutes for complex testing
# Or
NFTBAN_REBOOT_GRACE_PERIOD="120"  # 2 minutes for quick tests
```

### Production Deployment

**Testing workflow**:
```bash
# 1. Test on lab server first
lab$ sudo nftban-apply
lab$ # Test thoroughly
lab$ sudo nftban-confirm

# 2. Deploy to production (off-peak hours)
prod$ sudo nftban-apply
prod$ # Test all critical services
prod$ sudo nftban-confirm

# 3. Monitor for 24 hours
prod$ tail -f /var/log/nftban/*.log
```

**Rollout strategy**:
1. Test on 1 lab server (1-2 hours)
2. Test on 1 production server (24 hours monitoring)
3. Roll out to 10% of fleet
4. Roll out to 100% of fleet

**Rollback plan**:
```bash
# If issues found:
sudo nftban-rollback --force

# Or reboot with kill-switch:
# (at GRUB: add nftban=disabled)
```

### Emergency Preparedness

**Create runbook**:
```markdown
# Server Lockout Recovery Runbook

## Step 1: Verify Lockout
- Try SSH from different location
- Check monitoring dashboard
- Ping server (ICMP may work)

## Step 2: Wait for Auto-Rollback
- Default: 5 minutes
- Check time of last nftban-apply
- Wait if < 5 minutes ago

## Step 3: Console Access
- IPMI URL: https://ipmi.yourserver.com
- Credentials: (see password manager)
- Alternative: Provider console

## Step 4: Emergency Recovery
- Login via console
- Run: sudo nftban-rollback --force
- Test SSH from external

## Step 5: If Still Broken
- Run: nft flush ruleset
- Fix rules
- Re-apply with safety

## Contacts
- On-call: +1-555-xxx-xxxx
- NOC: support@provider.com
- IPMI vendor: vendor-support@...
```

**Test recovery procedures**:
```bash
# Quarterly drill:
1. Intentionally break firewall on test server
2. Practice recovery with console
3. Time how long recovery takes
4. Update runbook with learnings
```

---

## Configuration Reference

### Key Configuration Files

**Recovery config**: `/etc/nftban/conf.d/recovery.conf`
```bash
NFTBAN_RECOVERY_ENABLED="true"
NFTBAN_REBOOT_GRACE_PERIOD="300"
NFTBAN_SSH_TEST_BEFORE_APPLY="true"
NFTBAN_ROLLBACK_ALERT="true"
```

**Systemd units**:
- `/usr/lib/systemd/system/nftban-apply.service` - Apply with safety
- `/usr/lib/systemd/system/nftban-rollback.service` - Rollback check
- `/usr/lib/systemd/system/nftban-rollback.timer` - Periodic check

**Scripts**:
- `/usr/sbin/nftban-apply` - Apply rules with commit-confirm
- `/usr/sbin/nftban-confirm` - Confirm rules
- `/usr/sbin/nftban-rollback` - Rollback to backup

**Data files**:
- `/var/lib/nftban/backup.rules` - Last-known-good backup
- `/run/nftban.rollback.deadline` - Rollback deadline timestamp
- `/etc/nftban/baseline.nft` - Emergency baseline rules

### Command Reference

```bash
# Apply rules with safety
sudo nftban-apply

# Confirm rules (keep them)
sudo nftban-confirm

# Rollback immediately
sudo nftban-rollback --force

# Check if rollback pending
systemctl status nftban-rollback.timer

# View backup rules
cat /var/lib/nftban/backup.rules

# Load baseline (emergency)
sudo nft -f /etc/nftban/baseline.nft

# Flush all rules (nuclear option)
sudo nft flush ruleset

# Disable NFTBan at boot (GRUB)
# Add to kernel line: nftban=disabled
```

---

## FAQ

**Q: What happens if the server reboots during grace period?**

A: On reboot, the rollback timer is cleared. NFTBan will apply rules fresh (with safety checks if enabled). The commit-confirm process starts over.

**Q: Can I disable the recovery system?**

A: Yes, but not recommended. Set `NFTBAN_RECOVERY_ENABLED="false"` in recovery.conf. You'll lose automatic rollback protection.

**Q: What if backup.rules is corrupted?**

A: Use the baseline.nft instead: `sudo nft -f /etc/nftban/baseline.nft`. Then rebuild proper rules.

**Q: Does rollback affect fail2ban bans?**

A: No. Fail2ban bans are in separate nftables sets and are NOT affected by rollback. Only main firewall rules rollback.

**Q: Does rollback affect threat feed blocks?**

A: No. Threat feeds are in separate nftables sets and persist across rollbacks.

**Q: Can I customize the grace period per-apply?**

A: Yes, set environment variable:
```bash
NFTBAN_REBOOT_GRACE_PERIOD=600 sudo nftban-apply
```

**Q: What if I accidentally confirm bad rules?**

A: The previous backup is still at `/var/lib/nftban/backup.rules`. You can manually load it:
```bash
sudo nft -f /var/lib/nftban/backup.rules
```

**Q: Can I test without risking production?**

A: Yes! Test on lab server first. Or use VERY short grace period (30s) and be ready at console.

---

## Support & Resources

### Documentation
- **This guide**: `/usr/share/doc/nftban/RECOVERY_GUIDE.md`
- **Configuration**: `/etc/nftban/conf.d/recovery.conf`
- **Main README**: `/usr/share/doc/nftban/README.md`

### Commands
```bash
# Help
nftban help
man nftban

# Status check
systemctl status nftban-rollback.timer
nft list ruleset
```

### Logs
```bash
# Recovery logs
journalctl -u nftban-apply.service
journalctl -u nftban-rollback.service

# NFTBan general logs
tail -f /var/log/nftban/nftban.log

# nftables
journalctl -u nftables
```

### Community
- **Project website**: https://nftban.com
- **Documentation**: https://nftban.com/docs
- **Support**: contact@nftban.com

---

## Summary

**NFTBan v0.10.0 prevents permanent lockouts with:**

✓ **Commit-confirm pattern** - Apply → Test → Confirm
✓ **Automatic rollback** - Rules revert if not confirmed
✓ **SSH connectivity testing** - Verify before applying
✓ **Multiple recovery paths** - Console, IPMI, GRUB kill-switch
✓ **Baseline ruleset** - Emergency fallback
✓ **No permanent damage** - Always recoverable

**You can never permanently lock yourself out again!**

---

**NFTBan v0.10.0** — Simplifying Linux Firewall Management

For more information, visit: https://nftban.com
