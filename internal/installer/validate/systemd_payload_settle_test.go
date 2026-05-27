// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-validate-systemd-payload-settle-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-27"
// meta:description="Unit tests for v1.135 D-EXPORTER-SETTLE-WINDOW: auxiliary (metrics/observability) failed-unit classification + bounded settle re-poll. A transient exporter failure must not DEGRADE the install; protection-critical failures stay hard."
// meta:inventory.files="internal/installer/validate/systemd_payload_settle_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftban-unified-exporter.service"
// meta:inventory.network=""
// meta:inventory.privileges="none"

package validate

import (
	"strings"
	"testing"
)

func TestIsAuxiliaryUnit(t *testing.T) {
	cases := []struct {
		unit string
		want bool
	}{
		{"nftban-unified-exporter.service", true},
		{"nftban-unified-exporter.timer", true},
		{"nftband.service", false},     // Go daemon — protection critical
		{"nftban-core.service", false}, // protection critical
		{"nftban-firewall-init.service", false},
		{"nftban-maintenance.timer", false}, // critical core timer, not auxiliary
		{"sshd.service", false},             // not an nftban unit
		{"node_exporter.service", false},    // not an nftban unit (third-party)
	}
	for _, c := range cases {
		if got := IsAuxiliaryUnit(c.unit); got != c.want {
			t.Errorf("IsAuxiliaryUnit(%q) = %v, want %v", c.unit, got, c.want)
		}
	}
}

// A failed auxiliary unit (exporter) must NOT fail FAILED-UNIT-POSTINSTALL-001
// — it is routed to the non-fatal FailedAuxiliaryUnits bucket.
func TestSystemdPayload_FailedAuxiliaryUnitDoesNotFail(t *testing.T) {
	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		PathExists: pathSet(),
		Inventory:  inv(),
		FailedNftbanUnits: []FailedUnitFinding{
			{Unit: "nftban-unified-exporter.service", Active: "failed", Sub: "failed", Detail: "exit-code 2"},
		},
	})
	if !res.OK {
		t.Fatalf("expected OK (auxiliary failure is non-fatal); got %#v", res)
	}
	if !res.FailedUnitsOK() {
		t.Errorf("FailedUnitsOK should be true when only auxiliary units failed")
	}
	if len(res.FailedUnits) != 0 {
		t.Errorf("auxiliary failure must NOT be in FailedUnits; got %#v", res.FailedUnits)
	}
	if len(res.FailedAuxiliaryUnits) != 1 {
		t.Fatalf("expected 1 FailedAuxiliaryUnit; got %d", len(res.FailedAuxiliaryUnits))
	}
	if !strings.Contains(res.FailedAuxiliaryUnits[0].Detail, "exit-code 2") {
		t.Errorf("auxiliary detail should preserve reason; got %q", res.FailedAuxiliaryUnits[0].Detail)
	}
}

// A protection-critical failure alongside an auxiliary failure still fails the
// invariant; the auxiliary one is bucketed separately.
func TestSystemdPayload_MixedAuxiliaryAndProtectionFails(t *testing.T) {
	res := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		PathExists: pathSet(),
		Inventory:  inv(),
		FailedNftbanUnits: []FailedUnitFinding{
			{Unit: "nftban-unified-exporter.service", Active: "failed", Sub: "failed", Detail: "exit-code 2"},
			{Unit: "nftband.service", Active: "failed", Sub: "failed", Detail: "exit-code 1"},
		},
	})
	if res.OK {
		t.Fatalf("expected NOT OK (protection unit failed)")
	}
	if len(res.FailedUnits) != 1 || res.FailedUnits[0].Unit != "nftband.service" {
		t.Errorf("expected only nftband.service in FailedUnits; got %#v", res.FailedUnits)
	}
	if len(res.FailedAuxiliaryUnits) != 1 || res.FailedAuxiliaryUnits[0].Unit != "nftban-unified-exporter.service" {
		t.Errorf("expected exporter in FailedAuxiliaryUnits; got %#v", res.FailedAuxiliaryUnits)
	}
}

func TestAssertFailedUnits_AuxiliaryNonFatalDetail(t *testing.T) {
	spr := ValidateInstalledSystemdPayload(SystemdPayloadInputs{
		PathExists: pathSet(),
		Inventory:  inv(),
		FailedNftbanUnits: []FailedUnitFinding{
			{Unit: "nftban-unified-exporter.service", Active: "failed", Sub: "failed", Detail: "exit-code 2"},
		},
	})
	r := assertFailedUnitsPostInstall(spr, newTestLogger())
	if !r.Passed {
		t.Fatalf("assertion must PASS when only auxiliary units failed")
	}
	if !strings.Contains(r.Detail, "auxiliary") || !strings.Contains(r.Detail, "nftban-unified-exporter.service") {
		t.Errorf("Detail should surface the auxiliary degradation; got %q", r.Detail)
	}
}

func ff(unit string) FailedUnitFinding {
	return FailedUnitFinding{Unit: unit, Active: "failed", Sub: "failed"}
}

func TestSettleAuxiliaryFailures(t *testing.T) {
	exporter := "nftban-unified-exporter.service"
	daemon := "nftband.service"

	t.Run("auxiliary-only clears on re-poll", func(t *testing.T) {
		calls := 0
		requery := func() ([]FailedUnitFinding, string) {
			calls++
			return nil, "" // recovered
		}
		got := settleAuxiliaryFailures([]FailedUnitFinding{ff(exporter)}, requery, 3, func() {}, newTestLogger())
		if len(got) != 0 {
			t.Errorf("expected cleared after re-poll; got %#v", got)
		}
		if calls != 1 {
			t.Errorf("expected exactly 1 requery; got %d", calls)
		}
	})

	t.Run("auxiliary-only persists across the whole window", func(t *testing.T) {
		calls := 0
		requery := func() ([]FailedUnitFinding, string) {
			calls++
			return []FailedUnitFinding{ff(exporter)}, "" // never recovers
		}
		got := settleAuxiliaryFailures([]FailedUnitFinding{ff(exporter)}, requery, 3, func() {}, newTestLogger())
		if len(got) != 1 || got[0].Unit != exporter {
			t.Errorf("persistent auxiliary failure should still be reported; got %#v", got)
		}
		if calls != 2 { // maxAttempts=3 → initial + 2 requeries
			t.Errorf("expected 2 requeries for maxAttempts=3; got %d", calls)
		}
	})

	t.Run("protection-critical fails fast without waiting", func(t *testing.T) {
		calls, slept := 0, 0
		requery := func() ([]FailedUnitFinding, string) { calls++; return nil, "" }
		got := settleAuxiliaryFailures([]FailedUnitFinding{ff(daemon)}, requery, 3, func() { slept++ }, newTestLogger())
		if len(got) != 1 || got[0].Unit != daemon {
			t.Errorf("protection failure must be returned immediately; got %#v", got)
		}
		if calls != 0 || slept != 0 {
			t.Errorf("must not requery/sleep when a protection unit failed; calls=%d slept=%d", calls, slept)
		}
	})

	t.Run("requery error keeps the current set", func(t *testing.T) {
		requery := func() ([]FailedUnitFinding, string) { return nil, "dbus unavailable" }
		got := settleAuxiliaryFailures([]FailedUnitFinding{ff(exporter)}, requery, 3, func() {}, newTestLogger())
		if len(got) != 1 || got[0].Unit != exporter {
			t.Errorf("requery error should preserve prior findings; got %#v", got)
		}
	})

	t.Run("empty initial returns empty without requery", func(t *testing.T) {
		calls := 0
		requery := func() ([]FailedUnitFinding, string) { calls++; return nil, "" }
		got := settleAuxiliaryFailures(nil, requery, 3, func() {}, newTestLogger())
		if len(got) != 0 || calls != 0 {
			t.Errorf("empty initial should short-circuit; got=%#v calls=%d", got, calls)
		}
	})
}
