// =============================================================================
// NFTBan v1.0 - Watchdog Configuration
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="config"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Watchdog configuration with dynamic memory limits based on system resources"
// meta:input="System memory via /proc/meminfo"
// meta:output="Configuration struct"
// meta:depends="time,safety"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_MEM_BUDGET_BYTES"
// meta:inventory.config_files="/etc/nftban/conf.d/watchdog.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package watchdog

import (
	"time"

	"github.com/itcmsgr/nftban/pkg/constants"
	"github.com/itcmsgr/nftban/pkg/safety"
)

// Config holds watchdog configuration
type Config struct {
	// Enable/disable watchdog
	Enabled bool

	// Base collection interval (adjusts dynamically)
	BaseInterval time.Duration

	// ==========================================================================
	// Hysteresis Settings (prevents flapping)
	// ==========================================================================
	HysteresisWarnEnter  float64 // Enter WARN at this score
	HysteresisWarnExit   float64 // Exit WARN when below this for WarnExitDuration
	HysteresisCritEnter  float64 // Enter CRITICAL at this score
	HysteresisCritExit   float64 // Exit CRITICAL when below this for CritExitDuration
	WarnExitDuration     time.Duration
	CritExitDuration     time.Duration

	// ==========================================================================
	// Budget/Threshold Settings
	// ==========================================================================

	// Memory
	MemBudgetBytes          int64   // Align with GOMEMLIMIT
	RSSCritPercentOfBudget  float64 // RSS critical threshold as % of budget
	HeapCritPercentOfLimit  float64 // Heap critical threshold as % of GOMEMLIMIT

	// CPU
	CPUCritPercent          float64 // Process CPU critical threshold
	LoadNormalizedCrit      float64 // Load/NumCPU critical threshold

	// IO
	IOWaitCritPercent       float64 // iowait critical threshold
	DiskUseCritPercent      float64 // Disk usage critical threshold

	// Network/Conntrack
	ConntrackUtilCrit       float64 // Conntrack utilization critical threshold
	SoftnetDropsRateCrit    float64 // Softnet drops per second critical threshold

	// Goroutines
	GoroutinesCrit          int     // Goroutine count critical threshold

	// ==========================================================================
	// Collector Intervals (dynamic - change based on mode)
	// ==========================================================================
	ProcessInterval     time.Duration // Process/runtime metrics
	SystemInterval      time.Duration // System metrics
	KernelInterval      time.Duration // Kernel/netfilter metrics
	NFTSetInterval      time.Duration // nft set counts (cheap)
	NFTRulesetInterval  time.Duration // nft full ruleset (expensive)
	TopProcessesInterval time.Duration // Top hogs

	// Degraded mode multipliers
	DegradedIntervalMultiplier float64 // Multiply intervals by this in DEGRADED

	// ==========================================================================
	// Profiling Settings
	// ==========================================================================
	ProfileAutoEnabled    bool
	ProfileDir            string
	ProfileCPUCooldown    time.Duration
	ProfileHeapCooldown   time.Duration
	ProfileGoroutineCooldown time.Duration
	ProfileCPUDuration    time.Duration // Duration of CPU profile
	ProfileMaxCount       int           // Max profiles to keep

	// ==========================================================================
	// Memory Valve Settings
	// ==========================================================================
	FreeOSMemoryEnabled     bool
	FreeOSMemoryCooldown    time.Duration
	FreeOSMemoryOnlyIfCPUBelow float64 // Only trigger if CPU below this %

	// ==========================================================================
	// Degradation Settings
	// ==========================================================================
	DegradeDisableNFTRulesetScan bool
	DegradeReduceWorkersTo       int
	SurvivalReduceWorkersTo      int

	// ==========================================================================
	// Flight Recorder Settings
	// ==========================================================================
	RecorderEnabled         bool
	RecorderDir             string
	RecorderMaxEvents       int           // Ring buffer size
	RecorderSnapshotInterval time.Duration // How often to write snapshots
	RecorderRetentionDays   int           // Days to keep old files

	// ==========================================================================
	// Alerting
	// ==========================================================================
	AlertThrottleDuration   time.Duration // Don't repeat same alert within this
}

// DefaultConfig returns configuration with sensible defaults
// Memory budget is dynamically calculated based on available system memory
func DefaultConfig() *Config {
	// Dynamic memory budget: use safety package to get system-aware budget
	memBudget := safety.GetMemoryBudget()

	return &Config{
		Enabled:      true,
		BaseInterval: constants.WatchdogBaseInterval,

		// Hysteresis
		HysteresisWarnEnter:  60,
		HysteresisWarnExit:   50,
		HysteresisCritEnter:  80,
		HysteresisCritExit:   70,
		WarnExitDuration:     constants.WatchdogHysteresisWarnExit,
		CritExitDuration:     constants.WatchdogHysteresisCritExit,

		// Budgets/Thresholds (dynamic based on available memory)
		MemBudgetBytes:          memBudget, // Dynamic: 30% of available, capped at 1GB
		RSSCritPercentOfBudget:  95,
		HeapCritPercentOfLimit:  90,
		CPUCritPercent:          80,
		LoadNormalizedCrit:      4.0, // 4x CPU count
		IOWaitCritPercent:       40,
		DiskUseCritPercent:      95,
		ConntrackUtilCrit:       0.9,
		SoftnetDropsRateCrit:    100, // 100 drops/sec
		GoroutinesCrit:          10000,

		// Collector intervals
		ProcessInterval:      constants.WatchdogProcessInterval,
		SystemInterval:       constants.WatchdogSystemInterval,
		KernelInterval:       constants.WatchdogKernelInterval,
		NFTSetInterval:       constants.WatchdogNFTSetInterval,
		NFTRulesetInterval:   constants.WatchdogNFTRulesetInterval,
		TopProcessesInterval: constants.WatchdogTopProcessesInterval,

		DegradedIntervalMultiplier: 2.0, // Double intervals in DEGRADED

		// Profiling
		ProfileAutoEnabled:       true,
		ProfileDir:               "/var/lib/nftban/profiles",
		ProfileCPUCooldown:       constants.WatchdogProfileCPUCooldown,
		ProfileHeapCooldown:      constants.WatchdogProfileHeapCooldown,
		ProfileGoroutineCooldown: constants.WatchdogProfileGoroutineCooldown,
		ProfileCPUDuration:       constants.WatchdogProfileCPUDuration,
		ProfileMaxCount:          10,

		// Memory valve
		FreeOSMemoryEnabled:        true,
		FreeOSMemoryCooldown:       constants.WatchdogFreeOSMemoryCooldown,
		FreeOSMemoryOnlyIfCPUBelow: 40,

		// Degradation
		DegradeDisableNFTRulesetScan: true,
		DegradeReduceWorkersTo:       2,
		SurvivalReduceWorkersTo:      1,

		// Flight recorder
		RecorderEnabled:          true,
		RecorderDir:              "/var/lib/nftban/recorder",
		RecorderMaxEvents:        1000,
		RecorderSnapshotInterval: constants.WatchdogRecorderSnapshotInterval,
		RecorderRetentionDays:    7,

		// Alerting
		AlertThrottleDuration: constants.WatchdogAlertThrottle,
	}
}

// Validate ensures config values are within safe bounds
func (c *Config) Validate() {
	// Minimum intervals
	if c.BaseInterval < time.Second {
		c.BaseInterval = time.Second
	}
	if c.ProcessInterval < time.Second {
		c.ProcessInterval = time.Second
	}
	if c.SystemInterval < time.Second {
		c.SystemInterval = time.Second
	}
	if c.KernelInterval < time.Second {
		c.KernelInterval = time.Second
	}
	if c.NFTSetInterval < time.Second {
		c.NFTSetInterval = time.Second
	}
	if c.NFTRulesetInterval < constants.WatchdogMinNFTRulesetInterval {
		c.NFTRulesetInterval = constants.WatchdogMinNFTRulesetInterval
	}

	// Ensure hysteresis makes sense
	if c.HysteresisWarnExit >= c.HysteresisWarnEnter {
		c.HysteresisWarnExit = c.HysteresisWarnEnter - 10
	}
	if c.HysteresisCritExit >= c.HysteresisCritEnter {
		c.HysteresisCritExit = c.HysteresisCritEnter - 10
	}

	// Minimum cooldowns
	if c.ProfileCPUCooldown < time.Minute {
		c.ProfileCPUCooldown = time.Minute
	}
	if c.ProfileHeapCooldown < time.Minute {
		c.ProfileHeapCooldown = time.Minute
	}
	if c.FreeOSMemoryCooldown < constants.WatchdogMinFreeOSCooldown {
		c.FreeOSMemoryCooldown = constants.WatchdogMinFreeOSCooldown
	}

	// Reasonable bounds
	if c.DegradedIntervalMultiplier < 1.0 {
		c.DegradedIntervalMultiplier = 1.0
	}
	if c.DegradedIntervalMultiplier > 10.0 {
		c.DegradedIntervalMultiplier = 10.0
	}

	// Profile limits
	if c.ProfileMaxCount < 1 {
		c.ProfileMaxCount = 1
	}
	if c.ProfileMaxCount > 100 {
		c.ProfileMaxCount = 100
	}

	// Recorder limits
	if c.RecorderMaxEvents < 100 {
		c.RecorderMaxEvents = 100
	}
	if c.RecorderMaxEvents > 10000 {
		c.RecorderMaxEvents = 10000
	}
	if c.RecorderRetentionDays < 1 {
		c.RecorderRetentionDays = 1
	}
}

// GetIntervalForMode returns the adjusted interval for the given mode
func (c *Config) GetIntervalForMode(base time.Duration, mode Mode) time.Duration {
	switch mode {
	case ModeDegraded:
		return time.Duration(float64(base) * c.DegradedIntervalMultiplier)
	case ModeSurvival:
		// In survival, we still collect essential metrics at base rate
		return base
	default:
		return base
	}
}
