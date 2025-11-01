# Quick Start Guide

**Get NFTBan running in 5 minutes**

This guide will get you from zero to a protected server in 5 minutes.

---

## Prerequisites

Before you begin, ensure your system meets these requirements:

- **Operating System**: Linux kernel 5.10+ (Rocky Linux 9+, AlmaLinux 9+, Fedora 38+, Ubuntu 22.04+, Debian 12+)
- **Packages**: nftables 1.0.0+, systemd 250+, bash 5.0+
- **Access**: Root or sudo privileges
- **Network**: Internet connection for installation

---

## Step 1: Install NFTBan (1 minute)

### Option A: Quick Install (Recommended)

```bash
curl -sSL https://nftban.com/install.sh | sudo bash
```

### Option B: From Git

```bash
git clone https://github.com/itcmsgr/nftban.git
cd nftban
sudo ./install.sh
```

The installer will:
- ✓ Install required packages (nftables, fail2ban)
- ✓ Create FHS-compliant directory structure
- ✓ Deploy 17 core modules and 15 CLI commands
- ✓ Set up systemd services
- ✓ Configure default security profile
- ✓ Initialize nftables with 3-table structure

**Expected time**: 30-60 seconds

---

## Step 2: Verify Installation (30 seconds)

Check that NFTBan is installed and healthy:

```bash
sudo nftban health check
```

**Expected output:**
```
✓ Installation Integrity    PASS
✓ nftables Structure        PASS (3 tables: runtime, v4, v6)
✓ Module Availability       PASS (17 modules found)
✓ Configuration Validity    PASS
✓ Service Status            PASS (Fail2ban active)

Overall Health: HEALTHY ✓
```

If any checks fail, run with auto-fix:
```bash
sudo nftban health check --fix
```

---

## Step 3: Choose Security Profile (1 minute)

NFTBan includes 6 pre-configured security profiles. Choose the one that matches your server type:

### List Available Profiles

```bash
sudo nftban profile list
```

**Output:**
```
Available Security Profiles:
════════════════════════════

1. maximum        - Maximum Security (All protections enabled)
2. web-server     - Web Server (High HTTP/HTTPS traffic)
3. mail-server    - Mail Server (SMTP/IMAP/POP3 optimized)
4. database       - Database Server (MySQL/PostgreSQL)
5. mixed          - Mixed Services (Balanced approach)
6. development    - Development Mode (Minimal restrictions)
```

### Apply a Profile

**For most production servers** (recommended):
```bash
sudo nftban profile set mixed
```

**For maximum security** (paranoid mode):
```bash
sudo nftban profile set maximum
```

**For web servers** (Nginx/Apache):
```bash
sudo nftban profile set web-server
```

**For development servers**:
```bash
sudo nftban profile set development
```

The profile will be applied immediately to `/etc/nftban/nftban.conf.local`.

---

## Step 4: Update Threat Feeds (1 minute)

NFTBan uses threat intelligence feeds to block known malicious IPs. Update feeds:

```bash
sudo nftban feeds update
```

**Expected output:**
```
⏳ Updating threat intelligence feeds...

Downloading feeds (parallel):
  ✓ SPAMHAUS_DROP          (3,456 IPs)
  ✓ FIREHOL_LEVEL1         (45,678 IPs)
  ✓ EMERGING_COMPROMISED   (12,345 IPs)
  [... 11 more feeds ...]

Processing with Go binary: <1 second
Applying to nftables: Done

Total IPs blocked: 123,456
```

**Performance note**: Go binary processes 1M IPs in <1 second (vs 60-90s in bash)!

---

## Step 5: Apply Firewall Rules (1 minute)

Apply firewall rules with commit-confirm safety:

```bash
sudo nftban-apply
```

**What happens:**
1. ✓ Validates candidate ruleset
2. ✓ Creates backup of current rules
3. ✓ Applies new rules
4. ✓ Arms 5-minute rollback timer
5. ✓ Tests SSH connectivity

**Expected output:**
```
⏳ Applying NFTBan firewall rules...

  ✓ Validated ruleset (nft -c)
  ✓ Backed up current rules
  ✓ Applied new rules
  ✓ Armed rollback timer (5 minutes)
  ✓ SSH connectivity: OK

Rules applied successfully!

⚠️  IMPORTANT: You have 5 minutes to confirm!

Test your connectivity:
  - Can you SSH?
  - Can you access services?
  - Is everything working?

If YES, run:  sudo nftban-confirm
If NO, wait for auto-rollback (or run: sudo nftban-rollback)
```

### Test Connectivity (30 seconds)

**Open a NEW terminal** and test SSH:
```bash
ssh user@your-server-ip
```

If SSH works:
```bash
sudo nftban-confirm
```

**Output:**
```
✓ Rules confirmed!
✓ Rollback timer disarmed
✓ Configuration is now permanent
```

**If SSH fails**: Wait 5 minutes for automatic rollback, or force it:
```bash
sudo nftban-rollback --force
```

---

## Step 6: Enable Fail2Ban Integration (1 minute)

Enable automatic banning of brute-force attacks:

```bash
sudo nftban fail2ban sync
```

**What it does:**
- Discovers all active Fail2Ban jails automatically
- Creates NFTBan action for each jail
- Configures automatic temp bans (1 hour default)

**Expected output:**
```
🔍 Discovering Fail2Ban jails...

Found 3 active jails:
  ✓ sshd
  ✓ nginx-http-auth
  ✓ wordpress

Creating NFTBan actions:
  ✓ /etc/fail2ban/action.d/nftban-ban.conf
  ✓ Configured jail: sshd
  ✓ Configured jail: nginx-http-auth
  ✓ Configured jail: wordpress

Restarting Fail2Ban: Done

Fail2Ban → NFTBan integration complete!
```

Check jail status:
```bash
sudo nftban fail2ban status
```

---

## ✅ You're Done!

Your server is now protected with NFTBan! Here's what you have:

### Active Protection Layers

1. **✓ Connection State** - Stateful firewall
2. **✓ IP Whitelist** - Trusted IPs (system IPs auto-discovered)
3. **✓ Port Filtering** - Only required ports open
4. **✓ Dynamic Blacklist** - Manual bans ready
5. **✓ Threat Intelligence** - 123K+ known bad IPs blocked
6. **✓ Intrusion Detection** - Fail2Ban auto-banning
7. **✓ Application Layer** - App-specific security
8. **✓ Recovery System** - Cannot lock yourself out!

### What's Running

- **nftables**: 3 tables (runtime, v4, v6) with optimized rules
- **Fail2Ban**: Auto-banning SSH brute-force attacks
- **Threat Feeds**: 123K+ malicious IPs blocked
- **Health Monitor**: Continuous system checks
- **Recovery System**: 5-minute commit-confirm protection

---

## Next Steps

### Learn More

- **[Ban System Guide](ban-system.md)** - How to ban/unban IPs manually
- **[Security Profiles](security-profiles.md)** - Detailed profile comparison
- **[Health Diagnostics](health-diagnostics.md)** - System health monitoring
- **[Threat Feeds](feeds.md)** - Managing threat intelligence
- **[Architecture](../concepts/architecture.md)** - How NFTBan works

### Common Tasks

#### Ban an IP Manually

```bash
# Temporary ban (1 hour)
sudo nftban ban 192.0.2.50

# Permanent ban
sudo nftban ban 192.0.2.50 --permanent

# Unban
sudo nftban unban 192.0.2.50
```

#### List Banned IPs

```bash
sudo nftban list banned
```

#### Whitelist an IP

```bash
sudo nftban whitelist add 203.0.113.100
```

#### Check System Status

```bash
# Quick health check
sudo nftban health check

# Show current security profile
sudo nftban profile show

# Show Fail2Ban status
sudo nftban fail2ban status

# Show nftables statistics
sudo nftban nftables stats
```

#### Update Feeds (Daily/Weekly)

```bash
sudo nftban feeds update
```

**Tip**: Set up a cron job for automatic updates:
```bash
# Edit crontab
sudo crontab -e

# Add this line (daily at 3am):
0 3 * * * /usr/sbin/nftban feeds update >> /var/log/nftban/feeds-update.log 2>&1
```

---

## Troubleshooting

### Issue: "nftban: command not found"

**Solution**: Reinstall or add to PATH:
```bash
sudo ln -sf /usr/sbin/nftban /usr/local/bin/nftban
```

### Issue: Health check fails

**Solution**: Run with auto-fix:
```bash
sudo nftban health check --fix --verbose
```

### Issue: Locked out after nftban-apply

**Solution**: Wait 5 minutes for automatic rollback, or:
1. Access server via console/IPMI
2. Run: `sudo nftban-rollback --force`

### Issue: Feed update takes too long

**Solution**: Check if Go binary is working:
```bash
/usr/share/nftban/go-binaries/nftban-feeds --version
```

If missing, reinstall NFTBan.

### Issue: Fail2Ban not integrating

**Solution**: Check Fail2Ban is running:
```bash
sudo systemctl status fail2ban
sudo nftban fail2ban sync
```

---

## Emergency Recovery

If you accidentally lock yourself out:

### Path 1: Wait for Auto-Rollback (5 minutes)
- Safest option
- Rules restore automatically
- No console access needed

### Path 2: Console/IPMI Access
```bash
# Login via console
sudo nftban-rollback --force
```

### Path 3: Kernel Kill-Switch
```bash
# Reboot server
# Edit GRUB entry (press 'e')
# Add to linux line: nftban=disabled
# Boot

# Fix configuration, then remove nftban=disabled and reboot
```

---

## Summary

**Time spent**: 5-6 minutes
**Protection level**: Production-grade
**Locked out risk**: Zero (auto-rollback)

Your server is now protected with:
- ✓ Modern nftables firewall
- ✓ Automatic threat blocking (123K+ IPs)
- ✓ Brute-force protection (Fail2Ban)
- ✓ DDoS protection
- ✓ Port scan detection
- ✓ Recovery system (cannot lock out)

**Questions?** See the [full documentation](../index.md) or [troubleshooting guide](troubleshoot.md).

---

**Next**: [Ban System Guide →](ban-system.md)

