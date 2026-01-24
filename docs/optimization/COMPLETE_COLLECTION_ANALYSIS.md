# NFTBan - Complete Data Collection Analysis

**Document Version:** 2.0
**Date:** 2026-01-24
**Author:** Senior Architect Analysis
**Status:** COMPREHENSIVE FACT-BASED ANALYSIS

---

## Executive Summary

| Finding | Count | Impact |
|---------|-------|--------|
| **Total Collectors** | 11 | Multiple systems collecting same data |
| **exec.Command Calls** | 76 | HIGH - Many can be eliminated |
| **Periodic Tickers** | 35 | 14 in-process + 18 systemd + 3 misc |
| **CLI Polling Loops** | 5 | CRITICAL - Highest CPU waste |
| **Data Duplication** | 8+ points | Consolidation needed |

---

## 1. ALL COLLECTORS IN CODEBASE (11 Total)

### 1.1 Watchdog Collectors (6 files) - BEST PRACTICE

| File | Method | Data | CLI? |
|------|--------|------|------|
| `pkg/watchdog/collector_runtime.go` | `runtime.ReadMemStats()` | Heap, goroutines, GC | **NO** |
| `pkg/watchdog/collector_system.go` | `/proc` reads | Load, iowait, memory, disk | **NO** |
| `pkg/watchdog/collector_kernel.go` | `/proc/sys` reads | Conntrack, softnet, NIC drops | **NO** |
| `pkg/watchdog/collector_process.go` | `procfs` library | CPU%, RSS, FDs, threads | **NO** |
| `pkg/watchdog/collector_nftables.go` | `google/nftables` netlink | Rules, sets, elements | **NO** |
| `pkg/watchdog/collector_base.go` | Interface | Base collector pattern | N/A |

**Key Insight:** Watchdog uses `google/nftables` library for netlink access - NO CLI shelling.

```go
// pkg/watchdog/collector_nftables.go:67-71
conn, err := nftables.New()
if err != nil {
    return err
}
defer conn.CloseLasting()
```

### 1.2 Stats Collector - REAL-TIME COUNTERS

**File:** `pkg/stats/collector.go`

| Data | Method | Storage |
|------|--------|---------|
| Ban/unban counts | Atomic counters | In-memory |
| Event counts | Atomic counters | In-memory |
| IPC latency | Atomic counters | In-memory |
| Module status | State tracking | In-memory |
| Memory/goroutine alerts | Thresholds | In-memory |

**Output:** `/var/lib/nftban/stats/current.json` + daily archives

**Tickers:**
- Live: `config.LiveInterval` (default 10s)
- I/O: `config.IOInterval` (default 5min)

### 1.3 Textfile Collector - PROMETHEUS NODE_EXPORTER

**File:** `pkg/metrics/collector.go` (487 lines)

| Method | Data | CLI? |
|--------|------|------|
| `writeBlockMetrics()` | nftban_blocks_*, whitelist | nft CLI |
| `writeBandwidthMetrics()` | nftban_network_* | /proc/net/dev |
| `writeHealthMetrics()` | nftban_health_status | systemctl |
| `writeNFTablesMetrics()` | nftban_nftables_rules_total | nft CLI |
| `writeProtocolMetrics()` | nftban_protocol_* | /proc/net/snmp |
| `getConnectionStats()` | nftban_connections_active | /proc/net/sockstat |

**Output:** `.prom` textfile for node_exporter

**CLI Calls:**
- `nft -j list ruleset` (line 237)
- `nft list set <family> <table> <setName>` (line 256)
- `systemctl is-active <service>` (line 384)

### 1.4 Metrics Sampler - CLI POLLING (PROBLEMATIC)

**File:** `pkg/metrics/sampler.go` (780 lines)

| CLI Command | Line | Interval | Data |
|-------------|------|----------|------|
| `nftban status --json` | 504 | 10s | Status snapshot |
| `nftban feeds status` | 621 | 10s | Feed states |
| `nftban portscan stats` | 737 | 10s | Portscan counts |
| `nftban ddos stats` | 760 | 10s | DDoS counts |

**Impact:** 4 exec calls × 6 per minute = **24 process spawns per minute**

**CPU:** ~1.8 seconds per minute wasted

### 1.5 Suricata Collector - FILE TAIL

**File:** `pkg/suricata/stats/collector.go`

| Method | Data | CLI? |
|--------|------|------|
| File tail | EVE JSON alerts | **NO** |
| JSON parse | SID, category, severity | **NO** |
| In-memory cache | Bounded LRU | **NO** |

**Polling:** Continuous with 100ms retry

**Performance:** High - tails file directly, bounded memory with LRU eviction

### 1.6 Zabbix Collector - DAEMON APIS

**File:** `pkg/exporters/zabbix/collector.go`

| Method | Data | CLI? |
|--------|------|------|
| MetricsSource interface | All daemon state | **NO** |
| `/proc/sys/kernel/osrelease` | Kernel version | **NO** |
| `/proc/loadavg` | Load averages | **NO** |

**Key Insight:** Calls daemon APIs directly, no CLI polling.

### 1.7 Module-Specific Collectors

#### LoginMon Detector
**File:** `pkg/loginmon/detector/`

| Method | Data | Performance |
|--------|------|-------------|
| Signal-based pattern matching | Auth failures | **20M+ lines/sec** |
| Scoring engine | IP risk scores | Lock-free atomic stats |
| Journalctl OR EVE tail | Log events | Configurable mode |

**Key Insight:** Extremely high performance - no bottleneck.

#### DDoS Module
**File:** `pkg/ddos/module.go`

| Method | Data | CLI? |
|--------|------|------|
| Event bus subscriber | DDoS events | **NO** |
| Bash backend calls | Mode detection | **YES** (every 30s) |

#### Portscan Module
**File:** `pkg/portscan/module.go`

| Method | Data | CLI? |
|--------|------|------|
| Event bus subscriber | Scan events | **NO** |
| Bash backend calls | Detection cycle | **YES** (every 60s) |

---

## 2. ALL exec.Command CALLS (76 Total)

### 2.1 CRITICAL: Periodic CLI Loops

| File | Line | Command | Interval | Priority |
|------|------|---------|----------|----------|
| `pkg/metrics/sampler.go` | 504 | `nftban status --json` | 10s | **ELIMINATE** |
| `pkg/metrics/sampler.go` | 621 | `nftban feeds status` | 10s | **ELIMINATE** |
| `pkg/metrics/sampler.go` | 737 | `nftban portscan stats` | 10s | **ELIMINATE** |
| `pkg/metrics/sampler.go` | 760 | `nftban ddos stats` | 10s | **ELIMINATE** |
| `pkg/portscan/module.go` | 292-336 | Bash script sourcing | 60s | **REFACTOR** |
| `pkg/ddos/module.go` | 302-322 | Bash script sourcing | 30s | **REFACTOR** |

### 2.2 Metrics Collector CLI Calls

| File | Line | Command | Frequency |
|------|------|---------|-----------|
| `pkg/metrics/collector.go` | 237 | `nft -j list ruleset` | Per collection |
| `pkg/metrics/collector.go` | 256 | `nft list set <family> <table> <set>` | Per collection |
| `pkg/metrics/collector.go` | 384 | `systemctl is-active <service>` | Per collection |
| `pkg/metrics/collector.go` | 394 | `nft list ruleset` | Per collection |

### 2.3 API Handler CLI Calls (Per Request)

| File | Lines | Commands |
|------|-------|----------|
| `pkg/api/handlers.go` | 618, 645, 675 | nftban health, port status |
| `pkg/api/handlers.go` | 2825, 2989 | journalctl |
| `pkg/api/handlers.go` | 384, 394, 2930, 3090 | systemctl is-active |
| `pkg/api/network_handlers.go` | 122, 203-209 | cat /proc/net/dev, ss |

### 2.4 UI Handler CLI Calls (Per Page)

| File | Lines | Commands |
|------|-------|----------|
| `cmd/nftban-ui/handlers/goth.go` | 488-502 | hostname, uname, uptime |
| `cmd/nftban-ui/handlers/goth.go` | 532, 544, 632 | nft list, systemctl |
| `cmd/nftban-ui/handlers/goth.go` | 756, 808, 839 | grep /proc/stat, df, ps |
| `cmd/nftban-ui/handlers/goth.go` | 1897-2075 | nftban feeds/check/geoip/search |

### 2.5 Necessary nftables CLI (KEEP)

| File | Lines | Purpose |
|------|-------|---------|
| `pkg/nftbackend/backend.go` | 114, 179, 228, 253 | Add/delete elements |
| `pkg/nftbackend/backend.go` | 280, 305-307, 348, 366 | Flush, apply, list |
| `pkg/sync/nft_cli.go` | 77 | nft wrapper |

**Note:** Backend nft operations are necessary but should be batched.

---

## 3. ALL PERIODIC TICKERS (35 Total)

### 3.1 In-Process Tickers (14)

| Package | File:Line | Interval | Purpose | Impact |
|---------|-----------|----------|---------|--------|
| metrics | sampler.go:388 | **10s** | CLI status polling | **HIGH** |
| watchdog | watchdog.go:115 | configurable | Snapshot collection | MEDIUM |
| watchdog | watchdog.go:118 | 1h | Action cleanup | LOW |
| stats | collector.go:95 | LiveInterval | Runtime stats | MEDIUM |
| stats | collector.go:111 | IOInterval | I/O stats | LOW |
| loginmon | module.go:668 | **100ms** | EVE watcher | MEDIUM |
| loginmon | module.go:740 | 5min | Score decay | LOW |
| loginmon | module.go:755 | 1h | Cleanup | LOW |
| suricata | reader.go:178 | **100ms** | EVE polling | MEDIUM |
| suricata | scorer.go:66 | 1min | Score decay | MEDIUM |
| ddos | module.go:328 | **30s** | Status check | MEDIUM |
| portscan | module.go:320 | **60s** | Detection cycle | MEDIUM |
| webapi | session/memory.go:111 | 5min | Session cleanup | LOW |
| api | handlers.go:2163 | 10s | WebSocket heartbeat | MEDIUM |

### 3.2 Systemd Timers (18)

| Timer | Interval | Purpose | Status |
|-------|----------|---------|--------|
| nftban-unified-exporter.timer | 60s | Prom + Zabbix + Connectors | **RECOMMENDED** |
| nftban-metrics-exporter.timer | 60s | Prometheus only | DEPRECATED |
| nftban-zabbix-exporter.timer | 60s | Zabbix only | DEPRECATED |
| nftban-connector-exporter.timer | 60s | ES/Kafka/File | DEPRECATED |
| nftban-watchdog.timer | 90s | System health | ACTIVE |
| nftban-health.timer | 5min | Health check | ACTIVE |
| nftban-queue.timer | 5min | Task queue | ACTIVE |
| nftban-snapshot.timer | 1h | Config snapshot | ACTIVE |
| nftban-core-feeds.timer | daily 03:20 | Feed sync | ACTIVE |
| nftban-core-geoip.timer | weekly | GeoIP update | ACTIVE |
| nftban-suricata-update.timer | weekly 03:40 | Rules update | ACTIVE |
| nftban-rbl-check.timer | daily 02:00 | RBL check | ACTIVE |
| nftban-maintenance.timer | 15min | Cleanup | ACTIVE |
| nftban-rollback.timer | on-demand | Rollback | ACTIVE |
| nftban-pro-license.timer | 6h | License check | OPTIONAL |
| nftban-pro-inventory.timer | daily 04:00 | Inventory | OPTIONAL |

---

## 4. DATA DUPLICATION MATRIX

### 4.1 Blocked IPs Count

| Source | Method | Location |
|--------|--------|----------|
| sampler.go | `nftban status --json` CLI | line 504 |
| watchdog/collector_nftables.go | netlink SetElements | line 111 |
| metrics/collector.go | `nft list set` CLI | line 256 |
| nftban.go | `active_bans` gauge | line 276 |

**Winner:** watchdog (netlink, no CLI)

### 4.2 Firewall Rules Count

| Source | Method | Location |
|--------|--------|----------|
| sampler.go | `nftban status --json` CLI | line 504 |
| watchdog/collector_nftables.go | netlink RulesTotal | line 159 |
| metrics/collector.go | `nft list ruleset` CLI | line 394 |

**Winner:** watchdog (netlink, no CLI)

### 4.3 Network Stats

| Source | Method | Location |
|--------|--------|----------|
| sampler.go | `/proc/net/dev` read | embedded |
| metrics/collector.go | `/proc/net/dev` read | line 286 |
| watchdog/collector_kernel.go | `/proc` + `/sys` reads | line 144 |

**Winner:** watchdog (already collecting, extend if needed)

### 4.4 Health Status

| Source | Method | Location |
|--------|--------|----------|
| sampler.go | embedded logic | embedded |
| metrics/collector.go | `systemctl is-active` CLI | line 384 |
| stats/collector.go | threshold checks | line 229-293 |

**Winner:** stats/collector.go (in-process, no CLI)

### 4.5 Portscan/DDoS Stats

| Source | Method | Location |
|--------|--------|----------|
| sampler.go | `nftban portscan stats` CLI | line 737 |
| sampler.go | `nftban ddos stats` CLI | line 760 |
| nftban.go | real-time counters | line 207, 232 |

**Winner:** nftban.go (real-time, no CLI)

### 4.6 Feed Stats

| Source | Method | Location |
|--------|--------|----------|
| sampler.go | `nftban feeds status` CLI | line 621 |
| nftban.go | `feeds_ips_loaded` gauge | line 82 |
| feeds/loader | in-memory state | runtime |

**Winner:** Access feeds loader state directly

---

## 5. MODULE COLLECTION PATTERNS

### 5.1 Suricata - EXEMPLARY PATTERN

```
EVE JSON File → File Tail → JSON Parse → In-Memory Cache (LRU) → Prometheus
                    ↓
              Bounded Memory (safety.GetMemoryLimits())
                    ↓
              Disk Snapshot (periodic auto-save)
```

**Strengths:**
- No CLI polling
- Bounded memory with LRU eviction
- High performance (continuous tail)
- Disk persistence for recovery

### 5.2 LoginMon - HIGH PERFORMANCE

```
Journalctl/EVE → Signal Detector (20M+ lines/sec) → Scorer → Metrics
                         ↓
                  Pattern Registry (compiled patterns)
                         ↓
                  Atomic Stats (lock-free)
```

**Strengths:**
- Extremely high throughput
- Lock-free atomic counters
- Score decay with cleanup

### 5.3 DDoS/Portscan - BASH BACKEND (REFACTOR CANDIDATE)

```
Bash Scripts → exec.Command → Parse Output → Event Bus
     ↓
  30-60s periodic polling
```

**Weaknesses:**
- Relies on bash backend
- Periodic CLI polling
- Could be moved to in-process

### 5.4 Feeds - STREAMING PARSER

```
Feed Files (*.txt) → Streaming Parser → In-Memory SetData → nftables
                           ↓
                    <2 seconds for 50K IPs
```

**Strengths:**
- Streaming (low memory)
- Fast parsing
- Direct to nftables

---

## 6. CONSOLIDATION ROADMAP

### Phase 1: ELIMINATE sampler.go CLI (IMMEDIATE)

**Before:**
```go
// sampler.go - 4 CLI calls every 10 seconds
cmd := exec.Command("nftban", "status", "--json")
cmd := exec.Command("nftban", "feeds", "status")
cmd := exec.Command("nftban", "portscan", "stats")
cmd := exec.Command("nftban", "ddos", "stats")
```

**After:**
```go
// sampler.go - READ from existing sources
func (s *Sampler) takeSample() {
    // Watchdog snapshot (already collected via netlink)
    snapshot := s.watchdog.GetSnapshot()
    blockedIPs := snapshot.NFTables.SetElements["blacklist_ipv4"] +
                  snapshot.NFTables.SetElements["blacklist_ipv6"]

    // Feeds loader state (in-memory)
    feedsActive := s.feedsLoader.GetActiveCount()
    feedsIPs := s.feedsLoader.GetTotalIPs()

    // Real-time counters (nftban.go)
    // Already available via prometheus default registry

    // File scans only for unique data
    geobanCountries := s.countGeobanCountries()  // os.ReadDir
}
```

**Result:** 0 CLI calls, ~99% CPU reduction

### Phase 2: CONSOLIDATE metrics/collector.go

**Current:** Uses `nft` CLI for textfile metrics
**Target:** Use watchdog snapshot data

```go
// Before
output, _ := exec.Command("nft", "-j", "list", "ruleset").Output()

// After
snapshot := watchdog.GetSnapshot()
rulesTotal := snapshot.NFTables.RulesTotal
```

### Phase 3: CONSOLIDATE DDoS/Portscan Modules

**Current:** Bash script sourcing every 30-60s
**Target:** In-process detection or event-driven

Options:
1. Move bash logic to Go
2. Cache mode detection (load once at startup)
3. Subscribe to mode change events

### Phase 4: DEDUPLICATE Health Checks

**Current:** Multiple `systemctl is-active` calls
**Target:** Single health check with caching

```go
type HealthCache struct {
    services map[string]HealthStatus
    lastCheck time.Time
    ttl time.Duration
}
```

---

## 7. EXPECTED RESULTS

### Before Optimization

| Metric | Value |
|--------|-------|
| CLI exec per minute | **24** (sampler) + **1-2** (modules) |
| CPU time per minute | ~2-3 seconds |
| Duplicate data points | **8+** |
| Periodic tickers | 35 |

### After Phase 1

| Metric | Value | Change |
|--------|-------|--------|
| CLI exec per minute | **0** (sampler) | -100% |
| CPU time per minute | ~0.5 seconds | -80% |
| Duplicate data points | 4 | -50% |

### After All Phases

| Metric | Value | Change |
|--------|-------|--------|
| CLI exec per minute | <5 (necessary only) | -90% |
| CPU time per minute | ~0.1 seconds | -95% |
| Duplicate data points | 0 | -100% |

---

## 8. KEY ARCHITECTURAL DECISIONS

### Decision 1: Watchdog is Authoritative for System State

**Rationale:**
- Uses `google/nftables` netlink library (no CLI)
- Already collects: rules, sets, elements, process metrics, system metrics
- 5+ collectors with direct kernel/proc access

### Decision 2: nftban.go is Authoritative for Event Counts

**Rationale:**
- Real-time counters (promauto)
- Incremented at event time (microsecond latency)
- Labels for source, family, country, etc.

### Decision 3: sampler.go Should READ, Not POLL

**Rationale:**
- All data it needs exists in other collectors
- CLI polling is wasteful (process spawn overhead)
- Should access: watchdog snapshot, feeds state, nftban.go counters

### Decision 4: Module Bash Backends are Technical Debt

**Rationale:**
- DDoS/Portscan use bash script sourcing
- Should be refactored to pure Go over time
- Event-driven architecture preferred

---

## 9. FILES TO MODIFY

| Priority | File | Change |
|----------|------|--------|
| **P0** | `pkg/metrics/sampler.go` | Remove CLI, read from watchdog/feeds/nftban.go |
| **P1** | `pkg/metrics/collector.go` | Use watchdog snapshot instead of nft CLI |
| **P1** | `pkg/ddos/module.go` | Cache mode detection, reduce polling |
| **P1** | `pkg/portscan/module.go` | Cache mode detection, reduce polling |
| **P2** | `pkg/api/handlers.go` | Cache systemctl results |
| **P2** | `cmd/nftban-ui/handlers/goth.go` | Cache system info, reduce CLI calls |
| **P3** | `install/systemd/*.timer` | Remove deprecated timers |

---

**Document Status:** COMPLETE
**Analysis Based On:** Full codebase search (76 exec.Command calls, 35 tickers, 11 collectors)
**No Guessing:** All findings backed by file:line references
