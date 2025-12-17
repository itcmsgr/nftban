package util

// DiffResult is a generic diff result between two slices of comparable values.
// This replaces the old string-specific diff and can be reused for IPs, ports,
// feed IDs, alert types, or any comparable type.
type DiffResult[T comparable] struct {
	ToAdd     []T
	ToRemove  []T
	Unchanged int
}

// ComputeDiff returns which items should be added/removed to transform
// `current` into `desired`.
//
// This is the foundation for all sync operations in nftban v1.0:
// - IP set synchronization (whitelist/blacklist)
// - Threat feed updates
// - Suricata alert type management
// - Port set updates
// - Any set-based diff operation
//
// Performance characteristics:
// - O(n + m) time complexity where n=len(desired), m=len(current)
// - Preallocated maps with capacity hints for efficiency
// - Zero allocations for unchanged items
//
// Example usage:
//
//	desired := []string{"1.2.3.4", "5.6.7.8"}
//	current := []string{"5.6.7.8", "9.9.9.9"}
//	diff := util.ComputeDiff(desired, current)
//	// Result: ToAdd=["1.2.3.4"], ToRemove=["9.9.9.9"], Unchanged=1
func ComputeDiff[T comparable](desired, current []T) DiffResult[T] {
	// Preallocate maps with exact capacity to avoid resizing
	desiredSet := make(map[T]struct{}, len(desired))
	for _, v := range desired {
		desiredSet[v] = struct{}{}
	}

	currentSet := make(map[T]struct{}, len(current))
	for _, v := range current {
		currentSet[v] = struct{}{}
	}

	result := DiffResult[T]{
		ToAdd:    make([]T, 0),
		ToRemove: make([]T, 0),
	}

	// Find items in desired but not in current → add
	for v := range desiredSet {
		if _, ok := currentSet[v]; !ok {
			result.ToAdd = append(result.ToAdd, v)
		} else {
			result.Unchanged++
		}
	}

	// Find items in current but not in desired → remove
	for v := range currentSet {
		if _, ok := desiredSet[v]; !ok {
			result.ToRemove = append(result.ToRemove, v)
		}
	}

	return result
}
