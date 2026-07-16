// SPDX-License-Identifier: MPL-2.0
// meta:name="setsync/nft_replace_atomic_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Proves the atomic netlink set replacement: all elements validated before the connection is mutated, flush-before-add ordering, exactly ONE commit per replace, prior contents preserved on commit failure, explicit empty replacement, IPv4/IPv6 parity, family derived from KeyType (http_bot_*6), deterministic dedup, interval/CIDR rejection. Uses a recording fake connection — no nft, netlink, or root."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package setsync

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/google/nftables"
)

// recordingConn is a fake nftConn that records call order and counts, and can be
// told to fail SetAddElements or Flush. It never touches the kernel.
type recordingConn struct {
	order         []string
	flushSetCalls int
	addCalls      int
	addedTotal    int
	flushCalls    int
	addErr        error
	flushErr      error
}

func (c *recordingConn) FlushSet(s *nftables.Set) {
	c.order = append(c.order, "flushset")
	c.flushSetCalls++
}

func (c *recordingConn) SetAddElements(s *nftables.Set, vals []nftables.SetElement) error {
	c.order = append(c.order, "add")
	if c.addErr != nil {
		return c.addErr
	}
	c.addCalls++
	c.addedTotal += len(vals)
	return nil
}

func (c *recordingConn) Flush() error {
	c.order = append(c.order, "flush")
	c.flushCalls++
	return c.flushErr
}

func v4Set() *nftables.Set {
	return &nftables.Set{Name: "blacklist_manual_ipv4", KeyType: nftables.TypeIPAddr}
}

// http_bot_ban6 deliberately does NOT end in _ipv6 — the family must come from
// KeyType, not the name.
func v6Set() *nftables.Set {
	return &nftables.Set{Name: "http_bot_ban6", KeyType: nftables.TypeIP6Addr}
}

func in(vals ...string) []SetElementInput {
	out := make([]SetElementInput, len(vals))
	for i, v := range vals {
		out[i] = SetElementInput{Value: v}
	}
	return out
}

// VALIDATE_ALL_ELEMENTS_BEFORE_MUTATION
func TestReplace_ValidateBeforeMutation(t *testing.T) {
	c := &recordingConn{}
	err := replaceSetElementsOnConn(c, v4Set(), in("192.0.2.1", "not-an-ip", "192.0.2.2"))
	if err == nil {
		t.Fatal("expected error for invalid element")
	}
	if c.flushSetCalls != 0 || c.addCalls != 0 || c.flushCalls != 0 {
		t.Fatalf("connection was mutated before validation completed: %+v", c.order)
	}
}

// ONE_NETLINK_FLUSH_PER_REPLACE + flush-before-add ordering
func TestReplace_SingleFlushAndOrdering(t *testing.T) {
	c := &recordingConn{}
	if err := replaceSetElementsOnConn(c, v4Set(), in("192.0.2.1", "192.0.2.2", "192.0.2.3")); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if c.flushCalls != 1 {
		t.Fatalf("expected exactly 1 commit, got %d", c.flushCalls)
	}
	if c.addedTotal != 3 {
		t.Fatalf("expected 3 elements added, got %d", c.addedTotal)
	}
	// flushset must be first, and must precede every add; exactly one final flush.
	if len(c.order) == 0 || c.order[0] != "flushset" {
		t.Fatalf("flushset must be queued first, order=%v", c.order)
	}
	if c.order[len(c.order)-1] != "flush" {
		t.Fatalf("commit must be last, order=%v", c.order)
	}
	for i, op := range c.order {
		if op == "add" {
			// every add must come after the flushset (index 0)
			if i == 0 {
				t.Fatalf("add queued before flushset, order=%v", c.order)
			}
		}
	}
}

// EMPTY_REPLACEMENT_IS_EXPLICIT — one flush + one commit, zero adds, no error.
func TestReplace_EmptyIsExplicitAtomicFlush(t *testing.T) {
	c := &recordingConn{}
	if err := replaceSetElementsOnConn(c, v4Set(), nil); err != nil {
		t.Fatalf("empty replacement must succeed atomically, got %v", err)
	}
	if c.flushSetCalls != 1 || c.flushCalls != 1 {
		t.Fatalf("empty replacement must be one flushset + one commit, got flushset=%d flush=%d", c.flushSetCalls, c.flushCalls)
	}
	if c.addCalls != 0 {
		t.Fatalf("empty replacement must queue no adds, got %d", c.addCalls)
	}
}

// OLD_CONTENTS_PRESERVED_ON_FAILURE — commit failure surfaces as error (nothing applied).
func TestReplace_CommitFailurePreservesOldContents(t *testing.T) {
	c := &recordingConn{flushErr: errors.New("netlink commit boom")}
	err := replaceSetElementsOnConn(c, v4Set(), in("192.0.2.1", "192.0.2.2"))
	if err == nil {
		t.Fatal("commit failure must surface as an error (fail-closed)")
	}
	if c.flushCalls != 1 {
		t.Fatalf("exactly one commit attempt expected, got %d", c.flushCalls)
	}
	// The single transaction was rejected as a whole → the kernel set is unchanged.
}

// If SetAddElements fails to queue, the transaction is never committed (no Flush()).
func TestReplace_AddQueueFailureDoesNotCommit(t *testing.T) {
	c := &recordingConn{addErr: errors.New("marshal boom")}
	err := replaceSetElementsOnConn(c, v4Set(), in("192.0.2.1"))
	if err == nil {
		t.Fatal("add-queue failure must surface as an error")
	}
	if c.flushCalls != 0 {
		t.Fatalf("must NOT commit when add queuing fails, got %d commits", c.flushCalls)
	}
}

// IPV4_REPLACE
func TestReplace_IPv4(t *testing.T) {
	c := &recordingConn{}
	if err := replaceSetElementsOnConn(c, v4Set(), in("192.0.2.10", "203.0.113.5")); err != nil {
		t.Fatalf("valid IPv4 replace failed: %v", err)
	}
	if c.addedTotal != 2 {
		t.Fatalf("expected 2 IPv4 elements, got %d", c.addedTotal)
	}
}

// IPV6_REPLACE
func TestReplace_IPv6(t *testing.T) {
	c := &recordingConn{}
	if err := replaceSetElementsOnConn(c, v6Set(), in("2001:db8::1", "2001:db8::2")); err != nil {
		t.Fatalf("valid IPv6 replace failed: %v", err)
	}
	if c.addedTotal != 2 {
		t.Fatalf("expected 2 IPv6 elements, got %d", c.addedTotal)
	}
}

// Wrong-family rejection — before any mutation, both directions.
func TestReplace_WrongFamilyRejected(t *testing.T) {
	c := &recordingConn{}
	if err := replaceSetElementsOnConn(c, v4Set(), in("2001:db8::1")); err == nil {
		t.Fatal("IPv6 element in an ipv4_addr set must be rejected")
	}
	if err := replaceSetElementsOnConn(c, v6Set(), in("192.0.2.1")); err == nil {
		t.Fatal("IPv4 element in an ipv6_addr set must be rejected")
	}
	if c.flushSetCalls != 0 || c.flushCalls != 0 {
		t.Fatal("wrong-family input must not mutate the connection")
	}
}

// HTTP_BOT_SUFFIX6_FAMILY — family from KeyType, not the "6" suffix name.
func TestReplace_HTTPBotSuffix6FamilyFromKeyType(t *testing.T) {
	c := &recordingConn{}
	// http_bot_ban6 is TypeIP6Addr → IPv6 accepted.
	if err := replaceSetElementsOnConn(c, v6Set(), in("2001:db8::dead")); err != nil {
		t.Fatalf("http_bot_ban6 (ip6) must accept an IPv6 element: %v", err)
	}
	// ...and IPv4 rejected, proving the name suffix is not consulted.
	if err := replaceSetElementsOnConn(&recordingConn{}, v6Set(), in("192.0.2.1")); err == nil {
		t.Fatal("http_bot_ban6 (ip6) must reject an IPv4 element (family is from KeyType)")
	}
}

// Deterministic dedup — duplicates collapse to a single queued element.
func TestReplace_DeterministicDedup(t *testing.T) {
	c := &recordingConn{}
	if err := replaceSetElementsOnConn(c, v4Set(), in("192.0.2.1", "192.0.2.1", "192.0.2.2")); err != nil {
		t.Fatalf("dedup replace failed: %v", err)
	}
	if c.addedTotal != 2 {
		t.Fatalf("duplicate must be de-duplicated: expected 2 unique, got %d", c.addedTotal)
	}
}

// Large sets are batched across multiple SetAddElements messages (netlink
// message-size safety) but committed by EXACTLY ONE Flush() — atomic AND complete.
func TestReplace_LargeSetBatchedSingleCommit(t *testing.T) {
	c := &recordingConn{}
	n := 2500 // > 2*replaceAddBatch → at least 3 add batches
	els := make([]SetElementInput, n)
	for i := 0; i < n; i++ {
		els[i] = SetElementInput{Value: fmt.Sprintf("10.%d.%d.%d", (i>>16)&0xff, (i>>8)&0xff, i&0xff)}
	}
	if err := replaceSetElementsOnConn(c, v4Set(), els); err != nil {
		t.Fatalf("large replace failed: %v", err)
	}
	wantBatches := (n + replaceAddBatch - 1) / replaceAddBatch
	if c.addCalls != wantBatches {
		t.Fatalf("expected %d SetAddElements batches for %d elements (batch=%d), got %d", wantBatches, n, replaceAddBatch, c.addCalls)
	}
	if c.addedTotal != n {
		t.Fatalf("expected all %d elements queued, got %d", n, c.addedTotal)
	}
	if c.flushCalls != 1 {
		t.Fatalf("large batched replace must still commit EXACTLY once, got %d", c.flushCalls)
	}
	if c.flushSetCalls != 1 {
		t.Fatalf("exactly one flushset for the whole replace, got %d", c.flushSetCalls)
	}
}

// Interval and CIDR are rejected (this primitive is hash-set only).
func TestReplace_IntervalAndCIDRRejected(t *testing.T) {
	c := &recordingConn{}
	interval := &nftables.Set{Name: "blacklist_ipv4", KeyType: nftables.TypeIPAddr, Interval: true}
	if err := replaceSetElementsOnConn(c, interval, in("192.0.2.1")); err == nil || !strings.Contains(err.Error(), "interval") {
		t.Fatalf("interval set must be rejected, got %v", err)
	}
	if err := replaceSetElementsOnConn(&recordingConn{}, v4Set(), in("192.0.2.0/24")); err == nil {
		t.Fatal("CIDR element must be rejected by the hash-set replace primitive")
	}
	if c.flushCalls != 0 {
		t.Fatal("interval/CIDR rejection must not commit anything")
	}
}
