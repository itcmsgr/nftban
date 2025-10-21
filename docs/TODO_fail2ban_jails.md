# TODO: Fail2ban Jails Configuration

**Priority:** Medium
**Target Version:** v0.9.2
**Complexity:** Low
**Estimated Time:** 2-3 hours

---

## Issue

Currently nftban installs fail2ban service but **does not create jail configurations**. This means fail2ban is running but not actually monitoring anything.

### Current Status
- ✅ fail2ban service installed and active
- ✅ nftban integrates with fail2ban for IP banning
- ❌ No jail configurations created
- ❌ No log monitoring active
- ❌ No automatic ban actions from fail2ban

### Impact
- fail2ban is running but idle
- No automatic protection from brute force attacks
- Manual IP banning only (via nftban CLI)
- SSH/HTTP/other services not monitored

---

## Proposed Solution

Create default jail configurations for common services during nftban installation.

### Jails to Include

#### 1. SSH Protection (Priority: High)
**File:** `/etc/fail2ban/jail.d/nftban-sshd.conf`

```ini
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
           /var/log/secure
maxretry = 3
findtime = 600
bantime = 3600
action = nftban-ban
```

#### 2. HTTP/HTTPS Protection (Priority: Medium)
**File:** `/etc/fail2ban/jail.d/nftban-http.conf`

```ini
[http-auth]
enabled = true
port = http,https
filter = apache-auth
logpath = /var/log/apache*/*error.log
           /var/log/httpd/*error.log
           /var/log/nginx/*error.log
maxretry = 5
findtime = 600
bantime = 3600
action = nftban-ban

[http-404]
enabled = true
port = http,https
filter = apache-404
logpath = /var/log/apache*/*access.log
           /var/log/httpd/*access.log
           /var/log/nginx/*access.log
maxretry = 20
findtime = 120
bantime = 1800
action = nftban-ban
```

#### 3. Control Panel Protection (Priority: Medium)
**File:** `/etc/fail2ban/jail.d/nftban-panels.conf`

```ini
[directadmin]
enabled = true
port = 2222
filter = directadmin
logpath = /var/log/directadmin/error.log
maxretry = 3
findtime = 600
bantime = 3600
action = nftban-ban

[cpanel]
enabled = false
port = 2083,2087
filter = cpanel
logpath = /usr/local/cpanel/logs/login_log
maxretry = 3
findtime = 600
bantime = 3600
action = nftban-ban

[plesk]
enabled = false
port = 8443
filter = plesk
logpath = /var/log/plesk/panel.log
maxretry = 3
findtime = 600
bantime = 3600
action = nftban-ban
```

#### 4. Mail Server Protection (Priority: Low)
**File:** `/etc/fail2ban/jail.d/nftban-mail.conf`

```ini
[postfix-auth]
enabled = true
port = smtp,submission,smtps
filter = postfix-auth
logpath = /var/log/mail.log
           /var/log/maillog
maxretry = 3
findtime = 600
bantime = 3600
action = nftban-ban

[dovecot]
enabled = true
port = pop3,pop3s,imap,imaps
filter = dovecot
logpath = /var/log/mail.log
           /var/log/maillog
maxretry = 3
findtime = 600
bantime = 3600
action = nftban-ban
```

#### 5. FTP Protection (Priority: Low)
**File:** `/etc/fail2ban/jail.d/nftban-ftp.conf`

```ini
[proftpd]
enabled = true
port = ftp,ftps
filter = proftpd
logpath = /var/log/proftpd/proftpd.log
maxretry = 3
findtime = 600
bantime = 3600
action = nftban-ban

[vsftpd]
enabled = false
port = ftp,ftps
filter = vsftpd
logpath = /var/log/vsftpd.log
maxretry = 3
findtime = 600
bantime = 3600
action = nftban-ban
```

---

## Custom Action Configuration

### nftban-ban Action
**File:** `/etc/fail2ban/action.d/nftban-ban.conf`

```ini
[Definition]
actionstart =
actionstop =
actioncheck =
actionban = /usr/local/bin/nftban ban add <ip> 3600 "Fail2ban: <name>"
actionunban = /usr/local/bin/nftban ban remove <ip>

[Init]
name = default
```

---

## Implementation Plan

### Phase 1: Create Action Configuration
1. Create `/etc/fail2ban/action.d/nftban-ban.conf`
2. Test action manually
3. Verify nftban CLI integration

### Phase 2: Create Jail Configurations
1. Create jail files in `/etc/fail2ban/jail.d/`
2. Enable only essential jails by default (SSH)
3. Include optional jails (disabled by default)

### Phase 3: Auto-Detection
1. Detect installed services during nftban init
2. Auto-enable relevant jails based on detection
3. Example: If DirectAdmin detected, enable directadmin jail

### Phase 4: CLI Integration
1. Add `nftban fail2ban` command group
2. Commands:
   - `nftban fail2ban status` - Show jail status
   - `nftban fail2ban enable <jail>` - Enable jail
   - `nftban fail2ban disable <jail>` - Disable jail
   - `nftban fail2ban list` - List all jails
   - `nftban fail2ban banned` - Show banned IPs

### Phase 5: Testing
1. Test on all 3 lab servers
2. Verify bans are added to nftban
3. Verify unbans work correctly
4. Test with actual failed login attempts

---

## Configuration Options

### User-Configurable Settings
**File:** `/etc/nftban/config/fail2ban.conf.local`

```bash
# Fail2ban Integration Settings

# Enable/disable fail2ban integration
F2B_INTEGRATION_ENABLED=1

# Default ban time (seconds)
F2B_DEFAULT_BANTIME=3600

# Default max retries
F2B_DEFAULT_MAXRETRY=3

# Default find time (seconds)
F2B_DEFAULT_FINDTIME=600

# Auto-enable jails based on detected services
F2B_AUTO_ENABLE=1

# Specific jail enablement
F2B_ENABLE_SSHD=1
F2B_ENABLE_HTTP=1
F2B_ENABLE_MAIL=0
F2B_ENABLE_FTP=0
F2B_ENABLE_PANELS=1

# Email notifications for bans
F2B_EMAIL_ALERTS=1
F2B_EMAIL_RECIPIENT=""  # Uses NFTBAN_EMAIL_RECIPIENT if empty
```

---

## Testing Checklist

- [ ] Create nftban-ban action
- [ ] Test action manually
- [ ] Create SSH jail
- [ ] Test SSH jail with failed logins
- [ ] Verify IP appears in nftban ban list
- [ ] Verify IP is blocked by nftables
- [ ] Test unban functionality
- [ ] Create HTTP jails
- [ ] Create panel jails
- [ ] Test auto-detection
- [ ] Test CLI commands
- [ ] Test on CentOS 9
- [ ] Test on Ubuntu 24.04
- [ ] Test on CentOS 10
- [ ] Verify email notifications
- [ ] Documentation complete

---

## Files to Create

1. `/etc/fail2ban/action.d/nftban-ban.conf` - Custom action
2. `/etc/fail2ban/jail.d/nftban-sshd.conf` - SSH protection
3. `/etc/fail2ban/jail.d/nftban-http.conf` - HTTP protection
4. `/etc/fail2ban/jail.d/nftban-panels.conf` - Panel protection
5. `/etc/fail2ban/jail.d/nftban-mail.conf` - Mail protection
6. `/etc/fail2ban/jail.d/nftban-ftp.conf` - FTP protection
7. `/etc/nftban/config/fail2ban.conf` - Default config
8. `/etc/nftban/lib/nftban_fail2ban_setup.sh` - Setup script
9. `docs/FAIL2BAN_INTEGRATION.md` - Documentation

---

## Documentation Needed

### User Documentation
- How to enable/disable jails
- How to customize ban times
- How to view fail2ban status
- How to whitelist IPs from fail2ban
- Troubleshooting guide

### Developer Documentation
- Action configuration format
- Jail configuration format
- Integration with nftban CLI
- Testing procedures

---

## Benefits

✅ **Automatic Protection**
- SSH brute force protection
- HTTP attack protection
- Panel login protection

✅ **Unified Management**
- Single interface (nftban CLI)
- Centralized ban management
- Integrated with existing whitelist/blacklist

✅ **Better User Experience**
- Works out of the box
- Auto-detects services
- Sensible defaults

✅ **Complete Solution**
- Manual bans (nftban CLI)
- Automatic bans (fail2ban)
- Both integrated seamlessly

---

## Current Workaround

Until this is implemented, users can manually create fail2ban jails:

```bash
# Create SSH jail manually
cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
maxretry = 3
bantime = 3600
EOF

systemctl restart fail2ban
```

---

**Status:** Planned for v0.9.2
**Assigned To:** TBD
**Dependencies:** None (standalone feature)
**Blocked By:** None
