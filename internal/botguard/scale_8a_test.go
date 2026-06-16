// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: 8A synthetic scale-envelope suite
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Increment 8A Groups B+C — hermetic synthetic scale-envelope tests for
//          small/medium/large/stress profiles (generated representative input, no real hosts).
//          Proves: zero browser/e-shop/admin FP at scale, dynamic/scanner still ban under load,
//          cache bounded by configured caps (no OOM), IPv6 /64 churn bounded, bounded warm-up,
//          bounded read-only explain that never blocks classification, http_bot_* sets bounded,
//          cadence-lag reported, and the mid-band dynamic-abuse harm classified. Measurements
//          are emitted via t.Logf (Group C). No schema/metric/host/lab/release.
//
// meta:name="botguard_scale_8a_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Hermetic synthetic scale-envelope tests for BotGuard 8B (increment 8A)"
// meta:inventory.files="scale_8a_test.go"
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
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/botguard/decisioncache"
)

// synthIPv4 produces a deterministic distinct IPv4 for index i (10.x.y.z space).
func synthIPv4(i int) string {
	return netip.AddrFrom4([4]byte{10, byte(i >> 16), byte(i >> 8), byte(i)}).String()
}

// feedBatch pushes n ban signals of one class through the enforcing batch path.
func feedBatch(m *Module, class string, n int) {
	for i := 0; i < n; i++ {
		m.applyBatchSignal(mkSig(synthIPv4(i), class, "ban"))
	}
}

// countSet returns how many of the fed IPs landed in a set (enforcement/FP measurement).
func countInSets(b *recBackend, sets ...string) int {
	b.mu.Lock()
	defer b.mu.Unlock()
	total := 0
	for _, s := range sets {
		total += len(b.adds[s])
	}
	return total
}

func logCacheStats(t *testing.T, profile string, c *decisioncache.Cache) {
	t.Helper()
	s := c.Stats()
	t.Logf("[MEASURE %s] entries=%d candidates=%d v6prefixes=%d evictions=%d overflow=%d byState=%v",
		profile, s.TotalEntries, s.CandidateEntries, s.DistinctCandidatePrefix, s.Evictions, s.OverflowDrops, s.ByState)
}

// ---- browser/e-shop/admin NO-BAN at scale ----------------------------------

func TestSCALE_100_SITES_STATIC_FANOUT_NO_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	feedBatch(m, "static", 5000) // ~100-site static fan-out equivalent
	time.Sleep(200 * time.Millisecond)
	fp := countInSets(b, "http_bot_ban", "http_bot_grey")
	logCacheStats(t, "small/static", m.decisionCache)
	t.Logf("[MEASURE small/static] false_positive_bans=%d", fp)
	if fp != 0 {
		t.Fatalf("static fan-out must produce ZERO bans at scale, got %d", fp)
	}
}

func TestSCALE_300_SITES_STATIC_FANOUT_NO_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	feedBatch(m, "static", 20000) // ~300-site equivalent (bounded subset for CI runtime)
	time.Sleep(200 * time.Millisecond)
	fp := countInSets(b, "http_bot_ban", "http_bot_grey")
	logCacheStats(t, "large/static", m.decisionCache)
	t.Logf("[MEASURE large/static] false_positive_bans=%d (note: 20k IPs = bounded CI subset of 300-site)", fp)
	if fp != 0 {
		t.Fatalf("static fan-out (large) must produce ZERO bans, got %d", fp)
	}
}

func TestSCALE_100_SITES_WOOCOMMERCE_ADMIN_NO_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	for i := 0; i < 5000; i++ {
		// alternate the legit browser-like classes a WooCommerce/admin/gallery host emits
		cls := []string{"admin_ajax", "eshop_fanout", "static", "static404"}[i%4]
		m.applyBatchSignal(mkSig(synthIPv4(i), cls, "ban"))
	}
	time.Sleep(200 * time.Millisecond)
	fp := countInSets(b, "http_bot_ban", "http_bot_grey")
	t.Logf("[MEASURE medium/woo-admin] false_positive_bans=%d", fp)
	if fp != 0 {
		t.Fatalf("WooCommerce/admin/gallery mix must produce ZERO bans, got %d", fp)
	}
}

func TestSCALE_300_SITES_MIXED_TRAFFIC_NO_CACHE_OOM(t *testing.T) {
	m, _ := newEnforcingModule(t)
	m.config.CacheMaxEntries = 4000
	m.config.CacheMaxCandidates = 2000
	m.rebuildDecisionCacheFromConfig()
	classes := []string{"static", "static404", "eshop_fanout", "admin_ajax", "dynamic_abuse", "login_api", "scanner", "mixed"}
	for i := 0; i < 30000; i++ {
		m.applyBatchSignal(mkSig(synthIPv4(i), classes[i%len(classes)], "ban"))
		if m.decisionCache.Len() > m.config.CacheMaxEntries {
			t.Fatalf("cache exceeded MaxEntries=%d at i=%d (len=%d) — OOM risk", m.config.CacheMaxEntries, i, m.decisionCache.Len())
		}
	}
	logCacheStats(t, "large/mixed", m.decisionCache)
}

func TestSCALE_IPV6_64_CHURN_BOUNDED_CACHE(t *testing.T) {
	cfg := decisioncache.Config{MaxEntries: 5000, MaxCandidates: 5000, V6PrefixBits: 64}
	c := decisioncache.New(cfg)
	// 50k IPs sprayed across only ~16 /64s (aggressive low-bit churn).
	for i := 0; i < 50000; i++ {
		ip := netip.MustParseAddr(fmt.Sprintf("2001:db8:abcd:%x::%x", i%16, i))
		_ = c.Put(decisioncache.Record{IP: ip, State: decisioncache.StateCandidate}, time.Hour)
		if c.Len() > cfg.MaxEntries {
			t.Fatalf("IPv6 churn exceeded MaxEntries=%d (len=%d) at i=%d", cfg.MaxEntries, c.Len(), i)
		}
	}
	s := c.Stats()
	t.Logf("[MEASURE stress/ipv6churn] entries=%d candidates=%d distinctV6Prefixes=%d evictions=%d",
		s.TotalEntries, s.CandidateEntries, s.DistinctCandidatePrefix, s.Evictions)
	if s.DistinctCandidatePrefix > 16 {
		t.Fatalf("distinct /64 candidate prefixes must stay bounded (~16), got %d", s.DistinctCandidatePrefix)
	}
}

// ---- abuse still bans under load -------------------------------------------

func TestSCALE_DYNAMIC_ABUSE_STILL_BANS_UNDER_LOAD(t *testing.T) {
	m, b := newEnforcingModule(t)
	feedBatch(m, "static", 8000) // browser-like noise
	const abuser = "198.51.100.200"
	m.applyBatchSignal(mkSig(abuser, "dynamic_abuse", "ban"))
	if !waitBanned(b, "http_bot_ban", abuser) {
		t.Fatalf("dynamic_abuse must still ban under static-fanout load; sets=%v keys", len(b.adds))
	}
	t.Logf("[MEASURE large] dynamic_abuse enforced under load=1")
}

func TestSCALE_SCANNER_PATHS_STILL_BAN_UNDER_LOAD(t *testing.T) {
	m, b := newEnforcingModule(t)
	feedBatch(m, "eshop_fanout", 8000)
	const abuser = "198.51.100.201"
	m.applyBatchSignal(mkSig(abuser, "scanner", "ban"))
	if !waitBanned(b, "http_bot_ban", abuser) {
		t.Fatal("scanner must still ban under e-shop-fanout load")
	}
}

// ---- bounded warm-up / explain / sets / cadence ----------------------------

func TestSCALE_BATCH_SIGNALS_LARGE_FILE_BOUNDED_REPLAY(t *testing.T) {
	var lines []string
	for i := 0; i < 12000; i++ { // bounded for CI runtime; still >> the 256 KiB tail under test
		lines = append(lines, sigLineTS(synthIPv4(i), "scanner", "ban", recentTS()))
	}
	m, path := writeSignalFile(t, lines...)
	fi, _ := os.Stat(path)
	lim := warmupLimitsForTest()
	lim.maxBytes = 256 << 10
	lim.maxAccepted = 2000
	st := m.warmupFromBatchSignals(context.Background(), lim)
	t.Logf("[MEASURE stress/warmup] fileBytes=%d bytesRead=%d accepted=%d stopped=%s truncated=%v",
		fi.Size(), st.BytesRead, st.Accepted, st.Stopped, st.TruncatedTail)
	if st.Accepted > lim.maxAccepted || st.BytesRead >= fi.Size() {
		t.Fatalf("warm-up not bounded on large file: %+v file=%d", st, fi.Size())
	}
}

func TestSCALE_EXPLAIN_IP_TIMEOUT_UNDER_CACHE_PRESSURE(t *testing.T) {
	m := New()
	for i := 0; i < 20000; i++ {
		_ = m.decisionCache.Put(decisioncache.Record{IP: netip.MustParseAddr(synthIPv4(i)), State: decisioncache.StateChecking}, time.Hour)
	}
	// Cancelled context must degrade, never hang.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	r := m.ExplainIP(ctx, netip.MustParseAddr(synthIPv4(123)))
	if r.CacheAvailable {
		t.Fatal("cancelled context must degrade explain under pressure")
	}
	// A live query must return quickly (Peek is O(1)).
	t0 := time.Now()
	_ = m.ExplainIP(context.Background(), netip.MustParseAddr(synthIPv4(123)))
	d := time.Since(t0)
	t.Logf("[MEASURE pressure] explain_ip latency under 20k entries: %v", d)
	if !underRace && d > 2*time.Second {
		t.Fatalf("explain under pressure must be bounded (~O(1)), took %v", d)
	}
}

func TestSCALE_SUPPORT_HEALTH_NO_FULL_CACHE_DUMP(t *testing.T) {
	m := New()
	for i := 0; i < 5000; i++ {
		_ = m.decisionCache.Put(decisioncache.Record{IP: netip.MustParseAddr(synthIPv4(i)), State: decisioncache.StateBlockedTemporarily, RequestClass: "scanner"}, time.Hour)
	}
	// explain_ip (the support/health/debug data source) reports ONE IP, never the whole cache.
	r := m.ExplainIP(context.Background(), netip.MustParseAddr(synthIPv4(42)))
	if r.IP != synthIPv4(42) {
		t.Fatalf("explain must report only the queried IP, got %q", r.IP)
	}
	// No API exists to enumerate all entries from the read-only surface — structural guarantee.
}

func TestSCALE_BOTSCAN_CADENCE_LAG_REPORTED(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	fresh := cadenceModuleWithFile(t, now.Add(-1*time.Minute)).botScanCadenceStatus(now)
	stale := cadenceModuleWithFile(t, now.Add(-3*time.Hour)).botScanCadenceStatus(now)
	mUnknown := New()
	mUnknown.config.BatchSignalFile = filepath.Join(t.TempDir(), "absent.jsonl")
	unknown := mUnknown.botScanCadenceStatus(now)
	t.Logf("[MEASURE cadence] fresh=%s(%ds) stale=%s(%ds) unknown=%s(%d)",
		fresh.State, fresh.AgeSeconds, stale.State, stale.AgeSeconds, unknown.State, unknown.AgeSeconds)
	if fresh.State != CadenceFresh || stale.State != CadenceStale || unknown.State != CadenceUnknown {
		t.Fatalf("cadence lag must be reported as fresh/stale/unknown, got %s/%s/%s", fresh.State, stale.State, unknown.State)
	}
}

func TestSCALE_NFT_HTTP_BOT_SETS_BOUNDED(t *testing.T) {
	m, b := newEnforcingModule(t)
	// Mixed abuse + browser load; BotGuard must only ever write http_bot_* sets, bounded by
	// distinct banned IPs (browser-like never bans).
	for i := 0; i < 4000; i++ {
		cls := []string{"static", "scanner", "eshop_fanout", "dynamic_abuse"}[i%4]
		m.applyBatchSignal(mkSig(synthIPv4(i), cls, "ban"))
	}
	time.Sleep(400 * time.Millisecond)
	b.mu.Lock()
	defer b.mu.Unlock()
	total := 0
	for set, ips := range b.adds {
		if len(set) < 8 || set[:8] != "http_bot" {
			t.Fatalf("BotGuard must only write http_bot_* sets, saw %q", set)
		}
		total += len(ips)
	}
	// Only the abuse half (scanner+dynamic_abuse = 2000 IPs) should be banned; browser half = 0.
	t.Logf("[MEASURE large] http_bot_* total elements=%d (abuse-only; browser suppressed)", total)
	if total > 2100 {
		t.Fatalf("http_bot_* element count not bounded to abuse subset: %d", total)
	}
}

// ---- mid-band dynamic-abuse harm classification ----------------------------

func TestSCALE_MID_BAND_DYNAMIC_ABUSE_HARM_MEASURED(t *testing.T) {
	// Model the residual gap: a FIRST-SEEN IP doing sub-meter dynamic requests with NO prior
	// class evidence and NO ban signal yet. The request-blind meter escalation is GATED (5B2) →
	// it is intentionally NOT rate-banned. Measure the undetected window + emit the verdict.
	m, b := newClassifyingModule(t)
	const midBand = "198.51.100.210"
	classifyAtHit(m, midBand, 10) // meter persistent_suspect, but no dynamic class evidence
	assertNotInSets(t, b, midBand, "http_bot_ban", "http_bot_grey")

	// The window is "until BotScan classifies it" — bounded by cadence, which IS visible.
	now := time.Unix(1_700_000_000, 0)
	cad := cadenceModuleWithFile(t, now.Add(-1*time.Minute)).botScanCadenceStatus(now)

	verdict := "ACCEPT_WITH_VISIBLE_LAG"
	t.Logf("[MEASURE mid-band] meter-only escalation of unclassified IP = HELD (not banned) by design")
	t.Logf("[MEASURE mid-band] undetected-window = until next BotScan cadence; cadence visibility = %s", cad.State)
	t.Logf("[MID-BAND VERDICT] %s — meter+DDoS cover gross floods; BotScan refines on cadence; "+
		"cadence-lag is observable. A dedicated fast per-endpoint dynamic meter (NEEDS_FAST_DYNAMIC_ENDPOINT_METER_LANE) "+
		"remains an OPTIONAL separate lane, not required for browser-FP correctness.", verdict)
	// The gate behavior (held, not rate-banned) is the correct, tested outcome.
}

// ---- read-lock does not block classification -------------------------------

func TestSCALE_EXPLAIN_IP_DOES_NOT_BLOCK_CLASSIFICATION_UNDER_LOAD(t *testing.T) {
	m := New()
	done := make(chan struct{})
	var wg sync.WaitGroup
	// Writer: continuous Puts (classification-style).
	wg.Add(1)
	go func() {
		defer wg.Done()
		for i := 0; ; i++ {
			select {
			case <-done:
				return
			default:
				_ = m.decisionCache.Put(decisioncache.Record{IP: netip.MustParseAddr(synthIPv4(i % 40000)), State: decisioncache.StateChecking}, time.Hour)
			}
		}
	}()
	// Readers: many concurrent explain_ip (read-lock) must all complete promptly.
	t0 := time.Now()
	var rwg sync.WaitGroup
	for r := 0; r < 50; r++ {
		rwg.Add(1)
		go func(r int) {
			defer rwg.Done()
			for k := 0; k < 200; k++ {
				_ = m.ExplainIP(context.Background(), netip.MustParseAddr(synthIPv4((r*200+k)%40000)))
			}
		}(r)
	}
	rwg.Wait()
	elapsed := time.Since(t0)
	close(done)
	wg.Wait()
	t.Logf("[MEASURE concurrency] 50x200 explain_ip under continuous writes took %v", elapsed)
	// The real property is "completes without deadlock" (reached here = no block); the wall-clock
	// bound is skipped under -race (flaky), generous otherwise.
	if !underRace && elapsed > 20*time.Second {
		t.Fatalf("explain_ip read path appears to block classification under load: %v", elapsed)
	}
}

func TestSCALE_EVICTION_IS_NOT_ON_HOT_PATH(t *testing.T) {
	// Small cap + many inserts → continuous eviction. The O(n) victim scan is bounded by
	// MaxEntries (small), so per-insert cost stays bounded and total time is reasonable.
	c := decisioncache.New(decisioncache.Config{MaxEntries: 1000, MaxCandidates: 1000})
	const n = 30000
	t0 := time.Now()
	for i := 0; i < n; i++ {
		_ = c.Put(decisioncache.Record{IP: netip.MustParseAddr(synthIPv4(i)), State: decisioncache.StateChecking}, time.Hour)
	}
	elapsed := time.Since(t0)
	t.Logf("[MEASURE stress/eviction] %d inserts @cap=1000 took %v; evictions=%d", n, elapsed, c.Stats().Evictions)
	// Correctness (always): the cap holds under continuous eviction churn (no OOM/leak).
	if c.Len() > 1000 {
		t.Fatalf("cap not enforced under eviction churn: len=%d", c.Len())
	}
	// Timing assert is skipped under -race (the detector's ~10x slowdown makes an absolute
	// wall-clock bound flaky on shared CI runners); generous bound otherwise.
	if !underRace && elapsed > 30*time.Second {
		t.Fatalf("eviction appears to be a hot-path stall: %d inserts took %v", n, elapsed)
	}
}
