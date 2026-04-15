// =============================================================================
// NFTBan - NFT Rule Counter Collector (v1.41.0)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="rule_counters"
// meta:type="package"
// meta:version="1.41.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Extracts per-rule packet/byte counters from nftables JSON (named + anonymous)"
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
	"context"
	"encoding/json"
	"log"
	"os/exec"
	"strings"
	"sync"
	"time"

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

	// v1.41.0: Named counter metrics (preferred over anonymous)
	nftNamedCounterPackets = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "nft_named_counter_packets_total",
		Help:      "Packet count per named nftables counter",
	}, []string{"family", "counter"})

	nftNamedCounterBytes = promauto.NewGaugeVec(prometheus.GaugeOpts{
		Namespace: "nftban",
		Name:      "nft_named_counter_bytes_total",
		Help:      "Byte count per named nftables counter",
	}, []string{"family", "counter"})
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

// nftNamedCounterWrapper wraps a named counter entry in nftables JSON
type nftNamedCounterWrapper struct {
	Counter *namedCounterData `json:"counter,omitempty"`
}

type namedCounterData struct {
	Family  string `json:"family"`
	Table   string `json:"table"`
	Name    string `json:"name"`
	Packets uint64 `json:"packets"`
	Bytes   uint64 `json:"bytes"`
}

// ruleCounterMu protects concurrent collection
var ruleCounterMu sync.Mutex

// CollectRuleCounters extracts per-rule packet/byte counters from nftables
// Called from the sampler FULL tier. Tries named counters first (v1.41.0),
// falls back to anonymous counter extraction for backward compatibility.
func CollectRuleCounters() {
	ruleCounterMu.Lock()
	defer ruleCounterMu.Unlock()

	// v1.87.2: Single global nft call for named counters.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	output, err := nftListAllCountersJSON(ctx)

	for _, family := range []string{"ip", "ip6"} {
		if err == nil {
			counters, parseErr := parseNamedCountersJSONFiltered(output, family)
			if parseErr == nil && len(counters) > 0 {
				updatePrometheusFromNamedCounters(family, counters)
				continue
			}
		}
		// Fallback to anonymous counter extraction (pre-v1.41.0 schemas)
		collectFamilyCounters(family)
	}
}

// CollectNamedCounters returns all named counters as structured evidence data.
// v1.87 M87-2: This is the canonical evidence collection function.
// Collect once → render many (JSON, human, Prometheus).
//
// Semantics:
// - Empty Counters map = valid (no counters found, not an error)
// - Non-nil error = collection failed (command error, parse error)
// - Zero-valued counters are preserved (neutral, not failure)
func CollectNamedCounters(ctx context.Context) (*NamedCountersResult, error) {
	ruleCounterMu.Lock()
	defer ruleCounterMu.Unlock()

	result := &NamedCountersResult{
		CollectedAt: time.Now(),
		Counters:    make(map[string]CounterValue),
	}

	// v1.87.2: Single global nft call, filter both families in code.
	// The per-family form `nft list counters <family> <table>` is broken
	// on fleet nftables versions (v1.0.2-v1.1.1).
	ctx2, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	output, err := nftListAllCountersJSON(ctx2)
	if err != nil {
		return nil, err
	}

	for _, family := range []string{"ip", "ip6"} {
		counters, err := parseNamedCountersJSONFiltered(output, family)
		if err != nil {
			return nil, err
		}
		for name, val := range counters {
			key := family + ":" + name
			result.Counters[key] = val
		}
	}

	return result, nil
}

// collectNamedCountersStructured fetches global counters and filters by family.
// v1.87.2: Uses global `nft -j list counters` because the filtered form
// `nft list counters <family> <table>` is broken on nftables v1.0.x-v1.1.x.
func collectNamedCountersStructured(ctx context.Context, family string) (map[string]CounterValue, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	output, err := nftListAllCountersJSON(ctx)
	if err != nil {
		return nil, err
	}

	return parseNamedCountersJSONFiltered(output, family)
}

// parseNamedCountersJSONFiltered parses global counter JSON and filters
// by family and table=="nftban". This replaces the broken per-family query.
func parseNamedCountersJSONFiltered(data []byte, family string) (map[string]CounterValue, error) {
	var nft nftJSON
	if err := json.Unmarshal(data, &nft); err != nil {
		return nil, err
	}

	counters := make(map[string]CounterValue)
	for _, raw := range nft.NFTables {
		var wrapper nftNamedCounterWrapper
		if err := json.Unmarshal(raw, &wrapper); err != nil || wrapper.Counter == nil {
			continue
		}

		c := wrapper.Counter
		if c.Table != "nftban" || c.Family != family || c.Name == "" {
			continue
		}

		counters[c.Name] = CounterValue{
			Packets: int64(c.Packets),
			Bytes:   int64(c.Bytes),
		}
	}

	return counters, nil
}

// nftListAllCountersJSON runs nft -j list counters (global, no family/table filter).
// v1.87.2: The filtered form `nft list counters <family> <table>` is NOT supported
// on fleet nftables versions (v1.0.2-v1.1.1). Global listing works everywhere.
// Filtering by family and table happens in parseNamedCountersJSON().
func nftListAllCountersJSON(ctx context.Context) ([]byte, error) {
	return exec.CommandContext(ctx, "nft", "-j", "list", "counters").Output() // #nosec G204
}

// nftListTable runs nft -j list table for a specific family.
func nftListTable(family string) ([]byte, error) {
	switch family {
	case "ip":
		return exec.Command("nft", "-j", "list", "table", "ip", "nftban").Output() // #nosec G204
	case "ip6":
		return exec.Command("nft", "-j", "list", "table", "ip6", "nftban").Output() // #nosec G204
	default:
		return nil, nil
	}
}

// parseNamedCountersJSON is the pure parsing logic, testable without exec.
// Returns counter names as bare names (without family prefix).
// Caller adds the family prefix when building NamedCountersResult keys.
func parseNamedCountersJSON(data []byte) (map[string]CounterValue, error) {
	var nft nftJSON
	if err := json.Unmarshal(data, &nft); err != nil {
		return nil, err
	}

	counters := make(map[string]CounterValue)
	for _, raw := range nft.NFTables {
		var wrapper nftNamedCounterWrapper
		if err := json.Unmarshal(raw, &wrapper); err != nil || wrapper.Counter == nil {
			continue
		}

		c := wrapper.Counter
		if c.Table != "nftban" || c.Name == "" {
			continue
		}

		counters[c.Name] = CounterValue{
			Packets: int64(c.Packets),
			Bytes:   int64(c.Bytes),
		}
	}

	return counters, nil
}

// updatePrometheusFromNamedCounters writes structured counter data to Prometheus gauges.
// Preserves existing Prometheus exporter behavior.
func updatePrometheusFromNamedCounters(family string, counters map[string]CounterValue) {
	for name, val := range counters {
		nftNamedCounterPackets.WithLabelValues(family, name).Set(float64(val.Packets))
		nftNamedCounterBytes.WithLabelValues(family, name).Set(float64(val.Bytes))
	}
}

// collectFamilyCounters collects rule counters for a single nftables family
// using anonymous counter extraction (pre-v1.41.0 fallback)
func collectFamilyCounters(family string) {
	output, err := nftListTable(family)
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
