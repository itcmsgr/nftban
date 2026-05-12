// =============================================================================
// NFTBan v1.0 - Watchdog Core
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="watchdog"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-01-01"
// meta:description="Watchdog coordinator for metrics collection, pressure calculation, and actions"
// meta:inventory.files="/proc/stat,/proc/meminfo,/proc/net/dev"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/nftban.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// The Watchdog ties together all components:
//   - Collectors gather metrics
//   - PressureCalculator computes scores
//   - StateMachine handles transitions
//   - ActionExecutor applies actions
//   - Recorder logs events
//
// =============================================================================

package watchdog

import (
	"context"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/logx"
	sharedstate "github.com/itcmsgr/nftban/internal/state"
)

// Watchdog is the main watchdog coordinator
type Watchdog struct {
	config   *Config
	controls *RuntimeControls

	// Collectors
	processCollector  *ProcessCollector
	runtimeCollector  *RuntimeCollector
	systemCollector   *SystemCollector
	kernelCollector   *KernelCollector
	nftablesCollector *NFTablesCollector

	// Core components
	calculator *PressureCalculator
	state      *StateMachine
	executor   *ActionExecutor
	recorder   *Recorder

	// State tracking
	mu              sync.RWMutex
	running         bool
	lastSnapshot    *Snapshot
	lastState       *PressureState
	levelDurations  map[Dimension]time.Time // When each dimension entered current level

	// Metrics callbacks
	onMetrics func(*Snapshot, *PressureState)
	onAction  func(Action)
}

// New creates a new watchdog
func New(cfg *Config, controls *RuntimeControls) (*Watchdog, error) {
	if cfg == nil {
		cfg = DefaultConfig()
	}
	cfg.Validate()

	if controls == nil {
		controls = NewRuntimeControls()
	}

	// Create collectors
	processCollector, err := NewProcessCollector()
	if err != nil {
		return nil, err
	}

	w := &Watchdog{
		config:   cfg,
		controls: controls,

		processCollector:  processCollector,
		runtimeCollector:  NewRuntimeCollector(),
		systemCollector:   NewSystemCollector("/var/log"),
		kernelCollector:   NewKernelCollector(),
		nftablesCollector: NewNFTablesCollector(cfg.NFTRulesetInterval),

		calculator: NewPressureCalculator(cfg),
		state:      NewStateMachine(cfg),
		executor:   NewActionExecutor(cfg, controls),
		recorder:   NewRecorder(cfg),

		levelDurations: make(map[Dimension]time.Time),
	}

	// Wire up callbacks
	w.state.SetOnModeChange(w.handleModeChange)
	w.executor.SetOnAction(w.handleAction)

	return w, nil
}

// Run starts the watchdog loop
func (w *Watchdog) Run(ctx context.Context) error {
	if !w.config.Enabled {
		logx.Watchdog("disabled, not starting")
		return nil
	}

	w.mu.Lock()
	w.running = true
	w.mu.Unlock()

	defer func() {
		w.mu.Lock()
		w.running = false
		w.mu.Unlock()
	}()

	logx.Watchdog("starting with interval=%s", w.config.BaseInterval)

	// Start with base interval, will be adjusted based on mode
	currentInterval := w.config.BaseInterval
	ticker := time.NewTicker(currentInterval)
	defer ticker.Stop()

	cleanupTicker := time.NewTicker(time.Hour)
	defer cleanupTicker.Stop()

	for {
		select {
		case <-ctx.Done():
			logx.Watchdog("stopping")
			if err := w.recorder.Flush(); err != nil {
				logx.Watchdog("flush error: %v", err)
			}
			return ctx.Err()

		case <-ticker.C:
			w.tick(ctx)

			// Adjust interval based on current mode (degraded mode uses multiplier)
			newInterval := w.config.GetIntervalForMode(w.config.BaseInterval, w.state.GetMode())
			if newInterval != currentInterval {
				logx.Watchdog("adjusting interval: %s -> %s (mode=%s)",
					currentInterval, newInterval, w.state.GetMode())
				currentInterval = newInterval
				ticker.Reset(currentInterval)
			}

		case <-cleanupTicker.C:
			w.recorder.Cleanup()
		}
	}
}

// tick performs one watchdog cycle
func (w *Watchdog) tick(ctx context.Context) {
	// Collect metrics
	snapshot, err := w.collect(ctx)
	if err != nil {
		logx.WatchdogError("collect error: %v", err)
		return
	}

	// Calculate pressure scores
	scores := w.calculator.Calculate(snapshot)

	// Update state machine
	state := w.state.Update(scores)

	// Store for access
	w.mu.Lock()
	w.lastSnapshot = snapshot
	w.lastState = state
	w.mu.Unlock()

	// Record snapshot
	w.recorder.RecordSnapshot(snapshot)

	// Update shared state for BASIC tier consumers (stats CLI, UI, sampler)
	// This is the single source of truth - NO CLI calls needed by consumers
	sharedstate.Update(sharedstate.BasicSnapshot{
		BannedIPv4:    int64(snapshot.NFTables.SetElements["blacklist_ipv4"]),
		BannedIPv6:    int64(snapshot.NFTables.SetElements["blacklist_ipv6"]),
		WhitelistIPv4: int64(snapshot.NFTables.SetElements["whitelist_ipv4"]),
		WhitelistIPv6: int64(snapshot.NFTables.SetElements["whitelist_ipv6"]),
		RulesTotal:    int64(snapshot.NFTables.RulesTotal),
		// FeedsActive and FeedsIPs will be set by feeds loader callback
	})

	// Evaluate and execute actions
	w.evaluateActions(snapshot, state)

	// Callback for external metrics
	if w.onMetrics != nil {
		w.onMetrics(snapshot, state)
	}
}

// collect runs all collectors
func (w *Watchdog) collect(ctx context.Context) (*Snapshot, error) {
	snapshot := &Snapshot{
		Timestamp: time.Now(),
		NFTables: NFTablesMetrics{
			SetElements: make(map[string]int),
		},
	}

	// Process collector
	if err := w.processCollector.Collect(ctx, snapshot); err != nil {
		logx.WatchdogError("process collector: %v", err)
	}

	// Runtime collector
	if err := w.runtimeCollector.Collect(ctx, snapshot); err != nil {
		logx.WatchdogError("runtime collector: %v", err)
	}

	// System collector
	if err := w.systemCollector.Collect(ctx, snapshot); err != nil {
		logx.WatchdogError("system collector: %v", err)
	}

	// Kernel collector
	if err := w.kernelCollector.Collect(ctx, snapshot); err != nil {
		logx.WatchdogError("kernel collector: %v", err)
	}

	// nftables collector (may be disabled in degraded mode)
	if w.controls.EnableExpensiveCollectors.Load() || w.controls.GetMode() == ModeNormal {
		if err := w.nftablesCollector.Collect(ctx, snapshot); err != nil {
			logx.WatchdogError("nftables collector: %v", err)
		}
	}

	return snapshot, nil
}

// evaluateActions checks conditions and triggers appropriate actions
func (w *Watchdog) evaluateActions(snapshot *Snapshot, state *PressureState) {
	mode := state.Mode

	// Track level durations for each dimension
	for dim, level := range state.Levels {
		w.mu.Lock()
		if _, exists := w.levelDurations[dim]; !exists || level == LevelOK {
			w.levelDurations[dim] = time.Now()
		}
		w.mu.Unlock()
	}

	// === CPU CRITICAL Actions ===
	if state.Levels[DimCPU] == LevelCritical {
		duration := time.Since(w.getLevelEntryTime(DimCPU))

		// Capture CPU profile after 10s of CRITICAL
		if duration >= 10*time.Second {
			w.executor.CaptureCPUProfile("CPU_CRITICAL_10s", snapshot)
		}
	}

	// === MEM CRITICAL Actions ===
	if state.Levels[DimMEM] == LevelCritical {
		duration := time.Since(w.getLevelEntryTime(DimMEM))

		// Capture heap profile after 30s
		if duration >= 30*time.Second {
			w.executor.CaptureHeapProfile("MEM_CRITICAL_30s", snapshot)
		}

		// Try FreeOSMemory after 30s if CPU is low
		if duration >= 30*time.Second {
			w.executor.TryFreeOSMemory(duration, snapshot.Process.CPUPct, snapshot)
		}
	}

	// === Goroutine spike ===
	if snapshot.Runtime.Goroutines > w.config.GoroutinesCrit {
		w.executor.CaptureGoroutineProfile("goroutine_spike", snapshot)
	}

	// === Mode-based throttling ===
	switch mode {
	case ModeDegraded:
		w.executor.DisableOptional("degraded_mode")

	case ModeSurvival:
		w.executor.Throttle("survival_mode")
		w.executor.DisableOptional("survival_mode")
	}
}

// handleModeChange is called when operating mode changes
func (w *Watchdog) handleModeChange(oldMode, newMode Mode) {
	logx.Watchdog("mode change %s -> %s", oldMode, newMode)

	w.mu.RLock()
	snapshot := w.lastSnapshot
	w.mu.RUnlock()

	// Record in flight recorder
	w.recorder.RecordModeChange(oldMode, newMode, snapshot)

	// Apply mode settings
	w.executor.ApplyMode(newMode, snapshot)
}

// handleAction is called when an action is executed
func (w *Watchdog) handleAction(action Action) {
	logx.Watchdog("action %s - %s", action.Type, action.Reason)

	w.mu.RLock()
	snapshot := w.lastSnapshot
	cb := w.onAction
	w.mu.RUnlock()

	w.recorder.RecordAction(action, snapshot)

	if cb != nil {
		cb(action)
	}
}

// getLevelEntryTime returns when a dimension entered its current level
func (w *Watchdog) getLevelEntryTime(dim Dimension) time.Time {
	w.mu.RLock()
	defer w.mu.RUnlock()
	if t, exists := w.levelDurations[dim]; exists {
		return t
	}
	return time.Now()
}

// =============================================================================
// Public Accessors
// =============================================================================

// GetState returns the current pressure state
func (w *Watchdog) GetState() *PressureState {
	w.mu.RLock()
	defer w.mu.RUnlock()
	if w.lastState != nil {
		return w.lastState
	}
	return NewPressureState()
}

// GetSnapshot returns the last collected snapshot
func (w *Watchdog) GetSnapshot() *Snapshot {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return w.lastSnapshot
}

// GetMode returns the current operating mode
func (w *Watchdog) GetMode() Mode {
	return w.state.GetMode()
}

// GetControls returns the runtime controls
func (w *Watchdog) GetControls() *RuntimeControls {
	return w.controls
}

// IsRunning returns whether the watchdog is running
func (w *Watchdog) IsRunning() bool {
	w.mu.RLock()
	defer w.mu.RUnlock()
	return w.running
}

// SetOnMetrics sets a callback for metrics updates
func (w *Watchdog) SetOnMetrics(cb func(*Snapshot, *PressureState)) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.onMetrics = cb
}

// SetOnAction sets a callback fired when the watchdog executes an action.
// The callback runs on the watchdog's action-dispatch goroutine; it must not
// block. Wires action events into the Prometheus metrics exporter so that
// nftban_watchdog_action_total and nftban_watchdog_last_action_timestamp_seconds
// are emitted in production (companion to SetOnMetrics for tick-based metrics).
func (w *Watchdog) SetOnAction(cb func(Action)) {
	w.mu.Lock()
	defer w.mu.Unlock()
	w.onAction = cb
}

// GetRecorderStats returns flight recorder statistics
func (w *Watchdog) GetRecorderStats() RecorderStats {
	return w.recorder.GetStats()
}

// GetRecentEvents returns recent events from the flight recorder
func (w *Watchdog) GetRecentEvents(count int) []Event {
	return w.recorder.GetRecentEvents(count)
}

// RecordNFTApplyLatency records nft apply latency
func (w *Watchdog) RecordNFTApplyLatency(latency time.Duration) {
	w.nftablesCollector.RecordApplyLatency(latency)
}
