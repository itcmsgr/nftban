// SPDX-License-Identifier: MPL-2.0
// =============================================================================
// NFTBan v1.100 — Restore Planner tests (PR-25 §24)
// =============================================================================
// meta:name="restore_planner_test"
// meta:type="test"
// meta:version="1.100.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="PR-25 commit 2 tests: PlanFromDecision invariants — non-PROCEED rejection, Group→Kind mapping, missing/empty/unknown priorRec rejection, PanelNone rejection, ambiguous-input defensive guards, Kind=None unreachability, no mutation surface."
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
	"os"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// readSelf returns the source of a sibling .go file. Used by the
// no-mutation-surface scan below; read-only, never mutates anything.
func readSelf(filename string) (string, error) {
	b, err := os.ReadFile(filename)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// procRecordedPrior_StrongActive_NoFlag mirrors PR-24's G3.1/StrongPrior+NoFlag
// PROCEED rule. AuthorityNone, complete-active prior, no flags.
func fixtureG3_1_StrongPriorNoFlag() (DecisionResult, DecisionInput, *uninstall.PriorRecord) {
	dr := DecisionResult{
		Output: OutputProceed,
		Rule:   RuleG3_1StrongPriorNoFlag,
		Reason: "fixture",
	}
	in := DecisionInput{
		Authority:    uninstall.AuthorityNone,
		Ambiguity:    uninstall.AmbiguityNone,
		Prior:        PriorStateCompleteActive,
		Flags:        Flags{Restore: false, PanelAutoTakeover: false},
		PanelPresent: false,
	}
	rec := &uninstall.PriorRecord{
		SchemaVersion: uninstall.PriorRecordSchemaVersion,
		FirewallType:  "ufw",
	}
	return dr, in, rec
}

// fixtureG3_1_StrongPriorRestore mirrors G3.1/StrongPrior+Restore PROCEED rule.
func fixtureG3_1_StrongPriorRestore() (DecisionResult, DecisionInput, *uninstall.PriorRecord) {
	dr, in, rec := fixtureG3_1_StrongPriorNoFlag()
	dr.Rule = RuleG3_1StrongPriorRestore
	in.Flags = Flags{Restore: true, PanelAutoTakeover: false}
	return dr, in, rec
}

// fixtureG3_1_StrongPriorPanelAuto mirrors G3.1/StrongPrior+PanelAuto PROCEED.
// Note: prior record exists but Q4 forbids consulting it on this branch.
func fixtureG3_1_StrongPriorPanelAuto() (DecisionResult, DecisionInput, *uninstall.PriorRecord) {
	dr, in, rec := fixtureG3_1_StrongPriorNoFlag()
	dr.Rule = RuleG3_1StrongPriorPanelAuto
	in.Flags = Flags{Restore: false, PanelAutoTakeover: true}
	in.PanelPresent = true
	return dr, in, rec
}

// fixtureG3_3_NoRecordPanelAuto mirrors G3.3/NoRecord+PanelAuto PROCEED.
// No prior record at all.
func fixtureG3_3_NoRecordPanelAuto() (DecisionResult, DecisionInput, *uninstall.PriorRecord) {
	dr := DecisionResult{
		Output: OutputProceed,
		Rule:   RuleG3_3NoRecordPanelAuto,
		Reason: "fixture",
	}
	in := DecisionInput{
		Authority:    uninstall.AuthorityNone,
		Ambiguity:    uninstall.AmbiguityNone,
		Prior:        PriorStateNoRecord,
		Flags:        Flags{Restore: false, PanelAutoTakeover: true},
		PanelPresent: true,
	}
	return dr, in, nil // priorRec nil — no record on disk
}

// fixtureG4_1_OrphanStrongRestore mirrors G4.1/OrphanStrong+Restore PROCEED.
func fixtureG4_1_OrphanStrongRestore() (DecisionResult, DecisionInput, *uninstall.PriorRecord) {
	dr := DecisionResult{
		Output: OutputProceed,
		Rule:   RuleG4_1OrphanStrongRestore,
		Reason: "fixture",
	}
	in := DecisionInput{
		Authority:    uninstall.AuthorityAmbiguous,
		Ambiguity:    uninstall.AmbiguityOrphanNFTBan,
		Prior:        PriorStateCompleteActive,
		Flags:        Flags{Restore: true, PanelAutoTakeover: false},
		PanelPresent: false,
	}
	rec := &uninstall.PriorRecord{
		SchemaVersion: uninstall.PriorRecordSchemaVersion,
		FirewallType:  "firewalld",
	}
	return dr, in, rec
}

// fixtureG4_3_OrphanPanelAuto mirrors G4.3/OrphanPanelAuto PROCEED.
func fixtureG4_3_OrphanPanelAuto() (DecisionResult, DecisionInput, *uninstall.PriorRecord) {
	dr := DecisionResult{
		Output: OutputProceed,
		Rule:   RuleG4_3OrphanPanelAuto,
		Reason: "fixture",
	}
	in := DecisionInput{
		Authority:    uninstall.AuthorityAmbiguous,
		Ambiguity:    uninstall.AmbiguityOrphanNFTBan,
		Prior:        PriorStateNoRecord,
		Flags:        Flags{Restore: false, PanelAutoTakeover: true},
		PanelPresent: true,
	}
	return dr, in, nil
}

// =============================================================================
// Acceptance: each PR-24 PROCEED fixture maps to the contract-specified Kind.
// =============================================================================

func TestPlanFromDecision_G3_1_StrongPriorNoFlag_RecordedPrior(t *testing.T) {
	dr, in, rec := fixtureG3_1_StrongPriorNoFlag()
	ta, err := PlanFromDecision(dr, in, rec, detect.PanelNone)
	if err != nil {
		t.Fatalf("planner returned error: %v", err)
	}
	if ta.Kind() != TargetAuthorityKindRecordedPrior {
		t.Errorf("Kind = %q; want RecordedPrior (G3.1 NoFlag)", ta.Kind())
	}
	if ta.FirewallType() != "ufw" {
		t.Errorf("FirewallType = %q; want %q", ta.FirewallType(), "ufw")
	}
	if ta.Panel() != detect.PanelNone {
		t.Errorf("Panel = %q; want PanelNone (RecordedPrior payload invariant)", ta.Panel())
	}
}

func TestPlanFromDecision_G3_1_StrongPriorRestore_RecordedPrior(t *testing.T) {
	dr, in, rec := fixtureG3_1_StrongPriorRestore()
	ta, err := PlanFromDecision(dr, in, rec, detect.PanelNone)
	if err != nil {
		t.Fatalf("planner returned error: %v", err)
	}
	if ta.Kind() != TargetAuthorityKindRecordedPrior {
		t.Errorf("Kind = %q; want RecordedPrior (G3.1 Restore)", ta.Kind())
	}
}

func TestPlanFromDecision_G3_1_StrongPriorPanelAuto_PanelNative(t *testing.T) {
	// Per Q4 §20.3: prior record must NOT be consulted when PanelAuto.
	// This fixture supplies a non-nil priorRec with FirewallType="ufw"
	// to verify the planner ignores it (returned Panel must be the
	// supplied panel, not the priorRec's firewall).
	dr, in, rec := fixtureG3_1_StrongPriorPanelAuto()
	ta, err := PlanFromDecision(dr, in, rec, detect.PanelCPanel)
	if err != nil {
		t.Fatalf("planner returned error: %v", err)
	}
	if ta.Kind() != TargetAuthorityKindPanelNative {
		t.Errorf("Kind = %q; want PanelNative (G3.1 PanelAuto)", ta.Kind())
	}
	if ta.Panel() != detect.PanelCPanel {
		t.Errorf("Panel = %q; want %q", ta.Panel(), detect.PanelCPanel)
	}
	// §18.3 payload invariant — empty for PanelNative, not the
	// priorRec's "ufw".
	if ta.FirewallType() != "" {
		t.Errorf("FirewallType = %q; want empty (Q4 forbids consulting priorRec on PanelAuto)", ta.FirewallType())
	}
}

func TestPlanFromDecision_G3_3_NoRecordPanelAuto_PanelNative(t *testing.T) {
	dr, in, rec := fixtureG3_3_NoRecordPanelAuto()
	ta, err := PlanFromDecision(dr, in, rec, detect.PanelDirectAdmin)
	if err != nil {
		t.Fatalf("planner returned error: %v", err)
	}
	if ta.Kind() != TargetAuthorityKindPanelNative {
		t.Errorf("Kind = %q; want PanelNative (G3.3 NoRecord+PanelAuto)", ta.Kind())
	}
	if ta.Panel() != detect.PanelDirectAdmin {
		t.Errorf("Panel = %q; want %q", ta.Panel(), detect.PanelDirectAdmin)
	}
}

func TestPlanFromDecision_G4_1_OrphanStrongRestore_RecordedPrior(t *testing.T) {
	dr, in, rec := fixtureG4_1_OrphanStrongRestore()
	ta, err := PlanFromDecision(dr, in, rec, detect.PanelNone)
	if err != nil {
		t.Fatalf("planner returned error: %v", err)
	}
	if ta.Kind() != TargetAuthorityKindRecordedPrior {
		t.Errorf("Kind = %q; want RecordedPrior (G4.1 OrphanStrong+Restore)", ta.Kind())
	}
	if ta.FirewallType() != "firewalld" {
		t.Errorf("FirewallType = %q; want firewalld", ta.FirewallType())
	}
}

func TestPlanFromDecision_G4_3_OrphanPanelAuto_PanelNative(t *testing.T) {
	dr, in, rec := fixtureG4_3_OrphanPanelAuto()
	ta, err := PlanFromDecision(dr, in, rec, detect.PanelPlesk)
	if err != nil {
		t.Fatalf("planner returned error: %v", err)
	}
	if ta.Kind() != TargetAuthorityKindPanelNative {
		t.Errorf("Kind = %q; want PanelNative (G4.3 OrphanPanelAuto)", ta.Kind())
	}
}

// =============================================================================
// Rejection: non-PROCEED inputs must error before any further work.
// =============================================================================

func TestPlanFromDecision_RejectsRefuse(t *testing.T) {
	dr := DecisionResult{Output: OutputRefuse, Rule: "G1/AuthorityNFTBan", Reason: "fixture"}
	_, in, rec := fixtureG3_1_StrongPriorNoFlag()
	_, err := PlanFromDecision(dr, in, rec, detect.PanelNone)
	if err == nil {
		t.Fatalf("planner accepted REFUSE; want error")
	}
	if !errors.Is(err, ErrPlanNotProceed) {
		t.Errorf("wrong error class for REFUSE: %v", err)
	}
}

func TestPlanFromDecision_RejectsRequireExplicitIntent(t *testing.T) {
	dr := DecisionResult{Output: OutputRequireExplicitIntent, Rule: "G3.3/NoRecord+NoFlag", Reason: "fixture"}
	_, in, rec := fixtureG3_3_NoRecordPanelAuto()
	_, err := PlanFromDecision(dr, in, rec, detect.PanelCPanel)
	if err == nil {
		t.Fatalf("planner accepted REQUIRE_EXPLICIT_INTENT; want error")
	}
	if !errors.Is(err, ErrPlanNotProceed) {
		t.Errorf("wrong error class for REQUIRE_EXPLICIT_INTENT: %v", err)
	}
}

// =============================================================================
// RecordedPrior failure cases.
// =============================================================================

func TestPlanFromDecision_RecordedPrior_RejectsNilPriorRec(t *testing.T) {
	dr, in, _ := fixtureG3_1_StrongPriorRestore()
	_, err := PlanFromDecision(dr, in, nil, detect.PanelNone)
	if err == nil {
		t.Fatalf("planner accepted nil priorRec on RecordedPrior path; want error")
	}
	if !errors.Is(err, ErrPlanMissingPriorRecord) {
		t.Errorf("wrong error class for nil priorRec: %v", err)
	}
}

func TestPlanFromDecision_RecordedPrior_RejectsEmptyFirewallType(t *testing.T) {
	dr, in, rec := fixtureG3_1_StrongPriorRestore()
	rec.FirewallType = ""
	_, err := PlanFromDecision(dr, in, rec, detect.PanelNone)
	if err == nil {
		t.Fatalf("planner accepted empty FirewallType; want error")
	}
	if !errors.Is(err, ErrPlanInvariantViolation) {
		t.Errorf("wrong error class for empty FirewallType: %v", err)
	}
}

func TestPlanFromDecision_RecordedPrior_RejectsUnknownFirewallType(t *testing.T) {
	dr, in, rec := fixtureG3_1_StrongPriorRestore()
	// PR-24's Probe would classify this as PriorRecordIncomplete
	// (IncompleteReasonUnknownFirewallType) so PROCEED would never
	// fire. Reaching the planner with this combo means the dispatcher
	// fed inconsistent inputs.
	rec.FirewallType = "pf-not-supported"
	_, err := PlanFromDecision(dr, in, rec, detect.PanelNone)
	if err == nil {
		t.Fatalf("planner accepted unknown FirewallType; want error")
	}
	if !errors.Is(err, ErrPlanInvariantViolation) {
		t.Errorf("wrong error class for unknown FirewallType: %v", err)
	}
}

func TestPlanFromDecision_RecordedPrior_RejectsNonStrongPriorState(t *testing.T) {
	// G3.1/G4.1 require Prior=Complete{Active,Inactive}. NoRecord on
	// the RecordedPrior branch is an invariant violation.
	dr, in, rec := fixtureG3_1_StrongPriorRestore()
	in.Prior = PriorStateNoRecord
	_, err := PlanFromDecision(dr, in, rec, detect.PanelNone)
	if err == nil {
		t.Fatalf("planner accepted Prior=NoRecord on RecordedPrior path; want error")
	}
	if !errors.Is(err, ErrPlanInvariantViolation) {
		t.Errorf("wrong error class: %v", err)
	}
}

// =============================================================================
// PanelNative failure cases.
// =============================================================================

func TestPlanFromDecision_PanelNative_RejectsPanelNone(t *testing.T) {
	dr, in, rec := fixtureG3_1_StrongPriorPanelAuto()
	// in.PanelPresent is true but caller passes PanelNone — disagreement.
	_, err := PlanFromDecision(dr, in, rec, detect.PanelNone)
	if err == nil {
		t.Fatalf("planner accepted PanelNone on PanelAuto path; want error")
	}
	if !errors.Is(err, ErrPlanInvariantViolation) {
		t.Errorf("wrong error class: %v", err)
	}
}

func TestPlanFromDecision_PanelNative_PanelPresentMismatch(t *testing.T) {
	// PanelAutoTakeover flag set but input.PanelPresent=false.
	// PR-24's G2/PanelAutoTakeoverWithoutPanel would catch this as
	// REFUSE before PROCEED. Reaching the planner means inputs are
	// corrupted.
	dr, in, rec := fixtureG3_1_StrongPriorPanelAuto()
	in.PanelPresent = false
	_, err := PlanFromDecision(dr, in, rec, detect.PanelCPanel)
	if err == nil {
		t.Fatalf("planner accepted PanelAuto with PanelPresent=false; want error")
	}
	if !errors.Is(err, ErrPlanInvariantViolation) {
		t.Errorf("wrong error class: %v", err)
	}
}

// =============================================================================
// Both-flags-set defensive guard.
// =============================================================================

func TestPlanFromDecision_RejectsBothFlagsSet(t *testing.T) {
	// PR-24 G2/RestoreAndPanelAutoBothSet would refuse before PROCEED;
	// this is a defensive caller-corruption guard.
	dr, in, rec := fixtureG3_1_StrongPriorRestore()
	in.Flags = Flags{Restore: true, PanelAutoTakeover: true}
	_, err := PlanFromDecision(dr, in, rec, detect.PanelCPanel)
	if err == nil {
		t.Fatalf("planner accepted both flags set; want error")
	}
	if !errors.Is(err, ErrPlanInvariantViolation) {
		t.Errorf("wrong error class: %v", err)
	}
}

// =============================================================================
// Kind=None unreachability — by exhaustive coverage of valid PROCEED branches.
// =============================================================================

func TestPlanFromDecision_KindNone_UnreachableFromValidProceed(t *testing.T) {
	// Walk every PROCEED fixture and assert Kind != None on success.
	type fixtureFn func() (DecisionResult, DecisionInput, *uninstall.PriorRecord)
	type fixtureCase struct {
		name  string
		fn    fixtureFn
		panel detect.PanelType
	}
	cases := []fixtureCase{
		{"G3.1/NoFlag", fixtureG3_1_StrongPriorNoFlag, detect.PanelNone},
		{"G3.1/Restore", fixtureG3_1_StrongPriorRestore, detect.PanelNone},
		{"G3.1/PanelAuto", fixtureG3_1_StrongPriorPanelAuto, detect.PanelCPanel},
		{"G3.3/NoRecord+PanelAuto", fixtureG3_3_NoRecordPanelAuto, detect.PanelDirectAdmin},
		{"G4.1/OrphanStrong+Restore", fixtureG4_1_OrphanStrongRestore, detect.PanelNone},
		{"G4.3/OrphanPanelAuto", fixtureG4_3_OrphanPanelAuto, detect.PanelPlesk},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			dr, in, rec := tc.fn()
			ta, err := PlanFromDecision(dr, in, rec, tc.panel)
			if err != nil {
				t.Fatalf("planner unexpectedly errored: %v", err)
			}
			if ta.Kind() == TargetAuthorityKindNone {
				t.Errorf("planner produced Kind=None for valid PROCEED fixture %q", tc.name)
			}
		})
	}
}

// =============================================================================
// No mutation surface — structural / textual assertion that the planner
// implementation file does not reach for forbidden APIs.
// This is a cheap sanity net; the real enforcement is the file-fence
// rule applied at PR review time.
// =============================================================================

func TestPlanner_NoMutationSurface_FileScan(t *testing.T) {
	// Read the planner file and assert it does not import or reference
	// any obvious mutation-capable identifiers. Not a substitute for
	// review, but flags the next time a refactor accidentally reaches
	// for one.
	//
	// Forbidden patterns (substrings):
	//   - "os/exec" / "exec.Command" / "exec.CommandContext"
	//   - "os.WriteFile" / "os.Create" / "os.Remove" / "os.Rename"
	//   - "syscall." (any direct syscall)
	//   - "nft " / "systemctl " (shell-out fragments)
	//   - "DetectPanel(" / "Probe(" / "Classify(" (live re-detection)
	forbidden := []string{
		"os/exec",
		"exec.Command",
		"os.WriteFile",
		"os.Create",
		"os.Remove",
		"os.Rename",
		"syscall.",
		`"nft "`,
		`"systemctl `,
		"DetectPanel(",
		"uninstall.Probe(",
		"uninstall.Classify(",
		"restore.Decide(", // planner must not re-run the engine
	}
	body, err := readSelf("planner.go")
	if err != nil {
		t.Fatalf("read planner.go: %v", err)
	}
	for _, pat := range forbidden {
		if strings.Contains(body, pat) {
			t.Errorf("planner.go references forbidden pattern %q (mutation/re-detection surface)", pat)
		}
	}
}
