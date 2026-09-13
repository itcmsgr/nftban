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
