// =============================================================================
// NFTBan v1.0 - Dynamic Watchdog Package
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="doc"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Package documentation for NFTBan watchdog system"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Package watchdog implements a dynamic runtime watchdog for nftban that:
//
//   - Continuously monitors system + process + kernel/netfilter + nftables signals
//   - Computes a pressure state (OK/WARN/CRITICAL) per dimension (CPU, MEM, IO, NET)
//   - Automatically aligns behavior based on pressure state
//   - Triggers forensic capture (pprof) during incidents
//   - Exposes metrics in Prometheus format
//   - Maintains an on-disk flight recorder for post-mortem analysis
//
// Architecture:
//
//	┌─────────────────────────────────────────────────────────────┐
//	│                     Watchdog Core                           │
//	│  ┌─────────────────────────────────────────────────────────┐│
//	│  │                   State Machine                         ││
//	│  │  NORMAL ←→ DEGRADED ←→ SURVIVAL                         ││
//	│  └─────────────────────────────────────────────────────────┘│
//	│                           │                                 │
//	│     ┌─────────────────────┴─────────────────────┐           │
//	│     ▼                                           ▼           │
//	│  ┌─────────────────┐                 ┌─────────────────────┐│
//	│  │   Collectors    │                 │      Actions        ││
//	│  │  - Process      │                 │  - Throttle         ││
//	│  │  - Runtime      │                 │  - Profile          ││
//	│  │  - System       │                 │  - Memory Valve     ││
//	│  │  - Netfilter    │                 │  - Degrade Mode     ││
//	│  │  - nftables     │                 └─────────────────────┘│
//	│  └─────────────────┘                                        │
//	│                           │                                 │
//	│                           ▼                                 │
//	│              ┌─────────────────────────┐                    │
//	│              │    Flight Recorder      │                    │
//	│              │  - Event JSON           │                    │
//	│              │  - Periodic Snapshots   │                    │
//	│              │  - pprof Profiles       │                    │
//	│              └─────────────────────────┘                    │
//	└─────────────────────────────────────────────────────────────┘
//
// Pressure Dimensions:
//
//   - CPU: Process CPU%, system load, softnet drops
//   - MEM: RSS vs budget, heap vs GOMEMLIMIT, GC fraction, RSS slope
//   - IO: iowait%, disk usage, log partition fullness
//   - NET: conntrack utilization, softnet drops rate, nft apply latency
//
// Operating Modes:
//
//   - NORMAL: All dimensions OK. Full functionality.
//   - DEGRADED: Any dimension WARN. Reduced frequency, backpressure enabled.
//   - SURVIVAL: Any dimension CRITICAL. Essential operations only.
//
// Thread Safety:
//
//	All components are designed for concurrent access. The watchdog runs
//	as a single goroutine with collectors running in parallel.
//
// Usage:
//
//	cfg := watchdog.DefaultConfig()
//	w := watchdog.New(cfg, controls)
//	go w.Run(ctx)
//
// =============================================================================
package watchdog
