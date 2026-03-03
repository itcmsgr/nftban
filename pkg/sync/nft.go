// =============================================================================
// NFTBan - NFTables Manager
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nft"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2025-10-26"
// meta:description="NFTables operations via netlink with interval set and CIDR support"
// meta:input="IP addresses, CIDR ranges"
// meta:output="NFTables set modifications"
// meta:depends="github.com/google/nftables"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package sync

import (
	"encoding/binary"
	"fmt"
	"log"
	"net"
	"os"
	"regexp"
	"strings"
	"time"

	"github.com/google/nftables"
	"github.com/google/nftables/expr"
	"github.com/itcmsgr/nftban/pkg/safety"
)

// =============================================================================
// IPv4 Helper Functions for Range-Aware Operations
// =============================================================================

// ipv4ToUint32 converts an IPv4 address to uint32 for arithmetic operations
func ipv4ToUint32(ip net.IP) (uint32, error) {
	v4 := ip.To4()
	if v4 == nil {
		return 0, fmt.Errorf("not an IPv4 address: %v", ip)
	}
	return binary.BigEndian.Uint32(v4), nil
}

// uint32ToIPv4 converts uint32 back to an IPv4 address
func uint32ToIPv4(v uint32) net.IP {
	b := make([]byte, 4)
	binary.BigEndian.PutUint32(b, v)
	return net.IP(b)
}

// =============================================================================
// IPv6 Helper Functions for Range-Aware Operations
// =============================================================================

// ipv6ToBytes16 converts an IPv6 address to a [16]byte for comparison/arithmetic
func ipv6ToBytes16(ip net.IP) ([16]byte, error) {
	v6 := ip.To16()
	if v6 == nil {
		return [16]byte{}, fmt.Errorf("not a valid IP address: %v", ip)
	}
	var b [16]byte
	copy(b[:], v6)
	return b, nil
}

// bytes16ToIPv6 converts a [16]byte back to a net.IP
func bytes16ToIPv6(b [16]byte) net.IP {
	ip := make(net.IP, 16)
	copy(ip, b[:])
	return ip
}

// ipv6Compare returns -1 if a < b, 0 if a == b, 1 if a > b
func ipv6Compare(a, b [16]byte) int {
	for i := 0; i < 16; i++ {
		if a[i] < b[i] {
			return -1
		}
		if a[i] > b[i] {
			return 1
		}
	}
	return 0
}

// ipv6Inc increments an IPv6 address by 1 (returns new value)
func ipv6Inc(a [16]byte) [16]byte {
	var result [16]byte
	copy(result[:], a[:])
	for i := 15; i >= 0; i-- {
		result[i]++
		if result[i] != 0 {
			break // no carry
		}
	}
	return result
}

// ipv6Dec decrements an IPv6 address by 1 (returns new value)
func ipv6Dec(a [16]byte) [16]byte {
	var result [16]byte
	copy(result[:], a[:])
	for i := 15; i >= 0; i-- {
		if result[i] > 0 {
			result[i]--
			break // no borrow
		}
		result[i] = 0xff // borrow
	}
	return result
}

// IPRange6 represents a range of IPv6 addresses in an interval set
type IPRange6 struct {
	Start [16]byte
	End   [16]byte
}

// isIPv6 returns true if the IP is IPv6 (and not IPv4-mapped)
func isIPv6(ip net.IP) bool {
	return ip.To4() == nil && ip.To16() != nil
}

// NFTManager handles nftables operations via netlink
type NFTManager struct {
	conn *nftables.Conn

	// Cached tables to avoid repeated ListTables() calls
	cachedTables map[nftables.TableFamily]*nftables.Table
}

// NewNFTManager creates a new nftables manager
func NewNFTManager() (*NFTManager, error) {
	conn, err := nftables.New()
	if err != nil {
		return nil, fmt.Errorf("failed to create nftables connection: %w", err)
	}

	return &NFTManager{
		conn:         conn,
		cachedTables: make(map[nftables.TableFamily]*nftables.Table),
	}, nil
}

// Close closes the nftables connection
func (m *NFTManager) Close() {
	// Connection cleanup handled by Go GC
}

// GetOrCreateTable gets or creates the nftban table
// Uses caching to avoid repeated ListTables() calls for performance
func (m *NFTManager) GetOrCreateTable(family nftables.TableFamily) (*nftables.Table, error) {
	// Check cache first
	if cached, ok := m.cachedTables[family]; ok {
		return cached, nil
	}

	// Try to get existing table
	tables, err := m.conn.ListTables()
	if err != nil {
		return nil, fmt.Errorf("failed to list tables: %w", err)
	}

	for _, table := range tables {
		if table.Name == "nftban" && table.Family == family {
			m.cachedTables[family] = table // Cache it
			return table, nil
		}
	}

	// Create new table
	table := m.conn.AddTable(&nftables.Table{
		Family: family,
		Name:   "nftban",
	})

	if err := m.conn.Flush(); err != nil {
		return nil, fmt.Errorf("failed to create table: %w", err)
	}

	m.cachedTables[family] = table // Cache newly created table
	return table, nil
}

// InvalidateTableCache clears the table cache (use after external table changes)
func (m *NFTManager) InvalidateTableCache() {
	m.cachedTables = make(map[nftables.TableFamily]*nftables.Table)
}

// GetOrCreateSet gets or creates a named set in the table
func (m *NFTManager) GetOrCreateSet(table *nftables.Table, setName string, ipv4 bool) (*nftables.Set, error) {
	// Try to get existing set
	sets, err := m.conn.GetSets(table)
	if err != nil {
		return nil, fmt.Errorf("failed to list sets: %w", err)
	}

	for _, set := range sets {
		if set.Name == setName {
			return set, nil
		}
	}

	// Determine key type based on IPv4/IPv6
	var keyType nftables.SetDatatype
	if ipv4 {
		keyType = nftables.TypeIPAddr // IPv4
	} else {
		keyType = nftables.TypeIP6Addr // IPv6
	}

	// Create new set
	set := &nftables.Set{
		Table:   table,
		Name:    setName,
		KeyType: keyType,
	}

	if err := m.conn.AddSet(set, nil); err != nil {
		return nil, fmt.Errorf("failed to add set: %w", err)
	}

	if err := m.conn.Flush(); err != nil {
		return nil, fmt.Errorf("failed to create set: %w", err)
	}

	return set, nil
}

// GetOrCreateIntervalSet gets or creates an interval set for CIDR ranges
func (m *NFTManager) GetOrCreateIntervalSet(table *nftables.Table, setName string, ipv4 bool) (*nftables.Set, error) {
	// Try to get existing set
	sets, err := m.conn.GetSets(table)
	if err != nil {
		return nil, fmt.Errorf("failed to list sets: %w", err)
	}

	for _, set := range sets {
		if set.Name == setName {
			return set, nil
		}
	}

	// Determine table family and IP type
	var family, ipType string
	var keyType nftables.SetDatatype
	if ipv4 {
		family = "ip"
		ipType = "ipv4_addr"
		keyType = nftables.TypeIPAddr
	} else {
		family = "ip6"
		ipType = "ipv6_addr"
		keyType = nftables.TypeIP6Addr
	}

	// Create interval set using nft CLI with auto-merge
	// auto-merge supported since nftables 0.9.0 (tested on 1.0.9)
	// This allows nftables kernel to merge overlapping ranges efficiently
	setDef := fmt.Sprintf("{ type %s ; flags interval , timeout ; auto-merge ; }", ipType)
	if err := nftAddSet(family, table.Name, setName, setDef); err != nil {
		return nil, fmt.Errorf("failed to create interval set: %w", err)
	}

	// Return set object for compatibility
	set := &nftables.Set{
		Table:    table,
		Name:     setName,
		Interval: true,
		KeyType:  keyType,
	}

	return set, nil
}

// GetSetElements retrieves all elements from a set
func (m *NFTManager) GetSetElements(set *nftables.Set) ([]string, error) {
	elements, err := m.conn.GetSetElements(set)
	if err != nil {
		return nil, fmt.Errorf("failed to get set elements: %w", err)
	}

	ips := make([]string, 0, len(elements)) // Pre-allocate to avoid reallocations
	for _, elem := range elements {
		// Parse IP from element key
		ip := net.IP(elem.Key)
		if ip != nil {
			ips = append(ips, ip.String())
		}
	}

	return ips, nil
}

// AddSetElements adds IPs to a set (batch operation with chunking)
// Processes in batches of 10000 IPs to avoid netlink message size limits
func (m *NFTManager) AddSetElements(set *nftables.Set, ips []string) error {
	if len(ips) == 0 {
		return nil
	}

	// For interval sets, use nft CLI (netlink doesn't handle CIDR intervals well)
	if set.Interval {
		return m.addSetElementsCLI(set, ips)
	}

	// Process in chunks to avoid "message too long" error
	const batchSize = 10000
	for i := 0; i < len(ips); i += batchSize {
		end := i + batchSize
		if end > len(ips) {
			end = len(ips)
		}

		batch := ips[i:end]
		if err := m.addSetElementsBatch(set, batch); err != nil {
			return fmt.Errorf("failed to add batch %d-%d: %w", i, end, err)
		}
	}

	return nil
}

// addSetElementsCLI adds IPs/CIDRs to an interval set using nft CLI
// This is necessary because netlink library doesn't properly handle CIDR intervals
// Uses batching to avoid "argument list too long" errors with large IP lists
func (m *NFTManager) addSetElementsCLI(set *nftables.Set, ips []string) error {
	if len(ips) == 0 {
		return nil
	}

	// Determine table family
	family := nftFamily(set.Table.Family == nftables.TableFamilyIPv4)

	// Use centralized batch add (1000 elements per batch)
	return nftAddElementsBatch(family, set.Table.Name, set.Name, ips, 1000)
}

// deleteSetElementsCLI deletes IPs/CIDRs from an interval set using nft CLI
// Uses batching to avoid "argument list too long" errors with large IP lists
func (m *NFTManager) deleteSetElementsCLI(set *nftables.Set, ips []string) error {
	if len(ips) == 0 {
		return nil
	}

	// Determine table family
	family := nftFamily(set.Table.Family == nftables.TableFamilyIPv4)

	// Use centralized batch delete (1000 elements per batch)
	return nftDeleteElementsBatch(family, set.Table.Name, set.Name, ips, 1000)
}

// =============================================================================
// Range-Aware Unban for Interval Sets with Auto-Merge
// =============================================================================

// IPRange represents a range of IPs in an interval set
type IPRange struct {
	Start uint32
	End   uint32
}

// DeleteFromIntervalSetCLI removes a single IP from an interval set, handling merged ranges.
// If the IP is inside a merged range (e.g., 7.7.7.7 inside 7.7.7.0-8.8.8.0), it will:
// 1. Delete the containing range
// 2. Re-add the sub-ranges before and after the IP
//
// This works correctly with nftables auto-merge interval sets.
func (m *NFTManager) DeleteFromIntervalSetCLI(set *nftables.Set, ipStr string) error {
	// Parse the IP
	ip := net.ParseIP(ipStr)
	if ip == nil {
		return fmt.Errorf("invalid IP: %s", ipStr)
	}

	// Determine table family
	var family string
	if set.Table.Family == nftables.TableFamilyIPv4 {
		family = "ip"
	} else {
		family = "ip6"
	}

	// Step 1: Get current set elements using nft list
	output, err := nftListSetWithHandles(family, set.Table.Name, set.Name)
	if err != nil {
		return fmt.Errorf("failed to list set: %w", err)
	}

	// Branch: IPv6 path vs IPv4 path
	if isIPv6(ip) {
		return m.deleteFromIntervalSetIPv6(set, family, output, ipStr, ip)
	}

	// IPv4 path
	ipVal, err := ipv4ToUint32(ip)
	if err != nil {
		return fmt.Errorf("IP conversion failed: %w", err)
	}

	// Step 2: Parse elements to find the containing range
	containingRange, exactMatch, err := m.findContainingRange(output, ipStr, ipVal)
	if err != nil {
		return err
	}

	// Step 3: If exact match, simple delete
	if exactMatch {
		err := nftDeleteElement(family, set.Table.Name, set.Name, "{ "+ipStr+" }")
		if err == nil {
			return nil // Successfully deleted as exact element
		}
		// If it fails, element might be merged - continue to range splitting
	}

	// Step 4: If inside a range, need to split
	if containingRange != nil {
		return m.splitRangeAndRemoveIP(set, family, containingRange, ipVal)
	}

	// IP not found in set
	return fmt.Errorf("IP %s not found in set %s", ipStr, set.Name)
}

// deleteFromIntervalSetIPv6 handles IPv6 range-aware deletion
func (m *NFTManager) deleteFromIntervalSetIPv6(set *nftables.Set, family, output, ipStr string, ip net.IP) error {
	ipVal, err := ipv6ToBytes16(ip)
	if err != nil {
		return fmt.Errorf("IPv6 conversion failed: %w", err)
	}

	// Check for exact match first
	if strings.Contains(output, ipStr+",") || strings.Contains(output, ipStr+"}") ||
		strings.Contains(output, ", "+ipStr+",") || strings.Contains(output, "{ "+ipStr+",") {
		err := nftDeleteElement(family, set.Table.Name, set.Name, "{ "+ipStr+" }")
		if err == nil {
			return nil
		}
		// If it fails, element might be merged - continue to range splitting
	}

	// Parse IPv6 ranges — pattern: addr6-addr6
	// IPv6 addresses contain colons, ranges use dash separator
	// nft output example: 2001:db8::1-2001:db8::ff
	ipv6RangePattern := regexp.MustCompile(`([0-9a-fA-F:]+)-([0-9a-fA-F:]+)`)
	matches := ipv6RangePattern.FindAllStringSubmatch(output, -1)

	for _, match := range matches {
		if len(match) != 3 {
			continue
		}
		startIP := net.ParseIP(match[1])
		endIP := net.ParseIP(match[2])
		if startIP == nil || endIP == nil || !isIPv6(startIP) || !isIPv6(endIP) {
			continue
		}

		startVal, err1 := ipv6ToBytes16(startIP)
		endVal, err2 := ipv6ToBytes16(endIP)
		if err1 != nil || err2 != nil {
			continue
		}

		// Check if ipVal is within this range
		if ipv6Compare(startVal, ipVal) <= 0 && ipv6Compare(ipVal, endVal) <= 0 {
			containingRange := &IPRange6{Start: startVal, End: endVal}
			return m.splitRangeAndRemoveIPv6(set, family, containingRange, ipVal)
		}
	}

	// Try direct delete (may work if element is not inside a merged range)
	err = nftDeleteElement(family, set.Table.Name, set.Name, "{ "+ipStr+" }")
	if err == nil {
		return nil
	}

	// Fallback: full set refresh
	return m.fullSetRefreshExcludingIP6(set, family, ipStr, ipVal)
}

// splitRangeAndRemoveIPv6 splits an IPv6 range around the IP being removed
func (m *NFTManager) splitRangeAndRemoveIPv6(set *nftables.Set, family string, r *IPRange6, ipVal [16]byte) error {
	startIP := bytes16ToIPv6(r.Start).String()
	endIP := bytes16ToIPv6(r.End).String()
	rangeStr := startIP + "-" + endIP

	err := nftDeleteElement(family, set.Table.Name, set.Name, "{ "+rangeStr+" }")
	if err != nil {
		// Range delete failed — use full-set-refresh approach
		return m.fullSetRefreshExcludingIP6(set, family, bytes16ToIPv6(ipVal).String(), ipVal)
	}

	// Re-add left sub-range (if IP is not at start)
	if ipv6Compare(r.Start, ipVal) < 0 {
		leftEnd := ipv6Dec(ipVal)
		var leftStr string
		if ipv6Compare(r.Start, leftEnd) == 0 {
			leftStr = bytes16ToIPv6(r.Start).String()
		} else {
			leftStr = bytes16ToIPv6(r.Start).String() + "-" + bytes16ToIPv6(leftEnd).String()
		}
		_ = nftAddElement(family, set.Table.Name, set.Name, "{ "+leftStr+" }")
	}

	// Re-add right sub-range (if IP is not at end)
	if ipv6Compare(ipVal, r.End) < 0 {
		rightStart := ipv6Inc(ipVal)
		var rightStr string
		if ipv6Compare(rightStart, r.End) == 0 {
			rightStr = bytes16ToIPv6(r.End).String()
		} else {
			rightStr = bytes16ToIPv6(rightStart).String() + "-" + bytes16ToIPv6(r.End).String()
		}
		_ = nftAddElement(family, set.Table.Name, set.Name, "{ "+rightStr+" }")
	}

	return nil
}

// fullSetRefreshExcludingIP6 flushes the set and re-adds all elements except the specified IPv6 address
func (m *NFTManager) fullSetRefreshExcludingIP6(set *nftables.Set, family, excludeIP string, excludeVal [16]byte) error {
	output, err := NftListSet(family, set.Table.Name, set.Name)
	if err != nil {
		return fmt.Errorf("failed to list set: %w", err)
	}

	elements := m.parseSetElements(output)
	if len(elements) == 0 {
		return nil
	}

	filteredElements := make([]string, 0, len(elements))
	for _, elem := range elements {
		if strings.Contains(elem, "-") {
			parts := strings.Split(elem, "-")
			if len(parts) != 2 {
				filteredElements = append(filteredElements, elem)
				continue
			}

			startIP := net.ParseIP(strings.TrimSpace(parts[0]))
			endIP := net.ParseIP(strings.TrimSpace(parts[1]))
			if startIP == nil || endIP == nil {
				filteredElements = append(filteredElements, elem)
				continue
			}

			startVal, err1 := ipv6ToBytes16(startIP)
			endVal, err2 := ipv6ToBytes16(endIP)
			if err1 != nil || err2 != nil {
				filteredElements = append(filteredElements, elem)
				continue
			}

			if ipv6Compare(excludeVal, startVal) < 0 || ipv6Compare(excludeVal, endVal) > 0 {
				// IP not in this range, keep it
				filteredElements = append(filteredElements, elem)
			} else {
				// IP is inside range — split it
				if ipv6Compare(startVal, excludeVal) < 0 {
					leftEnd := ipv6Dec(excludeVal)
					if ipv6Compare(startVal, leftEnd) == 0 {
						filteredElements = append(filteredElements, bytes16ToIPv6(startVal).String())
					} else {
						filteredElements = append(filteredElements, bytes16ToIPv6(startVal).String()+"-"+bytes16ToIPv6(leftEnd).String())
					}
				}
				if ipv6Compare(excludeVal, endVal) < 0 {
					rightStart := ipv6Inc(excludeVal)
					if ipv6Compare(rightStart, endVal) == 0 {
						filteredElements = append(filteredElements, bytes16ToIPv6(endVal).String())
					} else {
						filteredElements = append(filteredElements, bytes16ToIPv6(rightStart).String()+"-"+bytes16ToIPv6(endVal).String())
					}
				}
			}
		} else {
			if strings.TrimSpace(elem) != excludeIP {
				filteredElements = append(filteredElements, elem)
			}
		}
	}

	if err := nftFlushSet(family, set.Table.Name, set.Name); err != nil {
		return fmt.Errorf("failed to flush set: %w", err)
	}

	cleanElements := make([]string, 0, len(filteredElements))
	for _, elem := range filteredElements {
		elem = strings.TrimSpace(elem)
		if elem != "" {
			cleanElements = append(cleanElements, elem)
		}
	}

	if len(cleanElements) == 0 {
		return nil
	}

	if err := nftAddElementsBatch(family, set.Table.Name, set.Name, cleanElements, 500); err != nil {
		fmt.Fprintf(os.Stderr, "Warning: batch add partial failure: %v\n", err)
	}

	return nil
}

// findContainingRange parses nft list output and finds the range containing the IP
func (m *NFTManager) findContainingRange(output, ipStr string, ipVal uint32) (*IPRange, bool, error) {
	// Look for exact match first
	// nft output format: elements = { 1.2.3.4, 5.6.7.8-9.10.11.12, ... }
	if strings.Contains(output, ipStr+",") || strings.Contains(output, ipStr+"}") ||
		strings.Contains(output, ", "+ipStr+",") || strings.Contains(output, "{ "+ipStr+",") {
		return nil, true, nil
	}

	// Parse ranges - look for patterns like "A.B.C.D-W.X.Y.Z"
	// Example: 7.7.7.7-8.8.8.7
	rangePattern := regexp.MustCompile(`(\d+\.\d+\.\d+\.\d+)-(\d+\.\d+\.\d+\.\d+)`)
	matches := rangePattern.FindAllStringSubmatch(output, -1)

	for _, match := range matches {
		if len(match) != 3 {
			continue
		}

		startIP := net.ParseIP(match[1])
		endIP := net.ParseIP(match[2])
		if startIP == nil || endIP == nil {
			continue
		}

		startVal, err1 := ipv4ToUint32(startIP)
		endVal, err2 := ipv4ToUint32(endIP)
		if err1 != nil || err2 != nil {
			continue
		}

		// Check if ipVal is within this range
		if startVal <= ipVal && ipVal <= endVal {
			return &IPRange{Start: startVal, End: endVal}, false, nil
		}
	}

	return nil, false, nil
}

// splitRangeAndRemoveIP uses a full-set-refresh approach to remove an IP from a merged range.
// Due to nftables kernel auto-merge behavior, we can't reliably delete individual ranges.
// Instead, we:
// 1. Parse all current set elements
// 2. Flush the set
// 3. Re-add all elements EXCEPT the IP we want to remove (and its containing range, split)
func (m *NFTManager) splitRangeAndRemoveIP(set *nftables.Set, family string, r *IPRange, ipVal uint32) error {
	// First try direct range delete (works in some nftables versions)
	startIP := uint32ToIPv4(r.Start).String()
	endIP := uint32ToIPv4(r.End).String()
	rangeStr := startIP + "-" + endIP

	err := nftDeleteElement(family, set.Table.Name, set.Name, "{ "+rangeStr+" }")
	if err != nil {
		// Range delete failed - use full-set-refresh approach
		// This is the only reliable way to split merged ranges
		return m.fullSetRefreshExcludingIP(set, family, uint32ToIPv4(ipVal).String())
	}

	// Range delete succeeded - now re-add the sub-ranges
	// Step 2: Re-add left sub-range (if IP is not at start)
	if r.Start < ipVal {
		leftEnd := ipVal - 1
		var leftRangeStr string
		if r.Start == leftEnd {
			leftRangeStr = uint32ToIPv4(r.Start).String()
		} else {
			leftRangeStr = uint32ToIPv4(r.Start).String() + "-" + uint32ToIPv4(leftEnd).String()
		}

		// Ignore interval overlaps - already covered
		_ = nftAddElement(family, set.Table.Name, set.Name, "{ "+leftRangeStr+" }")
	}

	// Step 3: Re-add right sub-range (if IP is not at end)
	if ipVal < r.End {
		rightStart := ipVal + 1
		var rightRangeStr string
		if rightStart == r.End {
			rightRangeStr = uint32ToIPv4(r.End).String()
		} else {
			rightRangeStr = uint32ToIPv4(rightStart).String() + "-" + uint32ToIPv4(r.End).String()
		}

		// Ignore interval overlaps - already covered
		_ = nftAddElement(family, set.Table.Name, set.Name, "{ "+rightRangeStr+" }")
	}

	return nil
}

// fullSetRefreshExcludingIP flushes the set and re-adds all elements except the specified IP.
// This is the nuclear option when range splitting doesn't work due to kernel auto-merge.
func (m *NFTManager) fullSetRefreshExcludingIP(set *nftables.Set, family, excludeIP string) error {
	// Step 1: Get all current elements
	output, err := NftListSet(family, set.Table.Name, set.Name)
	if err != nil {
		return fmt.Errorf("failed to list set: %w", err)
	}

	// Step 2: Parse all elements (IPs and ranges)
	elements := m.parseSetElements(output)
	if len(elements) == 0 {
		return nil // Nothing to do
	}

	// Step 3: Filter out the IP to exclude
	filteredElements := make([]string, 0, len(elements)) // Pre-allocate
	excludeIPVal, err := ipv4ToUint32(net.ParseIP(excludeIP))
	if err != nil {
		return fmt.Errorf("invalid exclude IP: %s", excludeIP)
	}

	for _, elem := range elements {
		if strings.Contains(elem, "-") {
			// It's a range - check if excludeIP is inside
			parts := strings.Split(elem, "-")
			if len(parts) != 2 {
				filteredElements = append(filteredElements, elem)
				continue
			}

			startIP := net.ParseIP(strings.TrimSpace(parts[0]))
			endIP := net.ParseIP(strings.TrimSpace(parts[1]))
			if startIP == nil || endIP == nil {
				filteredElements = append(filteredElements, elem)
				continue
			}

			startVal, _ := ipv4ToUint32(startIP)
			endVal, _ := ipv4ToUint32(endIP)

			if excludeIPVal < startVal || excludeIPVal > endVal {
				// IP not in this range, keep it
				filteredElements = append(filteredElements, elem)
			} else {
				// IP is inside range - split it
				if startVal < excludeIPVal {
					// Left part
					if startVal == excludeIPVal-1 {
						filteredElements = append(filteredElements, uint32ToIPv4(startVal).String())
					} else {
						filteredElements = append(filteredElements, uint32ToIPv4(startVal).String()+"-"+uint32ToIPv4(excludeIPVal-1).String())
					}
				}
				if excludeIPVal < endVal {
					// Right part
					if excludeIPVal+1 == endVal {
						filteredElements = append(filteredElements, uint32ToIPv4(endVal).String())
					} else {
						filteredElements = append(filteredElements, uint32ToIPv4(excludeIPVal+1).String()+"-"+uint32ToIPv4(endVal).String())
					}
				}
			}
		} else {
			// Single IP
			if strings.TrimSpace(elem) != excludeIP {
				filteredElements = append(filteredElements, elem)
			}
		}
	}

	// Step 4: Flush the set
	if err := nftFlushSet(family, set.Table.Name, set.Name); err != nil {
		return fmt.Errorf("failed to flush set: %w", err)
	}

	// Step 5: Re-add filtered elements in batches
	// First, filter out any empty strings that may have crept in
	cleanElements := make([]string, 0, len(filteredElements)) // Pre-allocate
	for _, elem := range filteredElements {
		elem = strings.TrimSpace(elem)
		if elem != "" {
			cleanElements = append(cleanElements, elem)
		}
	}

	if len(cleanElements) == 0 {
		return nil // Nothing to add back
	}

	// Use centralized batch add (500 elements per batch for safety)
	if err := nftAddElementsBatch(family, set.Table.Name, set.Name, cleanElements, 500); err != nil {
		// Log but continue - partial success is better than full failure
		fmt.Fprintf(os.Stderr, "Warning: batch add partial failure: %v\n", err)
	}

	return nil
}

// parseSetElements extracts IP addresses and ranges from nft list output
func (m *NFTManager) parseSetElements(output string) []string {
	// Estimate capacity based on comma count (each element separated by comma)
	estimatedCap := strings.Count(output, ",") + 1
	if estimatedCap < 16 {
		estimatedCap = 16 // Minimum capacity
	}
	elements := make([]string, 0, estimatedCap)

	// Find the elements section
	elemStart := strings.Index(output, "elements = {")
	if elemStart == -1 {
		return elements
	}

	// Find closing brace
	elemEnd := strings.LastIndex(output, "}")
	if elemEnd == -1 || elemEnd <= elemStart {
		return elements
	}

	// Extract content between braces
	content := output[elemStart+len("elements = {") : elemEnd]

	// Split by comma and clean up
	parts := strings.Split(content, ",")
	for _, part := range parts {
		elem := strings.TrimSpace(part)
		// Skip empty or invalid entries
		if elem == "" {
			continue
		}
		// Remove timeout info like "timeout 1h expires 30m"
		if idx := strings.Index(elem, " timeout"); idx != -1 {
			elem = elem[:idx]
		}
		if idx := strings.Index(elem, " expires"); idx != -1 {
			elem = elem[:idx]
		}
		elem = strings.TrimSpace(elem)
		if elem != "" && (strings.Contains(elem, ".") || strings.Contains(elem, ":")) {
			elements = append(elements, elem)
		}
	}

	return elements
}

// addSetElementsBatch adds a single batch of IPs or CIDRs
func (m *NFTManager) addSetElementsBatch(set *nftables.Set, ips []string) error {
	elements := make([]nftables.SetElement, 0, len(ips)*2) // Pre-allocate (*2 for CIDR ranges)
	for _, ipStr := range ips {
		var key []byte

		// Check if this is a CIDR range or single IP
		if strings.Contains(ipStr, "/") {
			// CIDR notation - parse as network
			_, ipNet, err := net.ParseCIDR(ipStr)
			if err != nil {
				return fmt.Errorf("invalid CIDR: %s (%w)", ipStr, err)
			}

			// For interval sets, use the network address
			if set.KeyType == nftables.TypeIPAddr {
				// IPv4 CIDR
				if ipNet.IP.To4() == nil {
					return fmt.Errorf("CIDR %s is not IPv4", ipStr)
				}
				key = ipNet.IP.To4()
			} else {
				// IPv6 CIDR
				if ipNet.IP.To4() != nil {
					return fmt.Errorf("CIDR %s is not IPv6", ipStr)
				}
				key = ipNet.IP.To16()
			}

			// Add CIDR with mask
			elements = append(elements, nftables.SetElement{
				Key:         key,
				IntervalEnd: false,
			})

			// Calculate and add the interval end (broadcast address)
			broadcastIP := make(net.IP, len(ipNet.IP))
			copy(broadcastIP, ipNet.IP)
			for i := range broadcastIP {
				broadcastIP[i] |= ^ipNet.Mask[i]
			}

			var endKey []byte
			if set.KeyType == nftables.TypeIPAddr {
				endKey = broadcastIP.To4()
			} else {
				endKey = broadcastIP.To16()
			}

			// Increment by 1 for interval end
			for i := len(endKey) - 1; i >= 0; i-- {
				endKey[i]++
				if endKey[i] != 0 {
					break
				}
			}

			elements = append(elements, nftables.SetElement{
				Key:         endKey,
				IntervalEnd: true,
			})
		} else {
			// Single IP
			ip := net.ParseIP(ipStr)
			if ip == nil {
				return fmt.Errorf("invalid IP: %s", ipStr)
			}

			// Convert to appropriate format
			if set.KeyType == nftables.TypeIPAddr {
				// IPv4 - use To4()
				ip = ip.To4()
				if ip == nil {
					return fmt.Errorf("IP %s is not IPv4", ipStr)
				}
			} else {
				// IPv6 - use To16()
				ip = ip.To16()
				if ip == nil {
					return fmt.Errorf("IP %s is not IPv6", ipStr)
				}
			}

			elements = append(elements, nftables.SetElement{
				Key: ip,
			})
		}
	}

	if err := m.conn.SetAddElements(set, elements); err != nil {
		return fmt.Errorf("failed to add elements: %w", err)
	}

	if err := m.conn.Flush(); err != nil {
		return fmt.Errorf("failed to flush add elements: %w", err)
	}

	return nil
}

// AddIPWithTimeout adds a single IP to a set with optional timeout
// If timeout is 0, IP is added permanently
// If timeout > 0, IP will auto-expire after the specified duration
//
// IMPORTANT: For interval sets, uses nft CLI to avoid corrupted ranges.
// The netlink library doesn't properly handle interval markers for single IPs,
// which can cause corrupted ranges like "1.2.3.4-255.255.255.255".
func (m *NFTManager) AddIPWithTimeout(set *nftables.Set, ipStr string, timeout time.Duration) error {
	// Try parsing as single IP first
	ip := net.ParseIP(ipStr)

	// If single IP parsing fails, try CIDR notation
	var isCIDR bool
	if ip == nil {
		_, cidrNet, err := net.ParseCIDR(ipStr)
		if err != nil {
			return fmt.Errorf("invalid IP or CIDR: %s", ipStr)
		}
		// CIDR parsed successfully - extract base IP for validation
		ip = cidrNet.IP
		isCIDR = true
	}

	// Validate IP type matches set type
	if set.KeyType == nftables.TypeIPAddr {
		if ip.To4() == nil {
			return fmt.Errorf("IP %s is not IPv4", ipStr)
		}
	} else {
		if ip.To4() != nil {
			return fmt.Errorf("IP %s is not IPv6", ipStr)
		}
	}

	// For interval sets OR CIDR ranges, use nft CLI
	// The netlink library doesn't properly handle interval markers for single IPs
	// CIDR ranges require interval sets and must use CLI
	if set.Interval || isCIDR {
		return m.addIPWithTimeoutCLI(set, ipStr, timeout)
	}

	// Non-interval sets: use netlink directly
	var key []byte
	if set.KeyType == nftables.TypeIPAddr {
		key = ip.To4()
	} else {
		key = ip.To16()
	}

	element := nftables.SetElement{
		Key: key,
	}

	// Add timeout if specified
	if timeout > 0 {
		element.Timeout = timeout
	}

	if err := m.conn.SetAddElements(set, []nftables.SetElement{element}); err != nil {
		return fmt.Errorf("failed to add element: %w", err)
	}

	if err := m.conn.Flush(); err != nil {
		// Ignore "file exists" errors - element already in set
		if !strings.Contains(err.Error(), "file exists") && !strings.Contains(err.Error(), "exists") {
			return fmt.Errorf("failed to flush: %w", err)
		}
		// Element already exists - not an error
	}

	return nil
}

// addIPWithTimeoutCLI adds a single IP to an interval set using nft CLI
// This avoids the corrupted interval range bug in netlink library
func (m *NFTManager) addIPWithTimeoutCLI(set *nftables.Set, ipStr string, timeout time.Duration) error {
	// Determine table family
	family := nftFamily(set.Table.Family == nftables.TableFamilyIPv4)

	// Build element string with optional timeout
	var elementStr string
	if timeout > 0 {
		// Format: { IP timeout Xs }
		elementStr = fmt.Sprintf("{ %s timeout %ds }", ipStr, int(timeout.Seconds()))
	} else {
		elementStr = fmt.Sprintf("{ %s }", ipStr)
	}

	// Use centralized add element (ignores interval overlaps and file exists)
	return nftAddElement(family, set.Table.Name, set.Name, elementStr)
}

// DeleteSetElements removes IPs from a set (batch operation)
func (m *NFTManager) DeleteSetElements(set *nftables.Set, ips []string) error {
	if len(ips) == 0 {
		return nil
	}

	// Check if any IPs are CIDRs - if so, use CLI method
	hasCIDR := false
	for _, ipStr := range ips {
		if strings.Contains(ipStr, "/") {
			hasCIDR = true
			break
		}
	}

	// For interval sets or CIDR ranges, use nft CLI
	if set.Interval || hasCIDR {
		return m.deleteSetElementsCLI(set, ips)
	}

	elements := make([]nftables.SetElement, 0, len(ips)) // Pre-allocate
	for _, ipStr := range ips {
		ip := net.ParseIP(ipStr)
		if ip == nil {
			return fmt.Errorf("invalid IP: %s", ipStr)
		}

		// Convert to appropriate format
		if set.KeyType == nftables.TypeIPAddr {
			// IPv4
			ip = ip.To4()
			if ip == nil {
				return fmt.Errorf("IP %s is not IPv4", ipStr)
			}
		} else {
			// IPv6
			ip = ip.To16()
			if ip == nil {
				return fmt.Errorf("IP %s is not IPv6", ipStr)
			}
		}

		elements = append(elements, nftables.SetElement{
			Key: ip,
		})
	}

	if err := m.conn.SetDeleteElements(set, elements); err != nil {
		return fmt.Errorf("failed to delete elements: %w", err)
	}

	if err := m.conn.Flush(); err != nil {
		return fmt.Errorf("failed to flush delete elements: %w", err)
	}

	return nil
}

// FlushSet removes all elements from a set
func (m *NFTManager) FlushSet(set *nftables.Set) error {
	m.conn.FlushSet(set)
	return m.conn.Flush()
}

// CreateChainIfNotExists creates a chain if it doesn't exist
func (m *NFTManager) CreateChainIfNotExists(table *nftables.Table, chainName string, chainType nftables.ChainType, hook *nftables.ChainHook, priority *nftables.ChainPriority) (*nftables.Chain, error) {
	// Try to get existing chain
	chains, err := m.conn.ListChains()
	if err != nil {
		return nil, fmt.Errorf("failed to list chains: %w", err)
	}

	for _, chain := range chains {
		if chain.Name == chainName && chain.Table.Name == table.Name {
			return chain, nil
		}
	}

	// Create new chain
	chain := &nftables.Chain{
		Name:     chainName,
		Table:    table,
		Type:     chainType,
		Hooknum:  hook,
		Priority: priority,
	}

	m.conn.AddChain(chain)

	if err := m.conn.Flush(); err != nil {
		return nil, fmt.Errorf("failed to create chain: %w", err)
	}

	return chain, nil
}

// AddDropRuleForSet adds a rule to drop packets from IPs in a set
func (m *NFTManager) AddDropRuleForSet(chain *nftables.Chain, set *nftables.Set, ipv4 bool) error {
	// Build rule: ip saddr @blacklist_ipv4 drop
	var expressions []expr.Any

	if ipv4 {
		// Load IPv4 source address
		expressions = append(expressions,
			&expr.Payload{
				DestRegister: 1,
				Base:         expr.PayloadBaseNetworkHeader,
				Offset:       12, // IPv4 source address offset
				Len:          4,  // IPv4 address length
			},
		)
	} else {
		// Load IPv6 source address
		expressions = append(expressions,
			&expr.Payload{
				DestRegister: 1,
				Base:         expr.PayloadBaseNetworkHeader,
				Offset:       8,  // IPv6 source address offset
				Len:          16, // IPv6 address length
			},
		)
	}

	// Lookup in set
	expressions = append(expressions,
		&expr.Lookup{
			SourceRegister: 1,
			SetName:        set.Name,
			SetID:          set.ID,
		},
	)

	// Drop verdict
	expressions = append(expressions,
		&expr.Verdict{
			Kind: expr.VerdictDrop,
		},
	)

	// Add rule
	rule := &nftables.Rule{
		Table: chain.Table,
		Chain: chain,
		Exprs: expressions,
	}

	m.conn.AddRule(rule)

	if err := m.conn.Flush(); err != nil {
		return fmt.Errorf("failed to add drop rule: %w", err)
	}

	return nil
}

// GetSetCount returns the number of elements in a set
func (m *NFTManager) GetSetCount(set *nftables.Set) (int, error) {
	elements, err := m.conn.GetSetElements(set)
	if err != nil {
		return 0, fmt.Errorf("failed to get set elements: %w", err)
	}
	return len(elements), nil
}

// GetPortSet retrieves an existing port set without creating it
// Returns nil, nil if the set doesn't exist (not an error - idempotent behavior)
// Port sets use TypeInetService (uint16) for port numbers
func (m *NFTManager) GetPortSet(table *nftables.Table, setName string) (*nftables.Set, error) {
	sets, err := m.conn.GetSets(table)
	if err != nil {
		return nil, fmt.Errorf("failed to list sets: %w", err)
	}

	for _, set := range sets {
		if set.Name == setName {
			return set, nil
		}
	}

	// Set doesn't exist - return nil without error (idempotent)
	return nil, nil
}

// GetOrCreatePortSet creates or gets an existing port set for TCP or UDP
// Port sets use TypeInetService (uint16) for port numbers
func (m *NFTManager) GetOrCreatePortSet(table *nftables.Table, setName string) (*nftables.Set, error) {
	// Try to get existing set
	sets, err := m.conn.GetSets(table)
	if err != nil {
		return nil, fmt.Errorf("failed to list sets: %w", err)
	}

	for _, set := range sets {
		if set.Name == setName {
			return set, nil
		}
	}

	// Create new port set (uint16 for port numbers)
	set := &nftables.Set{
		Table:   table,
		Name:    setName,
		KeyType: nftables.TypeInetService, // uint16 for ports
	}

	if err := m.conn.AddSet(set, nil); err != nil {
		return nil, fmt.Errorf("failed to add port set: %w", err)
	}

	if err := m.conn.Flush(); err != nil {
		return nil, fmt.Errorf("failed to create port set: %w", err)
	}

	return set, nil
}

// AddPortElements adds port numbers to a port set
func (m *NFTManager) AddPortElements(set *nftables.Set, ports []int) error {
	if len(ports) == 0 {
		return nil
	}

	elements := make([]nftables.SetElement, 0, len(ports)) // Pre-allocate
	for _, port := range ports {
		// Validate port range
		if port < 1 || port > 65535 {
			return fmt.Errorf("invalid port number: %d (must be 1-65535)", port)
		}

		// Port numbers are uint16 in big-endian format
		portBytes := []byte{byte(port >> 8), byte(port & 0xff)}
		elements = append(elements, nftables.SetElement{
			Key: portBytes,
		})
	}

	if err := m.conn.SetAddElements(set, elements); err != nil {
		return fmt.Errorf("failed to add port elements: %w", err)
	}

	if err := m.conn.Flush(); err != nil {
		return fmt.Errorf("failed to flush port elements: %w", err)
	}

	return nil
}

// DeletePortElements removes port numbers from a port set
// Returns nil for "no such file" errors (idempotent - element already doesn't exist)
func (m *NFTManager) DeletePortElements(set *nftables.Set, ports []int) error {
	if len(ports) == 0 {
		return nil
	}

	elements := make([]nftables.SetElement, 0, len(ports)) // Pre-allocate
	for _, port := range ports {
		// Port numbers are uint16 in big-endian format
		portBytes := []byte{byte(port >> 8), byte(port & 0xff)}
		elements = append(elements, nftables.SetElement{
			Key: portBytes,
		})
	}

	if err := m.conn.SetDeleteElements(set, elements); err != nil {
		return fmt.Errorf("failed to delete port elements: %w", err)
	}

	if err := m.conn.Flush(); err != nil {
		// Tolerate "no such file" errors - element already doesn't exist (idempotent)
		errStr := err.Error()
		if strings.Contains(errStr, "no such file") ||
			strings.Contains(errStr, "does not exist") ||
			strings.Contains(errStr, "ENOENT") {
			return nil // Idempotent: element already gone
		}
		return fmt.Errorf("failed to flush port delete: %w", err)
	}

	return nil
}

// AddCIDRElements adds CIDR ranges to an interval set (batch operation with chunking)
// Uses nft command-line tool with a temporary file to avoid argument list limits
// Automatically canonicalizes and merges overlapping CIDRs before loading
func (m *NFTManager) AddCIDRElements(set *nftables.Set, cidrs []string) error {
	_, err := m.AddCIDRElementsWithStats(set, cidrs)
	return err
}

// AddCIDRElementsWithStats adds CIDR elements to an interval set and returns merge statistics
func (m *NFTManager) AddCIDRElementsWithStats(set *nftables.Set, cidrs []string) (*MergeStats, error) {
	if len(cidrs) == 0 {
		return &MergeStats{}, nil
	}

	// Determine table family
	var family string
	switch set.Table.Family {
	case nftables.TableFamilyIPv4:
		family = "ip"
	case nftables.TableFamilyIPv6:
		family = "ip6"
	default:
		return nil, fmt.Errorf("unsupported table family: %v", set.Table.Family)
	}

	// Step 1: Validate and deduplicate CIDRs
	inputCount := len(cidrs)
	seen := make(map[string]bool, len(cidrs))
	validCIDRs := make([]string, 0, len(cidrs)) // Pre-allocate to avoid reallocations

	// Parse and deduplicate CIDRs using standard net package
	for _, cidr := range cidrs {
		// Validate CIDR using standard library
		_, ipNet, err := net.ParseCIDR(cidr)
		if err != nil {
			// Skip invalid CIDRs
			continue
		}

		// Normalize to canonical form
		canonical := ipNet.String()
		if !seen[canonical] {
			seen[canonical] = true
			validCIDRs = append(validCIDRs, canonical)
		}
	}

	// Step 2: Merge overlapping and adjacent CIDRs using safe interval merging
	// MergeCIDRsSafe automatically filters problematic CIDRs (bogon ranges, oversized)
	canonicalCIDRs, stats, filterStats, err := MergeCIDRsSafe(validCIDRs)
	if err != nil {
		return nil, fmt.Errorf("failed to merge CIDRs: %w", err)
	}

	// Log if any CIDRs were filtered (important for troubleshooting feed issues)
	if filterStats != nil && filterStats.Filtered > 0 {
		log.Printf("[SYNC] CIDR filter: removed %d problematic entries (bogon=%d, oversized=%d) from %d total",
			filterStats.Filtered, filterStats.Bogon, filterStats.TooLarge, filterStats.Total)
		// Record filter stats for metrics export
		if err := safety.RecordFilterState(filterStats.Total, filterStats.Filtered,
			filterStats.Bogon, filterStats.TooLarge, filterStats.Kept); err != nil {
			log.Printf("[SYNC] Warning: Failed to record filter state: %v", err)
		}
	}

	// Update stats to reflect total reduction (including invalid/duplicate removal)
	stats.InputCIDRs = inputCount
	if inputCount > 0 {
		stats.OverlapsMerged = inputCount - len(canonicalCIDRs)
		stats.ReductionPct = float64(stats.OverlapsMerged) / float64(inputCount) * 100.0
	}

	// Flush the set first using nft CLI to avoid netlink stale connection issues
	if err := nftFlushSet(family, set.Table.Name, set.Name); err != nil {
		return nil, fmt.Errorf("failed to flush set: %w", err)
	}

	// Create temporary file for nft command
	tmpfile, err := os.CreateTemp("", "nftban-cidr-*.nft")
	if err != nil {
		return nil, fmt.Errorf("failed to create temp file: %w", err)
	}
	defer os.Remove(tmpfile.Name())
	defer tmpfile.Close()

	// Write nft commands to file in batches to avoid memory issues
	// For large datasets, split into multiple add element commands (10k per batch)
	// Format: add element ip nftban blacklist_ipv4 { 10.0.0.0/8, 192.168.0.0/16, ... }

	const batchSize = 10000
	for batchStart := 0; batchStart < len(canonicalCIDRs); batchStart += batchSize {
		batchEnd := batchStart + batchSize
		if batchEnd > len(canonicalCIDRs) {
			batchEnd = len(canonicalCIDRs)
		}

		batch := canonicalCIDRs[batchStart:batchEnd]

		// Use strings.Builder for efficient string concatenation
		var builder strings.Builder
		for i, cidr := range batch {
			if i > 0 {
				builder.WriteString(", ")
			}
			builder.WriteString(cidr)
		}

		nftCmd := fmt.Sprintf("add element %s %s %s { %s }\n", family, set.Table.Name, set.Name, builder.String())
		if _, err := tmpfile.WriteString(nftCmd); err != nil {
			return nil, fmt.Errorf("failed to write to temp file: %w", err)
		}
	}
	tmpfile.Close()

	// Execute nft -f <file> using centralized helper
	if _, err := runNftFile(tmpfile.Name()); err != nil {
		return nil, err
	}

	return stats, nil
}

//nolint:U1000 // Helper method for set retrieval

//nolint:U1000 // Helper method for batch CIDR operations
