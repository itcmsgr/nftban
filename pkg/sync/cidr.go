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

//nolint:U1000 // Alternative CIDR merge implementation

// mergeCIDRsIPv4WithStats handles IPv4 CIDR merging with statistics

//nolint:U1000 // Alternative CIDR merge implementation

// mergeCIDRsIPv6WithStats handles IPv6 CIDR merging with statistics

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

//nolint:U1000 // Helper function for range-to-CIDR conversion

// rangeToCIDRsIPv6 converts an IPv6 range to minimal set of CIDRs
