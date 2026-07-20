// meta:name="health_budget_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 HEALTH-OOM hotfix tests for HealthServiceMemoryLimitsFor: MemoryHigh<MemoryMax invariant, the min-host RAM clamp (tiny VPS never gets an unsafe cap), the practical floor, monotonic-by-tier sizing, and the concrete fleet/dns2 cases (Scope-F P2/P3/P4/P6). Consumes the canonical ResourceTier — no health-local RAM classifier."
package safety

import "testing"

const testGiB = int64(1) << 30

func prof(totalRAM, availRAM int64, cores int) ServerProfile {
	return ServerProfile{TotalRAM: totalRAM, AvailRAM: availRAM, CPUCores: cores}
}

func healthFor(totalRAM, availRAM int64, cores int) HealthResourceProfile {
	p := prof(totalRAM, availRAM, cores)
	return HealthServiceMemoryLimitsFor(p, ClassifyResourceTier(p))
}

// Core safety invariant across a wide matrix incl. tiny VPS and huge hosts.
func TestHealthBudgetInvariants(t *testing.T) {
	rams := []int64{
		256 * healthMemMB, 512 * healthMemMB, 1 * testGiB, 2 * testGiB, 4 * testGiB,
		testGiB * 77 / 10, 8 * testGiB, 16 * testGiB, 64 * testGiB,
	}
	floor := int64(healthFloorMaxMB) * healthMemMB
	for _, ram := range rams {
		p := healthFor(ram, ram/2, 4)
		if p.MemoryHigh >= p.MemoryMax {
			t.Errorf("ram=%d: MemoryHigh(%d) >= MemoryMax(%d)", ram, p.MemoryHigh, p.MemoryMax)
		}
		if p.MemoryMax < floor {
			t.Errorf("ram=%d: MemoryMax(%d) below floor(%d)", ram, p.MemoryMax, floor)
		}
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
	p := healthFor(512*healthMemMB, 200*healthMemMB, 1) // 512 MiB host
	if p.Tier != ResourceTierSmall {
		t.Fatalf("512M host tier=%q want small", p.Tier)
	}
	floor := int64(healthFloorMaxMB) * healthMemMB
	if p.MemoryMax > 512*healthMemMB/4 && p.MemoryMax != floor {
		t.Errorf("512M host MemoryMax=%d not clamped to RAM/4 or floor", p.MemoryMax)
	}
	if !p.Clamped {
		t.Errorf("512M host should report Clamped=true; Max=%d", p.MemoryMax)
	}
	if p.MemoryHigh >= p.MemoryMax {
		t.Errorf("512M host MemoryHigh(%d) >= MemoryMax(%d)", p.MemoryHigh, p.MemoryMax)
	}
}

// P3 — dns2-class host (medium tier, 7.7 GiB): must exceed the pre-hotfix 256M so
// the observed 256M+ peak fits, and stay well under RAM/4.
func TestHealthBudgetMediumRaisesAbovePreHotfix(t *testing.T) {
	p := healthFor(testGiB*77/10, 4*testGiB, 4) // 7.7 GiB
	if p.Tier != ResourceTierMedium {
		t.Fatalf("7.7G tier=%q want medium", p.Tier)
	}
	if p.MemoryMax <= int64(256)*healthMemMB {
		t.Errorf("medium MemoryMax=%d must exceed pre-hotfix 256M (dns2 OOM'd at 256M+)", p.MemoryMax)
	}
	if p.Clamped {
		t.Errorf("7.7G host should NOT be clamped (RAM/4=%d >> tier max)", p.TotalRAM/4)
	}
}

// P4 — large host (>8 GiB): largest set buffers → largest budget, safe vs RAM/4.
func TestHealthBudgetLargeHost(t *testing.T) {
	p := healthFor(16*testGiB, 10*testGiB, 8)
	if p.Tier != ResourceTierLarge {
		t.Fatalf("16G tier=%q want large", p.Tier)
	}
	if p.MemoryMax != int64(healthLargeMaxMB)*healthMemMB {
		t.Errorf("large MemoryMax=%d want %d", p.MemoryMax, int64(healthLargeMaxMB)*healthMemMB)
	}
}

// Sizing must be monotonic non-decreasing by tier.
func TestHealthBudgetMonotonicByTier(t *testing.T) {
	small := healthFor(4*testGiB, 2*testGiB, 2)
	med := healthFor(6*testGiB, 3*testGiB, 4)
	large := healthFor(16*testGiB, 8*testGiB, 8)
	if !(small.MemoryMax <= med.MemoryMax && med.MemoryMax <= large.MemoryMax) {
		t.Errorf("MemoryMax not monotonic: small=%d med=%d large=%d", small.MemoryMax, med.MemoryMax, large.MemoryMax)
	}
	if small.MemoryMax != int64(healthSmallMaxMB)*healthMemMB {
		t.Errorf("small(4G) MemoryMax=%d want unchanged 256M", small.MemoryMax)
	}
}

func TestHealthBudgetZeroRAMFailsSafe(t *testing.T) {
	p := healthFor(0, 0, 1)
	floor := int64(healthFloorMaxMB) * healthMemMB
	if p.MemoryMax < floor {
		t.Errorf("zero-RAM MemoryMax=%d below floor %d", p.MemoryMax, floor)
	}
	if p.MemoryHigh >= p.MemoryMax {
		t.Errorf("zero-RAM MemoryHigh(%d) >= MemoryMax(%d)", p.MemoryHigh, p.MemoryMax)
	}
	if p.Tier != ResourceTierSmall {
		t.Errorf("zero-RAM tier=%q want small (conservative default)", p.Tier)
	}
}

// Health must consume the canonical tier: same tier in → same health budget out.
func TestHealthBudgetConsumesCanonicalTier(t *testing.T) {
	p := prof(6*testGiB, 3*testGiB, 4)
	got := HealthServiceMemoryLimitsFor(p, ClassifyResourceTier(p))
	if got.Tier != ClassifyResourceTier(p) {
		t.Errorf("health tier %q != canonical %q", got.Tier, ClassifyResourceTier(p))
	}
}
