// =============================================================================
// NFTBan v1.232.2 — update apply must not claim COMMITTED (falsifier)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// =============================================================================
//
// Subject: BUG-UPDATE-APPLY-CAN-COMMIT-WITHOUT-CONVERGENCE-VERDICT.
//
// ⛔ THIS FILE MUST FAIL AGAINST THE PRE-FIX CODE. It drives the FULLY SUCCESSFUL
// path — preflight passes, rebuild passes, validator passes, kernel table present,
// daemon active — and requires the run NOT to report COMMITTED. Before v1.232.2
// that path transitioned to StateCommitted and returned 0 with CONVERGENCE_VERIFIED
// left empty, which is precisely what production srv3 was observed holding.
//
// Everything here goes through the mock executor; nothing touches a real host.
//
// =============================================================================

package main

import (
	"context"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/history"
	"github.com/itcmsgr/nftban/internal/installer/postinstall"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
)

// runHappyApply drives the all-pass path and returns (rc, state file).
func runHappyApply(t *testing.T) (int, *state.StateFile) {
	t.Helper()
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(t, mock)
	cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
	sf := state.NewStateFile(cfg.stateDir)
	rc := runUpdateApply(context.Background(), mock, sf, cfg, newApplyTestLogger())
	return rc, sf
}

// The load-bearing assertion. A fully successful apply is still not a commit.
func TestUpdateApply_SuccessPath_NeverReportsCommitted(t *testing.T) {
	rc, sf := runHappyApply(t)

	if sf.State == state.StateCommitted {
		t.Fatal("update apply reached COMMITTED on a path that never evaluates convergence — " +
			"this is the srv3 defect (INSTALL_STATE=COMMITTED beside CONVERGENCE_VERIFIED=\"\")")
	}
	if rc == state.ExitCommitted {
		t.Fatalf("update apply returned %d (ExitCommitted) — every rc==0 consumer would read "+
			"this unverified run as a verified one", rc)
	}
	if sf.State != state.StateAppliedUnverified {
		t.Errorf("state = %s; want %s", sf.State, state.StateAppliedUnverified)
	}
	if rc != state.ExitAppliedUnverified {
		t.Errorf("rc = %d; want ExitAppliedUnverified (%d)", rc, state.ExitAppliedUnverified)
	}
}

// ⛔ THE VERDICT IS STATED, NOT LEFT BLANK. An empty field reads as "nobody got
// around to writing it"; NOT_EVALUATED reads as "this path does not evaluate
// convergence", which is the actual fact and is what makes the state auditable.
func TestUpdateApply_SuccessPath_RecordsNotEvaluatedExplicitly(t *testing.T) {
	_, sf := runHappyApply(t)

	if sf.ConvergenceVerified == "" {
		t.Fatal("CONVERGENCE_VERIFIED left EMPTY — the srv3 shape; an omission is not a verdict")
	}
	if got, want := sf.ConvergenceVerified, string(switchop.ConvergenceNotEvaluated); got != want {
		t.Errorf("CONVERGENCE_VERIFIED = %q; want %q", got, want)
	}
	// NOT_EVALUATED must be distinguishable from the two verdicts that mean
	// "we looked". Collapsing them would lose the reason recovery differs.
	if sf.ConvergenceVerified == string(switchop.ConvergenceNotConverged) ||
		sf.ConvergenceVerified == string(switchop.ConvergenceUnverified) {
		t.Error("NOT_EVALUATED collapsed into a verdict that implies convergence was actually tested")
	}
}

// The state↔exit↔history triple must agree, and history must not say success.
func TestUpdateApply_SuccessPath_HistoryIsNotSuccess(t *testing.T) {
	rc, sf := runHappyApply(t)

	if got := sf.State.ExitCode(); got != rc {
		t.Errorf("state.ExitCode() = %d but rc = %d — state↔exit contradiction", got, rc)
	}

	status := historyStatusForState(sf.State)
	if status == history.StatusSuccess {
		t.Fatal("history status = success for a run that never proved convergence")
	}
	if status != history.StatusAppliedUnverified {
		t.Errorf("history status = %q; want %q", status, history.StatusAppliedUnverified)
	}
	// ⛔ AND NOT install_fail EITHER. The mutation applied; recording it as a
	// failed install would misdirect fleet triage toward a rollback.
	if status == history.StatusInstallFail {
		t.Error("history status = install_fail — the mutation applied and the validator passed")
	}
}

// An unmapped state must never silently inherit another state's history status.
func TestHistoryStatusForUnknownStateIsUnknown(t *testing.T) {
	got := historyStatusForState(state.InstallState("A_STATE_THAT_DOES_NOT_EXIST"))
	if got != history.StatusUnknownState {
		t.Errorf("unknown state mapped to %q; want %q — a default of install_fail invents "+
			"a failure the system never observed", got, history.StatusUnknownState)
	}
}

// The package-native verifier must not report this as verified, and must not
// describe it with a sentence that is false about it.
func TestPostinstallVerdictForAppliedUnverified(t *testing.T) {
	v := postinstall.AppliedUnverified
	if v.Verified() {
		t.Fatal("AppliedUnverified reports Verified() — the package surface would claim success")
	}
	if v == postinstall.CurrentCommitted {
		t.Fatal("AppliedUnverified aliases CURRENT_COMMITTED")
	}
	if string(v) != string(state.StateAppliedUnverified) {
		t.Errorf("verdict token %q does not match the state literal %q — two surfaces naming "+
			"one outcome differently is how they drift apart", v, state.StateAppliedUnverified)
	}
}

// emitRecovery must print the DERIVED refusal reason, not a borrowed one.
func TestEmitRecoveryReasonIsStateSpecific(t *testing.T) {
	busy := state.StateRebuildRefusedBusy.RepairRefusalReason()
	applied := state.StateAppliedUnverified.RepairRefusalReason()

	if applied == "" {
		t.Fatal("APPLIED_UNVERIFIED has no refusal reason, but its RecoveryClass refuses --repair")
	}
	if applied == busy {
		t.Fatal("APPLIED_UNVERIFIED reuses REBUILD_REFUSED_BUSY's refusal reason verbatim — " +
			"one surface printing a reason the authority did not give it")
	}
	if strings.Contains(applied, "switch phase") || strings.Contains(applied, "SWITCH") {
		t.Errorf("APPLIED_UNVERIFIED resumes at VALIDATE, but its reason talks about SWITCH: %q", applied)
	}
	if state.StateAppliedUnverified.RecoveryClass() != state.RecoveryRetryFullTransaction {
		t.Error("APPLIED_UNVERIFIED must be RETRY_FULL_TRANSACTION")
	}
}
