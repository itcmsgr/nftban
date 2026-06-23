// =============================================================================
// NFTBan v1.201 - cadence-oneshot gated re-verify classification tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cadence_oneshot_reverify_v1201_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-23"
// meta:description="v1.201 (A2 + stale-oneshot/SOAK): the failed-unit classifier tolerates a cadence oneshot (watchdog/soak/maintenance) latch as non-fatal WARN_TRANSIENT_RECOVERED ONLY when the host-side gated re-verify ran CLEAN (OwnedWindowReverifyDone && Clean) — in-window OR pre-window; a re-verify that did not clean, or was not attempted, stays FATAL (no-mask). Non-cadence units and the existing botscan/alert@ pre-window stale-clear are unaffected."
// meta:input="SystemdPayloadInputs with FailedUnitFinding{OwnedWindowReverify*} → ValidateInstalledSystemdPayload"
// meta:output="t.Error on wrong bucket / FailedUnitsOK / masked persistent failure"
// meta:depends="testing,time"
// meta:inventory.files="internal/installer/validate/systemd_payload.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftban-watchdog.service,nftban-soak.service,nftban-maintenance.service"
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package validate

import (
	"testing"
	"time"
)

func TestV1201CadenceReverifyClassification(t *testing.T) {
	window := time.Date(2026, 6, 23, 20, 0, 0, 0, time.UTC)
	// inWindow = failed during the owned update window; preWindow = stale latch from before this run
	inWindow := window.Add(2 * time.Minute)
	preWindow := window.Add(-2 * time.Hour)

	mk := func(unit string, ft time.Time, rvDone, rvClean bool) FailedUnitFinding {
		return FailedUnitFinding{
			Unit: unit, Active: "failed", Sub: "failed", Detail: "exit-code 203",
			FailureTime: ft, FailureTimeKnown: true,
			OwnedWindowReverifyDone: rvDone, OwnedWindowReverifyClean: rvClean,
		}
	}
	base := func(f FailedUnitFinding) SystemdPayloadInputs {
		return SystemdPayloadInputs{
			FailedNftbanUnits:       []FailedUnitFinding{f},
			InstallWindowStart:      window,
			InstallWindowStartKnown: true,
			LiveHealthClean:         false, // worst case; cadence tolerance must NOT rely on live-health
			LiveHealthKnown:         true,
		}
	}

	cases := []struct {
		name          string
		in            SystemdPayloadInputs
		wantOK        bool
		wantFatal     int
		wantTransient int
		wantPreExist  int
	}{
		{"watchdog_in_window_reverify_clean_tolerated",
			base(mk("nftban-watchdog.service", inWindow, true, true)), true, 0, 1, 0},
		{"watchdog_in_window_reverify_not_clean_DEGRADES",
			base(mk("nftban-watchdog.service", inWindow, true, false)), false, 1, 0, 0},
		{"watchdog_in_window_no_reverify_DEGRADES",
			base(mk("nftban-watchdog.service", inWindow, false, false)), false, 1, 0, 0},
		{"soak_pre_window_reverify_clean_tolerated",
			base(mk("nftban-soak.service", preWindow, true, true)), true, 0, 1, 0},
		{"maintenance_in_window_reverify_clean_tolerated",
			base(mk("nftban-maintenance.service", inWindow, true, true)), true, 0, 1, 0},
		{"non_cadence_in_window_even_with_reverify_flags_DEGRADES",
			base(mk("nftban-health.service", inWindow, true, true)), false, 1, 0, 0},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			r := ValidateInstalledSystemdPayload(c.in)
			if r.FailedUnitsOK() != c.wantOK {
				t.Errorf("FailedUnitsOK()=%v want %v (fatal=%d transient=%d)", r.FailedUnitsOK(), c.wantOK, len(r.FailedUnits), len(r.FailedUnitsTransientRecovered))
			}
			if len(r.FailedUnits) != c.wantFatal {
				t.Errorf("FailedUnits=%d want %d", len(r.FailedUnits), c.wantFatal)
			}
			if len(r.FailedUnitsTransientRecovered) != c.wantTransient {
				t.Errorf("FailedUnitsTransientRecovered=%d want %d", len(r.FailedUnitsTransientRecovered), c.wantTransient)
			}
			if len(r.FailedUnitsPreExistingRecovered) != c.wantPreExist {
				t.Errorf("FailedUnitsPreExistingRecovered=%d want %d", len(r.FailedUnitsPreExistingRecovered), c.wantPreExist)
			}
		})
	}
}

// No-mask invariant: a persistent (re-run-failed) cadence oneshot is NEVER cleared.
func TestV1201NoMaskPersistentCadenceFailure(t *testing.T) {
	window := time.Date(2026, 6, 23, 20, 0, 0, 0, time.UTC)
	in := SystemdPayloadInputs{
		FailedNftbanUnits: []FailedUnitFinding{{
			Unit: "nftban-watchdog.service", Active: "failed", Sub: "failed", Detail: "exit-code 203",
			FailureTime: window.Add(time.Minute), FailureTimeKnown: true,
			OwnedWindowReverifyDone: true, OwnedWindowReverifyClean: false, // re-run STILL failed
		}},
		InstallWindowStart: window, InstallWindowStartKnown: true,
		LiveHealthClean: true, LiveHealthKnown: true, // even with clean health, a failed re-run stays fatal
	}
	r := ValidateInstalledSystemdPayload(in)
	if r.FailedUnitsOK() {
		t.Fatal("persistent cadence re-run failure must NOT pass FailedUnitsOK (no-mask)")
	}
	if len(r.FailedUnitsTransientRecovered) != 0 {
		t.Error("a re-run-failed cadence oneshot must never land in TransientRecovered")
	}
}

// Regression: the existing botscan pre-window stale-clear path is unchanged
// (unconditional recovery, no re-verify required).
func TestV1201BotscanPreWindowStaleClearUnchanged(t *testing.T) {
	window := time.Date(2026, 6, 23, 20, 0, 0, 0, time.UTC)
	in := SystemdPayloadInputs{
		FailedNftbanUnits: []FailedUnitFinding{{
			Unit: "nftban-botscan.service", Active: "failed", Sub: "failed", Detail: "timeout",
			FailureTime: window.Add(-time.Hour), FailureTimeKnown: true,
			// no re-verify flags — botscan uses the unconditional pre-window path
		}},
		InstallWindowStart: window, InstallWindowStartKnown: true,
		LiveHealthClean: false, LiveHealthKnown: true, // botscan recovers even with unclean live health
	}
	r := ValidateInstalledSystemdPayload(in)
	if !r.FailedUnitsOK() {
		t.Fatal("botscan pre-window stale-clear regressed (should still recover, FailedUnitsOK)")
	}
	if len(r.FailedUnitsPreExistingRecovered) != 1 {
		t.Errorf("botscan should be PreExistingRecovered=1, got %d", len(r.FailedUnitsPreExistingRecovered))
	}
	if len(r.FailedUnitsTransientRecovered) != 0 {
		t.Error("botscan must NOT use the v1.201 transient bucket")
	}
}
