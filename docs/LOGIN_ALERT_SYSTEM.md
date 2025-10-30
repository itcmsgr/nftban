# NFTBan Login Alert System

**Version:** 1.0.0
**Module:** `nftban_login_alert.sh` + `cmd_login.sh`
**Author:** Antonios Voulvoulis <contact@nftban.com>
**Website:** https://nftban.com
**Status:** ✅ Production Ready

---

## Table of Contents

1. [Overview](#overview)
2. [Features](#features)
3. [Architecture](#architecture)
4. [Installation](#installation)
5. [Configuration](#configuration)
6. [CLI Usage](#cli-usage)
7. [Alert Types](#alert-types)
8. [GeoIP Integration](#geoip-integration)
9. [Failed Attempt Tracking](#failed-attempt-tracking)
10. [Email Templates](#email-templates)
11. [Systemd Service](#systemd-service)
12. [Integration Examples](#integration-examples)
13. [Troubleshooting](#troubleshooting)

---

## Overview

The NFTBan Login Alert System monitors system logins (SSH, su, sudo, console) and sends real-time email alerts with GeoIP enrichment. It tracks failed login attempts and can trigger alerts when thresholds are exceeded.

### Key Benefits

- **Real-Time Monitoring** - Instant alerts on successful logins
- **GeoIP Enrichment** - Shows location of login source
- **Failed Attempt Tracking** - Detects brute force attempts
- **Beautiful HTML Emails** - Professional-looking alerts
- **IP Whitelisting** - Skip alerts for trusted IPs
- **Service Integration** - Runs as systemd service
- **Flexible Configuration** - Monitor what you want

---

## Features

### Monitoring Capabilities

1. **SSH Logins** - Both successful and failed attempts
2. **SU Commands** - User switching (optional)
3. **SUDO Commands** - Privileged command execution (optional)
4. **Console Logins** - Direct console access (optional)

### Alert Features

1. **Instant Notifications** - Email sent immediately on login
2. **GeoIP Location** - Country, region, city of source IP
3. **HTML & Text Formats** - Beautiful HTML or plain text
4. **Failed Attempt Detection** - Threshold-based alerts
5. **Time Window Tracking** - Track attempts over time
6. **IP Whitelisting** - Skip alerts for known IPs
7. **Detailed Logging** - All events logged

---

## Architecture

### Core Module: `nftban_login_alert.sh`

Location: `/usr/lib/nftban/core/nftban_login_alert.sh`

**10 Exported Functions:**

```bash
# Utility functions
nftban_login_log()               # Log events
nftban_login_is_whitelisted()    # Check IP whitelist
nftban_login_get_geoip()         # Get location data

# Alert functions
nftban_login_send_alert()        # Send email alert
nftban_login_send_text_alert()   # Plain text email
nftban_login_send_html_alert()   # HTML email

# Monitoring functions
nftban_login_monitor_ssh()       # Monitor SSH via journalctl
nftban_login_track_failed()      # Track failed attempts
nftban_login_monitor_all()       # Monitor all services

# Testing
nftban_login_test()              # Send test alert
```

### CLI Handler: `cmd_login.sh`

Location: `/usr/lib/nftban/cli/cmd_login.sh`

**8 CLI Commands:**

```bash
nftban login status      # Show monitoring status
nftban login install     # Install systemd service
nftban login enable      # Enable and start service
nftban login disable     # Disable and stop service
nftban login logs [N]    # Show logs (last N lines)
nftban login test        # Send test alert
nftban login run         # Run monitoring (for service)
nftban login help        # Show help
```

### Configuration File

Location: `/etc/nftban/conf.d/login_alert.conf`

**16 Configuration Options** - See [Configuration](#configuration) section.

---

## Installation

### Prerequisites

1. **Mail System** - `mail` or `mailx` command must be working
2. **Systemd** - For service management
3. **Journalctl** - For log monitoring
4. **GeoIP** (optional) - For location enrichment

### Verify Mail Works

```bash
# Test mail command
echo "Test email" | mail -s "Test" admin@example.com

# Check mail logs
journalctl -u postfix -f
# or
tail -f /var/log/mail.log
```

### Install Service

```bash
# Install systemd service
sudo nftban login install

# Output:
Installing NFTBan Login Monitor Service
========================================

Creating service file: /etc/systemd/system/nftban-login-monitor.service
✅ Service file created

Reloading systemd daemon...
✅ Systemd reloaded

Service installed successfully!

To start monitoring:
  systemctl start nftban-login-monitor

To enable on boot:
  systemctl enable nftban-login-monitor
```

### Enable and Start

```bash
# Enable and start service
sudo nftban login enable

# Output:
Enabling NFTBan Login Monitor
=============================

Enabling service...
✅ Service enabled

Starting service...
✅ Service started

● nftban-login-monitor.service - NFTBan Login Monitor
     Loaded: loaded
     Active: active (running) since Mon 2025-10-27 14:30:22 UTC
```

---

## Configuration

### Configuration File

Location: `/etc/nftban/conf.d/login_alert.conf`

```bash
# =============================================================================
# NFTBan Login Alert Configuration
# =============================================================================

# Enable/Disable login alerts
NFTBAN_LOGIN_ALERT_ENABLED="true"

# Alert destination email
NFTBAN_LOGIN_ALERT_EMAIL="admin@example.com"

# Alert for SSH logins
NFTBAN_LOGIN_ALERT_SSH="true"

# Alert for su/sudo commands
NFTBAN_LOGIN_ALERT_SU="true"
NFTBAN_LOGIN_ALERT_SUDO="true"

# Alert for console logins
NFTBAN_LOGIN_ALERT_CONSOLE="false"

# Include GeoIP information in alerts
NFTBAN_LOGIN_ALERT_GEOIP="true"

# Alert format (text|html)
NFTBAN_LOGIN_ALERT_FORMAT="html"

# Log file
NFTBAN_LOGIN_ALERT_LOG="/var/log/nftban/login_alert.log"

# Monitoring interval (seconds) for journalctl polling
NFTBAN_LOGIN_MONITOR_INTERVAL="5"

# Whitelist IPs (space-separated, no alerts for these)
NFTBAN_LOGIN_WHITELIST="192.168.1.100 10.0.0.50"

# Alert on failed login attempts
NFTBAN_LOGIN_ALERT_FAILED="true"

# Minimum failed attempts before alert
NFTBAN_LOGIN_FAILED_THRESHOLD="3"

# Time window for failed attempts (seconds)
NFTBAN_LOGIN_FAILED_WINDOW="300"
```

### Configuration Options Explained

| Option | Default | Description |
|--------|---------|-------------|
| `NFTBAN_LOGIN_ALERT_ENABLED` | `true` | Master enable/disable |
| `NFTBAN_LOGIN_ALERT_EMAIL` | `admin@example.com` | Alert destination |
| `NFTBAN_LOGIN_ALERT_SSH` | `true` | Monitor SSH logins |
| `NFTBAN_LOGIN_ALERT_SU` | `true` | Monitor su commands |
| `NFTBAN_LOGIN_ALERT_SUDO` | `true` | Monitor sudo commands |
| `NFTBAN_LOGIN_ALERT_CONSOLE` | `false` | Monitor console logins |
| `NFTBAN_LOGIN_ALERT_GEOIP` | `true` | Include GeoIP data |
| `NFTBAN_LOGIN_ALERT_FORMAT` | `html` | Email format (html/text) |
| `NFTBAN_LOGIN_ALERT_LOG` | `/var/log/nftban/login_alert.log` | Log file |
| `NFTBAN_LOGIN_MONITOR_INTERVAL` | `5` | Polling interval (seconds) |
| `NFTBAN_LOGIN_WHITELIST` | `""` | Space-separated IPs to skip |
| `NFTBAN_LOGIN_ALERT_FAILED` | `true` | Alert on failed attempts |
| `NFTBAN_LOGIN_FAILED_THRESHOLD` | `3` | Failed attempts before alert |
| `NFTBAN_LOGIN_FAILED_WINDOW` | `300` | Time window (5 minutes) |

### Quick Configuration Examples

#### Basic Setup

```bash
# /etc/nftban/conf.d/login_alert.conf

# Only monitor SSH, send HTML emails
NFTBAN_LOGIN_ALERT_ENABLED="true"
NFTBAN_LOGIN_ALERT_EMAIL="security@company.com"
NFTBAN_LOGIN_ALERT_SSH="true"
NFTBAN_LOGIN_ALERT_SU="false"
NFTBAN_LOGIN_ALERT_SUDO="false"
NFTBAN_LOGIN_ALERT_CONSOLE="false"
NFTBAN_LOGIN_ALERT_FORMAT="html"
```

#### High Security Setup

```bash
# Monitor everything, low threshold
NFTBAN_LOGIN_ALERT_SSH="true"
NFTBAN_LOGIN_ALERT_SU="true"
NFTBAN_LOGIN_ALERT_SUDO="true"
NFTBAN_LOGIN_ALERT_CONSOLE="true"
NFTBAN_LOGIN_ALERT_FAILED="true"
NFTBAN_LOGIN_FAILED_THRESHOLD="2"      # Alert after 2 failures
NFTBAN_LOGIN_FAILED_WINDOW="180"       # Within 3 minutes
```

#### Development Setup

```bash
# Whitelist local IPs, high threshold
NFTBAN_LOGIN_WHITELIST="127.0.0.1 192.168.1.0/24 10.0.0.0/8"
NFTBAN_LOGIN_FAILED_THRESHOLD="10"     # Only alert after 10 failures
NFTBAN_LOGIN_ALERT_FORMAT="text"       # Simple text emails
```

---

## CLI Usage

### Check Status

```bash
nftban login status

# Output:
NFTBan Login Alert Status
=========================

✅ Configuration: /etc/nftban/conf.d/login_alert.conf
✅ Core Module: Installed
✅ Service: Running

Configuration:
  Enabled: true
  Email: admin@example.com
  Format: html
  GeoIP: true

Monitoring:
  SSH: true
  SU: true
  SUDO: true
  Console: false

Failed Attempts:
  Alert on Failed: true
  Threshold: 3 attempts
  Time Window: 300 seconds

Log File: /var/log/nftban/login_alert.log (247 lines)
```

### Install Service

```bash
sudo nftban login install
```

See [Installation](#installation) section for details.

### Enable/Disable

```bash
# Enable and start
sudo nftban login enable

# Disable and stop
sudo nftban login disable

# Output:
Disabling NFTBan Login Monitor
==============================

Stopping service...
✅ Service stopped

Disabling service...
✅ Service disabled
```

### View Logs

```bash
# Show last 50 lines (default)
nftban login logs

# Show last 100 lines
nftban login logs 100

# Output:
NFTBan Login Alert Logs (last 100 lines)
===========================================

[2025-10-27 14:30:45] SSH login: alice from 203.0.113.45 (method: publickey)
[2025-10-27 14:31:12] SSH login: bob from 198.51.100.23 (method: password)
[2025-10-27 14:32:05] Failed SSH attempt: user from 192.0.2.100
[2025-10-27 14:32:08] Failed SSH attempt: user from 192.0.2.100
[2025-10-27 14:32:11] Failed SSH attempt: user from 192.0.2.100
[2025-10-27 14:32:11] Multiple failed attempts: user from 192.0.2.100 (SSH)

Service logs (last 100 lines):
==================================
Oct 27 14:30:22 server systemd[1]: Started NFTBan Login Monitor.
Oct 27 14:30:22 server nftban-login-alert[1234]: Starting login monitoring
```

### Send Test Alert

```bash
nftban login test

# Output:
Testing NFTBan Login Alert System
==================================

Configuration:
  Enabled: true
  Email: admin@example.com
  Format: html
  GeoIP: true

Testing GeoIP:
  8.8.8.8 → United States, California, Mountain View

Sending test alert...
✓ Test alert sent to admin@example.com
```

You'll receive an email with:
- Subject: `[NFTBan] SUCCESS Login: testuser @ server.example.com`
- Content: Test login from 8.8.8.8 with GeoIP data

---

## Alert Types

### Successful Login Alert

**Trigger:** Successful SSH/su/sudo/console login

**Email Subject:**
```
[NFTBan] SUCCESS Login: alice @ web-server-01
```

**Contains:**
- Username
- Source IP address
- GeoIP location (country, region, city)
- Authentication method (password, publickey, etc.)
- Timestamp
- Server hostname

### Failed Login Alert

**Trigger:** Multiple failed attempts exceed threshold

**Email Subject:**
```
[NFTBan] FAILED Login: user @ web-server-01
```

**Contains:**
- Username attempted
- Source IP address
- GeoIP location
- Number of failed attempts
- Time window
- Service (SSH, su, sudo)

### Suspicious Activity Alert

**Trigger:** Unusual patterns detected

**Email Subject:**
```
[NFTBan] SUSPICIOUS Login: root @ web-server-01
```

**Contains:**
- Details of suspicious behavior
- Source information
- Recommended actions

---

## GeoIP Integration

### How It Works

The Login Alert System integrates with the [GO GeoIP Module](GO_GEOIP_MODULE.md) to enrich alerts with location information.

**Lookup Process:**

1. Login detected via journalctl
2. IP address extracted from log entry
3. GeoIP lookup performed (40-50 μs)
4. Location data added to alert email

**Location Data Included:**

```
IP Address: 203.0.113.45
Location: United States, California, Mountain View
Coordinates: 37.386, -122.0838
```

### Without GeoIP

If GeoIP is disabled or unavailable:

```bash
NFTBAN_LOGIN_ALERT_GEOIP="false"
```

Alerts will show:
```
IP Address: 203.0.113.45
Location: GeoIP disabled
```

### GeoIP Fallback

If GeoIP lookup fails:

```
IP Address: 203.0.113.45
Location: Unknown (lookup failed)
```

---

## Failed Attempt Tracking

### How It Works

The system tracks failed login attempts per user@IP combination:

```bash
# Tracking key
key="${user}@${ip}"

# Data stored
NFTBAN_FAILED_ATTEMPTS[$key]=3       # Attempt count
NFTBAN_FAILED_TIMESTAMPS[$key]=1730042400  # First attempt timestamp
```

### Algorithm

```
1. Failed login detected
2. Check if user@IP exists in tracking
3. If first attempt:
   - Initialize counter = 1
   - Store timestamp
4. If subsequent attempt:
   - Check if within time window
   - If yes: increment counter
   - If counter >= threshold: send alert and reset
   - If no: reset counter and timestamp
```

### Example

Configuration:
```bash
NFTBAN_LOGIN_FAILED_THRESHOLD="3"
NFTBAN_LOGIN_FAILED_WINDOW="300"  # 5 minutes
```

Scenario:
```
14:30:00 - Failed attempt #1 from user@192.0.2.100 → Counter = 1
14:30:15 - Failed attempt #2 from user@192.0.2.100 → Counter = 2
14:30:30 - Failed attempt #3 from user@192.0.2.100 → Counter = 3 → ALERT!
14:36:00 - Failed attempt #4 from user@192.0.2.100 → Counter reset (outside 5min window)
```

Alert contains:
```
Failed attempts: 3 in 30 seconds
```

---

## Email Templates

### HTML Template

Beautiful, professional-looking emails with:

- **Gradient Header** - Purple gradient with NFTBan logo
- **Status Badge** - Color-coded (green/red/yellow)
- **Info Sections** - Organized in tables
- **Details Box** - Monospace font for technical details
- **Responsive Design** - Works on mobile and desktop
- **Branded Footer** - NFTBan branding and link

**Colors:**
- Success: `#28a745` (green)
- Failed: `#dc3545` (red)
- Suspicious: `#ffc107` (yellow)

**Sample HTML Email:**

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="author" content="Antonios Voulvoulis, contact@nftban.com">
    <meta name="generator" content="NFTBan v0.10.0">
    <title>NFTBan Login Alert</title>
    <style>
        /* Beautiful gradient, responsive layout, etc. */
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>🔐 NFTBan Login Alert</h1>
            <span class="status-badge">SUCCESS</span>
        </div>

        <div class="content">
            <div class="info-section">
                <h2>Event Information</h2>
                <div class="info-row">
                    <div class="info-label">Event Type:</div>
                    <div class="info-value">SSH Login</div>
                </div>
                <!-- More info rows -->
            </div>

            <div class="info-section">
                <h2>Connection Information</h2>
                <div class="info-row">
                    <div class="info-label">IP Address:</div>
                    <div class="info-value"><code>203.0.113.45</code></div>
                </div>
                <div class="info-row">
                    <div class="info-label">Location:</div>
                    <div class="info-value">United States, California, Mountain View</div>
                </div>
            </div>
        </div>

        <div class="footer">
            <strong>nftban — Simplifying Linux Firewall Management</strong><br>
            <a href="https://nftban.com">https://nftban.com</a>
        </div>
    </div>
</body>
</html>
```

### Text Template

Simple plain text for email clients that don't support HTML:

```
NFTBan Login Alert
==================

Event Type: SSH Login
Status: SUCCESS
Timestamp: 2025-10-27 14:30:22 UTC

User Information:
  Username: alice
  Service: SSH

Connection Information:
  IP Address: 203.0.113.45
  Location: United States, California, Mountain View
  Hostname: web-server-01

Additional Details:
Authentication method: publickey

---
nftban — Simplifying Linux Firewall Management
https://nftban.com
```

---

## Systemd Service

### Service File

Location: `/etc/systemd/system/nftban-login-monitor.service`

```ini
[Unit]
Description=NFTBan Login Monitor
Documentation=https://nftban.com
After=network.target sshd.service

[Service]
Type=simple
User=root
Group=root
ExecStart=/usr/sbin/nftban login run
Restart=on-failure
RestartSec=5s
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nftban-login-monitor

# Security hardening
PrivateTmp=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=/var/log/nftban

[Install]
WantedBy=multi-user.target
```

### Service Management

```bash
# Start service
sudo systemctl start nftban-login-monitor

# Stop service
sudo systemctl stop nftban-login-monitor

# Enable on boot
sudo systemctl enable nftban-login-monitor

# Disable on boot
sudo systemctl disable nftban-login-monitor

# Check status
sudo systemctl status nftban-login-monitor

# View logs
sudo journalctl -u nftban-login-monitor -f

# Restart service
sudo systemctl restart nftban-login-monitor
```

### Why Root Required

The service runs as root because:
1. **Journalctl Access** - Reading system logs requires root
2. **SSH Logs** - SSH logs contain sensitive information
3. **Email Sending** - Mail command may need privileges
4. **Log Writing** - Writing to `/var/log/nftban/` requires permissions

---

## Integration Examples

### Bash Script Integration

```bash
#!/bin/bash

# Source login alert module
source /usr/lib/nftban/core/nftban_login_alert.sh

# Send custom alert
nftban_login_send_alert \
    "Custom Event" \
    "admin" \
    "203.0.113.45" \
    "Web Console" \
    "SUCCESS" \
    "User accessed admin panel"
```

### PAM Integration (Advanced)

Add to `/etc/pam.d/sshd`:

```
# NFTBan login alert
session optional pam_exec.so /usr/lib/nftban/hooks/login-alert.sh
```

Create `/usr/lib/nftban/hooks/login-alert.sh`:

```bash
#!/bin/bash
source /usr/lib/nftban/core/nftban_login_alert.sh

nftban_login_send_alert \
    "PAM SSH Login" \
    "$PAM_USER" \
    "$PAM_RHOST" \
    "SSH" \
    "SUCCESS" \
    "Via PAM hook"
```

### Webhook Integration

Forward alerts to Slack, Discord, etc.:

```bash
# In login_alert.conf
NFTBAN_LOGIN_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

# Custom alert function
nftban_login_send_webhook() {
    local message="$1"

    curl -X POST "$NFTBAN_LOGIN_WEBHOOK_URL" \
        -H 'Content-Type: application/json' \
        -d "{\"text\": \"$message\"}"
}
```

---

## Troubleshooting

### Common Issues

#### 1. No emails received

**Check mail system:**
```bash
# Test mail command
echo "Test" | mail -s "Test" admin@example.com

# Check mail logs
journalctl -u postfix -f
tail -f /var/log/mail.log

# Verify configuration
grep NFTBAN_LOGIN_ALERT_EMAIL /etc/nftban/conf.d/login_alert.conf
```

**Solution:**
- Install and configure mail system (postfix, sendmail, etc.)
- Verify email address is correct
- Check firewall allows SMTP traffic

#### 2. Service not starting

**Check service status:**
```bash
sudo systemctl status nftban-login-monitor

# Check logs
sudo journalctl -u nftban-login-monitor -n 50
```

**Common causes:**
- Module not found: Check `/usr/lib/nftban/core/nftban_login_alert.sh` exists
- Permission denied: Service must run as root
- Configuration error: Check syntax in `login_alert.conf`

#### 3. GeoIP not working

**Check GeoIP:**
```bash
# Test GeoIP
nftban geoip lookup 8.8.8.8

# Check health
nftban health geoip
```

**Solution:**
```bash
# Update GeoIP
sudo nftban geoip update

# Or disable GeoIP
# In login_alert.conf:
NFTBAN_LOGIN_ALERT_GEOIP="false"
```

#### 4. Too many alerts

**Reduce alert volume:**

```bash
# In login_alert.conf

# Add whitelist
NFTBAN_LOGIN_WHITELIST="192.168.1.0/24 10.0.0.0/8"

# Increase failed attempt threshold
NFTBAN_LOGIN_FAILED_THRESHOLD="10"

# Disable sudo/su alerts
NFTBAN_LOGIN_ALERT_SU="false"
NFTBAN_LOGIN_ALERT_SUDO="false"
```

#### 5. Missed logins

**Check monitoring is running:**
```bash
# Check service
sudo systemctl status nftban-login-monitor

# Check logs
tail -f /var/log/nftban/login_alert.log

# Verify journalctl works
sudo journalctl -u sshd -n 10
```

### Debug Mode

```bash
# Stop service
sudo systemctl stop nftban-login-monitor

# Run manually with debug
sudo NFTBAN_DEBUG=1 nftban login run

# Watch logs
tail -f /var/log/nftban/login_alert.log
```

---

## Security Considerations

### Sensitive Information

Login alerts contain:
- ✅ Usernames - OK to send
- ✅ Source IPs - OK to send
- ✅ Timestamps - OK to send
- ❌ Passwords - **NEVER sent**

### Email Security

- **Use TLS** - Configure mail system to use TLS
- **Secure Recipients** - Only send to trusted addresses
- **Avoid Public Mail** - Don't use free email providers for production

### Log Rotation

Configure log rotation in `/etc/logrotate.d/nftban`:

```
/var/log/nftban/login_alert.log {
    daily
    rotate 30
    compress
    delaycompress
    missingok
    notifempty
    create 640 root nftban
}
```

---

## Performance

### Resource Usage

```
CPU: < 0.1% (idle monitoring)
     ~ 2-5% (during alert processing)
Memory: ~ 10-20 MB
Disk I/O: Minimal (only log writes)
Network: Only for email sending
```

### Email Delivery Time

```
Local delivery: < 1 second
Remote delivery: 1-5 seconds (depends on mail server)
GeoIP lookup: 40-50 microseconds
Alert generation: < 100 milliseconds
```

---

## Best Practices

1. **Test First** - Use `nftban login test` before enabling
2. **Configure Mail** - Ensure mail system works
3. **Use Whitelist** - Whitelist trusted IPs
4. **Monitor Logs** - Check `/var/log/nftban/login_alert.log` regularly
5. **Tune Thresholds** - Adjust based on your environment
6. **Enable Service** - Use systemd service, not manual runs
7. **Rotate Logs** - Configure log rotation
8. **Secure Emails** - Use TLS for email transmission
9. **Alert Recipients** - Multiple recipients for redundancy
10. **Regular Tests** - Test monthly to ensure it works

---

## Related Documentation

- [GO_GEOIP_MODULE.md](GO_GEOIP_MODULE.md) - GeoIP integration
- [HEALTH_CHECK_SYSTEM.md](HEALTH_CHECK_SYSTEM.md) - System health checks
- [BASH_COMPLETION.md](BASH_COMPLETION.md) - TAB completion

---

**nftban — Simplifying Linux Firewall Management**

https://nftban.com
