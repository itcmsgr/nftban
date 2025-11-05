package nftloader

import (
	"fmt"
	"net/netip"

	"github.com/google/nftables"
	"github.com/itcmsgr/nftban/go-feeds/internal/safety"
)

const (
	TableName = "nftban_main"
	SetNameV4 = "feed_v4"
	SetNameV6 = "feed_v6"
	ChunkSize = 4096 // Elements per netlink message
)

// LoadIPv4 atomically loads IPv4 prefixes into nftables set
// Flushes existing set, adds new elements, commits atomically
func LoadIPv4(prefixes []netip.Prefix) error {
	conn, err := nftables.New()
	if err != nil {
		return fmt.Errorf("nftables connection: %w", err)
	}

	// Find existing table
	table, err := findTable(conn, TableName)
	if err != nil {
		return err
	}

	// Find existing set
	set, err := findSet(conn, table, SetNameV4)
	if err != nil {
		return err
	}

	// BEGIN ATOMIC TRANSACTION
	// Step 1: Flush existing elements
	conn.FlushSet(set)

	// Step 2: Build elements
	elems := make([]nftables.SetElement, 0, len(prefixes))
	for _, p := range prefixes {
		if !p.Addr().Is4() {
			continue // Skip IPv6 in IPv4 set
		}

		// Convert netip.Prefix to nftables element
		elem := prefixToElement(p)
		elems = append(elems, elem)
	}

	// Step 3: Add elements in chunks with ENOBUFS retry
	if err := safety.AddChunkedWithRetry(conn, set, elems); err != nil {
		return fmt.Errorf("add IPv4 elements: %w", err)
	}

	// Step 4: Commit atomically to kernel
	if err := conn.Flush(); err != nil {
		return fmt.Errorf("commit transaction: %w", err)
	}

	return nil
}

// LoadIPv6 atomically loads IPv6 prefixes into nftables set
func LoadIPv6(prefixes []netip.Prefix) error {
	conn, err := nftables.New()
	if err != nil {
		return fmt.Errorf("nftables connection: %w", err)
	}

	table, err := findTable(conn, TableName)
	if err != nil {
		return err
	}

	set, err := findSet(conn, table, SetNameV6)
	if err != nil {
		return err
	}

	conn.FlushSet(set)

	elems := make([]nftables.SetElement, 0, len(prefixes))
	for _, p := range prefixes {
		if !p.Addr().Is6() {
			continue // Skip IPv4 in IPv6 set
		}

		elem := prefixToElement(p)
		elems = append(elems, elem)
	}

	// Add elements in chunks with ENOBUFS retry
	if err := safety.AddChunkedWithRetry(conn, set, elems); err != nil {
		return fmt.Errorf("add IPv6 elements: %w", err)
	}

	if err := conn.Flush(); err != nil {
		return fmt.Errorf("commit transaction: %w", err)
	}

	return nil
}

// Helper: Find table by name
func findTable(conn *nftables.Conn, name string) (*nftables.Table, error) {
	tables, err := conn.ListTables()
	if err != nil {
		return nil, fmt.Errorf("list tables: %w", err)
	}

	for _, t := range tables {
		if t.Name == name && t.Family == nftables.TableFamilyINet {
			return t, nil
		}
	}
	return nil, fmt.Errorf("table '%s' not found", name)
}

// Helper: Find set by name within table
func findSet(conn *nftables.Conn, table *nftables.Table, name string) (*nftables.Set, error) {
	sets, err := conn.GetSets(table)
	if err != nil {
		return nil, fmt.Errorf("get sets: %w", err)
	}

	for _, s := range sets {
		if s.Name == name {
			return s, nil
		}
	}
	return nil, fmt.Errorf("set '%s' not found in table '%s'", name, table.Name)
}

// Helper: Convert netip.Prefix to nftables SetElement
func prefixToElement(p netip.Prefix) nftables.SetElement {
	addr := p.Addr()
	bits := p.Bits()

	elem := nftables.SetElement{
		Key: addr.AsSlice(),
	}

	// For CIDRs (not /32 or /128), add mask
	maxBits := 32
	if addr.Is6() {
		maxBits = 128
	}

	if bits < maxBits {
		// This is a CIDR range, not a single IP
		// nftables interval sets handle this
		elem.IntervalEnd = false
	}

	return elem
}
