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

package setsync

import (
	"bytes"
	"fmt"
	"net"
	"sort"

	"github.com/google/nftables"
)

// GetOrCreateSet gets or creates a named set in the table
func (m *NFTManager) GetOrCreateSet(table *nftables.Table, setName string, ipv4 bool) (*nftables.Set, error) {
	// INV-NFT-TX-01: private connection, owned for this transaction only.
	conn, errTx := m.txConn()
	if errTx != nil {
		return nil, errTx
	}
	// Try to get existing set
	sets, err := conn.GetSets(table)
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

	if err := conn.AddSet(set, nil); err != nil {
		return nil, fmt.Errorf("failed to add set: %w", err)
	}

	if err := conn.Flush(); err != nil {
		return nil, fmt.Errorf("failed to create set: %w", err)
	}

	return set, nil
}

// GetOrCreateHashSet gets or creates a hash set with timeout support (O(1) lookup)
// v1.33.0: Used for manual/auto-detect bans where CIDR aggregation is not needed
func (m *NFTManager) GetOrCreateHashSet(table *nftables.Table, setName string, ipv4 bool) (*nftables.Set, error) {
	// INV-NFT-TX-01: private connection, owned for this transaction only.
	conn, errTx := m.txConn()
	if errTx != nil {
		return nil, errTx
	}
	// Try to get existing set
	sets, err := conn.GetSets(table)
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

	// Create hash set using nft CLI (timeout flag, NO interval, NO auto-merge)
	setDef := fmt.Sprintf("{ type %s ; flags timeout ; }", ipType)
	if err := nftAddSet(family, table.Name, setName, setDef); err != nil {
		return nil, fmt.Errorf("failed to create hash set: %w", err)
	}

	// Return set object for compatibility
	set := &nftables.Set{
		Table:   table,
		Name:    setName,
		KeyType: keyType,
	}

	return set, nil
}

// GetOrCreateIntervalSet gets or creates an interval set for CIDR ranges
func (m *NFTManager) GetOrCreateIntervalSet(table *nftables.Table, setName string, ipv4 bool) (*nftables.Set, error) {
	// INV-NFT-TX-01: private connection, owned for this transaction only.
	conn, errTx := m.txConn()
	if errTx != nil {
		return nil, errTx
	}
	// Try to get existing set
	sets, err := conn.GetSets(table)
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
	// INV-NFT-TX-01: private connection, owned for this transaction only.
	conn, errTx := m.txConn()
	if errTx != nil {
		return nil, errTx
	}
	elements, err := conn.GetSetElements(set)
	if err != nil {
		return nil, fmt.Errorf("failed to get set elements: %w", err)
	}

	ips := make([]string, 0, len(elements)) // Pre-allocate to avoid reallocations
	for _, elem := range elements {
		// Skip interval-end markers — for interval sets (CIDR ranges), the kernel
		// returns two elements per entry (start + end). We only want the start.
		if elem.IntervalEnd {
			continue
		}
		// Parse IP from element key
		ip := net.IP(elem.Key)
		if ip != nil {
			ips = append(ips, ip.String())
		}
	}

	return ips, nil
}

// decrementIP returns ip-1 (big-endian byte arithmetic). nftables interval END
// markers are EXCLUSIVE (last_ip + 1), so the inclusive end is endKey - 1.
func decrementIP(ip net.IP) net.IP {
	b := make(net.IP, len(ip))
	copy(b, ip)
	for i := len(b) - 1; i >= 0; i-- {
		if b[i] > 0 {
			b[i]--
			break
		}
		b[i] = 0xff
	}
	return b
}

// GetSetElementsRanges returns one token per set entry, reconstructing interval
// ranges as "start-end" (or a single IP when start==end). Unlike GetSetElements
// — which returns only interval STARTS as bare IPs and drops the range — this
// preserves CIDR/range COVERAGE so a range-aware diff can compare coverage, not
// strings (WHITELIST_DURABLE_APPLY_RECONCILE Step 4). nftables stores an interval
// [a,b] as a start element (a) + an interval-end marker (b+1, exclusive).
func (m *NFTManager) GetSetElementsRanges(set *nftables.Set) ([]string, error) {
	// INV-NFT-TX-01: private connection, owned for this transaction only.
	conn, errTx := m.txConn()
	if errTx != nil {
		return nil, errTx
	}
	elements, err := conn.GetSetElements(set)
	if err != nil {
		return nil, fmt.Errorf("failed to get set elements: %w", err)
	}
	return reconstructIntervalRanges(elements), nil
}

// reconstructIntervalRanges is the PURE (unit-testable) range reconstruction,
// separated from the netlink fetch. Empirically pinned model (lab2 probe,
// NFTABLES_INTERVAL_ELEMENT_MODEL): nftables interval sets emit, per logical
// entry, a START (IntervalEnd=false) and an EXCLUSIVE END (IntervalEnd=true, =
// last+1); singletons get a paired end (X → X+1); the END precedes its START in
// the stream; and there is a trailing orphan wraparound end (0.0.0.0). Intervals
// are disjoint (auto-merge), so we sort starts+ends and, for each start, take the
// smallest end strictly greater than it — which skips the orphan and never
// produces a backwards range.
func reconstructIntervalRanges(elements []nftables.SetElement) []string {
	var starts, ends [][]byte
	for _, elem := range elements {
		k := append([]byte(nil), elem.Key...)
		if elem.IntervalEnd {
			ends = append(ends, k)
		} else {
			starts = append(starts, k)
		}
	}
	// Plain (non-interval) set: no end markers → each element is a single IP.
	if len(ends) == 0 {
		out := make([]string, 0, len(starts))
		for _, s := range starts {
			out = append(out, net.IP(s).String())
		}
		return out
	}
	// nftables emits interval END markers (exclusive) and STARTs not necessarily
	// adjacent, plus a trailing wraparound end (0.0.0.0). Intervals are disjoint,
	// so: sort both ascending and, for each start, take the SMALLEST end strictly
	// greater than it (two-pointer). This skips the orphan wraparound end and
	// reconstructs each [start, end-1] correctly regardless of stream order.
	sort.Slice(starts, func(i, j int) bool { return bytes.Compare(starts[i], starts[j]) < 0 })
	sort.Slice(ends, func(i, j int) bool { return bytes.Compare(ends[i], ends[j]) < 0 })
	out := make([]string, 0, len(starts))
	ei := 0
	for _, s := range starts {
		for ei < len(ends) && bytes.Compare(ends[ei], s) <= 0 {
			ei++ // skip ends at/below this start (incl. the wraparound 0.0.0.0)
		}
		if ei >= len(ends) {
			// No end above this start — treat as a single IP (defensive).
			out = append(out, net.IP(s).String())
			continue
		}
		startIP := net.IP(s)
		endIncl := decrementIP(net.IP(ends[ei]))
		ei++
		if startIP.Equal(endIncl) {
			out = append(out, startIP.String())
		} else {
			out = append(out, startIP.String()+"-"+endIncl.String())
		}
	}
	return out
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
	// INV-NFT-TX-01: private connection, owned for this transaction only.
	conn, errTx := m.txConn()
	if errTx != nil {
		return errTx
	}
	conn.FlushSet(set)
	return conn.Flush()
}

// GetSetCount returns the number of elements in a set
// For interval sets, filters out IntervalEnd markers to return the true entry count
func (m *NFTManager) GetSetCount(set *nftables.Set) (int, error) {
	// INV-NFT-TX-01: private connection, owned for this transaction only.
	conn, errTx := m.txConn()
	if errTx != nil {
		return 0, errTx
	}
	elements, err := conn.GetSetElements(set)
	if err != nil {
		return 0, fmt.Errorf("failed to get set elements: %w", err)
	}
	if !set.Interval {
		return len(elements), nil
	}
	// Interval sets: count only start elements (kernel returns start+end per entry)
	count := 0
	for _, elem := range elements {
		if !elem.IntervalEnd {
			count++
		}
	}
	return count, nil
}
