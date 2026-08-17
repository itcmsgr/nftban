// =============================================================================
// NFTBan v1.0 - Stats Configuration
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="stats_config"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-01-01"
// meta:description="Configuration for watchdog stats collection"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Configuration for watchdog stats collection.
// Safe defaults ensure backwards compatibility when config keys are missing.
// =============================================================================

package stats

import (
	"time"

	"github.com/itcmsgr/nftban/internal/constants"
)

// Retention constants - hard limits per design agreement
const (
	MinRetentionWeeks     = 1
	DefaultRetentionWeeks = 2
	MaxRetentionWeeks     = 4 // Hard maximum, not overridable
)

// Config holds stats collection configuration
// All fields have safe defaults for backwards compatibility
type Config struct {
	// Enable stats collection (default: true)
	Enabled bool

	// Collection intervals
	LiveInterval time.Duration // Memory/goroutines (default: 60s)
	IOInterval   time.Duration // Events/throughput (default: 300s)

	// File paths
	CurrentFile string // current.json path
	HistoryDir  string // history/ directory
	ProfileDir  string // profiles/ directory

	// Retention limits
	// Local retention is capped at 4 weeks maximum (28 days)
	// Long-term storage is user's responsibility via external TSDB
	HistoryRetentionDays  int // Days to keep history (default: 14, max: 28)
	ProfileRetentionDays  int // Days to keep profiles (default: 7)
	ProfileMaxCount       int // Max profiles to keep (default: 10)

	// Thresholds
	MemoryWarnMB      float64 // Warning threshold (default: 200)
	MemoryCritMB      float64 // Critical threshold (default: 500)
	GoroutinesWarn    int     // Warning threshold (default: 100)
	GoroutinesCrit    int     // Critical threshold (default: 500)
	StaleThresholdSec int     // Stale data threshold (default: 300)

	// Profiling
	ProfileEnabled    bool // pprof enabled (default: false)
	ProfileAutoCapture bool // Auto-capture on breach (default: false)

	// Logging
	LogDir      string // Watchdog log directory
	StatsLog    string // Stats log file
	AlertsLog   string // Alerts log file
	ProfileLog  string // Profile log file

	// Reports
	ReportsEnabled     bool   // Enable report generation (default: true)
	ReportsDir         string // Reports output directory
	// ReportsRetentionDays is currently UNCONSUMED (v1.229.3). Its only reader was
	// CleanupReports, removed as stale after the v1.228.5 report move; the daily
	// stream is now governed by logrotate. The field and its
	// NFTBAN_REPORTS_RETENTION_DAYS schema entry are RETAINED rather than deleted
	// because that key is an operator-facing configuration surface -- silently
	// dropping it would break a published contract. Note the key was never wired to
	// this field in the first place (no Go reader), so the knob was already inert.
	// Deprecation is registered separately.
	ReportsRetentionDays int  // Days to keep daily reports (default: 14, max: 28) -- currently unconsumed
}

// DefaultConfig returns configuration with safe defaults
// Used when config keys are missing for backwards compatibility
func DefaultConfig() *Config {
	return &Config{
		Enabled:      true,
		LiveInterval: constants.StatsLiveInterval,
		IOInterval:   constants.StatsIOInterval,

		CurrentFile: "/var/lib/nftban/stats/current.json",
		HistoryDir:  "/var/lib/nftban/stats/history",
		ProfileDir:  "/var/lib/nftban/stats/profiles",

		// Default: 2 weeks (14 days), Max: 4 weeks (28 days)
		HistoryRetentionDays: DefaultRetentionWeeks * 7,
		ProfileRetentionDays: 7,
		ProfileMaxCount:      10,

		MemoryWarnMB:      200,
		MemoryCritMB:      500,
		GoroutinesWarn:    100,
		GoroutinesCrit:    500,
		StaleThresholdSec: 300,

		ProfileEnabled:     false,
		ProfileAutoCapture: false,

		LogDir:     "/var/log/nftban/watchdog",
		StatsLog:   "/var/log/nftban/watchdog/stats.log",
		AlertsLog:  "/var/log/nftban/watchdog/alerts.log",
		ProfileLog: "/var/log/nftban/watchdog/profiles.log",

		ReportsEnabled:       true,
		ReportsDir:           "/var/lib/nftban/reports",
		ReportsRetentionDays: DefaultRetentionWeeks * 7,
	}
}

// Validate checks config values and applies safe bounds
func (c *Config) Validate() {
	// Ensure minimum intervals (prevent CPU thrashing)
	if c.LiveInterval < constants.StatsMinLiveInterval {
		c.LiveInterval = constants.StatsMinLiveInterval
	}
	if c.IOInterval < constants.StatsMinIOInterval {
		c.IOInterval = constants.StatsMinIOInterval
	}

	// Enforce retention bounds
	// Minimum: 1 week (7 days)
	minDays := MinRetentionWeeks * 7
	if c.HistoryRetentionDays < minDays {
		c.HistoryRetentionDays = minDays
	}

	// Maximum: 4 weeks (28 days) - HARD LIMIT, not overridable
	maxDays := MaxRetentionWeeks * 7
	if c.HistoryRetentionDays > maxDays {
		c.HistoryRetentionDays = maxDays
	}

	if c.ProfileRetentionDays < 1 {
		c.ProfileRetentionDays = 1
	}
	if c.ProfileMaxCount < 1 {
		c.ProfileMaxCount = 1
	}

	// Reports retention bounds (same as history - 4 weeks max)
	if c.ReportsRetentionDays < minDays {
		c.ReportsRetentionDays = minDays
	}
	if c.ReportsRetentionDays > maxDays {
		c.ReportsRetentionDays = maxDays
	}

	// Ensure positive thresholds
	if c.MemoryWarnMB < 1 {
		c.MemoryWarnMB = 200
	}
	if c.MemoryCritMB < c.MemoryWarnMB {
		c.MemoryCritMB = c.MemoryWarnMB * 2
	}
	if c.GoroutinesWarn < 1 {
		c.GoroutinesWarn = 100
	}
	if c.GoroutinesCrit < c.GoroutinesWarn {
		c.GoroutinesCrit = c.GoroutinesWarn * 5
	}
	if c.StaleThresholdSec < 60 {
		c.StaleThresholdSec = 60
	}
}

// IsStatsEnabled returns true if stats collection is enabled
// Used to check before starting any background work
func (c *Config) IsStatsEnabled() bool {
	return c.Enabled
}

// IsProfileEnabled returns true if profiling is enabled
func (c *Config) IsProfileEnabled() bool {
	return c.ProfileEnabled
}
