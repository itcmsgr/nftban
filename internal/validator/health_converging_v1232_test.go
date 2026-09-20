// =============================================================================
// NFTBan - v1.232.0 convergence window must not be reported as IDLE
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="health_converging_v1232_test"
// meta:type="test"
// meta:description="v1.232.0 BUG-HEALTH-CONVERGENCE-WINDOW-REPORTED-AS-IDLE. nftbanconf.ReadEffectiveMode returns (ModeUnknown, BasisConverging) while a mode plan is mid-convergence, but module_health.readEffectiveMode discarded the basis with `_`, so no module could register as active and evaluateOverallStatus fell through to StatusIdle — a positive claim ('all axes pass, no relevant traffic observed') made at the exact moment the mode authority had not settled. Asserts CONVERGING survives basis -> validator -> surface: a module marked ReasonConverging yields StatusConverging instead of StatusIdle; the label renders CONVERGING; the exit code is 0 by an EXPLICIT arm rather than the default arm (which returns 2/DOWN, so a forgotten status would report every reload as no-viable-protection); and DEGRADED/DOWN still outrank a convergence window. Carries the discriminating negative control: the SAME shape with ReasonExpectationUnknown (genuinely unestablished, not converging) must still be IDLE, so the positive arms cannot pass by treating every unknown as converging."
// =============================================================================

package validator

import "testing"

// enforcingResult builds a result whose families all pass and which has no
// findings, so evaluateOverallStatus reaches the PROTECTED/IDLE decision rather
// than short-circuiting on DOWN or DEGRADED.
func convergingTestResult(reason StructuralReason) *ValidationResult {
	return &ValidationResult{
		Families: []FamilyResult{{Status: StatusProtected}},
		Modules: ModuleHealthMap{
			DDoS: &ModuleHealth{
				Config:           ConfigEnabled,
				Structural:       StructuralUnknown,
				StructuralReason: reason,
			},
		},
	}
}

// TestConvergingDoesNotFallThroughToIdle is the defect arm.
func TestConvergingDoesNotFallThroughToIdle(t *testing.T) {
	got := evaluateOverallStatus(convergingTestResult(ReasonConverging))
	if got == StatusIdle {
		t.Fatalf("a convergence window was reported as IDLE — IDLE asserts 'all axes pass, no relevant traffic observed', which is a claim the system cannot make while the mode authority has not settled")
	}
	if got != StatusConverging {
		t.Fatalf("expected StatusConverging, got %q", got)
	}
}

// TestUnestablishedExpectationIsStillIdle is the NEGATIVE CONTROL. Without it,
// an implementation that returned CONVERGING for every unknown would pass the
// arm above while destroying a distinction the operator needs: one unknown
// resolves itself in seconds, the other needs a human.
func TestUnestablishedExpectationIsStillIdle(t *testing.T) {
	got := evaluateOverallStatus(convergingTestResult(ReasonExpectationUnknown))
	if got != StatusIdle {
		t.Fatalf("expected StatusIdle for a genuinely unestablished expectation (not a convergence window), got %q", got)
	}
}

// TestConvergingIsDistinctFromEveryOtherStatus guards the vocabulary itself.
func TestConvergingIsDistinctFromEveryOtherStatus(t *testing.T) {
	for _, other := range []Status{StatusProtected, StatusIdle, StatusDegraded, StatusDown} {
		if StatusConverging == other {
			t.Fatalf("StatusConverging collides with %q", other)
		}
	}
}

// TestConvergingExitCodeIsExplicitlyZero. The switch in ExitCode has
// `default: return 2` (DOWN). A new status that is merely forgotten there would
// turn every routine convergence window into "no viable protection".
func TestConvergingExitCodeIsExplicitlyZero(t *testing.T) {
	r := &ValidationResult{Status: StatusConverging}
	if got := r.ExitCode(); got != 0 {
		t.Fatalf("CONVERGING must be exit 0 (transient, expected); got %d — it is almost certainly falling through to the default DOWN arm", got)
	}
	if got := r.StatusString(); got != "CONVERGING" {
		t.Fatalf("expected label CONVERGING, got %q", got)
	}
}

// TestRealFaultsOutrankConvergence — a convergence window must never mask an
// actual fault. DEGRADED and DOWN are decided before the fall-through.
func TestRealFaultsOutrankConvergence(t *testing.T) {
	degraded := convergingTestResult(ReasonConverging)
	degraded.Findings = []Finding{{Severity: SeverityError}}
	if got := evaluateOverallStatus(degraded); got != StatusDegraded {
		t.Fatalf("an error finding must still yield DEGRADED during a convergence window, got %q", got)
	}

	down := convergingTestResult(ReasonConverging)
	down.Findings = []Finding{{Severity: SeverityCritical}}
	if got := evaluateOverallStatus(down); got != StatusDown {
		t.Fatalf("a critical finding must still yield DOWN during a convergence window, got %q", got)
	}
}

// TestActiveModuleStillReportsProtected — if protection demonstrably exists,
// PROTECTED is the truthful answer and CONVERGING would understate it.
func TestActiveModuleStillReportsProtected(t *testing.T) {
	r := convergingTestResult(ReasonConverging)
	r.Modules.LoginMon = &ModuleHealth{Config: ConfigEnabled, Effective: EffectiveEnforcing}
	if got := evaluateOverallStatus(r); got != StatusProtected {
		t.Fatalf("an enforcing module must still yield PROTECTED, got %q", got)
	}
}
