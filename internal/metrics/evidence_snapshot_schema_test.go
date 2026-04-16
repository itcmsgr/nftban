// =============================================================================
// NFTBan v1.88 - Evidence Snapshot Schema Tests (M87-10)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="evidence_snapshot_schema_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:description="CI schema validation for EvidenceSnapshot JSON contract"
// meta:inventory.files="internal/metrics/evidence_snapshot_schema_test.go"
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
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

var fixedTime = time.Date(2026, 4, 15, 12, 0, 0, 0, time.UTC)

// =============================================================================
// Fixture builders
// =============================================================================

func buildFullSnapshotFixture() *EvidenceSnapshot {
	snap := &EvidenceSnapshot{
		SchemaVersion:  EvidenceSchemaVersion,
		CollectedAt:    fixedTime,
		TruthAuthority: "kernel",
	}
	snap.Kernel.Counters = map[string]CounterValue{
		"ip:input_ct_ssh_drop":          {Packets: 42, Bytes: 1234},
		"ip:input_syn_rate_exceeded":    {Packets: 2166, Bytes: 105678},
		"ip:input_blacklist_manual_drop": {Packets: 14, Bytes: 700},
	}
	snap.Kernel.Sets = map[string]SetInfo{
		"ip:blacklist_manual_ipv4": {Exists: true, Count: 3},
		"ip:http_bot_ban":          {Exists: true, Count: 5},
		"ip:http_bot_suspect":      {Exists: true, Count: 0},
		"ip6:blacklist_ipv6":       {Exists: true, Count: 847},
	}
	snap.Kernel.Chains = map[string]ChainInfo{
		"ip:input":             {Exists: true},
		"ip:ddos_protection":   {Exists: true},
		"ip:portscan_detection": {Exists: true},
		"ip6:input":            {Exists: true},
	}
	snap.Validator = &ValidatorSnapshot{
		Status:   "protected",
		Modules:  map[string]string{"ddos": "enforcing", "botguard": "observing", "portscan": "idle"},
		Findings: []string{"VAL-GEOBAN-001"},
	}
	snap.Correlation = map[string]string{
		"ddos":             CorrelationMatch,
		"botguard":         CorrelationMatch,
		"portscan":         CorrelationExpectedLimitation,
		"loginmon":         CorrelationMatch, // v1.88: journal-backed evidence
		"blacklist_manual": CorrelationMatch,
	}
	return snap
}

func buildMinimalSnapshotFixture() *EvidenceSnapshot {
	snap := &EvidenceSnapshot{
		SchemaVersion:  EvidenceSchemaVersion,
		CollectedAt:    fixedTime,
		TruthAuthority: "kernel",
	}
	snap.Kernel.Counters = nil // collection failed
	snap.Kernel.Sets = map[string]SetInfo{}
	snap.Kernel.Chains = map[string]ChainInfo{}
	snap.Validator = &ValidatorSnapshot{Status: "unavailable", Unknown: true}
	snap.Correlation = map[string]string{
		"ddos":             CorrelationUnknown,
		"botguard":         CorrelationUnknown,
		"portscan":         CorrelationUnknown,
		"loginmon":         CorrelationUnknown,
		"blacklist_manual": CorrelationUnknown,
	}
	return snap
}

// =============================================================================
// A. Top-level schema presence
// =============================================================================

func TestSchema_TopLevelFields(t *testing.T) {
	snap := buildFullSnapshotFixture()
	data, err := json.Marshal(snap)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}

	var m map[string]interface{}
	if err := json.Unmarshal(data, &m); err != nil {
		t.Fatalf("unmarshal to map failed: %v", err)
	}

	required := []string{"schema_version", "collected_at", "truth_authority", "kernel", "validator", "correlation"}
	for _, field := range required {
		if _, ok := m[field]; !ok {
			t.Errorf("missing required top-level field: %s", field)
		}
	}

	kernel, ok := m["kernel"].(map[string]interface{})
	if !ok {
		t.Fatal("kernel field is not an object")
	}
	for _, sub := range []string{"counters", "sets", "chains"} {
		if _, ok := kernel[sub]; !ok {
			t.Errorf("missing kernel sub-field: %s", sub)
		}
	}
}

// =============================================================================
// B. Schema version lock
// =============================================================================

func TestSchema_VersionLock(t *testing.T) {
	if EvidenceSchemaVersion != "1.88.0" {
		t.Errorf("EvidenceSchemaVersion = %s, want 1.88.0", EvidenceSchemaVersion)
	}

	snap := buildFullSnapshotFixture()
	data, _ := json.Marshal(snap)
	if !strings.Contains(string(data), `"schema_version":"1.88.0"`) {
		t.Error("JSON must contain schema_version: 1.88.0")
	}
}

// =============================================================================
// C. Counters nil vs empty semantics
// =============================================================================

func TestSchema_CountersNil(t *testing.T) {
	snap := buildMinimalSnapshotFixture()
	data, _ := json.Marshal(snap)

	var m map[string]interface{}
	json.Unmarshal(data, &m)

	kernel := m["kernel"].(map[string]interface{})
	if kernel["counters"] != nil {
		t.Error("nil counters must marshal as null, not empty object")
	}
}

func TestSchema_CountersEmpty(t *testing.T) {
	snap := buildFullSnapshotFixture()
	snap.Kernel.Counters = map[string]CounterValue{}
	data, _ := json.Marshal(snap)

	var m map[string]interface{}
	json.Unmarshal(data, &m)

	kernel := m["kernel"].(map[string]interface{})
	counters := kernel["counters"]
	if counters == nil {
		t.Error("empty counters map must marshal as {}, not null")
	}
}

// =============================================================================
// D. unknown,omitempty semantics
// =============================================================================

func TestSchema_SetInfo_UnknownOmitted(t *testing.T) {
	si := SetInfo{Exists: true, Count: 5}
	data, _ := json.Marshal(si)
	if strings.Contains(string(data), "unknown") {
		t.Errorf("Unknown=false should be omitted: %s", data)
	}
}

func TestSchema_SetInfo_UnknownPresent(t *testing.T) {
	si := SetInfo{Unknown: true}
	data, _ := json.Marshal(si)
	if !strings.Contains(string(data), "unknown") {
		t.Errorf("Unknown=true must be present: %s", data)
	}
}

func TestSchema_ChainInfo_UnknownOmitted(t *testing.T) {
	ci := ChainInfo{Exists: false}
	data, _ := json.Marshal(ci)
	if strings.Contains(string(data), "unknown") {
		t.Errorf("Unknown=false should be omitted: %s", data)
	}
}

func TestSchema_ChainInfo_UnknownPresent(t *testing.T) {
	ci := ChainInfo{Unknown: true}
	data, _ := json.Marshal(ci)
	if !strings.Contains(string(data), "unknown") {
		t.Errorf("Unknown=true must be present: %s", data)
	}
}

func TestSchema_Validator_UnknownOmitted(t *testing.T) {
	v := ValidatorSnapshot{Status: "protected"}
	data, _ := json.Marshal(v)
	if strings.Contains(string(data), "unknown") {
		t.Errorf("Unknown=false should be omitted: %s", data)
	}
}

func TestSchema_Validator_UnknownPresent(t *testing.T) {
	v := ValidatorSnapshot{Status: "unavailable", Unknown: true}
	data, _ := json.Marshal(v)
	if !strings.Contains(string(data), "unknown") {
		t.Errorf("Unknown=true must be present: %s", data)
	}
}

// =============================================================================
// E. Required validator semantics
// =============================================================================

func TestSchema_ValidatorRequiredFields(t *testing.T) {
	v := ValidatorSnapshot{Status: "protected", Modules: map[string]string{}, Findings: []string{}}
	data, _ := json.Marshal(v)

	var m map[string]interface{}
	json.Unmarshal(data, &m)

	if _, ok := m["status"]; !ok {
		t.Error("status must always be present")
	}
	if _, ok := m["modules"]; !ok {
		t.Error("modules must always be present")
	}
	if _, ok := m["findings"]; !ok {
		t.Error("findings must always be present")
	}
}

// =============================================================================
// F. Correlation enum safety
// =============================================================================

func TestSchema_CorrelationEnumValues(t *testing.T) {
	allowed := map[string]bool{
		CorrelationMatch:              true,
		CorrelationMismatch:           true,
		CorrelationWarning:            true,
		CorrelationExpectedLimitation: true,
		CorrelationUnknown:            true,
	}

	snap := buildFullSnapshotFixture()
	for mod, val := range snap.Correlation {
		if !allowed[val] {
			t.Errorf("module %s has invalid correlation value: %s", mod, val)
		}
	}

	snapMin := buildMinimalSnapshotFixture()
	for mod, val := range snapMin.Correlation {
		if !allowed[val] {
			t.Errorf("module %s has invalid correlation value: %s", mod, val)
		}
	}
}

// =============================================================================
// G. Golden snapshot fixture
// =============================================================================

func TestSchema_GoldenSnapshot(t *testing.T) {
	snap := buildFullSnapshotFixture()
	data, err := json.MarshalIndent(snap, "", "  ")
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}

	goldenPath := filepath.Join("testdata", "evidence_snapshot_v1.88.golden.json")

	// If golden file doesn't exist, create it (first run only)
	if _, err := os.Stat(goldenPath); os.IsNotExist(err) {
		if err := os.WriteFile(goldenPath, data, 0644); err != nil {
			t.Fatalf("failed to create golden file: %v", err)
		}
		t.Logf("Created golden file: %s", goldenPath)
		return
	}

	expected, err := os.ReadFile(goldenPath)
	if err != nil {
		t.Fatalf("failed to read golden file: %v", err)
	}

	if string(data) != string(expected) {
		t.Errorf("JSON schema drift detected.\n\nExpected (golden):\n%s\n\nActual:\n%s", expected, data)
	}
}
