// =============================================================================
// NFTBan v1.82 - Consistency Axis Evaluator
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
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
//   config vs kernel (enabled but missing = DEGRADED)
//   kernel vs validator (structural truth agreement)
//
// Per vocabulary Rule 8: DISABLED + PRESENT = valid residual, NOT a mismatch.
// Per vocabulary Rule 1: zero counters/sets = NEUTRAL, NOT evidence of failure.
// =============================================================================
package validator

// ConsistencyResult holds the outcome of cross-source verification.
type ConsistencyResult struct {
	Overall  string             `json:"overall"`  // "ok" | "mismatch"
	Checks   []ConsistencyCheck `json:"checks"`
	Findings []Finding          `json:"-"` // collected, appended to main result
}

// ConsistencyCheck represents one cross-source comparison.
type ConsistencyCheck struct {
	Module  string `json:"module"`
	Check   string `json:"check"`   // what was compared
	Result  string `json:"result"`  // "ok" | "mismatch"
	Detail  string `json:"detail,omitempty"`
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
//   ENABLED  + PRESENT → ok
//   ENABLED  + MISSING → MISMATCH (config says on, kernel says no)
//   DISABLED + PRESENT → ok (residual state, per Rule 8)
//   DISABLED + MISSING → ok (expected state)
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
		if h.Structural == StructuralPresent {
			check.Detail = "disabled + present (valid residual per Rule 8)"
		} else {
			check.Detail = "disabled + absent (expected)"
		}
		cr.Checks = append(cr.Checks, check)
		return
	}

	// Enabled modules: structural must be present
	if h.Config == ConfigEnabled {
		if h.Structural == StructuralPresent {
			check.Result = "ok"
			check.Detail = "enabled + present"
		} else if h.Structural == StructuralMissing {
			check.Result = "mismatch"
			check.Detail = "enabled in config but kernel objects missing"
			cr.Overall = "mismatch"
			cr.Findings = append(cr.Findings, Finding{
				Code:        CodeConsistencyMismatch,
				Severity:    SeverityError,
				Component:   "consistency",
				Message:     name + ": enabled in config but kernel objects missing (config/kernel mismatch)",
				Remediation: "Run: nftban " + name + " enable (or nftban firewall rebuild)",
			})
		} else {
			// Structural not yet evaluated (e.g. disabled short-circuit)
			check.Result = "ok"
			check.Detail = "enabled, structural not evaluated"
		}
		cr.Checks = append(cr.Checks, check)
	}
}
