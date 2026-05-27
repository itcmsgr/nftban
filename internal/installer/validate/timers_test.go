// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-timers-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-27"
// meta:description="Unit tests for the v1.135 critical-core-timer validator + assertion"
// meta:inventory.files="internal/installer/validate/timers_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package validate

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

func TestValidateCriticalTimers(t *testing.T) {
	const mt = "nftban-maintenance.timer"
	cases := []struct {
		name        string
		in          TimerValidationInputs
		wantOK      bool
		wantSkipped bool
		wantMissing int
	}{
		{
			name:   "enabled+active -> OK",
			in:     TimerValidationInputs{Critical: []string{mt}, States: map[string]TimerState{mt: {Enabled: true, ActiveOrScheduled: true}}},
			wantOK: true,
		},
		{
			name:        "disabled -> missing",
			in:          TimerValidationInputs{Critical: []string{mt}, States: map[string]TimerState{mt: {Enabled: false, ActiveOrScheduled: true}}},
			wantOK:      false,
			wantMissing: 1,
		},
		{
			name:        "inactive -> missing",
			in:          TimerValidationInputs{Critical: []string{mt}, States: map[string]TimerState{mt: {Enabled: true, ActiveOrScheduled: false}}},
			wantOK:      false,
			wantMissing: 1,
		},
		{
			name:        "absent (no observed state) -> missing",
			in:          TimerValidationInputs{Critical: []string{mt}, States: map[string]TimerState{}},
			wantOK:      false,
			wantMissing: 1,
		},
		{
			name:        "reconcile disabled -> skipped + OK (intentional)",
			in:          TimerValidationInputs{ReconcileDisabled: true, Critical: []string{mt}, States: map[string]TimerState{mt: {Enabled: false, ActiveOrScheduled: false}}},
			wantOK:      true,
			wantSkipped: true,
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := ValidateCriticalTimers(tc.in)
			if got.OK != tc.wantOK {
				t.Errorf("OK: want %v, got %v", tc.wantOK, got.OK)
			}
			if got.Skipped != tc.wantSkipped {
				t.Errorf("Skipped: want %v, got %v", tc.wantSkipped, got.Skipped)
			}
			if len(got.Missing) != tc.wantMissing {
				t.Errorf("Missing count: want %d, got %d (%v)", tc.wantMissing, len(got.Missing), got.Missing)
			}
		})
	}
}

func TestAssertCriticalTimersEnabled(t *testing.T) {
	log := newTestLogger()

	r := assertCriticalTimersEnabled(TimerValidationResult{OK: true}, log)
	if r.Name != "core_timers_active_or_scheduled_ok" || !r.Passed {
		t.Errorf("all-ok: want named+passed, got %+v", r)
	}

	r = assertCriticalTimersEnabled(TimerValidationResult{OK: true, Skipped: true}, log)
	if !r.Passed {
		t.Errorf("reconcile-disabled skip should PASS, got %+v", r)
	}

	r = assertCriticalTimersEnabled(TimerValidationResult{OK: false, Missing: []string{"nftban-maintenance.timer"}}, log)
	if r.Passed {
		t.Errorf("down critical timer should FAIL")
	}
	if !strings.Contains(r.Detail, "nftban-maintenance.timer") {
		t.Errorf("Detail must name the timer (reaches FAILURE_REASON), got %q", r.Detail)
	}
}

// Integration: the gatherer + validator over a mock host. Default mock has the
// critical timer neither enabled nor active -> fail; after enable+start -> OK.
func TestGatherTimerInputs_DownThenRecovered(t *testing.T) {
	mock := executor.NewMockExecutor()
	log := newTestLogger()

	if ValidateCriticalTimers(GatherTimerInputs(mock, log)).OK {
		t.Errorf("expected FAIL: maintenance timer not enabled/active on fresh mock")
	}

	_ = mock.ServiceEnable("nftban-maintenance.timer")
	_ = mock.ServiceStart("nftban-maintenance.timer")
	if !ValidateCriticalTimers(GatherTimerInputs(mock, log)).OK {
		t.Errorf("expected OK after enable+start of maintenance timer")
	}
}
