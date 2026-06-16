// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: Read-only explain API tests (6A)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Prove the v1.191 8B increment-6A read-only explain/query API: it returns the
//          temporary decision-cache state for an IP, is side-effect-free (Peek), never
//          refreshes TTL / creates entries / bans / greys, makes no durable claim, degrades
//          cleanly on a nil cache or a context error (without implying safe), and never dumps
//          the whole cache.
//
// meta:name="botguard_explain_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Unit tests for the read-only BotGuard decision-cache explain API"
// meta:inventory.files="explain_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"context"
	"encoding/json"
	"net/netip"
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/botguard/decisioncache"
)

func seedBlocked(t *testing.T, m *Module, ipStr, class string, ttl time.Duration) netip.Addr {
	t.Helper()
	ip := netip.MustParseAddr(ipStr)
	rec := decisioncache.Record{IP: ip, RequestClass: class, State: decisioncache.StateBlockedTemporarily, Reason: "test_reason", EvidenceSummary: "test_evidence", Host: "site.example"}
	if err := m.decisionCache.Put(rec, ttl); err != nil {
		t.Fatalf("seed blocked %s: %v", ipStr, err)
	}
	return ip
}

func TestEXPLAIN_IP_RETURNS_TEMP_CACHE_STATE(t *testing.T) {
	m := New()
	ip := seedBlocked(t, m, "198.51.100.80", "scanner", time.Hour)
	r := m.ExplainIP(context.Background(), ip)
	if !r.CacheAvailable || !r.Present {
		t.Fatalf("expected available+present, got %+v", r)
	}
	if r.State != "blocked_temporarily" || !r.Temporary {
		t.Fatalf("expected temporary blocked_temporarily, got state=%s temporary=%v", r.State, r.Temporary)
	}
	if r.Source != ExplainSource || r.RequestClass != "scanner" || r.Family != "ipv4" {
		t.Fatalf("bad fields: %+v", r)
	}
	if r.TTLRemainingMS <= 0 || r.ExpiresAt == "" || r.Reason == "" {
		t.Fatalf("expected ttl/expiry/reason populated: %+v", r)
	}
}

func TestEXPLAIN_IP_CACHE_MISS_RETURNS_ABSENT_NOT_SAFE(t *testing.T) {
	m := New()
	r := m.ExplainIP(context.Background(), netip.MustParseAddr("198.51.100.81"))
	if !r.CacheAvailable {
		t.Fatal("cache is available; only the entry is absent")
	}
	if r.Present {
		t.Fatal("absent IP must not be present")
	}
	if r.State != "unknown" {
		t.Fatalf("absent IP state must be 'unknown', got %q", r.State)
	}
	// Must NOT imply safe/allowed/clean, and must not claim durable truth.
	for _, bad := range []string{"safe", "allow", "clean", "not_banned", "legit_temporarily"} {
		if r.State == bad {
			t.Fatalf("absent must not be reported as %q", bad)
		}
	}
	if r.DurableAuthority != "not_evaluated" || r.Note == "" {
		t.Fatalf("absent must carry no-durable-claim + clarifying note: %+v", r)
	}
}

func TestEXPLAIN_IP_READ_ONLY_NO_SIDE_EFFECT(t *testing.T) {
	m := New()
	ip := seedBlocked(t, m, "198.51.100.82", "dynamic_abuse", time.Hour)
	before := m.decisionCache.Stats()
	lenBefore := m.decisionCache.Len()
	_ = m.ExplainIP(context.Background(), ip)
	_ = m.ExplainIP(context.Background(), netip.MustParseAddr("198.51.100.199")) // miss
	if m.decisionCache.Len() != lenBefore {
		t.Fatalf("explain changed cache size: %d -> %d", lenBefore, m.decisionCache.Len())
	}
	after := m.decisionCache.Stats()
	if after.Evictions != before.Evictions || after.ExpiredPurges != before.ExpiredPurges ||
		after.OverflowDrops != before.OverflowDrops || after.InvalidStateAttempts != before.InvalidStateAttempts {
		t.Fatalf("explain mutated stats: %+v -> %+v", before, after)
	}
	if pk, ok := m.decisionCache.Peek(ip); !ok || pk.State != decisioncache.StateBlockedTemporarily {
		t.Fatal("explain must not change the cached state")
	}
}

func TestEXPLAIN_IP_DOES_NOT_REFRESH_TTL(t *testing.T) {
	m := New()
	ip := seedBlocked(t, m, "198.51.100.83", "scanner", time.Hour)
	rem1, _ := m.decisionCache.TTLRemaining(ip)
	_ = m.ExplainIP(context.Background(), ip)
	_ = m.ExplainIP(context.Background(), ip)
	rem2, _ := m.decisionCache.TTLRemaining(ip)
	if rem2 > rem1 {
		t.Fatalf("explain must not refresh/extend TTL: %v -> %v", rem1, rem2)
	}
}

func TestEXPLAIN_IP_DOES_NOT_CREATE_CANDIDATE(t *testing.T) {
	m := New()
	lenBefore := m.decisionCache.Len()
	ip := netip.MustParseAddr("198.51.100.84")
	_ = m.ExplainIP(context.Background(), ip)
	if m.decisionCache.Len() != lenBefore {
		t.Fatalf("explain created an entry: len %d -> %d", lenBefore, m.decisionCache.Len())
	}
	if _, ok := m.decisionCache.Peek(ip); ok {
		t.Fatal("explain must not create a candidate for an unknown IP")
	}
}

func TestEXPLAIN_IP_DOES_NOT_BAN_OR_GREY(t *testing.T) {
	m, b := newEnforcingModule(t)
	ip := seedBlocked(t, m, "198.51.100.85", "scanner", time.Hour)
	_ = m.ExplainIP(context.Background(), ip)
	time.Sleep(100 * time.Millisecond)
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.adds) != 0 {
		t.Fatalf("explain must not enqueue any enforcement; saw %v", b.adds)
	}
}

func TestEXPLAIN_IP_NO_DURABLE_WHITELIST_BLACKLIST_CLAIM(t *testing.T) {
	m := New()
	ip := seedBlocked(t, m, "198.51.100.86", "scanner", time.Hour)
	r := m.ExplainIP(context.Background(), ip)
	if r.DurableAuthority != "not_evaluated" {
		t.Fatalf("explain must not claim durable authority, got %q", r.DurableAuthority)
	}
	if r.Source != ExplainSource || !r.Temporary {
		t.Fatalf("explain must report only temporary cache source: %+v", r)
	}
	// The response JSON must not assert any durable whitelist/blacklist verdict.
	js, _ := json.Marshal(r)
	for _, bad := range []string{"\"whitelisted\":true", "\"blacklisted\":true", "\"banned\":true"} {
		if strings.Contains(string(js), bad) {
			t.Fatalf("explain leaked a durable claim: %s", bad)
		}
	}
}

func TestEXPLAIN_IP_CACHE_UNAVAILABLE_DEGRADES(t *testing.T) {
	m := New()
	m.decisionCache = nil // simulate unavailable cache
	r := m.ExplainIP(context.Background(), netip.MustParseAddr("198.51.100.87"))
	if r.CacheAvailable {
		t.Fatal("nil cache must degrade to cache_available=false")
	}
	if r.State != "unavailable" || r.Present {
		t.Fatalf("degraded response must be unavailable+not-present, got %+v", r)
	}
}

func TestEXPLAIN_IP_CONTEXT_TIMEOUT_DEGRADES(t *testing.T) {
	m := New()
	ip := seedBlocked(t, m, "198.51.100.88", "scanner", time.Hour)
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already done
	r := m.ExplainIP(ctx, ip)
	if r.CacheAvailable || r.State != "unavailable" {
		t.Fatalf("cancelled context must degrade (not imply safe), got %+v", r)
	}
}

func TestEXPLAIN_IP_USES_PEEK_OR_READ_LOCK(t *testing.T) {
	m := New()
	ip := seedBlocked(t, m, "198.51.100.89", "scanner", 20*time.Millisecond)
	time.Sleep(50 * time.Millisecond) // entry now expired
	r := m.ExplainIP(context.Background(), ip)
	if r.Present {
		t.Fatal("expired entry must report absent")
	}
	// Peek (read-only) does NOT purge — Get would have. Len staying 1 proves Peek semantics.
	if m.decisionCache.Len() != 1 {
		t.Fatalf("explain must use Peek (no purge); Len = %d, want 1", m.decisionCache.Len())
	}
}

func TestEXPLAIN_IP_NO_FULL_CACHE_DUMP(t *testing.T) {
	m := New()
	ipA := seedBlocked(t, m, "198.51.100.90", "scanner", time.Hour)
	_ = seedBlocked(t, m, "198.51.100.91", "dynamic_abuse", time.Hour)
	r := m.ExplainIP(context.Background(), ipA)
	if r.IP != ipA.String() {
		t.Fatalf("explain must report only the queried IP, got %q", r.IP)
	}
	js, _ := json.Marshal(r)
	if strings.Contains(string(js), "198.51.100.91") {
		t.Fatalf("explain must not dump other cache entries; response leaked a second IP: %s", js)
	}
}
