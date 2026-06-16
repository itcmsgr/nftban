// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: Bounded warm-up replay tests (inc7)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Prove the v1.191 8B increment-7 restart warm-up: it replays only the bounded recent
//          tail of batch_signals.jsonl into the TEMPORARY decision cache (cache context only,
//          never enforcement, never durable, never a new persisted writer), is bounded for
//          large 100–300-site hosts (bytes/lines/age/accepted/budget; never reads the whole
//          file), and degrades to a no-op on missing/empty/malformed/nil-cache without panic.
//
// meta:name="botguard_warmup_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Unit tests for the bounded BotGuard decision-cache warm-up replay"
// meta:inventory.files="warmup_test.go"
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
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// fixedNow used for deterministic age cutoffs.
var warmupFixedNow = time.Unix(1_700_000_000, 0)

func warmupLimitsForTest() warmupLimits {
	l := defaultWarmupLimits()
	l.now = func() time.Time { return warmupFixedNow }
	return l
}

func sigLineTS(ip, class, action string, ts int64) string {
	s := BatchSignal{IP: ip, Score: 80, Action: action, RequestClass: class, TS: ts}
	b, _ := json.Marshal(s)
	return string(b)
}

// recentTS / oldTS relative to warmupFixedNow.
func recentTS() int64 { return warmupFixedNow.Add(-1 * time.Minute).Unix() }
func oldTS() int64    { return warmupFixedNow.Add(-2 * time.Hour).Unix() }

func writeSignalFile(t *testing.T, lines ...string) (*Module, string) {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "batch_signals.jsonl")
	if len(lines) > 0 {
		data := ""
		for _, l := range lines {
			data += l + "\n"
		}
		if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
			t.Fatalf("write signal file: %v", err)
		}
	}
	m := New()
	m.config.BatchSignalFile = path
	return m, path
}

func TestWARMUP_MISSING_BATCH_SIGNALS_NOOP(t *testing.T) {
	m := New()
	m.config.BatchSignalFile = filepath.Join(t.TempDir(), "does-not-exist.jsonl")
	st := m.warmupFromBatchSignals(context.Background(), warmupLimitsForTest())
	if st.Accepted != 0 || m.decisionCache.Len() != 0 {
		t.Fatalf("missing file must be a no-op: %+v len=%d", st, m.decisionCache.Len())
	}
}

func TestWARMUP_EMPTY_BATCH_SIGNALS_NOOP(t *testing.T) {
	m, _ := writeSignalFile(t) // creates no file (len 0) → simulate empty by touching
	path := m.config.BatchSignalFile
	if err := os.WriteFile(path, []byte(""), 0o600); err != nil {
		t.Fatal(err)
	}
	st := m.warmupFromBatchSignals(context.Background(), warmupLimitsForTest())
	if st.Accepted != 0 || m.decisionCache.Len() != 0 {
		t.Fatalf("empty file must be a no-op: %+v", st)
	}
}

func TestWARMUP_REPLAYS_RECENT_STRUCTURED_SIGNAL(t *testing.T) {
	m, _ := writeSignalFile(t, sigLineTS("198.51.100.10", "scanner", "ban", recentTS()))
	st := m.warmupFromBatchSignals(context.Background(), warmupLimitsForTest())
	if st.Accepted != 1 {
		t.Fatalf("expected 1 accepted, got %+v", st)
	}
	r, ok := m.decisionCache.Peek(netip.MustParseAddr("198.51.100.10"))
	if !ok || r.State != "blocked_temporarily" || r.RequestClass != "scanner" {
		t.Fatalf("recent structured signal must warm cache, got ok=%v %+v", ok, r)
	}
}

func TestWARMUP_OLD_SIGNAL_DEFAULTS_MIXED(t *testing.T) {
	// No request_class field → normalizes to "mixed" → ambiguous.
	line := fmt.Sprintf(`{"ip":"198.51.100.11","score":80,"reasons":["x"],"action":"ban","ts":%d}`, recentTS())
	m, _ := writeSignalFile(t, line)
	st := m.warmupFromBatchSignals(context.Background(), warmupLimitsForTest())
	if st.Accepted != 1 {
		t.Fatalf("expected 1 accepted, got %+v", st)
	}
	r, _ := m.decisionCache.Peek(netip.MustParseAddr("198.51.100.11"))
	if r.RequestClass != "mixed" || r.State != "ambiguous" {
		t.Fatalf("class-less signal must default mixed/ambiguous, got %+v", r)
	}
}

func TestWARMUP_DERIVES_FAMILY_FOR_OLD_SIGNAL(t *testing.T) {
	line := fmt.Sprintf(`{"ip":"2001:db8::77","score":80,"action":"ban","ts":%d}`, recentTS())
	m, _ := writeSignalFile(t, line)
	m.warmupFromBatchSignals(context.Background(), warmupLimitsForTest())
	r, ok := m.decisionCache.Peek(netip.MustParseAddr("2001:db8::77"))
	if !ok || r.Family != "ipv6" {
		t.Fatalf("family must be derived ipv6, got ok=%v %+v", ok, r)
	}
}

func TestWARMUP_SKIPS_TOO_OLD_SIGNAL(t *testing.T) {
	m, _ := writeSignalFile(t, sigLineTS("198.51.100.12", "scanner", "ban", oldTS()))
	st := m.warmupFromBatchSignals(context.Background(), warmupLimitsForTest())
	if st.SkippedOld != 1 || st.Accepted != 0 {
		t.Fatalf("too-old signal must be skipped, got %+v", st)
	}
	if _, ok := m.decisionCache.Peek(netip.MustParseAddr("198.51.100.12")); ok {
		t.Fatal("too-old signal must not warm the cache")
	}
}

func TestWARMUP_SKIPS_MALFORMED_LINE(t *testing.T) {
	m, _ := writeSignalFile(t,
		"not json at all {{{",
		sigLineTS("198.51.100.13", "dynamic_abuse", "ban", recentTS()),
		`{"score":1}`, // missing ip
	)
	st := m.warmupFromBatchSignals(context.Background(), warmupLimitsForTest())
	if st.SkippedMalformed < 2 || st.Accepted != 1 {
		t.Fatalf("malformed lines skipped+counted, good one accepted: %+v", st)
	}
}

func TestWARMUP_BOUNDS_MAX_LINES(t *testing.T) {
	var lines []string
	for i := 0; i < 50; i++ {
		lines = append(lines, sigLineTS(fmt.Sprintf("10.0.%d.%d", i/256, i%256), "scanner", "ban", recentTS()))
	}
	m, _ := writeSignalFile(t, lines...)
	lim := warmupLimitsForTest()
	lim.maxLines = 10
	lim.maxAccepted = 100000
	st := m.warmupFromBatchSignals(context.Background(), lim)
	if st.LinesScanned > 10 || st.Stopped != "max_lines" {
		t.Fatalf("must bound at maxLines=10, got %+v", st)
	}
}

func TestWARMUP_BOUNDS_MAX_BYTES(t *testing.T) {
	var lines []string
	for i := 0; i < 200; i++ {
		lines = append(lines, sigLineTS(fmt.Sprintf("10.1.%d.%d", i/256, i%256), "scanner", "ban", recentTS()))
	}
	m, path := writeSignalFile(t, lines...)
	fi, _ := os.Stat(path)
	lim := warmupLimitsForTest()
	lim.maxBytes = 512 // tiny tail
	st := m.warmupFromBatchSignals(context.Background(), lim)
	if !st.TruncatedTail {
		t.Fatalf("large file must mark TruncatedTail, got %+v", st)
	}
	if st.BytesRead > lim.maxBytes+int64(lim.maxLineSize) {
		t.Fatalf("must read only the bounded tail, BytesRead=%d file=%d", st.BytesRead, fi.Size())
	}
}

func TestWARMUP_BOUNDS_MAX_DURATION_OR_CONTEXT(t *testing.T) {
	var lines []string
	for i := 0; i < 100; i++ {
		lines = append(lines, sigLineTS(fmt.Sprintf("10.2.%d.%d", i/256, i%256), "scanner", "ban", recentTS()))
	}
	m, _ := writeSignalFile(t, lines...)
	ctx, cancel := context.WithCancel(context.Background())
	cancel() // already cancelled → replay must stop immediately
	st := m.warmupFromBatchSignals(ctx, warmupLimitsForTest())
	if st.Accepted != 0 || st.Stopped != "timeout" {
		t.Fatalf("cancelled context must stop replay immediately, got %+v", st)
	}
}

func TestWARMUP_DOES_NOT_READ_WHOLE_LARGE_FILE(t *testing.T) {
	var lines []string
	for i := 0; i < 5000; i++ {
		lines = append(lines, sigLineTS(fmt.Sprintf("10.3.%d.%d", (i/256)%256, i%256), "scanner", "ban", recentTS()))
	}
	m, path := writeSignalFile(t, lines...)
	fi, _ := os.Stat(path)
	lim := warmupLimitsForTest()
	lim.maxBytes = 64 << 10 // 64 KiB tail of a much larger file
	st := m.warmupFromBatchSignals(context.Background(), lim)
	if fi.Size() <= lim.maxBytes {
		t.Skip("file not large enough to exercise tail bound")
	}
	if !st.TruncatedTail || st.BytesRead >= fi.Size() {
		t.Fatalf("must not read whole file: BytesRead=%d file=%d trunc=%v", st.BytesRead, fi.Size(), st.TruncatedTail)
	}
}

func TestWARMUP_DOES_NOT_ENFORCE_BAN_DIRECTLY(t *testing.T) {
	m, b := newEnforcingModule(t) // real OpQueue + recording NetlinkBackend
	dir := t.TempDir()
	path := filepath.Join(dir, "batch_signals.jsonl")
	if err := os.WriteFile(path, []byte(sigLineTS("198.51.100.14", "scanner", "ban", recentTS())+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	m.config.BatchSignalFile = path
	m.warmupFromBatchSignals(context.Background(), warmupLimitsForTest())
	time.Sleep(150 * time.Millisecond)
	b.mu.Lock()
	defer b.mu.Unlock()
	if len(b.adds) != 0 {
		t.Fatalf("warm-up must NOT enqueue any enforcement; saw %v", b.adds)
	}
}

func TestWARMUP_DOES_NOT_CREATE_DURABLE_STATE(t *testing.T) {
	classes := []string{"static", "static404", "eshop_fanout", "admin_ajax", "dynamic_abuse", "login_api", "scanner", "mixed", ""}
	var lines []string
	for i, c := range classes {
		lines = append(lines, sigLineTS(fmt.Sprintf("10.4.0.%d", i), c, "ban", recentTS()))
	}
	m, _ := writeSignalFile(t, lines...)
	m.warmupFromBatchSignals(context.Background(), warmupLimitsForTest())
	allowed := map[string]bool{"candidate": true, "checking": true, "legit_temporarily": true, "blocked_temporarily": true, "ambiguous": true}
	for st := range m.decisionCache.Stats().ByState {
		if !allowed[string(st)] {
			t.Fatalf("warm-up created a durable/invalid state %q", st)
		}
	}
}

func TestWARMUP_BROWSER_LIKE_DOES_NOT_BECOME_BLOCK(t *testing.T) {
	m, _ := writeSignalFile(t, sigLineTS("203.0.113.50", "static", "ban", recentTS()))
	m.warmupFromBatchSignals(context.Background(), warmupLimitsForTest())
	r, ok := m.decisionCache.Peek(netip.MustParseAddr("203.0.113.50"))
	if !ok || r.State == "blocked_temporarily" {
		t.Fatalf("browser-like warm must NOT be blocked, got ok=%v %+v", ok, r)
	}
	if r.State != "legit_temporarily" {
		t.Fatalf("static warm should be legit_temporarily, got %s", r.State)
	}
}

func TestWARMUP_DYNAMIC_ABUSE_RESTORES_TEMP_BLOCKED_CONTEXT(t *testing.T) {
	m, _ := writeSignalFile(t, sigLineTS("198.51.100.15", "dynamic_abuse", "ban", recentTS()))
	m.warmupFromBatchSignals(context.Background(), warmupLimitsForTest())
	r, ok := m.decisionCache.Peek(netip.MustParseAddr("198.51.100.15"))
	if !ok || r.State != "blocked_temporarily" {
		t.Fatalf("dynamic_abuse+ban warm must restore blocked_temporarily, got ok=%v %+v", ok, r)
	}
}

func TestWARMUP_CACHE_UNAVAILABLE_DEGRADES_NO_PANIC(t *testing.T) {
	m, _ := writeSignalFile(t, sigLineTS("198.51.100.16", "scanner", "ban", recentTS()))
	m.decisionCache = nil // simulate unavailable cache
	st := m.warmupFromBatchSignals(context.Background(), warmupLimitsForTest())
	if st.Accepted != 0 || st.Stopped != "noop" {
		t.Fatalf("nil cache must no-op without panic, got %+v", st)
	}
}

func TestWARMUP_NO_PERSISTED_CACHE_WRITER(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "batch_signals.jsonl")
	if err := os.WriteFile(path, []byte(sigLineTS("198.51.100.17", "scanner", "ban", recentTS())+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	m := New()
	m.config.BatchSignalFile = path
	before, _ := os.ReadDir(dir)
	m.warmupFromBatchSignals(context.Background(), warmupLimitsForTest())
	after, _ := os.ReadDir(dir)
	if len(after) != len(before) {
		t.Fatalf("warm-up must not create any file (no persisted cache writer): before=%d after=%d", len(before), len(after))
	}
	// And a fresh module starts with an empty cache (no persisted load).
	if New().decisionCache.Len() != 0 {
		t.Fatal("fresh cache must be empty — no persisted load path")
	}
}

func TestWARMUP_LARGE_300_SITE_STYLE_FILE_BOUNDED(t *testing.T) {
	// Simulate a busy multi-site host: many distinct IPs, large file.
	var lines []string
	for i := 0; i < 20000; i++ {
		ip := netip.AddrFrom4([4]byte{172, byte(i >> 16), byte(i >> 8), byte(i)})
		cls := []string{"static", "eshop_fanout", "admin_ajax", "dynamic_abuse", "scanner"}[i%5]
		lines = append(lines, sigLineTS(ip.String(), cls, "ban", recentTS()))
	}
	m, path := writeSignalFile(t, lines...)
	fi, _ := os.Stat(path)
	lim := warmupLimitsForTest()
	lim.maxBytes = 256 << 10
	lim.maxAccepted = 2000
	t0 := time.Now()
	st := m.warmupFromBatchSignals(context.Background(), lim)
	elapsed := time.Since(t0)

	if st.Accepted > lim.maxAccepted {
		t.Fatalf("accepted must be bounded by maxAccepted: %+v", st)
	}
	if m.decisionCache.Len() > lim.maxAccepted {
		t.Fatalf("cache size must be bounded: len=%d", m.decisionCache.Len())
	}
	if st.BytesRead >= fi.Size() {
		t.Fatalf("must read only a bounded tail, not the whole %d-byte file", fi.Size())
	}
	if !underRace && elapsed > 15*time.Second {
		t.Fatalf("bounded warm-up took too long: %v", elapsed)
	}
}
