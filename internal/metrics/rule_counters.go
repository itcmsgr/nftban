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

// expectedNamedCounters lists the named counters declared in nftables.conf (v1.41.0)
// Same names exist in both ip and ip6 tables (except icmp vs icmpv6)
var expectedNamedCounters = []string{
	"input_invalid_drop",
	"input_whitelist_accept",
	"input_blacklist_manual_drop",
	"input_blacklist_drop",
	"input_port_allow_tcp_accept",
	"input_port_allow_udp_accept",
	"input_ct_ssh_drop",
	"input_ct_http_drop",
	"input_ct_mail_drop",
	"output_loopback_accept",
	"output_established_accept",
	"output_tcp_accept",
	"output_udp_accept",
	"output_egress_audit",
}

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

	for _, family := range []string{"ip", "ip6"} {
		// v1.41.0: Try named counters first (simpler, more efficient)
		if !collectNamedCounters(family) {
			// Fallback to anonymous counter extraction (pre-v1.41.0 schemas)
			collectFamilyCounters(family)
		}
	}
}

// collectNamedCounters extracts named counter values via `nft -j list counters`.
// Returns true if at least one named counter was found (schema has named counters).
func collectNamedCounters(family string) bool {
	cmd := exec.Command("nft", "-j", "list", "counters", family, "nftban")
	output, err := cmd.Output()
	if err != nil {
		return false // Table or counters not available
	}

	var nft nftJSON
	if err := json.Unmarshal(output, &nft); err != nil {
		log.Printf("[METRICS] Failed to parse named counters JSON for %s nftban: %v", family, err)
		return false
	}

	found := 0
	for _, raw := range nft.NFTables {
		var wrapper nftNamedCounterWrapper
		if err := json.Unmarshal(raw, &wrapper); err != nil || wrapper.Counter == nil {
			continue
		}

		c := wrapper.Counter
		if c.Table != "nftban" || c.Name == "" {
			continue
		}

		nftNamedCounterPackets.WithLabelValues(family, c.Name).Set(float64(c.Packets))
		nftNamedCounterBytes.WithLabelValues(family, c.Name).Set(float64(c.Bytes))
		found++
	}

	return found > 0
}

// collectFamilyCounters collects rule counters for a single nftables family
// using anonymous counter extraction (pre-v1.41.0 fallback)
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
