// =============================================================================
// NFTBan - Memory Availability Detection
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="mem"
// meta:type="package"
// meta:version="1.0.0"
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

	"github.com/itcmsgr/nftban/pkg/util"
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

// =============================================================================
// Resource Profile Detection (Server Specs + Control Panel)
// =============================================================================

// ServerProfile describes the server's resource characteristics
type ServerProfile struct {
	CPUCores        int    // Number of CPU cores
	TotalRAM        int64  // Total RAM in bytes
	AvailRAM        int64  // Available RAM in bytes
	HasControlPanel bool   // Whether a control panel is detected
	PanelType       string // "cpanel", "directadmin", "plesk", "cyberpanel", "none"
}

// DetectServerProfile analyzes the server and returns its resource profile
func DetectServerProfile() ServerProfile {
	profile := ServerProfile{
		CPUCores:  detectCPUCores(),
		PanelType: "none",
	}

	mem := AvailableMem()
	profile.TotalRAM = mem.Total
	profile.AvailRAM = mem.Avail

	// Detect control panels by checking for their processes/services
	profile.PanelType, profile.HasControlPanel = detectControlPanel()

	return profile
}

// detectCPUCores returns the number of CPU cores
func detectCPUCores() int {
	// Read from /proc/cpuinfo
	data, err := os.ReadFile("/proc/cpuinfo")
	if err != nil {
		return 1 // Default to 1
	}

	cores := 0
	for _, line := range strings.Split(string(data), "\n") {
		if strings.HasPrefix(line, "processor") {
			cores++
		}
	}

	if cores == 0 {
		return 1
	}
	return cores
}

// detectControlPanel checks for common control panel installations
func detectControlPanel() (panelType string, hasPanel bool) {
	// Check for cPanel (WHM/cPanel)
	if util.FileExists("/usr/local/cpanel/cpanel") || util.FileExists("/var/cpanel") {
		return "cpanel", true
	}

	// Check for DirectAdmin
	if util.FileExists("/usr/local/directadmin/directadmin") || util.FileExists("/usr/local/directadmin") {
		return "directadmin", true
	}

	// Check for Plesk
	if util.FileExists("/usr/local/psa/admin") || util.FileExists("/opt/psa") {
		return "plesk", true
	}

	// Check for CyberPanel
	if util.FileExists("/usr/local/CyberCP") || util.FileExists("/usr/local/lsws/cyberpanel") {
		return "cyberpanel", true
	}

	// Check for CloudPanel
	if util.FileExists("/home/clp") || util.FileExists("/usr/share/cloudpanel") {
		return "cloudpanel", true
	}

	// Check for VestaCP / HestiaCP
	if util.FileExists("/usr/local/vesta") {
		return "vestacp", true
	}
	if util.FileExists("/usr/local/hestia") {
		return "hestiacp", true
	}

	return "none", false
}


// GetResourceLimits calculates appropriate resource limits based on server profile
// Returns memory budget and max concurrent workers
func GetResourceLimits() (memBudget int64, maxWorkers int) {
	profile := DetectServerProfile()

	// Base memory budget calculation
	// Servers with control panels need more headroom for the panel itself
	var budgetPercent int64

	if profile.HasControlPanel {
		// Control panel servers: use 20% of available (more conservative)
		// Panel consumes significant RAM (cPanel ~500MB, DA ~200MB)
		budgetPercent = 20
	} else {
		// Non-panel servers: use 35% of available (more aggressive)
		budgetPercent = 35
	}

	memBudget = (profile.AvailRAM * budgetPercent) / 100

	// Apply caps based on total RAM (increased 15% from original for CIDR loading headroom)
	// Small servers (<=4GB): max 440MB (was 384MB)
	// Medium servers (4-8GB): max 590MB (was 512MB)
	// Large servers (>8GB): max 1.15GB (was 1GB)
	const GB = 1024 * 1024 * 1024
	var maxBudget int64

	switch {
	case profile.TotalRAM <= 4*GB:
		maxBudget = 440 * 1024 * 1024 // 440MB for small servers (+15%)
	case profile.TotalRAM <= 8*GB:
		maxBudget = 590 * 1024 * 1024 // 590MB for medium (+15%)
	default:
		maxBudget = 1178 * 1024 * 1024 // 1.15GB for large (+15%)
	}

	if memBudget > maxBudget {
		memBudget = maxBudget
	}

	// Minimum 64MB
	const minBudget = 64 * 1024 * 1024
	if memBudget < minBudget {
		memBudget = minBudget
	}

	// Worker count based on CPU cores
	// Panel servers: 1 worker per core (conservative)
	// Non-panel: 2 workers per core (can use more CPU)
	if profile.HasControlPanel {
		maxWorkers = profile.CPUCores
		if maxWorkers < 1 {
			maxWorkers = 1
		}
	} else {
		maxWorkers = profile.CPUCores * 2
		if maxWorkers < 2 {
			maxWorkers = 2
		}
	}

	// Cap workers at 8 for daemon stability
	if maxWorkers > 8 {
		maxWorkers = 8
	}

	return memBudget, maxWorkers
}

// GetProfileDescription returns a human-readable description of the server profile
func GetProfileDescription() string {
	profile := DetectServerProfile()
	memBudget, workers := GetResourceLimits()

	panel := "none"
	if profile.HasControlPanel {
		panel = profile.PanelType
	}

	return "cpu=" + strconv.Itoa(profile.CPUCores) +
		" ram=" + FormatBytes(profile.TotalRAM) +
		" avail=" + FormatBytes(profile.AvailRAM) +
		" panel=" + panel +
		" budget=" + FormatBytes(memBudget) +
		" workers=" + strconv.Itoa(workers)
}
