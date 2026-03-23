// =============================================================================
// NFTBan v1.0 - Suricata Recommendations Analyzer Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="analyzer_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for isAttackCategoryMatch and recommendation type constants"
// meta:input="Test cases"
// meta:output="Test results"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package recommendations

import (
	"testing"
)

// =============================================================================
// isAttackCategoryMatch Tests
// =============================================================================

func TestIsAttackCategoryMatch(t *testing.T) {
	tests := []struct {
		name     string
		category string
		want     bool
	}{
		// Direct matches
		{"exploit", "exploit", true},
		{"attack", "attack", true},
		{"shellcode", "shellcode", true},
		{"trojan", "trojan", true},
		{"malware", "malware", true},
		{"web_app_attack", "web-application-attack", true},
		{"sql_injection", "sql-injection", true},

		// Case insensitive
		{"case_exploit", "EXPLOIT", true},
		{"case_malware", "Malware", true},
		{"case_trojan", "TROJAN", true},

		// Compound categories (substring match)
		{"emerging_exploit", "emerging-exploit", true},
		{"et_trojan", "ET TROJAN Activity", true},
		{"web_attack", "web-application-attack-attempt", true},

		// Non-attack categories
		{"policy", "policy", false},
		{"info", "info", false},
		{"dns", "dns", false},
		{"scan", "scan", false},
		{"empty", "", false},
		{"benign", "normal-traffic", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isAttackCategoryMatch(tt.category)
			if got != tt.want {
				t.Errorf("isAttackCategoryMatch(%q) = %v, want %v", tt.category, got, tt.want)
			}
		})
	}
}

// =============================================================================
// RecommendationType Constants Tests
// =============================================================================

func TestRecommendationTypeConstants(t *testing.T) {
	// Verify all types are unique and non-empty
	types := []RecommendationType{
		FalsePositive,
		NoiseReduction,
		DropMode,
		DisableRule,
		InvestigateFurther,
	}

	seen := make(map[RecommendationType]bool)
	for _, rt := range types {
		if rt == "" {
			t.Error("empty RecommendationType found")
		}
		if seen[rt] {
			t.Errorf("duplicate RecommendationType: %q", rt)
		}
		seen[rt] = true
	}
}

func TestRecommendationTypeValues(t *testing.T) {
	if FalsePositive != "false_positive" {
		t.Errorf("FalsePositive = %q, want %q", FalsePositive, "false_positive")
	}
	if NoiseReduction != "noise_reduction" {
		t.Errorf("NoiseReduction = %q, want %q", NoiseReduction, "noise_reduction")
	}
	if DropMode != "drop_mode" {
		t.Errorf("DropMode = %q, want %q", DropMode, "drop_mode")
	}
	if DisableRule != "disable_rule" {
		t.Errorf("DisableRule = %q, want %q", DisableRule, "disable_rule")
	}
	if InvestigateFurther != "investigate" {
		t.Errorf("InvestigateFurther = %q, want %q", InvestigateFurther, "investigate")
	}
}

// =============================================================================
// attackCategorySet Tests
// =============================================================================

func TestAttackCategorySet_Populated(t *testing.T) {
	if len(attackCategorySet) == 0 {
		t.Error("attackCategorySet should not be empty")
	}

	expectedKeys := []string{
		"exploit", "attack", "shellcode", "trojan",
		"malware", "web-application-attack", "sql-injection",
	}

	for _, key := range expectedKeys {
		if _, ok := attackCategorySet[key]; !ok {
			t.Errorf("attackCategorySet missing key %q", key)
		}
	}
}
