// =============================================================================
// NFTBan v1.160 - Installer Logger warning-accounting tests (PR-A)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="logger_warncount_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-07"
// meta:description="v1.160 PR-A: verifies installer Logger warning truth-accounting — Warn() tallies non-fatal warnings (count + captured messages) so the final operator summary reports them honestly; accessors return a stable, copy-safe view."
// meta:input="Logger.Warn()/WarnCount()/Warnings() calls over a t.TempDir() log file"
// meta:output="t.Error on miscount or shared-slice mutation"
// meta:depends="testing,os,path/filepath"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package logging

import (
	"path/filepath"
	"testing"
)

// newTestLogger builds a Logger backed by a temp file so Warn()'s console+file
// writes have somewhere to go without touching the real /var/log path.
func newTestLogger(t *testing.T) *Logger {
	t.Helper()
	p := filepath.Join(t.TempDir(), "installer.log")
	l := New(p, false)
	t.Cleanup(l.Close)
	return l
}

func TestWarnCountZeroWhenNoWarnings(t *testing.T) {
	l := newTestLogger(t)
	if got := l.WarnCount(); got != 0 {
		t.Fatalf("WarnCount() = %d, want 0", got)
	}
	if got := l.Warnings(); len(got) != 0 {
		t.Fatalf("Warnings() len = %d, want 0", len(got))
	}
}

func TestWarnCountIncrements(t *testing.T) {
	l := newTestLogger(t)

	l.Warn("systemd-tmpfiles failed (exit %d)", 73)
	l.Warn("permissions enforce failed (exit %d)", 1)
	l.Warn("plain warning")

	if got := l.WarnCount(); got != 3 {
		t.Fatalf("WarnCount() = %d, want 3", got)
	}

	got := l.Warnings()
	if len(got) != 3 {
		t.Fatalf("Warnings() len = %d, want 3", len(got))
	}
	want := []string{
		"systemd-tmpfiles failed (exit 73)",
		"permissions enforce failed (exit 1)",
		"plain warning",
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("Warnings()[%d] = %q, want %q", i, got[i], want[i])
		}
	}
}

// Info/Error/Debug must not be tallied as warnings — only Warn() counts.
func TestNonWarnLevelsDoNotIncrement(t *testing.T) {
	l := newTestLogger(t)

	l.Info("informational")
	l.Error("an error")
	l.Debug("a debug line")

	if got := l.WarnCount(); got != 0 {
		t.Fatalf("WarnCount() = %d after non-Warn calls, want 0", got)
	}
}

// Warnings() must return a copy — mutating the result must not affect the
// logger's internal slice.
func TestWarningsReturnsCopy(t *testing.T) {
	l := newTestLogger(t)
	l.Warn("first")

	snap := l.Warnings()
	snap[0] = "tampered"

	again := l.Warnings()
	if again[0] != "first" {
		t.Fatalf("Warnings() leaked internal slice: got %q after caller mutation", again[0])
	}
}
