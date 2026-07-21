// SPDX-License-Identifier: MPL-2.0
// meta:name="health_verdict_assertion_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.223.0 verdict-truth: assertHealthResourcePolicyActive must SKIP (never fabricate a 0/0 DEGRADED) on a nil OR zero verdict (BUG-REPAIR-HEALTH-VERDICT-EMPTY), treat StateUnavailable as advisory on a NON-REQUIRED (small) tier, FAIL-CLOSED on UNAVAILABLE+unknown tier (v1.224.0 R2 strict default), FAIL on real medium FALLBACK_UNDERSIZED, and PASS on ACTIVE_MATCH."
// meta:inventory.files="internal/installer/validate/health_verdict_assertion_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package validate

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/healthresource"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/safety"
)

func nolog() *logging.Logger { return logging.New("/dev/null", false) }

// CORE regression (v1.223.0 owner-locked): a NON-NIL pointer to a ZERO verdict must
// FAIL CLOSED — every validation entry point resolves a real verdict first
// (services.ResolveHealthResourceVerdict), so a zero struct reaching the assertion
// means the wiring regressed. It must NOT silently pass unverified protection (the
// inverse of BUG-REPAIR-HEALTH-VERDICT-EMPTY) and must NOT fabricate a 0/0 message.
func TestAssertHealthZeroVerdictFailsClosed(t *testing.T) {
	r := assertHealthResourcePolicyActive(AssertionOpts{HealthResource: &healthresource.Verdict{}}, nolog())
	if r.Passed {
		t.Fatalf("zero verdict must FAIL CLOSED, got PASS: %s", r.Detail)
	}
	if strings.Contains(r.Detail, "0/0") {
		t.Fatalf("must NOT fabricate a 0/0 policy-failure message; got %q", r.Detail)
	}
}

// A truly nil verdict (this caller does not evaluate health) is a legitimate SKIP.
func TestAssertHealthNilVerdictSkips(t *testing.T) {
	r := assertHealthResourcePolicyActive(AssertionOpts{HealthResource: nil}, nolog())
	if !r.Passed {
		t.Fatal("nil verdict must SKIP")
	}
}

// UNAVAILABLE is advisory — cannot prove a failure, must not fabricate DEGRADED.
// UNAVAILABLE is advisory only for a NON-REQUIRED tier (small). v1.224.0 R2: this test
// now pins the tier explicitly to small — previously it relied on an unset tier being
// treated as non-required, which PROTECTIONREQUIRED-LENIENT-DEFAULT (Fix 5) deliberately
// reverses. Small stays advisory (scope item 8 — small semantics preserved).
func TestAssertHealthUnavailableIsAdvisory(t *testing.T) {
	v := &healthresource.Verdict{
		Profile:         safety.HealthResourceProfile{Tier: safety.ResourceTierSmall},
		EffectiveState:  healthresource.StateUnavailable,
		ValidationError: "systemctl show failed",
	}
	r := assertHealthResourcePolicyActive(AssertionOpts{HealthResource: v}, nolog())
	if !r.Passed {
		t.Fatal("UNAVAILABLE on a non-required (small) tier must be advisory (not DEGRADED)")
	}
}

// v1.224.0 R2 (PROTECTIONREQUIRED-LENIENT-DEFAULT): an UNAVAILABLE verdict with an
// unknown/empty/mis-detected tier must FAIL CLOSED — we can prove neither the tier nor
// the protection, so the strict default treats protection as required (no silent COMMIT
// off missing truth, the same inverse-bug guard as v1.223.0's UNAVAILABLE policy).
func TestAssertHealthUnavailableUnknownTierFailsClosed(t *testing.T) {
	for _, tier := range []safety.ResourceTier{"", "unknown"} {
		v := &healthresource.Verdict{
			Profile:         safety.HealthResourceProfile{Tier: tier},
			EffectiveState:  healthresource.StateUnavailable,
			ValidationError: "systemctl show failed",
		}
		r := assertHealthResourcePolicyActive(AssertionOpts{HealthResource: v}, nolog())
		if r.Passed {
			t.Fatalf("UNAVAILABLE + unknown tier %q must FAIL-CLOSED (strict default), not advisory-pass", tier)
		}
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
