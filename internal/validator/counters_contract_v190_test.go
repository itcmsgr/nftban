// SPDX-License-Identifier: MPL-2.0
//
// meta:name="counters_contract_v190_test"
// meta:type="test"
// meta:version="1.190.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.190.0 SCHEMA-UNFREEZE counters CONTRACT guard. Asserts: (1) schema bumped 1.83.0->1.84.0; (2) counters_phase='contract' present (anti-false-zero gate); (3) 'counters' object ABSENT in contract phase (no false-zero); (4) populated container round-trips incl. IP-family (FamilyCounts ipv4/ipv6) per DESIGN_AMENDMENT_V1_190_IP_FAMILY; (5) old-consumer compatibility (pre-1.84 struct still parses); (6) family-aware shape — IP-backed counters carry ipv4/ipv6, non-IP-backed (files_deferred/eventbus_drops) do NOT."
// meta:inventory.files="internal/validator/counters_contract_v190_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package validator

import (
	"encoding/json"
	"strings"
	"testing"
)

// (1) deliberate bump
func TestSchemaVersion_v190_Is_1_84_0(t *testing.T) {
	if SchemaVersionCurrent != "1.84.0" {
		t.Fatalf("SchemaVersionCurrent = %q; v1.190.0 SCHEMA-UNFREEZE requires 1.84.0", SchemaVersionCurrent)
	}
	if CountersPhaseContract != "contract" || CountersPhasePopulated != "populated" {
		t.Fatalf("phase constants drifted: %q/%q", CountersPhaseContract, CountersPhasePopulated)
	}
}

// (2)(3) contract phase: phase="contract" present, counters object ABSENT (no false-zero)
func TestCountersContract_Phase_And_AbsentCounters(t *testing.T) {
	h := HealthOutput{SchemaVersion: SchemaVersionCurrent, CountersPhase: CountersPhaseContract}
	b, err := json.Marshal(h)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	s := string(b)
	if !strings.Contains(s, `"counters_phase":"contract"`) {
		t.Errorf("counters_phase must be present and 'contract' in v1.190.0; got: %s", s)
	}
	if strings.Contains(s, `"counters"`) {
		t.Errorf("counters object MUST be ABSENT in contract phase (no false-zero); got: %s", s)
	}
	if !strings.Contains(s, `"schema_version":"1.84.0"`) {
		t.Errorf("schema_version must be 1.84.0; got: %s", s)
	}
}

// (4) populated shape (v1.191): counters object present + correctly typed
func TestCountersContract_PopulatedShape(t *testing.T) {
	h := HealthOutput{
		SchemaVersion: SchemaVersionCurrent,
		CountersPhase: CountersPhasePopulated,
		Counters: &CountersJSON{
			// IP-family split per DESIGN_AMENDMENT_V1_190_IP_FAMILY: bans v4+v6 independent.
			BotScan:   &BotScanCountersJSON{Bans: FamilyCounts{IPv4: 5, IPv6: 2}, FilesDeferred: 7},
			BotGuard:  &BotGuardCountersJSON{Decisions: FamilyCounts{IPv4: 3}, EventbusDrops: 1},
			Whitelist: &WhitelistCountersJSON{Changes: FamilyCounts{IPv6: 4}},
		},
	}
	b, _ := json.Marshal(h)
	s := string(b)
	// family present + independent in JSON
	if !strings.Contains(s, `"bans":{"ipv4":5,"ipv6":2}`) {
		t.Errorf("bans must split by family (ipv4/ipv6) independently; got: %s", s)
	}
	// non-IP-backed counters carry NO family (plain int)
	if !strings.Contains(s, `"files_deferred":7`) || !strings.Contains(s, `"eventbus_drops":1`) {
		t.Errorf("non-IP-backed counters must be plain (no family); got: %s", s)
	}
	var rt HealthOutput
	if err := json.Unmarshal(b, &rt); err != nil {
		t.Fatalf("round-trip unmarshal: %v", err)
	}
	if rt.CountersPhase != "populated" || rt.Counters == nil || rt.Counters.BotScan == nil ||
		rt.Counters.BotScan.Bans.IPv4 != 5 || rt.Counters.BotScan.Bans.IPv6 != 2 ||
		rt.Counters.BotScan.FilesDeferred != 7 || rt.Counters.BotGuard.Decisions.IPv4 != 3 ||
		rt.Counters.BotGuard.EventbusDrops != 1 || rt.Counters.Whitelist.Changes.IPv6 != 4 {
		t.Errorf("populated family-aware counters did not round-trip: %+v", rt.Counters)
	}
}

// (5) old-consumer compat: a consumer that predates the counters fields still parses 1.84.0
func TestCountersContract_OldConsumerCompat(t *testing.T) {
	// emit current (1.84.0) output WITHOUT counters (contract phase)
	cur, _ := json.Marshal(HealthOutput{SchemaVersion: SchemaVersionCurrent, Status: "protected", CountersPhase: CountersPhaseContract})
	// a pre-unfreeze consumer struct (no counters_phase / counters fields)
	type oldHealth struct {
		SchemaVersion string `json:"schema_version"`
		Status        string `json:"status"`
	}
	var old oldHealth
	if err := json.Unmarshal(cur, &old); err != nil {
		t.Fatalf("old consumer must still parse 1.84.0 output: %v", err)
	}
	if old.SchemaVersion != "1.84.0" || old.Status != "protected" {
		t.Errorf("old consumer parsed wrong values: %+v", old)
	}
}
