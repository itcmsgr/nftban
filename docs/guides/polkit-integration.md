# NFTBan Polkit Integration Guide

**Purpose:** Grant nftban-cli group members permission to manage fail2ban and nftables services without sudo
**Security:** Group-based authorization, no sudoers, no setuid binaries

---

## Overview

NFTBan uses **Polkit** (PolicyKit) to allow members of the `nftban-cli` group to manage specific systemd services through the `nftban` CLI without requiring root access or sudo permissions.

### What This Enables

Users in the `nftban-cli` group can run commands like:

```bash
# As a regular user (e.g., antonis)
nftban start nftables
nftban stop fail2ban
nftban restart nftables
nftban enable fail2ban
nftban disable fail2ban
nftban status nftables
```

Or directly with systemctl:

```bash
systemctl start nftables
systemctl stop fail2ban
systemctl restart nftables
systemctl enable fail2ban
```

### What This Does NOT Grant

- **NO root shell access**
- **NO access to other services** (e.g., cannot manage sshd, httpd, etc.)
- **NO file write permissions** to system directories (root still owns code/config)
- **NO ability to modify Polkit rules themselves**

---

## Architecture

### Permission Model

```
┌─────────────────────────────────────────────────────────────┐
│  TWO SEPARATE CONCERNS:                                      │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  1. FILE PERMISSIONS (Unix DAC)                               │
│     - /usr/lib/nftban → root:root (code)                      │
│     - /etc/nftban → root:nftban-cli (config, read-only)       │
│     - /var/lib/nftban → nftban:nftban (runtime data)          │
│                                                               │
│  2. SERVICE MANAGEMENT (Polkit)                               │
│     - Members of nftban-cli group                             │
│     - Can manage ONLY: nftables.service, fail2ban.service    │
│     - Via systemctl (no sudo)                                │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

### How It Works

1. User `antonis` is added to `nftban-cli` group
2. User runs: `nftban start nftables`
3. NFTBan CLI calls: `systemctl start nftables.service`
4. systemd asks Polkit: "Can user `antonis` start nftables.service?"
5. Polkit checks `/usr/share/polkit-1/rules.d/60-nftban-cli.rules`
6. Rule says: "YES, if user is in nftban-cli group AND unit is nftables.service"
7. systemd proceeds with start operation

---

## Installation

### Automatic (via Package Manager)

The Polkit rule is automatically installed when you install the nftban package:

**RPM-based (Rocky, AlmaLinux, Fedora):**
```bash
sudo dnf install nftban
# Polkit rule installed to: /usr/share/polkit-1/rules.d/60-nftban-cli.rules
```

**DEB-based (Debian, Ubuntu):**
```bash
sudo apt install nftban
# Polkit rule installed to: /usr/share/polkit-1/rules.d/60-nftban-cli.rules
```

### Manual Installation

If installing from source:

```bash
# Install Polkit rule
sudo install -m 0644 -D \
  packaging/polkit-1/rules.d/60-nftban-cli.rules \
  /usr/share/polkit-1/rules.d/60-nftban-cli.rules

# Reload Polkit (usually automatic, but can force)
sudo systemctl restart polkit
```

---

## Usage

### Adding Users to nftban-cli Group

```bash
# Add user antonis to nftban-cli group
sudo usermod -aG nftban-cli antonis

# Verify membership
id antonis
# Should show: groups=...,nftban-cli,...

# User must re-login for group to take effect
# Or use: newgrp nftban-cli
```

### Available Commands

Once in the `nftban-cli` group, users can:

**Via NFTBan CLI:**
```bash
# Manage nftables
nftban nftables start
nftban nftables stop
nftban nftables restart
nftban nftables enable
nftban nftables disable
nftban nftables status

# Manage fail2ban
nftban fail2ban start
nftban fail2ban stop
nftban fail2ban restart
```

**Direct systemctl:**
```bash
systemctl start nftables
systemctl stop fail2ban
systemctl restart nftables.service
systemctl enable fail2ban.service
systemctl disable fail2ban.service
systemctl status nftables
```

---

## Testing

### Test 1: Group Membership

```bash
# Check if user is in nftban-cli group
id $(whoami) | grep nftban-cli
# Expected: Should show nftban-cli in groups
```

### Test 2: Service Management (Allowed)

```bash
# As regular user (no sudo)
systemctl status nftables
systemctl restart nftables
systemctl restart fail2ban

# Expected: All should succeed without asking for password
```

### Test 3: Scope Check (Denied)

```bash
# Try to manage a service NOT in the allowlist
systemctl restart sshd

# Expected: Permission denied
# ==== AUTHENTICATION FAILED ====
# Failed to restart sshd.service: Access denied
```

### Test 4: NFTBan CLI

```bash
# As regular user (member of nftban-cli)
nftban start nftables
nftban stop fail2ban
nftban enable nftables

# Expected: All should succeed
```

---

## Polkit Rule Details

### Rule Location

```
/usr/share/polkit-1/rules.d/60-nftban-cli.rules
```

### Allowed Units

The Polkit rule grants permission for **ONLY** these units:

- `nftables.service`
- `fail2ban.service`

### Allowed Actions

Group members can perform:

- **manage-units**: start, stop, restart, kill, reload
- **manage-unit-files**: enable, disable, preset
- **reload-daemon**: reload systemd configuration

---

## Troubleshooting

### Permission Denied

**Problem:**
```bash
$ systemctl restart nftables
==== AUTHENTICATION FAILED ====
```

**Solutions:**

1. **Check group membership:**
   ```bash
   id | grep nftban-cli
   ```
   If not shown, add user to group:
   ```bash
   sudo usermod -aG nftban-cli $(whoami)
   ```

2. **Re-login for group to take effect:**
   ```bash
   # Log out and log back in
   # OR use:
   newgrp nftban-cli
   ```

3. **Verify Polkit rule exists:**
   ```bash
   ls -la /usr/share/polkit-1/rules.d/60-nftban-cli.rules
   # Should exist with mode 644
   ```

4. **Check Polkit is running:**
   ```bash
   systemctl status polkit
   # Should be active (running)
   ```

### Rule Not Loading

**Check Polkit syntax:**
```bash
# View Polkit logs
journalctl -u polkit -n 50

# Restart Polkit
sudo systemctl restart polkit
```

**Verify rule syntax:**
```bash
# The rule file should be valid JavaScript
# Check for syntax errors in:
cat /usr/share/polkit-1/rules.d/60-nftban-cli.rules
```

### Still Asking for Password

**Check systemd Polkit integration:**
```bash
# Test Polkit action directly
pkaction --action-id org.freedesktop.systemd1.manage-units --verbose

# Check if user is authorized
pkcheck --action-id org.freedesktop.systemd1.manage-units \
        --process $$ --detail unit=nftables.service
```

---

## Security Considerations

### Why This Is Safe

1. **Scoped Authorization**
   - Only specific units (nftables, fail2ban)
   - Cannot manage other services (sshd, httpd, etc.)
   - Cannot escalate to full root

2. **File Permissions Unchanged**
   - root still owns `/usr/lib/nftban` (code)
   - root still owns `/etc/nftban` (config)
   - Group membership only grants service management

3. **No Sudo, No Setuid**
   - No sudoers entries
   - No setuid binaries
   - Standard Polkit authorization via D-Bus

4. **Audit Trail**
   - All actions logged by systemd journal
   - Polkit logs authorization decisions

5. **Group-Based**
   - Explicit group membership required
   - Easy to audit: `getent group nftban-cli`
   - Easy to revoke: `gpasswd -d user nftban-cli`

### Attack Prevention

**Scenario:** Attacker compromises user in nftban-cli group

**What attacker CANNOT do:**
- ❌ Modify `/usr/lib/nftban` code (owned by root:root)
- ❌ Modify `/etc/nftban` config (owned by root:nftban-cli, read-only)
- ❌ Manage other services (sshd, httpd, etc.)
- ❌ Gain root shell
- ❌ Modify Polkit rules (requires root)

**What attacker CAN do:**
- ✅ Stop/start nftables (but systemd logs it)
- ✅ Stop/start fail2ban (but systemd logs it)

**Mitigation:**
- Monitor systemd journal for unexpected service changes
- Review `nftban-cli` group membership regularly

---

## Extending the Rule

To allow management of additional units, edit the Polkit rule:

```javascript
// Add more units to the allowlist
const allowedUnits = new Set([
  "nftables.service",
  "fail2ban.service",
  "nginx.service",      // Add this
  "postgresql.service"  // Add this
]);
```

Then reload Polkit:
```bash
sudo systemctl restart polkit
```

---

## Removing Access

### Remove User from Group

```bash
# Remove user antonis from nftban-cli group
sudo gpasswd -d antonis nftban-cli

# Verify
id antonis
# Should NOT show nftban-cli
```

### Disable Polkit Rule Entirely

```bash
# Remove the rule file
sudo rm /usr/share/polkit-1/rules.d/60-nftban-cli.rules

# Reload Polkit
sudo systemctl restart polkit
```

After removal, only root can manage nftables/fail2ban services.

---

## References

- **Polkit Documentation:** https://www.freedesktop.org/software/polkit/docs/latest/
- **systemd-polkit Integration:** `man polkit`
- **NFTBan Permission Architecture:** `docs/architecture/permission-architecture.md`
- **NFTBan Security Model:** See `/tmp/PERMISSION_ARCHITECTURE.md`

---

**Status:** ✅ Production Ready
**Security:** Reviewed and approved
**Maintenance:** No manual intervention required after installation
