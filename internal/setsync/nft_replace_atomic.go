// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="setsync/nft_replace_atomic" meta:type="package" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Atomic single-transaction netlink set replacement for the opqueue replace_set path (no standalone committed flush)"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"

package setsync

import (
	"fmt"
	"net"
	"time"

	"github.com/google/nftables"
)

// SetElementInput is a single element for an atomic set replacement: a bare IP
// (non-CIDR) plus an optional TTL. The address family is NEVER inferred from the
// value or the set name — it is validated against the resolved set's KeyType.
type SetElementInput struct {
	Value   string        // bare IPv4/IPv6 address (CIDR/interval elements are rejected here)
	Timeout time.Duration // 0 = permanent
}

// nftConn is the minimal subset of *nftables.Conn used by the atomic replacement.
// It exists so the single-transaction / call-ordering semantics are unit-testable
// with a recording fake, without nft, netlink, or root. *nftables.Conn satisfies it.
type nftConn interface {
	FlushSet(s *nftables.Set)
	SetAddElements(s *nftables.Set, vals []nftables.SetElement) error
	Flush() error
}

// replaceAddBatch bounds how many elements go into a single SetAddElements call.
// A single netlink message has a size limit; queuing too many elements in one
// SetAddElements produces an oversized message that the kernel silently applies
// only partially (observed ~1900-element cap on real hardware). Batching well
// under that — every batch queued on the SAME connection and committed by ONE
// Flush() — keeps the replacement BOTH atomic AND complete for large sets.
const replaceAddBatch = 1000

// FindSetInTable returns the existing set with the given name from the table's
// live kernel definition (carrying its real KeyType and Interval flag), or
// (nil, nil) if the table has no such set. It is NON-creating: it is used to
// resolve a set's address family authoritatively for the replace path instead of
// inferring the family from the set name (names like http_bot_ban6 do not end in
// _ipv6, so a name-suffix guess resolves the wrong table and can fabricate a
// bogus interval set).
func (m *NFTManager) FindSetInTable(table *nftables.Table, name string) (*nftables.Set, error) {
	// INV-NFT-TX-01: private connection, owned for this transaction only (read-only).
	conn, errTx := m.readConn()
	if errTx != nil {
		return nil, errTx
	}
	if table == nil {
		return nil, nil
	}
	sets, err := conn.GetSets(table)
	if err != nil {
		return nil, fmt.Errorf("list sets in %s: %w", table.Name, err)
	}
	for _, s := range sets {
		if s.Name == name {
			return s, nil
		}
	}
	return nil, nil
}

// ReplaceSetElements atomically replaces the ENTIRE contents of a non-interval
// (hash) set in a SINGLE netlink transaction: flush + add + exactly one commit.
//
// It is the atomic counterpart of the opqueue replace_set path's former
// standalone FlushSet()+AddElements() (two separately committed transactions),
// which left the kernel set transiently EMPTY between the flush commit and the
// adds — a fail-OPEN window on enforcement sets. Here the flush and the adds are
// queued together and committed by one conn.Flush(): the kernel applies them as
// one transaction, so readers never observe the set empty or partial. On commit
// failure NOTHING is applied and the set retains its prior (blocked) contents —
// fail-CLOSED.
//
// Contract:
//   - Every element is validated + canonicalized BEFORE the connection is mutated;
//     any invalid element (bad IP, wrong family, CIDR/interval) returns an error
//     with the set untouched.
//   - Address family is derived from set.KeyType (authoritative), never from the
//     set name — so names like http_bot_ban6 (no _ipv6 suffix) are handled
//     correctly.
//   - Duplicate elements are de-duplicated deterministically (first occurrence
//     wins) so the single transaction cannot self-conflict.
//   - An empty replacement is an EXPLICIT atomic flush (one commit, zero adds),
//     not an accidental empty-set fail-open.
//   - Interval sets are rejected: they are owned by the atomic FULL-sync path.
func (m *NFTManager) ReplaceSetElements(set *nftables.Set, elements []SetElementInput) error {
	release, errW := BeginWrite()
	if errW != nil {
		return errW
	}
	defer release()
	// INV-NFT-TX-01: the atomic replacement owns a PRIVATE connection. This is
	// what makes its documented atomicity true by construction — no other writer
	// can append into, or prematurely flush, this batch.
	conn, errTx := m.txConn()
	if errTx != nil {
		return errTx
	}
	return replaceSetElementsOnConn(conn, set, elements)
}

// replaceSetElementsOnConn is the testable core: pure validation, then the
// single-commit transaction on the supplied connection.
func replaceSetElementsOnConn(conn nftConn, set *nftables.Set, elements []SetElementInput) error {
	if set == nil {
		return fmt.Errorf("replace set: nil set")
	}
	isV4, err := hashSetIsV4(set)
	if err != nil {
		return fmt.Errorf("replace set %s: %w", set.Name, err)
	}

	// Phase 1: validate + canonicalize EVERY element before touching the connection.
	nlElems := make([]nftables.SetElement, 0, len(elements))
	seen := make(map[string]struct{}, len(elements))
	for _, e := range elements {
		key, kerr := canonicalHashKey(e.Value, isV4)
		if kerr != nil {
			return fmt.Errorf("replace set %s: %w", set.Name, kerr)
		}
		// Deterministic dedup by canonical key bytes (first occurrence wins).
		if _, dup := seen[string(key)]; dup {
			continue
		}
		seen[string(key)] = struct{}{}

		el := nftables.SetElement{Key: key}
		if e.Timeout > 0 {
			el.Timeout = e.Timeout
		}
		nlElems = append(nlElems, el)
	}

	// Phase 2: ONE transaction. Flush first, then all adds, then a single commit.
	// Elements are pre-validated to the exact key width for this set's KeyType, so
	// SetAddElements cannot fail marshaling here; queuing the flush before the adds
	// keeps flush-before-add ordering inside the one batch.
	conn.FlushSet(set)
	if start, end, err := queueInBatches(set, nlElems, conn.SetAddElements); err != nil {
		// Do not commit: without a Flush() the queued flush is never applied,
		// so the kernel set is unchanged (fail-CLOSED).
		return fmt.Errorf("replace set %s: queue add batch [%d:%d]: %w", set.Name, start, end, err)
	}
	if err := conn.Flush(); err != nil {
		// The whole batch (flush + adds) is rejected atomically → prior contents kept.
		return fmt.Errorf("replace set %s: commit transaction: %w", set.Name, err)
	}
	return nil
}

// hashSetIsV4 is the single family rule for netlink hash-set element writes: interval sets are
// refused (owned by the FULL-sync path), the family comes from set.KeyType, never the name.
// Shared by ReplaceSetElements and UpsertPermanentElements.
func hashSetIsV4(set *nftables.Set) (bool, error) {
	if set.Interval {
		return false, fmt.Errorf("interval set not supported by the atomic netlink replace primitive (owned by the FULL-sync path)")
	}
	switch set.KeyType {
	case nftables.TypeIPAddr:
		return true, nil
	case nftables.TypeIP6Addr:
		return false, nil
	default:
		return false, fmt.Errorf("unsupported key type %v", set.KeyType)
	}
}

// canonicalHashKey validates one bare IP for a hash set of the given family and returns its
// canonical key bytes (CIDR/interval values are refused). Shared by ReplaceSetElements and
// UpsertPermanentElements so both apply the same rules.
func canonicalHashKey(value string, isV4 bool) ([]byte, error) {
	ip := net.ParseIP(value)
	if ip == nil {
		return nil, fmt.Errorf("invalid IP %q (CIDR/interval not accepted here)", value)
	}
	if isV4 {
		key := ip.To4()
		if key == nil {
			return nil, fmt.Errorf("%q is not IPv4 but the set is ipv4_addr", value)
		}
		return key, nil
	}
	if ip.To4() != nil {
		return nil, fmt.Errorf("%q is IPv4 but the set is ipv6_addr", value)
	}
	key := ip.To16()
	if key == nil {
		return nil, fmt.Errorf("%q is not a valid IPv6 address", value)
	}
	return key, nil
}

// queueInBatches queues els on ONE connection in batches of at most replaceAddBatch, WITHOUT
// committing: every batch rides the caller's single Flush, so the transaction stays atomic and
// complete (an oversized single message is applied only partially by the kernel). On a queue
// error it returns the failing batch bounds; the caller must not commit.
func queueInBatches(set *nftables.Set, els []nftables.SetElement, queue func(*nftables.Set, []nftables.SetElement) error) (int, int, error) {
	for start := 0; start < len(els); start += replaceAddBatch {
		end := start + replaceAddBatch
		if end > len(els) {
			end = len(els)
		}
		if err := queue(set, els[start:end]); err != nil {
			return start, end, err
		}
	}
	return 0, 0, nil
}
