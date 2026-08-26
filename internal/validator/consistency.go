// =============================================================================
// NFTBan v1.82 - Consistency Axis Evaluator
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="consistency"
// meta:type="lib"
// meta:version="1.82.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Cross-source consistency verification per M81-4 health derivation"
// meta:inventory.files="internal/validator/consistency.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// The consistency axis detects disagreements between truth sources:
//
//	config vs kernel (enabled but missing = DEGRADED)
//	kernel vs validator (structural truth agreement)
//
// Per vocabulary Rule 8: DISABLED + PRESENT = valid residual, NOT a mismatch.
// Per vocabulary Rule 1: zero counters/sets = NEUTRAL, NOT evidence of failure.
// =============================================================================
package validator

// ConsistencyResult holds the outcome of cross-source verification.
type ConsistencyResult struct {
	Overall  string             `json:"overall"` // "ok" | "mismatch" | "unknown" (v1.229.7)
	Checks   []ConsistencyCheck `json:"checks"`
	Findings []Finding          `json:"-"` // collected, appended to main result
}

// ConsistencyCheck represents one cross-source comparison.
type ConsistencyCheck struct {
	Module string `json:"module"`
	Check  string `json:"check"`  // what was compared
	Result string `json:"result"` // "ok" | "mismatch"
	Detail string `json:"detail,omitempty"`
}

// evaluateConsistency checks cross-source agreement for all enabled modules.
// Returns findings that should be appended to the main ValidationResult.
func evaluateConsistency(modules ModuleHealthMap) ConsistencyResult {
	cr := ConsistencyResult{
		Overall: "ok",
		Checks:  make([]ConsistencyCheck, 0),
	}

	// Check each module: config vs structural agreement
	checkModuleConsistency(&cr, "botguard", modules.BotGuard)
	checkModuleConsistency(&cr, "ddos", modules.DDoS)
	checkModuleConsistency(&cr, "portscan", modules.Portscan)
	checkModuleConsistency(&cr, "loginmon", modules.LoginMon)

	return cr
}

// checkModuleConsistency verifies config↔structural agreement for one module.
//
// Truth table (from M81-4 §3.4):
//
//	ENABLED  + PRESENT → ok
//	ENABLED  + MISSING → MISMATCH (config says on, kernel says no)
//	DISABLED + PRESENT → ok (residual state, per Rule 8)
//	DISABLED + MISSING → ok (expected state)
//	ENABLED  + UNKNOWN → UNKNOWN / CONTRACT FAILURE (v1.229.7 PR-3A) — the
//	                     expectation could not be established, so no structural
//	                     verdict may be claimed in EITHER direction.
func checkModuleConsistency(cr *ConsistencyResult, name string, h *ModuleHealth) {
	if h == nil {
		return
	}

	check := ConsistencyCheck{
		Module: name,
		Check:  "config_vs_kernel",
	}

	// Disabled modules: always consistent (Rule 8 — residual is valid)
	if h.Config == ConfigDisabled {
		check.Result = "ok"
		switch h.Structural {
		case StructuralPresent:
			check.Detail = "disabled + present (valid residual per Rule 8)"
		case StructuralMissing:
			check.Detail = "disabled + absent (expected)"
		default:
			// Rule 8 makes a disabled module consistent either way, so the
			// verdict stays ok -- but the detail must not claim "absent" for a
			// state that was never observed. ABSENT_QUERY != RESOURCE_ABSENT.
			check.Detail = "disabled (kernel state not evaluated)"
		}
		cr.Checks = append(cr.Checks, check)
		return
	}

	// Enabled modules: structural must be present.
	//
	// v1.229.7 PR-3A: exhaustive by construction. Every StructuralState gets an
	// explicit arm and the default REJECTS, because the previous shape ended in
	// an `else` that reported "ok" for anything it did not recognise -- so an
	// unset or future value silently became a pass.
	//   NO IMPLICIT DEFAULT => PRESENT / MISSING
	//   UNKNOWN MUST PROPAGATE -- IT MUST NOT COLLAPSE TO PRESENT OR MISSING
	if h.Config == ConfigEnabled {
		// v1.229.7 PR-3A. Exhaustive by construction: every StructuralState has
		// an explicit arm and `default` means INVALID PROGRAM STATE, never
		// "everything else is okay". The previous shape ended in an `else` that
		// reported ok for anything it did not recognise.
		//   NO IMPLICIT DEFAULT => PRESENT / MISSING
		//   UNKNOWN MUST PROPAGATE -- NEVER COLLAPSE TO PRESENT OR MISSING
		//
		// UNKNOWN is not a synonym for failure either:
		//   UNKNOWN != PASS · != CONFIRMED DRIFT · != UNPROTECTED
		// It means the validator lacks the authoritative evidence to make the
		// claim, so it must decline the claim -- in both directions.
		switch h.Structural {
		case StructuralPresent:
			check.Result = "ok"
			check.Detail = "enabled + present"

		case StructuralMissing:
			check.Result = "mismatch"
			cr.Overall = "mismatch"
			// The diagnostic must name the ACTUAL condition. Cross-mode drift is
			// the opposite of absence -- too many objects, not too few -- and
			// telling an operator "objects missing" while the other mode's
			// pipeline is live sends them to the wrong remedy entirely.
			if h.StructuralReason == ReasonDriftPresent {
				check.Detail = "enabled, but objects from the OTHER mode are unexpectedly PRESENT (cross-mode drift)"
				cr.Findings = append(cr.Findings, Finding{
					Code:        CodeConsistencyMismatch,
					Severity:    SeverityError,
					Component:   "consistency",
					Message:     name + ": unexpected live kernel objects from the other mode are PRESENT while this mode is in force (cross-mode drift)",
					Remediation: "Run: nftban firewall rebuild (tears down the stale pipeline and reconciles to the resolved mode)",
				})
			} else {
				check.Detail = "enabled, but the expected kernel objects are absent"
				cr.Findings = append(cr.Findings, Finding{
					Code:        CodeConsistencyMismatch,
					Severity:    SeverityError,
					Component:   "consistency",
					Message:     name + ": enabled in config but the expected kernel objects are absent (config/kernel mismatch)",
					Remediation: "Run: nftban " + name + " enable (or nftban firewall rebuild)",
				})
			}

		case StructuralUnknown:
			// Declines the claim. Propagates to Overall AND -- via an error
			// finding -- to the top-line status, because without the finding
			// evaluateOverallStatus still returned PROTECTED for a module whose
			// structural axis was never actually evaluated.
			check.Result = "unknown"
			if cr.Overall == "ok" {
				cr.Overall = "unknown" // never downgrade a real mismatch
			}
			if h.StructuralReason == ReasonObservationUnknown {
				check.Detail = "enabled, expectation known, but the kernel state could not be observed"
				cr.Findings = append(cr.Findings, Finding{
					Code:        CodeConsistencyObserveUnknown,
					Severity:    SeverityError,
					Component:   "consistency",
					Message:     name + ": the kernel state could not be observed — structural axis UNKNOWN, not verified (observation incomplete)",
					Remediation: "Re-run once the ruleset is readable: nftban health",
				})
			} else {
				check.Detail = "enabled, but the effective mode could not be established (no authoritative resolved plan)"
				cr.Findings = append(cr.Findings, Finding{
					Code:        CodeConsistencyUnknown,
					Severity:    SeverityError,
					Component:   "consistency",
					Message:     name + ": mode is `auto` and no authoritative resolved plan was observed — the expected kernel state is UNKNOWN, not verified",
					Remediation: "Run: nftban " + name + " reconcile (re-resolves the plan), or set an explicit mode",
				})
			}

		case "":
			// Enabled, but nothing ever wrote the axis. Not an invalid value --
			// an absent observation. ABSENT_QUERY != RESOURCE_ABSENT.
			check.Result = "unknown"
			check.Detail = "enabled, but the structural axis was not evaluated"
			if cr.Overall == "ok" {
				cr.Overall = "unknown"
			}
			cr.Findings = append(cr.Findings, Finding{
				Code:      CodeConsistencyObserveUnknown,
				Severity:  SeverityError,
				Component: "consistency",
				Message:   name + ": structural axis not evaluated — UNKNOWN, not verified",
			})

		default:
			// INVALID PROGRAM STATE. A StructuralState exists that this consumer
			// was never taught -- i.e. someone extended the enum and did not
			// update this switch. Fail closed: the one outcome that must never
			// follow from an unrecognised value is a pass.
			check.Result = "unknown"
			check.Detail = "internal contract error: unrecognised structural state " + string(h.Structural)
			if cr.Overall == "ok" {
				cr.Overall = "unknown"
			}
			cr.Findings = append(cr.Findings, Finding{
				Code:        CodeConsistencyInvalidState,
				Severity:    SeverityError,
				Component:   "consistency",
				Message:     name + ": unrecognised structural state \"" + string(h.Structural) + "\" — this is a defect in nftban, not a firewall condition",
				Remediation: "Report this: the StructuralState enum was extended without updating checkModuleConsistency",
			})
		}
		cr.Checks = append(cr.Checks, check)
	}
}
