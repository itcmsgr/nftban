# System Protection Guide - NFTBan Go Feeds

**Priority:** CRITICAL - Protect CPU, RAM, and System Stability
**Date:** 2025-11-05
**Target:** Production servers must remain stable

---

## 🛡️ PROTECTION LAYERS

### 1. Resource Limits (systemd)

Create systemd service file with hard limits:

**File:** `/etc/systemd/system/nftban-feeds.service`

```ini
[Unit]
Description=NFTBan Feed Sync Service
After=network-online.target nftables.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/lib/nftban/bin/nftban-feeds sync greensnow,spamhaus-drop,cloudflare

# CPU PROTECTION
CPUQuota=50%                    # Max 50% of one CPU core
CPUAccounting=true

# MEMORY PROTECTION
MemoryMax=500M                  # Hard limit: 500MB RAM
MemoryHigh=400M                 # Soft limit: 400MB (throttle at this point)
MemoryAccounting=true

# I/O PROTECTION
IOWeight=100                    # Low I/O priority (default=100, max=10000)
IOAccounting=true

# TIMEOUT PROTECTION
TimeoutStartSec=60s             # Kill if takes >60 seconds
RuntimeMaxSec=120s              # Hard kill after 2 minutes

# PROCESS LIMITS
LimitNPROC=10                   # Max 10 processes (prevent fork bombs)
LimitNOFILE=1024                # Max 1024 open files

# SECURITY
PrivateTmp=true                 # Isolated /tmp
NoNewPrivileges=true            # Can't escalate privileges
ProtectSystem=strict            # Read-only /usr, /boot, /efi
ProtectHome=true                # No access to /home
ReadWritePaths=/var/lib/nftban  # Only write to cache dir

# USER/GROUP
User=root                       # Needs CAP_NET_ADMIN for netlink
Group=nftban
AmbientCapabilities=CAP_NET_ADMIN

# LOGGING
StandardOutput=journal
StandardError=journal
SyslogIdentifier=nftban-feeds

[Install]
WantedBy=multi-user.target
```

**Install:**
```bash
sudo systemctl daemon-reload
sudo systemctl enable nftban-feeds.service
```

---

### 2. Timer (Controlled Scheduling)

**File:** `/etc/systemd/system/nftban-feeds.timer`

```ini
[Unit]
Description=NFTBan Feed Sync Timer
Requires=nftban-feeds.service

[Timer]
# Run every 15 minutes
OnCalendar=*:0/15

# PROTECTION: Prevent overlapping runs
OnUnitActiveSec=infinity        # Don't start if already running

# PROTECTION: Random delay to spread load
RandomizedDelaySec=60s          # Start within 0-60s of trigger time

# PROTECTION: Catch-up behavior
Persistent=false                # Don't run missed timers on boot
AccuracySec=5min                # Allow 5min variance (reduce wakeups)

[Install]
WantedBy=timers.target
```

**Install:**
```bash
sudo systemctl daemon-reload
sudo systemctl enable nftban-feeds.timer
sudo systemctl start nftban-feeds.timer
```

**Check status:**
```bash
systemctl status nftban-feeds.timer
systemctl list-timers nftban-feeds.timer
```

---

### 3. Go Code Protections (Already Implemented)

#### 3.1 Memory Protection
```go
// Chunked loading prevents massive memory allocations
const ChunkSize = 4096  // Max 4096 elements in memory at once

// Stream processing (not loading entire feed into RAM)
scanner := bufio.NewScanner(resp.Body)  // Line-by-line
```

#### 3.2 CPU Protection
```go
// Worker pool limits concurrent operations
workers := min(8, len(urls))  // Max 8 concurrent fetches
sem := make(chan struct{}, workers)

// Timeouts prevent hung operations
ctx, cancel := context.WithTimeout(ctx, 10*time.Second)  // Per-fetch
reqCtx, cancel := context.WithTimeout(ctx, 30*time.Second)  // Global
```

#### 3.3 I/O Protection
```go
// Limit response size (prevent memory exhaustion from huge feeds)
body, err := io.ReadAll(io.LimitReader(resp.Body, 50*1024*1024))  // Max 50MB
```

---

### 4. Kernel Protection (nftables)

#### 4.1 Set Size Limits
```bash
# Add max size to nftables sets
sudo nft add set inet nftban_main feed_v4 '{
    type ipv4_addr;
    flags interval;
    size 1000000;        # Max 1M elements
    auto-merge;          # Kernel merges adjacent ranges
}'

sudo nft add set inet nftban_main feed_v6 '{
    type ipv6_addr;
    flags interval;
    size 1000000;        # Max 1M elements
    auto-merge;          # Kernel merges adjacent ranges
}'
```

#### 4.2 Netlink Rate Limiting
Already implemented via chunking - prevents flooding netlink socket.

---

### 5. Monitoring & Alerting

#### 5.1 Resource Monitoring Script

**File:** `/usr/local/bin/nftban-feeds-monitor.sh`

```bash
#!/bin/bash
# Monitor nftban-feeds resource usage

MAX_CPU=50      # Alert if >50% CPU
MAX_MEM=500     # Alert if >500MB RAM
MAX_TIME=120    # Alert if runs >120 seconds

while true; do
    # Check if nftban-feeds is running
    if pgrep -f nftban-feeds >/dev/null; then
        PID=$(pgrep -f nftban-feeds)

        # Get CPU usage (%)
        CPU=$(ps -p $PID -o %cpu= | awk '{print int($1)}')

        # Get memory usage (MB)
        MEM=$(ps -p $PID -o rss= | awk '{print int($1/1024)}')

        # Get runtime (seconds)
        ELAPSED=$(ps -p $PID -o etimes= | awk '{print int($1)}')

        # Check limits
        if [ $CPU -gt $MAX_CPU ]; then
            echo "WARNING: nftban-feeds using ${CPU}% CPU (limit: ${MAX_CPU}%)" | logger -t nftban-monitor
        fi

        if [ $MEM -gt $MAX_MEM ]; then
            echo "WARNING: nftban-feeds using ${MEM}MB RAM (limit: ${MAX_MEM}MB)" | logger -t nftban-monitor
        fi

        if [ $ELAPSED -gt $MAX_TIME ]; then
            echo "CRITICAL: nftban-feeds running ${ELAPSED}s (limit: ${MAX_TIME}s) - killing" | logger -t nftban-monitor
            kill -9 $PID
        fi
    fi

    sleep 5
done
```

#### 5.2 Systemd Monitoring Service

**File:** `/etc/systemd/system/nftban-feeds-monitor.service`

```ini
[Unit]
Description=NFTBan Feeds Resource Monitor
After=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/nftban-feeds-monitor.sh
Restart=always
RestartSec=10s

[Install]
WantedBy=multi-user.target
```

---

### 6. Emergency Kill Switch

#### 6.1 Manual Kill
```bash
# Kill all nftban-feeds processes immediately
sudo pkill -9 -f nftban-feeds

# Stop timer to prevent restart
sudo systemctl stop nftban-feeds.timer

# Disable service
sudo systemctl disable nftban-feeds.service
```

#### 6.2 Automatic Circuit Breaker

**File:** `/etc/systemd/system/nftban-feeds.service.d/override.conf`

```ini
[Unit]
# Stop trying after 5 failures
StartLimitBurst=5
StartLimitIntervalSec=300

[Service]
# Restart on failure, but with backoff
Restart=on-failure
RestartSec=30s
```

---

### 7. Testing Protection Limits

#### Test 7.1: Memory Limit
```bash
# Should fail if tries to use >500MB
sudo systemd-run --unit=test-memory-limit \
    --property=MemoryMax=500M \
    /usr/lib/nftban/bin/nftban-feeds sync greensnow

# Check if killed by OOM
journalctl -u test-memory-limit | grep -i "memory"
```

#### Test 7.2: CPU Limit
```bash
# Should be throttled to 50% CPU
sudo systemd-run --unit=test-cpu-limit \
    --property=CPUQuota=50% \
    /usr/lib/nftban/bin/nftban-feeds sync greensnow

# Monitor CPU usage
watch -n 1 'ps aux | grep nftban-feeds'
```

#### Test 7.3: Timeout
```bash
# Should be killed after 60s
sudo systemd-run --unit=test-timeout \
    --property=TimeoutStartSec=60s \
    sleep 120

# Should see timeout in logs
journalctl -u test-timeout
```

---

### 8. Production Checklist

Before deploying to production:

- [ ] systemd service file installed with limits
- [ ] Timer configured (not running continuously)
- [ ] Resource limits tested (CPU, RAM, timeout)
- [ ] Monitoring script running
- [ ] Emergency kill procedure documented
- [ ] Logs being collected (journalctl)
- [ ] Alerting configured (optional: Prometheus)
- [ ] Tested on lab server first
- [ ] Rollback plan ready

---

### 9. Safe Deployment Steps

```bash
# Step 1: Deploy to ONE lab server first
scp /tmp/GO_FEED_INTEGRATION/go-feeds/nftban-feeds root@lab.mywebhost.gr:/tmp/

# Step 2: Test manually with limits
ssh root@lab.mywebhost.gr
sudo systemd-run --unit=test-feeds \
    --property=MemoryMax=500M \
    --property=CPUQuota=50% \
    --property=TimeoutStartSec=60s \
    /tmp/nftban-feeds sync greensnow

# Step 3: Monitor during test
watch -n 1 'ps aux | grep nftban-feeds; echo "---"; free -h'

# Step 4: If successful, install service
sudo cp /tmp/nftban-feeds /usr/lib/nftban/bin/nftban-feeds
sudo cp /tmp/GO_FEED_INTEGRATION/nftban-feeds.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable nftban-feeds.timer
sudo systemctl start nftban-feeds.timer

# Step 5: Monitor for 24 hours
journalctl -u nftban-feeds -f

# Step 6: Deploy to remaining servers
```

---

### 10. Rollback Plan

If Go implementation causes issues:

```bash
# 1. Stop and disable Go feeds
sudo systemctl stop nftban-feeds.timer
sudo systemctl disable nftban-feeds.service

# 2. Bash fallback is ALREADY INTEGRATED
# nftban_feeds.sh checks for Go binary:
#   - If exists: use Go
#   - If missing: use bash
# So just remove Go binary:
sudo rm /usr/lib/nftban/bin/nftban-feeds

# 3. Verify bash fallback works
nftban feeds sync
# Should see: "Using bash feed loader (Go binary not found)"

# 4. Old behavior restored
# Bash bulk loading (v0.30.8) continues working
```

---

## 📊 Expected Resource Usage

### Normal Operation (Go v0.32.0)
| Resource | Expected | Alert If > |
|----------|----------|------------|
| CPU | 1-5% | 50% |
| RAM | 50-200 MB | 500 MB |
| Runtime | 1-10 sec | 60 sec |
| I/O | Minimal | N/A |

### Comparison with Bash (v0.30.8)
| Metric | Bash | Go | Improvement |
|--------|------|-----|-------------|
| CPU | 5-10% | 1-5% | 2-5x better |
| RAM | 500 MB | 50-200 MB | 3-10x better |
| Runtime | 10-30 sec | 1-10 sec | 3-30x faster |

---

## 🚨 Alert Thresholds

Configure these in your monitoring:

**WARNING** (log + notify):
- CPU >25% for >30 seconds
- RAM >300MB
- Runtime >30 seconds

**CRITICAL** (log + notify + consider killing):
- CPU >50% for >60 seconds
- RAM >500MB (systemd will OOM-kill)
- Runtime >60 seconds (systemd will kill)

**EMERGENCY** (automatic kill):
- Runtime >120 seconds (hard timeout)
- Memory limit breached (OOM kill)

---

## 🔍 Troubleshooting

### Issue: High CPU Usage
```bash
# Check what's consuming CPU
sudo perf top -p $(pgrep nftban-feeds)

# Check if stuck in loop
sudo strace -p $(pgrep nftban-feeds)

# Kill if needed
sudo pkill -9 -f nftban-feeds
```

### Issue: High Memory Usage
```bash
# Check memory breakdown
sudo pmap $(pgrep nftban-feeds)

# Check for memory leaks
sudo valgrind --leak-check=full /usr/lib/nftban/bin/nftban-feeds sync greensnow
```

### Issue: Won't Stop
```bash
# Force kill with systemd
sudo systemctl kill --signal=SIGKILL nftban-feeds.service

# Nuclear option
sudo pkill -9 -f nftban-feeds
```

---

## ✅ Safety Validation

Before considering production-ready:

1. [ ] Runs under systemd limits without triggering OOM
2. [ ] Completes within timeout (60s)
3. [ ] CPU stays under 50%
4. [ ] Memory stays under 500MB
5. [ ] Can be cleanly killed with SIGTERM
6. [ ] Rollback to bash works
7. [ ] Monitoring alerts trigger correctly
8. [ ] Tested under load (multiple concurrent feeds)
9. [ ] Tested with corrupted/malicious feed data
10. [ ] Tested with network failures

---

**Priority:** Deploy systemd limits BEFORE deploying Go binary to production!

**Contact:** Check logs with `journalctl -u nftban-feeds -f`
