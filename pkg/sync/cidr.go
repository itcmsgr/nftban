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
	InputCIDRs    int // Number of input CIDRs
	OutputRanges  int // Number of output ranges after merging
	OverlapsMerged int // Number of overlaps/duplicates that were merged
	ReductionPct  float64 // Percentage reduction in entries
}

// MergeCIDRs takes a list of CIDR strings and returns a canonical, non-overlapping list
// This function merges overlapping and adjacent ranges to minimize the number of intervals
func MergeCIDRs(cidrs []string, ipv4 bool) ([]string, error) {
	if len(cidrs) == 0 {
		return []string{}, nil
	}

	if ipv4 {
		result, _, err := mergeCIDRsIPv4WithStats(cidrs)
		return result, err
	}
	result, _, err := mergeCIDRsIPv6WithStats(cidrs)
	return result, err
}

// MergeCIDRsWithStats is like MergeCIDRs but also returns merge statistics
func MergeCIDRsWithStats(cidrs []string, ipv4 bool) ([]string, *MergeStats, error) {
	if len(cidrs) == 0 {
		return []string{}, &MergeStats{}, nil
	}

	if ipv4 {
		return mergeCIDRsIPv4WithStats(cidrs)
	}
	return mergeCIDRsIPv6WithStats(cidrs)
}

// mergeCIDRsIPv4 handles IPv4 CIDR merging
func mergeCIDRsIPv4(cidrs []string) ([]string, error) {
	intervals := make([]ipv4Interval, 0, len(cidrs))

	// Convert CIDRs to intervals
	for _, cidr := range cidrs {
		_, ipNet, err := net.ParseCIDR(cidr)
		if err != nil {
			return nil, fmt.Errorf("invalid CIDR %s: %w", cidr, err)
		}

		start := ipToUint32(ipNet.IP)
		ones, bits := ipNet.Mask.Size()
		hostBits := bits - ones
		rangeSize := uint32(1) << uint(hostBits)
		end := start + rangeSize - 1

		intervals = append(intervals, ipv4Interval{Start: start, End: end})
	}

	// Sort by start, then by end
	sort.Slice(intervals, func(i, j int) bool {
		if intervals[i].Start == intervals[j].Start {
			return intervals[i].End < intervals[j].End
		}
		return intervals[i].Start < intervals[j].Start
	})

	// Merge overlapping/adjacent intervals
	merged := make([]ipv4Interval, 0, len(intervals))
	for _, cur := range intervals {
		if len(merged) == 0 {
			merged = append(merged, cur)
			continue
		}

		last := &merged[len(merged)-1]
		// Check if current overlaps or is adjacent to last
		if cur.Start <= last.End+1 {
			// Merge: extend last interval if needed
			if cur.End > last.End {
				last.End = cur.End
			}
			// else: cur is fully contained in last, skip it
		} else {
			// No overlap, add as new interval
			merged = append(merged, cur)
		}
	}

	// Convert merged intervals back to range notation (simpler and more memory-efficient)
	result := make([]string, 0, len(merged))
	for _, interval := range merged {
		// Convert to IP range format: start-end
		startIP := uint32ToIP(interval.Start)
		endIP := uint32ToIP(interval.End)

		// Use range format (nftables supports this in interval sets)
		result = append(result, fmt.Sprintf("%s-%s", startIP.String(), endIP.String()))
	}

	return result, nil
}

// mergeCIDRsIPv4WithStats handles IPv4 CIDR merging with statistics
func mergeCIDRsIPv4WithStats(cidrs []string) ([]string, *MergeStats, error) {
	inputCount := len(cidrs)
	intervals := make([]ipv4Interval, 0, len(cidrs))

	// Convert CIDRs to intervals
	for _, cidr := range cidrs {
		_, ipNet, err := net.ParseCIDR(cidr)
		if err != nil {
			return nil, nil, fmt.Errorf("invalid CIDR %s: %w", cidr, err)
		}

		start := ipToUint32(ipNet.IP)
		ones, bits := ipNet.Mask.Size()
		hostBits := bits - ones
		rangeSize := uint32(1) << uint(hostBits)
		end := start + rangeSize - 1

		intervals = append(intervals, ipv4Interval{Start: start, End: end})
	}

	// Sort by start, then by end
	sort.Slice(intervals, func(i, j int) bool {
		if intervals[i].Start == intervals[j].Start {
			return intervals[i].End < intervals[j].End
		}
		return intervals[i].Start < intervals[j].Start
	})

	// Merge overlapping/adjacent intervals
	merged := make([]ipv4Interval, 0, len(intervals))
	for _, cur := range intervals {
		if len(merged) == 0 {
			merged = append(merged, cur)
			continue
		}

		last := &merged[len(merged)-1]
		// Check if current overlaps or is adjacent to last
		if cur.Start <= last.End+1 {
			// Merge: extend last interval if needed
			if cur.End > last.End {
				last.End = cur.End
			}
			// else: cur is fully contained in last, skip it
		} else {
			// No overlap, add as new interval
			merged = append(merged, cur)
		}
	}

	// Convert merged intervals back to range notation
	result := make([]string, 0, len(merged))
	for _, interval := range merged {
		startIP := uint32ToIP(interval.Start)
		endIP := uint32ToIP(interval.End)
		result = append(result, fmt.Sprintf("%s-%s", startIP.String(), endIP.String()))
	}

	// Calculate statistics
	outputCount := len(result)
	overlaps := inputCount - outputCount
	var reductionPct float64
	if inputCount > 0 {
		reductionPct = float64(overlaps) / float64(inputCount) * 100.0
	}

	stats := &MergeStats{
		InputCIDRs:    inputCount,
		OutputRanges:  outputCount,
		OverlapsMerged: overlaps,
		ReductionPct:  reductionPct,
	}

	return result, stats, nil
}

// mergeCIDRsIPv6 handles IPv6 CIDR merging
func mergeCIDRsIPv6(cidrs []string) ([]string, error) {
	intervals := make([]ipv6Interval, 0, len(cidrs))

	// Reuse big.Int objects to reduce allocations
	one := big.NewInt(1)
	rangeSizeTmp := new(big.Int)

	// Convert CIDRs to intervals
	for _, cidr := range cidrs {
		_, ipNet, err := net.ParseCIDR(cidr)
		if err != nil {
			return nil, fmt.Errorf("invalid CIDR %s: %w", cidr, err)
		}

		start := ipv6ToBigInt(ipNet.IP)
		ones, bits := ipNet.Mask.Size()
		hostBits := bits - ones

		// Reuse rangeSizeTmp instead of allocating new big.Int
		rangeSize := rangeSizeTmp.Lsh(one, uint(hostBits))

		// Create new big.Int for end (needs to persist in intervals slice)
		end := new(big.Int).Add(start, rangeSize)
		end.Sub(end, one)

		intervals = append(intervals, ipv6Interval{Start: start, End: end})
	}

	// Sort by start, then by end
	sort.Slice(intervals, func(i, j int) bool {
		cmpStart := intervals[i].Start.Cmp(intervals[j].Start)
		if cmpStart == 0 {
			return intervals[i].End.Cmp(intervals[j].End) < 0
		}
		return cmpStart < 0
	})

	// Merge overlapping/adjacent intervals
	merged := make([]ipv6Interval, 0, len(intervals))
	for _, cur := range intervals {
		if len(merged) == 0 {
			merged = append(merged, cur)
			continue
		}

		last := &merged[len(merged)-1]
		// Check if current overlaps or is adjacent to last
		nextStart := new(big.Int).Add(last.End, big.NewInt(1))
		if cur.Start.Cmp(nextStart) <= 0 {
			// Merge: extend last interval if needed
			if cur.End.Cmp(last.End) > 0 {
				last.End = cur.End
			}
		} else {
			// No overlap, add as new interval
			merged = append(merged, cur)
		}
	}

	// Convert merged intervals back to CIDR notation
	result := make([]string, 0, len(merged))
	for _, interval := range merged {
		startIP := bigIntToIPv6(interval.Start)
		endIP := bigIntToIPv6(interval.End)

		cidrs := rangeToCIDRsIPv6(startIP, endIP)
		result = append(result, cidrs...)
	}

	return result, nil
}

// mergeCIDRsIPv6WithStats handles IPv6 CIDR merging with statistics
func mergeCIDRsIPv6WithStats(cidrs []string) ([]string, *MergeStats, error) {
	inputCount := len(cidrs)
	intervals := make([]ipv6Interval, 0, len(cidrs))

	// Reuse big.Int objects to reduce allocations
	one := big.NewInt(1)
	rangeSizeTmp := new(big.Int)

	// Convert CIDRs to intervals
	for _, cidr := range cidrs {
		_, ipNet, err := net.ParseCIDR(cidr)
		if err != nil {
			return nil, nil, fmt.Errorf("invalid CIDR %s: %w", cidr, err)
		}

		start := ipv6ToBigInt(ipNet.IP)
		ones, bits := ipNet.Mask.Size()
		hostBits := bits - ones

		// Reuse rangeSizeTmp instead of allocating new big.Int
		rangeSize := rangeSizeTmp.Lsh(one, uint(hostBits))

		// Create new big.Int for end (needs to persist in intervals slice)
		end := new(big.Int).Add(start, rangeSize)
		end.Sub(end, one)

		intervals = append(intervals, ipv6Interval{Start: start, End: end})
	}

	// Sort by start, then by end
	sort.Slice(intervals, func(i, j int) bool {
		cmpStart := intervals[i].Start.Cmp(intervals[j].Start)
		if cmpStart == 0 {
			return intervals[i].End.Cmp(intervals[j].End) < 0
		}
		return cmpStart < 0
	})

	// Merge overlapping/adjacent intervals
	merged := make([]ipv6Interval, 0, len(intervals))
	for _, cur := range intervals {
		if len(merged) == 0 {
			merged = append(merged, cur)
			continue
		}

		last := &merged[len(merged)-1]
		// Check if current overlaps or is adjacent to last
		nextStart := new(big.Int).Add(last.End, big.NewInt(1))
		if cur.Start.Cmp(nextStart) <= 0 {
			// Merge: extend last interval if needed
			if cur.End.Cmp(last.End) > 0 {
				last.End = cur.End
			}
		} else {
			// No overlap, add as new interval
			merged = append(merged, cur)
		}
	}

	// Convert merged intervals back to CIDR notation
	result := make([]string, 0, len(merged))
	for _, interval := range merged {
		startIP := bigIntToIPv6(interval.Start)
		endIP := bigIntToIPv6(interval.End)

		cidrs := rangeToCIDRsIPv6(startIP, endIP)
		result = append(result, cidrs...)
	}

	// Calculate statistics
	outputCount := len(result)
	overlaps := inputCount - outputCount
	var reductionPct float64
	if inputCount > 0 {
		reductionPct = float64(overlaps) / float64(inputCount) * 100.0
	}

	stats := &MergeStats{
		InputCIDRs:    inputCount,
		OutputRanges:  outputCount,
		OverlapsMerged: overlaps,
		ReductionPct:  reductionPct,
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

// rangeToCIDRs converts an IPv4 range to minimal set of CIDRs
func rangeToCIDRs(start, end net.IP) []string {
	startInt := ipToUint32(start)
	endInt := ipToUint32(end)

	var result []string
	for startInt <= endInt {
		// Find the largest CIDR block starting at startInt that fits in the range
		maxSize := uint32(32)

		// Find trailing zeros in startInt (determines alignment)
		if startInt != 0 {
			tzeros := uint32(0)
			for i := uint32(0); i < 32; i++ {
				if (startInt & (1 << i)) != 0 {
					tzeros = i
					break
				}
			}
			maxSize = tzeros + 1
		}

		// Find the largest prefix that fits in remaining range
		remaining := endInt - startInt + 1
		for prefixLen := uint32(0); prefixLen < 32; prefixLen++ {
			blockSize := uint32(1) << (32 - prefixLen)
			if blockSize <= remaining && prefixLen <= maxSize {
				maxSize = prefixLen
			}
		}

		// Create CIDR with this prefix length
		prefixLen := 32 - maxSize
		if prefixLen < 0 {
			prefixLen = 0
		}

		cidr := fmt.Sprintf("%s/%d", uint32ToIP(startInt).String(), prefixLen)
		result = append(result, cidr)

		// Move to next block
		blockSize := uint32(1) << maxSize
		if startInt > 0xFFFFFFFF-blockSize {
			break // Avoid overflow
		}
		startInt += blockSize
	}

	return result
}

// rangeToCIDRsIPv6 converts an IPv6 range to minimal set of CIDRs
func rangeToCIDRsIPv6(start, end net.IP) []string {
	// For simplicity, just return the original as a range
	// A full implementation would split into minimal CIDRs
	// This is a simplified version
	startInt := ipv6ToBigInt(start)
	endInt := ipv6ToBigInt(end)

	// Check if it's exactly a CIDR block
	rangeSize := new(big.Int).Sub(endInt, startInt)
	rangeSize.Add(rangeSize, big.NewInt(1))

	// Find if rangeSize is a power of 2
	if rangeSize.BitLen() > 0 {
		// Simple case: return as single range
		// TODO: Implement proper CIDR splitting for IPv6
		return []string{fmt.Sprintf("%s-%s", start.String(), end.String())}
	}

	return []string{start.String() + "/128"}
}
