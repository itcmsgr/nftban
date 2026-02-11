// =============================================================================
// NFTBan v1.0 - Kernel/Netfilter Collector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="collector_kernel"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Collects kernel and netfilter metrics including conntrack and softnet"
// meta:inventory.files="/proc/sys/net/netfilter"
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
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// KernelCollector collects kernel/netfilter metrics
type KernelCollector struct {
	BaseCollector

	mu sync.Mutex

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
func (c *KernelCollector) Collect(ctx context.Context, snapshot *Snapshot) error {
	if !c.Enabled() {
		return nil
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	c.collectConntrack(snapshot)
	c.collectSoftnet(snapshot)
	c.collectNICDrops(snapshot)

	return nil
}

func (c *KernelCollector) collectConntrack(snapshot *Snapshot) {
	countData, err := os.ReadFile("/proc/sys/net/netfilter/nf_conntrack_count")
	if err != nil {
		return
	}
	snapshot.Kernel.ConntrackCount, _ = strconv.Atoi(strings.TrimSpace(string(countData)))

	maxData, err := os.ReadFile("/proc/sys/net/netfilter/nf_conntrack_max")
	if err != nil {
		return
	}
	snapshot.Kernel.ConntrackMax, _ = strconv.Atoi(strings.TrimSpace(string(maxData)))

	if snapshot.Kernel.ConntrackMax > 0 {
		snapshot.Kernel.ConntrackUtilization = float64(snapshot.Kernel.ConntrackCount) /
			float64(snapshot.Kernel.ConntrackMax)
	}
}

func (c *KernelCollector) collectSoftnet(snapshot *Snapshot) {
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

		drops, err := strconv.ParseUint(fields[1], 16, 64)
		if err == nil {
			totalDrops += drops
		}

		squeeze, err := strconv.ParseUint(fields[2], 16, 64)
		if err == nil {
			totalSqueeze += squeeze
		}
	}

	snapshot.Kernel.SoftnetDrops = totalDrops
	snapshot.Kernel.SoftnetTimeSqueeze = totalSqueeze

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

func (c *KernelCollector) collectNICDrops(snapshot *Snapshot) {
	var totalDrops uint64

	entries, err := os.ReadDir("/sys/class/net")
	if err != nil {
		return
	}

	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}

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
