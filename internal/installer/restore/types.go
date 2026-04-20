// =============================================================================
// NFTBan v1.100 PR-24 — Authority Restoration Policy Engine Types (Pure)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-restore-types"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-20"
// meta:description="Closed enums + input/result types for PR-24 decision engine"
// meta:inventory.files="internal/installer/restore/types.go"
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
//   This package implements the restoration POLICY DECISION ENGINE only.
//   It spawns no external process, mutates no kernel / service / file,
//   writes no history entry, and does not invoke any execution code.
//   Output is a closed enum of three values — PROCEED / REFUSE /
//   REQUIRE_EXPLICIT_INTENT — and no fourth output may be added.
//
//   Execution of any PROCEED outcome belongs to PR-25+.
//
// =============================================================================
package restore

import "github.com/itcmsgr/nftban/internal/installer/uninstall"

// Output is the closed enum of the three (and only three) outputs of
// the PR-24 decision engine. Per seed §4 (merged), no fourth value
// exists, and adding one is a contract violation caught by the
// G4-RESTORE-DECISION-CORRECTNESS CI gate.
type Output string

const (
	// OutputProceed — policy permits restoration. PR-25+ may execute.
	OutputProceed Output = "PROCEED"
	// OutputRefuse — policy forbids restoration. No execution permitted.
	OutputRefuse Output = "REFUSE"
	// OutputRequireExplicitIntent — policy cannot decide. Operator must
	// supply additional intent (e.g. switch the flag being used, or
	// accept that there is no valid restoration target).
	OutputRequireExplicitIntent Output = "REQUIRE_EXPLICIT_INTENT"
)

// PriorState is the normalized prior-authority-record state consumed by
// the decision engine. It is derived from uninstall.ProbeResult +
// freshness window check in the dispatcher layer; the engine itself
// takes the reduced state only.
//
// Mapping from uninstall.PriorRecordState (see dispatcher):
//
//   PriorNoRecord             → PriorStateNoRecord
//   PriorRecordMalformed      → preflight error (NOT a lattice input)
//   PriorRecordIncomplete     → PriorStateIncomplete
//   PriorRecordUsableActive   + recorded_at ≤ 365d → PriorStateCompleteActive
//   PriorRecordUsableActive   + recorded_at > 365d → PriorStateStale
//   PriorRecordUsableInactive + recorded_at ≤ 365d → PriorStateCompleteInactive
//   PriorRecordUsableInactive + recorded_at > 365d → PriorStateStale
//
// Legacy records that lack the ActiveAtInstall field are classified by
// uninstall.Probe as PriorRecordIncomplete (see uninstall/prior.go
// PR-P2-1 hardening). They therefore flow through PriorStateIncomplete
// here → REQUIRE_EXPLICIT_INTENT, per seed §3.B.
type PriorState string

const (
	PriorStateNoRecord         PriorState = "no_record"
	PriorStateCompleteActive   PriorState = "complete_active"
	PriorStateCompleteInactive PriorState = "complete_inactive"
	PriorStateIncomplete       PriorState = "incomplete"
	PriorStateStale            PriorState = "stale"
)

// StalenessWindowDays locks the freshness window at 365 days per seed
// §3.B and amendment history (auditor-approved). Configurability is a
// seed §15 follow-up item; PR-24 has no configurability knob.
const StalenessWindowDays = 365

// Flags captures the two operator-intent flags the engine considers.
// Exactly one of Restore / PanelAutoTakeover may be set at lattice
// evaluation time; the "both set" case is an input-validity REFUSE and
// is caught by Group 2 of the lattice (never reaches the proceed
// decisions).
type Flags struct {
	// Restore corresponds to --restore-prior-authority in the CLI
	// surface. Semantic: "restore the recorded prior firewall."
	Restore bool
	// PanelAutoTakeover corresponds to --panel-auto-takeover.
	// Semantic: "install the panel-native firewall." Target is the
	// panel, not the prior record — this asymmetry is the policy
	// hinge in seed §3.3 / §4.2.
	PanelAutoTakeover bool
}

// DecisionInput is the pure-function input to Decide. Every axis is
// pre-reduced (no raw probe results, no executor references, no file
// system). This keeps the engine side-effect-free by construction.
type DecisionInput struct {
	// Authority is the classifier state. Taken verbatim from
	// uninstall.ClassifyResult.State; AmbiguityKind is carried in the
	// dedicated field below so the engine does not have to re-import
	// or re-derive sub-classification.
	Authority uninstall.CurrentAuthority

	// Ambiguity is the sub-classification of AuthorityAmbiguous.
	// MUST be uninstall.AmbiguityNone for any Authority !=
	// AuthorityAmbiguous. Violations are treated as a preflight
	// invariant error in the dispatcher, not a lattice output.
	Ambiguity uninstall.AmbiguityKind

	// Prior is the normalized prior-record state (see PriorState).
	Prior PriorState

	// Flags captures operator intent.
	Flags Flags

	// PanelPresent is a single boolean rather than the raw panel type.
	// The lattice treats panel context as "panel or no panel"; any
	// specific panel (DA / cPanel / Plesk / Hestia / etc.) is
	// equivalent for policy purposes.
	PanelPresent bool
}

// DecisionResult is the pure-function output of Decide. Contains the
// closed-enum output plus the matched rule identifier for logging,
// testing, and CI-gate coverage assertions.
type DecisionResult struct {
	// Output is one of OutputProceed / OutputRefuse /
	// OutputRequireExplicitIntent. No fourth value.
	Output Output

	// Rule identifies the lattice rule that matched. The string is
	// stable (contract-level); tests and CI gates assert on it. Format:
	// "G{group}.{subgroup}/{flag-or-condition}", e.g. "G1/AuthorityNFTBan",
	// "G3.3/NoRecord+Restore", "G4.3/PanelAutoOnOrphan". See engine.go
	// for the canonical list.
	Rule string

	// Reason is a short human-readable explanation of the output. Not
	// contract-stable; kept for operator-facing output and logging.
	Reason string
}
