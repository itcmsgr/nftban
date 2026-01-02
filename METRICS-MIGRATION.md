# NFTBan Metrics Migration: Bash to Go

## Overview

NFTBan v1.0+ introduces a **hybrid metrics collection system** that automatically uses the best available exporter:

```
┌─────────────────────────────────────┐
│  nftban-metrics-exporter.service    │
└──────────────┬──────────────────────┘
               │
          ┌────▼────────────────┐
          │  Hybrid Wrapper     │
          │  (Auto-detection)   │
          └────┬────────────────┘
               │
       ┌───────┴───────────┐
       │                   │
   ┌───▼────┐        ┌─────▼─────┐
   │  Go    │        │   Bash    │
   │ Fast!  │        │ Fallback  │
   └───┬────┘        └─────┬─────┘
       │                   │
       └────────┬──────────┘
                │
        ┌───────▼────────┐
        │  nftban.prom   │
        └────────────────┘
```

## Problem Solved

**Before (Bash-only):**
- ❌ 11+ calls to `nft list` per collection
- ❌ Heavy grep/awk/wc processing
- ❌ CPU and I/O spikes every 30-60 seconds
- ❌ Slow (~2-5 seconds per collection)

**After (Hybrid Go + Bash):**
- ✅ Single `nft -j` JSON call (Go exporter)
- ✅ Efficient in-memory parsing
- ✅ Minimal CPU usage
- ✅ Fast (~50-200ms per collection)
- ✅ Automatic fallback to bash if Go unavailable

## Performance Comparison

| Metric | Bash Exporter | Go Exporter | Improvement |
|--------|---------------|-------------|-------------|
| **NFT Calls** | 11+ | 1 | -91% |
| **Execution Time** | 2-5 seconds | 50-200ms | -95% |
| **CPU Usage** | High (grep/awk) | Low (native) | -80% |
| **Memory** | Variable | Constant | More predictable |
| **Compatibility** | 100% | Requires Go binary | N/A |

## Architecture

### Components

1. **Hybrid Wrapper** (`nftban_metrics_wrapper.sh`)
   - Auto-detects Go vs bash exporter
   - Tries Go first, falls back to bash
   - Logs which exporter is used

2. **Go Exporter** (`nftban-core metrics export`)
   - Fast, efficient metrics collection
   - Single JSON call to nftables
   - Native Go performance

3. **Bash Exporter** (`nftban_prometheus_exporter.sh`)
   - Legacy compatibility
   - Works on any system with bash
   - No Go binary required

### Auto-Detection Logic

```bash
if command -v nftban-core >/dev/null 2>&1; then
    # Use Go exporter (preferred)
    exec nftban-core metrics export
else
    # Fallback to bash exporter
    exec /usr/lib/nftban/exporters/nftban_prometheus_exporter.sh
fi
```

## Installation Scenarios

### Scenario 1: Full Install (Go Binary Available)
```bash
# Install includes nftban-core binary
make install

# Systemd service automatically uses Go exporter
systemctl start nftban-metrics-exporter.service
```

**Result:** ✅ Uses Go exporter (high performance)

### Scenario 2: Minimal Install (Bash Only)
```bash
# Install without Go binary
make install-minimal

# Systemd service automatically falls back to bash
systemctl start nftban-metrics-exporter.service
```

**Result:** ✅ Uses bash exporter (compatible)

### Scenario 3: Upgrade from v0.7.x
```bash
# Existing bash-only installation
systemctl stop nftban-metrics-exporter.service

# Upgrade to v1.0
git pull && make install

# Service automatically upgrades to Go exporter
systemctl start nftban-metrics-exporter.service
```

**Result:** ✅ Automatically uses Go exporter after upgrade

## Usage

### Manual Execution

**Test Go exporter:**
```bash
nftban-core metrics export --output /tmp/metrics.prom
```

**Test bash exporter:**
```bash
/usr/lib/nftban/exporters/nftban_prometheus_exporter.sh
```

**Test hybrid wrapper:**
```bash
/usr/lib/nftban/exporters/nftban_metrics_wrapper.sh
```

### Check Which Exporter Is Being Used

```bash
# Check systemd logs
journalctl -u nftban-metrics-exporter.service -n 20

# Look for lines like:
# "Using Go-based exporter (high performance)"
# or
# "Using bash-based exporter (compatibility mode)"
```

### Monitor Performance

```bash
# Check collection duration
curl -s http://localhost:9100/metrics | grep nftban_exporter_duration_seconds

# Check which backend is active
curl -s http://localhost:9100/metrics | grep nftban_exporter_backend
# 1 = Go, 0 = Bash
```

## Metrics Collected

Both exporters collect the same metrics:

### Block Metrics
- `nftban_blocks_total` - Total blocked IPs
- `nftban_blocks_ipv4` - IPv4 blocks
- `nftban_blocks_ipv6` - IPv6 blocks
- `nftban_whitelist_ipv4` - IPv4 whitelist count
- `nftban_whitelist_ipv6` - IPv6 whitelist count

### Bandwidth Metrics
- `nftban_network_rx_bytes{interface}` - RX bytes per interface
- `nftban_network_tx_bytes{interface}` - TX bytes per interface
- `nftban_network_total_rx_bytes` - Total RX
- `nftban_network_total_tx_bytes` - Total TX

### Health Metrics
- `nftban_health_status{component}` - Component health (0=OK, 1=WARN, 2=ERROR, 3=CRITICAL)
  - Components: nftables, ssh, polkit

### NFTables Metrics
- `nftban_nftables_rules_total` - Total nftables rules

### Protocol Metrics
- `nftban_protocol_segments{protocol}` - TCP/UDP segments
- `nftban_connections_active` - Active connections

### Exporter Metrics
- `nftban_exporter_duration_seconds` - Collection time
- `nftban_exporter_last_success_timestamp` - Last successful collection
- `nftban_exporter_backend` - Which exporter is active (1=Go, 0=Bash)

## Troubleshooting

### Go Exporter Not Being Used

**Symptom:** Logs show "Using bash-based exporter" despite Go binary installed

**Check:**
```bash
# Verify Go binary exists
which nftban-core

# Test metrics command
nftban-core metrics --help

# Check PATH in systemd
systemctl show nftban-metrics-exporter.service -p Environment
```

**Fix:**
```bash
# Ensure nftban-core is in PATH
systemctl edit nftban-metrics-exporter.service

# Add:
[Service]
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
```

### Metrics Not Updating

**Symptom:** Prometheus shows stale metrics

**Check:**
```bash
# Verify timer is running
systemctl status nftban-metrics-exporter.timer

# Check service status
systemctl status nftban-metrics-exporter.service

# View recent runs
journalctl -u nftban-metrics-exporter.service --since "10 min ago"
```

### Permission Errors

**Symptom:** "Permission denied" in logs

**Fix:**
```bash
# Ensure output directory exists
mkdir -p /var/lib/node_exporter/textfile_collector

# Fix permissions
chown nftban:nftban /var/lib/node_exporter/textfile_collector
chmod 755 /var/lib/node_exporter/textfile_collector
```

## Migration Path

### For Users

No action required! The hybrid wrapper handles migration automatically:

1. **v0.7.x users:** Continue using bash exporter
2. **v1.0+ upgrade:** Automatically switch to Go exporter
3. **Minimal install:** Automatically use bash exporter

### For Developers

To add new metrics:

1. Add to **Go exporter** (`pkg/metrics/collector.go`)
2. Add to **bash exporter** (`nftban_prometheus_exporter.sh`)
3. Ensure parity between both exporters

## Future Plans

### v1.1+: Deprecation Notice
- Mark bash exporter as deprecated
- Add warning when bash exporter is used
- Recommend installing Go binary

### v2.0: Go-Only
- Require Go binary for metrics
- Remove bash exporter
- Simplified maintenance

## Related Files

- `pkg/metrics/collector.go` - Go metrics collector
- `cmd/nftban-core/cmd_metrics.go` - CLI command
- `cli/lib/nftban/exporters/nftban_metrics_wrapper.sh` - Hybrid wrapper
- `cli/lib/nftban/exporters/nftban_prometheus_exporter.sh` - Bash exporter (legacy)
- `install/systemd/nftban-metrics-exporter.service` - Systemd service

## License

Mozilla Public License 2.0 (MPL-2.0)
Copyright © 2024–2026 NFTBAN Project / Antonios Voulvoulis
Contact: contact@nftban.com | Website: https://nftban.com
