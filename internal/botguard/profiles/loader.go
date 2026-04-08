// =============================================================================
// NFTBan v1.79.0 - HTTP Bot Guard: Profile Loader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: profiles
// Purpose: Load and manage YAML profiles for BotGuard v2
//
// meta:name="botguard_profiles_loader"
// meta:type="package"
// meta:version="1.79.0"
// meta:package="profiles"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-08"
// meta:description="Profile loader for v2 BotGuard YAML configuration"
//
// NOTE: All v1.79 features are DISABLED by default.
// Loader returns empty results unless feature flags enabled.
//
// meta:inventory.files="loader.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package profiles

import (
	"fmt"
	"os"
	"path/filepath"
	"sync"

	"gopkg.in/yaml.v3"

	"github.com/itcmsgr/nftban/internal/botguard"
)

// ProfileLoader manages loading and caching of profile YAML files.
type ProfileLoader struct {
	profilesDir string
	cache       map[string]*Profile
	mu          sync.RWMutex
}

// NewProfileLoader creates a new loader for the given profiles directory.
func NewProfileLoader(dir string) *ProfileLoader {
	return &ProfileLoader{
		profilesDir: dir,
		cache:       make(map[string]*Profile),
	}
}

// LoadActiveProfiles loads the specified profiles and returns a rule registry.
// If features are disabled, returns an empty registry.
func (pl *ProfileLoader) LoadActiveProfiles(names []string, features botguard.FeatureFlags) (*RuleRegistry, LoadResult) {
	result := LoadResult{
		Loaded: make([]ProfileMetadata, 0),
		Failed: make([]string, 0),
		Errors: make([]error, 0),
	}

	// Feature flag check - return empty if disabled
	if !features.IsProfileActive() {
		return NewRuleRegistry(), result
	}

	registry := NewRuleRegistry()

	for _, name := range names {
		profile, err := pl.loadProfile(name)
		if err != nil {
			result.Failed = append(result.Failed, name)
			result.Errors = append(result.Errors, fmt.Errorf("failed to load profile %s: %w", name, err))
			continue
		}

		// Handle inheritance
		for _, parent := range profile.Inherits {
			parentProfile, err := pl.loadProfile(parent)
			if err != nil {
				result.Errors = append(result.Errors, fmt.Errorf("failed to load inherited profile %s: %w", parent, err))
				continue
			}
			registry.AddRules(parentProfile.Rules)
		}

		// Add this profile's rules
		registry.AddRules(profile.Rules)
		registry.AddSafePaths(profile.SafePaths)

		result.Loaded = append(result.Loaded, ProfileMetadata{
			Name:         profile.Name,
			Version:      profile.Version,
			Path:         filepath.Join(pl.profilesDir, name+".yaml"),
			RuleCount:    len(profile.Rules),
			Inherits:     profile.Inherits,
			AlwaysActive: profile.AlwaysActive,
		})
	}

	result.RuleCount = registry.RuleCount()
	return registry, result
}

// loadProfile loads a single profile from disk, using cache if available.
func (pl *ProfileLoader) loadProfile(name string) (*Profile, error) {
	pl.mu.RLock()
	if cached, ok := pl.cache[name]; ok {
		pl.mu.RUnlock()
		return cached, nil
	}
	pl.mu.RUnlock()

	// Load from disk
	// profilesDir is a configured system path, name comes from validated config
	path := filepath.Join(pl.profilesDir, name+".yaml")
	data, err := os.ReadFile(path) // #nosec G304 -- controlled path from config
	if err != nil {
		return nil, fmt.Errorf("read profile file: %w", err)
	}

	var profile Profile
	if err := yaml.Unmarshal(data, &profile); err != nil {
		return nil, fmt.Errorf("parse profile YAML: %w", err)
	}

	// Validate profile
	if profile.Name == "" {
		profile.Name = name
	}

	// Cache the loaded profile
	pl.mu.Lock()
	pl.cache[name] = &profile
	pl.mu.Unlock()

	return &profile, nil
}

// ClearCache clears the profile cache, forcing reload on next access.
func (pl *ProfileLoader) ClearCache() {
	pl.mu.Lock()
	pl.cache = make(map[string]*Profile)
	pl.mu.Unlock()
}

// ListAvailable returns the names of available profile files.
func (pl *ProfileLoader) ListAvailable() ([]string, error) {
	entries, err := os.ReadDir(pl.profilesDir)
	if err != nil {
		if os.IsNotExist(err) {
			return []string{}, nil
		}
		return nil, err
	}

	var names []string
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		if filepath.Ext(name) == ".yaml" || filepath.Ext(name) == ".yml" {
			names = append(names, name[:len(name)-len(filepath.Ext(name))])
		}
	}
	return names, nil
}
