// =============================================================================
// NFTBan v1.89 - Evidence Extraction Tests (INV-M-002)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="evidence_extract_test"
// meta:type="test"
// meta:version="1.89.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-16"
// meta:description="Tests for v1.89 evidence extraction from validator output"
// meta:inventory.files="internal/metrics/evidence_extract_test.go"
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
	"testing"

	"github.com/itcmsgr/nftban/internal/validator"
)

// buildTestRuleset creates a minimal NftRuleset for testing extraction.
func buildTestRuleset() *validator.NftRuleset {
	// Build JSON that ParseRuleset can consume.
	raw := `{
		"nftables": [
			{"metainfo": {"version": "1.0.2", "release_name": "test", "json_schema_version": 1}},
			{"table": {"family": "ip", "name": "nftban", "handle": 1}},
			{"chain": {"family": "ip", "table": "nftban", "name": "input", "type": "filter", "hook": "input", "prio": 0, "policy": "accept"}},
			{"chain": {"family": "ip", "table": "nftban", "name": "ddos_protection", "type": "filter"}},
			{"set": {"family": "ip", "table": "nftban", "name": "blacklist_manual_ipv4", "type": "ipv4_addr"}},
			{"set": {"family": "ip", "table": "nftban", "name": "http_bot_ban", "type": "ipv4_addr"}},
			{"counter": {"family": "ip", "table": "nftban", "name": "input_ct_ssh_drop", "packets": 42, "bytes": 1234}},
			{"counter": {"family": "ip", "table": "nftban", "name": "anchor_hygiene", "packets": 1000, "bytes": 50000}},
			{"table": {"family": "ip6", "name": "nftban", "handle": 2}},
			{"chain": {"family": "ip6", "table": "nftban", "name": "input", "type": "filter", "hook": "input", "prio": 0, "policy": "accept"}}
		]
	}`
	var ruleset validator.NftRuleset
	if err := json.Unmarshal([]byte(raw), &ruleset); err != nil {
		panic("test fixture parse failed: " + err.Error())
	}
	return &ruleset
}

func TestExtractCountersFromDoc(t *testing.T) {
	ruleset := buildTestRuleset()
	doc := validator.ParseRuleset(ruleset)

	counters := extractCountersFromDoc(doc)
	if counters == nil {
		t.Fatal("extractCountersFromDoc returned nil for valid doc")
	}

	// Check known counter
	ssh, ok := counters["ip:input_ct_ssh_drop"]
	if !ok {
		t.Fatal("missing ip:input_ct_ssh_drop")
	}
	if ssh.Packets != 42 {
		t.Errorf("packets = %d, want 42", ssh.Packets)
	}
	if ssh.Bytes != 1234 {
		t.Errorf("bytes = %d, want 1234", ssh.Bytes)
	}

	// Check anchor counter
	anchor, ok := counters["ip:anchor_hygiene"]
	if !ok {
		t.Fatal("missing ip:anchor_hygiene")
	}
	if anchor.Packets != 1000 {
		t.Errorf("anchor packets = %d, want 1000", anchor.Packets)
	}
}

func TestExtractCountersFromDoc_Nil(t *testing.T) {
	counters := extractCountersFromDoc(nil)
	if counters != nil {
		t.Error("extractCountersFromDoc(nil) should return nil")
	}
}

func TestExtractChainsFromDoc(t *testing.T) {
	ruleset := buildTestRuleset()
	doc := validator.ParseRuleset(ruleset)

	chains := extractChainsFromDoc(doc)
	if chains == nil {
		t.Fatal("extractChainsFromDoc returned nil for valid doc")
	}

	// Check present chain
	input, ok := chains["ip:input"]
	if !ok {
		t.Fatal("missing ip:input")
	}
	if !input.Exists {
		t.Error("ip:input should exist")
	}

	// Check absent chain
	portscan, ok := chains["ip:portscan_detection"]
	if !ok {
		t.Fatal("missing ip:portscan_detection entry")
	}
	if portscan.Exists {
		t.Error("ip:portscan_detection should not exist in test fixture")
	}

	// Check ip6 chain
	ip6input, ok := chains["ip6:input"]
	if !ok {
		t.Fatal("missing ip6:input")
	}
	if !ip6input.Exists {
		t.Error("ip6:input should exist")
	}
}

func TestExtractChainsFromDoc_Nil(t *testing.T) {
	chains := extractChainsFromDoc(nil)
	if chains != nil {
		t.Error("extractChainsFromDoc(nil) should return nil")
	}
}

func TestExtractSetsFromCounts(t *testing.T) {
	ruleset := buildTestRuleset()
	doc := validator.ParseRuleset(ruleset)

	counts := map[string]int{
		"ip:blacklist_manual_ipv4": 3,
		"ip:http_bot_ban":          5,
	}

	sets := extractSetsFromCounts(doc, counts)
	if sets == nil {
		t.Fatal("extractSetsFromCounts returned nil for valid inputs")
	}

	// Check set with elements
	manual, ok := sets["ip:blacklist_manual_ipv4"]
	if !ok {
		t.Fatal("missing ip:blacklist_manual_ipv4")
	}
	if !manual.Exists {
		t.Error("blacklist_manual_ipv4 should exist")
	}
	if manual.Count != 3 {
		t.Errorf("count = %d, want 3", manual.Count)
	}

	// Check set not in schema (confirmed absent)
	absent, ok := sets["ip:http_bot_allow"]
	if !ok {
		t.Fatal("missing ip:http_bot_allow entry")
	}
	if absent.Exists {
		t.Error("http_bot_allow should not exist (not in test schema)")
	}
	if absent.Unknown {
		t.Error("http_bot_allow should not be unknown (doc is valid)")
	}
}

func TestExtractSetsFromCounts_NilDoc(t *testing.T) {
	counts := map[string]int{"ip:test": 1}
	sets := extractSetsFromCounts(nil, counts)
	if sets != nil {
		t.Error("extractSetsFromCounts(nil, ...) should return nil")
	}
}

func TestBuildValidatorSnapshot(t *testing.T) {
	result := &validator.ValidationResult{
		Status: validator.StatusProtected,
		Modules: validator.ModuleHealthMap{
			DDoS: &validator.ModuleHealth{Effective: validator.EffectiveEnforcing},
			BotGuard: &validator.ModuleHealth{Effective: validator.EffectiveObserving},
			Blacklist: &validator.BlacklistHealth{
				Manual: validator.BlacklistSubHealth{State: "enforcing"},
				Feeds:  validator.BlacklistSubHealth{State: "loaded"},
				Geoban: validator.BlacklistSubHealth{State: "disabled"},
			},
		},
		Findings: []validator.Finding{
			{Code: "VAL-TEST-001"},
		},
	}

	snap := buildValidatorSnapshot(result)
	if snap.Status != "protected" {
		t.Errorf("status = %s, want protected", snap.Status)
	}
	if snap.Modules["ddos"] != "enforcing" {
		t.Errorf("ddos = %s, want enforcing", snap.Modules["ddos"])
	}
	if snap.Modules["botguard"] != "observing" {
		t.Errorf("botguard = %s, want observing", snap.Modules["botguard"])
	}
	if snap.Modules["blacklist_manual"] != "enforcing" {
		t.Errorf("blacklist_manual = %s, want enforcing", snap.Modules["blacklist_manual"])
	}
	if len(snap.Findings) != 1 || snap.Findings[0] != "VAL-TEST-001" {
		t.Errorf("findings = %v, want [VAL-TEST-001]", snap.Findings)
	}
	if snap.Unknown {
		t.Error("snapshot should not be unknown")
	}
}
