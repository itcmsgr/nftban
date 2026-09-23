// =============================================================================
// NFTBan v1.233.x Lane B — RECONCILE RECOVERY CLASS + ELIGIBILITY
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-recovery-reconcile"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-23"
// meta:description="Declares RECONCILE — the recovery class that derives lifecycle truth from proven live reality WITHOUT mutating that reality — and the deliberately narrow eligibility predicate that admits only REBUILD_REFUSED_BUSY. Carries its own rejecting anti-drift validator, in the same shape as ValidateRecoveryClass."
// meta:inventory.files="internal/installer/state/reconcile.go"
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
// WHY A THIRD RECOVERY CLASS EXISTS — MEASURED ON PRODUCTION srv3, 2026-09-23
// ═════════════════════════════════════════════════════════════════════════════════
// srv3 reached REBUILD_REFUSED_BUSY: every rebuild attempt inside the installer's
// deadline was refused by legitimate long-running convergence holders. Per that
// state's own definition NO REBUILD EXECUTED and the firewall was NOT MODIFIED.
//
// The runtime was subsequently repaired by a standalone firewall rebuild in a quiesced
// window. Live reality then satisfied everything the update transaction had promised —
// v1.233.0 package, keyed per-source connlimit sets, zero bare host-wide ct-count
// rules, convergence generation advanced by that rebuild's own commit.
//
// But NO SUPPORTED SURFACE COULD RECONCILE THE RECORD:
//   - --repair resumes at SWITCH and skips the boot-projection render (see recovery.go);
//     it cannot reach COMMITTED and is already correctly refused.
//   - a full retry would REBUILD A HEALTHY PRODUCTION FIREWALL to satisfy a bookkeeping
//     field.
//
//	LIFECYCLE STATE MUST BE DERIVED FROM PROVEN LIVE REALITY;
//	LIVE REALITY MUST NEVER BE ALTERED MERELY TO SATISFY LIFECYCLE STATE.
//
// RECONCILE is the class that closes that gap. It mutates the RECORD ONLY.

const (
	// RecoveryReconcile — the lifecycle record can be brought into agreement with
	// live reality by PROVING that reality, with no rebuild, no reinstall, and no
	// runtime mutation of any kind.
	//
	// ⛔ THIS IS NOT "FORCE" AND IT IS NOT A HAND-EDIT. It is strictly harder to
	// satisfy than either: it must establish, live and in one serialized window,
	// every fact the original transaction promised, and it must refuse if any of
	// them is unproven or if convergence moves underneath it while it looks.
	//
	// ⛔ IT PROVES; IT DOES NOT ASSUME. A matching structure fingerprint identifies
	// WHICH structure was certified — it is never a substitute for certifying it.
	RecoveryReconcile RecoveryClass = "RECONCILE"
)

// ReconcileEligible reports whether RECONCILE is admissible for this state AT ALL.
//
// ⛔ DELIBERATELY NARROW — ONE STATE. Eligibility here is a necessary condition, never
// a sufficient one: it says only that reconciliation is a COHERENT QUESTION to ask of
// this state. Whether live reality actually supports it is decided by the semantic
// assertions, which can and must still refuse.
//
// The admitting property is specific and not shared: REBUILD_REFUSED_BUSY asserts that
// NO REBUILD EXECUTED AND THE FIREWALL WAS NOT MODIFIED. Nothing this transaction did
// is left half-applied, so there is no partial mutation for a record change to paper
// over. Every excluded state fails exactly that test:
//
//	REBUILD_NOT_EXECUTED  execution was NOT ESTABLISHED — "no record" here means the
//	                      opposite thing, and we do not know whether anything ran.
//	                      Ambiguous provenance is not a base for certification.
//	APPLIED_UNVERIFIED    a mutation DID land. Its convergence was never evaluated,
//	                      which is a different defect with a different remedy.
//	DEGRADED / FAILED_*   a failure may have left the host partially mutated; deriving
//	                      COMMITTED from live state would conceal that, not reconcile it.
//	COMMITTED             nothing to reconcile.
//
// ⛔ DO NOT WIDEN THIS BY ANALOGY. Each additional state needs its own proof that a
// record-only change cannot mask an incomplete mutation.
func (s InstallState) ReconcileEligible() bool {
	return s == StateRebuildRefusedBusy
}

// ReconcileRefusalReason explains, in terms that apply to `s`, why RECONCILE is not
// admissible for it. Returns "" when it is.
//
// EXPORTED so the operator surface prints THIS reason instead of keeping its own copy —
// the drift that put a wrong "--repair resumes at the switch phase" sentence in front
// of APPLIED_UNVERIFIED operators.
func (s InstallState) ReconcileRefusalReason() string {
	if s.ReconcileEligible() {
		return ""
	}
	switch s {
	case StateCommitted:
		return "the transaction already committed; there is no divergence to reconcile"
	case StateRebuildNotExecuted:
		return fmt.Sprintf(
			"%s asserts that rebuild execution was NOT ESTABLISHED — it is unknown whether the firewall "+
				"was modified, and an unknown mutation history cannot support a derived COMMITTED", s)
	case StateAppliedUnverified:
		return fmt.Sprintf(
			"%s asserts that a mutation DID land with convergence never evaluated; that is a different "+
				"defect from a refused rebuild and is out of scope for record-only reconciliation", s)
	}
	return fmt.Sprintf(
		"%s does not assert that the firewall was left unmodified, so a record-only change to COMMITTED "+
			"could conceal a partially applied mutation rather than reconcile a bookkeeping divergence", s)
}

// ValidateReconcileEligibility reports why `declared` is wrong for `s`, or "" when right.
//
// ⛔ THE ANTI-DRIFT CONTROL, AND IT IS ONLY REAL BECAUSE IT CAN REJECT. It takes the
// claim from the CALLER rather than reading back what production computed, so a test can
// assert a DELIBERATELY WRONG eligibility and require this to catch it. If declaring
// DEGRADED as reconcile-eligible ever passes, the control is decorative.
func ValidateReconcileEligibility(s InstallState, declared bool) string {
	want := s.ReconcileEligible()
	if declared == want {
		return ""
	}
	if declared {
		return fmt.Sprintf(
			"%s declared RECONCILE-eligible, but %s", s, s.ReconcileRefusalReason())
	}
	return fmt.Sprintf(
		"%s declared NOT reconcile-eligible, but it asserts that no rebuild executed and the firewall "+
			"was not modified — the one shape a record-only reconciliation may act on", s)
}
