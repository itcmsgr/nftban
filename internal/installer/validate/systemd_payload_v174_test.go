// =============================================================================
// NFTBan v1.174 - Stale Failed-Unit Classification Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-systemd-payload-v174-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-11"
// meta:description="D-INSTALL-FAILED-UNITS-STALE-LATCHED-STATE: pre-existing vs in-window failed-unit classification + live-health downgrade + systemd timestamp parse"
// meta:inventory.files="internal/installer/validate/systemd_payload_v174_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validate

import (
	"fmt"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// windowStart is a fixed install-window-start instant used across the matrix.
var v174WindowStart = time.Date(2026, 6, 11, 18, 54, 0, 0, time.UTC)

// failedUnit builds a non-auxiliary protection-critical failed finding.
func v174FailedUnit(t time.Time, known bool) FailedUnitFinding {
	return FailedUnitFinding{
		Unit:             "nftban-health.service",
		Active:           "failed",
		Sub:              "failed",
		Detail:           "exit-code",
		FailureTime:      t,
		FailureTimeKnown: known,
	}
}

// TestValidateFailedUnitClassificationMatrix exercises every HARD-RULE row of
// the v1.174 fail-safe classification matrix purely through
// SystemdPayloadInputs fixtures.
func TestValidateFailedUnitClassificationMatrix(t *testing.T) {
	preExistingTime := v174WindowStart.Add(-16 * time.Hour) // 03:06 the day before
	inWindowTime := v174WindowStart.Add(5 * time.Minute)

	cases := []struct {
		name             string
		in               SystemdPayloadInputs
		wantOK           bool
		wantFatalLen     int
		wantRecoveredLen int
		wantAuxLen       int
	}{
		{
			name: "a_pre_existing_latch_live_clean_recovered",
			in: SystemdPayloadInputs{
				FailedNftbanUnits:       []FailedUnitFinding{v174FailedUnit(preExistingTime, true)},
				InstallWindowStart:      v174WindowStart,
				InstallWindowStartKnown: true,
				LiveHealthClean:         true,
				LiveHealthKnown:         true,
			},
			wantOK:           true,
			wantFatalLen:     0,
			wantRecoveredLen: 1,
		},
		{
			name: "b_pre_existing_live_not_clean_degraded",
			in: SystemdPayloadInputs{
				FailedNftbanUnits:       []FailedUnitFinding{v174FailedUnit(preExistingTime, true)},
				InstallWindowStart:      v174WindowStart,
				InstallWindowStartKnown: true,
				LiveHealthClean:         false,
				LiveHealthKnown:         true,
			},
			wantOK:       false,
			wantFatalLen: 1,
		},
		{
			name: "c_pre_existing_live_unknown_degraded",
			in: SystemdPayloadInputs{
				FailedNftbanUnits:       []FailedUnitFinding{v174FailedUnit(preExistingTime, true)},
				InstallWindowStart:      v174WindowStart,
				InstallWindowStartKnown: true,
				LiveHealthClean:         false,
				LiveHealthKnown:         false,
			},
			wantOK:       false,
			wantFatalLen: 1,
		},
		{
			name: "d_in_window_failure_degraded",
			in: SystemdPayloadInputs{
				FailedNftbanUnits:       []FailedUnitFinding{v174FailedUnit(inWindowTime, true)},
				InstallWindowStart:      v174WindowStart,
				InstallWindowStartKnown: true,
				LiveHealthClean:         true, // even with clean health, in-window stays fatal
				LiveHealthKnown:         true,
			},
			wantOK:       false,
			wantFatalLen: 1,
		},
		{
			name: "e_failure_time_unknown_degraded",
			in: SystemdPayloadInputs{
				FailedNftbanUnits:       []FailedUnitFinding{v174FailedUnit(time.Time{}, false)},
				InstallWindowStart:      v174WindowStart,
				InstallWindowStartKnown: true,
				LiveHealthClean:         true,
				LiveHealthKnown:         true,
			},
			wantOK:       false,
			wantFatalLen: 1,
		},
		{
			name: "f_window_start_unknown_degraded",
			in: SystemdPayloadInputs{
				FailedNftbanUnits:       []FailedUnitFinding{v174FailedUnit(preExistingTime, true)},
				InstallWindowStartKnown: false,
				LiveHealthClean:         true,
				LiveHealthKnown:         true,
			},
			wantOK:       false,
			wantFatalLen: 1,
		},
		{
			name: "g_query_error_fail_closed",
			in: SystemdPayloadInputs{
				FailedUnitQueryError:    "systemctl missing",
				InstallWindowStart:      v174WindowStart,
				InstallWindowStartKnown: true,
				LiveHealthClean:         true,
				LiveHealthKnown:         true,
			},
			wantOK:       false,
			wantFatalLen: 0, // query error path: FailedUnits empty but OK=false
		},
		{
			name: "h_auxiliary_only_non_fatal",
			in: SystemdPayloadInputs{
				FailedNftbanUnits: []FailedUnitFinding{{
					Unit:             "nftban-unified-exporter.service",
					Active:           "failed",
					Sub:              "exit-code",
					Detail:           "exit-2",
					FailureTime:      inWindowTime, // in-window, but auxiliary
					FailureTimeKnown: true,
				}},
				InstallWindowStart:      v174WindowStart,
				InstallWindowStartKnown: true,
				LiveHealthClean:         false,
				LiveHealthKnown:         false,
			},
			wantOK:       true,
			wantFatalLen: 0,
			wantAuxLen:   1,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res := ValidateInstalledSystemdPayload(tc.in)
			if res.FailedUnitsOK() != tc.wantOK {
				t.Errorf("FailedUnitsOK()=%v want %v (fatal=%d recovered=%d aux=%d qerr=%q)",
					res.FailedUnitsOK(), tc.wantOK,
					len(res.FailedUnits), len(res.FailedUnitsPreExistingRecovered),
					len(res.FailedAuxiliaryUnits), res.FailedUnitQueryError)
			}
			if len(res.FailedUnits) != tc.wantFatalLen {
				t.Errorf("len(FailedUnits)=%d want %d", len(res.FailedUnits), tc.wantFatalLen)
			}
			if len(res.FailedUnitsPreExistingRecovered) != tc.wantRecoveredLen {
				t.Errorf("len(FailedUnitsPreExistingRecovered)=%d want %d",
					len(res.FailedUnitsPreExistingRecovered), tc.wantRecoveredLen)
			}
			if len(res.FailedAuxiliaryUnits) != tc.wantAuxLen {
				t.Errorf("len(FailedAuxiliaryUnits)=%d want %d",
					len(res.FailedAuxiliaryUnits), tc.wantAuxLen)
			}
		})
	}
}

// TestNeverClassifyNewFailureAsRecovered guards the cardinal HARD RULE: a
// unit that failed exactly at the window start (boundary) or after must NOT
// land in the recovered bucket even with clean live health.
func TestNeverClassifyNewFailureAsRecovered(t *testing.T) {
	for _, ft := range []time.Time{v174WindowStart, v174WindowStart.Add(time.Nanosecond)} {
		in := SystemdPayloadInputs{
			FailedNftbanUnits:       []FailedUnitFinding{v174FailedUnit(ft, true)},
			InstallWindowStart:      v174WindowStart,
			InstallWindowStartKnown: true,
			LiveHealthClean:         true,
			LiveHealthKnown:         true,
		}
		res := ValidateInstalledSystemdPayload(in)
		if len(res.FailedUnitsPreExistingRecovered) != 0 {
			t.Errorf("failure at %v wrongly recovered", ft)
		}
		if res.FailedUnitsOK() {
			t.Errorf("failure at %v wrongly passed FailedUnitsOK()", ft)
		}
	}
}

// TestRecoveredEntryCarriesClassification confirms the diagnostic field.
func TestRecoveredEntryCarriesClassification(t *testing.T) {
	in := SystemdPayloadInputs{
		FailedNftbanUnits:       []FailedUnitFinding{v174FailedUnit(v174WindowStart.Add(-time.Hour), true)},
		InstallWindowStart:      v174WindowStart,
		InstallWindowStartKnown: true,
		LiveHealthClean:         true,
		LiveHealthKnown:         true,
	}
	res := ValidateInstalledSystemdPayload(in)
	if len(res.FailedUnitsPreExistingRecovered) != 1 {
		t.Fatalf("want 1 recovered, got %d", len(res.FailedUnitsPreExistingRecovered))
	}
	if got := res.FailedUnitsPreExistingRecovered[0].Classification; got != "WARN_PRE_EXISTING_RECOVERED" {
		t.Errorf("Classification=%q want WARN_PRE_EXISTING_RECOVERED", got)
	}
}

// TestParseSystemdTimestamp exercises the timestamp parse helper.
func TestParseSystemdTimestamp(t *testing.T) {
	cases := []struct {
		name      string
		in        string
		wantKnown bool
	}{
		{"systemd_weekday_tz", "Thu 2026-06-11 03:06:02 UTC", true},
		{"systemd_weekday_numeric_zone", "Thu 2026-06-11 03:06:02 +0000", true},
		{"no_weekday_tz", "2026-06-11 03:06:02 UTC", true},
		{"empty", "", false},
		{"garbage", "not-a-timestamp", false},
		{"epoch_zero_marker", "0", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			ts, ok := parseSystemdTimestamp(tc.in)
			if ok != tc.wantKnown {
				t.Fatalf("parseSystemdTimestamp(%q) known=%v want %v", tc.in, ok, tc.wantKnown)
			}
			if ok && ts.IsZero() {
				t.Errorf("parsed %q but got zero time", tc.in)
			}
		})
	}
}

// TestParseLiveHealthClean exercises the conservative text parse rules.
func TestParseLiveHealthClean(t *testing.T) {
	cases := []struct {
		name      string
		in        string
		wantClean bool
		wantKnown bool
	}{
		{"ok_none", "Overall: OK\nFindings: none\n", true, true},
		{"idle_none", "Overall: IDLE\nFindings: none\n", true, true},
		{"protected_none", "Overall: PROTECTED\nFindings: none\n", true, true},
		{"ok_lowercase", "overall: ok\nfindings: none\n", true, true},
		// The exact monitor/lab real-host shape: PROTECTED + hidden INFO findings.
		{"protected_info_hidden", "  Overall:       PROTECTED\n  Daemon:        RUNNING\n  Consistency:   ok\n  Findings: none (1 INFO finding(s) hidden — use --verbose to show)\n", true, true},
		{"idle_info_hidden", "Overall: IDLE\nFindings: none (3 INFO finding(s) hidden — use --verbose to show)\n", true, true},
		{"ok_with_findings", "Overall: OK\nFindings: 2\n", false, true},
		// "Findings (N):" header (real findings) has no "Findings: none" line →
		// unknown → fail-safe not-clean (safe: never downgrade with real findings).
		{"findings_header", "Overall: OK\nFindings (2):\n  - something\n", false, false},
		{"critical_present", "Overall: OK\nFindings: none\nCRITICAL: nft set missing\n", false, true},
		{"degraded_overall", "Overall: DEGRADED\nFindings: none\n", false, true},
		{"down_overall", "Overall: DOWN\nFindings: none\n", false, true},
		{"warn_overall", "Overall: WARNING\nFindings: none\n", false, true},
		{"fail_token", "Overall: PROTECTED\nFindings: none\nTruth: FAILED\n", false, true},
		{"error_token", "Overall: PROTECTED\nFindings: none\nvalidator ERROR: x\n", false, true},
		{"no_overall_line", "Findings: none\n", false, false},
		{"overall_no_findings", "Overall: PROTECTED\nDaemon: RUNNING\n", false, false},
		{"empty", "", false, false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			clean, known := parseLiveHealthClean(tc.in)
			if clean != tc.wantClean || known != tc.wantKnown {
				t.Errorf("parseLiveHealthClean(%q)=(clean=%v,known=%v) want (clean=%v,known=%v)",
					tc.in, clean, known, tc.wantClean, tc.wantKnown)
			}
		})
	}
}

// TestMonitorAlertUnitV174 covers the monitor live case: a templated
// nftban-alert@<svc>.service that latched failed BEFORE the install window must
// flow through the v1.174 timestamp classification (NOT the auxiliary carve-out),
// recover to WARN_PRE_EXISTING_RECOVERED when live health is clean (so --repair
// reaches COMMITTED), but stay DEGRADED when it failed in-window or live health
// is not clean (alert failure can be real).
func TestMonitorAlertUnitV174(t *testing.T) {
	const alertUnit = "nftban-alert@nftband.service.service"
	if !IsNftbanUnit(alertUnit) {
		t.Fatalf("IsNftbanUnit(%q) = false; want true (templated alert unit is nftban-owned)", alertUnit)
	}
	if IsAuxiliaryUnit(alertUnit) {
		t.Fatalf("IsAuxiliaryUnit(%q) = true; alert@ must NOT be auxiliary — alert failure can be real, classify by timestamp", alertUnit)
	}

	windowStart := time.Date(2026, 6, 11, 21, 42, 0, 0, time.UTC)
	preExisting := time.Date(2026, 6, 9, 16, 37, 52, 0, time.UTC) // monitor: failed ~2 days earlier
	inWindow := windowStart.Add(30 * time.Second)
	log := logging.New("/dev/null", false)

	mk := func(ft time.Time) FailedUnitFinding {
		return FailedUnitFinding{Unit: alertUnit, Active: "failed", Sub: "failed", Detail: "exit-code", FailureTime: ft, FailureTimeKnown: true}
	}

	// 1) pre-existing + clean live health -> recovered (not DEGRADED); assertion PASSES (repair -> COMMITTED).
	r := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		FailedNftbanUnits: []FailedUnitFinding{mk(preExisting)}, InstallWindowStart: windowStart,
		InstallWindowStartKnown: true, LiveHealthClean: true, LiveHealthKnown: true,
	})
	if !r.FailedUnitsOK() || len(r.FailedUnitsPreExistingRecovered) != 1 || len(r.FailedUnits) != 0 {
		t.Fatalf("pre-existing alert@ + clean health: want recovered/OK; got OK=%v recovered=%d fatal=%d",
			r.FailedUnitsOK(), len(r.FailedUnitsPreExistingRecovered), len(r.FailedUnits))
	}
	if a := assertFailedUnitsPostInstall(r, log); !a.Passed {
		t.Fatalf("recovered alert@: failed_units_postinstall_ok must PASS so --repair reaches COMMITTED; detail=%q", a.Detail)
	}

	// 2) in-window failure -> DEGRADED (alert failure can be real); assertion FAILS.
	r2 := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		FailedNftbanUnits: []FailedUnitFinding{mk(inWindow)}, InstallWindowStart: windowStart,
		InstallWindowStartKnown: true, LiveHealthClean: true, LiveHealthKnown: true,
	})
	if r2.FailedUnitsOK() || len(r2.FailedUnits) != 1 {
		t.Fatalf("in-window alert@: want DEGRADED/fatal; got OK=%v fatal=%d", r2.FailedUnitsOK(), len(r2.FailedUnits))
	}
	if a := assertFailedUnitsPostInstall(r2, log); a.Passed {
		t.Fatalf("in-window alert@: failed_units_postinstall_ok must FAIL (stays DEGRADED)")
	}

	// 3) pre-existing + live health NOT clean.
	// v1.198.1 PR-B (D-NFTBAN-ALERT-LOGGER-DEVLOG-PERMISSION /
	// D-V198-STICKY-DEGRADED-NO-RECOMMIT-PATH): nftban-alert@ is now a
	// stale-clearable oneshot (staleClearableOneshotStems), so a latch strictly
	// BEFORE the install window recovers WITHOUT the live-health gate — the alert
	// latch itself can make the live-health probe read unclean (the same circular
	// block v1.185.1 fixed for nftban-botscan, and the exact srv4 v1.198.0 case).
	// This SUPERSEDES the original v1.174 fail-safe-to-DEGRADED expectation for
	// this pre-existing case. An IN-WINDOW alert failure still DEGRADES (case 2),
	// so real current failures are never masked.
	r3 := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		FailedNftbanUnits: []FailedUnitFinding{mk(preExisting)}, InstallWindowStart: windowStart,
		InstallWindowStartKnown: true, LiveHealthClean: false, LiveHealthKnown: true,
	})
	if !r3.FailedUnitsOK() || len(r3.FailedUnitsPreExistingRecovered) != 1 || len(r3.FailedUnits) != 0 {
		t.Fatalf("v1.198.1 PR-B: pre-existing alert@ recovers without the live-health gate; got OK=%v recovered=%d fatal=%d",
			r3.FailedUnitsOK(), len(r3.FailedUnitsPreExistingRecovered), len(r3.FailedUnits))
	}
}

// TestResetRecoveredPreExistingUnitsV174 locks the bounded reset-failed contract:
// reset-failed is issued ONLY for WARN_PRE_EXISTING_RECOVERED units (exact names),
// never for IN_WINDOW / unknown-timestamp / unknown-or-unhealthy-live-health, never
// blanket, and a reset-failed error is non-fatal.
func TestResetRecoveredPreExistingUnitsV174(t *testing.T) {
	log := logging.New("/dev/null", false)
	win := time.Date(2026, 6, 11, 21, 42, 0, 0, time.UTC)
	pre := win.Add(-48 * time.Hour)
	inw := win.Add(time.Minute)
	mk := func(unit string, ft time.Time, ftk bool) FailedUnitFinding {
		return FailedUnitFinding{Unit: unit, Active: "failed", Sub: "failed", Detail: "exit-code", FailureTime: ft, FailureTimeKnown: ftk}
	}
	in := func(units []FailedUnitFinding, clean, known, wsKnown bool) SystemdPayloadInputs {
		return SystemdPayloadInputs{FailedNftbanUnits: units, InstallWindowStart: win, InstallWindowStartKnown: wsKnown, LiveHealthClean: clean, LiveHealthKnown: known}
	}
	resetCalls := func(m *executor.MockExecutor) []string {
		var u []string
		for _, c := range m.Commands {
			if c.Name == "systemctl" && len(c.Args) == 2 && c.Args[0] == "reset-failed" {
				u = append(u, c.Args[1])
			}
		}
		return u
	}

	// 1) pre-existing + clean -> reset-failed exactly that unit.
	m := executor.NewMockExecutor()
	resetRecoveredPreExistingUnits(m, log, ValidateInstalledSystemdPayload(in([]FailedUnitFinding{mk("nftban-alert@nftband.service.service", pre, true)}, true, true, true)))
	if got := resetCalls(m); len(got) != 1 || got[0] != "nftban-alert@nftband.service.service" {
		t.Fatalf("1 pre-existing+clean: want reset of exact unit; got %v", got)
	}

	// 2) in-window -> no reset.
	m = executor.NewMockExecutor()
	resetRecoveredPreExistingUnits(m, log, ValidateInstalledSystemdPayload(in([]FailedUnitFinding{mk("nftban-health.service", inw, true)}, true, true, true)))
	if got := resetCalls(m); len(got) != 0 {
		t.Fatalf("2 in-window: must NOT reset; got %v", got)
	}

	// 3) timestamp unknown -> no reset.
	m = executor.NewMockExecutor()
	resetRecoveredPreExistingUnits(m, log, ValidateInstalledSystemdPayload(in([]FailedUnitFinding{mk("nftban-health.service", time.Time{}, false)}, true, true, true)))
	if got := resetCalls(m); len(got) != 0 {
		t.Fatalf("3 unknown-ts: must NOT reset; got %v", got)
	}

	// 4a) live health unknown -> no reset.
	m = executor.NewMockExecutor()
	resetRecoveredPreExistingUnits(m, log, ValidateInstalledSystemdPayload(in([]FailedUnitFinding{mk("nftban-health.service", pre, true)}, false, false, true)))
	if got := resetCalls(m); len(got) != 0 {
		t.Fatalf("4a unknown-health: must NOT reset; got %v", got)
	}
	// 4b) live health unhealthy -> no reset.
	m = executor.NewMockExecutor()
	resetRecoveredPreExistingUnits(m, log, ValidateInstalledSystemdPayload(in([]FailedUnitFinding{mk("nftban-health.service", pre, true)}, false, true, true)))
	if got := resetCalls(m); len(got) != 0 {
		t.Fatalf("4b unhealthy: must NOT reset; got %v", got)
	}

	// 5) mixed: only the recovered pre-existing unit is reset; the in-window fatal stays.
	m = executor.NewMockExecutor()
	spr := ValidateInstalledSystemdPayload(in([]FailedUnitFinding{
		mk("nftban-alert@x.service.service", pre, true),
		mk("nftban-health.service", inw, true),
	}, true, true, true))
	resetRecoveredPreExistingUnits(m, log, spr)
	if got := resetCalls(m); len(got) != 1 || got[0] != "nftban-alert@x.service.service" {
		t.Fatalf("5 mixed: only recovered reset; got %v", got)
	}
	if len(spr.FailedUnits) != 1 || spr.FailedUnits[0].Unit != "nftban-health.service" {
		t.Fatalf("5 mixed: in-window fatal unit must remain in FailedUnits; got %+v", spr.FailedUnits)
	}

	// 6) reset-failed error is non-fatal (attempted once, no panic/escalation).
	m = executor.NewMockExecutor()
	m.ServiceResetFailedErr = fmt.Errorf("dbus down")
	resetRecoveredPreExistingUnits(m, log, ValidateInstalledSystemdPayload(in([]FailedUnitFinding{mk("nftban-health.service", pre, true)}, true, true, true)))
	if got := resetCalls(m); len(got) != 1 {
		t.Fatalf("6 reset error: attempt recorded once; got %v", got)
	}
}
