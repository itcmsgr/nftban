// =============================================================================
// NFTBan - NFTables Manager - Interval set operations and IPv6 helpers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nft"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Interval set operations and IPv6 helpers"
// meta:depends="github.com/google/nftables"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================

package setsync

import (
	"fmt"
	"net"
	"regexp"
	"strings"

	"github.com/google/nftables"
)

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

	cleanElements := make([]string, 0, len(filteredElements))
	for _, elem := range filteredElements {
		elem = strings.TrimSpace(elem)
		if elem != "" {
			cleanElements = append(cleanElements, elem)
		}
	}

	// Atomic flush+repopulate in one `nft -f` (V-NFT-SET-REFRESH-ATOMICITY): the
	// shared set is never observed empty between flush and re-add. An empty
	// cleanElements slice still flushes (the set legitimately becomes empty)
	// atomically. On failure the transaction rolls back (fail-CLOSED).
	if err := replaceSetElementsViaFile(family, set.Table.Name, set.Name, cleanElements); err != nil {
		return fmt.Errorf("failed to refresh set: %w", err)
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

	// Step 4: Filter out any empty strings that may have crept in.
	cleanElements := make([]string, 0, len(filteredElements)) // Pre-allocate
	for _, elem := range filteredElements {
		elem = strings.TrimSpace(elem)
		if elem != "" {
			cleanElements = append(cleanElements, elem)
		}
	}

	// Step 5: Atomic flush+repopulate in one `nft -f`
	// (V-NFT-SET-REFRESH-ATOMICITY): the set is never observed empty between
	// flush and re-add (closes the same-class fail-open window). On failure the
	// transaction rolls back and prior contents are retained (fail-CLOSED).
	if err := replaceSetElementsViaFile(family, set.Table.Name, set.Name, cleanElements); err != nil {
		return fmt.Errorf("failed to refresh set: %w", err)
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
