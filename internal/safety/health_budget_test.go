// meta:name="health_budget_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 HEALTH-OOM hotfix tests for HealthServiceMemoryLimitsFor: tier mapping, the MemoryHigh<MemoryMax invariant, the min-host RAM clamp (tiny VPS never gets an unsafe cap), the practical floor, monotonic-by-tier sizing, and the concrete fleet/dns2 cases (Scope-F P2/P3/P4/P6)."
package safety

import "testing"

const gib = int64(1) << 30

func TestRAMTierBoundaries(t *testing.T) {
	cases := []struct {
		ram  int64
		want string
	}{
		{1 * gib, "small"},
		{4 * gib, "small"},
		{4*gib + 1, "medium"},
		{7 * gib, "medium"}, // dns1/dns2 = 7.7G
		{8 * gib, "medium"},
		{8*gib + 1, "large"},
		{15 * gib, "large"}, // most of the fleet
	}
	for _, c := range cases {
		if got := ramTier(c.ram); got != c.want {
			t.Errorf("ramTier(%d)=%q want %q", c.ram, got, c.want)
		}
	}
}

// The core safety invariant: MemoryHigh strictly below MemoryMax, MemoryMax
// never above 25% of total RAM, never below the floor — across a wide matrix
// including tiny VPS and huge hosts.
func TestHealthBudgetInvariants(t *testing.T) {
	rams := []int64{
		256 * healthMemMB, 512 * healthMemMB, 1 * gib, 2 * gib, 4 * gib,
		int64(7.7 * float64(gib)), 8 * gib, 16 * gib, 64 * gib,
	}
	floor := int64(healthFloorMaxMB) * healthMemMB
	for _, ram := range rams {
		p := HealthServiceMemoryLimitsFor(ram, ram/2, 4)
		if p.MemoryHigh >= p.MemoryMax {
			t.Errorf("ram=%d: MemoryHigh(%d) >= MemoryMax(%d)", ram, p.MemoryHigh, p.MemoryMax)
		}
		if p.MemoryMax < floor {
			t.Errorf("ram=%d: MemoryMax(%d) below floor(%d)", ram, p.MemoryMax, floor)
		}
		// Hard ceiling must never exceed 25% of total RAM unless the floor forced
		// it (only possible when 25%RAM < floor, i.e. RAM < 4*floor = 512M).
		fracCap := ram / int64(healthMaxRAMFractionDiv)
		if p.MemoryMax > fracCap && fracCap >= floor {
			t.Errorf("ram=%d: MemoryMax(%d) exceeds RAM/4(%d)", ram, p.MemoryMax, fracCap)
		}
		if p.MemoryHigh <= 0 {
			t.Errorf("ram=%d: MemoryHigh must be positive, got %d", ram, p.MemoryHigh)
		}
	}
}

// P2 — constrained RAM: a tiny VPS must be clamped, never handed an unsafe cap.
func TestHealthBudgetTinyVPSClamped(t *testing.T) {
	// 512 MiB host: tier "small" wants 256M hard, but 25% = 128M; floor = 128M.
	p := HealthServiceMemoryLimitsFor(512*healthMemMB, 200*healthMemMB, 1)
	if p.Tier != "small" {
		t.Fatalf("512M host tier=%q want small", p.Tier)
	}
	if p.MemoryMax > 512*healthMemMB/4 && p.MemoryMax != int64(healthFloorMaxMB)*healthMemMB {
		t.Errorf("512M host MemoryMax=%d not clamped to RAM/4 or floor", p.MemoryMax)
	}
	if !p.Clamped {
		t.Errorf("512M host should report Clamped=true (got false); Max=%d", p.MemoryMax)
	}
	if p.MemoryHigh >= p.MemoryMax {
		t.Errorf("512M host MemoryHigh(%d) >= MemoryMax(%d)", p.MemoryHigh, p.MemoryMax)
	}
}

// P3 — standard/dns2-class host (medium tier, 7.7 GiB): must get more than the
// pre-hotfix 256M so the observed 256M+ peak fits, and stay far under RAM/4.
func TestHealthBudgetMediumRaisesAbovePreHotfix(t *testing.T) {
	p := HealthServiceMemoryLimitsFor(int64(7.7*float64(gib)), 4*gib, 4)
	if p.Tier != "medium" {
		t.Fatalf("7.7G tier=%q want medium", p.Tier)
	}
	preHotfix := int64(256) * healthMemMB
	if p.MemoryMax <= preHotfix {
		t.Errorf("medium MemoryMax=%d must exceed pre-hotfix 256M (dns2 OOM'd at 256M+)", p.MemoryMax)
	}
	if p.Clamped {
		t.Errorf("7.7G host should NOT be clamped (RAM/4=%d >> tier max)", p.TotalRAM/4)
	}
}

// P4 — large/high-volume host (>8 GiB): largest set buffers → largest budget,
// trivially safe against RAM/4.
func TestHealthBudgetLargeHost(t *testing.T) {
	p := HealthServiceMemoryLimitsFor(16*gib, 10*gib, 8)
	if p.Tier != "large" {
		t.Fatalf("16G tier=%q want large", p.Tier)
	}
	if p.MemoryMax != int64(healthLargeMaxMB)*healthMemMB {
		t.Errorf("large MemoryMax=%d want %d", p.MemoryMax, int64(healthLargeMaxMB)*healthMemMB)
	}
}

// Sizing must be monotonic non-decreasing by tier (set buffer grows with the
// RAM-tier-capped element count).
func TestHealthBudgetMonotonicByTier(t *testing.T) {
	small := HealthServiceMemoryLimitsFor(4*gib, 2*gib, 2)
	med := HealthServiceMemoryLimitsFor(6*gib, 3*gib, 4)
	large := HealthServiceMemoryLimitsFor(16*gib, 8*gib, 8)
	if !(small.MemoryMax <= med.MemoryMax && med.MemoryMax <= large.MemoryMax) {
		t.Errorf("MemoryMax not monotonic by tier: small=%d med=%d large=%d",
			small.MemoryMax, med.MemoryMax, large.MemoryMax)
	}
	// Small tier preserves the historical safe 256M hard cap on a >=1G small host.
	if small.MemoryMax != int64(healthSmallMaxMB)*healthMemMB {
		t.Errorf("small(4G) MemoryMax=%d want unchanged 256M", small.MemoryMax)
	}
}

func TestHealthBudgetZeroRAMFailsSafe(t *testing.T) {
	// Unknown RAM (0): no fraction clamp possible, but the floor still applies and
	// the tier default (large, since 0 <= nothing... 0 is <=4G → small) holds.
	p := HealthServiceMemoryLimitsFor(0, 0, 1)
	floor := int64(healthFloorMaxMB) * healthMemMB
	if p.MemoryMax < floor {
		t.Errorf("zero-RAM MemoryMax=%d below floor %d", p.MemoryMax, floor)
	}
	if p.MemoryHigh >= p.MemoryMax {
		t.Errorf("zero-RAM MemoryHigh(%d) >= MemoryMax(%d)", p.MemoryHigh, p.MemoryMax)
	}
}
