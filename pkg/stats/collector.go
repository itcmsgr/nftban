// =============================================================================
// NFTBan v1.0 - Stats Collector
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="stats_collector"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-01-01"
// meta:description="Runtime stats collection for the nftband daemon"
// meta:inventory.files="/var/lib/nftban/stats/"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Runtime stats collection for the nftband daemon.
// Collects Go runtime metrics, throughput counters, and module status.
// Writes to current.json atomically and archives daily history.
// =============================================================================

package stats

import (
	"context"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"runtime"
	"sync"
	"sync/atomic"
	"time"
)

// Collector gathers and persists runtime statistics
type Collector struct {
	config    *Config
	startTime time.Time
	mu        sync.RWMutex

	// Counters (thread-safe)
	banCount     atomic.Int64
	unbanCount   atomic.Int64
	eventCount   atomic.Int64
	ipcRequests  atomic.Int64
	ipcErrors    atomic.Int64
	ipcLatencyNs atomic.Int64 // Cumulative latency in nanoseconds

	// Module status
	modules map[string]*ModuleStats

	// Daily rollup tracking
	lastDate string

	// Alert state (for hysteresis)
	memoryAlertLevel    string // "", "warning", "critical"
	goroutineAlertLevel string

	// Active alerts
	activeAlerts []Alert

	// Watchdog state (set externally)
	watchdog Watchdog

	// Server info (set externally)
	server Server

	// Daemon mode
	daemonMode string
}

// ModuleStats tracks per-module statistics
type ModuleStats struct {
	Status     string
	EventCount atomic.Int64
}

// NewCollector creates a new stats collector
func NewCollector(config *Config) *Collector {
	if config == nil {
		config = DefaultConfig()
	}
	config.Validate()

	return &Collector{
		config:    config,
		startTime: time.Now(),
		modules:   make(map[string]*ModuleStats),
	}
}

// Start begins the stats collection goroutines
// Returns immediately if stats collection is disabled (no background work)
func (c *Collector) Start(ctx context.Context) {
	if !c.config.IsStatsEnabled() {
		log.Println("stats: collection disabled, not starting background workers")
		return
	}

	log.Printf("stats: starting collector (live=%v, io=%v)", c.config.LiveInterval, c.config.IOInterval)

	// Initialize lastDate for daily rollup detection
	c.lastDate = time.Now().Format("2006-01-02")

	// Live metrics ticker (memory, goroutines)
	go c.runLiveTicker(ctx)

	// I/O metrics ticker (throughput, cleanup)
	go c.runIOTicker(ctx)
}

// runLiveTicker collects live metrics at LiveInterval
func (c *Collector) runLiveTicker(ctx context.Context) {
	ticker := time.NewTicker(c.config.LiveInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Println("stats: live ticker stopped")
			return
		case <-ticker.C:
			c.collectAndWrite()
		}
	}
}

// runIOTicker handles I/O metrics and cleanup at IOInterval
func (c *Collector) runIOTicker(ctx context.Context) {
	ticker := time.NewTicker(c.config.IOInterval)
	defer ticker.Stop()

	for {
		select {
		case <-ctx.Done():
			log.Println("stats: IO ticker stopped")
			return
		case <-ticker.C:
			// Check for daily rollup
			c.checkDailyRollup()

			// Run cleanup
			c.runCleanup()
		}
	}
}

// collectAndWrite gathers current stats and writes to current.json
func (c *Collector) collectAndWrite() {
	snapshot := c.Collect()

	if err := WriteJSONAtomic(c.config.CurrentFile, snapshot); err != nil {
		log.Printf("stats: failed to write current.json: %v", err)
	}
}

// Collect gathers current runtime statistics
func (c *Collector) Collect() *Snapshot {
	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)

	snapshot := NewSnapshot()

	// Daemon info
	c.mu.RLock()
	mode := c.daemonMode
	if mode == "" {
		mode = "normal"
	}
	c.mu.RUnlock()

	snapshot.Daemon = Daemon{
		Version:       "1.0.0", // Will be set by daemon
		UptimeSeconds: int64(time.Since(c.startTime).Seconds()),
		PID:           os.Getpid(),
		Mode:          mode,
	}

	// Runtime metrics
	snapshot.Runtime = Runtime{
		MemoryHeapMB:  float64(memStats.HeapAlloc) / 1024 / 1024,
		MemoryAllocMB: float64(memStats.Alloc) / 1024 / 1024,
		MemorySysMB:   float64(memStats.Sys) / 1024 / 1024,
		Goroutines:    runtime.NumGoroutine(),
		GCCycles:      memStats.NumGC,
		GCPauseMs:     float64(memStats.PauseNs[(memStats.NumGC+255)%256]) / 1e6,
	}

	// Throughput
	uptimeMin := time.Since(c.startTime).Minutes()
	if uptimeMin < 1 {
		uptimeMin = 1
	}

	bans := c.banCount.Load()
	events := c.eventCount.Load()

	snapshot.Throughput = Throughput{
		BansTotal:    bans,
		UnbansTotal:  c.unbanCount.Load(),
		EventsTotal:  events,
		BansPerMin:   float64(bans) / uptimeMin,
		EventsPerMin: float64(events) / uptimeMin,
	}

	// IPC stats
	requests := c.ipcRequests.Load()
	latencyNs := c.ipcLatencyNs.Load()
	avgLatencyMs := float64(0)
	if requests > 0 {
		avgLatencyMs = float64(latencyNs) / float64(requests) / 1e6
	}

	snapshot.IPC = IPC{
		RequestsTotal: requests,
		AvgLatencyMs:  avgLatencyMs,
		ErrorsTotal:   c.ipcErrors.Load(),
	}

	// Watchdog state
	c.mu.RLock()
	snapshot.Watchdog = c.watchdog
	snapshot.Server = c.server
	c.mu.RUnlock()

	// Module status
	c.mu.RLock()
	for name, stats := range c.modules {
		snapshot.Modules[name] = ModuleStatus{
			Status: stats.Status,
			Events: stats.EventCount.Load(),
		}
	}
	c.mu.RUnlock()

	// Check thresholds and update alerts
	c.checkThresholds(snapshot)

	// Copy active alerts
	c.mu.RLock()
	snapshot.Alerts = make([]Alert, len(c.activeAlerts))
	copy(snapshot.Alerts, c.activeAlerts)
	c.mu.RUnlock()

	// Set health status
	snapshot.Health = c.determineHealth()

	return snapshot
}

// checkThresholds evaluates thresholds and updates alerts
// Uses simple hysteresis: only change alert level if threshold crossed
func (c *Collector) checkThresholds(snapshot *Snapshot) {
	c.mu.Lock()
	defer c.mu.Unlock()

	now := time.Now()
	newAlerts := make([]Alert, 0)

	// Memory threshold check
	heapMB := snapshot.Runtime.MemoryHeapMB
	if heapMB >= c.config.MemoryCritMB {
		if c.memoryAlertLevel != "critical" {
			c.memoryAlertLevel = "critical"
			alert := Alert{
				Level:     "critical",
				Type:      "memory",
				Message:   fmt.Sprintf("Heap memory %.1f MB exceeds critical threshold %.0f MB", heapMB, c.config.MemoryCritMB),
				Timestamp: now,
				Value:     heapMB,
				Threshold: c.config.MemoryCritMB,
			}
			newAlerts = append(newAlerts, alert)
			c.logAlert(alert)
		}
	} else if heapMB >= c.config.MemoryWarnMB {
		if c.memoryAlertLevel != "warning" && c.memoryAlertLevel != "critical" {
			c.memoryAlertLevel = "warning"
			alert := Alert{
				Level:     "warning",
				Type:      "memory",
				Message:   fmt.Sprintf("Heap memory %.1f MB exceeds warning threshold %.0f MB", heapMB, c.config.MemoryWarnMB),
				Timestamp: now,
				Value:     heapMB,
				Threshold: c.config.MemoryWarnMB,
			}
			newAlerts = append(newAlerts, alert)
			c.logAlert(alert)
		}
	} else {
		c.memoryAlertLevel = ""
	}

	// Goroutine threshold check
	goroutines := snapshot.Runtime.Goroutines
	if goroutines >= c.config.GoroutinesCrit {
		if c.goroutineAlertLevel != "critical" {
			c.goroutineAlertLevel = "critical"
			alert := Alert{
				Level:     "critical",
				Type:      "goroutines",
				Message:   fmt.Sprintf("Goroutine count %d exceeds critical threshold %d", goroutines, c.config.GoroutinesCrit),
				Timestamp: now,
				Value:     float64(goroutines),
				Threshold: float64(c.config.GoroutinesCrit),
			}
			newAlerts = append(newAlerts, alert)
			c.logAlert(alert)
		}
	} else if goroutines >= c.config.GoroutinesWarn {
		if c.goroutineAlertLevel != "warning" && c.goroutineAlertLevel != "critical" {
			c.goroutineAlertLevel = "warning"
			alert := Alert{
				Level:     "warning",
				Type:      "goroutines",
				Message:   fmt.Sprintf("Goroutine count %d exceeds warning threshold %d", goroutines, c.config.GoroutinesWarn),
				Timestamp: now,
				Value:     float64(goroutines),
				Threshold: float64(c.config.GoroutinesWarn),
			}
			newAlerts = append(newAlerts, alert)
			c.logAlert(alert)
		}
	} else {
		c.goroutineAlertLevel = ""
	}

	// Update active alerts (keep recent ones)
	c.activeAlerts = newAlerts
}

// logAlert writes an alert to the alerts log
func (c *Collector) logAlert(alert Alert) {
	// Ensure log directory exists
	logDir := filepath.Dir(c.config.AlertsLog)
	if err := os.MkdirAll(logDir, 0750); err != nil {
		log.Printf("stats: failed to create log directory %s: %v", logDir, err)
		return
	}

	f, err := os.OpenFile(c.config.AlertsLog, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0640)
	if err != nil {
		log.Printf("stats: failed to open alerts log: %v", err)
		return
	}
	defer f.Close()

	line := fmt.Sprintf("%s [%s] %s: %s (value=%.2f threshold=%.2f)\n",
		alert.Timestamp.Format(time.RFC3339),
		alert.Level,
		alert.Type,
		alert.Message,
		alert.Value,
		alert.Threshold,
	)
	f.WriteString(line)
}

// determineHealth returns overall health status
func (c *Collector) determineHealth() string {
	if c.memoryAlertLevel == "critical" || c.goroutineAlertLevel == "critical" {
		return "CRITICAL"
	}
	if c.memoryAlertLevel == "warning" || c.goroutineAlertLevel == "warning" {
		return "WARNING"
	}
	return "OK"
}

// checkDailyRollup checks if date changed and archives yesterday's data
func (c *Collector) checkDailyRollup() {
	today := time.Now().Format("2006-01-02")

	c.mu.Lock()
	lastDate := c.lastDate
	c.mu.Unlock()

	if today != lastDate {
		// Date changed - archive yesterday
		c.archiveDaily(lastDate)

		c.mu.Lock()
		c.lastDate = today
		c.mu.Unlock()
	}
}

// archiveDaily creates a daily summary file
func (c *Collector) archiveDaily(date string) {
	dailyStats := NewDailyStats(date)

	// Read current snapshot to get peak values
	snapshot := c.Collect()

	dailyStats.PeakMemoryMB = snapshot.Runtime.MemoryHeapMB
	dailyStats.PeakGoroutines = snapshot.Runtime.Goroutines
	dailyStats.PeakBansPerMin = snapshot.Throughput.BansPerMin
	dailyStats.TotalBans = snapshot.Throughput.BansTotal
	dailyStats.TotalUnbans = snapshot.Throughput.UnbansTotal
	dailyStats.TotalEvents = snapshot.Throughput.EventsTotal
	dailyStats.TotalIPCRequests = snapshot.IPC.RequestsTotal
	dailyStats.TotalIPCErrors = snapshot.IPC.ErrorsTotal
	dailyStats.AvgMemoryMB = snapshot.Runtime.MemoryHeapMB
	dailyStats.AvgGoroutines = float64(snapshot.Runtime.Goroutines)
	dailyStats.AvgLatencyMs = snapshot.IPC.AvgLatencyMs
	dailyStats.SampleCount = 1

	// Count alerts
	for _, alert := range snapshot.Alerts {
		if alert.Level == "warning" {
			dailyStats.WarningCount++
		} else if alert.Level == "critical" {
			dailyStats.CriticalCount++
		}
	}

	// Write to history directory
	historyFile := filepath.Join(c.config.HistoryDir, date+".json")
	if err := WriteJSONAtomic(historyFile, dailyStats); err != nil {
		log.Printf("stats: failed to write daily history %s: %v", historyFile, err)
	} else {
		log.Printf("stats: archived daily stats for %s", date)
	}
}

// runCleanup enforces retention limits
func (c *Collector) runCleanup() {
	// Cleanup history files
	// Note: c.config.HistoryRetentionDays is already capped at 28 days (4 weeks) by Validate()
	if err := CleanupHistory(c.config.HistoryDir, c.config.HistoryRetentionDays, MaxRetentionWeeks*7); err != nil {
		log.Printf("stats: history cleanup error: %v", err)
	}

	// Cleanup profile files
	if err := CleanupProfiles(c.config.ProfileDir, c.config.ProfileRetentionDays, c.config.ProfileMaxCount); err != nil {
		log.Printf("stats: profile cleanup error: %v", err)
	}
}

// =============================================================================
// Counter methods (called by daemon to update stats)
// =============================================================================

// RecordBan increments the ban counter
func (c *Collector) RecordBan() {
	c.banCount.Add(1)
	c.eventCount.Add(1)
}

// RecordUnban increments the unban counter
func (c *Collector) RecordUnban() {
	c.unbanCount.Add(1)
	c.eventCount.Add(1)
}

// RecordEvent increments the event counter
func (c *Collector) RecordEvent() {
	c.eventCount.Add(1)
}

// RecordIPCRequest records an IPC request with latency
func (c *Collector) RecordIPCRequest(latencyNs int64, success bool) {
	c.ipcRequests.Add(1)
	c.ipcLatencyNs.Add(latencyNs)
	if !success {
		c.ipcErrors.Add(1)
	}
}

// SetModuleStatus updates module status
func (c *Collector) SetModuleStatus(name, status string) {
	c.mu.Lock()
	defer c.mu.Unlock()

	if _, exists := c.modules[name]; !exists {
		c.modules[name] = &ModuleStats{}
	}
	c.modules[name].Status = status
}

// RecordModuleEvent increments a module's event counter
func (c *Collector) RecordModuleEvent(name string) {
	c.mu.RLock()
	stats, exists := c.modules[name]
	c.mu.RUnlock()

	if exists {
		stats.EventCount.Add(1)
	}
	c.eventCount.Add(1)
}

// SetVersion sets the daemon version in stats
func (c *Collector) SetVersion(version string) {
	// Version is set when collecting - store for later
	// This is handled in the daemon itself
}

// GetConfig returns the collector configuration
func (c *Collector) GetConfig() *Config {
	return c.config
}

// SetWatchdogState sets the current watchdog pressure state
func (c *Collector) SetWatchdogState(status int, mode string, cpuScore, memScore, ioScore float64) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.watchdog = Watchdog{
		Status:   status,
		Mode:     mode,
		CPUScore: cpuScore,
		MemScore: memScore,
		IOScore:  ioScore,
	}
}

// SetServerInfo sets server inventory information
func (c *Collector) SetServerInfo(hostname, region, os, kernel, arch string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.server = Server{
		Hostname: hostname,
		Region:   region,
		OS:       os,
		Kernel:   kernel,
		Arch:     arch,
	}
}

// SetDaemonMode sets the current daemon operating mode
func (c *Collector) SetDaemonMode(mode string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.daemonMode = mode
}
