// SPDX-License-Identifier: MPL-2.0
//
// v1.229.1 TRACK 1 — never-ban canonical identity regression.
//
// PROVEN BYPASS this locks out: the exempt store canonicalizes every key with
// Unmap(), the lookup did not, and netip's prefix Contains() does not match across
// families. So the IPv4-mapped IPv6 form of an exempt admin address missed BOTH
// membership paths and the ban proceeded:
//
//	stored key                  "203.0.113.5"
//	addr.String()               "::ffff:203.0.113.5"   -> exact MISS
//	v4prefix.Contains(mapped)    false                 -> cidr  MISS
//
// This is a bypass of the AUTHORITY, not of a downstream consumer: Backend.Ban,
// Backend.IsExempt and the AddElement guard all resolve through IsExempt, so a
// single missed lookup unbans the admin protection on every path at once.
//
// The arms below deliberately assert BOTH directions of the canonicalization:
// unmapping only the lookup would have moved the mismatch rather than removing it
// (a stored "::ffff:.../120" prefix Contains() the mapped form but NOT the unmapped
// one), which is why prefixes are canonicalized at store time too.
package nftbackend

import (
	"net/netip"
	"testing"
	"time"
)

// newLoadedResolver builds a resolver with a fixed snapshot and no refresh, so the
// arms test membership semantics only — not file/proc discovery.
func newLoadedResolver(exact []string, prefixes []string) *exemptResolver {
	r := &exemptResolver{exact: map[string]struct{}{}, ttl: 1 << 62}
	for _, e := range exact {
		a, err := netip.ParseAddr(e)
		if err != nil {
			panic("bad test exact: " + e)
		}
		r.exact[a.Unmap().String()] = struct{}{} // store side, as Refresh does
	}
	for _, p := range prefixes {
		pp, err := netip.ParsePrefix(p)
		if err != nil {
			panic("bad test prefix: " + p)
		}
		r.prefixes = append(r.prefixes, pp) // RAW: the fixture must not duplicate production canonicalization
	}
	r.loaded = true
	r.loadedAt = time.Now()
	return r
}

func TestNeverBanCanonicalIdentity_ExactPath(t *testing.T) {
	r := newLoadedResolver([]string{"203.0.113.5"}, nil)

	// Control: the plain form must already be exempt. If this fails the fixture is
	// wrong and every other assertion here would be meaningless.
	if ok, _ := r.IsExempt("203.0.113.5"); !ok {
		t.Fatal("control failed: plain IPv4 form is not exempt — fixture is broken")
	}

	// THE BYPASS: same address, IPv4-mapped IPv6 form.
	if ok, why := r.IsExempt("::ffff:203.0.113.5"); !ok {
		t.Fatalf("NEVER-BAN BYPASS: IPv4-mapped form of an exempt address is not exempt "+
			"(reason=%q) — this address would be banned despite being protected", why)
	}
}

func TestNeverBanCanonicalIdentity_PrefixPath(t *testing.T) {
	r := newLoadedResolver(nil, []string{"203.0.113.0/24"})

	if ok, _ := r.IsExempt("203.0.113.5"); !ok {
		t.Fatal("control failed: plain IPv4 inside an exempt CIDR is not exempt")
	}
	if ok, why := r.IsExempt("::ffff:203.0.113.5"); !ok {
		t.Fatalf("NEVER-BAN BYPASS: IPv4-mapped form inside an exempt CIDR is not exempt (reason=%q)", why)
	}
}

// A stored IPv4-mapped PREFIX must protect the same addresses as its IPv4
// equivalent — and this MUST be proven through the PRODUCTION store path.
//
// The first version of this arm built its fixture by calling canonPrefix() itself.
// That made it vacuous: deleting canonPrefix from production left the suite green,
// because the test was canonicalizing its own input. Inversion caught it. This
// version drives the real Refresh() via NFTBAN_MANAGEMENT_IPS (source 4), which
// reaches addEntry() -> canonPrefix() exactly as production does.
func TestNeverBanCanonicalIdentity_MappedPrefixStillProtects(t *testing.T) {
	t.Setenv("NFTBAN_MANAGEMENT_IPS", "::ffff:203.0.113.0/120")
	r := &exemptResolver{exact: map[string]struct{}{}, ttl: 1 << 62}
	r.Refresh() // PRODUCTION store path

	var stored []string
	for _, p := range r.prefixes {
		stored = append(stored, p.String())
	}
	// Non-vacuity: the fixture must actually have landed in the snapshot.
	found := false
	for _, sp := range stored {
		if sp == "203.0.113.0/24" || sp == "::ffff:203.0.113.0/120" {
			found = true
		}
	}
	if !found {
		t.Fatalf("fixture did not reach the snapshot (prefixes=%v) — arm would be vacuous", stored)
	}

	for _, in := range []string{"203.0.113.5", "::ffff:203.0.113.5"} {
		if ok, why := r.IsExempt(in); !ok {
			t.Fatalf("stored IPv4-mapped prefix failed to protect %q (reason=%q, prefixes=%v) — "+
				"canonicalizing only the lookup side moves the mismatch instead of removing it", in, why, stored)
		}
	}
}

// Non-exempt addresses must STILL be bannable. A canonicalization bug that made
// everything exempt would pass every arm above while disabling enforcement
// entirely — this is the negative control for the whole file.
func TestNeverBanCanonicalIdentity_DoesNotOverMatch(t *testing.T) {
	r := newLoadedResolver([]string{"203.0.113.5"}, []string{"198.51.100.0/24"})

	for _, in := range []string{
		"203.0.113.6",           // adjacent to an exact key
		"::ffff:203.0.113.6",    // mapped form of a non-exempt address
		"198.51.101.1",          // just outside the exempt prefix
		"2001:db8::1",           // unrelated v6
	} {
		if ok, why := r.IsExempt(in); ok {
			t.Fatalf("OVER-MATCH: %q reported exempt (reason=%q) — legitimate bans would be refused", in, why)
		}
	}
}

// v6 exact keys must keep working; canonicalization must not disturb real IPv6.
func TestNeverBanCanonicalIdentity_NativeIPv6Unaffected(t *testing.T) {
	r := newLoadedResolver([]string{"2001:db8::99"}, []string{"2001:db8:1::/48"})

	if ok, _ := r.IsExempt("2001:db8::99"); !ok {
		t.Fatal("native IPv6 exact key stopped matching")
	}
	if ok, _ := r.IsExempt("2001:db8:1::5"); !ok {
		t.Fatal("native IPv6 prefix stopped matching")
	}
}

// Malformed input must remain not-exempt (fail-safe: bans proceed), never panic.
func TestNeverBanCanonicalIdentity_MalformedInputIsNotExempt(t *testing.T) {
	r := newLoadedResolver([]string{"203.0.113.5"}, nil)
	for _, in := range []string{"", "   ", "not-an-ip", "203.0.113.5/32", "::ffff:203.0.113.999"} {
		if ok, _ := r.IsExempt(in); ok {
			t.Fatalf("malformed input %q reported exempt", in)
		}
	}
}
