// =============================================================================
// NFTBan v1.100 Amendment 3 — Dispatcher integration tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-restore-decide-amendment3-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-29"
// meta:description="Amendment 3 dispatcher-side wiring (ExternalIndicator + reframed E.2 + separate helper)"
// meta:inventory.files="cmd/nftban-installer/restore_decide_amendment3_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Confirms the dispatcher correctly:
//
//   1. Plumbs ClassifyResult.External into DecisionInput.ExternalIndicator
//      so the engine's G1/AmbiguityConflictExternal split sees the
//      §62 entry condition string.
//
//   2. Calls the Amendment 3 evidence helper (gatherOrphanEvidenceAmendment3)
//      on the Amendment 3 quintuple shape, NOT the Amendment 2 helper
//      (auditor-recommended separate-helper structure).
//
//   3. Calls the Amendment 2 evidence helper (gatherOrphanEvidence)
//      on the Amendment 2 quintuple shape (regression — Amendment 2
//      path unchanged).
//
//   4. Reframes E.2 in the Amendment 3 helper so AllTrueAmendment3()
//      returns true on the §62 happy path.
//
//   5. Keeps gatherOrphanEvidence's E.2 strictly evaluating
//      AuthorityNFTBan (Amendment 2 unchanged).
//
// =============================================================================
package main

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/uninstall"
)

// amd3HappyAuth returns a ClassifyResult shaped for the §62 Amendment 3
// entry condition: AuthorityAmbiguous + AmbiguityConflictExternal +
// external=="csf". Mirrors how dns2 looks post-canonical-install.
func amd3HappyAuth() *uninstall.ClassifyResult {
	return &uninstall.ClassifyResult{
		State:     uninstall.AuthorityAmbiguous,
		Ambiguity: uninstall.AmbiguityConflictExternal,
		External:  "csf",
	}
}

// TestGatherOrphanEvidenceAmendment3_E2Reframed_AllTrueAmendment3_True
// confirms the Amendment 3 helper sets E.2=true on the §62 entry
// condition and AllTrueAmendment3() returns true on the happy path.
// Also verifies E.12 is correctly false (entry condition IS
// AmbiguityConflictExternal) and that AllTrue() (Amendment 2 predicate)
// returns false on this fixture (because E.12 is required-true by §54.1).
func TestGatherOrphanEvidenceAmendment3_E2Reframed_AllTrueAmendment3_True(t *testing.T) {
	log := logging.New("/dev/null", false)
	ev := gatherOrphanEvidenceAmendment3(happyExec(), log, detect.PanelDirectAdmin, amd3HappyAuth(), happyProbe(), happyCfg())

	if !ev.E2AuthorityNFTBan {
		t.Errorf("E.2 = false on Amendment 3 entry condition; want true (reframed per §64.1)")
	}
	if !ev.AllTrueAmendment3() {
		t.Errorf("AllTrueAmendment3() = false; failed row=%s", ev.FailedRowIDAmendment3())
	}
	if ev.E12NoConflictExternal {
		t.Errorf("E.12 = true on Amendment 3 entry; want false (entry condition IS AmbiguityConflictExternal)")
	}
	if ev.AllTrue() {
		t.Errorf("AllTrue() = true on Amendment 3 entry; want false (Amendment 2 predicate requires E.12=true)")
	}
}

// TestGatherOrphanEvidenceAmendment3_E2FalseOnNonQualifying confirms
// that the Amendment 3 helper's E.2 is conservative: ONLY fires when
// the full §62 entry condition (AuthorityAmbiguous + ConflictExternal
// + external=="csf") is present.
func TestGatherOrphanEvidenceAmendment3_E2FalseOnNonQualifying(t *testing.T) {
	cases := []struct {
		name string
		auth *uninstall.ClassifyResult
		want bool
	}{
		{
			name: "amd3_path_authority_ambiguous_csf",
			auth: &uninstall.ClassifyResult{
				State:     uninstall.AuthorityAmbiguous,
				Ambiguity: uninstall.AmbiguityConflictExternal,
				External:  "csf",
			},
			want: true,
		},
		{
			name: "amd2_path_authority_nftban_FAILS_amendment3_helper",
			auth: &uninstall.ClassifyResult{
				State:     uninstall.AuthorityNFTBan,
				Ambiguity: uninstall.AmbiguityNone,
				External:  "",
			},
			want: false, // gatherOrphanEvidenceAmendment3 ONLY accepts §62 entry
		},
		{
			name: "external_empty_defensive",
			auth: &uninstall.ClassifyResult{
				State:     uninstall.AuthorityAmbiguous,
				Ambiguity: uninstall.AmbiguityConflictExternal,
				External:  "",
			},
			want: false,
		},
		{
			name: "external_ufw_out_of_scope",
			auth: &uninstall.ClassifyResult{
				State:     uninstall.AuthorityAmbiguous,
				Ambiguity: uninstall.AmbiguityConflictExternal,
				External:  "ufw",
			},
			want: false,
		},
		{
			name: "external_multi_csf_ufw",
			auth: &uninstall.ClassifyResult{
				State:     uninstall.AuthorityAmbiguous,
				Ambiguity: uninstall.AmbiguityConflictExternal,
				External:  "csf,ufw",
			},
			want: false,
		},
		{
			name: "ambiguity_orphan_nftban",
			auth: &uninstall.ClassifyResult{
				State:     uninstall.AuthorityAmbiguous,
				Ambiguity: uninstall.AmbiguityOrphanNFTBan,
				External:  "csf",
			},
			want: false,
		},
		{
			name: "authority_external",
			auth: &uninstall.ClassifyResult{
				State:    uninstall.AuthorityExternal,
				External: "csf",
			},
			want: false,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			log := logging.New("/dev/null", false)
			ev := gatherOrphanEvidenceAmendment3(happyExec(), log, detect.PanelDirectAdmin, c.auth, happyProbe(), happyCfg())
			if ev.E2AuthorityNFTBan != c.want {
				t.Errorf("E.2 = %v; want %v", ev.E2AuthorityNFTBan, c.want)
			}
		})
	}
}

// TestGatherOrphanEvidence_Amendment2Unchanged confirms the Amendment 2
// helper's E.2 still evaluates strictly AuthorityNFTBan. This is the
// regression check for §66.2 — Amendment 2 path stays passing.
func TestGatherOrphanEvidence_Amendment2Unchanged(t *testing.T) {
	cases := []struct {
		name string
		auth *uninstall.ClassifyResult
		want bool
	}{
		{
			name: "amd2_authority_nftban_true",
			auth: &uninstall.ClassifyResult{
				State:     uninstall.AuthorityNFTBan,
				Ambiguity: uninstall.AmbiguityNone,
			},
			want: true,
		},
		{
			name: "amd3_classifier_does_NOT_qualify_amendment2_E2",
			auth: &uninstall.ClassifyResult{
				State:     uninstall.AuthorityAmbiguous,
				Ambiguity: uninstall.AmbiguityConflictExternal,
				External:  "csf",
			},
			want: false, // Amendment 2 helper rejects Amendment 3 entry
		},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			log := logging.New("/dev/null", false)
			ev := gatherOrphanEvidence(happyExec(), log, detect.PanelDirectAdmin, c.auth, happyProbe(), happyCfg())
			if ev.E2AuthorityNFTBan != c.want {
				t.Errorf("E.2 = %v; want %v", ev.E2AuthorityNFTBan, c.want)
			}
		})
	}
}

// TestGatherOrphanEvidenceAmendment3_FailedRow confirms
// FailedRowIDAmendment3() returns AMD3-E.{N} on per-row failures and
// "" on the happy path. E.12 is omitted from the Amendment 3 walk so
// its falseness must not trigger a failed-row return.
func TestGatherOrphanEvidenceAmendment3_FailedRow(t *testing.T) {
	log := logging.New("/dev/null", false)

	ev := gatherOrphanEvidenceAmendment3(happyExec(), log, detect.PanelDirectAdmin, amd3HappyAuth(), happyProbe(), happyCfg())
	if id := ev.FailedRowIDAmendment3(); id != "" {
		t.Errorf("FailedRowIDAmendment3 on happy path = %q; want \"\"", id)
	}

	exec := happyExec()
	delete(exec.Files, "/usr/sbin/csf.disabled")
	ev = gatherOrphanEvidenceAmendment3(exec, log, detect.PanelDirectAdmin, amd3HappyAuth(), happyProbe(), happyCfg())
	if id := ev.FailedRowIDAmendment3(); id != "AMD3-E.7" {
		t.Errorf("FailedRowIDAmendment3 with E.7 absent = %q; want %q", id, "AMD3-E.7")
	}
}

// TestGatherOrphanEvidenceAmendment3_E2_FalseOnNonCSFExternal pins
// the AMD3-7-equivalent gating: external != "csf" → E.2 = false →
// AllTrueAmendment3 false → FailedRowIDAmendment3 == AMD3-E.2.
func TestGatherOrphanEvidenceAmendment3_E2_FalseOnNonCSFExternal(t *testing.T) {
	log := logging.New("/dev/null", false)
	auth := &uninstall.ClassifyResult{
		State:     uninstall.AuthorityAmbiguous,
		Ambiguity: uninstall.AmbiguityConflictExternal,
		External:  "ufw",
	}
	ev := gatherOrphanEvidenceAmendment3(happyExec(), log, detect.PanelDirectAdmin, auth, happyProbe(), happyCfg())
	if ev.E2AuthorityNFTBan {
		t.Errorf("E.2 = true on external=ufw; want false")
	}
	if ev.AllTrueAmendment3() {
		t.Errorf("AllTrueAmendment3 = true on external=ufw; want false")
	}
	if id := ev.FailedRowIDAmendment3(); id != "AMD3-E.2" {
		t.Errorf("FailedRowIDAmendment3 on external=ufw = %q; want %q", id, "AMD3-E.2")
	}
}

// TestGatherOrphanEvidenceAmendment3_OmitsE12 carries the §66.2
// invariant from the engine_amendment3_test.go suite into the
// dispatcher integration: AllTrueAmendment3() must NOT consider
// E.12 even when it is false.
func TestGatherOrphanEvidenceAmendment3_OmitsE12(t *testing.T) {
	log := logging.New("/dev/null", false)
	ev := gatherOrphanEvidenceAmendment3(happyExec(), log, detect.PanelDirectAdmin, amd3HappyAuth(), happyProbe(), happyCfg())

	// On Amendment 3 entry, E.12 is false (entry IS ConflictExternal).
	if ev.E12NoConflictExternal {
		t.Fatalf("invariant: E.12 must be false on Amendment 3 entry; got true")
	}
	// AllTrueAmendment3 must still pass — E.12 omitted from predicate.
	if !ev.AllTrueAmendment3() {
		t.Errorf("AllTrueAmendment3 = false despite E.12 omission; failed row=%s", ev.FailedRowIDAmendment3())
	}
}
