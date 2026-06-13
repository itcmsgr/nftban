// =============================================================================
// NFTBan v1.180.0 - LoginMon FTP Discovery Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// meta:name="loginmon_ftpdiscovery_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-13"
// meta:description="Unit tests for LoginMon FTP log discovery — FTP daemon detection (pure-ftpd/vsftpd/proftpd), daemon->glob mapping (scoped to detected daemon only), exclusion of rotated/compressed files, and discoverFromGlobs over real temp FTP log files. Also asserts no globs are produced when no FTP daemon is detected (zero-input path)."
//
// meta:inventory.files="ftpdiscovery_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package loginmon

import (
	"os"
	"strings"
	"testing"
)

func TestFTPStackDetected(t *testing.T) {
	none := &Module{detectedServices: map[string]bool{}}
	if none.ftpStackDetected() {
		t.Errorf("no FTP daemon should be false")
	}
	for _, svc := range []string{"pure-ftpd", "vsftpd", "proftpd"} {
		m := &Module{detectedServices: map[string]bool{svc: true}}
		if !m.ftpStackDetected() {
			t.Errorf("%s should count as FTP daemon", svc)
		}
	}
	// a non-FTP service must not flip ftpStackDetected
	web := &Module{detectedServices: map[string]bool{"apache": true, "ssh": true}}
	if web.ftpStackDetected() {
		t.Errorf("non-FTP services must not be treated as an FTP daemon")
	}
}

func TestFTPLogGlobs_DaemonMapping(t *testing.T) {
	mk := func(svcs ...string) *Module {
		m := &Module{detectedServices: map[string]bool{}}
		for _, s := range svcs {
			m.detectedServices[s] = true
		}
		return m
	}
	has := func(g []string, sub string) bool {
		for _, x := range g {
			if strings.Contains(x, sub) {
				return true
			}
		}
		return false
	}

	pure := mk("pure-ftpd").ftpLogGlobs()
	if !has(pure, "/var/log/pureftpd.log") || !has(pure, "/var/log/pure-ftpd/") {
		t.Errorf("pure-ftpd missing expected globs: %v", pure)
	}
	vs := mk("vsftpd").ftpLogGlobs()
	if !has(vs, "/var/log/vsftpd.log") {
		t.Errorf("vsftpd missing expected glob: %v", vs)
	}
	pro := mk("proftpd").ftpLogGlobs()
	if !has(pro, "/var/log/proftpd/") {
		t.Errorf("proftpd missing expected glob: %v", pro)
	}

	// daemon isolation: pure-ftpd-only host must not pull vsftpd/proftpd globs
	if has(pure, "vsftpd") || has(pure, "proftpd") {
		t.Errorf("pure-ftpd-only host must not include other daemon globs: %v", pure)
	}

	// no FTP daemon → no globs at all (zero-input path)
	if g := mk().ftpLogGlobs(); len(g) != 0 {
		t.Errorf("no FTP daemon should yield no globs, got: %v", g)
	}
}

func TestDiscoverFTPLogs_TempFiles(t *testing.T) {
	dir := t.TempDir()
	mk := func(name, body string) string {
		p := dir + "/" + name
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	// keep: live FTP log files
	mk("pureftpd.log", "auth fail\n")
	mk("vsftpd.log", "FAIL LOGIN\n")
	// exclude: rotated + compressed
	mk("pureftpd.log.1", "rotated\n")
	mk("vsftpd.log.2.gz", "compressed\n")

	// Reuse the shared discoverFromGlobs core with injected temp globs.
	got := discoverFromGlobs([]string{dir + "/*.log", dir + "/*.gz"})
	want := map[string]bool{dir + "/pureftpd.log": true, dir + "/vsftpd.log": true}
	if len(got) != len(want) {
		t.Fatalf("got %d files %v, want %d %v", len(got), got, len(want), want)
	}
	for _, p := range got {
		if !want[p] {
			t.Errorf("unexpected/excluded file returned: %s", p)
		}
	}
}
