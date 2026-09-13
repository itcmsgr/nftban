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
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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

// ─────────────────────────────────────────────────────────────────────────────
// R7 — the persisted contract must be INTERNALLY CONSISTENT
// ─────────────────────────────────────────────────────────────────────────────
// ⛔ NOT "the field is populated". A wrong-but-populated value passes that. These arms
// cross-check the THREE surfaces that disagreed on dns1:
//
//	prose             FAILURE_REASON
//	structured        REBUILD_EXIT_CODE / REBUILD_DURATION_MS
//	installer.log     the observed subprocess line
func TestR7_PersistedRebuildEvidenceIsInternallyConsistent(t *testing.T) {
	// A rebuild that executed, took real time and failed. driveInstall gives us the
	// state file AND the log from the same run, so the three surfaces can be compared
	// against each other rather than each against an expectation.
	r := driveInstall(t, testBudget, rebuildSim{dur: 25 * time.Millisecond, exit: 2})
	r.mustHaveReachedRebuild(t)

	if r.sf.RebuildExitCode != 2 {
		t.Errorf("REBUILD_EXIT_CODE = %d, want the observed 2 (dns1 recorded 0 for a failed rebuild)", r.sf.RebuildExitCode)
	}
	if r.sf.RebuildDurationMs <= 0 {
		t.Errorf("REBUILD_DURATION_MS = %d — a subprocess that occupied real time was recorded as instantaneous", r.sf.RebuildDurationMs)
	}
	// LEG 3: the log must corroborate the structured pair.
	if !r.says("rebuild subprocess observed: exit=2") {
		t.Errorf("installer.log does not carry the observed exit that install_state claims\n%s", r.log)
	}
	// LEG 1 vs LEG 2: whatever the prose asserts must not contradict the fields.
	if c := r.sf.RebuildEvidenceContradiction(); c != "" {
		t.Errorf("persisted record is self-contradictory: %s\nFAILURE_REASON=%s", c, r.sf.FailureReason)
	}
	// And the persisted file — not just the in-memory struct — must agree.
	reread := state.NewStateFile(r.stateDir)
	if err := reread.Read(); err != nil {
		t.Fatalf("cannot re-read install_state: %v", err)
	}
	if reread.RebuildExitCode != r.sf.RebuildExitCode || reread.RebuildDurationMs != r.sf.RebuildDurationMs {
		t.Errorf("on-disk evidence (%d, %d) != in-memory (%d, %d)",
			reread.RebuildExitCode, reread.RebuildDurationMs, r.sf.RebuildExitCode, r.sf.RebuildDurationMs)
	}
	if !reread.RebuildEvidenceUsable() {
		t.Errorf("a correctly written record must not be rejected: %s", reread.RebuildEvidenceRejection())
	}
}

// A successful run must record the measurement too — otherwise history keeps
// inheriting the 1-second fallback for every install.
func TestR7_SuccessAlsoRecordsTheMeasurement(t *testing.T) {
	r := driveInstall(t, testBudget, rebuildSim{dur: 25 * time.Millisecond, exit: 0})
	r.mustHaveReachedRebuild(t)
	if r.sf.RebuildExitCode != 0 {
		t.Errorf("REBUILD_EXIT_CODE = %d, want the observed 0", r.sf.RebuildExitCode)
	}
	if r.sf.RebuildDurationMs <= 0 {
		t.Errorf("REBUILD_DURATION_MS = %d — a 25ms rebuild was recorded as instantaneous", r.sf.RebuildDurationMs)
	}
	if !r.says("rebuild subprocess observed: exit=0") {
		t.Errorf("installer.log does not corroborate the recorded evidence\n%s", r.log)
	}
}

// THE dns1 RECORD ITSELF, replayed byte-for-byte from the forensic quote, must be
// REJECTED rather than read as a clean rebuild.
//
// ⛔ NEGATIVE CONTROL FIRST: the same record with the field populated correctly must be
// ACCEPTED, or the rejection would be indiscriminate rather than a contradiction test.
func TestR7_Dns1ShapedRecordIsRejected(t *testing.T) {
	write := func(t *testing.T, exitLine string) *state.StateFile {
		t.Helper()
		dir := t.TempDir()
		body := "INSTALL_STATE=FAILED_REBUILD\n" +
			"INSTALL_VERSION=1.229.14\n" +
			"PHASE_REACHED=SWITCH\n" +
			"FAILURE_REASON=nftban firewall rebuild produced no usable result contract (exit 1): rebuild result missing\n" +
			exitLine +
			"REBUILD_DURATION_MS=0\n"
		if err := os.WriteFile(filepath.Join(dir, "install_state"), []byte(body), 0o640); err != nil {
			t.Fatal(err)
		}
		sf := state.NewStateFile(dir)
		if err := sf.Read(); err != nil {
			t.Fatalf("a contradictory record must still PARSE — --repair depends on it: %v", err)
		}
		return sf
	}

	bad := write(t, "REBUILD_EXIT_CODE=0\n")
	if bad.RebuildEvidenceUsable() {
		t.Error("the dns1 record asserts exit 1 in prose and 0 in the structured field — it must be rejected")
	}
	if !strings.Contains(bad.RebuildEvidenceRejection(), "REBUILD_EXIT_CODE=0") {
		t.Errorf("the rejection must name what contradicted what; got %q", bad.RebuildEvidenceRejection())
	}
	// ⛔ REJECT, NEVER REPAIR: adopting the prose's 1 would make unstructured text the
	// authority for a structured field.
	if bad.RebuildExitCode != 0 {
		t.Errorf("the rejected field was REWRITTEN to %d — rejection must not repair", bad.RebuildExitCode)
	}
	// The rest of the record stays usable, or --repair could not run on the affected host.
	if bad.State != state.StateFailedRebuild || bad.PhaseReached != "SWITCH" {
		t.Errorf("rejection discarded unrelated fields: state=%s phase=%s", bad.State, bad.PhaseReached)
	}

	good := write(t, "REBUILD_EXIT_CODE=1\n")
	if !good.RebuildEvidenceUsable() {
		t.Errorf("a consistent record must be accepted (non-vacuity); rejected with %q", good.RebuildEvidenceRejection())
	}
}

// A record with no failure prose at all has nothing to contradict.
func TestR7_NoProseNoContradiction(t *testing.T) {
	sf := state.NewStateFile(t.TempDir())
	sf.FailureReason = ""
	sf.RebuildExitCode = 0
	if c := sf.RebuildEvidenceContradiction(); c != "" {
		t.Errorf("a clean record must not be flagged: %s", c)
	}
	// Prose that names exit 0 is not a contradiction either.
	sf.FailureReason = "post-update validator rejected state (exit 0)"
	if c := sf.RebuildEvidenceContradiction(); c != "" {
		t.Errorf("exit 0 in prose beside REBUILD_EXIT_CODE=0 is consistent: %s", c)
	}
}
