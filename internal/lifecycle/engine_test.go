// =============================================================================
// NFTBan v1.97 - Lifecycle Engine Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="lifecycle-engine-test"
// meta:type="test"
// meta:version="1.97.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Tests for lifecycle state machine engine"
// meta:inventory.files="internal/lifecycle/engine_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package lifecycle

import "testing"

// Test 1: NFTBAN + PROTECTED + no recovery → SUCCESS + PRESERVE
func TestEngineNFTBanProtectedNoRecovery(t *testing.T) {
	snap := Snapshot{
		Mode:   ModeUpdate,
		DryRun: true,
		CurrentAuthority: AuthorityState{
			Owner: AuthorityNFTBan, Health: HealthProtected,
		},
		LastOperation: LastOperation{Result: "SUCCESS"},
		Detection:     Detection{KernelValid: true, ValidatorConsistent: true, SSHSafe: true},
	}

	r := Run(snap)

	if r.Outcome != OutcomeSuccess {
		t.Errorf("outcome = %s; want SUCCESS", r.Outcome)
	}
	if r.Plan.HasAbort() {
		t.Error("should not abort")
	}
	if len(r.Plan.Actions) == 0 || r.Plan.Actions[0] != ActionPreserveAuthority {
		t.Errorf("actions = %v; want [PRESERVE_AUTHORITY]", r.Plan.Actions)
	}
}

// Test 2: NFTBAN + DEGRADED + recovery pending → NEEDS_RECOVERY
func TestEngineRecoveryPending(t *testing.T) {
	snap := Snapshot{
		Mode:   ModeUpdate,
		DryRun: true,
		CurrentAuthority: AuthorityState{
			Owner: AuthorityNFTBan, Health: HealthDegraded,
		},
		LastOperation: LastOperation{
			Result:          "FAILED_DEGRADED",
			RecoveryPending: true,
		},
		Detection: Detection{KernelValid: true, ValidatorConsistent: true, SSHSafe: true},
	}

	r := Run(snap)

	if r.Outcome != OutcomeFailed {
		t.Errorf("outcome = %s; want FAILED", r.Outcome)
	}
	if !r.Plan.HasRecovery() {
		t.Error("should have NEEDS_RECOVERY action")
	}
}

// Test 3: EXTERNAL + healthy → ABORT
func TestEngineExternalAuthority(t *testing.T) {
	snap := Snapshot{
		Mode:   ModeInstall,
		DryRun: true,
		CurrentAuthority: AuthorityState{
			Owner: AuthorityExternal, Health: HealthProtected,
		},
		LastOperation: LastOperation{Result: "SUCCESS"},
		Detection:     Detection{KernelValid: true, ValidatorConsistent: true, SSHSafe: true},
	}

	r := Run(snap)

	if r.Outcome != OutcomeFailed {
		t.Errorf("outcome = %s; want FAILED", r.Outcome)
	}
	if !r.Plan.HasAbort() {
		t.Error("should ABORT when external authority exists")
	}
}

// Test 4: NONE + DOWN → TAKE_AUTHORITY
func TestEngineNoneDown(t *testing.T) {
	snap := Snapshot{
		Mode:   ModeInstall,
		DryRun: true,
		CurrentAuthority: AuthorityState{
			Owner: AuthorityNone, Health: HealthDown,
		},
		LastOperation: LastOperation{Result: ""},
		Detection:     Detection{KernelValid: false, ValidatorConsistent: false, SSHSafe: true},
	}

	r := Run(snap)

	if r.Outcome != OutcomeSuccess {
		t.Errorf("outcome = %s; want SUCCESS", r.Outcome)
	}
	if len(r.Plan.Actions) == 0 || r.Plan.Actions[0] != ActionTakeAuthority {
		t.Errorf("actions = %v; want [TAKE_AUTHORITY]", r.Plan.Actions)
	}
	if r.Authority.Resulting.Owner != AuthorityNFTBan {
		t.Errorf("resulting.owner = %s; want NFTBAN", r.Authority.Resulting.Owner)
	}
}

// Test 5: NFTBAN + PROTECTED + last_op=FAILED_RECOVERED → SUCCESS with warning (INV-LC-008)
func TestEngineFailedRecoveredPreserveTwoTruths(t *testing.T) {
	snap := Snapshot{
		Mode:   ModeUpdate,
		DryRun: true,
		CurrentAuthority: AuthorityState{
			Owner: AuthorityNFTBan, Health: HealthProtected,
		},
		LastOperation: LastOperation{
			Result:            "FAILED_RECOVERED",
			FailureClass:      "POSTVALIDATION_REGRESSION",
			RecoveryPending:   false,
			LastRebuildFailed: true,
		},
		Detection: Detection{KernelValid: true, ValidatorConsistent: true, SSHSafe: true},
	}

	r := Run(snap)

	if r.Outcome != OutcomeSuccess {
		t.Errorf("outcome = %s; want SUCCESS (current state is healthy)", r.Outcome)
	}

	// Must preserve both truths
	if r.LastOperation.Result != "FAILED_RECOVERED" {
		t.Errorf("last_operation.result = %s; want FAILED_RECOVERED", r.LastOperation.Result)
	}
	if !r.LastOperation.LastRebuildFailed {
		t.Error("last_rebuild_failed should be true")
	}

	// Must have warning about recovery
	hasRecoveryWarning := false
	for _, w := range r.Plan.Warnings {
		if len(w) > 0 {
			hasRecoveryWarning = true
		}
	}
	if !hasRecoveryWarning {
		t.Error("should have warning about recovered rebuild failure")
	}
}

// Test 6: ConflictingFirewall=true → ABORT
func TestEngineConflictingFirewall(t *testing.T) {
	snap := Snapshot{
		Mode:   ModeInstall,
		DryRun: true,
		CurrentAuthority: AuthorityState{
			Owner: AuthorityNone, Health: HealthDown,
		},
		Detection: Detection{ConflictingFirewall: true, SSHSafe: true},
	}

	r := Run(snap)

	if r.Outcome != OutcomeFailed {
		t.Errorf("outcome = %s; want FAILED", r.Outcome)
	}
	if !r.Plan.HasAbort() {
		t.Error("should ABORT when conflicting firewall detected")
	}
	if len(r.Plan.Errors) == 0 {
		t.Error("should have error message about conflicting firewall")
	}
}

// Test 7: DryRun=true, all healthy → SUCCESS, plan rendered, no mutation
func TestEngineDryRunNoMutation(t *testing.T) {
	snap := Snapshot{
		Mode:   ModeInstall,
		DryRun: true,
		CurrentAuthority: AuthorityState{
			Owner: AuthorityNone, Health: HealthDown,
		},
		Detection: Detection{KernelValid: false, SSHSafe: true},
	}

	r := Run(snap)

	if !r.DryRun {
		t.Error("result should reflect dry_run=true")
	}
	if r.Outcome != OutcomeSuccess {
		t.Errorf("outcome = %s; want SUCCESS", r.Outcome)
	}
	// Engine is pure — no side effects to verify, but result must be complete
	if r.SchemaVersion != OutputSchemaVersion {
		t.Errorf("schema_version = %s; want %s", r.SchemaVersion, OutputSchemaVersion)
	}
	if r.Stage != StageFinal {
		t.Errorf("stage = %s; want FINAL", r.Stage)
	}
}

// Test 8: Update with DOWN authority → NEEDS_RECOVERY
func TestEngineUpdateDown(t *testing.T) {
	snap := Snapshot{
		Mode:   ModeUpdate,
		DryRun: true,
		CurrentAuthority: AuthorityState{
			Owner: AuthorityNFTBan, Health: HealthDown,
		},
		LastOperation: LastOperation{Result: "FAILED_FATAL"},
		Detection:     Detection{KernelValid: false, SSHSafe: true},
	}

	r := Run(snap)

	if r.Outcome != OutcomeFailed {
		t.Errorf("outcome = %s; want FAILED", r.Outcome)
	}
	if !r.Plan.HasRecovery() {
		t.Error("update on DOWN authority should require recovery")
	}
}

// Test 9: Maintenance with non-NFTBAN authority → ABORT
func TestEngineMaintenanceNoAuthority(t *testing.T) {
	snap := Snapshot{
		Mode:   ModeMaintenance,
		DryRun: true,
		CurrentAuthority: AuthorityState{
			Owner: AuthorityExternal, Health: HealthProtected,
		},
		Detection: Detection{KernelValid: true, SSHSafe: true},
	}

	r := Run(snap)

	if r.Outcome != OutcomeFailed {
		t.Errorf("outcome = %s; want FAILED", r.Outcome)
	}
	if !r.Plan.HasAbort() {
		t.Error("maintenance without NFTBAN authority should abort")
	}
}

// Test 10: Uninstall with NONE authority → NOOP
func TestEngineUninstallNone(t *testing.T) {
	snap := Snapshot{
		Mode:   ModeUninstall,
		DryRun: true,
		CurrentAuthority: AuthorityState{
			Owner: AuthorityNone, Health: HealthDown,
		},
		Detection: Detection{SSHSafe: true},
	}

	r := Run(snap)

	if len(r.Plan.Actions) == 0 || r.Plan.Actions[0] != ActionNoop {
		t.Errorf("actions = %v; want [NOOP] for uninstall with no authority", r.Plan.Actions)
	}
}

// Test 11: Invalid mode → ABORT
func TestEngineInvalidMode(t *testing.T) {
	snap := Snapshot{
		Mode:   "deploy",
		DryRun: true,
		CurrentAuthority: AuthorityState{
			Owner: AuthorityNone, Health: HealthDown,
		},
	}

	r := Run(snap)

	if r.Outcome != OutcomeFailed {
		t.Errorf("outcome = %s; want FAILED", r.Outcome)
	}
	if !r.Plan.HasAbort() {
		t.Error("invalid mode should abort")
	}
}

// Test 12: Schema version is set
func TestEngineSchemaVersion(t *testing.T) {
	r := Run(Snapshot{
		Mode:   ModeInstall,
		DryRun: true,
		CurrentAuthority: AuthorityState{Owner: AuthorityNone, Health: HealthDown},
		Detection:        Detection{SSHSafe: true},
	})

	if r.SchemaVersion != "1.0" {
		t.Errorf("schema_version = %s; want 1.0", r.SchemaVersion)
	}
}

// Test 13: Timestamp is set
func TestEngineTimestamp(t *testing.T) {
	r := Run(Snapshot{
		Mode:   ModeInstall,
		DryRun: true,
		CurrentAuthority: AuthorityState{Owner: AuthorityNone, Health: HealthDown},
		Detection:        Detection{SSHSafe: true},
	})

	if r.Timestamp.IsZero() {
		t.Error("timestamp should be set")
	}
}
