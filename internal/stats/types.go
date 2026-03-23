// =============================================================================
// NFTBan v1.0 - Stats Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="stats_types"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-01-01"
// meta:description="JSON structs for watchdog runtime stats"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// JSON structs for watchdog runtime stats.
// Schema version included for future compatibility.
// =============================================================================

package stats

import "time"

// SchemaVersion is the current JSON schema version
// Increment when making breaking changes to the JSON structure
const SchemaVersion = 2

// Snapshot represents a point-in-time stats snapshot
// Written to current.json by the daemon
type Snapshot struct {
	SchemaVersion int       `json:"schema_version"`
	Timestamp     time.Time `json:"timestamp"`
	Daemon        Daemon    `json:"daemon"`
	Runtime       Runtime   `json:"runtime"`
	Throughput    Throughput `json:"throughput"`
	IPC           IPC       `json:"ipc"`
	Watchdog      Watchdog  `json:"watchdog"`
	Server        Server    `json:"server"`
	Modules       map[string]ModuleStatus `json:"modules"`
	Health        string    `json:"health"`
	Alerts        []Alert   `json:"alerts"`
}

// Daemon contains daemon identification info
type Daemon struct {
	Version       string `json:"version"`
	UptimeSeconds int64  `json:"uptime_seconds"`
	PID           int    `json:"pid"`
	Mode          string `json:"mode"` // "normal", "degraded", "survival"
}

// Watchdog contains pressure monitoring metrics
type Watchdog struct {
	Status   int     `json:"status"`    // 1 = running, 0 = not running
	Mode     string  `json:"mode"`      // "normal", "degraded", "survival"
	CPUScore float64 `json:"cpu_score"` // 0-100 pressure score
	MemScore float64 `json:"mem_score"` // 0-100 pressure score
	IOScore  float64 `json:"io_score"`  // 0-100 pressure score
}

// Server contains server inventory information
type Server struct {
	Hostname string `json:"hostname"`
	Region   string `json:"region"` // Cloud region or datacenter
	OS       string `json:"os"`
	Kernel   string `json:"kernel"`
	Arch     string `json:"arch"`
}

// Runtime contains Go runtime metrics
type Runtime struct {
	MemoryHeapMB  float64 `json:"memory_heap_mb"`
	MemoryAllocMB float64 `json:"memory_alloc_mb"`
	MemorySysMB   float64 `json:"memory_sys_mb"`
	Goroutines    int     `json:"goroutines"`
	GCCycles      uint32  `json:"gc_cycles"`
	GCPauseMs     float64 `json:"gc_pause_ms"`
}

// Throughput contains event processing metrics
type Throughput struct {
	BansTotal     int64   `json:"bans_total"`
	UnbansTotal   int64   `json:"unbans_total"`
	EventsTotal   int64   `json:"events_total"`
	BansPerMin    float64 `json:"bans_per_min"`
	EventsPerMin  float64 `json:"events_per_min"`
}

// IPC contains IPC communication metrics
type IPC struct {
	RequestsTotal int64   `json:"requests_total"`
	AvgLatencyMs  float64 `json:"avg_latency_ms"`
	ErrorsTotal   int64   `json:"errors_total"`
}

// ModuleStatus contains status for a single module
type ModuleStatus struct {
	Status string `json:"status"`
	Events int64  `json:"events"`
}

// Alert represents an active alert
type Alert struct {
	Level     string    `json:"level"`     // "warning" or "critical"
	Type      string    `json:"type"`      // "memory", "goroutines", etc.
	Message   string    `json:"message"`
	Timestamp time.Time `json:"timestamp"`
	Value     float64   `json:"value"`
	Threshold float64   `json:"threshold"`
}

// DailyStats contains aggregated daily statistics
// Stored in history/ directory
type DailyStats struct {
	SchemaVersion int       `json:"schema_version"`
	Date          string    `json:"date"` // YYYY-MM-DD
	GeneratedAt   time.Time `json:"generated_at"`

	// Peak values for the day
	PeakMemoryMB    float64 `json:"peak_memory_mb"`
	PeakGoroutines  int     `json:"peak_goroutines"`
	PeakBansPerMin  float64 `json:"peak_bans_per_min"`

	// Totals for the day
	TotalBans       int64   `json:"total_bans"`
	TotalUnbans     int64   `json:"total_unbans"`
	TotalEvents     int64   `json:"total_events"`
	TotalIPCRequests int64  `json:"total_ipc_requests"`
	TotalIPCErrors  int64   `json:"total_ipc_errors"`

	// Averages for the day
	AvgMemoryMB     float64 `json:"avg_memory_mb"`
	AvgGoroutines   float64 `json:"avg_goroutines"`
	AvgLatencyMs    float64 `json:"avg_latency_ms"`

	// Alert counts
	WarningCount    int     `json:"warning_count"`
	CriticalCount   int     `json:"critical_count"`

	// Sample count (for averaging)
	SampleCount     int     `json:"sample_count"`
}

// ProfileInfo contains metadata about a saved profile
type ProfileInfo struct {
	Filename    string    `json:"filename"`
	Type        string    `json:"type"` // "heap", "cpu", "goroutine", "block"
	CreatedAt   time.Time `json:"created_at"`
	SizeBytes   int64     `json:"size_bytes"`
	DurationSec int       `json:"duration_sec,omitempty"` // For CPU profiles
}

// NewSnapshot creates a new snapshot with schema version set
func NewSnapshot() *Snapshot {
	return &Snapshot{
		SchemaVersion: SchemaVersion,
		Timestamp:     time.Now(),
		Modules:       make(map[string]ModuleStatus),
		Alerts:        make([]Alert, 0),
		Health:        "OK",
	}
}

// NewDailyStats creates a new daily stats struct
func NewDailyStats(date string) *DailyStats {
	return &DailyStats{
		SchemaVersion: SchemaVersion,
		Date:          date,
		GeneratedAt:   time.Now(),
	}
}
