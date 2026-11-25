// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package analytics

// v1.238 BUG-ANALYTICS-GETSUMMARY-NESTED-RLOCK (owner 2026-11-25; same defect class as
// BUG-SETCOUNTERS-SNAPSHOT-NESTED-RLOCK-DEADLOCK). GetSummary() held s.mu.RLock() and called
// GetCountryStats(), which took s.mu.RLock() again; a RecordBan() writer waiting between the two
// deadlocks both. Ordered like the stats test: the hook queues a real RecordBan writer while
// GetSummary holds its lock and proves it is queued (TryRLock fails only with a writer holding or
// waiting) before the summary continues.

import (
	"container/list"
	"runtime"
	"sync"
	"testing"
	"time"
)

func newTestState() *State {
	return &State{
		countries:        map[string]*CountryStats{},
		ipOrigins:        map[string]*IPOrigin{},
		ipOriginsLRU:     list.New(),
		maxIPOrigins:     1000,
		maxIPsPerCountry: 1000,
	}
}

func TestSummaryWithWriterQueuedBetweenLocksCompletes(t *testing.T) {
	s := newTestState()
	s.RecordBan("198.51.100.1", "DE", "", "portscan", "portscan:stealth", time.Now())

	writerDone := make(chan struct{})
	writerQueued := false
	testHookSummaryHoldsRLock = func() {
		go func() {
			s.RecordBan("198.51.100.2", "FR", "", "loginmon", "ssh", time.Now())
			close(writerDone)
		}()
		deadline := time.Now().Add(5 * time.Second)
		for time.Now().Before(deadline) {
			if s.mu.TryRLock() {
				s.mu.RUnlock()
				runtime.Gosched()
				continue
			}
			writerQueued = true
			return
		}
	}
	t.Cleanup(func() { testHookSummaryHoldsRLock = nil })

	done := make(chan *AnalyticsSummary, 1)
	go func() { done <- s.GetSummary() }()
	select {
	case sum := <-done:
		if !writerQueued {
			t.Fatal("precondition not reached: the writer was never observed waiting while GetSummary held its lock (test is vacuous)")
		}
		// The summary is one consistent view taken BEFORE the queued writer ran.
		if sum.TotalCountries != 1 || len(sum.Countries) != 1 || sum.Countries["DE"] == nil {
			t.Fatalf("summary not consistent with the state at lock time: countries=%d map=%v", sum.TotalCountries, sum.Countries)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("DEADLOCK: GetSummary did not return while a writer was queued between its read locks (nested RLock)")
	}
	select {
	case <-writerDone:
	case <-time.After(5 * time.Second):
		t.Fatal("writer never acquired the lock after GetSummary returned")
	}
	if got := len(s.GetCountryStats()); got != 2 {
		t.Fatalf("writer result lost: %d countries, want 2", got)
	}
}

func TestSummaryConcurrentWithRecordBanStress(t *testing.T) {
	s := newTestState()
	var wg sync.WaitGroup
	done := make(chan struct{})
	for g := 0; g < 4; g++ {
		wg.Add(1)
		go func(g int) {
			defer wg.Done()
			for i := 0; i < 1500; i++ {
				switch g {
				case 0:
					_ = s.GetSummary()
				case 1:
					s.RecordBan("203.0.113.7", []string{"DE", "FR", "GR"}[i%3], "", "portscan", "x", time.Now())
				case 2:
					_ = s.GetCountryStats()
					_ = s.GetTopCountries(3)
				default:
					_ = s.GetStats()
				}
			}
		}(g)
	}
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(60 * time.Second):
		t.Fatal("DEADLOCK under concurrent GetSummary/RecordBan/GetCountryStats")
	}
}
