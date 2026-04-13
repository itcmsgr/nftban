// =============================================================================
// NFTBan v1.78 - Kernel Validator Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="validator-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-05"
// meta:inventory.files="internal/validator/validator_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validator

import (
	"testing"
)

func TestCheckAnchorOrder(t *testing.T) {
	tests := []struct {
		name     string
		actual   []string
		expected []string
		want     bool
	}{
		{
			name: "exact match",
			actual: []string{
				"ANCHOR_HYGIENE", "ANCHOR_TRUSTED", "ANCHOR_BAN",
				"ANCHOR_ESTABLISHED", "ANCHOR_DETECT", "ANCHOR_SERVICE", "ANCHOR_FINAL",
			},
			expected: RequiredAnchors,
			want:     true,
		},
		{
			name:     "wrong order",
			actual:   []string{"ANCHOR_FINAL", "ANCHOR_HYGIENE", "ANCHOR_TRUSTED"},
			expected: RequiredAnchors,
			want:     false,
		},
		{
			name:     "missing anchors",
			actual:   []string{"ANCHOR_HYGIENE", "ANCHOR_TRUSTED"},
			expected: RequiredAnchors,
			want:     false,
		},
		{
			name:     "empty actual",
			actual:   []string{},
			expected: RequiredAnchors,
			want:     false,
		},
		{
			name: "extra anchors allowed",
			actual: []string{
				"ANCHOR_HYGIENE", "EXTRA1", "ANCHOR_TRUSTED", "ANCHOR_BAN",
				"ANCHOR_ESTABLISHED", "ANCHOR_DETECT", "ANCHOR_SERVICE", "EXTRA2", "ANCHOR_FINAL",
			},
			expected: RequiredAnchors,
			want:     true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := checkAnchorOrder(tt.actual, tt.expected)
			if got != tt.want {
				t.Errorf("checkAnchorOrder() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestValidateChains(t *testing.T) {
	// Create a mock document with some chains
	raw := &NftRuleset{
		Nftables: []NftObject{
			{Table: &NftTable{Family: "ip", Name: "nftban"}},
			{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "input"}},
			{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "forward"}},
			// output is missing
		},
	}
	doc := ParseRuleset(raw)

	result := &ValidationResult{Findings: make([]Finding, 0)}
	check := validateChains(doc, "ip", RequiredBaseChains, result)

	if check.AllFound {
		t.Error("AllFound should be false when output chain is missing")
	}

	if len(check.Missing) != 1 || check.Missing[0] != "output" {
		t.Errorf("Missing should contain 'output', got: %v", check.Missing)
	}

	if len(check.Found) != 2 {
		t.Errorf("Found should have 2 chains, got: %d", len(check.Found))
	}
}

func TestEvaluateOverallStatus(t *testing.T) {
	tests := []struct {
		name     string
		result   *ValidationResult
		expected Status
	}{
		{
			name: "all protected",
			result: &ValidationResult{
				Families: []FamilyResult{
					{Status: StatusProtected},
					{Status: StatusProtected},
				},
				Findings: []Finding{},
			},
			expected: StatusProtected,
		},
		{
			name: "one family degraded",
			result: &ValidationResult{
				Families: []FamilyResult{
					{Status: StatusProtected},
					{Status: StatusDegraded},
				},
				Findings: []Finding{
					{Severity: SeverityError, Message: "test"},
				},
			},
			expected: StatusDegraded,
		},
		{
			name: "critical finding",
			result: &ValidationResult{
				Families: []FamilyResult{
					{Status: StatusProtected},
				},
				Findings: []Finding{
					{Severity: SeverityCritical, Message: "critical issue"},
				},
			},
			expected: StatusDown,
		},
		{
			name: "already down",
			result: &ValidationResult{
				Status:   StatusDown,
				Families: []FamilyResult{},
				Findings: []Finding{},
			},
			expected: StatusDown,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := evaluateOverallStatus(tt.result)
			if got != tt.expected {
				t.Errorf("evaluateOverallStatus() = %v, want %v", got, tt.expected)
			}
		})
	}
}

func TestExtractAnchorsFromChain(t *testing.T) {
	// Create mock rules with anchor comments
	raw := &NftRuleset{
		Nftables: []NftObject{
			{Table: &NftTable{Family: "ip", Name: "nftban"}},
			{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "input"}},
			{Rule: &NftRule{
				Family:  "ip",
				Table:   "nftban",
				Chain:   "input",
				Comment: "NFTBAN_ANCHOR:ANCHOR_HYGIENE",
			}},
			{Rule: &NftRule{
				Family:  "ip",
				Table:   "nftban",
				Chain:   "input",
				Comment: "NFTBAN_ANCHOR:ANCHOR_TRUSTED",
			}},
			{Rule: &NftRule{
				Family:  "ip",
				Table:   "nftban",
				Chain:   "input",
				Comment: "NFTBAN_ANCHOR:ANCHOR_FINAL",
			}},
		},
	}
	doc := ParseRuleset(raw)

	anchors := doc.ExtractAnchorsFromChain("ip", "nftban", "input")

	if len(anchors) != 3 {
		t.Errorf("Expected 3 anchors, got %d", len(anchors))
	}

	expected := []string{"ANCHOR_HYGIENE", "ANCHOR_TRUSTED", "ANCHOR_FINAL"}
	for i, exp := range expected {
		if i >= len(anchors) || anchors[i] != exp {
			t.Errorf("Anchor %d: expected %s, got %s", i, exp, anchors[i])
		}
	}
}

func TestFinalGuard(t *testing.T) {
	tests := []struct {
		name        string
		anchors     []string
		wantPresent bool
	}{
		{
			name:        "FINAL at end",
			anchors:     []string{"ANCHOR_HYGIENE", "ANCHOR_FINAL"},
			wantPresent: true,
		},
		{
			name:        "FINAL not at end",
			anchors:     []string{"ANCHOR_FINAL", "ANCHOR_HYGIENE"},
			wantPresent: false,
		},
		{
			name:        "no FINAL",
			anchors:     []string{"ANCHOR_HYGIENE", "ANCHOR_TRUSTED"},
			wantPresent: false,
		},
		{
			name:        "empty",
			anchors:     []string{},
			wantPresent: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Simulate the FINAL GUARD check
			present := false
			if len(tt.anchors) > 0 && tt.anchors[len(tt.anchors)-1] == "ANCHOR_FINAL" {
				present = true
			}

			if present != tt.wantPresent {
				t.Errorf("FINAL present = %v, want %v", present, tt.wantPresent)
			}
		})
	}
}

func TestModuleTruth(t *testing.T) {
	// Create mock doc with DDoS chains
	raw := &NftRuleset{
		Nftables: []NftObject{
			{Table: &NftTable{Family: "ip", Name: "nftban"}},
			{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_sanity"}},
			{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_penalty"}},
			{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_prefix"}},
			{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "ddos_protection"}},
			{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "portscan_detection"}},
			{Set: &NftSet{Family: "ip", Table: "nftban", Name: "whitelist_ipv4"}},
			{Set: &NftSet{Family: "ip", Table: "nftban", Name: "blacklist_ipv4"}},
			{Set: &NftSet{Family: "ip", Table: "nftban", Name: "blacklist_manual_ipv4"}},
			{Set: &NftSet{Family: "ip", Table: "nftban", Name: "tcp_ports_in"}},
			{Set: &NftSet{Family: "ip", Table: "nftban", Name: "udp_ports_in"}},
		},
	}
	doc := ParseRuleset(raw)

	truth := deriveModuleTruth(doc)

	if !truth.DDoS.Enabled {
		t.Error("DDoS should be enabled when all helper chains present")
	}
	if !truth.Portscan.Enabled {
		t.Error("Portscan should be enabled when chain present")
	}
	if !truth.Blacklist.Enabled {
		t.Error("Blacklist should be enabled when sets present")
	}
	if !truth.Whitelist.Enabled {
		t.Error("Whitelist should be enabled when set present")
	}
	if !truth.ServiceAdmission.Enabled {
		t.Error("ServiceAdmission should be enabled when port sets present")
	}
}

// B80-3 (INV-S-008): Empty helper chain detection.
func TestEmptyHelperChain(t *testing.T) {
	tests := []struct {
		name       string
		objects    []NftObject
		wantStatus Status
		wantCode   string
	}{
		{
			name: "helper chain with rules → PROTECTED",
			objects: helperChainObjects(
				withRulesInChain("ddos_sanity", 3),
				withRulesInChain("ddos_penalty", 2),
				withRulesInChain("ddos_prefix", 1),
				withRulesInChain("ddos_protection", 5),
				withRulesInChain("portscan_detection", 2),
			),
			wantStatus: StatusProtected,
			wantCode:   "",
		},
		{
			name: "helper chain exists but empty → DEGRADED",
			objects: helperChainObjects(
				withRulesInChain("ddos_sanity", 3),
				withRulesInChain("ddos_penalty", 2),
				withRulesInChain("ddos_prefix", 1),
				withRulesInChain("ddos_protection", 0),
				withRulesInChain("portscan_detection", 2),
			),
			wantStatus: StatusDegraded,
			wantCode:   CodeChainEmpty,
		},
		{
			name: "multiple empty chains → multiple findings",
			objects: helperChainObjects(
				withRulesInChain("ddos_sanity", 0),
				withRulesInChain("ddos_penalty", 0),
				withRulesInChain("ddos_prefix", 1),
				withRulesInChain("ddos_protection", 5),
				withRulesInChain("portscan_detection", 0),
			),
			wantStatus: StatusDegraded,
			wantCode:   CodeChainEmpty,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			raw := &NftRuleset{Nftables: tt.objects}
			doc := ParseRuleset(raw)
			result := &ValidationResult{Findings: make([]Finding, 0)}
			fr := validateFamily(doc, "ip", result)

			if fr.Status != tt.wantStatus {
				t.Errorf("status = %s, want %s", fr.Status, tt.wantStatus)
			}

			if tt.wantCode != "" {
				found := false
				for _, f := range result.Findings {
					if f.Code == tt.wantCode {
						found = true
						break
					}
				}
				if !found {
					t.Errorf("expected finding code %s not found in %d findings", tt.wantCode, len(result.Findings))
					for _, f := range result.Findings {
						t.Logf("  finding: %s %s %s", f.Code, f.Severity, f.Message)
					}
				}
			}
		})
	}
}

func helperChainObjects(chainSpecs ...chainSpec) []NftObject {
	objects := []NftObject{
		{Table: &NftTable{Family: "ip", Name: "nftban"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "input", Type: "filter", Hook: "input", Policy: "drop"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "forward", Type: "filter", Hook: "forward", Policy: "drop"}},
		{Chain: &NftChain{Family: "ip", Table: "nftban", Name: "output", Type: "filter", Hook: "output", Policy: "accept"}},
	}
	for _, anchor := range RequiredAnchors {
		objects = append(objects, NftObject{Rule: &NftRule{
			Family: "ip", Table: "nftban", Chain: "input",
			Comment: "NFTBAN_ANCHOR:" + anchor,
		}})
	}
	for _, setName := range RequiredSetsIPv4 {
		objects = append(objects, NftObject{Set: &NftSet{Family: "ip", Table: "nftban", Name: setName}})
	}
	for _, spec := range chainSpecs {
		objects = append(objects, NftObject{Chain: &NftChain{
			Family: "ip", Table: "nftban", Name: spec.name,
		}})
		for i := 0; i < spec.ruleCount; i++ {
			objects = append(objects, NftObject{Rule: &NftRule{
				Family: "ip", Table: "nftban", Chain: spec.name,
			}})
		}
	}
	return objects
}

type chainSpec struct {
	name      string
	ruleCount int
}

func withRulesInChain(name string, count int) chainSpec {
	return chainSpec{name: name, ruleCount: count}
}

func TestModuleTruthMissing(t *testing.T) {
	// Create mock doc WITHOUT DDoS chains
	raw := &NftRuleset{
		Nftables: []NftObject{
			{Table: &NftTable{Family: "ip", Name: "nftban"}},
			// No helper chains
		},
	}
	doc := ParseRuleset(raw)

	truth := deriveModuleTruth(doc)

	if truth.DDoS.Enabled {
		t.Error("DDoS should be disabled when helper chains missing")
	}
	if truth.Portscan.Enabled {
		t.Error("Portscan should be disabled when chain missing")
	}
}
