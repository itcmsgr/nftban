// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-boundary-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Adversarial boundary tests for the Gate B retention calculator: tiny disk, forensic floor larger than a low MaxDays (floor wins), MaxBytes below the minimum floor, huge capacity (overflow-safe), Statfs failure, forced profiles, one family dominating the budget, sum-of-floors near/above the configured cap, and the per-family safety ceiling. Every case must uphold UNBOUNDED=0 and THEORETICAL_MAX<=BUDGET."
// meta:inventory.files="internal/logretention/logretention.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package logretention

import (
	"math"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func assertInvariants(t *testing.T, p EffectivePolicy) {
	t.Helper()
	if p.UnboundedCount != 0 {
		t.Errorf("UNBOUNDED_STANZAS = %d, want 0", p.UnboundedCount)
	}
	if p.TheoreticalMaxBytes > p.BudgetBytes {
		t.Errorf("THEORETICAL_MAX %d > BUDGET %d", p.TheoreticalMaxBytes, p.BudgetBytes)
	}
	for _, f := range p.Families {
		if f.SizeCapBytes == 0 || f.RotateCount < 1 {
			t.Errorf("family %s unbounded/degenerate: size=%d rotate=%d", f.Key, f.SizeCapBytes, f.RotateCount)
		}
	}
}

func TestFloorLargerThanLowMaxDays(t *testing.T) {
	// audit family has FloorDays=30; an operator MaxDays=10 must NOT cut it below
	// its forensic floor — the floor wins.
	disk := DiskFacts{TotalBytes: 80 * GiB, AvailBytes: 60 * GiB}
	p := mustCalc(t, disk, ClassifyProfile(disk, false, ""), Overrides{MaxDays: 10})
	assertInvariants(t, p)
	for _, f := range p.Families {
		if f.Key == "audit" {
			if f.RetentionDays < 30 {
				t.Errorf("audit retention %dd cut below forensic floor 30d by MaxDays=10", f.RetentionDays)
			}
			if f.ForensicFloorDays < 30 {
				t.Errorf("audit forensic floor reported %dd, want >=30", f.ForensicFloorDays)
			}
		}
	}
}

func TestMaxBytesBelowMinimumFloor(t *testing.T) {
	// A 1 MiB cap is far below the achievable minimum policy. The budget must rise
	// to the forensic+fixed floor (the floor overrides an impossibly small cap),
	// and the invariant must still hold.
	disk := DiskFacts{TotalBytes: 50 * GiB, AvailBytes: 40 * GiB}
	p := mustCalc(t, disk, ClassifyProfile(disk, false, ""), Overrides{MaxBytes: 1 * MiB})
	assertInvariants(t, p)
	if p.BudgetBytes <= 1*MiB {
		t.Errorf("budget %d did not rise above the impossibly small MaxBytes cap", p.BudgetBytes)
	}
}

func TestHugeCapacityOverflowSafe(t *testing.T) {
	for _, tot := range []uint64{100 * 1024 * GiB, math.MaxUint64} {
		disk := DiskFacts{TotalBytes: tot, AvailBytes: tot / 2}
		p, err := Calculate(disk, ClassifyProfile(disk, false, ""), Overrides{}, DefaultFamilies())
		if err != nil {
			t.Fatalf("huge capacity %d errored: %v", tot, err)
		}
		assertInvariants(t, p)
		if p.BudgetBytes > maxBudgetBytes {
			t.Errorf("budget %d exceeds sanity ceiling %d", p.BudgetBytes, maxBudgetBytes)
		}
	}
}

func TestStatfsFailure(t *testing.T) {
	if _, err := DetectDiskFacts("/nonexistent/path/should/not/exist/xyzzy"); err == nil {
		t.Error("DetectDiskFacts on a bad path should error")
	}
}

func TestPerFamilySafetyCeiling(t *testing.T) {
	// On a very large disk with budget to spare, retention must still be bounded by
	// each family's safety ceiling (high<=30, medium<=45, low<=120), not expand
	// without limit.
	disk := DiskFacts{TotalBytes: 2 * 1024 * GiB, AvailBytes: 1500 * GiB}
	p := mustCalc(t, disk, ClassifyProfile(disk, false, ""), Overrides{})
	assertInvariants(t, p)
	fams := DefaultFamilies()
	byKey := map[string]LogFamily{}
	for _, f := range fams {
		byKey[f.Key] = f
	}
	for _, f := range p.Families {
		lf := byKey[f.Key]
		if lf.Fixed {
			continue
		}
		ceil := lf.CeilingDays
		if ceil == 0 {
			ceil = ceilingDaysForVolume(lf.Volume)
		}
		if f.RetentionDays > ceil {
			t.Errorf("family %s retention %dd exceeds safety ceiling %dd", f.Key, f.RetentionDays, ceil)
		}
	}
}

func TestOneFamilyDominatingBudget(t *testing.T) {
	fams := []LogFamily{
		{Key: "whale", File: "main", Cadence: "daily", Volume: VolumeHigh, Weight: 1000, FloorDays: 7, BaseSizeBytes: 500 * MiB, Copytruncate: true, Create: "0640 nftban nftban", Paths: []string{"/var/log/nftban/whale.log"}},
		{Key: "minnow", File: "main", Cadence: "weekly", Volume: VolumeLow, Weight: 1, FloorDays: 7, BaseSizeBytes: 10 * MiB, Copytruncate: true, Create: "0640 nftban nftban", Paths: []string{"/var/log/nftban/minnow.log"}},
	}
	disk := DiskFacts{TotalBytes: 40 * GiB, AvailBytes: 30 * GiB}
	p, err := Calculate(disk, ClassifyProfile(disk, false, ""), Overrides{}, fams)
	if err != nil {
		t.Fatal(err)
	}
	assertInvariants(t, p)
	var whale, minnow FamilyPolicy
	for _, f := range p.Families {
		if f.Key == "whale" {
			whale = f
		}
		if f.Key == "minnow" {
			minnow = f
		}
	}
	if whale.WorstCaseBytes <= minnow.WorstCaseBytes {
		t.Errorf("dominating family should get more budget: whale=%d minnow=%d", whale.WorstCaseBytes, minnow.WorstCaseBytes)
	}
	if minnow.SizeCapBytes < minFamilySizeBytes {
		t.Errorf("minnow starved below floor: %d", minnow.SizeCapBytes)
	}
}

func TestSumOfFloorsNearCap(t *testing.T) {
	// Set MaxBytes right around the floor sum; the calculator must never produce a
	// policy exceeding max(MaxBytes, floor) and must stay bounded either way.
	disk := DiskFacts{TotalBytes: 60 * GiB, AvailBytes: 50 * GiB}
	// discover the floor by asking for an impossibly small cap
	floor := mustCalc(t, disk, ClassifyProfile(disk, false, ""), Overrides{MaxBytes: 1}).BudgetBytes
	for _, cap := range []uint64{floor - 50*MiB, floor, floor + 50*MiB} {
		p := mustCalc(t, disk, ClassifyProfile(disk, false, ""), Overrides{MaxBytes: cap})
		assertInvariants(t, p)
		if p.BudgetBytes < floor {
			t.Errorf("budget %d dropped below the forensic floor %d (cap=%d)", p.BudgetBytes, floor, cap)
		}
	}
}

func TestCapacityVerdictFloorExceedsCapacity(t *testing.T) {
	// A disk smaller than the sum of forensic floors is UNACHIEVABLE — the
	// calculator must flag it, not silently emit a "fits" policy (R7).
	disk := DiskFacts{TotalBytes: 500 * MiB, AvailBytes: 400 * MiB}
	p := mustCalc(t, disk, ClassifyProfile(disk, false, ""), Overrides{})
	if p.Achievable {
		t.Error("tiny disk below Σfloors should be unachievable")
	}
	if p.CapacityVerdict != CapFloorOverCapacity {
		t.Errorf("verdict = %s, want %s", p.CapacityVerdict, CapFloorOverCapacity)
	}
	if p.MinimumAchievableBytes <= disk.TotalBytes {
		t.Errorf("min-achievable %d should exceed capacity %d for this case", p.MinimumAchievableBytes, disk.TotalBytes)
	}
}

func TestGenerateRefusesUnachievablePolicy(t *testing.T) {
	dir := t.TempDir()
	_, err := Generate(GenerateOptions{
		MainPath:  filepath.Join(dir, "nftban"),
		StatePath: filepath.Join(dir, "state.json"),
		Disk:      DiskFacts{TotalBytes: 500 * MiB, AvailBytes: 400 * MiB},
		Validator: func([]string) (string, error) { return "stub", nil },
		Now:       time.Now(),
	})
	if err == nil {
		t.Fatal("Generate must refuse an unachievable (FLOOR_EXCEEDS_CAPACITY) policy")
	}
	if _, e := os.Stat(filepath.Join(dir, "state.json")); !os.IsNotExist(e) {
		t.Error("no state should be written for a refused policy")
	}
	if _, e := os.Stat(filepath.Join(dir, "nftban")); !os.IsNotExist(e) {
		t.Error("no policy file should be activated for a refused policy")
	}
}

func TestOperatorCapExceededVerdict(t *testing.T) {
	disk := DiskFacts{TotalBytes: 50 * GiB, AvailBytes: 40 * GiB}
	p := mustCalc(t, disk, ClassifyProfile(disk, false, ""), Overrides{MaxBytes: 100 * MiB})
	if !p.OperatorCapExceeded || p.CapacityVerdict != CapFloorOverOpCap {
		t.Errorf("MaxBytes below floor: opCapExceeded=%v verdict=%s", p.OperatorCapExceeded, p.CapacityVerdict)
	}
	// still achievable (floor fits the big disk) and still bounded
	if !p.Achievable {
		t.Error("policy should be achievable on a 50G disk")
	}
	assertInvariants(t, p)
}

func TestForensicFloorKindAndSizeTriggered(t *testing.T) {
	disk := DiskFacts{TotalBytes: 50 * GiB, AvailBytes: 40 * GiB}
	p := mustCalc(t, disk, ClassifyProfile(disk, false, ""), Overrides{})
	if p.ForensicFloorKind != "generations_and_bytes" {
		t.Errorf("forensic floor kind = %q, want generations_and_bytes (R6)", p.ForensicFloorKind)
	}
	for _, f := range p.Families {
		if !f.SizeTriggered {
			t.Errorf("family %s not marked size-triggered (all families are size-capped)", f.Key)
		}
		// hard floor = generations x size = worst-case bytes
		if uint64(f.RotateCount)*f.SizeCapBytes != f.WorstCaseBytes {
			t.Errorf("family %s: rotate*size != worst-case (%d*%d != %d)", f.Key, f.RotateCount, f.SizeCapBytes, f.WorstCaseBytes)
		}
	}
	if p.CapacityVerdict != CapAchievable {
		t.Errorf("normal disk verdict = %s, want ACHIEVABLE", p.CapacityVerdict)
	}
}

func TestForcedProfilesRetentionDiffers(t *testing.T) {
	disk := DiskFacts{TotalBytes: 100 * GiB, AvailBytes: 80 * GiB}
	small := mustCalc(t, disk, ClassifyProfile(disk, false, "small"), Overrides{Profile: "small"})
	high := mustCalc(t, disk, ClassifyProfile(disk, false, "high-volume"), Overrides{Profile: "high-volume"})
	assertInvariants(t, small)
	assertInvariants(t, high)
	// pick module-daily: high-volume profile should retain >= small profile
	get := func(p EffectivePolicy, key string) FamilyPolicy {
		for _, f := range p.Families {
			if f.Key == key {
				return f
			}
		}
		return FamilyPolicy{}
	}
	if get(high, "module-daily").RetentionDays < get(small, "module-daily").RetentionDays {
		t.Errorf("high-volume profile retained less than small: %d < %d",
			get(high, "module-daily").RetentionDays, get(small, "module-daily").RetentionDays)
	}
}
