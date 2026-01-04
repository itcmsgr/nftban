// =============================================================================
// NFTBan v1.0 - Kernel/Netfilter Collector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// Collects kernel and netfilter metrics:
//   - Conntrack count and max
//   - Conntrack utilization
//   - Softnet drops (aggregated across CPUs)
//   - Softnet time squeeze
//   - NIC RX drops (aggregated across interfaces)
//
// =============================================================================

package collectors

import (
	"bufio"
	"context"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/pkg/watchdog"
)

// KernelCollector collects kernel/netfilter metrics
type KernelCollector struct {
	BaseCollector

	mu sync.Mutex

	// For rate calculation
	lastSample       time.Time
	lastSoftnetDrops uint64
	lastNICDrops     uint64
	softnetDropsRate float64
	nicDropsRate     float64
}

// NewKernelCollector creates a new kernel collector
func NewKernelCollector() *KernelCollector {
	return &KernelCollector{
		BaseCollector: NewBaseCollector("kernel"),
	}
}

// Collect gathers kernel metrics
func (c *KernelCollector) Collect(ctx context.Context, snapshot *watchdog.Snapshot) error {
	if !c.Enabled() {
		return nil
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	// Conntrack
	c.collectConntrack(snapshot)

	// Softnet stats
	c.collectSoftnet(snapshot)

	// NIC drops
	c.collectNICDrops(snapshot)

	return nil
}

// collectConntrack reads conntrack metrics
func (c *KernelCollector) collectConntrack(snapshot *watchdog.Snapshot) {
	// Read current count
	countData, err := os.ReadFile("/proc/sys/net/netfilter/nf_conntrack_count")
	if err != nil {
		// Conntrack might not be loaded
		return
	}
	snapshot.Kernel.ConntrackCount, _ = strconv.Atoi(strings.TrimSpace(string(countData)))

	// Read max
	maxData, err := os.ReadFile("/proc/sys/net/netfilter/nf_conntrack_max")
	if err != nil {
		return
	}
	snapshot.Kernel.ConntrackMax, _ = strconv.Atoi(strings.TrimSpace(string(maxData)))

	// Calculate utilization
	if snapshot.Kernel.ConntrackMax > 0 {
		snapshot.Kernel.ConntrackUtilization = float64(snapshot.Kernel.ConntrackCount) /
			float64(snapshot.Kernel.ConntrackMax)
	}
}

// collectSoftnet reads softnet statistics from /proc/net/softnet_stat
// Format: Per-CPU lines with hex fields
// Fields: processed, dropped, time_squeeze, ...
func (c *KernelCollector) collectSoftnet(snapshot *watchdog.Snapshot) {
	f, err := os.Open("/proc/net/softnet_stat")
	if err != nil {
		return
	}
	defer f.Close()

	var totalDrops, totalSqueeze uint64

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		fields := strings.Fields(line)
		if len(fields) < 3 {
			continue
		}

		// Field 1 (index 1) is drops in hex
		drops, err := strconv.ParseUint(fields[1], 16, 64)
		if err == nil {
			totalDrops += drops
		}

		// Field 2 (index 2) is time_squeeze in hex
		squeeze, err := strconv.ParseUint(fields[2], 16, 64)
		if err == nil {
			totalSqueeze += squeeze
		}
	}

	snapshot.Kernel.SoftnetDrops = totalDrops
	snapshot.Kernel.SoftnetTimeSqueeze = totalSqueeze

	// Calculate rate if we have a previous sample
	now := time.Now()
	if !c.lastSample.IsZero() {
		elapsed := now.Sub(c.lastSample).Seconds()
		if elapsed > 0 {
			c.softnetDropsRate = float64(totalDrops-c.lastSoftnetDrops) / elapsed
		}
	}

	c.lastSample = now
	c.lastSoftnetDrops = totalDrops
}

// collectNICDrops aggregates RX drops across all network interfaces
func (c *KernelCollector) collectNICDrops(snapshot *watchdog.Snapshot) {
	var totalDrops uint64

	// Read from /sys/class/net/*/statistics/rx_dropped
	entries, err := os.ReadDir("/sys/class/net")
	if err != nil {
		return
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

		// Skip loopback and virtual interfaces
		name := entry.Name()
		if name == "lo" || strings.HasPrefix(name, "docker") ||
			strings.HasPrefix(name, "veth") || strings.HasPrefix(name, "br-") ||
			strings.HasPrefix(name, "virbr") {
			continue
		}

		dropsPath := filepath.Join("/sys/class/net", name, "statistics/rx_dropped")
		data, err := os.ReadFile(dropsPath)
		if err != nil {
			continue
		}

		drops, err := strconv.ParseUint(strings.TrimSpace(string(data)), 10, 64)
		if err == nil {
			totalDrops += drops
		}
	}

	snapshot.Kernel.NICDrops = totalDrops

	// Update rate calculation
	if !c.lastSample.IsZero() {
		elapsed := time.Since(c.lastSample).Seconds()
		if elapsed > 0 && c.lastNICDrops > 0 {
			c.nicDropsRate = float64(totalDrops-c.lastNICDrops) / elapsed
		}
	}
	c.lastNICDrops = totalDrops
}

// GetSoftnetDropsRate returns the current softnet drops rate per second
func (c *KernelCollector) GetSoftnetDropsRate() float64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.softnetDropsRate
}

// GetNICDropsRate returns the current NIC drops rate per second
func (c *KernelCollector) GetNICDropsRate() float64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.nicDropsRate
}
