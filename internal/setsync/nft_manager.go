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

package setsync

import (
	"encoding/binary"
	"fmt"
	"net"
	"sync"

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

// NFTManager handles nftables operations via netlink.
//
// v1.229.0 INV-NFT-TX-01 — TRANSACTION OWNERSHIP IS STRUCTURAL.
// This type deliberately holds NO *nftables.Conn. Every method obtains a
// PRIVATE connection from txConn() and owns it for exactly one
// queue -> Flush transaction.
//
// Why: a *nftables.Conn buffers queued messages in cc.messages, and Flush()
// transmits the WHOLE buffer then nils it. A second caller sharing that Conn
// finds len(messages)==0 and returns nil under the upstream comment
// "Messages were already programmed, returning nil" — so it reports success
// for a transaction it never transmitted, while its work was committed inside
// somebody else's batch. Reproduced on this tree: writer A's Flush transmitted
// [BATCH_BEGIN, NEWTABLE, NEWTABLE, BATCH_END] carrying BOTH writers' work;
// writer B then sent nothing and returned nil.
//
// A mutex would not fix it: caller B can append into caller A's buffer before
// A ever acquires the lock. Ownership must be a property of the object graph,
// not of lock discipline — hence a private Conn per transaction.
//
// This costs nothing. nftables.New() without AsLasting() is NON-LASTING: the
// library dials a fresh netlink socket inside every Flush/query and closes it
// again (conn.go netlinkConnUnderLock). Nothing was ever sharing a socket;
// only the defective buffer was shared.
type NFTManager struct {
	// cacheMu guards cachedTables ONLY. It is not a transaction lock and must
	// never be held across a Flush — transactions are isolated by ownership,
	// not by serialization.
	cacheMu      sync.RWMutex
	cachedTables map[nftables.TableFamily]*nftables.Table

	// newConn creates one private transaction connection. Production leaves it
	// nil and gets nftables.New(). It exists so the INV-NFT-TX-01 regression
	// suite can inject nftables.WithTestDial and assert on the messages each
	// transaction actually transmits — without that hook the guard could only
	// check pointer identity, and a reintroduced shared buffer would slip
	// through. Test-only injection; never set on the daemon path.
	newConn func() (*nftables.Conn, error)
}

// txConn returns a PRIVATE connection owning exactly one transaction.
//
// The caller must queue and Flush on the returned conn and then let it go. On
// any error path the caller simply returns: the queued messages die with the
// connection. That is the second half of the defect this fixes — the shared
// buffer had no discard API, so an early error left residue that rode into the
// NEXT writer's commit.
func (m *NFTManager) txConn() (*nftables.Conn, error) {
	if m.newConn != nil {
		return m.newConn()
	}
	conn, err := nftables.New()
	if err != nil {
		return nil, fmt.Errorf("failed to create nftables connection: %w", err)
	}
	return conn, nil
}

// NewNFTManager creates a new nftables manager.
//
// The probe connection is created and DISCARDED: it proves netlink is usable
// at construction (preserving the previous failure semantics) without retaining
// shared transaction state.
func NewNFTManager() (*NFTManager, error) {
	if _, err := nftables.New(); err != nil {
		return nil, fmt.Errorf("failed to create nftables connection: %w", err)
	}

	return &NFTManager{
		cachedTables: make(map[nftables.TableFamily]*nftables.Table),
	}, nil
}

// Close is retained for interface compatibility. Since v1.229.0 the manager
// holds no connection to close — transactions own private, non-lasting Conns
// that release their socket at the end of each Flush.
func (m *NFTManager) Close() {
	// Connection cleanup handled by Go GC
}

// GetOrCreateTable gets or creates the nftban table
// Uses caching to avoid repeated ListTables() calls for performance
func (m *NFTManager) GetOrCreateTable(family nftables.TableFamily) (*nftables.Table, error) {
	// R2: cachedTables was read here and written below with no synchronisation,
	// while the daemon reaches this method from OpQueue workers, per-connection
	// IPC handler goroutines and the backend concurrently. Proven by -race on
	// this tree (write InvalidateTableCache vs read here).
	if cached, ok := m.getCachedTable(family); ok {
		return cached, nil
	}

	// INV-NFT-TX-01: private connection, owned for this transaction only.
	conn, err := m.txConn()
	if err != nil {
		return nil, err
	}

	// Try to get existing table
	tables, err := conn.ListTables()
	if err != nil {
		return nil, fmt.Errorf("failed to list tables: %w", err)
	}

	for _, table := range tables {
		if table.Name == "nftban" && table.Family == family {
			m.setCachedTable(family, table)
			return table, nil
		}
	}

	// Create new table
	table := conn.AddTable(&nftables.Table{
		Family: family,
		Name:   "nftban",
	})

	if err := conn.Flush(); err != nil {
		return nil, fmt.Errorf("failed to create table: %w", err)
	}

	m.setCachedTable(family, table)
	return table, nil
}

// getCachedTable / setCachedTable are the ONLY accessors to cachedTables.
// R2 is fixed here and nowhere else: this lock guards the map, never a
// transaction. It must not be held across a Flush.
func (m *NFTManager) getCachedTable(family nftables.TableFamily) (*nftables.Table, bool) {
	m.cacheMu.RLock()
	defer m.cacheMu.RUnlock()
	t, ok := m.cachedTables[family]
	return t, ok
}

func (m *NFTManager) setCachedTable(family nftables.TableFamily, table *nftables.Table) {
	m.cacheMu.Lock()
	defer m.cacheMu.Unlock()
	m.cachedTables[family] = table
}

// InvalidateTableCache clears the table cache (use after external table changes)
func (m *NFTManager) InvalidateTableCache() {
	m.cacheMu.Lock()
	defer m.cacheMu.Unlock()
	m.cachedTables = make(map[nftables.TableFamily]*nftables.Table)
}
