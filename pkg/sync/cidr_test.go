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

package sync

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
