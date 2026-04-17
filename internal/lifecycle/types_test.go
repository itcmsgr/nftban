// =============================================================================
// NFTBan v1.97 - Lifecycle Types Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="lifecycle-types-test"
// meta:type="test"
// meta:version="1.97.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Tests for lifecycle type definitions, enums, helpers"
// meta:inventory.files="internal/lifecycle/types_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package lifecycle

import (
	"encoding/json"
	"testing"
)

func TestValidMode(t *testing.T) {
	valid := []Mode{ModeInstall, ModeUpdate, ModeUninstall, ModeMaintenance}
	for _, m := range valid {
		if !ValidMode(m) {
			t.Errorf("ValidMode(%s) = false; want true", m)
		}
	}

	invalid := []Mode{"", "deploy", "rollback", "INSTALL"}
	for _, m := range invalid {
		if ValidMode(m) {
			t.Errorf("ValidMode(%s) = true; want false", m)
		}
	}
}

func TestAuthorityStateIsOwned(t *testing.T) {
	tests := []struct {
		owner AuthorityOwner
		want  bool
	}{
		{AuthorityNFTBan, true},
		{AuthorityExternal, false},
		{AuthorityNone, false},
	}
	for _, tt := range tests {
		a := AuthorityState{Owner: tt.owner}
		if got := a.IsOwned(); got != tt.want {
			t.Errorf("AuthorityState{Owner: %s}.IsOwned() = %v; want %v", tt.owner, got, tt.want)
		}
	}
}

func TestAuthorityStateIsHealthy(t *testing.T) {
	tests := []struct {
		health LifecycleHealth
		want   bool
	}{
		{HealthProtected, true},
		{HealthIdle, true},
		{HealthDegraded, false},
		{HealthDown, false},
	}
	for _, tt := range tests {
		a := AuthorityState{Health: tt.health}
		if got := a.IsHealthy(); got != tt.want {
			t.Errorf("AuthorityState{Health: %s}.IsHealthy() = %v; want %v", tt.health, got, tt.want)
		}
	}
}

func TestDegradedOwnershipIsStillOwned(t *testing.T) {
	// INV-LC-004: NFTBAN + DEGRADED is valid ownership.
	// Lifecycle must not treat DEGRADED as "no authority."
	a := AuthorityState{Owner: AuthorityNFTBan, Health: HealthDegraded}

	if !a.IsOwned() {
		t.Error("NFTBAN + DEGRADED must still be owned (INV-LC-004)")
	}
	if a.IsHealthy() {
		t.Error("DEGRADED must not be healthy")
	}
}

func TestNormalizeNone(t *testing.T) {
	// Owner=NONE should normalize health to DOWN
	a := AuthorityState{Owner: AuthorityNone, Health: HealthProtected}
	a.NormalizeNone()
	if a.Health != HealthDown {
		t.Errorf("NormalizeNone: health = %s; want DOWN", a.Health)
	}

	// NFTBAN should NOT be affected
	b := AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}
	b.NormalizeNone()
	if b.Health != HealthProtected {
		t.Errorf("NormalizeNone should not affect NFTBAN: health = %s; want PROTECTED", b.Health)
	}

	// NONE + DOWN stays DOWN
	c := AuthorityState{Owner: AuthorityNone, Health: HealthDown}
	c.NormalizeNone()
	if c.Health != HealthDown {
		t.Errorf("NormalizeNone: NONE+DOWN should stay DOWN: health = %s", c.Health)
	}
}

func TestPlanHasAbort(t *testing.T) {
	p := Plan{Actions: []Action{ActionPreserveAuthority, ActionAbort}}
	if !p.HasAbort() {
		t.Error("plan with ABORT should return HasAbort=true")
	}

	p2 := Plan{Actions: []Action{ActionNoop}}
	if p2.HasAbort() {
		t.Error("plan without ABORT should return HasAbort=false")
	}
}

func TestPlanHasRecovery(t *testing.T) {
	p := Plan{Actions: []Action{ActionNeedsRecovery}}
	if !p.HasRecovery() {
		t.Error("plan with NEEDS_RECOVERY should return HasRecovery=true")
	}

	p2 := Plan{Actions: []Action{ActionTakeAuthority}}
	if p2.HasRecovery() {
		t.Error("plan without NEEDS_RECOVERY should return HasRecovery=false")
	}
}

func TestLastOperationCanRepresentRecoveredProtected(t *testing.T) {
	// INV-LC-008: FAILED_RECOVERED + PROTECTED must coexist without contradiction.
	lo := LastOperation{
		Result:            "FAILED_RECOVERED",
		FailureClass:      "POSTVALIDATION_REGRESSION",
		RecoveryPending:   false,
		LastRebuildFailed: true,
	}
	auth := AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}

	// Both truths must be representable simultaneously
	if lo.Result != "FAILED_RECOVERED" {
		t.Error("LastOperation must preserve FAILED_RECOVERED")
	}
	if !auth.IsOwned() || !auth.IsHealthy() {
		t.Error("authority must be owned and healthy despite failed operation")
	}
	if !lo.LastRebuildFailed {
		t.Error("LastRebuildFailed must be true for dashboard clarity")
	}
}

func TestSnapshotJSONRoundtrip(t *testing.T) {
	snap := Snapshot{
		Mode:   ModeInstall,
		DryRun: true,
		CurrentAuthority: AuthorityState{
			Owner:  AuthorityNone,
			Health: HealthDown,
		},
		LastOperation: LastOperation{
			Result:            "SUCCESS",
			FailureClass:      "",
			RecoveryPending:   false,
			LastRebuildFailed: false,
		},
		Detection: Detection{
			ConflictingFirewall: false,
			KernelValid:         true,
			ValidatorConsistent: true,
			SSHSafe:             true,
		},
	}

	data, err := json.MarshalIndent(snap, "", "  ")
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var snap2 Snapshot
	if err := json.Unmarshal(data, &snap2); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if snap2.Mode != ModeInstall {
		t.Errorf("mode = %s; want install", snap2.Mode)
	}
	if snap2.CurrentAuthority.Owner != AuthorityNone {
		t.Errorf("owner = %s; want NONE", snap2.CurrentAuthority.Owner)
	}
	if snap2.Detection.KernelValid != true {
		t.Error("kernel_valid should be true")
	}
}

func TestRunResultJSONRoundtrip(t *testing.T) {
	result := RunResult{
		SchemaVersion: OutputSchemaVersion,
		Mode:          ModeInstall,
		DryRun:        true,
		Stage:         StageFinal,
		Outcome:       OutcomeSuccess,
		LastOperation: LastOperation{
			Result:          "SUCCESS",
			RecoveryPending: false,
		},
		Plan: Plan{
			Actions:  []Action{ActionTakeAuthority},
			Warnings: []string{"first install"},
			Errors:   nil,
		},
		Detection: Detection{
			ConflictingFirewall: false,
			KernelValid:         true,
			ValidatorConsistent: true,
			SSHSafe:             true,
		},
	}
	result.Authority.Prior = AuthorityState{Owner: AuthorityNone, Health: HealthDown}
	result.Authority.Desired = AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}
	result.Authority.Resulting = AuthorityState{Owner: AuthorityNFTBan, Health: HealthProtected}

	data, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var result2 RunResult
	if err := json.Unmarshal(data, &result2); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if result2.SchemaVersion != "1.0" {
		t.Errorf("schema_version = %s; want 1.0", result2.SchemaVersion)
	}
	if result2.Outcome != OutcomeSuccess {
		t.Errorf("outcome = %s; want SUCCESS", result2.Outcome)
	}
	if result2.Authority.Prior.Owner != AuthorityNone {
		t.Errorf("prior.owner = %s; want NONE", result2.Authority.Prior.Owner)
	}
	if result2.Authority.Resulting.Owner != AuthorityNFTBan {
		t.Errorf("resulting.owner = %s; want NFTBAN", result2.Authority.Resulting.Owner)
	}
	if len(result2.Plan.Actions) != 1 || result2.Plan.Actions[0] != ActionTakeAuthority {
		t.Errorf("plan.actions = %v; want [TAKE_AUTHORITY]", result2.Plan.Actions)
	}
}

func TestStageValues(t *testing.T) {
	stages := []Stage{StageDetect, StagePlan, StageApply, StageVerify, StageFinal}
	for _, s := range stages {
		if s == "" {
			t.Error("stage value must not be empty")
		}
	}
}

func TestOutcomeValues(t *testing.T) {
	outcomes := []Outcome{OutcomeSuccess, OutcomeFailed, OutcomeFailedRecovered}
	for _, o := range outcomes {
		if o == "" {
			t.Error("outcome value must not be empty")
		}
	}
}

func TestOutputSchemaVersion(t *testing.T) {
	if OutputSchemaVersion != "1.0" {
		t.Errorf("OutputSchemaVersion = %s; want 1.0", OutputSchemaVersion)
	}
}
