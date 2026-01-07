// =============================================================================
// NFTBan - Memory Availability Detection
// =============================================================================
// SPDX-License-Identifier: GPL-3.0-or-later
// meta:name="mem"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Cgroup-aware memory detection for containers and hosts"
// meta:input="/proc/meminfo, cgroup memory files"
// meta:output="Available memory information"
// meta:depends="os"
// meta:inventory.files="/proc/meminfo,/sys/fs/cgroup/memory.max"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package safety

import (
	"os"
	"strconv"
	"strings"
)

// MemAvail holds available memory info (cgroup-aware)
// This matches the pattern from go-feeds/internal/safety/mem.go
type MemAvail struct {
	Total         int64
	Avail         int64
	CgroupLimit   int64
	CgroupCurrent int64
}

func readFirstInt64(path string) (int64, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	s := strings.TrimSpace(string(b))
	if s == "max" {
		return 1 << 62, nil // cgroup v2 "no limit"
	}
	return strconv.ParseInt(s, 10, 64)
}

// AvailableMem returns available memory (cgroup-aware for containers)
// This is critical for running in Docker/Kubernetes where cgroup limits apply
func AvailableMem() MemAvail {
	// cgroup v2 paths
	mlim, _ := readFirstInt64("/sys/fs/cgroup/memory.max")
	mcur, _ := readFirstInt64("/sys/fs/cgroup/memory.current")

	// cgroup v1 paths (fallback)
	if mlim == 0 {
		mlim, _ = readFirstInt64("/sys/fs/cgroup/memory/memory.limit_in_bytes")
		mcur, _ = readFirstInt64("/sys/fs/cgroup/memory/memory.usage_in_bytes")
	}

	// /proc/meminfo fallback (host system)
	var memTotal, memAvail int64
	if b, err := os.ReadFile("/proc/meminfo"); err == nil {
		lines := strings.Split(string(b), "\n")
		for _, ln := range lines {
			if strings.HasPrefix(ln, "MemTotal:") {
				fields := strings.Fields(ln)
				// kB → bytes
				if len(fields) >= 2 {
					if v, err := strconv.ParseInt(fields[1], 10, 64); err == nil {
						memTotal = v * 1024
					}
				}
			}
			if strings.HasPrefix(ln, "MemAvailable:") {
				fields := strings.Fields(ln)
				if len(fields) >= 2 {
					if v, err := strconv.ParseInt(fields[1], 10, 64); err == nil {
						memAvail = v * 1024
					}
				}
			}
		}
	}

	// if running under cgroup with a smaller limit than host RAM, use that window
	if mlim > 0 && mlim < (1<<61) {
		// avail within cgroup = limit - current (bounded by MemAvailable)
		cgAvail := mlim - mcur
		if cgAvail < 0 {
			cgAvail = 0
		}
		if memAvail == 0 || cgAvail < memAvail {
			memAvail = cgAvail
		}
		memTotal = mlim
	}

	return MemAvail{
		Total:         memTotal,
		Avail:         memAvail,
		CgroupLimit:   mlim,
		CgroupCurrent: mcur,
	}
}

// FormatBytes converts bytes to human-readable format
func FormatBytes(bytes int64) string {
	const (
		KB = 1024
		MB = KB * 1024
		GB = MB * 1024
	)

	switch {
	case bytes >= GB:
		return strconv.FormatInt(bytes/GB, 10) + " GB"
	case bytes >= MB:
		return strconv.FormatInt(bytes/MB, 10) + " MB"
	case bytes >= KB:
		return strconv.FormatInt(bytes/KB, 10) + " KB"
	default:
		return strconv.FormatInt(bytes, 10) + " B"
	}
}
