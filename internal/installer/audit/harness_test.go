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
// These tests confirm the harness fires (via t.Errorf) on each of the
// contract violations it exists to detect, and passes when the contract
// is respected. The trick: testing.TB cannot be implemented outside the
// testing package (it has an unexported method), so we use t.Run's
// return value to observe whether an inner subtest failed.
//
// =============================================================================
package audit

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// expectInnerFail runs the given assertion inside a subtest and reports
// whether the inner subtest failed (which is what we want, for each
// "harness must catch X" test). If the inner test PASSED, this helper
// marks the outer test failed — meaning the harness missed a violation.
func expectInnerFail(t *testing.T, name string, assertion func(tb testing.TB)) {
	t.Helper()
	innerPassed := t.Run(name, func(innerT *testing.T) {
		assertion(innerT)
	})
	if innerPassed {
		t.Errorf("%s: harness assertion did NOT fail as expected — contract violation went undetected", name)
	}
}

func TestHarness_CleanRunPasses(t *testing.T) {
	mock := executor.NewMockExecutor()
	dir := t.TempDir()
	h := NewPurityHarness(mock, dir)

	// Clean run must not fail any assertion.
	innerPassed := t.Run("clean", func(innerT *testing.T) {
		h.AssertAllPurity(innerT)
	})
	if !innerPassed {
		t.Error("harness flagged a clean run as violating — false positive")
	}
}

func TestHarness_CatchesExecutorWrites(t *testing.T) {
	mock := executor.NewMockExecutor()
	_ = mock.WriteFileAtomic("/var/lib/nftban/state/install_state", []byte("x"), 0600)
	h := NewPurityHarness(mock, t.TempDir())
	expectInnerFail(t, "executor-write", func(tb testing.TB) {
		h.AssertNoExecutorWrites(tb)
	})
}

func TestHarness_CatchesMkdirAll(t *testing.T) {
	mock := executor.NewMockExecutor()
	_ = mock.MkdirAll("/var/lib/nftban/state", 0750)
	h := NewPurityHarness(mock, t.TempDir())
	expectInnerFail(t, "mkdirall", func(tb testing.TB) {
		h.AssertNoDirectoryCreations(tb)
	})
}

func TestHarness_CatchesForbiddenCommand(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Run("nft", "add", "rule", "ip", "nftban", "input", "accept")
	h := NewPurityHarness(mock, t.TempDir())
	expectInnerFail(t, "forbidden-cmd", func(tb testing.TB) {
		h.AssertNoMutationCommands(tb)
	})
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
	expectInnerFail(t, "direct-fs-write", func(tb testing.TB) {
		h.AssertNoStateDirEntries(tb)
	})
}
