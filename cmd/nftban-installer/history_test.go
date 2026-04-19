// =============================================================================
// NFTBan v1.99 PR-19 — History Integrity + Source/Package Coherence Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-history-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Unit tests for historyStatusForState + historyInstallType"
// meta:inventory.files="cmd/nftban-installer/history_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// PR-19 G3-U12 (update history integrity):
//   - historyStatusForState must never coerce non-committed states to "success"
//   - intermediate non-terminal states (e.g. DETECT_COMPLETE) report install_fail
//
// PR-19 G3-U13 (source/package coherence):
//   - historyInstallType must return "source" for --source installs (not "rpm")
//   - priority order: source > deb > rpm > default
//
// =============================================================================
package main

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/history"
	"github.com/itcmsgr/nftban/internal/installer/state"
)

// PR-22B regression guard: the guard that gates writeHistory at main.go
// uses (!cfg.dryRun) && state.IsApplyTerminal(sf.State). These tests
// verify each half of the predicate produces the expected skip/write
// decision. We test the predicate directly rather than invoking
// writeHistory because that function writes to /var/lib/nftban/ — the
// gate must refuse to reach it for non-apply-terminal states.
func TestHistoryWriteGate_DryRunAlwaysSkips(t *testing.T) {
	// Apply-terminal state + dry-run → must still skip.
	dryRun := true
	s := state.StateCommitted
	if shouldWrite := !dryRun && s.IsApplyTerminal(); shouldWrite {
		t.Errorf("dry-run + Committed must NOT write history; gate produced write=true")
	}
}

func TestHistoryWriteGate_NonApplyTerminalAlwaysSkips(t *testing.T) {
	cases := []state.InstallState{
		state.StateDetectComplete,
		state.StatePrepareComplete,
		state.StateSwitchComplete,
		state.StateServicesComplete,
		state.StateUninstallPlanning,
		state.StateFilesInstalled,
	}
	for _, s := range cases {
		if shouldWrite := !false && s.IsApplyTerminal(); shouldWrite {
			t.Errorf("non-apply-terminal state %s must NOT write history; gate produced write=true", s)
		}
	}
}

func TestHistoryWriteGate_ApplyTerminalNonDryRunWrites(t *testing.T) {
	cases := []state.InstallState{
		state.StateCommitted,
		state.StateDegraded,
		state.StateFailedRebuild,
		state.StateFailedAbort,
	}
	for _, s := range cases {
		if shouldWrite := !false && s.IsApplyTerminal(); !shouldWrite {
			t.Errorf("apply-terminal state %s in non-dry-run must write history; gate produced write=false", s)
		}
	}
}

// historyStatusForState ───────────────────────────────────────────────────

func TestHistoryStatusForState_Committed_IsSuccess(t *testing.T) {
	if got := historyStatusForState(state.StateCommitted); got != history.StatusSuccess {
		t.Errorf("StateCommitted → %q; want %q", got, history.StatusSuccess)
	}
}

func TestHistoryStatusForState_Degraded_IsVerifyFail(t *testing.T) {
	if got := historyStatusForState(state.StateDegraded); got != history.StatusVerifyFail {
		t.Errorf("StateDegraded → %q; want %q", got, history.StatusVerifyFail)
	}
}

// G3-U12: every failure state maps to install_fail — no coercion to success.
func TestHistoryStatusForState_AllFailureStates_AreInstallFail(t *testing.T) {
	failureStates := []state.InstallState{
		state.StateFailedSSH,
		state.StateFailedAbort,
		state.StateFailedRender,
		state.StateFailedRebuild,
		state.StateFailedNoFirewall,
		state.StateFailedTakeover,
	}
	for _, s := range failureStates {
		if got := historyStatusForState(s); got != history.StatusInstallFail {
			t.Errorf("failure state %s → %q; want %q (no success coercion)", s, got, history.StatusInstallFail)
		}
	}
}

// G3-U12 regression guard: intermediate non-terminal states must NOT report
// success. Previously an interrupted apply (timeout / signal) left sf.State
// on something like DETECT_COMPLETE, and a careless review of the status
// could misread this as "install in progress" — the history writer must
// record it as a failure so operator audits remain honest.
func TestHistoryStatusForState_IntermediateStates_AreInstallFail(t *testing.T) {
	intermediateStates := []state.InstallState{
		state.StateFilesInstalled,
		state.StateDetectComplete,
		state.StatePrepareComplete,
		state.StateSwitchComplete,
		state.StateServicesComplete,
	}
	for _, s := range intermediateStates {
		if got := historyStatusForState(s); got != history.StatusInstallFail {
			t.Errorf("intermediate state %s → %q; want %q (non-terminal = not a success)", s, got, history.StatusInstallFail)
		}
	}
}

// historyInstallType ──────────────────────────────────────────────────────

func TestHistoryInstallType_Source(t *testing.T) {
	cfg := &config{source: true}
	if got := historyInstallType(cfg); got != "source" {
		t.Errorf("--source → %q; want %q (G3-U13 coherence: source installs must not be mislabeled)", got, "source")
	}
}

func TestHistoryInstallType_DEB(t *testing.T) {
	cfg := &config{deb: true}
	if got := historyInstallType(cfg); got != "deb" {
		t.Errorf("--deb → %q; want %q", got, "deb")
	}
}

func TestHistoryInstallType_RPM(t *testing.T) {
	cfg := &config{rpm: true}
	if got := historyInstallType(cfg); got != "rpm" {
		t.Errorf("--rpm → %q; want %q", got, "rpm")
	}
}

func TestHistoryInstallType_Priority_SourceOverridesDEB(t *testing.T) {
	cfg := &config{source: true, deb: true}
	if got := historyInstallType(cfg); got != "source" {
		t.Errorf("--source --deb → %q; want %q (source wins)", got, "source")
	}
}

func TestHistoryInstallType_Priority_DEBOverridesRPM(t *testing.T) {
	cfg := &config{deb: true, rpm: true}
	if got := historyInstallType(cfg); got != "deb" {
		t.Errorf("--deb --rpm → %q; want %q (deb wins, source not set)", got, "deb")
	}
}

func TestHistoryInstallType_NoFlag_DefaultsToRPM(t *testing.T) {
	cfg := &config{}
	if got := historyInstallType(cfg); got != "rpm" {
		t.Errorf("no flag → %q; want %q (legacy default)", got, "rpm")
	}
}
