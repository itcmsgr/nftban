// =============================================================================
// NFTBan v1.230.0 Gate 6R F2 — RECOVERY_CLASS
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-recovery-class"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-13"
// meta:description="Declares, per install state, WHICH recovery mechanism has an established route to COMMITTED. Only states whose --repair resume actually re-establishes every fact COMMITTED requires may advertise --repair; the rest must instruct a full retry. Derived from ResumePhase, not from a second hand-maintained table, so a recovery instruction cannot drift away from what recovery actually does."
// meta:inventory.files="internal/installer/state/recovery.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package state

import "fmt"

// ═════════════════════════════════════════════════════════════════════════════════
// WHY THIS EXISTS — MEASURED ON lab3
// ═════════════════════════════════════════════════════════════════════════════════
// A REBUILD_REFUSED_BUSY host was told:
//
//	To retry: /usr/lib/nftban/bin/nftban-installer --repair
//
// Executed live, that instruction did NOT recover. The rebuild ran and committed
// (generation 6 -> 7), but --repair resumes at SWITCH and therefore SKIPS the
// authoritative boot-projection render, which lives in PREPARE. The post-update
// convergence contract's projection_generated leg could not be established, the verdict
// came out NOT_CONVERGED, and the host landed on INSTALL_STATE=DEGRADED, exit 1.
//
//	AN INSTRUCTION THAT CANNOT REACH THE STATE IT PROMISES IS NOT A RECOVERY PATH.
//
// ⛔ THIS IS A SEMANTIC CLASS, NOT A SENTENCE. A textual guard ("does the message
// mention --repair?") would pass a future state that emits REPAIR wrongly but words it
// differently. The class is DERIVED from ResumePhase and one documented fact about what
// that resume omits, so it cannot drift away from what recovery actually does.
//
// ⛔ AND IT IS NOT A SECOND HAND-MAINTAINED TABLE. A lookup keyed by state would be one
// more list to forget to update — the same shape as the operator-wording list that went
// stale against this release's two new states.

// RecoveryClass names the mechanism an operator should use for a given state.
type RecoveryClass string

const (
	// RecoveryRepair — `nftban-installer --repair` has a DEMONSTRATED route to
	// COMMITTED from this state.
	RecoveryRepair RecoveryClass = "REPAIR"

	// RecoveryRetryFullTransaction — --repair must NOT be advertised. The operator
	// must re-run the normal NFTBan update/install transaction.
	//
	// ⛔ WORDED BY OPERATION, NEVER BY PACKAGE MANAGER. The live proof is RPM-only and
	// the originating incident host is dpkg; encoding `rpm -Uvh --force` (or any
	// specific command) into the contract would be wrong on half the fleet. A concrete
	// command may only ever be an ADDITIONAL HINT, and only where the originating
	// package manager is RELIABLY known.
	RecoveryRetryFullTransaction RecoveryClass = "RETRY_FULL_TRANSACTION"
)

// repairResumeReRendersProjection reports whether a --repair that resumes at `p`
// re-runs the authoritative boot-projection render.
//
// ⛔ THE ONE LOAD-BEARING FACT. The render is phasePrepare step 6
// (switchop.RenderBoot); it establishes phaseData.bootProjectionReady, which the
// post-update convergence contract requires for its projection_generated leg. A resume
// that begins at or after SWITCH never runs it, so bootProjectionReady is false and
// convergence cannot be verified — which is precisely what lab3 observed.
//
// PhaseConfigure and PhaseValidate resumes are different: they do not run a rebuild
// either, so they never clear the convergence verdict and the persisted one still
// applies. That is how a DEGRADED host legitimately recovers through --repair today.
func repairResumeReRendersProjection(p Phase) bool {
	switch p {
	case PhaseDetect, PhasePrepare:
		return true // the full chain runs, render included
	case PhaseSwitch:
		return false // ⛔ render is SKIPPED — the lab3 defect
	default: // PhaseConfigure, PhaseValidate, PhaseReport
		return true // no rebuild runs, so no convergence verdict is invalidated
	}
}

// RepairReachesCommitted reports whether --repair from this state can establish every
// fact COMMITTED requires.
//
// ⛔ DERIVED, NOT DECLARED. It reads ResumePhase — the same function --repair itself
// uses — so the answer cannot disagree with the behaviour it describes.
func (s InstallState) RepairReachesCommitted() bool {
	// A state --repair cannot act on at all obviously has no route through it.
	if s == StateCommitted {
		return false // nothing to recover; --repair is a no-op, not a recovery path
	}
	return repairResumeReRendersProjection(s.ResumePhase())
}

// RecoveryClass returns the mechanism whose route to COMMITTED is established.
func (s InstallState) RecoveryClass() RecoveryClass {
	if s.RepairReachesCommitted() {
		return RecoveryRepair
	}
	return RecoveryRetryFullTransaction
}

// ValidateRecoveryClass reports why `declared` is wrong for `s`, or "" when it is right.
//
// ⛔ THIS IS THE ANTI-DRIFT CONTROL, AND IT IS ONLY REAL BECAUSE IT CAN REJECT.
// A guard that merely reads back what production computed proves nothing. This takes a
// class from the CALLER and checks it against the derivation, so a test can declare a
// DELIBERATELY WRONG classification and require the guard to catch it. If declaring
// REBUILD_REFUSED_BUSY as REPAIR ever passes, the control is decorative and the lab3
// defect can reappear.
func ValidateRecoveryClass(s InstallState, declared RecoveryClass) string {
	want := s.RecoveryClass()
	if declared == want {
		return ""
	}
	if declared == RecoveryRepair {
		return fmt.Sprintf(
			"%s declared RECOVERY_CLASS=REPAIR, but --repair resumes at %s, which does not re-establish "+
				"the boot-projection render that the post-update convergence contract requires — "+
				"there is no demonstrated route to COMMITTED through --repair from this state",
			s, s.ResumePhase())
	}
	return fmt.Sprintf(
		"%s declared RECOVERY_CLASS=%s, but --repair resumes at %s and DOES re-establish everything "+
			"COMMITTED requires, so the operator should be sent to the cheaper recovery",
		s, declared, s.ResumePhase())
}
