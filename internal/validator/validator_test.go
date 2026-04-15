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
	"os/exec"
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
			name: "all protected families no active modules → idle",
			result: &ValidationResult{
				Families: []FamilyResult{
					{Status: StatusProtected},
					{Status: StatusProtected},
				},
				Findings: []Finding{},
				Modules:  ModuleHealthMap{},
			},
			expected: StatusIdle,
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

// v1.86 B86-1: TestModuleTruth deleted — ModuleTruth removed.
// Module health tests are in module_health_test.go (ModuleHealthMap-based).

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
				withRulesInChain("http_bot_guard", 4),
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
				withRulesInChain("http_bot_guard", 4),
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
				withRulesInChain("http_bot_guard", 4),
				withRulesInChain("portscan_detection", 0),
			),
			wantStatus: StatusDegraded,
			wantCode:   CodeChainEmpty,
		},
		{
			name: "module disabled (no helper chains at all) → PROTECTED",
			objects: helperChainObjects(),
			wantStatus: StatusProtected,
			wantCode:   "",
		},
		{
			name: "BotGuard disabled (only DDoS chains present with rules) → PROTECTED",
			objects: helperChainObjects(
				withRulesInChain("ddos_sanity", 3),
				withRulesInChain("ddos_penalty", 2),
				withRulesInChain("ddos_prefix", 1),
				withRulesInChain("ddos_protection", 5),
			),
			wantStatus: StatusProtected,
			wantCode:   "",
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

// v1.86 B86-1: TestModuleTruthMissing deleted — ModuleTruth removed.

// B80-4: Service-state checks.
// The validator must report DEGRADED when nftband is not active,
// even if kernel structure is perfect.

// mockServiceChecker implements ServiceChecker for testing.
type mockServiceChecker struct {
	state  RuntimeState
	detail string
}

func (m mockServiceChecker) CheckUnit(_ string) (RuntimeState, string) {
	return m.state, m.detail
}

func TestServiceStateRunning(t *testing.T) {
	SetServiceChecker(mockServiceChecker{state: RuntimeRunning, detail: "active"})
	defer SetServiceChecker(SystemdChecker{})

	ss := checkServiceState()
	if ss.Nftband != RuntimeRunning {
		t.Errorf("expected RUNNING, got %s", ss.Nftband)
	}
}

func TestServiceStateStopped(t *testing.T) {
	SetServiceChecker(mockServiceChecker{state: RuntimeStopped, detail: "inactive"})
	defer SetServiceChecker(SystemdChecker{})

	ss := checkServiceState()
	if ss.Nftband != RuntimeStopped {
		t.Errorf("expected STOPPED, got %s", ss.Nftband)
	}
}

func TestServiceStateError(t *testing.T) {
	// Covers the case where systemctl itself fails (e.g. D-Bus error).
	SetServiceChecker(mockServiceChecker{state: RuntimeError, detail: "unknown"})
	defer SetServiceChecker(SystemdChecker{})

	ss := checkServiceState()
	if ss.Nftband != RuntimeError {
		t.Errorf("expected ERROR, got %s", ss.Nftband)
	}
}

func TestServiceStateActivating(t *testing.T) {
	// ADJ-2: "activating" is a transition state during daemon startup.
	// It must map to STOPPED (not ERROR) to avoid misleading findings
	// during rebuild windows when the daemon restarts.
	SetServiceChecker(mockServiceChecker{state: RuntimeStopped, detail: "activating"})
	defer SetServiceChecker(SystemdChecker{})

	ss := checkServiceState()
	if ss.Nftband != RuntimeStopped {
		t.Errorf("expected STOPPED during activation, got %s", ss.Nftband)
	}
	if ss.NftbandDetail != "activating" {
		t.Errorf("expected detail='activating', got '%s'", ss.NftbandDetail)
	}
}

func TestServiceStoppedProducesFinding(t *testing.T) {
	// Daemon stopped + clean families → VAL-SERVICE-001 + DEGRADED.
	SetServiceChecker(mockServiceChecker{state: RuntimeStopped, detail: "inactive"})
	defer SetServiceChecker(SystemdChecker{})

	result := &ValidationResult{
		Families: []FamilyResult{
			{Status: StatusProtected},
			{Status: StatusProtected},
		},
		Findings: make([]Finding, 0),
	}

	ss := checkServiceState()
	result.ServiceState = ss
	if ss.Nftband != RuntimeRunning {
		result.Findings = append(result.Findings, Finding{
			Code:     CodeServiceDown,
			Severity: SeverityError,
			Component: "service",
			Message:  "nftband not running (state: " + string(ss.Nftband) + ")",
		})
	}

	status := evaluateOverallStatus(result)
	if status != StatusDegraded {
		t.Errorf("expected DEGRADED when nftband stopped, got %s", status)
	}

	found := false
	for _, f := range result.Findings {
		if f.Code == CodeServiceDown {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected VAL-SERVICE-001 finding when nftband is stopped")
	}
}

func TestServiceErrorProducesFinding(t *testing.T) {
	// Systemctl query error + clean families → VAL-SERVICE-001 + DEGRADED.
	SetServiceChecker(mockServiceChecker{state: RuntimeError, detail: "unknown"})
	defer SetServiceChecker(SystemdChecker{})

	result := &ValidationResult{
		Families: []FamilyResult{
			{Status: StatusProtected},
			{Status: StatusProtected},
		},
		Findings: make([]Finding, 0),
	}

	ss := checkServiceState()
	result.ServiceState = ss
	if ss.Nftband != RuntimeRunning {
		result.Findings = append(result.Findings, Finding{
			Code:     CodeServiceDown,
			Severity: SeverityError,
			Component: "service",
			Message:  "nftband query error (state: " + string(ss.Nftband) + ")",
		})
	}

	status := evaluateOverallStatus(result)
	if status != StatusDegraded {
		t.Errorf("expected DEGRADED when service check errors, got %s", status)
	}
}

func TestServiceRunningNoFinding(t *testing.T) {
	// Daemon running + clean families + no active modules → IDLE (not PROTECTED).
	// Per M81-4: PROTECTED requires at least one module ACTIVE/ENFORCING.
	// With empty Modules map (no modules reporting), all are idle → IDLE.
	SetServiceChecker(mockServiceChecker{state: RuntimeRunning, detail: "active"})
	defer SetServiceChecker(SystemdChecker{})

	result := &ValidationResult{
		Families: []FamilyResult{
			{Status: StatusProtected},
			{Status: StatusProtected},
		},
		Findings: make([]Finding, 0),
		Modules:  ModuleHealthMap{},
	}

	ss := checkServiceState()
	result.ServiceState = ss
	if ss.Nftband != RuntimeRunning {
		result.Findings = append(result.Findings, Finding{
			Code:     CodeServiceDown,
			Severity: SeverityError,
		})
	}

	status := evaluateOverallStatus(result)
	if status != StatusIdle {
		t.Errorf("expected IDLE when nftband running, families clean, no active modules, got %s", status)
	}

	for _, f := range result.Findings {
		if f.Code == CodeServiceDown {
			t.Error("should NOT have VAL-SERVICE-001 finding when nftband is running")
		}
	}
}

// =============================================================================
// v1.83: Timer liveness tests (VAL-TIMER-001)
// =============================================================================

// mockTimerChecker implements TimerChecker for testing.
type mockTimerChecker struct {
	count int
	err   error
}

func (m mockTimerChecker) CountActiveTimers() (int, error) {
	return m.count, m.err
}

func TestTimerStateWithActiveTimers(t *testing.T) {
	SetTimerChecker(mockTimerChecker{count: 9, err: nil})
	defer SetTimerChecker(SystemdTimerChecker{})

	count, err := checkTimerState()
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if count != 9 {
		t.Errorf("expected 9 active timers, got %d", count)
	}
}

func TestTimerStateZeroTimers(t *testing.T) {
	SetTimerChecker(mockTimerChecker{count: 0, err: nil})
	defer SetTimerChecker(SystemdTimerChecker{})

	count, err := checkTimerState()
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if count != 0 {
		t.Errorf("expected 0 timers, got %d", count)
	}
}

func TestTimerStateQueryError(t *testing.T) {
	// On query error, checkTimerState returns (0, err).
	SetTimerChecker(mockTimerChecker{count: 0, err: exec.ErrNotFound})
	defer SetTimerChecker(SystemdTimerChecker{})

	count, err := checkTimerState()
	if err == nil {
		t.Error("expected error, got nil")
	}
	if count != 0 {
		t.Errorf("expected 0 on error, got %d", count)
	}
}

func TestTimerZeroProducesFinding(t *testing.T) {
	// Zero timers should produce VAL-TIMER-001 finding (severity: error)
	// which causes DEGRADED through the normal evaluateOverallStatus path.
	SetTimerChecker(mockTimerChecker{count: 0, err: nil})
	defer SetTimerChecker(SystemdTimerChecker{})

	result := &ValidationResult{
		Families: []FamilyResult{
			{Status: StatusProtected},
			{Status: StatusProtected},
		},
		Findings: make([]Finding, 0),
	}

	timerCount, timerErr := checkTimerState()
	result.ServiceState.TimerCount = timerCount
	if timerErr != nil {
		result.Findings = append(result.Findings, Finding{
			Code:     CodeTimerError,
			Severity: SeverityWarn,
		})
	} else if timerCount == 0 {
		result.Findings = append(result.Findings, Finding{
			Code:      CodeTimerNone,
			Severity:  SeverityError,
			Component: "service",
			Message:   "no active nftban timers found",
		})
	}

	status := evaluateOverallStatus(result)
	if status != StatusDegraded {
		t.Errorf("expected DEGRADED with zero timers, got %s", status)
	}

	found := false
	for _, f := range result.Findings {
		if f.Code == CodeTimerNone {
			found = true
			if f.Severity != SeverityError {
				t.Errorf("VAL-TIMER-001 severity should be error, got %s", f.Severity)
			}
		}
	}
	if !found {
		t.Error("expected VAL-TIMER-001 finding when zero timers")
	}
}

func TestTimerQueryErrorProducesFinding(t *testing.T) {
	// Query error should produce VAL-TIMER-002 (warn), NOT VAL-TIMER-001 (error).
	// Distinguishes "no timers" from "couldn't check".
	SetTimerChecker(mockTimerChecker{count: 0, err: exec.ErrNotFound})
	defer SetTimerChecker(SystemdTimerChecker{})

	result := &ValidationResult{
		Families: []FamilyResult{
			{Status: StatusProtected},
		},
		Findings: make([]Finding, 0),
	}

	timerCount, timerErr := checkTimerState()
	result.ServiceState.TimerCount = timerCount
	if timerErr != nil {
		result.Findings = append(result.Findings, Finding{
			Code:      CodeTimerError,
			Severity:  SeverityWarn,
			Component: "service",
			Message:   "timer liveness query failed: " + timerErr.Error(),
		})
	} else if timerCount == 0 {
		result.Findings = append(result.Findings, Finding{
			Code:     CodeTimerNone,
			Severity: SeverityError,
		})
	}

	// Should get VAL-TIMER-002 (warn), NOT VAL-TIMER-001 (error)
	foundError := false
	foundWarn := false
	for _, f := range result.Findings {
		if f.Code == CodeTimerNone {
			foundError = true
		}
		if f.Code == CodeTimerError {
			foundWarn = true
			if f.Severity != SeverityWarn {
				t.Errorf("VAL-TIMER-002 severity should be warn, got %s", f.Severity)
			}
		}
	}
	if foundError {
		t.Error("should NOT emit VAL-TIMER-001 on query error — that's VAL-TIMER-002 territory")
	}
	if !foundWarn {
		t.Error("expected VAL-TIMER-002 finding on query error")
	}

	// Warn finding should NOT cause DEGRADED (only error/critical do)
	status := evaluateOverallStatus(result)
	if status == StatusDegraded {
		t.Error("query error (warn) should not cause DEGRADED — only real zero timers should")
	}
}

func TestTimerActiveNoFinding(t *testing.T) {
	// Active timers should NOT produce VAL-TIMER-001 or VAL-TIMER-002.
	SetTimerChecker(mockTimerChecker{count: 5, err: nil})
	defer SetTimerChecker(SystemdTimerChecker{})

	result := &ValidationResult{
		Families: []FamilyResult{
			{Status: StatusProtected},
		},
		Findings: make([]Finding, 0),
	}

	timerCount, timerErr := checkTimerState()
	result.ServiceState.TimerCount = timerCount
	if timerErr != nil {
		result.Findings = append(result.Findings, Finding{
			Code:     CodeTimerError,
			Severity: SeverityWarn,
		})
	} else if timerCount == 0 {
		result.Findings = append(result.Findings, Finding{
			Code:     CodeTimerNone,
			Severity: SeverityError,
		})
	}

	for _, f := range result.Findings {
		if f.Code == CodeTimerNone || f.Code == CodeTimerError {
			t.Errorf("should NOT have timer finding when timers are active, got %s", f.Code)
		}
	}
}
