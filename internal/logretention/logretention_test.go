// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-calculator-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Invariant tests for the Gate B retention calculator: UNBOUNDED_STANZAS=0 and THEORETICAL_MAX<=BUDGET across small/standard/large disks and profiles; forensic floor preserved; budget derives from CAPACITY not available space; valid overrides win; invalid overrides fail (no silent fallback); determinism."
// meta:inventory.files="internal/logretention/logretention.go,internal/logretention/inventory.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package logretention

import (
	"reflect"
	"testing"
)

func mustCalc(t *testing.T, disk DiskFacts, prof Profile, o Overrides) EffectivePolicy {
	t.Helper()
	p, err := Calculate(disk, prof, o, DefaultFamilies())
	if err != nil {
		t.Fatalf("Calculate: %v", err)
	}
	return p
}

func TestInvariantsAcrossDiskSizes(t *testing.T) {
	cases := []struct {
		name  string
		total uint64
		avail uint64
	}{
		{"tiny-5G", 5 * GiB, 2 * GiB},
		{"small-15G", 15 * GiB, 8 * GiB},
		{"standard-50G", 50 * GiB, 30 * GiB},
		{"large-500G", 500 * GiB, 400 * GiB},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			disk := DiskFacts{Path: "/var/log", TotalBytes: c.total, AvailBytes: c.avail}
			prof := ClassifyProfile(disk, false, "")
			p := mustCalc(t, disk, prof, Overrides{})

			if p.UnboundedCount != 0 {
				t.Errorf("UNBOUNDED_STANZAS = %d, want 0", p.UnboundedCount)
			}
			if p.TheoreticalMaxBytes > p.BudgetBytes {
				t.Errorf("THEORETICAL_MAX %d > BUDGET %d", p.TheoreticalMaxBytes, p.BudgetBytes)
			}
			// every family has a positive size cap and a positive rotate
			var sum uint64
			for _, f := range p.Families {
				if f.SizeCapBytes == 0 {
					t.Errorf("family %s has zero size cap (unbounded)", f.Key)
				}
				if f.RotateCount < 1 {
					t.Errorf("family %s rotate %d < 1", f.Key, f.RotateCount)
				}
				if f.RetentionDays < DefaultMinDays {
					t.Errorf("family %s retention %dd < forensic floor %dd", f.Key, f.RetentionDays, DefaultMinDays)
				}
				sum += f.WorstCaseBytes
			}
			if sum != p.TheoreticalMaxBytes {
				t.Errorf("sum of family worst-case %d != TheoreticalMax %d", sum, p.TheoreticalMaxBytes)
			}
		})
	}
}

func TestBudgetDerivesFromCapacityNotAvail(t *testing.T) {
	// Same capacity, very different available space → identical budget (available
	// space must NOT change the budget), but the fit verdict differs.
	a := DiskFacts{TotalBytes: 100 * GiB, AvailBytes: 90 * GiB}
	b := DiskFacts{TotalBytes: 100 * GiB, AvailBytes: 2 * GiB}
	pa := mustCalc(t, a, ClassifyProfile(a, false, ""), Overrides{})
	pb := mustCalc(t, b, ClassifyProfile(b, false, ""), Overrides{})
	if pa.BudgetBytes != pb.BudgetBytes {
		t.Errorf("budget changed with available space: %d vs %d", pa.BudgetBytes, pb.BudgetBytes)
	}
	if pa.FitVerdict == pb.FitVerdict {
		t.Errorf("fit verdict should differ with available space; both %s", pa.FitVerdict)
	}
	if pb.FitVerdict != FitOverHeadroom && pb.FitVerdict != FitTight {
		t.Errorf("low-avail host should read TIGHT/OVER_HEADROOM, got %s", pb.FitVerdict)
	}
}

func TestDefaultBudgetIsPercentOfCapacity(t *testing.T) {
	disk := DiskFacts{TotalBytes: 100 * GiB, AvailBytes: 80 * GiB}
	p := mustCalc(t, disk, ClassifyProfile(disk, false, ""), Overrides{})
	want := disk.TotalBytes / 100 * DefaultMaxPercent
	if p.BudgetBytes != want {
		t.Errorf("budget %d, want %d (%d%% of capacity)", p.BudgetBytes, want, DefaultMaxPercent)
	}
}

func TestOverrideMaxBytesCapsBudget(t *testing.T) {
	disk := DiskFacts{TotalBytes: 100 * GiB, AvailBytes: 80 * GiB}
	p := mustCalc(t, disk, ClassifyProfile(disk, false, ""), Overrides{MaxBytes: 3 * GiB})
	if p.BudgetBytes > 3*GiB {
		t.Errorf("MaxBytes override not honored: budget %d > 3G", p.BudgetBytes)
	}
	if p.PolicySource != "operator-override" {
		t.Errorf("policy source = %q, want operator-override", p.PolicySource)
	}
	if p.TheoreticalMaxBytes > p.BudgetBytes {
		t.Errorf("invariant broken under override: max %d > budget %d", p.TheoreticalMaxBytes, p.BudgetBytes)
	}
}

func TestOverrideProfileWins(t *testing.T) {
	disk := DiskFacts{TotalBytes: 500 * GiB, AvailBytes: 400 * GiB} // would auto-classify high-volume
	prof := ClassifyProfile(disk, false, "small")
	if prof.Name != "small" {
		t.Fatalf("override profile not applied: %s", prof.Name)
	}
	p := mustCalc(t, disk, prof, Overrides{Profile: "small"})
	if p.Profile.Name != "small" {
		t.Errorf("effective profile %s, want small", p.Profile.Name)
	}
}

func TestOverrideDaysClamp(t *testing.T) {
	disk := DiskFacts{TotalBytes: 200 * GiB, AvailBytes: 150 * GiB}
	p := mustCalc(t, disk, ClassifyProfile(disk, false, ""), Overrides{MinDays: 21, MaxDays: 40})
	for _, f := range p.Families {
		// non-fixed families should respect the [21,40] window (fixed report
		// families keep their monthly base and are exempt).
		if f.RetentionDays < 21 && f.Key != "reports" && f.Key != "reports-daily" {
			t.Errorf("family %s retention %dd below MinDays 21", f.Key, f.RetentionDays)
		}
	}
}

func TestInvalidOverridesFailNoSilentFallback(t *testing.T) {
	bad := []Overrides{
		{Mode: "bogus"},
		{Profile: "gigantic"},
		{MaxPercent: 200},
		{MaxPercent: -3},
		{MinDays: 90, MaxDays: 30},
	}
	disk := DiskFacts{TotalBytes: 50 * GiB, AvailBytes: 30 * GiB}
	for i, o := range bad {
		if err := o.Validate(); err == nil {
			t.Errorf("case %d: invalid override %+v passed validation", i, o)
		}
		if _, err := Calculate(disk, ClassifyProfile(disk, false, ""), o, DefaultFamilies()); err == nil {
			t.Errorf("case %d: Calculate silently accepted invalid override %+v", i, o)
		}
	}
}

func TestDeterministic(t *testing.T) {
	disk := DiskFacts{TotalBytes: 64 * GiB, AvailBytes: 40 * GiB}
	prof := ClassifyProfile(disk, true, "")
	a := mustCalc(t, disk, prof, Overrides{MinDays: 10})
	b := mustCalc(t, disk, prof, Overrides{MinDays: 10})
	if !reflect.DeepEqual(a, b) {
		t.Error("Calculate is not deterministic for identical inputs")
	}
}

func TestZeroCapacityRejected(t *testing.T) {
	if _, err := Calculate(DiskFacts{}, Profile{Name: "standard"}, Overrides{}, DefaultFamilies()); err == nil {
		t.Error("zero-capacity DiskFacts should be rejected")
	}
}
