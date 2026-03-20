// =============================================================================
// NFTBan - Tests for watchdog action executor
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="watchdog_executor_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for watchdog action executor"
// meta:input="None"
// meta:output="None"
// meta:depends="testing"
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
	"sync"
	"testing"
	"time"
)

// =============================================================================
// NewActionExecutor
// =============================================================================

func TestNewActionExecutor(t *testing.T) {
	cfg := testConfig()
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	if exec == nil {
		t.Fatal("NewActionExecutor() returned nil")
	}
	if exec.cooldowns == nil {
		t.Error("cooldowns should be initialized")
	}
}

// =============================================================================
// ApplyMode
// =============================================================================

func TestApplyMode(t *testing.T) {
	tests := []struct {
		name string
		mode Mode
	}{
		{"normal mode", ModeNormal},
		{"degraded mode", ModeDegraded},
		{"survival mode", ModeSurvival},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			cfg := testConfig()
			controls := NewRuntimeControls()
			exec := NewActionExecutor(cfg, controls)

			var recordedAction Action
			exec.SetOnAction(func(a Action) {
				recordedAction = a
			})

			err := exec.ApplyMode(tc.mode, &Snapshot{})
			if err != nil {
				t.Fatalf("ApplyMode() error = %v", err)
			}

			if recordedAction.Type != ActionDegradeMode {
				t.Errorf("action type = %q, want %q", recordedAction.Type, ActionDegradeMode)
			}
			if !recordedAction.Success {
				t.Error("action should be successful")
			}
			if controls.GetMode() != tc.mode {
				t.Errorf("controls mode = %q, want %q", controls.GetMode(), tc.mode)
			}
		})
	}
}

func TestApplyMode_NormalRestoresDefaults(t *testing.T) {
	cfg := testConfig()
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	// Set to survival first
	exec.ApplyMode(ModeSurvival, &Snapshot{})
	if controls.MaxWorkers.Load() != 2 {
		t.Fatalf("survival MaxWorkers = %d, want 2", controls.MaxWorkers.Load())
	}

	// Restore normal
	exec.ApplyMode(ModeNormal, &Snapshot{})
	if controls.MaxWorkers.Load() != 10 {
		t.Errorf("normal MaxWorkers = %d, want 10", controls.MaxWorkers.Load())
	}
	if !controls.EnableExpensiveCollectors.Load() {
		t.Error("EnableExpensiveCollectors should be true in normal")
	}
}

// =============================================================================
// Throttle
// =============================================================================

func TestThrottle(t *testing.T) {
	cfg := testConfig()
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	var recordedAction Action
	exec.SetOnAction(func(a Action) {
		recordedAction = a
	})

	err := exec.Throttle("test_reason")
	if err != nil {
		t.Fatalf("Throttle() error = %v", err)
	}

	// Workers should be halved: 10 -> 5
	if controls.MaxWorkers.Load() != 5 {
		t.Errorf("MaxWorkers = %d, want 5", controls.MaxWorkers.Load())
	}
	if controls.EnableExpensiveCollectors.Load() {
		t.Error("EnableExpensiveCollectors should be false after throttle")
	}
	if recordedAction.Type != ActionThrottle {
		t.Errorf("action type = %q, want %q", recordedAction.Type, ActionThrottle)
	}
}

func TestThrottle_MinimumOneWorker(t *testing.T) {
	cfg := testConfig()
	controls := NewRuntimeControls()
	controls.MaxWorkers.Store(1)
	exec := NewActionExecutor(cfg, controls)

	exec.Throttle("test")

	// 1/2 = 0, but minimum is 1
	if controls.MaxWorkers.Load() != 1 {
		t.Errorf("MaxWorkers = %d, want 1 (minimum)", controls.MaxWorkers.Load())
	}
}

func TestThrottle_CooldownPreventsRepeat(t *testing.T) {
	cfg := testConfig()
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	callCount := 0
	exec.SetOnAction(func(a Action) {
		callCount++
	})

	// First call
	exec.Throttle("first")
	if callCount != 1 {
		t.Fatalf("first Throttle: callCount = %d, want 1", callCount)
	}

	// Second call immediately - should be blocked by cooldown (1 minute)
	exec.Throttle("second")
	if callCount != 1 {
		t.Errorf("second Throttle: callCount = %d, want 1 (cooldown)", callCount)
	}
}

func TestThrottle_SuccessiveHalving(t *testing.T) {
	cfg := testConfig()
	controls := NewRuntimeControls()
	controls.MaxWorkers.Store(8)
	exec := NewActionExecutor(cfg, controls)

	// Override cooldown by manipulating internal state
	exec.Throttle("first")
	if controls.MaxWorkers.Load() != 4 {
		t.Errorf("after first throttle: MaxWorkers = %d, want 4", controls.MaxWorkers.Load())
	}

	// Force cooldown to expire by clearing it
	exec.cooldowns.lastActions[ActionThrottle] = time.Now().Add(-2 * time.Minute)

	exec.Throttle("second")
	if controls.MaxWorkers.Load() != 2 {
		t.Errorf("after second throttle: MaxWorkers = %d, want 2", controls.MaxWorkers.Load())
	}
}

// =============================================================================
// DisableOptional
// =============================================================================

func TestDisableOptional(t *testing.T) {
	cfg := testConfig()
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	var recordedAction Action
	exec.SetOnAction(func(a Action) {
		recordedAction = a
	})

	err := exec.DisableOptional("test_reason")
	if err != nil {
		t.Fatalf("DisableOptional() error = %v", err)
	}

	if controls.EnableNFTRulesetScan.Load() {
		t.Error("EnableNFTRulesetScan should be false")
	}
	if controls.EnableTopProcesses.Load() {
		t.Error("EnableTopProcesses should be false")
	}
	if controls.EnableVerboseLogging.Load() {
		t.Error("EnableVerboseLogging should be false")
	}
	if recordedAction.Type != ActionDisableOptional {
		t.Errorf("action type = %q, want %q", recordedAction.Type, ActionDisableOptional)
	}
}

func TestDisableOptional_CooldownPreventsRepeat(t *testing.T) {
	cfg := testConfig()
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	callCount := 0
	exec.SetOnAction(func(a Action) {
		callCount++
	})

	exec.DisableOptional("first")
	exec.DisableOptional("second") // should be blocked

	if callCount != 1 {
		t.Errorf("callCount = %d, want 1 (cooldown)", callCount)
	}
}

// =============================================================================
// Profile Actions (without filesystem access)
// =============================================================================

func TestCaptureCPUProfile_DisabledConfig(t *testing.T) {
	cfg := testConfig()
	cfg.ProfileAutoEnabled = false
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	path, err := exec.CaptureCPUProfile("test", &Snapshot{})
	if err != nil {
		t.Fatalf("CaptureCPUProfile() error = %v", err)
	}
	if path != "" {
		t.Errorf("path = %q, want empty (profiling disabled)", path)
	}
}

func TestCaptureHeapProfile_DisabledConfig(t *testing.T) {
	cfg := testConfig()
	cfg.ProfileAutoEnabled = false
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	path, err := exec.CaptureHeapProfile("test", &Snapshot{})
	if err != nil {
		t.Fatalf("CaptureHeapProfile() error = %v", err)
	}
	if path != "" {
		t.Errorf("path = %q, want empty (profiling disabled)", path)
	}
}

func TestCaptureGoroutineProfile_DisabledConfig(t *testing.T) {
	cfg := testConfig()
	cfg.ProfileAutoEnabled = false
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	path, err := exec.CaptureGoroutineProfile("test", &Snapshot{})
	if err != nil {
		t.Fatalf("CaptureGoroutineProfile() error = %v", err)
	}
	if path != "" {
		t.Errorf("path = %q, want empty (profiling disabled)", path)
	}
}

func TestCaptureCPUProfile_CooldownBlocks(t *testing.T) {
	cfg := testConfig()
	cfg.ProfileAutoEnabled = true
	cfg.ProfileDir = t.TempDir()
	cfg.ProfileCPUCooldown = time.Hour
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	snapshot := &Snapshot{
		NFTables: NFTablesMetrics{SetElements: map[string]int{}},
	}

	// First call succeeds
	path1, err := exec.CaptureCPUProfile("test", snapshot)
	if err != nil {
		t.Fatalf("first CaptureCPUProfile() error = %v", err)
	}

	// Second call blocked by cooldown
	path2, err := exec.CaptureCPUProfile("test", snapshot)
	if err != nil {
		t.Fatalf("second CaptureCPUProfile() error = %v", err)
	}
	if path2 != "" {
		t.Errorf("second call should return empty path due to cooldown, got %q", path2)
	}

	// Verify first call produced a path
	if path1 == "" {
		t.Error("first call should return a profile path")
	}

	// Wait a tiny bit for the background goroutine to finish
	time.Sleep(100 * time.Millisecond)
}

// =============================================================================
// TryFreeOSMemory
// =============================================================================

func TestTryFreeOSMemory_Disabled(t *testing.T) {
	cfg := testConfig()
	cfg.FreeOSMemoryEnabled = false
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	freed, err := exec.TryFreeOSMemory(time.Minute, 10.0, &Snapshot{})
	if err != nil {
		t.Fatalf("TryFreeOSMemory() error = %v", err)
	}
	if freed {
		t.Error("should not free memory when disabled")
	}
}

func TestTryFreeOSMemory_DurationTooShort(t *testing.T) {
	cfg := testConfig()
	cfg.FreeOSMemoryEnabled = true
	cfg.FreeOSMemoryCooldown = 5 * time.Minute
	cfg.FreeOSMemoryOnlyIfCPUBelow = 40
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	freed, err := exec.TryFreeOSMemory(10*time.Second, 10.0, &Snapshot{})
	if err != nil {
		t.Fatalf("TryFreeOSMemory() error = %v", err)
	}
	if freed {
		t.Error("should not free memory when duration < 30s")
	}
}

func TestTryFreeOSMemory_CPUTooHigh(t *testing.T) {
	cfg := testConfig()
	cfg.FreeOSMemoryEnabled = true
	cfg.FreeOSMemoryCooldown = 5 * time.Minute
	cfg.FreeOSMemoryOnlyIfCPUBelow = 40
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	freed, err := exec.TryFreeOSMemory(time.Minute, 50.0, &Snapshot{})
	if err != nil {
		t.Fatalf("TryFreeOSMemory() error = %v", err)
	}
	if freed {
		t.Error("should not free memory when CPU >= threshold")
	}
}

func TestTryFreeOSMemory_Success(t *testing.T) {
	cfg := testConfig()
	cfg.FreeOSMemoryEnabled = true
	cfg.FreeOSMemoryCooldown = 5 * time.Minute
	cfg.FreeOSMemoryOnlyIfCPUBelow = 40
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	var recordedAction Action
	exec.SetOnAction(func(a Action) {
		recordedAction = a
	})

	snapshot := &Snapshot{
		Process: ProcessMetrics{RSS: 100 * 1024 * 1024},
		Runtime: RuntimeMetrics{HeapAlloc: 50 * 1024 * 1024},
	}

	freed, err := exec.TryFreeOSMemory(time.Minute, 10.0, snapshot)
	if err != nil {
		t.Fatalf("TryFreeOSMemory() error = %v", err)
	}
	if !freed {
		t.Error("should have freed memory")
	}
	if recordedAction.Type != ActionFreeOSMemory {
		t.Errorf("action type = %q, want %q", recordedAction.Type, ActionFreeOSMemory)
	}
	if !recordedAction.Success {
		t.Error("action should be successful")
	}
}

func TestTryFreeOSMemory_CooldownBlocks(t *testing.T) {
	cfg := testConfig()
	cfg.FreeOSMemoryEnabled = true
	cfg.FreeOSMemoryCooldown = time.Hour
	cfg.FreeOSMemoryOnlyIfCPUBelow = 40
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	snapshot := &Snapshot{
		Process: ProcessMetrics{RSS: 100 * 1024 * 1024},
		Runtime: RuntimeMetrics{HeapAlloc: 50 * 1024 * 1024},
	}

	// First call
	freed1, _ := exec.TryFreeOSMemory(time.Minute, 10.0, snapshot)
	if !freed1 {
		t.Fatal("first call should succeed")
	}

	// Second call blocked by cooldown
	freed2, _ := exec.TryFreeOSMemory(time.Minute, 10.0, snapshot)
	if freed2 {
		t.Error("second call should be blocked by cooldown")
	}
}

// =============================================================================
// SetOnAction
// =============================================================================

func TestSetOnAction(t *testing.T) {
	cfg := testConfig()
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	callCount := 0
	exec.SetOnAction(func(a Action) {
		callCount++
	})

	exec.ApplyMode(ModeNormal, &Snapshot{})
	if callCount != 1 {
		t.Errorf("callCount = %d, want 1", callCount)
	}
}

func TestSetOnAction_NilCallback(t *testing.T) {
	cfg := testConfig()
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	// Should not panic with nil callback
	exec.SetOnAction(nil)
	exec.ApplyMode(ModeNormal, &Snapshot{})
}

// =============================================================================
// sanitizeReason
// =============================================================================

func TestSanitizeReason(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{"simple text", "test", "test"},
		{"with spaces", "hello world", "hello_world"},
		{"with underscores", "a_b_c", "a_b_c"},
		{"special characters", "hello!@#$%world", "helloworld"},
		{"mixed", "CPU_CRITICAL 10s!", "CPU_CRITICAL_10s"},
		{"empty", "", ""},
		{"long string truncated", "abcdefghijklmnopqrstuvwxyz", "abcdefghijklmnopqrst"},
		{"all special", "!@#$%^&*()", ""},
		{"digits only", "12345", "12345"},
		{"mixed case", "HelloWorld", "HelloWorld"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := sanitizeReason(tc.input)
			if got != tc.want {
				t.Errorf("sanitizeReason(%q) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}

// =============================================================================
// formatJSON
// =============================================================================

func TestFormatJSON(t *testing.T) {
	tests := []struct {
		name  string
		input interface{}
		want  string
	}{
		{"string", "hello", `"hello"`},
		{"string with quotes", `he"llo`, `"he\"llo"`},
		{"int", 42, "42"},
		{"float", 3.14, "3.14"},
		{"bool", true, "true"},
		{"map string int empty", map[string]int{}, "{}"},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			got := formatJSON(tc.input)
			if got != tc.want {
				t.Errorf("formatJSON(%v) = %q, want %q", tc.input, got, tc.want)
			}
		})
	}
}

func TestFormatJSON_MapStringInt(t *testing.T) {
	// Single key map (deterministic)
	m := map[string]int{"a": 1}
	got := formatJSON(m)
	want := `{"a": 1}`
	if got != want {
		t.Errorf("formatJSON(map) = %q, want %q", got, want)
	}
}

// =============================================================================
// Concurrency
// =============================================================================

func TestExecutorConcurrency(t *testing.T) {
	cfg := testConfig()
	controls := NewRuntimeControls()
	exec := NewActionExecutor(cfg, controls)

	var wg sync.WaitGroup

	// Multiple concurrent ApplyMode calls
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			switch n % 3 {
			case 0:
				exec.ApplyMode(ModeNormal, &Snapshot{})
			case 1:
				exec.ApplyMode(ModeDegraded, &Snapshot{})
			case 2:
				exec.ApplyMode(ModeSurvival, &Snapshot{})
			}
		}(i)
	}

	// Concurrent throttle/disable
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			exec.Throttle("concurrent")
			exec.DisableOptional("concurrent")
		}()
	}

	wg.Wait()
}
