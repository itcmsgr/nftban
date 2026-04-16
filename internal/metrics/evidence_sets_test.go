// =============================================================================
// NFTBan v1.88 - Set Element Evidence Tests (M87-3)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="evidence_sets_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:description="Tests for set element evidence collection"
// meta:inventory.files="internal/metrics/evidence_sets_test.go"
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

func TestParseSet_WithElements(t *testing.T) {
	fixture := `{"nftables": [
		{"metainfo": {"version": "1.0.9"}},
		{"set": {"family": "ip", "table": "nftban", "name": "blacklist_manual_ipv4",
			"elem": ["1.2.3.4", "5.6.7.8", "10.0.0.1"]}}
	]}`

	count, found := parseSetElementCount([]byte(fixture))
	if !found {
		t.Fatal("set should be found")
	}
	if count != 3 {
		t.Errorf("expected 3 elements, got %d", count)
	}
}

func TestParseSet_EmptySet(t *testing.T) {
	// Set object exists but no elem field → found=true, count=0
	fixture := `{"nftables": [
		{"metainfo": {"version": "1.0.9"}},
		{"set": {"family": "ip", "table": "nftban", "name": "blacklist_manual_ipv4"}}
	]}`

	count, found := parseSetElementCount([]byte(fixture))
	if !found {
		t.Fatal("set object exists → found should be true")
	}
	if count != 0 {
		t.Errorf("expected 0 elements, got %d", count)
	}
}

func TestParseSet_NoSetWrapper(t *testing.T) {
	// Valid JSON but no set object → found=false (absent, not empty-present)
	fixture := `{"nftables": [{"metainfo": {"version": "1.0.9"}}]}`

	_, found := parseSetElementCount([]byte(fixture))
	if found {
		t.Error("no set wrapper → found should be false (absent)")
	}
}

func TestParseSet_MalformedJSON(t *testing.T) {
	_, found := parseSetElementCount([]byte(`INVALID`))
	if found {
		t.Error("malformed JSON should return found=false")
	}
}

func TestSetInfo_PresentWithElements(t *testing.T) {
	si := SetInfo{Exists: true, Count: 42, Unknown: false}
	if si.Unknown {
		t.Error("present set should not be unknown")
	}
}

func TestSetInfo_ConfirmedAbsent(t *testing.T) {
	si := SetInfo{Exists: false, Count: 0, Unknown: false}
	if si.Unknown {
		t.Error("confirmed absent should not be unknown")
	}
	if si.Exists {
		t.Error("absent set should have Exists=false")
	}
}

func TestSetInfo_CollectionFailed(t *testing.T) {
	si := SetInfo{Exists: false, Count: 0, Unknown: true}
	if !si.Unknown {
		t.Error("collection failure should be Unknown=true")
	}
}

func TestSetInfo_JSONRoundTrip(t *testing.T) {
	original := SetInfo{Exists: true, Count: 42}
	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	var decoded SetInfo
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if decoded.Exists != original.Exists || decoded.Count != original.Count {
		t.Errorf("round-trip mismatch")
	}
}

func TestSetInfo_UnknownOmittedWhenFalse(t *testing.T) {
	si := SetInfo{Exists: true, Count: 5}
	data, err := json.Marshal(si)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	// Unknown=false should be omitted from JSON (omitempty)
	str := string(data)
	if contains(str, "unknown") {
		t.Errorf("Unknown=false should be omitted from JSON, got: %s", str)
	}
}

func TestSetInfo_UnknownPresentWhenTrue(t *testing.T) {
	si := SetInfo{Exists: false, Unknown: true}
	data, err := json.Marshal(si)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	str := string(data)
	if !contains(str, "unknown") {
		t.Errorf("Unknown=true should be present in JSON, got: %s", str)
	}
}

func TestPhase1Sets_Coverage(t *testing.T) {
	if len(Phase1Sets["ip"]) != 8 {
		t.Errorf("expected 8 IPv4 Phase 1 sets, got %d", len(Phase1Sets["ip"]))
	}
	if len(Phase1Sets["ip6"]) != 8 {
		t.Errorf("expected 8 IPv6 Phase 1 sets, got %d", len(Phase1Sets["ip6"]))
	}
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && json.Valid([]byte(s)) && indexOf187(s, substr) >= 0
}

func indexOf187(s, substr string) int {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return i
		}
	}
	return -1
}
