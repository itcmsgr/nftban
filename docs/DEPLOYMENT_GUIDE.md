# NFTBan v0.10.0 - Deployment Guide
**Date:** 2025-10-27
**Status:** 🚀 READY FOR DEPLOYMENT

═══════════════════════════════════════════════════════════════════════════════

## 📦 WHAT WILL BE DEPLOYED

### **Critical Fixes (Production-Ready)**
1. ✅ **Atomic Reload** - `nftban_nftables.sh` (6.1K)
2. ✅ **Whitelist Security** - `nftban_security.sh` (3.2K)
3. ✅ **Atomic File Writes** - `nftban_file_ops.sh` (4.0K)

### **System IP Protection**
4. ✅ **Auto-Detection Module** - `nftban_system_ip.sh` (16K)
5. ✅ **CLI Command** - `cmd_whitelist_system.sh` (2.3K)

### **Deployment Files**
6. ✅ **Systemd Units** - 8 units (nftban.service, timers, etc.)
7. ✅ **System Configs** - tmpfiles, sysusers, logrotate, auditd
8. ✅ **Install Script** - `deploy/install.sh`
9. ✅ **Template Files** - whitelist.conf, blacklist.conf

**Total:** 31.6K of production-ready code

═══════════════════════════════════════════════════════════════════════════════

## 🎯 DEPLOYMENT TARGETS

**Lab Servers:**
- lab.mywebhost.gr
- lab1.mywebhost.gr
- lab2.mywebhost.gr

═══════════════════════════════════════════════════════════════════════════════

## 🚀 AUTOMATED DEPLOYMENT

### **Quick Deploy (All Servers)**

```bash
cd /home/gituser/nftban-v0.10.0-dev
./DEPLOY_TO_LAB.sh
```

**What it does:**
1. Syncs core modules to `/usr/lib/nftban/core/`
2. Syncs CLI commands to `/usr/lib/nftban/cli/`
3. Syncs deployment files to `/tmp/nftban-deploy/`
4. Installs systemd units
5. Tests system IP detection

**Duration:** ~2 minutes per server

═══════════════════════════════════════════════════════════════════════════════

## 🔧 MANUAL DEPLOYMENT (Step-by-Step)

### **Step 1: Sync Files**

```bash
SERVER="lab.mywebhost.gr"

# Core modules
rsync -avz src/usr/lib/nftban/core/ root@$SERVER:/usr/lib/nftban/core/

# CLI commands
rsync -avz src/usr/lib/nftban/cli/ root@$SERVER:/usr/lib/nftban/cli/

# Deployment files
rsync -avz deploy/ root@$SERVER:/tmp/nftban-deploy/
```

---

### **Step 2: Install Systemd Units**

```bash
ssh root@$SERVER "
    # Install all systemd units
    cd /tmp/nftban-deploy

    install -D -m 0644 systemd/nftban.service /etc/systemd/system/
    install -D -m 0644 systemd/nftban.path /etc/systemd/system/
    install -D -m 0644 systemd/nftban-geoip-update.service /etc/systemd/system/
    install -D -m 0644 systemd/nftban-geoip-update.timer /etc/systemd/system/
    install -D -m 0644 systemd/nftban-backup.service /etc/systemd/system/
    install -D -m 0644 systemd/nftban-backup.timer /etc/systemd/system/
    install -D -m 0644 systemd/nftban-system-sync.service /etc/systemd/system/
    install -D -m 0644 systemd/nftban-system-sync.timer /etc/systemd/system/

    systemctl daemon-reload
    echo '✓ Systemd units installed'
"
```

---

### **Step 3: Install System Configs**

```bash
ssh root@$SERVER "
    cd /tmp/nftban-deploy

    # tmpfiles.d
    install -D -m 0644 tmpfiles.d/nftban.conf /etc/tmpfiles.d/

    # sysusers.d
    install -D -m 0644 sysusers.d/nftban.conf /etc/sysusers.d/

    # logrotate
    install -D -m 0644 logrotate.d/nftban /etc/logrotate.d/

    # auditd
    install -D -m 0644 auditd/nftban_whitelist.rules /etc/audit/rules.d/

    # Apply configs
    systemd-sysusers
    systemd-tmpfiles --create

    echo '✓ System configs installed'
"
```

---

### **Step 4: Create Directories**

```bash
ssh root@$SERVER "
    # Create directory structure
    mkdir -p /etc/nftban/{whitelist.d,blacklist.d,feeds.d,geoip.d,ports.d}
    mkdir -p /var/lib/nftban/{compiled,state}
    mkdir -p /var/log/nftban
    mkdir -p /var/backups/nftban
    mkdir -p /run/nftban

    # Set ownership
    chown -R nftban:nftban /var/lib/nftban /var/log/nftban /run/nftban
    chown -R root:root /var/backups/nftban

    echo '✓ Directories created'
"
```

---

### **Step 5: Deploy Template Files**

```bash
# Copy templates to local config
rsync -avz templates/99-user-whitelist.conf root@$SERVER:/etc/nftban/whitelist.d/
rsync -avz templates/50-user-blacklist.conf root@$SERVER:/etc/nftban/blacklist.d/
```

═══════════════════════════════════════════════════════════════════════════════

## 🧪 POST-DEPLOYMENT TESTING

### **Test 1: System IP Detection**

```bash
ssh root@lab.mywebhost.gr "
    source /usr/lib/nftban/core/nftban_system_ip.sh

    echo '=== Interface IPs ==='
    nftban_get_interface_ips

    echo ''
    echo '=== Public IPv4 ==='
    nftban_get_public_ip ipv4

    echo ''
    echo '=== Current User IP ==='
    nftban_get_current_user_ip
"
```

---

### **Test 2: System IP Sync**

```bash
ssh root@lab.mywebhost.gr "
    source /usr/lib/nftban/core/nftban_system_ip.sh
    nftban_whitelist_system_sync
"
```

**Expected output:**
```
═══════════════════════════════════════════════════════════
NFTBan System IP Auto-Detection
═══════════════════════════════════════════════════════════

[1/5] Protecting localhost...
[ADD] Whitelisted: 127.0.0.1 (Localhost (critical))
[ADD] Whitelisted: ::1 (Localhost (critical))

[2/5] Protecting server interface IPs...
[ADD] Whitelisted: 10.x.x.x (Server interface (auto-detected))
...
```

---

### **Test 3: Atomic Reload**

```bash
ssh root@lab.mywebhost.gr "
    source /usr/lib/nftban/core/nftban_nftables.sh
    source /usr/lib/nftban/core/nftban_file_ops.sh

    # Test atomic reload
    nftban_atomic_reload
"
```

**Expected output:**
```
[OK] Atomic reload complete. Backup at: /var/backups/nftban/ruleset-YYYYMMDD-HHMMSS.nft
```

---

### **Test 4: Systemd Timers**

```bash
ssh root@lab.mywebhost.gr "
    # Enable timers
    systemctl enable --now nftban-system-sync.timer
    systemctl enable --now nftban-geoip-update.timer
    systemctl enable --now nftban-backup.timer

    # Check status
    systemctl list-timers | grep nftban
"
```

═══════════════════════════════════════════════════════════════════════════════

## 📋 DEPLOYMENT CHECKLIST

### **Pre-Deployment**
- [ ] Review all code changes
- [ ] Test locally on dev machine
- [ ] Backup existing nftban configs (if any)
- [ ] Verify SSH access to all lab servers

### **Deployment**
- [ ] Run `./DEPLOY_TO_LAB.sh` OR manual steps
- [ ] Verify files copied successfully
- [ ] Verify systemd units installed
- [ ] Verify directories created

### **Post-Deployment Testing**
- [ ] Test system IP detection
- [ ] Test system IP sync
- [ ] Test atomic reload
- [ ] Test systemd timers
- [ ] Check logs: `/var/log/nftban/`
- [ ] Verify nftables rules: `nft list ruleset`

### **Enable Services (After Testing)**
- [ ] Enable config watcher: `systemctl enable --now nftban.path`
- [ ] Enable system sync: `systemctl enable --now nftban-system-sync.timer`
- [ ] Enable GeoIP updates: `systemctl enable --now nftban-geoip-update.timer`
- [ ] Enable backups: `systemctl enable --now nftban-backup.timer`

═══════════════════════════════════════════════════════════════════════════════

## 🔄 ROLLBACK PROCEDURE

If deployment fails:

```bash
SERVER="lab.mywebhost.gr"

ssh root@$SERVER "
    # Stop all nftban services
    systemctl stop nftban.path
    systemctl stop nftban-system-sync.timer

    # Restore from backup
    source /usr/lib/nftban/core/nftban_nftables.sh
    nftban_rollback_last_backup

    # Verify
    nft list ruleset
"
```

═══════════════════════════════════════════════════════════════════════════════

## 📊 DEPLOYMENT STATUS

**Lab Servers:**
- [ ] lab.mywebhost.gr - Not deployed
- [ ] lab1.mywebhost.gr - Not deployed
- [ ] lab2.mywebhost.gr - Not deployed

**Update this after deployment!**

═══════════════════════════════════════════════════════════════════════════════

## 🚀 READY TO DEPLOY

**Run:**
```bash
cd /home/gituser/nftban-v0.10.0-dev
./DEPLOY_TO_LAB.sh
```

═══════════════════════════════════════════════════════════════════════════════
