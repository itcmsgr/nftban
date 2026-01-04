// =============================================================================
// NFTBan v1.0 - System Collector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// Collects system-level metrics:
//   - Load average
//   - CPU count
//   - I/O wait percentage
//   - Memory (total, free, available)
//   - Swap usage
//   - Disk usage (log partition)
//   - Entropy available
//
// =============================================================================

package collectors

import (
	"bufio"
	"context"
	"os"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/itcmsgr/nftban/pkg/watchdog"
)

// SystemCollector collects OS-level metrics
type SystemCollector struct {
	BaseCollector

	mu sync.Mutex

	// For iowait calculation
	lastSample     time.Time
	lastCPUStats   cpuStats
	currentIOWait  float64

	// Disk path to monitor
	diskPath string
}

// cpuStats holds CPU time values from /proc/stat
type cpuStats struct {
	user    uint64
	nice    uint64
	system  uint64
	idle    uint64
	iowait  uint64
	irq     uint64
	softirq uint64
	steal   uint64
}

// NewSystemCollector creates a new system collector
func NewSystemCollector(diskPath string) *SystemCollector {
	if diskPath == "" {
		diskPath = "/var/log"
	}
	return &SystemCollector{
		BaseCollector: NewBaseCollector("system"),
		diskPath:      diskPath,
	}
}

// Collect gathers system metrics
func (c *SystemCollector) Collect(ctx context.Context, snapshot *watchdog.Snapshot) error {
	if !c.Enabled() {
		return nil
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	// CPU count
	snapshot.System.NumCPU = runtime.NumCPU()

	// Load average
	c.collectLoadAvg(snapshot)

	// I/O wait percentage
	c.collectIOWait(snapshot)

	// Memory info
	c.collectMemInfo(snapshot)

	// Disk usage
	c.collectDiskUsage(snapshot)

	// Entropy
	c.collectEntropy(snapshot)

	return nil
}

// collectLoadAvg reads load average from /proc/loadavg
func (c *SystemCollector) collectLoadAvg(snapshot *watchdog.Snapshot) {
	data, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return
	}

	fields := strings.Fields(string(data))
	if len(fields) < 3 {
		return
	}

	snapshot.System.LoadAvg1, _ = strconv.ParseFloat(fields[0], 64)
	snapshot.System.LoadAvg5, _ = strconv.ParseFloat(fields[1], 64)
	snapshot.System.LoadAvg15, _ = strconv.ParseFloat(fields[2], 64)
}

// collectIOWait calculates I/O wait percentage from /proc/stat
func (c *SystemCollector) collectIOWait(snapshot *watchdog.Snapshot) {
	stats, err := c.readCPUStats()
	if err != nil {
		return
	}

	now := time.Now()

	// First sample - no delta yet
	if c.lastSample.IsZero() {
		c.lastSample = now
		c.lastCPUStats = stats
		return
	}

	// Calculate delta
	totalDelta := c.totalCPUTime(stats) - c.totalCPUTime(c.lastCPUStats)
	if totalDelta <= 0 {
		return
	}

	iowaitDelta := float64(stats.iowait - c.lastCPUStats.iowait)
	c.currentIOWait = (iowaitDelta / float64(totalDelta)) * 100

	snapshot.System.IOWaitPct = c.currentIOWait

	// Update for next calculation
	c.lastSample = now
	c.lastCPUStats = stats
}

// readCPUStats reads CPU stats from /proc/stat
func (c *SystemCollector) readCPUStats() (cpuStats, error) {
	var stats cpuStats

	f, err := os.Open("/proc/stat")
	if err != nil {
		return stats, err
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "cpu ") {
			fields := strings.Fields(line)
			if len(fields) >= 9 {
				stats.user, _ = strconv.ParseUint(fields[1], 10, 64)
				stats.nice, _ = strconv.ParseUint(fields[2], 10, 64)
				stats.system, _ = strconv.ParseUint(fields[3], 10, 64)
				stats.idle, _ = strconv.ParseUint(fields[4], 10, 64)
				stats.iowait, _ = strconv.ParseUint(fields[5], 10, 64)
				stats.irq, _ = strconv.ParseUint(fields[6], 10, 64)
				stats.softirq, _ = strconv.ParseUint(fields[7], 10, 64)
				stats.steal, _ = strconv.ParseUint(fields[8], 10, 64)
			}
			break
		}
	}

	return stats, nil
}

// totalCPUTime returns total CPU time from stats
func (c *SystemCollector) totalCPUTime(stats cpuStats) uint64 {
	return stats.user + stats.nice + stats.system + stats.idle +
		stats.iowait + stats.irq + stats.softirq + stats.steal
}

// collectMemInfo reads memory info from /proc/meminfo
func (c *SystemCollector) collectMemInfo(snapshot *watchdog.Snapshot) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		parts := strings.Fields(line)
		if len(parts) < 2 {
			continue
		}

		key := strings.TrimSuffix(parts[0], ":")
		value, _ := strconv.ParseUint(parts[1], 10, 64)
		value *= 1024 // Convert from KB to bytes

		switch key {
		case "MemTotal":
			snapshot.System.MemTotal = value
		case "MemFree":
			snapshot.System.MemFree = value
		case "MemAvailable":
			snapshot.System.MemAvail = value
		case "SwapTotal":
			snapshot.System.SwapTotal = value
		case "SwapFree":
			snapshot.System.SwapFree = value
		}
	}
}

// collectDiskUsage gets disk usage for the configured path
func (c *SystemCollector) collectDiskUsage(snapshot *watchdog.Snapshot) {
	var stat syscall.Statfs_t
	if err := syscall.Statfs(c.diskPath, &stat); err != nil {
		return
	}

	totalBytes := stat.Blocks * uint64(stat.Bsize)
	freeBytes := stat.Bfree * uint64(stat.Bsize)

	if totalBytes > 0 {
		usedBytes := totalBytes - freeBytes
		snapshot.System.DiskUsePct = float64(usedBytes) / float64(totalBytes) * 100
	}
}

// collectEntropy reads available entropy from kernel
func (c *SystemCollector) collectEntropy(snapshot *watchdog.Snapshot) {
	data, err := os.ReadFile("/proc/sys/kernel/random/entropy_avail")
	if err != nil {
		return
	}

	snapshot.System.Entropy, _ = strconv.Atoi(strings.TrimSpace(string(data)))
}
