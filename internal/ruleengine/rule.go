// =============================================================================
// NFTBan - Event Rule Engine: Rule Definition
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="ruleengine-rule"
// meta:type="package"
// meta:version="1.93.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Rule grammar for semantic/behavioral event matching"
// meta:inventory.files="/etc/nftban/rules.d/*.rules"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ruleengine

import (
	"strings"
	"time"
)

// Rule defines a single matching rule.
type Rule struct {
	ID        string            `yaml:"id" json:"id"`
	Name      string            `yaml:"name" json:"name"`
	Match     RuleMatch         `yaml:"match" json:"match"`
	Threshold *RuleThreshold    `yaml:"threshold,omitempty" json:"threshold,omitempty"`
	Score     int               `yaml:"score" json:"score"`
	Action    string            `yaml:"action" json:"action"` // observe, score, ban_short, ban_long, ban_permanent
}

// RuleMatch defines the event matching criteria.
type RuleMatch struct {
	EventType string            `yaml:"event_type,omitempty" json:"event_type,omitempty"`
	Category  string            `yaml:"category,omitempty" json:"category,omitempty"`
	Service   string            `yaml:"service,omitempty" json:"service,omitempty"`
	Metadata  map[string]FieldMatch `yaml:"metadata,omitempty" json:"metadata,omitempty"`
}

// FieldMatch defines how a single field is matched.
type FieldMatch struct {
	Exact    string `yaml:"exact,omitempty" json:"exact,omitempty"`
	Contains string `yaml:"contains,omitempty" json:"contains,omitempty"`
	Prefix   string `yaml:"prefix,omitempty" json:"prefix,omitempty"`
}

// RuleThreshold defines count-over-time-window thresholds.
type RuleThreshold struct {
	Count  int           `yaml:"count" json:"count"`
	Window time.Duration `yaml:"window" json:"window"`
	Per    string        `yaml:"per" json:"per"` // "src_ip" (always per source IP)
}

// RulePack is a collection of rules loaded from a .rules file.
type RulePack struct {
	Name  string `yaml:"name" json:"name"`
	Rules []Rule `yaml:"rules" json:"rules"`
}

// Matches checks if an event matches this rule's criteria.
// This is pure field matching — no payload inspection (INV-S-012).
func (r *Rule) Matches(e *Event) bool {
	m := r.Match

	if m.EventType != "" && m.EventType != e.EventType {
		return false
	}
	if m.Category != "" && m.Category != e.Category {
		return false
	}
	if m.Service != "" && m.Service != e.Service {
		return false
	}

	for key, fm := range m.Metadata {
		val, ok := e.Metadata[key]
		if !ok {
			return false
		}
		if !fm.matches(val) {
			return false
		}
	}

	return true
}

func (fm *FieldMatch) matches(val string) bool {
	if fm.Exact != "" {
		return val == fm.Exact
	}
	if fm.Contains != "" {
		return strings.Contains(strings.ToLower(val), strings.ToLower(fm.Contains))
	}
	if fm.Prefix != "" {
		return strings.HasPrefix(strings.ToLower(val), strings.ToLower(fm.Prefix))
	}
	return true // no criteria = match all
}

// Action constants
const (
	ActionObserve      = "observe"
	ActionScore        = "score"
	ActionBanShort     = "ban_short"
	ActionBanLong      = "ban_long"
	ActionBanPermanent = "ban_permanent"
)
