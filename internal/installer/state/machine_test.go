// =============================================================================
// NFTBan v1.73 - Installer State Machine Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-state-machine-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Unit tests for state machine transitions and file I/O"
// meta:inventory.files="internal/installer/state/machine_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package state

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestInstallState_IsFailed(t *testing.T) {
	failed := []InstallState{
		StateFailedSSH, StateFailedAbort, StateFailedRender,
		StateFailedRebuild, StateFailedNoFirewall, StateFailedTakeover,
	}
	for _, s := range failed {
		if !s.IsFailed() {
			t.Errorf("expected %s to be failed", s)
		}
	}

	notFailed := []InstallState{
		StateFilesInstalled, StateDetectComplete, StatePrepareComplete,
		StateSwitchComplete, StateServicesComplete, StateCommitted, StateDegraded,
	}
	for _, s := range notFailed {
		if s.IsFailed() {
			t.Errorf("expected %s to NOT be failed", s)
		}
	}
}

func TestInstallState_IsTerminal(t *testing.T) {
	terminal := []InstallState{
		StateCommitted, StateDegraded,
		StateFailedSSH, StateFailedAbort, StateFailedRender,
		StateFailedRebuild, StateFailedNoFirewall, StateFailedTakeover,
	}
	for _, s := range terminal {
		if !s.IsTerminal() {
			t.Errorf("expected %s to be terminal", s)
		}
	}

	nonTerminal := []InstallState{
		StateFilesInstalled, StateDetectComplete, StatePrepareComplete,
		StateSwitchComplete, StateServicesComplete,
	}
	for _, s := range nonTerminal {
		if s.IsTerminal() {
			t.Errorf("expected %s to NOT be terminal", s)
		}
	}
}

func TestInstallState_ExitCode(t *testing.T) {
	tests := []struct {
		state InstallState
		want  int
	}{
		{StateCommitted, ExitCommitted},
		{StateDegraded, ExitDegraded},
		{StateFailedRebuild, ExitFailed},
		{StateFailedNoFirewall, ExitFailed},
		{StateFailedAbort, ExitAborted},
		{StateFailedSSH, ExitFailed},
		// PR-23 uninstall terminals
		{StateUninstallReleased, ExitCommitted},     // uninstall succeeded → process exit success
		{StateUninstallFailedRelease, ExitFailed},   // uninstall failed mid-flight → process exit failure
	}
	for _, tt := range tests {
		if got := tt.state.ExitCode(); got != tt.want {
			t.Errorf("ExitCode(%s) = %d, want %d", tt.state, got, tt.want)
		}
	}
}

func TestInstallState_ResumePhase(t *testing.T) {
	tests := []struct {
		state InstallState
		want  Phase
	}{
		{StateCommitted, PhaseReport},
		{StateDegraded, PhaseValidate},
		{StateServicesComplete, PhaseValidate},
		{StateSwitchComplete, PhaseConfigure},
		{StateFailedRebuild, PhaseSwitch},
		{StateFailedNoFirewall, PhaseSwitch},
		{StateFailedTakeover, PhaseSwitch},
		{StatePrepareComplete, PhaseSwitch},
		{StateFailedRender, PhasePrepare},
		{StateDetectComplete, PhasePrepare},
		{StateFilesInstalled, PhaseDetect},
		{StateFailedSSH, PhaseDetect},
		{StateFailedAbort, PhaseDetect},
	}
	for _, tt := range tests {
		if got := tt.state.ResumePhase(); got != tt.want {
			t.Errorf("ResumePhase(%s) = %s, want %s", tt.state, got, tt.want)
		}
	}
}

func TestStateFile_WriteAndRead(t *testing.T) {
	dir := t.TempDir()

	sf := NewStateFile(dir)
	sf.State = StateCommitted
	sf.Mode = "upgrade"
	sf.Version = "1.73.0"
	sf.Timestamp = time.Date(2026, 4, 4, 15, 30, 0, 0, time.UTC)
	sf.SSHPort = 55000
	sf.Authority = "UPDATE"
	sf.Panel = "cpanel"
	sf.Conflicts = ""
	sf.SchemaVersion = "0.7.3"
	sf.PhaseReached = "VALIDATE"
	sf.FailureReason = ""
	sf.PreflightPassed = true
	sf.RebuildExitCode = 0
	sf.RebuildDurationMs = 4523
	sf.ServicesEnabled = "nftband.socket,nftband.service"
	sf.ServicesFailed = ""

	if err := sf.WriteAtomic(); err != nil {
		t.Fatalf("WriteAtomic: %v", err)
	}

	// Verify file exists
	if _, err := os.Stat(filepath.Join(dir, StateFileName)); err != nil {
		t.Fatalf("state file not found: %v", err)
	}

	// Read back
	sf2 := NewStateFile(dir)
	if err := sf2.Read(); err != nil {
		t.Fatalf("Read: %v", err)
	}

	if sf2.State != StateCommitted {
		t.Errorf("State = %s, want COMMITTED", sf2.State)
	}
	if sf2.Mode != "upgrade" {
		t.Errorf("Mode = %s, want upgrade", sf2.Mode)
	}
	if sf2.SSHPort != 55000 {
		t.Errorf("SSHPort = %d, want 55000", sf2.SSHPort)
	}
	if sf2.Authority != "UPDATE" {
		t.Errorf("Authority = %s, want UPDATE", sf2.Authority)
	}
	if sf2.Panel != "cpanel" {
		t.Errorf("Panel = %s, want cpanel", sf2.Panel)
	}
	if sf2.SchemaVersion != "0.7.3" {
		t.Errorf("SchemaVersion = %s, want 0.7.3", sf2.SchemaVersion)
	}
	if !sf2.PreflightPassed {
		t.Error("PreflightPassed = false, want true")
	}
	if sf2.RebuildDurationMs != 4523 {
		t.Errorf("RebuildDurationMs = %d, want 4523", sf2.RebuildDurationMs)
	}
}

func TestStateFile_ReadMissing(t *testing.T) {
	dir := t.TempDir()
	sf := NewStateFile(dir)
	err := sf.Read()
	if !os.IsNotExist(err) {
		t.Errorf("Read missing file: got %v, want os.ErrNotExist", err)
	}
}

func TestStateFile_Transition(t *testing.T) {
	dir := t.TempDir()
	sf := NewStateFile(dir)
	sf.Mode = "install"
	sf.Version = "1.73.0"

	if err := sf.Transition(StateDetectComplete, PhaseDetect, ""); err != nil {
		t.Fatalf("Transition: %v", err)
	}
	if sf.State != StateDetectComplete {
		t.Errorf("State = %s, want DETECT_COMPLETE", sf.State)
	}
	if sf.PhaseReached != "DETECT" {
		t.Errorf("PhaseReached = %s, want DETECT", sf.PhaseReached)
	}

	// Transition to failure — must return error so phase runner halts
	if err := sf.Transition(StateFailedRebuild, PhaseSwitch, "rebuild exit 1"); err == nil {
		t.Fatal("Transition to failure state should return error")
	}
	if sf.FailureReason != "rebuild exit 1" {
		t.Errorf("FailureReason = %q, want %q", sf.FailureReason, "rebuild exit 1")
	}

	// Read back and verify
	sf2 := NewStateFile(dir)
	if err := sf2.Read(); err != nil {
		t.Fatalf("Read: %v", err)
	}
	if sf2.State != StateFailedRebuild {
		t.Errorf("Persisted State = %s, want FAILED_REBUILD", sf2.State)
	}
}

// PR-22B: DryRun=true must not create any files under stateDir. This
// test falsifies the boundary claim at the state layer — any regression
// that reintroduces a write during dry-run fails here before it can
// reach an orchestrator.
func TestStateFile_Transition_DryRunDoesNotWrite(t *testing.T) {
	dir := t.TempDir()
	sf := NewStateFile(dir)
	sf.DryRun = true
	sf.Mode = "upgrade"
	sf.Version = "1.100.0"

	if err := sf.Transition(StateDetectComplete, PhaseDetect, ""); err != nil {
		t.Fatalf("Transition under DryRun: %v", err)
	}
	if sf.State != StateDetectComplete {
		t.Errorf("in-memory State = %s, want DETECT_COMPLETE", sf.State)
	}
	// No file should have been created in stateDir.
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	if len(entries) != 0 {
		var names []string
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Errorf("DryRun Transition created files in stateDir: %v", names)
	}

	// A failure state under DryRun must still return the error (so phase
	// runners halt) but must NOT persist.
	if err := sf.Transition(StateFailedRebuild, PhaseSwitch, "simulated"); err == nil {
		t.Error("Transition to failure under DryRun must still return error to halt runners")
	}
	entries2, _ := os.ReadDir(dir)
	if len(entries2) != 0 {
		t.Errorf("DryRun failure Transition persisted state")
	}
}

// PR-22B: IsApplyTerminal is an explicit allowlist, not a catch-all.
// Every state must be either apply-terminal or not-apply-terminal; there
// are no unlisted "edge" states.
func TestInstallState_IsApplyTerminal(t *testing.T) {
	applyTerminal := []InstallState{
		StateCommitted,
		StateDegraded,
		StateFailedSSH,
		StateFailedAbort,
		StateFailedRender,
		StateFailedRebuild,
		StateFailedNoFirewall,
		StateFailedTakeover,
		// PR-23 uninstall terminals — apply-terminal for lifecycle
		// bookkeeping; history-write is gated separately by mode in
		// main.go so these don't pollute install-history.json.
		StateUninstallReleased,
		StateUninstallFailedRelease,
	}
	notApplyTerminal := []InstallState{
		StateFilesInstalled,
		StateDetectComplete,
		StatePrepareComplete,
		StateSwitchComplete,
		StateServicesComplete,
		// StateUninstallPlanning is the dry-run-only terminal; it
		// remains non-apply-terminal even after PR-23 because
		// dry-runs never produce history entries.
		StateUninstallPlanning,
	}
	for _, s := range applyTerminal {
		if !s.IsApplyTerminal() {
			t.Errorf("%s should be apply-terminal (completed apply outcome)", s)
		}
		if !IsApplyTerminal(s) {
			t.Errorf("IsApplyTerminal(%s) disagrees with method form", s)
		}
	}
	for _, s := range notApplyTerminal {
		if s.IsApplyTerminal() {
			t.Errorf("%s must NOT be apply-terminal (not a real apply outcome)", s)
		}
	}
}
