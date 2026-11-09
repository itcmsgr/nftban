// =============================================================================
// NFTBan v1.235 - never-ban split limit: an omitted prefix is a named gap, not a split
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="exemption_split_limit_v1235_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-09"
// meta:description="P1S-A integration (owner 2026-10-08). A bulk prefix whose split around never-ban addresses would exceed exemption.MaxSplitPerPrefix is dropped WHOLE so that nothing covering an exempt address reaches a drop set; that drop is a protection gap and must be reported as such: returned in omitted (never only folded into removed), counted in Stats.BlacklistExemptSplitLimitOmissions apart from BlacklistExemptSubtractions. The same input batch still keeps every ordinary non-exempt prefix verbatim and still protects the exempt addresses. Below the limit nothing is omitted."
// meta:input="None"
// meta:output="t.Error on a silent omission, a lost non-exempt prefix or a covered exempt address"
// meta:depends="testing,net/netip,fmt"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package nftbackend

import (
	"fmt"
	"net/netip"
	"testing"

	"github.com/itcmsgr/nftban/internal/exemption"
)

// scatteredExempt returns n exempt IPv6 singletons inside wide, each 2^48 apart, so a
// split of wide around them needs ~48 prefixes per gap: n=200 -> ~9600 > exemption.MaxSplitPerPrefix.
func scatteredExempt(n int) []string {
	out := make([]string, 0, n)
	for i := 1; i <= n; i++ {
		out = append(out, fmt.Sprintf("2606:4700:4700:0:%x::1", i<<8))
	}
	return out
}

func TestSplitLimit_OmissionIsNamedAndCountedApart(t *testing.T) {
	const wide = "2606:4700:4700::/64"     // covers every scattered exempt singleton
	const ordinary = "2a00:1450:4001::/48" // covers none: must stay bannable, verbatim
	exempt := scatteredExempt(200)
	// Positive control (the fixture really exceeds exemption.MaxSplitPerPrefix) lives next to
	// the splitter: internal/exemption/split_limit_fixture_test.go uses this same fixture.
	r := exemption.NewSnapshot(exempt, nil)

	b := &Backend{exempt: r}
	kept, removed, omitted := b.SubtractExempt([]string{wide, ordinary})

	if len(omitted) != 1 || omitted[0] != wide {
		t.Fatalf("the prefix dropped at the split limit is not reported: omitted=%v (want [%s])", omitted, wide)
	}
	for _, k := range kept {
		if k == wide {
			t.Fatalf("the omitted prefix was still loaded: %v", kept)
		}
		p, err := netip.ParsePrefix(k)
		if err != nil {
			continue
		}
		for _, e := range exempt {
			if p.Contains(netip.MustParseAddr(e)) {
				t.Fatalf("never-ban %s is covered by a kept element %s", e, k)
			}
		}
	}
	if len(kept) != 1 || kept[0] != ordinary {
		t.Fatalf("the ordinary non-exempt prefix must stay bannable, verbatim: kept=%v", kept)
	}
	if removed != 1 {
		t.Errorf("removed = %d, want 1 (the omitted input covered exempt space)", removed)
	}
	if b.stats.BlacklistExemptSplitLimitOmissions != 1 {
		t.Errorf("BlacklistExemptSplitLimitOmissions = %d, want 1 (the gap must be counted apart)", b.stats.BlacklistExemptSplitLimitOmissions)
	}
	if b.stats.BlacklistExemptSubtractions != 1 {
		t.Errorf("BlacklistExemptSubtractions = %d, want 1", b.stats.BlacklistExemptSubtractions)
	}
}

func TestSplitLimit_BelowTheLimitNothingIsOmitted(t *testing.T) {
	r := exemption.NewSnapshot([]string{exemptFixtureIP}, nil)
	b := &Backend{exempt: r}
	kept, removed, omitted := b.SubtractExempt([]string{exemptFixtureNet})
	if len(omitted) != 0 {
		t.Fatalf("an ordinary split was reported as an omission: %v", omitted)
	}
	if removed != 1 || len(kept) == 0 || keptCovers(t, kept, exemptFixtureIP) {
		t.Fatalf("ordinary split: removed=%d kept=%v (want split around %s, rest kept)", removed, kept, exemptFixtureIP)
	}
	if b.stats.BlacklistExemptSplitLimitOmissions != 0 {
		t.Errorf("BlacklistExemptSplitLimitOmissions = %d, want 0", b.stats.BlacklistExemptSplitLimitOmissions)
	}
}

// Fixtures and helper shared with internal/exemption's P1S-A tests (same values).
const (
	exemptFixtureIP  = "185.199.108.153"
	exemptFixtureNet = "185.199.108.0/24"
)

// keptCovers reports whether any kept element (CIDR or bare address) contains ip.
func keptCovers(t *testing.T, kept []string, ip string) bool {
	t.Helper()
	a, err := netip.ParseAddr(ip)
	if err != nil {
		t.Fatalf("INVALID_TEST: bad fixture address %q: %v", ip, err)
	}
	a = a.Unmap()
	for _, k := range kept {
		p, err := netip.ParsePrefix(k)
		if err != nil {
			q, err2 := netip.ParseAddr(k)
			if err2 != nil {
				continue
			}
			p = netip.PrefixFrom(q.Unmap(), q.Unmap().BitLen())
		}
		if p.Contains(a) {
			return true
		}
	}
	return false
}
