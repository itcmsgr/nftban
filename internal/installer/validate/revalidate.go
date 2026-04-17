// =============================================================================
// NFTBan v1.98 - Bounded Safe Auto-Fix + Re-Validation
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-revalidate"
// meta:type="lib"
// meta:version="1.98.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="VALIDATE_1 → bounded safe fix → VALIDATE_2 state machine"
// meta:inventory.files="internal/installer/validate/revalidate.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
//
// Contract: V198_INSTALL_CANONIZATION_CONTRACT.md
// INV-I-010: Post-install safe auto-fix trigger (one-shot after validation)
// INV-I-011: Safe auto-fix scope is allowlisted only (permissions enforce)
// INV-I-012: One-shot only — at most once per install
// INV-I-013: Re-validation mandatory — only post-fix result determines success
// =============================================================================

package validate

import (
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// RevalidateResult captures the outcome of the VALIDATE_1 → FIX → VALIDATE_2 flow.
type RevalidateResult struct {
	// Validate1Passed is true if initial assertions all passed.
	Validate1Passed bool

	// FixAttempted is true if bounded safe fix was run (only when V1 fails).
	FixAttempted bool

	// FixExitCode is the exit code of the permissions enforce command.
	FixExitCode int

	// Validate2Passed is true if re-validation passed after fix.
	// Only meaningful when FixAttempted is true.
	Validate2Passed bool

	// FinalPassed is the authoritative result: V1 if no fix needed, V2 if fix ran.
	FinalPassed bool

	// FailedNames contains assertion names that failed in the final validation.
	FailedNames []string
}

// RunWithBoundedFix implements the VALIDATE_1 → FIX → VALIDATE_2 state machine.
//
// Flow:
//  1. Run assertions (VALIDATE_1)
//  2. If all pass → return success immediately
//  3. If some fail → run bounded safe fix (permissions enforce only, INV-I-011)
//  4. Re-run assertions (VALIDATE_2, INV-I-013)
//  5. Return VALIDATE_2 result as authoritative
//
// The fix runs at most ONCE (INV-I-012). It calls ONLY 'nftban permissions enforce'
// which is bounded to chmod/chown on FHS-managed paths. It does NOT call 'health fix all'.
func RunWithBoundedFix(exec executor.Executor, sshPort int, log *logging.Logger) RevalidateResult {
	result := RevalidateResult{}

	// VALIDATE_1
	v1 := RunAssertions(exec, sshPort, log)
	result.Validate1Passed = AllPassed(v1)

	if result.Validate1Passed {
		// All good — no fix needed
		result.FinalPassed = true
		return result
	}

	// VALIDATE_1 failed — attempt bounded safe fix (one-shot, INV-I-012)
	result.FixAttempted = true
	failed1 := FailedNames(v1)
	log.Warn("VALIDATE_1: %d assertions failed: %v — running bounded safe fix", len(failed1), failed1)

	// Run ONLY permissions enforce — bounded, safe, idempotent (INV-I-011)
	fixRes := exec.RunTimeout(30*time.Second, fhs.NftbanCLI, "permissions", "enforce")
	result.FixExitCode = fixRes.ExitCode

	if fixRes.ExitCode == 0 {
		log.Info("permissions enforce completed — re-validating (INV-I-013)")
	} else {
		log.Warn("permissions enforce exit %d — re-validating anyway", fixRes.ExitCode)
	}

	// VALIDATE_2 — only this result counts (INV-I-013)
	v2 := RunAssertions(exec, sshPort, log)
	result.Validate2Passed = AllPassed(v2)
	result.FinalPassed = result.Validate2Passed

	if !result.FinalPassed {
		result.FailedNames = FailedNames(v2)
	}

	return result
}
