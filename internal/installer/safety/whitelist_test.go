// =============================================================================
// NFTBan v1.98.x - Installer Safety Whitelist Tests (PR-14-pre G-14-H)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-safety-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Tests for source-install safety whitelist seeding"
// meta:inventory.files="internal/installer/safety/whitelist_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars="SSH_CLIENT"
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package safety

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

func newTestLogger() *logging.Logger {
	return logging.New("", false)
}

func TestSeedManualWhitelist_CreatesFileWhenAbsent(t *testing.T) {
	mock := executor.NewMockExecutor()
	// File does not exist
	t.Setenv("SSH_CLIENT", "") // ensure deterministic (no env leakage)

	if err := SeedManualWhitelist(mock, newTestLogger()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	written, ok := mock.WrittenFiles[manualWhitelistPath]
	if !ok {
		t.Fatalf("expected %s to be written, but no atomic write recorded", manualWhitelistPath)
	}
	if !strings.Contains(string(written), "NFTBan Manual Whitelist") {
		t.Errorf("seeded file missing canonical header")
	}
}

func TestSeedManualWhitelist_PreservesOperatorContent(t *testing.T) {
	mock := executor.NewMockExecutor()
	// Existing file with operator content (a non-comment line)
	mock.Files[manualWhitelistPath] = []byte(`# NFTBan Manual Whitelist - User-Added IPs
192.168.42.99   # Operator added this
`)

	if err := SeedManualWhitelist(mock, newTestLogger()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Nothing should have been written — operator content preserved
	if _, wrote := mock.WrittenFiles[manualWhitelistPath]; wrote {
		t.Errorf("SeedManualWhitelist overwrote existing operator content")
	}
}

func TestSeedManualWhitelist_SeedsWhenFileHasOnlyComments(t *testing.T) {
	mock := executor.NewMockExecutor()
	// File exists but only has comments and blank lines (e.g., shipped template
	// that hasn't been populated yet)
	mock.Files[manualWhitelistPath] = []byte(`# =============================================================================
# NFTBan Manual Whitelist - User-Added IPs
# =============================================================================
#
#   some explanation
#
`)

	if err := SeedManualWhitelist(mock, newTestLogger()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// File should be rewritten since it had no operator content
	if _, wrote := mock.WrittenFiles[manualWhitelistPath]; !wrote {
		t.Errorf("SeedManualWhitelist did not seed a comments-only template")
	}
}

func TestSeedManualWhitelist_IncludesSSHClientIP(t *testing.T) {
	mock := executor.NewMockExecutor()
	// Set SSH_CLIENT env — simulating admin session
	t.Setenv("SSH_CLIENT", "203.0.113.42 54321 22")

	if err := SeedManualWhitelist(mock, newTestLogger()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	content := string(mock.WrittenFiles[manualWhitelistPath])
	if !strings.Contains(content, "203.0.113.42") {
		t.Errorf("seeded file missing SSH client IP 203.0.113.42")
	}
	if !strings.Contains(content, "SSH installer client IP") {
		t.Errorf("seeded file missing expected SSH client comment")
	}
}

func TestSeedManualWhitelist_SkipsMalformedSSHClient(t *testing.T) {
	mock := executor.NewMockExecutor()
	// Malformed SSH_CLIENT — should not crash or add garbage
	t.Setenv("SSH_CLIENT", "not-an-ip 0 0")

	if err := SeedManualWhitelist(mock, newTestLogger()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	content := string(mock.WrittenFiles[manualWhitelistPath])
	if strings.Contains(content, "not-an-ip") {
		t.Errorf("seeded file contains malformed SSH client value")
	}
}

func TestSeedManualWhitelist_SkipsLoopbackSSHClient(t *testing.T) {
	mock := executor.NewMockExecutor()
	t.Setenv("SSH_CLIENT", "127.0.0.1 0 0")

	if err := SeedManualWhitelist(mock, newTestLogger()); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	content := string(mock.WrittenFiles[manualWhitelistPath])
	if strings.Contains(content, "127.0.0.1") {
		t.Errorf("seeded file contains loopback IP (should be filtered)")
	}
}

func TestIsRoutableIP(t *testing.T) {
	cases := map[string]bool{
		"8.8.8.8":         true,
		"192.168.1.1":     true, // RFC1918 is still routable per net.IP
		"203.0.113.42":    true,
		"2001:db8::1":     true,
		"127.0.0.1":       false, // loopback
		"::1":             false, // v6 loopback
		"169.254.1.1":     false, // link-local v4
		"fe80::1":         false, // link-local v6
		"224.0.0.1":       false, // multicast
		"0.0.0.0":         false, // unspecified
		"::":              false, // v6 unspecified
		"not-an-ip":       false,
		"":                false,
		" 8.8.8.8 ":       true, // whitespace trimmed
	}
	for in, want := range cases {
		if got := isRoutableIP(in); got != want {
			t.Errorf("isRoutableIP(%q) = %v, want %v", in, got, want)
		}
	}
}

func TestHasOperatorContent(t *testing.T) {
	mock := executor.NewMockExecutor()

	// Case 1: file absent
	if hasOperatorContent(mock, manualWhitelistPath) {
		t.Errorf("expected false for absent file, got true")
	}

	// Case 2: only comments / blanks
	mock.Files[manualWhitelistPath] = []byte("# header\n#\n   \n")
	if hasOperatorContent(mock, manualWhitelistPath) {
		t.Errorf("expected false for comments-only file, got true")
	}

	// Case 3: operator line
	mock.Files[manualWhitelistPath] = []byte("# header\n192.168.1.1\n")
	if !hasOperatorContent(mock, manualWhitelistPath) {
		t.Errorf("expected true for file with operator content, got false")
	}

	// Case 4: inline comment on operator line still counts as operator content
	mock.Files[manualWhitelistPath] = []byte("# header\n10.0.0.1  # my box\n")
	if !hasOperatorContent(mock, manualWhitelistPath) {
		t.Errorf("expected true for operator line with inline comment, got false")
	}
}

