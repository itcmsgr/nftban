// =============================================================================
// NFTBan v1.0 - Go Runtime Collector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="collector_runtime"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Collects Go runtime metrics including goroutines, heap, and GC stats"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package watchdog

import (
	"context"
	"runtime"
	"runtime/debug"
)

// RuntimeCollector collects Go runtime metrics
type RuntimeCollector struct {
	BaseCollector
}

// NewRuntimeCollector creates a new runtime collector
func NewRuntimeCollector() *RuntimeCollector {
	return &RuntimeCollector{
		BaseCollector: NewBaseCollector("runtime"),
	}
}

// Collect gathers Go runtime metrics
func (c *RuntimeCollector) Collect(ctx context.Context, snapshot *Snapshot) error {
	if !c.Enabled() {
		return nil
	}

	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)

	snapshot.Runtime.Goroutines = runtime.NumGoroutine()
	snapshot.Runtime.HeapAlloc = memStats.HeapAlloc
	snapshot.Runtime.HeapInuse = memStats.HeapInuse
	snapshot.Runtime.HeapReleased = memStats.HeapReleased
	snapshot.Runtime.HeapSys = memStats.HeapSys
	snapshot.Runtime.StackInuse = memStats.StackInuse
	snapshot.Runtime.GCCPUFraction = memStats.GCCPUFraction
	snapshot.Runtime.NumGC = memStats.NumGC

	if memStats.NumGC > 0 {
		idx := (memStats.NumGC + 255) % 256
		snapshot.Runtime.GCPauseNs = memStats.PauseNs[idx]
	}

	snapshot.Runtime.GCPauseTotalNs = memStats.PauseTotalNs
	snapshot.Runtime.GOMEMLIMIT = getGOMEMLIMIT()

	return nil
}

func getGOMEMLIMIT() int64 {
	limit := debug.SetMemoryLimit(-1)
	if limit == int64(^uint64(0)>>1) {
		return -1
	}
	return limit
}
