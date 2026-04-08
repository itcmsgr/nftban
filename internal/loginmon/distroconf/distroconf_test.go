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
		"exim_reject_log":          "/var/log/exim/rejectlog",
		"dovecot_log":              "/var/log/maillog",
		"directadmin_login_log":    "/var/log/directadmin/login.log",
		"directadmin_security_log": "/var/log/directadmin/security.log",
		"pureftpd_log":             "/var/log/messages",
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
		"auth_log":        "/var/log/auth.log",
		"maillog":         "/var/log/mail.log",
		"exim_log":        "/var/log/exim4/mainlog",
		"exim_reject_log": "/var/log/exim4/rejectlog",
		"dovecot_log":     "/var/log/mail.log",
		"pureftpd_log":    "/var/log/syslog",
	}
	for k, want := range cases {
		if got := l.Path(k); got != want {
			t.Errorf("Path(%q): got %q, want %q", k, got, want)
		}
	}

	// DA keys must be n/a on Debian family.
	for _, k := range []string{"directadmin_login_log", "directadmin_security_log"} {
		if !l.IsNA(k) {
			t.Errorf("IsNA(%q): expected true on Debian, got false", k)
		}
		// Path() returns "" for n/a entries.
		if l.Path(k) != "" {
			t.Errorf("Path(%q) on n/a: got %q, want empty", k, l.Path(k))
		}
		// HasKey() must still return true.
		if !l.HasKey(k) {
			t.Errorf("HasKey(%q) on n/a: expected true (key is declared)", k)
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
	l, _ := LoadFromFile(filepath.Join(realConfDir, "debian-12.conf"))
	r := l.Resolve("directadmin_login_log")
	if r.Outcome != NotApplicable {
		t.Errorf("Outcome: got %v, want NotApplicable", r.Outcome)
	}
	if r.Path != "" {
		t.Errorf("Path: expected empty for n/a, got %q", r.Path)
	}
	if !strings.Contains(r.Reason, "n/a") {
		t.Errorf("Reason: %q should mention n/a", r.Reason)
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
		"exim_reject_log",
		"dovecot_log",
		"pureftpd_log",
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

			// DA keys: real path on RHEL, n/a on Debian.
			fam := l.Family()
			for _, k := range rhelOnly {
				if !l.HasKey(k) {
					t.Errorf("missing required key: %s (family=%s)", k, fam)
					continue
				}
				switch fam {
				case "rhel":
					if l.IsNA(k) {
						t.Errorf("%s must be a real path on RHEL family, got n/a", k)
					}
					if l.Path(k) == "" {
						t.Errorf("%s has empty value on RHEL family", k)
					}
				case "debian":
					if !l.IsNA(k) {
						t.Errorf("%s must be n/a on Debian family, got %q", k, l.Path(k))
					}
				default:
					t.Errorf("unknown family: %q", fam)
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
