// =============================================================================
// NFTBan - Tests for range-aware coverage oracle
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="netutil_coverage_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-25"
// meta:description="Tests for range-aware coverage oracle"
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

package netutil

import (
	"strings"
	"testing"
)

func TestCoverage_CloudflareCIDRIntervalEquivalence(t *testing.T) {
	// Baseline holds two adjacent CIDRs; kernel coalesced them into one interval.
	baseline := []string{"104.16.0.0/13", "104.24.0.0/14"}
	kernel := []string{"104.16.0.0-104.27.255.255"}
	res := CoverageDiff(baseline, kernel, nil)
	if len(res.MissingFromKernel) != 0 || len(res.ExtraInKernel) != 0 {
		t.Fatalf("expected 0 phantom anomalies, got missing=%v extra=%v", res.MissingFromKernel, res.ExtraInKernel)
	}
}

func TestCoverage_RealMissingDurableRange(t *testing.T) {
	baseline := []string{"1.2.3.4", "10.0.0.0/24"}
	kernel := []string{"1.2.3.4"} // 10.0.0.0/24 missing from kernel
	res := CoverageDiff(baseline, kernel, nil)
	if len(res.MissingFromKernel) != 1 || res.MissingFromKernel[0] != "10.0.0.0/24" {
		t.Fatalf("expected 10.0.0.0/24 missing, got %v", res.MissingFromKernel)
	}
	if len(res.ExtraInKernel) != 0 {
		t.Fatalf("unexpected extra: %v", res.ExtraInKernel)
	}
}

func TestCoverage_RealExtraInKernel(t *testing.T) {
	baseline := []string{"1.2.3.4"}
	kernel := []string{"1.2.3.4", "9.9.9.9"} // 9.9.9.9 injected, no baseline/session source
	res := CoverageDiff(baseline, kernel, nil)
	if len(res.ExtraInKernel) != 1 || res.ExtraInKernel[0] != "9.9.9.9" {
		t.Fatalf("expected 9.9.9.9 extra, got %v", res.ExtraInKernel)
	}
}

func TestCoverage_SessionAllowance(t *testing.T) {
	baseline := []string{"1.2.3.4"}
	kernel := []string{"1.2.3.4", "5.6.7.8"}
	sessions := []string{"5.6.7.8"} // 5.6.7.8 is a legit session entry, not "extra"
	res := CoverageDiff(baseline, kernel, sessions)
	if len(res.ExtraInKernel) != 0 {
		t.Fatalf("session entry should not be extra, got %v", res.ExtraInKernel)
	}
}

func TestCoverage_SingleIPCoveredByCIDR(t *testing.T) {
	// Baseline lists a single IP; kernel covers it via a CIDR → not missing.
	baseline := []string{"1.2.3.4"}
	kernel := []string{"1.2.3.0/24"}
	res := CoverageDiff(baseline, kernel, nil)
	if len(res.MissingFromKernel) != 0 {
		t.Fatalf("single IP should be covered by CIDR, got missing=%v", res.MissingFromKernel)
	}
}

func TestCoverage_IPv6(t *testing.T) {
	baseline := []string{"2606:4700::/32", "2001:db8:c014:f4da::1"}
	kernel := []string{"2606:4700::/32", "2001:db8:c014:f4da::1"}
	res := CoverageDiff(baseline, kernel, nil)
	if len(res.MissingFromKernel) != 0 || len(res.ExtraInKernel) != 0 {
		t.Fatalf("v6 exact match expected clean, got missing=%v extra=%v", res.MissingFromKernel, res.ExtraInKernel)
	}
	// v6 missing
	res2 := CoverageDiff([]string{"2606:4700::/32"}, []string{"2001:db8::1"}, nil)
	if len(res2.MissingFromKernel) != 1 {
		t.Fatalf("expected v6 missing, got %v", res2.MissingFromKernel)
	}
}

func TestCoverage_AdminIPMissingThenLive(t *testing.T) {
	// The srv3 scenario: durable single IP absent from live kernel set.
	res := CoverageDiff([]string{"192.0.2.122"}, []string{"46.224.164.50"}, nil)
	if len(res.MissingFromKernel) != 1 || res.MissingFromKernel[0] != "192.0.2.122" {
		t.Fatalf("expected admin IP missing, got %v", res.MissingFromKernel)
	}
	// after it is live:
	res2 := CoverageDiff([]string{"192.0.2.122"}, []string{"46.224.164.50", "192.0.2.122"}, nil)
	if len(res2.MissingFromKernel) != 0 {
		t.Fatalf("admin IP should be covered now, got %v", res2.MissingFromKernel)
	}
}

func TestParseRangeToken_BadInput(t *testing.T) {
	for _, bad := range []string{"", "not-an-ip", "1.2.3.4/99", "garbage-text"} {
		if _, err := ParseRangeToken(bad); err == nil {
			t.Fatalf("expected error for %q", bad)
		}
	}
}

func TestCoverage_BadTokensSurfaced(t *testing.T) {
	res := CoverageDiff([]string{"1.2.3.4", "JUNK"}, []string{"1.2.3.4"}, nil)
	if len(res.BadBaseline) != 1 || !strings.Contains(res.BadBaseline[0], "JUNK") {
		t.Fatalf("expected JUNK surfaced as bad baseline, got %v", res.BadBaseline)
	}
}
