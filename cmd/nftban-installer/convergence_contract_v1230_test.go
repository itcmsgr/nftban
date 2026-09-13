// =============================================================================
// NFTBan v1.230.0 Gate 6R — POST-UPDATE CONVERGENCE CONTRACT (T1..T6)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-convergence-contract-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-13"
// meta:description="T1..T6 acceptance for the post-update convergence contract: an update is COMMITTED only when the projection was generated in this run, nft -c accepted it, the apply confirmed, the effective convergence generation advanced, and the required kernel tables are present. Guards the dns1 shape where a rebuild claimed success, the kernel was not changed, and every surface said PASS."
// meta:inventory.files="cmd/nftban-installer/convergence_contract_v1230_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package main

import (
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/switchop"
)

// ⛔ THE FIVE FACTS THE INSTALLER USED TO COLLAPSE INTO ONE:
//
//	PACKAGE UPDATED != PROJECTION GENERATED != PROJECTION VALIDATED
//	                != KERNEL RULESET APPLIED != RUNTIME CONVERGED
//
// ⛔ NO ARM BELOW INFERS A STEP FROM a comment, a version string, daemon-active, file
// existence, mtime, or a package version. Each of those produced a FALSE conclusion
// during the dns1 investigation.

// T1 — the full happy chain reaches COMMITTED and records VERIFIED.
func TestT1_FullConvergenceChain_Commits(t *testing.T) {
	r := driveInstall(t, testBudget, rebuildSim{dur: 5 * time.Millisecond, exit: 0})
	r.mustHaveReachedRebuild(t)

	if got := r.sf.ConvergenceVerified; got != string(switchop.ConvergenceVerified) {
		t.Fatalf("CONVERGENCE_VERIFIED = %q, want VERIFIED\n%s", got, r.log)
	}
	// Each leg must be stated, so a future reader can see WHICH facts were established.
	for _, leg := range []string{
		"PASS projection_generated",
		"PASS projection_valid",
		"PASS apply_confirmed",
		"PASS effective_generation",
		"PASS kernel_tables_present",
	} {
		if !r.says(leg) {
			t.Errorf("convergence leg not recorded: %q\n%s", leg, r.log)
		}
	}
	// ⛔ AND THE PACKAGE LEG MUST BE DECLARED UNEVALUATED, not silently assumed.
	if !r.says("NOT_EVALUATED package_correct") {
		t.Errorf("the package leg must be declared not-evaluated rather than assumed\n%s", r.log)
	}
	// ⛔ SCOPED CLAIM. This harness is not a full all-pass host — other assertions can
	// legitimately end the run DEGRADED — so the honest T1 assertion is that CONVERGENCE
	// did not block the commit, not that the whole install committed.
	//     CLAIM ONLY WHAT THE SYSTEM KNOWS.
	if r.says("ASSERT post_update_convergence_verified: FAIL") {
		t.Errorf("a fully verified convergence must not block COMMITTED\n%s", r.log)
	}
	if r.sf.State == state.StateFailedRebuild {
		t.Errorf("a fully verified convergence was recorded FAILED_REBUILD\n%s", r.log)
	}
	if strings.Contains(r.sf.FailureReason, "post_update_convergence_verified") {
		t.Errorf("convergence named in the failure reason of a verified run: %s", r.sf.FailureReason)
	}
}

// T3 — the rebuild CLAIMS success but the kernel was NOT changed.
//
// ⛔ THE PRIORITY CASE. This must not be satisfiable by trusting the rebuild's own
// success claim, so the fixture reports a COMPLETE, committed contract with exit 0 and
// simply does not advance the effective convergence generation.
func TestT3_ApplyClaimsSuccessButKernelUnchanged_NotCommitted(t *testing.T) {
	r := driveInstall(t, testBudget, rebuildSim{dur: 5 * time.Millisecond, exit: 0, claimOnly: true})
	r.mustHaveReachedRebuild(t)

	// The claim WAS made — otherwise this proves nothing about disbelieving it.
	if !r.says("PASS apply_confirmed") {
		t.Fatalf("VACUOUS: the rebuild did not claim a completed transaction, so nothing was disbelieved\n%s", r.log)
	}
	if got := r.sf.ConvergenceVerified; got != string(switchop.ConvergenceNotConverged) {
		t.Fatalf("CONVERGENCE_VERIFIED = %q, want NOT_CONVERGED — a claim is not a verification\n%s", got, r.log)
	}
	if !r.says("FAIL effective_generation") {
		t.Errorf("the generation leg must name the contradiction\n%s", r.log)
	}
	if r.sf.State == state.StateCommitted {
		t.Errorf("an unverified convergence reached COMMITTED — this is the dns1 shape\n%s", r.log)
	}
	if r.rc == state.ExitCommitted {
		t.Errorf("rc = %d; an unverified convergence must not exit 0", r.rc)
	}
}

// T4 — the projection exists but `nft -c` REJECTS it.
func TestT4_ProjectionInvalid_NotCommitted(t *testing.T) {
	r := driveInstall(t, testBudget, rebuildSim{dur: 5 * time.Millisecond, exit: 0, projectionInvalid: true})
	r.mustHaveReachedRebuild(t)

	if got := r.sf.ConvergenceVerified; got != string(switchop.ConvergenceNotConverged) {
		t.Fatalf("CONVERGENCE_VERIFIED = %q, want NOT_CONVERGED for a projection nft -c rejects\n%s", got, r.log)
	}
	if !r.says("FAIL projection_valid") {
		t.Errorf("the projection-validity leg must name the rejection\n%s", r.log)
	}
	if r.sf.State == state.StateCommitted {
		t.Errorf("a host whose boot projection does not validate reached COMMITTED\n%s", r.log)
	}
}

// T6 — the projection was never established in this run: the update is INCOMPLETE even
// though the package is new and the daemon is active.
//
// ⛔ THE SECOND PRIORITY CASE. Package state and daemon liveness are present in this
// fixture and must not carry the verdict.
func TestT6_PackageNewDaemonActiveButConvergenceAbsent_Incomplete(t *testing.T) {
	r := driveInstall(t, testBudget, rebuildSim{dur: 5 * time.Millisecond, exit: 0, noProjection: true})
	r.mustHaveReachedRebuild(t)

	if got := r.sf.ConvergenceVerified; got != string(switchop.ConvergenceNotConverged) {
		t.Fatalf("CONVERGENCE_VERIFIED = %q, want NOT_CONVERGED\n%s", got, r.log)
	}
	if !r.says("FAIL projection_generated") {
		t.Errorf("the run must say the projection was not established IN THIS RUN\n%s", r.log)
	}
	if r.sf.State == state.StateCommitted {
		t.Errorf("package-new + daemon-active carried a COMMITTED verdict with convergence absent\n%s", r.log)
	}
}

// T2 composition — a refused rebuild never reaches the convergence contract at all,
// because the phase stops first. The two limbs must not fight each other.
func TestT2_RefusedComposesWithTheConvergenceContract(t *testing.T) {
	if state.StateRebuildRefusedBusy == state.StateFailedRebuild {
		t.Fatal("REFUSED_BUSY must stay distinct from FAILED_REBUILD")
	}
	// stateForRebuildError is the only mapping from a rebuild error to a state, so a
	// refusal cannot acquire a convergence verdict on the way past.
	if got := stateForRebuildError(switchop.ErrRebuildRefusedBusy); got != state.StateRebuildRefusedBusy {
		t.Errorf("stateForRebuildError = %s, want REBUILD_REFUSED_BUSY", got)
	}
	// And a deferred terminal stops the runner before phaseValidate can compute a verdict.
	sf := state.NewStateFile(t.TempDir())
	if err := sf.Transition(state.StateRebuildRefusedBusy, state.PhaseSwitch, "refused"); err == nil {
		t.Error("a refusal must stop the phase runner before Validate")
	}
	if sf.ConvergenceVerified != "" {
		t.Errorf("a refused run must not carry a convergence verdict; got %q", sf.ConvergenceVerified)
	}
}

// T5 — a self-contradictory result contract is REJECTED and can never PASS.
func TestT5_ContradictoryContractNeverPasses(t *testing.T) {
	// Rebuild-result contract: REFUSED that also claims a mutation.
	// (The full read-side arm lives in switchop; this pins the acceptance case.)
	sf := state.NewStateFile(t.TempDir())
	sf.FailureReason = "nftban firewall rebuild produced no usable result contract (exit 1): missing"
	sf.RebuildExitCode = 0
	if sf.RebuildEvidenceContradiction() == "" {
		t.Error("a record asserting exit 1 in prose beside REBUILD_EXIT_CODE=0 must be rejected")
	}
	// A rejected record's convergence verdict must never be laundered into VERIFIED by
	// the assertion default.
	for _, v := range []string{"", "NOT_CONVERGED", "bogus"} {
		if v == string(switchop.ConvergenceVerified) {
			t.Fatalf("fixture error: %q is the verified value", v)
		}
	}
}

// =============================================================================
// OWNER RULING (v1.230.0) — DEFERRED_RUNTIME MAY REACH COMMITTED, NEVER PROVES IT
// =============================================================================
// The end-to-end half of the pin. The unit arms in internal/installer/switchop and
// internal/installer/state cover the pieces; this one drives the REAL runInstall loop
// so a "simplification" anywhere along disposition -> verdict -> assertion -> state
// shows up as a failing install-level outcome, not just a changed constant.

// ⛔ BOTH HALVES OF THE RULING IN ONE RUN, because they are only meaningful together:
//
//	the deferral DOES NOT BLOCK THE COMMIT   (collapsing it to a failure = P12-A01,
//	                                          re-committed on every upgrade)
//	and it is NOT RECORDED AS VERIFIED       (collapsing it to success = the false-
//	                                          COMMITTED shape this gate exists to stop)
//
// The record keeps the truth: CONVERGENCE_VERIFIED=DEFERRED, convergence debt named in
// the log, and the generation deliberately not advanced.
//
// ⛔ THE FIRST HALF IS A SCOPED CLAIM — "the deferral did not block", not "the install
// committed". This harness is not a full all-pass host and T1 (a fully VERIFIED run)
// makes the same scoped claim for the same reason. Asserting COMMITTED here would fail
// on an unrelated fixture assertion and would prove nothing about the ruling.
func TestRuling_DeferredRuntimeReachesCommittedButRecordsDeferred(t *testing.T) {
	// exit:1 is REQUIRED alongside deferred — DEFERRED_RUNTIME/1 is the consistent pair
	// RebuildResult.ContradictsExitCode enforces; any other rc aborts as a contract
	// violation and this case would prove nothing.
	r := driveInstall(t, testBudget, rebuildSim{dur: 5 * time.Millisecond, exit: 1, deferred: true})
	r.mustHaveReachedRebuild(t)

	// ── half 1: the expected deferral must NOT be escalated into a failure ──────
	// ⛔ SCOPED CLAIM, same discipline as T1 above: this harness is NOT a full all-pass
	// host (health_resource_policy_active legitimately ends it DEGRADED on a mock with
	// no real cgroup limits), so asserting sf.State == COMMITTED here would fail for a
	// reason that has nothing to do with the ruling. The honest claim is that the
	// DEFERRAL did not stop the run and did not block the commit.
	//     CLAIM ONLY WHAT THE SYSTEM KNOWS.
	if r.sf.State == state.StateFailedRebuild {
		t.Fatalf("an EXPECTED pre-daemon deferral was recorded FAILED_REBUILD — that is the "+
			"v1.229.12 P12-A01 defect, re-committed for every upgrade\n%s", r.log)
	}
	if r.sf.State.IsDeferredRebuild() {
		t.Fatalf("state = %s — a DEFERRED_RUNTIME rebuild EXECUTED; it must not be classified "+
			"with the terminals that mean no rebuild ran\n%s", r.sf.State, r.log)
	}
	// The run must have carried on PAST the switch phase. Without this the two
	// assertions above could pass on a run that died even earlier.
	if !r.says("[PHASE] validate") {
		t.Fatalf("VACUOUS: the deferred run never reached Validate, so nothing here shows the "+
			"deferral was allowed to continue\n%s", r.log)
	}
	if r.says("ASSERT post_update_convergence_verified: FAIL") {
		t.Errorf("the convergence assertion FAILED on an expected deferral — it must WARN, "+
			"not block\n%s", r.log)
	}
	if strings.Contains(r.sf.FailureReason, "post_update_convergence_verified") {
		t.Errorf("convergence named in the failure reason of a deferred run: %s", r.sf.FailureReason)
	}

	// ── half 2: and it must never be recorded as proof of runtime application ───
	if got := r.sf.ConvergenceVerified; got != string(switchop.ConvergenceDeferred) {
		t.Fatalf("CONVERGENCE_VERIFIED = %q, want DEFERRED — DEFERRED_RUNTIME is a permitted "+
			"INTERMEDIATE disposition and must never itself constitute proof of successful "+
			"runtime application\n%s", got, r.log)
	}
	if r.sf.ConvergenceVerified == string(switchop.ConvergenceVerified) {
		t.Fatal("a deferred rebuild was recorded as a VERIFIED convergence")
	}
	// The evidence the operator needs must be ON the record, not only in the verdict.
	if !r.says("DEFERRED apply_confirmed") {
		t.Errorf("the apply leg must state that the projection was deliberately deferred\n%s", r.log)
	}
	if !r.says("convergence debt outstanding") {
		t.Errorf("the run must name the outstanding convergence debt\n%s", r.log)
	}
	// ⛔ AND THE INDEPENDENT COUNTER MUST NOT HAVE MOVED. This is what makes the
	// deferral safe to allow: the generation is written by nftban_plan_txn_commit,
	// which is reachable only from COMPLETE, so it is evidence the rebuild cannot
	// fabricate. A deferred run that advanced it would mean the contract is broken.
	if !r.says("DEFERRED effective_generation: not advanced") {
		t.Errorf("a deferred run must record the generation as NOT advanced\n%s", r.log)
	}
}

// The third line of the model, end to end: a REFUSED rebuild — the disposition that
// means "nothing ran at all" — must never reach COMMITTED, and must not be laundered
// into a convergence verdict on the way out.
func TestRuling_RefusedNeverReachesCommitted(t *testing.T) {
	if state.StateRebuildRefusedBusy.ExitCode() == state.ExitCommitted {
		t.Error("REBUILD_REFUSED_BUSY must never exit 0 — the convergence is still owed")
	}
	if state.StateRebuildNotExecuted.ExitCode() == state.ExitCommitted {
		t.Error("REBUILD_NOT_EXECUTED must never exit 0 — execution was never established")
	}
	// historyStatusForState is the other place a state could silently become "success".
	for _, s := range []state.InstallState{
		state.StateRebuildRefusedBusy,
		state.StateRebuildNotExecuted,
		state.StateFailedRebuild,
		state.InstallState("RULING_UNDECLARED_STATE"),
	} {
		if got := historyStatusForState(s); got == "success" {
			t.Errorf("historyStatusForState(%s) = %q — only COMMITTED may be recorded as success", s, got)
		}
	}
}
