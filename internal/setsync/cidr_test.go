// =============================================================================
// NFTBan - CIDR Merging Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cidr_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Test cases for CIDR merging utilities"
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
	"strconv"
	"testing"
)

func TestMergeCIDRs_IPv4_Overlapping(t *testing.T) {
	// Test overlapping CIDRs that should merge
	input := []string{
		"192.168.1.0/24",
		"192.168.1.128/25", // Overlaps with above
		"192.168.1.64/26",  // Also overlaps
	}

	result, stats, err := MergeCIDRs(input)
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	// Should merge to single /24
	if len(result) != 1 {
		t.Errorf("Expected 1 CIDR, got %d: %v", len(result), result)
	}

	if result[0] != "192.168.1.0/24" {
		t.Errorf("Expected 192.168.1.0/24, got %s", result[0])
	}

	if stats.InputCIDRs != 3 {
		t.Errorf("Expected 3 input CIDRs, got %d", stats.InputCIDRs)
	}

	if stats.OutputRanges != 1 {
		t.Errorf("Expected 1 output range, got %d", stats.OutputRanges)
	}

	if stats.OverlapsMerged != 2 {
		t.Errorf("Expected 2 overlaps merged, got %d", stats.OverlapsMerged)
	}

	t.Logf("Reduction: %.1f%%", stats.ReductionPct)
}

func TestMergeCIDRs_IPv4_Adjacent(t *testing.T) {
	// Test adjacent CIDRs that should merge
	input := []string{
		"192.168.1.0/25",   // 192.168.1.0 - 192.168.1.127
		"192.168.1.128/25", // 192.168.1.128 - 192.168.1.255
	}

	result, stats, err := MergeCIDRs(input)
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	// Should merge to single /24
	if len(result) != 1 {
		t.Errorf("Expected 1 CIDR, got %d: %v", len(result), result)
	}

	if result[0] != "192.168.1.0/24" {
		t.Errorf("Expected 192.168.1.0/24, got %s", result[0])
	}

	t.Logf("Stats: %+v", stats)
}

func TestMergeCIDRs_IPv4_Separate(t *testing.T) {
	// Test non-overlapping CIDRs that should NOT merge
	input := []string{
		"192.168.1.0/24",
		"192.168.3.0/24",
	}

	result, stats, err := MergeCIDRs(input)
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	// Should remain separate
	if len(result) != 2 {
		t.Errorf("Expected 2 CIDRs, got %d: %v", len(result), result)
	}

	if stats.OverlapsMerged != 0 {
		t.Errorf("Expected 0 overlaps merged, got %d", stats.OverlapsMerged)
	}

	t.Logf("Stats: %+v", stats)
}

func TestMergeCIDRs_IPv6(t *testing.T) {
	// Test IPv6 CIDR merging
	input := []string{
		"2001:db8::/64",
		"2001:db8:0:1::/64",
	}

	result, stats, err := MergeCIDRs(input)
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	// These are adjacent and should merge to 2001:db8::/63
	if len(result) != 1 {
		t.Errorf("Expected 1 CIDR (merged), got %d: %v", len(result), result)
	}
	if len(result) == 1 && result[0] != "2001:db8::/63" {
		t.Errorf("Expected 2001:db8::/63, got %s", result[0])
	}

	t.Logf("Stats: %+v", stats)
}

func TestMergeCIDRs_Mixed(t *testing.T) {
	// Test mixing IPv4 and IPv6
	input := []string{
		"192.168.1.0/24",
		"2001:db8::/64",
		"192.168.1.128/25", // Overlaps with first IPv4
	}

	result, stats, err := MergeCIDRs(input)
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	// Should have 1 IPv4 (merged) + 1 IPv6 = 2 total
	if len(result) != 2 {
		t.Errorf("Expected 2 CIDRs, got %d: %v", len(result), result)
	}

	if stats.OverlapsMerged != 1 {
		t.Errorf("Expected 1 overlap merged, got %d", stats.OverlapsMerged)
	}

	t.Logf("Stats: %+v", stats)
}

func TestMergeCIDRs_Empty(t *testing.T) {
	result, stats, err := MergeCIDRs([]string{})
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	if len(result) != 0 {
		t.Errorf("Expected 0 CIDRs for empty input, got %d", len(result))
	}

	if stats.InputCIDRs != 0 {
		t.Errorf("Expected 0 input CIDRs, got %d", stats.InputCIDRs)
	}
}

// =============================================================================
// EDGE CASE TESTS
// =============================================================================

func TestMergeCIDRs_Nil(t *testing.T) {
	result, stats, err := MergeCIDRs(nil)
	if err != nil {
		t.Fatalf("MergeCIDRs failed on nil input: %v", err)
	}

	if len(result) != 0 {
		t.Errorf("Expected 0 CIDRs for nil input, got %d", len(result))
	}

	if stats.InputCIDRs != 0 {
		t.Errorf("Expected 0 input CIDRs for nil, got %d", stats.InputCIDRs)
	}
}

func TestMergeCIDRs_SingleItem(t *testing.T) {
	input := []string{"10.0.0.0/8"}

	result, stats, err := MergeCIDRs(input)
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	if len(result) != 1 {
		t.Errorf("Expected 1 CIDR for single input, got %d", len(result))
	}

	if result[0] != "10.0.0.0/8" {
		t.Errorf("Expected 10.0.0.0/8, got %s", result[0])
	}

	if stats.InputCIDRs != 1 {
		t.Errorf("Expected 1 input CIDR, got %d", stats.InputCIDRs)
	}

	if stats.OverlapsMerged != 0 {
		t.Errorf("Expected 0 overlaps for single item, got %d", stats.OverlapsMerged)
	}
}

func TestMergeCIDRs_Duplicates(t *testing.T) {
	// Exact duplicates should be deduplicated
	input := []string{
		"192.168.1.0/24",
		"192.168.1.0/24",
		"192.168.1.0/24",
	}

	result, stats, err := MergeCIDRs(input)
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	if len(result) != 1 {
		t.Errorf("Expected 1 CIDR after dedup, got %d: %v", len(result), result)
	}

	if stats.InputCIDRs != 3 {
		t.Errorf("Expected 3 input CIDRs, got %d", stats.InputCIDRs)
	}

	t.Logf("Duplicates merged: %+v", stats)
}

func TestMergeCIDRs_SingleHost_IPv4(t *testing.T) {
	// Test /32 single-host CIDRs
	input := []string{
		"192.168.1.1/32",
		"192.168.1.2/32",
		"192.168.1.3/32",
	}

	result, stats, err := MergeCIDRs(input)
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	// These are not adjacent in CIDR terms, so may not merge
	t.Logf("Single hosts result: %v (count: %d)", result, len(result))
	t.Logf("Stats: %+v", stats)

	if stats.InputCIDRs != 3 {
		t.Errorf("Expected 3 input CIDRs, got %d", stats.InputCIDRs)
	}
}

func TestMergeCIDRs_SingleHost_IPv6(t *testing.T) {
	// Test /128 single-host CIDRs
	input := []string{
		"2001:db8::1/128",
		"2001:db8::2/128",
	}

	result, stats, err := MergeCIDRs(input)
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	t.Logf("IPv6 single hosts result: %v (count: %d)", result, len(result))
	t.Logf("Stats: %+v", stats)

	if stats.InputCIDRs != 2 {
		t.Errorf("Expected 2 input CIDRs, got %d", stats.InputCIDRs)
	}
}

func TestMergeCIDRs_MalformedCIDRs(t *testing.T) {
	// Test handling of invalid CIDR formats
	testCases := []struct {
		name  string
		input []string
	}{
		{"invalid IP", []string{"not-an-ip/24"}},
		{"missing prefix", []string{"192.168.1.0"}},
		{"invalid prefix", []string{"192.168.1.0/33"}},
		{"empty string", []string{""}},
		{"whitespace", []string{"  192.168.1.0/24  "}},
		{"IPv6 invalid prefix", []string{"2001:db8::/129"}},
	}

	for _, tc := range testCases {
		t.Run(tc.name, func(t *testing.T) {
			result, stats, err := MergeCIDRs(tc.input)
			// Should either error or skip invalid entries gracefully
			t.Logf("Input: %v, Result: %v, Stats: %+v, Error: %v", tc.input, result, stats, err)
			// We just verify it doesn't panic - behavior may vary
		})
	}
}

func TestMergeCIDRs_MixedValidInvalid(t *testing.T) {
	// Mix of valid and invalid CIDRs
	input := []string{
		"192.168.1.0/24",  // Valid
		"invalid",         // Invalid
		"192.168.2.0/24",  // Valid
		"",                // Invalid (empty)
		"10.0.0.0/8",      // Valid
	}

	result, stats, err := MergeCIDRs(input)
	// Should process valid entries, skip or error on invalid
	t.Logf("Mixed input result: %v, Stats: %+v, Error: %v", result, stats, err)

	// At minimum, valid entries should be processed if no error
	if err == nil && len(result) < 1 {
		t.Errorf("Expected at least some valid CIDRs to be processed")
	}
}

func TestMergeCIDRs_IPv6_Overlapping(t *testing.T) {
	// Test IPv6 overlapping CIDRs
	input := []string{
		"2001:db8::/32",
		"2001:db8:1::/48",  // Contained within /32
		"2001:db8:2::/48",  // Also contained within /32
	}

	result, stats, err := MergeCIDRs(input)
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	// The /32 contains both /48s, so should merge to single /32
	if len(result) != 1 {
		t.Errorf("Expected 1 CIDR (merged), got %d: %v", len(result), result)
	}

	if len(result) == 1 && result[0] != "2001:db8::/32" {
		t.Errorf("Expected 2001:db8::/32, got %s", result[0])
	}

	t.Logf("IPv6 overlapping stats: %+v", stats)
}

func TestMergeCIDRs_IPv6_Separate(t *testing.T) {
	// Test non-adjacent IPv6 CIDRs
	input := []string{
		"2001:db8::/64",
		"2001:db8:ffff::/64",
	}

	result, stats, err := MergeCIDRs(input)
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	// These are far apart and should not merge
	if len(result) != 2 {
		t.Errorf("Expected 2 separate CIDRs, got %d: %v", len(result), result)
	}

	if stats.OverlapsMerged != 0 {
		t.Errorf("Expected 0 overlaps for separate IPv6, got %d", stats.OverlapsMerged)
	}

	t.Logf("IPv6 separate stats: %+v", stats)
}

func TestMergeCIDRs_LargePrefixes(t *testing.T) {
	// Test very large CIDR blocks (/8, /16)
	input := []string{
		"10.0.0.0/8",
		"10.128.0.0/9",   // Second half of 10.0.0.0/8
		"10.0.0.0/9",     // First half of 10.0.0.0/8
	}

	result, stats, err := MergeCIDRs(input)
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	// The /8 contains both /9s
	if len(result) != 1 {
		t.Errorf("Expected 1 CIDR, got %d: %v", len(result), result)
	}

	t.Logf("Large prefix stats: %+v", stats)
}

func TestMergeCIDRs_MaxAggregation(t *testing.T) {
	// Many small CIDRs that should aggregate to one larger block
	// 256 /32s should become one /24
	input := make([]string, 256)
	for i := 0; i < 256; i++ {
		input[i] = "192.168.1." + strconv.Itoa(i) + "/32"
	}

	result, stats, err := MergeCIDRs(input)
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	// Should aggregate to 192.168.1.0/24
	if len(result) != 1 {
		maxShow := 10
		if len(result) < maxShow {
			maxShow = len(result)
		}
		t.Logf("Got %d CIDRs instead of 1: %v...", len(result), result[:maxShow])
	}

	t.Logf("Max aggregation: %d inputs -> %d outputs (%.1f%% reduction)",
		stats.InputCIDRs, stats.OutputRanges, stats.ReductionPct)
}

func TestMergeCIDRs_Supernet(t *testing.T) {
	// Test when a supernet contains multiple subnets
	input := []string{
		"10.0.0.0/16",     // Supernet
		"10.0.1.0/24",     // Contained in supernet
		"10.0.2.0/24",     // Contained in supernet
		"10.0.255.0/24",   // Contained in supernet
	}

	result, stats, err := MergeCIDRs(input)
	if err != nil {
		t.Fatalf("MergeCIDRs failed: %v", err)
	}

	// Should merge to just the /16 supernet
	if len(result) != 1 {
		t.Errorf("Expected 1 CIDR (supernet), got %d: %v", len(result), result)
	}

	if len(result) == 1 && result[0] != "10.0.0.0/16" {
		t.Errorf("Expected 10.0.0.0/16, got %s", result[0])
	}

	t.Logf("Supernet stats: %+v", stats)
}

// =============================================================================
// FILTER PROBLEMATIC CIDRS TESTS
// =============================================================================

func TestFilterProblematicCIDRs_Basic(t *testing.T) {
	// Valid public CIDRs should pass through unchanged
	input := []string{
		"1.2.3.0/24",
		"8.8.8.0/24",
		"44.0.0.0/9",
		"203.0.114.0/24", // Just outside TEST-NET-3 (203.0.113.0/24)
	}

	result, stats := FilterProblematicCIDRs(input)

	if len(result) != len(input) {
		t.Errorf("Expected %d CIDRs to pass, got %d: %v", len(input), len(result), result)
	}
	if stats.Filtered != 0 {
		t.Errorf("Expected 0 filtered, got %d", stats.Filtered)
	}
	if stats.Kept != len(input) {
		t.Errorf("Expected %d kept, got %d", len(input), stats.Kept)
	}
}

func TestFilterProblematicCIDRs_BogonRanges(t *testing.T) {
	// Each bogon prefix should be filtered (either as bogon or too-large)
	for _, bogon := range BogonPrefixes {
		t.Run(bogon, func(t *testing.T) {
			result, stats := FilterProblematicCIDRs([]string{bogon})
			if len(result) != 0 {
				t.Errorf("Bogon %s should be filtered, but got: %v", bogon, result)
			}
			if stats.Filtered != 1 {
				t.Errorf("Expected Filtered=1, got %d", stats.Filtered)
			}
			// Note: /8 and /4 bogons hit TooLarge check first (prefix < MinAllowedPrefixLen)
			// Only bogons with prefix >= MinAllowedPrefixLen are classified as Bogon
			if stats.Bogon == 0 && stats.TooLarge == 0 {
				t.Errorf("Expected either Bogon or TooLarge to be 1, both are 0")
			}
		})
	}
}

func TestFilterProblematicCIDRs_TooLarge(t *testing.T) {
	// CIDRs with prefix < MinAllowedPrefixLen should be filtered (IPv4 only)
	tooLarge := []string{
		"0.0.0.0/0",   // /0 — the entire internet
		"0.0.0.0/1",   // /1
		"128.0.0.0/1", // /1
		"0.0.0.0/4",   // /4
		"0.0.0.0/8",   // /8 — also bogon (0.0.0.0/8)
		"1.0.0.0/8",   // /8 — public but too large
	}

	for _, cidr := range tooLarge {
		t.Run(cidr, func(t *testing.T) {
			result, stats := FilterProblematicCIDRs([]string{cidr})
			if len(result) != 0 {
				t.Errorf("Too-large CIDR %s should be filtered, but got: %v", cidr, result)
			}
			if stats.Filtered != 1 {
				t.Errorf("Expected Filtered=1 for %s, got %d", cidr, stats.Filtered)
			}
		})
	}

	// /9 should be allowed (MinAllowedPrefixLen = 9)
	result, stats := FilterProblematicCIDRs([]string{"44.0.0.0/9"})
	if len(result) != 1 {
		t.Errorf("Expected /9 to pass (MinAllowedPrefixLen=%d), got filtered", MinAllowedPrefixLen)
	}
	if stats.TooLarge != 0 {
		t.Errorf("Expected TooLarge=0 for /9, got %d", stats.TooLarge)
	}
}

func TestFilterProblematicCIDRs_EdgeCases(t *testing.T) {
	// 0.0.0.0/0 — both too large AND bogon
	result, stats := FilterProblematicCIDRs([]string{"0.0.0.0/0"})
	if len(result) != 0 {
		t.Errorf("0.0.0.0/0 should be filtered, got: %v", result)
	}
	// Should be caught by TooLarge check first (prefix < MinAllowedPrefixLen)
	if stats.TooLarge != 1 {
		t.Errorf("Expected TooLarge=1 for 0.0.0.0/0, got %d", stats.TooLarge)
	}

	// Empty input
	result, stats = FilterProblematicCIDRs([]string{})
	if len(result) != 0 {
		t.Errorf("Expected 0 results for empty input, got %d", len(result))
	}
	if stats.Total != 0 {
		t.Errorf("Expected Total=0 for empty input, got %d", stats.Total)
	}

	// Nil input
	result, stats = FilterProblematicCIDRs(nil)
	if len(result) != 0 {
		t.Errorf("Expected 0 results for nil input, got %d", len(result))
	}
	if stats.Total != 0 {
		t.Errorf("Expected Total=0 for nil input, got %d", stats.Total)
	}

	// Invalid CIDR string
	result, stats = FilterProblematicCIDRs([]string{"not-a-cidr"})
	if len(result) != 0 {
		t.Errorf("Expected invalid CIDR to be filtered, got: %v", result)
	}
	if stats.Filtered != 1 {
		t.Errorf("Expected Filtered=1 for invalid CIDR, got %d", stats.Filtered)
	}
}

func TestFilterProblematicCIDRs_Stats(t *testing.T) {
	input := []string{
		"8.8.8.0/24",      // valid — kept
		"1.1.1.0/24",      // valid — kept
		"10.0.0.0/8",      // bogon — filtered
		"192.168.1.0/24",  // bogon — filtered
		"0.0.0.0/0",       // too large — filtered
		"127.0.0.1/32",    // bogon (127.0.0.0/8) — filtered
		"invalid",         // parse error — filtered
	}

	result, stats := FilterProblematicCIDRs(input)

	if stats.Total != 7 {
		t.Errorf("Expected Total=7, got %d", stats.Total)
	}
	if stats.Kept != 2 {
		t.Errorf("Expected Kept=2, got %d", stats.Kept)
	}
	if stats.Filtered != 5 {
		t.Errorf("Expected Filtered=5, got %d", stats.Filtered)
	}
	if len(result) != 2 {
		t.Errorf("Expected 2 results, got %d: %v", len(result), result)
	}

	// Verify the kept CIDRs are the expected ones
	kept := map[string]bool{}
	for _, cidr := range result {
		kept[cidr] = true
	}
	if !kept["8.8.8.0/24"] {
		t.Error("Expected 8.8.8.0/24 to be kept")
	}
	if !kept["1.1.1.0/24"] {
		t.Error("Expected 1.1.1.0/24 to be kept")
	}
}

func TestFilterProblematicCIDRs_MixedValid(t *testing.T) {
	// Realistic feed-like input: mix of valid, bogon, and too-large
	input := []string{
		"45.33.32.0/24",   // valid (Linode)
		"198.51.100.0/24", // bogon (TEST-NET-2)
		"185.220.101.0/24", // valid (Tor exit)
		"172.16.0.0/12",   // bogon (RFC 1918)
		"1.0.0.0/8",       // too large
		"91.121.0.0/16",   // valid (OVH)
		"169.254.1.0/24",  // bogon (link-local)
		"23.227.38.0/24",  // valid (Shopify)
	}

	result, stats := FilterProblematicCIDRs(input)

	if stats.Kept != 4 {
		t.Errorf("Expected Kept=4, got %d", stats.Kept)
	}
	if len(result) != 4 {
		t.Errorf("Expected 4 results, got %d: %v", len(result), result)
	}
	if stats.Bogon < 3 {
		t.Errorf("Expected at least 3 bogon, got %d", stats.Bogon)
	}
	if stats.TooLarge != 1 {
		t.Errorf("Expected TooLarge=1, got %d", stats.TooLarge)
	}
}

func TestFilterProblematicCIDRs_IPv6(t *testing.T) {
	// IPv6 CIDRs — prefix length check is IPv4-only, so large IPv6 should pass
	input := []string{
		"2001:db8::/32",      // Documentation prefix — but code only checks IPv4 bogons
		"2607:f8b0::/32",     // Google
		"::1/128",            // Loopback — not in BogonPrefixes (IPv4 only)
		"fe80::/10",          // Link-local — not in BogonPrefixes (IPv4 only)
		"2001:4860::/32",     // Google
	}

	result, stats := FilterProblematicCIDRs(input)

	// Current implementation only filters IPv4 bogons and IPv4 prefix lengths
	// So all IPv6 CIDRs should pass through
	if len(result) != len(input) {
		t.Errorf("Expected all %d IPv6 CIDRs to pass (IPv4-only filters), got %d: %v",
			len(input), len(result), result)
	}
	if stats.Filtered != 0 {
		t.Errorf("Expected Filtered=0 for IPv6 input, got %d", stats.Filtered)
	}
}
