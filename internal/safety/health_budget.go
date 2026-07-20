// meta:name="health_budget.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 HEALTH-OOM hotfix (Scope A+F): hardware-aware systemd memory budget for nftban-health.service. The health-check peak RSS is dominated by the Go validator buffering the full `nft -j list ruleset` (+ a transient ~2x while the nft child and Go parent both hold it) and 16 `nft -j list set` element reads; that buffer scales with ban-set/geoban/feeds ELEMENT count — not CPU cores, journal size, or concurrency (the check path is strictly sequential). Element count is itself capped per RAM tier, so the health memory need tracks the canonical ResourceTier. This is HEALTH-DOMAIN policy: it CONSUMES ClassifyResourceTier (the single RAM→tier authority in resource_tier.go) and maps the tier to health-specific MemoryHigh/MemoryMax, clamped to a safe fraction of total RAM with a floor so a tiny VPS is never handed an unsafe cap. It defines NO RAM thresholds and reads NO /proc facts of its own."
package safety

import "strconv"

// Health-service memory tiers: systemd MemoryHigh (soft, triggers reclaim) and
// MemoryMax (hard, cgroup OOM ceiling) budgets, mapped from the canonical
// ResourceTier. HEALTH-DOMAIN policy — the tier→bytes mapping only; the RAM→tier
// classification is ClassifyResourceTier's single responsibility.
//
// Small stays at the historical 256M hard cap (v1.174 HEALTH-OOM-JOURNALCTL):
// small hosts carry small nftables sets → low validator buffer → already safe.
// Medium/large are raised because their larger set buffers (+ transient 2x)
// crossed 256M (dns2 evidence: medium tier, MemoryPeak 256MiB+one-page, cgroup
// oom-kill on a host with GiB of free RAM).
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
	// (the validator needs at least this to complete on a normal ruleset).
	// MemoryMax = clamp(tierMax, floor, RAM/frac).
	healthMaxRAMFractionDiv = 4   // <= 25% of total RAM
	healthFloorMaxMB        = 128 // practical floor for the hard ceiling
)

// HealthResourceProfile is the resolved, operator-visible health resource sizing
// decision: the inputs (tier/cores/RAM) and the effective limits + reason.
type HealthResourceProfile struct {
	Tier       ResourceTier // canonical shared tier (from ClassifyResourceTier)
	CPUCores   int
	TotalRAM   int64 // bytes
	AvailRAM   int64 // bytes
	MemoryHigh int64 // bytes (systemd MemoryHigh)
	MemoryMax  int64 // bytes (systemd MemoryMax)
	Clamped    bool  // true if the min-host RAM clamp/floor changed a tier value
	Reason     string
}

// healthTierBudget maps the canonical RAM tier to health MemoryHigh/MemoryMax in
// MiB. HEALTH-DOMAIN policy; does not re-derive the tier.
func healthTierBudget(tier ResourceTier) (highMB, maxMB int64) {
	switch tier {
	case ResourceTierSmall:
		return healthSmallHighMB, healthSmallMaxMB
	case ResourceTierMedium:
		return healthMedHighMB, healthMedMaxMB
	default: // ResourceTierLarge
		return healthLargeHighMB, healthLargeMaxMB
	}
}

// HealthServiceMemoryLimitsFor computes the health-service budget from an explicit
// profile + its canonical tier. Pure and unit-testable. Returns MemoryHigh and
// MemoryMax in bytes plus whether the min-host clamp/floor altered a tier value.
//
// Invariants (asserted by tests): MemoryHigh < MemoryMax always; MemoryMax never
// exceeds TotalRAM/healthMaxRAMFractionDiv (when RAM is known) and never drops
// below healthFloorMaxMB.
func HealthServiceMemoryLimitsFor(profile ServerProfile, tier ResourceTier) HealthResourceProfile {
	highMB, maxMB := healthTierBudget(tier)
	high := highMB * healthMemMB
	max := maxMB * healthMemMB
	floor := int64(healthFloorMaxMB) * healthMemMB
	clamped := false

	// Min-host clamp: cap the hard ceiling at a safe fraction of total RAM.
	if profile.TotalRAM > 0 {
		fracCap := profile.TotalRAM / int64(healthMaxRAMFractionDiv)
		if fracCap < floor {
			// On a very small host the fraction cap would go below the floor;
			// the floor wins (a functioning health check needs at least this).
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

	// MemoryHigh must stay strictly below MemoryMax.
	if high >= max {
		high = max * 3 / 4
		clamped = true
	}

	reason := "tier=" + string(tier) + " (canonical safety RAM tier)"
	if clamped {
		reason += "; clamped to min-host RAM safety bound"
	}

	return HealthResourceProfile{
		Tier:       tier,
		CPUCores:   profile.CPUCores,
		TotalRAM:   profile.TotalRAM,
		AvailRAM:   profile.AvailRAM,
		MemoryHigh: high,
		MemoryMax:  max,
		Clamped:    clamped,
		Reason:     reason,
	}
}

// HealthServiceMemoryLimits resolves the health-service budget for THIS host,
// reusing the canonical fact authority (DetectServerProfile) and the canonical
// tier authority (ClassifyResourceTier). One classification, health-domain policy.
func HealthServiceMemoryLimits() HealthResourceProfile {
	p := DetectServerProfile()
	return HealthServiceMemoryLimitsFor(p, ClassifyResourceTier(p))
}

// SystemdMemBytes renders a byte count as a systemd-safe integer string (bytes);
// systemd accepts a bare integer as bytes for MemoryHigh/MemoryMax.
func SystemdMemBytes(b int64) string { return strconv.FormatInt(b, 10) }
