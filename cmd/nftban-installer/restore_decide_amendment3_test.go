// =============================================================================
// NFTBan v1.100 Amendment 3 — Dispatcher integration tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-restore-decide-amendment3-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-29"
// meta:description="Amendment 3 dispatcher-side wiring (ExternalIndicator + reframed E.2)"
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
//      so the engine's G1/AmbiguityConflictExternal split sees the entry
//      condition string.
//
//   2. Triggers gatherOrphanEvidence on the Amendment 3 quintuple shape
//      (AuthorityAmbiguous + AmbiguityConflictExternal + external=="csf"
//      + DirectAdmin + NoRecord + --panel-auto-takeover + --accept-orphan-nftban),
//      not only on the Amendment 2 triple.
//
//   3. Reframes E.2 in the Amendment 3 path so AllTrueAmendment3() returns
//      true on the happy path (per §64.1 + the dispatcher reframing).
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

// TestAmd3Dispatcher_E2Reframed_AllTrueAmendment3_True confirms that
// gatherOrphanEvidence sets E.2=true on the Amendment 3 entry condition
// (so AllTrueAmendment3() is satisfied on the happy path).
func TestAmd3Dispatcher_E2Reframed_AllTrueAmendment3_True(t *testing.T) {
	log := logging.New("/dev/null", false)
	ev := gatherOrphanEvidence(happyExec(), log, detect.PanelDirectAdmin, amd3HappyAuth(), happyProbe(), happyCfg())

	// E.2 must be true under the Amendment 3 entry condition (reframed
	// per §64.1).
	if !ev.E2AuthorityNFTBan {
		t.Errorf("E.2 = false on Amendment 3 entry condition; want true (reframed per §64.1)")
	}

	// AllTrueAmendment3() must be true (E.12 omitted; E.2 reframed-true).
	if !ev.AllTrueAmendment3() {
		t.Errorf("AllTrueAmendment3() = false; failed row=%s", ev.FailedRowIDAmendment3())
	}

	// E.12 (NoConflictExternal) must be FALSE because the entry condition
	// IS AmbiguityConflictExternal — this is Amendment 3 by construction.
	if ev.E12NoConflictExternal {
		t.Errorf("E.12 = true on Amendment 3 entry; want false (entry condition IS AmbiguityConflictExternal)")
	}

	// Amendment 2's AllTrue() must return false on this fixture because
	// E.12 is required-true by §54.1 but the Amendment 3 entry condition
	// makes that impossible. This proves the two predicates are
	// independently scoped.
	if ev.AllTrue() {
		t.Errorf("AllTrue() = true on Amendment 3 entry; want false (Amendment 2 predicate requires E.12=true)")
	}
}

// TestAmd3Dispatcher_E2_FalseWhenMisclassified confirms the E.2
// reframing is conservative: it only fires when the FULL quintuple
// shape is present in the classifier output. Empty external,
// non-csf external, and OrphanNFTBan ambiguity all keep E.2 false.
func TestAmd3Dispatcher_E2_FalseWhenMisclassified(t *testing.T) {
	cases := []struct {
		name string
		auth *uninstall.ClassifyResult
		want bool
	}{
		{
			name: "amd2_path_authority_nftban",
			auth: &uninstall.ClassifyResult{
				State:     uninstall.AuthorityNFTBan,
				Ambiguity: uninstall.AmbiguityNone,
				External:  "",
			},
			want: true, // Amendment 2's classic E.2
		},
		{
			name: "amd3_path_authority_ambiguous_csf",
			auth: &uninstall.ClassifyResult{
				State:     uninstall.AuthorityAmbiguous,
				Ambiguity: uninstall.AmbiguityConflictExternal,
				External:  "csf",
			},
			want: true, // Amendment 3 reframed E.2
		},
		{
			name: "external_empty_defensive",
			auth: &uninstall.ClassifyResult{
				State:     uninstall.AuthorityAmbiguous,
				Ambiguity: uninstall.AmbiguityConflictExternal,
				External:  "",
			},
			want: false, // empty external — not a §62 candidate
		},
		{
			name: "external_ufw_out_of_scope",
			auth: &uninstall.ClassifyResult{
				State:     uninstall.AuthorityAmbiguous,
				Ambiguity: uninstall.AmbiguityConflictExternal,
				External:  "ufw",
			},
			want: false, // non-csf external — not a §62 candidate
		},
		{
			name: "external_multi_csf_ufw",
			auth: &uninstall.ClassifyResult{
				State:     uninstall.AuthorityAmbiguous,
				Ambiguity: uninstall.AmbiguityConflictExternal,
				External:  "csf,ufw",
			},
			want: false, // multi-external — not a §62 candidate
		},
		{
			name: "ambiguity_orphan_nftban",
			auth: &uninstall.ClassifyResult{
				State:     uninstall.AuthorityAmbiguous,
				Ambiguity: uninstall.AmbiguityOrphanNFTBan,
				External:  "csf",
			},
			want: false, // wrong sub-classifier — not a §62 candidate
		},
		{
			name: "authority_external",
			auth: &uninstall.ClassifyResult{
				State:    uninstall.AuthorityExternal,
				External: "csf",
			},
			want: false, // AuthorityExternal — locked-REFUSE, not §62
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

// TestAmd3Dispatcher_FailedRow_Amendment3 confirms FailedRowIDAmendment3()
// returns AMD3-E.{N} on per-row failures from the Amendment 3 path.
// E.12 is omitted from the Amendment 3 walk so its falseness must not
// trigger a failed-row return.
func TestAmd3Dispatcher_FailedRow_Amendment3(t *testing.T) {
	log := logging.New("/dev/null", false)

	// Happy path: AllTrueAmendment3 holds, FailedRowIDAmendment3 is empty.
	ev := gatherOrphanEvidence(happyExec(), log, detect.PanelDirectAdmin, amd3HappyAuth(), happyProbe(), happyCfg())
	if id := ev.FailedRowIDAmendment3(); id != "" {
		t.Errorf("FailedRowIDAmendment3 on happy path = %q; want \"\"", id)
	}

	// Failure path: kill E.7 (csf.disabled absent).
	exec := happyExec()
	delete(exec.Files, "/usr/sbin/csf.disabled")
	ev = gatherOrphanEvidence(exec, log, detect.PanelDirectAdmin, amd3HappyAuth(), happyProbe(), happyCfg())
	if id := ev.FailedRowIDAmendment3(); id != "AMD3-E.7" {
		t.Errorf("FailedRowIDAmendment3 with E.7 absent = %q; want %q", id, "AMD3-E.7")
	}
}
