// =============================================================================
// NFTBan v1.0 - Watchdog Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="types"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Type definitions for watchdog pressure dimensions and metrics"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package watchdog

import (
	"sync/atomic"
	"time"
)

// =============================================================================
// Pressure Dimensions and Levels
// =============================================================================

// Dimension represents a monitored pressure dimension
type Dimension string

const (
	DimCPU Dimension = "cpu"
	DimMEM Dimension = "mem"
	DimIO  Dimension = "io"
	DimNET Dimension = "net"
)

// AllDimensions returns all pressure dimensions
func AllDimensions() []Dimension {
	return []Dimension{DimCPU, DimMEM, DimIO, DimNET}
}

// Level represents a pressure level
type Level string

const (
	LevelOK       Level = "ok"
	LevelWarn     Level = "warn"
	LevelCritical Level = "critical"
)

// Mode represents the operating mode derived from worst dimension
type Mode string

const (
	ModeNormal   Mode = "normal"   // All OK
	ModeDegraded Mode = "degraded" // Any WARN
	ModeSurvival Mode = "survival" // Any CRITICAL
)

// =============================================================================
// Pressure State
// =============================================================================

// PressureState holds the current pressure state for all dimensions
type PressureState struct {
	Timestamp time.Time

	// Per-dimension scores (0-100)
	Scores map[Dimension]float64

	// Per-dimension levels
	Levels map[Dimension]Level

	// Derived operating mode
	Mode Mode

	// Time in current mode
	ModeEnteredAt time.Time
	ModeDuration  time.Duration
}

// NewPressureState creates a new pressure state with all OK
func NewPressureState() *PressureState {
	ps := &PressureState{
		Timestamp:     time.Now(),
		Scores:        make(map[Dimension]float64),
		Levels:        make(map[Dimension]Level),
		Mode:          ModeNormal,
		ModeEnteredAt: time.Now(),
	}

	for _, dim := range AllDimensions() {
		ps.Scores[dim] = 0
		ps.Levels[dim] = LevelOK
	}

	return ps
}

// WorstLevel returns the worst level across all dimensions
func (ps *PressureState) WorstLevel() Level {
	worst := LevelOK
	for _, level := range ps.Levels {
		if level == LevelCritical {
			return LevelCritical
		}
		if level == LevelWarn {
			worst = LevelWarn
		}
	}
	return worst
}

// =============================================================================
// Metrics Snapshot
// =============================================================================

// Snapshot contains all collected metrics at a point in time
type Snapshot struct {
	Timestamp time.Time `json:"timestamp"`

	// Process metrics
	Process ProcessMetrics `json:"process"`

	// Go runtime metrics
	Runtime RuntimeMetrics `json:"runtime"`

	// System metrics
	System SystemMetrics `json:"system"`

	// Kernel/netfilter metrics
	Kernel KernelMetrics `json:"kernel"`

	// nftables metrics
	NFTables NFTablesMetrics `json:"nftables"`
}

// ProcessMetrics contains process-level metrics
type ProcessMetrics struct {
	PID       int     `json:"pid"`
	RSS       uint64  `json:"rss_bytes"`        // Resident Set Size
	VMS       uint64  `json:"vms_bytes"`        // Virtual Memory Size
	CPUPct    float64 `json:"cpu_percent"`      // CPU percentage (smoothed)
	FDs       int     `json:"open_fds"`         // Open file descriptors
	Threads   int     `json:"threads"`          // Thread count
	Uptime    float64 `json:"uptime_seconds"`   // Process uptime
}

// RuntimeMetrics contains Go runtime metrics
type RuntimeMetrics struct {
	Goroutines      int     `json:"goroutines"`
	HeapAlloc       uint64  `json:"heap_alloc_bytes"`
	HeapInuse       uint64  `json:"heap_inuse_bytes"`
	HeapReleased    uint64  `json:"heap_released_bytes"`
	HeapSys         uint64  `json:"heap_sys_bytes"`
	StackInuse      uint64  `json:"stack_inuse_bytes"`
	GCCPUFraction   float64 `json:"gc_cpu_fraction"`
	GCPauseNs       uint64  `json:"gc_pause_ns"`           // Last GC pause
	GCPauseTotalNs  uint64  `json:"gc_pause_total_ns"`     // Total GC pause time
	NumGC           uint32  `json:"num_gc"`                // Number of completed GC cycles
	GOMEMLIMIT      int64   `json:"gomemlimit_bytes"`      // GOMEMLIMIT value (-1 if not set)
}

// SystemMetrics contains OS-level metrics
type SystemMetrics struct {
	LoadAvg1   float64 `json:"load_avg_1"`
	LoadAvg5   float64 `json:"load_avg_5"`
	LoadAvg15  float64 `json:"load_avg_15"`
	NumCPU     int     `json:"num_cpu"`
	IOWaitPct  float64 `json:"iowait_percent"`
	MemTotal   uint64  `json:"mem_total_bytes"`
	MemFree    uint64  `json:"mem_free_bytes"`
	MemAvail   uint64  `json:"mem_available_bytes"`
	SwapTotal  uint64  `json:"swap_total_bytes"`
	SwapFree   uint64  `json:"swap_free_bytes"`
	DiskUsePct float64 `json:"disk_use_percent"`  // Log partition
	Entropy    int     `json:"entropy_available"` // /proc/sys/kernel/random/entropy_avail
}

// KernelMetrics contains kernel/netfilter metrics
type KernelMetrics struct {
	ConntrackCount       int     `json:"conntrack_count"`
	ConntrackMax         int     `json:"conntrack_max"`
	ConntrackUtilization float64 `json:"conntrack_utilization"` // count/max
	SoftnetDrops         uint64  `json:"softnet_drops_total"`   // Aggregated across CPUs
	SoftnetTimeSqueeze   uint64  `json:"softnet_time_squeeze_total"`
	NICDrops             uint64  `json:"nic_rx_dropped_total"`  // Aggregated across interfaces
}

// NFTablesMetrics contains nftables metrics
type NFTablesMetrics struct {
	RulesTotal       int            `json:"rules_total"`
	SetsTotal        int            `json:"sets_total"`
	SetElements      map[string]int `json:"set_elements"`       // set_name -> count
	CountersEnabled  bool           `json:"counters_enabled"`   // Whether rules have counters
	LastApplyLatency float64        `json:"last_apply_latency"` // Seconds
	SchemaValid      bool           `json:"schema_valid"`                  // v1.34.0
	SchemaErrors     []string       `json:"schema_errors,omitempty"`       // v1.34.0
}

// =============================================================================
// Action Types
// =============================================================================

// ActionType represents a watchdog action
type ActionType string

const (
	ActionThrottle        ActionType = "throttle"
	ActionDisableOptional ActionType = "disable_optional"
	ActionProfileCPU      ActionType = "profile_cpu"
	ActionProfileHeap     ActionType = "profile_heap"
	ActionProfileGoroutine ActionType = "profile_goroutine"
	ActionFreeOSMemory    ActionType = "free_os_memory"
	ActionDegradeMode     ActionType = "degrade_mode"
)

// Action represents an action taken by the watchdog
type Action struct {
	Type      ActionType `json:"type"`
	Timestamp time.Time  `json:"timestamp"`
	Reason    string     `json:"reason"`
	Details   string     `json:"details,omitempty"`
	Success   bool       `json:"success"`
}

// =============================================================================
// Runtime Controls (for throttling hooks)
// =============================================================================

// RuntimeControls allows the watchdog to dynamically adjust daemon behavior
// All values are atomic for thread-safe access without locks
type RuntimeControls struct {
	// Worker pool sizing
	MaxWorkers atomic.Int32

	// Feature toggles
	EnableExpensiveCollectors atomic.Bool
	EnableNFTRulesetScan      atomic.Bool
	EnableTopProcesses        atomic.Bool
	EnableVerboseLogging      atomic.Bool

	// Sampling factors (1.0 = normal, 0.5 = half, etc.)
	TelemetrySamplingFactor atomic.Uint32 // stored as percent (100 = 1.0)

	// Current mode (stored as int for atomic access)
	currentMode atomic.Int32 // 0=normal, 1=degraded, 2=survival
}

// NewRuntimeControls creates controls with defaults for NORMAL mode
func NewRuntimeControls() *RuntimeControls {
	rc := &RuntimeControls{}
	rc.Reset()
	return rc
}

// Reset sets all controls to NORMAL mode defaults
func (rc *RuntimeControls) Reset() {
	rc.MaxWorkers.Store(10)
	rc.EnableExpensiveCollectors.Store(true)
	rc.EnableNFTRulesetScan.Store(true)
	rc.EnableTopProcesses.Store(true)
	rc.EnableVerboseLogging.Store(true)
	rc.TelemetrySamplingFactor.Store(100) // 100%
	rc.currentMode.Store(0)               // NORMAL
}

// SetMode applies settings for the given operating mode
func (rc *RuntimeControls) SetMode(mode Mode) {
	switch mode {
	case ModeNormal:
		rc.MaxWorkers.Store(10)
		rc.EnableExpensiveCollectors.Store(true)
		rc.EnableNFTRulesetScan.Store(true)
		rc.EnableTopProcesses.Store(true)
		rc.EnableVerboseLogging.Store(true)
		rc.TelemetrySamplingFactor.Store(100)
		rc.currentMode.Store(0)

	case ModeDegraded:
		rc.MaxWorkers.Store(5) // Reduce workers
		rc.EnableExpensiveCollectors.Store(false)
		rc.EnableNFTRulesetScan.Store(false) // 60-120s instead
		rc.EnableTopProcesses.Store(false)   // 60s instead
		rc.EnableVerboseLogging.Store(false)
		rc.TelemetrySamplingFactor.Store(50) // 50%
		rc.currentMode.Store(1)

	case ModeSurvival:
		rc.MaxWorkers.Store(2) // Minimal workers
		rc.EnableExpensiveCollectors.Store(false)
		rc.EnableNFTRulesetScan.Store(false)
		rc.EnableTopProcesses.Store(false)
		rc.EnableVerboseLogging.Store(false)
		rc.TelemetrySamplingFactor.Store(25) // 25%
		rc.currentMode.Store(2)
	}
}

// GetMode returns the current mode
func (rc *RuntimeControls) GetMode() Mode {
	switch rc.currentMode.Load() {
	case 1:
		return ModeDegraded
	case 2:
		return ModeSurvival
	default:
		return ModeNormal
	}
}

// GetSamplingFactor returns the sampling factor as a float (0.0-1.0)
func (rc *RuntimeControls) GetSamplingFactor() float64 {
	return float64(rc.TelemetrySamplingFactor.Load()) / 100.0
}

// =============================================================================
// Event Types (for flight recorder)
// =============================================================================

// EventType categorizes recorder events
type EventType string

const (
	EventModeChange     EventType = "mode_change"
	EventPressureChange EventType = "pressure_change"
	EventActionTaken    EventType = "action_taken"
	EventThresholdBreach EventType = "threshold_breach"
	EventProfileCapture EventType = "profile_capture"
)

// Event represents a recorded event for post-mortem analysis
type Event struct {
	Type      EventType   `json:"type"`
	Timestamp time.Time   `json:"timestamp"`
	Message   string      `json:"message"`
	Snapshot  *Snapshot   `json:"snapshot,omitempty"`
	Action    *Action     `json:"action,omitempty"`
	OldMode   Mode        `json:"old_mode,omitempty"`
	NewMode   Mode        `json:"new_mode,omitempty"`
	Dimension Dimension   `json:"dimension,omitempty"`
	Score     float64     `json:"score,omitempty"`
	Level     Level       `json:"level,omitempty"`
}

// =============================================================================
// Cooldown Tracker
// =============================================================================

// Cooldowns tracks action cooldowns to prevent repeated actions
type Cooldowns struct {
	lastActions map[ActionType]time.Time
}

// NewCooldowns creates a new cooldown tracker
func NewCooldowns() *Cooldowns {
	return &Cooldowns{
		lastActions: make(map[ActionType]time.Time),
	}
}

// CanExecute returns true if the action is not in cooldown
func (c *Cooldowns) CanExecute(action ActionType, cooldown time.Duration) bool {
	last, exists := c.lastActions[action]
	if !exists {
		return true
	}
	return time.Since(last) >= cooldown
}

// Record marks an action as executed
func (c *Cooldowns) Record(action ActionType) {
	c.lastActions[action] = time.Now()
}

// TimeSince returns time since last action (or max duration if never)
func (c *Cooldowns) TimeSince(action ActionType) time.Duration {
	last, exists := c.lastActions[action]
	if !exists {
		return time.Hour * 24 * 365 // Never executed
	}
	return time.Since(last)
}
