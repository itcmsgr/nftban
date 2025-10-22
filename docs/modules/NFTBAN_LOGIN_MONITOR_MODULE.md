# NFTBan Login Monitor Module

**Module:** `nftban_login_monitor_module.sh` | **Version:** 0.9.3-dev | **Location:** `/usr/local/lib/nftban/`

## Overview

The Login Monitor Module provides automated login event monitoring and email alerting via systemd timer integration. It tracks root logins, sudo usage, and SSH login attempts, sending real-time notifications to administrators.

### Key Features

- **systemd Timer Integration**: Automated monitoring every minute
- **3 Event Types**: Root login alerts, sudo alerts, SSH login alerts
- **Email Notifications**: Real-time alerts via configured email
- **Test Mode**: Send test emails to verify configuration
- **Service Management**: Install, enable, start, stop, status commands
- **Low Overhead**: Runs every minute with minimal resource usage

### Dependencies

- **systemd**: For timer and service management
- **Core Module**: For email functionality (`nftban_send_email`)
- **System logs**: `/var/log/auth.log` or `/var/log/secure`

---

## API Reference

### Service Management

**`nftban_login_monitor_install()`** - Install systemd service
```bash
nftban login install

# Installing login monitor service...
# Login monitor service installed
#
# Service files created:
#   - /etc/systemd/system/nftban-login-monitor.service
#   - /etc/systemd/system/nftban-login-monitor.timer
#
# Next steps:
#   1. Configure: edit /etc/nftban/config/nftban.conf.local
#   2. Test: nftban login test
#   3. Enable: nftban login enable
#   4. Start: nftban login start
```
- **Creates**: Service and timer files
- **Reloads**: systemd daemon

**`nftban_login_monitor_uninstall()`** - Remove systemd service
```bash
nftban login uninstall

# Uninstalling login monitor service...
# Login monitor service uninstalled
```
- **Stops and disables**: Timer before removal
- **Removes**: Service and timer files

**`nftban_login_monitor_enable()`** - Enable service (auto-start on boot)
```bash
nftban login enable

# Login monitor enabled (will start on boot)
```

**`nftban_login_monitor_disable()`** - Disable service
```bash
nftban login disable

# Login monitor disabled
```

**`nftban_login_monitor_start()`** - Start timer
```bash
nftban login start

# Login monitor started
```

**`nftban_login_monitor_stop()`** - Stop timer
```bash
nftban login stop

# Login monitor stopped
```

**`nftban_login_monitor_restart()`** - Restart timer
```bash
nftban login restart

# Login monitor restarted
```

### Status & Configuration

**`nftban_login_monitor_status()`** - Show service status
```bash
nftban login status

# ═══════════════════════════════════════════════════════════
#   Login Monitor Status
# ═══════════════════════════════════════════════════════════
#
# Configuration:
#   Monitoring: true
#   Root login alerts: true
#   Sudo alerts: false
#   SSH alerts: true
#   Email recipient: admin@example.com
#
# Service Status:
#   ✓ Service installed
#   ● RUNNING
#   Boot: ENABLED
#
# Recent Alerts (last 10):
#   [2025-10-23 14:30:15] Root login detected from 192.168.1.100
#   [2025-10-23 14:25:03] SSH login attempt from 203.0.113.45 (failed)
```

**`nftban_login_monitor_test_config()`** - Test configuration and send test email
```bash
nftban login test

# Testing login monitor configuration...
#
# ✓ Configuration valid
#
# Send test email? (y/N): y
# Sending test email to admin@example.com...
# Test email sent successfully to admin@example.com
#
# ✓ Check your inbox at: admin@example.com
#   (Check spam folder if not received within a few minutes)
```
- **Validates**: Configuration settings
- **Optional**: Send test email to verify email delivery

### Monitoring Execution

**`nftban_login_monitor_run()`** - Run monitoring cycle (called by systemd)
```bash
# Executed automatically by systemd timer every minute
# Can also be run manually for testing:
nftban login run

# [2025-10-23 14:30:15] Monitor cycle completed
```

---

## Configuration

**Global Settings** (`/etc/nftban/config/nftban.conf.local`):

```bash
# Enable/disable login monitoring
NFTBAN_F2B_LOGIN_MONITOR="true"

# Enable root login alerts
NFTBAN_F2B_ROOT_LOGIN_ALERT="true"

# Enable sudo usage alerts
NFTBAN_F2B_SUDO_ALERT="false"

# Enable SSH login attempt alerts
NFTBAN_F2B_SSH_LOGIN_ALERT="true"

# Email recipient for alerts
NFTBAN_F2B_RECIPIENT="admin@example.com"
```

**Service File** (`/etc/systemd/system/nftban-login-monitor.service`):
```ini
[Unit]
Description=nftban Login Monitor Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nftban login run
StandardOutput=journal
StandardError=journal
User=root

[Install]
WantedBy=multi-user.target
```

**Timer File** (`/etc/systemd/system/nftban-login-monitor.timer`):
```ini
[Unit]
Description=nftban Login Monitor Timer
Requires=nftban-login-monitor.service

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=1s

[Install]
WantedBy=timers.target
```
- **OnBootSec**: Starts 1 minute after boot
- **OnUnitActiveSec**: Runs every 1 minute
- **AccuracySec**: 1-second precision

**Log Files**:
```
/var/log/nftban/login-monitor.log     # Monitor activity log
/var/log/nftban/login-alerts.log      # Alert history
```

**State Directory**:
```
/var/cache/nftban/login-monitor/      # State files (last check timestamps)
```

---

## CLI Integration

```bash
# Install service
nftban login install

# Test configuration
nftban login test

# Enable and start
nftban login enable
nftban login start

# Check status
nftban login status

# Stop and disable
nftban login stop
nftban login disable

# Uninstall
nftban login uninstall

# Manual run (for testing)
nftban login run
```

---

## Email Alert Examples

### Root Login Alert

```
Subject: [nftban] ALERT: Root login detected on server.example.com

nftban Login Monitor - Root Login Alert

A root login has been detected on your server:

Event Details:
- Type: Root login
- Server: server.example.com
- Source IP: 192.168.1.100
- Timestamp: 2025-10-23 14:30:15
- User: root
- Method: SSH

System Information:
- Hostname: server.example.com
- Date: 2025-10-23 14:30:15

Security Recommendation:
- Verify this login was authorized
- Consider disabling root SSH login (PermitRootLogin no)
- Use sudo with individual user accounts

---
This is an automated message from nftban login monitor
https://itcms.gr
```

### SSH Login Attempt Alert

```
Subject: [nftban] ALERT: SSH login attempt from 203.0.113.45

nftban Login Monitor - SSH Login Attempt

An SSH login attempt has been detected:

Event Details:
- Type: SSH login attempt
- Server: server.example.com
- Source IP: 203.0.113.45
- Timestamp: 2025-10-23 14:25:03
- User: admin
- Result: Failed (invalid password)

This IP has attempted login 5 times in the last hour.

Recommended Actions:
- Review /var/log/auth.log for details
- Consider banning IP: nftban blacklist ban 203.0.113.45
- Enable Fail2Ban for automatic blocking

---
This is an automated message from nftban login monitor
https://itcms.gr
```

---

## Testing

### Test 1: Service Installation

```bash
# Install service
nftban login install

# Verify service files created
ls -l /etc/systemd/system/nftban-login-monitor.*
# -rw-r--r-- 1 root root ... nftban-login-monitor.service
# -rw-r--r-- 1 root root ... nftban-login-monitor.timer

# Check systemd recognizes service
systemctl status nftban-login-monitor.service
systemctl status nftban-login-monitor.timer
```

### Test 2: Configuration Validation

```bash
# Configure email recipient
echo 'NFTBAN_F2B_RECIPIENT="admin@example.com"' >> /etc/nftban/config/nftban.conf.local
echo 'NFTBAN_F2B_LOGIN_MONITOR="true"' >> /etc/nftban/config/nftban.conf.local

# Test configuration
nftban login test

# Should show:
# ✓ Configuration valid
# Send test email? (y/N):
```

### Test 3: Timer Execution

```bash
# Enable and start timer
nftban login enable
nftban login start

# Check timer is active
systemctl status nftban-login-monitor.timer
# ● nftban-login-monitor.timer - nftban Login Monitor Timer
#    Loaded: loaded
#    Active: active (waiting)
#    Trigger: ... (next run time)

# Check next run time
systemctl list-timers nftban-login-monitor.timer
# NEXT                         LEFT       LAST  PASSED  UNIT
# Wed 2025-10-23 14:31:00 UTC  45s left   -     -       nftban-login-monitor.timer

# Wait for execution, then check logs
journalctl -u nftban-login-monitor.service -n 20
```

### Test 4: Manual Run

```bash
# Run monitor manually
nftban login run

# Check logs
tail -20 /var/log/nftban/login-monitor.log
# [2025-10-23 14:30:15] Monitor cycle completed
```

---

## systemd Journal Monitoring

```bash
# View all login monitor logs
journalctl -u nftban-login-monitor.service

# Follow logs in real-time
journalctl -u nftban-login-monitor.service -f

# Show logs from last hour
journalctl -u nftban-login-monitor.service --since "1 hour ago"

# Show timer trigger times
journalctl -u nftban-login-monitor.timer
```

---

## Troubleshooting

### Issue 1: Service Not Running

**Symptoms**: Timer shows "inactive (dead)"

**Solutions**:
```bash
# Check if service installed
ls -l /etc/systemd/system/nftban-login-monitor.*

# Reinstall if missing
nftban login install

# Reload systemd
systemctl daemon-reload

# Start timer
systemctl start nftban-login-monitor.timer

# Check status
systemctl status nftban-login-monitor.timer
```

### Issue 2: No Email Alerts

**Symptoms**: Monitoring runs but no emails received

**Solutions**:
```bash
# Verify email configuration
grep NFTBAN_F2B_RECIPIENT /etc/nftban/config/nftban.conf.local

# Test email manually
echo "test" | mail -s "Test" admin@example.com

# Check email logs
tail -50 /var/log/nftban/email.log

# Test nftban email function
nftban_send_email "admin@example.com" "Test Subject" "Test Body" "normal"
```

### Issue 3: Timer Not Triggering

**Symptoms**: Timer enabled but not executing

**Solutions**:
```bash
# Check timer status
systemctl list-timers nftban-login-monitor.timer

# Verify timer file syntax
systemctl cat nftban-login-monitor.timer

# Check for errors
systemctl status nftban-login-monitor.timer

# Restart timer
systemctl restart nftban-login-monitor.timer
```

### Issue 4: Configuration Not Applied

**Symptoms**: Changes to config file not taking effect

**Solutions**:
```bash
# Reload systemd after config changes
systemctl daemon-reload

# Restart timer
systemctl restart nftban-login-monitor.timer

# Verify config loaded
nftban login status
```

---

## Integration with Other Modules

### With Fail2Ban Module

Login monitor complements Fail2Ban by providing:
- **Real-time alerts**: Before Fail2Ban bans occur
- **Root login detection**: Tracks privileged access
- **Sudo monitoring**: Tracks privilege escalation

### With Blacklist Module

Use together for proactive security:
```bash
# Receive SSH alert from login monitor
# Subject: SSH login attempt from 203.0.113.45 (5 attempts)

# Manually ban persistent attacker
nftban blacklist ban 203.0.113.45 "Persistent SSH attacks (login monitor)"
```

---

## Best Practices

1. **Enable Root Login Alerts**:
   ```bash
   echo 'NFTBAN_F2B_ROOT_LOGIN_ALERT="true"' >> /etc/nftban/config/nftban.conf.local
   ```

2. **Use with SSH Key Authentication**:
   ```bash
   # Disable password auth in /etc/ssh/sshd_config:
   # PasswordAuthentication no

   # Monitor for unauthorized key-based logins
   echo 'NFTBAN_F2B_SSH_LOGIN_ALERT="true"' >> /etc/nftban/config/nftban.conf.local
   ```

3. **Test Email Delivery**:
   ```bash
   # Before relying on alerts, verify email works
   nftban login test
   # Send test email: y
   ```

4. **Monitor Timer Health**:
   ```bash
   # Weekly check that timer is running
   systemctl status nftban-login-monitor.timer
   ```

5. **Review Alert Logs**:
   ```bash
   # Check for patterns in login attempts
   tail -100 /var/log/nftban/login-alerts.log
   ```

---

## License

**NFTBAN Custom License v3.0**
SPDX-License-Identifier: NFTBAN-Custom-License

© 2025 Antonios Voulvoulis – ITCMS. All rights reserved.

**Summary:**
- ✅ Free to use for any purpose (personal, commercial, production)
- ✅ Free to modify privately
- ✅ Free to deploy unlimited instances
- ❌ NO redistribution, republication, or resale
- ❌ NO public GitHub forks or package uploads

Full license: https://github.com/itcmsgr/nftban/blob/main/LICENSE.md

---

**Made by ITCMS** | https://itcms.gr
Empowering system administrators with simple, powerful security tools.
