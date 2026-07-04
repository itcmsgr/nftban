// =============================================================================
// NFTBan - Tests for range-aware whitelist diff
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="setsync_range_diff_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-25"
// meta:description="Tests for range-aware whitelist diff"
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
)

func sortedEq(a, b []string) bool {
	sort.Strings(a)
	sort.Strings(b)
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func TestComputeWhitelistRangeDiff_CloudflareNoChurn(t *testing.T) {
	// Desired = adjacent CIDRs; kernel = coalesced interval (from GetSetElementsRanges).
	desired := []string{"104.16.0.0/13", "104.24.0.0/14"}
	current := []string{"104.16.0.0-104.27.255.255"}
	d := computeWhitelistRangeDiff(desired, current)
	if len(d.ToAdd) != 0 || len(d.ToRemove) != 0 {
		t.Fatalf("expected 0 churn, got ToAdd=%v ToRemove=%v", d.ToAdd, d.ToRemove)
	}
}

func TestComputeWhitelistRangeDiff_NewSingleIPOnCIDRHost(t *testing.T) {
	desired := []string{"104.16.0.0/13", "104.24.0.0/14", "62.38.150.122"}
	current := []string{"104.16.0.0-104.27.255.255"}
	d := computeWhitelistRangeDiff(desired, current)
	if !sortedEq(d.ToAdd, []string{"62.38.150.122"}) {
		t.Fatalf("expected ToAdd=[62.38.150.122], got %v", d.ToAdd)
	}
	if len(d.ToRemove) != 0 {
		t.Fatalf("expected no removals, got %v", d.ToRemove)
	}
}

func TestComputeWhitelistRangeDiff_RealExtraRemoved(t *testing.T) {
	desired := []string{"1.2.3.4"}
	current := []string{"1.2.3.4", "9.9.9.9"}
	d := computeWhitelistRangeDiff(desired, current)
	if len(d.ToAdd) != 0 {
		t.Fatalf("expected no adds, got %v", d.ToAdd)
	}
	if !sortedEq(d.ToRemove, []string{"9.9.9.9"}) {
		t.Fatalf("expected ToRemove=[9.9.9.9], got %v", d.ToRemove)
	}
}

func TestComputeWhitelistRangeDiff_IPCoveredByKernelInterval(t *testing.T) {
	// A desired single IP already covered by a live interval → not re-added.
	desired := []string{"104.20.0.5"}
	current := []string{"104.16.0.0-104.27.255.255"}
	d := computeWhitelistRangeDiff(desired, current)
	if len(d.ToAdd) != 0 {
		t.Fatalf("covered IP must not be re-added, got %v", d.ToAdd)
	}
}

func TestComputeWhitelistRangeDiff_IPv6(t *testing.T) {
	desired := []string{"2606:4700::/32"}
	current := []string{"2606:4700::-2606:4700:ffff:ffff:ffff:ffff:ffff:ffff"}
	d := computeWhitelistRangeDiff(desired, current)
	if len(d.ToAdd) != 0 || len(d.ToRemove) != 0 {
		t.Fatalf("v6 coverage-equivalent expected 0 churn, got ToAdd=%v ToRemove=%v", d.ToAdd, d.ToRemove)
	}
}

func TestDecrementIP(t *testing.T) {
	cases := []struct{ in, want string }{
		{"104.28.0.0", "104.27.255.255"},
		{"1.2.3.5", "1.2.3.4"},
		{"10.0.0.0", "9.255.255.255"},
	}
	for _, c := range cases {
		got := decrementIP(net.ParseIP(c.in).To4())
		if got.String() != c.want {
			t.Fatalf("decrementIP(%s)=%s want %s", c.in, got.String(), c.want)
		}
	}
}
