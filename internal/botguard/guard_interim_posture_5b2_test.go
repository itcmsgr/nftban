// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: G1 cadence-gap interim dynamic posture (5B2)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Prove the v1.191 8B increment-5B2 cadence-gap posture: the request-blind L4
//          meter hit-count escalation is gated by the decision cache so it can only
//          throttle/ban IPs with dynamic-endpoint class evidence (dynamic_abuse/login_api/
//          scanner). Browser/static/e-shop/admin and mixed/unknown suspects are NOT rate-
//          banned (no browser-burst false positives). Abuse enforcement, endpoint-flood,
//          and DDoS/portscan authority are unchanged; no durable/shell/persisted state.
//
// meta:name="botguard_guard_interim_posture_5b2_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Tests for the G1 cadence-gap interim dynamic-endpoint posture (increment 5B2)"
// meta:inventory.files="guard_interim_posture_5b2_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/botguard/decisioncache"
)

// newClassifyingModule extends the enforcing module with a real classifier so classify()
// (the meter hit-count path) can be exercised end-to-end against the recording backend.
func newClassifyingModule(t *testing.T) (*Module, *recBackend) {
	t.Helper()
	m, b := newEnforcingModule(t)
	cls, err := NewClassifier(m.config, nil)
	if err != nil {
		t.Fatalf("NewClassifier: %v", err)
	}
	m.classifier = cls
	return m, b
}

func seedCandidate(t *testing.T, m *Module, ipStr, class string) {
	t.Helper()
	rec := decisioncache.Record{IP: netip.MustParseAddr(ipStr), State: decisioncache.StateCandidate, RequestClass: class}
	if err := m.decisionCache.Put(rec, time.Hour); err != nil {
		t.Fatalf("seed candidate %s/%s: %v", ipStr, class, err)
	}
}

// classifyAtHit drives the meter path: an existing pending suspect at the given hit-count.
func classifyAtHit(m *Module, ipStr string, hit int64) {
	ip := netip.MustParseAddr(ipStr)
	r := m.getOrCreate(ip)
	r.State = StatePending
	r.HitCount = hit
	m.classify(r)
}

func assertNotInSets(t *testing.T, b *recBackend, ip string, sets ...string) {
	t.Helper()
	time.Sleep(300 * time.Millisecond)
	for _, s := range sets {
		if b.has(s, ip) {
			t.Fatalf("%s must NOT be in %s (no interim throttle/ban); sets=%v", ip, s, b.adds)
		}
	}
}

// --- dynamic classes get interim protection (escalation allowed) -------------

func TestCANDIDATE_DYNAMIC_ABUSE_GETS_INTERIM_PROTECTION(t *testing.T) {
	m, b := newClassifyingModule(t)
	const ip = "198.51.100.60"
	seedCandidate(t, m, ip, "dynamic_abuse")
	classifyAtHit(m, ip, 10) // classifier → Ban/persistent_suspect; gate allows (dynamic)
	if !waitBanned(b, "http_bot_ban", ip) {
		t.Fatalf("dynamic_abuse candidate must get interim protection (reach http_bot_ban); sets=%v", b.adds)
	}
}

func TestCANDIDATE_LOGIN_API_GETS_INTERIM_PROTECTION(t *testing.T) {
	m, b := newClassifyingModule(t)
	const ip = "198.51.100.61"
	seedCandidate(t, m, ip, "login_api")
	classifyAtHit(m, ip, 10)
	if !waitBanned(b, "http_bot_ban", ip) {
		t.Fatalf("login_api candidate must get interim protection; sets=%v", b.adds)
	}
}

func TestCANDIDATE_SCANNER_GETS_INTERIM_PROTECTION(t *testing.T) {
	m, b := newClassifyingModule(t)
	const ip = "198.51.100.62"
	seedCandidate(t, m, ip, "scanner")
	classifyAtHit(m, ip, 10)
	if !waitBanned(b, "http_bot_ban", ip) {
		t.Fatalf("scanner candidate must get interim protection; sets=%v", b.adds)
	}
}

// --- browser-like classes never throttled by rate ----------------------------

func TestCANDIDATE_STATIC_DOES_NOT_GET_INTERIM_THROTTLE(t *testing.T) {
	m, b := newClassifyingModule(t)
	const ip = "203.0.113.60"
	seedCandidate(t, m, ip, "static")
	classifyAtHit(m, ip, 10) // classifier wants Ban; gate holds (no dynamic evidence)
	assertNotInSets(t, b, ip, "http_bot_ban", "http_bot_grey")
}

func TestCANDIDATE_STATIC404_DOES_NOT_GET_INTERIM_THROTTLE(t *testing.T) {
	m, b := newClassifyingModule(t)
	const ip = "203.0.113.61"
	seedCandidate(t, m, ip, "static404")
	classifyAtHit(m, ip, 10)
	assertNotInSets(t, b, ip, "http_bot_ban", "http_bot_grey")
}

func TestCANDIDATE_ESHOP_FANOUT_DOES_NOT_GET_INTERIM_THROTTLE(t *testing.T) {
	m, b := newClassifyingModule(t)
	const ip = "203.0.113.62"
	seedCandidate(t, m, ip, "eshop_fanout")
	classifyAtHit(m, ip, 10)
	assertNotInSets(t, b, ip, "http_bot_ban", "http_bot_grey")
}

func TestCANDIDATE_ADMIN_AJAX_DOES_NOT_GET_INTERIM_THROTTLE(t *testing.T) {
	m, b := newClassifyingModule(t)
	const ip = "203.0.113.63"
	seedCandidate(t, m, ip, "admin_ajax")
	classifyAtHit(m, ip, 10)
	assertNotInSets(t, b, ip, "http_bot_ban", "http_bot_grey")
}

func TestMIXED_CANDIDATE_DOES_NOT_RATE_BAN_WITHOUT_DYNAMIC_EVIDENCE(t *testing.T) {
	m, b := newClassifyingModule(t)
	const ip = "203.0.113.64"
	// No cache evidence at all (request-blind meter suspect): must not rate-ban.
	classifyAtHit(m, ip, 10)
	assertNotInSets(t, b, ip, "http_bot_ban", "http_bot_grey")
	// Same for an explicit mixed candidate.
	const ip2 = "203.0.113.65"
	seedCandidate(t, m, ip2, "mixed")
	classifyAtHit(m, ip2, 10)
	assertNotInSets(t, b, ip2, "http_bot_ban", "http_bot_grey")
}

// --- legit / blocked cache semantics -----------------------------------------

func TestLEGIT_TEMPORARILY_SUPPRESSES_SAME_BROWSER_CLASS_ONLY(t *testing.T) {
	m, b := newEnforcingModule(t)
	const ip = "198.51.100.65"
	m.applyBatchSignal(mkSig(ip, "static", "ban")) // browser-like → suppressed
	assertNotBanned(t, b, "http_bot_ban", ip)
	m.applyBatchSignal(mkSig(ip, "scanner", "ban")) // abuse class → not suppressed
	if !waitBanned(b, "http_bot_ban", ip) {
		t.Fatalf("scanner must still ban for same IP (suppression is browser-class only); sets=%v", b.adds)
	}
}

func TestLEGIT_TEMPORARILY_DOES_NOT_SUPPRESS_DYNAMIC_ABUSE_5B2(t *testing.T) {
	m, b := newEnforcingModule(t)
	const ip = "198.51.100.66"
	if err := m.decisionCache.Put(decisioncache.Record{IP: netip.MustParseAddr(ip), State: decisioncache.StateLegitTemporarily}, 0); err != nil {
		t.Fatalf("seed legit: %v", err)
	}
	m.applyBatchSignal(mkSig(ip, "dynamic_abuse", "ban"))
	if !waitBanned(b, "http_bot_ban", ip) {
		t.Fatalf("legit_temporarily must not suppress dynamic_abuse; sets=%v", b.adds)
	}
}

func TestBLOCKED_TEMPORARILY_AVOIDS_RECLASSIFICATION_WHILE_ACTIVE(t *testing.T) {
	m, _ := newEnforcingModule(t)
	ip := netip.MustParseAddr("198.51.100.67")
	if err := m.decisionCache.Put(decisioncache.Record{IP: ip, State: decisioncache.StateBlockedTemporarily, RequestClass: "scanner"}, time.Hour); err != nil {
		t.Fatalf("seed blocked: %v", err)
	}
	// While blocked_temporarily is active, the posture holds protection in force and a rate
	// escalation is NOT downgraded (enforcement preserved without reclassification churn).
	if p := m.interimPostureForIP(ip); p != interimProtectDynamic {
		t.Fatalf("blocked_temporarily(dynamic) posture = %v, want interimProtectDynamic", p)
	}
	r := &IPRecord{IP: ip, State: StatePending, HitCount: 10}
	res := m.gateInterimRateEscalation(r, ClassifyResult{State: StateBan, Reason: "persistent_suspect"})
	if res.State != StateBan {
		t.Fatalf("blocked_temporarily active must preserve escalation, got %s", res.State)
	}
}

// --- fail-safe in both directions --------------------------------------------

func TestCACHE_ERROR_DOES_NOT_BAN_BROWSER_LIKE_TRAFFIC(t *testing.T) {
	m, b := newClassifyingModule(t)
	fillCacheToError(t, m) // Peek of any IP now misses → posture interimNone
	const ip = "203.0.113.67"
	classifyAtHit(m, ip, 10) // gate holds (no evidence) → no rate-ban
	assertNotInSets(t, b, ip, "http_bot_ban", "http_bot_grey")
}

func TestCACHE_ERROR_DOES_NOT_SUPPRESS_DYNAMIC_ABUSE_5B2(t *testing.T) {
	m, b := newEnforcingModule(t)
	fillCacheToError(t, m)
	const ip = "198.51.100.68"
	// The authoritative dynamic-abuse enforcement is the batch path (cache-independent).
	m.applyBatchSignal(mkSig(ip, "dynamic_abuse", "ban"))
	if !waitBanned(b, "http_bot_ban", ip) {
		t.Fatalf("cache error must not suppress dynamic_abuse enforcement; sets=%v", b.adds)
	}
}

// --- regression guards -------------------------------------------------------

func TestENDPOINT_FLOOD_BEHAVIOR_PRESERVED(t *testing.T) {
	m, b := newEnforcingModule(t)
	const ip = "198.51.100.69"
	// Endpoint-flood produces a dynamic_abuse ban signal; it must still reach http_bot_ban.
	m.applyBatchSignal(mkSig(ip, "dynamic_abuse", "ban", "endpoint_flood POST /xmlrpc.php"))
	if !waitBanned(b, "http_bot_ban", ip) {
		t.Fatalf("endpoint-flood ban must be preserved; sets=%v", b.adds)
	}
}

func TestDDOS_PORTSCAN_AUTHORITY_UNCHANGED(t *testing.T) {
	m, b := newClassifyingModule(t)
	// A dynamic candidate escalation + an abuse batch ban — BotGuard must only ever write its
	// own http_bot_* sets, never blacklist/ddos/portscan sets (no authority overlap).
	seedCandidate(t, m, "198.51.100.70", "scanner")
	classifyAtHit(m, "198.51.100.70", 10)
	m.applyBatchSignal(mkSig("198.51.100.71", "dynamic_abuse", "ban"))
	time.Sleep(300 * time.Millisecond)
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.adds) == 0 {
		t.Fatal("precondition: expected at least one enforcement write")
	}
	for set := range b.adds {
		if !strings.HasPrefix(set, "http_bot") {
			t.Fatalf("BotGuard must only touch http_bot_* sets; saw %q (ddos/portscan/blacklist authority must be unchanged)", set)
		}
	}
}

// --- no durable / no on-disk / no persisted writer ---------------------------

func TestNO_DURABLE_STATE_CREATED_5B2(t *testing.T) {
	m, _ := newClassifyingModule(t)
	allowed := map[decisioncache.State]bool{
		decisioncache.StateCandidate: true, decisioncache.StateChecking: true,
		decisioncache.StateLegitTemporarily: true, decisioncache.StateBlockedTemporarily: true,
		decisioncache.StateAmbiguous: true,
	}
	classes := []string{"dynamic_abuse", "login_api", "scanner", "static", "static404", "eshop_fanout", "admin_ajax", "mixed", ""}
	for i, c := range classes {
		ip := netip.AddrFrom4([4]byte{10, 12, byte(i >> 8), byte(i)})
		seedCandidate(t, m, ip.String(), c)
		classifyAtHit(m, ip.String(), 10)
	}
	for st := range m.decisionCache.Stats().ByState {
		if !allowed[st] {
			t.Fatalf("durable/invalid state %q created during 5B2", st)
		}
	}
}

func TestNO_SHELL_PARALLEL_CACHE_5B2(t *testing.T) {
	dir := t.TempDir()
	m, _ := newClassifyingModule(t)
	for i := 0; i < 30; i++ {
		ip := netip.AddrFrom4([4]byte{172, 18, byte(i >> 8), byte(i)})
		seedCandidate(t, m, ip.String(), "scanner")
		classifyAtHit(m, ip.String(), 10)
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

func TestNO_PERSISTED_CACHE_WRITER_5B2(t *testing.T) {
	m1, _ := newClassifyingModule(t)
	seedCandidate(t, m1, "198.51.100.72", "scanner")
	if _, ok := m1.decisionCache.Peek(netip.MustParseAddr("198.51.100.72")); !ok {
		t.Fatal("precondition: first cache should hold the entry")
	}
	m2 := New()
	if _, ok := m2.decisionCache.Peek(netip.MustParseAddr("198.51.100.72")); ok {
		t.Fatal("a fresh cache must start empty — no persisted cache writer/loader may exist")
	}
}
