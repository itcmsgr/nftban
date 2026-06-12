// =============================================================================
// NFTBan v1.96 - Recovery Marker Persistence
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="rebuild-marker"
// meta:type="lib"
// meta:version="1.96.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Persistent recovery marker for rebuild failure state and retry tracking"
// meta:inventory.files="internal/rebuild/marker.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Contract: V196_REBUILD_RECOVERY_CONTRACT.md §7
// Marker path: /var/lib/nftban/state/rebuild_recovery.json
// INV-RR-006: Retry count is finite and persisted
// =============================================================================

package rebuild

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"time"

	"github.com/itcmsgr/nftban/internal/safety"
)

// DefaultMarkerPath is the canonical location for the recovery marker.
const DefaultMarkerPath = "/var/lib/nftban/state/rebuild_recovery.json"

// RecoveryMarker persists rebuild failure state for recovery tracking.
// Written on any non-SUCCESS rebuild outcome (except PREVALIDATION_FAILED).
// Cleared on SUCCESS. Read by deferred retry service.
type RecoveryMarker struct {
	// FailureClass categorizes the root cause.
	FailureClass FailureClass `json:"failure_class"`

	// OperationResult is the rebuild operation outcome.
	OperationResult OperationResult `json:"operation_result"`

	// RetryCount is the number of retry attempts so far (immediate + deferred).
	RetryCount int `json:"retry_count"`

	// MaxRetries is the configured maximum total retries.
	MaxRetries int `json:"max_retries"`

	// DeferredRetryPending indicates a deferred retry should be attempted.
	DeferredRetryPending bool `json:"deferred_retry_pending"`

	// FirstFailureAt is the timestamp of the initial failure.
	FirstFailureAt time.Time `json:"first_failure_at"`

	// LastFailureAt is the timestamp of the most recent failure/retry.
	LastFailureAt time.Time `json:"last_failure_at"`

	// RollbackAttempted indicates whether rollback was triggered.
	RollbackAttempted bool `json:"rollback_attempted"`

	// RollbackResult is the outcome of the rollback attempt.
	RollbackResult string `json:"rollback_result"` // "success", "failed", "not_attempted"

	// BackupPath is the snapshot directory used for rollback.
	BackupPath string `json:"backup_path"`

	// LastHealthState is the validator state after recovery settled.
	LastHealthState string `json:"last_health_state"` // "protected", "degraded", "down"

	// Exhausted is true when max retries are reached.
	Exhausted bool `json:"exhausted"`

	// ModuleRestore captures per-module restore outcomes.
	ModuleRestore *ModuleRestoreReport `json:"module_restore,omitempty"`

	// DaemonRelated indicates whether the failure involved daemon unavailability.
	DaemonRelated bool `json:"daemon_related"`
}

// ReadMarker reads a recovery marker from the default path.
// Returns nil, nil if marker does not exist (no recovery pending).
func ReadMarker() (*RecoveryMarker, error) {
	return ReadMarkerFrom(DefaultMarkerPath)
}

// ReadMarkerFrom reads a recovery marker from a specific path.
// Returns nil, nil if marker does not exist.
func ReadMarkerFrom(path string) (*RecoveryMarker, error) {
	data, err := os.ReadFile(path) // #nosec G304 — path is controlled
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, fmt.Errorf("read recovery marker: %w", err)
	}

	var m RecoveryMarker
	if err := json.Unmarshal(data, &m); err != nil {
		return nil, fmt.Errorf("parse recovery marker: %w", err)
	}

	return &m, nil
}

// Write persists the recovery marker atomically.
// Uses temp file + rename for crash safety.
func (m *RecoveryMarker) Write() error {
	return m.WriteTo(DefaultMarkerPath)
}

// WriteTo persists the recovery marker to a specific path.
func (m *RecoveryMarker) WriteTo(path string) error {
	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		return fmt.Errorf("marshal recovery marker: %w", err)
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0750); err != nil {
		return fmt.Errorf("create marker directory: %w", err)
	}

	// v1.176 FSYNC-RESIDUAL (F-2): route through safety.SafeWriteFile — temp +
	// fsync + atomic rename (was os.WriteFile(tmp)+Rename with NO Sync → a crash
	// could leave a torn/zero-length recovery marker, defeating its crash-safety).
	if err := safety.SafeWriteFile(path, data, 0640); err != nil {
		return fmt.Errorf("write recovery marker: %w", err)
	}

	return nil
}

// Clear removes the recovery marker (rebuild succeeded).
func Clear() error {
	return ClearFrom(DefaultMarkerPath)
}

// ClearFrom removes a recovery marker at a specific path.
func ClearFrom(path string) error {
	err := os.Remove(path)
	if err != nil && !os.IsNotExist(err) {
		return fmt.Errorf("clear recovery marker: %w", err)
	}
	return nil
}

// NewMarker creates a new recovery marker for an initial failure.
func NewMarker(class FailureClass, result OperationResult) *RecoveryMarker {
	now := time.Now()
	return &RecoveryMarker{
		FailureClass:         class,
		OperationResult:      result,
		RetryCount:           0,
		MaxRetries:           MaxImmediateRetries + MaxDeferredRetries,
		DeferredRetryPending: false,
		FirstFailureAt:       now,
		LastFailureAt:        now,
		RollbackAttempted:    false,
		RollbackResult:       "not_attempted",
		Exhausted:            false,
	}
}

// IncrementRetry updates the marker for a retry attempt.
func (m *RecoveryMarker) IncrementRetry() {
	m.RetryCount++
	m.LastFailureAt = time.Now()
	if m.RetryCount >= m.MaxRetries {
		m.Exhausted = true
		m.DeferredRetryPending = false
	}
}

// ShouldDeferRetry returns true if a deferred retry should be scheduled.
func (m *RecoveryMarker) ShouldDeferRetry() bool {
	if m.Exhausted {
		return false
	}
	if neverRetryClasses[m.FailureClass] {
		return false
	}
	return m.RetryCount < m.MaxRetries
}

// SetRollbackResult records the rollback outcome.
func (m *RecoveryMarker) SetRollbackResult(success bool) {
	m.RollbackAttempted = true
	if success {
		m.RollbackResult = "success"
	} else {
		m.RollbackResult = "failed"
	}
}
