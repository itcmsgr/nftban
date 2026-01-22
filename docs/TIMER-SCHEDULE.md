# NFTBan Timer Schedule - Senior Architecture

## Design Philosophy

### Problems Solved

1. **Thundering Herd**: Multiple hosts firing at exact same time
2. **Duplicate Work**: 3 exporters collecting same metrics 3x
3. **Monitoring Gaps**: Missing `Persistent=true` caused data loss
4. **Resource Spikes**: All timers running simultaneously

### Solutions Implemented

1. **Unified Exporter**: Single collection, multiple export targets (66% reduction)
2. **Deterministic Jitter**: `FixedRandomDelay=true` - same offset per host
3. **Staggered Boot**: Different `OnBootSec` values prevent boot storms
4. **Smart Intervals**: Queue timer increased 2min → 5min (60% reduction)

---

## Timer Schedule Overview

### High-Frequency Timers (< 5 min)

| Timer | Interval | Boot Delay | Jitter | Purpose |
|-------|----------|------------|--------|---------|
| unified-exporter | 60s | 45s | 30s (50%) | Metrics to all targets |
| watchdog | 90s | 2m | 15s (17%) | System health alerts |

### Medium-Frequency Timers (5-60 min)

| Timer | Interval | Boot Delay | Jitter | Purpose |
|-------|----------|------------|--------|---------|
| queue | 5m | 3m | 2m (40%) | Task queue processing |
| maintenance | 15m | - | 2m (13%) | SSH/IP monitoring, autoheal |

### Daily Timers (Staggered Schedule)

| Timer | Schedule | Jitter | Purpose |
|-------|----------|--------|---------|
| rbl-check | 02:00 | 15m | RBL reputation check |
| health | 03:00 | 30m | Full system health check |
| core-feeds | 03:00 | 30m | Threat feed updates |
| pro-inventory | 04:00 | 15m | Pro inventory collection |

### Weekly Timers

| Timer | Schedule | Jitter | Purpose |
|-------|----------|--------|---------|
| core-geoip | Sun 02:00 | 60m | GeoIP database update |
| suricata-update | Sun 03:00 | 60m | Suricata rules update |

---

## Timeline Visualization

```
Boot Sequence (first 5 minutes):
├─ 0:30  metrics-exporter starts (if legacy mode)
├─ 0:45  unified-exporter starts (recommended)
├─ 2:00  watchdog starts
├─ 3:00  queue processor starts
└─ 5:00  all timers running

Hourly Pattern (with jitter):
├─ :00-:30  [unified-exporter window]
├─ :00-:15  [snapshot window]
├─ :05-:35  [queue window]
└─ :15-:45  [maintenance window]

Daily Pattern (staggered to avoid 03:00 pile-up):
├─ 02:00-02:15  rbl-check
├─ 03:00-03:30  health, core-feeds (30m jitter separates them)
└─ 04:00-04:15  pro-inventory
```

---

## Key Settings Explained

### `Persistent=true`
```ini
# CRITICAL for monitoring timers
# Without this: system reboot = missed data points
# With this: catches up on missed runs after boot
Persistent=true
```

### `FixedRandomDelay=true`
```ini
# DETERMINISTIC jitter based on machine-id
# Host A always fires at :15, Host B at :42
# Predictable for debugging, distributed for load
RandomizedDelaySec=30s
FixedRandomDelay=true
```

### `AccuracySec`
```ini
# Allows systemd to batch nearby timers
# Reduces CPU wakeups, improves power efficiency
# 10s for frequent timers, 1m for daily
AccuracySec=10s
```

---

## Migration Guide

### From Legacy (3 exporters) to Unified

```bash
# 1. Enable unified exporter
systemctl enable --now nftban-unified-exporter.timer

# 2. Disable legacy exporters
systemctl disable --now nftban-metrics-exporter.timer
systemctl disable --now nftban-zabbix-exporter.timer
systemctl disable --now nftban-connector-exporter.timer

# 3. Verify
systemctl list-timers 'nftban-*'
```

### Rollback to Legacy

```bash
# Disable unified
systemctl disable --now nftban-unified-exporter.timer

# Re-enable legacy (pick what you need)
systemctl enable --now nftban-metrics-exporter.timer
systemctl enable --now nftban-zabbix-exporter.timer
```

---

## Monitoring Timer Health

```bash
# List all NFTBan timers with next/last fire times
systemctl list-timers 'nftban-*' --all

# Check for failed timer runs
journalctl -u 'nftban-*.timer' --since '1 hour ago' | grep -i fail

# Timer statistics
systemd-analyze calendar '*:0/15'  # Preview schedule
```

---

## Performance Impact

### Before Optimization
- 3 metric collections per minute = 180/hour
- Timer overhead: 3 timers × 60 runs/hour = 180 timer activations
- Boot storm: 3 exporters starting simultaneously

### After Optimization
- 1 metric collection per minute = 60/hour (66% reduction)
- Timer overhead: 1 timer × 60 runs/hour = 60 activations (66% reduction)
- Staggered boot: exporters spread over 45 seconds

---

## Troubleshooting

### Timer not firing?
```bash
# Check timer status
systemctl status nftban-unified-exporter.timer

# Check if Persistent caught up
journalctl -u nftban-unified-exporter.timer | grep -i persistent
```

### Jitter too aggressive?
```bash
# Reduce jitter in timer file
RandomizedDelaySec=15s  # Instead of 30s

# Or disable for testing
RandomizedDelaySec=0
```

### Metrics delayed?
```bash
# Check actual fire times
systemctl show nftban-unified-exporter.timer -p LastTriggerUSec
systemctl show nftban-unified-exporter.timer -p NextElapseUSecRealtime
```
