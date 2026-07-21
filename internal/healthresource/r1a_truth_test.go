// SPDX-License-Identifier: MPL-2.0
// meta:name="r1a_truth_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.224.0 Lane B (R2) parser/classifier/predicate TRUTH regression suite. These began as R1a RED tests proving the v1.222.1-era defects live; the R2 product fixes make them green and they now run in ordinary CI (build tag removed). Covers: ParseMemBytes empty/whitespace/negative/boundary, classifier external-override precedence + the three loaded-drop-in distinctions, classifier infinity self-defense (mixed forms), and ProtectionRequired strict-unknown default."
// meta:inventory.files="internal/healthresource/r1a_truth_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// meta:execution_class="CI_UNIT"
package healthresource

import (
	"math"
	"testing"

	"github.com/itcmsgr/nftban/internal/safety"
)

func mediumCalc() safety.HealthResourceProfile {
	// 256/384 MiB — the medium-tier canonical policy (matches HealthServiceMemoryLimitsFor).
	return safety.HealthResourceProfile{Tier: safety.ResourceTierMedium, MemoryHigh: 268435456, MemoryMax: 402653184}
}

// PARSEMEMBYTES-EMPTY-OK-TRUE: empty / whitespace-only input is missing evidence, not a
// valid 0-byte limit → ok=false.
func TestParseMemBytesEmptyInvalid(t *testing.T) {
	for _, in := range []string{"", "   ", "\t", "\n", " \t "} {
		if _, _, ok := ParseMemBytes(in); ok {
			t.Errorf("ParseMemBytes(%q) ok=true; empty/blank must be ok=false", in)
		}
	}
}

// PARSEMEMBYTES-NEGATIVE-ACCEPTED: systemd never emits a negative memory limit; a
// negative parse is malformed and must be rejected (not clamped, not a sentinel).
func TestParseMemBytesNegativeInvalid(t *testing.T) {
	for _, in := range []string{"-1", "-268435456", "-9223372036854775808"} {
		if _, _, ok := ParseMemBytes(in); ok {
			t.Errorf("ParseMemBytes(%q) ok=true; a negative limit must be ok=false", in)
		}
	}
}

// Boundary contract for recognized/unrecognized numeric forms.
func TestParseMemBytesBoundary(t *testing.T) {
	cases := []struct {
		in      string
		wantV   int64
		wantInf bool
		wantOK  bool
	}{
		{"0", 0, false, true},
		{"1", 1, false, true},
		{"9223372036854775807", math.MaxInt64, false, true}, // MaxInt64: valid finite
		{"9223372036854775808", 0, false, false},            // > MaxInt64, != MaxUint64 → overflow → invalid
		{"18446744073709551615", InfinityBytes, true, true}, // MaxUint64: old systemd numeric infinity
		{"infinity", InfinityBytes, true, true},
		{"[not set]", InfinityBytes, true, true},
		{"garbage", 0, false, false}, // non-numeric → invalid
		{"12XB", 0, false, false},    // unit-suffixed form is NOT in the grammar → invalid
	}
	for _, c := range cases {
		v, inf, ok := ParseMemBytes(c.in)
		if v != c.wantV || inf != c.wantInf || ok != c.wantOK {
			t.Errorf("ParseMemBytes(%q)=(%d,%v,%v) want (%d,%v,%v)", c.in, v, inf, ok, c.wantV, c.wantInf, c.wantOK)
		}
	}
}

// CLASSIFY-EXTERNAL-OVERRIDE-MATCH-MISLABEL + the three loaded-drop-in distinctions.
// A loaded non-NFTBan drop-in is external authority and must be surfaced BEFORE any
// ordinary active/fallback verdict, even when the effective values coincide with calc.
// Authority is proven via loaded drop-in identity (otherDropinCount / ourLoaded), never
// file existence alone.
func TestClassifyExternalOverridePrecedence(t *testing.T) {
	calc := mediumCalc()
	cases := []struct {
		name             string
		effHigh, effMax  int64
		ourLoaded        bool
		otherDropinCount int
		weExpectLoaded   bool
		want             State
	}{
		// values coincide with calc but an external sibling is loaded → external conflict.
		{"ours+external sibling, values match", calc.MemoryHigh, calc.MemoryMax, true, 1, true, StateExternalConflict},
		// external-only loaded, values coincide → NOT packaged fallback; external conflict.
		{"external-only loaded, values match", calc.MemoryHigh, calc.MemoryMax, false, 1, true, StateExternalConflict},
		// our drop-in expected but not loaded, no external, effective != calc → distinct state.
		{"expected NFTBan drop-in not loaded", 100 * 1024 * 1024, 100 * 1024 * 1024, false, 0, true, StateExpectedNotLoaded},
		// pure NFTBan-owned reconciliation: our drop-in loaded, exact match, no external.
		{"NFTBan-only exact match", calc.MemoryHigh, calc.MemoryMax, true, 0, true, StateActiveMatch},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := ClassifyEffectiveDetailed(calc, c.effHigh, c.effMax, c.ourLoaded, c.otherDropinCount, c.weExpectLoaded)
			if got != c.want {
				t.Errorf("Classify=%s want %s", got, c.want)
			}
		})
	}
}

// CLASSIFY-NO-INFINITY-SELF-DEFENSE: the classifier itself must reject unbounded
// effective inputs (any of high/max infinity), independent of caller normalization.
func TestClassifyInfinitySelfDefense(t *testing.T) {
	calc := mediumCalc()
	cases := []struct {
		name            string
		effHigh, effMax int64
	}{
		{"both infinity", InfinityBytes, InfinityBytes},
		{"high finite / max infinity", calc.MemoryHigh, InfinityBytes},
		{"high infinity / max finite", InfinityBytes, calc.MemoryMax},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			got := ClassifyEffectiveDetailed(calc, c.effHigh, c.effMax, false, 0, false)
			if got == StateActiveMatch || got == StateFallbackMatch {
				t.Errorf("Classify(%s)=%s; unbounded must not classify as active/adequate", c.name, got)
			}
			if AcceptableFor(calc.Tier, got) {
				t.Errorf("Classify(%s)=%s is AcceptableFor(medium)=true; unbounded must never be accepted", c.name, got)
			}
		})
	}
}

// AcceptableFor rows NOT covered by verdict_test.go:TestAcceptableFor, plus the
// zero-Verdict invariant — an uninitialized verdict must never read as protection-active.
func TestAcceptableForUncoveredRows(t *testing.T) {
	cases := []struct {
		tier safety.ResourceTier
		st   State
		want bool
	}{
		{safety.ResourceTierLarge, StateEffectiveMismatch, false},
		{safety.ResourceTierMedium, StateExternalConflict, false},
		{safety.ResourceTierLarge, StateFallbackUnder, false},
		{safety.ResourceTierLarge, StateExpectedNotLoaded, false},
		{safety.ResourceTierMedium, StateActivationFailed, false}, // infinity self-defense result → never active
	}
	for _, c := range cases {
		if got := AcceptableFor(c.tier, c.st); got != c.want {
			t.Errorf("AcceptableFor(%q,%q)=%v want %v", c.tier, c.st, got, c.want)
		}
	}
	if (Verdict{}).Acceptable() {
		t.Error("zero Verdict.Acceptable()=true; an unresolved verdict must never read as active")
	}
}

// PROTECTIONREQUIRED-LENIENT-DEFAULT: unknown/zero/mis-detected tier fails SAFE
// (required); known tiers keep their v1.223.0 policy semantics.
func TestProtectionRequiredStrictDefault(t *testing.T) {
	cases := []struct {
		tier safety.ResourceTier
		want bool
	}{
		{safety.ResourceTierSmall, false},
		{safety.ResourceTierMedium, true},
		{safety.ResourceTierLarge, true},
		{safety.ResourceTier(""), true},
		{safety.ResourceTier("unknown"), true},
		{safety.ResourceTier("bogus"), true},
	}
	for _, c := range cases {
		if got := ProtectionRequired(c.tier); got != c.want {
			t.Errorf("ProtectionRequired(%q)=%v want %v", c.tier, got, c.want)
		}
	}
}
