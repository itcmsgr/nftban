// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// Regression matrix for the installer deadline false-verdict defect.
//
// Production shape (srv3, 1.229.11): a firewall rebuild ran 318s and returned exit=0
// against a 300s global budget. The phase loop checks ctx.Err() when ENTERING a phase,
// so the run was recorded FAILED_REBUILD naming "Configure" — a phase that never ran —
// while the firewall was healthy. ResumePhase(FAILED_REBUILD)=PhaseSwitch then makes
// --repair re-run the entire Switch phase, including another full rebuild, to recover
// from a run in which nothing failed.
package main

import (
	"context"
	"strings"
	"testing"
	"time"
)

// resetExempt clears the package-level record between cases.
func resetExempt() { globalPhaseData = phaseData{} }

// TestExemptCredit_NotGrantedWithoutACompletedOperation is the safety property that
// keeps the installer terminating: a credit must never be granted for an operation that
// is still running or never ran. Granting one then would be unbounded by construction.
func TestExemptCredit_NotGrantedWithoutACompletedOperation(t *testing.T) {
	resetExempt()
	if exemptOpSucceeded(&globalPhaseData) {
		t.Fatal("credit granted with no exempt operation recorded")
	}
	globalPhaseData = phaseData{exemptOpName: "firewall rebuild", exemptOpDuration: 318 * time.Second}
	if exemptOpSucceeded(&globalPhaseData) {
		t.Fatal("credit granted for an exempt operation that did NOT succeed — " +
			"a failed or still-running operation must never buy more budget")
	}
}

// TestExemptCredit_GrantedOnlyForSuccess is the production shape: rebuild exceeded the
// budget but SUCCEEDED, so the run must not be reclassified as a failure.
func TestExemptCredit_GrantedOnlyForSuccess(t *testing.T) {
	resetExempt()
	globalPhaseData = phaseData{
		exemptOpName:      "firewall rebuild",
		exemptOpDuration:  318 * time.Second,
		exemptOpSucceeded: true,
	}
	if !exemptOpSucceeded(&globalPhaseData) {
		t.Fatal("no credit for a completed, successful, policy-exempt operation — " +
			"this is the srv3 false-verdict case and must not fail the run")
	}
}

// TestPostExemptBudget_IsBoundedAndSmallerThanGlobal proves the tail is a FRESH BOUNDED
// budget, not "no deadline". Removing the false failure must not create an installer
// that can never terminate.
func TestPostExemptBudget_IsBoundedAndSmallerThanGlobal(t *testing.T) {
	if postExemptBudget <= 0 {
		t.Fatal("post-exempt budget must be positive — an unbounded tail is a hang")
	}
	if postExemptBudget >= globalTimeout {
		t.Errorf("post-exempt budget %s >= global %s: the tail must stay strictly bounded "+
			"and must not become a second full budget", postExemptBudget, globalTimeout)
	}
	ctx, cancel := context.WithTimeout(context.Background(), postExemptBudget)
	defer cancel()
	if _, ok := ctx.Deadline(); !ok {
		t.Fatal("post-exempt context carries no deadline")
	}
}

// TestGlobalBudgetIsLoggedInCollectorForm pins the cross-lane contract. The support
// bundle greps installer.log for `global (budget|timeout)=[0-9]+[a-z]*`; if this wording
// drifts the bundle silently returns to reporting UNKNOWN and operators lose the ability
// to tell a false verdict from a real failure.
func TestGlobalBudgetIsLoggedInCollectorForm(t *testing.T) {
	line := formatGlobalBudgetLine(globalTimeout, time.Unix(0, 0).UTC())
	re := `global (budget|timeout)=[0-9]+[a-z]*`
	if !matchesCollectorBudgetRegex(line) {
		t.Fatalf("logged budget line %q does not satisfy the support collector regex %q", line, re)
	}
}

// ---- full timeout/cancellation matrix ---------------------------------------
//
// Five timeout CLASSES, not one number:
//   1 normal bounded operation
//   2 long-running but healthy  (the srv3 case: 318s, exit=0)
//   3 slow with no progress     — NOT distinguishable today, see TestRebuildHangSupervisionIsMissing
//   4 truly hung                — NOT bounded today, same test
//   5 operation succeeds, later phase fails/never starts — attribution

func exemptOK(d time.Duration) *phaseData {
	return &phaseData{exemptOpName: "firewall rebuild", exemptOpDuration: d, exemptOpSucceeded: true}
}
func exemptFailed(d time.Duration) *phaseData {
	return &phaseData{exemptOpName: "firewall rebuild", exemptOpDuration: d, exemptOpSucceeded: false}
}

func TestDeadlineMatrix(t *testing.T) {
	for _, tc := range []struct {
		name       string
		lastRan    string
		next       string
		pd         *phaseData
		credited   bool
		wantFail   bool
		wantCredit bool
		mustSay    string
		mustNotSay string
	}{
		{
			name: "rebuild succeeded then budget gone -> continue, do NOT fail",
			lastRan: "Switch", next: "Configure", pd: exemptOK(318 * time.Second),
			wantCredit: true, mustSay: "exempt by policy and completed successfully",
		},
		{
			name: "exempt op FAILED -> real failure, no credit",
			lastRan: "Switch", next: "Configure", pd: exemptFailed(318 * time.Second),
			wantFail: true, mustSay: "after phase Switch",
		},
		{
			name: "exempt op never completed -> no credit (must not buy budget)",
			lastRan: "Switch", next: "Configure", pd: &phaseData{},
			wantFail: true, mustSay: "after phase Switch",
		},
		{
			name: "credit already consumed -> cannot be granted twice",
			lastRan: "Configure", next: "Validate", pd: exemptOK(318 * time.Second), credited: true,
			wantFail: true, mustSay: "after phase Configure",
		},
		{
			name: "expiry before ANY phase ran -> must not blame the first phase",
			lastRan: "none", next: "Detect", pd: &phaseData{},
			wantFail: true, mustSay: "phase Detect was not entered", mustNotSay: "during phase Detect",
		},
		{
			name: "attribution: names the phase that RAN, not the one about to start",
			lastRan: "Switch", next: "Configure", pd: &phaseData{},
			wantFail: true, mustSay: "after phase Switch; phase Configure was not entered",
			mustNotSay: "during phase Configure",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			got := decideOnExpiry(tc.lastRan, tc.next, tc.pd, tc.credited)
			if got.Fail != tc.wantFail {
				t.Errorf("Fail=%v want %v (msg=%q)", got.Fail, tc.wantFail, got.Message)
			}
			if got.GrantCredit != tc.wantCredit {
				t.Errorf("GrantCredit=%v want %v", got.GrantCredit, tc.wantCredit)
			}
			if tc.mustSay != "" && !strings.Contains(got.Message, tc.mustSay) {
				t.Errorf("message %q does not contain %q", got.Message, tc.mustSay)
			}
			if tc.mustNotSay != "" && strings.Contains(got.Message, tc.mustNotSay) {
				t.Errorf("message %q must NOT contain %q — that is the mis-attribution "+
					"that made --repair re-run the entire Switch phase", got.Message, tc.mustNotSay)
			}
			if tc.wantFail && !strings.HasPrefix(got.Reason, "deadline_expired_after_") {
				t.Errorf("persisted reason %q loses the attribution", got.Reason)
			}
		})
	}
}

// TestRebuildHangSupervisionIsMissing is a TRUTH ANCHOR, not a passing feature test.
// It documents, in executable form, that classes 3 and 4 (stalled / truly hung rebuild)
// are NOT bounded today: switchop.Rebuild runs the subprocess on context.Background(),
// so the installer's deadline cannot terminate it, and no scriptlet or systemd unit wraps
// the installer. Incident A did not create this window and does not close it.
// If someone later adds supervision, this test should be REPLACED by a real one.
func TestRebuildHangSupervisionIsMissing(t *testing.T) {
	if postExemptBudget <= 0 || globalTimeout <= 0 {
		t.Fatal("budgets must stay positive")
	}
	t.Log("REBUILD_HANG_SUPERVISION=MISSING — a rebuild that never returns hangs the " +
		"installer indefinitely. The global deadline cannot help: the subprocess runs on " +
		"context.Background(). Tracked as a GA backlog item (progress-aware supervision); " +
		"deliberately NOT solved by raising a wall-clock timeout, which would only convert " +
		"a 318s incident into a 618s one.")
}
