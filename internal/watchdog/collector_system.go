// =============================================================================
// NFTBan v1.0 - System Collector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="collector_system"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Collects system-level metrics including load, memory, and disk usage"
// meta:inventory.files="/proc/loadavg,/proc/meminfo,/proc/stat,/proc/vmstat,/proc/self/mountinfo"
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

	"github.com/itcmsgr/nftban/internal/safeconv"
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
	// PR-M2b-w1: host-vitals additions per schema doc 17 §F4.
	c.collectMultiMountDisks(snapshot)
	c.collectOOMEvents(snapshot)

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

	totalBytes := stat.Blocks * safeconv.Int64ToUint64OrZero(stat.Bsize)
	freeBytes := stat.Bfree * safeconv.Int64ToUint64OrZero(stat.Bsize)

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

// =============================================================================
// PR-M2b-w1 (v1.112) — Host-vitals collection per schema doc 17 §F4
// =============================================================================

// defaultHostDiskMounts is the default mount-policy allowlist for the
// host_disk_usage_ratio metric per schema doc 17 §F4.3.1. The first three
// match the doc default; /var/lib/nftban is added because nftban writes
// state there per the FHS spec.
var defaultHostDiskMounts = []string{"/", "/var", "/var/log", "/var/lib/nftban"}

// hostDiskMountAllowlist returns the mount-points to read for
// nftban_host_disk_usage_ratio. Operator may override via
// NFTBAN_HOST_DISK_MOUNT_ALLOWLIST (comma-separated). Empty env value
// falls back to defaultHostDiskMounts.
func hostDiskMountAllowlist() []string {
	env := strings.TrimSpace(os.Getenv("NFTBAN_HOST_DISK_MOUNT_ALLOWLIST"))
	if env == "" {
		return defaultHostDiskMounts
	}
	parts := strings.Split(env, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if t := strings.TrimSpace(p); t != "" {
			out = append(out, t)
		}
	}
	if len(out) == 0 {
		return defaultHostDiskMounts
	}
	return out
}

// collectMultiMountDisks populates snapshot.System.Disks via per-mount
// syscall.Statfs() across the allowlist. Mounts that fail to stat are
// skipped silently (e.g. unmounted, permission denied). Device + fstype
// are resolved from /proc/self/mountinfo; on parse failure they default
// to "unknown" so the ratio still emits keyed on the mount path.
func (c *SystemCollector) collectMultiMountDisks(snapshot *Snapshot) {
	mounts := hostDiskMountAllowlist()
	mountInfo := readMountInfo() // best-effort; may be empty map on parse error

	out := make([]DiskUsageEntry, 0, len(mounts))
	for _, mp := range mounts {
		var stat syscall.Statfs_t
		if err := syscall.Statfs(mp, &stat); err != nil {
			continue
		}
		blockSize := safeconv.Int64ToUint64OrZero(stat.Bsize)
		totalBytes := stat.Blocks * blockSize
		if totalBytes == 0 {
			continue
		}
		freeBytes := stat.Bfree * blockSize
		usedBytes := totalBytes - freeBytes
		ratio := float64(usedBytes) / float64(totalBytes)

		device, fstype := "unknown", "unknown"
		if info, ok := mountInfo[mp]; ok {
			device = info.device
			fstype = info.fstype
		}
		out = append(out, DiskUsageEntry{
			Mount:  mp,
			Device: device,
			FSType: fstype,
			Ratio:  ratio,
		})
	}
	snapshot.System.Disks = out
}

// collectOOMEvents reads /proc/vmstat oom_kill (cumulative kernel counter
// since kernel 4.7). On older kernels missing the field, the counter stays
// at zero silently — Prometheus Counter handles delta tracking on the
// emission side.
func (c *SystemCollector) collectOOMEvents(snapshot *Snapshot) {
	f, err := os.Open("/proc/vmstat")
	if err != nil {
		return
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := scanner.Text()
		if !strings.HasPrefix(line, "oom_kill ") {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 2 {
			snapshot.System.OOMEvents, _ = strconv.ParseUint(fields[1], 10, 64)
		}
		return
	}
}

// mountInfoEntry holds device + filesystem-type resolved from
// /proc/self/mountinfo for a given mount path.
type mountInfoEntry struct {
	device string
	fstype string
}

// readMountInfo parses /proc/self/mountinfo into a mount-point→entry map.
// Returns an empty (non-nil) map on read or parse failure so callers can
// always range over it. Format reference: proc(5) mountinfo —
// fields[4]=mount-point, fields[N+1]=fstype where N is index of "-"
// separator, fields[N+2]=mount-source.
func readMountInfo() map[string]mountInfoEntry {
	out := make(map[string]mountInfoEntry)
	f, err := os.Open("/proc/self/mountinfo")
	if err != nil {
		return out
	}
	defer f.Close()

	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		fields := strings.Fields(scanner.Text())
		if len(fields) < 5 {
			continue
		}
		mountPoint := fields[4]
		// Find the "-" separator between optional fields and fstype/source.
		sepIdx := -1
		for i := 5; i < len(fields); i++ {
			if fields[i] == "-" {
				sepIdx = i
				break
			}
		}
		if sepIdx < 0 || sepIdx+2 >= len(fields) {
			continue
		}
		out[mountPoint] = mountInfoEntry{
			device: fields[sepIdx+2],
			fstype: fields[sepIdx+1],
		}
	}
	return out
}
