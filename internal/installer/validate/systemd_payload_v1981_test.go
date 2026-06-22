// =============================================================================
// NFTBan v1.198.1 - Alert-template stale-clearable oneshot classification (PR-B)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-systemd-payload-v1981-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-22"
// meta:description="PR-B: nftban-alert@<svc>.service (OnFailure oneshot TEMPLATE) pre-existing failed-state recovers WITHOUT the live-health gate; real in-window failures still DEGRADE. Reproduces the srv4 v1.198.0 stuck-DEGRADED case."
// meta:inventory.files="internal/installer/validate/systemd_payload_v1981_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftban-alert@nftband.service.service"
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validate

import (
	"testing"
	"time"
)

func v1981AlertUnit(t time.Time, known bool) FailedUnitFinding {
	return FailedUnitFinding{
		Unit:             "nftban-alert@nftband.service.service",
		Active:           "failed",
		Sub:              "failed",
		Detail:           "exit-code", // logger: socket /dev/log: Permission denied → exit 1
		FailureTime:      t,
		FailureTimeKnown: known,
	}
}

// TestAlertTemplateStaleClearableClassification — v1.198.1 PR-B.
// The srv4 case: nftban-alert@nftband.service.service (OnFailure oneshot template)
// latched `failed` at 2026-06-21 23:26 (before PR-A made its logger sandbox-safe),
// ~14.5h BEFORE the v1.198.0 install window. Like nftban-botscan (v1.185.1), the
// latch can itself make the live-health probe read unclean (circular), so it must
// recover WITHOUT the live-health gate. A real in-window alert failure still
// DEGRADES (no masking).
func TestAlertTemplateStaleClearableClassification(t *testing.T) {
	window := time.Date(2026, 6, 22, 13, 59, 0, 0, time.UTC)
	preExisting := window.Add(-870 * time.Minute) // 2026-06-21 23:29-ish — the srv4 latch
	inWindow := window.Add(1 * time.Minute)

	cases := []struct {
		name             string
		in               SystemdPayloadInputs
		wantOK           bool
		wantFatalLen     int
		wantRecoveredLen int
	}{
		{
			// The exact srv4 scenario: pre-existing alert latch, live health reads
			// NOT clean (the latch itself), yet must RECOVER.
			name: "alert_template_pre_existing_live_not_clean_recovers",
			in: SystemdPayloadInputs{
				FailedNftbanUnits:       []FailedUnitFinding{v1981AlertUnit(preExisting, true)},
				InstallWindowStart:      window,
				InstallWindowStartKnown: true,
				LiveHealthClean:         false,
				LiveHealthKnown:         true,
			},
			wantOK:           true,
			wantFatalLen:     0,
			wantRecoveredLen: 1,
		},
		{
			// A REAL in-window alert failure must still DEGRADE.
			name: "alert_template_in_window_still_degrades",
			in: SystemdPayloadInputs{
				FailedNftbanUnits:       []FailedUnitFinding{v1981AlertUnit(inWindow, true)},
				InstallWindowStart:      window,
				InstallWindowStartKnown: true,
				LiveHealthClean:         true, // even clean: in-window stays fatal
				LiveHealthKnown:         true,
			},
			wantOK:       false,
			wantFatalLen: 1,
		},
		{
			// Unknown failure time → cannot prove pre-existing → fail safe DEGRADE.
			name: "alert_template_unknown_failure_time_degrades",
			in: SystemdPayloadInputs{
				FailedNftbanUnits:       []FailedUnitFinding{v1981AlertUnit(preExisting, false)},
				InstallWindowStart:      window,
				InstallWindowStartKnown: true,
				LiveHealthClean:         false,
				LiveHealthKnown:         true,
			},
			wantOK:       false,
			wantFatalLen: 1,
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			res := ValidateInstalledSystemdPayload(tc.in)
			if res.FailedUnitsOK() != tc.wantOK {
				t.Errorf("FailedUnitsOK=%v want %v (fatal=%d recovered=%d)",
					res.FailedUnitsOK(), tc.wantOK,
					len(res.FailedUnits), len(res.FailedUnitsPreExistingRecovered))
			}
			if len(res.FailedUnits) != tc.wantFatalLen {
				t.Errorf("len(FailedUnits)=%d want %d", len(res.FailedUnits), tc.wantFatalLen)
			}
			if len(res.FailedUnitsPreExistingRecovered) != tc.wantRecoveredLen {
				t.Errorf("len(FailedUnitsPreExistingRecovered)=%d want %d",
					len(res.FailedUnitsPreExistingRecovered), tc.wantRecoveredLen)
			}
		})
	}
}

// TestIsStaleClearableOneshotAlertTemplate pins the template membership: any
// instance of nftban-alert@ is stale-clearable; lookalikes are not.
func TestIsStaleClearableOneshotAlertTemplate(t *testing.T) {
	if !isStaleClearableOneshot("nftban-alert@nftband.service.service") {
		t.Error("nftban-alert@nftband.service.service must be stale-clearable (PR-B)")
	}
	if !isStaleClearableOneshot("nftban-alert@nftban-queue.service.service") {
		t.Error("nftban-alert@<any-instance>.service must be stale-clearable (template generalizes)")
	}
	if isStaleClearableOneshot("nftban-alertmanager.service") {
		t.Error("nftban-alertmanager.service must NOT match the nftban-alert@ template stem")
	}
	if isStaleClearableOneshot("nftband.service") {
		t.Error("nftband.service (protection daemon) must NOT be stale-clearable")
	}
}
