// =============================================================================
// NFTBan v1.87 - Named Counter Evidence Tests (M87-2)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="evidence_counters_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:description="Tests for named counter evidence collection"
// meta:inventory.files="internal/metrics/evidence_counters_test.go"
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
)

// =============================================================================
// A. Parsing tests — exercise parseNamedCountersJSON directly
// =============================================================================

func TestParse_ValidJSON_MultipleCounters(t *testing.T) {
	fixture := `{"nftables": [
		{"metainfo": {"version": "1.0.9"}},
		{"counter": {"family": "ip", "table": "nftban", "name": "input_ct_ssh_drop", "packets": 42, "bytes": 1234}},
		{"counter": {"family": "ip", "table": "nftban", "name": "input_ct_http_drop", "packets": 0, "bytes": 0}},
		{"counter": {"family": "ip", "table": "nftban", "name": "input_syn_rate_exceeded", "packets": 2166, "bytes": 105678}}
	]}`

	counters, err := parseNamedCountersJSON([]byte(fixture))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(counters) != 3 {
		t.Errorf("expected 3 counters, got %d", len(counters))
	}
	if counters["input_ct_ssh_drop"].Packets != 42 {
		t.Errorf("input_ct_ssh_drop packets = %d, want 42", counters["input_ct_ssh_drop"].Packets)
	}
	if counters["input_syn_rate_exceeded"].Bytes != 105678 {
		t.Errorf("input_syn_rate_exceeded bytes = %d, want 105678", counters["input_syn_rate_exceeded"].Bytes)
	}
}

func TestParse_ZeroValuesPreserved(t *testing.T) {
	fixture := `{"nftables": [
		{"counter": {"family": "ip", "table": "nftban", "name": "input_whitelist_accept", "packets": 0, "bytes": 0}}
	]}`

	counters, err := parseNamedCountersJSON([]byte(fixture))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	v, ok := counters["input_whitelist_accept"]
	if !ok {
		t.Fatal("zero-valued counter must be present in result")
	}
	if v.Packets != 0 || v.Bytes != 0 {
		t.Errorf("zero values must be preserved, got packets=%d bytes=%d", v.Packets, v.Bytes)
	}
}

func TestParse_ForeignTableIgnored(t *testing.T) {
	fixture := `{"nftables": [
		{"counter": {"family": "ip", "table": "nftban", "name": "input_drop", "packets": 10, "bytes": 100}},
		{"counter": {"family": "ip", "table": "filter", "name": "foreign_counter", "packets": 999, "bytes": 9999}}
	]}`

	counters, err := parseNamedCountersJSON([]byte(fixture))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(counters) != 1 {
		t.Errorf("expected 1 counter (filter table excluded), got %d", len(counters))
	}
	if _, exists := counters["foreign_counter"]; exists {
		t.Error("foreign table counter must be excluded")
	}
}

func TestParse_MalformedJSON(t *testing.T) {
	_, err := parseNamedCountersJSON([]byte(`{"nftables": [INVALID`))
	if err == nil {
		t.Error("malformed JSON should return error")
	}
}

func TestParse_EmptyValidResult(t *testing.T) {
	fixture := `{"nftables": [{"metainfo": {"version": "1.0.9"}}]}`
	counters, err := parseNamedCountersJSON([]byte(fixture))
	if err != nil {
		t.Fatalf("empty valid result should not error: %v", err)
	}
	if len(counters) != 0 {
		t.Errorf("expected 0 counters, got %d", len(counters))
	}
}

func TestParse_EmptyNameExcluded(t *testing.T) {
	fixture := `{"nftables": [
		{"counter": {"family": "ip", "table": "nftban", "name": "", "packets": 5, "bytes": 50}}
	]}`
	counters, err := parseNamedCountersJSON([]byte(fixture))
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(counters) != 0 {
		t.Errorf("empty-name counter should be excluded, got %d", len(counters))
	}
}

// =============================================================================
// B. Public key contract tests — verify family-prefixed stable keys
// =============================================================================

func TestKeyContract_FamilyPrefix(t *testing.T) {
	// Simulate what CollectNamedCounters does: add family prefix to parsed names
	parsed := map[string]CounterValue{
		"input_ct_ssh_drop":       {Packets: 42, Bytes: 1234},
		"input_syn_rate_exceeded": {Packets: 0, Bytes: 0},
	}

	result := &NamedCountersResult{
		Counters: make(map[string]CounterValue),
	}
	for name, val := range parsed {
		result.Counters["ip:"+name] = val
	}
	for name, val := range parsed {
		result.Counters["ip6:"+name] = val
	}

	// Verify all keys have family prefix
	for key := range result.Counters {
		if key[:3] != "ip:" && key[:4] != "ip6:" {
			t.Errorf("key %q missing family prefix", key)
		}
	}
	if len(result.Counters) != 4 {
		t.Errorf("expected 4 keys (2 families × 2 counters), got %d", len(result.Counters))
	}
}

// =============================================================================
// C. JSON round-trip tests
// =============================================================================

func TestCounterValue_JSONRoundTrip(t *testing.T) {
	original := CounterValue{Packets: 12345, Bytes: 678901}
	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	var decoded CounterValue
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if decoded != original {
		t.Errorf("round-trip mismatch: got %+v, want %+v", decoded, original)
	}
}

func TestNamedCountersResult_JSONRoundTrip(t *testing.T) {
	result := &NamedCountersResult{
		Counters: map[string]CounterValue{
			"ip:input_ct_ssh_drop":  {Packets: 42, Bytes: 1234},
			"ip6:input_ct_ssh_drop": {Packets: 0, Bytes: 0},
		},
	}
	data, err := json.Marshal(result)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	var decoded NamedCountersResult
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if len(decoded.Counters) != 2 {
		t.Errorf("expected 2 counters after round-trip, got %d", len(decoded.Counters))
	}
}
