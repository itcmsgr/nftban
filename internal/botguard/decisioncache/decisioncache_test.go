// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: Temporary Decision Cache Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: decisioncache
// Purpose: Prove the v1.191 8B temporary decision cache is correct IN ISOLATION —
//          allowed-states-only, durable rejection, monotonic-TTL expiry, bounded
//          eviction (expired-first then oldest-non-blocked, never durable), IPv6
//          prefix-aggregated candidate accounting that never auto-bans a prefix, and
//          concurrency safety. No guard.go wiring is exercised here (increment 5).
//
// meta:name="botguard_decisioncache_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Unit + race tests for the BotGuard temporary decision cache"
// meta:inventory.files="decisioncache_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package decisioncache

import (
	"fmt"
	"net/netip"
	"sync"
	"testing"
	"time"
)

// fakeClock drives the cache's monotonic + wall clocks deterministically.
type fakeClock struct {
	mono time.Duration
	wall time.Time
}

func newTestCache(cfg Config) (*Cache, *fakeClock) {
	c := New(cfg)
	fc := &fakeClock{wall: time.Unix(1_700_000_000, 0)}
	c.monoNow = func() time.Duration { return fc.mono }
	c.wallNow = func() time.Time { return fc.wall }
	return c, fc
}

func rec(ip string, st State) Record {
	return Record{
		IP:              netip.MustParseAddr(ip),
		RequestClass:    "mixed",
		State:           st,
		Reason:          "test",
		EvidenceSummary: "evidence",
	}
}

func mustPut(t *testing.T, c *Cache, r Record, ttl time.Duration) {
	t.Helper()
	if err := c.Put(r, ttl); err != nil {
		t.Fatalf("Put(%v,%v) unexpected error: %v", r.IP, r.State, err)
	}
}

func TestCACHE_ALLOWED_STATES_ONLY(t *testing.T) {
	c, _ := newTestCache(DefaultConfig())
	mustPut(t, c, rec("1.0.0.1", StateCandidate), 0)
	mustPut(t, c, rec("1.0.0.2", StateChecking), 0)
	mustPut(t, c, rec("1.0.0.3", StateLegitTemporarily), 0)
	mustPut(t, c, rec("1.0.0.4", StateBlockedTemporarily), 60*time.Second)
	mustPut(t, c, rec("1.0.0.5", StateAmbiguous), 0)
	// unknown is the absence sentinel, never storable.
	if err := c.Put(rec("1.0.0.6", StateUnknown), 0); err != ErrInvalidState {
		t.Fatalf("Put(unknown) = %v, want ErrInvalidState", err)
	}
}

func TestCACHE_REJECTS_DURABLE_STATES(t *testing.T) {
	c, _ := newTestCache(DefaultConfig())
	for _, bad := range []State{"trusted_durable", "blocked_durable", "permanent_allow", "blacklist"} {
		if err := c.Put(rec("2.0.0.1", bad), 60*time.Second); err != ErrInvalidState {
			t.Fatalf("Put(%q) = %v, want ErrInvalidState", bad, err)
		}
	}
	if got := c.Stats().InvalidStateAttempts; got != 4 {
		t.Fatalf("InvalidStateAttempts = %d, want 4", got)
	}
	if c.Len() != 0 {
		t.Fatalf("durable Puts must store nothing; Len = %d", c.Len())
	}
}

func TestCACHE_PUT_GET_PEEK(t *testing.T) {
	c, _ := newTestCache(DefaultConfig())
	r := rec("3.0.0.1", StateCandidate)
	r.RequestClass = "scanner"
	r.Host = "shop.example"
	mustPut(t, c, r, 0)

	got, ok := c.Get(netip.MustParseAddr("3.0.0.1"))
	if !ok {
		t.Fatal("Get miss after Put")
	}
	if got.Module != ModuleBotGuard || got.Family != "ipv4" || got.RequestClass != "scanner" || got.State != StateCandidate {
		t.Fatalf("Get returned wrong record: %+v", got)
	}
	pk, ok := c.Peek(netip.MustParseAddr("3.0.0.1"))
	if !ok || pk.State != StateCandidate || pk.RequestClass != "scanner" {
		t.Fatalf("Peek returned wrong record: %+v ok=%v", pk, ok)
	}
	if _, ok := c.Get(netip.MustParseAddr("3.0.0.99")); ok {
		t.Fatal("Get of absent IP must miss")
	}
}

func TestCACHE_PEEK_NO_SIDE_EFFECT(t *testing.T) {
	c, fc := newTestCache(DefaultConfig())
	mustPut(t, c, rec("4.0.0.1", StateChecking), 10*time.Second)
	fc.mono = 11 * time.Second // now expired

	before := c.Stats()
	if _, ok := c.Peek(netip.MustParseAddr("4.0.0.1")); ok {
		t.Fatal("Peek of expired entry must report absent")
	}
	if c.Len() != 1 {
		t.Fatalf("Peek must NOT purge: Len = %d, want 1", c.Len())
	}
	if c.Stats().ExpiredPurges != before.ExpiredPurges {
		t.Fatal("Peek must not mutate stats")
	}
	// Get, by contrast, lazily purges the expired entry.
	if _, ok := c.Get(netip.MustParseAddr("4.0.0.1")); ok {
		t.Fatal("Get of expired entry must report absent")
	}
	if c.Len() != 0 {
		t.Fatalf("Get must purge expired: Len = %d, want 0", c.Len())
	}
}

func TestCACHE_TTL_EXPIRES(t *testing.T) {
	c, fc := newTestCache(DefaultConfig())
	mustPut(t, c, rec("5.0.0.1", StateLegitTemporarily), 10*time.Second)
	fc.mono = 9 * time.Second
	if _, ok := c.Get(netip.MustParseAddr("5.0.0.1")); !ok {
		t.Fatal("entry must be live before TTL")
	}
	fc.mono = 11 * time.Second
	if _, ok := c.Get(netip.MustParseAddr("5.0.0.1")); ok {
		t.Fatal("entry must expire after TTL")
	}
}

func TestCACHE_MONOTONIC_TTL_NO_WALLCLOCK_EXTENSION(t *testing.T) {
	c, fc := newTestCache(DefaultConfig())
	mustPut(t, c, rec("6.0.0.1", StateLegitTemporarily), 10*time.Second)

	// Wall clock leaps FORWARD an hour but only 5s of monotonic elapses → still live.
	fc.wall = fc.wall.Add(time.Hour)
	fc.mono = 5 * time.Second
	if _, ok := c.Peek(netip.MustParseAddr("6.0.0.1")); !ok {
		t.Fatal("forward wall-clock jump must not expire a still-monotonically-live entry")
	}
	// Wall clock leaps BACKWARD two hours; monotonic crosses the deadline → expired.
	// A wall-clock rewind must NOT extend the suppression.
	fc.wall = fc.wall.Add(-2 * time.Hour)
	fc.mono = 11 * time.Second
	if _, ok := c.Peek(netip.MustParseAddr("6.0.0.1")); ok {
		t.Fatal("backward wall-clock jump must not extend legit_temporarily past its monotonic TTL")
	}
}

func TestLEGIT_TEMPORARY_SUPPRESSION_EXPIRES(t *testing.T) {
	cfg := DefaultConfig()
	cfg.LegitTTL = 30 * time.Second
	c, fc := newTestCache(cfg)
	mustPut(t, c, rec("7.0.0.1", StateLegitTemporarily), 0) // default LegitTTL
	fc.mono = 29 * time.Second
	if _, ok := c.Peek(netip.MustParseAddr("7.0.0.1")); !ok {
		t.Fatal("legit suppression must hold until TTL")
	}
	fc.mono = 31 * time.Second
	if _, ok := c.Peek(netip.MustParseAddr("7.0.0.1")); ok {
		t.Fatal("legit suppression must expire (treated as unknown) after TTL")
	}
}

func TestBLOCKED_TEMPORARY_RETURNS_UNTIL_BAN_TTL(t *testing.T) {
	c, fc := newTestCache(DefaultConfig())
	// blocked_temporarily REQUIRES a positive ban TTL.
	if err := c.Put(rec("8.0.0.1", StateBlockedTemporarily), 0); err != ErrBlockedNeedsTTL {
		t.Fatalf("blocked without ttl = %v, want ErrBlockedNeedsTTL", err)
	}
	mustPut(t, c, rec("8.0.0.1", StateBlockedTemporarily), 30*time.Second)
	fc.mono = 29 * time.Second
	got, ok := c.Get(netip.MustParseAddr("8.0.0.1"))
	if !ok || got.State != StateBlockedTemporarily {
		t.Fatalf("blocked must persist until ban TTL: %+v ok=%v", got, ok)
	}
	fc.mono = 31 * time.Second
	if _, ok := c.Get(netip.MustParseAddr("8.0.0.1")); ok {
		t.Fatal("blocked must lapse exactly at the ban TTL")
	}
}

func TestAMBIGUOUS_EXPIRES(t *testing.T) {
	cfg := DefaultConfig()
	cfg.AmbiguousTTL = 20 * time.Second
	c, fc := newTestCache(cfg)
	mustPut(t, c, rec("9.0.0.1", StateAmbiguous), 0)
	fc.mono = 21 * time.Second
	if _, ok := c.Peek(netip.MustParseAddr("9.0.0.1")); ok {
		t.Fatal("ambiguous must expire")
	}
}

func TestSAME_IP_CANDIDATE_DEDUP(t *testing.T) {
	c, fc := newTestCache(DefaultConfig())
	mustPut(t, c, rec("10.0.0.1", StateCandidate), 0)
	fc.mono = 1 * time.Second
	mustPut(t, c, rec("10.0.0.1", StateCandidate), 0) // same IP again
	if c.Len() != 1 {
		t.Fatalf("same-IP candidate must dedup to one record: Len = %d", c.Len())
	}
	if s := c.Stats(); s.CandidateEntries != 1 || s.TotalEntries != 1 {
		t.Fatalf("candidate accounting double-counted: %+v", s)
	}
}

func TestCACHE_MAX_ENTRIES_ENFORCED(t *testing.T) {
	cfg := DefaultConfig()
	cfg.MaxEntries = 10
	cfg.MaxCandidates = 10000
	c, fc := newTestCache(cfg)
	for i := 0; i < 200; i++ {
		fc.mono = time.Duration(i) * time.Millisecond
		// non-blocked so they remain evictable
		_ = c.Put(rec(fmt.Sprintf("11.%d.%d.1", i/256, i%256), StateChecking), time.Hour)
		if c.Len() > cfg.MaxEntries {
			t.Fatalf("Len exceeded MaxEntries: %d > %d at i=%d", c.Len(), cfg.MaxEntries, i)
		}
	}
	if c.Stats().TotalEntries > cfg.MaxEntries {
		t.Fatalf("TotalEntries exceeded MaxEntries: %d", c.Stats().TotalEntries)
	}
	if c.Stats().Evictions == 0 {
		t.Fatal("expected evictions under entry pressure")
	}
}

func TestCACHE_MAX_CANDIDATES_ENFORCED(t *testing.T) {
	cfg := DefaultConfig()
	cfg.MaxCandidates = 5
	cfg.MaxEntries = 10000
	c, fc := newTestCache(cfg)
	for i := 0; i < 200; i++ {
		fc.mono = time.Duration(i) * time.Millisecond
		_ = c.Put(rec(fmt.Sprintf("12.%d.%d.1", i/256, i%256), StateCandidate), time.Hour)
		if c.Stats().CandidateEntries > cfg.MaxCandidates {
			t.Fatalf("CandidateEntries exceeded MaxCandidates: %d > %d at i=%d",
				c.Stats().CandidateEntries, cfg.MaxCandidates, i)
		}
	}
}

func TestCACHE_OVERFLOW_EVICTS_EXPIRED_FIRST(t *testing.T) {
	cfg := DefaultConfig()
	cfg.MaxEntries = 3
	c, fc := newTestCache(cfg)
	// two short-lived (will expire) + one long-lived (live).
	mustPut(t, c, rec("13.0.0.1", StateChecking), 10*time.Second)
	mustPut(t, c, rec("13.0.0.2", StateChecking), 10*time.Second)
	mustPut(t, c, rec("13.0.0.3", StateLegitTemporarily), time.Hour)
	fc.mono = 11 * time.Second // first two now expired, third still live

	before := c.Stats()
	mustPut(t, c, rec("13.0.0.4", StateChecking), time.Hour) // forces eviction
	after := c.Stats()

	if after.ExpiredPurges <= before.ExpiredPurges {
		t.Fatal("overflow must evict an EXPIRED entry first")
	}
	if after.Evictions != before.Evictions {
		t.Fatal("a non-blocked live entry must NOT be force-evicted while an expired one exists")
	}
	if _, ok := c.Peek(netip.MustParseAddr("13.0.0.3")); !ok {
		t.Fatal("the live entry must survive (expired evicted first)")
	}
	if _, ok := c.Peek(netip.MustParseAddr("13.0.0.4")); !ok {
		t.Fatal("the new entry must be stored")
	}
}

func TestCACHE_OVERFLOW_EVICTS_OLDEST_NON_BLOCKED(t *testing.T) {
	cfg := DefaultConfig()
	cfg.MaxEntries = 3
	c, fc := newTestCache(cfg)
	fc.mono = 0
	mustPut(t, c, rec("14.0.0.1", StateChecking), time.Hour) // oldest
	fc.mono = 1 * time.Second
	mustPut(t, c, rec("14.0.0.2", StateChecking), time.Hour)
	fc.mono = 2 * time.Second
	mustPut(t, c, rec("14.0.0.3", StateChecking), time.Hour)

	before := c.Stats()
	fc.mono = 3 * time.Second
	mustPut(t, c, rec("14.0.0.4", StateChecking), time.Hour) // no expired → oldest non-blocked goes
	after := c.Stats()

	if after.ExpiredPurges != before.ExpiredPurges {
		t.Fatal("no entry was expired; ExpiredPurges must not move")
	}
	if after.Evictions <= before.Evictions {
		t.Fatal("expected a forced eviction of the oldest non-blocked entry")
	}
	if _, ok := c.Peek(netip.MustParseAddr("14.0.0.1")); ok {
		t.Fatal("the OLDEST non-blocked entry must be the eviction victim")
	}
	for _, ip := range []string{"14.0.0.2", "14.0.0.3", "14.0.0.4"} {
		if _, ok := c.Peek(netip.MustParseAddr(ip)); !ok {
			t.Fatalf("%s must survive", ip)
		}
	}
}

func TestCACHE_OVERFLOW_DOES_NOT_CREATE_DURABLE_STATE(t *testing.T) {
	cfg := DefaultConfig()
	cfg.MaxEntries = 8
	cfg.MaxCandidates = 4
	c, fc := newTestCache(cfg)
	states := []State{StateCandidate, StateChecking, StateLegitTemporarily, StateBlockedTemporarily, StateAmbiguous}
	for i := 0; i < 500; i++ {
		fc.mono = time.Duration(i) * time.Millisecond
		st := states[i%len(states)]
		ttl := time.Hour
		if st == StateBlockedTemporarily {
			ttl = 30 * time.Second
		}
		_ = c.Put(rec(fmt.Sprintf("15.%d.%d.%d", i/65536, (i/256)%256, i%256), st), ttl)
		for s := range c.Stats().ByState {
			if !allowedStates[s] {
				t.Fatalf("durable/invalid state %q appeared in cache at i=%d", s, i)
			}
		}
	}
	if c.Len() > cfg.MaxEntries {
		t.Fatalf("Len exceeded MaxEntries under churn: %d", c.Len())
	}
}

func TestIPV6_SAME_PREFIX_CANDIDATE_DEDUP(t *testing.T) {
	c, _ := newTestCache(DefaultConfig()) // V6PrefixBits=64
	mustPut(t, c, rec("2001:db8:abcd:1::1", StateCandidate), 0)
	mustPut(t, c, rec("2001:db8:abcd:1::2", StateCandidate), 0) // same /64, different IP
	if c.Len() != 2 {
		t.Fatalf("enforcement is per-IP: both records must exist, Len = %d", c.Len())
	}
	if c.Stats().CandidateEntries != 2 {
		t.Fatalf("per-IP candidate count = %d, want 2", c.Stats().CandidateEntries)
	}
	if got := c.DistinctCandidatePrefixes(); got != 1 {
		t.Fatalf("same-/64 candidates must dedup to one accounting prefix, got %d", got)
	}
}

func TestIPV6_PREFIX_SUSPICION_DOES_NOT_AUTO_BAN_WHOLE_PREFIX(t *testing.T) {
	c, _ := newTestCache(DefaultConfig())
	mustPut(t, c, rec("2001:db8:dead:1::100", StateBlockedTemporarily), 60*time.Second)
	// A different IP in the SAME /64 must be unaffected — no prefix-wide block exists.
	if _, ok := c.Peek(netip.MustParseAddr("2001:db8:dead:1::200")); ok {
		t.Fatal("blocking one IP must NOT block a sibling in the same /64")
	}
	// And a candidate on one sibling must not create a block on another.
	mustPut(t, c, rec("2001:db8:dead:1::300", StateCandidate), 0)
	if _, ok := c.Peek(netip.MustParseAddr("2001:db8:dead:1::400")); ok {
		t.Fatal("candidate on a sibling must not mark the whole prefix")
	}
}

func TestIPV4_PER_IP_BEHAVIOR_UNCHANGED(t *testing.T) {
	c, _ := newTestCache(DefaultConfig())
	// Two IPv4 in the same /24 are independent (per-IP /32 accounting, no aggregation).
	mustPut(t, c, rec("203.0.113.10", StateCandidate), 0)
	mustPut(t, c, rec("203.0.113.20", StateCandidate), 0)
	if got := c.DistinctCandidatePrefixes(); got != 2 {
		t.Fatalf("IPv4 must be per-IP: distinct candidate prefixes = %d, want 2", got)
	}
	mustPut(t, c, rec("203.0.113.10", StateBlockedTemporarily), 60*time.Second)
	if _, ok := c.Peek(netip.MustParseAddr("203.0.113.20")); !ok {
		t.Fatal("the sibling IPv4 candidate must remain unaffected")
	}
	if got, _ := c.Peek(netip.MustParseAddr("203.0.113.20")); got.State != StateCandidate {
		t.Fatalf("sibling state changed unexpectedly: %v", got.State)
	}
}

func TestCONCURRENT_PEEK_AND_UPDATE_SAFE(t *testing.T) {
	c := New(DefaultConfig()) // real clock; exercise under `go test -race`
	const workers = 16
	const iters = 2000
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			for i := 0; i < iters; i++ {
				ip := netip.AddrFrom4([4]byte{10, byte(w), byte(i >> 8), byte(i)})
				r := Record{IP: ip, State: StateCandidate, RequestClass: "mixed"}
				switch i % 4 {
				case 0:
					_ = c.Put(r, time.Minute)
				case 1:
					_, _ = c.Peek(ip)
				case 2:
					_, _ = c.Get(ip)
				case 3:
					_, _ = c.TTLRemaining(ip)
					_ = c.Stats()
				}
			}
		}(w)
	}
	wg.Wait()
	if c.Len() > DefaultConfig().MaxEntries {
		t.Fatalf("Len exceeded cap under concurrency: %d", c.Len())
	}
}
