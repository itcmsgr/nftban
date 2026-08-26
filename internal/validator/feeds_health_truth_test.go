// =============================================================================
// NFTBan v1.229.11 - Validator feeds sub-health truth tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// meta:name="validator_feeds_health_truth_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-08-25"
// meta:description="Tests for the feeds sub-health reader inside evaluateBlacklist. Feeds is NOT a standalone ModuleClassification module: it is a blacklist sub-health served by evaluateBlacklist. The reader must resolve enablement from the SAME authority the feeds surfaces use (conf.d/feeds.conf -> conf.d/feeds.conf.local -> nftban.conf.local, last wins, per-feed FEED_<NAME>_ENABLED) and must resolve materialized feed data under DataDir, not a hardcoded /var/lib/nftban. Positive control: an enabled feed with a fresh data file renders loaded. Negative control: no enabled feed renders disabled even when unrelated fresh files sit in the feeds data dir."
//
// meta:inventory.files="feeds_health_truth_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_DATA_DIR"
// meta:inventory.config_files="/etc/nftban/conf.d/feeds.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package validator

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// feedsConfWithTorExits mirrors the shipped install/config/feeds.conf shape:
// every feed ships DISABLED, enablement is an operator override written to
// the central nftban.conf.local (cli/lib/nftban/core/nftban_feeds.sh:195-215).
const feedsConfWithTorExits = `# feeds.conf
NFTBAN_FEEDS_ENABLED="false"
FEED_TOR_EXITS_URL="https://example.invalid/tor.txt"
FEED_TOR_EXITS_ENABLED="false"
FEED_TOR_EXITS_CATEGORY="protection"
FEED_SPAMHAUS_DROP_URL="https://example.invalid/drop.txt"
FEED_SPAMHAUS_DROP_ENABLED="false"
`

// writeFeedFile materializes <DataDir>/feeds/<name>.txt with the given mtime.
func writeFeedFile(t *testing.T, dataDir, name string, age time.Duration) {
	t.Helper()
	dir := filepath.Join(dataDir, "feeds")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(dir, name)
	if err := os.WriteFile(p, []byte("1.2.3.4\n5.6.7.8\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	mt := time.Now().Add(-age)
	if err := os.Chtimes(p, mt, mt); err != nil {
		t.Fatal(err)
	}
}

// stubManualSetReads pins the manual-blacklist kernel reader so these tests
// assert ONLY the feeds axis and never touch the host kernel.
func stubManualSetReads(t *testing.T) {
	t.Helper()
	old := countSetElementsStateFunc
	countSetElementsStateFunc = func(_, _ string) (int, bool, bool) { return 0, true, false }
	t.Cleanup(func() { countSetElementsStateFunc = old })
}

// TestBlacklistFeeds_EnabledAndPopulated_RendersLoaded is the POSITIVE control
// and the motivating live defect (srv2, v1.229.9): `nftban feeds list` reported
// 1/14 feeds enabled with a populated TOR_EXITS feed while `nftban health`
// reported the feeds sub-health as "disabled".
func TestBlacklistFeeds_EnabledAndPopulated_RendersLoaded(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/feeds.conf":       feedsConfWithTorExits,
		"nftban.conf.local":       "# --- FEEDS Configuration ---\nFEED_TOR_EXITS_ENABLED=\"true\"\n",
		"conf.d/geoban/main.conf": `GEOBAN_ENABLED="false"`,
	})
	defer cleanup()
	stubManualSetReads(t)

	tmp := t.TempDir()
	defer withDataDir(t, tmp)()
	writeFeedFile(t, tmp, "tor_exits.txt", time.Hour)

	moduleFindings = nil
	bh := evaluateBlacklist(buildDoc(nil, nil))
	if bh.Feeds.State != "loaded" {
		t.Errorf("feeds state=%q want loaded (one feed enabled via nftban.conf.local with fresh data)", bh.Feeds.State)
	}
}

// TestBlacklistFeeds_NoFeedEnabled_RendersDisabled is the NEGATIVE control.
// The shipped feeds.conf ALWAYS exists and always defines feeds, so config
// PRESENCE must never be read as enablement — and an orphan/disabled feed file
// left in the data dir must not lift the state off "disabled".
func TestBlacklistFeeds_NoFeedEnabled_RendersDisabled(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/feeds.conf":       feedsConfWithTorExits,
		"conf.d/geoban/main.conf": `GEOBAN_ENABLED="false"`,
	})
	defer cleanup()
	stubManualSetReads(t)

	tmp := t.TempDir()
	defer withDataDir(t, tmp)()
	// Orphan data from a feed that is no longer enabled.
	writeFeedFile(t, tmp, "tor_exits.txt", time.Hour)

	moduleFindings = nil
	bh := evaluateBlacklist(buildDoc(nil, nil))
	if bh.Feeds.State != "disabled" {
		t.Errorf("feeds state=%q want disabled (no FEED_*_ENABLED=true)", bh.Feeds.State)
	}
}

// TestBlacklistFeeds_NoConfigAtAll_RendersDisabled: a host with no feeds config
// (uninstalled/partial tree) must still read disabled, never a false loaded.
func TestBlacklistFeeds_NoConfigAtAll_RendersDisabled(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/geoban/main.conf": `GEOBAN_ENABLED="false"`,
	})
	defer cleanup()
	stubManualSetReads(t)

	tmp := t.TempDir()
	defer withDataDir(t, tmp)()

	moduleFindings = nil
	bh := evaluateBlacklist(buildDoc(nil, nil))
	if bh.Feeds.State != "disabled" {
		t.Errorf("feeds state=%q want disabled (no feeds config present)", bh.Feeds.State)
	}
}

// TestBlacklistFeeds_EnabledNoData_RendersStale: enabled but never downloaded
// is a sync failure, not a disabled module.
func TestBlacklistFeeds_EnabledNoData_RendersStale(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/feeds.conf":       feedsConfWithTorExits,
		"conf.d/feeds.conf.local": "FEED_TOR_EXITS_ENABLED=\"true\"\n",
		"conf.d/geoban/main.conf": `GEOBAN_ENABLED="false"`,
	})
	defer cleanup()
	stubManualSetReads(t)

	tmp := t.TempDir()
	defer withDataDir(t, tmp)()

	moduleFindings = nil
	bh := evaluateBlacklist(buildDoc(nil, nil))
	if bh.Feeds.State != "stale" {
		t.Errorf("feeds state=%q want stale (enabled, no data materialized)", bh.Feeds.State)
	}
}

// TestBlacklistFeeds_EnabledStaleData_RendersStale: data older than the 7-day
// freshness window is a stale sync.
func TestBlacklistFeeds_EnabledStaleData_RendersStale(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/feeds.conf":       feedsConfWithTorExits,
		"nftban.conf.local":       "FEED_TOR_EXITS_ENABLED=\"true\"\n",
		"conf.d/geoban/main.conf": `GEOBAN_ENABLED="false"`,
	})
	defer cleanup()
	stubManualSetReads(t)

	tmp := t.TempDir()
	defer withDataDir(t, tmp)()
	writeFeedFile(t, tmp, "tor_exits.txt", 30*24*time.Hour)

	moduleFindings = nil
	bh := evaluateBlacklist(buildDoc(nil, nil))
	if bh.Feeds.State != "stale" {
		t.Errorf("feeds state=%q want stale (data older than the freshness window)", bh.Feeds.State)
	}
}

// TestBlacklistFeeds_LocalOverrideCanDisable: precedence is last-wins, so a
// central nftban.conf.local "false" must be able to turn a feed back off.
func TestBlacklistFeeds_LocalOverrideCanDisable(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/feeds.conf":       "FEED_TOR_EXITS_URL=\"x\"\nFEED_TOR_EXITS_ENABLED=\"true\"\n",
		"nftban.conf.local":       "FEED_TOR_EXITS_ENABLED=\"false\"\n",
		"conf.d/geoban/main.conf": `GEOBAN_ENABLED="false"`,
	})
	defer cleanup()
	stubManualSetReads(t)

	tmp := t.TempDir()
	defer withDataDir(t, tmp)()
	writeFeedFile(t, tmp, "tor_exits.txt", time.Hour)

	moduleFindings = nil
	bh := evaluateBlacklist(buildDoc(nil, nil))
	if bh.Feeds.State != "disabled" {
		t.Errorf("feeds state=%q want disabled (central .local override wins, last-wins precedence)", bh.Feeds.State)
	}
}
