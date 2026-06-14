// =============================================================================
// NFTBan v1.185.1 - Stale-clearable oneshot classification tests (H2)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-systemd-payload-v1851-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-14"
// meta:description="H2: nftban-botscan.service (oneshot) pre-existing failed-state recovers WITHOUT the live-health gate; real in-window failures still DEGRADE"
// meta:inventory.files="internal/installer/validate/systemd_payload_v1851_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftban-botscan.service"
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validate

import (
	"testing"
	"time"
)

// botscanOneshot builds a failed finding for the nftban-botscan oneshot processor.
func v1851BotscanUnit(t time.Time, known bool) FailedUnitFinding {
	return FailedUnitFinding{
		Unit:             "nftban-botscan.service",
		Active:           "failed",
		Sub:              "failed",
		Detail:           "timeout",
		FailureTime:      t,
		FailureTimeKnown: known,
	}
}

// TestStaleClearableOneshotClassification — v1.185.1 H2.
// The botscan oneshot latches `failed` from a previous-version (v1.184) 300s
// timeout; that latch can make a live-health probe read unclean (circular), which
// kept the v1.174 general rule (preExisting && LiveHealthClean) from recovering
// it. H2: a botscan failure strictly BEFORE the install window recovers WITHOUT
// the live-health gate. Real in-window failures still DEGRADE.
func TestStaleClearableOneshotClassification(t *testing.T) {
	window := time.Date(2026, 6, 14, 7, 57, 0, 0, time.UTC)
	preExisting := window.Add(-1 * time.Minute) // 07:56 — the proven monitor case
	inWindow := window.Add(1 * time.Minute)     // 07:58 — a fresh failure

	cases := []struct {
		name             string
		in               SystemdPayloadInputs
		wantOK           bool
		wantFatalLen     int
		wantRecoveredLen int
	}{
		{
			// The exact monitor scenario: pre-existing v1.184 timeout, live health
			// reads NOT clean (the latch itself), yet must RECOVER (H2).
			name: "botscan_pre_existing_live_not_clean_recovers",
			in: SystemdPayloadInputs{
				FailedNftbanUnits:       []FailedUnitFinding{v1851BotscanUnit(preExisting, true)},
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
			// A REAL in-window botscan failure (under the new version) must still
			// DEGRADE — H2 must not mask current failures.
			name: "botscan_in_window_still_degrades",
			in: SystemdPayloadInputs{
				FailedNftbanUnits:       []FailedUnitFinding{v1851BotscanUnit(inWindow, true)},
				InstallWindowStart:      window,
				InstallWindowStartKnown: true,
				LiveHealthClean:         true, // even clean health: in-window stays fatal
				LiveHealthKnown:         true,
			},
			wantOK:       false,
			wantFatalLen: 1,
		},
		{
			// Unknown failure time → cannot prove pre-existing → fail safe DEGRADE.
			name: "botscan_unknown_failure_time_degrades",
			in: SystemdPayloadInputs{
				FailedNftbanUnits:       []FailedUnitFinding{v1851BotscanUnit(preExisting, false)},
				InstallWindowStart:      window,
				InstallWindowStartKnown: true,
				LiveHealthClean:         false,
				LiveHealthKnown:         true,
			},
			wantOK:       false,
			wantFatalLen: 1,
		},
		{
			// H2 must NOT over-broaden: a non-oneshot protection unit with the same
			// pre-existing + live-not-clean inputs stays FATAL (only botscan relaxes).
			name: "non_oneshot_pre_existing_live_not_clean_still_degrades",
			in: SystemdPayloadInputs{
				FailedNftbanUnits: []FailedUnitFinding{{
					Unit: "nftban-health.service", Active: "failed", Sub: "failed",
					Detail: "exit-code", FailureTime: preExisting, FailureTimeKnown: true,
				}},
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

// TestIsStaleClearableOneshot pins the membership: only the processor oneshot.
func TestIsStaleClearableOneshot(t *testing.T) {
	if !isStaleClearableOneshot("nftban-botscan.service") {
		t.Error("nftban-botscan.service must be stale-clearable")
	}
	if isStaleClearableOneshot("nftban-botscan-collector.service") {
		t.Error("nftban-botscan-collector.service must NOT be stale-clearable (different stem)")
	}
	if isStaleClearableOneshot("nftband.service") {
		t.Error("nftband.service (protection daemon) must NOT be stale-clearable")
	}
	if isStaleClearableOneshot("sshd.service") {
		t.Error("non-nftban units must never be stale-clearable")
	}
}
