// =============================================================================
// NFTBan v1.100 PR-24 — Authority Restoration Policy Decision Engine
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-restore-engine"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-20"
// meta:description="Pure decision engine for PR-24 restoration policy (lattice per seed §6)"
// meta:inventory.files="internal/installer/restore/engine.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// PR-24 scope lock (per merged contract seed, PR #493):
//
//   Pure decision. No side effects. No process spawn. No filesystem.
//   No kernel. No service. No history. Implements exactly the lattice
//   in seed §6 with the top-down precedence rule in §5.
//
//   If a cell of the input space does not match a rule, Decide panics.
//   This is by design: the lattice claims to cover every input, and a
//   fallthrough is a contract violation that the G4-RESTORE-
//   DECISION-CORRECTNESS CI gate catches via exhaustive fixtures. A
//   silent default in this file would directly violate seed §5
//   ("no default fallthrough branch") — losing at compile-time / CI is
//   strictly better than losing at runtime with the wrong answer.
//
// =============================================================================
package restore

import (
	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// Rule identifiers. Stable strings; fixtures and CI gates assert on
// these. Keep in sync with seed §6 group numbering.
const (
	// Group 1 — classifier hard-stops
	RuleG1AuthorityNFTBan          = "G1/AuthorityNFTBan"
	RuleG1AuthorityExternal        = "G1/AuthorityExternal"
	RuleG1AmbiguityConflictExt     = "G1/AmbiguityConflictExternal"

	// Group 1 — Amendment 2 split sub-rules (§53). These live ENTIRELY
	// within Group 1; no later group ever defeats a Group 1 outcome.
	RuleG1NFTBanDefault       = "G1/AuthorityNFTBan/default"
	RuleG1NFTBanOrphanProceed = "G1/AuthorityNFTBan/OrphanProceed"
	RuleG1EvidenceMismatch    = "G1/EvidenceMismatch"

	// Group 2 — input/flag validity
	RuleG2PanelAutoWithoutPanel    = "G2/PanelAutoTakeoverWithoutPanel"
	RuleG2BothRestoreFlags         = "G2/RestoreAndPanelAutoBothSet"

	// Group 3 — AuthorityNone
	RuleG3_1StrongPriorNoFlag      = "G3.1/StrongPrior+NoFlag"
	RuleG3_1StrongPriorRestore     = "G3.1/StrongPrior+Restore"
	RuleG3_1StrongPriorPanelAuto   = "G3.1/StrongPrior+PanelAuto"
	RuleG3_2CompleteInactive       = "G3.2/CompleteInactive"
	RuleG3_3NoRecordNoFlag         = "G3.3/NoRecord+NoFlag"
	RuleG3_3NoRecordRestore        = "G3.3/NoRecord+Restore"
	RuleG3_3NoRecordPanelAuto      = "G3.3/NoRecord+PanelAuto"
	RuleG3_3Incomplete             = "G3.3/Incomplete"
	RuleG3_3Stale                  = "G3.3/Stale"

	// Group 4 — AmbiguityOrphanNFTBan
	RuleG4_1OrphanStrongNoFlag     = "G4.1/OrphanStrong+NoFlag"
	RuleG4_1OrphanStrongRestore    = "G4.1/OrphanStrong+Restore"
	RuleG4_2OrphanCompleteInactive = "G4.2/OrphanCompleteInactive"
	RuleG4_2OrphanNoRecordNoFlag   = "G4.2/OrphanNoRecord+NoFlag"
	RuleG4_2OrphanNoRecordRestore  = "G4.2/OrphanNoRecord+Restore"
	RuleG4_2OrphanIncomplete       = "G4.2/OrphanIncomplete"
	RuleG4_2OrphanStale            = "G4.2/OrphanStale"
	RuleG4_3OrphanPanelAuto        = "G4.3/OrphanPanelAuto"
)

// Decide evaluates the lattice (seed §6) with the top-down precedence
// rule (seed §5). Returns a DecisionResult whose Output is exactly one
// of OutputProceed / OutputRefuse / OutputRequireExplicitIntent.
//
// Precedence (evaluated in this order; earlier match wins and is
// final — no later rule may override):
//
//   1. Classifier hard-stops
//   2. Input / flag validity
//   3. Prior-record integrity gates
//   4. Panel context gates (handled inline in 3 and 4 per seed §6 G5)
//   5. Proceed decisions
//
// Every possible input falls into exactly one rule; see tests for
// exhaustive coverage. A panic means a contract regression.
func Decide(in DecisionInput) DecisionResult {
	// ─── Group 1: Classifier hard-stops ──────────────────────────────
	//
	// These three states are absolute refusals: no flag and no panel
	// context may override them. Per seed §5 invariant, these are
	// evaluated first and cannot be weakened by later rules.

	switch in.Authority {
	case uninstall.AuthorityNFTBan:
		return decideAuthorityNFTBan(in)
	case uninstall.AuthorityExternal:
		return DecisionResult{
			Output: OutputRefuse,
			Rule:   RuleG1AuthorityExternal,
			Reason: "an external firewall is already authoritative; restore would silently override it",
		}
	case uninstall.AuthorityAmbiguous:
		if in.Ambiguity == uninstall.AmbiguityConflictExternal {
			return DecisionResult{
				Output: OutputRefuse,
				Rule:   RuleG1AmbiguityConflictExt,
				Reason: "conflicting external authority detected; operator must resolve before any restoration",
			}
		}
		// Fall through to Group 4 (AmbiguityOrphanNFTBan path). Any
		// other Ambiguity sub-kind is a preflight invariant violation
		// and is caught by the final panic.
	}

	// ─── Group 2: Input / flag validity ──────────────────────────────

	if in.Flags.Restore && in.Flags.PanelAutoTakeover {
		return DecisionResult{
			Output: OutputRefuse,
			Rule:   RuleG2BothRestoreFlags,
			Reason: "--restore-prior-authority and --panel-auto-takeover are mutually exclusive; pick one",
		}
	}

	if in.Flags.PanelAutoTakeover && !in.PanelPresent {
		return DecisionResult{
			Output: OutputRefuse,
			Rule:   RuleG2PanelAutoWithoutPanel,
			Reason: "--panel-auto-takeover requires a control panel on the host; none detected",
		}
	}

	// ─── Group 3: AuthorityNone ──────────────────────────────────────

	if in.Authority == uninstall.AuthorityNone {
		return decideAuthorityNone(in)
	}

	// ─── Group 4: AmbiguityOrphanNFTBan ──────────────────────────────

	if in.Authority == uninstall.AuthorityAmbiguous &&
		in.Ambiguity == uninstall.AmbiguityOrphanNFTBan {
		return decideAmbiguityOrphan(in)
	}

	// Contract regression guard: no rule matched. Per seed §5, every
	// input must land on exactly one rule. Reaching here means either
	// a new Authority value was introduced without a corresponding
	// rule, or the dispatcher passed an invariant-violating input
	// (e.g. Authority != Ambiguous but Ambiguity != None).
	panic("restore.Decide: input did not match any lattice rule — contract regression (add a rule or route to preflight error)")
}

// decideAuthorityNone implements seed §6 Group 3 for
// Authority=AuthorityNone. Split out so the main Decide stays readable.
//
// Precedence within Group 3:
//   3.1 strong prior (Complete + ActiveAtInstall=true)
//   3.2 complete-but-inactive (Complete + ActiveAtInstall=false)
//   3.3 weak / absent prior (NoRecord / Incomplete / Stale)
//
// Each sub-group is exhaustive over the flag space {none, Restore,
// PanelAutoTakeover}.
func decideAuthorityNone(in DecisionInput) DecisionResult {
	switch in.Prior {
	case PriorStateCompleteActive:
		// 3.1 Strong prior
		switch {
		case in.Flags.Restore:
			return DecisionResult{
				Output: OutputProceed,
				Rule:   RuleG3_1StrongPriorRestore,
				Reason: "restore requested against complete active prior-authority record",
			}
		case in.Flags.PanelAutoTakeover:
			// Group 2 already refused PanelAutoTakeover without panel;
			// reaching here means panel is present.
			return DecisionResult{
				Output: OutputProceed,
				Rule:   RuleG3_1StrongPriorPanelAuto,
				Reason: "panel-auto-takeover with panel present; target is panel-native",
			}
		default:
			return DecisionResult{
				Output: OutputRequireExplicitIntent,
				Rule:   RuleG3_1StrongPriorNoFlag,
				Reason: "complete active prior-authority record available; pass --restore-prior-authority to restore it",
			}
		}

	case PriorStateCompleteInactive:
		// 3.2 Complete-but-inactive: always REQUIRE_EXPLICIT_INTENT,
		// regardless of flags. Restoring a firewall the operator had
		// deliberately disabled is an implicit re-enablement.
		return DecisionResult{
			Output: OutputRequireExplicitIntent,
			Rule:   RuleG3_2CompleteInactive,
			Reason: "prior firewall was not active at install time; restore semantics are ambiguous between preserve-inactive and activate",
		}

	case PriorStateNoRecord:
		// 3.3 NoRecord: --restore returns REQUIRE_EXPLICIT_INTENT per
		// the locked amendment (no implicit target); panel-auto still
		// proceeds because panel is its own target.
		switch {
		case in.Flags.Restore:
			return DecisionResult{
				Output: OutputRequireExplicitIntent,
				Rule:   RuleG3_3NoRecordRestore,
				Reason: "--restore-prior-authority requires a recorded prior firewall; no record on disk",
			}
		case in.Flags.PanelAutoTakeover:
			return DecisionResult{
				Output: OutputProceed,
				Rule:   RuleG3_3NoRecordPanelAuto,
				Reason: "panel-auto-takeover with panel present; panel-native target is independent of prior record",
			}
		default:
			return DecisionResult{
				Output: OutputRequireExplicitIntent,
				Rule:   RuleG3_3NoRecordNoFlag,
				Reason: "no prior-authority record and no operator intent flag; choose --restore-prior-authority or --panel-auto-takeover",
			}
		}

	case PriorStateIncomplete:
		// 3.3 Incomplete: any flag → REQUIRE_EXPLICIT_INTENT.
		return DecisionResult{
			Output: OutputRequireExplicitIntent,
			Rule:   RuleG3_3Incomplete,
			Reason: "prior-authority record is incomplete (missing required field); cannot be trusted for automatic restoration",
		}

	case PriorStateStale:
		// 3.3 Stale: any flag → REQUIRE_EXPLICIT_INTENT.
		return DecisionResult{
			Output: OutputRequireExplicitIntent,
			Rule:   RuleG3_3Stale,
			Reason: "prior-authority record exceeds the 365-day freshness window; operator must confirm it still reflects intent",
		}
	}

	// Contract regression: a PriorState value exists with no rule.
	panic("restore.decideAuthorityNone: unhandled PriorState — contract regression")
}

// decideAmbiguityOrphan implements seed §6 Group 4 for orphan nftban
// ambiguity. Panel-auto-takeover is an absolute refusal here (4.3);
// otherwise the same prior-record strata as Group 3 apply, with --restore
// permitted only under strong prior (4.1).
func decideAmbiguityOrphan(in DecisionInput) DecisionResult {
	// 4.3 Orphan + panel-auto: REFUSE regardless of prior. Panel-auto
	// must never fire over nftban residue, recoverable or not.
	if in.Flags.PanelAutoTakeover {
		return DecisionResult{
			Output: OutputRefuse,
			Rule:   RuleG4_3OrphanPanelAuto,
			Reason: "nftban residue present (orphan); panel-auto-takeover must not fire over residual nftban state",
		}
	}

	switch in.Prior {
	case PriorStateCompleteActive:
		// 4.1 Strong prior
		if in.Flags.Restore {
			return DecisionResult{
				Output: OutputProceed,
				Rule:   RuleG4_1OrphanStrongRestore,
				Reason: "orphan ambiguity with complete active prior-record; restore requested",
			}
		}
		return DecisionResult{
			Output: OutputRequireExplicitIntent,
			Rule:   RuleG4_1OrphanStrongNoFlag,
			Reason: "orphan nftban residue plus complete active prior-record; operator must choose --restore-prior-authority",
		}

	case PriorStateCompleteInactive:
		return DecisionResult{
			Output: OutputRequireExplicitIntent,
			Rule:   RuleG4_2OrphanCompleteInactive,
			Reason: "orphan ambiguity; prior firewall was not active at install time; restore semantics ambiguous",
		}

	case PriorStateNoRecord:
		if in.Flags.Restore {
			return DecisionResult{
				Output: OutputRequireExplicitIntent,
				Rule:   RuleG4_2OrphanNoRecordRestore,
				Reason: "--restore-prior-authority requires a recorded prior firewall; no record on disk (orphan path)",
			}
		}
		return DecisionResult{
			Output: OutputRequireExplicitIntent,
			Rule:   RuleG4_2OrphanNoRecordNoFlag,
			Reason: "orphan nftban residue and no prior-authority record; operator must supply intent",
		}

	case PriorStateIncomplete:
		return DecisionResult{
			Output: OutputRequireExplicitIntent,
			Rule:   RuleG4_2OrphanIncomplete,
			Reason: "orphan ambiguity; prior-authority record is incomplete",
		}

	case PriorStateStale:
		return DecisionResult{
			Output: OutputRequireExplicitIntent,
			Rule:   RuleG4_2OrphanStale,
			Reason: "orphan ambiguity; prior-authority record is stale",
		}
	}

	panic("restore.decideAmbiguityOrphan: unhandled PriorState — contract regression")
}

// decideAuthorityNFTBan implements Amendment 2 §53 Group 1 split for
// Authority=AuthorityNFTBan. The split is ENTIRELY within Group 1; no
// later group ever defeats a Group 1 outcome. §5 precedence holds.
//
// Evaluation order (§53.2):
//
//  1. Pre-condition triple check — only the specific combination
//     `Prior=NoRecord + Panel=DirectAdmin + PanelAutoTakeover +
//     AcceptOrphanNFTBan` (and Group 2 not interfering) is the
//     "orphan-intent candidate". Any other combination → REFUSE
//     with `G1/AuthorityNFTBan/default`.
//  2. §54 evidence predicate evaluation — if all 13 rows hold,
//     PROCEED with `G1/AuthorityNFTBan/OrphanProceed`. If any row
//     is false, REFUSE with `G1/EvidenceMismatch` (NOT
//     REQUIRE_EXPLICIT_INTENT — see §54.2).
//
// Group 2 precedence preserved: `--restore-prior-authority +
// --panel-auto-takeover` (both set) emits `G2/RestoreAndPanelAutoBothSet`;
// `--panel-auto-takeover` with `PanelPresent=false` emits
// `G2/PanelAutoTakeoverWithoutPanel`. Both Group 2 rules win over
// the Amendment 2 split because they're checked here before the
// candidate-triple delegation, in that exact precedence order.
//
// All other AuthorityNFTBan flag patterns (no flags, only Restore,
// only PanelAutoTakeover, AcceptOrphanNFTBan without PanelAutoTakeover,
// Panel != DirectAdmin, Prior != NoRecord, etc.) emit
// `G1/AuthorityNFTBan/default` REFUSE — the Amendment 2 split's
// "default" sub-rule that preserves the original PR-24 G1 semantics.
func decideAuthorityNFTBan(in DecisionInput) DecisionResult {
	// Group 2 precedence: both flags set is an input-validity REFUSE.
	// Pinned by Amendment 2 §56.1 row 19.
	if in.Flags.Restore && in.Flags.PanelAutoTakeover {
		return DecisionResult{
			Output: OutputRefuse,
			Rule:   RuleG2BothRestoreFlags,
			Reason: "--restore-prior-authority and --panel-auto-takeover are mutually exclusive; pick one",
		}
	}

	// Group 2 precedence: panel-auto without a panel is an input-
	// validity REFUSE. Pinned by Amendment 2 §56.1 row 4.
	if in.Flags.PanelAutoTakeover && !in.PanelPresent {
		return DecisionResult{
			Output: OutputRefuse,
			Rule:   RuleG2PanelAutoWithoutPanel,
			Reason: "--panel-auto-takeover requires a control panel on the host; none detected",
		}
	}

	// Candidate-triple check for the Amendment 2 orphan-intent path.
	// Every condition must hold, else fall through to the default
	// REFUSE. The triple is composite: classifier already established
	// AuthorityNFTBan (caller); we additionally require
	// Prior=NoRecord, Panel=DirectAdmin, --panel-auto-takeover, and
	// --accept-orphan-nftban.
	triplePresent := in.Prior == PriorStateNoRecord &&
		in.Panel == detect.PanelDirectAdmin &&
		in.Flags.PanelAutoTakeover &&
		in.Flags.AcceptOrphanNFTBan

	if !triplePresent {
		return DecisionResult{
			Output: OutputRefuse,
			Rule:   RuleG1NFTBanDefault,
			Reason: "nftban is already authoritative on this host; no restore needed (default G1 hard-stop)",
		}
	}

	// Triple present — delegate to the §54 evidence predicate. The
	// dispatcher MUST have populated in.OrphanEvidence; nil is treated
	// as "evidence not gathered" → REFUSE/EvidenceMismatch with
	// AMD2-E.0 (defensive — should never happen if dispatcher follows
	// §54.3).
	if in.OrphanEvidence == nil || !in.OrphanEvidence.AllTrue() {
		return DecisionResult{
			Output: OutputRefuse,
			Rule:   RuleG1EvidenceMismatch,
			Reason: "amendment-2 evidence predicate did not hold; failing-row=" + in.OrphanEvidence.FailedRowID(),
		}
	}

	// All §54.1 rows hold. PROCEED PanelNative/csf — same target the
	// existing G3.3 NoRecord+PanelAuto path resolves to. PlanFromDecision
	// reuses the existing panel-static-map (§20.1: PanelDirectAdmin → "csf").
	return DecisionResult{
		Output: OutputProceed,
		Rule:   RuleG1NFTBanOrphanProceed,
		Reason: "amendment-2 orphan-intent: AuthorityNFTBan + DirectAdmin + strong CSF-disabled evidence; restoring CSF per §53.1",
	}
}
