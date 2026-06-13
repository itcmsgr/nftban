// =============================================================================
// NFTBan v1.79.2 - distroconf reader tests (BUG-15)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: distroconf
// Purpose: Unit tests for distroconf reader against real production distro confs.
//
// meta:name="loginmon_distroconf_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="distroconf"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-08"
// meta:description="Unit tests for distroconf reader; enforces BUG-14 schema parity"
//
// meta:inventory.files="distroconf_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="../../../etc/nftban/distros/*.conf"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package distroconf

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// realConfDir points at the production distro confs in the repo.
// Tests run against these so the test suite IS the BUG-14 schema enforcement.
const realConfDir = "../../../etc/nftban/distros"

// =============================================================================
// INI parser tests
// =============================================================================

func TestParseINI_Simple(t *testing.T) {
	in := strings.NewReader(`
[paths]
auth_log = /var/log/secure
maillog = /var/log/maillog
# this is a comment
exim_log = /var/log/exim/mainlog

[distro]
family = rhel
`)
	out, err := parseINI(in)
	if err != nil {
		t.Fatalf("parseINI: %v", err)
	}
	if out["paths"]["auth_log"] != "/var/log/secure" {
		t.Errorf("auth_log: got %q", out["paths"]["auth_log"])
	}
	if out["paths"]["maillog"] != "/var/log/maillog" {
		t.Errorf("maillog: got %q", out["paths"]["maillog"])
	}
	if out["distro"]["family"] != "rhel" {
		t.Errorf("family: got %q", out["distro"]["family"])
	}
}

func TestParseINI_NaLiteral(t *testing.T) {
	in := strings.NewReader(`
[paths]
directadmin_login_log = n/a
`)
	out, err := parseINI(in)
	if err != nil {
		t.Fatalf("parseINI: %v", err)
	}
	if out["paths"]["directadmin_login_log"] != "n/a" {
		t.Errorf("expected literal n/a, got %q", out["paths"]["directadmin_login_log"])
	}
}

func TestParseINI_MalformedSection(t *testing.T) {
	in := strings.NewReader("[paths\nkey = value\n")
	if _, err := parseINI(in); err == nil {
		t.Error("expected error on malformed section header")
	}
}

func TestParseINI_KeyOutsideSection(t *testing.T) {
	in := strings.NewReader("key = value\n")
	if _, err := parseINI(in); err == nil {
		t.Error("expected error on key outside section")
	}
}

// =============================================================================
// Loader tests against real production distro confs
// =============================================================================

func TestLoadFromFile_Almalinux9(t *testing.T) {
	l, err := LoadFromFile(filepath.Join(realConfDir, "almalinux-9.conf"))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if l.DistroID() != "almalinux-9" {
		t.Errorf("DistroID: got %q", l.DistroID())
	}
	if l.Family() != "rhel" {
		t.Errorf("Family: got %q", l.Family())
	}

	cases := map[string]string{
		"auth_log":                 "/var/log/secure",
		"maillog":                  "/var/log/maillog",
		"exim_log":                 "/var/log/exim/mainlog",
		"dovecot_log":              "/var/log/maillog",
		"directadmin_login_log":    "/var/log/directadmin/login.log",
		"directadmin_security_log": "/var/log/directadmin/security.log",
	}
	for k, want := range cases {
		if got := l.Path(k); got != want {
			t.Errorf("Path(%q): got %q, want %q", k, got, want)
		}
		if l.IsNA(k) {
			t.Errorf("IsNA(%q): expected false on RHEL", k)
		}
	}
}

func TestLoadFromFile_Debian12(t *testing.T) {
	l, err := LoadFromFile(filepath.Join(realConfDir, "debian-12.conf"))
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	if l.Family() != "debian" {
		t.Errorf("Family: got %q", l.Family())
	}

	// Universal keys must be present with Debian paths.
	cases := map[string]string{
		"auth_log":                 "/var/log/auth.log",
		"maillog":                  "/var/log/mail.log",
		"exim_log":                 "/var/log/exim4/mainlog",
		"dovecot_log":              "/var/log/mail.log",
		"directadmin_login_log":    "/var/log/directadmin/login.log",
		"directadmin_security_log": "/var/log/directadmin/security.log",
	}
	for k, want := range cases {
		if got := l.Path(k); got != want {
			t.Errorf("Path(%q): got %q, want %q", k, got, want)
		}
		if l.IsNA(k) {
			t.Errorf("IsNA(%q): expected false (BUG-19 — DA is universal)", k)
		}
	}
}

// =============================================================================
// Resolution tests — the canonical parser entry point
// =============================================================================

func TestResolve_Resolved(t *testing.T) {
	l, _ := LoadFromFile(filepath.Join(realConfDir, "almalinux-9.conf"))
	r := l.Resolve("exim_log")
	if r.Outcome != Resolved {
		t.Errorf("Outcome: got %v, want Resolved", r.Outcome)
	}
	if r.Path != "/var/log/exim/mainlog" {
		t.Errorf("Path: got %q", r.Path)
	}
	if r.DistroID != "almalinux-9" {
		t.Errorf("DistroID: got %q", r.DistroID)
	}
	if !strings.HasPrefix(r.Reason, "distroconf:") {
		t.Errorf("Reason: got %q, want distroconf: prefix", r.Reason)
	}
}

func TestResolve_NotApplicable(t *testing.T) {
	// BUG-19 (v1.79.3): no production distro conf uses n/a for any key.
	// Use a temp fixture to test the NotApplicable outcome semantics
	// independently of production conf state.
	dir := t.TempDir()
	confPath := filepath.Join(dir, "synthetic-1.conf")
	content := `[distro]
family = synthetic
[paths]
some_key = n/a
real_key = /var/log/example
`
	if err := os.WriteFile(confPath, []byte(content), 0644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	l, err := LoadFromFile(confPath)
	if err != nil {
		t.Fatalf("load: %v", err)
	}

	r := l.Resolve("some_key")
	if r.Outcome != NotApplicable {
		t.Errorf("Outcome: got %v, want NotApplicable", r.Outcome)
	}
	if r.Path != "" {
		t.Errorf("Path: expected empty for n/a, got %q", r.Path)
	}
	if !strings.Contains(r.Reason, "n/a") {
		t.Errorf("Reason: %q should mention n/a", r.Reason)
	}

	// Sibling sanity: real_key should be Resolved.
	r2 := l.Resolve("real_key")
	if r2.Outcome != Resolved || r2.Path != "/var/log/example" {
		t.Errorf("real_key: outcome=%v path=%q", r2.Outcome, r2.Path)
	}
}

func TestResolve_Absent(t *testing.T) {
	l, _ := LoadFromFile(filepath.Join(realConfDir, "almalinux-9.conf"))
	r := l.Resolve("nonexistent_log")
	if r.Outcome != Absent {
		t.Errorf("Outcome: got %v, want Absent", r.Outcome)
	}
	if r.Path != "" {
		t.Errorf("Path: got %q", r.Path)
	}
}

func TestResolve_LoaderUnavailable(t *testing.T) {
	var l *Loader
	r := l.Resolve("exim_log")
	if r.Outcome != LoaderUnavailable {
		t.Errorf("Outcome: got %v, want LoaderUnavailable", r.Outcome)
	}
}

// =============================================================================
// All-distros sanity check — the BUG-14 schema enforcement at test time
// =============================================================================

// TestAllDistros_HaveAllRequiredKeys is the parity test between the BUG-14 gap
// matrix and the actual distro confs in the repo. If a contributor adds a new
// distro conf without the required keys, this test fails.
func TestAllDistros_HaveAllRequiredKeys(t *testing.T) {
	universal := []string{
		"auth_log",
		"maillog",
		"exim_log",
		"dovecot_log",
	}
	rhelOnly := []string{
		"directadmin_login_log",
		"directadmin_security_log",
	}

	matches, err := filepath.Glob(filepath.Join(realConfDir, "*.conf"))
	if err != nil || len(matches) == 0 {
		t.Fatalf("no distro confs found: %v", err)
	}

	for _, path := range matches {
		name := strings.TrimSuffix(filepath.Base(path), ".conf")
		t.Run(name, func(t *testing.T) {
			l, err := LoadFromFile(path)
			if err != nil {
				t.Fatalf("load: %v", err)
			}

			// Universal keys required everywhere with a real path.
			for _, k := range universal {
				if !l.HasKey(k) {
					t.Errorf("missing required universal key: %s", k)
					continue
				}
				if l.IsNA(k) {
					t.Errorf("universal key %s must not be n/a", k)
					continue
				}
				if l.Path(k) == "" {
					t.Errorf("universal key %s has empty value", k)
				}
			}

			// BUG-19 (v1.79.3): DA path keys are universal — DirectAdmin
			// supports both RHEL and Debian/Ubuntu. Real paths on every family.
			for _, k := range rhelOnly {
				if !l.HasKey(k) {
					t.Errorf("missing required DA key: %s", k)
					continue
				}
				if l.IsNA(k) {
					t.Errorf("%s must be a real path (DA supports all families), got n/a", k)
				}
				if l.Path(k) == "" {
					t.Errorf("%s has empty value", k)
				}
			}
		})
	}
}

// =============================================================================
// Distro detection tests
// =============================================================================

func TestParseOSRelease_Almalinux9(t *testing.T) {
	in := strings.NewReader(`NAME="AlmaLinux"
VERSION="9.5 (Teal Serval)"
ID="almalinux"
ID_LIKE="rhel centos fedora"
VERSION_ID="9.5"
PRETTY_NAME="AlmaLinux 9.5 (Teal Serval)"
`)
	parsed, err := parseOSRelease(in)
	if err != nil {
		t.Fatalf("parseOSRelease: %v", err)
	}
	if parsed["ID"] != "almalinux" {
		t.Errorf("ID: got %q", parsed["ID"])
	}
	if parsed["VERSION_ID"] != "9.5" {
		t.Errorf("VERSION_ID: got %q", parsed["VERSION_ID"])
	}
}

func TestSeriesOf(t *testing.T) {
	cases := map[string]string{
		"9":     "9",
		"9.7":   "9",
		"24.04": "24",
		"24.10": "24",
		"12.5":  "12",
		"10":    "10",
		"":      "",
		"abc":   "",
		"43":    "43",
	}
	for in, want := range cases {
		if got := seriesOf(in); got != want {
			t.Errorf("seriesOf(%q): got %q, want %q", in, got, want)
		}
	}
}

func TestFamilyOf(t *testing.T) {
	cases := map[string]string{
		"almalinux-9":      "almalinux",
		"almalinux-10":     "almalinux",
		"ubuntu-22":        "ubuntu",
		"ubuntu-24":        "ubuntu",
		"debian-12":        "debian",
		"centos-stream-9":  "centos-stream",
		"centos-stream-10": "centos-stream",
		"fedora":           "", // no series suffix
		"rocky-9":          "rocky",
	}
	for in, want := range cases {
		if got := familyOf(in); got != want {
			t.Errorf("familyOf(%q): got %q, want %q", in, got, want)
		}
	}
}

func TestFindHighestSeriesConf(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{
		"almalinux-8.conf",
		"almalinux-9.conf",
		"almalinux-10.conf",
		"unrelated.conf",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("[paths]\n"), 0644); err != nil {
			t.Fatalf("write fixture: %v", err)
		}
	}

	got := findHighestSeriesConf(dir, "almalinux")
	want := filepath.Join(dir, "almalinux-10.conf")
	if got != want {
		t.Errorf("findHighestSeriesConf: got %q, want %q", got, want)
	}

	if findHighestSeriesConf(dir, "ubuntu") != "" {
		t.Errorf("expected empty for nonexistent family")
	}
}

func TestLoadByID_ForwardFitNewSeries(t *testing.T) {
	// Simulates a host running AlmaLinux 11.x when the newest shipped
	// conf is almalinux-10.conf. Should fall back to almalinux-10.conf
	// rather than failing.
	dir := t.TempDir()
	tenPath := filepath.Join(dir, "almalinux-10.conf")
	if err := os.WriteFile(tenPath, []byte("[paths]\nauth_log = /var/log/secure\n[distro]\nfamily = rhel\n"), 0644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "almalinux-9.conf"), []byte("[paths]\n[distro]\nfamily = rhel\n"), 0644); err != nil {
		t.Fatalf("write fixture: %v", err)
	}

	l, err := loadByID(dir, "almalinux-11")
	if err != nil {
		t.Fatalf("loadByID forward-fit: %v", err)
	}
	if l.ConfPath() != tenPath {
		t.Errorf("forward-fit: got %q, want %q", l.ConfPath(), tenPath)
	}
}

func TestNormalizeDistroID(t *testing.T) {
	cases := map[string]string{
		"alma":      "almalinux",
		"almalinux": "almalinux",
		"rhel":      "rhel",
		"redhat":    "rhel",
		"debian":    "debian",
		"ubuntu":    "ubuntu",
	}
	for in, want := range cases {
		if got := normalizeDistroID(in); got != want {
			t.Errorf("normalizeDistroID(%q): got %q, want %q", in, got, want)
		}
	}
}
