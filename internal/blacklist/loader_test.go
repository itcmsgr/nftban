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
