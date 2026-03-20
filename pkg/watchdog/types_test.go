// =============================================================================
// NFTBan - Tests for watchdog types and constants
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="watchdog_types_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for watchdog types and constants"
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
// AllDimensions
// =============================================================================

func TestAllDimensions(t *testing.T) {
	dims := AllDimensions()
	if len(dims) != 4 {
		t.Fatalf("AllDimensions() returned %d dimensions, want 4", len(dims))
	}

	expected := map[Dimension]bool{
		DimCPU: true,
		DimMEM: true,
		DimIO:  true,
		DimNET: true,
	}

	for _, dim := range dims {
		if !expected[dim] {
			t.Errorf("unexpected dimension %q in AllDimensions()", dim)
		}
	}
}

// =============================================================================
// NewPressureState
// =============================================================================

func TestNewPressureState(t *testing.T) {
	ps := NewPressureState()

	if ps == nil {
		t.Fatal("NewPressureState() returned nil")
	}

	if ps.Mode != ModeNormal {
		t.Errorf("Mode = %q, want %q", ps.Mode, ModeNormal)
	}

	if ps.Timestamp.IsZero() {
		t.Error("Timestamp should not be zero")
	}

	if ps.ModeEnteredAt.IsZero() {
		t.Error("ModeEnteredAt should not be zero")
	}

	// All dimensions should be initialized
	for _, dim := range AllDimensions() {
		if score, ok := ps.Scores[dim]; !ok {
			t.Errorf("Score for %s not initialized", dim)
		} else if score != 0 {
			t.Errorf("Score for %s = %f, want 0", dim, score)
		}

		if level, ok := ps.Levels[dim]; !ok {
			t.Errorf("Level for %s not initialized", dim)
		} else if level != LevelOK {
			t.Errorf("Level for %s = %q, want %q", dim, level, LevelOK)
		}
	}
}

// =============================================================================
// PressureState.WorstLevel
// =============================================================================

func TestWorstLevel(t *testing.T) {
	tests := []struct {
		name   string
		levels map[Dimension]Level
		want   Level
	}{
		{
			name: "all OK returns OK",
			levels: map[Dimension]Level{
				DimCPU: LevelOK,
				DimMEM: LevelOK,
				DimIO:  LevelOK,
				DimNET: LevelOK,
			},
			want: LevelOK,
		},
		{
			name: "one warn returns warn",
			levels: map[Dimension]Level{
				DimCPU: LevelOK,
				DimMEM: LevelWarn,
				DimIO:  LevelOK,
				DimNET: LevelOK,
			},
			want: LevelWarn,
		},
		{
			name: "one critical returns critical",
			levels: map[Dimension]Level{
				DimCPU: LevelOK,
				DimMEM: LevelWarn,
				DimIO:  LevelCritical,
				DimNET: LevelOK,
			},
			want: LevelCritical,
		},
		{
			name: "all critical returns critical",
			levels: map[Dimension]Level{
				DimCPU: LevelCritical,
				DimMEM: LevelCritical,
				DimIO:  LevelCritical,
				DimNET: LevelCritical,
			},
			want: LevelCritical,
		},
		{
			name: "multiple warn returns warn",
			levels: map[Dimension]Level{
				DimCPU: LevelWarn,
				DimMEM: LevelWarn,
				DimIO:  LevelOK,
				DimNET: LevelOK,
			},
			want: LevelWarn,
		},
		{
			name:   "empty levels returns OK",
			levels: map[Dimension]Level{},
			want:   LevelOK,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ps := &PressureState{
				Levels: tc.levels,
			}
			got := ps.WorstLevel()
			if got != tc.want {
				t.Errorf("WorstLevel() = %q, want %q", got, tc.want)
			}
		})
	}
}

// =============================================================================
// RuntimeControls
// =============================================================================

func TestNewRuntimeControls(t *testing.T) {
	rc := NewRuntimeControls()

	if rc.MaxWorkers.Load() != 10 {
		t.Errorf("MaxWorkers = %d, want 10", rc.MaxWorkers.Load())
	}
	if !rc.EnableExpensiveCollectors.Load() {
		t.Error("EnableExpensiveCollectors should be true")
	}
	if !rc.EnableNFTRulesetScan.Load() {
		t.Error("EnableNFTRulesetScan should be true")
	}
	if !rc.EnableTopProcesses.Load() {
		t.Error("EnableTopProcesses should be true")
	}
	if !rc.EnableVerboseLogging.Load() {
		t.Error("EnableVerboseLogging should be true")
	}
	if rc.TelemetrySamplingFactor.Load() != 100 {
		t.Errorf("TelemetrySamplingFactor = %d, want 100", rc.TelemetrySamplingFactor.Load())
	}
	if rc.GetMode() != ModeNormal {
		t.Errorf("GetMode() = %q, want %q", rc.GetMode(), ModeNormal)
	}
}

func TestRuntimeControlsSetMode(t *testing.T) {
	tests := []struct {
		name                     string
		mode                     Mode
		wantMaxWorkers           int32
		wantExpensiveCollectors  bool
		wantNFTRulesetScan       bool
		wantTopProcesses         bool
		wantVerboseLogging       bool
		wantSamplingFactor       uint32
		wantMode                 Mode
	}{
		{
			name:                    "normal mode",
			mode:                    ModeNormal,
			wantMaxWorkers:          10,
			wantExpensiveCollectors: true,
			wantNFTRulesetScan:      true,
			wantTopProcesses:        true,
			wantVerboseLogging:      true,
			wantSamplingFactor:      100,
			wantMode:                ModeNormal,
		},
		{
			name:                    "degraded mode",
			mode:                    ModeDegraded,
			wantMaxWorkers:          5,
			wantExpensiveCollectors: false,
			wantNFTRulesetScan:      false,
			wantTopProcesses:        false,
			wantVerboseLogging:      false,
			wantSamplingFactor:      50,
			wantMode:                ModeDegraded,
		},
		{
			name:                    "survival mode",
			mode:                    ModeSurvival,
			wantMaxWorkers:          2,
			wantExpensiveCollectors: false,
			wantNFTRulesetScan:      false,
			wantTopProcesses:        false,
			wantVerboseLogging:      false,
			wantSamplingFactor:      25,
			wantMode:                ModeSurvival,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rc := NewRuntimeControls()
			rc.SetMode(tc.mode)

			if rc.MaxWorkers.Load() != tc.wantMaxWorkers {
				t.Errorf("MaxWorkers = %d, want %d", rc.MaxWorkers.Load(), tc.wantMaxWorkers)
			}
			if rc.EnableExpensiveCollectors.Load() != tc.wantExpensiveCollectors {
				t.Errorf("EnableExpensiveCollectors = %v, want %v", rc.EnableExpensiveCollectors.Load(), tc.wantExpensiveCollectors)
			}
			if rc.EnableNFTRulesetScan.Load() != tc.wantNFTRulesetScan {
				t.Errorf("EnableNFTRulesetScan = %v, want %v", rc.EnableNFTRulesetScan.Load(), tc.wantNFTRulesetScan)
			}
			if rc.EnableTopProcesses.Load() != tc.wantTopProcesses {
				t.Errorf("EnableTopProcesses = %v, want %v", rc.EnableTopProcesses.Load(), tc.wantTopProcesses)
			}
			if rc.EnableVerboseLogging.Load() != tc.wantVerboseLogging {
				t.Errorf("EnableVerboseLogging = %v, want %v", rc.EnableVerboseLogging.Load(), tc.wantVerboseLogging)
			}
			if rc.TelemetrySamplingFactor.Load() != tc.wantSamplingFactor {
				t.Errorf("TelemetrySamplingFactor = %d, want %d", rc.TelemetrySamplingFactor.Load(), tc.wantSamplingFactor)
			}
			if rc.GetMode() != tc.wantMode {
				t.Errorf("GetMode() = %q, want %q", rc.GetMode(), tc.wantMode)
			}
		})
	}
}

func TestRuntimeControlsReset(t *testing.T) {
	rc := NewRuntimeControls()

	// Set to survival mode
	rc.SetMode(ModeSurvival)
	if rc.MaxWorkers.Load() != 2 {
		t.Fatalf("precondition failed: MaxWorkers = %d after survival", rc.MaxWorkers.Load())
	}

	// Reset
	rc.Reset()

	if rc.MaxWorkers.Load() != 10 {
		t.Errorf("MaxWorkers after Reset = %d, want 10", rc.MaxWorkers.Load())
	}
	if rc.GetMode() != ModeNormal {
		t.Errorf("GetMode() after Reset = %q, want %q", rc.GetMode(), ModeNormal)
	}
	if !rc.EnableExpensiveCollectors.Load() {
		t.Error("EnableExpensiveCollectors should be true after Reset")
	}
}

func TestRuntimeControlsGetSamplingFactor(t *testing.T) {
	tests := []struct {
		name    string
		stored  uint32
		want    float64
	}{
		{"100 percent", 100, 1.0},
		{"50 percent", 50, 0.5},
		{"25 percent", 25, 0.25},
		{"0 percent", 0, 0.0},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			rc := NewRuntimeControls()
			rc.TelemetrySamplingFactor.Store(tc.stored)
			got := rc.GetSamplingFactor()
			if got != tc.want {
				t.Errorf("GetSamplingFactor() = %f, want %f", got, tc.want)
			}
		})
	}
}

func TestRuntimeControlsGetModeDefault(t *testing.T) {
	rc := NewRuntimeControls()
	// Store an invalid mode value
	rc.currentMode.Store(99)
	if rc.GetMode() != ModeNormal {
		t.Errorf("GetMode() for invalid stored value = %q, want %q", rc.GetMode(), ModeNormal)
	}
}

func TestRuntimeControlsConcurrency(t *testing.T) {
	rc := NewRuntimeControls()

	var wg sync.WaitGroup

	// Writers
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				switch n % 3 {
				case 0:
					rc.SetMode(ModeNormal)
				case 1:
					rc.SetMode(ModeDegraded)
				case 2:
					rc.SetMode(ModeSurvival)
				}
			}
		}(i)
	}

	// Readers
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 100; j++ {
				_ = rc.GetMode()
				_ = rc.GetSamplingFactor()
				_ = rc.MaxWorkers.Load()
				_ = rc.EnableExpensiveCollectors.Load()
			}
		}()
	}

	wg.Wait()
}

// =============================================================================
// Cooldowns
// =============================================================================

func TestNewCooldowns(t *testing.T) {
	c := NewCooldowns()
	if c == nil {
		t.Fatal("NewCooldowns() returned nil")
	}
	if c.lastActions == nil {
		t.Error("lastActions map should be initialized")
	}
}

func TestCooldownsCanExecute(t *testing.T) {
	tests := []struct {
		name     string
		action   ActionType
		cooldown time.Duration
		setup    func(*Cooldowns)
		want     bool
	}{
		{
			name:     "never executed returns true",
			action:   ActionThrottle,
			cooldown: time.Second,
			setup:    func(c *Cooldowns) {},
			want:     true,
		},
		{
			name:     "different action returns true",
			action:   ActionProfileCPU,
			cooldown: time.Second,
			setup: func(c *Cooldowns) {
				c.Record(ActionThrottle)
			},
			want: true,
		},
		{
			name:     "recently executed returns false",
			action:   ActionThrottle,
			cooldown: time.Hour,
			setup: func(c *Cooldowns) {
				c.Record(ActionThrottle)
			},
			want: false,
		},
		{
			name:     "zero cooldown always returns true",
			action:   ActionThrottle,
			cooldown: 0,
			setup: func(c *Cooldowns) {
				c.Record(ActionThrottle)
			},
			want: true,
		},
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			c := NewCooldowns()
			tc.setup(c)
			got := c.CanExecute(tc.action, tc.cooldown)
			if got != tc.want {
				t.Errorf("CanExecute() = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestCooldownsRecord(t *testing.T) {
	c := NewCooldowns()

	// Should be able to execute
	if !c.CanExecute(ActionThrottle, time.Minute) {
		t.Error("should be able to execute before first record")
	}

	c.Record(ActionThrottle)

	// Should NOT be able to execute with long cooldown
	if c.CanExecute(ActionThrottle, time.Hour) {
		t.Error("should not be able to execute during cooldown period")
	}
}

func TestCooldownsTimeSince(t *testing.T) {
	c := NewCooldowns()

	// Never executed should return very large duration
	ts := c.TimeSince(ActionThrottle)
	if ts < time.Hour*24*364 {
		t.Errorf("TimeSince for unrecorded action = %v, want >= 364 days", ts)
	}

	// Record and check
	c.Record(ActionThrottle)
	time.Sleep(time.Millisecond)
	ts = c.TimeSince(ActionThrottle)
	if ts < time.Millisecond {
		t.Errorf("TimeSince after record = %v, want >= 1ms", ts)
	}
	if ts > time.Second {
		t.Errorf("TimeSince after record = %v, unexpectedly large", ts)
	}
}

func TestCooldownsMultipleActions(t *testing.T) {
	c := NewCooldowns()

	c.Record(ActionThrottle)
	c.Record(ActionProfileCPU)

	// Both should be in cooldown
	if c.CanExecute(ActionThrottle, time.Hour) {
		t.Error("ActionThrottle should be in cooldown")
	}
	if c.CanExecute(ActionProfileCPU, time.Hour) {
		t.Error("ActionProfileCPU should be in cooldown")
	}

	// Different action should be available
	if !c.CanExecute(ActionFreeOSMemory, time.Hour) {
		t.Error("ActionFreeOSMemory should be available")
	}
}

// =============================================================================
// Dimension and Level constants
// =============================================================================

func TestDimensionConstants(t *testing.T) {
	if DimCPU != "cpu" {
		t.Errorf("DimCPU = %q, want %q", DimCPU, "cpu")
	}
	if DimMEM != "mem" {
		t.Errorf("DimMEM = %q, want %q", DimMEM, "mem")
	}
	if DimIO != "io" {
		t.Errorf("DimIO = %q, want %q", DimIO, "io")
	}
	if DimNET != "net" {
		t.Errorf("DimNET = %q, want %q", DimNET, "net")
	}
}

func TestLevelConstants(t *testing.T) {
	if LevelOK != "ok" {
		t.Errorf("LevelOK = %q, want %q", LevelOK, "ok")
	}
	if LevelWarn != "warn" {
		t.Errorf("LevelWarn = %q, want %q", LevelWarn, "warn")
	}
	if LevelCritical != "critical" {
		t.Errorf("LevelCritical = %q, want %q", LevelCritical, "critical")
	}
}

func TestModeConstants(t *testing.T) {
	if ModeNormal != "normal" {
		t.Errorf("ModeNormal = %q, want %q", ModeNormal, "normal")
	}
	if ModeDegraded != "degraded" {
		t.Errorf("ModeDegraded = %q, want %q", ModeDegraded, "degraded")
	}
	if ModeSurvival != "survival" {
		t.Errorf("ModeSurvival = %q, want %q", ModeSurvival, "survival")
	}
}

func TestActionTypeConstants(t *testing.T) {
	expected := map[ActionType]string{
		ActionThrottle:         "throttle",
		ActionDisableOptional:  "disable_optional",
		ActionProfileCPU:       "profile_cpu",
		ActionProfileHeap:      "profile_heap",
		ActionProfileGoroutine: "profile_goroutine",
		ActionFreeOSMemory:     "free_os_memory",
		ActionDegradeMode:      "degrade_mode",
	}

	for at, want := range expected {
		if string(at) != want {
			t.Errorf("ActionType %v = %q, want %q", at, string(at), want)
		}
	}
}

func TestEventTypeConstants(t *testing.T) {
	expected := map[EventType]string{
		EventModeChange:      "mode_change",
		EventPressureChange:  "pressure_change",
		EventActionTaken:     "action_taken",
		EventThresholdBreach: "threshold_breach",
		EventProfileCapture:  "profile_capture",
	}

	for et, want := range expected {
		if string(et) != want {
			t.Errorf("EventType %v = %q, want %q", et, string(et), want)
		}
	}
}
