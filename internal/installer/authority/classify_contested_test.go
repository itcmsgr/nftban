// =============================================================================
// NFTBan — CSF-CLOSE-4: retroactive takeover must be reachable
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-authority-classify-contested-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-08-11"
// meta:description="Locks CSF-CLOSE-4: an explicitly approved takeover on a host where NFTBan is already authoritative AND a conflicting firewall is present must classify as Takeover, not silently downgrade to Update. Ordinary upgrades are unaffected."
// meta:inventory.files="internal/installer/authority/classify.go"
// meta:inventory.privileges="none"
// =============================================================================
//
// RUNTIME EVIDENCE (el9-clean, 2026-08-11, R3-P1 #3):
//
//	NFTBan COMMITTED with 65 kernel rules AND csf.service active with 129
//	iptables rules. Invoked with --takeover --force:
//
//	  extfw/detect: AMBIGUOUS — multiple active: [iptables csf]
//	  [conflict]  CSF=service (csf.service)
//	  [authority] decision=UPDATE        <- foreign-active state DISCARDED
//	  DisableConflicts markers: 0        <- never entered
//	  rc=0 · CONFLICTS=<empty> · status=PROTECTED
//
//	Confirmed by contrast in R3-P2 arm 1: same binary, same flags, same live
//	CSF — with NFTBan made non-authoritative the decision became TAKEOVER.
//	NFTBan's own authoritativeness was the sole discriminator.
//
//	NFTBAN OWNING THE FIREWALL != NOTHING ELSE DOES
package authority

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func testLog() *logging.Logger { return logging.New("/dev/null", false) }

// Reuses the package's existing authoritativeMock() helper rather than
// hand-rolling a second seeding convention — a hand-rolled mock used the wrong
// NftTables key format and made every arm SKIP, which would have looked like
// success. REUSE THE CANONICAL FIXTURE.

func TestClose4_AuthoritativeHostWithConflictAndExplicitApproval_IsTakeover(t *testing.T) {
	m := authoritativeMock()
	if !IsNftbanAuthoritative(m) {
		t.Skip("mock could not reach an authoritative shape — arm would be vacuous")
	}
	conflicts := []detect.Conflict{{Name: "CSF", Service: "csf.service", Active: true}}

	got := Classify(m, conflicts, detect.PanelNone, true /*forceApprove*/, false, testLog())

	if got != Takeover {
		t.Errorf("explicit --takeover with CSF present was downgraded to %q — "+
			"retroactive takeover unreachable (R3-P1 #3)", got)
	}
}

// NEGATIVE CONTROL 1: no conflicts => ordinary upgrade path must be untouched.
func TestClose4_AuthoritativeHostNoConflicts_StaysUpdate(t *testing.T) {
	m := authoritativeMock()
	if !IsNftbanAuthoritative(m) {
		t.Skip("mock not authoritative")
	}
	got := Classify(m, nil, detect.PanelNone, true /*forceApprove*/, false, testLog())
	if got != Update {
		t.Errorf("no conflicts present but classified %q — ordinary upgrades must stay Update", got)
	}
}

// NEGATIVE CONTROL 2: conflicts but NO explicit approval => must stay Update.
// This is the guard that keeps the fix narrow: it must not make routine
// upgrades destructive on a host that merely has another firewall installed.
func TestClose4_AuthoritativeHostConflictsWithoutApproval_StaysUpdate(t *testing.T) {
	m := authoritativeMock()
	if !IsNftbanAuthoritative(m) {
		t.Skip("mock not authoritative")
	}
	conflicts := []detect.Conflict{{Name: "CSF", Service: "csf.service", Active: true}}

	got := Classify(m, conflicts, detect.PanelNone, false /*forceApprove*/, false, testLog())

	if got != Update {
		t.Errorf("conflicts without explicit approval classified %q — "+
			"an unapproved upgrade must never become a takeover", got)
	}
}

// The pre-fix behaviour, stated as a property: a non-authoritative host with
// the same inputs already reached Takeover. Pinning it guards the contrast
// that isolated the discriminator, so a future refactor cannot quietly make
// BOTH paths Update.
func TestClose4_NonAuthoritativeHostWithConflict_IsTakeover(t *testing.T) {
	m := executor.NewMockExecutor() // no nftban table/daemon
	conflicts := []detect.Conflict{{Name: "CSF", Service: "csf.service", Active: true}}

	got := Classify(m, conflicts, detect.PanelNone, true, false, testLog())

	if got != Takeover {
		t.Errorf("non-authoritative host with conflict + approval classified %q, want Takeover", got)
	}
}
