// =============================================================================
// NFTBan - NFT Rule Counter Collector (v1.40.0)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="rule_counters"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Extracts per-rule packet/byte counters from nftables JSON"
// meta:inventory.files=""
// meta:inventory.binaries="nft"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package metrics

import (
	"encoding/json"
	"log"
	"os/exec"
	"strings"
	"sync"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promauto"
)

// Rule counter Prometheus metrics
var (
	nftRulePacketsTotal = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "nft_rule_packets_total",
		Help:      "Packet count per nftables rule (from anonymous counters)",
	}, []string{"table", "chain", "rule"})

	nftRuleBytesTotal = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "nft_rule_bytes_total",
		Help:      "Byte count per nftables rule (from anonymous counters)",
	}, []string{"table", "chain", "rule"})
)

// nftJSON represents the top-level nft -j output
type nftJSON struct {
	NFTables []json.RawMessage `json:"nftables"`
}

// nftRuleWrapper wraps a rule entry in the nftables JSON array
type nftRuleWrapper struct {
	Rule *nftRule `json:"rule,omitempty"`
}

// nftRule represents a single nft rule from JSON output
type nftRule struct {
	Family  string            `json:"family"`
	Table   string            `json:"table"`
	Chain   string            `json:"chain"`
	Comment string            `json:"comment"`
	Expr    []json.RawMessage `json:"expr"`
}

// nftCounter represents a counter expression in a rule
type nftCounter struct {
	Counter *counterData `json:"counter,omitempty"`
}

type counterData struct {
	Packets uint64 `json:"packets"`
	Bytes   uint64 `json:"bytes"`
}

// ruleCounterMu protects concurrent collection
var ruleCounterMu sync.Mutex

// CollectRuleCounters extracts per-rule packet/byte counters from nftables
// Called from the sampler FULL tier. Parses nft -j list table ip nftban.
func CollectRuleCounters() {
	ruleCounterMu.Lock()
	defer ruleCounterMu.Unlock()

	// Collect counters for both ip and ip6 families
	for _, family := range []string{"ip", "ip6"} {
		collectFamilyCounters(family)
	}
}

// collectFamilyCounters collects rule counters for a single nftables family
func collectFamilyCounters(family string) {
	cmd := exec.Command("nft", "-j", "list", "table", family, "nftban")
	output, err := cmd.Output()
	if err != nil {
		// Table may not exist for this family — not an error
		return
	}

	var nft nftJSON
	if err := json.Unmarshal(output, &nft); err != nil {
		log.Printf("[METRICS] Failed to parse nft JSON for %s nftban: %v", family, err)
		return
	}

	for _, raw := range nft.NFTables {
		var wrapper nftRuleWrapper
		if err := json.Unmarshal(raw, &wrapper); err != nil || wrapper.Rule == nil {
			continue
		}

		rule := wrapper.Rule
		if rule.Table != "nftban" {
			continue
		}

		// Derive rule label from comment field, or build from expression summary
		ruleLabel := rule.Comment
		if ruleLabel == "" {
			ruleLabel = deriveRuleLabel(rule.Expr)
		}
		if ruleLabel == "" {
			continue // Skip rules with no identifiable label
		}

		// Extract counter from expressions
		packets, bytes, found := extractCounter(rule.Expr)
		if !found {
			continue // No counter on this rule
		}

		nftRulePacketsTotal.WithLabelValues(family, rule.Chain, ruleLabel).Set(float64(packets))
		nftRuleBytesTotal.WithLabelValues(family, rule.Chain, ruleLabel).Set(float64(bytes))
	}
}

// extractCounter finds the counter expression in a rule's expressions
func extractCounter(exprs []json.RawMessage) (packets, bytes uint64, found bool) {
	for _, raw := range exprs {
		var c nftCounter
		if err := json.Unmarshal(raw, &c); err == nil && c.Counter != nil {
			return c.Counter.Packets, c.Counter.Bytes, true
		}
	}
	return 0, 0, false
}

// deriveRuleLabel creates a label from rule expressions when no comment exists
// Returns a simplified string like "drop", "accept", "jump_input_filter", etc.
func deriveRuleLabel(exprs []json.RawMessage) string {
	var parts []string

	for _, raw := range exprs {
		var m map[string]json.RawMessage
		if err := json.Unmarshal(raw, &m); err != nil {
			continue
		}

		// Check for terminal actions
		for _, action := range []string{"accept", "drop", "reject", "return", "continue"} {
			if _, ok := m[action]; ok {
				parts = append(parts, action)
			}
		}

		// Check for jump/goto
		if jumpRaw, ok := m["jump"]; ok {
			var jump struct {
				Target string `json:"target"`
			}
			if json.Unmarshal(jumpRaw, &jump) == nil && jump.Target != "" {
				parts = append(parts, "jump_"+jump.Target)
			}
		}
		if gotoRaw, ok := m["goto"]; ok {
			var g struct {
				Target string `json:"target"`
			}
			if json.Unmarshal(gotoRaw, &g) == nil && g.Target != "" {
				parts = append(parts, "goto_"+g.Target)
			}
		}
	}

	if len(parts) > 0 {
		return strings.Join(parts, "_")
	}
	return ""
}
