// =============================================================================
// NFTBan v1.154.0 - Timer Wedge-Recovery Mock Test
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-services-timers-post-install-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-06"
// meta:description="Mock-Executor test: only wedged nftban timers are restarted; healthy/inactive/uninstalled ones are not"
// meta:inventory.files="internal/installer/services/timers_post_install_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftban-*.timer"
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package services

import (
	"context"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// showKey builds the RunResults map key for the wedge-probe command the
// implementation issues: systemctl show <timer> -p ActiveState -p
// NextElapseUSecRealtime --value. The mock keys on "name:arg1:arg2:...".
func showKey(timer string) string {
	return strings.Join([]string{
		"systemctl", "show", timer,
		"-p", "ActiveState", "-p", "NextElapseUSecRealtime", "--value",
	}, ":")
}

// restartCalled reports whether `systemctl restart <timer>` was recorded.
func restartCalled(m *executor.MockExecutor, timer string) bool {
	for _, c := range m.Commands {
		if c.Name == "systemctl" && len(c.Args) >= 2 && c.Args[0] == "restart" && c.Args[1] == timer {
			return true
		}
	}
	return false
}

// installTimer marks a timer unit file as present so timerUnitInstalled() is true.
func installTimer(m *executor.MockExecutor, timer string) {
	m.Files["/usr/lib/systemd/system/"+timer] = []byte("[Timer]\n")
}

// TestRestartWedgedTimers_OnlyWedgedRestarted is the core contract: given a mix
// of wedged, healthy, inactive, and uninstalled timers, ONLY the wedged ones
// are restarted, daemon-reload is issued exactly once, and the implementation
// never aborts (warn-only).
func TestRestartWedgedTimers_OnlyWedgedRestarted(t *testing.T) {
	mock := executor.NewMockExecutor()

	// wedged: active + no next trigger
	wedged := "nftban-unified-exporter.timer"
	// wedged2: active + next trigger == "0"
	wedged2 := "nftban-health.timer"
	// healthy: active + real next trigger
	healthy := "nftban-maintenance.timer"
	// inactive: legitimately no trigger (disabled/stopped)
	inactive := "nftban-queue.timer"
	// uninstalled: probe never reached (unit file absent)
	uninstalled := "nftban-core-feeds.timer"

	for _, tmr := range []string{wedged, wedged2, healthy, inactive} {
		installTimer(mock, tmr)
	}
	// uninstalled: deliberately NOT installed.

	// Probe results. With multiple -p props + --value, systemctl prints one
	// value per line in request order: ActiveState, then NextElapseUSecRealtime.
	mock.RunResults[showKey(wedged)] = executor.Result{ExitCode: 0, Stdout: "active\nn/a\n"}
	mock.RunResults[showKey(wedged2)] = executor.Result{ExitCode: 0, Stdout: "active\n0\n"}
	mock.RunResults[showKey(healthy)] = executor.Result{ExitCode: 0, Stdout: "active\n1717689600000000\n"}
	mock.RunResults[showKey(inactive)] = executor.Result{ExitCode: 0, Stdout: "inactive\n0\n"}

	timers := []string{wedged, wedged2, healthy, inactive, uninstalled}
	RestartWedgedTimers(context.Background(), mock, newTestLogger(), timers)

	// daemon-reload exactly once.
	if n := mock.CommandCallCount("systemctl", "daemon-reload"); n != 1 {
		t.Errorf("expected exactly 1 daemon-reload, got %d", n)
	}

	// Wedged timers restarted.
	if !restartCalled(mock, wedged) {
		t.Errorf("%s is wedged (Trigger=n/a) but was NOT restarted", wedged)
	}
	if !restartCalled(mock, wedged2) {
		t.Errorf("%s is wedged (next-elapse=0) but was NOT restarted", wedged2)
	}

	// Healthy / inactive / uninstalled timers NOT restarted.
	if restartCalled(mock, healthy) {
		t.Errorf("%s is healthy but was needlessly restarted", healthy)
	}
	if restartCalled(mock, inactive) {
		t.Errorf("%s is inactive but was needlessly restarted", inactive)
	}
	if restartCalled(mock, uninstalled) {
		t.Errorf("%s is not installed but was restarted", uninstalled)
	}

	// Uninstalled timer must not even be probed.
	if _, probed := mock.RunResults[showKey(uninstalled)]; probed {
		t.Fatalf("test setup error: uninstalled timer should have no probe result")
	}
	for _, c := range mock.Commands {
		if c.Name == "systemctl" && len(c.Args) >= 3 && c.Args[0] == "show" && c.Args[1] == uninstalled {
			t.Errorf("uninstalled timer %s was probed; should be skipped before probe", uninstalled)
		}
	}
}

// TestRestartWedgedTimers_RestartErrorNonFatal asserts a failing restart does
// NOT abort the pass: a wedged timer ordered before another wedged timer fails
// to restart, yet the later wedged timer is still probed and restarted.
func TestRestartWedgedTimers_RestartErrorNonFatal(t *testing.T) {
	mock := executor.NewMockExecutor()

	first := "nftban-unified-exporter.timer"
	second := "nftban-health.timer"
	installTimer(mock, first)
	installTimer(mock, second)

	mock.RunResults[showKey(first)] = executor.Result{ExitCode: 0, Stdout: "active\nn/a\n"}
	mock.RunResults[showKey(second)] = executor.Result{ExitCode: 0, Stdout: "active\nn/a\n"}

	// First restart fails (non-zero exit); must not stop the loop.
	mock.RunResults["systemctl:restart:"+first] = executor.Result{ExitCode: 1, Stderr: "boom"}

	RestartWedgedTimers(context.Background(), mock, newTestLogger(), []string{first, second})

	if !restartCalled(mock, first) {
		t.Errorf("%s restart should have been attempted", first)
	}
	if !restartCalled(mock, second) {
		t.Errorf("%s should still be restarted after %s's restart failed (warn-only)", second, first)
	}
}

// TestRestartWedgedTimers_ProbeErrorTreatedHealthy asserts that a probe failure
// (non-zero exit) is treated as NOT wedged — never restart on uncertain
// evidence (zero false positives).
func TestRestartWedgedTimers_ProbeErrorTreatedHealthy(t *testing.T) {
	mock := executor.NewMockExecutor()

	tmr := "nftban-unified-exporter.timer"
	installTimer(mock, tmr)
	mock.RunResults[showKey(tmr)] = executor.Result{ExitCode: 1, Stderr: "Failed to get properties"}

	RestartWedgedTimers(context.Background(), mock, newTestLogger(), []string{tmr})

	if restartCalled(mock, tmr) {
		t.Errorf("%s probe errored; must NOT be restarted (uncertain evidence)", tmr)
	}
}

// TestRestartWedgedTimers_NoneWedged asserts daemon-reload still runs once and
// nothing is restarted when every installed timer is healthy.
func TestRestartWedgedTimers_NoneWedged(t *testing.T) {
	mock := executor.NewMockExecutor()

	tmr := "nftban-maintenance.timer"
	installTimer(mock, tmr)
	mock.RunResults[showKey(tmr)] = executor.Result{ExitCode: 0, Stdout: "active\n1717689600000000\n"}

	RestartWedgedTimers(context.Background(), mock, newTestLogger(), KnownTimers())

	if n := mock.CommandCallCount("systemctl", "daemon-reload"); n != 1 {
		t.Errorf("expected exactly 1 daemon-reload, got %d", n)
	}
	if restartCalled(mock, tmr) {
		t.Errorf("healthy %s should not be restarted", tmr)
	}
}
