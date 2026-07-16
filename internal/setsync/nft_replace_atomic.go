// SPDX-License-Identifier: MPL-2.0
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
	if table == nil {
		return nil, nil
	}
	sets, err := m.conn.GetSets(table)
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
	return replaceSetElementsOnConn(m.conn, set, elements)
}

// replaceSetElementsOnConn is the testable core: pure validation, then the
// single-commit transaction on the supplied connection.
func replaceSetElementsOnConn(conn nftConn, set *nftables.Set, elements []SetElementInput) error {
	if set == nil {
		return fmt.Errorf("replace set: nil set")
	}
	if set.Interval {
		return fmt.Errorf("replace set %s: interval set not supported by the atomic netlink replace primitive (owned by the FULL-sync path)", set.Name)
	}

	// Family is authoritative from the set key type — never from the name.
	var isV4 bool
	switch set.KeyType {
	case nftables.TypeIPAddr:
		isV4 = true
	case nftables.TypeIP6Addr:
		isV4 = false
	default:
		return fmt.Errorf("replace set %s: unsupported key type %v", set.Name, set.KeyType)
	}

	// Phase 1: validate + canonicalize EVERY element before touching the connection.
	nlElems := make([]nftables.SetElement, 0, len(elements))
	seen := make(map[string]struct{}, len(elements))
	for _, e := range elements {
		ip := net.ParseIP(e.Value)
		if ip == nil {
			return fmt.Errorf("replace set %s: invalid IP %q (CIDR/interval not accepted here)", set.Name, e.Value)
		}
		var key []byte
		if isV4 {
			key = ip.To4()
			if key == nil {
				return fmt.Errorf("replace set %s: %q is not IPv4 but the set is ipv4_addr", set.Name, e.Value)
			}
		} else {
			if ip.To4() != nil {
				return fmt.Errorf("replace set %s: %q is IPv4 but the set is ipv6_addr", set.Name, e.Value)
			}
			key = ip.To16()
			if key == nil {
				return fmt.Errorf("replace set %s: %q is not a valid IPv6 address", set.Name, e.Value)
			}
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
	for start := 0; start < len(nlElems); start += replaceAddBatch {
		end := start + replaceAddBatch
		if end > len(nlElems) {
			end = len(nlElems)
		}
		if err := conn.SetAddElements(set, nlElems[start:end]); err != nil {
			// Do not commit: without a Flush() the queued flush is never applied,
			// so the kernel set is unchanged (fail-CLOSED).
			return fmt.Errorf("replace set %s: queue add batch [%d:%d]: %w", set.Name, start, end, err)
		}
	}
	if err := conn.Flush(); err != nil {
		// The whole batch (flush + adds) is rejected atomically → prior contents kept.
		return fmt.Errorf("replace set %s: commit transaction: %w", set.Name, err)
	}
	return nil
}
