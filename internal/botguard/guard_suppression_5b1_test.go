// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: Cache-aware browser-like ban suppression (5B1)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Prove the v1.191 8B increment-5B1 enforcement behavior: browser-like
//          false-positive batch-signal bans are SUPPRESSED (never reach http_bot_ban from
//          class alone), abuse bans (dynamic_abuse/login_api/scanner) still reach
//          http_bot_ban, mixed/old signals keep their existing behavior, structured class
//          beats free-text reasons, blocked_temporarily preserves enforcement, and cache
//          errors fail safe in both directions. Durable authority is untouched.
//
// meta:name="botguard_guard_suppression_5b1_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Tests for cache-aware browser-like batch-ban suppression (increment 5B1)"
// meta:inventory.files="guard_suppression_5b1_test.go"
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
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/botguard/decisioncache"
	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/opqueue"
)

// newEnforcingModule builds a Module backed by a real OpQueue + recording NetlinkBackend so
// tests can observe whether a ban actually reaches the http_bot_ban set.
func newEnforcingModule(t *testing.T) (*Module, *recBackend) {
	t.Helper()
	b := &recBackend{adds: make(map[string][]string)}
	qcfg := opqueue.DefaultQueueConfig()
	qcfg.FlushThreshold = 1
	qcfg.FlushInterval = 5 * time.Millisecond
	q := opqueue.NewOpQueue(b, qcfg)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	q.Start(ctx)
	m := New()
	m.bus = eventbus.New()
	m.InitEnforcer(q)
	return m, b
}

func waitBanned(b *recBackend, set, ip string) bool {
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		if b.has(set, ip) {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return b.has(set, ip)
}

// assertNotBanned gives the async queue a window to flush, then asserts absence.
func assertNotBanned(t *testing.T, b *recBackend, set, ip string) {
	t.Helper()
	time.Sleep(300 * time.Millisecond)
	if b.has(set, ip) {
		t.Fatalf("%s must NOT be in %s (browser-like ban should be suppressed); sets=%v", ip, set, b.adds)
	}
}

// --- browser-like suppression: no http_bot_ban -------------------------------

func TestBROWSER_STATIC_BAN_SIGNAL_SUPPRESSED_NO_HTTP_BOT_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	const ip = "203.0.113.40"
	m.applyBatchSignal(mkSig(ip, "static", "ban"))
	assertNotBanned(t, b, "http_bot_ban", ip)
	if r, ok := m.decisionCache.Peek(netip.MustParseAddr(ip)); !ok || r.State != decisioncache.StateLegitTemporarily {
		t.Fatalf("static signal should leave cache legit_temporarily, got ok=%v %+v", ok, r)
	}
}

func TestSTATIC404_BAN_SIGNAL_SUPPRESSED_NO_HTTP_BOT_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	const ip = "203.0.113.41"
	m.applyBatchSignal(mkSig(ip, "static404", "ban"))
	assertNotBanned(t, b, "http_bot_ban", ip)
}

func TestESHOP_FANOUT_BAN_SIGNAL_SUPPRESSED_NO_HTTP_BOT_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	const ip = "203.0.113.42"
	m.applyBatchSignal(mkSig(ip, "eshop_fanout", "ban"))
	assertNotBanned(t, b, "http_bot_ban", ip)
}

func TestADMIN_AJAX_BAN_SIGNAL_SUPPRESSED_NO_HTTP_BOT_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	const ip = "203.0.113.43"
	m.applyBatchSignal(mkSig(ip, "admin_ajax", "ban"))
	assertNotBanned(t, b, "http_bot_ban", ip)
}

// --- abuse preservation: still reaches http_bot_ban --------------------------

func TestDYNAMIC_ABUSE_BAN_SIGNAL_STILL_REACHES_HTTP_BOT_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	const ip = "198.51.100.40"
	m.applyBatchSignal(mkSig(ip, "dynamic_abuse", "ban"))
	if !waitBanned(b, "http_bot_ban", ip) {
		t.Fatalf("dynamic_abuse ban must reach http_bot_ban; sets=%v", b.adds)
	}
}

func TestLOGIN_API_BAN_SIGNAL_STILL_REACHES_HTTP_BOT_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	const ip = "198.51.100.41"
	m.applyBatchSignal(mkSig(ip, "login_api", "ban"))
	if !waitBanned(b, "http_bot_ban", ip) {
		t.Fatalf("login_api ban must reach http_bot_ban; sets=%v", b.adds)
	}
}

func TestSCANNER_BAN_SIGNAL_STILL_REACHES_HTTP_BOT_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	const ip = "198.51.100.42"
	m.applyBatchSignal(mkSig(ip, "scanner", "ban"))
	if !waitBanned(b, "http_bot_ban", ip) {
		t.Fatalf("scanner ban must reach http_bot_ban; sets=%v", b.adds)
	}
}

// --- mixed / old-signal compatibility ----------------------------------------

func TestMIXED_OLD_SIGNAL_COMPATIBILITY_PRESERVED(t *testing.T) {
	m, b := newEnforcingModule(t)
	// mixed (explicit) and an OLD signal with no request_class must NOT be newly suppressed:
	// both keep the legacy behavior and reach http_bot_ban.
	m.applyBatchSignal(mkSig("198.51.100.43", "mixed", "ban"))
	m.applyBatchSignal(mkSig("198.51.100.44", "", "ban")) // pre-v1.191 producer
	if !waitBanned(b, "http_bot_ban", "198.51.100.43") {
		t.Fatalf("mixed ban must preserve legacy behavior (reach http_bot_ban); sets=%v", b.adds)
	}
	if !waitBanned(b, "http_bot_ban", "198.51.100.44") {
		t.Fatalf("old class-less ban must preserve legacy behavior (reach http_bot_ban); sets=%v", b.adds)
	}
}

// --- structured class beats reasons text for suppression ---------------------

func TestSTRUCTURED_CLASS_TAKES_PRECEDENCE_FOR_SUPPRESSION(t *testing.T) {
	m, b := newEnforcingModule(t)
	const ip = "203.0.113.44"
	// Reasons look abuse-y ("404_flood","wp_probe") but structured class is static → suppress.
	m.applyBatchSignal(mkSig(ip, "static", "ban", "404_flood", "wp_probe", "attack"))
	assertNotBanned(t, b, "http_bot_ban", ip)
}

// --- precedence / scoping ----------------------------------------------------

func TestLEGIT_TEMPORARILY_SUPPRESSES_SAME_CLASS_ONLY(t *testing.T) {
	m, b := newEnforcingModule(t)
	const ip = "198.51.100.45"
	// A browser-like ban is suppressed...
	m.applyBatchSignal(mkSig(ip, "static", "ban"))
	assertNotBanned(t, b, "http_bot_ban", ip)
	// ...but an abuse-class ban for the SAME IP is NOT suppressed.
	m.applyBatchSignal(mkSig(ip, "scanner", "ban"))
	if !waitBanned(b, "http_bot_ban", ip) {
		t.Fatalf("legit suppression must apply to browser-like class only; scanner must still ban; sets=%v", b.adds)
	}
}

func TestLEGIT_TEMPORARILY_DOES_NOT_SUPPRESS_DYNAMIC_ABUSE(t *testing.T) {
	m, b := newEnforcingModule(t)
	const ip = "198.51.100.46"
	// Pre-seed a legit_temporarily cache state for the IP.
	if err := m.decisionCache.Put(decisioncache.Record{IP: netip.MustParseAddr(ip), State: decisioncache.StateLegitTemporarily}, 0); err != nil {
		t.Fatalf("seed legit failed: %v", err)
	}
	// A dynamic_abuse ban must still reach http_bot_ban despite the legit cache state.
	m.applyBatchSignal(mkSig(ip, "dynamic_abuse", "ban"))
	if !waitBanned(b, "http_bot_ban", ip) {
		t.Fatalf("legit_temporarily must NOT suppress dynamic_abuse; sets=%v", b.adds)
	}
}

func TestBLOCKED_TEMPORARILY_PRESERVES_ENFORCEMENT(t *testing.T) {
	m, b := newEnforcingModule(t)
	const ip = "198.51.100.47"
	m.applyBatchSignal(mkSig(ip, "scanner", "ban")) // → http_bot_ban + cache blocked_temporarily
	if !waitBanned(b, "http_bot_ban", ip) {
		t.Fatalf("initial scanner ban must reach http_bot_ban; sets=%v", b.adds)
	}
	// A repeat abuse signal preserves enforcement and the blocked_temporarily cache state.
	m.applyBatchSignal(mkSig(ip, "scanner", "ban"))
	if r, ok := m.decisionCache.Peek(netip.MustParseAddr(ip)); !ok || r.State != decisioncache.StateBlockedTemporarily {
		t.Fatalf("blocked_temporarily must persist across repeat signals, got ok=%v %+v", ok, r)
	}
	if !b.has("http_bot_ban", ip) {
		t.Fatal("enforcement must be preserved while blocked_temporarily is active")
	}
}

// --- fail-safe in both directions --------------------------------------------

func fillCacheToError(t *testing.T, m *Module) {
	t.Helper()
	m.decisionCache = decisioncache.New(decisioncache.Config{MaxEntries: 1, MaxCandidates: 1})
	if err := m.decisionCache.Put(decisioncache.Record{IP: netip.MustParseAddr("198.51.100.254"), State: decisioncache.StateBlockedTemporarily}, time.Hour); err != nil {
		t.Fatalf("filler put failed: %v", err)
	}
}

func TestCACHE_ERROR_DOES_NOT_BAN_BROWSER_LIKE_SIGNAL(t *testing.T) {
	m, b := newEnforcingModule(t)
	fillCacheToError(t, m) // any new cache Put now errors
	const ip = "203.0.113.45"
	m.applyBatchSignal(mkSig(ip, "static", "ban")) // suppression must not depend on cache success
	assertNotBanned(t, b, "http_bot_ban", ip)
}

func TestCACHE_ERROR_DOES_NOT_SUPPRESS_DYNAMIC_ABUSE_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	fillCacheToError(t, m)
	const ip = "198.51.100.48"
	m.applyBatchSignal(mkSig(ip, "dynamic_abuse", "ban"))
	if !waitBanned(b, "http_bot_ban", ip) {
		t.Fatalf("a cache error must not suppress a clear dynamic_abuse ban; sets=%v", b.adds)
	}
}

// --- no durable / no on-disk / no persisted writer ---------------------------

func TestNO_DURABLE_STATE_CREATED_5B1(t *testing.T) {
	m, _ := newEnforcingModule(t)
	allowed := map[decisioncache.State]bool{
		decisioncache.StateCandidate: true, decisioncache.StateChecking: true,
		decisioncache.StateLegitTemporarily: true, decisioncache.StateBlockedTemporarily: true,
		decisioncache.StateAmbiguous: true,
	}
	classes := []string{"static", "static404", "eshop_fanout", "admin_ajax", "dynamic_abuse", "login_api", "scanner", "mixed", ""}
	n := 0
	for _, c := range classes {
		n++
		ip := netip.AddrFrom4([4]byte{10, 11, byte(n >> 8), byte(n)})
		m.applyBatchSignal(mkSig(ip.String(), c, "ban"))
	}
	for st := range m.decisionCache.Stats().ByState {
		if !allowed[st] {
			t.Fatalf("durable/invalid state %q created during 5B1 enforcement", st)
		}
	}
}

func TestNO_SHELL_PARALLEL_CACHE_5B1(t *testing.T) {
	dir := t.TempDir()
	m, _ := newEnforcingModule(t)
	for i := 0; i < 40; i++ {
		ip := netip.AddrFrom4([4]byte{172, 17, byte(i >> 8), byte(i)})
		m.applyBatchSignal(mkSig(ip.String(), "static", "ban"))
	}
	var found []string
	_ = filepath.Walk(dir, func(p string, info os.FileInfo, err error) error {
		if err == nil && info != nil && !info.IsDir() {
			found = append(found, p)
		}
		return nil
	})
	if len(found) != 0 {
		t.Fatalf("no shell/on-disk parallel cache may be written; found: %v", found)
	}
}

func TestNO_PERSISTED_CACHE_WRITER(t *testing.T) {
	// Populate a cache, then construct a FRESH module: nothing from the first cache may carry
	// over — proving there is no persisted writer/loader behind the cache.
	m1, _ := newEnforcingModule(t)
	const ip = "203.0.113.46"
	m1.applyBatchSignal(mkSig(ip, "scanner", "ban"))
	if _, ok := m1.decisionCache.Peek(netip.MustParseAddr(ip)); !ok {
		t.Fatal("precondition: first cache should hold the entry")
	}
	m2 := New()
	if _, ok := m2.decisionCache.Peek(netip.MustParseAddr(ip)); ok {
		t.Fatal("a fresh cache must start empty — no persisted cache writer/loader may exist")
	}
}
