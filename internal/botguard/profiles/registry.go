// =============================================================================
// NFTBan v1.79.0 - HTTP Bot Guard: Rule Registry
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: profiles
// Purpose: Compiled rule registry for efficient matching
//
// meta:name="botguard_profiles_registry"
// meta:type="package"
// meta:version="1.79.0"
// meta:package="profiles"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-08"
// meta:description="Rule registry for v2 BotGuard pattern matching"
//
// NOTE: All v1.79 features are DISABLED by default.
// Registry exists but matching is skipped unless feature flags enabled.
//
// meta:inventory.files="registry.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package profiles

import (
	"regexp"
	"sync"

	"github.com/itcmsgr/nftban/internal/botguard"
)

// RuleRegistry holds compiled rules for efficient matching.
type RuleRegistry struct {
	rules     []botguard.Rule
	byID      map[string]*botguard.Rule
	byGroup   map[botguard.RuleGroup][]botguard.Rule
	safePaths []*regexp.Regexp
	compiled  map[string]*regexp.Regexp
	mu        sync.RWMutex
}

// NewRuleRegistry creates an empty rule registry.
func NewRuleRegistry() *RuleRegistry {
	return &RuleRegistry{
		rules:     make([]botguard.Rule, 0),
		byID:      make(map[string]*botguard.Rule),
		byGroup:   make(map[botguard.RuleGroup][]botguard.Rule),
		safePaths: make([]*regexp.Regexp, 0),
		compiled:  make(map[string]*regexp.Regexp),
	}
}

// AddRules adds rules to the registry, compiling patterns as needed.
func (r *RuleRegistry) AddRules(rules []botguard.Rule) {
	r.mu.Lock()
	defer r.mu.Unlock()

	for _, rule := range rules {
		// Skip if already registered (by ID)
		if _, exists := r.byID[rule.ID]; exists {
			continue
		}

		// Compile pattern
		if rule.Pattern != "" {
			re, err := regexp.Compile(rule.Pattern)
			if err == nil {
				r.compiled[rule.ID] = re
			}
			// Note: Invalid patterns are silently skipped
			// Could add error logging here
		}

		// Store rule
		ruleCopy := rule
		r.rules = append(r.rules, ruleCopy)
		r.byID[rule.ID] = &r.rules[len(r.rules)-1]

		// Index by group
		r.byGroup[rule.Group] = append(r.byGroup[rule.Group], ruleCopy)
	}
}

// AddSafePaths adds safe path patterns to the registry.
func (r *RuleRegistry) AddSafePaths(patterns []string) {
	r.mu.Lock()
	defer r.mu.Unlock()

	for _, pattern := range patterns {
		re, err := regexp.Compile(pattern)
		if err == nil {
			r.safePaths = append(r.safePaths, re)
		}
	}
}

// RuleCount returns the total number of rules in the registry.
func (r *RuleRegistry) RuleCount() int {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return len(r.rules)
}

// GetRule returns a rule by ID, or nil if not found.
func (r *RuleRegistry) GetRule(id string) *botguard.Rule {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.byID[id]
}

// GetRulesByGroup returns all rules for a given group.
func (r *RuleRegistry) GetRulesByGroup(group botguard.RuleGroup) []botguard.Rule {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.byGroup[group]
}

// IsSafePath returns true if the path matches any safe path pattern.
func (r *RuleRegistry) IsSafePath(path string) bool {
	r.mu.RLock()
	defer r.mu.RUnlock()

	for _, re := range r.safePaths {
		if re.MatchString(path) {
			return true
		}
	}
	return false
}

// AllRules returns a copy of all rules in the registry.
func (r *RuleRegistry) AllRules() []botguard.Rule {
	r.mu.RLock()
	defer r.mu.RUnlock()

	result := make([]botguard.Rule, len(r.rules))
	copy(result, r.rules)
	return result
}

// GetCompiledPattern returns the compiled regex for a rule ID.
func (r *RuleRegistry) GetCompiledPattern(ruleID string) *regexp.Regexp {
	r.mu.RLock()
	defer r.mu.RUnlock()
	return r.compiled[ruleID]
}

// Groups returns all groups that have rules registered.
func (r *RuleRegistry) Groups() []botguard.RuleGroup {
	r.mu.RLock()
	defer r.mu.RUnlock()

	groups := make([]botguard.RuleGroup, 0, len(r.byGroup))
	for g := range r.byGroup {
		groups = append(groups, g)
	}
	return groups
}
