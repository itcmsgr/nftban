// SPDX-License-Identifier: MPL-2.0
// meta:name="verdict_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.223.0 verdict-truth: IsZero + the shared tier-aware AcceptableFor predicate (installer==CLI==revalidate). Closes the test-blindness that let RESOURCES-VERDICT-TIER-BLIND + the zero-verdict handling ship untested."
package healthresource

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/safety"
)

func TestVerdictIsZero(t *testing.T) {
	if !(Verdict{}).IsZero() {
		t.Fatal("a zero Verdict must report IsZero")
	}
	if (Verdict{EffectiveState: StateActiveMatch}).IsZero() {
		t.Fatal("populated EffectiveState is not zero")
	}
	if (Verdict{Profile: safety.HealthResourceProfile{Tier: safety.ResourceTierMedium}}).IsZero() {
		t.Fatal("populated tier is not zero")
	}
	if (Verdict{CalculatedMax: 1}).IsZero() {
		t.Fatal("populated calc is not zero")
	}
	// A resolved-but-unavailable verdict is MARKED, never zero.
	if (Verdict{EffectiveState: StateUnavailable}).IsZero() {
		t.Fatal("StateUnavailable is a marked verdict, not zero")
	}
}

func TestAcceptableFor(t *testing.T) {
	cases := []struct {
		tier safety.ResourceTier
		st   State
		want bool
	}{
		{safety.ResourceTierSmall, StateActiveMatch, true},
		{safety.ResourceTierMedium, StateActiveMatch, true},
		{safety.ResourceTierLarge, StateActiveMatch, true},
		{safety.ResourceTierSmall, StateFallbackMatch, true},   // small: packaged fallback meets calc
		{safety.ResourceTierMedium, StateFallbackMatch, false}, // medium/large: fallback is underprotection
		{safety.ResourceTierLarge, StateFallbackMatch, false},
		{safety.ResourceTierMedium, StateFallbackUnder, false},
		{safety.ResourceTierSmall, StateFallbackUnder, false},
		{safety.ResourceTierMedium, State(""), false}, // zero state never acceptable (no silent-protect)
		{safety.ResourceTier(""), State(""), false},
		{safety.ResourceTierMedium, StateUnavailable, false},
	}
	for _, c := range cases {
		if got := AcceptableFor(c.tier, c.st); got != c.want {
			t.Errorf("AcceptableFor(%q,%q)=%v want %v", c.tier, c.st, got, c.want)
		}
	}
}

// Verdict.Acceptable must be exactly the shared predicate — the CLI and installer
// cannot diverge (RESOURCES-VERDICT-TIER-BLIND).
func TestAcceptableUsesSharedPredicate(t *testing.T) {
	for _, tier := range []safety.ResourceTier{safety.ResourceTierSmall, safety.ResourceTierMedium, safety.ResourceTierLarge} {
		for _, st := range []State{StateActiveMatch, StateFallbackMatch, StateFallbackUnder, StateUnavailable, State("")} {
			v := Verdict{Profile: safety.HealthResourceProfile{Tier: tier}, EffectiveState: st}
			if v.Acceptable() != AcceptableFor(tier, st) {
				t.Errorf("Verdict.Acceptable diverged from AcceptableFor for tier=%q state=%q", tier, st)
			}
		}
	}
}
