// =============================================================================
// NFTBan v1.0 - Go Runtime Collector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// Collects Go runtime metrics:
//   - Goroutine count
//   - Heap allocation/usage
//   - GC statistics
//   - GOMEMLIMIT
//
// =============================================================================

package collectors

import (
	"context"
	"runtime"
	"runtime/debug"

	"github.com/itcmsgr/nftban/pkg/watchdog"
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
func (c *RuntimeCollector) Collect(ctx context.Context, snapshot *watchdog.Snapshot) error {
	if !c.Enabled() {
		return nil
	}

	// Read memory stats
	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)

	// Goroutines
	snapshot.Runtime.Goroutines = runtime.NumGoroutine()

	// Heap metrics
	snapshot.Runtime.HeapAlloc = memStats.HeapAlloc
	snapshot.Runtime.HeapInuse = memStats.HeapInuse
	snapshot.Runtime.HeapReleased = memStats.HeapReleased
	snapshot.Runtime.HeapSys = memStats.HeapSys

	// Stack
	snapshot.Runtime.StackInuse = memStats.StackInuse

	// GC metrics
	snapshot.Runtime.GCCPUFraction = memStats.GCCPUFraction
	snapshot.Runtime.NumGC = memStats.NumGC

	// Last GC pause (most recent)
	if memStats.NumGC > 0 {
		// PauseNs is a circular buffer of recent GC pause times
		idx := (memStats.NumGC + 255) % 256
		snapshot.Runtime.GCPauseNs = memStats.PauseNs[idx]
	}

	// Total GC pause time
	snapshot.Runtime.GCPauseTotalNs = memStats.PauseTotalNs

	// GOMEMLIMIT (Go 1.19+)
	snapshot.Runtime.GOMEMLIMIT = getGOMEMLIMIT()

	return nil
}

// getGOMEMLIMIT returns the GOMEMLIMIT value or -1 if not set
func getGOMEMLIMIT() int64 {
	// Use debug.SetMemoryLimit to read current value
	// Passing -1 returns current value without changing it
	limit := debug.SetMemoryLimit(-1)
	if limit == int64(^uint64(0)>>1) { // MaxInt64 means unlimited
		return -1
	}
	return limit
}
