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

	// Note: context.Background() is intentional here — this is the legacy
	// sampler-driven Prometheus path, not the new evidence CLI path.
	// Timeout is bounded per-family (2s) inside collectNamedCountersStructured.
	for _, family := range []string{"ip", "ip6"} {
		counters, err := collectNamedCountersStructured(context.Background(), family)
		if err == nil && len(counters) > 0 {
			updatePrometheusFromNamedCounters(family, counters)
		} else {
			// Fallback to anonymous counter extraction (pre-v1.41.0 schemas)
			collectFamilyCounters(family)
		}
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

	var lastErr error
	familiesSucceeded := 0

	for _, family := range []string{"ip", "ip6"} {
		counters, err := collectNamedCountersStructured(ctx, family)
		if err != nil {
			lastErr = err
			continue
		}
		familiesSucceeded++
		for name, val := range counters {
			key := family + ":" + name
			result.Counters[key] = val
		}
	}

	// Both families failed → return error (contract: non-nil error = collection failed)
	// At least one succeeded → return result, nil (may be partial)
	if familiesSucceeded == 0 && lastErr != nil {
		return nil, lastErr
	}

	return result, nil
}

// collectNamedCountersStructured executes nft and parses the result.
// Does NOT update Prometheus — caller decides.
func collectNamedCountersStructured(ctx context.Context, family string) (map[string]CounterValue, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	output, err := nftListCounters(ctx, family)
	if err != nil {
		return nil, err
	}

	return parseNamedCountersJSON(output)
}

// nftListCounters runs nft -j list counters for a specific family.
func nftListCounters(ctx context.Context, family string) ([]byte, error) {
	switch family {
	case "ip":
		return exec.CommandContext(ctx, "nft", "-j", "list", "counters", "ip", "nftban").Output() // #nosec G204
	case "ip6":
		return exec.CommandContext(ctx, "nft", "-j", "list", "counters", "ip6", "nftban").Output() // #nosec G204
	default:
		return nil, nil
	}
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
