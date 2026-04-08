// =============================================================================
// NFTBan v1.79.0 - HTTP Bot Guard: Feature Flags
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Feature flags for gradual v2 activation
//
// meta:name="botguard_features"
// meta:type="package"
// meta:version="1.79.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-08"
// meta:description="Feature flags for v2 profile-based BotGuard"
//
// All v1.79 features are DISABLED by default.
// Activation happens in v1.80+ via config:
//
//   HTTP_BOTGUARD_FEATURE_SCORING="true"
//   HTTP_BOTGUARD_FEATURE_PROFILES="true"
//   etc.
//
// meta:inventory.files="features.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

// FeatureFlags controls which v2 features are active.
// All flags default to false in v1.79.
type FeatureFlags struct {
	// Scoring enables the v2 scoring engine.
	// When false, classic rate-based classification is used.
	Scoring bool

	// Profiles enables YAML profile loading.
	// When false, no profiles are loaded and path scoring is skipped.
	Profiles bool

	// Pressure enables pressure-based threshold adjustments.
	// When false, thresholds are static regardless of traffic.
	Pressure bool

	// Prefix enables /24 (v4) and /64 (v6) prefix tracking.
	// When false, only per-IP tracking is used.
	Prefix bool

	// PathScoring enables rule-based path scoring.
	// When false, only rate signals contribute to score.
	PathScoring bool

	// Distributed enables distributed attack detection signals.
	// When false, distributed patterns are not tracked.
	Distributed bool
}

// DefaultFeatures returns the v1.79 defaults (all disabled).
func DefaultFeatures() FeatureFlags {
	return FeatureFlags{
		Scoring:     false,
		Profiles:    false,
		Pressure:    false,
		Prefix:      false,
		PathScoring: false,
		Distributed: false,
	}
}

// IsEnabled returns true if any advanced feature is enabled.
// Used for fast-path checks to skip v2 logic entirely.
func (f FeatureFlags) IsEnabled() bool {
	return f.Scoring || f.Profiles || f.Pressure ||
		f.Prefix || f.PathScoring || f.Distributed
}

// IsScoringActive returns true if the scoring engine should run.
// Requires both Scoring flag and at least one input source.
func (f FeatureFlags) IsScoringActive() bool {
	return f.Scoring && (f.PathScoring || f.Pressure || f.Prefix)
}

// IsProfileActive returns true if profile loading should occur.
func (f FeatureFlags) IsProfileActive() bool {
	return f.Profiles && f.PathScoring
}

// GroupMode controls how a rule group behaves.
type GroupMode string

const (
	// GroupModeProtect scores and enforces rules in this group.
	GroupModeProtect GroupMode = "protect"

	// GroupModeMonitor scores but does not enforce (logging only).
	GroupModeMonitor GroupMode = "monitor"

	// GroupModeExempt exempts matching requests from scoring.
	GroupModeExempt GroupMode = "exempt"

	// GroupModeAggressive uses stricter thresholds for this group.
	GroupModeAggressive GroupMode = "aggressive"

	// GroupModeDisabled completely disables this group.
	GroupModeDisabled GroupMode = "disabled"
)

// GroupConfig configures behavior for a rule group.
type GroupConfig struct {
	Mode       GroupMode // How to handle rules in this group
	Multiplier float64   // Score multiplier (1.0 = normal)
}

// DefaultGroupConfigs returns the default configuration for all groups.
// These can be overridden by config.
func DefaultGroupConfigs() map[RuleGroup]GroupConfig {
	return map[RuleGroup]GroupConfig{
		GroupAuth:     {Mode: GroupModeProtect, Multiplier: 1.0},
		GroupRPC:      {Mode: GroupModeMonitor, Multiplier: 1.0}, // Monitor by default
		GroupEnum:     {Mode: GroupModeProtect, Multiplier: 1.0},
		GroupCommerce: {Mode: GroupModeExempt, Multiplier: 1.0},  // Exempt by default
		GroupHeavy:    {Mode: GroupModeProtect, Multiplier: 1.0},
		GroupProbe:    {Mode: GroupModeProtect, Multiplier: 2.0}, // 2x multiplier
		GroupEvasion:  {Mode: GroupModeAggressive, Multiplier: 2.0},
		GroupGeneric:  {Mode: GroupModeProtect, Multiplier: 1.0},
	}
}

// V2Config holds all v2-specific configuration.
// This is populated from config files when feature flags are enabled.
type V2Config struct {
	Features    FeatureFlags
	Thresholds  ScoreThresholds
	Decay       ScoreDecay
	Pressure    PressureConfig
	Groups      map[RuleGroup]GroupConfig
	ProfilesDir string
	ActiveProfiles []string
}

// DefaultV2Config returns the default v2 configuration.
// All features disabled, conservative defaults.
func DefaultV2Config() V2Config {
	return V2Config{
		Features:       DefaultFeatures(),
		Thresholds:     DefaultScoreThresholds(),
		Decay:          DefaultScoreDecay(),
		Pressure:       DefaultPressureConfig(),
		Groups:         DefaultGroupConfigs(),
		ProfilesDir:    "/etc/nftban/conf.d/botguard/profiles",
		ActiveProfiles: []string{"generic"},
	}
}
