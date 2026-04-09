// =============================================================================
// NFTBan v1.80 - pipeline normalize tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: normalize
// Purpose: Tests for canonicalization helpers.
//
// meta:name="loginmon_pipeline_normalize_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="normalize"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Tests for normalize.Canonicalize"
//
// meta:inventory.files="normalize_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package normalize

import (
	"net/netip"
	"testing"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
)

func TestCanonicalize_Unmaps4In6(t *testing.T) {
	in := event.NormalizedEvent{
		SrcIP: netip.MustParseAddr("::ffff:192.0.2.1"),
	}
	out := Canonicalize(in)
	if !out.SrcIP.Is4() {
		t.Errorf("SrcIP: got %v, want plain v4", out.SrcIP)
	}
	if out.SrcIP.String() != "192.0.2.1" {
		t.Errorf("SrcIP.String: got %q", out.SrcIP.String())
	}
}

func TestCanonicalize_PreservesPlainV4(t *testing.T) {
	in := event.NormalizedEvent{
		SrcIP: netip.MustParseAddr("203.0.113.5"),
	}
	out := Canonicalize(in)
	if out.SrcIP.String() != "203.0.113.5" {
		t.Errorf("SrcIP: got %v", out.SrcIP)
	}
}

func TestCanonicalize_PreservesV6(t *testing.T) {
	in := event.NormalizedEvent{
		SrcIP: netip.MustParseAddr("2001:db8::1"),
	}
	out := Canonicalize(in)
	if out.SrcIP.String() != "2001:db8::1" {
		t.Errorf("SrcIP: got %v", out.SrcIP)
	}
}

func TestCanonicalize_ZeroAddrPasses(t *testing.T) {
	out := Canonicalize(event.NormalizedEvent{})
	if out.SrcIP.IsValid() {
		t.Errorf("zero SrcIP should stay invalid, got %v", out.SrcIP)
	}
}

func TestCanonicalize_SplitsUserDomain(t *testing.T) {
	cases := []struct {
		inUser, inDomain   string
		outUser, outDomain string
	}{
		{"info@example.gr", "", "info@example.gr", "example.gr"},
		{"info", "", "info", ""},
		{"", "", "", ""},
		{"info", "manual.gr", "info", "manual.gr"},          // explicit domain preserved
		{"info@a@b", "", "info@a@b", "b"},                    // last @ wins
	}
	for _, c := range cases {
		out := Canonicalize(event.NormalizedEvent{
			Username: c.inUser,
			Domain:   c.inDomain,
		})
		if out.Username != c.outUser || out.Domain != c.outDomain {
			t.Errorf("Canonicalize(%q,%q): got (%q,%q), want (%q,%q)",
				c.inUser, c.inDomain, out.Username, out.Domain, c.outUser, c.outDomain)
		}
	}
}
