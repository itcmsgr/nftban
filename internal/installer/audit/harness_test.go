// =============================================================================
// NFTBan v1.100 PR-22B — Purity Harness Self-Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-audit-harness-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Self-tests for the purity-harness assertion kit"
// meta:inventory.files="internal/installer/audit/harness_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// These tests confirm that the harness fails (via t.Errorf / t.Fatalf)
// on each of the contract violations it exists to detect, and passes
// when the contract is respected. Use a recording *testing.T substitute
// to observe failure behaviour without failing this test itself.
//
// =============================================================================
package audit

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// recordingT implements enough of testing.TB to let us observe the
// number of Errorf / Fatalf calls an assertion made without marking the
// real test as failed.
type recordingT struct {
	testing.TB
	errors int
	fatals int
}

func (r *recordingT) Errorf(format string, args ...interface{}) { r.errors++ }
func (r *recordingT) Fatalf(format string, args ...interface{}) { r.fatals++ }
func (r *recordingT) Helper()                                   {}

func TestHarness_CleanRunPasses(t *testing.T) {
	mock := executor.NewMockExecutor()
	dir := t.TempDir()
	h := NewPurityHarness(mock, dir)
	rec := &recordingT{}
	h.AssertAllPurity(rec)
	if rec.errors != 0 || rec.fatals != 0 {
		t.Errorf("clean run flagged %d errors / %d fatals", rec.errors, rec.fatals)
	}
}

func TestHarness_CatchesExecutorWrites(t *testing.T) {
	mock := executor.NewMockExecutor()
	_ = mock.WriteFileAtomic("/var/lib/nftban/state/install_state", []byte("x"), 0600)
	h := NewPurityHarness(mock, t.TempDir())
	rec := &recordingT{}
	h.AssertNoExecutorWrites(rec)
	if rec.errors == 0 {
		t.Error("harness must flag executor WriteFileAtomic call")
	}
}

func TestHarness_CatchesMkdirAll(t *testing.T) {
	mock := executor.NewMockExecutor()
	_ = mock.MkdirAll("/var/lib/nftban/state", 0750)
	h := NewPurityHarness(mock, t.TempDir())
	rec := &recordingT{}
	h.AssertNoDirectoryCreations(rec)
	if rec.errors == 0 {
		t.Error("harness must flag executor MkdirAll call")
	}
}

func TestHarness_CatchesForbiddenCommand(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Run("nft", "add", "rule", "ip", "nftban", "input", "accept")
	h := NewPurityHarness(mock, t.TempDir())
	rec := &recordingT{}
	h.AssertNoMutationCommands(rec)
	if rec.errors == 0 {
		t.Error("harness must flag 'nft add' command")
	}
}

func TestHarness_CatchesDirectFilesystemWrite(t *testing.T) {
	dir := t.TempDir()
	// Direct os.WriteFile bypassing the executor — the bug class that
	// escaped PR-22.
	path := filepath.Join(dir, "uninstall_plan.json")
	if err := os.WriteFile(path, []byte("{}"), 0600); err != nil {
		t.Fatal(err)
	}

	mock := executor.NewMockExecutor()
	h := NewPurityHarness(mock, dir)
	rec := &recordingT{}
	h.AssertNoStateDirEntries(rec)
	if rec.errors == 0 {
		t.Error("harness must flag direct filesystem write under state dir")
	}
}
