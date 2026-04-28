// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 — Restore Planner / Decision Bridge (PR-25 §24)
// =============================================================================
// meta:name="restore_planner"
// meta:type="package"
// meta:version="1.100.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="PR-25 commit 2 — translates a PR-24 PROCEED decision plus the inputs PR-24 already used into a frozen restore.TargetAuthority. Resolves exactly once. No mutation, no live re-detection. INV-PR25-AUTHORITY-IMMUTABILITY begins after PlanFromDecision returns successfully."
// meta:depends="github.com/itcmsgr/nftban/internal/installer/detect,github.com/itcmsgr/nftban/internal/installer/uninstall"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package restore

import (
	"errors"
	"fmt"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// Sentinel errors returned by PlanFromDecision. Callers may use errors.Is()
// to discriminate. None of these errors carry runtime data beyond what the
// caller already supplied.
var (
	// ErrPlanNotProceed is returned when the caller passes a non-PROCEED
	// DecisionResult. PR-24 REFUSE / REQUIRE_EXPLICIT_INTENT must NOT
	// reach the planner; they short-circuit at the dispatcher.
	ErrPlanNotProceed = errors.New("restore: PlanFromDecision called with non-PROCEED decision")

	// ErrPlanMissingPriorRecord is returned when a Flags.Restore (or
	// implicit-restore-on-strong-prior) PROCEED rule reached the planner
	// but the supplied priorRec is nil. This is a caller invariant
	// violation — PR-24's strong-prior PROCEED rules require a usable
	// record on disk.
	ErrPlanMissingPriorRecord = errors.New("restore: PROCEED rule requires a prior record but none was supplied")

	// ErrPlanInvariantViolation is returned when the caller's inputs
	// disagree with PR-24's PROCEED preconditions (e.g. both flags set,
	// or panel-auto without panel). PR-24 would never have returned
	// PROCEED for these combinations, so reaching the planner with them
	// means the caller corrupted the inputs between Decide and
	// PlanFromDecision.
	ErrPlanInvariantViolation = errors.New("restore: planner inputs violate PR-24 PROCEED preconditions")
)

// PlanFromDecision resolves the PR-25 TargetAuthority exactly once from
// the PR-24-approved inputs.
//
// Per contract §24, the planner consumes:
//
//   - decision   — must be PROCEED. Anything else returns ErrPlanNotProceed.
//   - input      — the same restore.DecisionInput that PR-24's Decide()
//                  evaluated. The planner reads the lattice axes (Flags,
//                  Authority, Prior, PanelPresent) verbatim. The planner
//                  does NOT re-run Decide and does NOT re-detect.
//   - priorRec   — the parsed prior-authority record from
//                  uninstall.Probe. Required for RecordedPrior PROCEED
//                  rules (G3.1+NoFlag/Restore, G4.1+NoFlag/Restore).
//                  Ignored for PanelNative rules (Q4 §20.3 forbids
//                  consulting it).
//   - panel      — the panel type from detect.DetectPanel. Required for
//                  PanelNative rules (Q4 §20). Ignored for RecordedPrior.
//
// Mapping (strict):
//
//	input.Flags.PanelAutoTakeover == true   → TargetPanelNative(panel)
//	input.Flags.PanelAutoTakeover == false  → TargetRecordedPrior(priorRec.FirewallType)
//
// All PROCEED rules in PR-24's engine.go fall into one of these two
// classes. PR-24 already rejected:
//
//   - Both flags set (REFUSE / G2/RestoreAndPanelAutoBothSet)
//   - panel-auto without panel (REFUSE / G2/PanelAutoTakeoverWithoutPanel)
//   - --restore on NoRecord (REQUIRE_EXPLICIT_INTENT / G3.3)
//   - --restore on Incomplete / Stale (REQUIRE_EXPLICIT_INTENT)
//
// so they cannot legitimately reach the planner. The planner still
// asserts these defensively and returns ErrPlanInvariantViolation if a
// caller corrupted the input chain.
//
// Side-effect contract:
//
//   - No filesystem read, no kernel probe, no service inspection,
//     no live re-classification, no fresh detect.Panel call,
//     no fresh prior-record read.
//   - Only operates on the values already passed in.
//
// Return contract:
//
//   - Returns a constructed TargetAuthority of kind RecordedPrior or
//     PanelNative. Kind=None is unreachable from PlanFromDecision —
//     enforced by exhaustive flag handling + invariant checks.
//   - Returns errors, never panics.
//
// Once this function returns nil error, the returned TargetAuthority is
// frozen for the entire PR-25 execution window
// (INV-PR25-AUTHORITY-IMMUTABILITY, contract §17.3).
func PlanFromDecision(
	decision DecisionResult,
	input DecisionInput,
	priorRec *uninstall.PriorRecord,
	panel detect.PanelType,
) (TargetAuthority, error) {
	// 1. Hard gate: only PROCEED reaches the planner.
	if decision.Output != OutputProceed {
		return TargetAuthority{}, fmt.Errorf("%w: got %q (rule=%q)",
			ErrPlanNotProceed, decision.Output, decision.Rule)
	}

	// 2. Defensive invariant: PR-24 G2 should have caught both-flags-set
	// before this point.
	if input.Flags.Restore && input.Flags.PanelAutoTakeover {
		return TargetAuthority{}, fmt.Errorf("%w: both Restore and PanelAutoTakeover flags set (rule=%q)",
			ErrPlanInvariantViolation, decision.Rule)
	}

	// 3. Defensive invariant: PR-24 G2 should have caught
	// panel-auto-without-panel before this point.
	if input.Flags.PanelAutoTakeover && !input.PanelPresent {
		return TargetAuthority{}, fmt.Errorf("%w: PanelAutoTakeover flag set but PanelPresent=false (rule=%q)",
			ErrPlanInvariantViolation, decision.Rule)
	}

	// 4. Mapping: panel-auto flag wins (Q4 §20). The prior record's
	// FirewallType is structurally ignored on this branch.
	if input.Flags.PanelAutoTakeover {
		if panel == detect.PanelNone {
			// Caller's panel argument disagrees with input.PanelPresent.
			// Belt-and-braces: if PanelPresent=true but panel=PanelNone,
			// the dispatcher fed inconsistent data.
			return TargetAuthority{}, fmt.Errorf("%w: PanelAutoTakeover requires non-None panel but panel=%q (rule=%q)",
				ErrPlanInvariantViolation, panel, decision.Rule)
		}
		ta, err := TargetPanelNative(panel)
		if err != nil {
			// Should be unreachable given the panel != PanelNone check
			// above, but plumb the constructor error through rather than
			// inventing one.
			return TargetAuthority{}, fmt.Errorf("restore: TargetPanelNative failed (rule=%q): %w",
				decision.Rule, err)
		}
		return ta, nil
	}

	// 5. Default branch: RecordedPrior. PR-24's strong-prior PROCEED
	// rules (G3.1+NoFlag, G3.1+Restore, G4.1+NoFlag, G4.1+Restore)
	// guarantee priorRec is non-nil with a valid FirewallType. Verify
	// defensively.
	if priorRec == nil {
		return TargetAuthority{}, fmt.Errorf("%w (rule=%q)",
			ErrPlanMissingPriorRecord, decision.Rule)
	}
	if priorRec.FirewallType == "" {
		return TargetAuthority{}, fmt.Errorf("%w: priorRec.FirewallType is empty (rule=%q)",
			ErrPlanInvariantViolation, decision.Rule)
	}

	// 6. Defensive invariant: PriorState reaching this branch must be
	// CompleteActive or CompleteInactive. NoRecord/Incomplete/Stale
	// either don't reach PROCEED or only reach the panel-auto branch
	// (handled above). If a strong-prior PROCEED rule reached here with
	// a non-strong PriorState, the caller's input chain is inconsistent.
	switch input.Prior {
	case PriorStateCompleteActive, PriorStateCompleteInactive:
		// expected
	default:
		return TargetAuthority{}, fmt.Errorf("%w: RecordedPrior path requires Prior=Complete{Active,Inactive} but got %q (rule=%q)",
			ErrPlanInvariantViolation, input.Prior, decision.Rule)
	}

	ta, err := TargetRecordedPrior(priorRec.FirewallType)
	if err != nil {
		// Constructor rejected the firewall type. Surface as invariant
		// violation: PR-24's Probe should have classified an unknown
		// firewall type as PriorRecordIncomplete (uninstall/prior.go
		// IncompleteReasonUnknownFirewallType) so PROCEED would never
		// fire for this record. Reaching here means the dispatcher
		// passed a record that should not have produced PROCEED.
		return TargetAuthority{}, fmt.Errorf("%w: TargetRecordedPrior rejected firewallType=%q (rule=%q): %v",
			ErrPlanInvariantViolation, priorRec.FirewallType, decision.Rule, err)
	}
	return ta, nil
}
