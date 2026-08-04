// =============================================================================
// NFTBan v1.73 - Installer Rebuild Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
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
	mock.RunResults["/usr/sbin/nftban:firewall:rebuild:--install-context"] = executor.Result{ExitCode: 0}

	err := Rebuild(mock, newTestLogger())
	if err != nil {
		t.Fatalf("expected success, got: %v", err)
	}
}

func TestRebuild_Degraded(t *testing.T) {
	// Exit 1 = DEGRADED: firewall operational but module checks failed.
	// This is expected during upgrade and must NOT return an error.
	mock := executor.NewMockExecutor()
	// v1.228.5: these tests assert SPECIFIC exit codes, so a stale argv key must
	// fail loudly (exit 255) rather than silently returning success. See mock.go.
	mock.StrictUnregistered = true
	mock.RunResults["/usr/sbin/nftban:firewall:rebuild:--install-context"] = executor.Result{ExitCode: 1, Stderr: "DEGRADED"}

	err := Rebuild(mock, newTestLogger())
	if err != nil {
		t.Fatalf("exit 1 (DEGRADED) should not return error, got: %v", err)
	}

	// Verify install-failed marker was NOT written for degraded
	if mock.FileExists("/run/nftban/install_failed") {
		t.Error("install_failed marker should not be written for DEGRADED")
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
	mock.RunResults["/usr/sbin/nftban:firewall:rebuild:--install-context"] = executor.Result{
		ExitCode: 1, Stderr: "", Stdout: "base schema applied\nmodule chains pending daemon",
	}
	log, dump := readLog(t)
	if err := Rebuild(mock, log); err != nil {
		t.Fatalf("exit 1 (DEGRADED) must not error: %v", err)
	}
	out := dump()
	if !strings.Contains(out, "DEGRADED (exit 1): module chains pending daemon") {
		t.Errorf("expected reason recovered from stdout; got:\n%s", out)
	}
	if strings.Contains(out, "completed (exit 1)") {
		t.Errorf("must NOT log self-contradictory 'completed (exit 1)'; got:\n%s", out)
	}
	if !strings.Contains(out, "finished DEGRADED (exit 1)") {
		t.Errorf("expected 'finished DEGRADED (exit 1)' wording; got:\n%s", out)
	}
}

func TestRebuild_DegradedEmptyOutput_StaticReason(t *testing.T) {
	// exit 1 with empty stderr AND empty stdout → static fallback reason (never blank).
	mock := executor.NewMockExecutor()
	// v1.228.5: these tests assert SPECIFIC exit codes, so a stale argv key must
	// fail loudly (exit 255) rather than silently returning success. See mock.go.
	mock.StrictUnregistered = true
	mock.RunResults["/usr/sbin/nftban:firewall:rebuild:--install-context"] = executor.Result{ExitCode: 1}
	log, dump := readLog(t)
	_ = Rebuild(mock, log)
	out := dump()
	if !strings.Contains(out, "DEGRADED (exit 1): base schema loaded; module chains deferred to daemon start") {
		t.Errorf("expected static fallback reason (never blank); got:\n%s", out)
	}
	if strings.Contains(out, "completed (exit 1)") {
		t.Errorf("must NOT log 'completed (exit 1)'; got:\n%s", out)
	}
}

func TestRebuild_Success_PlainCompleted(t *testing.T) {
	mock := executor.NewMockExecutor()
	// v1.228.5: these tests assert SPECIFIC exit codes, so a stale argv key must
	// fail loudly (exit 255) rather than silently returning success. See mock.go.
	mock.StrictUnregistered = true
	mock.RunResults["/usr/sbin/nftban:firewall:rebuild:--install-context"] = executor.Result{ExitCode: 0}
	log, dump := readLog(t)
	if err := Rebuild(mock, log); err != nil {
		t.Fatalf("exit 0 must not error: %v", err)
	}
	out := dump()
	if !strings.Contains(out, "firewall rebuild completed") {
		t.Errorf("expected 'firewall rebuild completed'; got:\n%s", out)
	}
	if strings.Contains(out, "completed (exit") {
		t.Errorf("exit 0 must log plain 'completed', not 'completed (exit N)'; got:\n%s", out)
	}
}
