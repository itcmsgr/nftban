package sync

import (
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

	// Should remain separate (not adjacent in IPv6 space)
	if len(result) != 2 {
		t.Errorf("Expected 2 CIDRs, got %d: %v", len(result), result)
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
