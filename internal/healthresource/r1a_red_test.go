// SPDX-License-Identifier: MPL-2.0
//go:build r1a_red

// meta:name="r1a_red_test.go"
// meta:type="go"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.224.0 Lane A1 (TEST-DEBT-V1_222_1-HEALTHRESOURCE-UNITS): INTENTIONALLY-RED regression tests that assert the DESIRED Lane B behavior and FAIL against the v1.223.0 baseline, proving each classifier/parser/predicate defect is LIVE. GOVERNED via the r1a_red build tag (NOT t.Skip) so the baseline suite stays green and CI is never red-stormed; they are meant to be run explicitly (go test -tags r1a_red ./internal/healthresource/) and to flip green when Lane B lands. NO product code is changed by this file."
// meta:inventory.files="internal/healthresource/r1a_red_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// meta:execution_class="MANUAL_FORENSIC"
// meta:red_lane="r1a_red — expected-failing against v1.223.0; flips green under Lane B"
package healthresource

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/safety"
)

func mediumCalc() safety.HealthResourceProfile {
	// 256/384 MiB — the medium-tier canonical policy (matches HealthServiceMemoryLimitsFor).
	return safety.HealthResourceProfile{Tier: safety.ResourceTierMedium, MemoryHigh: 268435456, MemoryMax: 402653184}
}

// PARSEMEMBYTES-EMPTY-OK-TRUE: an empty/whitespace-only MemoryMax is missing evidence,
// not a valid 0-byte limit. Contract: ok=false so callers can distinguish "unset" from
// a genuine value. v1.223.0 returns (0,false,true) → RED.
func TestR1aParseMemBytesEmptyMustBeInvalid(t *testing.T) {
	for _, in := range []string{"", "   ", "\t"} {
		if _, _, ok := ParseMemBytes(in); ok {
			t.Errorf("ParseMemBytes(%q) ok=true; empty/blank input must be ok=false (missing evidence, not a real 0)", in)
		}
	}
}

// PARSEMEMBYTES negative: systemd never emits a negative memory limit; a negative parse
// is malformed and must be rejected. v1.223.0 ParseInt accepts "-1" → ok=true → RED.
// (Surfaced by the R1a spec's invalid-value set; propose folding into Lane B parser truth.)
func TestR1aParseMemBytesNegativeMustBeInvalid(t *testing.T) {
	for _, in := range []string{"-1", "-268435456"} {
		if _, _, ok := ParseMemBytes(in); ok {
			t.Errorf("ParseMemBytes(%q) ok=true; a negative memory limit is malformed and must be ok=false", in)
		}
	}
}

// CLASSIFY-EXTERNAL-OVERRIDE-MATCH-MISLABEL: when a non-NFTBan drop-in is loaded and its
// effective values happen to EQUAL our calculated policy, the classifier must still
// surface EXTERNAL_OVERRIDE_CONFLICT (operator review) — an external authority is shaping
// the limits and a coincidental numeric match must not launder it into ACTIVE/FALLBACK.
// Authority is proven via loaded drop-in identity (otherDropinCount), not file existence.
// v1.223.0 tests `match` BEFORE otherDropinCount → returns ACTIVE_MATCH/FALLBACK_MATCH → RED.
func TestR1aClassifyExternalOverrideBeforeMatch(t *testing.T) {
	calc := mediumCalc()
	cases := []struct {
		name      string
		ourLoaded bool
	}{
		{"ours+external both loaded, values coincide", true},
		{"only external loaded, values coincide", false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			// effective == calc exactly, but an external drop-in is loaded (otherDropinCount=1).
			got := ClassifyEffectiveDetailed(calc, calc.MemoryHigh, calc.MemoryMax, c.ourLoaded, 1, true)
			if got != StateExternalConflict {
				t.Errorf("Classify(...external loaded, values match...)=%s want %s (external authority must not be masked by a numeric match)", got, StateExternalConflict)
			}
		})
	}
}

// CLASSIFY-NO-INFINITY-SELF-DEFENSE: passing an unbounded (infinity) effective limit
// DIRECTLY into the classifier — bypassing assembleReport's upstream infinity guard —
// must NOT resolve to a protective ACTIVE_MATCH/FALLBACK_MATCH. The classifier must
// self-defend with an explicit unbounded/invalid classification. v1.223.0 returns
// FALLBACK_MATCH (infinity >= calc) → RED (defense-in-depth missing at the boundary).
func TestR1aClassifyInfinitySelfDefense(t *testing.T) {
	calc := mediumCalc()
	got := ClassifyEffectiveDetailed(calc, InfinityBytes, InfinityBytes, false, 0, false)
	if got == StateActiveMatch || got == StateFallbackMatch {
		t.Errorf("Classify(infinity,infinity)=%s; an unbounded effective limit must not classify as active/adequate (expected explicit unbounded/invalid)", got)
	}
	if AcceptableFor(calc.Tier, got) {
		t.Errorf("Classify(infinity)=%s is AcceptableFor(medium)=true; unbounded must never be accepted as protection", got)
	}
}

// PROTECTIONREQUIRED-LENIENT-DEFAULT: an unknown/zero tier must fail SAFE (treat
// protection as required) rather than silently lenient. v1.223.0 returns false for any
// non-medium/large tier including "" → RED (a mis-detected tier would silently downgrade).
func TestR1aProtectionRequiredUnknownStrict(t *testing.T) {
	for _, tier := range []safety.ResourceTier{"", "unknown", "bogus"} {
		if ProtectionRequired(tier) != true {
			t.Errorf("ProtectionRequired(%q)=false; an unknown/zero tier must fail-safe to required (strict default)", tier)
		}
	}
}
