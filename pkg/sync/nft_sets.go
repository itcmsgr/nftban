// =============================================================================
// NFTBan - NFTables Manager - Set CRUD operations via netlink
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nft"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Set CRUD operations via netlink"
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
	"fmt"
	"net"

	"github.com/google/nftables"
)

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

// FlushSet removes all elements from a set
func (m *NFTManager) FlushSet(set *nftables.Set) error {
	m.conn.FlushSet(set)
	return m.conn.Flush()
}

// GetSetCount returns the number of elements in a set
func (m *NFTManager) GetSetCount(set *nftables.Set) (int, error) {
	elements, err := m.conn.GetSetElements(set)
	if err != nil {
		return 0, fmt.Errorf("failed to get set elements: %w", err)
	}
	return len(elements), nil
}
