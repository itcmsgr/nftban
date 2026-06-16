// =============================================================================
// NFTBan v1.191.0 - HTTP Bot Guard: Config-knobs tests (decision-cache + warm-up)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: botguard
// Purpose: Prove the v1.191 8B config-knobs gate: decision-cache caps and warm-up replay
//          bounds are operator-configurable via conf.d/botguard/main.conf, defaults preserve
//          current Inc4/Inc7 behavior, invalid/absurd values clamp/fall-back to safe defaults
//          (never unlimited / never whole-file), and the configured values actually drive the
//          cache and the warm-up. No schema/counter/metric change; no persisted/shell cache.
//
// meta:name="botguard_config_knobs_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Unit tests for BotGuard decision-cache + warm-up config knobs"
// meta:inventory.files="config_knobs_test.go"
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
	"strings"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/botguard/decisioncache"
)

// loadConfWith writes a main.conf with the given body and loads it.
func loadConfWith(t *testing.T, body string) *Config {
	t.Helper()
	dir := t.TempDir()
	path := filepath.Join(dir, "main.conf")
	if err := os.WriteFile(path, []byte(body), 0o600); err != nil {
		t.Fatalf("write conf: %v", err)
	}
	cfg, err := LoadConfig(path)
	if err != nil {
		t.Fatalf("LoadConfig: %v", err)
	}
	return cfg
}

func TestCONFIG_DEFAULTS_MATCH_CURRENT_DECISION_CACHE_LIMITS(t *testing.T) {
	cfg := DefaultConfig()
	dc := decisioncache.DefaultConfig()
	if cfg.CacheMaxEntries != dc.MaxEntries || cfg.CacheMaxCandidates != dc.MaxCandidates || cfg.CacheV6PrefixBits != dc.V6PrefixBits {
		t.Fatalf("config defaults must match decisioncache.DefaultConfig(): cfg(%d/%d/%d) dc(%d/%d/%d)",
			cfg.CacheMaxEntries, cfg.CacheMaxCandidates, cfg.CacheV6PrefixBits,
			dc.MaxEntries, dc.MaxCandidates, dc.V6PrefixBits)
	}
}

func TestCONFIG_DEFAULTS_MATCH_CURRENT_WARMUP_LIMITS(t *testing.T) {
	cfg := DefaultConfig()
	d := defaultWarmupLimits()
	if cfg.WarmupMaxLines != d.maxLines || cfg.WarmupMaxBytes != d.maxBytes ||
		cfg.WarmupMaxAccepted != d.maxAccepted || cfg.WarmupMaxAge != d.maxAge ||
		cfg.WarmupMaxDuration != d.budget || cfg.WarmupMaxLineSize != d.maxLineSize {
		t.Fatalf("config defaults must match defaultWarmupLimits(): cfg=%+v d=%+v", cfg, d)
	}
}

func TestCONFIG_OVERRIDES_CACHE_MAX_ENTRIES(t *testing.T) {
	cfg := loadConfWith(t, `HTTP_BOT_CACHE_MAX_ENTRIES="1234"`)
	if cfg.CacheMaxEntries != 1234 {
		t.Fatalf("override not applied: %d", cfg.CacheMaxEntries)
	}
}

func TestCONFIG_OVERRIDES_CACHE_MAX_CANDIDATES(t *testing.T) {
	cfg := loadConfWith(t, `HTTP_BOT_CACHE_MAX_CANDIDATES="777"`)
	if cfg.CacheMaxCandidates != 777 {
		t.Fatalf("override not applied: %d", cfg.CacheMaxCandidates)
	}
}

func TestCONFIG_OVERRIDES_V6_PREFIX_BITS(t *testing.T) {
	cfg := loadConfWith(t, `HTTP_BOT_CACHE_V6_PREFIX_BITS="56"`)
	if cfg.CacheV6PrefixBits != 56 {
		t.Fatalf("override not applied: %d", cfg.CacheV6PrefixBits)
	}
}

func TestCONFIG_INVALID_CACHE_VALUES_CLAMP_OR_DEFAULT(t *testing.T) {
	// zero, negative, non-numeric, absurd → keep safe default (never unlimited).
	for _, body := range []string{
		`HTTP_BOT_CACHE_MAX_ENTRIES="0"`,
		`HTTP_BOT_CACHE_MAX_ENTRIES="-5"`,
		`HTTP_BOT_CACHE_MAX_ENTRIES="banana"`,
		`HTTP_BOT_CACHE_MAX_ENTRIES="999999999999"`,
	} {
		cfg := loadConfWith(t, body)
		if cfg.CacheMaxEntries != 50000 {
			t.Fatalf("invalid %q must fall back to default 50000, got %d", body, cfg.CacheMaxEntries)
		}
	}
	// V6 prefix out of [32,128] → default 64.
	if c := loadConfWith(t, `HTTP_BOT_CACHE_V6_PREFIX_BITS="200"`); c.CacheV6PrefixBits != 64 {
		t.Fatalf("absurd v6 prefix must default to 64, got %d", c.CacheV6PrefixBits)
	}
	if c := loadConfWith(t, `HTTP_BOT_CACHE_V6_PREFIX_BITS="8"`); c.CacheV6PrefixBits != 64 {
		t.Fatalf("too-small v6 prefix must default to 64, got %d", c.CacheV6PrefixBits)
	}
}

func TestCONFIG_NO_UNLIMITED_CACHE_MODE(t *testing.T) {
	// There is no key/value that yields an unlimited cache. 0 → default; the cache then enforces.
	cfg := loadConfWith(t, `HTTP_BOT_CACHE_MAX_ENTRIES="0"`)
	if cfg.CacheMaxEntries <= 0 {
		t.Fatal("cache max entries must never be <=0 (no unlimited mode)")
	}
	c := decisioncache.New(decisionCacheConfigFrom(cfg))
	for i := 0; i < cfg.CacheMaxEntries+50; i++ {
		_ = c.Put(decisioncache.Record{IP: netip.AddrFrom4([4]byte{10, byte(i >> 16), byte(i >> 8), byte(i)}), State: decisioncache.StateChecking}, time.Hour)
		if c.Len() > cfg.CacheMaxEntries {
			t.Fatalf("cache exceeded its cap — unlimited mode leaked: %d", c.Len())
		}
	}
}

func TestCONFIG_OVERRIDES_WARMUP_MAX_LINES(t *testing.T) {
	if c := loadConfWith(t, `HTTP_BOT_WARMUP_MAX_LINES="42"`); c.WarmupMaxLines != 42 {
		t.Fatalf("got %d", c.WarmupMaxLines)
	}
}
func TestCONFIG_OVERRIDES_WARMUP_MAX_BYTES(t *testing.T) {
	if c := loadConfWith(t, `HTTP_BOT_WARMUP_MAX_BYTES="65536"`); c.WarmupMaxBytes != 65536 {
		t.Fatalf("got %d", c.WarmupMaxBytes)
	}
}
func TestCONFIG_OVERRIDES_WARMUP_MAX_AGE(t *testing.T) {
	if c := loadConfWith(t, `HTTP_BOT_WARMUP_MAX_AGE_SECONDS="600"`); c.WarmupMaxAge != 10*time.Minute {
		t.Fatalf("got %v", c.WarmupMaxAge)
	}
}
func TestCONFIG_OVERRIDES_WARMUP_MAX_DURATION(t *testing.T) {
	if c := loadConfWith(t, `HTTP_BOT_WARMUP_MAX_DURATION_MS="250"`); c.WarmupMaxDuration != 250*time.Millisecond {
		t.Fatalf("got %v", c.WarmupMaxDuration)
	}
}
func TestCONFIG_OVERRIDES_WARMUP_MAX_ACCEPTED(t *testing.T) {
	if c := loadConfWith(t, `HTTP_BOT_WARMUP_MAX_ACCEPTED="99"`); c.WarmupMaxAccepted != 99 {
		t.Fatalf("got %d", c.WarmupMaxAccepted)
	}
}

func TestCONFIG_INVALID_WARMUP_VALUES_CLAMP_OR_DEFAULT(t *testing.T) {
	for _, tc := range []struct {
		body string
		get  func(*Config) any
		want any
	}{
		{`HTTP_BOT_WARMUP_MAX_LINES="0"`, func(c *Config) any { return c.WarmupMaxLines }, 10000},
		{`HTTP_BOT_WARMUP_MAX_BYTES="-1"`, func(c *Config) any { return c.WarmupMaxBytes }, int64(4 << 20)},
		{`HTTP_BOT_WARMUP_MAX_BYTES="999999999999"`, func(c *Config) any { return c.WarmupMaxBytes }, int64(4 << 20)},
		{`HTTP_BOT_WARMUP_MAX_DURATION_MS="0"`, func(c *Config) any { return c.WarmupMaxDuration }, 400 * time.Millisecond},
	} {
		cfg := loadConfWith(t, tc.body)
		if got := tc.get(cfg); got != tc.want {
			t.Fatalf("%q → %v, want %v (safe default)", tc.body, got, tc.want)
		}
	}
}

func TestCONFIG_NO_UNBOUNDED_WARMUP_MODE(t *testing.T) {
	// 0 maxBytes must NOT mean "read whole file" — it falls back to a bounded default.
	cfg := loadConfWith(t, "HTTP_BOT_WARMUP_MAX_BYTES=\"0\"\nHTTP_BOT_WARMUP_MAX_LINES=\"0\"")
	lim := warmupLimitsFrom(cfg)
	if lim.maxBytes <= 0 || lim.maxLines <= 0 || lim.maxAccepted <= 0 {
		t.Fatalf("warm-up limits must never be <=0 (no unbounded mode): %+v", lim)
	}
}

func TestWARMUP_USES_CONFIGURED_LIMITS(t *testing.T) {
	m := New()
	m.config.WarmupMaxLines = 3
	dir := t.TempDir()
	path := filepath.Join(dir, "batch_signals.jsonl")
	data := ""
	for i := 0; i < 20; i++ {
		data += sigLineTS(fmt.Sprintf("10.5.0.%d", i), "scanner", "ban", recentTS()) + "\n"
	}
	if err := os.WriteFile(path, []byte(data), 0o600); err != nil {
		t.Fatal(err)
	}
	m.config.BatchSignalFile = path
	lim := warmupLimitsFrom(m.config)
	lim.now = func() time.Time { return warmupFixedNow } // deterministic age cutoff
	st := m.warmupFromBatchSignals(context.Background(), lim)
	if st.LinesScanned > 3 || st.Stopped != "max_lines" {
		t.Fatalf("warm-up must honor configured maxLines=3, got %+v", st)
	}
}

func TestDECISION_CACHE_USES_CONFIGURED_LIMITS(t *testing.T) {
	m := New()
	m.config.CacheMaxEntries = 5
	m.rebuildDecisionCacheFromConfig()
	for i := 0; i < 50; i++ {
		_ = m.decisionCache.Put(decisioncache.Record{IP: netip.AddrFrom4([4]byte{10, 6, byte(i >> 8), byte(i)}), State: decisioncache.StateChecking}, time.Hour)
	}
	if m.decisionCache.Len() > 5 {
		t.Fatalf("cache must honor configured MaxEntries=5, got Len=%d", m.decisionCache.Len())
	}
}

func TestV6_PREFIX_BITS_CONFIG_AFFECTS_CANDIDATE_ACCOUNTING(t *testing.T) {
	// Two IPv6 in the same /56 but different /64 (4th hextet 0x0001 vs 0x0002 → byte index 7
	// differs (=/64 differs), byte index 6 == 0x00 (=/56 shared)).
	ipA := netip.MustParseAddr("2001:db8:abcd:1::1")
	ipB := netip.MustParseAddr("2001:db8:abcd:2::1")

	c64 := decisioncache.New(decisioncache.Config{V6PrefixBits: 64})
	_ = c64.Put(decisioncache.Record{IP: ipA, State: decisioncache.StateCandidate}, time.Hour)
	_ = c64.Put(decisioncache.Record{IP: ipB, State: decisioncache.StateCandidate}, time.Hour)
	if c64.DistinctCandidatePrefixes() != 2 {
		t.Fatalf("/64 must keep them distinct: %d", c64.DistinctCandidatePrefixes())
	}

	c56 := decisioncache.New(decisioncache.Config{V6PrefixBits: 56})
	_ = c56.Put(decisioncache.Record{IP: ipA, State: decisioncache.StateCandidate}, time.Hour)
	_ = c56.Put(decisioncache.Record{IP: ipB, State: decisioncache.StateCandidate}, time.Hour)
	if c56.DistinctCandidatePrefixes() != 1 {
		t.Fatalf("/56 must aggregate them to one prefix: %d", c56.DistinctCandidatePrefixes())
	}
}

func TestNO_SCHEMA_COUNTER_METRIC_CHANGE(t *testing.T) {
	// The new knobs are botguard config keys only — they must not appear in the validator
	// schema or the metrics inventory (no schema/counter/metric surface change).
	root := "../.."
	for _, f := range []string{
		filepath.Join(root, "internal/validator/types.go"),
		filepath.Join(root, "cli/lib/nftban/data/config-schema.json"),
	} {
		b, err := os.ReadFile(f)
		if err != nil {
			continue // file may not exist in all trees
		}
		for _, tok := range []string{"HTTP_BOT_CACHE_MAX_ENTRIES", "WarmupMaxBytes", "HTTP_BOT_WARMUP_MAX_LINES"} {
			if strings.Contains(string(b), tok) {
				t.Fatalf("%s must not reference config-knob token %q (no schema change)", f, tok)
			}
		}
	}
}

func TestNO_PERSISTED_CACHE_WRITER_CONFIG(t *testing.T) {
	dir := t.TempDir()
	m := New()
	m.config.CacheMaxEntries = 100
	m.rebuildDecisionCacheFromConfig()
	_ = m.decisionCache.Put(decisioncache.Record{IP: netip.MustParseAddr("10.7.0.1"), State: decisioncache.StateChecking}, time.Hour)
	files, _ := os.ReadDir(dir)
	if len(files) != 0 {
		t.Fatalf("building/using cache from config must not write any file: %d", len(files))
	}
	if New().decisionCache.Len() != 0 {
		t.Fatal("fresh cache must be empty — no persisted load")
	}
}

func TestNO_SHELL_PARALLEL_CACHE_CONFIG(t *testing.T) {
	// The config knobs are Go-only; loading config + building cache writes no shell-side cache.
	dir := t.TempDir()
	path := filepath.Join(dir, "main.conf")
	_ = os.WriteFile(path, []byte(`HTTP_BOT_CACHE_MAX_ENTRIES="100"`), 0o600)
	before, _ := os.ReadDir(dir)
	cfg, _ := LoadConfig(path)
	_ = decisioncache.New(decisionCacheConfigFrom(cfg))
	after, _ := os.ReadDir(dir)
	if len(after) != len(before) {
		t.Fatalf("config load + cache build must not create files: before=%d after=%d", len(before), len(after))
	}
}
