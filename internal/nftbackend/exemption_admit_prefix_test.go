// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package nftbackend

import (
	"net/netip"
	"testing"
	"time"
)

// AdmitPrefix: SubtractExempt's question with a whole-prefix, fail-closed remedy (BotScan HTTP
// campaign /24). Every protected overlap refuses the whole prefix; nothing is split.
// Fixtures are routable, non-documentation ranges so the overlap rule, not the address-class
// rule, decides each case.
func TestAdmitPrefixWholePrefixRefusal(t *testing.T) {
	r := &exemptResolver{ttl: time.Hour, loaded: true, loadedAt: time.Now(), exact: map[string]struct{}{
		"185.220.101.7": {}, // an exempt single address
	}}
	r.prefixes = []netip.Prefix{
		netip.MustParsePrefix("185.199.108.0/22"), // wider than /24
		netip.MustParsePrefix("23.129.97.128/26"), // narrower than /24
	}

	cases := []struct {
		prefix, why string
		admit       bool
	}{
		{"45.33.32.0/24", "clean", true},
		{"185.220.101.0/24", "holds an exact exempt address", false},
		{"185.199.109.0/24", "inside an exempt range", false},
		{"23.129.97.0/24", "an exempt range inside it", false},
		{"10.20.30.0/24", "non-bannable class (private)", false},
		{"127.0.0.0/24", "non-bannable class (loopback)", false},
		{"not-a-prefix", "unparseable", false},
	}
	for _, c := range cases {
		ok, reason := r.AdmitPrefix(c.prefix)
		if ok != c.admit {
			t.Errorf("%s (%s): admit=%v (%s), want %v", c.prefix, c.why, ok, reason, c.admit)
		}
	}

	// The feed remedy is untouched: SubtractExempt still splits around the exempt address
	// instead of refusing the prefix.
	kept, removed, _ := r.SubtractExempt([]string{"185.220.101.0/24"})
	if removed != 1 || len(kept) == 0 {
		t.Fatalf("SubtractExempt changed: removed=%d kept=%v (must still split, not refuse)", removed, kept)
	}
}

// No resolver or no backend refuses: a /24 drop without the never-ban authority is never safe.
func TestAdmitPrefixFailsClosed(t *testing.T) {
	var nilR *exemptResolver
	if ok, _ := nilR.AdmitPrefix("45.33.32.0/24"); ok {
		t.Fatal("nil resolver admitted a prefix")
	}
	var nilB *Backend
	if ok, _ := nilB.AdmitPrefix("45.33.32.0/24"); ok {
		t.Fatal("nil backend admitted a prefix")
	}
	if ok, _ := (&Backend{}).AdmitPrefix("45.33.32.0/24"); ok {
		t.Fatal("backend without a resolver admitted a prefix")
	}
}
