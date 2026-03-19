// =============================================================================
// NFTBan - NFTables Manager - NFTManager struct, table management, and IP conversion helpers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nft"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="NFTManager struct, table management, and IP conversion helpers"
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
	"net"

	"github.com/google/nftables"
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
