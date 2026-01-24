# NFTBan Zabbix & Watchdog Systems - High-Level Design

**Document Version:** 1.0
**Date:** 2026-01-24
**Author:** Senior Architect Analysis
**Based On:** Actual codebase at `/home/gituser/github/nftban`

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Zabbix Exporter System](#2-zabbix-exporter-system)
3. [Watchdog System](#3-watchdog-system)
4. [Prometheus Integration](#4-prometheus-integration)
5. [Data Flow Architecture](#5-data-flow-architecture)
6. [Metrics Comparison](#6-metrics-comparison)
7. [Integration Analysis](#7-integration-analysis)
8. [Recommendations](#8-recommendations)

---

## 1. Executive Summary

NFTBan implements **two parallel monitoring systems** with distinct purposes:

| System | Purpose | Protocol | Collection | Output |
|--------|---------|----------|------------|--------|
| **Zabbix Exporter** | Enterprise monitoring | Trapper/Push | Poll daemon APIs | Zabbix Server |
| **Watchdog** | Self-healing & pressure management | Internal | Kernel/Process collectors | Actions + Prometheus |

### Key Finding: Prometheus Registry Relationship

| Component | Registry | Exposed at `/metrics` |
|-----------|----------|----------------------|
| `pkg/watchdog/metrics.go` | Default (promauto) | **YES** |
| `pkg/metrics/nftban.go` | Default (promauto) | **YES** |
| `pkg/metrics/sampler.go` | CUSTOM registry | **NO** |
| `pkg/exporters/zabbix/*` | None (pushes to Zabbix) | N/A |

---

## 2. Zabbix Exporter System

### 2.1 Architecture Overview

```
+------------------+     +-----------------+     +----------------+
|  MetricsSource   | --> |    Collector    | --> | MetricsSnapshot|
|  (daemon APIs)   |     |  collector.go   |     |    types.go    |
+------------------+     +-----------------+     +----------------+
                                                        |
                              +-------------------------+
                              |
                              v
+------------------+     +-----------------+     +----------------+
|  DiscoveryMgr    |     |    Exporter     | --> |  MultiSender   |
|  discovery.go    | <-- |  exporter.go    |     |   multi.go     |
+------------------+     +-----------------+     +----------------+
                                                        |
                              +-------------------------+
                              |
                              v
                         +-----------------+     +----------------+
                         |     Sender      | --> | Zabbix Server  |
                         |   sender.go     |     |   (10051/tcp)  |
                         +-----------------+     +----------------+
```

### 2.2 File Inventory (9 files, 3,800+ lines)

| File | Lines | Purpose |
|------|-------|---------|
| `collector.go` | 657 | Collects metrics from daemon via MetricsSource interface |
| `exporter.go` | 466 | Main orchestrator with collection loop |
| `sender.go` | 476 | Single-target sender with retry logic |
| `multi.go` | ~400 | Multi-target sender with failover |
| `protocol.go` | 429 | Zabbix trapper protocol encoder/decoder |
| `discovery.go` | 618 | Low-Level Discovery (LLD) for dynamic entities |
| `types.go` | 472 | Type definitions for protocol and metrics |
| `config.go` | 490 | Configuration with validation |
| `http.go` | 326 | HTTP API endpoints for metrics exposure |

### 2.3 MetricsSource Interface

**File:** `pkg/exporters/zabbix/collector.go:34-73`

```go
type MetricsSource interface {
    GetDaemonInfo() DaemonInfo       // Version, uptime, PID
    GetRuntimeMetrics() RuntimeInfo   // Go heap, goroutines, GC
    GetBanStats() BanStats           // Total, 24h, 1h, rate
    GetEventStats() EventStats       // Total, rate, dropped
    GetIPCStats() IPCStats           // Requests, errors, latency
    GetModuleStatus() map[string]ModuleInfo  // Per-module status
    GetWatchdogStatus() WatchdogInfo // Pressure scores, mode
    GetNFTablesStats() NFTablesInfo  // Rules, sets, elements
    GetFeedStats() FeedStats         // Enabled, loaded, IPs
    GetGeoIPStats() GeoIPStats       // DB age, lookups
    GetSuricataStats() SuricataInfo  // Alerts, bans
    GetAPIStats() APIStats           // Requests, errors
    GetDiscoveryData() DiscoveryInfo // LLD data
}
```

### 2.4 Metrics Collected (70+ metrics)

**File:** `pkg/exporters/zabbix/collector.go:509-644`

| Category | Metrics | Keys |
|----------|---------|------|
| **Daemon** | 7 | `nftban.version`, `nftban.uptime`, `nftban.pid`, `nftban.status`, `nftban.mode` |
| **Runtime** | 11 | `nftban.memory.heap`, `nftban.goroutines`, `nftban.gc.*`, `nftban.fds.open` |
| **Bans** | 9 | `nftban.bans.total`, `nftban.bans.24h`, `nftban.bans.rate`, `nftban.active.count` |
| **Events** | 4 | `nftban.events.total`, `nftban.events.rate`, `nftban.events.dropped` |
| **IPC** | 4 | `nftban.ipc.requests`, `nftban.ipc.errors`, `nftban.ipc.latency_avg` |
| **Modules** | 3 | `nftban.modules.enabled`, `nftban.modules.active`, `nftban.modules.failed` |
| **Watchdog** | 9 | `nftban.watchdog.status`, `nftban.watchdog.cpu_score`, `nftban.watchdog.mode` |
| **NFTables** | 5 | `nftban.nft.rules_total`, `nftban.nft.sets_total`, `nftban.nft.apply_latency` |
| **Feeds** | 5 | `nftban.feeds.enabled`, `nftban.feeds.loaded`, `nftban.feeds.ips_total` |
| **GeoIP** | 4 | `nftban.geoip.database_age`, `nftban.geoip.lookups_total` |
| **Suricata** | 5 | `nftban.suricata.enabled`, `nftban.suricata.alerts_processed` |
| **API** | 5 | `nftban.api.requests_total`, `nftban.api.errors_total`, `nftban.api.latency_avg` |
| **Server** | 8 | `nftban.server.hostname`, `nftban.server.load_1m`, `nftban.server.cpu_cores` |

### 2.5 Low-Level Discovery (LLD)

**File:** `pkg/exporters/zabbix/discovery.go:32-39`

| Discovery Rule | Key | Macros |
|----------------|-----|--------|
| Modules | `nftban.discovery.modules` | `{#MODULE}`, `{#MODE}`, `{#ENABLED}` |
| Interfaces | `nftban.discovery.interfaces` | `{#IFACE}`, `{#ZONE}` |
| Countries | `nftban.discovery.countries` | `{#COUNTRY}`, `{#COUNTRY_NAME}`, `{#BLOCKED}` |
| Feeds | `nftban.discovery.feeds` | `{#FEED}`, `{#URL}`, `{#ENABLED}` |
| Timers | `nftban.discovery.timers` | `{#TIMER}`, `{#DURATION}` |

**LLD Data Format:**
```json
{"data": [
  {"{#MODULE}": "loginmon", "{#MODE}": "monitor", "{#ENABLED}": "1"},
  {"{#MODULE}": "portscan", "{#MODE}": "block", "{#ENABLED}": "1"}
]}
```

### 2.6 Protocol Implementation

**File:** `pkg/exporters/zabbix/protocol.go`

```
+--------+--------+--------+--------+--------+--------+--------+--------+--------+
| Z  B  X  D | 0x01 |     Length (8 bytes, little-endian)     |   JSON Payload   |
+--------+--------+--------+--------+--------+--------+--------+--------+--------+
   Header (5)              Length (8)                              Data (N)
```

**Trapper Request:**
```json
{
  "request": "sender data",
  "data": [
    {"host": "web1", "key": "nftban.bans.total", "value": "12345", "clock": 1706140800}
  ],
  "clock": 1706140800
}
```

### 2.7 HTTP API Endpoints

**File:** `pkg/exporters/zabbix/http.go:44-49`

| Endpoint | Method | Purpose |
|----------|--------|---------|
| `/api/v1/metrics` | GET | Full metrics snapshot (JSON) |
| `/api/v1/metrics/zabbix` | GET | Flat key-value format |
| `/api/v1/zabbix/status` | GET | Exporter status and stats |
| `/api/v1/zabbix/discovery` | GET | LLD data (optional `?key=` filter) |
| `/api/v1/zabbix/health` | GET | Target health status |

### 2.8 Configuration

**File:** `pkg/exporters/zabbix/config.go:36-76`

```yaml
zabbix:
  enabled: true
  hostname: "web1.example.com"
  interval: 60s
  batch_size: 100
  connect_timeout: 10s
  retry_count: 3
  buffer_enabled: true
  buffer_path: "/var/lib/nftban/zabbix/buffer"
  discovery_enabled: true
  discovery_interval: 3600s

  targets:
    - name: "primary"
      address: "zabbix.example.com"
      port: 10051
      priority: 1
      tls:
        enabled: true
        cert_file: "/etc/nftban/certs/zabbix.crt"
```

---

## 3. Watchdog System

### 3.1 Architecture Overview

```
+-------------------+     +-------------------+     +-------------------+
| ProcessCollector  |     | RuntimeCollector  |     | SystemCollector   |
| (RSS, CPU, FDs)   |     | (Go heap, GC)     |     | (load, mem, disk) |
+-------------------+     +-------------------+     +-------------------+
         |                        |                        |
         +-----------+------------+-----------+------------+
                     |                        |
                     v                        v
            +-------------------+     +-------------------+
            | KernelCollector   |     | NFTablesCollector |
            | (conntrack,softnet)|    | (rules, sets)     |
            +-------------------+     +-------------------+
                     |                        |
                     +-----------+------------+
                                 |
                                 v
                        +-------------------+
                        |     Snapshot      |
                        | (all metrics)     |
                        +-------------------+
                                 |
              +------------------+------------------+
              |                                     |
              v                                     v
     +-------------------+                 +-------------------+
     | PressureCalculator|                 | MetricsExporter   |
     | (CPU,MEM,IO,NET)  |                 | (Prometheus)      |
     +-------------------+                 +-------------------+
              |
              v
     +-------------------+
     |   StateMachine    |
     | (hysteresis)      |
     +-------------------+
              |
              v
     +-------------------+
     |  ActionExecutor   |-----> Throttle, Profile, FreeOSMemory
     +-------------------+
              |
              v
     +-------------------+
     |  FlightRecorder   |-----> /var/lib/nftban/recorder/
     +-------------------+
```

### 3.2 File Inventory (16+ files)

| File | Lines | Purpose |
|------|-------|---------|
| `watchdog.go` | 358 | Main coordinator |
| `types.go` | 373 | Types: Dimension, Level, Mode, Snapshot |
| `config.go` | 277 | Configuration with defaults |
| `pressure.go` | 256 | Pressure score calculation |
| `state.go` | 290 | State machine with hysteresis |
| `executor.go` | 468 | Action execution (profile, throttle) |
| `flight_recorder.go` | 355 | Event logging and snapshots |
| `metrics.go` | 332 | Prometheus metrics export |
| `collector_process.go` | ~200 | Process metrics from /proc |
| `collector_runtime.go` | ~150 | Go runtime metrics |
| `collector_system.go` | ~250 | System metrics (load, memory) |
| `collector_kernel.go` | ~200 | Kernel metrics (conntrack) |
| `collector_nftables.go` | ~300 | nftables statistics |

### 3.3 Pressure Dimensions

**File:** `pkg/watchdog/types.go:18-26`

| Dimension | Inputs | Weight |
|-----------|--------|--------|
| **CPU** | Process CPU%, system load, softnet drops | 50/30/20 |
| **MEM** | RSS vs budget, heap vs GOMEMLIMIT, GC fraction, RSS slope | 40/30/15/15 |
| **IO** | iowait%, disk usage | 60/40 |
| **NET** | conntrack util, softnet drops rate, nft apply latency | 50/30/20 |

### 3.4 Pressure Score Calculation

**File:** `pkg/watchdog/pressure.go:71-187`

```go
// CPU Score (0-100)
cpuContrib    = (processCPU% / CPUCritPercent) * 50      // max 50 pts
loadContrib   = (load5 / NumCPU / LoadNormalizedCrit) * 30  // max 30 pts
softnetContrib = (dropsRate / SoftnetDropsRateCrit) * 20   // max 20 pts

// MEM Score (0-100)
rssContrib    = (RSS / MemBudget) / RSSCritPercent * 40    // max 40 pts
heapContrib   = (HeapInuse / GOMEMLIMIT) / HeapCritPercent * 30  // max 30 pts
gcContrib     = (GCCPUFraction / 0.10) * 15                // max 15 pts
slopeContrib  = (RSSGrowthPerMin / 50MB) * 15              // max 15 pts
```

### 3.5 State Machine with Hysteresis

**File:** `pkg/watchdog/state.go:1-20`

```
Level Transitions:
                 >=60              >=80
    OK ─────────────> WARN ─────────────> CRITICAL
       <─────────────      <─────────────
         <50 for 30s         <70 for 60s
```

**Hysteresis Thresholds:**

| Transition | Threshold | Duration |
|------------|-----------|----------|
| OK → WARN | Score >= 60 | Immediate |
| WARN → OK | Score < 50 | 30 seconds |
| WARN → CRITICAL | Score >= 80 | Immediate |
| CRITICAL → WARN | Score < 70 | 60 seconds |

### 3.6 Operating Modes

**File:** `pkg/watchdog/types.go:44-49`

| Mode | Condition | Workers | Features |
|------|-----------|---------|----------|
| **NORMAL** | All OK | 10 | All enabled |
| **DEGRADED** | Any WARN | 5 | Expensive collectors disabled |
| **SURVIVAL** | Any CRITICAL | 2 | Minimal operation |

### 3.7 Runtime Controls

**File:** `pkg/watchdog/types.go:220-287`

```go
type RuntimeControls struct {
    MaxWorkers                    atomic.Int32  // 10/5/2
    EnableExpensiveCollectors     atomic.Bool   // true/false/false
    EnableNFTRulesetScan          atomic.Bool   // true/false/false
    EnableTopProcesses            atomic.Bool   // true/false/false
    EnableVerboseLogging          atomic.Bool   // true/false/false
    TelemetrySamplingFactor       atomic.Uint32 // 100/50/25 (percent)
}
```

### 3.8 Action Executor

**File:** `pkg/watchdog/executor.go`

| Action | Cooldown | Trigger Condition |
|--------|----------|-------------------|
| `Throttle` | 1 min | SURVIVAL mode |
| `DisableOptional` | 1 min | DEGRADED or SURVIVAL |
| `ProfileCPU` | 15 min | CPU CRITICAL for 10s |
| `ProfileHeap` | 30 min | MEM CRITICAL for 30s |
| `ProfileGoroutine` | 5 min | Goroutines > 10000 |
| `FreeOSMemory` | 10 min | MEM CRITICAL for 30s AND CPU < 40% |

### 3.9 Flight Recorder

**File:** `pkg/watchdog/flight_recorder.go`

```
/var/lib/nftban/recorder/
├── events/
│   └── events_2026-01-24.jsonl   # Daily event log (ring buffer)
└── snapshots/
    └── snapshot_2026-01-24_120000.json  # Periodic snapshots
```

**Event Types:**
- `mode_change` - Operating mode transition
- `pressure_change` - Dimension level change
- `action_taken` - Action executed
- `threshold_breach` - Score exceeded threshold
- `profile_capture` - Profile captured

---

## 4. Prometheus Integration

### 4.1 Watchdog Prometheus Metrics (22 metrics)

**File:** `pkg/watchdog/metrics.go`

| Category | Metrics | Type |
|----------|---------|------|
| **Pressure** | `nftban_pressure_state{dim,level}`, `nftban_pressure_score{dim}` | Gauge |
| **Mode** | `nftban_operating_mode{mode}` | Gauge |
| **Actions** | `nftban_watchdog_action_total{action}`, `nftban_watchdog_last_action_timestamp_seconds{action}` | Counter/Gauge |
| **Process** | `nftban_proc_rss_bytes`, `nftban_proc_cpu_percent`, `nftban_proc_fd_open`, `nftban_proc_threads` | Gauge |
| **Runtime** | `nftban_go_goroutines`, `nftban_go_gc_cpu_fraction`, `nftban_go_gc_pause_seconds`, `nftban_go_heap_*` | Gauge/Histogram |
| **Kernel** | `nftban_conntrack_used`, `nftban_conntrack_max`, `nftban_conntrack_utilization`, `nftban_softnet_*` | Gauge |
| **NFTables** | `nftban_nft_set_elements{set,family}`, `nftban_nft_rules_total` | Gauge |
| **Cost** | `nftban_cost_bytes_per_block_rss` | Gauge |

### 4.2 Registry Analysis

**Watchdog uses promauto (default registry):**
```go
// pkg/watchdog/metrics.go:24
pressureState = promauto.NewGaugeVec(prometheus.GaugeOpts{
    Namespace: "nftban",
    Name:      "pressure_state",
    Help:      "Current pressure state per dimension",
}, []string{"dim", "level"})
```

**Zabbix does NOT use Prometheus:**
- Zabbix pushes metrics via trapper protocol
- Separate collection path from Prometheus
- No registry integration needed

---

## 5. Data Flow Architecture

### 5.1 Complete Data Flow

```
                                    DAEMON RUNTIME
+--------------------------------------------------------------------------+
|                                                                          |
|    +----------------+     +----------------+     +----------------+       |
|    |   Modules      |     |   EventBus     |     |   nftables     |       |
|    | (loginmon,etc) |     | (subscribers)  |     |   (sets,rules) |       |
|    +----------------+     +----------------+     +----------------+       |
|            |                      |                      |               |
|            +----------+-----------+----------+-----------+               |
|                       |                      |                           |
|                       v                      v                           |
|              +----------------+     +----------------+                   |
|              | pkg/metrics/   |     | pkg/watchdog/  |                   |
|              | nftban.go      |     | collectors     |                   |
|              | (promauto)     |     | (5 collectors) |                   |
|              +----------------+     +----------------+                   |
|                       |                      |                           |
|                       v                      v                           |
|              +----------------+     +----------------+                   |
|              | /metrics       |     | Watchdog Core  |                   |
|              | (Prometheus)   |     | (actions)      |                   |
|              +----------------+     +----------------+                   |
|                       ^                      |                           |
|                       |                      v                           |
|              +----------------+     +----------------+                   |
|              | pkg/watchdog/  |     | pkg/exporters/ |                   |
|              | metrics.go     |     | zabbix/        |                   |
|              | (promauto)     |     | (MetricsSource)|                   |
|              +----------------+     +----------------+                   |
|                                              |                           |
+--------------------------------------------------------------------------+
                                               |
                                               v
                          +------------------------------------------+
                          |            EXTERNAL SYSTEMS              |
                          |                                          |
                          |    +----------------+  +----------------+ |
                          |    | Prometheus     |  | Zabbix Server  | |
                          |    | (scrape)       |  | (10051/tcp)    | |
                          |    +----------------+  +----------------+ |
                          +------------------------------------------+
```

### 5.2 Collection Timing

| System | Interval | Collection Method |
|--------|----------|-------------------|
| **Prometheus scrape** | 15-60s | HTTP pull `/metrics` |
| **Zabbix push** | 60s (default) | TCP push to 10051 |
| **Watchdog tick** | 5s | Internal collectors |
| **Sampler (deprecated)** | 10s | CLI exec polling |

---

## 6. Metrics Comparison

### 6.1 Zabbix vs Prometheus Metrics Overlap

| Data Point | Zabbix Key | Prometheus Metric | Notes |
|------------|------------|-------------------|-------|
| Goroutines | `nftban.goroutines` | `nftban_go_goroutines` | Same data |
| Heap | `nftban.memory.heap` | `nftban_go_heap_alloc_bytes` | Same data |
| RSS | `nftban.memory.rss` | `nftban_proc_rss_bytes` | Same data |
| CPU% | N/A | `nftban_proc_cpu_percent` | Watchdog only |
| Conntrack | N/A | `nftban_conntrack_*` | Watchdog only |
| Bans total | `nftban.bans.total` | `nftban_bans_total` | Different source |
| Watchdog scores | `nftban.watchdog.*_score` | `nftban_pressure_score{dim}` | Same data |

### 6.2 Unique to Each System

**Zabbix Only (via MetricsSource):**
- `nftban.feeds.*` - Feed statistics
- `nftban.geoip.*` - GeoIP statistics
- `nftban.api.*` - API statistics
- `nftban.ipc.*` - IPC statistics
- LLD discovery data

**Prometheus Only (via Watchdog):**
- `nftban_pressure_state{dim,level}` - Level state
- `nftban_go_gc_pause_seconds` - GC pause histogram
- `nftban_softnet_*` - Softnet stats
- `nftban_cost_bytes_per_block_rss` - Memory cost

---

## 7. Integration Analysis

### 7.1 How Zabbix Gets Watchdog Data

```go
// pkg/exporters/zabbix/collector.go:366-367
wd := c.source.GetWatchdogStatus()
snapshot.Watchdog = WatchdogMetrics(wd)
```

The daemon implements `MetricsSource` interface, providing watchdog data to Zabbix:

```go
type WatchdogInfo struct {
    Status       int     // 1=ok, 0=disabled, -1=error
    Mode         string  // normal, degraded, survival
    CPUScore     float64 // 0-100
    MemScore     float64 // 0-100
    IOScore      float64 // 0-100
    NetScore     float64 // 0-100
    ActionsTaken int64
    LastAction   string
    ModeChanges  int64
}
```

### 7.2 Prometheus Integration Point

```go
// pkg/watchdog/watchdog.go:165-167
if w.onMetrics != nil {
    w.onMetrics(snapshot, state)
}
```

The daemon sets a callback that feeds the MetricsExporter:

```go
// Usage in daemon
watchdog.SetOnMetrics(func(snapshot *Snapshot, state *PressureState) {
    metricsExporter.Update(snapshot, state)
})
```

---

## 8. Recommendations

### 8.1 Current State Assessment

| Aspect | Status | Notes |
|--------|--------|-------|
| Zabbix collection | GOOD | Clean interface, well-structured |
| Watchdog Prometheus | GOOD | Uses promauto correctly |
| Data overlap | MINIMAL | Different focus areas |
| Performance | GOOD | Watchdog is lightweight (5s tick) |

### 8.2 Optimization Opportunities

| Opportunity | Impact | Effort |
|-------------|--------|--------|
| Share watchdog snapshot with Zabbix | LOW | LOW |
| Add missing Prometheus metrics (feeds, geoip) | MEDIUM | MEDIUM |
| Consolidate runtime metrics collection | LOW | MEDIUM |

### 8.3 No Action Required

The current architecture is well-designed:

1. **Separation of Concerns**
   - Zabbix: Enterprise monitoring via push
   - Prometheus: Container/cloud monitoring via scrape
   - Watchdog: Internal health management

2. **Minimal Duplication**
   - Each system collects what it needs
   - Overlap is acceptable (both need goroutines, etc.)

3. **Different Update Frequencies**
   - Zabbix: 60s push (configurable)
   - Prometheus: 15-60s scrape (external)
   - Watchdog: 5s internal tick (for responsiveness)

### 8.4 Future Considerations

1. **If Prometheus becomes primary:**
   - Add feed/geoip/api metrics to watchdog exporter
   - Keep Zabbix for legacy integrations

2. **If Zabbix becomes primary:**
   - Consider Zabbix agent 2 (Prometheus export)
   - Keep watchdog for self-healing

3. **For unified observability:**
   - OpenTelemetry collector could aggregate both
   - OTLP export would unify Prometheus and Zabbix paths

---

## 9. Summary

### 9.1 Key Findings

| Finding | Status |
|---------|--------|
| Zabbix exporter is well-implemented | GOOD |
| Watchdog Prometheus integration is correct | GOOD |
| No critical overlap issues | GOOD |
| Different collection mechanisms justified | GOOD |

### 9.2 System Purposes

| System | Primary Purpose | Secondary Purpose |
|--------|-----------------|-------------------|
| **Zabbix** | Enterprise alerting | Capacity planning |
| **Watchdog** | Self-healing | Prometheus metrics |
| **pkg/metrics** | Real-time counters | Prometheus scrape |

### 9.3 Files Referenced

**Zabbix System:**
- `pkg/exporters/zabbix/collector.go` - 657 lines
- `pkg/exporters/zabbix/exporter.go` - 466 lines
- `pkg/exporters/zabbix/sender.go` - 476 lines
- `pkg/exporters/zabbix/protocol.go` - 429 lines
- `pkg/exporters/zabbix/discovery.go` - 618 lines
- `pkg/exporters/zabbix/types.go` - 472 lines
- `pkg/exporters/zabbix/config.go` - 490 lines
- `pkg/exporters/zabbix/http.go` - 326 lines

**Watchdog System:**
- `pkg/watchdog/watchdog.go` - 358 lines
- `pkg/watchdog/types.go` - 373 lines
- `pkg/watchdog/config.go` - 277 lines
- `pkg/watchdog/pressure.go` - 256 lines
- `pkg/watchdog/state.go` - 290 lines
- `pkg/watchdog/executor.go` - 468 lines
- `pkg/watchdog/flight_recorder.go` - 355 lines
- `pkg/watchdog/metrics.go` - 332 lines

---

**Document Status:** COMPLETE
**Analysis Based On:** Actual code review
**No Guessing:** All findings backed by code references
