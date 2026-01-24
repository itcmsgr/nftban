# NFTBan Metrics Optimization - Execution Plan

**Document Version:** 1.1
**Date:** 2026-01-24
**Status:** APPROVED FOR IMPLEMENTATION
**Type:** Runbook

---

## Golden Rule: Tiered Collection

**Metrics collection has TWO tiers:**

| Tier | Config | Collected | Purpose |
|------|--------|-----------|---------|
| **BASIC** | Always ON | Banned IPs, Whitelist IPs, Feeds | Core operational data |
| **FULL** | `NFTBAN_METRICS_ENABLED=true` | All 93 metrics | Prometheus/Zabbix/Grafana |

**BASIC tier is ALWAYS available** - needed for UI and basic health.
**FULL tier is OPTIONAL** - only when user enables metrics.

Current gap: Config `NFTBAN_METRICS_ENABLED` is NOT connected to sampler startup.

---

## Quick Reference

| Phase | Priority | Effort | Impact |
|-------|----------|--------|--------|
| **Phase 0: Enablement gate** | **P0** | 0.5 day | Zero overhead when disabled |
| Phase 1: sampler.go refactor | **P0** | 1-2 days | 99% CPU reduction |
| Phase 2: Registry cleanup | P1 | 0.5 day | Operational clarity |
| Phase 3: Module optimization | P1 | 1 day | 50% module overhead reduction |
| Phase 4: Timer cleanup | P2 | 0.5 day | Clean deployment |

---

## Phase 0: Metrics Enablement Gate (CRITICAL)

### 0.1 Current Problem

```
CONFIG: NFTBAN_METRICS_ENABLED=false (default)
SAMPLER: Still initializes, still has ticker ready
WATCHDOG: Still collects data
RESULT: Wasted resources even when user doesn't want metrics
```

**Principle:** User says NO → We do NOTHING.

### 0.2 Fix: Connect Config to Sampler

**File:** `pkg/metrics/sampler.go` - Modify `GetSampler()`

```go
// GetSampler returns the global sampler instance (singleton)
// Returns nil if metrics are disabled - callers MUST check
func GetSampler() *Sampler {
    samplerOnce.Do(func() {
        cfg := nftbanconf.MustLoad()

        // CRITICAL: If metrics disabled, don't create sampler at all
        if !cfg.MetricsEnabled {
            log.Println("[METRICS] Metrics disabled in config - sampler not created")
            return  // globalSampler stays nil
        }

        // Rest of initialization...
        samplingInterval := cfg.MetricsSamplingInterval
        // ...
    })
    return globalSampler  // May be nil if disabled
}

// IsEnabled returns true if metrics collection is enabled
func IsEnabled() bool {
    cfg := nftbanconf.MustLoad()
    return cfg.MetricsEnabled
}
```

### 0.3 Fix: Guard All Callers

**File:** `cmd/nftban-ui/main.go` (and other callers)

```go
// BEFORE
sampler := metrics.GetSampler()
router.Handle("/metrics", promhttp.HandlerFor(sampler.Registry(), opts))

// AFTER
if metrics.IsEnabled() {
    sampler := metrics.GetSampler()
    if sampler != nil {
        router.Handle("/metrics", promhttp.HandlerFor(sampler.Registry(), opts))
    }
} else {
    log.Println("[METRICS] Metrics disabled - /metrics endpoint not registered")
}
```

### 0.4 Fix: Guard Watchdog Metrics Collection

**File:** `pkg/watchdog/watchdog.go`

```go
// In the collection loop
func (w *Watchdog) runCollectionLoop() {
    ticker := time.NewTicker(w.config.BaseInterval)
    defer ticker.Stop()

    for {
        select {
        case <-ticker.C:
            // CRITICAL: Skip collection if metrics disabled
            if !metrics.IsEnabled() {
                continue  // Zero work done
            }
            w.collectSnapshot()
        case <-w.stopChan:
            return
        }
    }
}
```

### 0.5 Fix: Guard Textfile Collector

**File:** `pkg/metrics/collector.go`

```go
func (c *Collector) Collect() error {
    // CRITICAL: Early exit if metrics disabled
    if !IsEnabled() {
        return nil  // Zero work done
    }

    // Rest of collection...
}
```

### 0.6 Fix: Guard promauto Metrics Updates

**File:** `pkg/metrics/nftban.go`

```go
// RecordBan records a ban event
func RecordBan(source, family string) {
    // CRITICAL: Skip if metrics disabled
    if !IsEnabled() {
        return
    }
    bansTotal.WithLabelValues(source, family).Inc()
}

// Apply same pattern to ALL Record* functions
```

### 0.7 Verification

```bash
# Set metrics disabled
grep NFTBAN_METRICS_ENABLED /etc/nftban/nftban.conf
# Should show: NFTBAN_METRICS_ENABLED="false"

# Verify no sampler activity
journalctl -u nftband | grep -i metrics
# Should show: "Metrics disabled in config - sampler not created"

# Verify no /metrics endpoint
curl -s http://localhost:8443/metrics
# Should return 404 or empty

# Verify zero CPU overhead from metrics
top -b -n1 | grep nftban
# Should show minimal CPU (no collection running)
```

### 0.8 Tiered Collection Behavior

#### BASIC Tier (Always ON)

| Data | Source | Method | Cost |
|------|--------|--------|------|
| Banned IPs count | watchdog nftables | netlink SetElements | ~1ms |
| Whitelist IPs count | watchdog nftables | netlink SetElements | ~1ms |
| Feeds status | feeds loader | in-memory state | ~0ms |

**These are ALWAYS collected** - needed for UI dashboard and basic health.

#### FULL Tier (When `NFTBAN_METRICS_ENABLED=true`)

| Component | Behavior |
|-----------|----------|
| Sampler (full) | All 15 gauges updated |
| Watchdog metrics | Full snapshot collection |
| Textfile collector | Write .prom file |
| promauto counters | All counters incremented |
| /metrics endpoint | Registered and active |

#### When FULL Tier Disabled

| Component | Behavior |
|-----------|----------|
| Sampler | **BASIC only** (banned, whitelist, feeds) |
| Watchdog metrics | **BASIC only** (nftables sets) |
| Textfile collector | **Not run** |
| promauto counters | **Not incremented** |
| /metrics endpoint | **Not registered (404)** |
| CPU overhead | **MINIMAL** (~5ms/min for BASIC) |

### 0.9 Configuration Hierarchy

The system has multiple enable flags - all must be respected:

```
┌─────────────────────────────────────────────────────────────────────┐
│                    CONFIGURATION HIERARCHY                          │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  LEVEL 1: Global Metrics Enable                                      │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │ NFTBAN_METRICS_ENABLED=false → STOP (zero overhead)            ││
│  └─────────────────────────────────────────────────────────────────┘│
│                           │                                          │
│                           ▼ (if true)                                │
│  LEVEL 2: Component Enables                                          │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │ watchdog.Enabled=false → Skip watchdog collection              ││
│  │ stats.Enabled=false → Skip stats collection                    ││
│  │ sampler.metricsEnabled=false → Session-based only              ││
│  └─────────────────────────────────────────────────────────────────┘│
│                           │                                          │
│                           ▼ (if true)                                │
│  LEVEL 3: Mode Adjustments                                           │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │ DEGRADED mode → 2x intervals, skip expensive scans             ││
│  │ SURVIVAL mode → Minimal collection, 1 worker                   ││
│  │ Profiling active → Skip sample to avoid interference           ││
│  └─────────────────────────────────────────────────────────────────┘│
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

**Implementation Pattern:**

```go
func (s *Sampler) takeSample() {
    snapshot := s.watchdog.GetSnapshot()
    if snapshot == nil {
        return
    }

    // =========================================
    // BASIC TIER: ALWAYS COLLECTED (for UI)
    // =========================================
    s.collectBasic(snapshot)

    // =========================================
    // FULL TIER: Only if metrics enabled
    // =========================================
    if !metrics.IsEnabled() {
        return  // Stop here - BASIC only
    }

    // Component check
    if !s.metricsEnabled && s.activeSessions == 0 {
        return
    }

    // Profile interference check
    if s.watchdog.IsProfilingActive() {
        return
    }

    // Mode-based collection
    switch snapshot.OperatingMode {
    case "SURVIVAL":
        s.collectSurvival(snapshot)
    case "DEGRADED":
        s.collectDegraded(snapshot)
    default:
        s.collectFull(snapshot)
    }
}

// collectBasic - ALWAYS runs, minimal cost
func (s *Sampler) collectBasic(snapshot *Snapshot) {
    // Banned IPs (from watchdog netlink, no CLI)
    banned := snapshot.NFTables.SetElements["blacklist_ipv4"] +
              snapshot.NFTables.SetElements["blacklist_ipv6"]
    s.basicBannedIPs = banned

    // Whitelist IPs (from watchdog netlink, no CLI)
    whitelist := snapshot.NFTables.SetElements["whitelist_ipv4"] +
                 snapshot.NFTables.SetElements["whitelist_ipv6"]
    s.basicWhitelistIPs = whitelist

    // Feeds (from in-memory loader, no CLI)
    if s.feedsLoader != nil {
        s.basicFeedsActive = s.feedsLoader.GetActiveCount()
        s.basicFeedsIPs = s.feedsLoader.GetTotalIPs()
    }
}
```

---

## Phase 1: Eliminate sampler.go CLI Polling

### 1.1 Pre-Requisites

```bash
# Verify current state
grep -n "exec.Command" /home/gituser/github/nftban/pkg/metrics/sampler.go
```

Expected output (lines to remove):
- Line 504: `nftban status --json`
- Line 621: `nftban feeds status`
- Line 737: `nftban portscan stats`
- Line 760: `nftban ddos stats`

### 1.2 Struct Modifications

**File:** `pkg/metrics/sampler.go`

```go
// ADD to Sampler struct (around line 50-80)
type Sampler struct {
    // ... existing fields ...

    // NEW: References to data sources
    watchdog    *watchdog.Watchdog    // For nftables, process, system metrics
    feedsLoader *feeds.Loader         // For feed state
    startTime   time.Time             // For uptime (may already exist)
}

// ADD to NewSampler() constructor
func NewSampler(cfg *Config, watchdog *watchdog.Watchdog, feedsLoader *feeds.Loader) *Sampler {
    s := &Sampler{
        // ... existing init ...
        watchdog:    watchdog,
        feedsLoader: feedsLoader,
        startTime:   time.Now(),
    }
    return s
}
```

### 1.3 Replace CLI Calls in takeSample()

**File:** `pkg/metrics/sampler.go` - Function `takeSample()` (around line 500+)

#### REMOVE (lines ~504-520):
```go
// DELETE THIS BLOCK
cmd := exec.Command("nftban", "status", "--json")
output, err := cmd.Output()
if err != nil {
    // error handling
}
var status StatusResponse
json.Unmarshal(output, &status)
```

#### REPLACE WITH:
```go
// Get watchdog snapshot (already collected via netlink, no CLI)
snapshot := s.watchdog.GetSnapshot()
if snapshot == nil {
    s.logger.Warn("watchdog snapshot not available")
    return
}

// nftables data from watchdog (netlink, not CLI)
blockedIPv4 := int64(0)
blockedIPv6 := int64(0)
if elements, ok := snapshot.NFTables.SetElements["blacklist_ipv4"]; ok {
    blockedIPv4 = int64(elements)
}
if elements, ok := snapshot.NFTables.SetElements["blacklist_ipv6"]; ok {
    blockedIPv6 = int64(elements)
}
s.blockedIPsGauge.Set(float64(blockedIPv4 + blockedIPv6))

// Rules count from watchdog
s.ruleCountGauge.Set(float64(snapshot.NFTables.RulesTotal))

// Whitelist from watchdog
whitelistIPv4 := int64(0)
whitelistIPv6 := int64(0)
if elements, ok := snapshot.NFTables.SetElements["whitelist_ipv4"]; ok {
    whitelistIPv4 = int64(elements)
}
if elements, ok := snapshot.NFTables.SetElements["whitelist_ipv6"]; ok {
    whitelistIPv6 = int64(elements)
}
s.whitelistIPsGauge.Set(float64(whitelistIPv4 + whitelistIPv6))
```

#### REMOVE (lines ~621-650):
```go
// DELETE THIS BLOCK
cmd := exec.Command("nftban", "feeds", "status")
// ... all feeds CLI parsing ...
```

#### REPLACE WITH:
```go
// Feeds data from loader (in-memory, no CLI)
if s.feedsLoader != nil {
    s.feedsActiveGauge.Set(float64(s.feedsLoader.GetActiveCount()))
    s.feedsTotalIPsGauge.Set(float64(s.feedsLoader.GetTotalIPs()))
}
```

#### REMOVE (lines ~737-760):
```go
// DELETE THESE BLOCKS
cmd := exec.Command("nftban", "portscan", "stats")
// ...
cmd := exec.Command("nftban", "ddos", "stats")
// ...
```

#### REPLACE WITH:
```go
// Portscan/DDoS stats - read from prometheus counters directly
// These are already tracked in pkg/metrics/nftban.go as real-time counters
// The sampler gauge can read from the counter value or we can expose a getter

// Option A: If nftban.go exposes getters
s.portscanBlocksGauge.Set(float64(metrics.GetPortscanBansTotal()))
s.ddosBlocksGauge.Set(float64(metrics.GetDDoSMitigationsTotal()))

// Option B: Remove these gauges entirely (counters are authoritative)
// The data is already in nftban_portscan_bans_total and nftban_ddos_mitigations_total
```

### 1.4 Keep Filesystem Scans (Unique Data)

These are VALID and should be kept (they don't use CLI):

```go
// KEEP: Geoban country count (unique to sampler)
func (s *Sampler) countGeobanCountries() int {
    entries, err := os.ReadDir("/var/lib/nftban/geoban/tracking")
    if err != nil {
        return 0
    }
    count := 0
    for _, e := range entries {
        if e.IsDir() {
            count++
        }
    }
    return count
}

// KEEP: Blacklist count (unique to sampler)
func (s *Sampler) countBlacklistIPs() int {
    entries, err := os.ReadDir("/etc/nftban/blacklist.d")
    if err != nil {
        return 0
    }
    return len(entries)
}

// KEEP: Session count (internal state)
s.activeSessionsGauge.Set(float64(s.activeSessions))

// KEEP: Uptime (internal state)
s.uptimeGauge.Set(time.Since(s.startTime).Seconds())
```

### 1.5 Update Callers

**File:** `cmd/nftband/main.go` or wherever Sampler is instantiated

```go
// BEFORE
sampler := metrics.NewSampler(cfg)

// AFTER
sampler := metrics.NewSampler(cfg, watchdogInstance, feedsLoaderInstance)
```

**File:** `cmd/nftban-ui/main.go`

```go
// Same pattern - pass watchdog and feeds loader references
```

### 1.6 Verification

```bash
# After changes, verify no CLI calls remain
grep -n "exec.Command" /home/gituser/github/nftban/pkg/metrics/sampler.go
# Expected: 0 matches

# Run tests
go test ./pkg/metrics/...

# Check metrics endpoint
curl -s http://localhost:8443/metrics | grep nftban_blocked
```

---

## Phase 2: Registry Cleanup (Optional)

### 2.1 Current State (VALID)

Two endpoints exist and this is architecturally sound:

| Endpoint | Registry | Metrics |
|----------|----------|---------|
| `nftband:8080/metrics` | Default (promauto) | 78 metrics |
| `nftban-ui:8443/metrics` | Custom (sampler) | 15 metrics |

### 2.2 If Single Endpoint Desired

**Option A: Merge Gatherers in nftband**

**File:** `cmd/nftband/main.go` (around line 1171)

```go
// BEFORE
mux.Handle("/metrics", promhttp.Handler())

// AFTER
import "github.com/itcmsgr/nftban/pkg/metrics"

sampler := metrics.GetSampler()
combinedGatherer := prometheus.Gatherers{
    prometheus.DefaultGatherer,
    sampler.Registry(),
}
mux.Handle("/metrics", promhttp.HandlerFor(combinedGatherer, promhttp.HandlerOpts{}))
```

**Option B: Migrate sampler to promauto**

**File:** `pkg/metrics/sampler.go`

```go
// BEFORE (custom registry)
s.registry = prometheus.NewRegistry()
s.blockedIPsGauge = prometheus.NewGauge(prometheus.GaugeOpts{...})
s.registry.MustRegister(s.blockedIPsGauge)

// AFTER (promauto - auto-registers with default)
var samplerBlockedIPs = promauto.NewGauge(prometheus.GaugeOpts{
    Namespace: "nftban",
    Subsystem: "sampler",  // Add subsystem to avoid name collision
    Name:      "blocked_ips_total",
    Help:      "Current blocked IP count",
})
```

### 2.3 Prometheus Config

```yaml
# If keeping two endpoints
scrape_configs:
  - job_name: 'nftband'
    static_configs:
      - targets: ['localhost:8080']

  - job_name: 'nftban-ui'
    static_configs:
      - targets: ['localhost:8443']

# If merged to single endpoint
scrape_configs:
  - job_name: 'nftban'
    static_configs:
      - targets: ['localhost:8080']
```

---

## Phase 3: Module Optimization

### 3.1 DDoS Module - Cache Mode Detection

**File:** `pkg/ddos/module.go`

```go
// BEFORE: Detects mode every 30 seconds
func (m *Module) runPeriodicCheck() {
    cmd := exec.Command("bash", "-c", "source "+m.script+" && nftban_ddos_get_mode")
    // ...
}

// AFTER: Detect once at startup, cache result
type Module struct {
    // ... existing fields ...
    detectedMode     string
    modeDetectedOnce sync.Once
}

func (m *Module) getMode() string {
    m.modeDetectedOnce.Do(func() {
        cmd := exec.Command("bash", "-c", "source "+m.script+" && nftban_ddos_get_mode")
        output, err := cmd.Output()
        if err == nil {
            m.detectedMode = strings.TrimSpace(string(output))
        }
    })
    return m.detectedMode
}

// For mode changes, expose a method to invalidate cache
func (m *Module) InvalidateModeCache() {
    m.modeDetectedOnce = sync.Once{}
}
```

### 3.2 Portscan Module - Same Pattern

**File:** `pkg/portscan/module.go`

```go
// Same caching pattern as DDoS module
type Module struct {
    detectedMode     string
    modeDetectedOnce sync.Once
}

func (m *Module) getMode() string {
    m.modeDetectedOnce.Do(func() {
        // Detect mode once
    })
    return m.detectedMode
}
```

### 3.3 Reduce Polling Frequency (If Caching Not Feasible)

```go
// BEFORE
const DefaultCheckInterval = 30 * time.Second  // DDoS
const DefaultCheckInterval = 60 * time.Second  // Portscan

// AFTER (if detection must remain periodic)
const DefaultCheckInterval = 5 * time.Minute   // DDoS
const DefaultCheckInterval = 5 * time.Minute   // Portscan
```

---

## Phase 4: Timer Cleanup

### 4.1 Disable Deprecated Timers

```bash
# Run on target system
sudo systemctl disable nftban-metrics-exporter.timer
sudo systemctl disable nftban-zabbix-exporter.timer
sudo systemctl disable nftban-connector-exporter.timer

sudo systemctl stop nftban-metrics-exporter.timer
sudo systemctl stop nftban-zabbix-exporter.timer
sudo systemctl stop nftban-connector-exporter.timer
```

### 4.2 Enable Unified Exporter

```bash
sudo systemctl enable nftban-unified-exporter.timer
sudo systemctl start nftban-unified-exporter.timer
```

### 4.3 Remove Deprecated Files (Optional)

**Files to remove from `install/systemd/`:**

```bash
rm install/systemd/nftban-metrics-exporter.timer
rm install/systemd/nftban-metrics-exporter.service
rm install/systemd/nftban-zabbix-exporter.timer
rm install/systemd/nftban-zabbix-exporter.service
rm install/systemd/nftban-connector-exporter.timer
rm install/systemd/nftban-connector-exporter.service
```

### 4.4 Verify Timer State

```bash
systemctl list-timers | grep nftban
# Expected: Only unified-exporter, watchdog, health, feeds, etc.
# NOT: metrics-exporter, zabbix-exporter, connector-exporter
```

---

## Validation Checklist

### After Phase 1

- [ ] `grep -c "exec.Command" pkg/metrics/sampler.go` returns 0
- [ ] `curl localhost:8443/metrics | grep nftban_blocked` returns data
- [ ] `go test ./pkg/metrics/...` passes
- [ ] CPU usage for nftban-ui process decreased

### After Phase 2

- [ ] Prometheus scrapes all expected metrics
- [ ] Grafana dashboards show data (update queries if metric names changed)

### After Phase 3

- [ ] DDoS/Portscan modules start without CLI calls
- [ ] Mode detection works on config reload (cache invalidation)

### After Phase 4

- [ ] `systemctl list-timers | grep -c nftban-metrics-exporter` returns 0
- [ ] `systemctl list-timers | grep -c nftban-unified-exporter` returns 1

---

## Rollback Plan

### Phase 1 Rollback

```bash
git checkout HEAD~1 -- pkg/metrics/sampler.go
go build ./cmd/nftband ./cmd/nftban-ui
sudo systemctl restart nftband nftban-ui
```

### Phase 4 Rollback

```bash
sudo systemctl enable nftban-metrics-exporter.timer
sudo systemctl disable nftban-unified-exporter.timer
sudo systemctl start nftban-metrics-exporter.timer
```

---

## Metrics Deprecation List (For Dashboard Updates)

If implementing Option B in Phase 2 (promauto migration), metric names change:

| Old Name | New Name | Reason |
|----------|----------|--------|
| `nftban_blocked_ips_total` | `nftban_sampler_blocked_ips_total` | Added subsystem |
| `nftban_firewall_rules_total` | `nftban_sampler_firewall_rules_total` | Added subsystem |
| `nftban_health_status` | `nftban_sampler_health_status` | Added subsystem |
| `nftban_feeds_active_total` | `nftban_sampler_feeds_active_total` | Added subsystem |

**OR** keep names unchanged if using Option A (merge gatherers).

---

## Final State Summary

```
┌─────────────────────────────────────────────────────────────────────┐
│                    OPTIMIZED METRICS ARCHITECTURE                    │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  FIRST CHECK: Is NFTBAN_METRICS_ENABLED=true?                        │
│                                                                      │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │  IF NO → STOP HERE. Zero work. Zero overhead. User's choice.   ││
│  └─────────────────────────────────────────────────────────────────┘│
│                                                                      │
│  IF YES → DATA FLOW (NO CLI POLLING):                                │
│                                                                      │
│  Kernel (nftables) ──netlink──► Watchdog ──snapshot──► sampler.go   │
│                                                                      │
│  Event (ban/detect) ──promauto──► nftban.go ──counter──► /metrics   │
│                                                                      │
│  Feeds (files) ──loader──► in-memory ──getter──► sampler.go         │
│                                                                      │
│  Filesystem ──os.ReadDir──► sampler.go (geoban, blacklist)          │
│                                                                      │
│  CLI exec.Command: **ZERO** in metrics collection path               │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### When Metrics DISABLED

| Component | State | CPU |
|-----------|-------|-----|
| Sampler | nil (not created) | 0 |
| Watchdog metrics | Skipped | 0 |
| promauto counters | Not incremented | 0 |
| /metrics endpoint | 404 | 0 |
| **Total** | **Nothing runs** | **0** |

### When Metrics ENABLED

| Component | State | CPU |
|-----------|-------|-----|
| Sampler | Active (reads from watchdog) | ~0.01s/min |
| Watchdog metrics | Collected via netlink | ~0.02s/min |
| promauto counters | Real-time updates | ~0.001s/min |
| /metrics endpoint | Available | on-demand |
| **Total** | **Efficient collection** | **~0.05s/min** |

### Degraded Mode (Automatic Performance Management)

The watchdog already has smart degradation modes:

| Mode | Trigger | Interval Multiplier | nft Ruleset Scan | Workers |
|------|---------|---------------------|------------------|---------|
| **NORMAL** | Score < 60 | 1x | Enabled | Full |
| **DEGRADED** | Score >= 60 | **2x** | **Disabled** | 2 |
| **SURVIVAL** | Score >= 80 | 2x | Disabled | **1** |

**Sampler MUST respect watchdog mode:**

```go
// In sampler.go takeSample()
func (s *Sampler) takeSample() {
    snapshot := s.watchdog.GetSnapshot()

    // RESPECT DEGRADED MODE: Skip expensive operations
    if snapshot.OperatingMode == "DEGRADED" || snapshot.OperatingMode == "SURVIVAL" {
        // Only collect essential metrics
        s.collectEssentialOnly(snapshot)
        return
    }

    // Full collection in NORMAL mode
    s.collectFull(snapshot)
}
```

### Profiling Integration

The system has auto-profiling on threshold breach:

| Config | Default | Purpose |
|--------|---------|---------|
| `ProfileAutoEnabled` | true | Capture pprof on breach |
| `ProfileCPUCooldown` | 15 min | Minimum between CPU profiles |
| `ProfileHeapCooldown` | 30 min | Minimum between heap profiles |
| `ProfileMaxCount` | 10 | Max profiles retained |

**Sampler should NOT interfere with profiling:**

```go
// Don't add overhead during profile capture
if s.watchdog.IsProfilingActive() {
    return  // Skip this sample
}
```

---

**Document Status:** EXECUTION READY
**Owner:** Development Team
**Review Required:** Before each phase deployment
