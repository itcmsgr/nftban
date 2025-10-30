# NFTBan 24-Hour Stability Monitoring Plan

**Start Date:** 2025-10-30 20:30 UTC
**End Date:** 2025-10-31 20:30 UTC
**Servers:** lab4.example.test (primary), lab.example.test, lab1.example.test, lab2.example.test

---

## Objectives

Monitor NFTBan v0.10.0 for 24 hours to verify:
- ✅ System stability
- ✅ Timer execution (health checks, permission audits)
- ✅ Polkit authorization (service management)
- ✅ Resource usage (CPU, memory, disk)
- ✅ Error rates and patterns
- ✅ FHS compliance maintenance

---

## Current Status (2025-10-30 20:30 UTC)

### lab4.example.test ✅ READY

**Installed:**
- NFTBan v0.10.0-1.el10.x86_64 (RPM)
- nftables v1.1.1
- fail2ban v1.1.0
- Go 1.24.6
- Polkit v125

**Services Running:**
- ✅ nftables (active)
- ✅ fail2ban (active)

**Timers Enabled:**
- ✅ nftban-health.timer (hourly, next run: 2025-10-31 00:28 UTC)
- ✅ nftban-permissions-audit.timer (weekly, next run: 2025-11-02 02:20 UTC)

**Health Status:**
- Modules: 25 OK, 0 errors
- Services: All OK
- FHS: 21/21 directories OK
- Minor warnings: GeoIP database not installed (optional)

**Test User:**
- testuser (member of nftban-cli group)
- Polkit authorization tested ✅ WORKING

---

## Monitoring Schedule

### Automatic Monitoring (via Timers)

| Time (UTC) | Action | Timer |
|------------|--------|-------|
| Every hour | Health check | nftban-health.timer |
| Sunday 02:00 | Permission audit | nftban-permissions-audit.timer |

### Manual Checks (Tomorrow Morning)

**2025-10-31 08:00-10:00 UTC:**
1. Review all timer execution logs
2. Check error counts
3. Verify Polkit activity
4. Analyze resource usage
5. Generate summary report

---

## What to Monitor

### 1. Timer Execution ✅

**Check:**
```bash
# View timer status
systemctl list-timers | grep nftban

# Check health service logs
journalctl -u nftban-health.service --since "24 hours ago"

# Check permission audit logs
journalctl -u nftban-permissions-audit.service --since "24 hours ago"
```

**Expected:**
- Health checks run every hour
- No errors in execution
- All checks report OK status

### 2. Polkit Authorization ✅

**Check:**
```bash
# Review Polkit activity
journalctl -u polkit --since "24 hours ago" | grep nftban

# Test as nftban-cli member
su - testuser
systemctl restart nftables  # Should work
systemctl restart sshd       # Should be denied
```

**Expected:**
- Polkit grants access to nftables/fail2ban
- Polkit denies access to other services
- No JavaScript errors in Polkit logs

### 3. System Stability ✅

**Check:**
```bash
# System load
uptime
cat /proc/loadavg

# Memory usage
free -h

# Disk usage
df -h | grep -E "(nftban|var|tmp)"

# Process list
ps aux | grep nftban
```

**Expected:**
- Load average normal for system
- Memory usage stable
- Disk usage not increasing unexpectedly
- No zombie processes

### 4. Error Rates ✅

**Check:**
```bash
# Count errors in last 24h
journalctl --since "24 hours ago" | grep -i "nftban" | grep -ci "error"

# View error details
journalctl --since "24 hours ago" -p err | grep nftban

# Check FHS errors
nftban fhs check | grep ERROR
```

**Expected:**
- Zero critical errors
- Warnings only for optional components (GeoIP, mail tools)
- FHS compliance maintained

### 5. Service Health ✅

**Check:**
```bash
# Full health check
nftban health check

# Service status
systemctl is-active nftables fail2ban

# Verify nftables rules
nft list table inet nftban 2>/dev/null || echo "Table not created yet (normal)"
```

**Expected:**
- All services active
- Health check passes (ignoring optional warnings)
- No unexpected service restarts

---

## Monitoring Commands

### Quick Health Check (Run Anytime)

```bash
ssh root@lab4.example.test '
echo "=== Quick Status Check ==="
echo "Time: $(date)"
echo ""
echo "Services:"
systemctl is-active nftables fail2ban nftban-health.timer
echo ""
echo "Last Health Check:"
journalctl -u nftban-health.service -n 20 --no-pager | tail -10
echo ""
echo "Errors (1h):"
journalctl --since "1 hour ago" -p err | grep -c nftban || echo "0"
echo ""
echo "Load:"
cat /proc/loadavg
'
```

### Full 24h Report (Run Tomorrow Morning)

```bash
ssh root@lab4.example.test '
echo "=== NFTBan 24-Hour Stability Report ==="
echo "Generated: $(date)"
echo "Monitoring Period: 2025-10-30 20:30 UTC to 2025-10-31 20:30 UTC"
echo ""

echo "=== Timer Execution Summary ==="
journalctl -u nftban-health.service --since "24 hours ago" --no-pager | \
  grep -c "Health check complete" && echo "health checks executed"

echo ""
echo "=== Error Analysis ==="
echo "Total errors (24h):"
journalctl --since "24 hours ago" -p err | grep -c nftban || echo "0"

echo ""
echo "=== Health Check Results ==="
nftban health check

echo ""
echo "=== FHS Compliance ==="
nftban fhs check | grep "Total directories"

echo ""
echo "=== Polkit Activity ==="
journalctl -u polkit --since "24 hours ago" | grep -c nftban && echo "Polkit authorizations"

echo ""
echo "=== Resource Usage ==="
echo "Load Average:"
cat /proc/loadavg
echo ""
echo "Memory:"
free -h | grep -E "(total|Mem)"
echo ""
echo "Disk (nftban areas):"
du -sh /var/lib/nftban /var/log/nftban /var/cache/nftban 2>/dev/null

echo ""
echo "=== Service Uptime ==="
systemctl show nftables fail2ban | grep ActiveEnterTimestamp
'
```

---

## Success Criteria

### ✅ Stability Confirmed If:

1. **Timer Execution:** ≥20 health checks completed successfully (1 per hour for 24h)
2. **Error Rate:** <5 errors total in 24 hours
3. **Service Uptime:** nftables and fail2ban running continuously
4. **Polkit Authorization:** No authorization failures for valid requests
5. **FHS Compliance:** 21/21 directories OK throughout monitoring period
6. **Resource Usage:**
   - Load average normal for system
   - Memory usage stable (no leaks)
   - Disk usage increase <100 MB

### ⚠️  Investigation Required If:

1. **Any service crashes or restarts unexpectedly**
2. **>10 errors in 24 hours**
3. **Timer fails to execute**
4. **Polkit authorization errors**
5. **FHS compliance degrades**
6. **Memory usage increases >50 MB**

---

## Current Baseline (2025-10-30 20:30 UTC)

```
System: lab4.example.test
OS: Rocky Linux 10.0 (Red Quartz)
Kernel: 6.17.5-200.fc42.x86_64

Load Average: (to be measured)
Memory Used: (to be measured)
Disk Usage:
  /var/lib/nftban: (to be measured)
  /var/log/nftban: (to be measured)

Services:
  nftables: active since 2025-10-30 20:21 UTC
  fail2ban: active since 2025-10-30 20:21 UTC

Timers:
  nftban-health.timer: enabled, next: 2025-10-31 00:28 UTC
  nftban-permissions-audit.timer: enabled, next: 2025-11-02 02:20 UTC

Health Status:
  Modules: 25 OK
  FHS: 21/21 OK
  Services: OK
  Warnings: GeoIP (optional), Binaries (go/mail not needed at runtime)
```

---

## Tomorrow's Tasks (2025-10-31)

### Morning (08:00-10:00 UTC)

1. **Collect 24h Logs**
   ```bash
   ./scripts/monitor-24h.sh lab4.example.test
   ```

2. **Analyze Results**
   - Review timer execution logs
   - Count errors and warnings
   - Check resource usage trends
   - Verify Polkit activity

3. **Generate Report**
   - Summary of all findings
   - Error analysis
   - Performance metrics
   - Recommendations

4. **Decision Point**
   - ✅ If stable: Deploy to other lab servers
   - ⚠️  If issues: Investigate and fix before wider deployment

### Afternoon (if stable)

5. **Deploy to Remaining Lab Servers**
   - lab.example.test
   - lab1.example.test
   - lab2.example.test

6. **Enable Monitoring on All Servers**

7. **Begin Multi-Server Stability Testing**

---

## Troubleshooting Guide

### Issue: Health Check Not Running

**Symptoms:** No logs from nftban-health.service

**Check:**
```bash
systemctl status nftban-health.timer
journalctl -u nftban-health.timer
```

**Fix:**
```bash
systemctl restart nftban-health.timer
systemctl list-timers | grep nftban
```

### Issue: Permission Errors

**Symptoms:** FHS check shows errors

**Check:**
```bash
nftban fhs check
journalctl -u nftban-permissions-audit.service
```

**Fix:**
```bash
nftban permissions enforce
nftban fhs check
```

### Issue: Polkit Denials

**Symptoms:** Service management fails for nftban-cli members

**Check:**
```bash
journalctl -u polkit | grep -i error
cat /usr/share/polkit-1/rules.d/60-nftban-cli.rules
```

**Fix:**
```bash
systemctl restart polkit
# Test again as testuser
su - testuser -c "systemctl restart nftables"
```

### Issue: High Resource Usage

**Symptoms:** Load average elevated, memory increasing

**Check:**
```bash
top -b -n 1 | head -20
ps aux | grep nftban
free -h
```

**Investigation:**
- Check for runaway processes
- Review recent timer executions
- Check log file sizes

---

## Monitoring Script Usage

### Created Script: `scripts/monitor-24h.sh`

**Purpose:** Automates 24-hour stability monitoring

**Usage:**
```bash
# Monitor single server
./scripts/monitor-24h.sh lab4.example.test

# Monitor all lab servers
./scripts/monitor-24h.sh all

# Continuous monitoring (every hour for 24h)
watch -n 3600 ./scripts/monitor-24h.sh all
```

**Output:**
- Individual server reports: `/tmp/nftban-24h-monitoring/[server]_[timestamp].log`
- Summary report: `/tmp/nftban-24h-monitoring/SUMMARY_[timestamp].md`

---

## Contact & Escalation

**Monitoring Period:** 2025-10-30 20:30 UTC to 2025-10-31 20:30 UTC

**Review Meeting:** 2025-10-31 08:00-10:00 UTC

**Decision Point:** 2025-10-31 12:00 UTC (deploy wider or investigate issues)

---

## Appendix: Test Results So Far

### lab4.example.test - Initial Testing (2025-10-30)

✅ **Package Installation**
- NFTBan v0.10.0-1.el10.x86_64 installed via RPM
- All dependencies resolved
- Polkit rule installed correctly

✅ **Polkit Integration** (12 comprehensive tests)
- nftban-cli members can manage nftables ✓
- nftban-cli members can manage fail2ban ✓
- Cannot manage other services (sshd, etc.) ✓
- No password required ✓
- Security boundaries enforced ✓

✅ **Go Binaries**
- nftban-feeds v1.0.0 built successfully (2.0 MiB)
- nftban-geoip v1.0.0 built successfully (2.1 MiB)
- Both binaries tested and working ✓

✅ **FHS Compliance**
- 21/21 directories OK
- Permissions correct
- Auto-healing working

✅ **Services**
- nftables: active
- fail2ban: active
- Timers: enabled and scheduled

---

**Status:** ✅ MONITORING STARTED - 24 HOURS IN PROGRESS

**Next Review:** 2025-10-31 08:00 UTC
