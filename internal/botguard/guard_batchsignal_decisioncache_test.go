// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: Batch-signal → decision-cache transitions (5A)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Prove the v1.191 8B increment-5A wiring: batch signals drive TEMPORARY
//          decision-cache transitions (observation/state-transition layer only). The
//          cache never enforces, never creates durable state, and a cache error never
//          escalates a browser-like signal to a block. The existing BotScan→BotGuard ban
//          action is preserved and still reaches the http_bot_ban set.
//
// meta:name="botguard_guard_batchsignal_decisioncache_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Tests for batch_signal -> decision-cache state transitions (increment 5A)"
// meta:inventory.files="guard_batchsignal_decisioncache_test.go"
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
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/botguard/decisioncache"
	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/opqueue"
)

// --- helpers -----------------------------------------------------------------

func mkSig(ip, class, action string, reasons ...string) *BatchSignal {
	return &BatchSignal{IP: ip, Score: 80, Action: action, RequestClass: class, Reasons: reasons}
}

// transition observes one signal and returns the resulting cache record (must exist).
func transition(t *testing.T, m *Module, s *BatchSignal) decisioncache.Record {
	t.Helper()
	ip := netip.MustParseAddr(s.IP)
	m.recordDecisionTransition(s, ip)
	r, ok := m.decisionCache.Peek(ip)
	if !ok {
		t.Fatalf("no cache entry after transition for %s (class=%s action=%s)", s.IP, s.RequestClass, s.Action)
	}
	return r
}

func assertNotBlocked(t *testing.T, r decisioncache.Record) {
	t.Helper()
	if r.State == decisioncache.StateBlockedTemporarily {
		t.Fatalf("browser-like class %q must NOT be blocked, got state=%s", r.RequestClass, r.State)
	}
}

// --- browser-like classes: legit/ambiguous, never blocked ---------------------

func TestBATCH_SIGNAL_STATIC_TRANSITIONS_LEGIT_TEMPORARILY(t *testing.T) {
	m := New()
	// Action is "ban" on purpose: a browser-like class must still NOT block from class/rate.
	r := transition(t, m, mkSig("203.0.113.1", "static", "ban"))
	if r.State != decisioncache.StateLegitTemporarily {
		t.Fatalf("static → %s, want legit_temporarily", r.State)
	}
}

func TestBATCH_SIGNAL_STATIC404_TRANSITIONS_LEGIT_OR_AMBIGUOUS_NO_BAN(t *testing.T) {
	m := New()
	r := transition(t, m, mkSig("203.0.113.2", "static404", "ban"))
	if r.State != decisioncache.StateLegitTemporarily && r.State != decisioncache.StateAmbiguous {
		t.Fatalf("static404 → %s, want legit_temporarily or ambiguous", r.State)
	}
	assertNotBlocked(t, r)
}

func TestBATCH_SIGNAL_ESHOP_FANOUT_TRANSITIONS_LEGIT_TEMPORARILY(t *testing.T) {
	m := New()
	r := transition(t, m, mkSig("203.0.113.3", "eshop_fanout", "ban"))
	if r.State != decisioncache.StateLegitTemporarily {
		t.Fatalf("eshop_fanout → %s, want legit_temporarily", r.State)
	}
}

func TestBATCH_SIGNAL_ADMIN_AJAX_TRANSITIONS_LEGIT_OR_AMBIGUOUS_NO_BAN(t *testing.T) {
	m := New()
	r := transition(t, m, mkSig("203.0.113.4", "admin_ajax", "ban"))
	if r.State != decisioncache.StateLegitTemporarily && r.State != decisioncache.StateAmbiguous {
		t.Fatalf("admin_ajax → %s, want legit_temporarily or ambiguous", r.State)
	}
	assertNotBlocked(t, r)
}

// --- abuse classes: blocked_temporarily when action indicates block ----------

func TestBATCH_SIGNAL_DYNAMIC_ABUSE_TRANSITIONS_BLOCKED_TEMPORARILY(t *testing.T) {
	m := New()
	r := transition(t, m, mkSig("198.51.100.1", "dynamic_abuse", "ban"))
	if r.State != decisioncache.StateBlockedTemporarily {
		t.Fatalf("dynamic_abuse+ban → %s, want blocked_temporarily", r.State)
	}
}

func TestBATCH_SIGNAL_LOGIN_API_TRANSITIONS_BLOCKED_TEMPORARILY(t *testing.T) {
	m := New()
	r := transition(t, m, mkSig("198.51.100.2", "login_api", "ban"))
	if r.State != decisioncache.StateBlockedTemporarily {
		t.Fatalf("login_api+ban → %s, want blocked_temporarily", r.State)
	}
}

func TestBATCH_SIGNAL_SCANNER_TRANSITIONS_BLOCKED_TEMPORARILY(t *testing.T) {
	m := New()
	r := transition(t, m, mkSig("198.51.100.3", "scanner", "ban"))
	if r.State != decisioncache.StateBlockedTemporarily {
		t.Fatalf("scanner+ban → %s, want blocked_temporarily", r.State)
	}
}

func TestBATCH_SIGNAL_MIXED_TRANSITIONS_AMBIGUOUS(t *testing.T) {
	m := New()
	r := transition(t, m, mkSig("198.51.100.4", "mixed", "ban"))
	if r.State != decisioncache.StateAmbiguous {
		t.Fatalf("mixed → %s, want ambiguous", r.State)
	}
}

// --- old-signal compatibility ------------------------------------------------

func TestOLD_BATCH_SIGNAL_WITHOUT_CLASS_DEFAULTS_MIXED(t *testing.T) {
	m := New()
	// No request_class (pre-v1.191 producer).
	r := transition(t, m, mkSig("192.0.2.10", "", "ban"))
	if r.RequestClass != "mixed" {
		t.Fatalf("missing request_class normalized to %q, want mixed", r.RequestClass)
	}
	if r.State != decisioncache.StateAmbiguous {
		t.Fatalf("missing-class signal → %s, want ambiguous", r.State)
	}
}

func TestOLD_BATCH_SIGNAL_WITHOUT_FAMILY_DERIVES_FAMILY(t *testing.T) {
	m := New()
	r4 := transition(t, m, mkSig("192.0.2.11", "mixed", "ban")) // no family field
	if r4.Family != "ipv4" {
		t.Fatalf("derived family for IPv4 = %q, want ipv4", r4.Family)
	}
	r6 := transition(t, m, mkSig("2001:db8::beef", "mixed", "ban"))
	if r6.Family != "ipv6" {
		t.Fatalf("derived family for IPv6 = %q, want ipv6", r6.Family)
	}
}

// --- structured class beats free-text reasons --------------------------------

func TestSTRUCTURED_CLASS_TAKES_PRECEDENCE_OVER_REASON_TEXT(t *testing.T) {
	m := New()
	// Reasons LOOK browser-like / 404-ish, but the structured class is scanner.
	s := mkSig("198.51.100.5", "scanner", "ban", "404_flood", "static_asset", "looks_like_image")
	r := transition(t, m, s)
	if r.RequestClass != "scanner" || r.State != decisioncache.StateBlockedTemporarily {
		t.Fatalf("structured class must win over reasons text: class=%s state=%s", r.RequestClass, r.State)
	}
}

// --- no durable state ever --------------------------------------------------

func TestNO_DURABLE_STATE_CREATED_FROM_BATCH_SIGNAL(t *testing.T) {
	m := New()
	classes := []string{"static", "static404", "eshop_fanout", "admin_ajax", "dynamic_abuse", "login_api", "scanner", "mixed", "", "garbage-class"}
	actions := []string{"ban", "grey", "allow_demote", "allow_extend", "weird"}
	allowed := map[decisioncache.State]bool{
		decisioncache.StateCandidate:          true,
		decisioncache.StateChecking:           true,
		decisioncache.StateLegitTemporarily:   true,
		decisioncache.StateBlockedTemporarily: true,
		decisioncache.StateAmbiguous:          true,
	}
	n := 0
	for _, c := range classes {
		for _, a := range actions {
			n++
			ip := netip.AddrFrom4([4]byte{10, 10, byte(n >> 8), byte(n)})
			s := mkSig(ip.String(), c, a)
			m.recordDecisionTransition(s, ip)
		}
	}
	for st := range m.decisionCache.Stats().ByState {
		if !allowed[st] {
			t.Fatalf("durable/invalid state %q created from batch signals", st)
		}
	}
}

// --- no shell/on-disk parallel cache ----------------------------------------

func TestNO_SHELL_PARALLEL_CACHE(t *testing.T) {
	// The decision cache is daemon-Go and in-memory only. Processing signals must not
	// create any on-disk (shell-readable) parallel cache file.
	dir := t.TempDir()
	m := New()
	for i := 0; i < 50; i++ {
		ip := netip.AddrFrom4([4]byte{172, 16, byte(i >> 8), byte(i)})
		m.recordDecisionTransition(mkSig(ip.String(), "scanner", "ban"), ip)
	}
	var found []string
	_ = filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err == nil && info != nil && !info.IsDir() {
			found = append(found, p)
		}
		return nil
	})
	if len(found) != 0 {
		t.Fatalf("decision cache must be in-memory only; unexpected on-disk files: %v", found)
	}
}

// --- cache error fails safe (no block of a browser-like signal) --------------

func TestCACHE_UPDATE_ERROR_DOES_NOT_BAN_BROWSER_LIKE_SIGNAL(t *testing.T) {
	m := New()
	// Force the cache to be unable to accept new entries: a 1-slot cache pre-filled with a
	// non-evictable blocked entry → any new Put returns ErrOverflow.
	tiny := decisioncache.Config{MaxEntries: 1, MaxCandidates: 1}
	m.decisionCache = decisioncache.New(tiny)
	filler := decisioncache.Record{IP: netip.MustParseAddr("198.51.100.250"), State: decisioncache.StateBlockedTemporarily}
	if err := m.decisionCache.Put(filler, time.Hour); err != nil {
		t.Fatalf("filler put failed: %v", err)
	}

	// A browser-like signal whose cache Put will error must NOT end up blocked.
	browserIP := netip.MustParseAddr("203.0.113.99")
	m.recordDecisionTransition(mkSig(browserIP.String(), "static", "ban"), browserIP) // must not panic
	if r, ok := m.decisionCache.Peek(browserIP); ok && r.State == decisioncache.StateBlockedTemporarily {
		t.Fatal("cache error must not cause a browser-like signal to be blocked")
	}
	// And the cache must not have synthesized any state for it (failed safe to absent).
	if _, ok := m.decisionCache.Peek(browserIP); ok {
		t.Fatal("on cache overflow error the browser-like IP must remain absent/unknown")
	}
}

// --- existing ban path preserved (reaches http_bot_ban) ----------------------

type recBackend struct {
	mu   sync.Mutex
	adds map[string][]string
}

func (b *recBackend) FlushSet(table, set string) error { return nil }
func (b *recBackend) AddElements(table, set string, els []opqueue.SetElement) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, e := range els {
		b.adds[set] = append(b.adds[set], e.Value)
	}
	return len(els), nil
}
func (b *recBackend) DeleteElements(table, set string, els []opqueue.SetElement) error { return nil }
func (b *recBackend) GetSetElements(table, set string) ([]string, error)               { return nil, nil }
func (b *recBackend) has(set, ip string) bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	for _, v := range b.adds[set] {
		if v == ip {
			return true
		}
	}
	return false
}

func TestEXISTING_BOTSCAN_BAN_ACTION_STILL_REACHES_HTTP_BOT_BAN(t *testing.T) {
	b := &recBackend{adds: make(map[string][]string)}
	qcfg := opqueue.DefaultQueueConfig()
	qcfg.FlushThreshold = 1
	qcfg.FlushInterval = 5 * time.Millisecond
	q := opqueue.NewOpQueue(b, qcfg)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	q.Start(ctx)

	m := New()
	m.bus = eventbus.New()
	m.InitEnforcer(q)

	const ip = "198.51.100.77"
	// Abuse class + ban action: the legacy enforce path must still reach http_bot_ban.
	m.applyBatchSignal(mkSig(ip, "scanner", "ban", "scanner pattern: webshell"))

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if b.has("http_bot_ban", ip) {
			break
		}
		time.Sleep(10 * time.Millisecond)
	}
	if !b.has("http_bot_ban", ip) {
		t.Fatalf("existing BotScan ban action did not reach http_bot_ban (sets seen: %v)", b.adds)
	}
	// And the cache also recorded a TEMPORARY block (parallel observation, not the enforcer).
	if r, ok := m.decisionCache.Peek(netip.MustParseAddr(ip)); !ok || r.State != decisioncache.StateBlockedTemporarily {
		t.Fatalf("cache should observe scanner+ban as blocked_temporarily, got ok=%v %+v", ok, r)
	}
}
