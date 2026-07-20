// SPDX-License-Identifier: MPL-2.0
// meta:name="resource_tier_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.222.1 EXTRACT_SHARED_AUTHORITY tests: canonical ResourceTier boundary classification, consumer-parity proof that CIDR caps and daemon budgets are byte-for-byte unchanged per tier, and a structural dedup guard proving exactly one RAM threshold table and no health-local tier classifier."
package safety

import (
	"os"
	"strings"
	"testing"
)

// Boundary classification — the ONE authority. Preserves the released <=4G/<=8G/>8G.
func TestClassifyResourceTierBoundaries(t *testing.T) {
	const GB = int64(1) << 30
	cases := []struct {
		ram  int64
		want ResourceTier
	}{
		{0, ResourceTierSmall},
		{1 * GB, ResourceTierSmall},
		{4 * GB, ResourceTierSmall},
		{4*GB + 1, ResourceTierMedium},
		{GB * 77 / 10, ResourceTierMedium},
		{8 * GB, ResourceTierMedium},
		{8*GB + 1, ResourceTierLarge},
		{16 * GB, ResourceTierLarge},
	}
	for _, c := range cases {
		if got := ClassifyResourceTier(ServerProfile{TotalRAM: c.ram}); got != c.want {
			t.Errorf("ClassifyResourceTier(%d)=%q want %q", c.ram, got, c.want)
		}
	}
}

// Consumer parity: CIDR caps unchanged per tier (was 75k/100k/150k inline).
func TestCIDRCapParityPerTier(t *testing.T) {
	want := map[ResourceTier]int{
		ResourceTierSmall:  75000,
		ResourceTierMedium: 100000,
		ResourceTierLarge:  150000,
	}
	for tier, w := range want {
		if got := maxCIDRsForTier(tier); got != w {
			t.Errorf("maxCIDRsForTier(%q)=%d want %d (CIDR behavior must be unchanged)", tier, got, w)
		}
	}
}

// Consumer parity: daemon memory budget cap unchanged per tier (440/590/1178 MB).
func TestDaemonBudgetParityPerTier(t *testing.T) {
	const MB = int64(1024 * 1024)
	want := map[ResourceTier]int64{
		ResourceTierSmall:  440 * MB,
		ResourceTierMedium: 590 * MB,
		ResourceTierLarge:  1178 * MB,
	}
	for tier, w := range want {
		if got := daemonMaxBudgetForTier(tier); got != w {
			t.Errorf("daemonMaxBudgetForTier(%q)=%d want %d (daemon behavior must be unchanged)", tier, got, w)
		}
	}
}

// End-to-end tier identity: all three consumers agree on the tier for a given RAM.
func TestAllConsumersShareTierIdentity(t *testing.T) {
	const GB = int64(1) << 30
	for _, ram := range []int64{2 * GB, 6 * GB, 32 * GB} {
		p := ServerProfile{TotalRAM: ram, AvailRAM: ram / 2, CPUCores: 4}
		tier := ClassifyResourceTier(p)
		health := HealthServiceMemoryLimitsFor(p, tier)
		if health.Tier != tier {
			t.Errorf("ram=%d: health tier %q != canonical %q", ram, health.Tier, tier)
		}
	}
}

// Structural dedup guard: exactly one RAM threshold table, no health-local
// classifier, no stray inline `TotalRAM <= 4`-style tier switch.
func TestResourceTierSingleAuthorityStructuralGuard(t *testing.T) {
	entries, err := os.ReadDir(".")
	if err != nil {
		t.Fatal(err)
	}
	var filesWithThresholdConst, ramTierFuncs, inlineTierSwitches, classifyDefs int
	for _, e := range entries {
		name := e.Name()
		if !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		b, err := os.ReadFile(name)
		if err != nil {
			t.Fatal(err)
		}
		src := string(b)
		// The single threshold-table constant lives in exactly one file.
		if strings.Contains(src, "resourceTierSmallMaxBytes") && strings.Contains(src, "resourceTierMediumMaxBytes") {
			filesWithThresholdConst++
		}
		classifyDefs += strings.Count(src, "func ClassifyResourceTier")
		if strings.Contains(src, "func ramTier") {
			ramTierFuncs++
			t.Errorf("forbidden health-local classifier func ramTier found in %s", name)
		}
		// No consumer may re-introduce an inline RAM-tier switch on raw GB literals.
		inlineTierSwitches += strings.Count(src, "TotalRAM <= 4")
		inlineTierSwitches += strings.Count(src, "TotalRAM <= 8")
	}
	if filesWithThresholdConst != 1 {
		t.Errorf("RAM_THRESHOLD_TABLES=%d want 1 (single authority file resource_tier.go)", filesWithThresholdConst)
	}
	if classifyDefs != 1 {
		t.Errorf("ClassifyResourceTier definitions=%d want 1", classifyDefs)
	}
	if ramTierFuncs != 0 {
		t.Errorf("HEALTH_LOCAL_CLASSIFIER=%d want 0", ramTierFuncs)
	}
	if inlineTierSwitches != 0 {
		t.Errorf("inline RAM-tier switches outside ClassifyResourceTier=%d want 0", inlineTierSwitches)
	}
}
