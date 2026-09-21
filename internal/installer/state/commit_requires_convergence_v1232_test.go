// =============================================================================
// NFTBan v1.232.2 — COMMITTED requires a convergence verdict (falsifiers)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// =============================================================================
//
// Subject: BUG-UPDATE-APPLY-CAN-COMMIT-WITHOUT-CONVERGENCE-VERDICT (CRITICAL,
// GA_BLOCKING). Measured on production srv3: INSTALL_STATE=COMMITTED written
// beside CONVERGENCE_VERIFIED="" after a three-phase run.
//
// ⛔ THESE ARE FALSIFIERS, NOT READ-BACKS. Each one supplies a value the
// production path is capable of producing and REQUIRES the invariant to reject
// it. A test that only asserted "VERIFIED is accepted" would pass on the
// pre-fix code, which accepted everything.
//
// =============================================================================

package state

import (
	"strings"
	"testing"
)

// The forbidden-transition matrix. Exactly one verdict may reach COMMITTED.
func TestCommittedRefusesEveryNonVerifiedConvergenceVerdict(t *testing.T) {
	cases := []struct {
		verdict string
		why     string
		permit  bool
	}{
		// REFUSED — no verdict was ever established, or it was established as NO.
		{"", "EMPTY — the srv3 value; an omission is not a verdict", false},
		{ConvergenceNotEvaluatedValue, "NOT_EVALUATED — the path declines to evaluate", false},
		{"NOT_CONVERGED", "NOT_CONVERGED — it ran and the answer was no", false},
		{"verified", "lowercase — the comparison must not be case-insensitive", false},
		{"VERIFIED ", "trailing space — must not be trimmed into acceptance", false},
		{"PROBABLY_VERIFIED", "a superstring must not satisfy a prefix/contains test", false},
		{"SOME_FUTURE_VERDICT", "unrecognised — must fail CLOSED, not inherit permission", false},

		// PERMITTED — the contract RAN. DEFERRED and UNVERIFIED are permitted
		// intermediate dispositions whose commit-eligibility this release did NOT
		// re-decide (see the allowlist comment in file.go); they are gated by the
		// other assertions, not by this boundary. Their presence here is the control
		// that proves the guard was narrowed deliberately rather than left broad.
		{ConvergenceVerifiedValue, "VERIFIED — every leg passed", true},
		{"DEFERRED", "DEFERRED — ran; debt recorded (P12-A01: refusing this breaks every deferring upgrade)", true},
		{"UNVERIFIED", "UNVERIFIED — ran; a leg was unobservable", true},
	}

	for _, c := range cases {
		sf := NewStateFile(t.TempDir())
		sf.ConvergenceVerified = c.verdict
		err := sf.Transition(StateCommitted, PhaseValidate, "falsifier")

		if c.permit {
			if err != nil {
				t.Errorf("CONVERGENCE_VERIFIED=%q (%s): transition refused with %v; it must be permitted",
					c.verdict, c.why, err)
			} else if sf.State != StateCommitted {
				t.Errorf("CONVERGENCE_VERIFIED=%q: no error but state = %s; want COMMITTED", c.verdict, sf.State)
			}
			continue
		}

		if err == nil {
			t.Errorf("CONVERGENCE_VERIFIED=%q (%s): transition to COMMITTED was PERMITTED — "+
				"this is the srv3 defect", c.verdict, c.why)
		}
		// ⛔ REFUSING IS NOT ENOUGH — the assignment must not have happened.
		// Every production caller invokes Transition as `_ = sf.Transition(...)`,
		// so an invariant that returns an error AFTER mutating sf.State would be
		// completely inert in production while looking correct in a test.
		if sf.State == StateCommitted {
			t.Errorf("CONVERGENCE_VERIFIED=%q: Transition returned an error but STILL assigned "+
				"COMMITTED — every caller discards the error, so the invariant would be inert", c.verdict)
		}
	}
}

// The refusal must name the value it saw, or an operator cannot act on it.
func TestCommittedRefusalNamesTheOffendingVerdict(t *testing.T) {
	sf := NewStateFile(t.TempDir())
	sf.ConvergenceVerified = ConvergenceNotEvaluatedValue
	err := sf.Transition(StateCommitted, PhaseValidate, "falsifier")
	if err == nil {
		t.Fatal("expected refusal")
	}
	if !strings.Contains(err.Error(), ConvergenceNotEvaluatedValue) {
		t.Errorf("refusal does not name the observed verdict: %v", err)
	}
}

// APPLIED_UNVERIFIED's own contract.
func TestAppliedUnverifiedContract(t *testing.T) {
	s := StateAppliedUnverified

	if s.ExitCode() != ExitAppliedUnverified {
		t.Errorf("ExitCode() = %d; want ExitAppliedUnverified (%d)", s.ExitCode(), ExitAppliedUnverified)
	}
	// ⛔ NEVER 0. The whole point of a distinct code is that no rc==0 consumer
	// can read "verified" out of a run that verified nothing.
	if s.ExitCode() == ExitCommitted {
		t.Error("APPLIED_UNVERIFIED exits 0 — an rc==0 consumer would read it as success")
	}
	if s.IsFailed() {
		t.Error("APPLIED_UNVERIFIED must not be a FAILED state — the mutation applied")
	}
	if !s.IsTerminal() {
		t.Error("APPLIED_UNVERIFIED must be terminal for this run")
	}
	if !s.IsApplyTerminal() {
		t.Error("APPLIED_UNVERIFIED must be apply-terminal — an apply was attempted and landed")
	}
	if !s.DeclaresNoConvergenceVerdict() {
		t.Error("APPLIED_UNVERIFIED must declare that no convergence verdict exists")
	}
}

// ⛔ THE ONE THAT WOULD HAVE BEEN MISSED. APPLIED_UNVERIFIED resumes at VALIDATE,
// and the original derivation answered "a VALIDATE resume renders nothing, so it
// invalidates nothing, so --repair reaches COMMITTED" — true for DEGRADED, which
// HAS a verdict to carry, and false here, where the state's definition is that
// there is none. A --repair from this state cannot render the boot projection,
// so the invariant above would refuse COMMITTED and the operator would have been
// sent to a mechanism with no route.
func TestAppliedUnverifiedRecoveryIsFullTransaction(t *testing.T) {
	s := StateAppliedUnverified

	if s.ResumePhase() != PhaseValidate {
		t.Fatalf("precondition changed: ResumePhase() = %s; this test exists because it is VALIDATE",
			s.ResumePhase())
	}
	if s.RepairReachesCommitted() {
		t.Error("--repair is claimed to reach COMMITTED from APPLIED_UNVERIFIED, but a VALIDATE " +
			"resume renders no boot projection and there is no verdict to carry forward")
	}
	if got := s.RecoveryClass(); got != RecoveryRetryFullTransaction {
		t.Errorf("RecoveryClass() = %s; want %s", got, RecoveryRetryFullTransaction)
	}

	// The anti-drift control must REJECT the wrong classification.
	if msg := ValidateRecoveryClass(s, RecoveryRepair); msg == "" {
		t.Error("ValidateRecoveryClass accepted RECOVERY_CLASS=REPAIR for APPLIED_UNVERIFIED — " +
			"the control is decorative")
	}

	// And it must reject it for the RIGHT reason. The pre-existing wording
	// ("resumes at SWITCH, skips the render") is true of REBUILD_REFUSED_BUSY and
	// FALSE of this state; printing it here would misdiagnose the operator.
	reason := s.RepairRefusalReason()
	if reason == "" {
		t.Fatal("no refusal reason given for a state whose --repair has no route")
	}
	if strings.Contains(reason, "SWITCH") {
		t.Errorf("refusal reason borrowed REBUILD_REFUSED_BUSY's wording: %q", reason)
	}
	if !strings.Contains(reason, ConvergenceNotEvaluatedValue) {
		t.Errorf("refusal reason does not state the actual cause (no verdict to carry): %q", reason)
	}
}

// DEGRADED must keep its cheap recovery — proving the change above narrowed the
// carry-forward route rather than deleting it.
func TestDegradedStillRecoversThroughRepair(t *testing.T) {
	if got := StateDegraded.RecoveryClass(); got != RecoveryRepair {
		t.Errorf("DEGRADED RecoveryClass() = %s; want %s — the carry-forward route was over-narrowed",
			got, RecoveryRepair)
	}
	if msg := ValidateRecoveryClass(StateDegraded, RecoveryRetryFullTransaction); msg == "" {
		t.Error("ValidateRecoveryClass accepted RETRY_FULL_TRANSACTION for DEGRADED")
	}
}

// REBUILD_REFUSED_BUSY keeps its own, different refusal reason.
func TestRebuildRefusedBusyKeepsItsOwnRefusalReason(t *testing.T) {
	reason := StateRebuildRefusedBusy.RepairRefusalReason()
	if !strings.Contains(reason, "SWITCH") {
		t.Errorf("REBUILD_REFUSED_BUSY refusal reason lost the render-skip fact: %q", reason)
	}
}

// The new exit code must not collide inside the installer's own namespace.
func TestExitAppliedUnverifiedIsUnique(t *testing.T) {
	seen := map[int]InstallState{}
	states := []InstallState{
		StateCommitted, StateDegraded, StateAppliedUnverified,
		StateFailedAbort, StateFailedRebuild, StateFailedRender,
		StateFailedNoFirewall, StateFailedSSH, StateFailedTakeover,
		StateRestoreRefused, StateRestoreIntentRequired, StateRestoreExecuted,
		StateRestoreFailedExecution, StateRestoreDegraded, StateRestoreFailedVerification,
	}
	for _, s := range states {
		code := s.ExitCode()
		if prev, dup := seen[code]; dup && prev != s {
			// Deliberate reuse is documented (e.g. the FAILED family share 2);
			// only APPLIED_UNVERIFIED is required to be unique.
			if s == StateAppliedUnverified || prev == StateAppliedUnverified {
				t.Errorf("ExitAppliedUnverified collides: %s and %s both exit %d", prev, s, code)
			}
			continue
		}
		seen[code] = s
	}
}
