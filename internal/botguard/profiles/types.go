// =============================================================================
// NFTBan v1.79.0 - HTTP Bot Guard: Profile Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: profiles
// Purpose: Profile and rule types for YAML-based configuration
//
// meta:name="botguard_profiles_types"
// meta:type="package"
// meta:version="1.79.0"
// meta:package="profiles"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-08"
// meta:description="Profile types for v2 BotGuard YAML configuration"
//
// NOTE: All v1.79 features are DISABLED by default.
// Profiles are loaded but not active unless feature flags enabled.
//
// meta:inventory.files="types.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package profiles

import (
	"github.com/itcmsgr/nftban/internal/botguard"
)

// Profile defines a set of detection rules for a specific application or use case.
// Profiles are loaded from YAML files in /etc/nftban/conf.d/botguard/profiles/.
type Profile struct {
	// Name is the profile identifier (e.g., "wordpress", "generic").
	Name string `yaml:"profile"`

	// Version is the profile schema version.
	Version string `yaml:"version"`

	// Description explains what this profile protects.
	Description string `yaml:"description"`

	// Inherits lists parent profiles whose rules are included.
	// Rules from inherited profiles run before this profile's rules.
	Inherits []string `yaml:"inherits"`

	// AlwaysActive means this profile runs for all requests.
	// If false, profile must be explicitly enabled in config.
	AlwaysActive bool `yaml:"always_active"`

	// Rules are the detection patterns for this profile.
	Rules []botguard.Rule `yaml:"rules"`

	// SafePaths are paths that should never be scored by this profile.
	// Useful for exempting known-good endpoints.
	SafePaths []string `yaml:"safe_paths"`
}

// ProfileFile is the top-level structure of a profile YAML file.
type ProfileFile struct {
	Profile Profile `yaml:"profile"`
}

// ProfileMetadata contains information about a loaded profile.
type ProfileMetadata struct {
	Name        string   // Profile name
	Version     string   // Profile version
	Path        string   // File path where loaded from
	RuleCount   int      // Number of rules in profile
	Inherits    []string // Parent profiles
	AlwaysActive bool    // Whether profile is always active
}

// LoadResult contains the outcome of loading profiles.
type LoadResult struct {
	Loaded   []ProfileMetadata // Successfully loaded profiles
	Failed   []string          // Profile names that failed to load
	Errors   []error           // Errors encountered during loading
	RuleCount int              // Total rules across all profiles
}

// MatchResult contains the outcome of matching a request against rules.
type MatchResult struct {
	Matched bool             // Whether any rule matched
	Rules   []botguard.Rule  // Rules that matched
	Signals []botguard.Signal // Signals generated from matches
	Exempt  bool             // Whether request is exempted from further scoring
}
