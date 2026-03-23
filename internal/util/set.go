// =============================================================================
// NFTBan - Generic Set Implementation
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="set"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Type-safe generic set with zero-overhead values"
// meta:input="Comparable values"
// meta:output="Set operations"
// meta:depends="None"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package util

// Set is a generic set implementation using Go's map type.
// Uses struct{} as value type for zero memory overhead.
//
// This replaces map[string]bool and similar patterns throughout the codebase
// with a consistent, efficient, and type-safe API.
//
// Benefits over map[T]bool:
// - Zero memory overhead for values (struct{} vs bool)
// - Consistent API across all set operations
// - Type-safe
// - Self-documenting code
type Set[T comparable] map[T]struct{}

// NewSet creates a new set and optionally adds initial values.
// Preallocates map with correct capacity if initial values provided.
//
// Example:
//
//	// Empty set
//	ips := util.NewSet[string]()
//
//	// Set with initial values
//	ports := util.NewSet(80, 443, 8080)
func NewSet[T comparable](values ...T) Set[T] {
	s := make(Set[T], len(values))
	for _, v := range values {
		s[v] = struct{}{}
	}
	return s
}

// Add adds a value to the set.
// Safe to call multiple times with same value (idempotent).
func (s Set[T]) Add(v T) {
	s[v] = struct{}{}
}

// Has checks if a value exists in the set.
// O(1) average time complexity.
func (s Set[T]) Has(v T) bool {
	_, ok := s[v]
	return ok
}

// Remove removes a value from the set.
// Safe to call even if value doesn't exist.
func (s Set[T]) Remove(v T) {
	delete(s, v)
}

// ToSlice converts the set to a slice.
// Order is not guaranteed (map iteration is random).
// Preallocates slice with exact capacity to avoid resizing.
func (s Set[T]) ToSlice() []T {
	out := make([]T, 0, len(s))
	for v := range s {
		out = append(out, v)
	}
	return out
}

// Len returns the number of elements in the set.
func (s Set[T]) Len() int {
	return len(s)
}

// Clear removes all elements from the set.
// More efficient than creating a new set if you plan to reuse.
func (s Set[T]) Clear() {
	for k := range s {
		delete(s, k)
	}
}

// Clone creates a shallow copy of the set.
// Useful when you need to preserve the original.
func (s Set[T]) Clone() Set[T] {
	clone := make(Set[T], len(s))
	for k := range s {
		clone[k] = struct{}{}
	}
	return clone
}

// Union returns a new set containing all elements from both sets.
func (s Set[T]) Union(other Set[T]) Set[T] {
	result := make(Set[T], len(s)+len(other))
	for k := range s {
		result[k] = struct{}{}
	}
	for k := range other {
		result[k] = struct{}{}
	}
	return result
}

// Intersection returns a new set containing only elements present in both sets.
func (s Set[T]) Intersection(other Set[T]) Set[T] {
	result := make(Set[T])
	for k := range s {
		if other.Has(k) {
			result[k] = struct{}{}
		}
	}
	return result
}

// Difference returns a new set containing elements in s but not in other.
func (s Set[T]) Difference(other Set[T]) Set[T] {
	result := make(Set[T])
	for k := range s {
		if !other.Has(k) {
			result[k] = struct{}{}
		}
	}
	return result
}
