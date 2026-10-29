// =============================================================================
// NFTBan v1.236 - safety lane stage 1: permanent upsert (hermetic)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="setsync/permanent_upsert_v1236_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="Hermetic proof of UpsertPermanentElements (BUG-UPGRADE-SYNC-SCALES-WITH-PERMANENT-BANS-TIMEOUT-AND-ENFORCEMENT-GAP stage 1): the planner (absent/timed/permanent), ONE transaction per plan with delete-before-add and a single Flush, nothing counted when the commit is rejected, a rejected (ENOENT) commit re-planned from a fresh read, every key counted once across retries, Converged=false reported when another writer keeps changing elements, interval sets refused, invalid/wrong-family input counted and never queued. Recording fakes only: no nft, netlink or root."
// =============================================================================

package setsync

import (
	"errors"
	"fmt"
	"os"
	"testing"
	"time"

	"github.com/google/nftables"
)

type upsertFake struct {
	order       []string
	deleted     int
	added       int
	flushes     int
	flushErrs   []error // consumed one per Flush; nil entry = success
}

func (f *upsertFake) SetDeleteElements(s *nftables.Set, v []nftables.SetElement) error {
	f.order = append(f.order, "del")
	f.deleted += len(v)
	return nil
}
func (f *upsertFake) SetAddElements(s *nftables.Set, v []nftables.SetElement) error {
	f.order = append(f.order, "add")
	f.added += len(v)
	return nil
}
func (f *upsertFake) Flush() error {
	f.order = append(f.order, "flush")
	f.flushes++
	if len(f.flushErrs) == 0 {
		return nil
	}
	e := f.flushErrs[0]
	f.flushErrs = f.flushErrs[1:]
	return e
}

// readerSeq returns, read after read, the given set contents.
type readerSeq struct{ states [][]nftables.SetElement }

func (r *readerSeq) GetSetElements(*nftables.Set) ([]nftables.SetElement, error) {
	if len(r.states) == 0 {
		return nil, fmt.Errorf("no more reads scripted")
	}
	s := r.states[0]
	if len(r.states) > 1 {
		r.states = r.states[1:]
	}
	return s, nil
}

func k4(ip string) []byte { k, _ := canonicalHashKey(ip, true); return k }
func perm(ip string) nftables.SetElement { return nftables.SetElement{Key: k4(ip)} }
func timedEl(ip string) nftables.SetElement {
	return nftables.SetElement{Key: k4(ip), Timeout: time.Hour, Expires: 30 * time.Minute}
}

func TestPlanPermanentUpsert(t *testing.T) {
	cur := []nftables.SetElement{perm("192.0.2.1"), timedEl("192.0.2.2"), perm("192.0.2.9")}
	add, rep, unch := planPermanentUpsert(cur, [][]byte{k4("192.0.2.1"), k4("192.0.2.2"), k4("192.0.2.3")})
	if len(add) != 1 || len(rep) != 1 || unch != 1 {
		t.Fatalf("plan: add=%d replace=%d unchanged=%d, want 1/1/1", len(add), len(rep), unch)
	}
}

func TestCommitPermanentUpsertOneTransaction(t *testing.T) {
	f := &upsertFake{}
	add := [][]byte{k4("192.0.2.3")}
	rep := [][]byte{k4("192.0.2.2")}
	if err := commitPermanentUpsert(f, v4Set(), add, rep); err != nil {
		t.Fatal(err)
	}
	if f.flushes != 1 || f.deleted != 1 || f.added != 2 {
		t.Fatalf("one transaction: flushes=%d deleted=%d added=%d, want 1/1/2", f.flushes, f.deleted, f.added)
	}
	if f.order[0] != "del" || f.order[len(f.order)-1] != "flush" {
		t.Fatalf("order %v: delete must precede add, single flush last", f.order)
	}
	// Large plans are queued in batches on the SAME transaction (one flush).
	big := make([][]byte, 0, 2500)
	for i := 0; i < 2500; i++ {
		big = append(big, k4(fmt.Sprintf("198.18.%d.%d", i/250, i%250)))
	}
	g := &upsertFake{}
	if err := commitPermanentUpsert(g, v4Set(), big, nil); err != nil {
		t.Fatal(err)
	}
	if g.flushes != 1 || g.added != 2500 {
		t.Fatalf("2500: flushes=%d added=%d, want 1/2500", g.flushes, g.added)
	}
}

func run(t *testing.T, reads [][]nftables.SetElement, flushErrs []error, values []string) (*SyncStats, *upsertFake, error) {
	t.Helper()
	f := &upsertFake{flushErrs: flushErrs}
	r := &readerSeq{states: reads}
	st, err := upsertPermanentElements(v4Set(), values,
		func() (setReader, error) { return r, nil },
		func() (upsertConn, error) { return f, nil })
	return st, f, err
}

func TestUpsertConvergesAndCountsAcknowledgedEffects(t *testing.T) {
	before := []nftables.SetElement{perm("192.0.2.1"), timedEl("192.0.2.2")}
	after := []nftables.SetElement{perm("192.0.2.1"), perm("192.0.2.2"), perm("192.0.2.3")}
	st, f, err := run(t, [][]nftables.SetElement{before, after}, nil,
		[]string{"192.0.2.1", "192.0.2.2", "192.0.2.3", "192.0.2.3", "2001:db8::1", "bad"})
	if err != nil || !st.Converged {
		t.Fatalf("err=%v converged=%v", err, st.Converged)
	}
	if st.IPsAdded != 1 || st.IPsReplaced != 1 || st.IPsUnchanged != 1 || st.IPsInvalid != 2 || f.flushes != 1 {
		t.Fatalf("got %+v flushes=%d, want added=1 replaced=1 unchanged=1 invalid=2 flushes=1", *st, f.flushes)
	}
}

func TestUpsertRejectedCommitCountsNothingAndReplans(t *testing.T) {
	// The timed element expired before our commit: the delete fails ENOENT, the WHOLE transaction
	// is rejected (nothing applied), then a fresh read plans a plain add.
	r1 := []nftables.SetElement{timedEl("192.0.2.2")}
	r2 := []nftables.SetElement{}
	r3 := []nftables.SetElement{perm("192.0.2.2")}
	st, f, err := run(t, [][]nftables.SetElement{r1, r2, r3}, []error{os.ErrNotExist, nil}, []string{"192.0.2.2"})
	if err != nil || !st.Converged {
		t.Fatalf("err=%v converged=%v", err, st.Converged)
	}
	if st.IPsAdded != 1 || st.IPsReplaced != 0 || f.flushes != 2 {
		t.Fatalf("rejected commit must count nothing: got %+v flushes=%d, want added=1 replaced=0 flushes=2", *st, f.flushes)
	}
}

func TestUpsertConcurrentWriterCountedOnceAndBounded(t *testing.T) {
	// After each commit another writer makes the key timed again: one corrective commit, then
	// stop (bounded), report not-converged, and never count the key twice.
	timedState := []nftables.SetElement{timedEl("192.0.2.2")}
	st, f, err := run(t, [][]nftables.SetElement{timedState, timedState, timedState}, nil, []string{"192.0.2.2"})
	if err != nil {
		t.Fatalf("err=%v", err)
	}
	if st.Converged {
		t.Fatal("must report Converged=false when another writer keeps changing the element")
	}
	if st.IPsReplaced != 1 || f.flushes != upsertMaxCommits {
		t.Fatalf("got %+v flushes=%d, want replaced counted once, flushes=%d", *st, f.flushes, upsertMaxCommits)
	}
}

func TestUpsertHardCommitFailureReturnsError(t *testing.T) {
	st, _, err := run(t, [][]nftables.SetElement{{}}, []error{errors.New("netlink: permission denied")}, []string{"192.0.2.5"})
	if err == nil || st.IPsAdded != 0 {
		t.Fatalf("hard failure: err=%v stats=%+v, want error and nothing counted", err, *st)
	}
}

func TestUpsertRefusesIntervalSet(t *testing.T) {
	iv := &nftables.Set{Name: "blacklist_ipv4", KeyType: nftables.TypeIPAddr, Interval: true}
	_, err := upsertPermanentElements(iv, []string{"192.0.2.1"},
		func() (setReader, error) { t.Fatal("must not read"); return nil, nil },
		func() (upsertConn, error) { t.Fatal("must not open a transaction"); return nil, nil })
	if err == nil {
		t.Fatal("interval set must be refused (owned by the FULL-sync path)")
	}
}
