// =============================================================================
// NFTBan v1.80 - pipeline dedup
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: dedup
// Purpose: Bounded LRU sieve to suppress duplicate events from overlapping sources.
//
// meta:name="loginmon_pipeline_dedup"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="dedup"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Bounded dedup sieve for overlapping parser sources"
//
// meta:inventory.files="dedup.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package dedup provides a bounded LRU sieve that suppresses duplicate
// events. It is used by the pipeline to absorb overlap from sources that
// record the same event in two places (e.g. DirectAdmin login.log AND
// security.log) and to handle re-reads after watcher reopen.
//
// The dedup key is intentionally narrow: (Reason, SrcIP, Username, time
// bucket). Two records with the same key within the dedup window are
// considered the same event. The default window is 5 seconds.
package dedup

import (
	"container/list"
	"net/netip"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
)

// DefaultWindow is the dedup time bucket size. Two events with identical
// (Reason, SrcIP, Username) falling within this window are considered the
// same event.
const DefaultWindow = 5 * time.Second

// DefaultCapacity is the maximum number of keys held by the sieve.
//
// LRU eviction kicks in when the sieve is full. At ~100 bytes per entry
// this is ~6.5 MB total. Sized for sustained > 13,000 events/sec on a
// single host without losing dedup precision; far above observed traffic.
const DefaultCapacity = 65536

// Key is the dedup identity for an event.
//
// Composition is intentionally narrow: events from different parsers (e.g.
// SSH brute and dovecot brute from the same IP) have different Reason
// values and are therefore distinct events. The TimeBucket is the event
// timestamp truncated to the sieve's window.
type Key struct {
	Reason     event.Reason
	SrcIP      netip.Addr
	Username   string
	TimeBucket int64 // event timestamp truncated to window resolution, Unix seconds
}

// KeyFromEvent computes the canonical Key for a NormalizedEvent given a
// dedup window.
func KeyFromEvent(e event.NormalizedEvent, window time.Duration) Key {
	if window <= 0 {
		window = DefaultWindow
	}
	return Key{
		Reason:     e.Reason,
		SrcIP:      e.SrcIP,
		Username:   e.Username,
		TimeBucket: e.Timestamp.Truncate(window).Unix(),
	}
}

// Sieve is a bounded LRU dedup window.
//
// Operations:
//
//	Admit(event)  - returns true if the event is new in the window, false
//	                if it is a duplicate. Inserts new keys and updates LRU
//	                order on hit.
//
// Sieve is safe for concurrent use.
type Sieve struct {
	mu       sync.Mutex
	window   time.Duration
	capacity int
	now      func() time.Time

	order *list.List               // doubly-linked list of *entry, MRU at front
	index map[Key]*list.Element    // key -> list element
}

type entry struct {
	key      Key
	insertAt time.Time
}

// SieveOptions configures NewSieve.
type SieveOptions struct {
	Window   time.Duration
	Capacity int
	Now      func() time.Time // injectable clock for tests
}

// NewSieve constructs a Sieve with the given options.
func NewSieve(opts SieveOptions) *Sieve {
	if opts.Window <= 0 {
		opts.Window = DefaultWindow
	}
	if opts.Capacity <= 0 {
		opts.Capacity = DefaultCapacity
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}
	return &Sieve{
		window:   opts.Window,
		capacity: opts.Capacity,
		now:      opts.Now,
		order:    list.New(),
		index:    make(map[Key]*list.Element, opts.Capacity),
	}
}

// Admit reports whether the event is new in the window.
//
// Returns true if the event has not been seen recently (and inserts it).
// Returns false if the same key was already admitted within the dedup
// window.
//
// Capacity-based eviction: when the sieve is full, the oldest entry is
// evicted regardless of age. This is intentionally simple — under
// sustained load the dedup window effectively shrinks. The aggregator is
// the long-memory layer; dedup is the immediate-duplicate sieve.
func (s *Sieve) Admit(e event.NormalizedEvent) bool {
	key := KeyFromEvent(e, s.window)

	s.mu.Lock()
	defer s.mu.Unlock()

	// Evict expired entries lazily.
	s.evictExpired()

	if elt, ok := s.index[key]; ok {
		// Hit: update LRU order, do not admit again.
		s.order.MoveToFront(elt)
		return false
	}

	// Miss: insert. Evict LRU if at capacity.
	if s.order.Len() >= s.capacity {
		oldest := s.order.Back()
		if oldest != nil {
			old := oldest.Value.(*entry)
			delete(s.index, old.key)
			s.order.Remove(oldest)
		}
	}

	elt := s.order.PushFront(&entry{key: key, insertAt: s.now()})
	s.index[key] = elt
	return true
}

// evictExpired removes entries whose insert time is older than the window.
// Called under lock by Admit.
func (s *Sieve) evictExpired() {
	cutoff := s.now().Add(-s.window)
	for s.order.Len() > 0 {
		oldest := s.order.Back()
		ent := oldest.Value.(*entry)
		if ent.insertAt.After(cutoff) {
			return
		}
		delete(s.index, ent.key)
		s.order.Remove(oldest)
	}
}

// Len returns the number of keys currently held. Test/diagnostic helper.
func (s *Sieve) Len() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.order.Len()
}
