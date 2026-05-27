// =============================================================================
// NFTBan v1.107 - Installer State File I/O — V108 Item 5 hygiene tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-state-file-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-11"
// meta:description="Unit tests for V108 Item 5 applyTerminalHygiene rule + Transition()"
// meta:inventory.files="internal/installer/state/file.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package state

import (
	"testing"
)

// V108 Item 5 — apply hygiene rule when transitioning to terminal success
// or soft-success. See V108_ITEM5_INSTALL_STATE_HYGIENE_SCOPE.md.

// newDryStateFile returns a StateFile that does not touch the filesystem.
// All hygiene-rule tests use DryRun=true so Transition() exercises the
// in-memory path without needing a real /var/lib/nftban/state.
func newDryStateFile(t *testing.T) *StateFile {
	t.Helper()
	sf := NewStateFile("/tmp/v108-item5-test-not-used")
	sf.DryRun = true
	return sf
}

// TestTransitionToCommittedClearsCarryOverFields covers the canonical
// hygiene case: an earlier-failed phase left FailureReason+Conflicts+
// PreflightPassed=false set. Authority is now UPDATE (takeover approved).
// On Transition(StateCommitted, …) all three fields are cleaned.
func TestTransitionToCommittedClearsCarryOverFields(t *testing.T) {
	sf := newDryStateFile(t)
	sf.FailureReason = "prior failure: conflicts detected"
	sf.Conflicts = "UFW"
	sf.PreflightPassed = false
	sf.Authority = "UPDATE"

	if err := sf.Transition(StateCommitted, PhaseValidate, ""); err != nil {
		t.Fatalf("Transition returned unexpected error: %v", err)
	}
	if sf.FailureReason != "" {
		t.Errorf("FailureReason: want \"\", got %q", sf.FailureReason)
	}
	if sf.Conflicts != "" {
		t.Errorf("Conflicts: want \"\" (Authority=UPDATE), got %q", sf.Conflicts)
	}
	if !sf.PreflightPassed {
		t.Errorf("PreflightPassed: want true, got false")
	}
	if sf.State != StateCommitted {
		t.Errorf("State: want %s, got %s", StateCommitted, sf.State)
	}
}

// TestTransitionToCommittedPreservesConflictsWhenAuthorityAmbiguous
// covers the lab2 case: AUTHORITY=AMBIGUOUS so CONFLICTS still describes
// current state. FailureReason is still cleared (no current failure)
// per §4 rule. Conflicts must be preserved.
func TestTransitionToCommittedPreservesConflictsWhenAuthorityAmbiguous(t *testing.T) {
	sf := newDryStateFile(t)
	sf.FailureReason = "prior reason"
	sf.Conflicts = "UFW"
	sf.PreflightPassed = false
	sf.Authority = "AMBIGUOUS"

	if err := sf.Transition(StateCommitted, PhaseValidate, ""); err != nil {
		t.Fatalf("Transition returned unexpected error: %v", err)
	}
	if sf.FailureReason != "" {
		t.Errorf("FailureReason: want \"\" (terminal hygiene clears it), got %q", sf.FailureReason)
	}
	if sf.Conflicts != "UFW" {
		t.Errorf("Conflicts: want %q (preserved because Authority=AMBIGUOUS), got %q",
			"UFW", sf.Conflicts)
	}
	if !sf.PreflightPassed {
		t.Errorf("PreflightPassed: want true, got false")
	}
}

// TestTransitionToDegradedSrv4Case reproduces srv4's v1.107.2 rollout
// row: AUTHORITY=UPDATE (takeover approved) but pre-state CONFLICTS+
// FAILURE_REASON still describing pre-approval conflicts. After
// transition to DEGRADED, both should be cleared.
func TestTransitionToDegradedSrv4Case(t *testing.T) {
	sf := newDryStateFile(t)
	sf.FailureReason = "conflicts detected, takeover not approved: iptables-nft,iptables,CSF"
	sf.Conflicts = "iptables-nft,iptables,CSF"
	sf.PreflightPassed = false
	sf.Authority = "UPDATE"

	if err := sf.Transition(StateDegraded, PhaseValidate, ""); err != nil {
		t.Fatalf("Transition returned unexpected error: %v", err)
	}
	if sf.FailureReason != degradedReasonFallback {
		t.Errorf("FailureReason: want v1.135 fallback %q, got %q", degradedReasonFallback, sf.FailureReason)
	}
	if sf.Conflicts != "" {
		t.Errorf("Conflicts: want \"\" (Authority=UPDATE), got %q", sf.Conflicts)
	}
	if !sf.PreflightPassed {
		t.Errorf("PreflightPassed: want true, got false")
	}
	if sf.State != StateDegraded {
		t.Errorf("State: want %s, got %s", StateDegraded, sf.State)
	}
}

// TestTransitionToDegradedLab2Case reproduces lab2's v1.107.2 rollout
// row: AUTHORITY=AMBIGUOUS, CONFLICTS=UFW, FAILURE_REASON describing
// the UFW conflict. After DEGRADED transition, Conflicts is preserved
// (Authority is not UPDATE); the stale FailureReason is replaced by the
// v1.135 empty-reason fallback (a DEGRADED terminal is never blank).
func TestTransitionToDegradedLab2Case(t *testing.T) {
	sf := newDryStateFile(t)
	sf.FailureReason = "conflicts detected, takeover not approved: UFW"
	sf.Conflicts = "UFW"
	sf.PreflightPassed = false
	sf.Authority = "AMBIGUOUS"

	if err := sf.Transition(StateDegraded, PhaseValidate, ""); err != nil {
		t.Fatalf("Transition returned unexpected error: %v", err)
	}
	if sf.FailureReason != degradedReasonFallback {
		t.Errorf("FailureReason: want v1.135 fallback %q, got %q", degradedReasonFallback, sf.FailureReason)
	}
	if sf.Conflicts != "UFW" {
		t.Errorf("Conflicts: want %q (preserved because Authority=AMBIGUOUS), got %q",
			"UFW", sf.Conflicts)
	}
	if !sf.PreflightPassed {
		t.Errorf("PreflightPassed: want true, got false")
	}
}

// TestTransitionToDegradedEmptyReasonBackstop — v1.135 scope §5: a DEGRADED
// transition handed an empty reason must NOT leave FAILURE_REASON blank.
func TestTransitionToDegradedEmptyReasonBackstop(t *testing.T) {
	sf := newDryStateFile(t)
	if err := sf.Transition(StateDegraded, PhaseValidate, ""); err != nil {
		t.Fatalf("Transition error: %v", err)
	}
	if sf.FailureReason == "" {
		t.Errorf("FailureReason: want non-empty fallback, got empty")
	}
	if sf.FailureReason != degradedReasonFallback {
		t.Errorf("FailureReason: want %q, got %q", degradedReasonFallback, sf.FailureReason)
	}
}

// TestTransitionToDegradedPreservesTimerReason — a non-empty reason (e.g. the
// critical-timer assertion) is carried verbatim into FAILURE_REASON.
func TestTransitionToDegradedPreservesTimerReason(t *testing.T) {
	sf := newDryStateFile(t)
	reason := "failed assertions after safe auto-fix: core_timers_active_or_scheduled_ok (critical core timer(s) not enabled+active: nftban-maintenance.timer)"
	if err := sf.Transition(StateDegraded, PhaseValidate, reason); err != nil {
		t.Fatalf("Transition error: %v", err)
	}
	if sf.FailureReason != reason {
		t.Errorf("FailureReason: want %q, got %q", reason, sf.FailureReason)
	}
}

// TestTransitionToFailedAbortPreservesAllFields ensures failure
// terminals (StateFailedAbort) keep all diagnostic fields intact.
// FailureReason is overwritten by the new reason; Conflicts and
// PreflightPassed are NOT cleared.
func TestTransitionToFailedAbortPreservesAllFields(t *testing.T) {
	sf := newDryStateFile(t)
	sf.FailureReason = "previous reason"
	sf.Conflicts = "UFW,iptables-nft"
	sf.PreflightPassed = false
	sf.Authority = "AMBIGUOUS"

	const newReason = "fresh failure on this transition"
	err := sf.Transition(StateFailedAbort, PhaseDetect, newReason)
	// Failure transition returns an error (per Transition contract)
	if err == nil {
		t.Fatalf("Transition to failure state must return an error")
	}
	if sf.FailureReason != newReason {
		t.Errorf("FailureReason: want %q (overwritten), got %q", newReason, sf.FailureReason)
	}
	if sf.Conflicts != "UFW,iptables-nft" {
		t.Errorf("Conflicts: want preserved %q, got %q", "UFW,iptables-nft", sf.Conflicts)
	}
	if sf.PreflightPassed {
		t.Errorf("PreflightPassed: want false (preserved), got true")
	}
}

// TestTransitionToIntermediateStatePreservesAllFields ensures the
// hygiene step does NOT fire on non-terminal transitions. Intermediate
// states (anything not COMMITTED, DEGRADED, or a failure terminal) keep
// the prior FailureReason/Conflicts/PreflightPassed verbatim.
func TestTransitionToIntermediateStatePreservesAllFields(t *testing.T) {
	sf := newDryStateFile(t)
	sf.FailureReason = "diagnostic carry-over"
	sf.Conflicts = "UFW"
	sf.PreflightPassed = false
	sf.Authority = "UPDATE"

	// Pick a non-terminal, non-failure intermediate state. The state-machine
	// has many such states; use StateFilesInstalled which is the default
	// initial state per NewStateFile.
	if err := sf.Transition(StateFilesInstalled, PhaseDetect, ""); err != nil {
		t.Fatalf("Transition returned unexpected error: %v", err)
	}
	if sf.FailureReason != "diagnostic carry-over" {
		t.Errorf("FailureReason: want preserved, got %q", sf.FailureReason)
	}
	if sf.Conflicts != "UFW" {
		t.Errorf("Conflicts: want preserved, got %q", sf.Conflicts)
	}
	if sf.PreflightPassed {
		t.Errorf("PreflightPassed: want false (preserved), got true")
	}
}

// TestTransitionFromCleanIdleToCommittedIdempotent ensures the hygiene
// step is a clean no-op on a host that never failed. All fields start
// at their zero values; the hygiene sets PreflightPassed=true (which
// it correctly should on COMMITTED success).
func TestTransitionFromCleanIdleToCommittedIdempotent(t *testing.T) {
	sf := newDryStateFile(t)
	// Fields default to zero values; no prior failure.

	if err := sf.Transition(StateCommitted, PhaseValidate, ""); err != nil {
		t.Fatalf("Transition returned unexpected error: %v", err)
	}
	if sf.FailureReason != "" {
		t.Errorf("FailureReason: want \"\", got %q", sf.FailureReason)
	}
	if sf.Conflicts != "" {
		t.Errorf("Conflicts: want \"\", got %q", sf.Conflicts)
	}
	if !sf.PreflightPassed {
		t.Errorf("PreflightPassed: want true on successful COMMITTED, got false")
	}
}

// TestTransitionToDegradedPreservesReason locks the v1.131.4 fix for
// D-INSTALL-STATE-BLANK-REASON: DEGRADED is a completed-WITH-issues terminal
// whose reason (the still-failing assertion names) is CURRENT, not stale
// carry-over, so — unlike COMMITTED — it must survive applyTerminalHygiene
// into FAILURE_REASON= and the report() "Issues:" line.
func TestTransitionToDegradedPreservesReason(t *testing.T) {
	sf := newDryStateFile(t)
	const reason = "failed assertions after safe auto-fix: systemd_payload_inventory_ok"

	if err := sf.Transition(StateDegraded, PhaseValidate, reason); err != nil {
		t.Fatalf("Transition returned unexpected error: %v", err)
	}
	if sf.State != StateDegraded {
		t.Errorf("State: want DEGRADED, got %s", sf.State)
	}
	if sf.FailureReason != reason {
		t.Errorf("FailureReason: want %q, got %q", reason, sf.FailureReason)
	}
	// terminal hygiene still applies (PreflightPassed forced true).
	if !sf.PreflightPassed {
		t.Errorf("PreflightPassed: want true on terminal, got false")
	}
}
