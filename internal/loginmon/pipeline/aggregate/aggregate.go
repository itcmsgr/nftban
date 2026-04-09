// =============================================================================
// NFTBan v1.80 - pipeline aggregation
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: aggregate
// Purpose: Per-IP, per-account, sliding-window counters for the detection pipeline.
//
// meta:name="loginmon_pipeline_aggregate"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="aggregate"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Per-IP / per-account counters + sliding windows + Effective-axis snapshot"
//
// meta:inventory.files="aggregate.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package aggregate implements the v1.80 aggregation layer.
//
// Aggregation answers two questions:
//
//  1. Classic brute-force: how many failures has this single IP produced?
//  2. Distributed spray: how many distinct IPs have hit this single account?
//
// Both are answered per source, over multiple sliding windows. The
// Aggregator publishes a Snapshot that downstream consumers (the future
// Effective-axis health predicate, the validator JSON, the CLI) read.
//
// Aggregator OWNs the counters; it does NOT make ban decisions. The
// existing scorer (internal/loginmon/detector/scorer.go) is unchanged in
// Phase A. Phase E will add a thin signal layer that the scorer can
// optionally consume; until then aggregation is observe-only.
package aggregate

import (
	"net/netip"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
)

// DefaultWindows are the sliding window sizes the aggregator tracks per
// source. Each window is a single Bucket that resets when the window expires.
//
// Phase A keeps the implementation simple: one bucket per (source, window),
// reset when wall-clock advances past the window. Phase E may upgrade to
// rolling sub-buckets for smoother sliding behavior.
var DefaultWindows = []time.Duration{
	5 * time.Minute,
	10 * time.Minute,
	1 * time.Hour,
}

// Bucket holds counts for one (source, window) pair.
//
// Bucket is intentionally bounded:
//
//   - PerIP and PerAccount are capped (MaxIPs, MaxAccounts) to prevent
//     unbounded memory growth on hostile or noisy hosts.
//   - When the cap is hit, the bucket flags Truncated=true and stops
//     accepting new keys, but continues counting EventCount. The
//     Effective-axis predicate treats Truncated buckets as "more diverse
//     than measured", which is conservative.
type Bucket struct {
	Source     string
	Window     time.Duration
	WindowStart time.Time
	WindowEnd   time.Time

	EventCount int
	BanCount   int

	PerIP             map[netip.Addr]int
	PerAccount        map[string]int
	UniqueIPsByAccount map[string]map[netip.Addr]struct{}
	UniqueAccountsByIP map[netip.Addr]map[string]struct{}

	Truncated bool
}

// Bucket size caps. These are intentionally generous; observed traffic on
// the production fleet is far below these.
const (
	MaxIPsPerBucket      = 16384
	MaxAccountsPerBucket = 4096
)

// newBucket constructs a fresh Bucket aligned to the window boundary.
func newBucket(source string, window time.Duration, now time.Time) *Bucket {
	start := now.Truncate(window)
	return &Bucket{
		Source:             source,
		Window:             window,
		WindowStart:        start,
		WindowEnd:          start.Add(window),
		PerIP:              make(map[netip.Addr]int),
		PerAccount:         make(map[string]int),
		UniqueIPsByAccount: make(map[string]map[netip.Addr]struct{}),
		UniqueAccountsByIP: make(map[netip.Addr]map[string]struct{}),
	}
}

// recordEvent updates the bucket counters for a NormalizedEvent.
func (b *Bucket) recordEvent(e event.NormalizedEvent) {
	b.EventCount++
	if e.SrcIP.IsValid() {
		if len(b.PerIP) < MaxIPsPerBucket {
			b.PerIP[e.SrcIP]++
		} else {
			b.Truncated = true
		}
	}
	if e.Username != "" {
		if len(b.PerAccount) < MaxAccountsPerBucket {
			b.PerAccount[e.Username]++
		} else {
			b.Truncated = true
		}
		if e.SrcIP.IsValid() {
			set, ok := b.UniqueIPsByAccount[e.Username]
			if !ok {
				if len(b.UniqueIPsByAccount) < MaxAccountsPerBucket {
					set = make(map[netip.Addr]struct{})
					b.UniqueIPsByAccount[e.Username] = set
				}
			}
			if set != nil {
				set[e.SrcIP] = struct{}{}
			}
			set2, ok := b.UniqueAccountsByIP[e.SrcIP]
			if !ok {
				if len(b.UniqueAccountsByIP) < MaxIPsPerBucket {
					set2 = make(map[string]struct{})
					b.UniqueAccountsByIP[e.SrcIP] = set2
				}
			}
			if set2 != nil {
				set2[e.Username] = struct{}{}
			}
		}
	}
}

// Aggregator owns one Bucket per (source, window) pair.
//
// Aggregator is safe for concurrent use. The pipeline calls Ingest from one
// or more parser goroutines, and Snapshot from a status/validator goroutine.
type Aggregator struct {
	mu      sync.RWMutex
	windows []time.Duration
	now     func() time.Time

	// buckets[source][window] = current bucket
	buckets map[string]map[time.Duration]*Bucket
}

// AggregatorOptions configures NewAggregator.
type AggregatorOptions struct {
	Windows []time.Duration  // default DefaultWindows
	Now     func() time.Time // injectable clock for tests
}

// NewAggregator constructs an Aggregator with the given options.
func NewAggregator(opts AggregatorOptions) *Aggregator {
	if len(opts.Windows) == 0 {
		opts.Windows = DefaultWindows
	}
	if opts.Now == nil {
		opts.Now = time.Now
	}
	return &Aggregator{
		windows: opts.Windows,
		now:     opts.Now,
		buckets: make(map[string]map[time.Duration]*Bucket),
	}
}

// Ingest records a NormalizedEvent into all (source, window) buckets.
//
// If the event timestamp falls outside the current bucket's window, the
// bucket is rolled over (the old bucket is discarded — Phase A keeps only
// the current window for each size; Phase E may add ring buffers).
func (a *Aggregator) Ingest(e event.NormalizedEvent) {
	if e.Source == "" {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()

	now := a.now()
	srcBuckets, ok := a.buckets[e.Source]
	if !ok {
		srcBuckets = make(map[time.Duration]*Bucket, len(a.windows))
		a.buckets[e.Source] = srcBuckets
	}

	for _, w := range a.windows {
		b, ok := srcBuckets[w]
		if !ok || now.After(b.WindowEnd) || (!e.Timestamp.IsZero() && e.Timestamp.After(b.WindowEnd)) {
			b = newBucket(e.Source, w, now)
			srcBuckets[w] = b
		}
		b.recordEvent(e)
	}
}

// RecordBan records a ban observed for the given source. Used by the future
// signal bridge from the existing scorer to feed bans/events ratios into
// the Effective axis. In Phase A no caller invokes RecordBan; tests do so
// directly.
func (a *Aggregator) RecordBan(source string, at time.Time) {
	if source == "" {
		return
	}
	a.mu.Lock()
	defer a.mu.Unlock()

	now := a.now()
	srcBuckets, ok := a.buckets[source]
	if !ok {
		srcBuckets = make(map[time.Duration]*Bucket, len(a.windows))
		a.buckets[source] = srcBuckets
	}
	for _, w := range a.windows {
		b, ok := srcBuckets[w]
		if !ok || now.After(b.WindowEnd) {
			b = newBucket(source, w, now)
			srcBuckets[w] = b
		}
		b.BanCount++
	}
}

// Snapshot is a read-only view of the aggregator state at a moment in time.
type Snapshot struct {
	GeneratedAt time.Time
	Sources     map[string]SourceSnapshot
}

// SourceSnapshot is the per-source view inside a Snapshot.
type SourceSnapshot struct {
	Source  string
	Windows map[time.Duration]WindowSnapshot
}

// WindowSnapshot is the per-(source, window) view inside a SourceSnapshot.
//
// All fields are computed at snapshot time and are safe to read without
// locking the aggregator.
type WindowSnapshot struct {
	Window           time.Duration
	WindowStart      time.Time
	WindowEnd        time.Time
	EventCount       int
	BanCount         int
	UniqueIPs        int
	UniqueAccounts   int
	MaxIPsPerAccount int
	MaxAccountsPerIP int
	Truncated        bool
	Ratio            float64 // BanCount / EventCount; 1.0 if EventCount==0
}

// Snapshot returns a read-only view of the aggregator. Cheap on small
// fleets; downstream callers should cache for ~60 seconds.
func (a *Aggregator) Snapshot() Snapshot {
	a.mu.RLock()
	defer a.mu.RUnlock()

	snap := Snapshot{
		GeneratedAt: a.now(),
		Sources:     make(map[string]SourceSnapshot, len(a.buckets)),
	}

	for srcName, srcBuckets := range a.buckets {
		ss := SourceSnapshot{
			Source:  srcName,
			Windows: make(map[time.Duration]WindowSnapshot, len(srcBuckets)),
		}
		for w, b := range srcBuckets {
			ws := WindowSnapshot{
				Window:      w,
				WindowStart: b.WindowStart,
				WindowEnd:   b.WindowEnd,
				EventCount:  b.EventCount,
				BanCount:    b.BanCount,
				UniqueIPs:   len(b.PerIP),
				UniqueAccounts: len(b.PerAccount),
				Truncated:   b.Truncated,
			}
			for _, ipSet := range b.UniqueIPsByAccount {
				if n := len(ipSet); n > ws.MaxIPsPerAccount {
					ws.MaxIPsPerAccount = n
				}
			}
			for _, acctSet := range b.UniqueAccountsByIP {
				if n := len(acctSet); n > ws.MaxAccountsPerIP {
					ws.MaxAccountsPerIP = n
				}
			}
			if b.EventCount == 0 {
				ws.Ratio = 1.0
			} else {
				ws.Ratio = float64(b.BanCount) / float64(b.EventCount)
			}
			ss.Windows[w] = ws
		}
		snap.Sources[srcName] = ss
	}
	return snap
}

// === Effective axis scaffold (Phase A: types only, no state machine yet) ===

// EffectiveState is the v1.80 health-axis state for one (source, window).
type EffectiveState int

const (
	EffectiveActive   EffectiveState = iota // detection translating to bans, or insufficient signal
	EffectiveDegraded                       // real volume, multiple sources, weak enforcement
	EffectiveFailing                        // heavy volume, many sources, near-zero enforcement
)

// String satisfies fmt.Stringer.
func (s EffectiveState) String() string {
	switch s {
	case EffectiveActive:
		return "ACTIVE"
	case EffectiveDegraded:
		return "DEGRADED"
	case EffectiveFailing:
		return "FAILING"
	}
	return "INVALID"
}

// EffectiveSnapshot is the per-source effective-axis evaluation.
//
// Phase A defines the type only. Phase E will add the state-machine
// implementation that maps WindowSnapshot to EffectiveSnapshot.
type EffectiveSnapshot struct {
	Source           string
	Window           time.Duration
	EvaluatedAt      time.Time
	EventsInWindow   int
	BansInWindow     int
	UniqueAttackers  int
	Ratio            float64
	State            EffectiveState
	Reason           string
}
