// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
package structure

import (
	"strings"
	"testing"
)

// fixtureRuleset is nftban-shaped: keyed per-source connlimit sets with MULTI-LINE
// element blocks (the exact shape that produced the "6 bare ct-count rules survived"
// false reading), a ban set, named counters, and ordinary rules.
const fixtureRuleset = `table ip nftban {
	set banned_ips {
		type ipv4_addr
		flags timeout
		size 65535
		elements = { 203.0.113.9 timeout 1d expires 23h1m2s914ms,
			     203.0.113.10 timeout 1d expires 22h4m1s12ms,
			     198.51.100.7 timeout 1d expires 20h }
	}
	set connlimit_ssh_v4 {
		type ipv4_addr
		size 65535
		flags dynamic
		elements = { 203.0.113.44 ct count over 15,
			     198.51.100.2 ct count over 15 }
	}
	set connlimit_ssh_v6 {
		type ipv6_addr
		size 65535
		flags dynamic
	}
	counter nftban_drops {
		packets 41231 bytes 9912384
	}
	chain input {
		type filter hook input priority filter; policy drop;
		ct state established,related accept # handle 4
		ip saddr @banned_ips drop # handle 5
		tcp dport @ssh_ports add @connlimit_ssh_v4 { ip saddr ct count over 15 } counter packets 12 bytes 640 drop # handle 6
		tcp dport @ssh_ports add @connlimit_ssh_v6 { ip6 saddr ct count over 15 } counter packets 0 bytes 0 drop # handle 7
	}
}
`

func mustFP(t *testing.T, raw string) Result {
	t.Helper()
	r, err := FromRuleset(raw)
	if err != nil {
		t.Fatalf("FromRuleset refused a valid ruleset: %v", err)
	}
	return r
}

// ─────────────────────────────────────────────────────────────────────────────
// STABILITY — volatile state must NOT move the digest.
// ─────────────────────────────────────────────────────────────────────────────
// ⛔ THE AUTHORITATIVE NEGATIVE CONTROL IS THE LIVE 60s srv4 MEASUREMENT recorded in
// V1_233_X_LANE_B_LIFECYCLE_RECOVERY_SPEC.md §7.6 (digest identical while the raw
// ruleset sha moved). These cases pin the same property against fixtures so a
// regression is caught without production traffic — they do not replace it.
func TestFingerprint_VolatileStateDoesNotMoveTheDigest(t *testing.T) {
	base := mustFP(t, fixtureRuleset)

	cases := []struct {
		name string
		mut  func(string) string
	}{
		{"ban-set population changes", func(s string) string {
			return strings.Replace(s, "198.51.100.7 timeout 1d expires 20h }",
				"198.51.100.7 timeout 1d expires 20h,\n\t\t\t     192.0.2.55 timeout 1d expires 11h }", 1)
		}},
		{"connlimit element population changes", func(s string) string {
			return strings.Replace(s, "198.51.100.2 ct count over 15 }",
				"198.51.100.2 ct count over 15,\n\t\t\t     192.0.2.77 ct count over 15 }", 1)
		}},
		{"dynamic element expiry ticks", func(s string) string {
			return strings.Replace(s, "expires 23h1m2s914ms", "expires 23h0m59s3ms", 1)
		}},
		{"inline rule counters advance", func(s string) string {
			return strings.Replace(s, "counter packets 12 bytes 640", "counter packets 99999 bytes 4410222", 1)
		}},
		{"named counter object advances", func(s string) string {
			return strings.Replace(s, "packets 41231 bytes 9912384", "packets 41999 bytes 9999999", 1)
		}},
		{"rule handles are reassigned", func(s string) string {
			return strings.Replace(s, "# handle 6", "# handle 806", 1)
		}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := mustFP(t, tc.mut(fixtureRuleset))
			if got.Digest != base.Digest {
				t.Errorf("volatile change moved the durable identity\n  %s\n  base   %s\n  mutated %s\n"+
					"A digest that churns on live traffic can never certify anything.",
					tc.name, base.Digest, got.Digest)
			}
		})
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// SENSITIVITY — every structural token must be INSIDE the hashed surface.
// ─────────────────────────────────────────────────────────────────────────────
// ⛔ THIS CHARACTERISES THE DEFECT, NOT THE FIX. Ask of each arm: "if the structure
// were WORSE, would this still pass?" A fingerprint blind to the keyed→bare regression
// would certify a host that had silently lost per-source enforcement.
func TestFingerprint_StructuralChangeMovesTheDigest(t *testing.T) {
	base := mustFP(t, fixtureRuleset)

	cases := []struct {
		name string
		mut  func(string) string
	}{
		{"threshold change", func(s string) string {
			return strings.Replace(s, "add @connlimit_ssh_v4 { ip saddr ct count over 15 }",
				"add @connlimit_ssh_v4 { ip saddr ct count over 16 }", 1)
		}},
		{"family/keying correlation break", func(s string) string {
			return strings.Replace(s, "add @connlimit_ssh_v4 { ip saddr ct count over 15 }",
				"add @connlimit_ssh_v4 { ip6 saddr ct count over 15 }", 1)
		}},
		{"keyed collapses to bare host-wide", func(s string) string {
			return strings.Replace(s, "add @connlimit_ssh_v4 { ip saddr ct count over 15 }",
				"ct count over 15", 1)
		}},
		{"set target change", func(s string) string {
			return strings.Replace(s, "add @connlimit_ssh_v4 {", "add @connlimit_http_v4 {", 1)
		}},
		{"set declaration size change", func(s string) string {
			return strings.Replace(s, "size 65535\n\t\tflags dynamic", "size 32768\n\t\tflags dynamic", 1)
		}},
		{"set declaration flags change", func(s string) string {
			return strings.Replace(s, "flags dynamic", "flags dynamic,timeout", 1)
		}},
		{"DDoS authority population shrinks (rule removed)", func(s string) string {
			return strings.Replace(s,
				"\t\ttcp dport @ssh_ports add @connlimit_ssh_v6 { ip6 saddr ct count over 15 } counter packets 0 bytes 0 drop # handle 7\n", "", 1)
		}},
		{"chain policy drop -> accept", func(s string) string {
			return strings.Replace(s, "policy drop;", "policy accept;", 1)
		}},
		{"counter expression removed from a rule", func(s string) string {
			return strings.Replace(s, "} counter packets 12 bytes 640 drop", "} drop", 1)
		}},
		// ⛔ ORDERING IS SEMANTICS. nftables evaluates rules in order: hoisting the
		// established/related accept below the ban lookup, or swapping a drop above an
		// accept, changes which packets are governed. A digest blind to order would
		// certify two rulesets that behave differently as the same structure.
		{"rule ORDER changes (evaluation semantics)", func(s string) string {
			a := "\t\tct state established,related accept # handle 4\n"
			b := "\t\tip saddr @banned_ips drop # handle 5\n"
			return strings.Replace(s, a+b, b+a, 1)
		}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := mustFP(t, tc.mut(fixtureRuleset))
			if got.Digest == base.Digest {
				t.Errorf("structural change was INVISIBLE to the fingerprint: %s\n"+
					"  digest unchanged at %s — this token is outside the hashed surface",
					tc.name, base.Digest)
			}
		})
	}
}

// ─────────────────────────────────────────────────────────────────────────────
// FAIL CLOSED — an observation that cannot be canonicalised is REFUSED.
// ─────────────────────────────────────────────────────────────────────────────
// ⛔ A CONFIDENTLY WRONG DIGEST IS WORSE THAN NO DIGEST: the reconciliation that
// consumes it would certify a structure nobody measured.
func TestFingerprint_RefusesRatherThanGuesses(t *testing.T) {
	cases := []struct {
		name, raw, wantSubstr string
	}{
		{
			name:       "empty observation is not an empty ruleset",
			raw:        "   \n\n",
			wantSubstr: "EMPTY",
		},
		{
			name:       "no table declaration is not a ruleset",
			raw:        "counter foo {\n\tpackets 1 bytes 2\n}\n",
			wantSubstr: "no `table` declaration",
		},
		{
			name: "unclosed element block elides the tail wholesale",
			raw: "table ip nftban {\n\tset s {\n\t\telements = { 1.2.3.4,\n" +
				"\t\t\t     5.6.7.8,\n",
			wantSubstr: "never closed",
		},
		{
			name: "structural keyword reached while eliding trips the wire",
			raw: "table ip nftban {\n\tset s {\n\t\telements = { 1.2.3.4,\n" +
				"\tchain input {\n\t\tpolicy drop;\n\t}\n}\n",
			wantSubstr: "STRUCTURAL but was reached while eliding",
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			r, err := FromRuleset(tc.raw)
			if err == nil {
				t.Fatalf("expected REFUSAL, got digest %s — the canonicaliser guessed", r.Digest)
			}
			if !strings.Contains(err.Error(), tc.wantSubstr) {
				t.Errorf("refusal did not name the actual defect\n  want substring: %q\n  got: %v",
					tc.wantSubstr, err)
			}
		})
	}
}

// TestFingerprint_SchemaIsBoundIntoTheDigest proves the schema token is not decorative
// metadata that a reader could ignore: two schemas can never collide on one input.
func TestFingerprint_SchemaIsBoundIntoTheDigest(t *testing.T) {
	r := mustFP(t, fixtureRuleset)
	if r.Schema != SchemaV1 {
		t.Fatalf("schema = %q, want %q", r.Schema, SchemaV1)
	}
	if !strings.HasPrefix(r.Digest, "sha256:") {
		t.Errorf("digest %q is not self-describing about its hash function", r.Digest)
	}
	// ⛔ NO PLACEHOLDER. nft omits the elements line entirely for an EMPTY set, so
	// emitting one for a populated set would make emptiness structural.
	if strings.Contains(r.Canonical, "elements") {
		t.Error("an elements line survived into the hashed surface — a set crossing empty/non-empty " +
			"would then shift every following line and churn the digest")
	}
	if strings.Contains(r.Canonical, "203.0.113.9") {
		t.Error("ban-set population leaked into the hashed surface")
	}
	// The counter EXPRESSION survives; only its value is stripped.
	if !strings.Contains(r.Canonical, "counter packets <v> bytes <v>") {
		t.Error("the counter expression was deleted rather than value-stripped — a rule LOSING its " +
			"counter would then be invisible to the fingerprint")
	}
}

// TestFingerprint_IsDeterministic guards against map-iteration or time entering the
// digest: the same input must hash identically across runs.
func TestFingerprint_IsDeterministic(t *testing.T) {
	a := mustFP(t, fixtureRuleset)
	for i := 0; i < 20; i++ {
		if b := mustFP(t, fixtureRuleset); b.Digest != a.Digest {
			t.Fatalf("non-deterministic digest on iteration %d: %s != %s", i, b.Digest, a.Digest)
		}
	}
}

// TestFingerprint_EmptyAndPopulatedSetsAgree pins the defect MEASURED on production
// srv4: nft omits `elements = { … }` entirely for an empty set. If the canonicaliser
// represents the populated case with any line at all, a set crossing the empty boundary
// shifts every subsequent line and the digest churns under live traffic — same multiset,
// different order.
func TestFingerprint_EmptyAndPopulatedSetsAgree(t *testing.T) {
	empty := `table ip nftban {
	set connlimit_ssh_v4 {
		type ipv4_addr
		size 65535
		flags dynamic
	}
	chain input {
		type filter hook input priority filter; policy drop;
		tcp dport 22 add @connlimit_ssh_v4 { ip saddr ct count over 15 } drop
	}
}
`
	populated := strings.Replace(empty,
		"\t\tflags dynamic\n",
		"\t\tflags dynamic\n\t\telements = { 203.0.113.9 ct count over 15,\n\t\t\t     198.51.100.2 ct count over 15 }\n", 1)

	a, b := mustFP(t, empty), mustFP(t, populated)
	if a.Digest != b.Digest {
		t.Errorf("an EMPTY set and the SAME set with members produced different identities:\n"+
			"  empty     %s\n  populated %s\n"+
			"Population is not structure; this is the srv4 churn defect.", a.Digest, b.Digest)
	}
}
