// =============================================================================
// NFTBan v1.96 - Recovery Marker Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="rebuild-marker-test"
// meta:type="test"
// meta:version="1.96.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-17"
// meta:description="Tests for recovery marker persistence and lifecycle"
// meta:inventory.files="internal/rebuild/marker_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package rebuild

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func TestNewMarker(t *testing.T) {
	m := NewMarker(ClassDaemonRestartFailed, ResultFailedDegraded)

	if m.FailureClass != ClassDaemonRestartFailed {
		t.Errorf("FailureClass = %s; want DAEMON_RESTART_FAILED", m.FailureClass)
	}
	if m.OperationResult != ResultFailedDegraded {
		t.Errorf("OperationResult = %s; want FAILED_DEGRADED", m.OperationResult)
	}
	if m.RetryCount != 0 {
		t.Errorf("RetryCount = %d; want 0", m.RetryCount)
	}
	if m.MaxRetries != MaxImmediateRetries+MaxDeferredRetries {
		t.Errorf("MaxRetries = %d; want %d", m.MaxRetries, MaxImmediateRetries+MaxDeferredRetries)
	}
	if m.Exhausted {
		t.Error("Exhausted should be false on new marker")
	}
	if m.RollbackResult != "not_attempted" {
		t.Errorf("RollbackResult = %s; want not_attempted", m.RollbackResult)
	}
}

func TestMarkerWriteReadClear(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "state", "rebuild_recovery.json")

	m := NewMarker(ClassModuleRestoreIncomplete, ResultFailedDegraded)
	m.BackupPath = "/var/lib/nftban/backup/rebuild_20260417_120000"
	m.LastHealthState = "degraded"
	m.DaemonRelated = true
	m.SetRollbackResult(true)

	// Write
	if err := m.WriteTo(path); err != nil {
		t.Fatalf("WriteTo: %v", err)
	}

	// Verify file exists
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("marker file does not exist: %v", err)
	}

	// Read
	got, err := ReadMarkerFrom(path)
	if err != nil {
		t.Fatalf("ReadMarkerFrom: %v", err)
	}
	if got == nil {
		t.Fatal("ReadMarkerFrom returned nil")
	}

	if got.FailureClass != ClassModuleRestoreIncomplete {
		t.Errorf("FailureClass = %s; want MODULE_RESTORE_INCOMPLETE", got.FailureClass)
	}
	if got.BackupPath != "/var/lib/nftban/backup/rebuild_20260417_120000" {
		t.Errorf("BackupPath = %s", got.BackupPath)
	}
	if got.RollbackAttempted != true {
		t.Error("RollbackAttempted should be true")
	}
	if got.RollbackResult != "success" {
		t.Errorf("RollbackResult = %s; want success", got.RollbackResult)
	}
	if got.DaemonRelated != true {
		t.Error("DaemonRelated should be true")
	}

	// Clear
	if err := ClearFrom(path); err != nil {
		t.Fatalf("ClearFrom: %v", err)
	}

	// Verify cleared
	got2, err := ReadMarkerFrom(path)
	if err != nil {
		t.Fatalf("ReadMarkerFrom after clear: %v", err)
	}
	if got2 != nil {
		t.Error("marker should be nil after clear")
	}
}

func TestReadMarkerNotExist(t *testing.T) {
	got, err := ReadMarkerFrom("/tmp/nonexistent_rebuild_marker.json")
	if err != nil {
		t.Fatalf("unexpected error for missing marker: %v", err)
	}
	if got != nil {
		t.Error("should return nil for missing marker")
	}
}

func TestClearNonExistent(t *testing.T) {
	err := ClearFrom("/tmp/nonexistent_rebuild_marker.json")
	if err != nil {
		t.Errorf("clearing non-existent marker should not error: %v", err)
	}
}

func TestIncrementRetry(t *testing.T) {
	m := NewMarker(ClassDaemonRestartFailed, ResultFailedDegraded)

	// Max retries = 3 (1 immediate + 2 deferred)
	m.IncrementRetry()
	if m.RetryCount != 1 || m.Exhausted {
		t.Errorf("after 1 retry: count=%d, exhausted=%v", m.RetryCount, m.Exhausted)
	}

	m.IncrementRetry()
	if m.RetryCount != 2 || m.Exhausted {
		t.Errorf("after 2 retries: count=%d, exhausted=%v", m.RetryCount, m.Exhausted)
	}

	m.IncrementRetry()
	if m.RetryCount != 3 || !m.Exhausted {
		t.Errorf("after 3 retries: count=%d, exhausted=%v (should be exhausted)", m.RetryCount, m.Exhausted)
	}
}

func TestShouldDeferRetry(t *testing.T) {
	// Retryable class, not exhausted → should defer
	m := NewMarker(ClassDaemonRestartFailed, ResultFailedDegraded)
	m.RetryCount = 1
	if !m.ShouldDeferRetry() {
		t.Error("should defer retry for retryable class with attempts remaining")
	}

	// Exhausted → should not defer
	m.Exhausted = true
	if m.ShouldDeferRetry() {
		t.Error("should not defer retry when exhausted")
	}

	// Never-retry class → should not defer
	m2 := NewMarker(ClassRollbackFailed, ResultFailedFatal)
	if m2.ShouldDeferRetry() {
		t.Error("should not defer retry for never-retry class")
	}
}

func TestModuleRestoreReport(t *testing.T) {
	// All OK
	r := &ModuleRestoreReport{
		DDoS:     RestoreOK,
		Portscan: RestoreOK,
		BotGuard: RestoreSkipped,
		LoginMon: RestoreOK,
	}
	if !r.AllOK() {
		t.Error("AllOK should be true when all enabled modules are OK or skipped")
	}
	if r.HasFailure() {
		t.Error("HasFailure should be false")
	}

	// One incomplete
	r.BotGuard = RestoreIncomplete
	if r.AllOK() {
		t.Error("AllOK should be false with incomplete module")
	}
	if r.HasFailure() {
		t.Error("HasFailure should be false for incomplete (not failed)")
	}
	if !r.HasIncomplete() {
		t.Error("HasIncomplete should be true")
	}

	// One failed
	r.DDoS = RestoreFailed
	if !r.HasFailure() {
		t.Error("HasFailure should be true")
	}
}

func TestMarkerJSONSerialization(t *testing.T) {
	m := NewMarker(ClassModuleRestoreIncomplete, ResultFailedDegraded)
	m.ModuleRestore = &ModuleRestoreReport{
		DDoS:     RestoreOK,
		Portscan: RestoreFailed,
		BotGuard: RestoreSkipped,
		LoginMon: RestoreIncomplete,
	}

	data, err := json.MarshalIndent(m, "", "  ")
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}

	var m2 RecoveryMarker
	if err := json.Unmarshal(data, &m2); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}

	if m2.ModuleRestore == nil {
		t.Fatal("ModuleRestore should not be nil after roundtrip")
	}
	if m2.ModuleRestore.Portscan != RestoreFailed {
		t.Errorf("Portscan = %s; want RESTORE_FAILED", m2.ModuleRestore.Portscan)
	}
	if m2.ModuleRestore.LoginMon != RestoreIncomplete {
		t.Errorf("LoginMon = %s; want RESTORE_INCOMPLETE", m2.ModuleRestore.LoginMon)
	}
}
