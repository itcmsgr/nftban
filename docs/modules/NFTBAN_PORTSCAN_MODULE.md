# NFTBan Port Scan Detection Module

**Module:** `nftban_portscan_module.sh` | **Version:** 0.9.3-dev | **Location:** `/usr/local/lib/nftban/`

## Overview

The Port Scan Detection Module identifies and blocks malicious port scanning activity using pattern detection and automatic response. It tracks distinct port access patterns per IP address within configurable time windows, triggering automatic bans when threshold limits are exceeded.

### Key Features

- **Pattern-Based Detection**: Tracks distinct ports accessed per IP within time window (default: 10 ports in 300 seconds)
- **In-Memory Tracking**: Associative arrays for O(1) lookups with automatic cleanup
- **nftables Log Integration**: Parses kernel logs with configurable log prefixes
- **Auto-Ban Capability**: Automatic temporary or permanent bans upon detection
- **Whitelist Support**: Module-specific whitelist + main NFTBan whitelist integration
- **Email Alerts**: Detailed port scan notifications with forensic data
- **Configurable Thresholds**: Customizable detection sensitivity and response actions

### Dependencies

- **Core Module**: `nftban_core.sh`
- **Blacklist Module**: `nftban_blacklist_module.sh` (for auto-ban)
- **Whitelist Module**: `nftban_whitelist_module.sh` (for safety checks)
- **Utils Module**: `nftban_utils_lib.sh` (for email alerts)
- **nftables**: Logging rules for packet capture

---

## API Reference

### Configuration Management

**`nftban_portscan_load_config(key, default)`** - Load configuration with caching
```bash
threshold=$(nftban_portscan_load_config "PORTSCAN_THRESHOLD" "10")
# Returns: "10" (or value from portscan.conf.local / portscan.conf)
```
- **Config precedence**: `.conf.local` > `.conf` > default
- **Caching**: Results cached in `NFTBAN_PORTSCAN_CONFIG_CACHE` for performance
- **Usage**: Internal function for all config reads

**`nftban_portscan_is_enabled()`** - Check if detection is globally enabled
```bash
if nftban_portscan_is_enabled; then
    echo "Port scan detection is active"
fi
```
- **Default**: Enabled (1)
- **Config key**: `PORTSCAN_ENABLED`

**`nftban_portscan_is_whitelisted(ip)`** - Check if IP is exempt from detection
```bash
if nftban_portscan_is_whitelisted "203.0.113.50"; then
    echo "IP is whitelisted - skipping detection"
fi
```
- **Checks**: Main NFTBan whitelist + module-specific whitelist
- **File**: `/etc/nftban/portscan_whitelist.conf`

---

### Tracking Functions

**`nftban_portscan_init_tracking()`** - Initialize tracking system
```bash
nftban_portscan_init_tracking
# Creates tracking directory, clears old data (>10 minutes)
```
- **Cleanup**: Removes tracking files older than 10 minutes
- **Auto-called**: By `nftban_portscan_enable()`

**`nftban_portscan_record_access(ip, port)`** - Record port access for IP
```bash
nftban_portscan_record_access "203.0.113.100" "22"
nftban_portscan_record_access "203.0.113.100" "80"
nftban_portscan_record_access "203.0.113.100" "443"
# Tracks distinct ports accessed by this IP
```
- **Storage**: In-memory associative arrays
  - `NFTBAN_PORTSCAN_IP_PORTS[ip]`: "22,80,443,..."
  - `NFTBAN_PORTSCAN_IP_COUNT[ip]`: 3
  - `NFTBAN_PORTSCAN_IP_FIRST_SEEN[ip]`: Unix timestamp
- **Deduplication**: Only counts distinct ports (duplicates ignored)

**`nftban_portscan_check_ip(ip)`** - Check if IP exceeds detection threshold
```bash
if nftban_portscan_check_ip "203.0.113.100"; then
    echo "Port scanner detected!"
fi
```
- **Returns**: 0 if threshold exceeded, 1 otherwise
- **Auto-reset**: Clears tracking if time window expired
- **Logged**: Warning message with forensic details

**`nftban_portscan_get_ports(ip)`** - Get comma-separated port list for IP
```bash
ports=$(nftban_portscan_get_ports "203.0.113.100")
echo "Ports accessed: $ports"
# Output: Ports accessed: 22,80,443,8080,3306,5432
```

---

### Detection Functions

**`nftban_portscan_parse_nftables_log()`** - Parse kernel logs for port scan activity
```bash
nftban_portscan_parse_nftables_log
# Parses last 1000 lines from /var/log/messages or /var/log/kern.log
# Extracts IP addresses and ports, records access, triggers detection
```
- **Log sources**: `/var/log/kern.log` (Debian/Ubuntu), `/var/log/messages` (RHEL/CentOS), `/var/log/syslog`
- **Log prefix**: Configurable (default: "nftban: portscan: ")
- **Parsing**: Extracts `SRC=` (IP) and `DPT=` (port) from kernel log format
- **Workflow**:
  1. Read last 1000 log lines
  2. Filter lines with port scan prefix
  3. Extract source IP and destination port
  4. Skip whitelisted IPs
  5. Record access
  6. Check threshold and trigger handler

**`nftban_portscan_handle_detected_scanner(ip)`** - Handle detected port scanner
```bash
# Called automatically when threshold exceeded
# Actions:
# 1. Logs warning with port list
# 2. Sends email alert (if enabled)
# 3. Auto-bans IP (temporary or permanent)
# 4. Clears tracking data for IP
```
- **Ban types**:
  - **Temporary**: Default 3600 seconds (1 hour)
  - **Permanent**: Added to user blacklist
- **Auto-ban**: Controlled by `PORTSCAN_AUTO_BAN` (default: 1)

**`nftban_portscan_send_alert(ip, count, ports)`** - Send email alert
```bash
# Called automatically by handler
# Email includes:
# - Timestamp and server hostname
# - Scanner IP address
# - Number of ports accessed
# - Full port list
# - Action taken (banned/monitored)
# - Investigation commands (whois, stats)
```

---

### Control Functions

**`nftban_portscan_enable()`** - Enable port scan detection
```bash
nftban portscan enable
# ✓ Port scan detection enabled
```
- **Actions**:
  1. Checks if globally enabled in config
  2. Initializes tracking system
  3. Sets up nftables logging rules
  4. Creates log files and directories
- **Requirements**: `PORTSCAN_ENABLED="1"` in config

**`nftban_portscan_disable()`** - Disable port scan detection
```bash
nftban portscan disable
# ✓ Port scan detection disabled
```
- **Actions**: Removes nftables logging rules

**`nftban_portscan_check()`** - Run detection check manually
```bash
nftban portscan check
# Parses logs and processes any detected scanners
```
- **Use case**: Manual forensics, cron jobs, immediate response

**`nftban_portscan_status()`** - Show comprehensive status
```bash
nftban portscan status

# Output:
# =======================================================
#   Port Scan Detection Status
# =======================================================
#
# Configuration:
#   Enabled: 1
#   Threshold: 10 ports
#   Time Window: 300 seconds
#   Auto-Ban: 1
#   Ban Type: temporary
#   Ban Duration: 3600 seconds
#
# Tracking:
#   IPs Currently Tracked: 3
#
#   Top Active IPs:
#     203.0.113.100: 8 ports
#     203.0.113.200: 5 ports
#     203.0.113.50: 2 ports
#
# Recent Detections:
#   [2025-10-22 14:30:15] Port scanner detected: 203.0.113.100 (accessed 12 ports)
```

**`nftban_portscan_check_ip_manual(ip)`** - Check specific IP status
```bash
nftban portscan check 203.0.113.100

# Output:
# Checking IP: 203.0.113.100
#
# Status: BEING TRACKED
# Ports Accessed: 8
# Time Elapsed: 180 seconds
# Ports: 22,80,443,8080,3306,5432,27017,6379
#
# ℹ️  2 more ports until detection threshold
```

**`nftban_portscan_stats()`** - Show detection statistics
```bash
nftban portscan stats

# Output:
# =======================================================
#   Port Scan Detection Statistics
# =======================================================
#
# Detection Summary:
#   Total Detections: 47
#   Today: 3
#
# Current Tracking:
#   Active IPs: 2
#
# Configuration:
#   Threshold: 10 ports
#   Time Window: 300s
#   Auto-Ban: 1
```

---

### nftables Integration

**`nftban_portscan_setup_nftables_logging()`** - Add logging rules
```bash
# Creates logging rules for closed ports (where port scans hit)
# Rules added to both IPv4 and IPv6 input chains
```

**Example nftables rule (added by module):**
```nft
# IPv4 table
nft insert rule ip nftban_v4 input \
    ct state new \
    limit rate 10/minute burst 5 packets \
    log prefix "nftban: portscan: "

# IPv6 table
nft insert rule ip6 nftban_v6 input \
    ct state new \
    limit rate 10/minute burst 5 packets \
    log prefix "nftban: portscan: "
```
- **Rate limiting**: Prevents log flooding (10/minute max, burst 5)
- **State filter**: Only logs NEW connections (prevents duplicates)
- **Split tables**: Supports v0.9.0+ dual-table architecture

**`nftban_portscan_remove_nftables_logging()`** - Remove logging rules
```bash
# Removes all rules containing "nftban: portscan:" log prefix
# Iterates through handles to avoid partial deletions
```

---

## Configuration

**Files:**
- `/etc/nftban/portscan.conf` - Main configuration
- `/etc/nftban/portscan.conf.local` - User overrides (takes precedence)
- `/etc/nftban/portscan_whitelist.conf` - Module-specific whitelist
- `/var/log/nftban/portscan-detection.log` - Detection log
- `/var/lib/nftban/portscan-tracking/` - Tracking data directory

### Detection Settings

```bash
# Enable/disable detection
PORTSCAN_ENABLED="1"

# Detection threshold (distinct ports accessed)
PORTSCAN_THRESHOLD="10"

# Time window in seconds
PORTSCAN_TIME_WINDOW="300"

# Auto-ban detected scanners
PORTSCAN_AUTO_BAN="1"

# Ban type: "temporary" or "permanent"
PORTSCAN_BAN_TYPE="temporary"

# Ban duration for temporary bans (seconds)
PORTSCAN_BAN_TIME="3600"
```

### Logging Settings

```bash
# Enable nftables logging rules
PORTSCAN_USE_NFTABLES_LOG="1"

# Log prefix for nftables rules
PORTSCAN_NFT_LOG_PREFIX="nftban: portscan: "
```

### Alert Settings

```bash
# Enable email alerts
PORTSCAN_EMAIL_ALERTS="1"

# Alert recipient (defaults to NFTBAN_F2B_RECIPIENT)
PORTSCAN_REPORT_EMAIL="admin@example.com"
```

---

## CLI Integration

```bash
# Enable detection
nftban portscan enable

# Disable detection
nftban portscan disable

# Show status
nftban portscan status

# Check specific IP
nftban portscan check 203.0.113.100

# Run manual detection check
nftban portscan check

# Show statistics
nftban portscan stats
```

---

## Detection Workflow

### 1. nftables Logging
```
Incoming packet → nftables input chain → Logged if NEW connection → Kernel log
```

### 2. Log Parsing
```
Kernel log → parse_nftables_log() → Extract SRC/DPT → Filter whitelisted
```

### 3. Tracking
```
record_access(ip, port) → Update in-memory tracking → Increment distinct port count
```

### 4. Detection
```
check_ip(ip) → Compare count vs threshold → Return true if exceeded
```

### 5. Response
```
handle_detected_scanner(ip) → Log + Email + Auto-ban → Clear tracking
```

---

## Testing

### Test 1: Manual Port Scan Detection

```bash
# Enable detection
nftban portscan enable

# Simulate port scan from test machine
for port in 22 80 443 8080 3306 5432 6379 27017 9200 5601 3000 8000; do
    nc -zv target.example.com $port 2>/dev/null &
done
sleep 2

# Check if detected
nftban portscan check
nftban portscan status
```

### Test 2: Threshold Testing

```bash
# Set low threshold for testing
echo 'PORTSCAN_THRESHOLD="5"' >> /etc/nftban/portscan.conf.local

# Enable with low threshold
nftban portscan enable

# Scan 6 ports (exceeds threshold)
nmap -F target.example.com

# Verify detection
nftban portscan stats
```

### Test 3: Whitelist Exemption

```bash
# Add test IP to whitelist
echo "192.168.1.100  # Testing scanner" >> /etc/nftban/portscan_whitelist.conf

# Verify exemption
nftban portscan check 192.168.1.100
# Output: Status: WHITELISTED (will not be detected)

# Scan from whitelisted IP (should NOT be detected)
ssh user@target "nmap -F localhost"
```

### Test 4: Time Window Expiration

```bash
# Set short time window
echo 'PORTSCAN_TIME_WINDOW="60"' >> /etc/nftban/portscan.conf.local

# Scan 5 ports
for port in 22 80 443 8080 3306; do nc -zv target $port; done
nftban portscan check 192.168.1.50
# Output: Status: BEING TRACKED, Ports Accessed: 5

# Wait for window to expire
sleep 70

# Tracking should be reset
nftban portscan check 192.168.1.50
# Output: Status: NOT TRACKED
```

---

## Performance

- **Memory**: ~200 bytes per tracked IP (3 associative array entries)
- **Log parsing**: Processes 1000 lines in ~0.5 seconds
- **nftables overhead**: Minimal (rate-limited logging)
- **Cleanup**: Automatic removal of data older than 10 minutes

### Benchmarks

```bash
# Tracking 100 IPs with 10 ports each
# Memory: ~20KB
# Lookup time: O(1) for check_ip()
# Parse time: ~0.5s for 1000 log lines
```

---

## Troubleshooting

### Issue 1: No Port Scans Detected

**Symptoms**: Status shows 0 detections, logs show scan activity

**Causes**:
1. Detection disabled in config
2. nftables logging rules not present
3. Wrong log file path
4. Threshold too high

**Solutions**:
```bash
# Verify enabled
grep PORTSCAN_ENABLED /etc/nftban/portscan.conf

# Check nftables rules
nft list chain ip nftban_v4 input | grep "nftban: portscan:"

# Verify log file
ls -l /var/log/kern.log /var/log/messages /var/log/syslog

# Lower threshold for testing
echo 'PORTSCAN_THRESHOLD="5"' >> /etc/nftban/portscan.conf.local
```

### Issue 2: False Positives

**Symptoms**: Legitimate IPs flagged as scanners

**Causes**:
1. Threshold too low
2. Application probes multiple ports (monitoring tools)
3. Time window too long

**Solutions**:
```bash
# Whitelist legitimate scanners
echo "10.0.0.50  # Nagios monitoring" >> /etc/nftban/portscan_whitelist.conf

# Increase threshold
echo 'PORTSCAN_THRESHOLD="20"' >> /etc/nftban/portscan.conf.local

# Shorten time window
echo 'PORTSCAN_TIME_WINDOW="120"' >> /etc/nftban/portscan.conf.local
```

### Issue 3: Log Flooding

**Symptoms**: Kernel log fills with port scan entries

**Causes**:
1. nftables rate limit too high
2. Active port scan in progress

**Solutions**:
```bash
# Check current rate limit
nft list chain ip nftban_v4 input | grep "nftban: portscan:" | grep limit

# Reduce rate limit (manually edit rule)
# Default: 10/minute burst 5 packets
# Reduce to: 5/minute burst 3 packets

# Temporarily disable logging
nftban portscan disable
```

### Issue 4: Memory Leak

**Symptoms**: Tracking array grows indefinitely

**Causes**: Cleanup not running (tracking init not called)

**Solutions**:
```bash
# Manual cleanup
find /var/lib/nftban/portscan-tracking -type f -mmin +10 -delete

# Restart detection
nftban portscan disable
nftban portscan enable

# Verify cleanup in cron
# Add to /etc/cron.hourly/nftban-cleanup:
#!/bin/bash
find /var/lib/nftban/portscan-tracking -type f -mmin +10 -delete 2>/dev/null
```

---

## Security Considerations

### Attack Scenarios

**Scenario 1: Slow Port Scan (Below Threshold)**
- **Attack**: Scanner accesses 9 ports in 300 seconds (below default threshold of 10)
- **Detection**: Not triggered
- **Mitigation**: Lower threshold to 5-7 ports for sensitive systems

**Scenario 2: Distributed Port Scan**
- **Attack**: Multiple IPs each scan 5 ports (total 100 ports scanned)
- **Detection**: Each IP below threshold
- **Mitigation**: Use Feeds Module to import threat intelligence for known scanner IPs

**Scenario 3: Time Window Evasion**
- **Attack**: Scanner waits 301 seconds between batches of 9 ports
- **Detection**: Tracking resets between scans
- **Mitigation**: Increase time window to 600-900 seconds, use Fail2Ban for persistent attempts

**Scenario 4: Whitelist Bypass**
- **Attack**: Attacker spoofs IP of whitelisted system
- **Detection**: Whitelisted IP not flagged
- **Mitigation**: Use strict whitelist policies, monitor whitelist changes, implement network-level anti-spoofing

---

## Integration with Other Modules

### With Fail2Ban Module
```bash
# Port scan triggers Fail2Ban jail
# /etc/fail2ban/filter.d/nftban-portscan.conf
[Definition]
failregex = ^.*Port scanner detected: <HOST>.*$
ignoreregex =

# /etc/fail2ban/jail.d/nftban-portscan.conf
[nftban-portscan]
enabled = true
filter = nftban-portscan
logpath = /var/log/nftban/portscan-detection.log
bantime = 86400
findtime = 3600
maxretry = 1
```

### With Feeds Module
```bash
# Import known scanner IPs from threat feeds
nftban feeds enable
nftban feeds update

# Scanner IPs auto-banned before they can complete scan
```

### With Stats Module
```bash
# View port scan statistics
nftban stats portscan

# Historical analysis
nftban stats history --type=portscan --days=30
```

---

## Best Practices

### Production Deployment

1. **Tuning Phase** (first 7 days):
   - Set threshold to 15-20 ports
   - Enable monitoring mode (auto-ban off)
   - Review false positives daily
   - Whitelist legitimate scanners

2. **Active Phase** (after tuning):
   - Reduce threshold to 8-12 ports
   - Enable auto-ban with temporary bans
   - Set ban time to 3600-7200 seconds
   - Monitor alert emails

3. **Hardened Phase** (high-security systems):
   - Threshold: 5-7 ports
   - Permanent bans for repeat scanners
   - Integrate with threat feeds
   - Enable strict whitelisting

### Recommended Settings

**Web Server:**
```bash
PORTSCAN_THRESHOLD="12"
PORTSCAN_TIME_WINDOW="300"
PORTSCAN_AUTO_BAN="1"
PORTSCAN_BAN_TYPE="temporary"
PORTSCAN_BAN_TIME="3600"
```

**Database Server:**
```bash
PORTSCAN_THRESHOLD="8"
PORTSCAN_TIME_WINDOW="180"
PORTSCAN_AUTO_BAN="1"
PORTSCAN_BAN_TYPE="permanent"
```

**Development Server:**
```bash
PORTSCAN_THRESHOLD="20"
PORTSCAN_TIME_WINDOW="600"
PORTSCAN_AUTO_BAN="0"  # Monitoring only
PORTSCAN_EMAIL_ALERTS="1"
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
