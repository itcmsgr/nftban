// =============================================================================
// NFTBan - Event Rule Engine: YAML Rule Loader
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="ruleengine-loader"
// meta:type="package"
// meta:version="1.93.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Loads rule packs from /etc/nftban/rules.d/*.yml"
// meta:inventory.files="/etc/nftban/rules.d/"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ruleengine

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"time"

	"gopkg.in/yaml.v3"
)

// ruleFileSchema is the on-disk YAML format for rule packs.
type ruleFileSchema struct {
	Name  string           `yaml:"name"`
	Rules []ruleYAMLSchema `yaml:"rules"`
}

type ruleYAMLSchema struct {
	ID    string `yaml:"id"`
	Name  string `yaml:"name"`
	Match struct {
		EventType string                       `yaml:"event_type,omitempty"`
		Category  string                       `yaml:"category,omitempty"`
		Service   string                       `yaml:"service,omitempty"`
		Metadata  map[string]fieldMatchYAML    `yaml:"metadata,omitempty"`
	} `yaml:"match"`
	Threshold *thresholdYAML `yaml:"threshold,omitempty"`
	Score     int            `yaml:"score"`
	Action    string         `yaml:"action"`
}

type fieldMatchYAML struct {
	Exact    string `yaml:"exact,omitempty"`
	Contains string `yaml:"contains,omitempty"`
	Prefix   string `yaml:"prefix,omitempty"`
}

type thresholdYAML struct {
	Count  int    `yaml:"count"`
	Window string `yaml:"window"` // "60s", "5m", etc.
	Per    string `yaml:"per"`
}

// LoadRulesFromDir loads all .yml rule packs from a directory.
// Returns the combined list of rules from all packs.
func LoadRulesFromDir(dir string) ([]Rule, error) {
	pattern := filepath.Join(dir, "*.yml")
	files, err := filepath.Glob(pattern)
	if err != nil {
		return nil, fmt.Errorf("glob %s: %w", pattern, err)
	}

	if len(files) == 0 {
		log.Printf("[ruleengine] no rule files found in %s", dir)
		return nil, nil
	}

	var allRules []Rule
	for _, f := range files {
		rules, err := loadRuleFile(f)
		if err != nil {
			log.Printf("[ruleengine] skip %s: %v", f, err)
			continue
		}
		allRules = append(allRules, rules...)
		log.Printf("[ruleengine] loaded %d rules from %s", len(rules), filepath.Base(f))
	}

	return allRules, nil
}

func loadRuleFile(path string) ([]Rule, error) {
	data, err := os.ReadFile(filepath.Clean(path)) // #nosec G304 -- paths from /etc/nftban/rules.d/ (trusted config dir)
	if err != nil {
		return nil, err
	}

	var schema ruleFileSchema
	if err := yaml.Unmarshal(data, &schema); err != nil {
		return nil, fmt.Errorf("parse %s: %w", filepath.Base(path), err)
	}

	var rules []Rule
	for _, rs := range schema.Rules {
		r := Rule{
			ID:     rs.ID,
			Name:   rs.Name,
			Score:  rs.Score,
			Action: rs.Action,
			Match: RuleMatch{
				EventType: rs.Match.EventType,
				Category:  rs.Match.Category,
				Service:   rs.Match.Service,
			},
		}

		// Convert metadata matches
		if len(rs.Match.Metadata) > 0 {
			r.Match.Metadata = make(map[string]FieldMatch)
			for k, v := range rs.Match.Metadata {
				r.Match.Metadata[k] = FieldMatch{
					Exact:    v.Exact,
					Contains: v.Contains,
					Prefix:   v.Prefix,
				}
			}
		}

		// Convert threshold
		if rs.Threshold != nil {
			window, err := time.ParseDuration(rs.Threshold.Window)
			if err != nil {
				log.Printf("[ruleengine] rule %s: invalid threshold window %q, skipping threshold", rs.ID, rs.Threshold.Window)
			} else {
				r.Threshold = &RuleThreshold{
					Count:  rs.Threshold.Count,
					Window: window,
					Per:    rs.Threshold.Per,
				}
			}
		}

		rules = append(rules, r)
	}

	return rules, nil
}
