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

// (6) nft.anchors[] contract: ABSENT in contract phase (no false-zero), present+typed when populated.
func TestNFTAnchorsContract_AbsentThenPopulated(t *testing.T) {
	// contract phase: "nft" object MUST be absent (omitempty, NFT==nil)
	cb, _ := json.Marshal(HealthOutput{SchemaVersion: SchemaVersionCurrent, CountersPhase: CountersPhaseContract})
	if strings.Contains(string(cb), `"nft"`) {
		t.Errorf("nft object MUST be ABSENT in contract phase (no false-zero anchors); got: %s", cb)
	}
	// populated (v1.191) shape: anchors carry NORMALIZED family ipv4/ipv6
	h := HealthOutput{
		SchemaVersion: SchemaVersionCurrent,
		CountersPhase: CountersPhasePopulated,
		NFT: &NFTCountersJSON{Anchors: []NFTAnchorJSON{
			{Family: FamilyIPv4, Anchor: "anchor_hygiene", Packets: 10, Bytes: 800},
			{Family: FamilyIPv6, Anchor: "anchor_final", Packets: 2, Bytes: 96},
		}},
	}
	b, _ := json.Marshal(h)
	s := string(b)
	if !strings.Contains(s, `"family":"ipv4"`) || !strings.Contains(s, `"family":"ipv6"`) {
		t.Errorf("nft.anchors[] must use normalized ipv4/ipv6; got: %s", s)
	}
	if !strings.Contains(s, `"anchor":"anchor_hygiene"`) || !strings.Contains(s, `"anchor":"anchor_final"`) {
		t.Errorf("nft.anchors[] must carry anchor name; got: %s", s)
	}
	// SOS-3: JSON must NEVER emit raw nft family ip/ip6
	if strings.Contains(s, `"family":"ip"`) || strings.Contains(s, `"family":"ip6"`) {
		t.Errorf("SOS-3 violation: JSON must NOT emit raw nft family ip/ip6; got: %s", s)
	}
	var rt HealthOutput
	if err := json.Unmarshal(b, &rt); err != nil {
		t.Fatalf("round-trip: %v", err)
	}
	if rt.NFT == nil || len(rt.NFT.Anchors) != 2 || rt.NFT.Anchors[0].Family != FamilyIPv4 ||
		rt.NFT.Anchors[0].Packets != 10 || rt.NFT.Anchors[1].Family != FamilyIPv6 {
		t.Errorf("nft.anchors[] did not round-trip: %+v", rt.NFT)
	}
}

// (7) SOS-3 family normalization: nft ip→ipv4, ip6→ipv6; one JSON vocabulary.
func TestNormalizeNFTFamily_SOS3(t *testing.T) {
	cases := map[string]string{
		"ip":    FamilyIPv4,    // nft IPv4 table → JSON ipv4 (bridges Prometheus family="ip")
		"ipv4":  FamilyIPv4,    // already-normalized passthrough
		"ip6":   FamilyIPv6,    // nft IPv6 table → JSON ipv6 (bridges Prometheus family="ip6")
		"ipv6":  FamilyIPv6,    // already-normalized passthrough
		"inet":  FamilyInet,    // genuinely table-level; never fake-split
		"":      FamilyUnknown, // missing → unknown (defect signal on per-IP/anchor counters)
		"bogus": FamilyUnknown,
	}
	for in, want := range cases {
		if got := NormalizeNFTFamily(in); got != want {
			t.Errorf("NormalizeNFTFamily(%q) = %q; want %q", in, got, want)
		}
	}
	// the JSON vocabulary must be exactly {ipv4,ipv6,inet,unknown}
	if FamilyIPv4 != "ipv4" || FamilyIPv6 != "ipv6" || FamilyInet != "inet" || FamilyUnknown != "unknown" {
		t.Fatalf("JSON family vocabulary drifted: %q/%q/%q/%q", FamilyIPv4, FamilyIPv6, FamilyInet, FamilyUnknown)
	}
}

// (5) old-consumer compat: a consumer that predates the counters fields still parses 1.84.0
func TestCountersContract_OldConsumerCompat(t *testing.T) {
	// emit FULLY-POPULATED (v1.191-shape) 1.84.0 output incl. counters + nft.anchors[]
	// to prove a pre-unfreeze consumer ignores ALL added fields (additive compat).
	cur, _ := json.Marshal(HealthOutput{
		SchemaVersion: SchemaVersionCurrent, Status: "protected", CountersPhase: CountersPhasePopulated,
		Counters: &CountersJSON{BotScan: &BotScanCountersJSON{Bans: FamilyCounts{IPv4: 1}}},
		NFT:      &NFTCountersJSON{Anchors: []NFTAnchorJSON{{Family: FamilyIPv4, Anchor: "anchor_ban", Packets: 1}}},
	})
	// a pre-unfreeze consumer struct (no counters_phase / counters / nft fields)
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
