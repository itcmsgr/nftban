// SPDX-License-Identifier: MPL-2.0
// meta:name="unavailable_tier_v1223_test.go"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.223.0 verdict-truth: assertHealthResourcePolicyActive UNAVAILABLE tier policy — small (protection NOT required) → advisory PASS (never a fabricated ACTIVE_MATCH); medium/large (protection REQUIRED) → FAIL (unverifiable protection must DEGRADE, the inverse of a false SUCCESS from missing truth). Plus the zero-verdict fail-closed guard (no 0/0)."
// meta:inventory.files="internal/installer/validate/unavailable_tier_v1223_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package validate

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/safety"
)

func unavailableVerdict(tier safety.ResourceTier) *healthresource.Verdict {
	return &healthresource.Verdict{
		Profile:         safety.HealthResourceProfile{Tier: tier},
		EffectiveState:  healthresource.StateUnavailable,
		ResolvedFrom:    "unavailable",
		ValidationError: "live systemctl show failed and no persisted evidence",
	}
}

func TestAssertHealthUnavailable_TierMatrix(t *testing.T) {
	cases := []struct {
		tier       safety.ResourceTier
		wantPassed bool // small: advisory PASS; medium/large: FAIL (protection required)
	}{
		{safety.ResourceTierSmall, true},
		{safety.ResourceTierMedium, false},
		{safety.ResourceTierLarge, false},
	}
	for _, c := range cases {
		t.Run(string(c.tier), func(t *testing.T) {
			r := assertHealthResourcePolicyActive(AssertionOpts{HealthResource: unavailableVerdict(c.tier)}, nolog())
			if r.Passed != c.wantPassed {
				t.Fatalf("tier=%s UNAVAILABLE: Passed=%v want %v (detail=%s)", c.tier, r.Passed, c.wantPassed, r.Detail)
			}
			// UNAVAILABLE must never be reported as a fabricated ACTIVE_MATCH.
			if r.Passed && c.tier == safety.ResourceTierSmall {
				if wantsActiveMatch(r.Detail) {
					t.Errorf("small UNAVAILABLE advisory-pass must NOT fabricate ACTIVE_MATCH; detail=%q", r.Detail)
				}
			}
		})
	}
}

func wantsActiveMatch(detail string) bool {
	return detail == string(healthresource.StateActiveMatch)
}
