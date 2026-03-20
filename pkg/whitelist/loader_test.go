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
