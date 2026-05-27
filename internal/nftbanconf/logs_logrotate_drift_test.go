// =============================================================================
// NFTBan - Log inventory <-> logrotate template drift test (v1.137, B-12)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="logs_logrotate_drift_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-27"
// meta:description="v1.137 B-12 bridge: asserts logs.go LogInventory() is covered by the packaged logrotate templates with matching frequency/retain; fails on drift, legacy names, or missing v1.137 additions."
// meta:input="install/config/nftban.logrotate, install/config/nftban-suricata.logrotate"
// meta:output="None"
// meta:depends="testing,os,path/filepath,strings,fmt"
// meta:inventory.files="install/config/nftban.logrotate,install/config/nftban-suricata.logrotate,internal/nftbanconf/logs.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// This is the mandatory BRIDGE for the "inventory authority + drift-test"
// design (B-12). LogInventory() in logs.go is the canonical inventory authority;
// the packaged logrotate templates (install/config/nftban.logrotate +
// install/config/nftban-suricata.logrotate) are the execution policy. This test
// proves they cannot silently diverge:
//
//   - every LogInventory() entry is COVERED by a stanza in its template;
//   - the stanza's frequency (daily/weekly/monthly) matches entry.Rotation;
//   - the stanza's "rotate N" matches entry.Retain;
//   - the inventory carries the CURRENT real filenames, not the pre-split /
//     pre-rename legacy names (ddos.log, portscan.log, cli_errors.log);
//   - the v1.137 additions (installer.log, update.log, suricata eve) are present.
//
// It does not generate the templates from the inventory (the generator direction
// is rejected: the inventory cannot express copytruncate/size/su/olddir/create).
// =============================================================================

package nftbanconf

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

type stanzaPolicy struct {
	freq   string // daily | weekly | monthly | ""
	retain int    // rotate N, -1 if unset
}

// repoRoot resolves the repository root from the package dir (internal/nftbanconf).
func repoRoot(t *testing.T) string {
	t.Helper()
	wd, err := os.Getwd()
	if err != nil {
		t.Fatalf("getwd: %v", err)
	}
	return filepath.Clean(filepath.Join(wd, "..", ".."))
}

// parseLogrotate parses a logrotate config into a map of log path (relative to
// /var/log/nftban/) -> policy. It handles multi-path stanzas (paths on separate
// lines, the last sharing the line with "{") and ignores comments, non-nftban
// log paths, and directives other than frequency/rotate.
func parseLogrotate(t *testing.T, path string) map[string]stanzaPolicy {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read %s: %v", path, err)
	}
	const prefix = "/var/log/nftban/"
	cov := map[string]stanzaPolicy{}
	lines := strings.Split(string(data), "\n")
	var pending []string
	for i := 0; i < len(lines); i++ {
		line := strings.TrimSpace(lines[i])
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.Contains(line, "{") {
			before := strings.TrimSpace(strings.SplitN(line, "{", 2)[0])
			if before != "" {
				pending = append(pending, strings.Fields(before)...)
			}
			pol := stanzaPolicy{retain: -1}
			for i++; i < len(lines); i++ {
				d := strings.TrimSpace(lines[i])
				if strings.HasPrefix(d, "}") {
					break
				}
				switch {
				case d == "daily", d == "weekly", d == "monthly":
					pol.freq = d
				case strings.HasPrefix(d, "rotate "):
					var n int
					if _, err := fmt.Sscanf(d, "rotate %d", &n); err == nil {
						pol.retain = n
					}
				}
			}
			for _, p := range pending {
				if strings.HasPrefix(p, prefix) {
					cov[strings.TrimPrefix(p, prefix)] = pol
				}
			}
			pending = nil
			continue
		}
		pending = append(pending, strings.Fields(line)...)
	}
	return cov
}

// TestLogInventoryCoveredByTemplates is the core drift assertion.
func TestLogInventoryCoveredByTemplates(t *testing.T) {
	root := repoRoot(t)
	mainCov := parseLogrotate(t, filepath.Join(root, "install", "config", "nftban.logrotate"))
	suriCov := parseLogrotate(t, filepath.Join(root, "install", "config", "nftban-suricata.logrotate"))

	for _, p := range LogInventory() {
		cov := mainCov
		if p.Template == TemplateSuricata {
			cov = suriCov
		}
		sp, ok := cov[p.Name]
		if !ok {
			t.Errorf("DRIFT: inventory log %q (%s) is NOT covered by any stanza in %s", p.Name, p.Category, p.Template)
			continue
		}
		if sp.freq != p.Rotation {
			t.Errorf("DRIFT: %q frequency: template=%q inventory=%q", p.Name, sp.freq, p.Rotation)
		}
		if sp.retain != p.Retain {
			t.Errorf("DRIFT: %q retain: template rotate=%d inventory=%d", p.Name, sp.retain, p.Retain)
		}
	}
}

// TestLogInventoryHasNoLegacyNames guards against the pre-v1.137 stale names
// reappearing (the original drift this mechanism was built to catch).
func TestLogInventoryHasNoLegacyNames(t *testing.T) {
	// Names that must never appear as inventory entries. Note ddos.log and
	// portscan.log are NOT here: they are live writer targets (nftban_ddos.sh /
	// nftban_portscan.sh) now covered by the template + inventory (v1.137 gap
	// close). Only the underscore CLI-errors name and the never-real suricata.log
	// remain rejected.
	legacy := []string{
		"cli_errors.log", // -> cli-errors.log (hyphen is the live writer path)
		"suricata.log",   // -> suricata-events.log or suricata/* native logs
	}
	for _, p := range LogInventory() {
		for _, bad := range legacy {
			if p.Name == bad {
				t.Errorf("inventory contains legacy/pre-split name %q (reconcile to current split/hyphen filename)", bad)
			}
		}
	}
}

// TestLogInventoryHasRequiredAdditions asserts the v1.137 additions + the
// reconciled current filenames are present.
func TestLogInventoryHasRequiredAdditions(t *testing.T) {
	required := []string{
		"installer.log", "update.log",
		"cli-errors.log",
		"ddos-classic.log", "ddos-suricata.log",
		"portscan-classic.log", "portscan-suricata.log",
		"suricata/eve-alerts.json",
	}
	have := map[string]bool{}
	for _, p := range LogInventory() {
		have[p.Name] = true
	}
	for _, r := range required {
		if !have[r] {
			t.Errorf("inventory is missing required entry %q", r)
		}
	}
}

// TestAllLogFilesDeriveFromInventory sanity-checks the runtime accessors stay in
// lockstep with the inventory (no second source of truth).
func TestAllLogFilesDeriveFromInventory(t *testing.T) {
	main, suri := 0, 0
	for _, p := range LogInventory() {
		if p.Template == TemplateSuricata {
			suri++
		} else {
			main++
		}
	}
	if got := len(AllLogFiles()); got != main {
		t.Errorf("AllLogFiles()=%d, want %d (main-template inventory entries)", got, main)
	}
	if got := len(SuricataLogFiles()); got != suri {
		t.Errorf("SuricataLogFiles()=%d, want %d (suricata-template inventory entries)", got, suri)
	}
}
