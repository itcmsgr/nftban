// =============================================================================
// NFTBan - Tests for nftables interval range reconstruction
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="setsync_nft_ranges_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-25"
// meta:description="Tests for nftables interval range reconstruction"
// meta:input="None"
// meta:output="None"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package setsync

import (
	"net"
	"sort"
	"testing"

	"github.com/google/nftables"
)

// el builds a SetElement with the family-correct key length.
func el(ip string, end bool) nftables.SetElement {
	p := net.ParseIP(ip)
	var k []byte
	if v4 := p.To4(); v4 != nil {
		k = v4
	} else {
		k = p.To16()
	}
	return nftables.SetElement{Key: k, IntervalEnd: end}
}

// TestReconstructIntervalRanges_ObservedStructure pins the EXACT element stream
// observed from google/nftables on lab2 (NFTABLES_INTERVAL_ELEMENT_MODEL):
//   - each logical entry = a START (IntervalEnd=false) + an EXCLUSIVE END (=last+1)
//   - the END precedes its START in the stream
//   - singletons get a paired end (X → X+1)
//   - a trailing orphan wraparound end (0.0.0.0) is present
//
// Set: { 8.8.8.8, 9.9.9.9, 62.38.150.122, 65.21.157.15, 104.16.0.0-104.27.255.255, 127.0.0.1 }
func TestReconstructIntervalRanges_ObservedStructure(t *testing.T) {
	elems := []nftables.SetElement{
		el("127.0.0.2", true), el("127.0.0.1", false),
		el("104.28.0.0", true), el("104.16.0.0", false),
		el("65.21.157.16", true), el("65.21.157.15", false),
		el("62.38.150.123", true), el("62.38.150.122", false),
		el("9.9.9.10", true), el("9.9.9.9", false),
		el("8.8.8.9", true), el("8.8.8.8", false),
		el("0.0.0.0", true), // orphan wraparound end
	}
	got := reconstructIntervalRanges(elems)
	want := []string{
		"8.8.8.8", "9.9.9.9", "62.38.150.122", "65.21.157.15",
		"104.16.0.0-104.27.255.255", "127.0.0.1",
	}
	sort.Strings(got)
	sort.Strings(want)
	if !sortedEq(got, want) {
		t.Fatalf("reconstructIntervalRanges mismatch:\n got=%v\nwant=%v", got, want)
	}
	// Guard against the prior bug: NO backwards range (start > end) must ever appear.
	for _, tok := range got {
		if i := indexByte(tok, '-'); i > 0 {
			a := net.ParseIP(tok[:i])
			b := net.ParseIP(tok[i+1:])
			if a == nil || b == nil {
				t.Fatalf("unparseable reconstructed range %q", tok)
			}
			if compareIP(a, b) > 0 {
				t.Fatalf("BACKWARDS range produced: %q", tok)
			}
		}
	}
}

func TestReconstructIntervalRanges_SingletonAndOrphanOnly(t *testing.T) {
	// One singleton + the orphan end only.
	got := reconstructIntervalRanges([]nftables.SetElement{
		el("9.9.9.10", true), el("9.9.9.9", false), el("0.0.0.0", true),
	})
	if len(got) != 1 || got[0] != "9.9.9.9" {
		t.Fatalf("got %v want [9.9.9.9]", got)
	}
}

func TestReconstructIntervalRanges_IPv6(t *testing.T) {
	// 2606:4700::/32 → start 2606:4700:: , exclusive end 2606:4701::
	got := reconstructIntervalRanges([]nftables.SetElement{
		el("2606:4701::", true), el("2606:4700::", false), el("::", true),
	})
	want := "2606:4700::-2606:4700:ffff:ffff:ffff:ffff:ffff:ffff"
	if len(got) != 1 || got[0] != want {
		t.Fatalf("got %v want [%s]", got, want)
	}
}

func TestReconstructIntervalRanges_HashSetNoEnds(t *testing.T) {
	// Plain (non-interval) set: no IntervalEnd markers → each element is single IP.
	got := reconstructIntervalRanges([]nftables.SetElement{
		el("1.2.3.4", false), el("5.6.7.8", false),
	})
	sort.Strings(got)
	if !sortedEq(got, []string{"1.2.3.4", "5.6.7.8"}) {
		t.Fatalf("hash-set got %v", got)
	}
}

func indexByte(s string, b byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == b {
			return i
		}
	}
	return -1
}

func compareIP(a, b net.IP) int {
	a16, b16 := a.To16(), b.To16()
	for i := 0; i < 16; i++ {
		if a16[i] != b16[i] {
			if a16[i] < b16[i] {
				return -1
			}
			return 1
		}
	}
	return 0
}
