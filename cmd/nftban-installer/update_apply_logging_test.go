// =============================================================================
// NFTBan v1.99 PR-20 — Update Apply Logging Tests (G3-U15/U16/U17)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-update-apply-logging-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Verify PR-20 adds observability without changing behavior"
// meta:inventory.files="cmd/nftban-installer/update_apply_logging_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// PR-20 is observability only. These tests assert:
//
//   T-L1  from → to version line emitted after preflight detection
//   T-L2  "already up-to-date" marker when current == target
//   T-L3  per-phase duration_ms + result line at PhaseEnd
//   T-L4  end-of-run trailer with key=value pairs
//   T-L5  trailer fires on every exit branch (preflight-fail / rebuild-fail /
//         validator-fail / happy) via defer
//   T-L6  call-path purity preserved — no new commands added by logging
//
// =============================================================================
package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/internal/installer/update"
)

// newLoggingTestLogger returns a Logger that writes to a tempfile inside
// the test's own dir. The returned path is where the test reads logs back
// from.
func newLoggingTestLogger(t *testing.T) (*logging.Logger, string) {
	t.Helper()
	logPath := filepath.Join(t.TempDir(), "test.log")
	return logging.New(logPath, true), logPath
}

// readLog returns the captured log contents as a single string.
func readLog(t *testing.T, logPath string) string {
	t.Helper()
	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	return string(data)
}

// T-L1 — from → to version line emitted after preflight detection.
func TestUpdateApplyLog_EmitsFromToLine(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(mock)
	// Source install — DetectVersions reads VERSION from sourceDir too.
	mock.Files["/tmp/srcdir/VERSION"] = []byte("2.0.0\n")
	mock.Files["/usr/lib/nftban/VERSION"] = []byte("1.99.0\n")

	cfg := &config{mode: "upgrade", stateDir: t.TempDir(), source: true, sourceDir: "/tmp/srcdir"}
	sf := state.NewStateFile(cfg.stateDir)

	log, logPath := newLoggingTestLogger(t)
	_ = runUpdateApply(context.Background(), mock, sf, cfg, log)
	log.Close()

	content := readLog(t, logPath)
	if !strings.Contains(content, "update apply: 1.99.0 → 2.0.0") {
		t.Errorf("log missing from→to line:\n%s", content)
	}
}

// T-L2 — "already up-to-date" marker when current == target.
func TestUpdateApplyLog_AlreadyUpToDateMarker(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(mock)
	// current == target == 1.99.0
	mock.Files["/tmp/srcdir/VERSION"] = []byte("1.99.0\n")
	mock.Files["/usr/lib/nftban/VERSION"] = []byte("1.99.0\n")

	cfg := &config{mode: "upgrade", stateDir: t.TempDir(), source: true, sourceDir: "/tmp/srcdir"}
	sf := state.NewStateFile(cfg.stateDir)

	log, logPath := newLoggingTestLogger(t)
	_ = runUpdateApply(context.Background(), mock, sf, cfg, log)
	log.Close()

	content := readLog(t, logPath)
	if !strings.Contains(content, "already up-to-date") {
		t.Errorf("log missing idempotency marker when current == target:\n%s", content)
	}
	if !strings.Contains(content, "rebuild will no-op") {
		t.Error("idempotency marker should clarify rebuild handles no-op")
	}
}

// T-L3 — per-phase duration_ms + result line at PhaseEnd.
func TestUpdateApplyLog_PhaseDurationAndResult(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(mock)

	cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
	sf := state.NewStateFile(cfg.stateDir)

	log, logPath := newLoggingTestLogger(t)
	_ = runUpdateApply(context.Background(), mock, sf, cfg, log)
	log.Close()

	content := readLog(t, logPath)
	for _, phase := range []string{"Preflight", "Rebuild", "Validate"} {
		needle := "phase " + phase + " duration_ms="
		if !strings.Contains(content, needle) {
			t.Errorf("log missing duration marker for phase %q:\n%s", phase, content)
		}
	}
	if !strings.Contains(content, "result=pass") {
		t.Error("log missing phase pass/fail marker")
	}
}

// T-L4 — trailer contains the documented key=value pairs.
func TestUpdateApplyLog_TrailerFields(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(mock)

	cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
	sf := state.NewStateFile(cfg.stateDir)

	log, logPath := newLoggingTestLogger(t)
	_ = runUpdateApply(context.Background(), mock, sf, cfg, log)
	log.Close()

	content := readLog(t, logPath)
	if !strings.Contains(content, "update apply trailer:") {
		t.Fatalf("log missing trailer line:\n%s", content)
	}
	for _, key := range []string{
		"mode=", "from=", "to=",
		"phases_passed=", "phases_failed=",
		"duration_ms=", "exit=", "final_state=",
	} {
		if !strings.Contains(content, key) {
			t.Errorf("trailer missing key %q", key)
		}
	}
}

// T-L5 — trailer fires on every exit branch (defer coverage).
func TestUpdateApplyLog_TrailerFiresOnEveryBranch(t *testing.T) {
	branches := []struct {
		name  string
		setup func(*executor.MockExecutor)
	}{
		{"happy", func(m *executor.MockExecutor) {}},
		{"preflight-fail", func(m *executor.MockExecutor) {
			delete(m.NftTables, "ip:nftban")
		}},
		{"rebuild-fail", func(m *executor.MockExecutor) {
			m.RunResults["nftban:firewall:rebuild"] = executor.Result{ExitCode: 2}
		}},
		{"validator-fail", func(m *executor.MockExecutor) {
			m.RunResults["nftban-validate:--json"] = executor.Result{ExitCode: 2}
		}},
	}
	for _, b := range branches {
		b := b
		t.Run(b.name, func(t *testing.T) {
			mock := executor.NewMockExecutor()
			seedHappyApplyHost(mock)
			b.setup(mock)
			cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
			sf := state.NewStateFile(cfg.stateDir)

			log, logPath := newLoggingTestLogger(t)
			_ = runUpdateApply(context.Background(), mock, sf, cfg, log)
			log.Close()

			content := readLog(t, logPath)
			if !strings.Contains(content, "update apply trailer:") {
				t.Errorf("[%s] trailer not emitted:\n%s", b.name, content)
			}
		})
	}
}

// T-L6 — logging additions did not broaden the call path.
func TestUpdateApplyLog_CallPathPurityPreserved(t *testing.T) {
	mock := executor.NewMockExecutor()
	seedHappyApplyHost(mock)

	cfg := &config{mode: "upgrade", stateDir: t.TempDir()}
	sf := state.NewStateFile(cfg.stateDir)

	log, _ := newLoggingTestLogger(t)
	_ = runUpdateApply(context.Background(), mock, sf, cfg, log)
	log.Close()

	trace := cmdTrace(mock)
	if v := update.AuditRecordedCommands(trace); len(v) != 0 {
		t.Errorf("PR-20 logging additions broke call-path purity:\n%s", strings.Join(v, "\n"))
	}
	if v := update.AuditWrittenFiles(writtenPaths(mock)); len(v) != 0 {
		t.Errorf("PR-20 logging additions broke write-path purity:\n%s", strings.Join(v, "\n"))
	}
}
