// =============================================================================
// NFTBan v1.81 - Health Mapper Tests (M81-6 Schema Compliance)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="health_mapper_test"
// meta:type="test"
// meta:version="1.81.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Tests that MapToHealthOutput produces schema-compliant JSON"
// meta:inventory.files="internal/validator/health_mapper_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validator

import (
	"encoding/json"
	"testing"
	"time"
)

func TestMapToHealthOutput_SchemaVersion(t *testing.T) {
	r := &ValidationResult{
		Status:    StatusProtected,
		Timestamp: time.Date(2026, 4, 14, 10, 0, 0, 0, time.UTC),
	}
	h := MapToHealthOutput(r)
	if h.SchemaVersion != "1.81.0" {
		t.Errorf("schema_version = %s, want 1.81.0", h.SchemaVersion)
	}
}

func TestMapToHealthOutput_StatusValues(t *testing.T) {
	tests := []struct {
		status Status
		want   string
	}{
		{StatusProtected, "protected"},
		{StatusIdle, "idle"},
		{StatusDegraded, "degraded"},
		{StatusDown, "down"},
	}
	for _, tt := range tests {
		r := &ValidationResult{Status: tt.status, Timestamp: time.Now()}
		h := MapToHealthOutput(r)
		if h.Status != tt.want {
			t.Errorf("status %s mapped to %s, want %s", tt.status, h.Status, tt.want)
		}
	}
}

func TestMapModule_DisabledOmitsAxes(t *testing.T) {
	h := &ModuleHealth{Config: ConfigDisabled}
	j := mapModule(h, true)

	if j.Config != "disabled" {
		t.Errorf("config = %s, want disabled", j.Config)
	}
	if j.Structural != "" {
		t.Errorf("structural should be omitted for disabled, got %s", j.Structural)
	}
	if j.Runtime != "" {
		t.Errorf("runtime should be omitted for disabled, got %s", j.Runtime)
	}
	if j.Effective != "" {
		t.Errorf("effective should be omitted for disabled, got %s", j.Effective)
	}
}

func TestMapModule_KernelOnlyOmitsRuntime(t *testing.T) {
	h := &ModuleHealth{
		Config:     ConfigEnabled,
		Structural: StructuralPresent,
		Runtime:    RuntimeRunning, // should be ignored for kernel-only
		Effective:  EffectiveEnforcing,
	}
	j := mapModule(h, false) // daemonDependent = false

	if j.Runtime != "" {
		t.Errorf("runtime should be omitted for kernel-only module, got %s", j.Runtime)
	}
	if j.Effective != "enforcing" {
		t.Errorf("effective = %s, want enforcing", j.Effective)
	}
}

func TestMapModule_DaemonDependentIncludesRuntime(t *testing.T) {
	h := &ModuleHealth{
		Config:     ConfigEnabled,
		Structural: StructuralPresent,
		Runtime:    RuntimeRunning,
		Effective:  EffectiveIdle,
	}
	j := mapModule(h, true) // daemonDependent = true

	if j.Runtime != "running" {
		t.Errorf("runtime = %s, want running (lowercase)", j.Runtime)
	}
}

func TestNormalizeRuntime(t *testing.T) {
	tests := []struct {
		in   RuntimeState
		want string
	}{
		{RuntimeRunning, "running"},
		{RuntimeStopped, "stopped"},
		{RuntimeError, "error"},
	}
	for _, tt := range tests {
		got := normalizeRuntime(tt.in)
		if got != tt.want {
			t.Errorf("normalizeRuntime(%s) = %s, want %s", tt.in, got, tt.want)
		}
	}
}

func TestMapBlacklist(t *testing.T) {
	b := &BlacklistHealth{
		Manual: BlacklistSubHealth{State: "idle", Entries: 0},
		Feeds:  BlacklistSubHealth{State: "loaded", Entries: 847},
		Geoban: BlacklistSubHealth{State: "degraded"},
	}
	j := mapBlacklist(b)

	if j.Manual.State != "idle" {
		t.Errorf("manual state = %s, want idle", j.Manual.State)
	}
	if j.Feeds.State != "loaded" {
		t.Errorf("feeds state = %s, want loaded", j.Feeds.State)
	}
	if j.Feeds.Entries != 847 {
		t.Errorf("feeds entries = %d, want 847", j.Feeds.Entries)
	}
	if j.Geoban.State != "degraded" {
		t.Errorf("geoban state = %s, want degraded", j.Geoban.State)
	}
}

func TestMapConsistency_DefaultOK(t *testing.T) {
	c := mapConsistency()
	if c.KernelVsValidator != "ok" {
		t.Errorf("kernel_vs_validator = %s, want ok", c.KernelVsValidator)
	}
}

func TestMapFindings(t *testing.T) {
	findings := []Finding{
		{Code: "VAL-SERVICE-001", Severity: SeverityError, Component: "service", Message: "nftband stopped"},
		{Code: "VAL-CHAIN-004", Severity: SeverityError, Component: "chain", Family: "ip", Message: "empty chain"},
	}
	out := mapFindings(findings)

	if len(out) != 2 {
		t.Fatalf("findings count = %d, want 2", len(out))
	}
	if out[0].Code != "VAL-SERVICE-001" {
		t.Errorf("finding[0].code = %s, want VAL-SERVICE-001", out[0].Code)
	}
	if out[1].Family != "ip" {
		t.Errorf("finding[1].family = %s, want ip", out[1].Family)
	}
}

func TestFullOutput_ValidJSON(t *testing.T) {
	// Build a complete ValidationResult and verify the output is valid JSON
	// with no unexpected nulls.
	r := &ValidationResult{
		Status:    StatusProtected,
		Timestamp: time.Date(2026, 4, 14, 10, 0, 0, 0, time.UTC),
		ServiceState: ServiceState{
			Nftband:       RuntimeRunning,
			NftbandDetail: "active",
		},
		Modules: ModuleHealthMap{
			BotGuard: &ModuleHealth{Config: ConfigDisabled},
			DDoS: &ModuleHealth{
				Config:     ConfigEnabled,
				Structural: StructuralPresent,
				Effective:  EffectiveEnforcing,
			},
			Portscan: &ModuleHealth{
				Config:     ConfigEnabled,
				Structural: StructuralPresent,
				Effective:  EffectiveIdle,
			},
			LoginMon: &ModuleHealth{
				Config:     ConfigEnabled,
				Structural: StructuralPresent,
				Runtime:    RuntimeRunning,
				Effective:  EffectiveIdle,
			},
			Blacklist: &BlacklistHealth{
				Manual: BlacklistSubHealth{State: "idle"},
				Feeds:  BlacklistSubHealth{State: "loaded"},
				Geoban: BlacklistSubHealth{State: "disabled"},
			},
		},
		Findings: []Finding{},
	}

	h := MapToHealthOutput(r)
	data, err := json.MarshalIndent(h, "", "  ")
	if err != nil {
		t.Fatalf("json marshal failed: %v", err)
	}

	jsonStr := string(data)

	// Schema version present
	if h.SchemaVersion != "1.81.0" {
		t.Errorf("schema_version missing or wrong")
	}

	// Status is vocabulary-approved
	if h.Status != "protected" {
		t.Errorf("status = %s, want protected", h.Status)
	}

	// No "null" in output (hard constraint per M81-6)
	if contains(jsonStr, "null") {
		t.Errorf("JSON output contains null — violates M81-6 no-nulls rule:\n%s", jsonStr)
	}

	// BotGuard disabled = config only
	if h.Modules.BotGuard.Structural != "" {
		t.Errorf("disabled botguard should not have structural field")
	}

	// DDoS kernel-only = no runtime
	if h.Modules.DDoS.Runtime != "" {
		t.Errorf("kernel-only ddos should not have runtime field")
	}

	// LoginMon daemon-dependent = has runtime
	if h.Modules.LoginMon.Runtime != "running" {
		t.Errorf("loginmon runtime = %s, want running", h.Modules.LoginMon.Runtime)
	}

	// Consistency stub present
	if h.Consistency.KernelVsValidator != "ok" {
		t.Errorf("consistency stub = %s, want ok", h.Consistency.KernelVsValidator)
	}

	// Findings is empty array, not null
	if h.Findings == nil {
		t.Errorf("findings is nil — should be empty array")
	}
}

// contains checks if a string contains a substring.
func contains(s, sub string) bool {
	return len(s) >= len(sub) && searchString(s, sub)
}

func searchString(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
