// =============================================================================
// NFTBan - Tests for blacklist loading and management
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="blacklist_loader_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for blacklist loading and management"
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

package blacklist

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
	blDir := filepath.Join(dir, "blacklist.d")
	if err := os.MkdirAll(blDir, 0750); err != nil {
		t.Fatalf("failed to create blacklist.d: %v", err)
	}
	return dir
}

func writeBlacklistFile(t *testing.T, dir, name, content string) {
	t.Helper()
	path := filepath.Join(dir, "blacklist.d", name)
	if err := os.WriteFile(path, []byte(content), 0640); err != nil {
		t.Fatalf("failed to write %s: %v", name, err)
	}
}

// =============================================================================
// LoadAllBlacklists tests
// =============================================================================

func TestLoadAllBlacklists_Empty(t *testing.T) {
	dir := setupTestConfig(t)

	ipv4, ipv6, err := LoadAllBlacklists(dir)
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

func TestLoadAllBlacklists_IPv4Only(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "99-manual.conf", `# Manual blacklist
1.2.3.4
5.6.7.8
10.0.0.1
`)

	ipv4, ipv6, err := LoadAllBlacklists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 3 {
		t.Errorf("len(ipv4) = %d, want 3", len(ipv4))
	}
	if len(ipv6) != 0 {
		t.Errorf("len(ipv6) = %d, want 0", len(ipv6))
	}

	// Check specific IPs
	for _, ip := range []string{"1.2.3.4", "5.6.7.8", "10.0.0.1"} {
		if !ipv4[ip] {
			t.Errorf("expected %s in IPv4 set", ip)
		}
	}
}

func TestLoadAllBlacklists_MixedIPv4IPv6(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "99-manual.conf", `1.2.3.4
2001:db8::1
10.0.0.0/8
::1
`)

	ipv4, ipv6, err := LoadAllBlacklists(dir)
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

func TestLoadAllBlacklists_MultipleFiles(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "login-auto.conf", `# Login bans
1.2.3.4
`)
	writeBlacklistFile(t, dir, "portscan-auto.conf", `# Portscan bans
5.6.7.8
`)
	writeBlacklistFile(t, dir, "99-manual.conf", `# Manual bans
10.0.0.1
`)

	ipv4, _, err := LoadAllBlacklists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 3 {
		t.Errorf("len(ipv4) = %d, want 3", len(ipv4))
	}
}

func TestLoadAllBlacklists_SkipsNonConf(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "99-manual.conf", "1.2.3.4\n")
	// Non-.conf files should be skipped
	os.WriteFile(filepath.Join(dir, "blacklist.d", "readme.md"), []byte("docs"), 0640)
	os.WriteFile(filepath.Join(dir, "blacklist.d", "backup.bak"), []byte("5.6.7.8\n"), 0640)

	ipv4, _, err := LoadAllBlacklists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 1 {
		t.Errorf("len(ipv4) = %d, want 1 (should skip non-.conf)", len(ipv4))
	}
}

func TestLoadAllBlacklists_SkipsDirectories(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "99-manual.conf", "1.2.3.4\n")
	os.MkdirAll(filepath.Join(dir, "blacklist.d", "subdir"), 0750)

	ipv4, _, err := LoadAllBlacklists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 1 {
		t.Errorf("len(ipv4) = %d, want 1", len(ipv4))
	}
}

func TestLoadAllBlacklists_NoBlacklistDir(t *testing.T) {
	dir := t.TempDir() // No blacklist.d subdirectory

	ipv4, ipv6, err := LoadAllBlacklists(dir)
	if err != nil {
		t.Fatalf("unexpected error (should be non-fatal): %v", err)
	}
	if len(ipv4) != 0 || len(ipv6) != 0 {
		t.Error("expected empty sets when blacklist.d doesn't exist")
	}
}

func TestLoadAllBlacklists_CommentsAndBlanks(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "99-manual.conf", `# Header
; Semicolon comment

1.2.3.4  # inline comment

# Middle comment
5.6.7.8  ; another comment
`)

	ipv4, _, err := LoadAllBlacklists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 2 {
		t.Errorf("len(ipv4) = %d, want 2", len(ipv4))
	}
}

func TestLoadAllBlacklists_Deduplication(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "login-auto.conf", "1.2.3.4\n")
	writeBlacklistFile(t, dir, "99-manual.conf", "1.2.3.4\n5.6.7.8\n")

	ipv4, _, err := LoadAllBlacklists(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// 1.2.3.4 appears in both files but should only count once
	if len(ipv4) != 2 {
		t.Errorf("len(ipv4) = %d, want 2 (deduplicated)", len(ipv4))
	}
}

// =============================================================================
// AddIPWithSource tests
// =============================================================================

func TestAddIPWithSource_ManualBan(t *testing.T) {
	dir := setupTestConfig(t)

	err := AddIPWithSource(dir, "1.2.3.4", "brute force", "manual")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	content, _ := os.ReadFile(filepath.Join(dir, "blacklist.d", "99-manual.conf"))
	if !strings.Contains(string(content), "1.2.3.4") {
		t.Error("file should contain the IP")
	}
	if !strings.Contains(string(content), "brute force") {
		t.Error("file should contain the reason")
	}
}

func TestAddIPWithSource_LoginBan(t *testing.T) {
	dir := setupTestConfig(t)

	err := AddIPWithSource(dir, "1.2.3.4", "login failure", "login")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Verify it went to login-auto.conf
	content, err := os.ReadFile(filepath.Join(dir, "blacklist.d", "login-auto.conf"))
	if err != nil {
		t.Fatalf("failed to read login-auto.conf: %v", err)
	}
	if !strings.Contains(string(content), "1.2.3.4") {
		t.Error("login-auto.conf should contain the IP")
	}
}

func TestAddIPWithSource_DuplicateDetection(t *testing.T) {
	dir := setupTestConfig(t)

	// First add
	err := AddIPWithSource(dir, "1.2.3.4", "first", "manual")
	if err != nil {
		t.Fatalf("first add error: %v", err)
	}

	// Duplicate
	err = AddIPWithSource(dir, "1.2.3.4", "second", "manual")
	if err == nil {
		t.Error("expected error for duplicate IP")
	}
	if err != nil && !strings.Contains(err.Error(), "already blacklisted") {
		t.Errorf("expected 'already blacklisted' error, got: %v", err)
	}
}

func TestAddIPWithSource_IPv6(t *testing.T) {
	dir := setupTestConfig(t)

	err := AddIPWithSource(dir, "2001:db8::1", "ipv6 test", "manual")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	ipv4, ipv6, _ := LoadAllBlacklists(dir)
	if len(ipv4) != 0 {
		t.Errorf("len(ipv4) = %d, want 0", len(ipv4))
	}
	if len(ipv6) != 1 {
		t.Errorf("len(ipv6) = %d, want 1", len(ipv6))
	}
}

func TestAddIPWithSource_InvalidIP(t *testing.T) {
	dir := setupTestConfig(t)

	err := AddIPWithSource(dir, "not-an-ip", "test", "manual")
	if err == nil {
		t.Error("expected error for invalid IP")
	}
}

func TestAddIPWithSource_NoReason(t *testing.T) {
	dir := setupTestConfig(t)

	err := AddIPWithSource(dir, "1.2.3.4", "", "manual")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	content, _ := os.ReadFile(filepath.Join(dir, "blacklist.d", "99-manual.conf"))
	lines := strings.Split(strings.TrimSpace(string(content)), "\n")
	lastLine := lines[len(lines)-1]
	// Should just be the IP without a comment
	if strings.TrimSpace(lastLine) != "1.2.3.4" {
		t.Errorf("last line = %q, want just the IP", lastLine)
	}
}

func TestAddIP_FallsBackToManual(t *testing.T) {
	dir := setupTestConfig(t)

	err := AddIP(dir, "1.2.3.4", "test")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Should be in 99-manual.conf (AddIP uses "manual" source)
	content, _ := os.ReadFile(filepath.Join(dir, "blacklist.d", "99-manual.conf"))
	if !strings.Contains(string(content), "1.2.3.4") {
		t.Error("99-manual.conf should contain the IP")
	}
}

// =============================================================================
// RemoveIP tests
// =============================================================================

func TestRemoveIP_ExistingIP(t *testing.T) {
	dir := setupTestConfig(t)

	// Add first
	AddIPWithSource(dir, "1.2.3.4", "test", "manual")

	// Remove
	err := RemoveIP(dir, "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// Verify removed
	ipv4, _, _ := LoadAllBlacklists(dir)
	if ipv4["1.2.3.4"] {
		t.Error("IP should have been removed")
	}
}

func TestRemoveIP_NonexistentIP(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "99-manual.conf", "5.6.7.8\n")

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

func TestRemoveIP_NoBlacklistDir(t *testing.T) {
	dir := t.TempDir() // No blacklist.d

	err := RemoveIP(dir, "1.2.3.4")
	if err == nil {
		t.Error("expected error when blacklist.d doesn't exist")
	}
}

// =============================================================================
// GetBlacklistByCategory tests
// =============================================================================

func TestGetBlacklistByCategory(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "login-auto.conf", `1.2.3.4
5.6.7.8
2001:db8::1
`)

	ipv4, ipv6, err := GetBlacklistByCategory(dir, "login-auto")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(ipv4) != 2 {
		t.Errorf("len(ipv4) = %d, want 2", len(ipv4))
	}
	if len(ipv6) != 1 {
		t.Errorf("len(ipv6) = %d, want 1", len(ipv6))
	}
}

func TestGetBlacklistByCategory_NotFound(t *testing.T) {
	dir := setupTestConfig(t)

	_, _, err := GetBlacklistByCategory(dir, "nonexistent")
	if err == nil {
		t.Error("expected error for nonexistent category")
	}
}

// =============================================================================
// removeIPFromFile tests
// =============================================================================

func TestBlacklist_RemoveIPFromFile_InlineComment(t *testing.T) {
	dir := setupTestConfig(t)
	filePath := filepath.Join(dir, "blacklist.d", "test.conf")
	os.WriteFile(filePath, []byte("1.2.3.4  # some reason\n5.6.7.8\n"), 0640)

	err := removeIPFromFile(filePath, "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	content, _ := os.ReadFile(filePath)
	if strings.Contains(string(content), "1.2.3.4") {
		t.Error("1.2.3.4 should have been removed")
	}
	if !strings.Contains(string(content), "5.6.7.8") {
		t.Error("5.6.7.8 should remain")
	}
}

// =============================================================================
// V119 A1: Typed loader + IsIPInBlacklistFile tests
// Covers V116_CAND3_MANUAL_CIDR_DESIGN_FIX_SCOPE.md §7 test matrix rows 1-4.
// =============================================================================

func TestLoadAllBlacklistsTyped_PreservesIsCIDR(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "99-manual.conf", `# Mixed single-IP + CIDR entries
1.2.3.4
1.2.3.0/27
5.6.7.8
2001:db8::1
2001:db8::/64
`)

	ipv4, ipv6, err := LoadAllBlacklistsTyped(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if len(ipv4) != 3 {
		t.Errorf("len(ipv4) = %d, want 3 (1.2.3.4 + 1.2.3.0/27 + 5.6.7.8)", len(ipv4))
	}
	if len(ipv6) != 2 {
		t.Errorf("len(ipv6) = %d, want 2 (2001:db8::1 + 2001:db8::/64)", len(ipv6))
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

// V116 §7 Test 1: literal IPv4 exact match (pre-V119 path still works).
func TestIsIPInBlacklistFile_SingleIPv4ExactMatch(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "99-manual.conf", "1.2.3.4\n")

	ipv4, _, err := LoadAllBlacklistsTyped(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !IsIPInBlacklistFile("1.2.3.4", ipv4) {
		t.Error("IsIPInBlacklistFile(1.2.3.4) = false, want true")
	}
	if IsIPInBlacklistFile("1.2.3.5", ipv4) {
		t.Error("IsIPInBlacklistFile(1.2.3.5) = true, want false (not in file)")
	}
}

// V116 §7 Test 2: IPv4 CIDR containment — IS the V119 fix.
// Pre-V119 all three sub-checks returned false; post-V119 the first two MUST return true.
func TestIsIPInBlacklistFile_IPv4CIDRContainment(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "99-manual.conf", "1.2.3.0/27\n")

	ipv4, _, err := LoadAllBlacklistsTyped(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	// 1.2.3.5 is inside 1.2.3.0/27 (which spans 1.2.3.0-1.2.3.31).
	if !IsIPInBlacklistFile("1.2.3.5", ipv4) {
		t.Error("IsIPInBlacklistFile(1.2.3.5) against 1.2.3.0/27: got false, want true")
	}
	// 1.2.3.32 is OUTSIDE 1.2.3.0/27 (next /27 starts at .32).
	if IsIPInBlacklistFile("1.2.3.32", ipv4) {
		t.Error("IsIPInBlacklistFile(1.2.3.32) against 1.2.3.0/27: got true, want false")
	}
	// Exact CIDR literal still matches (preserves operator workflow).
	if !IsIPInBlacklistFile("1.2.3.0/27", ipv4) {
		t.Error("IsIPInBlacklistFile(1.2.3.0/27) against 1.2.3.0/27: got false, want true (exact key)")
	}
}

// V116 §7 Test 3: single IPv6 — symmetric to Test 1.
func TestIsIPInBlacklistFile_SingleIPv6ExactMatch(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "99-manual.conf", "2001:db8::1\n")

	_, ipv6, err := LoadAllBlacklistsTyped(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !IsIPInBlacklistFile("2001:db8::1", ipv6) {
		t.Error("IsIPInBlacklistFile(2001:db8::1) = false, want true")
	}
	if IsIPInBlacklistFile("2001:db8::2", ipv6) {
		t.Error("IsIPInBlacklistFile(2001:db8::2) = true, want false")
	}
}

// V116 §7 Test 4: IPv6 CIDR — symmetric to Test 2.
func TestIsIPInBlacklistFile_IPv6CIDRContainment(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "99-manual.conf", "2001:db8::/64\n")

	_, ipv6, err := LoadAllBlacklistsTyped(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	if !IsIPInBlacklistFile("2001:db8::5", ipv6) {
		t.Error("IsIPInBlacklistFile(2001:db8::5) against 2001:db8::/64: got false, want true")
	}
	if IsIPInBlacklistFile("2001:db9::1", ipv6) {
		t.Error("IsIPInBlacklistFile(2001:db9::1) against 2001:db8::/64: got true, want false")
	}
}

// Edge case: invalid IP argument returns false rather than panicking.
func TestIsIPInBlacklistFile_InvalidIPInput(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "99-manual.conf", "1.2.3.0/27\n")
	ipv4, _, _ := LoadAllBlacklistsTyped(dir)

	if IsIPInBlacklistFile("not-an-ip", ipv4) {
		t.Error("IsIPInBlacklistFile(not-an-ip) = true, want false (invalid input)")
	}
	if IsIPInBlacklistFile("", ipv4) {
		t.Error("IsIPInBlacklistFile(\"\") = true, want false")
	}
}

// Dual-API parity guard: legacy LoadAllBlacklists must return identical
// key sets as LoadAllBlacklistsTyped (just shaped differently). This
// guards profile_sync.go's legacy-API callers against silent drift.
func TestLoadAllBlacklists_DualAPIParity(t *testing.T) {
	dir := setupTestConfig(t)
	writeBlacklistFile(t, dir, "99-manual.conf", `1.2.3.4
1.2.3.0/27
2001:db8::1
2001:db8::/64
`)

	ipv4Bool, ipv6Bool, err := LoadAllBlacklists(dir)
	if err != nil {
		t.Fatalf("LoadAllBlacklists: %v", err)
	}
	ipv4Typed, ipv6Typed, err := LoadAllBlacklistsTyped(dir)
	if err != nil {
		t.Fatalf("LoadAllBlacklistsTyped: %v", err)
	}

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
