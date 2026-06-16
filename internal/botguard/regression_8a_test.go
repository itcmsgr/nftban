// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: 8A consolidated regression + cadence visibility
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Increment 8A Group A — one consolidated suite proving every 8B increment behavior
//          remains intact (browser-like suppression, abuse enforcement, cadence-gap gate,
//          explain_ip read-only, bounded warm-up, config-knob defaults), plus the cadence-lag
//          visibility advisory (fresh/stale/unknown, text-only) and the two config-knob tests
//          that complete the config-knobs gate (warm-up line-size override; defaults-preserve).
//
// meta:name="botguard_regression_8a_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Consolidated 8B regression + cadence-lag visibility tests (increment 8A)"
// meta:inventory.files="regression_8a_test.go"
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
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/botguard/decisioncache"
)

// ---- A. consolidated correctness regression --------------------------------

func TestREGRESSION_BROWSER_STATIC_NO_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	m.applyBatchSignal(mkSig("203.0.113.150", "static", "ban"))
	assertNotBanned(t, b, "http_bot_ban", "203.0.113.150")
}
func TestREGRESSION_STATIC404_NO_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	m.applyBatchSignal(mkSig("203.0.113.151", "static404", "ban"))
	assertNotBanned(t, b, "http_bot_ban", "203.0.113.151")
}
func TestREGRESSION_ESHOP_FANOUT_NO_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	m.applyBatchSignal(mkSig("203.0.113.152", "eshop_fanout", "ban"))
	assertNotBanned(t, b, "http_bot_ban", "203.0.113.152")
}
func TestREGRESSION_ADMIN_AJAX_NO_BAN(t *testing.T) {
	m, b := newEnforcingModule(t)
	m.applyBatchSignal(mkSig("203.0.113.153", "admin_ajax", "ban"))
	assertNotBanned(t, b, "http_bot_ban", "203.0.113.153")
}
func TestREGRESSION_DYNAMIC_ABUSE_BANS(t *testing.T) {
	m, b := newEnforcingModule(t)
	m.applyBatchSignal(mkSig("198.51.100.150", "dynamic_abuse", "ban"))
	if !waitBanned(b, "http_bot_ban", "198.51.100.150") {
		t.Fatalf("dynamic_abuse must ban; sets=%v", b.adds)
	}
}
func TestREGRESSION_LOGIN_API_BANS(t *testing.T) {
	m, b := newEnforcingModule(t)
	m.applyBatchSignal(mkSig("198.51.100.151", "login_api", "ban"))
	if !waitBanned(b, "http_bot_ban", "198.51.100.151") {
		t.Fatalf("login_api must ban; sets=%v", b.adds)
	}
}
func TestREGRESSION_SCANNER_BANS(t *testing.T) {
	m, b := newEnforcingModule(t)
	m.applyBatchSignal(mkSig("198.51.100.152", "scanner", "ban"))
	if !waitBanned(b, "http_bot_ban", "198.51.100.152") {
		t.Fatalf("scanner must ban; sets=%v", b.adds)
	}
}
func TestREGRESSION_MIXED_NO_RATE_ONLY_BAN(t *testing.T) {
	// Request-blind meter suspect with no dynamic class evidence must NOT be rate-banned.
	m, b := newClassifyingModule(t)
	classifyAtHit(m, "203.0.113.154", 10)
	assertNotInSets(t, b, "203.0.113.154", "http_bot_ban", "http_bot_grey")
}
func TestREGRESSION_OLD_BATCH_SIGNAL_COMPAT(t *testing.T) {
	m, b := newEnforcingModule(t)
	// Class-less (pre-v1.191) ban signal → mixed → not browser-suppressed → legacy bans.
	m.applyBatchSignal(mkSig("198.51.100.153", "", "ban"))
	if !waitBanned(b, "http_bot_ban", "198.51.100.153") {
		t.Fatalf("old class-less ban must preserve legacy behavior; sets=%v", b.adds)
	}
	if r, ok := m.decisionCache.Peek(netip.MustParseAddr("198.51.100.153")); !ok || r.RequestClass != "mixed" {
		t.Fatalf("old signal must normalize to mixed in cache: %+v", r)
	}
}
func TestREGRESSION_EXPLAIN_IP_READ_ONLY(t *testing.T) {
	m := New()
	ip := netip.MustParseAddr("198.51.100.154")
	_ = m.decisionCache.Put(decisioncache.Record{IP: ip, State: decisioncache.StateBlockedTemporarily, RequestClass: "scanner"}, time.Hour)
	before := m.decisionCache.Len()
	_ = m.ExplainIP(context.Background(), ip)
	_ = m.ExplainIP(context.Background(), netip.MustParseAddr("198.51.100.199"))
	if m.decisionCache.Len() != before {
		t.Fatalf("explain_ip must be read-only; len %d -> %d", before, m.decisionCache.Len())
	}
}
func TestREGRESSION_WARMUP_BOUNDED(t *testing.T) {
	var lines []string
	for i := 0; i < 2000; i++ {
		lines = append(lines, sigLineTS(fmt.Sprintf("10.8.%d.%d", i/256, i%256), "scanner", "ban", recentTS()))
	}
	m, _ := writeSignalFile(t, lines...)
	lim := warmupLimitsForTest()
	lim.maxBytes = 32 << 10
	lim.maxAccepted = 100
	st := m.warmupFromBatchSignals(context.Background(), lim)
	if st.Accepted > 100 || !st.TruncatedTail {
		t.Fatalf("warm-up must stay bounded: %+v", st)
	}
}
func TestREGRESSION_CONFIG_KNOBS_DEFAULTS_PRESERVE_BEHAVIOR(t *testing.T) {
	cfg := DefaultConfig()
	dc := decisioncache.DefaultConfig()
	if cfg.CacheMaxEntries != dc.MaxEntries || cfg.CacheMaxCandidates != dc.MaxCandidates || cfg.CacheV6PrefixBits != dc.V6PrefixBits {
		t.Fatal("cache defaults drifted from decisioncache.DefaultConfig()")
	}
	d := defaultWarmupLimits()
	if cfg.WarmupMaxBytes != d.maxBytes || cfg.WarmupMaxLines != d.maxLines || cfg.WarmupMaxAccepted != d.maxAccepted {
		t.Fatal("warm-up defaults drifted from defaultWarmupLimits()")
	}
}

// ---- config-knobs completion (cadence + remaining cases) -------------------

func TestCONFIG_OVERRIDES_WARMUP_MAX_LINE_SIZE(t *testing.T) {
	if c := loadConfWith(t, `HTTP_BOT_WARMUP_MAX_LINE_SIZE="4096"`); c.WarmupMaxLineSize != 4096 {
		t.Fatalf("got %d", c.WarmupMaxLineSize)
	}
}

func TestDEFAULT_CONFIG_DOES_NOT_CHANGE_EXISTING_BEHAVIOR(t *testing.T) {
	cfg := DefaultConfig()
	dcc := decisionCacheConfigFrom(cfg)
	dc := decisioncache.DefaultConfig()
	if dcc.MaxEntries != dc.MaxEntries || dcc.MaxCandidates != dc.MaxCandidates || dcc.V6PrefixBits != dc.V6PrefixBits {
		t.Fatalf("default-derived cache config diverges: %+v vs %+v", dcc, dc)
	}
	lim := warmupLimitsFrom(cfg)
	d := defaultWarmupLimits()
	if lim.maxBytes != d.maxBytes || lim.maxLines != d.maxLines || lim.maxAccepted != d.maxAccepted ||
		lim.maxAge != d.maxAge || lim.budget != d.budget || lim.maxLineSize != d.maxLineSize {
		t.Fatalf("default-derived warm-up limits diverge: %+v vs %+v", lim, d)
	}
}

// ---- cadence-lag visibility (fresh / stale / unknown; text-only) -----------

func cadenceModuleWithFile(t *testing.T, mtime time.Time) *Module {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "batch_signals.jsonl")
	if err := os.WriteFile(path, []byte("{}\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatal(err)
	}
	m := New()
	m.config.BatchSignalFile = path
	return m
}

func TestCADENCE_LAG_VISIBILITY_FRESH(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	m := cadenceModuleWithFile(t, now.Add(-1*time.Minute)) // touched 1 min ago
	cs := m.botScanCadenceStatus(now)
	if cs.State != CadenceFresh {
		t.Fatalf("recent batch-signal mtime must be fresh, got %s (age=%ds)", cs.State, cs.AgeSeconds)
	}
}
func TestCADENCE_LAG_VISIBILITY_STALE(t *testing.T) {
	now := time.Unix(1_700_000_000, 0)
	m := cadenceModuleWithFile(t, now.Add(-3*time.Hour)) // 3h > 90m default window
	cs := m.botScanCadenceStatus(now)
	if cs.State != CadenceStale {
		t.Fatalf("old batch-signal mtime must be stale (lag suspected), got %s (age=%ds)", cs.State, cs.AgeSeconds)
	}
}
func TestCADENCE_LAG_VISIBILITY_UNKNOWN_DEGRADES_TEXT_ONLY(t *testing.T) {
	m := New()
	m.config.BatchSignalFile = filepath.Join(t.TempDir(), "nope.jsonl") // missing
	cs := m.botScanCadenceStatus(time.Unix(1_700_000_000, 0))
	if cs.State != CadenceUnknown || cs.AgeSeconds != -1 {
		t.Fatalf("missing file must degrade to unknown (text-only), got %s age=%d", cs.State, cs.AgeSeconds)
	}
	if cs.Note == "" {
		t.Fatal("unknown must carry an advisory note (text-only)")
	}
	// Text-only: the status is a plain struct, not a schema/metric/install_state input.
	// (No assertion on install_state — by construction it is never fed there.)
}
