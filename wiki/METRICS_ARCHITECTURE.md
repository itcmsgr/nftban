# NFTBan Metrics Architecture

**Version:** 1.0.0
**Status:** STABLE
**Last Updated:** 2026-01-24

---

## Design Philosophy

NFTBan is a **metrics producer**, not a monitoring product.

We expose a stable OpenMetrics schema. Users choose how they ingest, store, and visualize.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         NFTBan Metrics Architecture                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                              │
│   ┌──────────────────┐                                                       │
│   │     nftband      │ ← Go daemon (schema v2)                               │
│   │   (IPC socket)   │                                                       │
│   └────────┬─────────┘                                                       │
│            │                                                                 │
│            │ JSON (watchdog, runtime, ipc, throughput)                       │
│            ▼                                                                 │
│   ┌──────────────────────────────────────────────────────────────────┐      │
│   │              nftban_metrics_collector.sh                          │      │
│   │                    (CENTRAL HUB)                                  │      │
│   │                                                                    │      │
│   │  Collects from:                                                    │      │
│   │  • Daemon IPC (schema v2 stats)                                    │      │
│   │  • nftables via netlink (ban counts, rules)                        │      │
│   │  • /proc (system load, memory, network)                            │      │
│   │  • Feeds loader (active feeds, IPs loaded)                         │      │
│   │                                                                    │      │
│   │  Outputs: combined.json (canonical schema)                         │      │
│   └───────────────────────────┬──────────────────────────────────────┘      │
│                               │                                              │
│               ┌───────────────┼───────────────┬───────────────┐              │
│               ▼               ▼               ▼               ▼              │
│   ┌───────────────┐   ┌───────────────┐   ┌───────────────┐   ┌──────────┐  │
│   │   Prometheus  │   │    Zabbix     │   │   InfluxDB    │   │  Custom  │  │
│   │   Exporter    │   │   Exporter    │   │   (future)    │   │   Sink   │  │
│   │               │   │               │   │               │   │          │  │
│   │ OpenMetrics   │   │ Zabbix trap   │   │ Line protocol │   │ Your API │  │
│   └───────┬───────┘   └───────┬───────┘   └───────────────┘   └──────────┘  │
│           │                   │                                              │
│           ▼                   ▼                                              │
│   ┌───────────────┐   ┌───────────────┐                                     │
│   │  Prometheus   │   │    Zabbix     │                                     │
│   │  / Victoria   │   │    Server    │                                     │
│   │  / Mimir      │   │              │                                     │
│   └───────┬───────┘   └───────────────┘                                     │
│           │                                                                  │
│           ▼                                                                  │
│   ┌───────────────┐                                                         │
│   │    Grafana    │ ← Recommended for visualization                         │
│   └───────────────┘                                                         │
│                                                                              │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## What NFTBan Provides

### Supported

| Capability | Status |
|------------|--------|
| OpenMetrics/Prometheus format | Full |
| Zabbix ingestion (trapper items) | Full |
| Stable metric naming | Guaranteed |
| Controlled label cardinality | Enforced |
| Reference Grafana dashboard | Provided |
| PromQL examples | Provided |
| Alert rule examples | Provided |

### Out of Scope (By Design)

| Capability | Status |
|------------|--------|
| Maintaining TSDB-specific configs | Not provided |
| Opinionated visualization | Not provided |
| Agent recommendations | User choice |
| Storage recommendations | User choice |

---

## Compatibility Matrix

| Consumer | Protocol | Status |
|----------|----------|--------|
| Prometheus | Scrape | Full |
| VictoriaMetrics | Scrape | Full |
| Grafana Mimir | Scrape | Full |
| Zabbix | Trapper | Full |
| Datadog | Agent | Planned |
| InfluxDB | Telegraf | Planned |
| OpenTelemetry | OTLP | Planned |

---

## Contract Stability

We guarantee:

| Aspect | Guarantee |
|--------|-----------|
| Metric names | Stable (semantic versioning) |
| Label names | Stable |
| Label values | Bounded sets documented |
| Counter behavior | Standard (resets on restart) |
| Units | Documented and stable |

Breaking changes (metric rename, removal, semantic change) require major version bump.

---

## Cardinality Control

### Safe Labels (bounded)

| Label | Max Cardinality |
|-------|-----------------|
| `type` | 3-5 |
| `family` | 2 |
| `action` | 2 |
| `reason` | 5 |
| `protocol` | 3 |
| `component` | 3 |
| `set` | 4 |

### Moderate Labels (bounded but larger)

| Label | Max Cardinality | Mitigation |
|-------|-----------------|------------|
| `interface` | ~10 | Filter in queries |
| `country` | ~250 | Use `topk()` |

### Forbidden Labels

| Label | Status | Reason |
|-------|--------|--------|
| `ip` | Never | Unbounded |
| `user` | Never | Unbounded |
| `session_id` | Never | Unbounded |
| `request_id` | Never | Unbounded |

---

## Files Provided

| File | Purpose |
|------|---------|
| `METRICS_CONTRACT.md` | Authoritative schema definition |
| `GRAFANA_DASHBOARD.json` | Import-ready Grafana dashboard |
| `PROMQL_EXAMPLES.md` | Copy-paste PromQL queries |
| `share/templates/zabbix/*.yaml` | Zabbix items/triggers (no dashboards) |

---

## Quick Start

### Prometheus

1. Configure scrape:
```yaml
scrape_configs:
  - job_name: 'nftban'
    static_configs:
      - targets: ['your-server:9100']
```

2. Import Grafana dashboard from `GRAFANA_DASHBOARD.json`

3. Done.

### Zabbix

1. Import template from `share/templates/zabbix/`
2. Link template to hosts
3. Configure Zabbix agent or proxy
4. Use Grafana with Zabbix datasource for visualization

---

## Summary

NFTBan produces correct, stable metrics in OpenMetrics format.

The ecosystem consumes them.

**That is exactly where we want to be.**
