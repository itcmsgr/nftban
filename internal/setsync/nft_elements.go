// =============================================================================
// NFTBan - NFTables Manager - Batch element operations, CIDR support, and timeouts
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nft"
// meta:type="package"
// meta:version="1.41.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Batch element operations, CIDR support, and timeouts"
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
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"strings"
	"time"

	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/internal/safety"
)

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
		// Ignore EEXIST errors - element already in set
		if !errors.Is(err, os.ErrExist) {
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
		// Tolerate ENOENT errors - element already doesn't exist (idempotent)
		if errors.Is(err, os.ErrNotExist) {
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

	// Atomically replace the set contents: flush + add in ONE `nft -f`
	// transaction (V-NFT-SET-REFRESH-ATOMICITY). Previously this flushed via a
	// standalone `nft flush set` and repopulated in a SEPARATE `nft -f`, leaving
	// the shared blacklist_* set transiently EMPTY between transactions — the
	// F-FEED / F-GEO fail-open window where banned IPs were admitted during the
	// daily feed / weekly geoban refresh. The single-transaction replace closes
	// it; on nft failure the transaction rolls back and the prior (blocked)
	// contents are retained (fail-CLOSED).
	if err := replaceSetElementsViaFile(family, set.Table.Name, set.Name, canonicalCIDRs); err != nil {
		return nil, err
	}

	return stats, nil
}

// =============================================================================
// CONCAT SET OPERATIONS (v1.41.0 — IP + port concatenation sets)
// =============================================================================

// GetOrCreateConcatSet creates or retrieves a concat set (IP . port) for per-IP port access.
// The set type is ipv4_addr . inet_service (or ipv6_addr) with timeout flag.
func (m *NFTManager) GetOrCreateConcatSet(table *nftables.Table, setName string, ipv4 bool) (*nftables.Set, error) {
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

	// Create concat set: IP address . inet_service
	addrType := nftables.TypeIPAddr
	if !ipv4 {
		addrType = nftables.TypeIP6Addr
	}

	set := &nftables.Set{
		Table:      table,
		Name:       setName,
		HasTimeout: true,
		KeyType:    nftables.MustConcatSetType(addrType, nftables.TypeInetService),
	}

	if err := m.conn.AddSet(set, nil); err != nil {
		return nil, fmt.Errorf("failed to add concat set %s: %w", setName, err)
	}

	if err := m.conn.Flush(); err != nil {
		return nil, fmt.Errorf("failed to flush concat set creation: %w", err)
	}

	return set, nil
}

// AddConcatIPPort adds an IP+port element to a concat set.
// The key is concatenated as [IP bytes][port bytes (big-endian)].
func (m *NFTManager) AddConcatIPPort(set *nftables.Set, ipStr string, port int, timeout time.Duration) error {
	if port < 1 || port > 65535 {
		return fmt.Errorf("invalid port: %d", port)
	}

	ip := net.ParseIP(ipStr)
	if ip == nil {
		return fmt.Errorf("invalid IP: %s", ipStr)
	}

	// Build concat key: [IP bytes][port uint16 big-endian]
	var key []byte
	if ip4 := ip.To4(); ip4 != nil {
		// IPv4: 4 bytes IP + padding to 4-byte boundary + 2 bytes port + 2 padding
		key = make([]byte, 8) // 4 (IP) + 2 (port) + 2 (padding to align)
		copy(key[0:4], ip4)
		key[4] = byte(port >> 8)
		key[5] = byte(port & 0xff)
	} else if ip6 := ip.To16(); ip6 != nil {
		// IPv6: 16 bytes IP + 2 bytes port + 2 padding
		key = make([]byte, 20) // 16 (IP) + 2 (port) + 2 (padding)
		copy(key[0:16], ip6)
		key[16] = byte(port >> 8)
		key[17] = byte(port & 0xff)
	} else {
		return fmt.Errorf("cannot convert IP: %s", ipStr)
	}

	elem := nftables.SetElement{Key: key}
	if timeout > 0 {
		elem.Timeout = timeout
	}

	if err := m.conn.SetAddElements(set, []nftables.SetElement{elem}); err != nil {
		return fmt.Errorf("failed to add concat element: %w", err)
	}

	if err := m.conn.Flush(); err != nil {
		return fmt.Errorf("failed to flush concat element: %w", err)
	}

	return nil
}

// DeleteConcatIPPort removes an IP+port element from a concat set.
func (m *NFTManager) DeleteConcatIPPort(set *nftables.Set, ipStr string, port int) error {
	if port < 1 || port > 65535 {
		return fmt.Errorf("invalid port: %d", port)
	}

	ip := net.ParseIP(ipStr)
	if ip == nil {
		return fmt.Errorf("invalid IP: %s", ipStr)
	}

	var key []byte
	if ip4 := ip.To4(); ip4 != nil {
		key = make([]byte, 8)
		copy(key[0:4], ip4)
		key[4] = byte(port >> 8)
		key[5] = byte(port & 0xff)
	} else if ip6 := ip.To16(); ip6 != nil {
		key = make([]byte, 20)
		copy(key[0:16], ip6)
		key[16] = byte(port >> 8)
		key[17] = byte(port & 0xff)
	} else {
		return fmt.Errorf("cannot convert IP: %s", ipStr)
	}

	if err := m.conn.SetDeleteElements(set, []nftables.SetElement{{Key: key}}); err != nil {
		return fmt.Errorf("failed to delete concat element: %w", err)
	}

	if err := m.conn.Flush(); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil // Idempotent: element already gone
		}
		return fmt.Errorf("failed to flush concat delete: %w", err)
	}

	return nil
}
