// =============================================================================
// NFTBan v1.179.0 - LoginMon Web Discovery Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
//
// meta:name="loginmon_webdiscovery_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-13"
// meta:description="Unit tests for LoginMon web access-log discovery — exclusion (error/compressed/rotated), panel->glob mapping, web-stack detection, and discoverFromGlobs over real temp files (regression lock for the canonical-path dedup bug)."
//
// meta:inventory.files="webdiscovery_test.go"
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

func TestIsExcludedWebLog(t *testing.T) {
	excluded := []string{
		"/var/log/httpd/domains/example.com.error_log",
		"/var/log/httpd/domains/example.gr.error.log",
		"/var/log/nginx/error.log",
		"/var/log/httpd/domains/example.com-error.log",
		"/var/log/apache2/access.log.gz",
		"/var/log/nginx/access.log.1",
		"/var/log/httpd/domains/example.com.log.14",
	}
	for _, p := range excluded {
		if !isExcludedWebLog(p) {
			t.Errorf("expected EXCLUDED: %s", p)
		}
	}
	kept := []string{
		"/var/log/httpd/domains/example.com.log",
		"/var/log/nginx/access.log",
		"/var/log/apache2/access.log",
		"/usr/local/apache/domlogs/example.com",
		"/var/www/vhosts/system/example.com/logs/access_log",
	}
	for _, p := range kept {
		if isExcludedWebLog(p) {
			t.Errorf("expected KEPT: %s", p)
		}
	}
}

func TestWebAccessLogGlobs_PanelMapping(t *testing.T) {
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
	// DirectAdmin → domains globs
	da := mk("directadmin").webAccessLogGlobs()
	if !has(da, "/var/log/httpd/domains/*.log") {
		t.Errorf("DA missing httpd domains glob: %v", da)
	}
	// cPanel → domlogs
	cp := mk("cpanel").webAccessLogGlobs()
	if !has(cp, "/usr/local/apache/domlogs/*") {
		t.Errorf("cPanel missing domlogs glob: %v", cp)
	}
	// Plesk → vhost access_log
	pl := mk("plesk").webAccessLogGlobs()
	if !has(pl, "/var/www/vhosts/system/*/logs/access_log") {
		t.Errorf("Plesk missing vhost glob: %v", pl)
	}
	// generic always present
	gen := mk().webAccessLogGlobs()
	if !has(gen, "/var/log/nginx/access.log") || !has(gen, "/var/log/apache2/access.log") {
		t.Errorf("generic globs missing: %v", gen)
	}
	// DA should NOT pull cPanel domlogs (panel isolation)
	if has(da, "/usr/local/apache/domlogs/*") {
		t.Errorf("DA must not include cPanel domlogs glob: %v", da)
	}
}

func TestWebStackDetected(t *testing.T) {
	none := &Module{detectedServices: map[string]bool{}}
	if none.webStackDetected() {
		t.Errorf("no stack should be false")
	}
	for _, svc := range []string{"apache", "nginx", "litespeed", "directadmin", "cpanel", "plesk"} {
		m := &Module{detectedServices: map[string]bool{svc: true}}
		if !m.webStackDetected() {
			t.Errorf("%s should count as web stack", svc)
		}
	}
}

func TestDiscoverFromGlobs(t *testing.T) {
	dir := t.TempDir()
	mk := func(name, body string) string {
		p := dir + "/" + name
		if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
		return p
	}
	mk("access.log", "GET /\n")        // keep
	mk("example.com.log", "GET /\n")   // keep
	mk("error.log", "err\n")           // exclude
	mk("example.com-error.log", "e\n") // exclude
	mk("access.log.1", "rot\n")        // exclude (rotated)
	mk("access.log.2.gz", "gz\n")      // exclude (compressed)
	got := discoverFromGlobs([]string{dir + "/*.log", dir + "/*.gz"})
	want := map[string]bool{dir + "/access.log": true, dir + "/example.com.log": true}
	if len(got) != len(want) {
		t.Fatalf("got %d files %v, want %d %v", len(got), got, len(want), want)
	}
	for _, p := range got {
		if !want[p] {
			t.Errorf("unexpected/excluded file returned: %s", p)
		}
	}
}
