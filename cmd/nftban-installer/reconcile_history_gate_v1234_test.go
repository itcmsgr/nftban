// =============================================================================
// NFTBan v1.234.0 R1 — --reconcile-lifecycle never writes update-history.json
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="nftban-installer-reconcile-history-gate-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-23"
// meta:description="Pins historyWriteAllowed: --reconcile-lifecycle is excluded for every state and outcome; normal gate semantics unchanged"
// meta:inventory.files="cmd/nftban-installer/reconcile_history_gate_v1234_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// MEASURED package-native (v1.234 C1, lab2 DEB + lab4 RPM, candidate 3667bed8): every
// real --reconcile-lifecycle invocation appended a FALSE entry to update-history.json,
// because main() wrote history from the state it read BEFORE the reconcile. These tests
// call the gate main() actually uses; the older history_test.go gate tests re-implement
// the predicate inline and could not have caught it.

package main

import (
	"os"
	"regexp"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/state"
)

// Every state a record can carry when main() reaches the gate. A reconcile run reads
// REBUILD_REFUSED_BUSY (eligible), COMMITTED (already committed / second run), or
// whatever a --state-dir copy contains — so the exclusion must not depend on state.
// The synthetic value proves the exclusion is decided before the state is consulted.
var allGateStates = []state.InstallState{
	state.StateAppliedUnverified, state.StateCommitted, state.StateDegraded,
	state.StateDetectComplete, state.StateFailedAbort, state.StateFailedNoFirewall,
	state.StateFailedPreflightDiskSpace, state.StateFailedRebuild, state.StateFailedRender,
	state.StateFailedSSH, state.StateFailedTakeover, state.StateFilesInstalled,
	state.StatePrepareComplete, state.StateRebuildNotExecuted, state.StateRebuildRefusedBusy,
	state.StateRestoreDecided, state.StateRestoreDegraded, state.StateRestoreExecuted,
	state.StateRestoreFailedExecution, state.StateRestoreFailedVerification,
	state.StateRestoreIntentRequired, state.StateRestoreRefused, state.StateServicesComplete,
	state.StateSwitchComplete, state.StateUninstallFailedRelease, state.StateUninstallPlanning,
	state.StateUninstallReleased,
	state.InstallState("SOME_FUTURE_STATE"),
}

// The population above must track the declared constants, or a new state could slip
// past this test unexamined. Derived from the source, not from memory.
func TestReconcileHistoryGate_StatePopulationMatchesDeclaredConstants(t *testing.T) {
	re := regexp.MustCompile(`(?m)^\s*(State[A-Za-z]+)\s+InstallState\s*=`)
	dir := "../../internal/installer/state"
	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("read %s: %v", dir, err)
	}
	declared := 0
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".go") || strings.HasSuffix(e.Name(), "_test.go") {
			continue
		}
		b, err := os.ReadFile(dir + "/" + e.Name())
		if err != nil {
			t.Fatalf("read %s: %v", e.Name(), err)
		}
		declared += len(re.FindAllSubmatch(b, -1))
	}
	if declared == 0 {
		t.Fatal("found 0 declared InstallState constants — the scan is broken, not the population empty")
	}
	if got := len(allGateStates) - 1; got != declared { // -1: the synthetic state
		t.Fatalf("allGateStates lists %d real states, source declares %d — update the population", got, declared)
	}
}

func TestReconcileHistoryGate_ReconcileNeverWrites_AnyStateAnyFlags(t *testing.T) {
	for _, s := range allGateStates {
		for _, dry := range []bool{false, true} {
			for _, mode := range []string{"", "install", "upgrade"} {
				cfg := &config{reconcileLifecycle: true, dryRun: dry, mode: mode}
				if historyWriteAllowed(cfg, s) {
					t.Errorf("reconcile would write history: state=%s dryRun=%v mode=%q", s, dry, mode)
				}
			}
		}
	}
}

// The packaging paths still pass --deb/--rpm; a reconcile run carrying them must not
// regain history access either.
func TestReconcileHistoryGate_ReconcileNeverWrites_WithPackageFlags(t *testing.T) {
	for _, cfg := range []*config{
		{reconcileLifecycle: true, deb: true},
		{reconcileLifecycle: true, rpm: true},
		{reconcileLifecycle: true, source: true},
	} {
		if historyWriteAllowed(cfg, state.StateCommitted) || historyWriteAllowed(cfg, state.StateRebuildRefusedBusy) {
			t.Errorf("reconcile with package flag would write history: %+v", *cfg)
		}
	}
}

// Normal transactions keep their existing, truthful history behaviour.
func TestReconcileHistoryGate_NormalGateUnchanged(t *testing.T) {
	cases := []struct {
		name string
		cfg  *config
		s    state.InstallState
		want bool
	}{
		{"committed install writes", &config{mode: "upgrade", deb: true}, state.StateCommitted, true},
		{"refused-busy transaction writes", &config{mode: "upgrade", rpm: true}, state.StateRebuildRefusedBusy, true},
		{"dry-run never writes", &config{mode: "upgrade", dryRun: true}, state.StateCommitted, false},
		{"uninstall never writes", &config{mode: "uninstall"}, state.StateUninstallReleased, false},
		{"restore never writes", &config{mode: "restore"}, state.StateCommitted, false},
		{"non-apply-terminal never writes", &config{mode: "upgrade"}, state.StatePrepareComplete, false},
	}
	for _, c := range cases {
		if got := historyWriteAllowed(c.cfg, c.s); got != c.want {
			t.Errorf("%s: historyWriteAllowed=%v, want %v", c.name, got, c.want)
		}
	}
}

// Structural: main() may reach writeHistory ONLY through historyWriteAllowed, and the
// reconcile dispatch file must never call it directly.
func TestReconcileHistoryGate_WriteHistoryOnlyBehindGate(t *testing.T) {
	body, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatalf("read main.go: %v", err)
	}
	src := string(body)
	calls := regexp.MustCompile(`(?m)^\s*writeHistory\(`).FindAllStringIndex(src, -1)
	if len(calls) != 1 {
		t.Fatalf("expected exactly 1 writeHistory call site in main.go, found %d", len(calls))
	}
	before := src[:calls[0][0]]
	if i := strings.LastIndex(before, "\n\tif "); i < 0 || !strings.Contains(before[i:], "historyWriteAllowed(cfg, sf.State)") {
		t.Error("the writeHistory call is not guarded by historyWriteAllowed(cfg, sf.State)")
	}
	rl, err := os.ReadFile("reconcile_lifecycle.go")
	if err != nil {
		t.Fatalf("read reconcile_lifecycle.go: %v", err)
	}
	if strings.Contains(string(rl), "writeHistory(") {
		t.Error("reconcile_lifecycle.go calls writeHistory — reconcile must not write update history")
	}
}
