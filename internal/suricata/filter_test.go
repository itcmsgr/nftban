// =============================================================================
// NFTBan v1.0 - Suricata Filter Matcher Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="filter_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for filter matching logic (signature, category, event)"
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

package suricata

import (
	"testing"
	"time"
)

// =============================================================================
// Helper: create test Config with filters
// =============================================================================

func testConfig(filters map[string]*FilterConfig) *Config {
	return &Config{
		GlobalEnabled:    true,
		DefaultThreshold: 100,
		DefaultBanTime:   30 * time.Minute,
		DefaultAction:    "ban",
		ScoreDecay:       1 * time.Hour,
		Filters:          filters,
	}
}

// =============================================================================
// MatchSignature Tests
// =============================================================================

func TestMatchSignature_Match(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{
		"exploit": {
			Name:     "exploit",
			Enabled:  true,
			Keywords: []string{"exploit", "shellcode"},
		},
	})

	fm := NewFilterMatcher(cfg)
	name, filter := fm.MatchSignature("ET EXPLOIT Apache Struts RCE")

	if name != "exploit" {
		t.Errorf("expected filter name %q, got %q", "exploit", name)
	}
	if filter == nil {
		t.Error("expected non-nil filter")
	}
}

func TestMatchSignature_CaseInsensitive(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{
		"exploit": {
			Name:     "exploit",
			Enabled:  true,
			Keywords: []string{"exploit"},
		},
	})

	fm := NewFilterMatcher(cfg)
	name, _ := fm.MatchSignature("ET EXPLOIT APACHE STRUTS")

	if name != "exploit" {
		t.Errorf("expected case-insensitive match, got %q", name)
	}
}

func TestMatchSignature_NoMatch(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{
		"exploit": {
			Name:     "exploit",
			Enabled:  true,
			Keywords: []string{"exploit"},
		},
	})

	fm := NewFilterMatcher(cfg)
	name, filter := fm.MatchSignature("ET MALWARE Trojan Activity")

	if name != "" {
		t.Errorf("expected empty name for no match, got %q", name)
	}
	if filter != nil {
		t.Error("expected nil filter for no match")
	}
}

func TestMatchSignature_DisabledFilter(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{
		"exploit": {
			Name:     "exploit",
			Enabled:  false, // Disabled
			Keywords: []string{"exploit"},
		},
	})

	fm := NewFilterMatcher(cfg)
	name, filter := fm.MatchSignature("ET EXPLOIT Apache Struts RCE")

	if name != "" {
		t.Errorf("expected no match for disabled filter, got %q", name)
	}
	if filter != nil {
		t.Error("expected nil filter for disabled filter")
	}
}

func TestMatchSignature_MultipleKeywords(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{
		"malware": {
			Name:     "malware",
			Enabled:  true,
			Keywords: []string{"malware", "trojan", "backdoor"},
		},
	})

	fm := NewFilterMatcher(cfg)

	tests := []struct {
		signature string
		want      string
	}{
		{"ET MALWARE Known C&C", "malware"},
		{"ET TROJAN Activity Detected", "malware"},
		{"Backdoor shell detected", "malware"},
		{"ET SCAN Nmap SYN", ""},
	}

	for _, tt := range tests {
		name, _ := fm.MatchSignature(tt.signature)
		if name != tt.want {
			t.Errorf("MatchSignature(%q) = %q, want %q", tt.signature, name, tt.want)
		}
	}
}

// =============================================================================
// MatchCategory Tests
// =============================================================================

func TestMatchCategory_Match(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{
		"scan": {
			Name:     "scan",
			Enabled:  true,
			Keywords: []string{"scan", "reconnaissance"},
		},
	})

	fm := NewFilterMatcher(cfg)
	name, filter := fm.MatchCategory("Network Scan Detection")

	if name != "scan" {
		t.Errorf("expected filter name %q, got %q", "scan", name)
	}
	if filter == nil {
		t.Error("expected non-nil filter")
	}
}

func TestMatchCategory_CaseInsensitive(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{
		"scan": {
			Name:     "scan",
			Enabled:  true,
			Keywords: []string{"scan"},
		},
	})

	fm := NewFilterMatcher(cfg)
	name, _ := fm.MatchCategory("NETWORK SCAN DETECTION")

	if name != "scan" {
		t.Errorf("expected case-insensitive match, got %q", name)
	}
}

func TestMatchCategory_NoMatch(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{
		"scan": {
			Name:     "scan",
			Enabled:  true,
			Keywords: []string{"scan"},
		},
	})

	fm := NewFilterMatcher(cfg)
	name, filter := fm.MatchCategory("Attempted Admin Privilege Gain")

	if name != "" {
		t.Errorf("expected empty name, got %q", name)
	}
	if filter != nil {
		t.Error("expected nil filter")
	}
}

// =============================================================================
// GetFilterForEvent Tests
// =============================================================================

func TestGetFilterForEvent_SignatureFirst(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{
		"exploit": {
			Name:     "exploit",
			Enabled:  true,
			Keywords: []string{"exploit"},
		},
		"scan": {
			Name:     "scan",
			Enabled:  true,
			Keywords: []string{"scan"},
		},
	})

	fm := NewFilterMatcher(cfg)
	// Signature matches "exploit", category matches "scan"
	name, filter := fm.GetFilterForEvent("ET EXPLOIT Apache Struts", "Scan Detection")

	// Signature match should take priority
	if name != "exploit" {
		t.Errorf("expected signature match %q, got %q", "exploit", name)
	}
	if filter == nil {
		t.Error("expected non-nil filter")
	}
}

func TestGetFilterForEvent_FallbackToCategory(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{
		"scan": {
			Name:     "scan",
			Enabled:  true,
			Keywords: []string{"scan"},
		},
	})

	fm := NewFilterMatcher(cfg)
	// Signature doesn't match, but category does
	name, filter := fm.GetFilterForEvent("ET POLICY Something", "Scan Detection")

	if name != "scan" {
		t.Errorf("expected category fallback %q, got %q", "scan", name)
	}
	if filter == nil {
		t.Error("expected non-nil filter")
	}
}

func TestGetFilterForEvent_NoMatch(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{
		"exploit": {
			Name:     "exploit",
			Enabled:  true,
			Keywords: []string{"exploit"},
		},
	})

	fm := NewFilterMatcher(cfg)
	name, filter := fm.GetFilterForEvent("ET INFO Something", "Policy Violation")

	if name != "" {
		t.Errorf("expected no match, got %q", name)
	}
	if filter != nil {
		t.Error("expected nil filter")
	}
}

func TestGetFilterForEvent_EmptyFilters(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{})

	fm := NewFilterMatcher(cfg)
	name, filter := fm.GetFilterForEvent("ET EXPLOIT Something", "Attack")

	if name != "" {
		t.Errorf("expected no match with empty filters, got %q", name)
	}
	if filter != nil {
		t.Error("expected nil filter")
	}
}

// =============================================================================
// Config.GetEnabledFilters Tests
// =============================================================================

func TestGetEnabledFilters(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{
		"exploit": {Name: "exploit", Enabled: true},
		"scan":    {Name: "scan", Enabled: true},
		"policy":  {Name: "policy", Enabled: false},
	})

	enabled := cfg.GetEnabledFilters()
	if len(enabled) != 2 {
		t.Errorf("expected 2 enabled filters, got %d", len(enabled))
	}
	if _, ok := enabled["exploit"]; !ok {
		t.Error("expected exploit in enabled filters")
	}
	if _, ok := enabled["scan"]; !ok {
		t.Error("expected scan in enabled filters")
	}
	if _, ok := enabled["policy"]; ok {
		t.Error("policy should not be in enabled filters")
	}
}

// =============================================================================
// Config.GetFilter Tests
// =============================================================================

func TestGetFilter(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{
		"exploit": {Name: "exploit", Enabled: true},
	})

	filter, ok := cfg.GetFilter("exploit")
	if !ok {
		t.Error("expected to find filter")
	}
	if filter.Name != "exploit" {
		t.Errorf("expected filter name %q, got %q", "exploit", filter.Name)
	}
}

func TestGetFilter_NotFound(t *testing.T) {
	cfg := testConfig(map[string]*FilterConfig{})

	_, ok := cfg.GetFilter("nonexistent")
	if ok {
		t.Error("expected filter not found")
	}
}

// =============================================================================
// Config.parseGlobalSetting Tests
// =============================================================================

func TestParseGlobalSetting(t *testing.T) {
	cfg := &Config{
		GlobalEnabled:    true,
		DefaultThreshold: 100,
		Filters:          make(map[string]*FilterConfig),
	}

	// Test enabled parsing
	cfg.parseGlobalSetting("enabled", "false")
	if cfg.GlobalEnabled {
		t.Error("expected GlobalEnabled=false after setting 'false'")
	}

	cfg.parseGlobalSetting("enabled", "true")
	if !cfg.GlobalEnabled {
		t.Error("expected GlobalEnabled=true after setting 'true'")
	}

	cfg.parseGlobalSetting("enabled", "yes")
	if !cfg.GlobalEnabled {
		t.Error("expected GlobalEnabled=true after setting 'yes'")
	}

	cfg.parseGlobalSetting("enabled", "1")
	if !cfg.GlobalEnabled {
		t.Error("expected GlobalEnabled=true after setting '1'")
	}

	// Test threshold parsing
	cfg.parseGlobalSetting("default_threshold", "200")
	if cfg.DefaultThreshold != 200 {
		t.Errorf("expected DefaultThreshold=200, got %d", cfg.DefaultThreshold)
	}

	// Invalid threshold should not change value
	cfg.parseGlobalSetting("default_threshold", "not_a_number")
	if cfg.DefaultThreshold != 200 {
		t.Errorf("expected DefaultThreshold unchanged at 200, got %d", cfg.DefaultThreshold)
	}

	// Test default_action
	cfg.parseGlobalSetting("default_action", "observe")
	if cfg.DefaultAction != "observe" {
		t.Errorf("expected DefaultAction=%q, got %q", "observe", cfg.DefaultAction)
	}
}
