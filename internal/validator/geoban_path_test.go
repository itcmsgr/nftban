// =============================================================================
// NFTBan v1.197.0 - Validator geoban GeoIP DB path resolution tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// meta:name="validator_geoban_path_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-21"
// meta:description="Tests for the v1.197 PR-A rider: the geoban health check must resolve the GeoIP database at ${NFTBAN_DATA_DIR}/geoip/dbip-country-lite.mmdb (DataDir) instead of a hardcoded /var/lib/nftban path, matching the shell geoip sync writer. Proves a DB under a configured DataDir reads loaded (no missing finding), an absent DB under that DataDir reads stale + emits CodeGeobanDBMissing, and resolveDataDir falls back deterministically to the canonical default."
//
// meta:inventory.files="geoban_path_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="NFTBAN_DATA_DIR"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package validator

import (
	"os"
	"path/filepath"
	"testing"
)

// withDataDir overrides the package DataDir for a test and restores it after.
func withDataDir(t *testing.T, dir string) func() {
	t.Helper()
	old := DataDir
	DataDir = dir
	return func() { DataDir = old }
}

func geobanFindingPresent() bool {
	for _, f := range moduleFindings {
		if f.Code == CodeGeobanDBMissing {
			return true
		}
	}
	return false
}

// TestGeobanDBPath_HonorsDataDir: a GeoIP DB placed under a configured DataDir
// (not /var/lib/nftban) must be found → geoban reads loaded, no missing finding.
func TestGeobanDBPath_HonorsDataDir(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/geoban/main.conf": `GEOBAN_ENABLED="true"`,
	})
	defer cleanup()

	tmp := t.TempDir()
	restore := withDataDir(t, tmp)
	defer restore()

	dbPath := filepath.Join(tmp, "geoip", "dbip-country-lite.mmdb")
	if err := os.MkdirAll(filepath.Dir(dbPath), 0755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(dbPath, []byte("mmdb-bytes"), 0644); err != nil {
		t.Fatal(err)
	}

	moduleFindings = nil
	bh := evaluateBlacklist(buildDoc(nil, nil))
	if bh.Geoban.State != "loaded" {
		t.Errorf("geoban state=%q want loaded (DB under configured DataDir must be found)", bh.Geoban.State)
	}
	if geobanFindingPresent() {
		t.Error("did not expect CodeGeobanDBMissing when the DB exists under DataDir")
	}
}

// TestGeobanDBPath_FallbackMissing: with the DB absent under DataDir, geoban reads
// stale and emits CodeGeobanDBMissing — deterministic, path-driven fallback.
func TestGeobanDBPath_FallbackMissing(t *testing.T) {
	cleanup := setupTestConfig(t, map[string]string{
		"conf.d/geoban/main.conf": `GEOBAN_ENABLED="true"`,
	})
	defer cleanup()

	restore := withDataDir(t, t.TempDir()) // empty: no geoip/ dir
	defer restore()

	moduleFindings = nil
	bh := evaluateBlacklist(buildDoc(nil, nil))
	if bh.Geoban.State != "stale" {
		t.Errorf("geoban state=%q want stale (DB missing under DataDir)", bh.Geoban.State)
	}
	if !geobanFindingPresent() {
		t.Error("expected CodeGeobanDBMissing when the DB is absent under DataDir")
	}
}

// TestResolveDataDir_Fallback: resolveDataDir honors NFTBAN_DATA_DIR when set and
// falls back to the canonical default otherwise.
func TestResolveDataDir_Fallback(t *testing.T) {
	t.Setenv("NFTBAN_DATA_DIR", "/srv/custom/nftban-data")
	if got := resolveDataDir(); got != "/srv/custom/nftban-data" {
		t.Errorf("resolveDataDir()=%q want the configured NFTBAN_DATA_DIR", got)
	}
	t.Setenv("NFTBAN_DATA_DIR", "")
	if got := resolveDataDir(); got != "/var/lib/nftban" {
		t.Errorf("resolveDataDir()=%q want the canonical default /var/lib/nftban", got)
	}
}
