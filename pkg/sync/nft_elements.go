// =============================================================================
// NFTBan - NFTables Manager - Batch element operations, CIDR support, and timeouts
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nft"
// meta:type="package"
// meta:version="1.0.0"
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

package sync

import (
	"errors"
	"fmt"
	"log"
	"net"
	"os"
	"strings"
	"time"

	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/pkg/safety"
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
