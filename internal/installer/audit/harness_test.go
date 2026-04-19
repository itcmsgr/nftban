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
// These tests exercise the Check* methods directly (which return
// violation lists) and verify that each contract violation produces a
// non-empty list. No testing.TB mock required.
//
// =============================================================================
package audit

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

func TestHarness_CleanRun_NoViolations(t *testing.T) {
	mock := executor.NewMockExecutor()
	h := NewPurityHarness(mock, t.TempDir())
	if v := h.CheckExecutorWrites(); len(v) != 0 {
		t.Errorf("clean run: CheckExecutorWrites returned %v", v)
	}
	if v := h.CheckDirectoryCreations(); len(v) != 0 {
		t.Errorf("clean run: CheckDirectoryCreations returned %v", v)
	}
	if v := h.CheckMutationCommands(); len(v) != 0 {
		t.Errorf("clean run: CheckMutationCommands returned %v", v)
	}
	if v := h.CheckStateDirEntries(); len(v) != 0 {
		t.Errorf("clean run: CheckStateDirEntries returned %v", v)
	}
}

func TestHarness_CatchesExecutorWrites(t *testing.T) {
	mock := executor.NewMockExecutor()
	_ = mock.WriteFileAtomic("/var/lib/nftban/state/install_state", []byte("x"), 0600)
	h := NewPurityHarness(mock, t.TempDir())
	if v := h.CheckExecutorWrites(); len(v) == 0 {
		t.Error("harness must flag executor WriteFileAtomic call; returned no violations")
	}
}

func TestHarness_CatchesMkdirAll(t *testing.T) {
	mock := executor.NewMockExecutor()
	_ = mock.MkdirAll("/var/lib/nftban/state", 0750)
	h := NewPurityHarness(mock, t.TempDir())
	if v := h.CheckDirectoryCreations(); len(v) == 0 {
		t.Error("harness must flag executor MkdirAll call; returned no violations")
	}
}

func TestHarness_CatchesForbiddenCommand(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Run("nft", "add", "rule", "ip", "nftban", "input", "accept")
	h := NewPurityHarness(mock, t.TempDir())
	if v := h.CheckMutationCommands(); len(v) == 0 {
		t.Error("harness must flag 'nft add' command; returned no violations")
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
	if v := h.CheckStateDirEntries(); len(v) == 0 {
		t.Error("harness must flag direct filesystem write under state dir; returned no violations")
	}
}
