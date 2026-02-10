# Metrics

NFTBan exposes metrics in OpenMetrics format for monitoring and alerting.

---

## Table of Contents
- [Purpose](#purpose)
- [Prerequisites](#prerequisites)
- [CLI Commands](#cli-commands)
- [Architecture](#architecture)
- [Metrics Reference](#metrics-reference)
- [PromQL Examples](#promql-examples)
- [Alert Rules](#alert-rules)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)
- [References](#references)

---

## Purpose

**NFTBan is a metrics producer, not a monitoring product.**

| NFTBan Provides | User Chooses |
|-----------------|--------------|
| OpenMetrics endpoint (`/metrics`) | Scraping agent (Prometheus, vmagent) |
| Textfile collector output (`.prom`) | Storage backend (Prometheus, VictoriaMetrics) |
| Stable metric naming | Visualization (Grafana) |
| Reference dashboard JSON | Alerting rules and thresholds |

---

## Prerequisites

| Requirement | Details |
|-------------|---------|
| nftban | Version 1.10.0+ |
| Prometheus/VictoriaMetrics | For scraping and storage |
| Grafana | For visualization (optional) |
| node_exporter | For textfile collector method |

---

## CLI Commands

### Enable/Disable Metrics
```bash
nftban metrics enable
nftban metrics disable
```

### Status
```bash
nftban metrics status
```

### Export to File
```bash
nftban metrics export --format prometheus
```

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    NFTBan Metrics Architecture                       │
├─────────────────────────────────────────────────────────────────────┤
│   ┌──────────────────┐                                              │
│   │     nftband      │ ← Go daemon                                  │
│   │   (IPC socket)   │                                              │
│   └────────┬─────────┘                                              │
│            │ JSON (watchdog, runtime, ipc, throughput)              │
│            ▼                                                         │
│   ┌──────────────────────────────────────────────────────┐          │
│   │         nftban_metrics_collector.sh                   │          │
│   │                  (CENTRAL HUB)                        │          │
│   │  Collects from: Daemon IPC, nftables, /proc, feeds    │          │
│   └───────────────────────┬──────────────────────────────┘          │
│               ┌───────────┼───────────┐                              │
│               ▼           ▼           ▼                              │
│       ┌───────────┐ ┌───────────┐ ┌───────────┐                     │
│       │Prometheus │ │  Zabbix   │ │  Custom   │                     │
│       │ Exporter  │ │ Exporter  │ │   Sink    │                     │
│       └─────┬─────┘ └─────┬─────┘ └───────────┘                     │
│             ▼             ▼                                          │
│       ┌───────────┐ ┌───────────┐                                   │
│       │Prometheus │ │  Zabbix   │                                   │
│       │/Victoria  │ │  Server   │                                   │
│       └─────┬─────┘ └───────────┘                                   │
│             ▼                                                        │
│       ┌───────────┐                                                 │
│       │  Grafana  │                                                 │
│       └───────────┘                                                 │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Metrics Reference

### Daemon Status
| Metric | Type | Description |
|--------|------|-------------|
| `nftban_daemon_up` | gauge | 1 if running, 0 if down |
| `nftban_daemon_uptime_seconds` | gauge | Uptime since start |

### Watchdog Pressure
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `nftban_watchdog_pressure_score` | gauge | `type`=cpu/memory/io | System pressure (0-100) |

Interpretation: 0-40 normal, 40-60 elevated, 60-80 degraded, 80-100 critical.

### Go Runtime
| Metric | Type | Description |
|--------|------|-------------|
| `nftban_runtime_goroutines` | gauge | Active goroutines |
| `nftban_runtime_memory_bytes` | gauge | Memory by type (heap/alloc/sys) |
| `nftban_runtime_gc_cycles_total` | counter | Total GC cycles |

### IPC
| Metric | Type | Description |
|--------|------|-------------|
| `nftban_ipc_requests_total` | counter | Total IPC requests |
| `nftban_ipc_latency_seconds` | gauge | Average latency |
| `nftban_ipc_errors_total` | counter | Total IPC errors |

### Throughput
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `nftban_throughput_total` | counter | `type`=bans/unbans/events | Event counts |
| `nftban_throughput_bans_per_minute` | gauge | - | Current ban rate |

### Blocks & Bans
| Metric | Type | Description |
|--------|------|-------------|
| `nftban_blocks_total` | gauge | Current blocked IPs |
| `nftban_banned_ips` | gauge | IPs by family/type |
| `nftban_bans_last_24h` | gauge | Bans in last 24h |
| `nftban_blocks_by_country` | gauge | Blocked per country |

### Firewall
| Metric | Type | Labels | Description |
|--------|------|--------|-------------|
| `nftban_firewall_packets_total` | counter | `action`, `reason` | Packets by action |
| `nftban_set_size` | gauge | `set` | nftables set sizes |

### Network
| Metric | Type | Description |
|--------|------|-------------|
| `nftban_network_rx_mbps` | gauge | Receive bandwidth |
| `nftban_network_tx_mbps` | gauge | Transmit bandwidth |
| `nftban_connections_active` | gauge | Active connections |

### Cardinality Summary
| Label | Max Values | Risk |
|-------|------------|------|
| `type` | 3 | None |
| `family` | 2 | None |
| `protocol` | 3 | None |
| `interface` | ~10 | Low |
| `country` | ~250 | Use topk() |

**Forbidden labels:** `ip`, `user`, `session_id` (unbounded).

---

## PromQL Examples

### Status
```promql
# Daemon up/down
nftban_daemon_up

# Max pressure (any dimension)
max(nftban_watchdog_pressure_score)
```

### Bans
```promql
# Ban rate (per second)
rate(nftban_throughput_total{type="bans"}[5m])

# Top 10 countries blocked
topk(10, nftban_blocks_by_country)

# Bans in last 24h
nftban_bans_last_24h
```

### Firewall
```promql
# Blacklist drops rate
rate(nftban_firewall_packets_total{action="drop",reason="blacklist"}[5m])

# Set sizes
nftban_set_size{set="blacklist_ipv4"}
```

### Network
```promql
# Total bandwidth
nftban_network_total_rx_mbps
nftban_network_total_tx_mbps

# Active connections
nftban_connections_active
```

### Runtime
```promql
# Heap memory (MB)
nftban_runtime_memory_bytes{type="heap"} / 1024 / 1024

# Goroutines
nftban_runtime_goroutines
```

---

## Alert Rules

### Daemon Down
```yaml
- alert: NFTBanDaemonDown
  expr: nftban_daemon_up == 0
  for: 1m
  labels:
    severity: critical
```

### High Memory Pressure
```yaml
- alert: NFTBanHighMemoryPressure
  expr: nftban_watchdog_pressure_score{type="memory"} > 80
  for: 5m
  labels:
    severity: warning
```

### High Ban Rate
```yaml
- alert: NFTBanHighBanRate
  expr: rate(nftban_throughput_total{type="bans"}[5m]) > 10
  for: 5m
  labels:
    severity: warning
```

### Goroutine Leak
```yaml
- alert: NFTBanGoroutineLeak
  expr: nftban_runtime_goroutines > 1000
  for: 10m
  labels:
    severity: warning
```

---

## Configuration

### Prometheus Scrape Config
```yaml
scrape_configs:
  - job_name: 'nftban'
    static_configs:
      - targets: ['localhost:9100']  # node_exporter
```

### Local Retention
| Setting | Value |
|---------|-------|
| Options | 1, 2, 3, or 4 weeks |
| Default | 2 weeks |
| Hard maximum | 4 weeks |

Long-term storage is user's responsibility via external TSDB.

---

## Troubleshooting

### Metrics Not Updating

**Cause:** Collector not running or daemon down.

**Fix:**
```bash
nftban metrics status
systemctl status nftband
```

### High Cardinality Warning

**Cause:** Too many unique label values (usually `country`).

**Fix:** Use `topk()` in queries:
```promql
topk(10, nftban_blocks_by_country)
```

### Scrape Timeout

**Cause:** Slow metric collection.

**Fix:** Increase scrape timeout in Prometheus:
```yaml
scrape_configs:
  - job_name: 'nftban'
    scrape_timeout: 30s
```

---

## References

- [Prometheus Naming Best Practices](https://prometheus.io/docs/practices/naming/)
- [OpenMetrics Specification](https://openmetrics.io/)
- Source: `/usr/lib/nftban/exporters/`
- Config: `/etc/nftban/conf.d/metrics.conf`
- Dashboard: `/usr/share/nftban/templates/grafana/`
