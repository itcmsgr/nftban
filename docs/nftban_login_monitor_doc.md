# NFTBan Login Monitor Module

**File:** `lib/nftban_login_monitor_module.sh`  
**Version:** 1.0.0  
**Author:** ITCMS Team (Antonios Voulvoulis)  
**Purpose:** Login event monitoring and alerting via systemd timer

---

## Overview

The Login Monitor Module provides automated monitoring and alerting for security-relevant login events including root logins, sudo command executions, SSH authentication attempts, and other authentication events. It runs as a systemd timer service for continuous monitoring.

This module is designed to complement Fail2ban by providing proactive alerting for successful authentication events that may indicate security concerns. While Fail2ban focuses on failed attempts, this module tracks successful events that warrant administrator attention.

Key features include systemd timer integration (runs every minute), email alerting for suspicious events, configurable monitoring levels (root login, sudo, SSH), real-time event detection from system logs, alert deduplication to prevent spam, and comprehensive status reporting.

**Note:** Version 1.0.0 provides the infrastructure and service management. Full monitoring logic implementation is planned for future versions.

---

## Key Functions

### Public Functions (Exported)

| Function | Purpose | Parameters | Returns |
|----------|---------|------------|---------|
| `nftban_login_monitor_install()` | Install systemd service and timer | None | 0 on success |
| `nftban_login_monitor_uninstall()` | Remove systemd service and timer | None | 0 on success |
| `nftban_login_monitor_enable()` | Enable service at boot | None | 0 on success |
| `nftban_login_monitor_disable()` | Disable service at boot | None | 0 on success |
| `nftban_login_monitor_start()` | Start monitoring service | None | 0 on success |
| `nftban_login_monitor_stop()` | Stop monitoring service | None | 0 on success |
| `nftban_login_monitor_restart()` | Restart monitoring service | None | 0 on success |
| `nftban_login_monitor_status()` | Show comprehensive status | None | Display status report |
| `nftban_login_monitor_test_config()` | Test configuration and email | None | 0 if valid, 1 if errors |
| `nftban_login_monitor_run()` | Run monitoring cycle | None | Called by systemd timer |

---

## Configuration Variables

### Module Constants

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_LOGIN_MONITOR_LOG` | `${NFTBAN_LOG_DIR}/login-monitor.log` | Monitor activity log |
| `NFTBAN_LOGIN_ALERT_LOG` | `${NFTBAN_LOG_DIR}/login-alerts.log` | Alert event log |
| `NFTBAN_LOGIN_STATE_DIR` | `${NFTBAN_CACHE_DIR}/login-monitor` | State tracking directory |
| `NFTBAN_LOGIN_SERVICE_FILE` | `/etc/systemd/system/nftban-login-monitor.service` | Systemd service unit |
| `NFTBAN_LOGIN_TIMER_FILE` | `/etc/systemd/system/nftban-login-monitor.timer` | Systemd timer unit |

### User-Configurable (in nftban.conf.local)

| Variable | Default | Description |
|----------|---------|-------------|
| `NFTBAN_F2B_LOGIN_MONITOR` | `false` | Enable/disable login monitoring |
| `NFTBAN_F2B_ROOT_LOGIN_ALERT` | `false` | Alert on root logins |
| `NFTBAN_F2B_SUDO_ALERT` | `false` | Alert on sudo command execution |
| `NFTBAN_F2B_SSH_LOGIN_ALERT` | `false` | Alert on SSH logins |
| `NFTBAN_F2B_RECIPIENT` | `""` | Email recipient for alerts |

---

## Dependencies

**Required:**
- `systemd` - Timer and service management (required)
- `systemctl` - Service control commands (required)

**Optional:**
- Email system (sendmail/mail) - For alert notifications
- `journalctl` - For log reading (future implementation)

**Related Modules:**
- `nftban_core.sh` - Core logging and configuration
- Email module (future) - For sending alerts

---

## Usage Examples

### Example 1: Complete Setup (First-Time Installation)
```bash
# Step 1: Install service
nftban login install

# Expected output:
# [INFO] Installing login monitor service...
# [SUCCESS] Login monitor service installed
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

# Step 2: Configure monitoring
sudo nano /etc/nftban/config/nftban.conf.local

# Add/modify:
# NFTBAN_F2B_LOGIN_MONITOR="true"
# NFTBAN_F2B_ROOT_LOGIN_ALERT="true"
# NFTBAN_F2B_SUDO_ALERT="true"
# NFTBAN_F2B_SSH_LOGIN_ALERT="true"
# NFTBAN_F2B_RECIPIENT="admin@example.com"

# Step 3: Test configuration
nftban login test

# Expected output:
# Testing login monitor configuration...
#
# [SUCCESS] Configuration valid
#
# Send test email? (y/N):

# Step 4: Enable at boot
nftban login enable

# Expected output:
# [SUCCESS] Login monitor enabled (will start on boot)

# Step 5: Start service
nftban login start

# Expected output:
# [SUCCESS] Login monitor started

# Step 6: Verify status
nftban login status
```

### Example 2: Check Status
```bash
nftban login status

# Expected output:
# ═══════════════════════════════════════════════════════════
#   Login Monitor Status
# ═══════════════════════════════════════════════════════════
#
# Configuration:
#   Monitoring: true
#   Root login alerts: true
#   Sudo alerts: true
#   SSH alerts: true
#   Email recipient: admin@example.com
#
# Service Status:
#   ✓ Service installed
#   ● RUNNING
#   Boot: ENABLED
#
# Recent Alerts (last 10):
#   [2025-10-20 14:32:15] Root login detected from 203.0.113.50
#   [2025-10-20 14:35:42] Sudo command: user='john' cmd='/usr/bin/apt-get update'
#   [2025-10-20 14:40:10] SSH login: user='admin' from 198.51.100.25
```

### Example 3: Start/Stop Service
```bash
# Start monitoring
nftban login start

# Stop monitoring
nftban login stop

# Restart service
nftban login restart

# Check if running
systemctl status nftban-login-monitor.timer
```

### Example 4: Enable/Disable at Boot
```bash
# Enable automatic start at boot
nftban login enable

# Disable automatic start
nftban login disable

# Check if enabled
systemctl is-enabled nftban-login-monitor.timer
```

### Example 5: Uninstall Service
```bash
nftban login uninstall

# Expected output:
# [INFO] Uninstalling login monitor service...
# [SUCCESS] Login monitor service uninstalled

# Verify removal
ls -l /etc/systemd/system/nftban-login-monitor.*
# Should show: No such file or directory
```

### Example 6: Test Configuration
```bash
nftban login test

# If monitoring disabled:
# Testing login monitor configuration...
#
# [ERROR] Login monitoring is disabled
#   Set: NFTBAN_F2B_LOGIN_MONITOR="true"

# If email not configured:
# [ERROR] Email recipient not configured
#   Set: NFTBAN_F2B_RECIPIENT="your@email.com"

# If valid:
# [SUCCESS] Configuration valid
#
# Send test email? (y/N): y
# Sending test email to admin@example.com...
# [INFO] Test email functionality not yet implemented
```

---

## Systemd Service Files

### Service Unit File

**Location:** `/etc/systemd/system/nftban-login-monitor.service`

**Content:**
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

**Explanation:**
- `Type=oneshot` - Service runs once and exits
- `ExecStart` - Calls `nftban login run` to perform monitoring cycle
- `User=root` - Runs as root (needed for log access)
- `StandardOutput=journal` - Logs to systemd journal

---

### Timer Unit File

**Location:** `/etc/systemd/system/nftban-login-monitor.timer`

**Content:**
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

**Explanation:**
- `OnBootSec=1min` - Start 1 minute after boot
- `OnUnitActiveSec=1min` - Run every minute after last execution
- `AccuracySec=1s` - Timer accuracy (1 second precision)
- `Requires` - Timer triggers the service

---

## Monitoring Cycle

### What Gets Monitored (Future Implementation)

**1. Root Logins**
- Direct root SSH logins
- Console root logins
- su to root from other users
- **Alert:** Immediate email notification

**2. Sudo Command Execution**
- All sudo commands
- User who executed
- Command that was run
- **Alert:** Email digest (every 15 minutes to prevent spam)

**3. SSH Login Events**
- Successful SSH authentications
- Source IP address
- Username
- **Alert:** Email for non-whitelisted IPs

**4. Failed Authentication Attempts**
- Multiple failed attempts (handled by Fail2ban primarily)
- Pattern recognition for attacks
- **Alert:** Email on sustained attacks

---

### Monitoring Workflow (Future Implementation)

```
Timer Trigger (every minute)
    ↓
1. Read new log entries since last check
   - /var/log/auth.log
   - /var/log/secure
   - systemd journal
    ↓
2. Parse events
   - Root login detected?
   - Sudo command executed?
   - SSH authentication?
    ↓
3. Check whitelist
   - Is IP whitelisted?
   - Is user expected?
    ↓
4. Check alert rules
   - Should alert be sent?
   - Deduplicate (same event within N minutes)
    ↓
5. Send alerts
   - Email notification
   - Log to alert log
    ↓
6. Update state
   - Save last processed log position
   - Update alert timestamps
```

---

## File Operations

### Creates:
- `/etc/systemd/system/nftban-login-monitor.service` - Service unit
- `/etc/systemd/system/nftban-login-monitor.timer` - Timer unit

### Reads from:
- `${NFTBAN_CONFIG_DIR}/nftban.conf.local` - Configuration
- `/var/log/auth.log` - Authentication logs (Debian/Ubuntu) (future)
- `/var/log/secure` - Authentication logs (RHEL/CentOS) (future)
- `systemd journal` - System logs (future)

### Writes to:
- `${NFTBAN_LOG_DIR}/login-monitor.log` - Monitoring activity
- `${NFTBAN_LOG_DIR}/login-alerts.log` - Alert events
- `${NFTBAN_CACHE_DIR}/login-monitor/` - State tracking (future)

---

## Alert Examples (Future Implementation)

### Root Login Alert

**Email Subject:** `[SECURITY] Root login detected on server-01`

**Email Body:**
```
Security Alert: Root Login Detected

Server: server-01.example.com
Timestamp: 2025-10-20 14:32:15
Event: Root login via SSH
Source IP: 203.0.113.50
Location: Unknown (GeoIP lookup failed)

This is an automated security alert from NFTBan.
If this login was unauthorized, investigate immediately.

Actions:
- Review: nftban stats ip-history 203.0.113.50
- Block: nftban blacklist add 203.0.113.50 "Unauthorized root login"

---
NFTBan Login Monitor
```

---

### Sudo Command Alert

**Email Subject:** `[INFO] Sudo activity on server-01`

**Email Body:**
```
Sudo Activity Summary

Server: server-01.example.com
Period: 2025-10-20 14:30:00 to 14:45:00
Commands executed: 5

Details:
1. [14:32:15] User: john | Command: /usr/bin/apt-get update
2. [14:33:42] User: john | Command: /usr/bin/apt-get upgrade -y
3. [14:35:10] User: mary | Command: /bin/systemctl restart nginx
4. [14:40:05] User: john | Command: /usr/bin/vi /etc/nginx/nginx.conf
5. [14:42:30] User: mary | Command: /bin/systemctl reload nginx

---
NFTBan Login Monitor
```

---

### SSH Login Alert

**Email Subject:** `[NOTICE] SSH login from new IP on server-01`

**Email Body:**
```
SSH Login Alert

Server: server-01.example.com
Timestamp: 2025-10-20 14:40:10
User: admin
Source IP: 198.51.100.25
Location: United States / New York / Example ISP
Authentication: Public key

This IP has not been seen before in the last 30 days.

IP History:
- First seen: 2025-10-20 14:40:10
- Previous logins: None

Actions:
- Whitelist: nftban whitelist add 198.51.100.25 "Admin workstation"
- Block: nftban blacklist add 198.51.100.25 "Suspicious login"

---
NFTBan Login Monitor
```

---

## Configuration Examples

### Minimal Configuration (Root Logins Only)

```bash
# /etc/nftban/config/nftban.conf.local

# Enable monitoring
NFTBAN_F2B_LOGIN_MONITOR="true"

# Alert only on root logins
NFTBAN_F2B_ROOT_LOGIN_ALERT="true"
NFTBAN_F2B_SUDO_ALERT="false"
NFTBAN_F2B_SSH_LOGIN_ALERT="false"

# Email recipient
NFTBAN_F2B_RECIPIENT="security@example.com"
```

---

### Full Monitoring Configuration

```bash
# /etc/nftban/config/nftban.conf.local

# Enable all monitoring
NFTBAN_F2B_LOGIN_MONITOR="true"
NFTBAN_F2B_ROOT_LOGIN_ALERT="true"
NFTBAN_F2B_SUDO_ALERT="true"
NFTBAN_F2B_SSH_LOGIN_ALERT="true"

# Alert settings
NFTBAN_F2B_RECIPIENT="admin@example.com,security@example.com"
NFTBAN_F2B_ALERT_FREQUENCY="15"  # minutes (future)
NFTBAN_F2B_SSH_WHITELIST_IPS="203.0.113.0/24"  # (future)
```

---

### High-Security Configuration

```bash
# /etc/nftban/config/nftban.conf.local

# Maximum monitoring
NFTBAN_F2B_LOGIN_MONITOR="true"
NFTBAN_F2B_ROOT_LOGIN_ALERT="true"
NFTBAN_F2B_SUDO_ALERT="true"
NFTBAN_F2B_SSH_LOGIN_ALERT="true"

# Strict alerting
NFTBAN_F2B_RECIPIENT="security@example.com"
NFTBAN_F2B_ALERT_IMMEDIATE="true"  # No digest, immediate (future)
NFTBAN_F2B_ALERT_ON_NEW_IP="true"  # Alert on first-time IPs (future)

# Integration with threat feeds (future)
NFTBAN_F2B_CHECK_GEOIP="true"
NFTBAN_F2B_ALERT_HIGH_RISK_COUNTRIES="true"
```

---

## Integration Points

**Called by:**
- `systemd` - Timer triggers service every minute
- `nftban_main_cli.sh` - For `nftban login` commands
- System administrators - Manual testing and control

**Calls:**
- `nftban_log_*()` from `nftban_core.sh` - Logging
- `nftban_get_config()` from `nftban_core.sh` - Configuration
- `systemctl` - Service management
- Email system (future) - Alert delivery

**Integrates with:**
- Fail2ban - Complementary (Fail2ban=failed attempts, Login Monitor=successful events)
- nftban_geoip_module - GeoIP lookups for alerts (future)
- nftban_whitelist_module - Check if IP is whitelisted (future)

---

## Troubleshooting

### Problem: Service Won't Start

**Diagnostic:**
```bash
# Check service status
systemctl status nftban-login-monitor.timer

# Check service file exists
ls -l /etc/systemd/system/nftban-login-monitor.*

# Check for errors
journalctl -u nftban-login-monitor.service -n 50

# Test manual run
/usr/local/bin/nftban login run
```

**Solution:**
```bash
# Reinstall service
nftban login uninstall
nftban login install

# Reload systemd
systemctl daemon-reload

# Enable and start
nftban login enable
nftban login start
```

---

### Problem: No Alerts Received

**Diagnostic:**
```bash
# Check configuration
nftban login status

# Verify email recipient set
grep NFTBAN_F2B_RECIPIENT /etc/nftban/config/nftban.conf.local

# Check alert log
tail -50 /var/log/nftban/login-alerts.log

# Test email system
echo "Test" | mail -s "Test" admin@example.com
```

**Solution:**
```bash
# Enable monitoring if disabled
# Edit: /etc/nftban/config/nftban.conf.local
# Set: NFTBAN_F2B_LOGIN_MONITOR="true"

# Set recipient
# Set: NFTBAN_F2B_RECIPIENT="your@email.com"

# Restart service
nftban login restart

# Trigger test event (SSH login) and wait 1 minute
```

---

### Problem: Timer Not Triggering

**Diagnostic:**
```bash
# Check timer status
systemctl status nftban-login-monitor.timer

# List timers
systemctl list-timers | grep nftban

# Check timer file
cat /etc/systemd/system/nftban-login-monitor.timer
```

**Solution:**
```bash
# Reload systemd
systemctl daemon-reload

# Re-enable timer
systemctl disable nftban-login-monitor.timer
systemctl enable nftban-login-monitor.timer

# Start timer
systemctl start nftban-login-monitor.timer

# Verify
systemctl list-timers | grep nftban
```

---

### Problem: High CPU Usage

**Cause:** Timer running too frequently with large log files

**Diagnostic:**
```bash
# Check timer frequency
cat /etc/systemd/system/nftban-login-monitor.timer | grep OnUnitActiveSec

# Check log size
ls -lh /var/log/auth.log /var/log/secure

# Monitor CPU during run
top -p $(pgrep -f nftban-login-monitor)
```

**Solution:**
```bash
# Adjust timer frequency (edit timer file)
sudo nano /etc/systemd/system/nftban-login-monitor.timer

# Change from every minute to every 5 minutes:
# OnUnitActiveSec=5min

# Reload and restart
systemctl daemon-reload
systemctl restart nftban-login-monitor.timer

# Or rotate logs more frequently
logrotate -f /etc/logrotate.d/rsyslog
```

---

## Best Practices

### ✅ DO:

1. **Configure email recipient** before enabling
2. **Test configuration** before production use
3. **Whitelist known IPs** to reduce alert noise
4. **Review alerts regularly** (weekly minimum)
5. **Adjust sensitivity** based on environment
6. **Enable at boot** for continuous monitoring
7. **Monitor log sizes** (rotate regularly)
8. **Document expected behavior** (baseline)
9. **Integrate with incident response** procedures
10. **Test email delivery** periodically

### ❌ DON'T:

1. **Don't enable without email configured** (alerts go nowhere)
2. **Don't ignore alerts** (defeats purpose)
3. **Don't alert on everything** (alert fatigue)
4. **Don't skip testing** before enabling
5. **Don't forget log rotation** (disk space issues)
6. **Don't disable during maintenance** (security gap)
7. **Don't use personal email** for production alerts
8. **Don't forget to whitelist admin IPs**
9. **Don't run timer too frequently** (<1 minute)
10. **Don't neglect alert log review**

---

## Future Enhancements (Roadmap)

### Planned for v1.1.0
- [ ] Full monitoring logic implementation
- [ ] Log parsing (auth.log, secure, journal)
- [ ] Email alert delivery
- [ ] Alert deduplication
- [ ] State tracking (last processed position)

### Planned for v1.2.0
- [ ] GeoIP integration for alerts
- [ ] Threat intelligence lookups
- [ ] Alert digests (reduce spam)
- [ ] Whitelist integration
- [ ] Configurable alert templates

### Planned for v2.0.0
- [ ] Slack/webhook notifications
- [ ] Advanced pattern detection
- [ ] Machine learning anomaly detection
- [ ] Dashboard integration
- [ ] Historical analysis and reporting

---

## Change Log

### Version 1.0.0 (2025-10-20) - Initial Release
- Systemd service and timer installation
- Service management (enable, disable, start, stop)
- Configuration validation and testing
- Status reporting
- Infrastructure for future monitoring logic
- Alert log framework

---

## See Also

**Related Modules:**
- `nftban_fail2ban_module.sh` - Failed authentication handling
- `nftban_geoip_module.sh` - GeoIP lookups (future integration)
- `nftban_whitelist_module.sh` - IP whitelist checking (future integration)
- `nftban_core.sh` - Core logging and configuration

**Related Documentation:**
- systemd.timer(5) - Timer unit configuration
- systemd.service(5) - Service unit configuration
- journalctl(1) - Journal query tool

**External Resources:**
- [systemd Timers](https://www.freedesktop.org/software/systemd/man/systemd.timer.html)
- [Monitoring Linux Logins](https://www.tecmint.com/monitor-linux-login-attempts/)

---

## Summary

The Login Monitor Module provides infrastructure for security event monitoring via systemd timer integration (runs every minute), email alerting framework, configurable monitoring levels, and comprehensive service management. Version 1.0.0 establishes the foundation; full monitoring logic planned for v1.1.0. Essential for proactive security monitoring beyond Fail2ban's failed attempt detection.