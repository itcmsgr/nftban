// =============================================================================
// NFTBan v1.0 - Process Collector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// Collects process-level metrics from /proc/self:
//   - RSS (Resident Set Size)
//   - CPU percentage (computed from utime+stime)
//   - Open file descriptors
//   - Thread count
//
// =============================================================================

package watchdog

import (
	"context"
	"os"
	"sync"
	"time"

	"github.com/prometheus/procfs"
)

// ProcessCollector collects process-level metrics
type ProcessCollector struct {
	BaseCollector

	mu sync.Mutex

	// For CPU percentage calculation
	lastSample     time.Time
	lastTotalTicks float64
	cpuPct         float64

	// For smoothing
	smoothingFactor float64

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
		smoothingFactor: 0.3,
		proc:            proc,
	}, nil
}

// Collect gathers process metrics
func (c *ProcessCollector) Collect(ctx context.Context, snapshot *Snapshot) error {
	if !c.Enabled() {
		return nil
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	stat, err := c.proc.Stat()
	if err != nil {
		return err
	}

	snapshot.Process.PID = os.Getpid()
	snapshot.Process.RSS = uint64(stat.ResidentMemory())
	snapshot.Process.VMS = uint64(stat.VirtualMemory())
	snapshot.Process.Threads = stat.NumThreads
	snapshot.Process.Uptime = time.Since(c.startTime).Seconds()
	snapshot.Process.CPUPct = c.calculateCPUPercent(stat)

	fds, err := c.countOpenFDs()
	if err == nil {
		snapshot.Process.FDs = fds
	}

	return nil
}

func (c *ProcessCollector) calculateCPUPercent(stat procfs.ProcStat) float64 {
	now := time.Now()
	totalTicks := float64(stat.UTime + stat.STime)

	if c.lastSample.IsZero() {
		c.lastSample = now
		c.lastTotalTicks = totalTicks
		return 0
	}

	elapsed := now.Sub(c.lastSample).Seconds()
	if elapsed < 0.1 {
		return c.cpuPct
	}

	tickDelta := totalTicks - c.lastTotalTicks
	clockTicks := float64(100)
	rawPct := (tickDelta / clockTicks) / elapsed * 100

	if c.cpuPct == 0 {
		c.cpuPct = rawPct
	} else {
		c.cpuPct = c.smoothingFactor*rawPct + (1-c.smoothingFactor)*c.cpuPct
	}

	c.lastSample = now
	c.lastTotalTicks = totalTicks

	return c.cpuPct
}

func (c *ProcessCollector) countOpenFDs() (int, error) {
	entries, err := os.ReadDir("/proc/self/fd")
	if err != nil {
		return 0, err
	}
	return len(entries), nil
}
