// =============================================================================
// NFTBan v1.73 - Installer Services Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-services-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Tests for daemon, timers, cleanup, whitelist, panel, login"
// meta:inventory.files="internal/installer/services/services_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package services

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newTestLogger() *logging.Logger {
	return logging.New("/dev/null", false)
}

func TestStartDaemon(t *testing.T) {
	mock := executor.NewMockExecutor()
	StartDaemon(mock, newTestLogger())

	// After start, mock auto-sets services active
	if !mock.ServiceActive("nftband.service") {
		t.Error("expected nftband.service to be active")
	}
}

// TestStartDaemon_UnmasksNftbandBeforeEnable — v1.100.4 defensive
// belt for UPSTREAM-UNINSTALL-INCOMPLETE-001. A prior uninstall may
// have left a phantom mask symlink at /etc/systemd/system/nftband.service
// -> /dev/null; install must call ServiceUnmask before ServiceEnable.
func TestStartDaemon_UnmasksNftbandBeforeEnable(t *testing.T) {
	mock := executor.NewMockExecutor()
	StartDaemon(mock, newTestLogger())

	unmaskIdx, enableIdx := -1, -1
	for i, c := range mock.Commands {
		switch {
		case c.Name == "systemctl" && len(c.Args) >= 2 && c.Args[0] == "unmask" && c.Args[1] == "nftband.service":
			if unmaskIdx < 0 {
				unmaskIdx = i
			}
		case c.Name == "systemctl" && len(c.Args) >= 2 && c.Args[0] == "enable" && c.Args[1] == "nftband.service":
			if enableIdx < 0 {
				enableIdx = i
			}
		}
	}
	if unmaskIdx < 0 {
		t.Fatal("StartDaemon must invoke ServiceUnmask(nftband.service); never called")
	}
	if enableIdx < 0 {
		t.Fatal("StartDaemon must invoke ServiceEnable(nftband.service); never called")
	}
	if unmaskIdx >= enableIdx {
		t.Errorf("ServiceUnmask at index %d must precede ServiceEnable at index %d", unmaskIdx, enableIdx)
	}
}

func TestReconcileTimers_Default(t *testing.T) {
	mock := executor.NewMockExecutor()
	// No config file → default is reconcile=true
	ReconcileTimers(mock, newTestLogger())

	// Verify core timers were started (mock records commands)
	found := false
	for _, cmd := range mock.Commands {
		if cmd.Name == "systemctl" && len(cmd.Args) >= 2 && cmd.Args[0] == "enable" && cmd.Args[1] == "nftban-maintenance.timer" {
			found = true
			break
		}
	}
	if !found {
		t.Error("expected nftban-maintenance.timer to be enabled")
	}
}

func TestReconcileTimers_Disabled(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files["/etc/nftban/nftban.conf"] = []byte("NFTBAN_RECONCILE_CORE_TIMERS=\"false\"\n")

	ReconcileTimers(mock, newTestLogger())

	// Should NOT have enabled any timers
	for _, cmd := range mock.Commands {
		if cmd.Name == "systemctl" && len(cmd.Args) >= 2 && cmd.Args[0] == "enable" {
			t.Errorf("unexpected timer enable: %v", cmd.Args)
		}
	}
}

func TestReconcileTimers_LocalOverride(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files["/etc/nftban/nftban.conf"] = []byte("NFTBAN_RECONCILE_CORE_TIMERS=\"true\"\n")
	mock.Files["/etc/nftban/nftban.conf.local"] = []byte("NFTBAN_RECONCILE_CORE_TIMERS=\"false\"\n")

	ReconcileTimers(mock, newTestLogger())

	// local override disables → no timers enabled
	for _, cmd := range mock.Commands {
		if cmd.Name == "systemctl" && len(cmd.Args) >= 2 && cmd.Args[0] == "enable" {
			t.Errorf("unexpected timer enable: %v", cmd.Args)
		}
	}
}

func TestCleanStaleFiles(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Files["/etc/systemd/system/nftban-loginmon.service"] = []byte("stale")
	mock.Files["/etc/systemd/system/nftban-collector.timer"] = []byte("stale")
	mock.Files["/etc/polkit-1/rules.d/49-nftban-collector.rules"] = []byte("stale")

	CleanStaleFiles(mock, newTestLogger())

	if mock.FileExists("/etc/systemd/system/nftban-loginmon.service") {
		t.Error("expected loginmon service to be removed")
	}
	if mock.FileExists("/etc/polkit-1/rules.d/49-nftban-collector.rules") {
		t.Error("expected polkit rules to be removed")
	}
}

func TestCleanStaleFiles_NothingStale(t *testing.T) {
	mock := executor.NewMockExecutor()
	CleanStaleFiles(mock, newTestLogger())
	// Should complete without error
}

func TestSyncWhitelist(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["/usr/sbin/nftban:sync"] = executor.Result{ExitCode: 0}

	SyncWhitelist(mock, newTestLogger())
}

func TestEnablePanel_None(t *testing.T) {
	mock := executor.NewMockExecutor()
	EnablePanel(mock, detect.PanelNone, newTestLogger())
	// Should be a no-op — no commands recorded for nftban
}

func TestEnablePanel_CPanel(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["/usr/sbin/nftban:services:enable:cpanel"] = executor.Result{ExitCode: 0}

	EnablePanel(mock, detect.PanelCPanel, newTestLogger())
}

func TestEnableLogin(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.RunResults["/usr/sbin/nftban:login:enable"] = executor.Result{ExitCode: 0}

	EnableLogin(mock, newTestLogger())
}
