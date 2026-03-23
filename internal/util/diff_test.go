// =============================================================================
// NFTBan - Diff Computation Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="diff_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Test cases for generic diff computation"
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

package util

import (
	"testing"
)

func TestComputeDiff_Strings(t *testing.T) {
	desired := []string{"1.2.3.4", "5.6.7.8", "10.0.0.1"}
	current := []string{"5.6.7.8", "9.9.9.9"}

	diff := ComputeDiff(desired, current)

	// Should add 1.2.3.4 and 10.0.0.1
	if len(diff.ToAdd) != 2 {
		t.Errorf("Expected 2 items to add, got %d", len(diff.ToAdd))
	}

	// Should remove 9.9.9.9
	if len(diff.ToRemove) != 1 {
		t.Errorf("Expected 1 item to remove, got %d", len(diff.ToRemove))
	}

	// Should have 1 unchanged (5.6.7.8)
	if diff.Unchanged != 1 {
		t.Errorf("Expected 1 unchanged, got %d", diff.Unchanged)
	}
}

func TestComputeDiff_Integers(t *testing.T) {
	desired := []int{80, 443, 8080}
	current := []int{443, 22}

	diff := ComputeDiff(desired, current)

	// Should add 80 and 8080
	if len(diff.ToAdd) != 2 {
		t.Errorf("Expected 2 items to add, got %d", len(diff.ToAdd))
	}

	// Should remove 22
	if len(diff.ToRemove) != 1 {
		t.Errorf("Expected 1 item to remove, got %d", len(diff.ToRemove))
	}

	// Should have 1 unchanged (443)
	if diff.Unchanged != 1 {
		t.Errorf("Expected 1 unchanged, got %d", diff.Unchanged)
	}
}

func TestComputeDiff_Empty(t *testing.T) {
	// Empty desired, non-empty current = remove all
	diff1 := ComputeDiff([]string{}, []string{"1.2.3.4", "5.6.7.8"})
	if len(diff1.ToRemove) != 2 {
		t.Errorf("Expected 2 items to remove, got %d", len(diff1.ToRemove))
	}
	if len(diff1.ToAdd) != 0 {
		t.Errorf("Expected 0 items to add, got %d", len(diff1.ToAdd))
	}

	// Non-empty desired, empty current = add all
	diff2 := ComputeDiff([]string{"1.2.3.4", "5.6.7.8"}, []string{})
	if len(diff2.ToAdd) != 2 {
		t.Errorf("Expected 2 items to add, got %d", len(diff2.ToAdd))
	}
	if len(diff2.ToRemove) != 0 {
		t.Errorf("Expected 0 items to remove, got %d", len(diff2.ToRemove))
	}

	// Both empty = no changes
	diff3 := ComputeDiff([]string{}, []string{})
	if len(diff3.ToAdd) != 0 || len(diff3.ToRemove) != 0 || diff3.Unchanged != 0 {
		t.Errorf("Expected all zeros for empty diff")
	}
}

func TestComputeDiff_Identical(t *testing.T) {
	items := []string{"1.2.3.4", "5.6.7.8", "10.0.0.1"}
	diff := ComputeDiff(items, items)

	if len(diff.ToAdd) != 0 {
		t.Errorf("Expected 0 items to add, got %d", len(diff.ToAdd))
	}
	if len(diff.ToRemove) != 0 {
		t.Errorf("Expected 0 items to remove, got %d", len(diff.ToRemove))
	}
	if diff.Unchanged != 3 {
		t.Errorf("Expected 3 unchanged, got %d", diff.Unchanged)
	}
}
