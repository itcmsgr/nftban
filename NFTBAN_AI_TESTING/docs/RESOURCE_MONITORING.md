# NFTBan v0.30 - System Resource Monitoring

**Feature:** Automatic monitoring of disk, CPU, RAM, and system resources
**Status:** ✅ Integrated into health checks
**Effort:** Low (small feature, high value)

---

## Overview

NFTBan v0.30 includes comprehensive system resource monitoring as part of the health check system. This feature automatically monitors critical resources and can send alerts when thresholds are exceeded.

---

## What's Monitored

### 1. **Disk Usage**
- **Filesystems:** `/`, `/var`, `/var/log`, `/tmp`
- **Metrics:** Space usage percentage
- **Default Thresholds:**
  - Warning: 85%
  - Critical: 95%

### 2. **Inode Usage**
- **Why:** Can cause issues even with free disk space
- **Filesystems:** Same as disk usage
- **Default Thresholds:**
  - Warning: 85%
  - Critical: 95%

### 3. **Memory (RAM)**
- **Metrics:** RAM usage based on available memory
- **Default Thresholds:**
  - Warning: 90%
  - Critical: 95%

### 4. **Swap Usage**
- **Why:** High swap indicates memory pressure
- **Default Threshold:**
  - Warning: 75%

### 5. **CPU Load**
- **Metrics:** 1-minute load average as percentage of CPU cores
- **Example:** On 4-core system, 80% = load of 3.2
- **Default Thresholds:**
  - Warning: 80%
  - Critical: 95%

---

## Configuration

### File Location
```
/etc/nftban/conf.d/health.conf
```

### Default Settings
```bash
# Disk thresholds
NFTBAN_DISK_WARN_THRESHOLD=85
NFTBAN_DISK_CRIT_THRESHOLD=95

# RAM thresholds
NFTBAN_RAM_WARN_THRESHOLD=90
NFTBAN_RAM_CRIT_THRESHOLD=95

# CPU thresholds
NFTBAN_CPU_WARN_THRESHOLD=80
NFTBAN_CPU_CRIT_THRESHOLD=95

# Alert throttling (prevent spam)
NFTBAN_ALERT_THROTTLE_SECONDS=3600    # 1 hour
NFTBAN_ALERT_MAX_PER_DAY=24           # Max once per hour
```

### Override with .local File
```bash
# Create local override
cat > /etc/nftban/conf.d/health.conf.local <<EOF
# Custom thresholds for production
NFTBAN_DISK_WARN_THRESHOLD=80
NFTBAN_DISK_CRIT_THRESHOLD=90
NFTBAN_RAM_WARN_THRESHOLD=85
NFTBAN_ALERT_THROTTLE_SECONDS=7200   # 2 hours
EOF
```

---

## Alert Throttling

### Problem
Without throttling, you could receive alerts every minute for the same issue.

### Solution
**Smart Alert Throttling:**
- Only send 1 alert per issue per hour (configurable)
- State tracking in `/var/lib/nftban/state/health_alerts.state`
- Automatic cleanup of old alerts (24 hours)

### How It Works
```
Time 00:00 - Disk at 90% → Alert sent ✉️
Time 00:15 - Disk at 91% → Throttled (too soon) 🚫
Time 00:30 - Disk at 92% → Throttled (too soon) 🚫
Time 01:00 - Disk at 93% → Alert sent ✉️
```

### Configuration
```bash
# Send alerts at most once every 2 hours
NFTBAN_ALERT_THROTTLE_SECONDS=7200

# Maximum 12 alerts per day
NFTBAN_ALERT_MAX_PER_DAY=12
```

---

## Usage

### Manual Check
```bash
# Check resources as part of health check
nftban health check

# View detailed resource status
nftban-health --inventory | jq '.resources'
```

### Automated Monitoring
```bash
# Enable health timer (includes resource checks)
systemctl enable --now nftban-health.timer

# Check timer status
systemctl status nftban-health.timer

# View recent checks
journalctl -u nftban-health.service -n 50
```

### Example Output
```
════════════════════════════════════════════════════════════
  NFTBan Health Check
════════════════════════════════════════════════════════════

✓ Binaries: OK
⚠ Resources: WARNING
  - WARNING: / disk usage at 87%
  - WARNING: RAM usage at 92%
✓ GeoIP: OK
✓ v0.30 Helpers: All helpers OK (4/4)
✓ Services: OK

Overall Status: WARNING
```

---

## Alert Integration

### With Mail System
Resource alerts integrate with NFTBan's smart mail adapter:

```bash
# Configure mail (if not already done)
cat > /etc/nftban/conf.d/mail.conf <<EOF
NFTBAN_MAIL_ENABLED=1
NFTBAN_MAIL_TO="admin@example.com"
NFTBAN_MAIL_FROM="nftban@$(hostname)"
EOF

# Test alert
nftban-health --alert
```

### Alert Format
```
Subject: [NFTBan Alert] System Resources - WARNING

Server: production.example.com
Time: 2025-11-03 15:30:00 UTC
Status: WARNING

Resource Issues:
- WARNING: / disk usage at 87%
- WARNING: RAM usage at 92%

Action Required:
- Review disk usage: df -h /
- Review memory usage: free -h
- Consider cleanup or scaling

Next alert in: 1 hour (throttled)
```

---

## Threshold Examples

### Conservative (Production)
```bash
NFTBAN_DISK_WARN_THRESHOLD=80
NFTBAN_DISK_CRIT_THRESHOLD=90
NFTBAN_RAM_WARN_THRESHOLD=85
NFTBAN_RAM_CRIT_THRESHOLD=93
NFTBAN_CPU_WARN_THRESHOLD=75
NFTBAN_CPU_CRIT_THRESHOLD=90
NFTBAN_ALERT_THROTTLE_SECONDS=7200  # 2 hours
```

### Balanced (Default)
```bash
NFTBAN_DISK_WARN_THRESHOLD=85
NFTBAN_DISK_CRIT_THRESHOLD=95
NFTBAN_RAM_WARN_THRESHOLD=90
NFTBAN_RAM_CRIT_THRESHOLD=95
NFTBAN_CPU_WARN_THRESHOLD=80
NFTBAN_CPU_CRIT_THRESHOLD=95
NFTBAN_ALERT_THROTTLE_SECONDS=3600  # 1 hour
```

### Relaxed (Development)
```bash
NFTBAN_DISK_WARN_THRESHOLD=90
NFTBAN_DISK_CRIT_THRESHOLD=98
NFTBAN_RAM_WARN_THRESHOLD=93
NFTBAN_RAM_CRIT_THRESHOLD=98
NFTBAN_CPU_WARN_THRESHOLD=85
NFTBAN_CPU_CRIT_THRESHOLD=98
NFTBAN_ALERT_THROTTLE_SECONDS=1800  # 30 minutes
```

---

## Technical Details

### Function: `nftban_health_check_resources()`

**Location:** `/usr/lib/nftban/core/nftban_health.sh`

**Checks Performed:**
1. Disk usage for critical mount points
2. Inode usage (prevents "no space" errors with free disk)
3. Memory usage (using available memory metric)
4. Swap usage (indicates memory pressure)
5. CPU load average (normalized by core count)

**Return Codes:**
- `0` = All resources OK
- `1` = Warning threshold exceeded
- `2` = Critical threshold exceeded

### Function: `nftban_health_should_alert()`

**Purpose:** Prevent alert spam

**Algorithm:**
1. Load throttle configuration
2. Check state file for last alert time
3. If too soon (< throttle seconds), return 1 (throttled)
4. If OK to alert, update state file and return 0
5. Clean up alerts older than 24 hours

**State File:** `/var/lib/nftban/state/health_alerts.state`

**Format:**
```
alert_key:timestamp
disk_root:1730649600
ram_usage:1730653200
```

---

## Integration Points

### 1. Health Check System
- Integrated into `nftban_health_check_all()`
- Runs automatically with `nftban health check`
- Results stored in `NFTBAN_HEALTH_RESULTS["resources"]`

### 2. Timer System
- Executes via `nftban-health.timer`
- Default: Every hour
- Configurable via systemd timer

### 3. Alert System
- Uses `nftban-health --alert`
- Sends via mail adapter
- Throttling prevents spam

### 4. Inventory System
- Resource status included in `--inventory` JSON
- Baseline comparison for trending
- Historical tracking

---

## Troubleshooting

### No Alerts Received
```bash
# Check configuration
cat /etc/nftban/conf.d/health.conf

# Check mail system
source /usr/lib/nftban/core/nftban_mail_v030.sh
nftban_v030_mail_info

# Check alert state
cat /var/lib/nftban/state/health_alerts.state

# Manual test
nftban-health --alert
```

### Too Many Alerts
```bash
# Increase throttle time
echo "NFTBAN_ALERT_THROTTLE_SECONDS=7200" >> /etc/nftban/conf.d/health.conf.local

# Or adjust thresholds higher
echo "NFTBAN_DISK_WARN_THRESHOLD=90" >> /etc/nftban/conf.d/health.conf.local
```

### False Positives
```bash
# Check actual resource usage
df -h
free -h
cat /proc/loadavg
nproc

# Adjust thresholds for your environment
vim /etc/nftban/conf.d/health.conf.local
```

---

## Benefits

### 1. **Proactive Monitoring**
- Catch issues before they become critical
- Prevent service outages
- Better capacity planning

### 2. **Low Overhead**
- Minimal CPU/memory impact
- Built-in throttling
- Efficient state tracking

### 3. **Easy Configuration**
- Sensible defaults
- Override with .local files
- Per-environment customization

### 4. **Smart Alerting**
- No alert spam
- Configurable frequency
- Automatic cleanup

### 5. **Integration**
- Works with existing health system
- Uses existing mail system
- Part of automated monitoring

---

## Best Practices

### 1. **Start Conservative**
Use default thresholds initially, then adjust based on your environment.

### 2. **Use .local Files**
Override defaults with `.local` files to preserve upgrades:
```bash
/etc/nftban/conf.d/health.conf        # Default (don't edit)
/etc/nftban/conf.d/health.conf.local  # Your overrides
```

### 3. **Monitor the Monitors**
```bash
# Check health timer is running
systemctl status nftban-health.timer

# Review recent alerts
journalctl -u nftban-health.service --since "24 hours ago"
```

### 4. **Test Alerting**
```bash
# Temporarily lower threshold to trigger alert
export NFTBAN_DISK_WARN_THRESHOLD=10
nftban-health --alert
```

### 5. **Document Your Thresholds**
Keep notes on why you chose specific thresholds for your environment.

---

## Future Enhancements

Possible future additions (not in v0.30):
- [ ] Network bandwidth monitoring
- [ ] Process count limits
- [ ] Open file descriptor tracking
- [ ] Database connection monitoring
- [ ] Custom check plugins

---

## Summary

✅ **Implemented Features:**
- Disk usage monitoring (space + inodes)
- RAM usage monitoring
- CPU load monitoring
- Swap usage monitoring
- Configurable thresholds
- Alert throttling (no spam)
- Integration with health and mail systems

✅ **Configuration:**
- `/etc/nftban/conf.d/health.conf` - Main config
- `.local` override support
- Environment-specific customization

✅ **Zero Configuration Required:**
- Works out of the box with sensible defaults
- Customize only if needed

---

*NFTBan v0.30 - Smart Resource Monitoring, Zero Alert Spam* 🎯
