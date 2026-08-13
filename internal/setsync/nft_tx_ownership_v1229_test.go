// SPDX-License-Identifier: MPL-2.0
//
// v1.229.0 — INV-NFT-TX-01 regression suite.
//
// Guards the invariant that ONE mutating method invocation owns ONE private
// *nftables.Conn for exactly one queue -> Flush transaction.
//
// The defect these lock out was REPRODUCED on v1.228.12 before the fix:
// two writers sharing one Conn, writer A's Flush transmitted
// [BATCH_BEGIN, NEWTABLE, NEWTABLE, BATCH_END] — carrying BOTH writers' work —
// and writer B then transmitted nothing and returned nil. Upstream states it
// plainly in conn.go: "Messages were already programmed, returning nil".
//
// These tests assert on TRANSMITTED MESSAGES, not on error values. "Both calls
// returned nil" would have passed against the defective code; attribution is
// the whole point.
package setsync

import (
	"sync"
	"testing"

	"github.com/google/nftables"
	"github.com/mdlayher/netlink"
)

// nftMsgNewTable is NFT_MSG_NEWTABLE as it appears in a batch's netlink header
// type field. Batches are wrapped in BATCH_BEGIN(16) / BATCH_END(17).
const nftMsgNewTable = 2560

// txRecorder records one entry per transmitted batch so a test can attribute
// which operations rode in which transaction.
type txRecorder struct {
	mu    sync.Mutex
	sends [][]netlink.Message
}

// nftBatchBegin marks a transaction commit; anything else is a read query.
const nftBatchBegin = 16

func (r *txRecorder) dial(req []netlink.Message) ([]netlink.Message, error) {
	isBatch := false
	for _, m := range req {
		if m.Header.Type == nftBatchBegin {
			isBatch = true
			break
		}
	}
	if !isBatch {
		// A query (ListTables/GetSets). Answer "nothing exists" so the caller
		// proceeds to its create path. Queries carry no transaction and are not
		// recorded — only commits are attributable to an owner.
		return []netlink.Message{}, nil
	}
	r.mu.Lock()
	cp := make([]netlink.Message, len(req))
	copy(cp, req)
	r.sends = append(r.sends, cp)
	r.mu.Unlock()
	// Echo the batch, as google/nftables' own tests do, so Flush takes its
	// acknowledgement path.
	return req, nil
}

// newTableMessages counts NEWTABLE operations across every transmitted batch.
func (r *txRecorder) newTableMessages() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	n := 0
	for _, b := range r.sends {
		for _, m := range b {
			if m.Header.Type == nftMsgNewTable {
				n++
			}
		}
	}
	return n
}

// maxNewTablesInOneBatch is the attribution assertion: how many NEWTABLE
// operations rode inside a SINGLE transaction.
func (r *txRecorder) maxNewTablesInOneBatch() int {
	r.mu.Lock()
	defer r.mu.Unlock()
	worst := 0
	for _, b := range r.sends {
		n := 0
		for _, m := range b {
			if m.Header.Type == nftMsgNewTable {
				n++
			}
		}
		if n > worst {
			worst = n
		}
	}
	return worst
}

// TestINVNFTTX01_OneMethodOneTransaction is a CONTRACT test, not a
// reintroduction guard. Read the scope note before trusting it.
//
// It asserts that a manager method transmits exactly its own operation in its
// own batch. That is worth pinning — but it CANNOT detect a reintroduced shared
// connection, and this was verified by inversion: re-adding a shared conn to
// NFTManager leaves this test GREEN. The reason is structural — each mutating
// method queues AND flushes inside one invocation, so sequential calls never
// overlap, and the merge window (both writers queued before either flushes)
// never opens.
//
// The arm that actually fails on reintroduction is
// TestINVNFTTX01_ManagerHoldsNoSharedConn.
func TestINVNFTTX01_OneMethodOneTransaction(t *testing.T) {
	rec := &txRecorder{}

	// Drive the REAL manager. If a future change reintroduces a shared
	// connection, every method's work lands in one buffer and the attribution
	// assertion below fails. Creating two conns directly in the test would
	// prove only that the library works — it would pass against the defect.
	m := &NFTManager{
		cachedTables: make(map[nftables.TableFamily]*nftables.Table),
		newConn: func() (*nftables.Conn, error) {
			return nftables.New(nftables.WithTestDial(rec.dial))
		},
	}

	// Two independent mutating transactions through real entry points.
	if _, err := m.GetOrCreateTable(nftables.TableFamilyIPv4); err != nil {
		t.Fatalf("GetOrCreateTable v4: %v", err)
	}
	if _, err := m.GetOrCreateTable(nftables.TableFamilyIPv6); err != nil {
		t.Fatalf("GetOrCreateTable v6: %v", err)
	}

	if got := rec.maxNewTablesInOneBatch(); got != 1 {
		t.Fatalf("INV-NFT-TX-01 VIOLATED: a single transaction carried %d NEWTABLE operations; "+
			"each method invocation must own its own transaction", got)
	}
	if got := rec.newTableMessages(); got != 2 {
		t.Fatalf("expected each transaction to transmit its own NEWTABLE exactly once, got %d", got)
	}
}

// TestINVNFTTX01_AbandonedTransactionSemantics documents WHY private conns fix
// the residue sub-defect. It is a LIBRARY-SEMANTICS test over google/nftables,
// not a guard on NFTManager: it drives its own connections, so like the contract
// test above it stays green if a shared conn is reintroduced (verified by
// inversion).
//
// It is kept because the residue path is the half of the defect that has no
// upstream API to mitigate — v0.3.0 offers no discard, and Flush() would APPLY
// a partial transaction rather than drop it. Pinning the semantics keeps the
// rationale falsifiable if the dependency is ever upgraded.
func TestINVNFTTX01_AbandonedTransactionSemantics(t *testing.T) {
	rec := &txRecorder{}

	// Transaction 1 queues work and is then abandoned WITHOUT Flush, exactly as
	// a method returning an error mid-way would abandon it.
	abandoned, err := nftables.New(nftables.WithTestDial(rec.dial))
	if err != nil {
		t.Fatalf("conn: %v", err)
	}
	abandoned.AddTable(&nftables.Table{Family: nftables.TableFamilyIPv4, Name: "abandoned"})
	// no Flush — the transaction dies here.

	// Transaction 2 is a fresh owner and commits its own single operation.
	next, err := nftables.New(nftables.WithTestDial(rec.dial))
	if err != nil {
		t.Fatalf("conn: %v", err)
	}
	next.AddTable(&nftables.Table{Family: nftables.TableFamilyIPv6, Name: "next"})
	if err := next.Flush(); err != nil {
		t.Fatalf("next Flush: %v", err)
	}

	if got := rec.newTableMessages(); got != 1 {
		t.Fatalf("RESIDUE LEAKED: expected exactly 1 transmitted NEWTABLE (the committed one), got %d; "+
			"an abandoned transaction's queued work reached the wire", got)
	}
	if got := rec.maxNewTablesInOneBatch(); got != 1 {
		t.Fatalf("RESIDUE LEAKED: a transaction carried %d NEWTABLE operations", got)
	}
}

// TestINVNFTTX01_ManagerHoldsNoSharedConn is THE load-bearing guard of this
// suite — the only arm proven to fail when a shared connection is reintroduced.
//
// Verified by inversion on lab2: re-adding a cached conn to txConn() turns this
// test RED while the other two arms stay green. Falsifiability lives here.
//
// A compile-time "field absent" assertion is not expressible, so this asserts
// the observable consequence: two transactions must never be handed the same
// connection, because that is exactly what lets one Flush commit another
// writer's queued work.
func TestINVNFTTX01_ManagerHoldsNoSharedConn(t *testing.T) {
	m := &NFTManager{cachedTables: make(map[nftables.TableFamily]*nftables.Table)}

	c1, err := m.txConn()
	if err != nil {
		t.Skipf("txConn unavailable in this environment: %v", err)
	}
	c2, err := m.txConn()
	if err != nil {
		t.Skipf("txConn unavailable in this environment: %v", err)
	}
	if c1 == c2 {
		t.Fatal("INV-NFT-TX-01 VIOLATED: txConn returned the SAME connection twice; " +
			"transactions would share a message buffer")
	}
}

// TestR2_CachedTablesConcurrentAccess is the permanent race regression for the
// unsynchronised map. Pre-fix, `go test -race` reported a data race between
// InvalidateTableCache (write) and GetOrCreateTable (read) through these exact
// exported entry points. Run with -race for this to carry its weight.
func TestR2_CachedTablesConcurrentAccess(t *testing.T) {
	m := &NFTManager{cachedTables: make(map[nftables.TableFamily]*nftables.Table)}

	// Seed the cache so readers hit the fast path and never need netlink; this
	// keeps the test hermetic while still exercising the map concurrently.
	m.setCachedTable(nftables.TableFamilyIPv4, &nftables.Table{Name: "nftban", Family: nftables.TableFamilyIPv4})
	m.setCachedTable(nftables.TableFamilyIPv6, &nftables.Table{Name: "nftban", Family: nftables.TableFamilyIPv6})

	const goroutines = 8
	const iterations = 200
	var wg sync.WaitGroup
	start := make(chan struct{})

	for g := 0; g < goroutines; g++ {
		wg.Add(1)
		go func(id int) {
			defer wg.Done()
			<-start
			fam := nftables.TableFamilyIPv4
			if id%2 == 1 {
				fam = nftables.TableFamilyIPv6
			}
			for i := 0; i < iterations; i++ {
				_, _ = m.getCachedTable(fam)
				m.setCachedTable(fam, &nftables.Table{Name: "nftban", Family: fam})
				if id == 0 && i%25 == 0 {
					m.InvalidateTableCache()
				}
			}
		}(g)
	}
	close(start)
	wg.Wait()
}
