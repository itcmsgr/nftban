# NFTBan Metrics - Final Architecture Decision

**Document Version:** 1.0
**Date:** 2026-01-24
**Status:** APPROVED FOR IMPLEMENTATION

---

## Executive Summary

After comprehensive analysis of the entire codebase:

| Analyzed | Count |
|----------|-------|
| Collectors | **11** |
| exec.Command calls | **76** |
| Periodic tickers | **35** |
| Data duplication points | **8+** |

**Key Decision:** ELIMINATE CLI polling, REUSE existing collectors.

---

## The Problem

### sampler.go is Wasteful

```go
// pkg/metrics/sampler.go - CURRENT (BAD)
// Every 10 seconds, spawns 4 processes:

cmd := exec.Command("nftban", "status", "--json")     // 50-200ms
cmd := exec.Command("nftban", "feeds", "status")      // 30-100ms
cmd := exec.Command("nftban", "portscan", "stats")    // 30-100ms
cmd := exec.Command("nftban", "ddos", "stats")        // 30-100ms

// Result: 24 process spawns per minute, ~1.8s CPU wasted
```

### But We Already Have the Data!

```
┌─────────────────────────────────────────────────────────────────────┐
│                    EXISTING COLLECTORS (NO CLI)                      │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  watchdog/collector_nftables.go:                                     │
│  ├── conn, _ := nftables.New()     // NETLINK, not CLI              │
│  ├── conn.ListTables()             // Direct kernel access           │
│  ├── conn.GetSets(table)           // Set metadata                   │
│  ├── conn.GetSetElements(set)      // Element counts                 │
│  └── conn.GetRules(table, chain)   // Rule counts                    │
│                                                                      │
│  nftban.go:                                                          │
│  ├── nftban_bans_total             // Real-time counter              │
│  ├── nftban_portscan_bans_total    // Real-time counter              │
│  └── nftban_ddos_mitigations_total // Real-time counter              │
│                                                                      │
│  feeds/loader (in-memory):                                           │
│  ├── GetActiveCount()              // Active feeds                   │
│  └── GetTotalIPs()                 // Total IPs loaded               │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## The Solution

### sampler.go Should READ, Not POLL

```go
// pkg/metrics/sampler.go - AFTER (GOOD)
func (s *Sampler) takeSample() {
    // 1. Get watchdog snapshot (already collected via netlink)
    snapshot := s.watchdog.GetSnapshot()

    // 2. Read nftables data (NO CLI)
    blockedIPv4 := snapshot.NFTables.SetElements["blacklist_ipv4"]
    blockedIPv6 := snapshot.NFTables.SetElements["blacklist_ipv6"]
    rulesTotal := snapshot.NFTables.RulesTotal

    // 3. Read feeds state (in-memory, NO CLI)
    feedsActive := s.feedsLoader.GetActiveCount()
    feedsIPs := s.feedsLoader.GetTotalIPs()

    // 4. File scans for unique data only (cheap, NO CLI)
    geobanCountries := countDir("/var/lib/nftban/geoban/tracking")
    blacklistIPs := countDir("/etc/nftban/blacklist.d")

    // 5. Internal state (unique to sampler)
    sessions := s.activeSessions
    uptime := time.Since(s.startTime)

    // Update gauges
    s.blockedIPsGauge.Set(float64(blockedIPv4 + blockedIPv6))
    s.rulesGauge.Set(float64(rulesTotal))
    s.feedsActiveGauge.Set(float64(feedsActive))
    // ...
}

// Result: 0 process spawns, ~0.01s CPU
```

---

## Data Source Mapping

| sampler.go Metric | Source | Method | File:Line |
|-------------------|--------|--------|-----------|
| `blocked_ips_total` | watchdog | netlink SetElements | collector_nftables.go:111 |
| `firewall_rules_total` | watchdog | netlink GetRules | collector_nftables.go:159 |
| `whitelist_ips_total` | watchdog | netlink SetElements | collector_nftables.go:111 |
| `portscan_blocks_total` | nftban.go | real-time counter | nftban.go:221 |
| `ddos_blocks_total` | nftban.go | real-time counter | nftban.go:239 |
| `feeds_active_total` | feeds/loader | in-memory state | runtime |
| `feeds_total_ips` | feeds/loader | in-memory state | runtime |
| `network_rx/tx_mbps` | watchdog | extend collector | collector_kernel.go |
| `health_status` | stats/collector | threshold checks | collector.go:229-293 |
| `geoban_countries` | filesystem | os.ReadDir | unique to sampler |
| `blacklist_ips` | filesystem | os.ReadDir | unique to sampler |
| `sessions_total` | sampler | internal state | unique to sampler |
| `uptime_seconds` | sampler | internal state | unique to sampler |

---

## Implementation Checklist

### Phase 1: sampler.go Refactor (IMMEDIATE)

- [ ] Add watchdog reference to sampler struct
- [ ] Add feeds loader reference to sampler struct
- [ ] Replace `nftban status --json` with watchdog.GetSnapshot()
- [ ] Replace `nftban feeds status` with feedsLoader.GetActiveCount()
- [ ] Replace `nftban portscan stats` with reading nftban.go counter
- [ ] Replace `nftban ddos stats` with reading nftban.go counter
- [ ] Keep filesystem scans for geoban/blacklist (unique data)
- [ ] Keep internal state for sessions/uptime (unique data)
- [ ] Remove all exec.Command calls from sampler.go

### Phase 2: metrics/collector.go Optimization

- [ ] Replace `nft -j list ruleset` with watchdog snapshot
- [ ] Replace `nft list set` with watchdog snapshot
- [ ] Keep `/proc` reads (already efficient)
- [ ] Cache `systemctl is-active` results

### Phase 3: Module Optimization

- [ ] DDoS: Cache mode detection at startup
- [ ] Portscan: Cache mode detection at startup
- [ ] Reduce bash script polling frequency

### Phase 4: Cleanup

- [ ] Remove deprecated systemd timers
- [ ] Document authoritative data sources
- [ ] Update dashboards if metric names change

---

## Expected Results

| Metric | Before | After Phase 1 | After All |
|--------|--------|---------------|-----------|
| CLI exec/minute | 24 | **0** | **<5** |
| CPU time/minute | ~2s | **~0.01s** | **~0.05s** |
| Data duplication | 8+ | 4 | **0** |
| Process spawns | 24+/min | **0** | **minimal** |

---

## Architecture Principles Established

### 0. Two-Tier Metrics Collection (NON-NEGOTIABLE)

```
┌─────────────────────────────────────────────────────────────────────┐
│                    TWO-TIER METRICS SYSTEM                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  BASIC TIER (Always ON):                                             │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │ • Banned IPs count      → watchdog netlink (no CLI)            ││
│  │ • Whitelist IPs count   → watchdog netlink (no CLI)            ││
│  │ • Feeds active/IPs      → in-memory loader (no CLI)            ││
│  │ • Cost: ~5ms/minute                                             ││
│  │ • Purpose: UI dashboard, basic health                           ││
│  └─────────────────────────────────────────────────────────────────┘│
│                                                                      │
│  FULL TIER (When NFTBAN_METRICS_ENABLED=true):                       │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │ • All 93 Prometheus metrics                                     ││
│  │ • Textfile collector output                                     ││
│  │ • promauto counters                                             ││
│  │ • /metrics endpoint                                             ││
│  │ • Cost: ~50ms/minute                                            ││
│  │ • Purpose: Prometheus, Zabbix, Grafana                          ││
│  └─────────────────────────────────────────────────────────────────┘│
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

**Rationale:**
- BASIC tier ensures UI always works, regardless of metrics config
- FULL tier is optional - user chooses if they need detailed observability
- Both tiers use NO CLI polling (netlink + in-memory only)

### 1. Watchdog is Authoritative for System State

The watchdog collectors use `google/nftables` netlink library for direct kernel access:
- No CLI shelling
- Already collects rules, sets, elements, process metrics
- Other components should READ from watchdog snapshot

### 2. nftban.go is Authoritative for Event Counts

Real-time counters incremented at event time:
- Bans, unbans, detections
- Labels for source, family, country
- Other components should NOT duplicate these counts

### 3. CLI Exec is Technical Debt

Every `exec.Command` should be questioned:
- Can we use a Go library instead?
- Can we read from /proc directly?
- Can we access in-memory state?
- Is the data already collected elsewhere?

### 4. Two Metrics Endpoints are Valid

Current architecture with two endpoints is VALID:
- `nftband:8080/metrics` - default registry (promauto)
- `nftban-ui:8443/metrics` - sampler registry

Prometheus scrapes both. No need to merge registries.

---

## Related Documents

| Document | Purpose |
|----------|---------|
| `COMPLETE_COLLECTION_ANALYSIS.md` | Full analysis of 76 exec.Command calls, 35 tickers, 11 collectors |
| `METRICS_SYSTEM_HLD.md` | Prometheus metrics inventory (93 metrics) |
| `ZABBIX_WATCHDOG_HLD.md` | Zabbix exporter and watchdog system analysis |
| `GAP_ANALYSIS_AND_OPTIMIZATION.md` | Gap analysis and optimization roadmap |
| `METRICS_COLLECTION_AND_OPTIMIZATION.md` | Collection mechanisms and performance analysis |

---

**Decision Status:** APPROVED
**Implementation Priority:** P0
**Estimated Effort:** Phase 1 = 1-2 days, All Phases = 2 weeks
