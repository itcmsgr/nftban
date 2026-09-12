// =============================================================================
// NFTBan v1.230.0 Gate 6R — refusal maps to a DEFERRED install state
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-rebuild-refusal-state-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-13"
// meta:description="R3: a rebuild refused through the whole installer deadline persists REBUILD_REFUSED_BUSY, never FAILED_REBUILD and never COMMITTED, stops the phase runner before Configure/Validate can manufacture a verdict, resumes at PhaseSwitch, and cannot be laundered into COMMITTED by --revalidate. Guards the dns1 v1.229.13->v1.229.14 defect where a pre-mutation refusal was recorded as FAILED_REBUILD."
// meta:inventory.files="cmd/nftban-installer/rebuild_refusal_state_v1230_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package main

import (
	"context"
	"fmt"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
	"github.com/itcmsgr/nftban/pkg/version"
)

// R3 — THREE OUTCOMES, THREE STATES. The classification is taken from the typed error
// derived from the shell contract, never from message text.
func TestR3_RebuildErrorClassification(t *testing.T) {
	cases := []struct {
		name string
		err  error
		want state.InstallState
	}{
		{"refused busy", fmt.Errorf("wrapped: %w", switchop.ErrRebuildRefusedBusy), state.StateRebuildRefusedBusy},
		{"not executed", fmt.Errorf("wrapped: %w", switchop.ErrRebuildNotExecuted), state.StateRebuildNotExecuted},
		{"executed and failed", fmt.Errorf("rebuild REGRESSION (exit 2)"), state.StateFailedRebuild},
		// ⛔ NON-VACUITY: an error whose TEXT mentions refusal but which is not the typed
		// sentinel must NOT be classified as a refusal. Text is not the interface.
		{"stderr text lookalike", fmt.Errorf("ERROR: convergence already in progress — this rebuild was REFUSED."), state.StateFailedRebuild},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := stateForRebuildError(tc.err); got != tc.want {
				t.Errorf("stateForRebuildError = %s, want %s", got, tc.want)
			}
		})
	}
}

// R3 — the deferred terminals must be distinguishable from failure AND from success.
func TestR3_DeferredTerminalsAreNeitherFailedNorCommitted(t *testing.T) {
	for _, s := range []state.InstallState{state.StateRebuildRefusedBusy, state.StateRebuildNotExecuted} {
		if s == state.StateCommitted {
			t.Fatalf("%s must never equal COMMITTED", s)
		}
		if s == state.StateFailedRebuild {
			t.Fatalf("%s must never equal FAILED_REBUILD", s)
		}
		if s.IsFailed() {
			t.Errorf("%s: refusal is not failure — no rebuild executed, so nothing failed", s)
		}
		if !s.IsDeferredRebuild() {
			t.Errorf("%s must be recognised as a deferred rebuild terminal", s)
		}
		if !s.IsTerminal() {
			t.Errorf("%s must be terminal for this run", s)
		}
		// ⛔ DEFERRED IS NOT SUCCESS: the process must not exit 0.
		if s.ExitCode() == state.ExitCommitted {
			t.Errorf("%s must never exit 0 — the transaction did not complete", s)
		}
		// --repair must re-run the rebuild that never ran.
		if got := s.ResumePhase(); got != state.PhaseSwitch {
			t.Errorf("%s resumes at %s, want SWITCH", s, got)
		}
		// A deferred outcome that never reaches history is invisible to fleet operators.
		if !s.IsApplyTerminal() {
			t.Errorf("%s must be apply-terminal so the run is recorded", s)
		}
	}
	// FAILED_REBUILD keeps its own meaning (negative control).
	if state.StateFailedRebuild.IsDeferredRebuild() {
		t.Error("FAILED_REBUILD must not be reclassified as deferred")
	}
	if !state.StateFailedRebuild.IsFailed() {
		t.Error("FAILED_REBUILD must remain a failure")
	}
}

// R3 — the transition must STOP the phase runner.
//
// ⛔ THIS IS THE FALSE-COMMITTED GUARD. StateFile.Transition returns nil for
// non-failure states, and runInstall walks to the next phase on nil. If a deferred
// rebuild returned nil, the run would continue into Configure and Validate and could
// reach COMMITTED because enforcement happened to still be in force.
//
//	PROTECTED != TRANSACTION COMPLETE.
func TestR3_DeferredTransitionStopsThePhaseRunner(t *testing.T) {
	for _, s := range []state.InstallState{state.StateRebuildRefusedBusy, state.StateRebuildNotExecuted} {
		dir := t.TempDir()
		sf := state.NewStateFile(dir)
		reason := "no rebuild executed; convergence attribution NOT established"
		err := sf.Transition(s, state.PhaseSwitch, reason)
		if err == nil {
			t.Fatalf("%s: Transition returned nil — the phase runner would continue into Configure/Validate", s)
		}
		if sf.State != s {
			t.Errorf("in-memory state = %s, want %s", sf.State, s)
		}
		if sf.FailureReason != reason {
			t.Errorf("%s: reason not recorded (got %q) — a terminal that will not say why is not diagnosable", s, sf.FailureReason)
		}
		// Persisted truth must match what report() renders.
		reread := state.NewStateFile(dir)
		if rerr := reread.Read(); rerr != nil {
			t.Fatalf("cannot re-read persisted state: %v", rerr)
		}
		if reread.State != s {
			t.Errorf("persisted state = %s, want %s", reread.State, s)
		}
		if reread.State == state.StateFailedRebuild {
			t.Errorf("persisted state must never be FAILED_REBUILD for %s", s)
		}
	}
}

// R3 — --revalidate must not launder a deferred rebuild into COMMITTED.
//
// revalidate recomputes install_state from LIVE post-install assertions, i.e. from
// "is enforcement currently protected right now". For a transaction that never
// converged, that question CANNOT establish COMMITTED — enforcement being in force is
// the OLD generation, unattributable to this update. This drives the real entrypoint
// so the property is proven, not assumed from the state's spelling.
func TestR3_RevalidateRefusesDeferredRebuildStates(t *testing.T) {
	ctx := context.Background()
	for _, s := range []state.InstallState{state.StateRebuildRefusedBusy, state.StateRebuildNotExecuted} {
		dir := t.TempDir()
		writeRevalState(t, dir, s, version.Version)
		log := logging.New(dir+"/installer.log", false)
		cfg := &config{stateDir: dir, revalidate: true}
		rc := runRevalidate(ctx, executor.NewMockExecutor(), newRevalSF(dir), cfg, log)
		if rc == state.ExitCommitted {
			t.Errorf("%s: revalidate returned ExitCommitted — a deferred convergence was laundered into success", s)
		}
		if rc != state.ExitRefused {
			t.Errorf("%s: rc=%d, want ExitRefused(%d)", s, rc, state.ExitRefused)
		}
		got := state.NewStateFile(dir)
		if err := got.Read(); err != nil {
			t.Fatalf("cannot re-read state: %v", err)
		}
		if got.State != s {
			t.Errorf("%s: revalidate rewrote the record to %s — refusal must not mutate it", s, got.State)
		}
	}
}
