// =============================================================================
// NFTBan v1.73 - Installer Rebuild Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-switchop-rebuild-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Tests for nftban firewall rebuild operations"
//
// v1.228.5: MockExecutor keys results by the COLON-JOINED argv
// (executor/mock.go Run -> RunTimeout), so these keys must track the exact argv
// switchop.Rebuild passes. Rebuild now sends --install-context, which tells the
// pre-daemon rebuild to DEFER the durable whitelist projection rather than treat
// the intentionally-absent daemon as a failure. A stale key here does NOT error:
// the mock simply misses and returns a zero-value Result{ExitCode: 0}, so a test
// expecting exit 1 or 2 fails with a confusing "got 0". Keep these in sync.
// meta:inventory.files="internal/installer/switchop/rebuild_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package switchop

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newTestLogger() *logging.Logger {
	return logging.New("/dev/null", false)
}

func TestRebuild_Success(t *testing.T) {
	mock := executor.NewMockExecutor()
	// v1.228.5: these tests assert SPECIFIC exit codes, so a stale argv key must
	// fail loudly (exit 255) rather than silently returning success. See mock.go.
	mock.StrictUnregistered = true
	publishResult(t, mock, "COMPLETE", 0, nil)

	err := Rebuild(mock, newTestLogger())
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}
}

func TestRebuild_Degraded(t *testing.T) {
	// ⛔ v1.229.12 P12-A01b — INVERTED, NOT DELETED.
	// RETIRED property: rc==1 + "DEGRADED" text authorizes install continuation.
	// This test is retained as the direct FALSIFIER for that fail-open: rc and text
	// alone, with no published result record, must now ABORT the install.
	mock := executor.NewMockExecutor()
	// v1.228.5: these tests assert SPECIFIC exit codes, so a stale argv key must
	// fail loudly (exit 255) rather than silently returning success. See mock.go.
	mock.StrictUnregistered = true
	runNoRecord(t, mock, 1, "DEGRADED", "")

	err := Rebuild(mock, newTestLogger())
	if err == nil {
		t.Fatal("rc=1 with NO result record must ABORT the install (A01b falsifier)")
	}
	if !mock.FileExists("/run/nftban/install_failed") {
		t.Error("install_failed marker MUST be written when no valid result contract exists")
	}
}

func TestRebuild_Failure(t *testing.T) {
	// Exit 2 = FAILED: rebuild failed, rollback happened.
	mock := executor.NewMockExecutor()
	// v1.228.5: these tests assert SPECIFIC exit codes, so a stale argv key must
	// fail loudly (exit 255) rather than silently returning success. See mock.go.
	mock.StrictUnregistered = true
	mock.RunResults["/usr/sbin/nftban:firewall:rebuild:--install-context"] = executor.Result{ExitCode: 2, Stderr: "rebuild failed"}

	err := Rebuild(mock, newTestLogger())
	if err == nil {
		t.Fatal("exit 2 (FAILED) should return error, got nil")
	}

	// Verify install-failed marker was written
	if !mock.FileExists("/run/nftban/install_failed") {
		t.Error("expected install_failed marker to be written")
	}
}

// ----------------------------------------------------------------------------
// v1.151 BUG-REBUILD-DEGRADED-EMPTY-REASON: degraded rebuild must log a real
// reason and must NOT log the self-contradictory "completed (exit 1)".
// ----------------------------------------------------------------------------

func readLog(t *testing.T) (*logging.Logger, func() string) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "installer.log")
	l := logging.New(p, false)
	return l, func() string {
		l.Close()
		b, _ := os.ReadFile(p)
		return string(b)
	}
}

func TestRebuild_DegradedReason_FromStdout_NoContradiction(t *testing.T) {
	// Real recoverable case: exit 1 with EMPTY stderr; reason is on stdout.
	mock := executor.NewMockExecutor()
	// v1.228.5: these tests assert SPECIFIC exit codes, so a stale argv key must
	// fail loudly (exit 255) rather than silently returning success. See mock.go.
	mock.StrictUnregistered = true
	// ⛔ INVERTED (P12-A01b): human-readable text on stdout/stderr can never authorize
	// continuation. The reason-recovery logic it used to assert is retired with the
	// contract that made rc semantic.
	runNoRecord(t, mock, 1, "", "base schema applied\nmodule chains pending daemon")
	log, _ := readLog(t)
	if err := Rebuild(mock, log); err == nil {
		t.Fatal("stdout/stderr wording must NOT authorize continuation without a result record")
	}
}

func TestRebuild_DegradedEmptyOutput_StaticReason(t *testing.T) {
	// ⛔ INVERTED (P12-A01b): a STATIC FALLBACK REASON cannot manufacture a valid verdict.
	// The old contract synthesised text when stdout+stderr were empty and continued anyway.
	mock := executor.NewMockExecutor()
	mock.StrictUnregistered = true
	runNoRecord(t, mock, 1, "", "")
	if err := Rebuild(mock, newTestLogger()); err == nil {
		t.Fatal("empty output + rc=1 + no result record must ABORT (no synthesised verdict)")
	}

}

func TestRebuild_Success_PlainCompleted(t *testing.T) {
	mock := executor.NewMockExecutor()
	// v1.228.5: these tests assert SPECIFIC exit codes, so a stale argv key must
	// fail loudly (exit 255) rather than silently returning success. See mock.go.
	mock.StrictUnregistered = true
	publishResult(t, mock, "COMPLETE", 0, nil)
	log, dump := readLog(t)
	if err := Rebuild(mock, log); err != nil {
		t.Fatalf("exit 0 must not error: %v", err)
	}
	out := dump()
	if !strings.Contains(out, "firewall rebuild COMPLETE") {
		t.Errorf("expected 'firewall rebuild COMPLETE'; got:\n%s", out)
	}
	if strings.Contains(out, "completed (exit") {
		t.Errorf("exit 0 must log plain 'completed', not 'completed (exit N)'; got:\n%s", out)
	}
}
