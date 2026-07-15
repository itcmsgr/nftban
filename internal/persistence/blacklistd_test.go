// =============================================================================
// NFTBan - Tests for blacklist persistence
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="persistence_blacklistd_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for blacklist persistence"
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

package persistence

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// =============================================================================
// Helper functions
// =============================================================================

func setupTestDir(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	blDir := filepath.Join(dir, "blacklist.d")
	if err := os.MkdirAll(blDir, 0750); err != nil {
		t.Fatalf("failed to create blacklist.d: %v", err)
	}
	return dir
}

func readFile(t *testing.T, path string) string {
	t.Helper()
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("failed to read %s: %v", path, err)
	}
	return string(data)
}

// =============================================================================
// fileMapping tests
// =============================================================================

func TestFileMapping_KnownSources(t *testing.T) {
	knownSources := []string{"login", "portscan", "ddos", "persistent", "manual"}
	for _, source := range knownSources {
		mapping, ok := fileMapping[source]
		if !ok {
			t.Errorf("fileMapping missing source %q", source)
			continue
		}
		if mapping.filename == "" {
			t.Errorf("fileMapping[%q].filename is empty", source)
		}
		if mapping.header == "" {
			t.Errorf("fileMapping[%q].header is empty", source)
		}
	}
}

func TestFileMapping_Filenames(t *testing.T) {
	tests := []struct {
		source   string
		filename string
	}{
		{"login", "login-auto.conf"},
		{"portscan", "portscan-auto.conf"},
		{"ddos", "ddos-auto.conf"},
		{"persistent", "30-persistent-offenders.conf"},
		{"manual", "99-manual.conf"},
	}

	for _, tt := range tests {
		t.Run(tt.source, func(t *testing.T) {
			mapping := fileMapping[tt.source]
			if mapping.filename != tt.filename {
				t.Errorf("fileMapping[%q].filename = %q, want %q",
					tt.source, mapping.filename, tt.filename)
			}
		})
	}
}

// =============================================================================
// Result type tests
// =============================================================================

func TestResultConstants(t *testing.T) {
	if Created != "created" {
		t.Errorf("Created = %q, want created", Created)
	}
	if AlreadyPresent != "already_present" {
		t.Errorf("AlreadyPresent = %q, want already_present", AlreadyPresent)
	}
}

// =============================================================================
// PersistBan tests
// =============================================================================

func TestPersistBan_NewIP(t *testing.T) {
	dir := setupTestDir(t)

	result, filename, err := PersistBan(dir, "1.2.3.4", "brute force", "manual")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != Created {
		t.Errorf("result = %q, want %q", result, Created)
	}
	if filename != "99-manual.conf" {
		t.Errorf("filename = %q, want 99-manual.conf", filename)
	}

	// Verify file contents
	content := readFile(t, filepath.Join(dir, "blacklist.d", "99-manual.conf"))
	if !strings.Contains(content, "1.2.3.4") {
		t.Error("file should contain the IP")
	}
	if !strings.Contains(content, "brute force") {
		t.Error("file should contain the reason")
	}
}

func TestPersistBan_DuplicateIP(t *testing.T) {
	dir := setupTestDir(t)

	// First ban
	result1, _, err := PersistBan(dir, "1.2.3.4", "first", "manual")
	if err != nil {
		t.Fatalf("unexpected error on first ban: %v", err)
	}
	if result1 != Created {
		t.Errorf("first ban result = %q, want %q", result1, Created)
	}

	// Duplicate ban
	result2, _, err := PersistBan(dir, "1.2.3.4", "second", "manual")
	if err != nil {
		t.Fatalf("unexpected error on duplicate ban: %v", err)
	}
	if result2 != AlreadyPresent {
		t.Errorf("duplicate ban result = %q, want %q", result2, AlreadyPresent)
	}
}

func TestPersistBan_DifferentSources(t *testing.T) {
	tests := []struct {
		source       string
		wantFilename string
	}{
		{"login", "login-auto.conf"},
		{"portscan", "portscan-auto.conf"},
		{"ddos", "ddos-auto.conf"},
		{"persistent", "30-persistent-offenders.conf"},
		{"manual", "99-manual.conf"},
		{"unknown", "99-manual.conf"}, // Falls back to manual
	}

	for _, tt := range tests {
		t.Run(tt.source, func(t *testing.T) {
			dir := setupTestDir(t)
			_, filename, err := PersistBan(dir, "1.2.3.4", "test", tt.source)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if filename != tt.wantFilename {
				t.Errorf("filename = %q, want %q", filename, tt.wantFilename)
			}
		})
	}
}

func TestPersistBan_NoReason(t *testing.T) {
	dir := setupTestDir(t)

	_, _, err := PersistBan(dir, "1.2.3.4", "", "manual")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	content := readFile(t, filepath.Join(dir, "blacklist.d", "99-manual.conf"))
	// Should just have the IP, no "# " comment
	lines := strings.Split(strings.TrimSpace(content), "\n")
	lastLine := lines[len(lines)-1]
	if strings.Contains(lastLine, "#") {
		t.Errorf("line should not have comment when reason is empty: %q", lastLine)
	}
}

func TestPersistBan_IPv6(t *testing.T) {
	dir := setupTestDir(t)

	result, _, err := PersistBan(dir, "2001:4860:4860::8888", "ipv6 test", "manual")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != Created {
		t.Errorf("result = %q, want %q", result, Created)
	}
}

func TestPersistBan_CIDR(t *testing.T) {
	dir := setupTestDir(t)

	result, _, err := PersistBan(dir, "10.0.0.0/8", "block range", "manual")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if result != Created {
		t.Errorf("result = %q, want %q", result, Created)
	}
}

func TestPersistBan_InvalidIP(t *testing.T) {
	dir := setupTestDir(t)

	_, _, err := PersistBan(dir, "not-an-ip", "test", "manual")
	if err == nil {
		t.Error("expected error for invalid IP")
	}
}

func TestPersistBan_Header(t *testing.T) {
	dir := setupTestDir(t)

	_, _, err := PersistBan(dir, "1.2.3.4", "test", "login")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	content := readFile(t, filepath.Join(dir, "blacklist.d", "login-auto.conf"))
	if !strings.Contains(content, "Login Monitor Auto-Ban") {
		t.Error("login file should have Login Monitor header")
	}
}

func TestPersistBan_MultipleIPs(t *testing.T) {
	dir := setupTestDir(t)

	ips := []string{"1.2.3.4", "5.6.7.8", "9.9.9.9"}
	for _, ip := range ips {
		result, _, err := PersistBan(dir, ip, "test", "manual")
		if err != nil {
			t.Fatalf("unexpected error for %s: %v", ip, err)
		}
		if result != Created {
			t.Errorf("result for %s = %q, want %q", ip, result, Created)
		}
	}

	content := readFile(t, filepath.Join(dir, "blacklist.d", "99-manual.conf"))
	for _, ip := range ips {
		if !strings.Contains(content, ip) {
			t.Errorf("file should contain %s", ip)
		}
	}
}

// =============================================================================
// UnpersistBan tests
// =============================================================================

func TestUnpersistBan_ExistingIP(t *testing.T) {
	dir := setupTestDir(t)

	// Add an IP first
	_, _, err := PersistBan(dir, "1.2.3.4", "test", "manual")
	if err != nil {
		t.Fatalf("setup error: %v", err)
	}

	// Remove it
	modified, err := UnpersistBan(dir, "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if modified != 1 {
		t.Errorf("modified = %d, want 1", modified)
	}

	// Verify it's gone
	content := readFile(t, filepath.Join(dir, "blacklist.d", "99-manual.conf"))
	for _, line := range strings.Split(content, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		fields := strings.Fields(trimmed)
		if len(fields) > 0 && fields[0] == "1.2.3.4" {
			t.Error("IP should have been removed from file")
		}
	}
}

func TestUnpersistBan_NonexistentIP(t *testing.T) {
	dir := setupTestDir(t)

	// Add different IP
	_, _, err := PersistBan(dir, "5.6.7.8", "test", "manual")
	if err != nil {
		t.Fatalf("setup error: %v", err)
	}

	// Try to remove IP that doesn't exist
	modified, err := UnpersistBan(dir, "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if modified != 0 {
		t.Errorf("modified = %d, want 0 (IP not in any file)", modified)
	}
}

func TestUnpersistBan_NoBlacklistDir(t *testing.T) {
	dir := t.TempDir() // No blacklist.d subdirectory

	modified, err := UnpersistBan(dir, "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if modified != 0 {
		t.Errorf("modified = %d, want 0 (no blacklist.d)", modified)
	}
}

func TestUnpersistBan_InvalidIP(t *testing.T) {
	dir := setupTestDir(t)

	_, err := UnpersistBan(dir, "not-an-ip")
	if err == nil {
		t.Error("expected error for invalid IP")
	}
}

func TestUnpersistBan_AcrossMultipleFiles(t *testing.T) {
	dir := setupTestDir(t)

	// Add same IP to multiple sources
	PersistBan(dir, "1.2.3.4", "login attempt", "login")
	// Must add to manual file manually since PersistBan deduplicates
	manualFile := filepath.Join(dir, "blacklist.d", "99-manual.conf")
	os.WriteFile(manualFile, []byte("1.2.3.4  # manual ban\n"), 0640)

	modified, err := UnpersistBan(dir, "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if modified != 2 {
		t.Errorf("modified = %d, want 2 (should remove from both files)", modified)
	}
}

// =============================================================================
// removeIPFromFile tests
// =============================================================================

func TestRemoveIPFromFile_WithComment(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "test.conf")
	content := `# Header
1.2.3.4  # brute force
5.6.7.8  # scanner
`
	os.WriteFile(file, []byte(content), 0640)

	removed, err := removeIPFromFile(file, "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !removed {
		t.Error("expected removed = true")
	}

	result := readFile(t, file)
	if strings.Contains(result, "1.2.3.4") {
		t.Error("1.2.3.4 should have been removed")
	}
	if !strings.Contains(result, "5.6.7.8") {
		t.Error("5.6.7.8 should still be present")
	}
}

func TestRemoveIPFromFile_NonexistentFile(t *testing.T) {
	removed, err := removeIPFromFile("/tmp/nonexistent-file-12345", "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if removed {
		t.Error("expected removed = false for nonexistent file")
	}
}

func TestRemoveIPFromFile_IPNotInFile(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "test.conf")
	os.WriteFile(file, []byte("5.6.7.8\n"), 0640)

	removed, err := removeIPFromFile(file, "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if removed {
		t.Error("expected removed = false when IP not in file")
	}
}

func TestRemoveIPFromFile_PreservesComments(t *testing.T) {
	dir := t.TempDir()
	file := filepath.Join(dir, "test.conf")
	content := `# This is a header
# DO NOT EDIT
1.2.3.4
5.6.7.8
# Footer
`
	os.WriteFile(file, []byte(content), 0640)

	removed, err := removeIPFromFile(file, "1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !removed {
		t.Error("expected removed = true")
	}

	result := readFile(t, file)
	if !strings.Contains(result, "This is a header") {
		t.Error("header comment should be preserved")
	}
	if !strings.Contains(result, "Footer") {
		t.Error("footer comment should be preserved")
	}
}
