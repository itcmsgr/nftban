// =============================================================================
// NFTBan v1.154.0 - Timer Wedge-Recovery Mock Test
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
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
// implementation issues (v1.235 T1: key=value, no --value). The mock keys on
// "name:arg1:arg2:...".
func showKey(timer string) string {
	return strings.Join([]string{
		"systemctl", "show", timer,
		"-p", "ActiveState", "-p", "Unit",
		"-p", "TimersCalendar", "-p", "TimersMonotonic",
		"-p", "NextElapseUSecRealtime", "-p", "NextElapseUSecMonotonic",
	}, ":")
}

// svcKey is the key for the triggered-service state probe.
func svcKey(unit string) string {
	return strings.Join([]string{"systemctl", "show", unit, "-p", "ActiveState"}, ":")
}

// svcFor maps "nftban-x.timer" to its service, as the Unit= property does.
func svcFor(timer string) string {
	return strings.TrimSuffix(timer, ".timer") + ".service"
}

// Probe fixtures in systemd's real property order (measured 2026-10-05 on
// systemd 252/255/257: Unit, Timers*, NextElapse*, ActiveState).
func calendarShow(timer, nextRealtime, active string) string {
	return "Unit=" + svcFor(timer) + "\n" +
		"TimersCalendar={ OnCalendar=*-*-* *:00/15:00 ; next_elapse=Mon 2026-10-05 20:30:00 UTC }\n" +
		"NextElapseUSecRealtime=" + nextRealtime + "\n" +
		"NextElapseUSecMonotonic=0\n" +
		"ActiveState=" + active + "\n"
}

func intervalShow(timer, nextMonotonic, active string) string {
	return "Unit=" + svcFor(timer) + "\n" +
		"TimersMonotonic={ OnUnitActiveUSec=2min ; next_elapse=0 }\n" +
		"TimersMonotonic={ OnBootUSec=2min ; next_elapse=0 }\n" +
		"NextElapseUSecRealtime=\n" +
		"NextElapseUSecMonotonic=" + nextMonotonic + "\n" +
		"ActiveState=" + active + "\n"
}

func setSvc(m *executor.MockExecutor, timer, state string) {
	m.RunResults[svcKey(svcFor(timer))] = executor.Result{ExitCode: 0, Stdout: "ActiveState=" + state + "\n"}
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

	// Probe results in systemd's real key=value form (v1.235 T1).
	mock.RunResults[showKey(wedged)] = executor.Result{ExitCode: 0, Stdout: intervalShow(wedged, "infinity", "active")}
	mock.RunResults[showKey(wedged2)] = executor.Result{ExitCode: 0, Stdout: calendarShow(wedged2, "", "active")}
	mock.RunResults[showKey(healthy)] = executor.Result{ExitCode: 0, Stdout: calendarShow(healthy, "Mon 2026-10-05 20:30:11 UTC", "active")}
	mock.RunResults[showKey(inactive)] = executor.Result{ExitCode: 0, Stdout: intervalShow(inactive, "infinity", "inactive")}
	setSvc(mock, wedged, "inactive")
	setSvc(mock, wedged2, "inactive")

	timers := []string{wedged, wedged2, healthy, inactive, uninstalled}
	RestartWedgedTimers(context.Background(), mock, newTestLogger(), timers)

	// daemon-reload exactly once.
	if n := mock.CommandCallCount("systemctl", "daemon-reload"); n != 1 {
		t.Errorf("expected exactly 1 daemon-reload, got %d", n)
	}

	// Wedged timers restarted.
	if !restartCalled(mock, wedged) {
		t.Errorf("%s is wedged (interval, NextElapseUSecMonotonic=infinity) but was NOT restarted", wedged)
	}
	if !restartCalled(mock, wedged2) {
		t.Errorf("%s is wedged (calendar, NextElapseUSecRealtime empty) but was NOT restarted", wedged2)
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

	mock.RunResults[showKey(first)] = executor.Result{ExitCode: 0, Stdout: intervalShow(first, "infinity", "active")}
	mock.RunResults[showKey(second)] = executor.Result{ExitCode: 0, Stdout: intervalShow(second, "infinity", "active")}
	setSvc(mock, first, "inactive")
	setSvc(mock, second, "inactive")

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
	mock.RunResults[showKey(tmr)] = executor.Result{ExitCode: 0, Stdout: calendarShow(tmr, "Mon 2026-10-05 20:30:11 UTC", "active")}

	RestartWedgedTimers(context.Background(), mock, newTestLogger(), KnownTimers())

	if n := mock.CommandCallCount("systemctl", "daemon-reload"); n != 1 {
		t.Errorf("expected exactly 1 daemon-reload, got %d", n)
	}
	if restartCalled(mock, tmr) {
		t.Errorf("healthy %s should not be restarted", tmr)
	}
}

// =============================================================================
// v1.235 T1 — the probe reads key=value in any order, per trigger kind.
// =============================================================================

// wedgedCase drives timerIsWedged directly with strict fixtures: an unexpected
// command fails loudly instead of returning a permissive success.
func wedgedCase(t *testing.T, timer, show string, svcState string) bool {
	t.Helper()
	m := executor.NewMockExecutor()
	m.StrictUnregistered = true
	m.RunResults[showKey(timer)] = executor.Result{ExitCode: 0, Stdout: show}
	if svcState != "" {
		setSvc(m, timer, svcState)
	}
	got := timerIsWedged(context.Background(), m, timer)
	if u := m.UnmatchedCommands(); len(u) > 0 {
		t.Fatalf("unregistered commands issued: %v", u)
	}
	return got
}

// TestTimerIsWedged_RealSystemdOutput_v1235 uses the exact output captured on
// lab4 (systemd 252) for the dead watchdog timer and the healthy maintenance
// timer. The v1.154 positional parser called BOTH "not wedged".
func TestTimerIsWedged_RealSystemdOutput_v1235(t *testing.T) {
	deadWatchdog := "Unit=nftban-watchdog.service\n" +
		"TimersMonotonic={ OnUnitActiveUSec=2min ; next_elapse=0 }\n" +
		"TimersMonotonic={ OnBootUSec=2min ; next_elapse=0 }\n" +
		"NextElapseUSecRealtime=\n" +
		"NextElapseUSecMonotonic=infinity\n" +
		"ActiveState=active\n"
	if !wedgedCase(t, "nftban-watchdog.timer", deadWatchdog, "inactive") {
		t.Errorf("lab4 watchdog (active, NextElapseUSecMonotonic=infinity, service inactive) must be wedged")
	}
	healthyMaint := "Unit=nftban-maintenance.service\n" +
		"TimersCalendar={ OnCalendar=*-*-* *:00/15:00 ; next_elapse=Mon 2026-10-05 20:30:00 UTC }\n" +
		"NextElapseUSecRealtime=Mon 2026-10-05 20:30:11 UTC\n" +
		"NextElapseUSecMonotonic=0\n" +
		"ActiveState=active\n"
	if wedgedCase(t, "nftban-maintenance.timer", healthyMaint, "") {
		t.Errorf("healthy calendar timer (NextElapseUSecMonotonic=0 is normal for it) must not be wedged")
	}
	healthyWatchdog := "Unit=nftban-watchdog.service\n" +
		"TimersMonotonic={ OnUnitActiveUSec=2min ; next_elapse=3w 6d 11h 45min 19.714520s }\n" +
		"TimersMonotonic={ OnBootUSec=2min ; next_elapse=2min }\n" +
		"NextElapseUSecRealtime=\n" +
		"NextElapseUSecMonotonic=3w 6d 11h 45min 24.834782s\n" +
		"ActiveState=active\n"
	if wedgedCase(t, "nftban-watchdog.timer", healthyWatchdog, "") {
		t.Errorf("healthy interval timer (lab2, systemd 255; empty realtime is normal) must not be wedged")
	}
}

// TestTimerIsWedged_OrderIndependent_v1235: the same facts in the order the
// v1.154 code ASSUMED (ActiveState first) and in systemd's real order give the
// same verdict.
func TestTimerIsWedged_OrderIndependent_v1235(t *testing.T) {
	tmr := "nftban-queue.timer"
	real := intervalShow(tmr, "infinity", "active")
	lines := strings.Split(strings.TrimSpace(real), "\n")
	reversed := ""
	for i := len(lines) - 1; i >= 0; i-- {
		reversed += lines[i] + "\n"
	}
	if !wedgedCase(t, tmr, real, "inactive") {
		t.Errorf("systemd order: wedged interval timer not detected")
	}
	if !wedgedCase(t, tmr, reversed, "inactive") {
		t.Errorf("reversed order: wedged interval timer not detected")
	}
}

// TestTimerIsWedged_ServiceRunningIsNotWedged_v1235: while the triggered service
// runs, systemd legitimately shows no next elapse; that is not a wedge.
func TestTimerIsWedged_ServiceRunningIsNotWedged_v1235(t *testing.T) {
	tmr := "nftban-botscan.timer"
	for _, st := range []string{"active", "activating", "reloading", "deactivating"} {
		if wedgedCase(t, tmr, intervalShow(tmr, "infinity", "active"), st) {
			t.Errorf("service %s: a run in progress must not be treated as wedged", st)
		}
	}
	if !wedgedCase(t, tmr, intervalShow(tmr, "infinity", "active"), "failed") {
		t.Errorf("service failed + no next elapse: must be wedged")
	}
}

// TestTimerIsWedged_UncertainIsNotWedged_v1235: inactive timers, unclassifiable
// output and failed service probes never trigger a restart.
func TestTimerIsWedged_UncertainIsNotWedged_v1235(t *testing.T) {
	tmr := "nftban-unified-exporter.timer"
	if wedgedCase(t, tmr, intervalShow(tmr, "infinity", "inactive"), "") {
		t.Errorf("inactive timer must not be wedged")
	}
	if wedgedCase(t, tmr, "ActiveState=active\nNextElapseUSecMonotonic=infinity\n", "") {
		t.Errorf("no Timers* property: cannot classify, must not be wedged")
	}
	if wedgedCase(t, tmr, "active\n\n", "") {
		t.Errorf("--value-style output (no keys) must not be wedged")
	}
	m := executor.NewMockExecutor()
	m.StrictUnregistered = true
	m.RunResults[showKey(tmr)] = executor.Result{ExitCode: 0, Stdout: intervalShow(tmr, "infinity", "active")}
	m.RunResults[svcKey(svcFor(tmr))] = executor.Result{ExitCode: 1, Stderr: "boom"}
	if timerIsWedged(context.Background(), m, tmr) {
		t.Errorf("service probe failed: must not be wedged")
	}
}

// fakeSystemctlShow emulates `systemctl show <unit> -p A -p B [--value]` the way
// systemd answers it: requested properties are printed in the UNIT'S property
// order (not request order), every occurrence of a repeated name is printed,
// and --value drops the "Name=" prefix. It answers whatever probe an
// implementation issues, so a test built on it is behavioural, not tied to one
// argv.
func fakeSystemctlShow(units map[string][][2]string) func(string, []string) (executor.Result, bool) {
	return func(name string, args []string) (executor.Result, bool) {
		if name != "systemctl" || len(args) < 2 || args[0] != "show" {
			return executor.Result{}, false
		}
		props, ok := units[args[1]]
		if !ok {
			return executor.Result{ExitCode: 0, Stdout: "ActiveState=inactive\n"}, true
		}
		want := map[string]bool{}
		value := false
		for i := 2; i < len(args); i++ {
			switch args[i] {
			case "-p":
				if i+1 < len(args) {
					want[args[i+1]] = true
					i++
				}
			case "--value":
				value = true
			}
		}
		var b strings.Builder
		for _, kv := range props {
			if !want[kv[0]] {
				continue
			}
			if value {
				b.WriteString(kv[1] + "\n")
			} else {
				b.WriteString(kv[0] + "=" + kv[1] + "\n")
			}
		}
		return executor.Result{ExitCode: 0, Stdout: b.String()}, true
	}
}

// TestTimerIsWedged_EmulatedSystemd_v1235 is the behavioural falsifier: the
// lab4 (systemd 252) facts for the dead watchdog and the healthy maintenance
// timer, served by a systemctl emulator. The v1.154 positional probe answers
// "not wedged" for the dead watchdog here; the fixed probe must answer "wedged".
func TestTimerIsWedged_EmulatedSystemd_v1235(t *testing.T) {
	units := map[string][][2]string{
		"nftban-watchdog.timer": {
			{"Unit", "nftban-watchdog.service"},
			{"TimersMonotonic", "{ OnUnitActiveUSec=2min ; next_elapse=0 }"},
			{"TimersMonotonic", "{ OnBootUSec=2min ; next_elapse=0 }"},
			{"NextElapseUSecRealtime", ""},
			{"NextElapseUSecMonotonic", "infinity"},
			{"ActiveState", "active"},
		},
		"nftban-watchdog.service": {{"ActiveState", "inactive"}},
		"nftban-maintenance.timer": {
			{"Unit", "nftban-maintenance.service"},
			{"TimersCalendar", "{ OnCalendar=*-*-* *:00/15:00 ; next_elapse=Mon 2026-10-05 20:30:00 UTC }"},
			{"NextElapseUSecRealtime", "Mon 2026-10-05 20:30:11 UTC"},
			{"NextElapseUSecMonotonic", "0"},
			{"ActiveState", "active"},
		},
		"nftban-maintenance.service": {{"ActiveState", "inactive"}},
	}
	m := executor.NewMockExecutor()
	m.RunHook = fakeSystemctlShow(units)
	if !timerIsWedged(context.Background(), m, "nftban-watchdog.timer") {
		t.Errorf("dead watchdog (lab4, systemd 252) not detected as wedged")
	}
	if timerIsWedged(context.Background(), m, "nftban-maintenance.timer") {
		t.Errorf("healthy maintenance timer reported wedged")
	}
}
