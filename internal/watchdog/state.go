// =============================================================================
// NFTBan v1.0 - Watchdog State Machine
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="state"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Manages pressure state transitions with hysteresis to prevent flapping"
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
	"time"
)

// StateMachine manages pressure state transitions
type StateMachine struct {
	config *Config

	mu sync.RWMutex

	// Current state
	current *PressureState

	// Hysteresis tracking per dimension
	levelEntryTime    map[Dimension]time.Time
	belowThresholdAt  map[Dimension]time.Time

	// Mode transition tracking
	modeEntryTime time.Time

	// Event callback
	onStateChange func(old, new *PressureState)
	onModeChange  func(old, new Mode)
}

// NewStateMachine creates a new state machine
func NewStateMachine(cfg *Config) *StateMachine {
	state := NewPressureState()

	return &StateMachine{
		config:           cfg,
		current:          state,
		levelEntryTime:   make(map[Dimension]time.Time),
		belowThresholdAt: make(map[Dimension]time.Time),
		modeEntryTime:    time.Now(),
	}
}

// SetOnStateChange sets the callback for state changes
func (sm *StateMachine) SetOnStateChange(cb func(old, new *PressureState)) {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	sm.onStateChange = cb
}

// SetOnModeChange sets the callback for mode changes
func (sm *StateMachine) SetOnModeChange(cb func(old, new Mode)) {
	sm.mu.Lock()
	defer sm.mu.Unlock()
	sm.onModeChange = cb
}

// Update processes new scores and updates state
func (sm *StateMachine) Update(scores map[Dimension]float64) *PressureState {
	sm.mu.Lock()
	defer sm.mu.Unlock()

	now := time.Now()

	// Copy current state for comparison
	oldState := sm.copyState()
	oldMode := sm.current.Mode

	// Update timestamp
	sm.current.Timestamp = now
	sm.current.ModeDuration = now.Sub(sm.current.ModeEnteredAt)

	// Update scores and evaluate levels with hysteresis
	for _, dim := range AllDimensions() {
		score := scores[dim]
		sm.current.Scores[dim] = score

		newLevel := sm.evaluateLevelWithHysteresis(dim, score, now)
		sm.current.Levels[dim] = newLevel
	}

	// Determine new mode from worst level
	sm.current.Mode = sm.deriveMode()

	// Check for mode change
	if sm.current.Mode != oldMode {
		sm.current.ModeEnteredAt = now
		sm.current.ModeDuration = 0
		sm.modeEntryTime = now

		if sm.onModeChange != nil {
			sm.onModeChange(oldMode, sm.current.Mode)
		}
	}

	// Check for state change callback
	if sm.stateChanged(oldState, sm.current) && sm.onStateChange != nil {
		sm.onStateChange(oldState, sm.copyState())
	}

	return sm.copyState()
}

// evaluateLevelWithHysteresis applies hysteresis rules to determine level
func (sm *StateMachine) evaluateLevelWithHysteresis(dim Dimension, score float64, now time.Time) Level {
	currentLevel := sm.current.Levels[dim]

	switch currentLevel {
	case LevelOK:
		// Can only go up
		if score >= sm.config.HysteresisCritEnter {
			sm.levelEntryTime[dim] = now
			delete(sm.belowThresholdAt, dim)
			return LevelCritical
		}
		if score >= sm.config.HysteresisWarnEnter {
			sm.levelEntryTime[dim] = now
			delete(sm.belowThresholdAt, dim)
			return LevelWarn
		}
		return LevelOK

	case LevelWarn:
		// Can go up to CRITICAL or down to OK
		if score >= sm.config.HysteresisCritEnter {
			sm.levelEntryTime[dim] = now
			delete(sm.belowThresholdAt, dim)
			return LevelCritical
		}

		// Check for exit condition (below threshold for duration)
		if score < sm.config.HysteresisWarnExit {
			if _, exists := sm.belowThresholdAt[dim]; !exists {
				sm.belowThresholdAt[dim] = now
			}
			if now.Sub(sm.belowThresholdAt[dim]) >= sm.config.WarnExitDuration {
				delete(sm.belowThresholdAt, dim)
				return LevelOK
			}
		} else {
			delete(sm.belowThresholdAt, dim)
		}
		return LevelWarn

	case LevelCritical:
		// Can only go down
		if score < sm.config.HysteresisCritExit {
			if _, exists := sm.belowThresholdAt[dim]; !exists {
				sm.belowThresholdAt[dim] = now
			}
			if now.Sub(sm.belowThresholdAt[dim]) >= sm.config.CritExitDuration {
				delete(sm.belowThresholdAt, dim)
				// Drop to WARN, not OK (gradual recovery)
				if score >= sm.config.HysteresisWarnEnter {
					return LevelWarn
				}
				return LevelOK
			}
		} else {
			delete(sm.belowThresholdAt, dim)
		}
		return LevelCritical
	}

	return LevelOK
}

// deriveMode determines operating mode from worst dimension level
func (sm *StateMachine) deriveMode() Mode {
	for _, level := range sm.current.Levels {
		if level == LevelCritical {
			return ModeSurvival
		}
	}

	for _, level := range sm.current.Levels {
		if level == LevelWarn {
			return ModeDegraded
		}
	}

	return ModeNormal
}

// GetState returns a copy of the current state
func (sm *StateMachine) GetState() *PressureState {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return sm.copyState()
}

// GetMode returns the current operating mode
func (sm *StateMachine) GetMode() Mode {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return sm.current.Mode
}

// GetLevel returns the level for a specific dimension
func (sm *StateMachine) GetLevel(dim Dimension) Level {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return sm.current.Levels[dim]
}

// GetScore returns the score for a specific dimension
func (sm *StateMachine) GetScore(dim Dimension) float64 {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return sm.current.Scores[dim]
}

// GetModeDuration returns time in current mode
func (sm *StateMachine) GetModeDuration() time.Duration {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return time.Since(sm.modeEntryTime)
}

// GetLevelDuration returns time at current level for a dimension
func (sm *StateMachine) GetLevelDuration(dim Dimension) time.Duration {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	if entryTime, exists := sm.levelEntryTime[dim]; exists {
		return time.Since(entryTime)
	}
	return 0
}

// IsStable returns true if no dimension is transitioning
func (sm *StateMachine) IsStable() bool {
	sm.mu.RLock()
	defer sm.mu.RUnlock()
	return len(sm.belowThresholdAt) == 0
}

// copyState creates a deep copy of the current state
func (sm *StateMachine) copyState() *PressureState {
	copy := &PressureState{
		Timestamp:     sm.current.Timestamp,
		Scores:        make(map[Dimension]float64),
		Levels:        make(map[Dimension]Level),
		Mode:          sm.current.Mode,
		ModeEnteredAt: sm.current.ModeEnteredAt,
		ModeDuration:  sm.current.ModeDuration,
	}

	for dim, score := range sm.current.Scores {
		copy.Scores[dim] = score
	}
	for dim, level := range sm.current.Levels {
		copy.Levels[dim] = level
	}

	return copy
}

// stateChanged checks if state has meaningfully changed
func (sm *StateMachine) stateChanged(old, new *PressureState) bool {
	if old.Mode != new.Mode {
		return true
	}

	for _, dim := range AllDimensions() {
		if old.Levels[dim] != new.Levels[dim] {
			return true
		}
	}

	return false
}
