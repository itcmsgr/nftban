# NFTBan Metrics Contract

**Version:** 1.0.0
**Schema Version:** 2
**Last Updated:** 2026-01-24
**Status:** STABLE

---

## Overview

NFTBan exposes metrics in Prometheus text exposition format. This document is the **authoritative contract** for all metric names, types, labels, and semantics.

### Scrape Configuration

```yaml
scrape_configs:
  - job_name: 'nftban'
    static_configs:
      - targets: ['localhost:9100']  # node_exporter with textfile collector
    # OR direct daemon scrape:
    # - targets: ['localhost:8080']
```

### Labels Provided Automatically

| Label | Source | Example |
|-------|--------|---------|
| `instance` | Prometheus scrape | `lab.example.test:9100` |
| `job` | Prometheus config | `nftban` |

---

## Metric Groups

### 1. Daemon Status

| Metric | Type | Unit | Description |
|--------|------|------|-------------|
| `nftban_daemon_up` | gauge | boolean | 1 if daemon running, 0 if down |
| `nftban_daemon_uptime_seconds` | gauge | seconds | Daemon uptime since start |
| `nftban_daemon_info` | gauge | info | Always 1, carries labels |

**Labels for `nftban_daemon_info`:**

| Label | Values | Description |
|-------|--------|-------------|
| `mode` | `normal`, `degraded`, `survival` | Operating mode |
| `pid` | integer | Process ID |

**Reset Semantics:** `uptime_seconds` resets on daemon restart.

---

### 2. Watchdog Pressure

| Metric | Type | Unit | Description |
|--------|------|------|-------------|
| `nftban_watchdog_up` | gauge | boolean | 1 if watchdog running |
| `nftban_watchdog_info` | gauge | info | Always 1, carries mode label |
| `nftban_watchdog_pressure_score` | gauge | percent (0-100) | System pressure by dimension |

**Labels for `nftban_watchdog_pressure_score`:**

| Label | Values | Description |
|-------|--------|-------------|
| `type` | `cpu`, `memory`, `io` | Pressure dimension |

**Interpretation:**
- 0-40: Normal (green)
- 40-60: Elevated (yellow)
- 60-80: High/Degraded mode triggered (orange)
- 80-100: Critical/Survival mode triggered (red)

**Cardinality:** Fixed at 3 (cpu, memory, io). Safe.

---

### 3. Go Runtime

| Metric | Type | Unit | Description |
|--------|------|------|-------------|
| `nftban_runtime_goroutines` | gauge | count | Active goroutines |
| `nftban_runtime_memory_bytes` | gauge | bytes | Memory usage by type |
| `nftban_runtime_gc_cycles_total` | counter | count | Total GC cycles |
| `nftban_runtime_gc_pause_seconds` | gauge | seconds | Last GC pause duration |

**Labels for `nftban_runtime_memory_bytes`:**

| Label | Values | Description |
|-------|--------|-------------|
| `type` | `heap`, `alloc`, `sys` | Memory category |

**Cardinality:** Fixed at 3. Safe.

**Recommended Aggregation:**
- `goroutines`: Direct value, alert on > 1000
- `memory_bytes`: Direct value, alert heap > 500MB
- `gc_cycles_total`: Use `rate()` for GC frequency
- `gc_pause_seconds`: Direct value, alert > 0.1s

---

### 4. IPC (Inter-Process Communication)

| Metric | Type | Unit | Description |
|--------|------|------|-------------|
| `nftban_ipc_requests_total` | counter | count | Total IPC requests to daemon |
| `nftban_ipc_latency_seconds` | gauge | seconds | Average request latency |
| `nftban_ipc_errors_total` | counter | count | Total IPC errors |

**Reset Semantics:** Counters reset on daemon restart.

**Recommended Aggregation:**
- `requests_total`: Use `rate(nftban_ipc_requests_total[5m])`
- `errors_total`: Use `rate(nftban_ipc_errors_total[5m])`
- `latency_seconds`: Direct value

---

### 5. Throughput

| Metric | Type | Unit | Description |
|--------|------|------|-------------|
| `nftban_throughput_total` | counter | count | Event counts by type |
| `nftban_throughput_bans_per_minute` | gauge | count/min | Current ban rate |

**Labels for `nftban_throughput_total`:**

| Label | Values | Description |
|-------|--------|-------------|
| `type` | `bans`, `unbans`, `events` | Event category |

**Cardinality:** Fixed at 3. Safe.

**Recommended Aggregation:**
- `throughput_total`: Use `rate(nftban_throughput_total[5m])`
- `bans_per_minute`: Direct value (already a rate)

---

### 6. Blocks & Bans

| Metric | Type | Unit | Description |
|--------|------|------|-------------|
| `nftban_blocks_total` | gauge | count | Current total blocked IPs |
| `nftban_blocks_permanent` | gauge | count | Permanently blocked IPs |
| `nftban_blocks_temporary` | gauge | count | Temporarily blocked IPs |
| `nftban_blocks_geoban` | gauge | count | Geo-blocked IPs |
| `nftban_blocks_by_country` | gauge | count | Blocked IPs per country |
| `nftban_banned_ips` | gauge | count | IPs by family and type |
| `nftban_bans_total` | counter | count | Cumulative bans since reset |
| `nftban_bans_last_24h` | gauge | count | Bans in last 24 hours |

**Labels for `nftban_blocks_by_country`:**

| Label | Values | Description |
|-------|--------|-------------|
| `country` | ISO 3166-1 alpha-2 | Country code (CN, RU, US, etc.) |

**Cardinality Warning:** Up to ~250 countries. Use `topk()` in queries.

**Labels for `nftban_banned_ips`:**

| Label | Values | Description |
|-------|--------|-------------|
| `family` | `ipv4`, `ipv6` | IP address family |
| `type` | `permanent`, `temporary`, `total` | Ban type |

**Cardinality:** Fixed at 6 combinations. Safe.

---

### 7. Firewall Counters

| Metric | Type | Unit | Description |
|--------|------|------|-------------|
| `nftban_firewall_packets_total` | counter | count | Packets by action/reason |
| `nftban_firewall_bytes_total` | counter | bytes | Bytes by action/reason |
| `nftban_nftables_rules_count` | gauge | count | Total firewall rules |
| `nftban_set_size` | gauge | count | Elements per nftables set |

**Labels for `nftban_firewall_*_total`:**

| Label | Values | Description |
|-------|--------|-------------|
| `action` | `drop`, `accept` | Firewall action |
| `reason` | `blacklist`, `whitelist`, `default_drop`, `icmp_accept`, `established` | Rule category |

**Cardinality:** Fixed at ~10 combinations. Safe.

**Labels for `nftban_set_size`:**

| Label | Values | Description |
|-------|--------|-------------|
| `set` | `blacklist_ipv4`, `blacklist_ipv6`, `whitelist_ipv4`, `whitelist_ipv6` | Set name |

**Cardinality:** Fixed at 4. Safe.

---

### 8. Network

| Metric | Type | Unit | Description |
|--------|------|------|-------------|
| `nftban_network_rx_bytes` | counter | bytes | Received bytes per interface |
| `nftban_network_tx_bytes` | counter | bytes | Transmitted bytes per interface |
| `nftban_network_rx_packets` | counter | count | Received packets per interface |
| `nftban_network_tx_packets` | counter | count | Transmitted packets per interface |
| `nftban_network_rx_mbps` | gauge | Mbps | Current receive bandwidth |
| `nftban_network_tx_mbps` | gauge | Mbps | Current transmit bandwidth |
| `nftban_network_total_rx_mbps` | gauge | Mbps | Total receive bandwidth |
| `nftban_network_total_tx_mbps` | gauge | Mbps | Total transmit bandwidth |
| `nftban_bandwidth_peak_rx_mbps` | gauge | Mbps | Peak RX in last 5 min |
| `nftban_bandwidth_peak_tx_mbps` | gauge | Mbps | Peak TX in last 5 min |
| `nftban_connections_active` | gauge | count | Active TCP connections |
| `nftban_connections_established` | gauge | count | Established connections |
| `nftban_connections_time_wait` | gauge | count | TIME_WAIT connections |
| `nftban_connections_close_wait` | gauge | count | CLOSE_WAIT connections |

**Labels for `nftban_network_*` (per-interface):**

| Label | Values | Description |
|-------|--------|-------------|
| `interface` | `eth0`, `ens3`, etc. | Network interface name |

**Cardinality Warning:** Typically 2-10 interfaces. Safe on normal servers.

**Recommended Aggregation:**
- `rx_bytes`, `tx_bytes`: Use `rate()[5m]` to get bytes/second
- `rx_mbps`, `tx_mbps`: Direct value (already a rate)

---

### 9. Protocol Statistics

| Metric | Type | Unit | Description |
|--------|------|------|-------------|
| `nftban_protocol_bytes` | counter | bytes | Bytes per protocol |
| `nftban_protocol_packets` | counter | count | Packets per protocol |

**Labels:**

| Label | Values | Description |
|-------|--------|-------------|
| `protocol` | `tcp`, `udp`, `icmp` | Protocol type |

**Cardinality:** Fixed at 3. Safe.

---

### 10. Threat Feeds

| Metric | Type | Unit | Description |
|--------|------|------|-------------|
| `nftban_feeds_enabled` | gauge | count | Number of enabled feeds |
| `nftban_feeds_ips` | gauge | count | Total IPs from feeds |

**Labels for `nftban_feeds_ips`:**

| Label | Values | Description |
|-------|--------|-------------|
| `family` | `ipv4`, `ipv6` | IP address family |

**Cardinality:** Fixed at 2. Safe.

---

### 11. Health Status

| Metric | Type | Unit | Description |
|--------|------|------|-------------|
| `nftban_health_status` | gauge | enum | Component health (0=OK, 1=WARN, 2=ERROR, 3=CRITICAL) |

**Labels:**

| Label | Values | Description |
|-------|--------|-------------|
| `component` | `nftables`, `polkit`, `ssh` | System component |

**Cardinality:** Fixed at 3. Safe.

---

### 12. Exporter Metadata

| Metric | Type | Unit | Description |
|--------|------|------|-------------|
| `nftban_exporter_duration_seconds` | gauge | seconds | Time to collect metrics |
| `nftban_last_update_timestamp` | gauge | unix timestamp | Last collection time |

---

## Cardinality Summary

| Label | Max Values | Risk |
|-------|------------|------|
| `type` (memory) | 3 | None |
| `type` (pressure) | 3 | None |
| `type` (throughput) | 3 | None |
| `family` | 2 | None |
| `protocol` | 3 | None |
| `action` | 2 | None |
| `reason` | 5 | None |
| `set` | 4 | None |
| `component` | 3 | None |
| `interface` | ~10 | Low |
| `country` | ~250 | Medium - use topk() |

**High-Cardinality Labels NOT Allowed:**
- `ip` - Never expose individual IPs as labels
- `user` - Never expose usernames as labels
- `session_id` - Never expose session IDs

---

## Versioning

This contract follows semantic versioning:

- **MAJOR:** Breaking changes (metric renamed/removed, label meaning changed)
- **MINOR:** New metrics added, new labels added to existing metrics
- **PATCH:** Documentation updates, bug fixes

Current version: **1.0.0**

---

## Compatibility

| Backend | Status | Notes |
|---------|--------|-------|
| Prometheus | Full | Native format |
| Grafana | Full | Via Prometheus datasource |
| Zabbix | Full | Via trapper items |
| InfluxDB | Planned | Via Telegraf |
| Datadog | Planned | Via agent |

---

## References

- [Prometheus Naming Best Practices](https://prometheus.io/docs/practices/naming/)
- [OpenMetrics Specification](https://openmetrics.io/)
- [NFTBan Documentation](https://nftban.com/docs)
