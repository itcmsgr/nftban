// =============================================================================
// NFTBan - Tests for watchdog state machine
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="watchdog_state_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for watchdog state machine"
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

// testConfig returns a config suitable for testing with short durations
func testConfig() *Config {
	return &Config{
		Enabled:                    true,
		BaseInterval:               5 * time.Second,
		HysteresisWarnEnter:        60,
		HysteresisWarnExit:         50,
		HysteresisCritEnter:        80,
		HysteresisCritExit:         70,
		WarnExitDuration:           0, // instant for testing
		CritExitDuration:           0, // instant for testing
		MemBudgetBytes:             512 * 1024 * 1024,
		RSSCritPercentOfBudget:     95,
		HeapCritPercentOfLimit:     90,
		CPUCritPercent:             80,
		LoadNormalizedCrit:         4.0,
		IOWaitCritPercent:          40,
		DiskUseCritPercent:         95,
		ConntrackUtilCrit:          0.9,
		SoftnetDropsRateCrit:       100,
		GoroutinesCrit:             10000,
		DegradedIntervalMultiplier: 2.0,
		ProfileAutoEnabled:         false,
		FreeOSMemoryEnabled:        false,
		RecorderEnabled:            false,
		RecorderMaxEvents:          100,
		RecorderRetentionDays:      1,
		ProfileMaxCount:            1,
	}
}

// allOKScores returns scores where all dimensions are zero
func allOKScores() map[Dimension]float64 {
	return map[Dimension]float64{
		DimCPU: 0,
		DimMEM: 0,
		DimIO:  0,
		DimNET: 0,
	}
}

// =============================================================================
// NewStateMachine
// =============================================================================

func TestNewStateMachine(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	if sm == nil {
		t.Fatal("NewStateMachine() returned nil")
	}
	if sm.GetMode() != ModeNormal {
		t.Errorf("initial mode = %q, want %q", sm.GetMode(), ModeNormal)
	}

	for _, dim := range AllDimensions() {
		if sm.GetLevel(dim) != LevelOK {
			t.Errorf("initial level for %s = %q, want %q", dim, sm.GetLevel(dim), LevelOK)
		}
		if sm.GetScore(dim) != 0 {
			t.Errorf("initial score for %s = %f, want 0", dim, sm.GetScore(dim))
		}
	}
}

// =============================================================================
// State Transitions: OK -> WARN -> CRITICAL -> WARN -> OK
// =============================================================================

func TestStateTransition_OKtoWarn(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	scores := allOKScores()
	scores[DimCPU] = 65 // above HysteresisWarnEnter (60)

	state := sm.Update(scores)

	if state.Levels[DimCPU] != LevelWarn {
		t.Errorf("CPU level = %q, want %q", state.Levels[DimCPU], LevelWarn)
	}
	if state.Mode != ModeDegraded {
		t.Errorf("mode = %q, want %q", state.Mode, ModeDegraded)
	}
}

func TestStateTransition_OKtoCritical(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	scores := allOKScores()
	scores[DimMEM] = 85 // above HysteresisCritEnter (80)

	state := sm.Update(scores)

	if state.Levels[DimMEM] != LevelCritical {
		t.Errorf("MEM level = %q, want %q", state.Levels[DimMEM], LevelCritical)
	}
	if state.Mode != ModeSurvival {
		t.Errorf("mode = %q, want %q", state.Mode, ModeSurvival)
	}
}

func TestStateTransition_WarnToCritical(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	// First push to WARN
	scores := allOKScores()
	scores[DimIO] = 65
	sm.Update(scores)

	// Then push to CRITICAL
	scores[DimIO] = 85
	state := sm.Update(scores)

	if state.Levels[DimIO] != LevelCritical {
		t.Errorf("IO level = %q, want %q", state.Levels[DimIO], LevelCritical)
	}
	if state.Mode != ModeSurvival {
		t.Errorf("mode = %q, want %q", state.Mode, ModeSurvival)
	}
}

func TestStateTransition_CriticalToWarn(t *testing.T) {
	cfg := testConfig()
	cfg.CritExitDuration = 0 // instant recovery for testing
	sm := NewStateMachine(cfg)

	// Push to CRITICAL
	scores := allOKScores()
	scores[DimNET] = 85
	sm.Update(scores)

	// Drop below crit exit (70) but above warn enter (60) -> WARN
	scores[DimNET] = 65
	state := sm.Update(scores)

	if state.Levels[DimNET] != LevelWarn {
		t.Errorf("NET level = %q, want %q (score=65, critExit=70)", state.Levels[DimNET], LevelWarn)
	}
}

func TestStateTransition_CriticalToOK(t *testing.T) {
	cfg := testConfig()
	cfg.CritExitDuration = 0
	sm := NewStateMachine(cfg)

	// Push to CRITICAL
	scores := allOKScores()
	scores[DimCPU] = 85
	sm.Update(scores)

	// Drop below warn enter (60) -> should go straight to OK
	scores[DimCPU] = 40
	state := sm.Update(scores)

	if state.Levels[DimCPU] != LevelOK {
		t.Errorf("CPU level = %q, want %q (score=40, warnEnter=60)", state.Levels[DimCPU], LevelOK)
	}
}

func TestStateTransition_WarnToOK(t *testing.T) {
	cfg := testConfig()
	cfg.WarnExitDuration = 0
	sm := NewStateMachine(cfg)

	// Push to WARN
	scores := allOKScores()
	scores[DimMEM] = 65
	sm.Update(scores)

	// Drop below warn exit (50) -> OK
	scores[DimMEM] = 40
	state := sm.Update(scores)

	if state.Levels[DimMEM] != LevelOK {
		t.Errorf("MEM level = %q, want %q", state.Levels[DimMEM], LevelOK)
	}
	if state.Mode != ModeNormal {
		t.Errorf("mode = %q, want %q", state.Mode, ModeNormal)
	}
}

// =============================================================================
// Hysteresis Tests
// =============================================================================

func TestHysteresis_WarnDoesNotExitImmediately(t *testing.T) {
	cfg := testConfig()
	cfg.WarnExitDuration = time.Hour // Very long - should prevent exit
	sm := NewStateMachine(cfg)

	// Push to WARN
	scores := allOKScores()
	scores[DimCPU] = 65
	sm.Update(scores)

	// Drop below exit threshold but duration not met
	scores[DimCPU] = 45 // below HysteresisWarnExit (50)
	state := sm.Update(scores)

	// Should STILL be WARN because exit duration not met
	if state.Levels[DimCPU] != LevelWarn {
		t.Errorf("CPU level = %q, want %q (hysteresis should prevent exit)", state.Levels[DimCPU], LevelWarn)
	}
}

func TestHysteresis_CritDoesNotExitImmediately(t *testing.T) {
	cfg := testConfig()
	cfg.CritExitDuration = time.Hour
	sm := NewStateMachine(cfg)

	// Push to CRITICAL
	scores := allOKScores()
	scores[DimMEM] = 85
	sm.Update(scores)

	// Drop below crit exit but duration not met
	scores[DimMEM] = 65
	state := sm.Update(scores)

	// Should still be CRITICAL
	if state.Levels[DimMEM] != LevelCritical {
		t.Errorf("MEM level = %q, want %q (hysteresis)", state.Levels[DimMEM], LevelCritical)
	}
}

func TestHysteresis_WarnBounceBack(t *testing.T) {
	cfg := testConfig()
	cfg.WarnExitDuration = time.Hour
	sm := NewStateMachine(cfg)

	// Push to WARN
	scores := allOKScores()
	scores[DimCPU] = 65
	sm.Update(scores)

	// Drop below exit threshold
	scores[DimCPU] = 45
	sm.Update(scores)

	// Bounce back above exit threshold but still in WARN range
	scores[DimCPU] = 55 // above WarnExit (50) but below WarnEnter (60)
	state := sm.Update(scores)

	// Should still be WARN (the belowThresholdAt timer resets)
	if state.Levels[DimCPU] != LevelWarn {
		t.Errorf("CPU level = %q, want %q (bounce back resets timer)", state.Levels[DimCPU], LevelWarn)
	}
}

func TestHysteresis_OKStaysBelowWarnEnter(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	// Score just below warn enter threshold
	scores := allOKScores()
	scores[DimCPU] = 59 // below HysteresisWarnEnter (60)
	state := sm.Update(scores)

	if state.Levels[DimCPU] != LevelOK {
		t.Errorf("CPU level = %q, want %q (below warn enter)", state.Levels[DimCPU], LevelOK)
	}
}

func TestHysteresis_WarnStaysBelowCritEnter(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	// Push to WARN
	scores := allOKScores()
	scores[DimIO] = 65
	sm.Update(scores)

	// Score just below crit enter
	scores[DimIO] = 79 // below HysteresisCritEnter (80)
	state := sm.Update(scores)

	// Should stay WARN
	if state.Levels[DimIO] != LevelWarn {
		t.Errorf("IO level = %q, want %q (below crit enter)", state.Levels[DimIO], LevelWarn)
	}
}

// =============================================================================
// Mode Derivation
// =============================================================================

func TestDeriveMode_NormalWhenAllOK(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	state := sm.Update(allOKScores())

	if state.Mode != ModeNormal {
		t.Errorf("mode = %q, want %q", state.Mode, ModeNormal)
	}
}

func TestDeriveMode_DegradedWhenAnyWarn(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	scores := allOKScores()
	scores[DimIO] = 65
	state := sm.Update(scores)

	if state.Mode != ModeDegraded {
		t.Errorf("mode = %q, want %q", state.Mode, ModeDegraded)
	}
}

func TestDeriveMode_SurvivalWhenAnyCritical(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	scores := allOKScores()
	scores[DimCPU] = 65 // WARN
	scores[DimNET] = 85 // CRITICAL
	state := sm.Update(scores)

	if state.Mode != ModeSurvival {
		t.Errorf("mode = %q, want %q", state.Mode, ModeSurvival)
	}
}

func TestDeriveMode_CriticalTakesPrecedence(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	scores := allOKScores()
	scores[DimCPU] = 65 // WARN
	scores[DimMEM] = 65 // WARN
	scores[DimIO] = 85  // CRITICAL
	scores[DimNET] = 65 // WARN
	state := sm.Update(scores)

	if state.Mode != ModeSurvival {
		t.Errorf("mode = %q, want %q (critical takes precedence)", state.Mode, ModeSurvival)
	}
}

// =============================================================================
// Callback Tests
// =============================================================================

func TestOnModeChangeCallback(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	var gotOld, gotNew Mode
	callCount := 0
	sm.SetOnModeChange(func(old, new Mode) {
		gotOld = old
		gotNew = new
		callCount++
	})

	// Trigger mode change to degraded
	scores := allOKScores()
	scores[DimCPU] = 65
	sm.Update(scores)

	if callCount != 1 {
		t.Errorf("callback count = %d, want 1", callCount)
	}
	if gotOld != ModeNormal {
		t.Errorf("old mode = %q, want %q", gotOld, ModeNormal)
	}
	if gotNew != ModeDegraded {
		t.Errorf("new mode = %q, want %q", gotNew, ModeDegraded)
	}
}

func TestOnModeChangeCallback_NotCalledWhenSameMode(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	callCount := 0
	sm.SetOnModeChange(func(old, new Mode) {
		callCount++
	})

	// Update with all OK (stays NORMAL)
	sm.Update(allOKScores())
	sm.Update(allOKScores())
	sm.Update(allOKScores())

	if callCount != 0 {
		t.Errorf("callback called %d times, want 0 (mode didn't change)", callCount)
	}
}

func TestOnStateChangeCallback(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	callCount := 0
	sm.SetOnStateChange(func(old, new *PressureState) {
		callCount++
	})

	// Change a dimension level
	scores := allOKScores()
	scores[DimCPU] = 65
	sm.Update(scores)

	if callCount != 1 {
		t.Errorf("state change callback count = %d, want 1", callCount)
	}
}

func TestOnStateChangeCallback_NotCalledWhenNoChange(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	callCount := 0
	sm.SetOnStateChange(func(old, new *PressureState) {
		callCount++
	})

	// Same scores, no change
	sm.Update(allOKScores())
	sm.Update(allOKScores())

	if callCount != 0 {
		t.Errorf("state change callback called %d times, want 0", callCount)
	}
}

// =============================================================================
// GetState / GetMode / GetLevel / GetScore / GetModeDuration / IsStable
// =============================================================================

func TestGetState_ReturnsCopy(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	scores := allOKScores()
	scores[DimCPU] = 65
	sm.Update(scores)

	state1 := sm.GetState()
	state2 := sm.GetState()

	// Modify state1 and verify state2 is not affected
	state1.Scores[DimCPU] = 999
	if state2.Scores[DimCPU] == 999 {
		t.Error("GetState should return a copy, not a reference")
	}
}

func TestGetLevel(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	scores := allOKScores()
	scores[DimCPU] = 65
	sm.Update(scores)

	if sm.GetLevel(DimCPU) != LevelWarn {
		t.Errorf("GetLevel(DimCPU) = %q, want %q", sm.GetLevel(DimCPU), LevelWarn)
	}
	if sm.GetLevel(DimMEM) != LevelOK {
		t.Errorf("GetLevel(DimMEM) = %q, want %q", sm.GetLevel(DimMEM), LevelOK)
	}
}

func TestGetScore(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	scores := allOKScores()
	scores[DimNET] = 42.5
	sm.Update(scores)

	if sm.GetScore(DimNET) != 42.5 {
		t.Errorf("GetScore(DimNET) = %f, want 42.5", sm.GetScore(DimNET))
	}
}

func TestGetModeDuration(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	sm.Update(allOKScores())
	time.Sleep(2 * time.Millisecond)

	dur := sm.GetModeDuration()
	if dur < time.Millisecond {
		t.Errorf("GetModeDuration() = %v, expected >= 1ms", dur)
	}
}

func TestGetLevelDuration_NeverSet(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	dur := sm.GetLevelDuration(DimCPU)
	if dur != 0 {
		t.Errorf("GetLevelDuration for unset dim = %v, want 0", dur)
	}
}

func TestGetLevelDuration_AfterEntry(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	scores := allOKScores()
	scores[DimCPU] = 65
	sm.Update(scores)
	time.Sleep(2 * time.Millisecond)

	dur := sm.GetLevelDuration(DimCPU)
	if dur < time.Millisecond {
		t.Errorf("GetLevelDuration = %v, expected >= 1ms", dur)
	}
}

func TestIsStable(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	// Initially stable
	sm.Update(allOKScores())
	if !sm.IsStable() {
		t.Error("should be stable when all OK")
	}
}

func TestIsStable_UnstableDuringTransition(t *testing.T) {
	cfg := testConfig()
	cfg.WarnExitDuration = time.Hour // prevent exit
	sm := NewStateMachine(cfg)

	// Push to WARN
	scores := allOKScores()
	scores[DimCPU] = 65
	sm.Update(scores)

	// Drop below exit threshold (starts the belowThresholdAt timer)
	scores[DimCPU] = 45
	sm.Update(scores)

	if sm.IsStable() {
		t.Error("should NOT be stable during exit transition")
	}
}

// =============================================================================
// stateChanged
// =============================================================================

func TestStateChanged_ModeChange(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	old := &PressureState{
		Mode:   ModeNormal,
		Levels: map[Dimension]Level{DimCPU: LevelOK, DimMEM: LevelOK, DimIO: LevelOK, DimNET: LevelOK},
	}
	new := &PressureState{
		Mode:   ModeDegraded,
		Levels: map[Dimension]Level{DimCPU: LevelWarn, DimMEM: LevelOK, DimIO: LevelOK, DimNET: LevelOK},
	}

	if !sm.stateChanged(old, new) {
		t.Error("stateChanged should detect mode change")
	}
}

func TestStateChanged_LevelChange(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	old := &PressureState{
		Mode:   ModeNormal,
		Levels: map[Dimension]Level{DimCPU: LevelOK, DimMEM: LevelOK, DimIO: LevelOK, DimNET: LevelOK},
	}
	new := &PressureState{
		Mode:   ModeNormal,
		Levels: map[Dimension]Level{DimCPU: LevelOK, DimMEM: LevelWarn, DimIO: LevelOK, DimNET: LevelOK},
	}

	if !sm.stateChanged(old, new) {
		t.Error("stateChanged should detect level change")
	}
}

func TestStateChanged_NoChange(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	old := &PressureState{
		Mode:   ModeNormal,
		Levels: map[Dimension]Level{DimCPU: LevelOK, DimMEM: LevelOK, DimIO: LevelOK, DimNET: LevelOK},
	}
	new := &PressureState{
		Mode:   ModeNormal,
		Levels: map[Dimension]Level{DimCPU: LevelOK, DimMEM: LevelOK, DimIO: LevelOK, DimNET: LevelOK},
	}

	if sm.stateChanged(old, new) {
		t.Error("stateChanged should return false when nothing changed")
	}
}

// =============================================================================
// Concurrency
// =============================================================================

func TestStateMachineConcurrency(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	var wg sync.WaitGroup

	// Writers
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func(n int) {
			defer wg.Done()
			for j := 0; j < 50; j++ {
				scores := allOKScores()
				scores[DimCPU] = float64(n*10 + j)
				sm.Update(scores)
			}
		}(i)
	}

	// Readers
	for i := 0; i < 10; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for j := 0; j < 50; j++ {
				_ = sm.GetState()
				_ = sm.GetMode()
				_ = sm.GetLevel(DimCPU)
				_ = sm.GetScore(DimMEM)
				_ = sm.GetModeDuration()
				_ = sm.IsStable()
			}
		}()
	}

	wg.Wait()
}

// =============================================================================
// Full Lifecycle: NORMAL -> DEGRADED -> SURVIVAL -> DEGRADED -> NORMAL
// =============================================================================

func TestFullLifecycle(t *testing.T) {
	cfg := testConfig()
	cfg.WarnExitDuration = 0
	cfg.CritExitDuration = 0
	sm := NewStateMachine(cfg)

	modeChanges := []Mode{}
	sm.SetOnModeChange(func(old, new Mode) {
		modeChanges = append(modeChanges, new)
	})

	// Step 1: NORMAL
	state := sm.Update(allOKScores())
	if state.Mode != ModeNormal {
		t.Errorf("step 1: mode = %q, want normal", state.Mode)
	}

	// Step 2: CPU goes to WARN -> DEGRADED
	scores := allOKScores()
	scores[DimCPU] = 65
	state = sm.Update(scores)
	if state.Mode != ModeDegraded {
		t.Errorf("step 2: mode = %q, want degraded", state.Mode)
	}

	// Step 3: CPU goes CRITICAL -> SURVIVAL
	scores[DimCPU] = 85
	state = sm.Update(scores)
	if state.Mode != ModeSurvival {
		t.Errorf("step 3: mode = %q, want survival", state.Mode)
	}

	// Step 4: CPU drops to WARN range -> DEGRADED
	scores[DimCPU] = 65
	state = sm.Update(scores)
	if state.Mode != ModeDegraded {
		t.Errorf("step 4: mode = %q, want degraded", state.Mode)
	}

	// Step 5: CPU drops to OK -> NORMAL
	scores[DimCPU] = 30
	state = sm.Update(scores)
	if state.Mode != ModeNormal {
		t.Errorf("step 5: mode = %q, want normal", state.Mode)
	}

	expectedModes := []Mode{ModeDegraded, ModeSurvival, ModeDegraded, ModeNormal}
	if len(modeChanges) != len(expectedModes) {
		t.Fatalf("mode changes = %d, want %d: %v", len(modeChanges), len(expectedModes), modeChanges)
	}
	for i, m := range expectedModes {
		if modeChanges[i] != m {
			t.Errorf("mode change %d = %q, want %q", i, modeChanges[i], m)
		}
	}
}

// =============================================================================
// Multiple dimensions
// =============================================================================

func TestMultipleDimensionsIndependent(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	scores := allOKScores()
	scores[DimCPU] = 65 // WARN
	scores[DimMEM] = 85 // CRITICAL
	scores[DimIO] = 30  // OK
	scores[DimNET] = 55 // OK (below 60)

	state := sm.Update(scores)

	if state.Levels[DimCPU] != LevelWarn {
		t.Errorf("CPU level = %q, want warn", state.Levels[DimCPU])
	}
	if state.Levels[DimMEM] != LevelCritical {
		t.Errorf("MEM level = %q, want critical", state.Levels[DimMEM])
	}
	if state.Levels[DimIO] != LevelOK {
		t.Errorf("IO level = %q, want ok", state.Levels[DimIO])
	}
	if state.Levels[DimNET] != LevelOK {
		t.Errorf("NET level = %q, want ok", state.Levels[DimNET])
	}
	if state.Mode != ModeSurvival {
		t.Errorf("mode = %q, want survival", state.Mode)
	}
}

// =============================================================================
// Edge Cases
// =============================================================================

func TestUpdate_ExactThresholdBoundaries(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	tests := []struct {
		name  string
		score float64
		want  Level
	}{
		{"exactly at warn enter", 60, LevelWarn},
		{"just below warn enter", 59.99, LevelOK},
		{"exactly at crit enter", 80, LevelCritical},
		{"just below crit enter", 79.99, LevelWarn}, // 79.99 >= WarnEnter(60) so it's WARN, not OK
	}

	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			sm2 := NewStateMachine(cfg)
			scores := allOKScores()
			scores[DimCPU] = tc.score
			state := sm2.Update(scores)
			if state.Levels[DimCPU] != tc.want {
				t.Errorf("CPU level = %q, want %q (score=%.2f)", state.Levels[DimCPU], tc.want, tc.score)
			}
		})
	}
	_ = sm // silence unused
}

func TestUpdate_ModeEnteredAtUpdatesOnChange(t *testing.T) {
	cfg := testConfig()
	sm := NewStateMachine(cfg)

	// Get initial state
	state1 := sm.Update(allOKScores())
	enteredAt1 := state1.ModeEnteredAt

	time.Sleep(2 * time.Millisecond)

	// No mode change -> ModeEnteredAt stays the same
	state2 := sm.Update(allOKScores())
	// The actual ModeEnteredAt for the internal state should not change
	// (though the returned copy reflects the state at Update time)
	if state2.Mode != ModeNormal {
		t.Errorf("mode should still be normal")
	}

	// Trigger mode change
	scores := allOKScores()
	scores[DimCPU] = 65
	state3 := sm.Update(scores)

	if !state3.ModeEnteredAt.After(enteredAt1) {
		t.Error("ModeEnteredAt should update on mode change")
	}
	if state3.ModeDuration != 0 {
		t.Errorf("ModeDuration = %v, want 0 after mode change", state3.ModeDuration)
	}
}
