// =============================================================================
// NFTBan - CIDR Merging Utilities
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="cidr"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="Merges overlapping IPv4 and IPv6 CIDR ranges for nftables interval sets"
// meta:input="CIDR strings"
// meta:output="Merged non-overlapping CIDRs"
// meta:depends="encoding/binary,math/big,net"
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
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"math/big"
	"net"
	"os"
	"runtime"
	"sort"
)

// ErrMemoryBudgetExceeded is returned when CIDR merging exceeds memory budget
var ErrMemoryBudgetExceeded = errors.New("CIDR merge aborted: memory budget exceeded")

// DefaultMemoryBudget is the default memory limit for CIDR merging (256MB)
const DefaultMemoryBudget = 256 * 1024 * 1024

// memoryBudget is the current memory budget for CIDR operations
var memoryBudget uint64 = DefaultMemoryBudget

// SetMemoryBudget sets the memory budget for CIDR merging operations
func SetMemoryBudget(bytes uint64) {
	memoryBudget = bytes
}

// debugMemStats controls whether ReadMemStats is called during CIDR merging.
// ReadMemStats triggers a stop-the-world pause and hurts performance under load.
// Enable only for debugging by setting NFTBAN_DEBUG_MEMSTATS=1.
var debugMemStats = os.Getenv("NFTBAN_DEBUG_MEMSTATS") == "1"

// checkMemoryBudget returns true if current heap allocation exceeds budget.
// When debugMemStats is false (default), this is a no-op to avoid the
// stop-the-world pause caused by runtime.ReadMemStats on the hot path.
func checkMemoryBudget() bool {
	if !debugMemStats {
		return false
	}
	var m runtime.MemStats
	runtime.ReadMemStats(&m)
	return m.HeapAlloc > memoryBudget
}

// MinAllowedPrefixLen is the minimum prefix length (maximum range size) allowed
// /8 = 16M IPs, /9 = 8M IPs - we allow /9 and smaller (more specific)
const MinAllowedPrefixLen = 9

// BogonPrefixes are reserved/special-use IPv4 ranges that should be filtered
// These ranges are not routable on the public internet and shouldn't be in threat feeds
var BogonPrefixes = []string{
	"0.0.0.0/8",     // "This" network (RFC 1122)
	"10.0.0.0/8",    // Private-Use (RFC 1918)
	"100.64.0.0/10", // Shared Address Space (RFC 6598)
	"127.0.0.0/8",   // Loopback (RFC 1122)
	"169.254.0.0/16", // Link Local (RFC 3927)
	"172.16.0.0/12", // Private-Use (RFC 1918)
	"192.0.0.0/24",  // IETF Protocol Assignments (RFC 6890)
	"192.0.2.0/24",  // Documentation (TEST-NET-1, RFC 5737)
	"192.168.0.0/16", // Private-Use (RFC 1918)
	"198.18.0.0/15", // Benchmarking (RFC 2544)
	"198.51.100.0/24", // Documentation (TEST-NET-2, RFC 5737)
	"203.0.113.0/24", // Documentation (TEST-NET-3, RFC 5737)
	"224.0.0.0/4",   // Multicast (RFC 5771) - was /3 in firehol!
	"240.0.0.0/4",   // Reserved (RFC 1112)
	"255.255.255.255/32", // Limited Broadcast
}

// bogonNets caches parsed bogon networks for fast lookup
var bogonNets []*net.IPNet

func init() {
	bogonNets = make([]*net.IPNet, 0, len(BogonPrefixes))
	for _, cidr := range BogonPrefixes {
		_, ipNet, err := net.ParseCIDR(cidr)
		if err == nil {
			bogonNets = append(bogonNets, ipNet)
		}
	}
}

// FilterStats contains statistics about CIDR filtering
type FilterStats struct {
	Total      int // Total input CIDRs
	Filtered   int // CIDRs removed by filtering
	TooLarge   int // CIDRs removed for being too large
	Bogon      int // CIDRs removed for being bogon/reserved
	Kept       int // CIDRs that passed filtering
}

// FilterProblematicCIDRs removes CIDRs that could cause processing issues:
// 1. CIDRs with prefix length < MinAllowedPrefixLen (too large)
// 2. CIDRs that overlap with bogon/reserved ranges
// This is a proactive defense - filter bad data at input, not during processing
func FilterProblematicCIDRs(cidrs []string) ([]string, *FilterStats) {
	stats := &FilterStats{Total: len(cidrs)}
	result := make([]string, 0, len(cidrs))

	for _, cidr := range cidrs {
		ip, ipNet, err := net.ParseCIDR(cidr)
		if err != nil {
			stats.Filtered++
			continue
		}

		// Check prefix length (only for IPv4)
		ones, _ := ipNet.Mask.Size()
		if ip.To4() != nil && ones < MinAllowedPrefixLen {
			stats.TooLarge++
			stats.Filtered++
			continue
		}

		// Check if it's a bogon/reserved range
		isBogon := false
		for _, bogon := range bogonNets {
			// Check if the CIDR's network address falls within a bogon range
			if bogon.Contains(ipNet.IP) {
				isBogon = true
				break
			}
		}
		if isBogon {
			stats.Bogon++
			stats.Filtered++
			continue
		}

		result = append(result, cidr)
		stats.Kept++
	}

	return result, stats
}

// ipv4Interval represents an IPv4 range as [start, end] inclusive
type ipv4Interval struct {
	Start uint32
	End   uint32
}

// ipv6Interval represents an IPv6 range as [start, end] inclusive
type ipv6Interval struct {
	Start *big.Int
	End   *big.Int
}

// MergeStats contains statistics about CIDR canonicalization
type MergeStats struct {
	InputCIDRs     int     // Number of input CIDRs
	OutputRanges   int     // Number of output ranges after merging
	OverlapsMerged int     // Number of overlaps/duplicates that were merged
	ReductionPct   float64 // Percentage reduction in entries
}

// MergeCIDRsSafe merges CIDRs with automatic filtering of problematic ranges.
// This is the recommended function for processing untrusted feed data.
// It filters out bogon/reserved ranges and overly large CIDRs before merging.
func MergeCIDRsSafe(cidrs []string) ([]string, *MergeStats, *FilterStats, error) {
	// Filter problematic CIDRs first
	filtered, filterStats := FilterProblematicCIDRs(cidrs)

	// Now merge the safe CIDRs
	result, mergeStats, err := MergeCIDRs(filtered)
	return result, mergeStats, filterStats, err
}

// MergeCIDRs merges overlapping and adjacent CIDRs (auto-detects IPv4/IPv6)
// Returns minimal CIDR set and statistics
// WARNING: For untrusted data (feeds, geoban), use MergeCIDRsSafe instead
func MergeCIDRs(cidrs []string) ([]string, *MergeStats, error) {
	if len(cidrs) == 0 {
		return nil, &MergeStats{}, nil
	}

	// Separate IPv4 and IPv6 CIDRs - pre-allocate to avoid reallocation
	ipv4Cidrs := make([]string, 0, len(cidrs))
	ipv6Cidrs := make([]string, 0, len(cidrs))

	for _, cidr := range cidrs {
		ip, _, err := net.ParseCIDR(cidr)
		if err != nil {
			return nil, nil, fmt.Errorf("invalid CIDR %s: %w", cidr, err)
		}

		if ip.To4() != nil {
			ipv4Cidrs = append(ipv4Cidrs, cidr)
		} else {
			ipv6Cidrs = append(ipv6Cidrs, cidr)
		}
	}

	// Merge IPv4 and IPv6 separately
	result := make([]string, 0, len(cidrs))
	var combinedStats MergeStats

	if len(ipv4Cidrs) > 0 {
		merged, stats, err := mergeCIDRsIPv4WithStats(ipv4Cidrs)
		if err != nil {
			return nil, nil, fmt.Errorf("failed to merge IPv4 CIDRs: %w", err)
		}
		result = append(result, merged...)
		combinedStats.InputCIDRs += stats.InputCIDRs
		combinedStats.OutputRanges += stats.OutputRanges
		combinedStats.OverlapsMerged += stats.OverlapsMerged
	}

	if len(ipv6Cidrs) > 0 {
		merged, stats, err := mergeCIDRsIPv6WithStats(ipv6Cidrs)
		if err != nil {
			return nil, nil, fmt.Errorf("failed to merge IPv6 CIDRs: %w", err)
		}
		result = append(result, merged...)
		combinedStats.InputCIDRs += stats.InputCIDRs
		combinedStats.OutputRanges += stats.OutputRanges
		combinedStats.OverlapsMerged += stats.OverlapsMerged
	}

	// Calculate combined reduction percentage
	if combinedStats.InputCIDRs > 0 {
		combinedStats.ReductionPct = float64(combinedStats.OverlapsMerged) / float64(combinedStats.InputCIDRs) * 100
	}

	return result, &combinedStats, nil
}

// mergeCIDRsIPv4WithStats merges overlapping/adjacent IPv4 CIDRs
// Returns minimal CIDR set, statistics, or error
func mergeCIDRsIPv4WithStats(cidrs []string) ([]string, *MergeStats, error) {
	if len(cidrs) == 0 {
		return nil, &MergeStats{}, nil
	}

	// Parse CIDRs to intervals
	intervals := make([]ipv4Interval, 0, len(cidrs))
	for _, cidr := range cidrs {
		_, ipNet, err := net.ParseCIDR(cidr)
		if err != nil {
			return nil, nil, err
		}

		start := ipToUint32(ipNet.IP)
		// Calculate end: broadcast address of the network
		ones, bits := ipNet.Mask.Size()
		// G115: bits-ones is always 0-32 for IPv4 (safe for uint32)
		hostBits := uint32(bits - ones) // #nosec G115 - IPv4 mask bits always 0-32
		var end uint32
		if hostBits >= 32 {
			// /0 prefix: 1<<32 overflows uint32, entire IPv4 space
			end = math.MaxUint32
		} else {
			end = start + (1 << hostBits) - 1
		}

		intervals = append(intervals, ipv4Interval{Start: start, End: end})
	}

	// Sort by start address
	sort.Slice(intervals, func(i, j int) bool {
		return intervals[i].Start < intervals[j].Start
	})

	// Merge overlapping and adjacent ranges
	merged := make([]ipv4Interval, 0, len(intervals))
	current := intervals[0]

	for i := 1; i < len(intervals); i++ {
		next := intervals[i]

		// Check if ranges overlap or are adjacent
		// R11 FIX: Handle uint32 overflow when current.End == MaxUint32
		// Adding 1 to MaxUint32 would overflow to 0, causing incorrect merges
		shouldMerge := current.End == math.MaxUint32 || next.Start <= current.End+1
		if shouldMerge {
			// Merge: extend current range if needed
			if next.End > current.End {
				current.End = next.End
			}
		} else {
			// No overlap: save current and start new range
			merged = append(merged, current)
			current = next
		}
	}
	// Don't forget the last range
	merged = append(merged, current)

	// Convert merged intervals back to CIDRs
	// Pre-allocate with estimate: merged intervals typically expand to ~1.5x CIDRs
	result := make([]string, 0, len(merged)*2)
	for _, interval := range merged {
		intervalCIDRs, err := rangeToCIDRsIPv4(interval.Start, interval.End)
		if err != nil {
			return nil, nil, fmt.Errorf("IPv4 CIDR conversion failed: %w", err)
		}
		result = append(result, intervalCIDRs...)

		// Also check memory budget after each interval
		if checkMemoryBudget() {
			return nil, nil, ErrMemoryBudgetExceeded
		}
	}

	// Calculate statistics
	stats := &MergeStats{
		InputCIDRs:     len(cidrs),
		OutputRanges:   len(result),
		OverlapsMerged: len(cidrs) - len(result),
	}
	if len(cidrs) > 0 {
		stats.ReductionPct = float64(stats.OverlapsMerged) / float64(len(cidrs)) * 100
	}

	return result, stats, nil
}

// mergeCIDRsIPv6WithStats merges overlapping/adjacent IPv6 CIDRs
// Returns minimal CIDR set, statistics, or error
func mergeCIDRsIPv6WithStats(cidrs []string) ([]string, *MergeStats, error) {
	if len(cidrs) == 0 {
		return nil, &MergeStats{}, nil
	}

	// Parse CIDRs to intervals
	intervals := make([]ipv6Interval, 0, len(cidrs))
	for _, cidr := range cidrs {
		_, ipNet, err := net.ParseCIDR(cidr)
		if err != nil {
			return nil, nil, err
		}

		start := ipv6ToBigInt(ipNet.IP)

		// Calculate end address
		ones, bits := ipNet.Mask.Size()
		hostBits := bits - ones

		// end = start + (2^hostBits - 1)
		// #nosec G115 - hostBits is IPv6 mask bits (0-128), always fits in uint
		hostCount := new(big.Int).Lsh(big.NewInt(1), uint(hostBits))
		end := new(big.Int).Add(start, hostCount)
		end.Sub(end, big.NewInt(1))

		intervals = append(intervals, ipv6Interval{Start: start, End: end})
	}

	// Sort by start address
	sort.Slice(intervals, func(i, j int) bool {
		return intervals[i].Start.Cmp(intervals[j].Start) < 0
	})

	// Merge overlapping and adjacent ranges
	merged := make([]ipv6Interval, 0, len(intervals))
	current := ipv6Interval{
		Start: new(big.Int).Set(intervals[0].Start),
		End:   new(big.Int).Set(intervals[0].End),
	}

	for i := 1; i < len(intervals); i++ {
		next := intervals[i]

		// Check if ranges overlap or are adjacent
		// adjacent if next.Start == current.End + 1
		adjacentThreshold := new(big.Int).Add(current.End, big.NewInt(1))

		if next.Start.Cmp(adjacentThreshold) <= 0 {
			// Merge: extend current range if needed
			if next.End.Cmp(current.End) > 0 {
				current.End = new(big.Int).Set(next.End)
			}
		} else {
			// No overlap: save current and start new range
			merged = append(merged, current)
			current = ipv6Interval{
				Start: new(big.Int).Set(next.Start),
				End:   new(big.Int).Set(next.End),
			}
		}
	}
	// Don't forget the last range
	merged = append(merged, current)

	// Convert merged intervals back to CIDRs
	// Pre-allocate with estimate: merged intervals typically expand to ~1.5x CIDRs
	result := make([]string, 0, len(merged)*2)
	for _, interval := range merged {
		intervalCIDRs, err := rangeToCIDRsIPv6(interval.Start, interval.End)
		if err != nil {
			return nil, nil, fmt.Errorf("IPv6 CIDR conversion failed: %w", err)
		}
		result = append(result, intervalCIDRs...)

		// Also check memory budget after each interval
		if checkMemoryBudget() {
			return nil, nil, ErrMemoryBudgetExceeded
		}
	}

	// Calculate statistics
	stats := &MergeStats{
		InputCIDRs:     len(cidrs),
		OutputRanges:   len(result),
		OverlapsMerged: len(cidrs) - len(result),
	}
	if len(cidrs) > 0 {
		stats.ReductionPct = float64(stats.OverlapsMerged) / float64(len(cidrs)) * 100
	}

	return result, stats, nil
}

// ipToUint32 converts an IPv4 address to uint32
func ipToUint32(ip net.IP) uint32 {
	ip = ip.To4()
	return binary.BigEndian.Uint32(ip)
}

// uint32ToIP converts uint32 to IPv4 address
func uint32ToIP(n uint32) net.IP {
	ip := make(net.IP, 4)
	binary.BigEndian.PutUint32(ip, n)
	return ip
}

// ipv6ToBigInt converts an IPv6 address to big.Int
func ipv6ToBigInt(ip net.IP) *big.Int {
	ip = ip.To16()
	return new(big.Int).SetBytes(ip)
}

// bigIntToIPv6 converts big.Int to IPv6 address
func bigIntToIPv6(n *big.Int) net.IP {
	bytes := n.Bytes()
	// Pad to 16 bytes if necessary
	if len(bytes) < 16 {
		padded := make([]byte, 16)
		copy(padded[16-len(bytes):], bytes)
		return net.IP(padded)
	}
	return net.IP(bytes)
}

// rangeToCIDRsIPv4 converts an IPv4 range [start, end] to minimal CIDR set
// Returns error if memory budget is exceeded
func rangeToCIDRsIPv4(start, end uint32) ([]string, error) {
	// Pre-allocate for typical range (32 is max CIDRs for any IPv4 range)
	cidrs := make([]string, 0, 32)
	iterations := 0

	for start <= end {
		// Check memory budget every 1000 iterations
		iterations++
		if iterations%1000 == 0 {
			if checkMemoryBudget() {
				return nil, ErrMemoryBudgetExceeded
			}
		}

		// Find the largest prefix that fits within [start, end]
		// maxPrefixLen is the number of host bits (0 = /32, 32 = /0)
		maxPrefixLen := uint32(0)

		// Find trailing zeros in start (determines max CIDR size)
		// For start=0, all bits are zero so we can use any alignment
		if start == 0 {
			maxPrefixLen = 32 // Can use /0 alignment (but will be limited by range size)
		} else {
			for i := uint32(0); i < 32; i++ {
				if (start & (1 << i)) != 0 {
					maxPrefixLen = i
					break
				}
			}
		}

		// Calculate max block size that fits in range
		// Use uint64 to avoid overflow when maxPrefixLen is large
		rangeSize := uint64(end) - uint64(start) + 1
		var blockSize uint64
		if maxPrefixLen >= 32 {
			blockSize = uint64(1) << 32 // 4 billion (entire IPv4 space)
		} else {
			blockSize = uint64(1) << maxPrefixLen
		}

		// Don't exceed remaining range
		for blockSize > rangeSize && maxPrefixLen > 0 {
			maxPrefixLen--
			blockSize = uint64(1) << maxPrefixLen
		}

		// Create CIDR
		ip := uint32ToIP(start)
		prefixLen := 32 - maxPrefixLen
		cidr := fmt.Sprintf("%s/%d", ip.String(), prefixLen)
		cidrs = append(cidrs, cidr)

		// Move to next block (check for overflow at end of IPv4 space)
		if blockSize > uint64(^uint32(0))-uint64(start) {
			break // Would overflow, we're done
		}
		// #nosec G115 - blockSize is bounded by rangeSize which fits in uint32
		start += uint32(blockSize)
	}

	return cidrs, nil
}

// rangeToCIDRsIPv6 converts an IPv6 range [start, end] to minimal CIDR set
// Returns error if memory budget is exceeded
func rangeToCIDRsIPv6(start, end *big.Int) ([]string, error) {
	cidrs := make([]string, 0, 128) // Pre-allocate for typical range

	current := new(big.Int).Set(start)
	one := big.NewInt(1)

	// Pre-allocate reusable big.Int objects to avoid allocations in loop
	// This prevents ~4-5 allocations per iteration
	temp := new(big.Int)
	rangeSize := new(big.Int)
	blockSize := new(big.Int)

	iterations := 0
	for current.Cmp(end) <= 0 {
		// Check memory budget every 1000 iterations
		iterations++
		if iterations%1000 == 0 {
			if checkMemoryBudget() {
				return nil, ErrMemoryBudgetExceeded
			}
		}

		// Find the largest prefix that fits within [current, end]
		maxPrefixLen := 128

		// Find trailing zeros in current (determines max CIDR size)
		temp.Set(current) // Reuse temp instead of allocating new
		for i := 0; i < 128; i++ {
			if temp.Bit(i) != 0 {
				maxPrefixLen = i
				break
			}
		}

		// Calculate max block size that fits in range - reuse rangeSize
		rangeSize.Sub(end, current)
		rangeSize.Add(rangeSize, one) // +1 because range is inclusive

		// Reuse blockSize instead of allocating new
		blockSize.Lsh(one, uint(maxPrefixLen))

		// Don't exceed remaining range - reuse blockSize in loop
		for blockSize.Cmp(rangeSize) > 0 && maxPrefixLen > 0 {
			maxPrefixLen--
			// #nosec G115 - maxPrefixLen is IPv6 prefix bits (0-128), always fits in uint
			blockSize.Lsh(one, uint(maxPrefixLen))
		}

		// Create CIDR
		ip := bigIntToIPv6(current)
		prefixLen := 128 - maxPrefixLen
		cidr := fmt.Sprintf("%s/%d", ip.String(), prefixLen)
		cidrs = append(cidrs, cidr)

		// Move to next block
		current.Add(current, blockSize)
	}

	return cidrs, nil
}
