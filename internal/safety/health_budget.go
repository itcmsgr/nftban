// meta:name="health_budget.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 HEALTH-OOM hotfix (Scope A+F): hardware/workload-aware systemd memory budget for nftban-health.service. The health-check peak RSS is dominated by the Go validator buffering the full `nft -j list ruleset` (+ a transient ~2x while the nft child and Go parent both hold it) and 16 `nft -j list set` element reads; that buffer scales with ban-set/geoban/feeds ELEMENT count — not CPU cores, journal size, or concurrency (the check path is strictly sequential). Element count is itself RAM-tier-capped by GetMaxCIDRsHardWithTier (small<=75k / medium<=100k / large<=150k), so the health memory need tracks the RAM tier. This computes MemoryHigh (soft throttle) + MemoryMax (hard ceiling) from the canonical safety RAM tier, clamped to a safe fraction of total RAM with a hard floor so a tiny VPS is never given an unsafe cap. Consumed by the installer (writes a systemd drop-in) and by `nftban-core resource-profile` (operator diagnostics)."
package safety

import "strconv"

// Health-service memory tiers. These are the systemd MemoryHigh (soft, triggers
// reclaim/throttle) and MemoryMax (hard, cgroup OOM ceiling) budgets for
// nftban-health.service, keyed on the same RAM tiers used by GetResourceLimits
// (small <=4GB / medium 4-8GB / large >8GB).
//
// Small stays at the historical 256M hard cap (v1.174 HEALTH-OOM-JOURNALCTL):
// small hosts carry small nftables sets, so the validator buffer stays low and
// the pre-hotfix behaviour was already safe there. Medium/large are raised
// because their larger set buffers (and the transient 2x) crossed 256M — the
// dns2 evidence (medium tier, MemoryPeak 256MiB+one-page, cgroup oom-kill on a
// host with GiB of free RAM).
const (
	healthMemMB = 1024 * 1024

	// Soft (MemoryHigh) / hard (MemoryMax) per tier, in MiB.
	healthSmallHighMB = 192
	healthSmallMaxMB  = 256
	healthMedHighMB   = 256
	healthMedMaxMB    = 384
	healthLargeHighMB = 384
	healthLargeMaxMB  = 512

	// Min-host safety: never let the hard ceiling exceed this fraction of TOTAL
	// RAM (guards tiny VPS/IoT hosts), and never drop below this practical floor
	// (the validator needs at least this to complete without a self-inflicted OOM
	// on a normally-sized ruleset). MemoryMax = clamp(tierMax, floor, RAM/frac).
	healthMaxRAMFractionDiv = 4         // <= 25% of total RAM
	healthFloorMaxMB        = 128       // practical floor for the hard ceiling
	oneGiB                  = int64(1) << 30
)

// HealthResourceProfile is the resolved, operator-visible health resource sizing
// decision for this host: the inputs (tier/cores/RAM) and the effective limits.
type HealthResourceProfile struct {
	Tier       string // "small" | "medium" | "large"
	CPUCores   int
	TotalRAM   int64 // bytes
	AvailRAM   int64 // bytes
	MemoryHigh int64 // bytes (systemd MemoryHigh)
	MemoryMax  int64 // bytes (systemd MemoryMax)
	Clamped    bool  // true if min-host RAM clamp/floor changed a tier value
}

// ramTier classifies total RAM into the same tiers GetResourceLimits uses.
func ramTier(totalRAM int64) string {
	const GB = int64(1) << 30
	switch {
	case totalRAM <= 4*GB:
		return "small"
	case totalRAM <= 8*GB:
		return "medium"
	default:
		return "large"
	}
}

// healthTierBudget returns the raw (pre-clamp) MemoryHigh/MemoryMax for a tier.
func healthTierBudget(tier string) (highMB, maxMB int64) {
	switch tier {
	case "small":
		return healthSmallHighMB, healthSmallMaxMB
	case "medium":
		return healthMedHighMB, healthMedMaxMB
	default: // "large"
		return healthLargeHighMB, healthLargeMaxMB
	}
}

// HealthServiceMemoryLimitsFor computes the health-service budget for an explicit
// profile. Split from HealthServiceMemoryLimits so it is pure and unit-testable
// without touching /proc. Returns MemoryHigh and MemoryMax in bytes, the tier,
// and whether the min-host clamp/floor altered a tier value.
//
// Invariants (asserted by tests): MemoryHigh < MemoryMax always; MemoryMax never
// exceeds total_RAM/healthMaxRAMFractionDiv (when RAM is known) and never drops
// below healthFloorMaxMB.
func HealthServiceMemoryLimitsFor(totalRAM, availRAM int64, cores int) HealthResourceProfile {
	tier := ramTier(totalRAM)
	highMB, maxMB := healthTierBudget(tier)
	high := highMB * healthMemMB
	max := maxMB * healthMemMB
	floor := int64(healthFloorMaxMB) * healthMemMB
	clamped := false

	// Min-host clamp: cap the hard ceiling at a safe fraction of total RAM.
	// Only meaningful when totalRAM is known (>0).
	if totalRAM > 0 {
		fracCap := totalRAM / int64(healthMaxRAMFractionDiv)
		if fracCap < floor {
			// On a very small host the fraction cap would go below the floor;
			// the floor wins (a functioning health check needs at least this),
			// but we never exceed the tier value either.
			fracCap = floor
		}
		if max > fracCap {
			max = fracCap
			clamped = true
		}
	}
	if max < floor {
		max = floor
		clamped = true
	}

	// MemoryHigh must stay strictly below MemoryMax; keep it at ~75% of the
	// (possibly clamped) hard ceiling if the tier soft value would meet/exceed it.
	if high >= max {
		high = max * 3 / 4
		clamped = true
	}

	return HealthResourceProfile{
		Tier:       tier,
		CPUCores:   cores,
		TotalRAM:   totalRAM,
		AvailRAM:   availRAM,
		MemoryHigh: high,
		MemoryMax:  max,
		Clamped:    clamped,
	}
}

// HealthServiceMemoryLimits resolves the health-service budget for THIS host by
// reading the canonical safety profile (RAM tier + cores). Reuses
// DetectServerProfile so there is one host-profile authority, not a duplicate
// classifier.
func HealthServiceMemoryLimits() HealthResourceProfile {
	p := DetectServerProfile()
	return HealthServiceMemoryLimitsFor(p.TotalRAM, p.AvailRAM, p.CPUCores)
}

// SystemdMemBytes renders a byte count as a systemd-safe integer string (bytes).
// systemd accepts a bare integer as bytes for MemoryHigh/MemoryMax.
func SystemdMemBytes(b int64) string { return strconv.FormatInt(b, 10) }
