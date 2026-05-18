// =============================================================================
// NFTBan - Tests for whitelist loading and management
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="whitelist_loader_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for whitelist loading and management"
// meta:input="None"
// meta:output="None"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package whitelist

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// =============================================================================
// Helper functions
// =============================================================================

func setupTestConfig(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	wlDir := filepath.Join(dir, "whitelist.d")
	if err := os.MkdirAll(wlDir, 0750); err != nil {
		t.Fatalf("failed to create whitelist.d: %v", err)
	}
	return dir
}

func writeWhitelistFile(t *testing.T, dir, name, content string) {
	t.Helper()
	path := filepath.Join(dir, "whitelist.d", name)
	if err := os.WriteFile(path, []byte(content), 0640); err != nil {
		t.Fatalf("failed to write %s: %v", name, err)
	}
}

// =============================================================================
// LoadAllWhitelists tests
// =============================================================================

func TestLoadAllWhitelists_Empty(t *testing.T) {
	dir := setupTestConfig(t)

	ipv4, ipv6, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 0 {
		t.Errorf("len(ipv4) = %d, want 0", len(ipv4))
	}
	if len(ipv6) != 0 {
		t.Errorf("len(ipv6) = %d, want 0", len(ipv6))
	}
}

func TestLoadAllWhitelists_IPv4Only(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "99-manual.conf", `# Manual whitelist
1.2.3.4
5.6.7.8
192.168.1.0/24
`)

	ipv4, ipv6, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 3 {
		t.Errorf("len(ipv4) = %d, want 3", len(ipv4))
	}
	if len(ipv6) != 0 {
		t.Errorf("len(ipv6) = %d, want 0", len(ipv6))
	}
}

func TestLoadAllWhitelists_MixedIPv4IPv6(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "99-manual.conf", `1.2.3.4
2001:db8::1
10.0.0.0/8
::1
`)

	ipv4, ipv6, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 2 {
		t.Errorf("len(ipv4) = %d, want 2", len(ipv4))
	}
	if len(ipv6) != 2 {
		t.Errorf("len(ipv6) = %d, want 2", len(ipv6))
	}
}

func TestLoadAllWhitelists_MainFile(t *testing.T) {
	dir := setupTestConfig(t)

	// Create main whitelist.conf (not in whitelist.d/)
	mainFile := filepath.Join(dir, "whitelist.conf")
	os.WriteFile(mainFile, []byte("1.2.3.4\n"), 0640)

	ipv4, _, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 1 {
		t.Errorf("len(ipv4) = %d, want 1 (from whitelist.conf)", len(ipv4))
	}
}

func TestLoadAllWhitelists_MainFileAndDir(t *testing.T) {
	dir := setupTestConfig(t)

	// Main file
	mainFile := filepath.Join(dir, "whitelist.conf")
	os.WriteFile(mainFile, []byte("1.2.3.4\n"), 0640)

	// Directory file
	writeWhitelistFile(t, dir, "99-manual.conf", "5.6.7.8\n")

	ipv4, _, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// Both sources merged
	if len(ipv4) != 2 {
		t.Errorf("len(ipv4) = %d, want 2 (merged from both sources)", len(ipv4))
	}
}

func TestLoadAllWhitelists_MultipleFiles(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "00-system.conf", "10.0.0.1\n")
	writeWhitelistFile(t, dir, "01-admin.conf", "192.168.1.1\n")
	writeWhitelistFile(t, dir, "99-manual.conf", "5.6.7.8\n")

	ipv4, _, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 3 {
		t.Errorf("len(ipv4) = %d, want 3", len(ipv4))
	}
}

func TestLoadAllWhitelists_SkipsNonConf(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "99-manual.conf", "1.2.3.4\n")
	os.WriteFile(filepath.Join(dir, "whitelist.d", "notes.txt"), []byte("5.6.7.8\n"), 0640)

	ipv4, _, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 1 {
		t.Errorf("len(ipv4) = %d, want 1 (should skip .txt files)", len(ipv4))
	}
}

func TestLoadAllWhitelists_SkipsDirectories(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "99-manual.conf", "1.2.3.4\n")
	os.MkdirAll(filepath.Join(dir, "whitelist.d", "subdir"), 0750)

	ipv4, _, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 1 {
		t.Errorf("len(ipv4) = %d, want 1", len(ipv4))
	}
}

func TestLoadAllWhitelists_NoWhitelistDir(t *testing.T) {
	dir := t.TempDir() // No whitelist.d subdirectory

	ipv4, ipv6, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// Non-fatal: returns empty sets
	if len(ipv4) != 0 || len(ipv6) != 0 {
		t.Error("expected empty sets when whitelist.d doesn't exist")
	}
}

func TestLoadAllWhitelists_CommentsAndBlanks(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "99-manual.conf", `# Header
; Semicolon comment

1.2.3.4  # admin IP

# Middle comment
5.6.7.8  ; server IP
`)

	ipv4, _, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 2 {
		t.Errorf("len(ipv4) = %d, want 2 (should skip comments/blanks)", len(ipv4))
	}
}

func TestLoadAllWhitelists_Deduplication(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "00-system.conf", "1.2.3.4\n")
	writeWhitelistFile(t, dir, "99-manual.conf", "1.2.3.4\n5.6.7.8\n")

	ipv4, _, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 2 {
		t.Errorf("len(ipv4) = %d, want 2 (deduplicated)", len(ipv4))
	}
}

// =============================================================================
// AddIP tests
// =============================================================================

func TestAddIP_BasicIPv4(t *testing.T) {
	dir := setupTestConfig(t)

	// NOTE: AddIP passes IPs through sync.FilterProblematicCIDRs which uses
	// net.ParseCIDR — bare IPs (no /prefix) fail parsing and get filtered.
	// Must use CIDR notation for AddIP to work.
	err := AddIP(dir, "8.8.8.8/32")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	ipv4, _, _ := LoadAllWhitelists(dir)
	if !ipv4["8.8.8.8/32"] {
		t.Error("8.8.8.8/32 should be in whitelist")
	}
}

func TestAddIP_BareIPRejected(t *testing.T) {
	// TODO: This is arguably a bug — AddIP should accept bare IPs.
	// FilterProblematicCIDRs uses net.ParseCIDR which requires /prefix.
	dir := setupTestConfig(t)

	err := AddIP(dir, "8.8.8.8")
	if err == nil {
		t.Error("expected error for bare IP (FilterProblematicCIDRs rejects non-CIDR)")
	}
}

func TestAddIP_IPv6(t *testing.T) {
	dir := setupTestConfig(t)

	err := AddIP(dir, "2001:4860:4860::8888/128")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	_, ipv6, _ := LoadAllWhitelists(dir)
	if !ipv6["2001:4860:4860::8888/128"] {
		t.Error("2001:4860:4860::8888/128 should be in whitelist")
	}
}

func TestAddIP_DuplicateDetection(t *testing.T) {
	dir := setupTestConfig(t)

	// First add
	err := AddIP(dir, "8.8.8.8/32")
	if err != nil {
		t.Fatalf("first add error: %v", err)
	}

	// Duplicate
	err = AddIP(dir, "8.8.8.8/32")
	if err == nil {
		t.Error("expected error for duplicate IP")
	}
	if err != nil && !strings.Contains(err.Error(), "already whitelisted") {
		t.Errorf("expected 'already whitelisted' error, got: %v", err)
	}
}

func TestAddIP_InvalidIP(t *testing.T) {
	dir := setupTestConfig(t)

	err := AddIP(dir, "not-an-ip")
	if err == nil {
		t.Error("expected error for invalid IP")
	}
}

func TestAddIP_RejectsSlash0(t *testing.T) {
	dir := setupTestConfig(t)

	err := AddIP(dir, "0.0.0.0/0")
	if err == nil {
		t.Error("expected error for /0 CIDR")
	}
	if err != nil && !strings.Contains(err.Error(), "refusing") {
		t.Errorf("expected 'refusing' error, got: %v", err)
	}
}

func TestAddIP_RejectsSlash1(t *testing.T) {
	dir := setupTestConfig(t)

	err := AddIP(dir, "0.0.0.0/1")
	if err == nil {
		t.Error("expected error for /1 CIDR")
	}
}

func TestAddIP_CreatesManualFile(t *testing.T) {
	dir := setupTestConfig(t)

	AddIP(dir, "8.8.8.8/32")

	manualFile := filepath.Join(dir, "whitelist.d", "99-manual.conf")
	content, err := os.ReadFile(manualFile)
	if err != nil {
		t.Fatalf("99-manual.conf should exist: %v", err)
	}
	if !strings.Contains(string(content), "8.8.8.8") {
		t.Error("99-manual.conf should contain the IP")
	}
	// Should have header on first write
	if !strings.Contains(string(content), "Manual Whitelist") {
		t.Error("99-manual.conf should have header")
	}
}

// =============================================================================
// RemoveIP tests
// =============================================================================

func TestRemoveIP_ExistingIP(t *testing.T) {
	dir := setupTestConfig(t)

	// Add first
	AddIP(dir, "8.8.8.8/32")

	// Remove
	err := RemoveIP(dir, "8.8.8.8/32")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Verify removed
	ipv4, _, _ := LoadAllWhitelists(dir)
	if ipv4["8.8.8.8/32"] {
		t.Error("IP should have been removed")
	}
}

func TestRemoveIP_NotFound(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "99-manual.conf", "5.6.7.8\n")

	err := RemoveIP(dir, "1.2.3.4")
	if err == nil {
		t.Error("expected error when IP not found")
	}
	if err != nil && !strings.Contains(err.Error(), "not found") {
		t.Errorf("expected 'not found' error, got: %v", err)
	}
}

func TestRemoveIP_InvalidIP(t *testing.T) {
	dir := setupTestConfig(t)

	err := RemoveIP(dir, "not-an-ip")
	if err == nil {
		t.Error("expected error for invalid IP")
	}
}

func TestRemoveIP_SkipsSystemFiles(t *testing.T) {
	dir := setupTestConfig(t)

	// Write IP to system file
	writeWhitelistFile(t, dir, "00-system.conf", "1.2.3.4\n")
	// Also add to manual file
	writeWhitelistFile(t, dir, "99-manual.conf", "1.2.3.4\n")

	err := RemoveIP(dir, "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// IP should still be in system file (protected from removal)
	content, _ := os.ReadFile(filepath.Join(dir, "whitelist.d", "00-system.conf"))
	if !strings.Contains(string(content), "1.2.3.4") {
		t.Error("00-system.conf should not have IP removed (protected)")
	}
}

func TestRemoveIP_SkipsInitFiles(t *testing.T) {
	dir := setupTestConfig(t)

	writeWhitelistFile(t, dir, "01-nftban-init.conf", "10.0.0.1\n")
	writeWhitelistFile(t, dir, "99-manual.conf", "10.0.0.1\n")

	err := RemoveIP(dir, "10.0.0.1")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Init file should be untouched
	content, _ := os.ReadFile(filepath.Join(dir, "whitelist.d", "01-nftban-init.conf"))
	if !strings.Contains(string(content), "10.0.0.1") {
		t.Error("01-nftban-init.conf should not have IP removed (protected)")
	}
}

func TestRemoveIP_FromMainFile(t *testing.T) {
	dir := setupTestConfig(t)

	// Write to main whitelist.conf
	mainFile := filepath.Join(dir, "whitelist.conf")
	os.WriteFile(mainFile, []byte("1.2.3.4\n5.6.7.8\n"), 0640)

	err := RemoveIP(dir, "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	content, _ := os.ReadFile(mainFile)
	if strings.Contains(string(content), "1.2.3.4") {
		t.Error("IP should have been removed from main file")
	}
	if !strings.Contains(string(content), "5.6.7.8") {
		t.Error("other IPs should remain")
	}
}

// =============================================================================
// removeIPFromFile tests
// =============================================================================

func TestRemoveIPFromFile_ExactMatch(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "test.conf")
	os.WriteFile(file, []byte("1.2.3.4\n5.6.7.8\n"), 0640)

	err := removeIPFromFile(file, "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	content, _ := os.ReadFile(file)
	if strings.Contains(string(content), "1.2.3.4") {
		t.Error("IP should have been removed")
	}
}

func TestRemoveIPFromFile_WithSpaceAfter(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "test.conf")
	os.WriteFile(file, []byte("1.2.3.4 some comment\n"), 0640)

	err := removeIPFromFile(file, "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	content, _ := os.ReadFile(file)
	if strings.Contains(string(content), "1.2.3.4") {
		t.Error("IP with trailing space+text should have been removed")
	}
}

func TestRemoveIPFromFile_WithTabAfter(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "test.conf")
	os.WriteFile(file, []byte("1.2.3.4\tsome comment\n"), 0640)

	err := removeIPFromFile(file, "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	content, _ := os.ReadFile(file)
	if strings.Contains(string(content), "1.2.3.4") {
		t.Error("IP with trailing tab+text should have been removed")
	}
}

func TestRemoveIPFromFile_NotFound(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "test.conf")
	os.WriteFile(file, []byte("5.6.7.8\n"), 0640)

	err := removeIPFromFile(file, "1.2.3.4")
	if err == nil {
		t.Error("expected error when IP not found")
	}
}

func TestRemoveIPFromFile_FileNotFound(t *testing.T) {
	err := removeIPFromFile("/tmp/nonexistent-12345", "1.2.3.4")
	if err == nil {
		t.Error("expected error for nonexistent file")
	}
}

// =============================================================================
// V119 A1: Typed loader + IsIPInWhitelistFile tests
// Mirror of blacklist/loader_test.go §7 matrix — closes whitelist half of
// D-MANUAL-CIDR-LOAD-GAP per V116 §7 Test 5.
// =============================================================================

func TestLoadAllWhitelistsTyped_PreservesIsCIDR(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "99-manual.conf", `# Mixed single-IP + CIDR entries
1.2.3.4
1.2.3.0/27
2001:db8::/64
`)

	ipv4, ipv6, err := LoadAllWhitelistsTyped(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(ipv4) != 2 {
		t.Errorf("len(ipv4) = %d, want 2 (1.2.3.4 + 1.2.3.0/27)", len(ipv4))
	}
	if len(ipv6) != 1 {
		t.Errorf("len(ipv6) = %d, want 1 (2001:db8::/64)", len(ipv6))
	}

	if entry, ok := ipv4["1.2.3.4"]; !ok || entry.IsCIDR {
		t.Errorf("ipv4[1.2.3.4]: got IsCIDR=%v, want IsCIDR=false (and present)", entry.IsCIDR)
	}
	if entry, ok := ipv4["1.2.3.0/27"]; !ok || !entry.IsCIDR {
		t.Errorf("ipv4[1.2.3.0/27]: got IsCIDR=%v, want IsCIDR=true (and present)", entry.IsCIDR)
	}
	if entry, ok := ipv6["2001:db8::/64"]; !ok || !entry.IsCIDR {
		t.Errorf("ipv6[2001:db8::/64]: got IsCIDR=%v, want IsCIDR=true (and present)", entry.IsCIDR)
	}
}

// V116 §7 Test 5: whitelist CIDR pre-ban guard — symmetric to blacklist
// Test 2 but in the whitelist namespace. Closes the daemon-side half of
// D-MANUAL-CIDR-LOAD-GAP — without this fix, an IP inside a whitelisted
// /27 was NOT protected from being banned.
func TestIsIPInWhitelistFile_IPv4CIDRContainment(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "99-manual.conf", "1.2.3.0/27\n")

	ipv4, _, err := LoadAllWhitelistsTyped(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// 1.2.3.5 is inside 1.2.3.0/27 — whitelist guard MUST recognise this.
	if !IsIPInWhitelistFile("1.2.3.5", ipv4) {
		t.Error("IsIPInWhitelistFile(1.2.3.5) against 1.2.3.0/27: got false, want true (this is the V119 fix)")
	}
	// 1.2.3.32 is OUTSIDE 1.2.3.0/27 — must NOT be over-protected.
	if IsIPInWhitelistFile("1.2.3.32", ipv4) {
		t.Error("IsIPInWhitelistFile(1.2.3.32) against 1.2.3.0/27: got true, want false")
	}
	// Exact CIDR literal still matches.
	if !IsIPInWhitelistFile("1.2.3.0/27", ipv4) {
		t.Error("IsIPInWhitelistFile(1.2.3.0/27) against 1.2.3.0/27: got false, want true (exact key)")
	}
}

func TestIsIPInWhitelistFile_SingleIPv4ExactMatch(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "99-manual.conf", "1.2.3.4\n")

	ipv4, _, _ := LoadAllWhitelistsTyped(dir)
	if !IsIPInWhitelistFile("1.2.3.4", ipv4) {
		t.Error("IsIPInWhitelistFile(1.2.3.4) = false, want true")
	}
	if IsIPInWhitelistFile("1.2.3.5", ipv4) {
		t.Error("IsIPInWhitelistFile(1.2.3.5) = true, want false")
	}
}

func TestIsIPInWhitelistFile_IPv6CIDRContainment(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "99-manual.conf", "2001:db8::/64\n")

	_, ipv6, _ := LoadAllWhitelistsTyped(dir)
	if !IsIPInWhitelistFile("2001:db8::5", ipv6) {
		t.Error("IsIPInWhitelistFile(2001:db8::5) against 2001:db8::/64: got false, want true")
	}
	if IsIPInWhitelistFile("2001:db9::1", ipv6) {
		t.Error("IsIPInWhitelistFile(2001:db9::1) against 2001:db8::/64: got true, want false")
	}
}

func TestIsIPInWhitelistFile_InvalidIPInput(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "99-manual.conf", "1.2.3.0/27\n")
	ipv4, _, _ := LoadAllWhitelistsTyped(dir)

	if IsIPInWhitelistFile("not-an-ip", ipv4) {
		t.Error("IsIPInWhitelistFile(not-an-ip) = true, want false (invalid input)")
	}
}

// =============================================================================
// V120 EXPIRES_AT matrix tests (D-UPDATE-OPERATOR-SELF-BAN-GAP-001)
// =============================================================================
// Asserts the v1.120 loader extension `shouldSkipDueToExpiresAt`:
//   * loads entries with EXPIRES_AT in the future
//   * skips entries with EXPIRES_AT in the past (expired)
//   * conservatively skips entries with malformed EXPIRES_AT timestamps
//   * preserves backward compatibility (no marker → always load)
// =============================================================================

func TestLoadAllWhitelists_EXPIRES_AT_FutureEntryLoaded(t *testing.T) {
	dir := setupTestConfig(t)
	// EXPIRES_AT in the year 2100 — comfortably future.
	writeWhitelistFile(t, dir, "00-session.conf", `10.0.0.1  # EXPIRES_AT=2100-01-01T00:00:00Z  REASON=test  ADDED_BY=test
`)

	ipv4, _, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !ipv4["10.0.0.1/32"] && !ipv4["10.0.0.1"] {
		t.Errorf("expected 10.0.0.1 to be loaded (EXPIRES_AT future), ipv4=%v", ipv4)
	}
}

func TestLoadAllWhitelists_EXPIRES_AT_PastEntrySkipped(t *testing.T) {
	dir := setupTestConfig(t)
	// EXPIRES_AT in the year 2000 — comfortably past.
	writeWhitelistFile(t, dir, "00-session.conf", `10.0.0.2  # EXPIRES_AT=2000-01-01T00:00:00Z  REASON=stale  ADDED_BY=test
`)

	ipv4, _, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ipv4["10.0.0.2/32"] || ipv4["10.0.0.2"] {
		t.Errorf("expected 10.0.0.2 to be SKIPPED (EXPIRES_AT past), ipv4=%v", ipv4)
	}
}

func TestLoadAllWhitelists_EXPIRES_AT_MalformedSkippedConservatively(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "00-session.conf", `10.0.0.3  # EXPIRES_AT=not-a-timestamp  REASON=garbage  ADDED_BY=test
`)

	ipv4, _, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// Malformed marker → conservative skip (the marker's PRESENCE signals
	// "this is a TTL'd entry"; failure to parse must not be treated as
	// "no marker" because that would default to permanent load).
	if ipv4["10.0.0.3/32"] || ipv4["10.0.0.3"] {
		t.Errorf("expected 10.0.0.3 to be SKIPPED (malformed EXPIRES_AT), ipv4=%v", ipv4)
	}
}

func TestLoadAllWhitelists_EXPIRES_AT_NoMarkerLoaded(t *testing.T) {
	dir := setupTestConfig(t)
	// Plain entry without any EXPIRES_AT marker — backward-compat path.
	writeWhitelistFile(t, dir, "99-manual.conf", `10.0.0.4
`)

	ipv4, _, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !ipv4["10.0.0.4/32"] && !ipv4["10.0.0.4"] {
		t.Errorf("expected 10.0.0.4 to be loaded (no EXPIRES_AT = permanent), ipv4=%v", ipv4)
	}
}

func TestLoadAllWhitelists_EXPIRES_AT_MixedFileFutureAndPast(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "00-session.conf", `# header
10.0.0.5  # EXPIRES_AT=2100-01-01T00:00:00Z  REASON=keep  ADDED_BY=test
10.0.0.6  # EXPIRES_AT=2000-01-01T00:00:00Z  REASON=drop  ADDED_BY=test
10.0.0.7
`)

	ipv4, _, err := LoadAllWhitelists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !ipv4["10.0.0.5/32"] && !ipv4["10.0.0.5"] {
		t.Errorf("expected 10.0.0.5 loaded (future), ipv4=%v", ipv4)
	}
	if ipv4["10.0.0.6/32"] || ipv4["10.0.0.6"] {
		t.Errorf("expected 10.0.0.6 SKIPPED (past), ipv4=%v", ipv4)
	}
	if !ipv4["10.0.0.7/32"] && !ipv4["10.0.0.7"] {
		t.Errorf("expected 10.0.0.7 loaded (no marker), ipv4=%v", ipv4)
	}
}

// Dual-API parity guard: legacy LoadAllWhitelists key set must match
// LoadAllWhitelistsTyped (guards profile_sync.go callers against drift).
func TestLoadAllWhitelists_DualAPIParity(t *testing.T) {
	dir := setupTestConfig(t)
	writeWhitelistFile(t, dir, "99-manual.conf", `1.2.3.4
1.2.3.0/27
2001:db8::/64
`)

	ipv4Bool, ipv6Bool, _ := LoadAllWhitelists(dir)
	ipv4Typed, ipv6Typed, _ := LoadAllWhitelistsTyped(dir)

	if len(ipv4Bool) != len(ipv4Typed) {
		t.Errorf("len(ipv4Bool)=%d != len(ipv4Typed)=%d", len(ipv4Bool), len(ipv4Typed))
	}
	if len(ipv6Bool) != len(ipv6Typed) {
		t.Errorf("len(ipv6Bool)=%d != len(ipv6Typed)=%d", len(ipv6Bool), len(ipv6Typed))
	}
	for k := range ipv4Typed {
		if !ipv4Bool[k] {
			t.Errorf("ipv4Typed key %q missing from ipv4Bool", k)
		}
	}
	for k := range ipv6Typed {
		if !ipv6Bool[k] {
			t.Errorf("ipv6Typed key %q missing from ipv6Bool", k)
		}
	}
}
