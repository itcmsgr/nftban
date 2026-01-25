# NFTBan Metrics Architecture

**Version:** 1.1.0
**Status:** STABLE
**Last Updated:** 2026-01-25

---

## Design Philosophy

**NFTBan is a metrics producer, not a monitoring product.**

NFTBan exposes metrics in OpenMetrics format. Users choose their own backend for ingestion, storage, and visualization.

### What This Means

| NFTBan Provides | User Chooses |
|-----------------|--------------|
| OpenMetrics endpoint (`/metrics`) | Scraping agent (Prometheus, vmagent, Grafana Agent) |
| Textfile collector output (`.prom`) | Storage backend (Prometheus TSDB, VictoriaMetrics, Mimir) |
| Stable metric naming contract | Visualization (Grafana, custom dashboards) |
| Bounded label cardinality | Alerting rules and thresholds |
| Reference dashboard JSON | Long-term retention (external TSDB) |

### What NFTBan Does NOT Provide

- **No bundled TSDB** - We don't ship Prometheus or VictoriaMetrics
- **No bundled agent** - User installs their preferred scraper
- **No analytics** - NFTBan is a firewall, not a BI tool
- **No managed dashboards** - We provide templates, user maintains them
- **No unlimited retention** - Local storage capped at 4 weeks

### Local Retention Policy

| Setting | Value |
|---------|-------|
| Options | 1, 2, 3, or 4 weeks |
| Default | 2 weeks |
| Hard maximum | 4 weeks (not overridable) |

Long-term storage beyond 4 weeks is the user's responsibility via their external TSDB.

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

### Provided

| Capability | Status | Notes |
|------------|--------|-------|
| OpenMetrics/Prometheus format | Full | Native `/metrics` endpoint |
| Zabbix trapper items | Full | Optional push via `zabbix_sender` |
| Stable metric naming | Guaranteed | Semantic versioning for changes |
| Bounded label cardinality | Enforced | No unbounded labels |
| Reference Grafana dashboard | Provided | JSON template for import |
| PromQL examples | Provided | Copy-paste queries |
| Alert rule examples | Provided | YAML templates |

### Not Provided (By Design)

| Capability | Status | Why |
|------------|--------|-----|
| Bundled TSDB | Not provided | User chooses backend |
| Bundled scraping agent | Not provided | User chooses agent |
| Long-term storage (>4 weeks) | Not provided | External TSDB responsibility |
| Managed dashboards | Not provided | User maintains their own |
| TSDB-specific tuning | Not provided | Backend-dependent |
| Analytics or BI | Not provided | NFTBan is a firewall |

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

**NFTBan produces metrics. You consume them.**

| What | How |
|------|-----|
| Format | OpenMetrics (Prometheus compatible) |
| Endpoint | `/metrics` on port 8080 (optional) |
| Textfile | `/var/lib/node_exporter/textfile_collector/nftban.prom` (optional) |
| Zabbix | Push via `zabbix_sender` (optional) |
| Local retention | 1-4 weeks (default: 2, max: 4) |
| Long-term | Your TSDB (Prometheus, VictoriaMetrics, Mimir, etc.) |

### Integration Pattern

```
NFTBan ──► OpenMetrics ──► Your Scraper ──► Your TSDB ──► Your Dashboard
         (producer)      (your choice)    (your choice)   (your choice)
```

**NFTBan is not a monitoring product. It's a secure firewall that happens to expose good metrics.**
