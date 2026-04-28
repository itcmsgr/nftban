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

import (
	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

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
	// AcceptOrphanNFTBan corresponds to --accept-orphan-nftban
	// (Amendment 2, locked 2026-04-28). Semantic: "explicit operator
	// intent to restore CSF on a DirectAdmin host where NFTBan is the
	// current authority and no prior-authority record exists." Combined
	// with PanelAutoTakeover + DirectAdmin + strong CSF-disabled
	// evidence, this activates the §53 G1 split orphan-intent path.
	// Standalone (without PanelAutoTakeover, or under any other
	// classifier) the flag has no effect — REFUSE remains.
	//
	// MUST be supplied via CLI argv only. No env-var, no config-file,
	// no implicit default — see Amendment 2 §55.
	AcceptOrphanNFTBan bool
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
	// equivalent for policy purposes for §6 Groups 1–5.
	PanelPresent bool

	// Panel is the typed panel identity. Required by Amendment 2 §54
	// evidence row E.1 (the orphan-intent PROCEED path activates only
	// for Panel == detect.PanelDirectAdmin). Outside the Amendment 2
	// G1/AuthorityNFTBan split, the lattice ignores this field —
	// PanelPresent remains the sole panel input for §6 Groups 3 and 4.
	Panel detect.PanelType

	// OrphanEvidence carries the §54.1 read-only evidence predicate
	// result, populated by the dispatcher only when the candidate
	// triple (AuthorityNFTBan + Prior=NoRecord + Panel=DirectAdmin +
	// Flags.PanelAutoTakeover + Flags.AcceptOrphanNFTBan) is present.
	// Nil for every other input pattern — the engine MUST NOT
	// dereference it outside the Amendment 2 split.
	OrphanEvidence *OrphanEvidence
}

// OrphanEvidence is the §54.1 evidence predicate result. All 13 rows
// are read-only observations of the live host state. The engine
// consumes a pre-evaluated struct; the dispatcher (`gatherOrphanEvidence`)
// does the live reads.
//
// `AllTrue()` returns true iff every row is satisfied; `FailedRowID()`
// returns the first failing row's stable ID (e.g. "AMD2-E.6") for
// structured logging. The struct is value-type so a nil pointer at
// DecisionInput is unambiguous ("evidence not gathered").
type OrphanEvidence struct {
	E1PanelDirectAdmin    bool // detect.DetectPanel == PanelDirectAdmin
	E2AuthorityNFTBan     bool // uninstall.Classify == AuthorityNFTBan
	E3PriorNoRecord       bool // uninstall.Probe == PriorNoRecord
	E4PanelAutoTakeover   bool // --panel-auto-takeover present
	E5AcceptOrphanNFTBan  bool // --accept-orphan-nftban present (CLI argv only)
	E6CSFServiceDisabled  bool // csf.service exists AND not active AND is-enabled in {masked, disabled}
	E7CSFDisabledExists   bool // /usr/sbin/csf.disabled exists
	E8CSFAbsent           bool // /usr/sbin/csf does NOT exist
	E9NftIPNftbanPresent  bool // nft table ip nftban present
	E10NftIP6NftbanPres   bool // nft table ip6 nftban present
	E11NftbandActive      bool // nftband.service active
	E12NoConflictExternal bool // classifier did not return AmbiguityConflictExternal
	E13NoAmbiguous        bool // classifier did not return AuthorityAmbiguous
}

// AllTrue reports whether every §54.1 row is satisfied. Read failures
// in the dispatcher MUST set the corresponding row to false — never
// REQUIRE_EXPLICIT_INTENT — per Amendment 2 §54.2.
func (e *OrphanEvidence) AllTrue() bool {
	if e == nil {
		return false
	}
	return e.E1PanelDirectAdmin &&
		e.E2AuthorityNFTBan &&
		e.E3PriorNoRecord &&
		e.E4PanelAutoTakeover &&
		e.E5AcceptOrphanNFTBan &&
		e.E6CSFServiceDisabled &&
		e.E7CSFDisabledExists &&
		e.E8CSFAbsent &&
		e.E9NftIPNftbanPresent &&
		e.E10NftIP6NftbanPres &&
		e.E11NftbandActive &&
		e.E12NoConflictExternal &&
		e.E13NoAmbiguous
}

// FailedRowID returns the stable ID of the first false row (e.g.
// "AMD2-E.6"), or empty string if all rows are true. Nil receiver
// returns "AMD2-E.0" so structured logs distinguish "evidence not
// gathered" from "every row evaluated false".
func (e *OrphanEvidence) FailedRowID() string {
	if e == nil {
		return "AMD2-E.0"
	}
	switch {
	case !e.E1PanelDirectAdmin:
		return "AMD2-E.1"
	case !e.E2AuthorityNFTBan:
		return "AMD2-E.2"
	case !e.E3PriorNoRecord:
		return "AMD2-E.3"
	case !e.E4PanelAutoTakeover:
		return "AMD2-E.4"
	case !e.E5AcceptOrphanNFTBan:
		return "AMD2-E.5"
	case !e.E6CSFServiceDisabled:
		return "AMD2-E.6"
	case !e.E7CSFDisabledExists:
		return "AMD2-E.7"
	case !e.E8CSFAbsent:
		return "AMD2-E.8"
	case !e.E9NftIPNftbanPresent:
		return "AMD2-E.9"
	case !e.E10NftIP6NftbanPres:
		return "AMD2-E.10"
	case !e.E11NftbandActive:
		return "AMD2-E.11"
	case !e.E12NoConflictExternal:
		return "AMD2-E.12"
	case !e.E13NoAmbiguous:
		return "AMD2-E.13"
	}
	return ""
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
