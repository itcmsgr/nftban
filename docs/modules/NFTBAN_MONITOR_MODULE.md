# NFTBan System Monitor Module

**Module:** `nftban_monitoring_module.sh` | **Version:** 0.9.3-dev | **Location:** `/usr/local/lib/nftban/`

## Overview

The System Monitor Module provides multi-level resource monitoring with sustained violation tracking and email alerts. It monitors disk space, memory usage, CPU load, and inode consumption with configurable thresholds (WARNING, CRITICAL, EMERGENCY) and duration requirements to prevent false positives.

### Key Features

- **4 Resource Monitors**: Disk, Memory, CPU, Inodes
- **3-Level Thresholds**: WARNING (80%), CRITICAL (90%), EMERGENCY (95%)
- **Sustained Violation Tracking**: Requires threshold exceeded for duration before alerting
- **Alert Cooldown**: Prevents email spam (1-hour default between alerts)
- **State Persistence**: Tracks violation start times across monitoring cycles
- **Email Alerts**: Detailed alerts with top resource consumers
- **Multi-Filesystem**: Monitors /, /var, /tmp, /home automatically

### Dependencies

- **Core Module**: For email and logging functions
- **System tools**: `df`, `free`, `top`, `ps`

---

## API Reference

### Initialization

**`nftban_monitor_init_state()`** - Initialize state directory
```bash
# Creates:
# - /etc/nftban/data/monitoring/ (state files)
# - /var/log/nftban/monitoring.log
```

### Disk Monitoring

**`nftban_monitor_check_disk()`** - Check disk space on all filesystems
```bash
nftban monitor check-disk

# Checks: /, /var, /tmp, /home
# Thresholds: 80% (warn), 90% (crit), 95% (emerg)

# Email alert example:
# Subject: [nftban] CRITICAL: Disk space 92% on server.example.com
# Body:
#   Filesystem: /var
#   Used: 92% (184G / 200G)
#   Available: 16G
#   Threshold: crit (90%)
#   Server: server.example.com
#   Time: 2025-10-23T14:30:15+00:00
#
#   Action: Consider cleanup of old logs, backups, or temporary files.
```
- **Instant alerts**: No duration requirement (disk full is immediate)
- **Per-filesystem**: Independent alerts for each filesystem

### Memory Monitoring

**`nftban_monitor_check_memory()`** - Check memory usage with sustained tracking
```bash
# Thresholds: 80% (warn), 90% (crit), 95% (emerg)
# Duration requirements:
#   WARNING: 5 minutes
#   CRITICAL: 5 minutes
#   EMERGENCY: 3 minutes

# Only alerts if threshold exceeded for full duration
```
- **Sustained tracking**: Prevents alerts for transient spikes
- **State files**: `/etc/nftban/data/monitoring/memory_warn.state`
- **Top consumers**: Email includes top 5 memory-using processes

### CPU Monitoring

**`nftban_monitor_check_cpu()`** - Check CPU usage with sustained tracking
```bash
# Thresholds: 80% (warn), 90% (crit), 95% (emerg)
# Duration requirements:
#   WARNING: 10 minutes
#   CRITICAL: 5 minutes
#   EMERGENCY: 3 minutes
```
- **Load average**: Included in alert emails
- **Top consumers**: Email includes top 5 CPU-using processes

### Inode Monitoring

**`nftban_monitor_check_inodes()`** - Check inode usage
```bash
# Checks filesystem inode exhaustion
# Common with many small files (/tmp, /var/spool, session dirs)

# Alert example:
# Subject: [nftban] WARNING: Inode usage 85% on server.example.com
# Body:
#   Filesystem: /var
#   Inode Usage: 85%
#   Total Inodes: 1,000,000
#   Used Inodes: 850,000
#   Available Inodes: 150,000
#
#   Action: Clean up directories with many small files.
#   Common culprits: /tmp, /var/spool, session directories.
```

### Main Monitoring

**`nftban_monitor_run()`** - Run all monitoring checks
```bash
nftban monitor run

# Starting monitoring check...
# Monitoring check complete: All systems normal

# Or with issues:
# Monitoring check complete: 2 issue(s) detected
```
- **Runs all checks**: Disk, Memory, CPU, Inodes
- **Return code**: 0 (all normal), >0 (issues detected)

### Status Display

**`nftban_monitor_status()`** - Show current system status
```bash
nftban monitor status

# === NFTBan System Monitoring Status ===
#
# Disk Space:
#   Mounted on           Size       Used      Avail   Use%
#   /                    50G        30G       18G     63%
#   /var                 200G       184G      16G     92%
#   /tmp                 10G        2G        8G      20%
#   /home                500G       350G      150G    70%
#
# Memory Usage:
#                total        used        free      shared  buff/cache   available
#   Mem:          32Gi        24Gi       1.5Gi       128Mi        6.5Gi        7.8Gi
#
# CPU & Load Average:
#   Load: 2.15, 1.98, 1.85
#   CPU: 15.2% user, 5.1% system, 79.7% idle
#
# Inode Usage:
#   Mounted on           Inodes      IUsed       IFree   IUse%
#   /                    1000000     450000      550000   45%
#   /var                 1000000     850000      150000   85%
#
# Alert Thresholds:
#   Disk:   80% / 90% / 95% (warn/crit/emerg)
#   Memory: 80% / 90% / 95% (warn/crit/emerg)
#   CPU:    80% / 90% / 95% (warn/crit/emerg)
#   Inodes: 80% / 90% / 95% (warn/crit/emerg)
#
# Duration Requirements (sustained before alert):
#   Memory: 5m / 5m / 3m
#   CPU:    10m / 5m / 3m
```

---

## Configuration

**Global Settings** (`/etc/nftban/nftban.conf`):

```bash
# Disk thresholds (percentage)
NFTBAN_MONITOR_DISK_WARN=80
NFTBAN_MONITOR_DISK_CRIT=90
NFTBAN_MONITOR_DISK_EMERG=95

# Memory thresholds (percentage)
NFTBAN_MONITOR_MEM_WARN=80
NFTBAN_MONITOR_MEM_CRIT=90
NFTBAN_MONITOR_MEM_EMERG=95

# CPU thresholds (percentage)
NFTBAN_MONITOR_CPU_WARN=80
NFTBAN_MONITOR_CPU_CRIT=90
NFTBAN_MONITOR_CPU_EMERG=95

# Inode thresholds (percentage)
NFTBAN_MONITOR_INODE_WARN=80
NFTBAN_MONITOR_INODE_CRIT=90
NFTBAN_MONITOR_INODE_EMERG=95

# Duration thresholds (seconds) - sustained violations before alerting
NFTBAN_MONITOR_MEM_DURATION_WARN=300   # 5 minutes
NFTBAN_MONITOR_MEM_DURATION_CRIT=300   # 5 minutes
NFTBAN_MONITOR_MEM_DURATION_EMERG=180  # 3 minutes

NFTBAN_MONITOR_CPU_DURATION_WARN=600   # 10 minutes
NFTBAN_MONITOR_CPU_DURATION_CRIT=300   # 5 minutes
NFTBAN_MONITOR_CPU_DURATION_EMERG=180  # 3 minutes

# Alert cooldown (seconds) - prevent alert spam
NFTBAN_MONITOR_ALERT_COOLDOWN=3600  # 1 hour
```

**State Files** (`/etc/nftban/data/monitoring/`):
```
memory_warn.state     # Timestamp of first WARNING threshold violation
memory_crit.state     # Timestamp of first CRITICAL threshold violation
memory_emerg.state    # Timestamp of first EMERGENCY threshold violation
cpu_warn.state
cpu_crit.state
cpu_emerg.state
disk__var_warn.state  # Per-filesystem states
```

**Alert Tracking** (`/etc/nftban/data/monitoring/`):
```
memory_warn.alert     # Timestamp of last alert sent
memory_crit.alert
cpu_warn.alert
disk__var_crit.alert
```

**Log File**: `/var/log/nftban/monitoring.log`

---

## CLI Integration

```bash
# Run all checks
nftban monitor run
nftban monitor check

# Show current status
nftban monitor status

# Individual checks (internal)
nftban_monitor_check_disk
nftban_monitor_check_memory
nftban_monitor_check_cpu
nftban_monitor_check_inodes
```

---

## Sustained Violation Tracking

### How It Works

1. **First violation detected**:
   ```bash
   # Memory usage: 92% (CRITICAL threshold: 90%)
   # State file created: memory_crit.state with current timestamp
   # Log: "Memory crit threshold reached: 92% (tracking duration)"
   ```

2. **Subsequent checks**:
   ```bash
   # Memory still at 92%
   # Calculate duration: current_time - state_file_timestamp
   # Log: "Memory crit ongoing: 92% for 180s (need 300s)"
   ```

3. **Duration requirement met**:
   ```bash
   # Duration: 305 seconds (>300s requirement)
   # Send email alert
   # Update last alert timestamp (cooldown tracking)
   ```

4. **Threshold drops below**:
   ```bash
   # Memory usage: 85% (below CRITICAL 90%)
   # Clear state file: memory_crit.state
   # Ready for new violations
   ```

### Benefits

- **No false positives**: Transient spikes don't trigger alerts
- **Actionable alerts**: If you get an alert, it's sustained and serious
- **Appropriate urgency**: Longer durations for WARNING, shorter for EMERGENCY

---

## Testing

### Test 1: Disk Space Alert

```bash
# Create test file to fill disk
dd if=/dev/zero of=/var/testfile bs=1M count=50000

# Run monitor
nftban monitor run

# Check logs
tail -20 /var/log/nftban/monitoring.log
# Should show: Disk space alerts: CRITICAL: /var at 92%

# Cleanup
rm -f /var/testfile
```

### Test 2: Sustained Memory Violation

```bash
# Lower memory threshold for testing
echo 'NFTBAN_MONITOR_MEM_WARN=20' >> /etc/nftban/nftban.conf
echo 'NFTBAN_MONITOR_MEM_DURATION_WARN=60' >> /etc/nftban/nftban.conf

# Run monitor multiple times (1 minute apart)
nftban monitor run
# First run: "Memory warn threshold reached: 75% (tracking duration)"

sleep 60

nftban monitor run
# Second run: Alert sent if still above 20%
```

### Test 3: Alert Cooldown

```bash
# Trigger alert
nftban monitor run
# Alert sent: [nftban] WARNING: Disk space 85%

# Immediately run again
nftban monitor run
# Alert suppressed (cooldown): [nftban] WARNING: Disk space 85%

# Check last alert timestamp
cat /etc/nftban/data/monitoring/disk__var_warn.alert
# Unix timestamp of last alert
```

### Test 4: Status Display

```bash
# View current system status
nftban monitor status

# Verify all sections displayed:
# - Disk Space (df -h output)
# - Memory Usage (free -h output)
# - CPU & Load (uptime + top)
# - Inode Usage (df -i output)
# - Alert Thresholds
# - Duration Requirements
```

---

## systemd Timer Setup (Optional)

**Create service** (`/etc/systemd/system/nftban-monitor.service`):
```ini
[Unit]
Description=NFTBan System Monitor
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/nftban monitor run
User=root
```

**Create timer** (`/etc/systemd/system/nftban-monitor.timer`):
```ini
[Unit]
Description=NFTBan System Monitor Timer

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=1s

[Install]
WantedBy=timers.target
```

**Enable**:
```bash
systemctl daemon-reload
systemctl enable --now nftban-monitor.timer

# Check status
systemctl status nftban-monitor.timer
systemctl list-timers nftban-monitor.timer
```

---

## Troubleshooting

### Issue 1: Alerts Not Sent

**Symptoms**: Threshold exceeded but no email

**Solutions**:
```bash
# Check email function configured
grep NFTBAN_EMAIL /etc/nftban/nftban.conf

# Test email manually
echo "test" | mail -s "Test" admin@example.com

# Check monitoring log
tail -50 /var/log/nftban/monitoring.log

# Verify duration requirement met
cat /etc/nftban/data/monitoring/memory_warn.state
# Compare timestamp to current time
```

### Issue 2: State Files Accumulating

**Symptoms**: Many .state files in monitoring directory

**Solutions**:
```bash
# This is normal - states track ongoing violations
# Old states should auto-clear when thresholds drop

# Manual cleanup if needed
rm -f /etc/nftban/data/monitoring/*.state

# Next monitor run will recreate if still violated
```

### Issue 3: False Positives Despite Duration

**Symptoms**: Alerts for brief spikes

**Solutions**:
```bash
# Increase duration requirements
echo 'NFTBAN_MONITOR_MEM_DURATION_WARN=600' >> /etc/nftban/nftban.conf  # 10 minutes
echo 'NFTBAN_MONITOR_CPU_DURATION_WARN=1200' >> /etc/nftban/nftban.conf  # 20 minutes

# Or increase thresholds
echo 'NFTBAN_MONITOR_MEM_WARN=85' >> /etc/nftban/nftban.conf
```

### Issue 4: Too Many Alert Emails

**Symptoms**: Email spam during sustained issues

**Solutions**:
```bash
# Increase cooldown period
echo 'NFTBAN_MONITOR_ALERT_COOLDOWN=7200' >> /etc/nftban/nftban.conf  # 2 hours

# Or disable specific alerts
echo 'NFTBAN_MONITOR_DISK_WARN=95' >> /etc/nftban/nftban.conf  # Only alert at 95%
```

---

## Best Practices

1. **Tune Thresholds for Your Environment**:
   ```bash
   # High-traffic servers: Higher thresholds
   NFTBAN_MONITOR_MEM_WARN=85
   NFTBAN_MONITOR_CPU_WARN=90

   # Critical systems: Lower thresholds
   NFTBAN_MONITOR_MEM_WARN=70
   NFTBAN_MONITOR_DISK_CRIT=85
   ```

2. **Set Appropriate Durations**:
   ```bash
   # Batch processing servers: Longer durations
   NFTBAN_MONITOR_CPU_DURATION_WARN=1800  # 30 minutes

   # Web servers: Shorter durations
   NFTBAN_MONITOR_MEM_DURATION_CRIT=180  # 3 minutes
   ```

3. **Monitor Logs Regularly**:
   ```bash
   # Check for threshold violations
   tail -f /var/log/nftban/monitoring.log
   ```

4. **Test Email Alerts**:
   ```bash
   # Manually trigger alert for testing
   # Lower threshold temporarily
   echo 'NFTBAN_MONITOR_DISK_WARN=50' >> /etc/nftban/nftban.conf
   nftban monitor run
   ```

5. **Automated Monitoring**:
   ```bash
   # Use systemd timer (every 5 minutes)
   # Or cron:
   */5 * * * * /usr/local/bin/nftban monitor run
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
