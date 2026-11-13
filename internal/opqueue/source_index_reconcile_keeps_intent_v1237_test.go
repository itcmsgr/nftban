// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="opqueue_source_index_reconcile_keeps_intent_v1237_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="v1.237 BUG-RECONCILE-DELETES-KERNEL-MISSING-BANS-FROM-SOURCE-INDEX: ReconcileWithBackend keeps an index entry that carries a real source when its element is missing from the kernel (including a record in the format persisted by releases <= v1.202.0), drops entries whose sole source is the reconcile's own \"unknown\", mirrors kernel-only elements as \"unknown\", and leaves expiry (PruneExpired) and explicit removal (Remove) unchanged."
// meta:inventory.privileges="none"

package opqueue

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

type reconcileStubBackend struct{ sets map[string][]string }

func (reconcileStubBackend) FlushSet(table, set string) error { return nil }
func (reconcileStubBackend) AddElements(table, set string, e []SetElement) (int, error) {
	return len(e), nil
}
func (reconcileStubBackend) DeleteElements(table, set string, e []SetElement) error { return nil }
func (b reconcileStubBackend) GetSetElements(table, set string) ([]string, error) {
	return b.sets[set], nil
}
func (reconcileStubBackend) ReplaceSet(table, set string, e []SetElement) error { return nil }

func TestReconcile_KeepsSourcedEntryMissingFromKernel(t *testing.T) {
	si := NewSourceIndex(filepath.Join(t.TempDir(), "source_index.jsonl"))
	si.Add("blacklist_ipv4", "203.0.113.0/24", "feeds") // recorded intent, lost from the kernel
	si.Add("blacklist_ipv4", "203.0.113.9", "unknown")    // reconcile's own mirror, gone from the kernel
	si.Add("blacklist_ipv4", "198.51.100.7", "geoban")    // recorded and still in the kernel
	si.Add("blacklist_ipv4", "192.0.2.44", "unknown")     // mirror and also sourced
	si.Add("blacklist_ipv4", "192.0.2.44", "module")

	si.ReconcileWithBackend(reconcileStubBackend{sets: map[string][]string{
		"blacklist_ipv4": {"198.51.100.7", "192.0.2.200"}, // 192.0.2.200 = kernel-only (documentation range)
	}})

	got := si.GetAllElements("blacklist_ipv4")
	for _, want := range []string{"203.0.113.0/24", "198.51.100.7", "192.0.2.44", "192.0.2.200"} {
		if !got[want] {
			t.Errorf("%s must be in the index after reconcile, got %v", want, got)
		}
	}
	if got["203.0.113.9"] {
		t.Errorf("an unknown-only entry missing from the kernel must be dropped")
	}
	if src := si.GetElementsBySource("blacklist_ipv4", "unknown"); !reconcileContains(src, "192.0.2.200") {
		t.Errorf("kernel-only element must be mirrored as unknown, got %v", src)
	}
}

// The persisted format of releases <= v1.202.0 (queue-sourced "feeds" records): loaded, then kept
// across reconcile when its element is not in the kernel (the 2026-11-11 legacy reproduction).
func TestReconcile_KeepsLegacyPersistedFeedRecord(t *testing.T) {
	p := filepath.Join(t.TempDir(), "source_index.jsonl")
	legacy := `{"set":"blacklist_ipv4","element":"203.0.113.0/24","sources":["feeds"],"updated":1780000000}` + "\n"
	if err := os.WriteFile(p, []byte(legacy), 0o600); err != nil {
		t.Fatal(err)
	}
	si := NewSourceIndex(p)
	if err := si.LoadFromDisk(); err != nil {
		t.Fatal(err)
	}
	if !si.GetAllElements("blacklist_ipv4")["203.0.113.0/24"] {
		t.Fatal("legacy record not loaded")
	}
	si.ReconcileWithBackend(reconcileStubBackend{sets: map[string][]string{"blacklist_ipv4": nil}})
	if !si.GetAllElements("blacklist_ipv4")["203.0.113.0/24"] {
		t.Fatal("legacy feeds record deleted by reconcile on kernel absence")
	}
}

// Explicit removal and expiry are unchanged: an unbanned (Removed) entry stays gone, and an
// expired timed entry is pruned, whether or not reconcile runs.
func TestReconcile_UnbanAndExpiryUnchanged(t *testing.T) {
	si := NewSourceIndex(filepath.Join(t.TempDir(), "source_index.jsonl"))
	si.Add("blacklist_manual_ipv4", "198.51.100.22", "cli")
	si.Remove("blacklist_manual_ipv4", "198.51.100.22", "cli") // explicit unban
	si.AddWithExpiry("blacklist_manual_ipv4", "198.51.100.23", "botscan", time.Now().Add(-time.Second).Unix())

	si.ReconcileWithBackend(reconcileStubBackend{sets: map[string][]string{"blacklist_manual_ipv4": nil}})
	if n := si.PruneExpired(); n != 1 {
		t.Errorf("expired timed entry must be pruned once, pruned=%d", n)
	}
	got := si.GetAllElements("blacklist_manual_ipv4")
	if got["198.51.100.22"] {
		t.Errorf("an explicitly removed (unbanned) entry must not come back")
	}
	if got["198.51.100.23"] {
		t.Errorf("an expired timed entry must stay expired")
	}
}

func reconcileContains(xs []string, v string) bool {
	for _, x := range xs {
		if x == v {
			return true
		}
	}
	return false
}
