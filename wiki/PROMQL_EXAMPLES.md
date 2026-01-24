# NFTBan PromQL Examples

Quick-reference PromQL queries for common monitoring scenarios.

---

## Status & Health

### Daemon Up/Down
```promql
nftban_daemon_up
```

### Uptime (seconds)
```promql
nftban_daemon_uptime_seconds
```

### Watchdog Running
```promql
nftban_watchdog_up
```

---

## Watchdog Pressure (0-100)

### CPU Pressure
```promql
nftban_watchdog_pressure_score{type="cpu"}
```

### Memory Pressure
```promql
nftban_watchdog_pressure_score{type="memory"}
```

### I/O Pressure
```promql
nftban_watchdog_pressure_score{type="io"}
```

### Max Pressure (any dimension)
```promql
max(nftban_watchdog_pressure_score)
```

---

## Runtime (Go)

### Goroutines
```promql
nftban_runtime_goroutines
```

### Heap Memory (bytes)
```promql
nftban_runtime_memory_bytes{type="heap"}
```

### Heap Memory (MB)
```promql
nftban_runtime_memory_bytes{type="heap"} / 1024 / 1024
```

### GC Cycles Rate (per second)
```promql
rate(nftban_runtime_gc_cycles_total[5m])
```

### GC Pause Duration
```promql
nftban_runtime_gc_pause_seconds
```

---

## IPC

### Request Rate (per second)
```promql
rate(nftban_ipc_requests_total[5m])
```

### Error Rate (per second)
```promql
rate(nftban_ipc_errors_total[5m])
```

### Error Ratio
```promql
rate(nftban_ipc_errors_total[5m]) / rate(nftban_ipc_requests_total[5m])
```

### Latency (seconds)
```promql
nftban_ipc_latency_seconds
```

---

## Throughput

### Ban Rate (per second)
```promql
rate(nftban_throughput_total{type="bans"}[5m])
```

### Unban Rate (per second)
```promql
rate(nftban_throughput_total{type="unbans"}[5m])
```

### Event Rate (per second)
```promql
rate(nftban_throughput_total{type="events"}[5m])
```

### Current Bans Per Minute
```promql
nftban_throughput_bans_per_minute
```

---

## Blocks & Bans

### Total Blocked IPs (current)
```promql
nftban_blocks_total
```

### Bans in Last 24 Hours
```promql
nftban_bans_last_24h
```

### Top 10 Countries Blocked
```promql
topk(10, nftban_blocks_by_country)
```

### Banned IPs by Family
```promql
sum by (family) (nftban_banned_ips{type="total"})
```

### IPv4 Permanent Bans
```promql
nftban_banned_ips{family="ipv4", type="permanent"}
```

### IPv6 Temporary Bans
```promql
nftban_banned_ips{family="ipv6", type="temporary"}
```

---

## Firewall

### Dropped Packets Rate (by reason)
```promql
rate(nftban_firewall_packets_total{action="drop"}[5m])
```

### Blacklist Drops Rate
```promql
rate(nftban_firewall_packets_total{action="drop",reason="blacklist"}[5m])
```

### Accepted Packets Rate
```promql
rate(nftban_firewall_packets_total{action="accept"}[5m])
```

### NFTables Set Sizes
```promql
nftban_set_size
```

### Blacklist IPv4 Size
```promql
nftban_set_size{set="blacklist_ipv4"}
```

---

## Network

### Bandwidth by Interface (Mbps)
```promql
nftban_network_rx_mbps
nftban_network_tx_mbps
```

### Total Bandwidth
```promql
nftban_network_total_rx_mbps
nftban_network_total_tx_mbps
```

### Peak Bandwidth (5 min window)
```promql
nftban_bandwidth_peak_rx_mbps
nftban_bandwidth_peak_tx_mbps
```

### Interface Throughput (bytes/sec)
```promql
rate(nftban_network_rx_bytes[5m])
rate(nftban_network_tx_bytes[5m])
```

### Active Connections
```promql
nftban_connections_active
```

### Established Connections
```promql
nftban_connections_established
```

### TIME_WAIT Connections
```promql
nftban_connections_time_wait
```

---

## Threat Feeds

### Enabled Feeds Count
```promql
nftban_feeds_enabled
```

### Total Feed IPs by Family
```promql
nftban_feeds_ips
```

---

## Alert Rules (Examples)

### Daemon Down
```yaml
- alert: NFTBanDaemonDown
  expr: nftban_daemon_up == 0
  for: 1m
  labels:
    severity: critical
  annotations:
    summary: "NFTBan daemon is down"
```

### High Memory Pressure
```yaml
- alert: NFTBanHighMemoryPressure
  expr: nftban_watchdog_pressure_score{type="memory"} > 80
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "NFTBan memory pressure is {{ $value }}%"
```

### High Ban Rate
```yaml
- alert: NFTBanHighBanRate
  expr: rate(nftban_throughput_total{type="bans"}[5m]) > 10
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "High ban rate: {{ $value }} bans/sec"
```

### IPC Errors
```yaml
- alert: NFTBanIPCErrors
  expr: rate(nftban_ipc_errors_total[5m]) > 0.1
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "NFTBan IPC errors detected"
```

### Goroutine Leak
```yaml
- alert: NFTBanGoroutineLeak
  expr: nftban_runtime_goroutines > 1000
  for: 10m
  labels:
    severity: warning
  annotations:
    summary: "Possible goroutine leak: {{ $value }} goroutines"
```

---

## Recording Rules (Examples)

For frequently used queries, create recording rules:

```yaml
groups:
  - name: nftban
    rules:
      - record: nftban:ban_rate:5m
        expr: rate(nftban_throughput_total{type="bans"}[5m])

      - record: nftban:pressure:max
        expr: max(nftban_watchdog_pressure_score)

      - record: nftban:memory_mb
        expr: nftban_runtime_memory_bytes{type="heap"} / 1024 / 1024
```
