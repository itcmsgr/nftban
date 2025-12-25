# NFTBan UI v0.5.1 - Installation & Removal Verification

**Date**: 2025-11-16
**Purpose**: Verify complete installation and clean removal for both RPM and DEB packages

---

## Installation Requirements Checklist

### 1. Users and Groups

#### What Gets Created on Install?

| Item | Type | UID/GID | Home | Shell | Purpose |
|------|------|---------|------|-------|---------|
| `nftban` | User | System (auto) | /var/lib/nftban | /sbin/nologin | Service user |
| `nftban` | Group | System (auto) | - | - | Daemon group (no human users) |
| `nftban-cli` | Group | System (auto) | - | - | CLI and Web GUI operators |
| `nftban-auditors` | Group | System (auto) | - | - | Read-only auditors |

> **Note:** NFTBan v1.0 uses 3-group model: `nftban` (daemon only), `nftban-cli` (CLI + Web GUI), `nftban-auditors` (read-only). The old `nftban-web` group is **retired**.

#### RPM Implementation (%pre)
```bash
getent group nftban >/dev/null || groupadd -r nftban
getent group nftban-auditors >/dev/null || groupadd -r nftban-auditors
getent passwd nftban >/dev/null || \
    useradd -r -g nftban -d /var/lib/nftban -s /sbin/nologin \
    -c "NFTBan system user" nftban
```

#### DEB Implementation (postinst)
```bash
if ! getent group nftban > /dev/null 2>&1; then
    addgroup --system nftban
fi
if ! getent group nftban-auditors > /dev/null 2>&1; then
    addgroup --system nftban-auditors
fi
if ! getent passwd nftban > /dev/null 2>&1; then
    adduser --system --group --home /var/lib/nftban \
        --no-create-home --disabled-login \
        --gecos "NFTBan system user" nftban
fi
```

**Status**: ✅ Identical behavior between RPM and DEB

---

### 2. Systemd Services

#### What Gets Installed?

| Service | Type | Enabled on Install? | Started on Install? |
|---------|------|---------------------|---------------------|
| `nftban-ui-auth.socket` | Socket | ✅ Yes (fresh install) | ✅ Yes (fresh install) |
| `nftban-ui-auth.service` | Service | ⚠️ No (socket-activated) | ⚠️ No (on-demand) |
| `nftban-ui.service` | Service | ⚠️ Manual | ⚠️ Manual |

**Note**: The auth service is socket-activated, so it starts automatically when the socket receives a connection.

#### RPM Implementation (%post)
```bash
# Enable and start socket (will auto-start service on-demand)
%systemd_post nftban-ui-auth.socket
%systemd_post nftban-ui.service

# Only enable socket if this is initial install
if [ $1 -eq 1 ]; then
    systemctl enable nftban-ui-auth.socket >/dev/null 2>&1 || :
    systemctl start nftban-ui-auth.socket >/dev/null 2>&1 || :
fi

# If upgrading and service is already running, restart it
if [ $1 -eq 2 ]; then
    systemctl try-restart nftban-ui-auth.socket >/dev/null 2>&1 || :
    systemctl try-restart nftban-ui.service >/dev/null 2>&1 || :
fi
```

**$1 = 1**: Fresh install
**$1 = 2**: Upgrade

#### DEB Implementation (postinst)
```bash
# Enable and start socket on fresh install
if [ -z "$2" ]; then
    deb-systemd-helper enable nftban-ui-auth.socket >/dev/null || true
    deb-systemd-invoke start nftban-ui-auth.socket >/dev/null || true
fi

# Restart services on upgrade
if [ -n "$2" ]; then
    deb-systemd-invoke try-restart nftban-ui-auth.socket >/dev/null || true
    deb-systemd-invoke try-restart nftban-ui.service >/dev/null || true
fi
```

**$2 = ""**: Fresh install
**$2 = "old-version"**: Upgrade

**Status**: ✅ Identical behavior between RPM and DEB

---

### 3. Files and Directories

#### Binaries

| File | Path | Permissions | Owner | Group |
|------|------|-------------|-------|-------|
| GUI Server | /usr/sbin/nftban-ui | 0755 | root | root |
| Auth Service | /usr/libexec/nftban-ui-auth | 0755 | root | root |

#### Systemd Units

| File | Path | Permissions | Owner | Group |
|------|------|-------------|-------|-------|
| GUI Service | /usr/lib/systemd/system/nftban-ui.service | 0644 | root | root |
| Auth Service | /usr/lib/systemd/system/nftban-ui-auth.service | 0644 | root | root |
| Auth Socket | /usr/lib/systemd/system/nftban-ui-auth.socket | 0644 | root | root |

**Note**: DEB uses `/lib/systemd/system/` which is symlinked to `/usr/lib/systemd/system/`

#### Configuration Files

| File | Path | Permissions | Owner | Group | Replaced on Upgrade? |
|------|------|-------------|-------|-------|---------------------|
| PAM Config | /etc/pam.d/nftban-ui | 0644 | root | root | ⚠️ No (noreplace/conffile) |
| Allowed Groups | /etc/nftban/allowed-gui-groups | 0644 | root | root | ⚠️ No (noreplace/conffile) |
| Main Config | /etc/nftban/ui.conf | 0644 | root | root | ⚠️ No (created by `nftban ui init`) |
| IP Whitelist | /etc/nftban/ui-whitelist.conf | 0644 | root | root | ⚠️ No (created by `nftban ui init`) |

**Note**: Config files marked with `config(noreplace)` in RPM and conffiles in DEB will NOT be overwritten on upgrade.

#### Runtime Directories

| Directory | Path | Permissions | Owner | Group | Created When? |
|-----------|------|-------------|-------|-------|--------------|
| Runtime Dir | /run/nftban-ui/ | 0755 | root | nftban | postinst |
| Socket | /run/nftban-ui/auth.sock | 0770 | root | nftban | systemd (socket activation) |

#### Log Directories

| Directory | Path | Permissions | Owner | Group | Created When? |
|-----------|------|-------------|-------|-------|--------------|
| Log Dir | /var/log/nftban/ | 0750 | nftban | nftban | Package install |

#### Data Directories

| Directory | Path | Permissions | Owner | Group | Purpose |
|-----------|------|-------------|-------|-------|---------|
| Web Files | /usr/share/nftban-ui/web/ | 0755 | root | root | Static HTML/CSS/JS |
| State Dir | /var/lib/nftban/ | 0755 | nftban | nftban | Runtime state (not created by package) |

---

## Removal Procedures Checklist

### 1. Service Shutdown

#### What Happens on Package Removal?

**RPM (%preun)**:
```bash
%systemd_preun nftban-ui.service
%systemd_preun nftban-ui-auth.socket
%systemd_preun nftban-ui-auth.service
```

**Translation**:
```bash
if [ $1 -eq 0 ]; then  # Only on removal, not upgrade
    systemctl stop nftban-ui.service >/dev/null 2>&1 || :
    systemctl stop nftban-ui-auth.socket >/dev/null 2>&1 || :
    systemctl stop nftban-ui-auth.service >/dev/null 2>&1 || :
    systemctl disable nftban-ui.service >/dev/null 2>&1 || :
    systemctl disable nftban-ui-auth.socket >/dev/null 2>&1 || :
    systemctl disable nftban-ui-auth.service >/dev/null 2>&1 || :
fi
```

**$1 = 0**: Complete removal
**$1 = 1**: Upgrade (don't stop services)

**DEB (prerm)**:
```bash
case "$1" in
    remove|deconfigure)
        deb-systemd-invoke stop nftban-ui.service >/dev/null || true
        deb-systemd-invoke stop nftban-ui-auth.socket >/dev/null || true
        deb-systemd-invoke stop nftban-ui-auth.service >/dev/null || true
        ;;
esac
```

**Status**: ✅ Both stop services before removal

---

### 2. File Cleanup

#### RPM: Files Removed Automatically

RPM automatically removes all files listed in `%files` section:
- ✅ `/usr/sbin/nftban-ui`
- ✅ `/usr/libexec/nftban-ui-auth`
- ✅ `/usr/lib/systemd/system/nftban-ui*.service`
- ✅ `/usr/lib/systemd/system/nftban-ui-auth.socket`
- ✅ `/usr/share/nftban-ui/`

#### RPM: Files NOT Removed (By Design)

**Config files marked with `config(noreplace)`**:
- ⚠️ `/etc/pam.d/nftban-ui` - **KEPT** (admin may have customized)
- ⚠️ `/etc/nftban/allowed-gui-groups` - **KEPT** (admin may have customized)

**Created at runtime (not in %files)**:
- ⚠️ `/etc/nftban/ui.conf` - **KEPT** (created by `nftban ui init`)
- ⚠️ `/etc/nftban/ui-whitelist.conf` - **KEPT** (contains admin's IPs)
- ⚠️ `/etc/nftban/ssl/` - **KEPT** (TLS certificates)
- ⚠️ `/var/log/nftban/*.log` - **KEPT** (audit trail)
- ⚠️ `/run/nftban-ui/` - **REMOVED** (tmpfs, disappears on reboot anyway)

#### RPM: %postun Cleanup

```bash
%systemd_postun_with_restart nftban-ui.service
%systemd_postun_with_restart nftban-ui-auth.socket
```

This runs `systemctl daemon-reload` to clean up systemd state.

---

#### DEB: Files Removed Automatically

DEB automatically removes all installed files except conffiles:
- ✅ `/usr/sbin/nftban-ui`
- ✅ `/usr/libexec/nftban-ui-auth`
- ✅ `/lib/systemd/system/nftban-ui*.service`
- ✅ `/lib/systemd/system/nftban-ui-auth.socket`
- ✅ `/usr/share/nftban-ui/`

#### DEB: Files NOT Removed on `apt remove`

**Configuration files (automatically preserved)**:
- ⚠️ `/etc/pam.d/nftban-ui` - **KEPT**
- ⚠️ `/etc/nftban/allowed-gui-groups` - **KEPT**

**Created at runtime**:
- ⚠️ `/etc/nftban/ui.conf` - **KEPT**
- ⚠️ `/etc/nftban/ui-whitelist.conf` - **KEPT**
- ⚠️ `/etc/nftban/ssl/` - **KEPT**
- ⚠️ `/var/log/nftban/*.log` - **KEPT**

#### DEB: Files Removed on `apt purge` (postrm with purge)

**Current DEB postrm**:
```bash
case "$1" in
    purge)
        rm -rf /etc/nftban/ui.conf
        rm -rf /etc/nftban/ui-whitelist.conf
        rm -rf /etc/nftban/ssl
        rm -rf /var/log/nftban/ui-*.log
        rm -rf /run/nftban-ui

        deb-systemd-helper purge nftban-ui.service >/dev/null || true
        deb-systemd-helper purge nftban-ui-auth.socket >/dev/null || true
        deb-systemd-helper purge nftban-ui-auth.service >/dev/null || true
        ;;
esac
```

**Status**: ✅ DEB purge removes runtime files

---

### 3. Users and Groups Cleanup

#### ⚠️ IMPORTANT: Users/Groups Are NOT Removed

**RPM**: No user/group cleanup in %postun
**DEB**: No user/group cleanup in postrm

**Why?**
1. **Security**: UIDs/GIDs might be reused, causing permission issues
2. **Data preservation**: User might own files outside package management
3. **Best practice**: System users are rarely removed

**Manual cleanup** (if needed after uninstall):
```bash
# WARNING: Only do this if you're sure!
userdel nftban
groupdel nftban
groupdel nftban-auditors
```

---

## Current Issues Found

### ❌ Issue 1: DEB postinst creates /run/nftban-ui on every install
**Problem**: /run is tmpfs, this directory should be created by systemd or the service itself
**Impact**: LOW - Directory will be recreated, but unnecessary

**Recommendation**: Remove from postinst, add to systemd service:
```ini
[Service]
RuntimeDirectory=nftban-ui
RuntimeDirectoryMode=0755
```

### ❌ Issue 2: Log directory ownership
**RPM**: Creates directory in %files, sets ownership in %post
**DEB**: Creates directory in rules, sets ownership in postinst

**Problem**: Race condition - directory might not exist when setting ownership

**Recommendation**: Consistent approach:
```bash
install -d -m 0750 -o nftban -g nftban /var/log/nftban
```

### ❌ Issue 3: RPM doesn't clean up generated configs on removal
**Current**: `/etc/nftban/ui.conf` and SSL certs left behind after `rpm -e`
**Expected**: Admin configs should be kept (correct behavior)
**Issue**: No warning to admin that configs remain

**Recommendation**: Add to %postun:
```bash
if [ $1 -eq 0 ]; then
    echo "Note: Configuration files in /etc/nftban/ and logs in /var/log/nftban/ were not removed"
fi
```

### ❌ Issue 4: DEB purge removes conffiles that might be shared
**Current**: `rm -rf /etc/nftban/ui.conf` in purge
**Problem**: If main nftban package also uses /etc/nftban/, this could break it

**Recommendation**: Only remove UI-specific files:
```bash
rm -f /etc/nftban/ui.conf
rm -f /etc/nftban/ui-whitelist.conf
rm -rf /etc/nftban/ssl/cert.pem
rm -rf /etc/nftban/ssl/key.pem
# Don't remove entire /etc/nftban/ directory!
```

---

## 🔒 Post-Installation Security Configuration

### GUI Port Access Control (CRITICAL)

After installing nftban-ui, you **MUST** configure nftables to restrict GUI port access (3940, 18443) to whitelisted IPs only.

#### Why This Is Critical

By default, the nftban_main chain has `policy accept`, which means:
- ✅ Whitelisted IPs: Full access (all ports)
- ⚠️ Other IPs: Can access GUI ports (SECURITY RISK)

The GUI should ONLY be accessible from whitelisted IPs.

#### Quick Fix (5 minutes)

```bash
# 1. Backup current ruleset
nft list ruleset > /root/nftables-backup-$(date +%Y%m%d-%H%M%S).nft

# 2. Change main chain policy to DROP
nft chain inet nftban_main input '{ policy drop ; }'

# 3. Add public service rules (SSH, HTTP, HTTPS)
nft add rule inet nftban_main input tcp dport 22 accept comment "SSH - public"
nft add rule inet nftban_main input tcp dport 80 accept comment "HTTP - public"
nft add rule inet nftban_main input tcp dport 443 accept comment "HTTPS - public"

# 4. Make persistent
nft list ruleset > /etc/nftables.conf
systemctl enable nftables
```

#### Result After Fix

```
Incoming connection to port 3940:

1. From whitelisted IP (e.g., 192.0.2.122):
   Priority 0: In whitelist_v4 → ACCEPT ✅
   Result: ✅ GUI accessible

2. From non-whitelisted IP (e.g., 1.2.3.4):
   Priority 0: Not in whitelist_v4 → Continue
               Not matching SSH/HTTP/HTTPS rules
               Hit policy: DROP ❌
   Result: ❌ GUI blocked (as intended)
```

#### Safety Checklist

**BEFORE changing policy to drop**:

- [ ] You are SSH'd from a whitelisted IP
- [ ] Whitelist contains your IP (`nft list set inet nftban_main whitelist_v4`)
- [ ] You have console/out-of-band access (in case of lockout)
- [ ] Backup created
- [ ] Public service rules added (SSH at minimum)

**If you get locked out**:
```bash
# Use console access
# Restore backup:
nft -f /root/nftables-backup-YYYYMMDD-HHMMSS.nft

# Or change policy back:
nft chain inet nftban_main input '{ policy accept ; }'
```

#### Verification

```bash
# Check policy
nft list chain inet nftban_main input | grep policy
# Expected: "policy drop"

# Check whitelist
nft list set inet nftban_main whitelist_v4
# Should contain your admin IP

# Test GUI access from whitelisted IP
curl -I https://your-server:3940/
# Expected: ✅ Connection succeeds

# Test from non-whitelisted IP (should fail)
# Expected: ❌ Connection timeout/refused
```

#### Alternative: Explicit GUI Port Blocking (Not Recommended)

If you cannot use `policy drop`, you can explicitly block GUI ports:

```bash
# Add AFTER whitelist rules
nft add rule inet nftban_main input tcp dport 3940 drop comment "GUI - whitelist only"
nft add rule inet nftban_main input tcp dport 18443 drop comment "GUI - whitelist only"
```

⚠️ **Warning**: This is less secure (default allow). Use `policy drop` whenever possible.

---

## Complete Installation/Removal Test Plan

### Fresh Install Test

**RPM (CentOS 9)**:
```bash
# Before install
id nftban  # Should fail
getent group nftban  # Should fail
systemctl list-units | grep nftban  # Should be empty

# Install
sudo rpm -ivh nftban-ui-0.5.0-1.el9.x86_64.rpm

# Verify
id nftban  # Should succeed
getent group nftban  # Should succeed
systemctl is-enabled nftban-ui-auth.socket  # Should be 'enabled'
systemctl is-active nftban-ui-auth.socket  # Should be 'active'
ls -la /usr/sbin/nftban-ui  # Should exist
ls -la /etc/pam.d/nftban-ui  # Should exist
ls -ld /var/log/nftban/  # Should exist, owned by nftban:nftban
ls -ld /run/nftban-ui/  # Should exist
```

**DEB (Debian)**:
```bash
# Before install
id nftban  # Should fail
getent group nftban  # Should fail
systemctl list-units | grep nftban  # Should be empty

# Install
sudo dpkg -i nftban-ui_0.5.0-1_amd64.deb

# Verify (same as RPM above)
```

### Upgrade Test

**RPM**:
```bash
# Install v0.5.0
sudo rpm -ivh nftban-ui-0.5.0-1.el9.x86_64.rpm

# Customize config
echo "CUSTOM=value" >> /etc/nftban/ui.conf

# Start service
sudo systemctl start nftban-ui.service

# Upgrade to v0.5.1 (hypothetical)
sudo rpm -Uvh nftban-ui-0.5.1-1.el9.x86_64.rpm

# Verify
grep "CUSTOM=value" /etc/nftban/ui.conf  # Should still exist
systemctl is-active nftban-ui.service  # Should be active (try-restart ran)
```

**DEB**:
```bash
# Same test as RPM but with dpkg
sudo dpkg -i nftban-ui_0.5.0-1_amd64.deb
echo "CUSTOM=value" >> /etc/nftban/ui.conf
sudo systemctl start nftban-ui.service
sudo dpkg -i nftban-ui_0.5.1-1_amd64.deb
grep "CUSTOM=value" /etc/nftban/ui.conf  # Should still exist
```

### Removal Test

**RPM (remove)**:
```bash
# Stop service first
sudo systemctl stop nftban-ui.service

# Remove package
sudo rpm -e nftban-ui

# Verify
ls /usr/sbin/nftban-ui  # Should NOT exist
systemctl list-unit-files | grep nftban  # Should be empty
ls /etc/pam.d/nftban-ui  # Should STILL EXIST (config preserved)
ls /etc/nftban/ui.conf  # Should STILL EXIST
id nftban  # Should STILL EXIST (user not removed)
```

**DEB (remove)**:
```bash
# Remove package
sudo apt remove nftban-ui

# Verify (same as RPM)
ls /usr/sbin/nftban-ui  # Should NOT exist
ls /etc/pam.d/nftban-ui  # Should STILL EXIST
```

**DEB (purge)**:
```bash
# Purge package
sudo apt purge nftban-ui

# Verify
ls /usr/sbin/nftban-ui  # Should NOT exist
ls /etc/pam.d/nftban-ui  # Should NOT exist
ls /etc/nftban/ui.conf  # Should NOT exist
ls /etc/nftban/ssl/  # Should NOT exist
ls /var/log/nftban/ui-*.log  # Should NOT exist
id nftban  # Should STILL EXIST (user not removed even on purge)
```

---

## Summary

### ✅ What Works Correctly

1. Users/groups created identically on both RPM and DEB
2. Services enabled and started on fresh install
3. Services gracefully restarted on upgrade (try-restart)
4. Binaries and systemd units removed on package removal
5. Config files preserved on upgrade (noreplace/conffiles)
6. Services stopped before removal

### ⚠️ What Needs Attention

1. **DEB postinst**: Remove manual /run/nftban-ui creation, use RuntimeDirectory in systemd
2. **Both**: Log directory ownership should be set atomically during install
3. **RPM %postun**: Add informational message about leftover configs
4. **DEB postrm purge**: Be more selective, don't remove shared /etc/nftban/ directory

### 📋 Missing Features (Optional Enhancements)

1. **Backup on removal**: Optionally tar up /etc/nftban/ before purge
2. **Migration helper**: Script to migrate from old package if detected
3. **Health check**: Post-install verification script
4. **Rollback**: Keep previous package version for easy downgrade

---

**Last Updated**: 2025-11-16
**Verified By**: Claude Code Assistant
**Version**: v0.5.1
