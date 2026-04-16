// =============================================================================
// NFTBan v1.88 - Validator Snapshot Bridge Tests (M87-5)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="evidence_validator_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-15"
// meta:description="Tests for validator snapshot bridge"
// meta:inventory.files="internal/metrics/evidence_validator_test.go"
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

func TestParseValidator_ProtectedWithModules(t *testing.T) {
	fixture := `{
		"status": "protected",
		"modules": {
			"ddos": {"config": "enabled", "structural": "present", "effective": "enforcing"},
			"botguard": {"config": "disabled"},
			"portscan": {"config": "enabled", "structural": "present", "effective": "idle"},
			"loginmon": {"config": "enabled", "structural": "present", "runtime": "running", "effective": "idle"},
			"blacklist": {
				"manual": {"state": "enforcing", "entries": 3, "drops": 42},
				"feeds": {"state": "disabled"},
				"geoban": {"state": "loaded"}
			}
		},
		"findings": [
			{"code": "VAL-GEOBAN-001", "severity": "warn", "message": "test"}
		]
	}`

	snap := parseValidatorJSON([]byte(fixture))

	if snap.Status != "protected" {
		t.Errorf("status = %s, want protected", snap.Status)
	}
	if snap.Unknown {
		t.Error("should not be unknown")
	}
	if snap.Modules["ddos"] != "enforcing" {
		t.Errorf("ddos effective = %s, want enforcing", snap.Modules["ddos"])
	}
	if snap.Modules["botguard"] != "" {
		t.Errorf("disabled botguard should have empty effective, got %s", snap.Modules["botguard"])
	}
	if snap.Modules["blacklist_manual"] != "enforcing" {
		t.Errorf("blacklist_manual = %s, want enforcing", snap.Modules["blacklist_manual"])
	}
	if snap.Modules["blacklist_geoban"] != "loaded" {
		t.Errorf("blacklist_geoban = %s, want loaded", snap.Modules["blacklist_geoban"])
	}
	if len(snap.Findings) != 1 || snap.Findings[0] != "VAL-GEOBAN-001" {
		t.Errorf("findings = %v, want [VAL-GEOBAN-001]", snap.Findings)
	}
}

func TestParseValidator_Degraded(t *testing.T) {
	fixture := `{
		"status": "degraded",
		"modules": {
			"ddos": {"config": "enabled", "structural": "missing"}
		},
		"findings": [
			{"code": "VAL-CHAIN-001"},
			{"code": "VAL-SERVICE-001"}
		]
	}`

	snap := parseValidatorJSON([]byte(fixture))

	if snap.Status != "degraded" {
		t.Errorf("status = %s, want degraded", snap.Status)
	}
	if len(snap.Findings) != 2 {
		t.Errorf("expected 2 findings, got %d", len(snap.Findings))
	}
}

func TestParseValidator_MalformedJSON(t *testing.T) {
	snap := parseValidatorJSON([]byte(`INVALID`))

	if snap.Status != "unavailable" {
		t.Errorf("malformed JSON should produce status=unavailable, got %s", snap.Status)
	}
	if !snap.Unknown {
		t.Error("malformed JSON should be Unknown=true")
	}
}

func TestParseValidator_EmptyJSON(t *testing.T) {
	// Valid JSON but missing required status field → unknown
	snap := parseValidatorJSON([]byte(`{}`))

	if snap.Status != "unavailable" {
		t.Errorf("empty JSON (no status) should produce status=unavailable, got %s", snap.Status)
	}
	if !snap.Unknown {
		t.Error("empty JSON with no status should be Unknown=true")
	}
}

func TestParseValidator_NoFindings(t *testing.T) {
	fixture := `{"status": "protected", "modules": {}, "findings": []}`
	snap := parseValidatorJSON([]byte(fixture))

	if len(snap.Findings) != 0 {
		t.Errorf("expected 0 findings, got %d", len(snap.Findings))
	}
}

func TestValidatorSnapshot_JSONRoundTrip(t *testing.T) {
	original := &ValidatorSnapshot{
		Status:   "protected",
		Modules:  map[string]string{"ddos": "enforcing"},
		Findings: []string{"VAL-GEOBAN-001"},
	}
	data, err := json.Marshal(original)
	if err != nil {
		t.Fatalf("marshal failed: %v", err)
	}
	var decoded ValidatorSnapshot
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatalf("unmarshal failed: %v", err)
	}
	if decoded.Status != original.Status {
		t.Errorf("status mismatch")
	}
	if decoded.Modules["ddos"] != "enforcing" {
		t.Errorf("module mismatch")
	}
}

func TestValidatorSnapshot_UnknownOmitted(t *testing.T) {
	snap := &ValidatorSnapshot{Status: "protected"}
	data, _ := json.Marshal(snap)
	str := string(data)
	if jsonContains(str, "unknown") {
		t.Errorf("Unknown=false should be omitted, got: %s", str)
	}
}

func TestValidatorSnapshot_UnknownPresent(t *testing.T) {
	snap := &ValidatorSnapshot{Status: "unavailable", Unknown: true}
	data, _ := json.Marshal(snap)
	str := string(data)
	if !jsonContains(str, "unknown") {
		t.Errorf("Unknown=true should be present, got: %s", str)
	}
}

func jsonContains(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
