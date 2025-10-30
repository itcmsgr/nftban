# NFTBan v0.10.0 - Lab Deployment Checklist

**Purpose:** Step-by-step checklist for deploying and testing NFTBan on lab servers
**Version:** v0.10.0
**Servers:** lab.mywebhost.gr, lab1.mywebhost.gr, lab2.mywebhost.gr

---

## Pre-Deployment

### ✅ Preparation

- [ ] Backup current nftban configuration (if exists)
- [ ] Review changes in git log
- [ ] Build/download latest package
- [ ] Have console/IPMI access ready (in case of lockout)
- [ ] Notify team of maintenance window

```bash
# Backup existing installation (if present)
tar -czf /root/nftban-backup-$(date +%Y%m%d).tar.gz \
  /etc/nftban \
  /usr/lib/nftban \
  /var/lib/nftban \
  2>/dev/null || true
```

---

## Deployment Steps

### 1. Push Code to Git

- [ ] All changes committed locally
- [ ] Tests pass (if applicable)
- [ ] Documentation updated
- [ ] Push to GitHub

```bash
cd /home/gituser/github/nftban
git status
git log --oneline -5
git push origin main
```

### 2. Deploy to Lab Servers

**Method A: From Git (Recommended)**

```bash
# On each lab server
ssh root@lab.mywebhost.gr

# Pull latest code
cd /root/nftban-deploy
git pull origin main

# Install/update
cd src
sudo ./install.sh

# Or use package
sudo dnf install -y ./nftban-0.10.0-1.el9.x86_64.rpm
```

**Method B: SCP from dev machine**

```bash
# From dev machine
cd /home/gituser/github/nftban
tar -czf /tmp/nftban-v0.10.0.tar.gz src/

# Deploy to each server
for server in lab.mywebhost.gr lab1.mywebhost.gr lab2.mywebhost.gr; do
  scp /tmp/nftban-v0.10.0.tar.gz root@$server:/tmp/
  ssh root@$server "cd /tmp && tar -xzf nftban-v0.10.0.tar.gz && cd src && ./install.sh"
done
```

### 3. Verify Installation

**On each server:**

- [ ] NFTBan binary installed
- [ ] User and groups created
- [ ] Polkit rule installed
- [ ] Systemd units present
- [ ] Permissions correct

```bash
# Check version
nftban --version
# Expected: NFTBan v0.10.0

# Check users/groups
getent passwd nftban
getent group nftban-cli
# Expected: Both exist

# Check Polkit rule
ls -la /usr/share/polkit-1/rules.d/60-nftban-cli.rules
# Expected: -rw-r--r-- 1 root root ... 60-nftban-cli.rules

# Check file permissions
nftban fhs check
# Expected: 21/21 OK
```

---

## Testing

### 4. Test Core Functionality

**On first server (lab.mywebhost.gr):**

- [ ] Health check passes
- [ ] FHS compliance OK
- [ ] Services status correct
- [ ] No permission errors

```bash
# Health check
nftban health check
# Expected: 0 errors, 0 warnings

# FHS compliance
nftban fhs check
# Expected: 21/21 directories OK

# Services status
nftban services status
# Expected: All services shown correctly
```

### 5. Test Polkit Integration

**Critical Test: Group-based service management**

- [ ] Add test user to nftban-cli group
- [ ] Test service management without sudo
- [ ] Verify scope limits (cannot manage other services)
- [ ] Test NFTBan CLI commands

```bash
# Add user to nftban-cli group (replace 'antonis' with actual username)
sudo usermod -aG nftban-cli antonis

# Verify group membership
id antonis | grep nftban-cli
# Expected: Should show nftban-cli in groups

# Switch to test user
su - antonis

# Test service management (WITHOUT sudo)
systemctl status nftables
# Expected: Should work

systemctl restart nftables
# Expected: Should work without password

systemctl restart fail2ban
# Expected: Should work without password

# Test NFTBan CLI
nftban start nftables
# Expected: ✓ nftables service started successfully

nftban stop fail2ban
# Expected: ✓ fail2ban service stopped successfully

nftban restart nftables
# Expected: ✓ nftables service restarted successfully

# Test scope limit (should be DENIED)
systemctl restart sshd
# Expected: ==== AUTHENTICATION FAILED ====
#           Access denied (not in allowlist)

# Exit back to root
exit
```

### 6. Test File Permissions

**Verify security model:**

- [ ] root owns code
- [ ] root owns config (nftban-cli can read)
- [ ] nftban owns runtime data
- [ ] Regular users cannot write to system files

```bash
# Check code ownership
stat -c "%U:%G %a %n" /usr/lib/nftban
# Expected: root:root 755 /usr/lib/nftban

# Check config ownership
stat -c "%U:%G %a %n" /etc/nftban
# Expected: root:nftban-cli 750 /etc/nftban

# Check runtime data
stat -c "%U:%G %a %n" /var/lib/nftban
# Expected: nftban:nftban 755 /var/lib/nftban

# Test as nftban-cli user (cannot modify code)
su - antonis
cat /etc/nftban/nftban.conf
# Expected: Can read

echo "test" >> /etc/nftban/nftban.conf
# Expected: Permission denied

exit
```

### 7. Test Firewall Operations

**Verify firewall functionality:**

- [ ] Firewall status check
- [ ] Ban/unban operations
- [ ] Whitelist/blacklist
- [ ] Stats dashboard

```bash
# Firewall status
nftban firewall status
# Expected: Firewall health report

# Test ban
nftban ban 192.0.2.100 1h test
# Expected: IP banned successfully

# Verify ban
nftban list banned
# Expected: 192.0.2.100 shown

# Test unban
nftban unban 192.0.2.100
# Expected: IP unbanned

# Stats dashboard
nftban stats dashboard
# Expected: Current statistics shown
```

---

## Verification Matrix

### Server Status Table

| Server | Version | FHS | Polkit | Users | Services | Status |
|--------|---------|-----|--------|-------|----------|--------|
| lab.mywebhost.gr | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| lab1.mywebhost.gr | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |
| lab2.mywebhost.gr | [ ] | [ ] | [ ] | [ ] | [ ] | [ ] |

**Fill in with:**
- ✅ PASS
- ❌ FAIL
- ⚠️ WARNING

### Detailed Checks

**For each server, verify:**

```bash
# Version
nftban --version

# FHS compliance
nftban fhs check

# Polkit rule
ls /usr/share/polkit-1/rules.d/60-nftban-cli.rules

# Users and groups
getent passwd nftban
getent group nftban-cli

# Services
systemctl status nftables
systemctl status fail2ban

# Permissions
nftban health check
```

---

## Post-Deployment

### 8. Enable Services

**On all servers:**

- [ ] Enable nftban timers
- [ ] Enable health monitoring
- [ ] Enable permission audit
- [ ] Verify timers scheduled

```bash
# Enable auto-heal timer
sudo systemctl enable --now nftban-health.timer

# Enable permission audit
sudo systemctl enable --now nftban-permissions-audit.timer

# Verify timers
systemctl list-timers | grep nftban
# Expected: Both timers shown with next run time
```

### 9. Monitor Logs

**Check for any issues:**

- [ ] No errors in journal
- [ ] No permission warnings
- [ ] Services stable

```bash
# Check recent logs
journalctl -u nftban-health.service -n 50
journalctl -u nftban-permissions-audit.service -n 50

# Check for errors
journalctl -p err -n 50 | grep nftban

# Monitor live (Ctrl+C to exit)
journalctl -f -u nftban-health.service
```

### 10. Document Results

**Record deployment outcome:**

```bash
# Create deployment report
cat > /root/nftban-deployment-$(date +%Y%m%d).txt <<EOF
NFTBan v0.10.0 Deployment Report
Date: $(date)
Server: $(hostname)

Version: $(nftban --version)
FHS Status: $(nftban fhs check | grep "directories")
Health: $(nftban health check | grep -c "ERROR")
Polkit: $(ls /usr/share/polkit-1/rules.d/60-nftban-cli.rules && echo "OK" || echo "MISSING")

Users:
$(getent passwd nftban)
$(getent group nftban-cli)

Timers:
$(systemctl list-timers | grep nftban)

Status: ✅ PASS / ⚠️ WARNING / ❌ FAIL
Notes: [Add any issues or observations]
EOF

cat /root/nftban-deployment-$(date +%Y%m%d).txt
```

---

## Rollback Procedure

**If deployment fails:**

### Emergency Rollback

```bash
# Stop services
sudo systemctl stop nftban-health.timer
sudo systemctl stop nftban-permissions-audit.timer

# Restore from backup
sudo tar -xzf /root/nftban-backup-YYYYMMDD.tar.gz -C /

# Restart services
sudo systemctl daemon-reload
sudo systemctl start nftban-health.timer

# Verify
nftban --version
```

### Clean Uninstall

```bash
# Uninstall package
sudo dnf remove nftban  # or apt remove nftban

# Or manual cleanup
sudo rm -rf /usr/lib/nftban
sudo rm -rf /etc/nftban
sudo rm /usr/sbin/nftban
sudo rm /usr/share/polkit-1/rules.d/60-nftban-cli.rules
sudo userdel nftban
sudo groupdel nftban-cli
```

---

## Success Criteria

**Deployment is successful when:**

- ✅ NFTBan v0.10.0 installed on all servers
- ✅ FHS compliance: 21/21 OK
- ✅ Polkit rule present and working
- ✅ Users can manage services as nftban-cli group members
- ✅ File permissions correct (root owns code, nftban owns data)
- ✅ No errors in health checks
- ✅ Timers enabled and scheduled
- ✅ Firewall operations working
- ✅ No lockouts or connectivity issues

---

## Troubleshooting

### Common Issues

**Polkit not working:**
```bash
# Check rule exists
ls -la /usr/share/polkit-1/rules.d/60-nftban-cli.rules

# Restart Polkit
sudo systemctl restart polkit

# Check Polkit logs
journalctl -u polkit -n 50
```

**Permission denied:**
```bash
# Verify group membership
id username | grep nftban-cli

# User must re-login
su - username
newgrp nftban-cli
```

**FHS errors:**
```bash
# Fix as root
sudo nftban health fix all

# Check result
nftban fhs check
```

---

## Final Checklist

Before marking deployment complete:

- [ ] All 3 servers deployed
- [ ] All tests passed
- [ ] Polkit working on all servers
- [ ] No errors in logs
- [ ] Timers enabled
- [ ] Documentation updated
- [ ] Deployment report created
- [ ] Team notified of completion

---

**Deployment Date:** _______________
**Deployed By:** _______________
**Status:** ✅ SUCCESS / ⚠️ PARTIAL / ❌ FAILED
**Notes:** _______________

---

**Next Steps After Successful Deployment:**
1. Monitor for 24-48 hours
2. Review timer execution logs
3. Test in production-like scenarios
4. Consider enabling additional features (feeds, DDoS, etc.)
5. Update production servers after lab validation

**End of Checklist**
