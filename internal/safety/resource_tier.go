// SPDX-License-Identifier: MPL-2.0
// meta:name="resource_tier.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 EXTRACT_SHARED_AUTHORITY: the ONE canonical host RAM-tier authority for internal/safety. Before this, the ≤4GB/≤8GB/>8GB threshold table was duplicated inline in GetMaxCIDRsHard, GetMaxCIDRsHardWithTier, and GetResourceLimits (and a 4th copy was proposed in the health-budget lane). This is now the single classifier; CIDR policy, daemon resource limits, and health resource policy all CONSUME it and map the tier to their own domain values. It is a generic hardware dimension — no CIDR/health/domain name in the type. Facts come from the existing DetectServerProfile()/AvailableMem() authority; this adds NO new /proc parser."
package safety

// ResourceTier is the canonical host RAM/hardware size class. It is a generic
// hardware dimension shared by every internal/safety resource-policy consumer
// (CIDR limits, daemon budget, health-service memory). It intentionally carries
// no domain name (not "CIDRTier", not "HealthTier").
type ResourceTier string

const (
	ResourceTierSmall  ResourceTier = "small"  // <= 4 GiB total RAM
	ResourceTierMedium ResourceTier = "medium" // 4 GiB < RAM <= 8 GiB
	ResourceTierLarge  ResourceTier = "large"  // > 8 GiB total RAM
)

// resourceTierGiB is the byte size of one GiB, kept private to the single
// classifier so the threshold table exists in exactly one place.
const resourceTierGiB = int64(1) << 30

// resourceTierSmallMaxBytes and resourceTierMediumMaxBytes are the ONLY RAM-tier
// boundaries in the codebase. Every historical inline 4 GiB / 8 GiB total-RAM tier
// switch (GetMaxCIDRsHard, GetMaxCIDRsHardWithTier, GetResourceLimits) is replaced
// by ClassifyResourceTier so this table is never duplicated.
const (
	resourceTierSmallMaxBytes  = 4 * resourceTierGiB
	resourceTierMediumMaxBytes = 8 * resourceTierGiB
)

// ClassifyResourceTier maps a host profile to its canonical RAM tier.
//
// Semantics are preserved byte-for-byte from the pre-v1.222.1 inline switches:
// classification keys on profile.TotalRAM (NOT AvailRAM / NOT the cgroup current)
// with boundaries <=4GiB → small, <=8GiB → medium, else large. A zero/unknown
// TotalRAM falls into the small (most conservative) tier, matching the prior
// behavior where `0 <= 4*GB` selected the small branch — the safe default.
func ClassifyResourceTier(profile ServerProfile) ResourceTier {
	switch {
	case profile.TotalRAM <= resourceTierSmallMaxBytes:
		return ResourceTierSmall
	case profile.TotalRAM <= resourceTierMediumMaxBytes:
		return ResourceTierMedium
	default:
		return ResourceTierLarge
	}
}

// CurrentResourceTier classifies THIS host using the canonical fact authority.
func CurrentResourceTier() ResourceTier {
	return ClassifyResourceTier(DetectServerProfile())
}
