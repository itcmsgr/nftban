// =============================================================================
// NFTBan - CIDR Merging Utilities
// =============================================================================
// SPDX-License-Identifier: GPL-3.0-or-later
// meta:name="cidr"
// meta:type="go"
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

package sync

import (
	"encoding/binary"
	"fmt"
	"math/big"
	"net"
	"sort"
)

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

// MergeCIDRs merges overlapping and adjacent CIDRs (auto-detects IPv4/IPv6)
// Returns minimal CIDR set and statistics
func MergeCIDRs(cidrs []string) ([]string, *MergeStats, error) {
	if len(cidrs) == 0 {
		return nil, &MergeStats{}, nil
	}

	// Separate IPv4 and IPv6 CIDRs
	ipv4Cidrs := make([]string, 0)
	ipv6Cidrs := make([]string, 0)

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
		hostBits := uint32(bits - ones)
		end := start + (1 << hostBits) - 1

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
		if next.Start <= current.End+1 {
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
	result := make([]string, 0)
	for _, interval := range merged {
		cidrs := rangeToCIDRsIPv4(interval.Start, interval.End)
		result = append(result, cidrs...)
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
	result := make([]string, 0)
	for _, interval := range merged {
		cidrs := rangeToCIDRsIPv6(interval.Start, interval.End)
		result = append(result, cidrs...)
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
func rangeToCIDRsIPv4(start, end uint32) []string {
	cidrs := make([]string, 0)

	for start <= end {
		// Find the largest prefix that fits within [start, end]
		maxPrefixLen := uint32(32)

		// Find trailing zeros in start (determines max CIDR size)
		for i := uint32(0); i < 32; i++ {
			if (start & (1 << i)) != 0 {
				maxPrefixLen = i
				break
			}
		}

		// Calculate max block size that fits in range
		rangeSize := end - start + 1
		blockSize := uint32(1) << maxPrefixLen

		// Don't exceed remaining range
		for blockSize > rangeSize {
			maxPrefixLen--
			blockSize = 1 << maxPrefixLen
		}

		// Create CIDR
		ip := uint32ToIP(start)
		prefixLen := 32 - maxPrefixLen
		cidr := fmt.Sprintf("%s/%d", ip.String(), prefixLen)
		cidrs = append(cidrs, cidr)

		// Move to next block
		start += blockSize
	}

	return cidrs
}

// rangeToCIDRsIPv6 converts an IPv6 range [start, end] to minimal CIDR set
func rangeToCIDRsIPv6(start, end *big.Int) []string {
	cidrs := make([]string, 0)

	current := new(big.Int).Set(start)
	one := big.NewInt(1)

	for current.Cmp(end) <= 0 {
		// Find the largest prefix that fits within [current, end]
		maxPrefixLen := 128

		// Find trailing zeros in current (determines max CIDR size)
		temp := new(big.Int).Set(current)
		for i := 0; i < 128; i++ {
			if temp.Bit(i) != 0 {
				maxPrefixLen = i
				break
			}
		}

		// Calculate max block size that fits in range
		rangeSize := new(big.Int).Sub(end, current)
		rangeSize.Add(rangeSize, one) // +1 because range is inclusive

		blockSize := new(big.Int).Lsh(one, uint(maxPrefixLen))

		// Don't exceed remaining range
		for blockSize.Cmp(rangeSize) > 0 && maxPrefixLen > 0 {
			maxPrefixLen--
			blockSize = new(big.Int).Lsh(one, uint(maxPrefixLen))
		}

		// Create CIDR
		ip := bigIntToIPv6(current)
		prefixLen := 128 - maxPrefixLen
		cidr := fmt.Sprintf("%s/%d", ip.String(), prefixLen)
		cidrs = append(cidrs, cidr)

		// Move to next block
		current.Add(current, blockSize)
	}

	return cidrs
}
