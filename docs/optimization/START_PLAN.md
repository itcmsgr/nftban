# NFTBan Metrics Optimization - START PLAN

**Document Version:** 1.0
**Date:** 2026-01-24
**Status:** READY TO EXECUTE

---

## Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                    OPTIMIZATION SUMMARY                              │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  BEFORE: 76 CLI exec calls, ~2s CPU/min, 8+ duplications            │
│  AFTER:  0 CLI exec for metrics, ~0.05s CPU/min, 0 duplications     │
│                                                                      │
│  USER EXPERIENCE:                                                    │
│  • nftban stats     → Always works (uses shared data)               │
│  • Web UI           → Always works (BASIC tier)                     │
│  • Prometheus       → Works when enabled (FULL tier)                │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Data Flow Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    SINGLE SOURCE OF TRUTH                            │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  WATCHDOG (netlink) ───────────────────────────────────────────────►│
│  ├── Banned IPs (blacklist_ipv4 + blacklist_ipv6)                   │
│  ├── Whitelist IPs (whitelist_ipv4 + whitelist_ipv6)                │
│  ├── Rules count                                                     │
│  └── Sets metadata                                                   │
│                                                                      │
│  FEEDS LOADER (in-memory) ─────────────────────────────────────────►│
│  ├── Active feeds count                                              │
│  ├── Total IPs from feeds                                            │
│  └── Per-feed status                                                 │
│                                                                      │
│  STATS COLLECTOR (counters) ───────────────────────────────────────►│
│  ├── Total bans (historical)                                         │
│  ├── Unique IPs (historical)                                         │
│  └── Module stats                                                    │
│                                                                      │
│                              │                                        │
│                              ▼                                        │
│  ┌─────────────────────────────────────────────────────────────────┐│
│  │              SHARED STATE (pkg/state/snapshot.go)               ││
│  │  • Updated by watchdog every 5s                                 ││
│  │  • Read by: sampler, stats CLI, API handlers, UI                ││
│  │  • NO CLI CALLS - all consumers read from this                  ││
│  └─────────────────────────────────────────────────────────────────┘│
│                              │                                        │
│              ┌───────────────┼───────────────┐                        │
│              ▼               ▼               ▼                        │
│         sampler.go     nftban stats      Web UI                      │
│         (metrics)      (CLI command)     (dashboard)                 │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Two-Tier Metrics System

### BASIC Tier (Always ON)

| Data | Source | Used By | Cost |
|------|--------|---------|------|
| Banned IPs | watchdog netlink | stats, UI, sampler | ~1ms |
| Whitelist IPs | watchdog netlink | stats, UI, sampler | ~1ms |
| Feeds active | feeds loader | stats, UI, sampler | ~0ms |
| Feeds IPs | feeds loader | stats, UI, sampler | ~0ms |

**Always available for:**
- `nftban stats` command
- Web UI dashboard
- Basic health checks

### FULL Tier (When `NFTBAN_METRICS_ENABLED=true`)

| Component | Data |
|-----------|------|
| Prometheus metrics | All 93 metrics |
| Textfile collector | .prom output |
| promauto counters | Event counts |
| /metrics endpoint | HTTP scrape |

---

## Execution Order

### Step 1: Create Shared Snapshot State

**File:** `pkg/state/snapshot.go` (NEW)

```go
package state

import (
    "sync"
    "time"
)

// BasicSnapshot holds data needed by BASIC tier
type BasicSnapshot struct {
    // nftables data (from watchdog netlink)
    BannedIPv4    int64
    BannedIPv6    int64
    WhitelistIPv4 int64
    WhitelistIPv6 int64
    RulesTotal    int64

    // Feeds data (from loader in-memory)
    FeedsActive   int
    FeedsIPs      int64

    // Timestamp
    UpdatedAt     time.Time
}

var (
    current  BasicSnapshot
    mu       sync.RWMutex
)

// Update is called by watchdog after each collection
func Update(snap BasicSnapshot) {
    mu.Lock()
    defer mu.Unlock()
    snap.UpdatedAt = time.Now()
    current = snap
}

// Get returns current snapshot (for stats CLI, sampler, UI)
func Get() BasicSnapshot {
    mu.RLock()
    defer mu.RUnlock()
    return current
}

// GetBannedTotal returns total banned IPs
func GetBannedTotal() int64 {
    mu.RLock()
    defer mu.RUnlock()
    return current.BannedIPv4 + current.BannedIPv6
}

// GetWhitelistTotal returns total whitelist IPs
func GetWhitelistTotal() int64 {
    mu.RLock()
    defer mu.RUnlock()
    return current.WhitelistIPv4 + current.WhitelistIPv6
}
```

### Step 2: Update Watchdog to Populate Snapshot

**File:** `pkg/watchdog/watchdog.go`

```go
// In collectSnapshot() method, after collecting nftables data:
func (w *Watchdog) collectSnapshot() {
    // ... existing collection code ...

    // Update shared state for BASIC tier consumers
    state.Update(state.BasicSnapshot{
        BannedIPv4:    w.snapshot.NFTables.SetElements["blacklist_ipv4"],
        BannedIPv6:    w.snapshot.NFTables.SetElements["blacklist_ipv6"],
        WhitelistIPv4: w.snapshot.NFTables.SetElements["whitelist_ipv4"],
        WhitelistIPv6: w.snapshot.NFTables.SetElements["whitelist_ipv6"],
        RulesTotal:    w.snapshot.NFTables.RulesTotal,
        FeedsActive:   w.feedsLoader.GetActiveCount(),
        FeedsIPs:      w.feedsLoader.GetTotalIPs(),
    })
}
```

### Step 3: Update sampler.go to Use Shared State

**File:** `pkg/metrics/sampler.go`

```go
func (s *Sampler) takeSample() {
    // Get shared state (BASIC tier - always available)
    snap := state.Get()

    // BASIC metrics (always collected)
    s.basicBannedIPs = snap.BannedIPv4 + snap.BannedIPv6
    s.basicWhitelistIPs = snap.WhitelistIPv4 + snap.WhitelistIPv6
    s.basicFeedsActive = snap.FeedsActive
    s.basicFeedsIPs = snap.FeedsIPs

    // FULL metrics (only if enabled)
    if !metrics.IsEnabled() {
        return
    }

    // Continue with full collection...
    s.blockedIPsGauge.Set(float64(snap.BannedIPv4 + snap.BannedIPv6))
    s.whitelistIPsGauge.Set(float64(snap.WhitelistIPv4 + snap.WhitelistIPv6))
    s.feedsActiveGauge.Set(float64(snap.FeedsActive))
    // ... rest of FULL tier metrics
}
```

### Step 4: Update nftban stats to Use Shared State

**Option A: Go API (preferred)**

Create Go API that stats CLI can call:

**File:** `pkg/api/stats_api.go`

```go
package api

import "github.com/itcmsgr/nftban/pkg/state"

// StatsResponse for nftban stats command
type StatsResponse struct {
    BannedIPv4    int64 `json:"banned_ipv4"`
    BannedIPv6    int64 `json:"banned_ipv6"`
    BannedTotal   int64 `json:"banned_total"`
    WhitelistIPv4 int64 `json:"whitelist_ipv4"`
    WhitelistIPv6 int64 `json:"whitelist_ipv6"`
    WhitelistTotal int64 `json:"whitelist_total"`
    FeedsActive   int   `json:"feeds_active"`
    FeedsIPs      int64 `json:"feeds_ips"`
    UpdatedAt     int64 `json:"updated_at"`
}

// GetBasicStats returns stats from shared state (no CLI)
func GetBasicStats() StatsResponse {
    snap := state.Get()
    return StatsResponse{
        BannedIPv4:     snap.BannedIPv4,
        BannedIPv6:     snap.BannedIPv6,
        BannedTotal:    snap.BannedIPv4 + snap.BannedIPv6,
        WhitelistIPv4:  snap.WhitelistIPv4,
        WhitelistIPv6:  snap.WhitelistIPv6,
        WhitelistTotal: snap.WhitelistIPv4 + snap.WhitelistIPv6,
        FeedsActive:    snap.FeedsActive,
        FeedsIPs:       snap.FeedsIPs,
        UpdatedAt:      snap.UpdatedAt.Unix(),
    }
}
```

**File:** `cmd/nftban-core/cmd_stats_api.go`

```go
// Handler for: nftban stats --api
func cmdStatsAPI() {
    stats := api.GetBasicStats()
    json.NewEncoder(os.Stdout).Encode(stats)
}
```

**Option B: IPC Socket**

Stats CLI queries nftband via IPC:

```bash
# In nftban_stats.sh
nftban_stats_get_basic() {
    # Query daemon via IPC instead of nft CLI
    local response
    response=$(nftban-ipc stats-basic 2>/dev/null) || {
        # Fallback to nft CLI if daemon not running
        _nftban_stats_get_basic_cli
        return
    }
    echo "$response"
}
```

### Step 5: Update nftban_stats.sh to Use API

**File:** `cli/lib/nftban/core/nftban_stats.sh`

```bash
nftban_stats_count_active_bans() {
    # TRY 1: Get from daemon API (fast, no CLI)
    local api_result
    if api_result=$(nftban stats --api --json 2>/dev/null); then
        echo "$api_result" | jq -r '.banned_total'
        return 0
    fi

    # TRY 2: Get from shared state file (if daemon writes it)
    local state_file="${NFTBAN_DATA_DIR}/state/basic.json"
    if [[ -f "$state_file" ]]; then
        local age
        age=$(( $(date +%s) - $(stat -c %Y "$state_file") ))
        if [[ $age -lt 60 ]]; then  # Fresh enough
            jq -r '.banned_total' "$state_file"
            return 0
        fi
    fi

    # TRY 3: Fallback to nft CLI (slow, but always works)
    _nftban_stats_count_active_bans_cli
}

_nftban_stats_count_active_bans_cli() {
    # Original CLI implementation (fallback only)
    local black_v4=0 black_v6=0
    if nft list set "${NFTBAN_TABLE_IPV4}" blacklist_ipv4 &>/dev/null; then
        black_v4=$(nft list set "${NFTBAN_TABLE_IPV4}" blacklist_ipv4 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | wc -l)
    fi
    # ... etc
    echo $((black_v4 + black_v6))
}
```

---

## Implementation Checklist

### Week 1: Foundation

- [ ] **Day 1-2:** Create `pkg/state/snapshot.go` with BasicSnapshot
- [ ] **Day 2-3:** Update watchdog to populate shared state
- [ ] **Day 3-4:** Add `--api` flag to nftban stats command
- [ ] **Day 4-5:** Test BASIC tier data flow

### Week 2: sampler.go Refactor

- [ ] **Day 1-2:** Remove CLI calls from sampler.go
- [ ] **Day 2-3:** Implement tiered collection (BASIC always, FULL if enabled)
- [ ] **Day 3-4:** Update callers (nftband, nftban-ui)
- [ ] **Day 4-5:** Test and verify metrics

### Week 3: Stats Integration

- [ ] **Day 1-2:** Update nftban_stats.sh to use API first
- [ ] **Day 2-3:** Add fallback logic for when daemon not running
- [ ] **Day 3-4:** Test `nftban stats` in all scenarios
- [ ] **Day 4-5:** Documentation and cleanup

---

## User Experience After Optimization

### `nftban status` Command (Enhanced with Metrics Info)

```
$ nftban status

🛡️ NFTBan System Status
======================================================================

📊 Current Statistics:
----------------------------------------------------------------------
Whitelist IPv4: 12
Whitelist IPv6: 3
Blacklist IPv4: 1,234
Blacklist IPv6: 89
Last Reload:    2026-01-24 14:30:00

📈 Counters:
----------------------------------------------------------------------
Total Bans:     5,678
Total Unbans:   1,234
Total Reloads:  45
Total Syncs:    890
Sync Errors:    2

📡 Metrics Status:                          ← NEW SECTION
----------------------------------------------------------------------
  Metrics Enabled:    true                  ← From NFTBAN_METRICS_ENABLED
  Metrics Backend:    prometheus            ← From NFTBAN_METRICS_BACKEND
  Sampler Running:    true                  ← sampler.IsRunning()
  Sampler Mode:       continuous            ← continuous or session-based
  Collection Tier:    FULL                  ← BASIC or FULL
  Last Sample:        2 seconds ago         ← sampler.GetLastSampleTime()
  Samples Stored:     360/360               ← ring buffer status

  Endpoints:
    nftband:          http://localhost:8080/metrics (78 metrics)
    nftban-ui:        http://localhost:8443/metrics (15 metrics)

  Watchdog Mode:      NORMAL                ← NORMAL/DEGRADED/SURVIVAL
  Watchdog Score:     35/100                ← pressure score

======================================================================
✅ Status check complete!
```

### `nftban stats` Command

```
$ nftban stats

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  NFTBan Statistics Dashboard
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

FIREWALL (CURRENT)
───────────────────────────────────────────────────────────
  Blocked IPs......... 1,234        ← From shared state (instant)
  Whitelisted......... 56           ← From shared state (instant)

FEEDS
───────────────────────────────────────────────────────────
  Active Feeds........ 12           ← From shared state (instant)
  Total IPs........... 45,678       ← From shared state (instant)

Data Source: daemon API (fast)      ← Shows data source to user
Last Updated: 2 seconds ago         ← Shows freshness
```

### When Daemon Not Running

```
$ nftban stats

[INFO] Daemon not running, using direct nftables query...

FIREWALL (CURRENT)
───────────────────────────────────────────────────────────
  Blocked IPs......... 1,234        ← From nft CLI (fallback)
  ...

Data Source: nft CLI (fallback)     ← Informs user of slower path
```

---

## Verification Commands

```bash
# 1. Check shared state is being updated
cat /var/lib/nftban/state/basic.json
# Should show recent timestamp

# 2. Check stats uses API
nftban stats --debug
# Should show "Data Source: daemon API"

# 3. Check no CLI calls in sampler
strace -e execve -p $(pgrep nftband) 2>&1 | grep -E "nft|nftban"
# Should show NO nft/nftban calls from sampler

# 4. Verify BASIC tier always works
systemctl stop nftband
nftban stats
# Should still work (fallback to CLI)
```

---

## Summary: What Changes for User

| Scenario | Before | After |
|----------|--------|-------|
| `nftban stats` | Always uses nft CLI | Uses API first, CLI fallback |
| UI Dashboard | sampler CLI polling | Reads shared state |
| Metrics disabled | Still collected | BASIC only, minimal cost |
| Daemon stopped | Works | Works (CLI fallback) |
| Performance | ~2s CPU/min | ~0.05s CPU/min |

---

## Files to Create/Modify

| Priority | File | Action |
|----------|------|--------|
| **P0** | `pkg/state/snapshot.go` | **CREATE** - Shared state |
| **P0** | `pkg/watchdog/watchdog.go` | MODIFY - Populate shared state |
| **P0** | `pkg/metrics/sampler.go` | MODIFY - Remove CLI, use shared state |
| **P1** | `cmd/nftban-core/cmd_status.go` | MODIFY - Add metrics info section |
| **P1** | `cmd/nftban-core/cmd_stats.go` | **CREATE** - Stats API handler |
| **P1** | `cli/lib/nftban/core/nftban_stats.sh` | MODIFY - Use API first |
| **P2** | `pkg/api/handlers.go` | MODIFY - Expose stats API |

---

## Code Change: Add Metrics Info to `nftban status`

**File:** `cmd/nftban-core/cmd_status.go`

```go
func cmdStatus(cfg *nftbanconf.Config) error {
    // ... existing code ...

    // NEW: Display metrics status
    fmt.Println("📡 Metrics Status:")
    fmt.Println(strings.Repeat("-", 70))

    // Metrics configuration
    fmt.Printf("  Metrics Enabled:    %v\n", cfg.MetricsEnabled)
    if cfg.MetricsEnabled {
        fmt.Printf("  Metrics Backend:    %s\n", cfg.MetricsBackend)
    }

    // Sampler status (if running)
    sampler := metrics.GetSampler()
    if sampler != nil {
        status := sampler.GetStatus()
        fmt.Printf("  Sampler Running:    %v\n", status["running"])
        if status["metrics_enabled"].(bool) {
            fmt.Printf("  Sampler Mode:       continuous\n")
        } else {
            fmt.Printf("  Sampler Mode:       session-based (%d active)\n", status["active_sessions"])
        }

        // Collection tier
        if cfg.MetricsEnabled {
            fmt.Printf("  Collection Tier:    FULL\n")
        } else {
            fmt.Printf("  Collection Tier:    BASIC (UI only)\n")
        }

        // Last sample
        if lastSample, ok := status["last_sample"].(time.Time); ok && !lastSample.IsZero() {
            age := time.Since(lastSample).Truncate(time.Second)
            fmt.Printf("  Last Sample:        %s ago\n", age)
        }

        // Ring buffer
        fmt.Printf("  Samples Stored:     %d/%d\n", status["samples_stored"], status["max_samples"])
    } else {
        fmt.Printf("  Sampler:            not initialized\n")
        fmt.Printf("  Collection Tier:    BASIC (metrics disabled)\n")
    }

    fmt.Println()

    // Endpoints info
    fmt.Println("  Endpoints:")
    fmt.Printf("    nftband:          http://localhost:8080/metrics\n")
    if sampler != nil {
        fmt.Printf("    nftban-ui:        http://localhost:8443/metrics\n")
    }
    fmt.Println()

    // Watchdog status
    if wdSnapshot := watchdog.GetSnapshot(); wdSnapshot != nil {
        fmt.Printf("  Watchdog Mode:      %s\n", wdSnapshot.OperatingMode)
        fmt.Printf("  Watchdog Score:     %.0f/100\n", wdSnapshot.PressureScore)
    }

    fmt.Println()

    // ... rest of existing code ...
}
```

---

## Start Command

```bash
# Step 1: Create shared state package
mkdir -p /home/gituser/github/nftban/pkg/state
# Create snapshot.go with BasicSnapshot

# Step 2: Update watchdog
# Edit pkg/watchdog/watchdog.go to call state.Update()

# Step 3: Test
go build ./...
go test ./pkg/state/...
go test ./pkg/watchdog/...

# Step 4: Continue with sampler.go refactor
```

---

**Document Status:** READY TO EXECUTE
**Start With:** `pkg/state/snapshot.go` (shared state)
**Goal:** All consumers read from shared state, zero CLI polling for metrics
