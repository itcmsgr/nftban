// =============================================================================
// NFTBan v1.100 Amendment 2 — Engine fixture matrix (§§56.1 + 56.2 + 56.4)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-restore-engine-amendment2-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-28"
// meta:description="Amendment 2 §56.1 + §56.2 + §56.4 coverage for the G1 split"
// meta:inventory.files="internal/installer/restore/engine_amendment2_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Amendment 2 (contract.md §§52–61) defines the G1/AuthorityNFTBan
// split. This file exercises every row of §56.1 (unit tests) + §56.2
// (regression) + §56.4 (mutation-surface invariant) directly against
// `restore.Decide`. The dispatcher integration test for §56.5 lives in
// cmd/nftban-installer/restore_decide_amendment2_test.go.
//
// =============================================================================
package restore

import (
	"go/ast"
	"go/parser"
	"go/token"
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// allEvidenceTrue returns an OrphanEvidence struct with every §54.1
// row set true, simulating a real host that satisfies the candidate
// triple precondition.
func allEvidenceTrue() *OrphanEvidence {
	return &OrphanEvidence{
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
	}
}

// TestAmd2_Section56_1_SplitFixtures exercises every row of contract
// §56.1 against the engine.
func TestAmd2_Section56_1_SplitFixtures(t *testing.T) {
	cases := []struct {
		name     string
		input    DecisionInput
		wantOut  Output
		wantRule string
	}{
		// Row 1 — AuthorityNFTBan + NoRecord + no flags → G1/default
		{
			name: "row01_no_flags",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{},
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1NFTBanDefault,
		},
		// Row 2 — only --panel-auto-takeover → G1/default
		{
			name: "row02_panel_auto_only",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true},
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1NFTBanDefault,
		},
		// Row 3 — only --accept-orphan-nftban → G1/default
		{
			name: "row03_orphan_only",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{AcceptOrphanNFTBan: true},
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1NFTBanDefault,
		},
		// Row 4 — both flags + Panel=None → G2/PanelAutoNoPanel (existing rule wins)
		{
			name: "row04_panel_none",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelNone,
				PanelPresent: false,
				Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG2PanelAutoWithoutPanel,
		},
		// Row 5 — Panel=cPanel → G1/default (candidate triple absent)
		{
			name: "row05_panel_cpanel",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelCPanel,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1NFTBanDefault,
		},
		// Row 6 — DirectAdmin + csf.service ABSENT (E.6 false) → G1/EvidenceMismatch
		{
			name: "row06_csf_absent",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence: func() *OrphanEvidence {
					ev := allEvidenceTrue()
					ev.E6CSFServiceDisabled = false
					return ev
				}(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1EvidenceMismatch,
		},
		// Row 7 — csf.service ACTIVE → G1/EvidenceMismatch (E.6 false; E.6 row collapses csf-active into the disabled-or-masked check)
		{
			name: "row07_csf_active",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence: func() *OrphanEvidence {
					ev := allEvidenceTrue()
					ev.E6CSFServiceDisabled = false // active
					return ev
				}(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1EvidenceMismatch,
		},
		// Row 7d — csf inactive + disabled (acceptable fallback) → PROCEED
		{
			name: "row07d_csf_disabled_inactive_proceed",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				// E.6 true semantically covers both masked+inactive and disabled+inactive
				// per AMD2-E.6; the engine just sees the boolean true.
				OrphanEvidence: allEvidenceTrue(),
			},
			wantOut:  OutputProceed,
			wantRule: RuleG1NFTBanOrphanProceed,
		},
		// Row 8 — /usr/sbin/csf.disabled ABSENT (E.7 false)
		{
			name: "row08_csf_disabled_absent",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence: func() *OrphanEvidence {
					ev := allEvidenceTrue()
					ev.E7CSFDisabledExists = false
					return ev
				}(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1EvidenceMismatch,
		},
		// Row 9 — /usr/sbin/csf PRESENT (E.8 false; ambiguous-both-present)
		{
			name: "row09_csf_present_ambiguous",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence: func() *OrphanEvidence {
					ev := allEvidenceTrue()
					ev.E8CSFAbsent = false
					return ev
				}(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1EvidenceMismatch,
		},
		// Row 10 — ip:nftban ABSENT (E.9 false)
		{
			name: "row10_ip_nftban_absent",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence: func() *OrphanEvidence {
					ev := allEvidenceTrue()
					ev.E9NftIPNftbanPresent = false
					return ev
				}(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1EvidenceMismatch,
		},
		// Row 11 — nftband.service INACTIVE (E.11 false)
		{
			name: "row11_nftband_inactive",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence: func() *OrphanEvidence {
					ev := allEvidenceTrue()
					ev.E11NftbandActive = false
					return ev
				}(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1EvidenceMismatch,
		},
		// Row 12 — ALL §54.1 rows true → PROCEED (strongest variant)
		{
			name: "row12_all_evidence_true_proceed",
			input: DecisionInput{
				Authority:      uninstall.AuthorityNFTBan,
				Prior:          PriorStateNoRecord,
				Panel:          detect.PanelDirectAdmin,
				PanelPresent:   true,
				Flags:          Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence: allEvidenceTrue(),
			},
			wantOut:  OutputProceed,
			wantRule: RuleG1NFTBanOrphanProceed,
		},
		// Row 13 — Prior=Complete → G1/default (candidate triple absent)
		{
			name: "row13_prior_complete",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateCompleteActive,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1NFTBanDefault,
		},
		// Row 14 — Prior=Incomplete → G1/default
		{
			name: "row14_prior_incomplete",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateIncomplete,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1NFTBanDefault,
		},
		// Row 15 — Prior=Stale → G1/default
		{
			name: "row15_prior_stale",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateStale,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1NFTBanDefault,
		},
		// Row 16 — AuthorityExternal + orphan flag + everything-else true → REFUSE/G1/AuthorityExternal (no bypass)
		{
			name: "row16_authority_external_no_bypass",
			input: DecisionInput{
				Authority:      uninstall.AuthorityExternal,
				Prior:          PriorStateNoRecord,
				Panel:          detect.PanelDirectAdmin,
				PanelPresent:   true,
				Flags:          Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
				OrphanEvidence: allEvidenceTrue(),
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1AuthorityExternal,
		},
		// Row 17 — AmbiguityConflictExternal + orphan flag → REFUSE/G1/AmbiguityConflictExternal (no bypass)
		{
			name: "row17_ambiguity_conflict_no_bypass",
			input: DecisionInput{
				Authority:    uninstall.AuthorityAmbiguous,
				Ambiguity:    uninstall.AmbiguityConflictExternal,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1AmbiguityConflictExt,
		},
		// Row 18 — AmbiguityOrphanNFTBan + panel-auto + orphan-flag → REFUSE/G4.3 (locked by §59 Q2)
		{
			name: "row18_ambiguity_orphan_panelauto_locked_refuse",
			input: DecisionInput{
				Authority:    uninstall.AuthorityAmbiguous,
				Ambiguity:    uninstall.AmbiguityOrphanNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG4_3OrphanPanelAuto,
		},
		// Row 19 — both --panel-auto-takeover AND --restore-prior-authority + orphan-flag → REFUSE/G2/BothFlags
		{
			name: "row19_both_flags_set",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{Restore: true, PanelAutoTakeover: true, AcceptOrphanNFTBan: true},
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG2BothRestoreFlags,
		},
		// Row 20 — orphan-flag absent (env-var-only would simulate this);
		// engine sees Flags.AcceptOrphanNFTBan=false → G1/default. The
		// CLI argv-only constraint is enforced at flag-parse layer; the
		// engine's contract is that Flags is the truth.
		{
			name: "row20_no_env_var_fallback_simulation",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				// AcceptOrphanNFTBan deliberately false even though
				// PanelAutoTakeover is true and other conditions hold —
				// simulates the env-var-only path correctly producing
				// AcceptOrphanNFTBan=false.
				Flags: Flags{PanelAutoTakeover: true, AcceptOrphanNFTBan: false},
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1NFTBanDefault,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Decide(tc.input)
			if got.Output != tc.wantOut {
				t.Errorf("Output: got=%s want=%s (rule=%s reason=%q)",
					got.Output, tc.wantOut, got.Rule, got.Reason)
			}
			if got.Rule != tc.wantRule {
				t.Errorf("Rule: got=%s want=%s", got.Rule, tc.wantRule)
			}
		})
	}
}

// TestAmd2_Section56_2_RegressionsPreserved confirms that pre-Amendment-2
// rules continue to fire identically. R1–R6 from contract §56.2.
func TestAmd2_Section56_2_RegressionsPreserved(t *testing.T) {
	cases := []struct {
		name     string
		input    DecisionInput
		wantOut  Output
		wantRule string
	}{
		// R1: AuthorityNone + NoRecord + --panel-auto-takeover + DirectAdmin → G3.3 PROCEED
		{
			name: "R1_AuthorityNone_NoRecord_PanelAuto_DirectAdmin",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNone,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true},
			},
			wantOut:  OutputProceed,
			wantRule: RuleG3_3NoRecordPanelAuto,
		},
		// R2: AuthorityNone + strong prior + --restore → G3.1 PROCEED
		{
			name: "R2_AuthorityNone_StrongPrior_Restore",
			input: DecisionInput{
				Authority:    uninstall.AuthorityNone,
				Prior:        PriorStateCompleteActive,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{Restore: true},
			},
			wantOut:  OutputProceed,
			wantRule: RuleG3_1StrongPriorRestore,
		},
		// R3: AuthorityNone + NoRecord + --restore → G3.3 REQUIRE_EXPLICIT_INTENT
		{
			name: "R3_AuthorityNone_NoRecord_Restore_RequireIntent",
			input: DecisionInput{
				Authority: uninstall.AuthorityNone,
				Prior:     PriorStateNoRecord,
				Flags:     Flags{Restore: true},
			},
			wantOut:  OutputRequireExplicitIntent,
			wantRule: RuleG3_3NoRecordRestore,
		},
		// R4: AmbiguityOrphanNFTBan + strong prior + --restore → G4.1 PROCEED
		{
			name: "R4_AmbiguityOrphan_StrongPrior_Restore",
			input: DecisionInput{
				Authority:    uninstall.AuthorityAmbiguous,
				Ambiguity:    uninstall.AmbiguityOrphanNFTBan,
				Prior:        PriorStateCompleteActive,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{Restore: true},
			},
			wantOut:  OutputProceed,
			wantRule: RuleG4_1OrphanStrongRestore,
		},
		// R5: AmbiguityOrphanNFTBan + --panel-auto-takeover → G4.3 REFUSE
		{
			name: "R5_AmbiguityOrphan_PanelAuto_Refuse",
			input: DecisionInput{
				Authority:    uninstall.AuthorityAmbiguous,
				Ambiguity:    uninstall.AmbiguityOrphanNFTBan,
				Prior:        PriorStateNoRecord,
				Panel:        detect.PanelDirectAdmin,
				PanelPresent: true,
				Flags:        Flags{PanelAutoTakeover: true},
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG4_3OrphanPanelAuto,
		},
		// R6: AuthorityNFTBan + no orphan-flag → G1/default REFUSE (umbrella behavior preserved)
		{
			name: "R6_AuthorityNFTBan_NoOrphanFlag_Default",
			input: DecisionInput{
				Authority: uninstall.AuthorityNFTBan,
				Prior:     PriorStateNoRecord,
				Flags:     Flags{},
			},
			wantOut:  OutputRefuse,
			wantRule: RuleG1NFTBanDefault,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := Decide(tc.input)
			if got.Output != tc.wantOut {
				t.Errorf("Output: got=%s want=%s (rule=%s reason=%q)",
					got.Output, tc.wantOut, got.Rule, got.Reason)
			}
			if got.Rule != tc.wantRule {
				t.Errorf("Rule: got=%s want=%s", got.Rule, tc.wantRule)
			}
		})
	}
}

// TestAmd2_OrphanEvidence_FailedRowID confirms FailedRowID() returns the
// stable per-row ID for the first failing row, used by structured logs.
func TestAmd2_OrphanEvidence_FailedRowID(t *testing.T) {
	tests := []struct {
		name string
		mut  func(*OrphanEvidence)
		want string
	}{
		{"all_true_returns_empty", func(e *OrphanEvidence) {}, ""},
		{"e1_first_failing", func(e *OrphanEvidence) { e.E1PanelDirectAdmin = false }, "AMD2-E.1"},
		{"e6_first_failing", func(e *OrphanEvidence) { e.E6CSFServiceDisabled = false }, "AMD2-E.6"},
		{"e8_first_failing", func(e *OrphanEvidence) { e.E8CSFAbsent = false }, "AMD2-E.8"},
		{"e13_first_failing", func(e *OrphanEvidence) { e.E13NoAmbiguous = false }, "AMD2-E.13"},
	}
	for _, tc := range tests {
		t.Run(tc.name, func(t *testing.T) {
			ev := allEvidenceTrue()
			tc.mut(ev)
			got := ev.FailedRowID()
			if got != tc.want {
				t.Errorf("FailedRowID = %q, want %q", got, tc.want)
			}
		})
	}
	t.Run("nil_receiver", func(t *testing.T) {
		var ev *OrphanEvidence
		if got := ev.FailedRowID(); got != "AMD2-E.0" {
			t.Errorf("nil receiver FailedRowID = %q, want AMD2-E.0", got)
		}
		if ev.AllTrue() {
			t.Errorf("nil receiver AllTrue = true, want false")
		}
	})
}

// TestAmd2_Section56_4_NoMutationSurfacesInDecisionLayer is the §56.4
// structural invariant: the engine.go file (the decision layer) must
// reference ZERO mutating executor methods. Any reference to a
// mutating method in this file is a contract violation against
// INV-PR26-NEW-MUTATION-SURFACES-BOUNDED and Amendment 2 §55.
func TestAmd2_Section56_4_NoMutationSurfacesInDecisionLayer(t *testing.T) {
	mutatingMethods := []string{
		"ServiceMask", "ServiceUnmask", "ServiceStop", "ServiceStart",
		"ServiceEnable", "ServiceDisable",
		"Rename", "RemoveFile", "WriteFileAtomic", "MkdirAll",
		"NftDeleteTable",
	}

	enginePath, err := filepath.Abs("engine.go")
	if err != nil {
		t.Fatalf("filepath.Abs: %v", err)
	}
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, enginePath, nil, parser.AllErrors)
	if err != nil {
		t.Fatalf("parser.ParseFile %s: %v", enginePath, err)
	}

	var hits []string
	ast.Inspect(f, func(n ast.Node) bool {
		sel, ok := n.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		for _, m := range mutatingMethods {
			if sel.Sel.Name == m {
				pos := fset.Position(sel.Pos())
				hits = append(hits, m+" at "+pos.String())
			}
		}
		return true
	})
	if len(hits) > 0 {
		t.Errorf("engine.go references %d mutating method(s) — Amendment 2 §55 violation: %v",
			len(hits), hits)
	}
}

// TestAmd2_Section56_3_NoForceOrOverrideInFlagText scans the engine.go
// file and the new evidence file for any "force" or "override"
// substring in human-facing strings, per Amendment 2 §55 forbidden
// behavior "no force semantics". (CLI flag text is checked separately
// in the cmd-package test.)
func TestAmd2_Section56_3_NoForceOrOverrideInFlagText(t *testing.T) {
	files := []string{"engine.go", "types.go"}
	for _, file := range files {
		t.Run(file, func(t *testing.T) {
			path, err := filepath.Abs(file)
			if err != nil {
				t.Fatalf("filepath.Abs: %v", err)
			}
			fset := token.NewFileSet()
			f, err := parser.ParseFile(fset, path, nil, parser.AllErrors)
			if err != nil {
				t.Fatalf("parser.ParseFile %s: %v", path, err)
			}
			ast.Inspect(f, func(n ast.Node) bool {
				lit, ok := n.(*ast.BasicLit)
				if !ok || lit.Kind != token.STRING {
					return true
				}
				s := strings.ToLower(lit.Value)
				// Match only against amendment-2-specific contexts:
				// the orphan-restore reasoning. Skip strings that
				// don't relate to the new path.
				if !strings.Contains(s, "amendment-2") &&
					!strings.Contains(s, "orphan") &&
					!strings.Contains(s, "accept-orphan-nftban") {
					return true
				}
				if strings.Contains(s, "force") || strings.Contains(s, "override") {
					t.Errorf("Amendment 2 §55: forbidden 'force'/'override' in amendment-2-context string at %s: %s",
						fset.Position(lit.Pos()), lit.Value)
				}
				return true
			})
		})
	}
}
