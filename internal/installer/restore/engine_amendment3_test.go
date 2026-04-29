// =============================================================================
// NFTBan v1.100 Amendment 3 — Engine fixture matrix (§67 — 15 rows)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-restore-engine-amendment3-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-29"
// meta:description="Amendment 3 §67 15-row matrix for G1/AmbiguityConflictExternal split"
// meta:inventory.files="internal/installer/restore/engine_amendment3_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Amendment 3 (contract.md §§62–69) defines the G1/AmbiguityConflictExternal
// split mirroring Amendment 2's G1/AuthorityNFTBan split. This file
// implements the 15-row matrix at §67 directly against `restore.Decide`.
//
// Discipline:
//   - Decision-layer only. No execute path. No state-machine changes.
//   - No classifier semantic change.
//   - No new mutation surface.
//   - Amendment 2 §54 predicate untouched (regression-checked via
//     AMD3-12 row + the existing engine_amendment2_test.go suite).
//   - Reuses OrphanEvidence struct via AllTrueAmendment3() /
//     FailedRowIDAmendment3() helpers (E.12 omitted per §64.1).
//
// =============================================================================
package restore

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// allEvidenceTrueAmendment3 returns an OrphanEvidence struct configured
// for the §62 entry condition: E.2's row-bool is reframed semantically
// (AuthorityAmbiguous + AmbiguityConflictExternal + ExternalIndicator=="csf"
// rather than AuthorityNFTBan), but the row is true because the host is
// a candidate. E.12 is false (the §62 entry IS AmbiguityConflictExternal,
// so E.12 cannot be true on this path) — but AllTrueAmendment3() omits
// it from the predicate, so the predicate is satisfied.
func allEvidenceTrueAmendment3() *OrphanEvidence {
	return &OrphanEvidence{
		E1PanelDirectAdmin:    true,
		E2AuthorityNFTBan:     true,  // semantically reframed per §64.1; dispatcher sets true on §62 entry
		E3PriorNoRecord:       true,
		E4PanelAutoTakeover:   true,
		E5AcceptOrphanNFTBan:  true,
		E6CSFServiceDisabled:  true,
		E7CSFDisabledExists:   true,
		E8CSFAbsent:           true,
		E9NftIPNftbanPresent:  true,
		E10NftIP6NftbanPres:   true,
		E11NftbandActive:      true,
		E12NoConflictExternal: false, // OMITTED from AllTrueAmendment3
		E13NoAmbiguous:        true,
	}
}

// TestAmd3_Section67_FifteenRows exercises every row of contract §67
// against the engine. This is the load-bearing matrix for Amendment 3.
func TestAmd3_Section67_FifteenRows(t *testing.T) {
	cases := []struct {
		name        string
		input       DecisionInput
		wantOut     Output
		wantRule    string
		reasonFrag  string // optional: substring expected in result.Reason
	}{
		// AMD3-1 — full candidate quintuple + all §64 rows true → PROCEED
		{
			name: "AMD3-1_proceed_all_true",
			input: DecisionInput{
				Authority:         uninstall.AuthorityAmbiguous,
				Ambiguity:         uninstall.AmbiguityConflictExternal,
				ExternalIndicator: "csf",
				Prior:             PriorStateNoRecord,
				Panel:             detect.PanelDirectAdmin,
				PanelPresent:      true,
				Flags:             Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence:    allEvidenceTrueAmendment3(),
			},
			wantOut:    OutputProceed,
			wantRule:   RuleG1AmbConflictExtOrphanProceed,
			reasonFrag: "amendment-3 orphan-intent",
		},
		// AMD3-2 — quintuple present, E.7 false → EvidenceMismatch
		{
			name: "AMD3-2_E7_false_evidence_mismatch",
			input: DecisionInput{
				Authority:         uninstall.AuthorityAmbiguous,
				Ambiguity:         uninstall.AmbiguityConflictExternal,
				ExternalIndicator: "csf",
				Prior:             PriorStateNoRecord,
				Panel:             detect.PanelDirectAdmin,
				PanelPresent:      true,
				Flags:             Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence: func() *OrphanEvidence {
					e := allEvidenceTrueAmendment3()
					e.E7CSFDisabledExists = false
					return e
				}(),
			},
			wantOut:    OutputRefuse,
			wantRule:   RuleG1AmbConflictExtEvidenceMismatch,
			reasonFrag: "AMD3-E.7",
		},
		// AMD3-3 — missing --accept-orphan-nftban → default REFUSE
		{
			name: "AMD3-3_missing_accept_orphan_default_refuse",
			input: DecisionInput{
				Authority:         uninstall.AuthorityAmbiguous,
				Ambiguity:         uninstall.AmbiguityConflictExternal,
				ExternalIndicator: "csf",
				Prior:             PriorStateNoRecord,
				Panel:             detect.PanelDirectAdmin,
				PanelPresent:      true,
				Flags:             Flags{PanelAutoTakeover: true},
				OrphanEvidence:    allEvidenceTrueAmendment3(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1AmbConflictExtDefault,
		},
		// AMD3-4 — missing --panel-auto-takeover → default REFUSE
		{
			name: "AMD3-4_missing_panel_auto_default_refuse",
			input: DecisionInput{
				Authority:         uninstall.AuthorityAmbiguous,
				Ambiguity:         uninstall.AmbiguityConflictExternal,
				ExternalIndicator: "csf",
				Prior:             PriorStateNoRecord,
				Panel:             detect.PanelDirectAdmin,
				PanelPresent:      true,
				Flags:             Flags{AcceptOrphanNFTBan: true},
				OrphanEvidence:    allEvidenceTrueAmendment3(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1AmbConflictExtDefault,
		},
		// AMD3-5 — Panel=cpanel → default REFUSE
		{
			name: "AMD3-5_cpanel_default_refuse",
			input: DecisionInput{
				Authority:         uninstall.AuthorityAmbiguous,
				Ambiguity:         uninstall.AmbiguityConflictExternal,
				ExternalIndicator: "csf",
				Prior:             PriorStateNoRecord,
				Panel:             detect.PanelCPanel,
				PanelPresent:      true,
				Flags:             Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence:    allEvidenceTrueAmendment3(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1AmbConflictExtDefault,
		},
		// AMD3-6 — no panel → Group 2 PanelAutoWithoutPanel REFUSE wins
		// (Group 2 precedence over Amendment 3 candidate-quintuple check).
		{
			name: "AMD3-6_no_panel_g2_refuse",
			input: DecisionInput{
				Authority:         uninstall.AuthorityAmbiguous,
				Ambiguity:         uninstall.AmbiguityConflictExternal,
				ExternalIndicator: "csf",
				Prior:             PriorStateNoRecord,
				Panel:             detect.PanelNone,
				PanelPresent:      false,
				Flags:             Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence:    allEvidenceTrueAmendment3(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG2PanelAutoWithoutPanel,
		},
		// AMD3-7 — ExternalIndicator=ufw → default REFUSE
		{
			name: "AMD3-7_external_ufw_default_refuse",
			input: DecisionInput{
				Authority:         uninstall.AuthorityAmbiguous,
				Ambiguity:         uninstall.AmbiguityConflictExternal,
				ExternalIndicator: "ufw",
				Prior:             PriorStateNoRecord,
				Panel:             detect.PanelDirectAdmin,
				PanelPresent:      true,
				Flags:             Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence:    allEvidenceTrueAmendment3(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1AmbConflictExtDefault,
		},
		// AMD3-8 — Prior=StrongPrior (CompleteActive) → default REFUSE
		{
			name: "AMD3-8_strong_prior_default_refuse",
			input: DecisionInput{
				Authority:         uninstall.AuthorityAmbiguous,
				Ambiguity:         uninstall.AmbiguityConflictExternal,
				ExternalIndicator: "csf",
				Prior:             PriorStateCompleteActive,
				Panel:             detect.PanelDirectAdmin,
				PanelPresent:      true,
				Flags:             Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence:    allEvidenceTrueAmendment3(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1AmbConflictExtDefault,
		},
		// AMD3-9 — quintuple present, E.6 false → EvidenceMismatch
		{
			name: "AMD3-9_E6_false_evidence_mismatch",
			input: DecisionInput{
				Authority:         uninstall.AuthorityAmbiguous,
				Ambiguity:         uninstall.AmbiguityConflictExternal,
				ExternalIndicator: "csf",
				Prior:             PriorStateNoRecord,
				Panel:             detect.PanelDirectAdmin,
				PanelPresent:      true,
				Flags:             Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence: func() *OrphanEvidence {
					e := allEvidenceTrueAmendment3()
					e.E6CSFServiceDisabled = false
					return e
				}(),
			},
			wantOut:    OutputRefuse,
			wantRule:   RuleG1AmbConflictExtEvidenceMismatch,
			reasonFrag: "AMD3-E.6",
		},
		// AMD3-10 — Ambiguity=OrphanNFTBan → routed to Group 4
		// (Amendment 3 does NOT touch the OrphanNFTBan path). The
		// candidate quintuple flags here trigger G4.3 OrphanPanelAuto.
		{
			name: "AMD3-10_orphan_nftban_g4_locked",
			input: DecisionInput{
				Authority:         uninstall.AuthorityAmbiguous,
				Ambiguity:         uninstall.AmbiguityOrphanNFTBan,
				ExternalIndicator: "csf",
				Prior:             PriorStateNoRecord,
				Panel:             detect.PanelDirectAdmin,
				PanelPresent:      true,
				Flags:             Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence:    allEvidenceTrueAmendment3(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG4_3OrphanPanelAuto,
		},
		// AMD3-11 — Authority=External → G1/AuthorityExternal locked REFUSE.
		{
			name: "AMD3-11_authority_external_locked",
			input: DecisionInput{
				Authority:         uninstall.AuthorityExternal,
				ExternalIndicator: "csf",
				Prior:             PriorStateNoRecord,
				Panel:             detect.PanelDirectAdmin,
				PanelPresent:      true,
				Flags:             Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence:    allEvidenceTrueAmendment3(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1AuthorityExternal,
		},
		// AMD3-12 — Authority=NFTBan + all §54 true (Amendment 2 path)
		// → still PROCEEDs unchanged (regression check).
		{
			name: "AMD3-12_amendment_2_regression",
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
					E12NoConflictExternal: true, // Amendment 2 path requires this true
					E13NoAmbiguous:        true,
				},
			},
			wantOut:  OutputProceed,
			wantRule: RuleG1NFTBanOrphanProceed,
		},
		// AMD3-13 — ExternalIndicator empty → default REFUSE (defensive guard).
		// classifier-malformed-output edge case: classifier says
		// AmbiguityConflictExternal but emits empty external string.
		{
			name: "AMD3-13_external_empty_defensive_refuse",
			input: DecisionInput{
				Authority:         uninstall.AuthorityAmbiguous,
				Ambiguity:         uninstall.AmbiguityConflictExternal,
				ExternalIndicator: "",
				Prior:             PriorStateNoRecord,
				Panel:             detect.PanelDirectAdmin,
				PanelPresent:      true,
				Flags:             Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence:    allEvidenceTrueAmendment3(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1AmbConflictExtDefault,
		},
		// AMD3-14 — rule-label assertion: full PROCEED path with explicit
		// downstream-consumer assertions. Pins rule string + Reason
		// substring for Code-D evidence-record consumers and post-B
		// auditor grep.
		{
			name: "AMD3-14_proceed_rule_label_assertion",
			input: DecisionInput{
				Authority:         uninstall.AuthorityAmbiguous,
				Ambiguity:         uninstall.AmbiguityConflictExternal,
				ExternalIndicator: "csf",
				Prior:             PriorStateNoRecord,
				Panel:             detect.PanelDirectAdmin,
				PanelPresent:      true,
				Flags:             Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence:    allEvidenceTrueAmendment3(),
			},
			wantOut:    OutputProceed,
			wantRule:   "G1/AmbiguityConflictExternal/OrphanProceed",
			reasonFrag: "amendment-3 orphan-intent",
		},
		// AMD3-15 — multi-external "csf,ufw" → default REFUSE
		// (defensive guard against future classifier behavior).
		{
			name: "AMD3-15_multi_external_defensive_refuse",
			input: DecisionInput{
				Authority:         uninstall.AuthorityAmbiguous,
				Ambiguity:         uninstall.AmbiguityConflictExternal,
				ExternalIndicator: "csf,ufw",
				Prior:             PriorStateNoRecord,
				Panel:             detect.PanelDirectAdmin,
				PanelPresent:      true,
				Flags:             Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence:    allEvidenceTrueAmendment3(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1AmbConflictExtDefault,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := Decide(c.input)
			if got.Output != c.wantOut {
				t.Errorf("Output = %q; want %q", got.Output, c.wantOut)
			}
			if got.Rule != c.wantRule {
				t.Errorf("Rule = %q; want %q", got.Rule, c.wantRule)
			}
			if c.reasonFrag != "" && !strings.Contains(got.Reason, c.reasonFrag) {
				t.Errorf("Reason = %q; want substring %q", got.Reason, c.reasonFrag)
			}
		})
	}
}

// TestAmd3_RuleConstants pins the canonical rule strings so any rename
// in engine.go that drifts from the contract triggers a test failure.
func TestAmd3_RuleConstants(t *testing.T) {
	cases := []struct {
		name string
		got  string
		want string
	}{
		{"default", RuleG1AmbConflictExtDefault, "G1/AmbiguityConflictExternal/default"},
		{"orphan_proceed", RuleG1AmbConflictExtOrphanProceed, "G1/AmbiguityConflictExternal/OrphanProceed"},
		{"evidence_mismatch", RuleG1AmbConflictExtEvidenceMismatch, "G1/AmbiguityConflictExternal/EvidenceMismatch"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if c.got != c.want {
				t.Errorf("rule constant = %q; want %q", c.got, c.want)
			}
		})
	}
}

// TestAmd3_AllTrueAmendment3_OmitsE12 verifies that the Amendment 3
// predicate omits row E.12 (NoConflictExternal). Required because the
// §62 entry condition IS AmbiguityConflictExternal.
func TestAmd3_AllTrueAmendment3_OmitsE12(t *testing.T) {
	e := allEvidenceTrueAmendment3()
	if e.E12NoConflictExternal {
		t.Fatalf("test fixture invariant broken: allEvidenceTrueAmendment3 must set E.12 false to model the §62 entry condition")
	}
	if !e.AllTrueAmendment3() {
		t.Errorf("AllTrueAmendment3() = false; want true (E.12 must be omitted from the predicate)")
	}
	// Sanity: the Amendment 2 AllTrue() requires E.12 true and so
	// must return false on this fixture.
	if e.AllTrue() {
		t.Errorf("AllTrue() = true; want false (Amendment 2 predicate requires E.12 true)")
	}
}

// TestAmd3_FailedRowIDAmendment3_SkipsE12 verifies that
// FailedRowIDAmendment3 walks the same row order as Amendment 2's
// FailedRowID except it skips E.12 (which is omitted from the
// predicate).
func TestAmd3_FailedRowIDAmendment3_SkipsE12(t *testing.T) {
	cases := []struct {
		name     string
		mutate   func(*OrphanEvidence)
		wantID   string
	}{
		{"E1_false", func(e *OrphanEvidence) { e.E1PanelDirectAdmin = false }, "AMD3-E.1"},
		{"E6_false", func(e *OrphanEvidence) { e.E6CSFServiceDisabled = false }, "AMD3-E.6"},
		{"E7_false", func(e *OrphanEvidence) { e.E7CSFDisabledExists = false }, "AMD3-E.7"},
		{"E11_false", func(e *OrphanEvidence) { e.E11NftbandActive = false }, "AMD3-E.11"},
		{"E13_false", func(e *OrphanEvidence) { e.E13NoAmbiguous = false }, "AMD3-E.13"},
		// Note: E.12 false is the entry-condition norm for Amendment 3;
		// it must NOT trigger a FailedRowID return.
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			e := allEvidenceTrueAmendment3()
			c.mutate(e)
			got := e.FailedRowIDAmendment3()
			if got != c.wantID {
				t.Errorf("FailedRowIDAmendment3() = %q; want %q", got, c.wantID)
			}
		})
	}
}

// TestAmd3_NilEvidence_AMD3E0 verifies that a nil OrphanEvidence
// pointer reports the AMD3-E.0 sentinel (distinct from Amendment 2's
// AMD2-E.0) so structured logs and Code-D evidence-records can
// attribute correctly which predicate fired.
func TestAmd3_NilEvidence_AMD3E0(t *testing.T) {
	var e *OrphanEvidence
	if e.AllTrueAmendment3() {
		t.Errorf("nil.AllTrueAmendment3() = true; want false")
	}
	if got := e.FailedRowIDAmendment3(); got != "AMD3-E.0" {
		t.Errorf("nil.FailedRowIDAmendment3() = %q; want %q", got, "AMD3-E.0")
	}
}
