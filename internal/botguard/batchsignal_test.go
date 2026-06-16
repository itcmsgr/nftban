// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: Structured Batch-Signal Accessor Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Verify the v1.191 8B structured batch-signal contract + back-compat.
//
// meta:name="botguard_batchsignal_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Unit tests for structured request-class/family accessors"
// meta:inventory.files="batchsignal_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"encoding/json"
	"testing"
)

// v1.191 8B increment 2 — structured batch-signal contract + back-compat.

func TestBatchSignal_OldLineStillParses(t *testing.T) {
	line := `{"ip":"1.2.3.4","score":80,"reasons":["botscan-404","404_flood"],"action":"ban","ts":1000}`
	var s BatchSignal
	if err := json.Unmarshal([]byte(line), &s); err != nil {
		t.Fatalf("old (pre-v1.191) signal line must still parse: %v", err)
	}
	if s.IP != "1.2.3.4" || s.Score != 80 || s.Action != "ban" || s.TS != 1000 {
		t.Fatalf("existing fields lost: %+v", s)
	}
	if got := s.NormalizedRequestClass(); got != "mixed" {
		t.Fatalf("missing request_class must default to mixed, got %q", got)
	}
	if got := s.ResolvedFamily(); got != "ipv4" {
		t.Fatalf("missing family must derive ipv4 from IP, got %q", got)
	}
}

func TestBatchSignal_NewLineParsesAllFields(t *testing.T) {
	line := `{"ip":"2001:db8::1","score":90,"reasons":["x"],"action":"ban","ts":1,"family":"ipv6","request_class":"dynamic_abuse","confidence":75}`
	var s BatchSignal
	if err := json.Unmarshal([]byte(line), &s); err != nil {
		t.Fatalf("new signal line must parse: %v", err)
	}
	if got := s.ResolvedFamily(); got != "ipv6" {
		t.Fatalf("family = ipv6, got %q", got)
	}
	if got := s.NormalizedRequestClass(); got != "dynamic_abuse" {
		t.Fatalf("request_class = dynamic_abuse, got %q", got)
	}
	if s.Confidence != 75 {
		t.Fatalf("confidence = 75, got %d", s.Confidence)
	}
}

func TestBatchSignal_MissingRequestClassDefaultsMixed(t *testing.T) {
	s := BatchSignal{IP: "1.2.3.4", Family: "ipv4"}
	if got := s.NormalizedRequestClass(); got != "mixed" {
		t.Fatalf("missing request_class -> mixed, got %q", got)
	}
}

func TestBatchSignal_InvalidRequestClassMapsMixed(t *testing.T) {
	s := BatchSignal{IP: "1.2.3.4", RequestClass: "totally-bogus"}
	if got := s.NormalizedRequestClass(); got != "mixed" {
		t.Fatalf("invalid request_class must map safely to mixed, got %q", got)
	}
}

func TestBatchSignal_FamilyExplicitAndDerivedAndUnknown(t *testing.T) {
	cases := []struct {
		ip, family, want string
	}{
		{"10.0.0.1", "", "ipv4"},      // derived v4
		{"fe80::1", "", "ipv6"},       // derived v6
		{"bad-ip", "ipv4", "ipv4"},    // explicit family wins over unparseable IP
		{"bad-ip", "", "unknown"},     // unparseable + no family -> unknown
		{"1.2.3.4", "ipv6", "ipv6"},   // explicit family is authoritative (trusted from producer)
	}
	for _, c := range cases {
		s := BatchSignal{IP: c.ip, Family: c.family}
		if got := s.ResolvedFamily(); got != c.want {
			t.Fatalf("ResolvedFamily(ip=%q,family=%q) = %q, want %q", c.ip, c.family, got, c.want)
		}
	}
}

// The daemon must NOT infer class from the free-text Reasons when a structured
// request_class is present: reasons say "404_flood" but the structured class is "scanner".
func TestBatchSignal_StructuredClassNotInferredFromReasons(t *testing.T) {
	s := BatchSignal{
		IP:           "1.2.3.4",
		Reasons:      []string{"404_flood", "wp_probe"},
		RequestClass: "scanner",
	}
	if got := s.NormalizedRequestClass(); got != "scanner" {
		t.Fatalf("must use structured request_class (scanner), not grep Reasons, got %q", got)
	}
}
