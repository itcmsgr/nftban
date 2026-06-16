// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: Temporary Decision Cache
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: decisioncache
// Purpose: v1.191 8B (increment 4) — daemon-owned, in-memory, TEMPORARY decision cache
//          for BotGuard. Holds short-lived classification states only; never a durable
//          trust/block store. Durable allow/deny remain the nft sets' job, not this cache.
//          This increment is a standalone, fully-tested component — it is NOT yet wired
//          into guard.go (that is increment 5, the first behavior change).
//
// Time: all TTL math uses a MONOTONIC clock (time.Since over a captured base), so a
//       wall-clock jump can neither extend nor shorten a temporary suppression. Expired
//       entries are treated as absent (== unknown). No state here is ever persisted.
//
// meta:name="botguard_decisioncache"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="In-memory monotonic-TTL temporary decision cache for BotGuard (no durable states, bounded eviction, IPv6 prefix-aggregated candidate accounting)"
// meta:inventory.files="decisioncache.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package decisioncache

import (
	"errors"
	"net/netip"
	"sync"
	"time"
)

// ModuleBotGuard is the only module that owns this cache in v1.191.
const ModuleBotGuard = "botguard"

// State is a TEMPORARY decision state. Durable trust/block states are intentionally
// absent from this type and rejected by the cache — durable decisions live in nft sets.
type State string

const (
	// StateUnknown is the absence sentinel: an IP with no live record is "unknown".
	// It is never stored; Put(StateUnknown) is rejected (use Delete to forget an IP).
	StateUnknown State = "unknown"

	StateCandidate          State = "candidate"           // seen, not yet classified
	StateChecking           State = "checking"            // verification in flight
	StateLegitTemporarily   State = "legit_temporarily"   // temporarily suppressed (looks legit)
	StateBlockedTemporarily State = "blocked_temporarily" // temporarily blocked (ban-TTL driven)
	StateAmbiguous          State = "ambiguous"           // conflicting evidence, hold briefly
)

var (
	// ErrInvalidState is returned when a Put targets a state outside the allowed
	// temporary set — including any durable trust/block-equivalent state.
	ErrInvalidState = errors.New("decisioncache: invalid or durable state not allowed")
	// ErrInvalidTransition is returned when a state transition is not permitted.
	ErrInvalidTransition = errors.New("decisioncache: invalid state transition")
	// ErrBlockedNeedsTTL is returned when blocked_temporarily is stored without a positive TTL.
	ErrBlockedNeedsTTL = errors.New("decisioncache: blocked_temporarily requires a positive ban TTL")
	// ErrOverflow is returned when the entry could not be stored because the cache is full
	// of non-evictable (blocked, unexpired) entries.
	ErrOverflow = errors.New("decisioncache: cache full, entry dropped")
	// ErrInvalidIP is returned for an unparseable / zero address.
	ErrInvalidIP = errors.New("decisioncache: invalid IP")
)

// allowedStates is the closed set of storable states. Anything else (durable or garbage)
// is rejected by Put. StateUnknown is allowed as a transition source but not as a target.
var allowedStates = map[State]bool{
	StateCandidate:          true,
	StateChecking:           true,
	StateLegitTemporarily:   true,
	StateBlockedTemporarily: true,
	StateAmbiguous:          true,
}

// transitions defines permitted (from -> to) moves among temporary states. It is a full
// mesh today (reclassification is normal), but it is the hook for future tightening and,
// crucially, it never contains a durable target — so a durable transition can never be
// authorized here. StateUnknown is the implicit source for a not-yet-stored IP.
var transitions = map[State]map[State]bool{
	StateUnknown:            allowedStates,
	StateCandidate:          allowedStates,
	StateChecking:           allowedStates,
	StateLegitTemporarily:   allowedStates,
	StateBlockedTemporarily: allowedStates,
	StateAmbiguous:          allowedStates,
}

// Record is a single temporary decision. Enforcement is always per-IP; IPv6 prefix
// aggregation (below) affects candidate COST ACCOUNTING only, never the record key.
type Record struct {
	Module          string     // always ModuleBotGuard
	IP              netip.Addr // per-IP key
	Family          string     // "ipv4" | "ipv6"
	RequestClass    string     // from the BotScan structured signal (increment 3 taxonomy)
	Host            string     // optional site/vhost
	State           State      // temporary state
	Reason          string     // short why
	EvidenceSummary string     // compact evidence (for later observability)
	FirstSeen       time.Time  // wall-clock, for display/logging only
	LastSeen        time.Time  // wall-clock, for display/logging only
	ExpiresAt       time.Time  // wall-clock approximation of expiry (display only)

	// expiresMono is the AUTHORITATIVE expiry: monotonic elapsed-since-base deadline.
	// TTL decisions use this exclusively, immune to wall-clock changes.
	expiresMono time.Duration
	// firstMono / lastMono are monotonic stamps for TTL + eviction ordering.
	firstMono time.Duration
	lastMono  time.Duration
}

// Config bounds the cache. Zero values fall back to DefaultConfig() values via New.
type Config struct {
	MaxEntries    int // hard cap on total live entries
	MaxCandidates int // hard cap on candidate-state entries
	PerFamilyCap  int // optional per-family cap (0 = disabled)
	PerHostCap    int // optional per-host/site cap (0 = disabled; needs Host set)
	V6PrefixBits  int // IPv6 candidate-accounting aggregation width (default 64; e.g. 56)

	CandidateTTL time.Duration // default TTL for candidate
	CheckingTTL  time.Duration // default TTL for checking
	LegitTTL     time.Duration // default TTL for legit_temporarily
	AmbiguousTTL time.Duration // default TTL for ambiguous
	// blocked_temporarily has no default: it always follows the caller-supplied ban TTL.
}

// DefaultConfig returns conservative bounds suitable for a single busy host.
func DefaultConfig() Config {
	return Config{
		MaxEntries:    50000,
		MaxCandidates: 20000,
		PerFamilyCap:  0,
		PerHostCap:    0,
		V6PrefixBits:  64,
		CandidateTTL:  5 * time.Minute,
		CheckingTTL:   30 * time.Second,
		LegitTTL:      10 * time.Minute,
		AmbiguousTTL:  5 * time.Minute,
	}
}

// Stats is a bounded, internal-only snapshot for later observability. It is NOT wired to
// health/schema in this increment.
type Stats struct {
	TotalEntries              int
	ByState                   map[State]int
	CandidateEntries          int
	DistinctCandidatePrefix   int
	Evictions                 int64
	ExpiredPurges             int64
	OverflowDrops             int64
	InvalidStateAttempts      int64
	InvalidTransitionAttempts int64
}

// Cache is a concurrency-safe temporary decision cache.
type Cache struct {
	mu  sync.RWMutex
	cfg Config

	entries map[netip.Addr]*Record

	candidateCount int
	candPrefix     map[netip.Prefix]int // candidate count per aggregated prefix
	familyCount    map[string]int
	hostCount      map[string]int

	// monotonic + wall clocks (overridable in tests).
	base    time.Time
	monoNow func() time.Duration
	wallNow func() time.Time

	// counters
	evictions            int64
	expiredPurges        int64
	overflowDrops        int64
	invalidStateAttempts int64
	invalidTransAttempts int64
}

// New constructs a Cache with the given Config (zero fields filled from DefaultConfig).
func New(cfg Config) *Cache {
	d := DefaultConfig()
	if cfg.MaxEntries <= 0 {
		cfg.MaxEntries = d.MaxEntries
	}
	if cfg.MaxCandidates <= 0 {
		cfg.MaxCandidates = d.MaxCandidates
	}
	if cfg.V6PrefixBits <= 0 || cfg.V6PrefixBits > 128 {
		cfg.V6PrefixBits = d.V6PrefixBits
	}
	if cfg.CandidateTTL <= 0 {
		cfg.CandidateTTL = d.CandidateTTL
	}
	if cfg.CheckingTTL <= 0 {
		cfg.CheckingTTL = d.CheckingTTL
	}
	if cfg.LegitTTL <= 0 {
		cfg.LegitTTL = d.LegitTTL
	}
	if cfg.AmbiguousTTL <= 0 {
		cfg.AmbiguousTTL = d.AmbiguousTTL
	}
	base := time.Now()
	return &Cache{
		cfg:         cfg,
		entries:     make(map[netip.Addr]*Record),
		candPrefix:  make(map[netip.Prefix]int),
		familyCount: make(map[string]int),
		hostCount:   make(map[string]int),
		base:        base,
		monoNow:     func() time.Duration { return time.Since(base) },
		wallNow:     time.Now,
	}
}

// ---- helpers ----------------------------------------------------------------

func familyOf(ip netip.Addr) string {
	if ip.Is4() || ip.Is4In6() {
		return "ipv4"
	}
	return "ipv6"
}

// aggPrefix returns the candidate-accounting prefix: /32 (per-IP) for IPv4, /V6PrefixBits
// for IPv6. This affects COST ACCOUNTING ONLY — never the per-IP record key, so prefix
// suspicion can never auto-ban a whole prefix.
func (c *Cache) aggPrefix(ip netip.Addr) netip.Prefix {
	if ip.Is4() || ip.Is4In6() {
		p, _ := ip.Unmap().Prefix(32)
		return p
	}
	p, err := ip.Prefix(c.cfg.V6PrefixBits)
	if err != nil {
		p, _ = ip.Prefix(128)
	}
	return p
}

func (c *Cache) defaultTTL(s State) time.Duration {
	switch s {
	case StateCandidate:
		return c.cfg.CandidateTTL
	case StateChecking:
		return c.cfg.CheckingTTL
	case StateLegitTemporarily:
		return c.cfg.LegitTTL
	case StateAmbiguous:
		return c.cfg.AmbiguousTTL
	default:
		return 0
	}
}

func (r *Record) expiredAt(mono time.Duration) bool {
	return mono >= r.expiresMono
}

// ---- accounting (must hold the write lock) ----------------------------------

func (c *Cache) accountAdd(ip netip.Addr, r *Record) {
	if r.State == StateCandidate {
		c.candidateCount++
		c.candPrefix[c.aggPrefix(ip)]++
	}
	c.familyCount[r.Family]++
	if r.Host != "" {
		c.hostCount[r.Host]++
	}
}

func (c *Cache) accountRemove(ip netip.Addr, r *Record) {
	if r.State == StateCandidate {
		c.candidateCount--
		pfx := c.aggPrefix(ip)
		if c.candPrefix[pfx] <= 1 {
			delete(c.candPrefix, pfx)
		} else {
			c.candPrefix[pfx]--
		}
	}
	if c.familyCount[r.Family] <= 1 {
		delete(c.familyCount, r.Family)
	} else {
		c.familyCount[r.Family]--
	}
	if r.Host != "" {
		if c.hostCount[r.Host] <= 1 {
			delete(c.hostCount, r.Host)
		} else {
			c.hostCount[r.Host]--
		}
	}
}

func (c *Cache) deleteEntry(ip netip.Addr) {
	if r, ok := c.entries[ip]; ok {
		c.accountRemove(ip, r)
		delete(c.entries, ip)
	}
}

// purgeExpiredLocked removes one expired entry if any; returns true if it removed one.
func (c *Cache) evictOneExpired(now time.Duration) bool {
	for ip, r := range c.entries {
		if r.expiredAt(now) {
			c.deleteEntry(ip)
			c.expiredPurges++
			return true
		}
	}
	return false
}

// evictOneOldestNonBlocked removes the oldest (lowest lastMono) NON-blocked entry.
// Blocked-temporary entries are never force-evicted here. Returns true if it removed one.
func (c *Cache) evictOneOldestNonBlocked() bool {
	var victim netip.Addr
	var found bool
	var oldest time.Duration
	for ip, r := range c.entries {
		if r.State == StateBlockedTemporarily {
			continue
		}
		if !found || r.lastMono < oldest {
			oldest = r.lastMono
			victim = ip
			found = true
		}
	}
	if found {
		c.deleteEntry(victim)
		c.evictions++
	}
	return found
}

// evictOneOldestCandidate removes the oldest candidate-state entry. Returns true if removed.
func (c *Cache) evictOneOldestCandidate() bool {
	var victim netip.Addr
	var found bool
	var oldest time.Duration
	for ip, r := range c.entries {
		if r.State != StateCandidate {
			continue
		}
		if !found || r.lastMono < oldest {
			oldest = r.lastMono
			victim = ip
			found = true
		}
	}
	if found {
		c.deleteEntry(victim)
		c.evictions++
	}
	return found
}

// ---- public API -------------------------------------------------------------

// Put inserts or updates a temporary decision for rec.IP. ttl<=0 uses the state's default;
// blocked_temporarily REQUIRES ttl>0 (it follows the ban TTL). It validates the target
// state and transition, enforces caps with bounded eviction, and never creates a durable
// state. The Module field is always stamped to ModuleBotGuard.
func (c *Cache) Put(rec Record, ttl time.Duration) error {
	if !rec.IP.IsValid() || rec.IP.IsUnspecified() {
		return ErrInvalidIP
	}
	ip := rec.IP.Unmap()

	if rec.State == StateUnknown || !allowedStates[rec.State] {
		c.mu.Lock()
		c.invalidStateAttempts++
		c.mu.Unlock()
		return ErrInvalidState
	}
	if rec.State == StateBlockedTemporarily && ttl <= 0 {
		return ErrBlockedNeedsTTL
	}

	c.mu.Lock()
	defer c.mu.Unlock()

	now := c.monoNow()

	// Validate transition from the current (or unknown) state.
	from := StateUnknown
	if old, ok := c.entries[ip]; ok && !old.expiredAt(now) {
		from = old.State
	}
	if !transitions[from][rec.State] {
		c.invalidTransAttempts++
		return ErrInvalidTransition
	}

	if ttl <= 0 {
		ttl = c.defaultTTL(rec.State)
	}

	// Stamp authoritative + display fields.
	rec.Module = ModuleBotGuard
	rec.IP = ip
	rec.Family = familyOf(ip)
	rec.lastMono = now
	rec.expiresMono = now + ttl
	wall := c.wallNow()
	rec.LastSeen = wall
	rec.ExpiresAt = wall.Add(ttl)

	_, isUpdate := c.entries[ip]
	if isUpdate {
		rec.firstMono = c.entries[ip].firstMono
		rec.FirstSeen = c.entries[ip].FirstSeen
	} else {
		rec.firstMono = now
		rec.FirstSeen = wall
	}

	// --- candidate cap (per-IP count) with bounded eviction ---
	if rec.State == StateCandidate {
		// effective count excludes this IP if it is already a candidate (update in place).
		eff := c.candidateCount
		if old, ok := c.entries[ip]; ok && old.State == StateCandidate {
			eff--
		}
		for eff >= c.cfg.MaxCandidates {
			if !c.evictOneOldestCandidate() {
				break
			}
			eff = c.candidateCount
			if old, ok := c.entries[ip]; ok && old.State == StateCandidate {
				eff--
			}
		}
		if eff >= c.cfg.MaxCandidates {
			c.overflowDrops++
			return ErrOverflow
		}
	}

	// --- total-entries cap (only for genuinely new keys) ---
	if !isUpdate {
		for len(c.entries) >= c.cfg.MaxEntries {
			if c.evictOneExpired(now) {
				continue
			}
			if c.evictOneOldestNonBlocked() {
				continue
			}
			// All remaining are blocked + unexpired: cannot make room → drop.
			c.overflowDrops++
			return ErrOverflow
		}
	}

	// --- optional per-family / per-host caps ---
	if c.cfg.PerFamilyCap > 0 && !isUpdate {
		if c.familyCount[rec.Family] >= c.cfg.PerFamilyCap {
			c.overflowDrops++
			return ErrOverflow
		}
	}
	if c.cfg.PerHostCap > 0 && rec.Host != "" && !isUpdate {
		if c.hostCount[rec.Host] >= c.cfg.PerHostCap {
			c.overflowDrops++
			return ErrOverflow
		}
	}

	// Commit: replace accounting for any prior record, then store.
	c.deleteEntry(ip)
	stored := rec
	c.entries[ip] = &stored
	c.accountAdd(ip, &stored)
	return nil
}

// Get returns the live record for ip (a copy). Expired entries are treated as absent and
// are lazily purged (a side effect — for a pure read use Peek).
func (c *Cache) Get(ip netip.Addr) (Record, bool) {
	ip = ip.Unmap()
	c.mu.Lock()
	defer c.mu.Unlock()
	now := c.monoNow()
	r, ok := c.entries[ip]
	if !ok {
		return Record{}, false
	}
	if r.expiredAt(now) {
		c.deleteEntry(ip)
		c.expiredPurges++
		return Record{}, false
	}
	return *r, true
}

// Peek returns the live record for ip WITHOUT any side effect: no purge, no stat change,
// no LastSeen update. Expired entries are reported as absent.
func (c *Cache) Peek(ip netip.Addr) (Record, bool) {
	ip = ip.Unmap()
	c.mu.RLock()
	defer c.mu.RUnlock()
	now := c.monoNow()
	r, ok := c.entries[ip]
	if !ok || r.expiredAt(now) {
		return Record{}, false
	}
	return *r, true
}

// Delete forgets an IP (returns it to the unknown state). Safe if absent.
func (c *Cache) Delete(ip netip.Addr) {
	ip = ip.Unmap()
	c.mu.Lock()
	c.deleteEntry(ip)
	c.mu.Unlock()
}

// TTLRemaining returns the remaining TTL for ip and whether it is live. Uses monotonic time.
func (c *Cache) TTLRemaining(ip netip.Addr) (time.Duration, bool) {
	ip = ip.Unmap()
	c.mu.RLock()
	defer c.mu.RUnlock()
	now := c.monoNow()
	r, ok := c.entries[ip]
	if !ok || r.expiredAt(now) {
		return 0, false
	}
	return r.expiresMono - now, true
}

// Len returns the number of map entries (including not-yet-purged expired ones). Use Stats
// for state-accurate live accounting in tests.
func (c *Cache) Len() int {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.entries)
}

// DistinctCandidatePrefixes returns the number of distinct aggregated prefixes that
// currently hold at least one candidate (IPv6 aggregated to V6PrefixBits, IPv4 per-IP).
func (c *Cache) DistinctCandidatePrefixes() int {
	c.mu.RLock()
	defer c.mu.RUnlock()
	return len(c.candPrefix)
}

// Stats returns a bounded snapshot. ByState counts only live (non-expired) entries.
func (c *Cache) Stats() Stats {
	c.mu.RLock()
	defer c.mu.RUnlock()
	now := c.monoNow()
	by := make(map[State]int)
	total := 0
	for _, r := range c.entries {
		if r.expiredAt(now) {
			continue
		}
		by[r.State]++
		total++
	}
	return Stats{
		TotalEntries:              total,
		ByState:                   by,
		CandidateEntries:          c.candidateCount,
		DistinctCandidatePrefix:   len(c.candPrefix),
		Evictions:                 c.evictions,
		ExpiredPurges:             c.expiredPurges,
		OverflowDrops:             c.overflowDrops,
		InvalidStateAttempts:      c.invalidStateAttempts,
		InvalidTransitionAttempts: c.invalidTransAttempts,
	}
}
