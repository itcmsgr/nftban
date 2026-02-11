// =============================================================================
// NFTBan v1.0 - System Collector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="collector_system"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Collects system-level metrics including load, memory, and disk usage"
// meta:inventory.files="/proc/loadavg,/proc/meminfo,/proc/stat"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package watchdog

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
)

// SystemCollector collects OS-level metrics
type SystemCollector struct {
	BaseCollector

	mu sync.Mutex

	lastSample    time.Time
	lastCPUStats  cpuStats
	currentIOWait float64
	diskPath      string
}

type cpuStats struct {
	user, nice, system, idle    uint64
	iowait, irq, softirq, steal uint64
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
func (c *SystemCollector) Collect(ctx context.Context, snapshot *Snapshot) error {
	if !c.Enabled() {
		return nil
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	snapshot.System.NumCPU = runtime.NumCPU()
	c.collectLoadAvg(snapshot)
	c.collectIOWait(snapshot)
	c.collectMemInfo(snapshot)
	c.collectDiskUsage(snapshot)
	c.collectEntropy(snapshot)

	return nil
}

func (c *SystemCollector) collectLoadAvg(snapshot *Snapshot) {
	data, err := os.ReadFile("/proc/loadavg")
	if err != nil {
		return
	}

	fields := strings.Fields(string(data))
	if len(fields) >= 3 {
		snapshot.System.LoadAvg1, _ = strconv.ParseFloat(fields[0], 64)
		snapshot.System.LoadAvg5, _ = strconv.ParseFloat(fields[1], 64)
		snapshot.System.LoadAvg15, _ = strconv.ParseFloat(fields[2], 64)
	}
}

func (c *SystemCollector) collectIOWait(snapshot *Snapshot) {
	stats, err := c.readCPUStats()
	if err != nil {
		return
	}

	now := time.Now()

	if c.lastSample.IsZero() {
		c.lastSample = now
		c.lastCPUStats = stats
		return
	}

	totalDelta := c.totalCPUTime(stats) - c.totalCPUTime(c.lastCPUStats)
	if totalDelta <= 0 {
		return
	}

	iowaitDelta := float64(stats.iowait - c.lastCPUStats.iowait)
	c.currentIOWait = (iowaitDelta / float64(totalDelta)) * 100
	snapshot.System.IOWaitPct = c.currentIOWait

	c.lastSample = now
	c.lastCPUStats = stats
}

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

func (c *SystemCollector) totalCPUTime(stats cpuStats) uint64 {
	return stats.user + stats.nice + stats.system + stats.idle +
		stats.iowait + stats.irq + stats.softirq + stats.steal
}

func (c *SystemCollector) collectMemInfo(snapshot *Snapshot) {
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
		value *= 1024

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

func (c *SystemCollector) collectDiskUsage(snapshot *Snapshot) {
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

func (c *SystemCollector) collectEntropy(snapshot *Snapshot) {
	data, err := os.ReadFile("/proc/sys/kernel/random/entropy_avail")
	if err != nil {
		return
	}
	snapshot.System.Entropy, _ = strconv.Atoi(strings.TrimSpace(string(data)))
}
