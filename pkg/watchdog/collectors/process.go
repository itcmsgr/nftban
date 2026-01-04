// =============================================================================
// NFTBan v1.0 - Process Collector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// Collects process-level metrics from /proc/self:
//   - RSS (Resident Set Size)
//   - VMS (Virtual Memory Size)
//   - CPU percentage (computed from utime+stime)
//   - Open file descriptors
//   - Thread count
//   - Uptime
//
// Uses procfs library for robust /proc parsing.
// =============================================================================

package collectors

import (
	"context"
	"os"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/watchdog"
	"github.com/prometheus/procfs"
)

// ProcessCollector collects process-level metrics
type ProcessCollector struct {
	BaseCollector

	mu sync.Mutex

	// For CPU percentage calculation
	lastSample     time.Time
	lastTotalTicks float64
	cpuPct         float64 // Smoothed value

	// For smoothing
	smoothingFactor float64 // EMA alpha

	// Start time for uptime
	startTime time.Time

	// procfs handle
	proc procfs.Proc
}

// NewProcessCollector creates a new process collector
func NewProcessCollector() (*ProcessCollector, error) {
	proc, err := procfs.Self()
	if err != nil {
		return nil, err
	}

	return &ProcessCollector{
		BaseCollector:   NewBaseCollector("process"),
		startTime:       time.Now(),
		smoothingFactor: 0.3, // EMA with alpha=0.3 for smoothing
		proc:            proc,
	}, nil
}

// Collect gathers process metrics
func (c *ProcessCollector) Collect(ctx context.Context, snapshot *watchdog.Snapshot) error {
	if !c.Enabled() {
		return nil
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	// Get process stats
	stat, err := c.proc.Stat()
	if err != nil {
		return err
	}

	// PID
	snapshot.Process.PID = os.Getpid()

	// RSS and VMS from stat
	snapshot.Process.RSS = uint64(stat.ResidentMemory())
	snapshot.Process.VMS = uint64(stat.VirtualMemory())

	// Thread count from stat
	snapshot.Process.Threads = stat.NumThreads

	// Uptime
	snapshot.Process.Uptime = time.Since(c.startTime).Seconds()

	// CPU percentage calculation
	snapshot.Process.CPUPct = c.calculateCPUPercent(stat)

	// Open file descriptors
	fds, err := c.countOpenFDs()
	if err == nil {
		snapshot.Process.FDs = fds
	}

	return nil
}

// calculateCPUPercent computes CPU usage percentage using delta of utime+stime
func (c *ProcessCollector) calculateCPUPercent(stat procfs.ProcStat) float64 {
	now := time.Now()

	// Total CPU ticks (user + system)
	totalTicks := stat.UTime + stat.STime

	// First sample - no delta yet
	if c.lastSample.IsZero() {
		c.lastSample = now
		c.lastTotalTicks = totalTicks
		return 0
	}

	// Calculate delta
	elapsed := now.Sub(c.lastSample).Seconds()
	if elapsed < 0.1 { // Avoid division by near-zero
		return c.cpuPct
	}

	tickDelta := totalTicks - c.lastTotalTicks

	// CPU ticks per second (usually 100 on Linux)
	clockTicks := float64(100) // sysconf(_SC_CLK_TCK)

	// CPU percentage
	rawPct := (tickDelta / clockTicks) / elapsed * 100

	// Apply exponential moving average for smoothing
	if c.cpuPct == 0 {
		c.cpuPct = rawPct
	} else {
		c.cpuPct = c.smoothingFactor*rawPct + (1-c.smoothingFactor)*c.cpuPct
	}

	// Update for next calculation
	c.lastSample = now
	c.lastTotalTicks = totalTicks

	return c.cpuPct
}

// countOpenFDs counts open file descriptors by reading /proc/self/fd
func (c *ProcessCollector) countOpenFDs() (int, error) {
	entries, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		return 0, err
	}
	return len(entries), nil
}

// GetCPUPercent returns the current smoothed CPU percentage
func (c *ProcessCollector) GetCPUPercent() float64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.cpuPct
}
