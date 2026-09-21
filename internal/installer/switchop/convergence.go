// =============================================================================
// NFTBan v1.230.0 Gate 6R — POST-UPDATE CONVERGENCE CONTRACT
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-switchop-convergence"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-13"
// meta:description="Verifies END-TO-END nftables convergence after the switch phase, independently of the rebuild's own success claim. Establishes projection validity, an observed advance of the effective convergence generation, and presence of the required kernel tables; produces the CONVERGENCE_VERIFIED verdict that gates COMMITTED."
// meta:inventory.files="internal/installer/switchop/convergence.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/etc/nftban/generated/nftban-boot.nft"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package switchop

import (
	"fmt"
	"strconv"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// ═════════════════════════════════════════════════════════════════════════════════
// WHY THIS EXISTS
// ═════════════════════════════════════════════════════════════════════════════════
// The installer validated PACKAGE/UPDATE success without ever proving end-to-end
// nftables convergence, and collapsed five distinct facts into one:
//
//	PACKAGE UPDATED != PROJECTION GENERATED != PROJECTION VALIDATED
//	                != KERNEL RULESET APPLIED != RUNTIME CONVERGED
//
// ⛔ WORDING THE EVIDENCE FORCED. The final dns1 evidence DISPROVED the earlier claim
// that the host was running an old version or an old schema. It was not. The defect is
// narrower and worse: convergence was never PROVEN. "Not proven" is the finding; "wrong
// ruleset loaded" was retracted.
//
// ⛔ NOTHING HERE INFERS A STEP FROM: a comment, a version string, daemon-active, file
// existence, mtime, or a package version. Every one of those produced a FALSE conclusion
// during the incident:
//   - the `v1.228.6` string in the live ruleset is a SET COMMENT that also ships in
//     v1.229.14 — it carries zero version information;
//   - /etc/nftban/nftables.conf is a RETIRED legacy include (render/sysconf.go), NOT the
//     boot authority — the projection is /etc/nftban/generated/nftban-boot.nft;
//   - dpkg preserves package build mtimes, so a file's mtime says nothing about when it
//     was installed, and a publication path may legitimately no-op on a byte-identical
//     candidate.
//
// The one leg that makes this more than a restatement of the rebuild's own report is the
// EFFECTIVE CONVERGENCE GENERATION. In the shell, /run/nftban/convergence-generation is
// written by exactly one function, nftban_plan_txn_commit (module_authority.sh), and the
// rebuild reaches that commit ONLY from disposition COMPLETE — cmd_firewall.sh asserts
// that structurally before committing. So:
//
//	disposition COMPLETE  ==>  the generation MUST have advanced.
//
// Reading the counter before and after therefore TESTS THE CLAIM AGAINST A FACT WRITTEN
// BY A DIFFERENT FUNCTION. A rebuild that reports success while the kernel was not
// changed cannot satisfy it.
//
//	⛔ A COMPONENT'S OWN SUCCESS CLAIM IS NOT VERIFICATION OF THAT CLAIM.

// ═════════════════════════════════════════════════════════════════════════════════
// OWNER RULING (v1.230.0) — DEFERRED_RUNTIME MAY REACH COMMITTED, BUT NEVER PROVES IT
// ═════════════════════════════════════════════════════════════════════════════════
// This file is where the rebuild's disposition is INTERPRETED into a convergence
// verdict, so the ruling is restated here at the point of interpretation.
//
// ⛔ `DEFERRED_RUNTIME == success` IS INCORRECT AND MUST NOT BE SIMPLIFIED INTO THAT.
// It is a PERMITTED INTERMEDIATE DISPOSITION, not proof of successful runtime
// application. ApplyDeferred is an INPUT to this verifier; it is never a verdict.
//
//	COMPLETE                            -> eligible for COMMITTED
//	DEFERRED_RUNTIME                    -> eligible for COMMITTED ONLY when the
//	                                       deferral is explicitly EXPECTED AND the
//	                                       post-start convergence contract proves the
//	                                       runtime converged
//	REFUSED / NOT_EXECUTED / FAILED
//	  / unknown                         -> NEVER COMMITTED
//
// ⛔ DO NOT "SIMPLIFY" IN EITHER DIRECTION:
//   - making ApplyDeferred a fail() call re-introduces v1.229.12 P12-A01 (escalating
//     an EXPECTED pre-daemon deferral into a fatal outcome) on every upgrade;
//   - making it a pass() call — or deleting the ConvergenceDeferred verdict and
//     letting a deferred run fall through as ConvergenceVerified — asserts a runtime
//     convergence that demonstrably did not happen.
//
// The dominance rule at the end of VerifyPostUpdateConvergence is the mechanism that
// keeps both errors out: a deferred run can never be VERIFIED, and a deferral can
// never soften a positive failure.
//
// Pinned by the Ruling-1 arms in convergence_v1230_test.go.
// ═════════════════════════════════════════════════════════════════════════════════

// BootProjectionPath is the boot projection the include authority points at.
// ⛔ NOT /etc/nftban/nftables.conf — that is the retired legacy include.
const BootProjectionPath = "/etc/nftban/generated/nftban-boot.nft"

// ConvergenceGenerationPath is the effective convergence generation counter.
// Canonical value of NFTBAN_PLAN_GENERATION_FILE (lib/module_authority.sh). tmpfs, so
// it resets at boot; only the BEFORE/AFTER DELTA within one run is read here, never the
// absolute value.
const ConvergenceGenerationPath = "/run/nftban/convergence-generation"

// ConvergenceVerdict is the installer's post-update convergence conclusion.
type ConvergenceVerdict string

const (
	// ConvergenceVerified — every evaluated leg passed. The only value that may
	// support COMMITTED.
	ConvergenceVerified ConvergenceVerdict = "VERIFIED"
	// ConvergenceNotConverged — a leg POSITIVELY FAILED. T3/T4/T6.
	ConvergenceNotConverged ConvergenceVerdict = "NOT_CONVERGED"
	// ConvergenceDeferred — the rebuild deliberately deferred its module projection
	// (DEFERRED_RUNTIME), so the generation was intentionally not advanced. Convergence
	// debt is outstanding; this is NOT a verified convergence.
	//
	// ⛔ THIS VERDICT IS THE RULING MADE MACHINE-READABLE. It exists so a deferral can
	// be carried forward as an INTERMEDIATE DISPOSITION without ever being spelled
	// VERIFIED. Deleting it — or folding it into ConvergenceVerified because "the run
	// was clean otherwise" — is exactly the simplification the owner ruling forbids.
	ConvergenceDeferred ConvergenceVerdict = "DEFERRED"
	// ConvergenceUnverified — a leg could not be OBSERVED at all. ⛔ Not a pass and not
	// a failure: an unobservable leg is an absence of evidence, and manufacturing either
	// verdict from it is the error this whole gate exists to remove.
	ConvergenceUnverified ConvergenceVerdict = "UNVERIFIED"

	// ConvergenceNotEvaluated — v1.232.2. This transaction PATH does not evaluate
	// convergence at all; the contract was never run.
	//
	// ⛔ DISTINCT FROM ITS NEIGHBOURS, and the distinction is the point:
	//	NOT_CONVERGED  the contract RAN and a leg FAILED
	//	UNVERIFIED     the contract RAN but a leg could not be OBSERVED
	//	NOT_EVALUATED  the contract NEVER RAN for this caller
	//
	// It replaces the EMPTY string for this condition. Empty means "someone forgot
	// to establish a verdict", which is exactly how a COMMITTED-without-proof state
	// became representable; a value that cannot express intent cannot be enforced.
	// A state carrying this verdict must terminate as APPLIED_UNVERIFIED, never
	// COMMITTED.
	ConvergenceNotEvaluated ConvergenceVerdict = "NOT_EVALUATED"
)

// generationObservation is the tri-state read of the effective generation counter.
type generationObservation int

const (
	genAdvanced generationObservation = iota
	genNotAdvanced
	// genUnobservable — the counter could not be read AFTER the rebuild. On a host with
	// no reachable generation authority this is indistinguishable from "did not
	// advance", so it must NOT be reported as a failure.
	genUnobservable
)

// ConvergenceInputs are the facts the caller already holds. They are PASSED, never
// re-derived here — the same discipline --install-context follows.
type ConvergenceInputs struct {
	// ProjectionGenerated is true ONLY when the authoritative render succeeded IN THIS
	// RUN (phaseData.bootProjectionReady). ⛔ Never os.Stat, never mtime, never size.
	ProjectionGenerated bool
	// ApplyClaimedComplete is the rebuild's OWN claim (disposition COMPLETE with a
	// committed transaction). ⛔ Necessary, never sufficient — T3 exists precisely
	// because this claim was true while the kernel was unchanged.
	ApplyClaimedComplete bool
	// ApplyDeferred is true when the rebuild reported DEFERRED_RUNTIME.
	//
	// ⛔ AN EXPECTED DEFERRAL, NOT A SUCCESS SIGNAL. It suppresses the T6 "nothing
	// converged" failure (an unadvanced generation is what a deferral MEANS) and
	// nothing more — it never satisfies a leg and never produces ConvergenceVerified.
	ApplyDeferred bool
	// GenerationBefore is the counter read BEFORE the rebuild ran, from
	// ReadConvergenceGeneration. -1 means it could not be read.
	GenerationBefore int64
}

// ConvergenceResult carries the verdict and the per-leg evidence behind it.
type ConvergenceResult struct {
	Verdict ConvergenceVerdict
	// Legs is an ordered, human-readable evidence list — one line per leg, each stating
	// what was OBSERVED, not what was assumed.
	Legs []string
	// Detail names the first leg that decided a non-VERIFIED verdict.
	Detail string
}

// ReadConvergenceGeneration returns the effective convergence generation, or -1 when it
// cannot be read.
//
// ⛔ -1 IS "NOT OBSERVED", NOT ZERO. The shell treats an absent file as generation 0 for
// its own comparisons, but here the two must stay apart: an unreadable counter is an
// absence of evidence and must never be differenced against a real value to manufacture
// a "did not advance" conclusion.
//
//	ENOENT != ABSENCE. ABSENT_QUERY != RESOURCE_ABSENT.
func ReadConvergenceGeneration(exec executor.Executor) int64 {
	raw, err := exec.ReadFile(ConvergenceGenerationPath)
	if err != nil {
		return -1
	}
	v, cerr := strconv.ParseInt(strings.TrimSpace(string(raw)), 10, 64)
	if cerr != nil {
		return -1
	}
	return v
}

func observeGeneration(before, after int64) generationObservation {
	if after < 0 {
		return genUnobservable
	}
	if before < 0 {
		// The counter appeared during this run where it could not be read before. That
		// is an advance from "no completed convergence" to a recorded one.
		return genAdvanced
	}
	if after > before {
		return genAdvanced
	}
	return genNotAdvanced
}

// VerifyPostUpdateConvergence establishes the post-update convergence contract:
//
//	EXPECTED PACKAGE
//	  -> expected generated projection      (ProjectionGenerated, established this run)
//	  -> nft -c validation PASS             (probed here, on the projection's CONTENT)
//	  -> actual apply/rebuild result PASS   (ApplyClaimedComplete, the claim)
//	  -> effective kernel generation verified (probed here, independently of the claim)
//	  -> required kernel objects verified   (probed here)
//	  -> only then COMMITTED
//
// ⛔ THE PACKAGE LEG IS DELIBERATELY NOT EVALUATED HERE and is reported as such. It is
// owned by payload verification, and the only evidence available at this point would be
// a package version string — which this gate forbids as a convergence input. Claiming it
// would be exactly the collapse being removed.
//
//	CLAIM ONLY WHAT THE SYSTEM KNOWS.
//
// It is READ-ONLY. It probes; it never mutates, never re-applies, never "fixes".
func VerifyPostUpdateConvergence(exec executor.Executor, log *logging.Logger, in ConvergenceInputs) ConvergenceResult {
	res := ConvergenceResult{Verdict: ConvergenceVerified}
	fail := func(leg, detail string) {
		if res.Verdict != ConvergenceNotConverged {
			res.Verdict = ConvergenceNotConverged
			res.Detail = detail
		}
		res.Legs = append(res.Legs, "FAIL "+leg+": "+detail)
	}
	pass := func(leg, detail string) { res.Legs = append(res.Legs, "PASS "+leg+": "+detail) }
	unknown := func(leg, detail string) {
		if res.Verdict == ConvergenceVerified {
			res.Verdict = ConvergenceUnverified
			res.Detail = detail
		}
		res.Legs = append(res.Legs, "UNKNOWN "+leg+": "+detail)
	}

	res.Legs = append(res.Legs,
		"NOT_EVALUATED package_correct: owned by payload verification; a package version string is not convergence evidence")

	// ── LEG: projection generated ────────────────────────────────────────────────
	if in.ProjectionGenerated {
		pass("projection_generated", "the authoritative render succeeded IN THIS RUN")
	} else {
		fail("projection_generated", "the boot projection was not established in this run — "+
			"a projection that exists on disk from an earlier run is not this transaction's projection")
	}

	// ── LEG: projection valid (nft -c) ───────────────────────────────────────────
	// ⛔ rc=0 from `firewall render-boot` does NOT mean `nft -c` passed: the shell
	// publication path returns 0 for the UNKNOWN + byte-identical-preservation case too
	// (boot_projection.sh). So validation is probed here rather than inherited.
	raw, rerr := exec.ReadFile(BootProjectionPath)
	switch {
	case rerr != nil:
		fail("projection_valid", fmt.Sprintf("the boot projection %s could not be read: %v", BootProjectionPath, rerr))
	case len(strings.TrimSpace(string(raw))) == 0:
		fail("projection_valid", "the boot projection is empty — an empty projection boots to no enforcement")
	default:
		if cerr := exec.NftCheck(string(raw)); cerr != nil {
			fail("projection_valid", fmt.Sprintf("nft -c REJECTED the boot projection: %v — it must not be relied on for boot or apply", cerr))
		} else {
			pass("projection_valid", "nft -c accepted the published boot projection's content")
		}
	}

	// ── LEG: apply confirmed (the CLAIM) ─────────────────────────────────────────
	switch {
	case in.ApplyClaimedComplete:
		pass("apply_confirmed", "the rebuild reported a COMPLETE, committed transaction (claim only — see effective_generation)")
	case in.ApplyDeferred:
		res.Legs = append(res.Legs, "DEFERRED apply_confirmed: the rebuild deliberately deferred its module projection; the generation was intentionally NOT advanced")
	default:
		fail("apply_confirmed", "no rebuild reported a completed transaction")
	}

	// ── LEG: effective kernel generation (the INDEPENDENT check) ─────────────────
	after := ReadConvergenceGeneration(exec)
	switch observeGeneration(in.GenerationBefore, after) {
	case genAdvanced:
		pass("effective_generation", fmt.Sprintf("advanced %d -> %d; the commit that writes this counter ran", in.GenerationBefore, after))
	case genNotAdvanced:
		if in.ApplyClaimedComplete {
			// ⛔ T3. The rebuild CLAIMED success and the kernel generation says otherwise.
			// This is the only leg that can catch that, because it is the only one not
			// sourced from the rebuild itself.
			fail("effective_generation", fmt.Sprintf(
				"the rebuild reported COMPLETE but the effective convergence generation did NOT advance (%d -> %d) — "+
					"the commit that advances it is reachable only from COMPLETE, so the claim is not corroborated by the kernel-side record",
				in.GenerationBefore, after))
		} else if !in.ApplyDeferred {
			// ⛔ T6. Nothing claimed success and nothing converged.
			fail("effective_generation", fmt.Sprintf(
				"no convergence was recorded (%d -> %d) — the update is INCOMPLETE regardless of package state or daemon liveness",
				in.GenerationBefore, after))
		} else {
			res.Legs = append(res.Legs, fmt.Sprintf(
				"DEFERRED effective_generation: not advanced (%d -> %d), which is what DEFERRED_RUNTIME means; convergence debt outstanding",
				in.GenerationBefore, after))
		}
	case genUnobservable:
		unknown("effective_generation", "the effective convergence generation could not be read; "+
			"convergence is NOT verified and must not be reported as verified")
	}

	// ── LEG: required kernel objects ─────────────────────────────────────────────
	// The minimum honest statement: the nftban tables the rest of the runtime hangs off
	// are actually in the kernel. ⛔ Deliberately NOT called "chains and sets verified" —
	// that is more than this probes.
	v4 := exec.NftTableExists("ip", "nftban")
	v6 := exec.NftTableExists("ip6", "nftban")
	switch {
	case v4 && v6:
		pass("kernel_tables_present", "ip and ip6 nftban tables are present in the kernel")
	case in.ApplyClaimedComplete:
		fail("kernel_tables_present", fmt.Sprintf(
			"the rebuild reported COMPLETE but the kernel tables are not both present (ip=%t ip6=%t)", v4, v6))
	default:
		unknown("kernel_tables_present", fmt.Sprintf("ip=%t ip6=%t and no completed apply to compare against", v4, v6))
	}

	// ⛔ OWNER RULING ENFORCEMENT POINT (see the block above the constants).
	// DEFERRED dominates a clean run: a deferred projection is not a verified
	// convergence, and calling it VERIFIED would be the false-COMMITTED shape again.
	// It does NOT override a positive failure.
	//
	// ⛔ DO NOT DELETE THIS AS REDUNDANT. It is the only line that stops an otherwise
	// all-PASS deferred run — including one where the generation advanced for some
	// unrelated reason — from being reported as a proven convergence.
	if in.ApplyDeferred && res.Verdict == ConvergenceVerified {
		res.Verdict = ConvergenceDeferred
		res.Detail = "the rebuild deferred its module projection; convergence debt is outstanding"
	}

	for _, l := range res.Legs {
		log.Info("convergence leg: %s", l)
	}
	log.Info("post-update convergence verdict: %s", res.Verdict)
	return res
}
