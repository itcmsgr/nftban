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

// hasTryRestart reports whether a `systemctl try-restart <unit>` was recorded.
func hasTryRestart(mock *executor.MockExecutor, unit string) bool {
	for _, cmd := range mock.Commands {
		if cmd.Name == "systemctl" && len(cmd.Args) >= 2 && cmd.Args[0] == "try-restart" && cmd.Args[1] == unit {
			return true
		}
	}
	return false
}

// TestStartDaemon_UpgradeOverLiveDaemon_TryRestarts — v1.185
// INSTALL-UPGRADE-NO-DAEMON-RESTART: when nftband.service is ALREADY active before
// StartDaemon runs (the upgrade-over-live-daemon case proven on dns2), the plain
// `start` is a no-op so the new binary must be loaded via try-restart.
func TestStartDaemon_UpgradeOverLiveDaemon_TryRestarts(t *testing.T) {
	mock := executor.NewMockExecutor()
	mock.Services["nftband.service"] = true // daemon already running (upgrade)

	StartDaemon(mock, newTestLogger())

	if !hasTryRestart(mock, "nftband.service") {
		t.Error("expected try-restart nftband.service on upgrade-over-live-daemon (stale-binary fix)")
	}
}

// TestStartDaemon_FreshInstall_NoTryRestart — on a fresh install the unit is inactive
// when StartDaemon runs, so the first-start is real and NO redundant try-restart fires.
func TestStartDaemon_FreshInstall_NoTryRestart(t *testing.T) {
	mock := executor.NewMockExecutor()
	// nftband.service inactive by default (fresh install)

	StartDaemon(mock, newTestLogger())

	if hasTryRestart(mock, "nftband.service") {
		t.Error("fresh install must not issue a redundant try-restart (only first-start)")
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

// TestReconcileTimers_GeobanRefreshEnabled — v1.156 PR-A. The geoban-refresh
// timer ships under install/systemd/ and is listed in the install set, but
// before v1.156 it was absent from coreTimers, so a default install left it
// installed-but-not-auto-enabled. This asserts the reconcile (coreTimers) loop
// now issues BOTH `systemctl enable` and `systemctl start` for it, matching the
// best-effort enableAndStart path used by the other core timers (it is NOT in
// criticalCoreTimers — failure must not DEGRADE the install).
func TestReconcileTimers_GeobanRefreshEnabled(t *testing.T) {
	mock := executor.NewMockExecutor()
	// No config file → default is reconcile=true.
	ReconcileTimers(mock, newTestLogger())

	enabled, started := false, false
	for _, cmd := range mock.Commands {
		if cmd.Name != "systemctl" || len(cmd.Args) < 2 {
			continue
		}
		if cmd.Args[1] != "nftban-geoban-refresh.timer" {
			continue
		}
		switch cmd.Args[0] {
		case "enable":
			enabled = true
		case "start":
			started = true
		}
	}
	if !enabled {
		t.Error("expected nftban-geoban-refresh.timer to be enabled (added to coreTimers in v1.156 PR-A)")
	}
	if !started {
		t.Error("expected nftban-geoban-refresh.timer to be started (best-effort enableAndStart)")
	}
}

// TestGeobanRefreshTimerInCoreTimers asserts the geoban-refresh timer is a
// member of the coreTimers reconcile set but is NOT in criticalCoreTimers
// (best-effort, must not DEGRADE the install on failure).
func TestGeobanRefreshTimerInCoreTimers(t *testing.T) {
	const geoban = "nftban-geoban-refresh.timer"

	inCore := false
	for _, n := range coreTimers {
		if n == geoban {
			inCore = true
			break
		}
	}
	if !inCore {
		t.Errorf("%s must be in coreTimers (v1.156 PR-A)", geoban)
	}

	for _, n := range criticalCoreTimers {
		if n == geoban {
			t.Errorf("%s must NOT be in criticalCoreTimers — keep best-effort", geoban)
		}
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
