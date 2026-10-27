package opqueue

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

// applyRecorder records every AddElements call that reaches the backend. A call for a set is
// what would create it (the daemon's wrapper get-or-creates), so "no call" = "no creation".
type applyRecorder struct {
	mu    sync.Mutex
	calls map[string]int
	ttl   map[string]uint32 // set|element -> TTL
}

func (r *applyRecorder) FlushSet(string, string) error { return nil }
func (r *applyRecorder) AddElements(_ string, set string, els []SetElement) (int, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.calls[set]++
	for _, e := range els {
		r.ttl[set+"|"+e.Value] = e.TTL
	}
	return len(els), nil
}
func (r *applyRecorder) DeleteElements(string, string, []SetElement) error { return nil }
func (r *applyRecorder) GetSetElements(string, string) ([]string, error)   { return nil, nil }
func (r *applyRecorder) ReplaceSet(string, string, []SetElement) error     { return nil }
func (r *applyRecorder) snapshot(set, elem string) (int, uint32, bool) {
	r.mu.Lock()
	defer r.mu.Unlock()
	v, ok := r.ttl[set+"|"+elem]
	return r.calls[set], v, ok
}

const guardedSet = "campaign_prefix_ipv4"

// pausedQueue: started (enqueue needs a running queue) but never flushing on its own.
func pausedQueue(t *testing.T, guard ApplyGuard) (*OpQueue, *applyRecorder) {
	t.Helper()
	rec := &applyRecorder{calls: map[string]int{}, ttl: map[string]uint32{}}
	cfg := DefaultQueueConfig()
	cfg.FlushThreshold = 1 << 30
	cfg.FlushInterval = time.Hour
	q := NewOpQueue(rec, cfg)
	q.SetApplyGuard(guard)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	q.Start(ctx)
	return q, rec
}

func flushAndWait(q *OpQueue, set string) {
	q.triggerFlush(set)
	time.Sleep(150 * time.Millisecond)
}

// The decision is taken at application: a state change while the add is queued (disable,
// drop rule removed, never-ban overlap) refuses it, before the backend runs.
func TestApplyGuardDecidesAtApplication(t *testing.T) {
	for _, why := range []string{"campaign disabled", "drop rule not live", "never-ban admission: overlaps-exempt"} {
		t.Run(why, func(t *testing.T) {
			var mu sync.Mutex
			refuse := "" // admitted when enqueued
			q, rec := pausedQueue(t, func(set, _ string) error {
				mu.Lock()
				defer mu.Unlock()
				if set == guardedSet && refuse != "" {
					return errors.New(refuse)
				}
				return nil
			})
			if err := q.EnqueueBan(guardedSet, "45.33.32.0/24", 3600, "botscan-campaign", "t"); err != nil {
				t.Fatal(err)
			}
			mu.Lock()
			refuse = why // changes while the add sits in the queue
			mu.Unlock()
			flushAndWait(q, guardedSet)
			calls, _, applied := rec.snapshot(guardedSet, "45.33.32.0/24")
			if applied || calls != 0 {
				t.Fatalf("queued add reached the backend (calls=%d applied=%v): it could create or refill the set", calls, applied)
			}
		})
	}
}

// Positive control: an add admitted at application reaches the backend with its TTL, and the
// guard leaves every other set alone.
func TestApplyGuardAdmitsAndScopesToItsSet(t *testing.T) {
	q, rec := pausedQueue(t, func(set, _ string) error {
		if set == guardedSet {
			return nil
		}
		return errors.New("must never be asked about other sets")
	})
	if err := q.EnqueueBan(guardedSet, "45.33.32.0/24", 3600, "botscan-campaign", "t"); err != nil {
		t.Fatal(err)
	}
	flushAndWait(q, guardedSet)
	if _, ttl, ok := rec.snapshot(guardedSet, "45.33.32.0/24"); !ok || ttl != 3600 {
		t.Fatalf("admitted add not applied (ok=%v ttl=%d)", ok, ttl)
	}

	other, rec2 := pausedQueue(t, func(set, _ string) error {
		if set == guardedSet {
			return errors.New("refused")
		}
		return nil
	})
	if err := other.EnqueueBan("blacklist_manual_ipv4", "45.33.32.61", 86400, "botscan", "t"); err != nil {
		t.Fatal(err)
	}
	flushAndWait(other, "blacklist_manual_ipv4")
	if _, _, ok := rec2.snapshot("blacklist_manual_ipv4", "45.33.32.61"); !ok {
		t.Fatal("the campaign guard blocked an unrelated set")
	}
}

// A refusal is reported through the truth-bearing contract and is distinguishable.
func TestApplyGuardRefusalIsReported(t *testing.T) {
	g := guardedBackend{
		NetlinkBackend: &applyRecorder{calls: map[string]int{}, ttl: map[string]uint32{}},
		guard: func(_, e string) error {
			if e == "45.33.33.0/24" {
				return errors.New("refused")
			}
			return nil
		},
	}
	n, err := g.AddElements("ip nftban", guardedSet, []SetElement{{Value: "45.33.32.0/24"}, {Value: "45.33.33.0/24"}})
	if n != 1 || !errors.Is(err, ErrApplyRefused) {
		t.Fatalf("applied=%d err=%v, want 1 and ErrApplyRefused", n, err)
	}
}
