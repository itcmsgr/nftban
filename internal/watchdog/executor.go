// =============================================================================
// NFTBan v1.0 - Watchdog Action Executor
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="executor"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Action executor for throttle, profiler, and memory valve operations"
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
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"runtime/pprof"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/logx"
)

// ActionExecutor handles action execution with cooldowns
type ActionExecutor struct {
	config   *Config
	controls *RuntimeControls

	mu        sync.Mutex
	cooldowns *Cooldowns

	// Callbacks for recording events
	onAction func(action Action)
}

// NewActionExecutor creates a new action executor
func NewActionExecutor(cfg *Config, controls *RuntimeControls) *ActionExecutor {
	return &ActionExecutor{
		config:    cfg,
		controls:  controls,
		cooldowns: NewCooldowns(),
	}
}

// SetOnAction sets the callback for when actions are taken
func (e *ActionExecutor) SetOnAction(cb func(Action)) {
	e.mu.Lock()
	defer e.mu.Unlock()
	e.onAction = cb
}

// =============================================================================
// Mode Transition Actions
// =============================================================================

// ApplyMode applies settings for the given mode
func (e *ActionExecutor) ApplyMode(mode Mode, snapshot *Snapshot) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	// Apply runtime controls
	e.controls.SetMode(mode)

	action := Action{
		Type:      ActionDegradeMode,
		Timestamp: time.Now(),
		Reason:    fmt.Sprintf("mode transition to %s", mode),
		Success:   true,
	}

	switch mode {
	case ModeNormal:
		action.Details = "restored normal operation"

	case ModeDegraded:
		action.Details = fmt.Sprintf("workers=%d, expensive_collectors=false",
			e.controls.MaxWorkers.Load())

	case ModeSurvival:
		action.Details = fmt.Sprintf("workers=%d, minimal operation",
			e.controls.MaxWorkers.Load())
	}

	e.recordAction(action)
	return nil
}

// =============================================================================
// Throttle Actions
// =============================================================================

// Throttle reduces worker count and disables optional work
func (e *ActionExecutor) Throttle(reason string) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if !e.cooldowns.CanExecute(ActionThrottle, time.Minute) {
		return nil // Still in cooldown
	}

	currentWorkers := e.controls.MaxWorkers.Load()
	newWorkers := currentWorkers / 2
	if newWorkers < 1 {
		newWorkers = 1
	}
	e.controls.MaxWorkers.Store(newWorkers)
	e.controls.EnableExpensiveCollectors.Store(false)

	action := Action{
		Type:      ActionThrottle,
		Timestamp: time.Now(),
		Reason:    reason,
		Details:   fmt.Sprintf("workers: %d->%d", currentWorkers, newWorkers),
		Success:   true,
	}

	e.cooldowns.Record(ActionThrottle)
	e.recordAction(action)
	return nil
}

// DisableOptional disables optional collectors
func (e *ActionExecutor) DisableOptional(reason string) error {
	e.mu.Lock()
	defer e.mu.Unlock()

	if !e.cooldowns.CanExecute(ActionDisableOptional, time.Minute) {
		return nil
	}

	e.controls.EnableNFTRulesetScan.Store(false)
	e.controls.EnableTopProcesses.Store(false)
	e.controls.EnableVerboseLogging.Store(false)

	action := Action{
		Type:      ActionDisableOptional,
		Timestamp: time.Now(),
		Reason:    reason,
		Details:   "disabled nft_ruleset_scan, top_processes, verbose_logging",
		Success:   true,
	}

	e.cooldowns.Record(ActionDisableOptional)
	e.recordAction(action)
	return nil
}

// =============================================================================
// Profiling Actions
// =============================================================================

// CaptureCPUProfile captures a CPU profile
func (e *ActionExecutor) CaptureCPUProfile(reason string, snapshot *Snapshot) (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	if !e.config.ProfileAutoEnabled {
		return "", nil
	}

	if !e.cooldowns.CanExecute(ActionProfileCPU, e.config.ProfileCPUCooldown) {
		return "", nil
	}

	// Create profile file
	filename := fmt.Sprintf("cpu_%s_%s.pprof",
		time.Now().Format("20060102_150405"),
		sanitizeReason(reason))
	path := filepath.Join(e.config.ProfileDir, filename)

	// Ensure directory exists
	if err := os.MkdirAll(e.config.ProfileDir, 0750); err != nil {
		return "", err
	}

	f, err := os.Create(path)
	if err != nil {
		return "", err
	}

	if err := pprof.StartCPUProfile(f); err != nil {
		f.Close()
		return "", err
	}

	// Run profiling in background
	go func() {
		time.Sleep(e.config.ProfileCPUDuration)
		pprof.StopCPUProfile()
		f.Close()

		// Write sidecar JSON
		e.writeProfileSidecar(path, "cpu", reason, snapshot)
	}()

	action := Action{
		Type:      ActionProfileCPU,
		Timestamp: time.Now(),
		Reason:    reason,
		Details:   fmt.Sprintf("path=%s duration=%s", path, e.config.ProfileCPUDuration),
		Success:   true,
	}

	e.cooldowns.Record(ActionProfileCPU)
	e.recordAction(action)
	return path, nil
}

// CaptureHeapProfile captures a heap profile
func (e *ActionExecutor) CaptureHeapProfile(reason string, snapshot *Snapshot) (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	if !e.config.ProfileAutoEnabled {
		return "", nil
	}

	if !e.cooldowns.CanExecute(ActionProfileHeap, e.config.ProfileHeapCooldown) {
		return "", nil
	}

	filename := fmt.Sprintf("heap_%s_%s.pprof",
		time.Now().Format("20060102_150405"),
		sanitizeReason(reason))
	path := filepath.Join(e.config.ProfileDir, filename)

	if err := os.MkdirAll(e.config.ProfileDir, 0750); err != nil {
		return "", err
	}

	f, err := os.Create(path)
	if err != nil {
		return "", err
	}
	defer f.Close()

	runtime.GC() // For accurate heap stats
	if err := pprof.WriteHeapProfile(f); err != nil {
		return "", err
	}

	e.writeProfileSidecar(path, "heap", reason, snapshot)

	action := Action{
		Type:      ActionProfileHeap,
		Timestamp: time.Now(),
		Reason:    reason,
		Details:   fmt.Sprintf("path=%s", path),
		Success:   true,
	}

	e.cooldowns.Record(ActionProfileHeap)
	e.recordAction(action)
	return path, nil
}

// CaptureGoroutineProfile captures a goroutine profile
func (e *ActionExecutor) CaptureGoroutineProfile(reason string, snapshot *Snapshot) (string, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	if !e.config.ProfileAutoEnabled {
		return "", nil
	}

	if !e.cooldowns.CanExecute(ActionProfileGoroutine, e.config.ProfileGoroutineCooldown) {
		return "", nil
	}

	filename := fmt.Sprintf("goroutine_%s_%s.pprof",
		time.Now().Format("20060102_150405"),
		sanitizeReason(reason))
	path := filepath.Join(e.config.ProfileDir, filename)

	if err := os.MkdirAll(e.config.ProfileDir, 0750); err != nil {
		return "", err
	}

	f, err := os.Create(path)
	if err != nil {
		return "", err
	}
	defer f.Close()

	if err := pprof.Lookup("goroutine").WriteTo(f, 0); err != nil {
		return "", err
	}

	e.writeProfileSidecar(path, "goroutine", reason, snapshot)

	action := Action{
		Type:      ActionProfileGoroutine,
		Timestamp: time.Now(),
		Reason:    reason,
		Details:   fmt.Sprintf("path=%s goroutines=%d", path, snapshot.Runtime.Goroutines),
		Success:   true,
	}

	e.cooldowns.Record(ActionProfileGoroutine)
	e.recordAction(action)
	return path, nil
}

// =============================================================================
// Memory Valve
// =============================================================================

// TryFreeOSMemory calls debug.FreeOSMemory if conditions are met
// Safe conditions:
//   - MEM CRITICAL for >= 30s
//   - CPU below threshold (not during high load)
//   - Cooldown passed
func (e *ActionExecutor) TryFreeOSMemory(
	memCriticalDuration time.Duration,
	cpuPercent float64,
	snapshot *Snapshot,
) (bool, error) {
	e.mu.Lock()
	defer e.mu.Unlock()

	if !e.config.FreeOSMemoryEnabled {
		return false, nil
	}

	// Check cooldown
	if !e.cooldowns.CanExecute(ActionFreeOSMemory, e.config.FreeOSMemoryCooldown) {
		return false, nil
	}

	// Check duration requirement (30s default)
	if memCriticalDuration < 30*time.Second {
		return false, nil
	}

	// Check CPU condition
	if cpuPercent >= e.config.FreeOSMemoryOnlyIfCPUBelow {
		return false, nil
	}

	// Record before stats
	beforeRSS := snapshot.Process.RSS
	beforeHeap := snapshot.Runtime.HeapAlloc

	// Execute
	debug.FreeOSMemory()

	// Record after stats (need fresh read)
	var memStats runtime.MemStats
	runtime.ReadMemStats(&memStats)
	afterHeap := memStats.HeapAlloc

	action := Action{
		Type:      ActionFreeOSMemory,
		Timestamp: time.Now(),
		Reason:    fmt.Sprintf("MEM CRITICAL for %s, CPU=%.1f%%", memCriticalDuration, cpuPercent),
		Details: fmt.Sprintf("before_rss=%d before_heap=%d after_heap=%d",
			beforeRSS, beforeHeap, afterHeap),
		Success: true,
	}

	e.cooldowns.Record(ActionFreeOSMemory)
	e.recordAction(action)

	logx.Watchdog("FreeOSMemory executed (heap: %d -> %d bytes)",
		beforeHeap, afterHeap)

	return true, nil
}

// =============================================================================
// Helpers
// =============================================================================

// recordAction records an action via callback
func (e *ActionExecutor) recordAction(action Action) {
	if e.onAction != nil {
		e.onAction(action)
	}
}

// writeProfileSidecar writes JSON metadata alongside profile
func (e *ActionExecutor) writeProfileSidecar(profilePath, profileType, reason string, snapshot *Snapshot) {
	sidecarPath := profilePath + ".json"

	data := map[string]interface{}{
		"timestamp":    time.Now().Format(time.RFC3339),
		"profile_type": profileType,
		"reason":       reason,
		"pid":          snapshot.Process.PID,
		"rss_bytes":    snapshot.Process.RSS,
		"heap_bytes":   snapshot.Runtime.HeapAlloc,
		"goroutines":   snapshot.Runtime.Goroutines,
		"cpu_percent":  snapshot.Process.CPUPct,
		"mode":         e.controls.GetMode(),
	}

	// Include nft set sizes
	if snapshot.NFTables.SetElements != nil {
		data["nft_sets"] = snapshot.NFTables.SetElements
	}

	// Include conntrack if available
	if snapshot.Kernel.ConntrackMax > 0 {
		data["conntrack_util"] = snapshot.Kernel.ConntrackUtilization
	}

	// Write JSON
	f, err := os.Create(sidecarPath)
	if err != nil {
		return
	}
	defer f.Close()

	fmt.Fprintf(f, "{\n")
	first := true
	for k, v := range data {
		if !first {
			fmt.Fprintf(f, ",\n")
		}
		first = false
		fmt.Fprintf(f, "  %q: %v", k, formatJSON(v))
	}
	fmt.Fprintf(f, "\n}\n")
}

// formatJSON formats a value for JSON output
func formatJSON(v interface{}) string {
	switch val := v.(type) {
	case string:
		return fmt.Sprintf("%q", val)
	case map[string]int:
		s := "{"
		first := true
		for k, v := range val {
			if !first {
				s += ", "
			}
			first = false
			s += fmt.Sprintf("%q: %d", k, v)
		}
		s += "}"
		return s
	default:
		return fmt.Sprintf("%v", val)
	}
}

// sanitizeReason makes a reason string safe for filenames
func sanitizeReason(reason string) string {
	result := ""
	for _, r := range reason {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') {
			result += string(r)
		} else if r == ' ' || r == '_' {
			result += "_"
		}
	}
	if len(result) > 20 {
		result = result[:20]
	}
	return result
}
