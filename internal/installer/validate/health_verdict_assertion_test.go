// SPDX-License-Identifier: MPL-2.0
// meta:name="health_verdict_assertion_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.223.0 verdict-truth: assertHealthResourcePolicyActive must SKIP (never fabricate a 0/0 DEGRADED) on a nil OR zero verdict (BUG-REPAIR-HEALTH-VERDICT-EMPTY), treat StateUnavailable as advisory (not DEGRADED), FAIL on real medium FALLBACK_UNDERSIZED, and PASS on ACTIVE_MATCH."
package validate

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/safety"
)

func nolog() *logging.Logger { return logging.New("/dev/null", false) }

// CORE regression: a zero verdict must SKIP (Passed), never a fabricated 0/0 FAIL.
func TestAssertHealthZeroVerdictSkipsNotFail(t *testing.T) {
	r := assertHealthResourcePolicyActive(AssertionOpts{HealthResource: &healthresource.Verdict{}}, nolog())
	if !r.Passed {
		t.Fatalf("zero verdict must SKIP (pass), got FAIL: %s", r.Detail)
	}
}

func TestAssertHealthNilVerdictSkips(t *testing.T) {
	r := assertHealthResourcePolicyActive(AssertionOpts{HealthResource: nil}, nolog())
	if !r.Passed {
		t.Fatal("nil verdict must SKIP")
	}
}

// UNAVAILABLE is advisory — cannot prove a failure, must not fabricate DEGRADED.
func TestAssertHealthUnavailableIsAdvisory(t *testing.T) {
	v := &healthresource.Verdict{EffectiveState: healthresource.StateUnavailable, ValidationError: "systemctl show failed"}
	r := assertHealthResourcePolicyActive(AssertionOpts{HealthResource: v}, nolog())
	if !r.Passed {
		t.Fatal("UNAVAILABLE must be advisory (not DEGRADED)")
	}
}

// A genuinely underprotected medium host must FAIL (no masking).
func TestAssertHealthMediumUndersizedFails(t *testing.T) {
	v := &healthresource.Verdict{
		Profile:        safety.HealthResourceProfile{Tier: safety.ResourceTierMedium},
		EffectiveState: healthresource.StateFallbackUnder,
		CalculatedMax:  402653184,
		EffectiveMax:   268435456,
	}
	r := assertHealthResourcePolicyActive(AssertionOpts{HealthResource: v}, nolog())
	if r.Passed {
		t.Fatal("medium FALLBACK_UNDERSIZED must FAIL (real underprotection)")
	}
}

func TestAssertHealthActiveMatchPasses(t *testing.T) {
	v := &healthresource.Verdict{
		Profile:        safety.HealthResourceProfile{Tier: safety.ResourceTierMedium},
		EffectiveState: healthresource.StateActiveMatch,
	}
	r := assertHealthResourcePolicyActive(AssertionOpts{HealthResource: v}, nolog())
	if !r.Passed {
		t.Fatal("ACTIVE_MATCH must PASS")
	}
}
