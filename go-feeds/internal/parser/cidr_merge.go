package parser

import (
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/netip"
	"sort"
)

// MergeCIDRs performs basic CIDR merging and optimization
// This is a simple implementation that deduplicates
// TODO: Add advanced interval tree merging for adjacent/overlapping ranges
func MergeCIDRs(prefixes []netip.Prefix) []netip.Prefix {
	// For now, just deduplicate
	// In a future version, we can add proper CIDR collapse
	return Deduplicate(prefixes)
}

// HashPrefixes creates a deterministic hash of a prefix list
// Used to detect if the merged feed content has changed
func HashPrefixes(prefixes []netip.Prefix) string {
	// Sort for deterministic hash
	sorted := make([]netip.Prefix, len(prefixes))
	copy(sorted, prefixes)
	sort.Slice(sorted, func(i, j int) bool {
		return sorted[i].String() < sorted[j].String()
	})

	h := sha256.New()
	for _, p := range sorted {
		io.WriteString(h, p.String())
		io.WriteString(h, "\n")
	}
	return hex.EncodeToString(h.Sum(nil))
}

// CompareHashes checks if current hash matches cached hash
// Returns true if feeds are unchanged (skip reload)
func CompareHashes(current, cached string) bool {
	return current == cached && current != ""
}
