# NFTBan v0.30 - Lab Server Issues Found

**Date:** 2025-11-03
**Analysis:** Claude AI

## 🔴 Critical Issues - Why No Emails Are Sent

### 1. EMAIL NOT CONFIGURED
- **Problem:** No `NFTBAN_MAIL_TO` variable set in configuration files
- **Impact:** NFTBan doesn't know where to send alerts
- **Found in:** All 5 lab servers
- **Solution:** Add to `/etc/nftban/nftban.conf.local`:
  ```bash
  NFTBAN_MAIL_TO="contact@nftban.com"
  NFTBAN_MAIL_ENABLED="true"
  ```

### 2. NFTBan Package Status
- **lab.mywebhost.gr:** Package NOT installed via RPM (manual installation)
- **lab1.mywebhost.gr:** Package NOT installed via DEB (manual installation)
- **lab2/lab3/lab4:** Partial RPM installation
- **Root Cause:** Servers have v0.10.0 installed manually (from ChatGPT testing), not via package manager

### 3. Health Check Failures
- **Read-only filesystem errors** on `/usr/share/nftban`
- Permission enforcement failing repeatedly
- Service exits with code 2 (INVALIDARGUMENT)
- Health check reports: `Health: ERROR (1 errors, 2 warnings)`

### 4. Service Configuration
- `nftban.timer`: DISABLED on most servers
- `nftban-health.timer`: ENABLED but failing every run
- Services manually installed, not properly integrated

## 📊 Server-by-Server Status

| Server | OS | Version | Timers Active | Email Config | Issues |
|--------|-----|---------|---------------|--------------|--------|
| lab.mywebhost.gr | CentOS Stream 9 | Manual v0.10 | 1/2 | ❌ No | Read-only FS, No email |
| lab1.mywebhost.gr | Ubuntu 24.04 | Manual v0.10 | 1/2 | ❌ No | Read-only FS, No email |
| lab2.mywebhost.gr | CentOS Stream 10 | Manual v0.10 | 1/2 | ❌ No | Read-only FS, No email |
| lab3.mywebhost.gr | AlmaLinux 10.0 | Manual v0.10 | 0/2 | ❌ No | No mail cmd, No email |
| lab4.mywebhost.gr | Rocky Linux 10 | RPM v0.10 | 1/2 | ❌ No | No mail cmd, No email |

## 🔍 Root Cause Analysis

The lab servers have NFTBan v0.10.0 installed **MANUALLY** (from ChatGPT deployment/testing), NOT via package manager. This explains:

1. ❌ No RPM/DEB package shows as installed
2. ❌ Configuration files incomplete
3. ❌ Email notifications not configured
4. ❌ v0.30 components deployed but not integrated
5. ❌ Services not properly managed by systemd

## ✅ Solution: Clean Package Installation

Wait for GitHub Actions to build v0.30.0 packages (in progress), then:

### Step 1: Install Proper Packages

**RPM servers (CentOS, AlmaLinux, Rocky):**
```bash
dnf upgrade -y https://github.com/itcmsgr/nftban/releases/download/v0.30.0/nftban-0.30.0-1.el9.x86_64.rpm
```

**DEB servers (Ubuntu):**
```bash
apt install -y https://github.com/itcmsgr/nftban/releases/download/v0.30.0/nftban_0.30.0-1_amd64.deb
```

### Step 2: Configure Email

Create `/etc/nftban/nftban.conf.local`:
```bash
# Email configuration for v0.30
NFTBAN_MAIL_TO="contact@nftban.com"
NFTBAN_MAIL_ENABLED="true"

# Resource monitoring thresholds (optional)
NFTBAN_DISK_WARN_THRESHOLD=85
NFTBAN_DISK_CRIT_THRESHOLD=95
NFTBAN_RAM_WARN_THRESHOLD=90

# Alert throttling
NFTBAN_ALERT_THROTTLE_SECONDS=3600  # 1 hour
```

### Step 3: Enable Services

```bash
systemctl enable --now nftban.timer
systemctl enable --now nftban-health.timer
```

### Step 4: Test

```bash
# Test health check
nftban health check

# Test inventory
nftban-health --inventory | jq .

# Trigger alert (will send email if configured)
nftban health check
```

## 📁 Log Files

Detailed logs from all 5 servers saved in:
- `docs/testing/v0.30/lab_logs/lab.mywebhost.gr_status.log`
- `docs/testing/v0.30/lab_logs/lab1.mywebhost.gr_status.log`
- `docs/testing/v0.30/lab_logs/lab2.mywebhost.gr_status.log`
- `docs/testing/v0.30/lab_logs/lab3.mywebhost.gr_status.log`
- `docs/testing/v0.30/lab_logs/lab4.mywebhost.gr_status.log`

## 🎯 Next Steps

1. ⏳ **Wait for GitHub Actions** to complete v0.30.0 package build (~5-10 minutes)
2. 📥 **Download and install** packages on all lab servers
3. ⚙️ **Configure email** via `.local` override files
4. 🧪 **Test complete workflow** including email alerts
5. ✅ **Validate** CI/CD pipeline: Git → Build → Release → Install → Test

## 🔗 Related Documentation

- **Test Scripts:** `docs/testing/v0.30/test_package_upgrade_labs.sh`
- **Monitor Script:** `docs/testing/v0.30/monitor_build.sh`
- **Test Results:** `docs/testing/v0.30/TEST_REVIEW_SUMMARY.md`
- **Deployment Report:** `docs/testing/v0.30/FINAL_DEPLOYMENT_REPORT.md`

---

**Status:** Issues documented, solution prepared, waiting for automated package build to complete.
