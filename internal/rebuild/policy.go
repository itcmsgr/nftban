// =============================================================================
// NFTBan v1.96 - Rebuild Retry Policy
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="rebuild-policy"
// meta:type="lib"
// meta:version="1.96.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Retry policy constants and disposition logic for rebuild recovery"
// meta:inventory.files="internal/rebuild/policy.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Contract: V196_REBUILD_RECOVERY_CONTRACT.md §5
// INV-RR-005: Invalid state, structural failure, authority conflict → NEVER retried
// INV-RR-006: Retry count is finite and persisted
// =============================================================================

package rebuild

// Retry policy constants.
const (
	// MaxImmediateRetries is the maximum retry count within the same process.
	MaxImmediateRetries = 1

	// MaxDeferredRetries is the maximum deferred retry count across boots/triggers.
	MaxDeferredRetries = 2

	// DeferredRetryDelaySec is the delay before deferred retry (systemd timer).
	DeferredRetryDelaySec = 60
)

// neverRetryClasses are failure classes that must never be retried.
// INV-RR-005: these represent invalid desired state or unrecoverable failures.
var neverRetryClasses = map[FailureClass]bool{
	ClassPrevalidationFailed:   true,
	ClassSnapshotFailed:        true,
	ClassPostvalidationHardFail: true,
	ClassRollbackFailed:        true,
	ClassAuthorityConflict:     true,
	ClassBackupMissing:         true,
	ClassRetryExhausted:        true,
}

// immediateRetryClasses are eligible for one in-process retry.
var immediateRetryClasses = map[FailureClass]bool{
	ClassApplyFailed:             true,
	ClassDaemonRestartFailed:     true,
	ClassModuleRestoreFailed:     true,
	ClassModuleRestoreIncomplete: true,
}

// GetRetryDisposition determines whether a failure should be retried and how.
//
// Rules:
//   - Never-retry classes → NoRetry regardless of attempt count
//   - POSTVALIDATION_REGRESSION → conditional (see isDaemonRelatedRegression)
//   - Immediate-retry classes → RetryImmediate if attempt < max
//   - Otherwise → RetryDeferred if deferred attempts remain
//   - Exhausted → NoRetry
func GetRetryDisposition(class FailureClass, immediateAttempts, deferredAttempts int, daemonRelated bool) RetryDisposition {
	// Never retry these classes
	if neverRetryClasses[class] {
		return NoRetry
	}

	// POSTVALIDATION_REGRESSION: conditional retry
	// Retry ONLY if regression was caused by daemon/module restore path.
	// If caused by validator structural failure → never retry.
	if class == ClassPostvalidationRegression {
		if !daemonRelated {
			return NoRetry
		}
		// Daemon-related regression: treat as retryable
		if immediateAttempts < MaxImmediateRetries {
			return RetryImmediate
		}
		if deferredAttempts < MaxDeferredRetries {
			return RetryDeferred
		}
		return NoRetry
	}

	// Standard retryable classes
	if immediateRetryClasses[class] {
		if immediateAttempts < MaxImmediateRetries {
			return RetryImmediate
		}
		if deferredAttempts < MaxDeferredRetries {
			return RetryDeferred
		}
		return NoRetry
	}

	// Unknown class — safe default
	return NoRetry
}

// IsRetryable returns true if the failure class is potentially retryable.
// For POSTVALIDATION_REGRESSION, this returns true but actual retry depends
// on whether the regression is daemon-related (checked at call site).
func IsRetryable(class FailureClass) bool {
	if neverRetryClasses[class] {
		return false
	}
	if immediateRetryClasses[class] {
		return true
	}
	if class == ClassPostvalidationRegression {
		return true // conditionally — caller must check daemonRelated
	}
	return false
}
