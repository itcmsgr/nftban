// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package stats

// v1.238 BUG-SETCOUNTERS-SNAPSHOT-NESTED-RLOCK-DEADLOCK (owner 2026-11-25, monitor incident).
// Snapshot() held sc.mu.RLock() and then called RecommendedExporterInterval() -> GlobalScale(),
// which took sc.mu.RLock() AGAIN. sync.RWMutex forbids recursive read locking: when a writer
// (Set/Add/SetReconciled) waits between the two RLocks, the second RLock blocks behind the waiting
// writer while the first is never released — the reader and the writer wait for each other forever.
// On monitor the writer was the hourly reconciliation, which held the exclusive nft_operations.lock,
// so every CLI convergence operation was REFUSED for 30 h.
//
// The ordered test does not depend on runner speed: the hook runs while Snapshot holds its read
// lock, starts a writer, and waits until that writer is provably queued (TryRLock fails only when a
// writer holds or waits for the lock). Only then does Snapshot continue. With the nested RLock the
// snapshot never returns; with one RLock it returns and the writer completes after it.

import (
	"runtime"
	"sync"
	"testing"
	"time"
)

func TestSnapshotWithWriterQueuedBetweenLocksCompletes(t *testing.T) {
	sc := NewSetCounters(t.TempDir())
	sc.Set("blacklist_ipv4", 5)

	writerDone := make(chan struct{})
	writerQueued := false
	testHookSnapshotHoldsRLock = func() {
		go func() {
			sc.Set("ssh_ports", 1) // the writer the reconciliation was: needs sc.mu.Lock()
			close(writerDone)
		}()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if sc.mu.TryRLock() { // succeeds only while no writer is holding or waiting
				sc.mu.RUnlock()
				runtime.Gosched()
				continue
			}
			writerQueued = true
			return
		}
	}
	t.Cleanup(func() { testHookSnapshotHoldsRLock = nil })

	snapDone := make(chan SetCountSnapshot, 1)
	go func() { snapDone <- sc.Snapshot() }()

	select {
	case snap := <-snapDone:
		if !writerQueued {
			t.Fatal("precondition not reached: the writer was never observed waiting while Snapshot held its lock (test is vacuous)")
		}
		if snap.ScaleMode == "" || snap.ExporterInterval <= 0 {
			t.Fatalf("snapshot incomplete: scale=%q interval=%d", snap.ScaleMode, snap.ExporterInterval)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("DEADLOCK: Snapshot did not return while a writer was queued between its read locks (nested RLock)")
	}
	select {
	case <-writerDone:
	case <-time.After(5 * time.Second):
		t.Fatal("writer never acquired the lock after Snapshot returned")
	}
	if got := sc.Get("ssh_ports"); got != 1 {
		t.Fatalf("writer result lost: ssh_ports=%d, want 1", got)
	}
}

// Complementary stress (run with -race in CI): concurrent snapshots, cache writes and every writer
// kind must all finish; a nested read lock shows up here as a hang caught by the deadline.
func TestSnapshotConcurrentWithWritersStress(t *testing.T) {
	sc := NewSetCounters(t.TempDir())
	const rounds = 2000
	var wg sync.WaitGroup
	done := make(chan struct{})
	work := []func(i int){
		func(i int) { _ = sc.Snapshot() },
		func(i int) { _ = sc.WriteCacheFile() },
		func(i int) { sc.Set("blacklist_ipv4", int64(i)) },
		func(i int) { sc.Add("blacklist_ipv6", 1) },
		func(i int) { sc.SetReconciled("whitelist_ipv4", int64(i%7)) },
		func(i int) { _ = sc.GlobalScale(); _ = sc.RecommendedExporterInterval(); _ = sc.AllSets() },
	}
	for _, f := range work {
		wg.Add(1)
		go func(f func(int)) {
			defer wg.Done()
			for i := 0; i < rounds; i++ {
				f(i)
			}
		}(f)
	}
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(60 * time.Second):
		t.Fatal("DEADLOCK under concurrent Snapshot/WriteCacheFile/Set/Add/SetReconciled")
	}
}

// The interval Snapshot reports must be the one RecommendedExporterInterval gives for the same counts.
func TestSnapshotIntervalMatchesRecommended(t *testing.T) {
	sc := NewSetCounters(t.TempDir())
	for _, n := range []int64{0, 1000, 600000, 3000000} {
		sc.Set("blacklist_ipv4", n)
		snap := sc.Snapshot()
		if want := int(sc.RecommendedExporterInterval().Seconds()); snap.ExporterInterval != want {
			t.Errorf("count %d: snapshot interval %d, RecommendedExporterInterval %d", n, snap.ExporterInterval, want)
		}
		if snap.ScaleMode != sc.GlobalScale() {
			t.Errorf("count %d: snapshot scale %q, GlobalScale %q", n, snap.ScaleMode, sc.GlobalScale())
		}
	}
}
