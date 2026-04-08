// =============================================================================
// NFTBan v1.79.0 - HTTP Bot Guard: Scoring Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Scoring engine types for profile-based BotGuard (v2)
//
// meta:name="botguard_scoring_types"
// meta:type="package"
// meta:version="1.79.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-08"
// meta:description="Scoring types for v2 profile-based BotGuard"
//
// NOTE: All v1.79 features are DISABLED by default.
// This file ships the types; activation happens in v1.80+.
//
// meta:inventory.files="scoring_types.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"net/netip"
	"time"
)

// IPScore tracks the accumulated score and signal history for an IP.
// This is the v2 scoring structure used when feature flags are enabled.
type IPScore struct {
	IP          netip.Addr         // IP address
	TotalScore  int                // Current accumulated score
	RuleHits    map[string]int     // Count of hits per rule ID
	GroupScores map[RuleGroup]int  // Score contribution per group
	Signals     []Signal           // Recent signals (bounded buffer)
	State       IPState            // Current classification state
	FirstSeen   time.Time          // When first observed
	LastSeen    time.Time          // Last activity time
	WindowStart time.Time          // Start of current scoring window
	ExpiresAt   time.Time          // When score expires (decay complete)
	HighWaterMark int              // Peak score in current window
	StateHeldUntil time.Time       // Minimum time to hold current state
}

// NewIPScore creates a new IPScore for the given IP.
func NewIPScore(ip netip.Addr) *IPScore {
	now := time.Now()
	return &IPScore{
		IP:          ip,
		TotalScore:  0,
		RuleHits:    make(map[string]int),
		GroupScores: make(map[RuleGroup]int),
		Signals:     make([]Signal, 0, 100), // Pre-allocate for efficiency
		State:       StateUnknown,
		FirstSeen:   now,
		LastSeen:    now,
		WindowStart: now,
	}
}

// AddSignal adds a signal to the IP's score tracking.
func (s *IPScore) AddSignal(sig Signal) {
	s.TotalScore += sig.Score
	s.LastSeen = sig.Timestamp

	if sig.Rule != nil {
		s.RuleHits[sig.Rule.ID]++
		s.GroupScores[sig.Rule.Group] += sig.Score
	}

	// Track high water mark
	if s.TotalScore > s.HighWaterMark {
		s.HighWaterMark = s.TotalScore
	}

	// Bounded signal buffer (keep last 100)
	if len(s.Signals) >= 100 {
		s.Signals = s.Signals[1:]
	}
	s.Signals = append(s.Signals, sig)
}

// ScoringResult represents the outcome of a scoring evaluation.
type ScoringResult struct {
	IP        netip.Addr  // IP that was evaluated
	OldScore  int         // Score before this evaluation
	NewScore  int         // Score after this evaluation
	OldState  IPState     // State before this evaluation
	NewState  IPState     // State after this evaluation
	Changed   bool        // Whether state changed
	TopRules  []string    // Top contributing rule IDs
	TopGroups []RuleGroup // Top contributing groups
	Reason    string      // Human-readable reason for decision
}

// ScoreDecay configures how scores decay over time.
// Decay is applied per-tick by the scoring engine.
type ScoreDecay struct {
	// Window is the scoring window duration.
	// Scores older than this are fully decayed.
	Window time.Duration

	// DecayRate is the per-tick decay multiplier (0.0-1.0).
	// Example: 0.1 means 10% decay per tick.
	DecayRate float64

	// HighSeverityHoldTime prevents decay for high-severity events.
	// If an IP hit a high-severity rule, decay is paused for this duration.
	HighSeverityHoldTime time.Duration

	// MinimumStateHoldTime prevents rapid state oscillation.
	// IP must stay in a state for at least this long before transitioning.
	MinimumStateHoldTime time.Duration

	// FloorScore is the minimum score after decay.
	// Prevents full decay for IPs with recent activity.
	FloorScore int
}

// DefaultScoreDecay returns the default decay configuration.
// These values can be overridden by config.
func DefaultScoreDecay() ScoreDecay {
	return ScoreDecay{
		Window:               5 * time.Minute,
		DecayRate:            0.1,
		HighSeverityHoldTime: 10 * time.Minute,
		MinimumStateHoldTime: 60 * time.Second,
		FloorScore:           10,
	}
}

// ScoreThresholds defines the score boundaries for state transitions.
type ScoreThresholds struct {
	// Suspect is the score at which an IP becomes a suspect.
	// Below this, IP is UNKNOWN.
	Suspect int

	// Grey is the score at which an IP is throttled.
	Grey int

	// Ban is the score at which an IP is banned.
	Ban int

	// Emergency is the score at which an IP is emergency-blocked.
	Emergency int
}

// DefaultScoreThresholds returns the default threshold configuration.
func DefaultScoreThresholds() ScoreThresholds {
	return ScoreThresholds{
		Suspect:   20,
		Grey:      40,
		Ban:       70,
		Emergency: 90,
	}
}

// EvaluateState determines the appropriate state for a given score.
func (t ScoreThresholds) EvaluateState(score int) IPState {
	switch {
	case score >= t.Emergency:
		return StateEmergency
	case score >= t.Ban:
		return StateBan
	case score >= t.Grey:
		return StateGrey
	case score >= t.Suspect:
		return StatePending
	default:
		return StateUnknown
	}
}

// PressureLevel represents the server-wide traffic pressure state.
type PressureLevel int

const (
	// PressureNormal indicates normal traffic levels.
	PressureNormal PressureLevel = iota

	// PressureElevated indicates above-normal traffic (defensive adjustments).
	PressureElevated

	// PressureCritical indicates attack-level traffic (aggressive defense).
	PressureCritical
)

// String returns the pressure level as a string.
func (p PressureLevel) String() string {
	switch p {
	case PressureNormal:
		return "normal"
	case PressureElevated:
		return "elevated"
	case PressureCritical:
		return "critical"
	default:
		return "unknown"
	}
}

// PressureConfig configures pressure-based threshold adjustments.
type PressureConfig struct {
	// Enabled controls whether pressure adjustments are active.
	Enabled bool

	// ElevatedRPS is the requests-per-second threshold for elevated pressure.
	ElevatedRPS int

	// CriticalRPS is the requests-per-second threshold for critical pressure.
	CriticalRPS int

	// Multiplier adjusts thresholds during elevated pressure.
	// Example: 1.5 makes thresholds 50% stricter.
	Multiplier float64
}

// DefaultPressureConfig returns the default pressure configuration.
func DefaultPressureConfig() PressureConfig {
	return PressureConfig{
		Enabled:     false, // Disabled by default in v1.79
		ElevatedRPS: 150,
		CriticalRPS: 500,
		Multiplier:  1.5,
	}
}
