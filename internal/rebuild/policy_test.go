// =============================================================================
// NFTBan v1.96 - Rebuild Retry Policy Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="rebuild-policy-test"
// meta:type="test"
// meta:version="1.96.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Tests for rebuild retry policy logic"
// meta:inventory.files="internal/rebuild/policy_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package rebuild

import "testing"

func TestNeverRetryClasses(t *testing.T) {
	neverRetry := []FailureClass{
		ClassPrevalidationFailed,
		ClassSnapshotFailed,
		ClassPostvalidationHardFail,
		ClassRollbackFailed,
		ClassAuthorityConflict,
		ClassBackupMissing,
		ClassRetryExhausted,
	}

	for _, class := range neverRetry {
		got := GetRetryDisposition(class, 0, 0, false)
		if got != NoRetry {
			t.Errorf("GetRetryDisposition(%s, 0, 0, false) = %s; want NO_RETRY", class, got)
		}
		// Even with daemonRelated=true, these should never retry
		got = GetRetryDisposition(class, 0, 0, true)
		if got != NoRetry {
			t.Errorf("GetRetryDisposition(%s, 0, 0, true) = %s; want NO_RETRY", class, got)
		}
	}
}

func TestImmediateRetryClasses(t *testing.T) {
	retryable := []FailureClass{
		ClassApplyFailed,
		ClassDaemonRestartFailed,
		ClassModuleRestoreFailed,
		ClassModuleRestoreIncomplete,
	}

	for _, class := range retryable {
		// First attempt → immediate retry
		got := GetRetryDisposition(class, 0, 0, false)
		if got != RetryImmediate {
			t.Errorf("GetRetryDisposition(%s, 0, 0, false) = %s; want RETRY_IMMEDIATE", class, got)
		}

		// After immediate exhausted → deferred
		got = GetRetryDisposition(class, 1, 0, false)
		if got != RetryDeferred {
			t.Errorf("GetRetryDisposition(%s, 1, 0, false) = %s; want RETRY_DEFERRED", class, got)
		}

		// After all exhausted → no retry
		got = GetRetryDisposition(class, 1, 2, false)
		if got != NoRetry {
			t.Errorf("GetRetryDisposition(%s, 1, 2, false) = %s; want NO_RETRY", class, got)
		}
	}
}

func TestPostvalidationRegressionConditional(t *testing.T) {
	class := ClassPostvalidationRegression

	// Non-daemon-related regression → never retry
	got := GetRetryDisposition(class, 0, 0, false)
	if got != NoRetry {
		t.Errorf("non-daemon regression: got %s; want NO_RETRY", got)
	}

	// Daemon-related regression → immediate retry
	got = GetRetryDisposition(class, 0, 0, true)
	if got != RetryImmediate {
		t.Errorf("daemon-related regression, attempt 0: got %s; want RETRY_IMMEDIATE", got)
	}

	// Daemon-related, immediate exhausted → deferred
	got = GetRetryDisposition(class, 1, 0, true)
	if got != RetryDeferred {
		t.Errorf("daemon-related regression, immediate exhausted: got %s; want RETRY_DEFERRED", got)
	}

	// Daemon-related, all exhausted → no retry
	got = GetRetryDisposition(class, 1, 2, true)
	if got != NoRetry {
		t.Errorf("daemon-related regression, all exhausted: got %s; want NO_RETRY", got)
	}
}

func TestIsRetryable(t *testing.T) {
	tests := []struct {
		class FailureClass
		want  bool
	}{
		{ClassPrevalidationFailed, false},
		{ClassSnapshotFailed, false},
		{ClassRollbackFailed, false},
		{ClassAuthorityConflict, false},
		{ClassBackupMissing, false},
		{ClassRetryExhausted, false},
		{ClassPostvalidationHardFail, false},
		{ClassApplyFailed, true},
		{ClassDaemonRestartFailed, true},
		{ClassModuleRestoreFailed, true},
		{ClassModuleRestoreIncomplete, true},
		{ClassPostvalidationRegression, true}, // conditionally
	}

	for _, tt := range tests {
		got := IsRetryable(tt.class)
		if got != tt.want {
			t.Errorf("IsRetryable(%s) = %v; want %v", tt.class, got, tt.want)
		}
	}
}

func TestPrevalidationNeverEntersRecovery(t *testing.T) {
	// INV-RR contract: PREVALIDATION_FAILED must never write marker
	// or enter recovery flow. This test documents the invariant.
	class := ClassPrevalidationFailed

	if IsRetryable(class) {
		t.Error("PREVALIDATION_FAILED must not be retryable")
	}

	disp := GetRetryDisposition(class, 0, 0, true)
	if disp != NoRetry {
		t.Errorf("PREVALIDATION_FAILED disposition = %s; want NO_RETRY even with daemonRelated=true", disp)
	}
}
