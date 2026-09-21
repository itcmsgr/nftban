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

// repairEvidenceRoute names HOW a --repair resuming at a given phase can end up with
// the evidence COMMITTED requires. There are three distinct answers, and the first
// version of this file collapsed two of them into one boolean `true` — which is what
// would have mis-classified APPLIED_UNVERIFIED as REPAIR.
type repairEvidenceRoute int

const (
	// routeRenders — the resume re-runs the authoritative boot-projection render
	// itself, so it MANUFACTURES the evidence regardless of what was persisted.
	routeRenders repairEvidenceRoute = iota

	// routeSkipsRender — ⛔ the lab3 defect. The resume begins at or after SWITCH, so
	// switchop.RenderBoot never runs, phaseData.bootProjectionReady stays false, and
	// the projection_generated leg of the post-update convergence contract can never
	// pass in that run.
	routeSkipsRender

	// routeCarriesForward — no rebuild runs, so nothing INVALIDATES a convergence
	// verdict; the resume reaches COMMITTED by carrying forward the verdict already on
	// record. This route is conditional: it is only a route at all if such a verdict
	// exists. That is how a DEGRADED host legitimately recovers through --repair, and
	// precisely why APPLIED_UNVERIFIED cannot.
	routeCarriesForward
)

// repairEvidenceRouteFor maps the resume phase to its route.
//
// ⛔ THE ONE LOAD-BEARING FACT. The render is phasePrepare step 6
// (switchop.RenderBoot); it establishes phaseData.bootProjectionReady, which the
// post-update convergence contract requires for its projection_generated leg.
func repairEvidenceRouteFor(p Phase) repairEvidenceRoute {
	switch p {
	case PhaseDetect, PhasePrepare:
		return routeRenders // the full chain runs, render included
	case PhaseSwitch:
		return routeSkipsRender // ⛔ render is SKIPPED — the lab3 defect
	default: // PhaseConfigure, PhaseValidate, PhaseReport
		return routeCarriesForward
	}
}

// DeclaresNoConvergenceVerdict reports whether the state's OWN DEFINITION is that no
// convergence verdict exists for the transaction that produced it.
//
// ⛔ THIS IS NOT A RECOVERY LOOKUP TABLE. It is the state's meaning, read back. The
// whole point of StateAppliedUnverified is "the mutation landed and validated, and
// convergence was never evaluated" — CONVERGENCE_VERIFIED=NOT_EVALUATED is written in
// the same breath as the transition. A carry-forward recovery route has nothing to
// carry from such a state, so it is not a route.
func (s InstallState) DeclaresNoConvergenceVerdict() bool {
	return s == StateAppliedUnverified
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
	switch repairEvidenceRouteFor(s.ResumePhase()) {
	case routeRenders:
		return true
	case routeSkipsRender:
		return false
	default: // routeCarriesForward
		return !s.DeclaresNoConvergenceVerdict()
	}
}

// RepairRefusalReason explains, in the terms that actually apply to `s`, why --repair
// has no demonstrated route to COMMITTED from it. Returns "" when it does have one.
//
// The two refusals are NOT the same defect and must not share wording: one is "the
// resume skips the render", the other is "there is no verdict to carry forward".
// It is EXPORTED because the operator-facing recovery surface must print THIS
// reason rather than its own copy of it: cmd/nftban-installer/emitRecovery used to
// hardcode "resumes at the switch phase and skips the boot-projection render", which
// is true of REBUILD_REFUSED_BUSY and false of APPLIED_UNVERIFIED.
func (s InstallState) RepairRefusalReason() string {
	if s.RepairReachesCommitted() {
		return ""
	}
	if s == StateCommitted {
		return "the transaction already committed; --repair is a no-op, not a recovery path"
	}
	if repairEvidenceRouteFor(s.ResumePhase()) == routeSkipsRender {
		return fmt.Sprintf(
			"--repair resumes at %s, which does not re-establish the boot-projection render that the "+
				"post-update convergence contract requires", s.ResumePhase())
	}
	return fmt.Sprintf(
		"--repair resumes at %s, which runs no rebuild and therefore RENDERS NOTHING; it could only reach "+
			"COMMITTED by carrying forward a convergence verdict, and %s is defined as having none "+
			"(CONVERGENCE_VERIFIED=%s)", s.ResumePhase(), s, ConvergenceNotEvaluatedValue)
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
			"%s declared RECOVERY_CLASS=REPAIR, but %s — there is no demonstrated route to COMMITTED "+
				"through --repair from this state",
			s, s.RepairRefusalReason())
	}
	return fmt.Sprintf(
		"%s declared RECOVERY_CLASS=%s, but --repair resumes at %s and DOES re-establish everything "+
			"COMMITTED requires, so the operator should be sent to the cheaper recovery",
		s, declared, s.ResumePhase())
}
