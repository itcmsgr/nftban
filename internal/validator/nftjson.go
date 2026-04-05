// =============================================================================
// NFTBan v1.78 - nft JSON Output Parsing
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="validator-nftjson"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-05"
// meta:description="Parse nft -j list ruleset JSON output"
// meta:inventory.files="internal/validator/nftjson.go"
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package validator

import (
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"
)

// NftRuleset represents the top-level nft -j list ruleset output.
// The JSON structure is: { "nftables": [ {...}, {...}, ... ] }
type NftRuleset struct {
	Nftables []NftObject `json:"nftables"`
}

// NftObject is a wrapper for any nft object (table, chain, set, rule, etc.).
// Only one field will be populated per object.
type NftObject struct {
	Metainfo *NftMetainfo `json:"metainfo,omitempty"`
	Table    *NftTable    `json:"table,omitempty"`
	Chain    *NftChain    `json:"chain,omitempty"`
	Set      *NftSet      `json:"set,omitempty"`
	Rule     *NftRule     `json:"rule,omitempty"`
	Counter  *NftCounter  `json:"counter,omitempty"`
}

// NftMetainfo holds nft version info.
type NftMetainfo struct {
	Version    string `json:"version"`
	ReleaseName string `json:"release_name"`
	JsonSchemaVersion int `json:"json_schema_version"`
}

// NftTable represents an nftables table.
type NftTable struct {
	Family string `json:"family"`
	Name   string `json:"name"`
	Handle int    `json:"handle,omitempty"`
}

// NftChain represents an nftables chain.
type NftChain struct {
	Family   string `json:"family"`
	Table    string `json:"table"`
	Name     string `json:"name"`
	Type     string `json:"type,omitempty"`
	Hook     string `json:"hook,omitempty"`
	Priority int    `json:"prio,omitempty"`
	Policy   string `json:"policy,omitempty"`
	Handle   int    `json:"handle,omitempty"`
}

// NftSet represents an nftables set.
type NftSet struct {
	Family  string   `json:"family"`
	Table   string   `json:"table"`
	Name    string   `json:"name"`
	Type    string   `json:"type,omitempty"`
	Flags   []string `json:"flags,omitempty"`
	Timeout int      `json:"timeout,omitempty"`
	Handle  int      `json:"handle,omitempty"`
}

// NftRule represents an nftables rule.
type NftRule struct {
	Family  string        `json:"family"`
	Table   string        `json:"table"`
	Chain   string        `json:"chain"`
	Handle  int           `json:"handle,omitempty"`
	Comment string        `json:"comment,omitempty"`
	Expr    []interface{} `json:"expr,omitempty"`
}

// NftCounter represents a named counter.
type NftCounter struct {
	Family  string `json:"family"`
	Table   string `json:"table"`
	Name    string `json:"name"`
	Handle  int    `json:"handle,omitempty"`
	Packets int64  `json:"packets,omitempty"`
	Bytes   int64  `json:"bytes,omitempty"`
}

// LoadRulesetJSON executes nft -j list ruleset and parses the output.
// This is a PURE function - it only reads kernel state, never modifies.
func LoadRulesetJSON(ctx context.Context) (*NftRuleset, error) {
	// Create command with timeout
	if ctx == nil {
		var cancel context.CancelFunc
		ctx, cancel = context.WithTimeout(context.Background(), 30*time.Second)
		defer cancel()
	}

	cmd := exec.CommandContext(ctx, "nft", "-j", "list", "ruleset")
	output, err := cmd.Output()
	if err != nil {
		if exitErr, ok := err.(*exec.ExitError); ok {
			return nil, fmt.Errorf("nft command failed (exit %d): %s", exitErr.ExitCode(), string(exitErr.Stderr))
		}
		return nil, fmt.Errorf("nft command error: %w", err)
	}

	if len(output) == 0 {
		return nil, fmt.Errorf("nft returned empty output")
	}

	var ruleset NftRuleset
	if err := json.Unmarshal(output, &ruleset); err != nil {
		return nil, fmt.Errorf("failed to parse nft JSON: %w", err)
	}

	return &ruleset, nil
}

// RulesetDocument provides structured access to the parsed ruleset.
type RulesetDocument struct {
	raw      *NftRuleset
	tables   map[string]*NftTable   // key: "family:name"
	chains   map[string]*NftChain   // key: "family:table:name"
	sets     map[string]*NftSet     // key: "family:table:name"
	rules    map[string][]*NftRule  // key: "family:table:chain"
	counters map[string]*NftCounter // key: "family:table:name"
}

// ParseRuleset converts raw NftRuleset into a structured document.
func ParseRuleset(raw *NftRuleset) *RulesetDocument {
	doc := &RulesetDocument{
		raw:      raw,
		tables:   make(map[string]*NftTable),
		chains:   make(map[string]*NftChain),
		sets:     make(map[string]*NftSet),
		rules:    make(map[string][]*NftRule),
		counters: make(map[string]*NftCounter),
	}

	for i := range raw.Nftables {
		obj := &raw.Nftables[i]

		if obj.Table != nil {
			key := obj.Table.Family + ":" + obj.Table.Name
			doc.tables[key] = obj.Table
		}

		if obj.Chain != nil {
			key := obj.Chain.Family + ":" + obj.Chain.Table + ":" + obj.Chain.Name
			doc.chains[key] = obj.Chain
		}

		if obj.Set != nil {
			key := obj.Set.Family + ":" + obj.Set.Table + ":" + obj.Set.Name
			doc.sets[key] = obj.Set
		}

		if obj.Rule != nil {
			key := obj.Rule.Family + ":" + obj.Rule.Table + ":" + obj.Rule.Chain
			doc.rules[key] = append(doc.rules[key], obj.Rule)
		}

		if obj.Counter != nil {
			key := obj.Counter.Family + ":" + obj.Counter.Table + ":" + obj.Counter.Name
			doc.counters[key] = obj.Counter
		}
	}

	return doc
}

// TableExists checks if a table exists.
func (d *RulesetDocument) TableExists(family, name string) bool {
	key := family + ":" + name
	_, ok := d.tables[key]
	return ok
}

// ChainExists checks if a chain exists.
func (d *RulesetDocument) ChainExists(family, table, chain string) bool {
	key := family + ":" + table + ":" + chain
	_, ok := d.chains[key]
	return ok
}

// SetExists checks if a set exists.
func (d *RulesetDocument) SetExists(family, table, set string) bool {
	key := family + ":" + table + ":" + set
	_, ok := d.sets[key]
	return ok
}

// GetChains returns all chain names for a table.
func (d *RulesetDocument) GetChains(family, table string) []string {
	prefix := family + ":" + table + ":"
	var names []string
	for key := range d.chains {
		if strings.HasPrefix(key, prefix) {
			name := strings.TrimPrefix(key, prefix)
			names = append(names, name)
		}
	}
	return names
}

// GetSets returns all set names for a table.
func (d *RulesetDocument) GetSets(family, table string) []string {
	prefix := family + ":" + table + ":"
	var names []string
	for key := range d.sets {
		if strings.HasPrefix(key, prefix) {
			name := strings.TrimPrefix(key, prefix)
			names = append(names, name)
		}
	}
	return names
}

// GetRules returns all rules for a chain.
func (d *RulesetDocument) GetRules(family, table, chain string) []*NftRule {
	key := family + ":" + table + ":" + chain
	return d.rules[key]
}

// ExtractAnchorsFromChain extracts anchor names from rule comments in a chain.
// Anchors are identified by comments containing "NFTBAN_ANCHOR:ANCHOR_*".
func (d *RulesetDocument) ExtractAnchorsFromChain(family, table, chain string) []string {
	rules := d.GetRules(family, table, chain)
	var anchors []string

	for _, rule := range rules {
		if rule.Comment != "" && strings.Contains(rule.Comment, "NFTBAN_ANCHOR:") {
			// Extract anchor name from comment like "NFTBAN_ANCHOR:ANCHOR_HYGIENE"
			parts := strings.Split(rule.Comment, "NFTBAN_ANCHOR:")
			if len(parts) >= 2 {
				anchorPart := strings.TrimSpace(parts[1])
				// Take only the anchor name (stop at whitespace or end)
				if idx := strings.IndexAny(anchorPart, " \t"); idx > 0 {
					anchorPart = anchorPart[:idx]
				}
				anchors = append(anchors, anchorPart)
			}
		}
	}

	return anchors
}

// CountChains returns total chain count for a family's nftban table.
func (d *RulesetDocument) CountChains(family string) int {
	prefix := family + ":nftban:"
	count := 0
	for key := range d.chains {
		if strings.HasPrefix(key, prefix) {
			count++
		}
	}
	return count
}

// CountSets returns total set count for a family's nftban table.
func (d *RulesetDocument) CountSets(family string) int {
	prefix := family + ":nftban:"
	count := 0
	for key := range d.sets {
		if strings.HasPrefix(key, prefix) {
			count++
		}
	}
	return count
}
