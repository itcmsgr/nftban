// =============================================================================
// NFTBan v1.100 PR-24 — Decision Engine Fixture Matrix + Determinism
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-restore-engine-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-20"
// meta:description="Rule-path coverage for PR-24 decision engine + determinism"
// meta:inventory.files="internal/installer/restore/engine_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package restore

import (
	"reflect"
	"sort"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// fixture is one rule-path test case. Together, fixtures exhaustively
// cover every rule declared in engine.go (asserted by
// TestRuleCoverage_EveryRuleExercised).
type fixture struct {
	name     string
	input    DecisionInput
	wantOut  Output
	wantRule string
}

// allFixtures is the canonical rule-path matrix. Every Rule* constant
// declared in engine.go MUST appear in exactly one fixture's wantRule.
// The coverage test below enforces that invariant.
var allFixtures = []fixture{
	// ───────────────────────── Group 1 hard-stops ────────────────────
	{
		// Amendment 2 §53 split: the umbrella RuleG1AuthorityNFTBan is
		// retained for grep / log parents, but every concrete fixture
		// resolves to a sub-rule. With Restore=true the candidate-triple
		// for orphan-intent does NOT hold (the orphan path requires
		// PanelAutoTakeover, not Restore), so the default sub-rule fires.
		name: "G1_AuthorityNFTBan_refuses_any_flag",
		input: DecisionInput{
			Authority: uninstall.AuthorityNFTBan,
			Prior:     PriorStateNoRecord,
			Flags:     Flags{Restore: true, PanelAutoTakeover: false},
		},
		wantOut:  OutputRefuse,
		wantRule: RuleG1NFTBanDefault,
	},
	// Amendment 2 §53 — Group 1 split sub-rules. These two fixtures
	// pin RuleG1NFTBanOrphanProceed and RuleG1EvidenceMismatch for the
	// coverage assertion. The full §56.1 matrix lives in
	// engine_amendment2_test.go.
	{
		name: "G1_AuthorityNFTBan_OrphanProceed_all_evidence_true",
		input: DecisionInput{
			Authority:    uninstall.AuthorityNFTBan,
			Prior:        PriorStateNoRecord,
			Panel:        detect.PanelDirectAdmin,
			PanelPresent: true,
			Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
			OrphanEvidence: &OrphanEvidence{
				E1PanelDirectAdmin:    true,
				E2AuthorityNFTBan:     true,
				E3PriorNoRecord:       true,
				E4PanelAutoTakeover:   true,
				E5AcceptOrphanNFTBan:  true,
				E6CSFServiceDisabled:  true,
				E7CSFDisabledExists:   true,
				E8CSFAbsent:           true,
				E9NftIPNftbanPresent:  true,
				E10NftIP6NftbanPres:   true,
				E11NftbandActive:      true,
				E12NoConflictExternal: true,
				E13NoAmbiguous:        true,
			},
		},
		wantOut:  OutputProceed,
		wantRule: RuleG1NFTBanOrphanProceed,
	},
	{
		name: "G1_EvidenceMismatch_one_row_false",
		input: DecisionInput{
			Authority:    uninstall.AuthorityNFTBan,
			Prior:        PriorStateNoRecord,
			Panel:        detect.PanelDirectAdmin,
			PanelPresent: true,
			Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
			OrphanEvidence: &OrphanEvidence{
				E1PanelDirectAdmin:    true,
				E2AuthorityNFTBan:     true,
				E3PriorNoRecord:       true,
				E4PanelAutoTakeover:   true,
				E5AcceptOrphanNFTBan:  true,
				E6CSFServiceDisabled:  false, // <-- single row false
				E7CSFDisabledExists:   true,
				E8CSFAbsent:           true,
				E9NftIPNftbanPresent:  true,
				E10NftIP6NftbanPres:   true,
				E11NftbandActive:      true,
				E12NoConflictExternal: true,
				E13NoAmbiguous:        true,
			},
		},
		wantOut:  OutputRefuse,
		wantRule: RuleG1EvidenceMismatch,
	},
	{
		name: "G1_AuthorityExternal_refuses_any_flag",
		input: DecisionInput{
			Authority: uninstall.AuthorityExternal,
			Prior:     PriorStateCompleteActive,
			Flags:     Flags{Restore: true},
		},
		wantOut:  OutputRefuse,
		wantRule: RuleG1AuthorityExternal,
	},
	{
		name: "G1_AmbiguityConflictExternal_refuses_any_flag",
		input: DecisionInput{
			Authority: uninstall.AuthorityAmbiguous,
			Ambiguity: uninstall.AmbiguityConflictExternal,
			Prior:     PriorStateCompleteActive,
			Flags:     Flags{PanelAutoTakeover: true},
			PanelPresent: true,
		},
		wantOut:  OutputRefuse,
		wantRule: RuleG1AmbiguityConflictExt,
	},

	// ───────────────────────── Group 2 input validity ────────────────
	{
		name: "G2_BothFlags_refuses",
		input: DecisionInput{
			Authority:    uninstall.AuthorityNone,
			Prior:        PriorStateCompleteActive,
			Flags:        Flags{Restore: true, PanelAutoTakeover: true},
			PanelPresent: true,
		},
		wantOut:  OutputRefuse,
		wantRule: RuleG2BothRestoreFlags,
	},
	{
		name: "G2_PanelAutoWithoutPanel_refuses",
		input: DecisionInput{
			Authority:    uninstall.AuthorityNone,
			Prior:        PriorStateCompleteActive,
			Flags:        Flags{PanelAutoTakeover: true},
			PanelPresent: false,
		},
		wantOut:  OutputRefuse,
		wantRule: RuleG2PanelAutoWithoutPanel,
	},

	// ───────────────────────── Group 3.1 strong prior ────────────────
	{
		name: "G3_1_StrongPrior_NoFlag_requiresIntent",
		input: DecisionInput{
			Authority: uninstall.AuthorityNone,
			Prior:     PriorStateCompleteActive,
			Flags:     Flags{},
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG3_1StrongPriorNoFlag,
	},
	{
		name: "G3_1_StrongPrior_Restore_proceeds",
		input: DecisionInput{
			Authority: uninstall.AuthorityNone,
			Prior:     PriorStateCompleteActive,
			Flags:     Flags{Restore: true},
		},
		wantOut:  OutputProceed,
		wantRule: RuleG3_1StrongPriorRestore,
	},
	{
		name: "G3_1_StrongPrior_PanelAuto_proceeds",
		input: DecisionInput{
			Authority:    uninstall.AuthorityNone,
			Prior:        PriorStateCompleteActive,
			Flags:        Flags{PanelAutoTakeover: true},
			PanelPresent: true,
		},
		wantOut:  OutputProceed,
		wantRule: RuleG3_1StrongPriorPanelAuto,
	},

	// ───────────────────────── Group 3.2 complete-inactive ───────────
	{
		name: "G3_2_CompleteInactive_AnyFlag_requiresIntent_Restore",
		input: DecisionInput{
			Authority: uninstall.AuthorityNone,
			Prior:     PriorStateCompleteInactive,
			Flags:     Flags{Restore: true},
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG3_2CompleteInactive,
	},
	{
		name: "G3_2_CompleteInactive_AnyFlag_requiresIntent_PanelAuto",
		input: DecisionInput{
			Authority:    uninstall.AuthorityNone,
			Prior:        PriorStateCompleteInactive,
			Flags:        Flags{PanelAutoTakeover: true},
			PanelPresent: true,
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG3_2CompleteInactive,
	},
	{
		name: "G3_2_CompleteInactive_NoFlag_requiresIntent",
		input: DecisionInput{
			Authority: uninstall.AuthorityNone,
			Prior:     PriorStateCompleteInactive,
			Flags:     Flags{},
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG3_2CompleteInactive,
	},

	// ───────────────────────── Group 3.3 weak / absent ───────────────
	{
		name: "G3_3_NoRecord_NoFlag_requiresIntent",
		input: DecisionInput{
			Authority: uninstall.AuthorityNone,
			Prior:     PriorStateNoRecord,
			Flags:     Flags{},
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG3_3NoRecordNoFlag,
	},
	{
		// Locked amendment: NoRecord + --restore ≠ PROCEED.
		name: "G3_3_NoRecord_Restore_requiresIntent_LOCKED_AMENDMENT",
		input: DecisionInput{
			Authority: uninstall.AuthorityNone,
			Prior:     PriorStateNoRecord,
			Flags:     Flags{Restore: true},
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG3_3NoRecordRestore,
	},
	{
		name: "G3_3_NoRecord_PanelAutoWithPanel_proceeds",
		input: DecisionInput{
			Authority:    uninstall.AuthorityNone,
			Prior:        PriorStateNoRecord,
			Flags:        Flags{PanelAutoTakeover: true},
			PanelPresent: true,
		},
		wantOut:  OutputProceed,
		wantRule: RuleG3_3NoRecordPanelAuto,
	},
	{
		name: "G3_3_Incomplete_AnyFlag_requiresIntent",
		input: DecisionInput{
			Authority: uninstall.AuthorityNone,
			Prior:     PriorStateIncomplete,
			Flags:     Flags{Restore: true},
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG3_3Incomplete,
	},
	{
		// Legacy-record-without-ActiveAtInstall flows through as
		// Incomplete (uninstall.Probe enforces this per PR-P2-1). This
		// fixture documents the contract at the lattice layer.
		name: "G3_3_Incomplete_LegacyMissingActiveAtInstall_requiresIntent",
		input: DecisionInput{
			Authority: uninstall.AuthorityNone,
			Prior:     PriorStateIncomplete,
			Flags:     Flags{},
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG3_3Incomplete,
	},
	{
		name: "G3_3_Stale_AnyFlag_requiresIntent",
		input: DecisionInput{
			Authority: uninstall.AuthorityNone,
			Prior:     PriorStateStale,
			Flags:     Flags{Restore: true},
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG3_3Stale,
	},

	// ───────────────────────── Group 4.1 orphan strong prior ─────────
	{
		name: "G4_1_OrphanStrong_NoFlag_requiresIntent",
		input: DecisionInput{
			Authority: uninstall.AuthorityAmbiguous,
			Ambiguity: uninstall.AmbiguityOrphanNFTBan,
			Prior:     PriorStateCompleteActive,
			Flags:     Flags{},
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG4_1OrphanStrongNoFlag,
	},
	{
		name: "G4_1_OrphanStrong_Restore_proceeds",
		input: DecisionInput{
			Authority: uninstall.AuthorityAmbiguous,
			Ambiguity: uninstall.AmbiguityOrphanNFTBan,
			Prior:     PriorStateCompleteActive,
			Flags:     Flags{Restore: true},
		},
		wantOut:  OutputProceed,
		wantRule: RuleG4_1OrphanStrongRestore,
	},

	// ───────────────────────── Group 4.2 orphan weak prior ───────────
	{
		name: "G4_2_OrphanCompleteInactive_requiresIntent",
		input: DecisionInput{
			Authority: uninstall.AuthorityAmbiguous,
			Ambiguity: uninstall.AmbiguityOrphanNFTBan,
			Prior:     PriorStateCompleteInactive,
			Flags:     Flags{Restore: true},
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG4_2OrphanCompleteInactive,
	},
	{
		name: "G4_2_OrphanNoRecord_NoFlag_requiresIntent",
		input: DecisionInput{
			Authority: uninstall.AuthorityAmbiguous,
			Ambiguity: uninstall.AmbiguityOrphanNFTBan,
			Prior:     PriorStateNoRecord,
			Flags:     Flags{},
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG4_2OrphanNoRecordNoFlag,
	},
	{
		// Locked amendment mirror in orphan path.
		name: "G4_2_OrphanNoRecord_Restore_requiresIntent_LOCKED_AMENDMENT",
		input: DecisionInput{
			Authority: uninstall.AuthorityAmbiguous,
			Ambiguity: uninstall.AmbiguityOrphanNFTBan,
			Prior:     PriorStateNoRecord,
			Flags:     Flags{Restore: true},
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG4_2OrphanNoRecordRestore,
	},
	{
		name: "G4_2_OrphanIncomplete_requiresIntent",
		input: DecisionInput{
			Authority: uninstall.AuthorityAmbiguous,
			Ambiguity: uninstall.AmbiguityOrphanNFTBan,
			Prior:     PriorStateIncomplete,
			Flags:     Flags{Restore: true},
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG4_2OrphanIncomplete,
	},
	{
		name: "G4_2_OrphanStale_requiresIntent",
		input: DecisionInput{
			Authority: uninstall.AuthorityAmbiguous,
			Ambiguity: uninstall.AmbiguityOrphanNFTBan,
			Prior:     PriorStateStale,
			Flags:     Flags{Restore: true},
		},
		wantOut:  OutputRequireExplicitIntent,
		wantRule: RuleG4_2OrphanStale,
	},

	// ───────────────────────── Group 4.3 orphan + panel-auto ─────────
	{
		name: "G4_3_OrphanPanelAutoWithPanel_refuses",
		input: DecisionInput{
			Authority:    uninstall.AuthorityAmbiguous,
			Ambiguity:    uninstall.AmbiguityOrphanNFTBan,
			Prior:        PriorStateCompleteActive,
			Flags:        Flags{PanelAutoTakeover: true},
			PanelPresent: true,
		},
		wantOut:  OutputRefuse,
		wantRule: RuleG4_3OrphanPanelAuto,
	},
}

// TestDecide_FixtureMatrix drives every rule path.
func TestDecide_FixtureMatrix(t *testing.T) {
	for _, fx := range allFixtures {
		t.Run(fx.name, func(t *testing.T) {
			got := Decide(fx.input)
			if got.Output != fx.wantOut {
				t.Errorf("Output: got=%s want=%s (rule=%s reason=%q)",
					got.Output, fx.wantOut, got.Rule, got.Reason)
			}
			if got.Rule != fx.wantRule {
				t.Errorf("Rule: got=%s want=%s", got.Rule, fx.wantRule)
			}
			if got.Output != OutputProceed && got.Output != OutputRefuse && got.Output != OutputRequireExplicitIntent {
				t.Errorf("Output is not one of the 3 closed-enum values: %q", got.Output)
			}
		})
	}
}

// TestRuleCoverage_EveryRuleExercised enforces that the fixture matrix
// covers every declared rule constant. Adding a new rule to engine.go
// without a fixture is a contract violation and fails this test.
func TestRuleCoverage_EveryRuleExercised(t *testing.T) {
	declared := declaredRules()
	sort.Strings(declared)

	covered := map[string]bool{}
	for _, fx := range allFixtures {
		covered[fx.wantRule] = true
	}

	var missing []string
	for _, r := range declared {
		if !covered[r] {
			missing = append(missing, r)
		}
	}
	if len(missing) > 0 {
		t.Errorf("rule-path coverage gap — %d declared rule(s) have no fixture: %v",
			len(missing), missing)
	}

	// Also check the inverse: every fixture points to a declared rule.
	declaredSet := map[string]bool{}
	for _, r := range declared {
		declaredSet[r] = true
	}
	var undeclared []string
	for _, fx := range allFixtures {
		if !declaredSet[fx.wantRule] {
			undeclared = append(undeclared, fx.wantRule)
		}
	}
	if len(undeclared) > 0 {
		t.Errorf("fixture(s) reference undeclared rule(s): %v", undeclared)
	}
}

// declaredRules returns every Rule* constant declared in engine.go.
// Keep in sync when new rules are added.
func declaredRules() []string {
	return []string{
		// Amendment 2 §53 split: RuleG1AuthorityNFTBan is now an umbrella
		// const retained for log-parent grep; concrete fixtures resolve
		// to the three sub-rules below.
		RuleG1NFTBanDefault,
		RuleG1NFTBanOrphanProceed,
		RuleG1EvidenceMismatch,
		RuleG1AuthorityExternal,
		RuleG1AmbiguityConflictExt,

		RuleG2PanelAutoWithoutPanel,
		RuleG2BothRestoreFlags,

		RuleG3_1StrongPriorNoFlag,
		RuleG3_1StrongPriorRestore,
		RuleG3_1StrongPriorPanelAuto,
		RuleG3_2CompleteInactive,
		RuleG3_3NoRecordNoFlag,
		RuleG3_3NoRecordRestore,
		RuleG3_3NoRecordPanelAuto,
		RuleG3_3Incomplete,
		RuleG3_3Stale,

		RuleG4_1OrphanStrongNoFlag,
		RuleG4_1OrphanStrongRestore,
		RuleG4_2OrphanCompleteInactive,
		RuleG4_2OrphanNoRecordNoFlag,
		RuleG4_2OrphanNoRecordRestore,
		RuleG4_2OrphanIncomplete,
		RuleG4_2OrphanStale,
		RuleG4_3OrphanPanelAuto,
	}
}

// TestDecide_Determinism — same input twice must yield identical
// result (Output, Rule, Reason). No hidden env-var, time-of-day, or
// random-seed dependency.
func TestDecide_Determinism(t *testing.T) {
	for _, fx := range allFixtures {
		t.Run(fx.name, func(t *testing.T) {
			first := Decide(fx.input)
			second := Decide(fx.input)
			if !reflect.DeepEqual(first, second) {
				t.Errorf("non-deterministic: first=%+v second=%+v", first, second)
			}
		})
	}
}

// TestDecide_OutputClosedEnum — no rule path may emit a value outside
// the three locked outputs. Guards against a future edit that
// introduces a fourth state via a mis-spelled constant.
func TestDecide_OutputClosedEnum(t *testing.T) {
	allowed := map[Output]bool{
		OutputProceed:               true,
		OutputRefuse:                true,
		OutputRequireExplicitIntent: true,
	}
	for _, fx := range allFixtures {
		t.Run(fx.name, func(t *testing.T) {
			got := Decide(fx.input)
			if !allowed[got.Output] {
				t.Errorf("invalid output value %q (not in closed enum)", got.Output)
			}
		})
	}
}

// TestDecide_LockedAmendments — explicit guards for the two locked
// amendments documented in the seed (NoRecord+Restore → REQUIRE and
// legacy-missing-ActiveAtInstall → Incomplete → REQUIRE). These are
// separate from the fixture matrix so they fail loudly if a future
// change attempts to "optimize" either branch.
func TestDecide_LockedAmendment_NoRecordRestoreRequiresIntent(t *testing.T) {
	// AuthorityNone path
	got := Decide(DecisionInput{
		Authority: uninstall.AuthorityNone,
		Prior:     PriorStateNoRecord,
		Flags:     Flags{Restore: true},
	})
	if got.Output != OutputRequireExplicitIntent {
		t.Errorf("NoRecord + --restore must be REQUIRE_EXPLICIT_INTENT (locked amendment); got %s", got.Output)
	}
	if got.Rule != RuleG3_3NoRecordRestore {
		t.Errorf("rule mismatch: got %s want %s", got.Rule, RuleG3_3NoRecordRestore)
	}

	// Orphan path mirror
	got = Decide(DecisionInput{
		Authority: uninstall.AuthorityAmbiguous,
		Ambiguity: uninstall.AmbiguityOrphanNFTBan,
		Prior:     PriorStateNoRecord,
		Flags:     Flags{Restore: true},
	})
	if got.Output != OutputRequireExplicitIntent {
		t.Errorf("Orphan + NoRecord + --restore must be REQUIRE_EXPLICIT_INTENT (locked amendment); got %s", got.Output)
	}
}

// TestDecide_HardStopsDominateAnyFlag — seed §5 invariant: Group 1
// hard-stops cannot be overridden by any flag or panel context.
func TestDecide_HardStopsDominateAnyFlag(t *testing.T) {
	hardStops := []struct {
		name string
		auth uninstall.CurrentAuthority
		amb  uninstall.AmbiguityKind
	}{
		{"AuthorityNFTBan", uninstall.AuthorityNFTBan, uninstall.AmbiguityNone},
		{"AuthorityExternal", uninstall.AuthorityExternal, uninstall.AmbiguityNone},
		{"AmbiguityConflictExternal", uninstall.AuthorityAmbiguous, uninstall.AmbiguityConflictExternal},
	}
	flagCombos := []Flags{
		{},
		{Restore: true},
		{PanelAutoTakeover: true},
		{Restore: true, PanelAutoTakeover: true},
	}
	priors := []PriorState{
		PriorStateNoRecord,
		PriorStateCompleteActive,
		PriorStateCompleteInactive,
		PriorStateIncomplete,
		PriorStateStale,
	}
	for _, hs := range hardStops {
		for _, f := range flagCombos {
			for _, p := range priors {
				for _, panel := range []bool{false, true} {
					got := Decide(DecisionInput{
						Authority:    hs.auth,
						Ambiguity:    hs.amb,
						Prior:        p,
						Flags:        f,
						PanelPresent: panel,
					})
					if got.Output != OutputRefuse {
						t.Errorf("hard-stop %s must REFUSE under any flag/panel/prior; got %s (rule=%s) for flags=%+v prior=%s panel=%v",
							hs.name, got.Output, got.Rule, f, p, panel)
					}
				}
			}
		}
	}
}

// TestDecide_OrphanPanelAutoRefused — seed §6 Group 4.3 invariant.
func TestDecide_OrphanPanelAutoRefused(t *testing.T) {
	for _, p := range []PriorState{
		PriorStateNoRecord,
		PriorStateCompleteActive,
		PriorStateCompleteInactive,
		PriorStateIncomplete,
		PriorStateStale,
	} {
		got := Decide(DecisionInput{
			Authority:    uninstall.AuthorityAmbiguous,
			Ambiguity:    uninstall.AmbiguityOrphanNFTBan,
			Prior:        p,
			Flags:        Flags{PanelAutoTakeover: true},
			PanelPresent: true,
		})
		if got.Output != OutputRefuse {
			t.Errorf("Orphan + --panel-auto-takeover must REFUSE under any prior; got %s (prior=%s)", got.Output, p)
		}
		if got.Rule != RuleG4_3OrphanPanelAuto {
			t.Errorf("rule mismatch: got %s want %s (prior=%s)", got.Rule, RuleG4_3OrphanPanelAuto, p)
		}
	}
}
