// =============================================================================
// NFTBan v1.0 - Suricata Custom Rule Validator Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="validator_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for rule validation, SID extraction, and sanitization"
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

package customrules

import (
	"testing"
)

// =============================================================================
// Constants Tests
// =============================================================================

func TestSIDRangeConstants(t *testing.T) {
	if MinCustomSID != 9000000 {
		t.Errorf("MinCustomSID = %d, want 9000000", MinCustomSID)
	}
	if MaxCustomSID != 9999999 {
		t.Errorf("MaxCustomSID = %d, want 9999999", MaxCustomSID)
	}
	if MinCustomSID >= MaxCustomSID {
		t.Error("MinCustomSID should be less than MaxCustomSID")
	}
}

// =============================================================================
// ValidateRule Tests
// =============================================================================

func TestValidateRule_EmptyRule(t *testing.T) {
	result, err := ValidateRule("")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Valid {
		t.Error("expected invalid for empty rule")
	}
	if len(result.Errors) == 0 {
		t.Error("expected errors for empty rule")
	}
}

func TestValidateRule_CommentedOut(t *testing.T) {
	result, err := ValidateRule("# alert tcp any any -> any any (msg:\"Test\"; sid:9000001; rev:1;)")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result.Valid {
		t.Error("expected invalid for commented rule")
	}
}

func TestValidateRule_ValidRule(t *testing.T) {
	rule := `alert tcp any any -> any any (msg:"NFTBan Test Rule"; sid:9000001; rev:1;)`
	result, err := ValidateRule(rule)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Note: validateWithSuricata may add a warning if suricata binary is not found,
	// which would cause result.Valid to be false. We check specific fields instead.
	if result.SID != 9000001 {
		t.Errorf("expected SID 9000001, got %d", result.SID)
	}
	if result.Action != "alert" {
		t.Errorf("expected action %q, got %q", "alert", result.Action)
	}
	if result.Message != "NFTBan Test Rule" {
		t.Errorf("expected message %q, got %q", "NFTBan Test Rule", result.Message)
	}
}

func TestValidateRule_DropAction(t *testing.T) {
	rule := `drop tcp any any -> any any (msg:"Drop Rule"; sid:9000002; rev:1;)`
	result, err := ValidateRule(rule)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result.Action != "drop" {
		t.Errorf("expected action %q, got %q", "drop", result.Action)
	}
}

func TestValidateRule_RejectAction(t *testing.T) {
	rule := `reject tcp any any -> any any (msg:"Reject Rule"; sid:9000003; rev:1;)`
	result, err := ValidateRule(rule)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result.Action != "reject" {
		t.Errorf("expected action %q, got %q", "reject", result.Action)
	}
}

func TestValidateRule_PassAction(t *testing.T) {
	rule := `pass tcp any any -> any any (msg:"Pass Rule"; sid:9000004; rev:1;)`
	result, err := ValidateRule(rule)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result.Action != "pass" {
		t.Errorf("expected action %q, got %q", "pass", result.Action)
	}
}

// =============================================================================
// validateBasicStructure Tests
// =============================================================================

func TestValidateBasicStructure_InvalidAction(t *testing.T) {
	result := &ValidationResult{Valid: true, Errors: make([]string, 0)}
	err := validateBasicStructure("invalid tcp any any -> any any (msg:\"test\"; sid:9000001;)", result)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	found := false
	for _, e := range result.Errors {
		if e == "Rule must start with action: alert, drop, reject, or pass" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected action error, got: ", result.Errors)
	}
}

func TestValidateBasicStructure_MissingProtocol(t *testing.T) {
	result := &ValidationResult{Valid: true, Errors: make([]string, 0)}
	// No valid protocol
	err := validateBasicStructure("alert xyz any any -> any any (msg:\"test\"; sid:9000001;)", result)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	found := false
	for _, e := range result.Errors {
		if e == "Rule must specify protocol (tcp, udp, icmp, ip, http, etc.)" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected protocol error, got: ", result.Errors)
	}
}

func TestValidateBasicStructure_MissingParentheses(t *testing.T) {
	result := &ValidationResult{Valid: true, Errors: make([]string, 0)}
	err := validateBasicStructure("alert tcp any any -> any any msg:\"test\"; sid:9000001;", result)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	found := false
	for _, e := range result.Errors {
		if e == "Rule must contain options in parentheses" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected parentheses error, got: ", result.Errors)
	}
}

func TestValidateBasicStructure_UnbalancedParentheses(t *testing.T) {
	result := &ValidationResult{Valid: true, Errors: make([]string, 0)}
	// Rule with opening ( but no closing ) — validator catches as missing parentheses
	err := validateBasicStructure("alert tcp any any -> any any (msg:\"test\"; sid:9000001;", result)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(result.Errors) == 0 {
		t.Error("expected validation error for unbalanced parentheses")
	}
	// Validator reports "Rule must contain options in parentheses" for malformed option blocks
	found := false
	for _, e := range result.Errors {
		if e == "Rule must contain options in parentheses" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected parentheses error, got: ", result.Errors)
	}
}

func TestValidateBasicStructure_MissingMsg(t *testing.T) {
	result := &ValidationResult{Valid: true, Errors: make([]string, 0)}
	err := validateBasicStructure("alert tcp any any -> any any (sid:9000001;)", result)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	found := false
	for _, e := range result.Errors {
		if e == "Rule must contain 'msg:' field" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected msg error, got: ", result.Errors)
	}
}

func TestValidateBasicStructure_ExtractsMessage(t *testing.T) {
	result := &ValidationResult{Valid: true, Errors: make([]string, 0)}
	err := validateBasicStructure(`alert tcp any any -> any any (msg:"My Custom Rule"; sid:9000001; rev:1;)`, result)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result.Message != "My Custom Rule" {
		t.Errorf("expected message %q, got %q", "My Custom Rule", result.Message)
	}
}

// =============================================================================
// validateSID Tests
// =============================================================================

func TestValidateSID_ValidSID(t *testing.T) {
	result := &ValidationResult{Valid: true, Errors: make([]string, 0)}
	err := validateSID(`alert tcp any any -> any any (msg:"test"; sid:9000001; rev:1;)`, result)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if result.SID != 9000001 {
		t.Errorf("expected SID 9000001, got %d", result.SID)
	}
	// Should have no SID-related errors
	for _, e := range result.Errors {
		t.Errorf("unexpected error: %s", e)
	}
}

func TestValidateSID_OutOfRange(t *testing.T) {
	tests := []struct {
		name string
		rule string
		sid  int
	}{
		{"too_low", `alert tcp any any -> any any (msg:"test"; sid:1000; rev:1;)`, 1000},
		{"too_high", `alert tcp any any -> any any (msg:"test"; sid:10000000; rev:1;)`, 10000000},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := &ValidationResult{Valid: true, Errors: make([]string, 0)}
			err := validateSID(tt.rule, result)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			if result.SID != tt.sid {
				t.Errorf("expected SID %d, got %d", tt.sid, result.SID)
			}

			// Should have range error
			found := false
			for _, e := range result.Errors {
				if len(e) > 10 { // Basic check for error message
					found = true
					break
				}
			}
			if !found {
				t.Error("expected SID range error")
			}
		})
	}
}

func TestValidateSID_MissingSID(t *testing.T) {
	result := &ValidationResult{Valid: true, Errors: make([]string, 0)}
	err := validateSID(`alert tcp any any -> any any (msg:"test"; rev:1;)`, result)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	found := false
	for _, e := range result.Errors {
		if e == "Rule must contain 'sid:' field" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected missing SID error")
	}
}

func TestValidateSID_MissingRev(t *testing.T) {
	result := &ValidationResult{Valid: true, Errors: make([]string, 0)}
	err := validateSID(`alert tcp any any -> any any (msg:"test"; sid:9000001;)`, result)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	found := false
	for _, e := range result.Errors {
		if e == "Rule should contain 'rev:' field (recommended)" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected missing rev warning")
	}
}

// =============================================================================
// SanitizeRule Tests
// =============================================================================

func TestSanitizeRule(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{
			name:  "trim_whitespace",
			input: "  alert tcp any any -> any any (msg:\"test\"; sid:9000001;)  ",
			want:  `alert tcp any any -> any any (msg:"test"; sid:9000001;)`,
		},
		{
			name:  "normalize_spaces",
			input: "alert  tcp   any  any  ->  any  any  (msg:\"test\";  sid:9000001;)",
			want:  `alert tcp any any -> any any (msg:"test"; sid:9000001;)`,
		},
		{
			name:  "remove_space_before_semicolon",
			input: "alert tcp any any -> any any (msg:\"test\" ; sid:9000001 ;)",
			want:  `alert tcp any any -> any any (msg:"test"; sid:9000001;)`,
		},
		{
			name:  "already_clean",
			input: `alert tcp any any -> any any (msg:"test"; sid:9000001; rev:1;)`,
			want:  `alert tcp any any -> any any (msg:"test"; sid:9000001; rev:1;)`,
		},
		{
			name:  "empty_string",
			input: "",
			want:  "",
		},
		{
			name:  "only_whitespace",
			input: "   ",
			want:  "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := SanitizeRule(tt.input)
			if got != tt.want {
				t.Errorf("SanitizeRule(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}
