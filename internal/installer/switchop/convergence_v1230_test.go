// =============================================================================
// NFTBan v1.230.0 Gate 6R — convergence verifier legs
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-switchop-convergence-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-13"
// meta:description="Per-leg acceptance for VerifyPostUpdateConvergence: an unadvanced effective generation falsifies a COMPLETE claim, an nft -c rejection falsifies the projection, an unobservable leg yields UNVERIFIED rather than a manufactured pass or failure, and a deferred rebuild is never reported as verified."
// meta:inventory.files="internal/installer/switchop/convergence_v1230_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package switchop

import (
	"errors"
	"os"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

func convergedHost() *executor.MockExecutor {
	m := executor.NewMockExecutor()
	m.Files[BootProjectionPath] = []byte("table ip nftban {\n}\n")
	m.Files[ConvergenceGenerationPath] = []byte("8\n")
	m.NftTables["ip:nftban"] = true
	m.NftTables["ip6:nftban"] = true
	return m
}

func completedApply() ConvergenceInputs {
	return ConvergenceInputs{ProjectionGenerated: true, ApplyClaimedComplete: true, GenerationBefore: 7}
}

func TestConvergence_HappyPath(t *testing.T) {
	got := VerifyPostUpdateConvergence(convergedHost(), newTestLogger(), completedApply())
	if got.Verdict != ConvergenceVerified {
		t.Fatalf("verdict = %s, want VERIFIED (legs: %s)", got.Verdict, strings.Join(got.Legs, " | "))
	}
	// The package leg must be DECLARED unevaluated, never quietly counted as passing.
	if !strings.Contains(strings.Join(got.Legs, " | "), "NOT_EVALUATED package_correct") {
		t.Error("the package leg must be declared not-evaluated")
	}
}

// ⛔ THE CLAIM IS NOT THE VERIFICATION. Everything the rebuild reports stays identical;
// only the counter written by a DIFFERENT function fails to move.
func TestConvergence_CompleteClaimWithoutGenerationAdvance_Fails(t *testing.T) {
	m := convergedHost()
	m.Files[ConvergenceGenerationPath] = []byte("7\n") // unchanged
	got := VerifyPostUpdateConvergence(m, newTestLogger(), completedApply())
	if got.Verdict != ConvergenceNotConverged {
		t.Fatalf("verdict = %s, want NOT_CONVERGED", got.Verdict)
	}
	if !strings.Contains(got.Detail, "did NOT advance") {
		t.Errorf("detail must name the unadvanced generation; got %q", got.Detail)
	}
}

func TestConvergence_ProjectionRejectedByNftCheck_Fails(t *testing.T) {
	m := convergedHost()
	m.NftCheckErr = errors.New("syntax error")
	got := VerifyPostUpdateConvergence(m, newTestLogger(), completedApply())
	if got.Verdict != ConvergenceNotConverged {
		t.Fatalf("verdict = %s, want NOT_CONVERGED for a projection nft -c rejects", got.Verdict)
	}
	if !strings.Contains(strings.Join(got.Legs, " | "), "FAIL projection_valid") {
		t.Error("the failing leg must be named")
	}
}

func TestConvergence_ProjectionNotEstablishedInThisRun_Fails(t *testing.T) {
	in := completedApply()
	in.ProjectionGenerated = false
	got := VerifyPostUpdateConvergence(convergedHost(), newTestLogger(), in)
	if got.Verdict != ConvergenceNotConverged {
		t.Fatalf("verdict = %s, want NOT_CONVERGED", got.Verdict)
	}
	// ⛔ The file EXISTS in this fixture. Existence must not have rescued the leg.
	if !strings.Contains(strings.Join(got.Legs, " | "), "FAIL projection_generated") {
		t.Error("a projection that exists on disk from an earlier run must not satisfy this leg")
	}
}

// T6 shape at unit level: nothing claimed success and nothing converged.
func TestConvergence_NothingConverged_Fails(t *testing.T) {
	m := convergedHost()
	m.Files[ConvergenceGenerationPath] = []byte("7\n")
	got := VerifyPostUpdateConvergence(m, newTestLogger(), ConvergenceInputs{
		ProjectionGenerated: true, ApplyClaimedComplete: false, GenerationBefore: 7,
	})
	if got.Verdict != ConvergenceNotConverged {
		t.Fatalf("verdict = %s, want NOT_CONVERGED", got.Verdict)
	}
	// Detail names the FIRST failing leg (apply_confirmed here); the generation leg must
	// still state the T6 conclusion in its own words.
	if !strings.Contains(strings.Join(got.Legs, " | "), "INCOMPLETE") {
		t.Errorf("the update must be described as INCOMPLETE; legs: %s", strings.Join(got.Legs, " | "))
	}
}

// ⛔ ABSENCE OF EVIDENCE IS NEITHER A PASS NOR A FAILURE.
func TestConvergence_UnobservableGeneration_IsUnverified(t *testing.T) {
	m := convergedHost()
	delete(m.Files, ConvergenceGenerationPath)
	in := completedApply()
	in.GenerationBefore = -1
	got := VerifyPostUpdateConvergence(m, newTestLogger(), in)
	if got.Verdict != ConvergenceUnverified {
		t.Fatalf("verdict = %s, want UNVERIFIED when the counter cannot be read", got.Verdict)
	}
	if got.Verdict == ConvergenceVerified {
		t.Error("an unobservable leg must never be reported as verified")
	}
}

// A counter that appears during the run IS an advance — it moved from "no recorded
// convergence" to a recorded one. ⛔ Distinct from "unreadable afterwards".
func TestConvergence_CounterAppearsDuringRun_IsAnAdvance(t *testing.T) {
	in := completedApply()
	in.GenerationBefore = -1
	if got := VerifyPostUpdateConvergence(convergedHost(), newTestLogger(), in); got.Verdict != ConvergenceVerified {
		t.Fatalf("verdict = %s, want VERIFIED", got.Verdict)
	}
}

func TestConvergence_DeferredIsNotVerified(t *testing.T) {
	m := convergedHost()
	m.Files[ConvergenceGenerationPath] = []byte("7\n") // deferred does not advance it
	got := VerifyPostUpdateConvergence(m, newTestLogger(), ConvergenceInputs{
		ProjectionGenerated: true, ApplyDeferred: true, GenerationBefore: 7,
	})
	if got.Verdict != ConvergenceDeferred {
		t.Fatalf("verdict = %s, want DEFERRED", got.Verdict)
	}
	if got.Verdict == ConvergenceVerified {
		t.Error("a deferred convergence must never be reported as verified")
	}
}

// A positive failure must dominate DEFERRED — a deferral does not soften a broken
// projection.
func TestConvergence_FailureDominatesDeferred(t *testing.T) {
	m := convergedHost()
	m.NftCheckErr = errors.New("syntax error")
	got := VerifyPostUpdateConvergence(m, newTestLogger(), ConvergenceInputs{
		ProjectionGenerated: true, ApplyDeferred: true, GenerationBefore: 7,
	})
	if got.Verdict != ConvergenceNotConverged {
		t.Fatalf("verdict = %s, want NOT_CONVERGED", got.Verdict)
	}
}

// ⛔ -1 IS NOT ZERO. An unreadable counter must not be differenced into a conclusion.
func TestReadConvergenceGeneration_UnreadableIsMinusOne(t *testing.T) {
	m := executor.NewMockExecutor()
	if got := ReadConvergenceGeneration(m); got != -1 {
		t.Errorf("absent counter = %d, want -1 (ENOENT != generation 0 for this comparison)", got)
	}
	m.Files[ConvergenceGenerationPath] = []byte("not-a-number\n")
	if got := ReadConvergenceGeneration(m); got != -1 {
		t.Errorf("malformed counter = %d, want -1", got)
	}
	m.Files[ConvergenceGenerationPath] = []byte(" 12 \n")
	if got := ReadConvergenceGeneration(m); got != 12 {
		t.Errorf("counter = %d, want 12", got)
	}
}

// ⛔ THE PROJECTION IS NOT THE RETIRED LEGACY INCLUDE.
func TestConvergence_ProjectionPathIsTheGeneratedArtifact(t *testing.T) {
	if BootProjectionPath != "/etc/nftban/generated/nftban-boot.nft" {
		t.Errorf("BootProjectionPath = %q — the boot authority is the generated projection", BootProjectionPath)
	}
	if strings.HasSuffix(BootProjectionPath, "/etc/nftban/nftables.conf") {
		t.Error("/etc/nftban/nftables.conf is the RETIRED legacy include, not the boot authority")
	}
}

// =============================================================================
// OWNER RULING (v1.230.0) — DEFERRED_RUNTIME MAY REACH COMMITTED, NEVER PROVES IT
// =============================================================================
// Pins for the ruling documented in convergence.go and at the top of
// internal/installer/state/machine.go. Each arm asserts a consequence that a
// "simplification" in EITHER direction would have to break.

// ⛔ THE STRONGEST ARM. An otherwise PERFECT deferred run — projection generated,
// nft -c clean, kernel tables present, AND a generation counter that advanced —
// still must not be reported as VERIFIED.
//
// A future reader who deletes the DEFERRED-dominance rule as "redundant, every leg
// passed anyway" breaks exactly here. The deferral asserts the module projection has
// not happened yet; no amount of surrounding green converts that into proof.
func TestRuling_DeferredNeverVerifiedEvenWhenEveryLegPasses(t *testing.T) {
	m := convergedHost() // generation 8 vs GenerationBefore 7 => genAdvanced
	got := VerifyPostUpdateConvergence(m, newTestLogger(), ConvergenceInputs{
		ProjectionGenerated: true, ApplyDeferred: true, GenerationBefore: 7,
	})
	if got.Verdict == ConvergenceVerified {
		t.Fatalf("a DEFERRED_RUNTIME rebuild was reported VERIFIED (legs: %s) — "+
			"DEFERRED_RUNTIME is a permitted INTERMEDIATE disposition, never proof of success",
			strings.Join(got.Legs, " | "))
	}
	if got.Verdict != ConvergenceDeferred {
		t.Fatalf("verdict = %s, want DEFERRED", got.Verdict)
	}
}

// ⛔ AND THE OPPOSITE SIMPLIFICATION IS EQUALLY FORBIDDEN. Turning the deferral into a
// failure re-introduces v1.229.12 P12-A01 — escalating an EXPECTED pre-daemon deferral
// — on every upgrade. DEFERRED must stay its own verdict, distinct from NOT_CONVERGED.
func TestRuling_DeferredIsNotEscalatedToNotConverged(t *testing.T) {
	m := convergedHost()
	m.Files[ConvergenceGenerationPath] = []byte("7\n") // a deferral does not advance it
	got := VerifyPostUpdateConvergence(m, newTestLogger(), ConvergenceInputs{
		ProjectionGenerated: true, ApplyDeferred: true, GenerationBefore: 7,
	})
	if got.Verdict == ConvergenceNotConverged {
		t.Fatalf("an EXPECTED deferral was escalated to NOT_CONVERGED — that is the "+
			"v1.229.12 P12-A01 defect, re-committed for every upgrade (legs: %s)",
			strings.Join(got.Legs, " | "))
	}
	if got.Verdict != ConvergenceDeferred {
		t.Fatalf("verdict = %s, want DEFERRED", got.Verdict)
	}
	// The four verdicts must stay four distinct tokens: a collapse shows up here first.
	seen := map[ConvergenceVerdict]bool{}
	for _, v := range []ConvergenceVerdict{
		ConvergenceVerified, ConvergenceNotConverged, ConvergenceDeferred, ConvergenceUnverified,
	} {
		if seen[v] {
			t.Errorf("convergence verdict %q is duplicated — the four classes have been collapsed", v)
		}
		seen[v] = true
	}
}

// The disposition -> installer-policy map, pinned whole. This is the table that
// decides which rebuild outcomes may continue at all.
//
//	COMPLETE          -> CONTINUE_COMPLETE   (eligible for COMMITTED)
//	DEFERRED_RUNTIME  -> CONTINUE_DEFERRED   (permitted to continue; NOT success)
//	REFUSED           -> RETRY_REFUSED       (nothing ran; retry, never COMMITTED here)
//	REGRESSION/FATAL  -> ABORT
//	unknown           -> ABORT               (⛔ schema evolution defaults to safe)
func TestRuling_DispositionToContinuationMap(t *testing.T) {
	for _, c := range []struct {
		disp RebuildDisposition
		want InstallerContinuation
	}{
		{DispositionComplete, ContinueComplete},
		{DispositionDeferredRuntime, ContinueDeferred},
		{DispositionRefused, RetryRefused},
		{DispositionRegression, Abort},
		{DispositionFatal, Abort},
		{RebuildDisposition("NOT_EXECUTED"), Abort},
		{RebuildDisposition(""), Abort},
		{RebuildDisposition("FUTURE_DISPOSITION_XYZ"), Abort},
	} {
		r := &RebuildResult{Disposition: c.disp}
		if got := r.Continuation(); got != c.want {
			t.Errorf("disposition %q -> %s, want %s", c.disp, got, c.want)
		}
	}
	// ⛔ CONTINUE_DEFERRED IS NOT CONTINUE_COMPLETE. If these ever compare equal, a
	// caller switching on the continuation can no longer tell a deferral from a success.
	if ContinueDeferred == ContinueComplete {
		t.Error("CONTINUE_DEFERRED and CONTINUE_COMPLETE have been collapsed into one value")
	}
}

// STRUCTURAL guard: the ruling must stay written where the disposition is interpreted.
// ⛔ Sentences, never a line number — line numbers drift and a guard located by one is
// invalid in this repository.
func TestRuling_ConvergenceDocumentsTheOwnerRuling(t *testing.T) {
	src, err := os.ReadFile("convergence.go")
	if err != nil {
		t.Fatalf("cannot read convergence.go: %v", err)
	}
	for _, want := range []string{
		"`DEFERRED_RUNTIME == success`",
		"IS INCORRECT AND MUST NOT BE SIMPLIFIED INTO THAT",
		"PERMITTED INTERMEDIATE DISPOSITION",
		"NEVER COMMITTED",
		"P12-A01",
	} {
		if !strings.Contains(string(src), want) {
			t.Errorf("convergence.go no longer documents the owner ruling: missing %q", want)
		}
	}
}
