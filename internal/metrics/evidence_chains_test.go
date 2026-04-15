// =============================================================================
// NFTBan v1.87 - Chain Presence Evidence Tests (M87-4)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="evidence_chains_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:description="Tests for chain presence evidence collection"
// meta:inventory.files="internal/metrics/evidence_chains_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package metrics

import (
	"encoding/json"
	"strings"
	"testing"
)

// parseChainList exercises the same parsing logic as listChains
// but from a string fixture instead of exec.
func parseChainList(output string) map[string]bool {
	result := make(map[string]bool)
	for _, line := range strings.Split(output, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "chain ") {
			parts := strings.Fields(line)
			if len(parts) >= 2 {
				result[parts[1]] = true
			}
		}
	}
	return result
}

func TestParseChains_FullOutput(t *testing.T) {
	fixture := `table ip nftban {
	chain input {
	}
	chain forward {
	}
	chain output {
	}
	chain ddos_sanity {
	}
	chain ddos_penalty {
	}
	chain ddos_prefix {
	}
	chain ddos_protection {
	}
	chain portscan_detection {
	}
	chain http_bot_guard {
	}
}`

	chains := parseChainList(fixture)
	for _, name := range Phase1Chains {
		if !chains[name] {
			t.Errorf("expected chain %q to be present", name)
		}
	}
}

func TestParseChains_PartialOutput(t *testing.T) {
	fixture := `table ip nftban {
	chain input {
	}
	chain forward {
	}
	chain output {
	}
}`

	chains := parseChainList(fixture)
	if !chains["input"] || !chains["forward"] || !chains["output"] {
		t.Error("base chains should be present")
	}
	if chains["ddos_protection"] {
		t.Error("ddos_protection should not be present in partial output")
	}
}

func TestParseChains_EmptyOutput(t *testing.T) {
	chains := parseChainList("")
	if len(chains) != 0 {
		t.Errorf("empty output should produce 0 chains, got %d", len(chains))
	}
}

func TestChainInfo_Present(t *testing.T) {
	ci := ChainInfo{Exists: true, Unknown: false}
	if ci.Unknown {
		t.Error("present chain should not be unknown")
	}
}

func TestChainInfo_ConfirmedAbsent(t *testing.T) {
	ci := ChainInfo{Exists: false, Unknown: false}
	if ci.Unknown || ci.Exists {
		t.Error("confirmed absent: Exists=false, Unknown=false")
	}
}

func TestChainInfo_CollectionFailed(t *testing.T) {
	ci := ChainInfo{Exists: false, Unknown: true}
	if !ci.Unknown {
		t.Error("collection failure should be Unknown=true")
	}
}

func TestChainInfo_JSONRoundTrip(t *testing.T) {
	original := ChainInfo{Exists: true}
	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	var decoded ChainInfo
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if decoded != original {
		t.Errorf("round-trip mismatch")
	}
}

func TestChainInfo_UnknownOmittedWhenFalse(t *testing.T) {
	ci := ChainInfo{Exists: true}
	data, _ := json.Marshal(ci)
	if strings.Contains(string(data), "unknown") {
		t.Errorf("Unknown=false should be omitted, got: %s", data)
	}
}

func TestChainInfo_UnknownPresentWhenTrue(t *testing.T) {
	ci := ChainInfo{Exists: false, Unknown: true}
	data, _ := json.Marshal(ci)
	if !strings.Contains(string(data), "unknown") {
		t.Errorf("Unknown=true should be present, got: %s", data)
	}
}

func TestPhase1Chains_Coverage(t *testing.T) {
	if len(Phase1Chains) != 9 {
		t.Errorf("expected 9 Phase 1 chains, got %d", len(Phase1Chains))
	}
}
