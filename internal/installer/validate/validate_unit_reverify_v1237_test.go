// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="validate_unit_reverify_v1237_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 BUG-UPGRADE-PREEXISTING-FAILED-VALIDATE-UNIT-MARKS-INSTALL-DEGRADED: a nftban-firewall-validate.service failed state left by an older release is re-verified through the normal entry point (reset-failed + one fresh systemctl start). The fresh run decides: PROTECTED/IDLE (exit 0) or DEGRADED (exit 1) recovers the latch; a DOWN verdict (exit 2), an unreadable or unexpected verdict, or an execution failure (unit still failed after the run) stays FATAL. The re-verify touches only that unit."
// meta:inventory.systemd_units="nftban-firewall-validate.service"
// meta:inventory.privileges="none"

package validate

import (
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

// mockValidateRun scripts the two systemctl queries the re-verify makes after the fresh start.
func mockValidateRun(stillFailed bool, showExit int, execMainStatus string) *executor.MockExecutor {
	m := executor.NewMockExecutor()
	m.RunHook = func(name string, args []string) (executor.Result, bool) {
		if name != "systemctl" || len(args) == 0 {
			return executor.Result{}, false
		}
		switch args[0] {
		case "is-failed":
			if stillFailed {
				return executor.Result{ExitCode: 0, Stdout: "failed\n"}, true
			}
			return executor.Result{ExitCode: 1, Stdout: "inactive\n"}, true
		case "show":
			return executor.Result{ExitCode: showExit, Stdout: execMainStatus + "\n"}, true
		}
		return executor.Result{}, false
	}
	return m
}

func TestValidateUnitReverify_FreshVerdictDecides(t *testing.T) {
	cases := []struct {
		name        string
		stillFailed bool
		showExit    int
		status      string
		wantClean   bool
	}{
		{"fresh run PROTECTED/IDLE (exit 0) recovers the old latch", false, 0, "0", true},
		{"fresh run DEGRADED (exit 1) recovers the old latch", false, 0, "1", true},
		{"fresh run DOWN (exit 2) stays FATAL", false, 0, "2", false},
		{"execution failure: unit failed again after the run stays FATAL", true, 0, "203", false},
		{"verdict unreadable stays FATAL", false, 1, "", false},
		{"unexpected exit status stays FATAL", false, 0, "3", false},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			m := mockValidateRun(tc.stillFailed, tc.showExit, tc.status)
			done, clean := reverifyCadenceOneshot(m, validateUnit, nolog())
			if !done || clean != tc.wantClean {
				t.Fatalf("done=%v clean=%v, want done=true clean=%v", done, clean, tc.wantClean)
			}
			// the re-verify went through the normal entry point, on this unit only
			var reset, start bool
			for _, c := range m.Commands {
				if c.Name != "systemctl" || len(c.Args) < 2 || (c.Args[0] != "reset-failed" && c.Args[0] != "start") {
					continue
				}
				if c.Args[1] != validateUnit {
					t.Errorf("re-verify touched another unit: %v", c.Args)
					continue
				}
				reset = reset || c.Args[0] == "reset-failed"
				start = start || c.Args[0] == "start"
			}
			if !reset || !start {
				t.Errorf("expected reset-failed + start of %s, got %v", validateUnit, m.Commands)
			}
		})
	}
}

// The classifier routes the validate unit through the gated re-verify: a clean re-run is non-fatal,
// a re-run that did not clean stays FATAL even when the failure predates the install window.
func TestValidateUnitReverify_Classification(t *testing.T) {
	window := time.Date(2026, 11, 13, 8, 0, 0, 0, time.UTC)
	mk := func(clean bool) SystemdPayloadInputs {
		return SystemdPayloadInputs{
			FailedNftbanUnits: []FailedUnitFinding{{
				Unit: validateUnit, Active: "failed", Sub: "failed", Detail: "exit-code 1",
				FailureTime: window.Add(-time.Hour), FailureTimeKnown: true,
				OwnedWindowReverifyDone: true, OwnedWindowReverifyClean: clean,
			}},
			InstallWindowStart: window, InstallWindowStartKnown: true,
			LiveHealthKnown: true, LiveHealthClean: true, // must not rescue a failed re-verify
		}
	}
	if !isCadenceReverifiableOneshot(validateUnit) {
		t.Fatalf("%s must be a re-verify member", validateUnit)
	}
	ok := ValidateInstalledSystemdPayload(mk(true))
	if !ok.FailedUnitsOK() || len(ok.FailedUnitsTransientRecovered) != 1 {
		t.Errorf("clean re-run: want non-fatal WARN_TRANSIENT_RECOVERED, got fatal=%d transient=%d", len(ok.FailedUnits), len(ok.FailedUnitsTransientRecovered))
	}
	bad := ValidateInstalledSystemdPayload(mk(false))
	if bad.FailedUnitsOK() || len(bad.FailedUnits) != 1 {
		t.Errorf("re-run not clean: want FATAL, got fatal=%d preexisting_recovered=%d", len(bad.FailedUnits), len(bad.FailedUnitsPreExistingRecovered))
	}
}
