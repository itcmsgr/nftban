// SPDX-License-Identifier: MPL-2.0
// meta:name="logretention-loadconf-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-19"
// meta:description="Tests the logs.conf -> Overrides reader: absent file is fully automatic; the shipped auto default parses clean; uncommented overrides are honored; commented lines are ignored; malformed and out-of-contract values fail (no silent fallback); the repo's shipped conf.d/logs.conf loads and validates."
// meta:inventory.files="internal/logretention/loadconf.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="etc/nftban/conf.d/logs.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package logretention

import (
	"os"
	"path/filepath"
	"testing"
)

func writeConf(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "logs.conf")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestLoadOverridesAbsentIsAuto(t *testing.T) {
	o, err := LoadOverrides(filepath.Join(t.TempDir(), "nope.conf"))
	if err != nil {
		t.Fatalf("absent conf should not error: %v", err)
	}
	if (o != Overrides{}) {
		t.Errorf("absent conf should yield zero Overrides, got %+v", o)
	}
}

func TestLoadOverridesShippedDefaultIsAuto(t *testing.T) {
	p := writeConf(t, `# comment
LOG_RETENTION_MODE="auto"
#LOG_RETENTION_MAX_PERCENT="15"
#LOG_RETENTION_MAX_BYTES="0"
`)
	o, err := LoadOverrides(p)
	if err != nil {
		t.Fatalf("shipped default should load: %v", err)
	}
	if o.Mode != "auto" || o.MaxPercent != 0 || o.MaxBytes != 0 {
		t.Errorf("commented overrides leaked: %+v", o)
	}
	// auto mode must NOT read as an operator override
	disk := DiskFacts{TotalBytes: 50 * GiB, AvailBytes: 30 * GiB}
	p2, _ := Calculate(disk, ClassifyProfile(disk, false, ""), o, DefaultFamilies())
	if p2.PolicySource != "automatic" {
		t.Errorf("auto conf should be automatic, got %s", p2.PolicySource)
	}
}

func TestLoadOverridesHonorsUncommented(t *testing.T) {
	p := writeConf(t, `LOG_RETENTION_MODE="fixed"
LOG_RETENTION_MAX_PERCENT="25"
LOG_RETENTION_MAX_BYTES="3221225472"
LOG_RETENTION_MIN_DAYS="14"
LOG_RETENTION_MAX_DAYS="45"
LOG_RETENTION_PROFILE="high-volume"
`)
	o, err := LoadOverrides(p)
	if err != nil {
		t.Fatalf("valid overrides should load: %v", err)
	}
	if o.Mode != "fixed" || o.MaxPercent != 25 || o.MaxBytes != 3*GiB || o.MinDays != 14 || o.MaxDays != 45 || o.Profile != "high-volume" {
		t.Errorf("overrides not parsed: %+v", o)
	}
}

func TestLoadOverridesInvalidFails(t *testing.T) {
	bad := []string{
		`LOG_RETENTION_MAX_PERCENT="abc"`,                                    // non-numeric
		`LOG_RETENTION_MAX_PERCENT="200"`,                                    // out of contract (Validate)
		`LOG_RETENTION_MODE="off"`,                                           // unsupported mode
		`LOG_RETENTION_MIN_DAYS="90"` + "\n" + `LOG_RETENTION_MAX_DAYS="30"`, // min>max
		`LOG_RETENTION_MAX_BYTES="ten"`,                                      // non-numeric bytes
	}
	for i, b := range bad {
		if _, err := LoadOverrides(writeConf(t, b)); err == nil {
			t.Errorf("case %d: invalid conf %q did not fail", i, b)
		}
	}
}

func TestShippedConfLoads(t *testing.T) {
	// the repo's actual conf.d/logs.conf must parse + validate
	repo := "../../etc/nftban/conf.d/logs.conf"
	if _, err := os.Stat(repo); err != nil {
		t.Skipf("shipped conf not found: %v", err)
	}
	o, err := LoadOverrides(repo)
	if err != nil {
		t.Fatalf("shipped conf.d/logs.conf failed to load/validate: %v", err)
	}
	if o.Mode != "auto" {
		t.Errorf("shipped conf mode = %q, want auto", o.Mode)
	}
}
