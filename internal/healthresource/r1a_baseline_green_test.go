// SPDX-License-Identifier: MPL-2.0
// meta:name="r1a_baseline_green_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.224.0 Lane A1 (TEST-DEBT-V1_222_1-HEALTHRESOURCE-UNITS): baseline regression coverage that LOCKS IN the already-correct v1.223.0 parser/predicate/tier behavior the v1.222.1 suite never asserted. These PASS on v1.223.0 (untagged, mergeable, zero product change). The intentionally-RED companions are in r1a_red_test.go behind //go:build r1a_red. NOTE: the AcceptableFor core (tier,state) truth table already lives in verdict_test.go:TestAcceptableFor — this only adds the rows that table omitted, to avoid duplication."
// meta:inventory.files="internal/healthresource/r1a_baseline_green_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package healthresource

import (
	"math"
	"strconv"
	"testing"

	"github.com/itcmsgr/nftban/internal/safety"
)

// TestR1aParseMemBytesKnownGood locks the parser rows that are already correct on
// v1.223.0 (garbage/unit-suffixed → !ok; decimals → ok; infinity forms → inf,ok).
// The empty-input and negative-input contract defects are asserted (RED) separately
// in r1a_red_test.go — do not add them here or the baseline suite goes red.
func TestR1aParseMemBytesKnownGood(t *testing.T) {
	cases := []struct {
		in      string
		wantV   int64
		wantInf bool
		wantOK  bool
	}{
		{"1024", 1024, false, true},
		{"0", 0, false, true},
		{"infinity", InfinityBytes, true, true},
		{"[not set]", InfinityBytes, true, true},
		{strconv.FormatUint(math.MaxUint64, 10), InfinityBytes, true, true}, // old systemd numeric infinity
		{"garbage", 0, false, false},
		{"12XB", 0, false, false}, // unit-suffixed form is NOT part of the grammar
	}
	for _, c := range cases {
		v, inf, ok := ParseMemBytes(c.in)
		if v != c.wantV || inf != c.wantInf || ok != c.wantOK {
			t.Errorf("ParseMemBytes(%q)=(%d,%v,%v) want (%d,%v,%v)", c.in, v, inf, ok, c.wantV, c.wantInf, c.wantOK)
		}
	}
}

// TestR1aProtectionRequiredKnownProfiles locks the strict-required stance for the
// KNOWN tiers. The unknown/zero-tier default (currently lenient) is asserted RED
// in r1a_red_test.go (PROTECTIONREQUIRED-LENIENT-DEFAULT).
func TestR1aProtectionRequiredKnownProfiles(t *testing.T) {
	cases := []struct {
		tier safety.ResourceTier
		want bool
	}{
		{safety.ResourceTierSmall, false},  // small: packaged fallback meets calc → advisory
		{safety.ResourceTierMedium, true},  // medium: active drop-in MANDATORY
		{safety.ResourceTierLarge, true},   // large: active drop-in MANDATORY
	}
	for _, c := range cases {
		if got := ProtectionRequired(c.tier); got != c.want {
			t.Errorf("ProtectionRequired(%q)=%v want %v", c.tier, got, c.want)
		}
	}
}

// TestR1aAcceptableForUncoveredRows adds the (tier,state) rows that
// verdict_test.go:TestAcceptableFor omits, plus the zero-Verdict invariant, without
// duplicating the existing table. All already correct on v1.223.0 → green.
func TestR1aAcceptableForUncoveredRows(t *testing.T) {
	cases := []struct {
		tier safety.ResourceTier
		st   State
		want bool
	}{
		{safety.ResourceTierLarge, StateEffectiveMismatch, false},  // large + reload-lag mismatch → not active
		{safety.ResourceTierMedium, StateExternalConflict, false},  // external override is never silently accepted
		{safety.ResourceTierLarge, StateFallbackUnder, false},      // large undersized fallback → not active
		{safety.ResourceTierLarge, StateExpectedNotLoaded, false},  // our drop-in on disk but not loaded → not active
	}
	for _, c := range cases {
		if got := AcceptableFor(c.tier, c.st); got != c.want {
			t.Errorf("AcceptableFor(%q,%q)=%v want %v", c.tier, c.st, got, c.want)
		}
	}
	// An uninitialized verdict must NEVER evaluate as protection-active.
	if (Verdict{}).Acceptable() {
		t.Error("zero Verdict.Acceptable()=true; an unresolved verdict must never read as active")
	}
}
