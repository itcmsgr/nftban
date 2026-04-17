// =============================================================================
// NFTBan v1.96 - Rebuild Recovery Types
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="rebuild-types"
// meta:type="lib"
// meta:version="1.96.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Type definitions for rebuild recovery: failure classes, operation results, module restore"
// meta:inventory.files="internal/rebuild/types.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Contract: V196_REBUILD_RECOVERY_CONTRACT.md
// Invariants: INV-RR-001 through INV-RR-010
// =============================================================================

package rebuild

// OperationResult represents the outcome of a rebuild operation.
// This is distinct from system health (validator.Status).
//
// A rebuild can FAIL while system health remains PROTECTED if rollback
// restored a validated known-good state. These are separate truths:
//   - OperationResult = what happened during rebuild
//   - validator.Status = current firewall protection state
type OperationResult string

const (
	// ResultSuccess means rebuild completed and post-validation passed.
	ResultSuccess OperationResult = "SUCCESS"

	// ResultFailedRecovered means rebuild failed but rollback restored a
	// validated PROTECTED state. System is healthy, but rebuild did not achieve
	// its goal. Command exits non-zero, health may be PROTECTED.
	ResultFailedRecovered OperationResult = "FAILED_RECOVERED"

	// ResultFailedDegraded means rebuild failed and system is in DEGRADED state.
	// Either rollback restored a DEGRADED state, retry was exhausted,
	// or module restoration was incomplete.
	ResultFailedDegraded OperationResult = "FAILED_DEGRADED"

	// ResultFailedFatal means rollback itself failed. Manual recovery required.
	// System is in DOWN or untrusted state. Exit code 3.
	ResultFailedFatal OperationResult = "FAILED_FATAL"
)

// FailureClass categorizes the root cause of a rebuild failure.
// Each class has a fixed retry policy — see policy.go.
//
// Contract: Only transient classes are retryable. Invalid desired state,
// structural failures, and rollback failures are NEVER retried.
type FailureClass string

const (
	// ClassPrevalidationFailed means nft -c -f rejected the rendered config.
	// This is an INPUT failure — no kernel mutation occurred.
	// INV-RR-001: must abort before any kernel change.
	// MUST NOT write recovery marker. MUST NOT enter recovery flow.
	ClassPrevalidationFailed FailureClass = "PREVALIDATION_FAILED"

	// ClassSnapshotFailed means pre-rebuild state could not be captured.
	// INV-RR-002: snapshot must exist before destructive change.
	ClassSnapshotFailed FailureClass = "SNAPSHOT_FAILED"

	// ClassApplyFailed means nft -f load failed after validation passed.
	// May be transient (kernel busy, resource exhaustion).
	ClassApplyFailed FailureClass = "APPLY_FAILED"

	// ClassPostvalidationRegression means post-state is worse than pre-state.
	// Retry is CONDITIONAL: only if caused by daemon/module restore path.
	// If caused by validator structural failure → never retry.
	ClassPostvalidationRegression FailureClass = "POSTVALIDATION_REGRESSION"

	// ClassPostvalidationHardFail means validator reports structural DOWN.
	ClassPostvalidationHardFail FailureClass = "POSTVALIDATION_HARD_FAIL"

	// ClassDaemonRestartFailed means nftband could not start for module restore.
	// Retryable — daemon may start on deferred retry after boot completes.
	ClassDaemonRestartFailed FailureClass = "DAEMON_RESTART_FAILED"

	// ClassModuleRestoreFailed means module re-enable failed explicitly.
	// Retryable if daemon dependency is the root cause.
	ClassModuleRestoreFailed FailureClass = "MODULE_RESTORE_FAILED"

	// ClassModuleRestoreIncomplete means some modules restored, others failed.
	// Retryable once — may succeed if daemon becomes available.
	ClassModuleRestoreIncomplete FailureClass = "MODULE_RESTORE_INCOMPLETE"

	// ClassRollbackFailed means snapshot restore failed. Never retry.
	// Exit code 3. Manual recovery required.
	ClassRollbackFailed FailureClass = "ROLLBACK_FAILED"

	// ClassAuthorityConflict means a foreign firewall was detected during rebuild.
	ClassAuthorityConflict FailureClass = "AUTHORITY_CONFLICT"

	// ClassBackupMissing means no snapshot was available for rollback.
	ClassBackupMissing FailureClass = "BACKUP_MISSING"

	// ClassRetryExhausted means max retry attempts reached. Stop.
	ClassRetryExhausted FailureClass = "RETRY_EXHAUSTED"
)

// ModuleRestoreResult represents the outcome of restoring a single module
// after rebuild. Three verification levels are required:
//
//	Level 1: Structure presence (chains + sets exist)
//	Level 2: Wiring correctness (jumps in correct anchor positions)
//	Level 3: Activation evidence (counters, active set references, or validator confirmation)
//
// Classification:
//
//	Level 1 only         → RestoreIncomplete
//	Level 1 + Level 2    → RestoreIncomplete (wired but unproven)
//	Level 1 + 2 + 3      → RestoreOK
//	Level 1 fails        → RestoreFailed
//	Not attempted        → RestoreSkipped
type ModuleRestoreResult string

const (
	// RestoreOK means module restored and verified at all 3 levels.
	RestoreOK ModuleRestoreResult = "RESTORE_OK"

	// RestoreFailed means module restore attempt failed (Level 1 not met).
	RestoreFailed ModuleRestoreResult = "RESTORE_FAILED"

	// RestoreIncomplete means partial verification (Level 1 or 1+2 only).
	RestoreIncomplete ModuleRestoreResult = "RESTORE_INCOMPLETE"

	// RestoreSkipped means module was not enabled pre-rebuild or not applicable.
	RestoreSkipped ModuleRestoreResult = "RESTORE_SKIPPED"
)

// RetryDisposition is the decision on whether and how to retry a failure.
type RetryDisposition string

const (
	// RetryImmediate means retry once in the same process execution.
	RetryImmediate RetryDisposition = "RETRY_IMMEDIATE"

	// RetryDeferred means schedule a follow-up retry via systemd timer.
	RetryDeferred RetryDisposition = "RETRY_DEFERRED"

	// NoRetry means this failure class must not be retried.
	NoRetry RetryDisposition = "NO_RETRY"
)

// ModuleRestoreReport captures per-module restore outcomes after rebuild.
type ModuleRestoreReport struct {
	DDoS     ModuleRestoreResult `json:"ddos"`
	Portscan ModuleRestoreResult `json:"portscan"`
	BotGuard ModuleRestoreResult `json:"botguard"`
	LoginMon ModuleRestoreResult `json:"loginmon"`
}

// AllOK returns true if all enabled modules restored successfully.
func (r *ModuleRestoreReport) AllOK() bool {
	for _, result := range r.results() {
		if result == RestoreFailed || result == RestoreIncomplete {
			return false
		}
	}
	return true
}

// HasFailure returns true if any enabled module failed to restore.
func (r *ModuleRestoreReport) HasFailure() bool {
	for _, result := range r.results() {
		if result == RestoreFailed {
			return true
		}
	}
	return false
}

// HasIncomplete returns true if any module is partially restored.
func (r *ModuleRestoreReport) HasIncomplete() bool {
	for _, result := range r.results() {
		if result == RestoreIncomplete {
			return true
		}
	}
	return false
}

func (r *ModuleRestoreReport) results() []ModuleRestoreResult {
	return []ModuleRestoreResult{r.DDoS, r.Portscan, r.BotGuard, r.LoginMon}
}
