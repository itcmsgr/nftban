// =============================================================================
// NFTBan v1.0 - Geographic IP Banning Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="geoban_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for geoban constants, directory listing, and build"
// meta:input="Test cases"
// meta:output="Test results"
// meta:depends="testing"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package geoban

import (
	"os"
	"path/filepath"
	"testing"
)

// =============================================================================
// Constants Tests
// =============================================================================

func TestBanFilePrefix(t *testing.T) {
	if BanFilePrefix != "50-ban-" {
		t.Errorf("BanFilePrefix = %q, want %q", BanFilePrefix, "50-ban-")
	}
}

func TestWhitelistFilePrefix(t *testing.T) {
	if WhitelistFilePrefix != "40-whitelist-" {
		t.Errorf("WhitelistFilePrefix = %q, want %q", WhitelistFilePrefix, "40-whitelist-")
	}
}

// =============================================================================
// Stats Struct Tests
// =============================================================================

func TestStats_Struct(t *testing.T) {
	stats := Stats{
		Countries:     2,
		TotalCIDRs:    100,
		IPv4CIDRs:     80,
		IPv6CIDRs:     20,
		BannedList:    []string{"CN", "RU"},
		WhitelistList: []string{"US"},
	}

	if stats.Countries != 2 {
		t.Errorf("Countries = %d, want 2", stats.Countries)
	}
	if stats.TotalCIDRs != 100 {
		t.Errorf("TotalCIDRs = %d, want 100", stats.TotalCIDRs)
	}
	if stats.IPv4CIDRs != 80 {
		t.Errorf("IPv4CIDRs = %d, want 80", stats.IPv4CIDRs)
	}
	if stats.IPv6CIDRs != 20 {
		t.Errorf("IPv6CIDRs = %d, want 20", stats.IPv6CIDRs)
	}
	if len(stats.BannedList) != 2 {
		t.Errorf("BannedList length = %d, want 2", len(stats.BannedList))
	}
	if len(stats.WhitelistList) != 1 {
		t.Errorf("WhitelistList length = %d, want 1", len(stats.WhitelistList))
	}
}

// =============================================================================
// ListBannedCountries Tests
// =============================================================================

func TestListBannedCountries_EmptyDir(t *testing.T) {
	dir := t.TempDir()

	countries, err := ListBannedCountries(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(countries) != 0 {
		t.Errorf("expected 0 countries, got %d", len(countries))
	}
}

func TestListBannedCountries_WithBanFiles(t *testing.T) {
	dir := t.TempDir()

	// Create ban files
	for _, cc := range []string{"CN", "RU", "KP"} {
		f := filepath.Join(dir, BanFilePrefix+cc+".conf")
		if err := os.WriteFile(f, []byte("# test"), 0644); err != nil {
			t.Fatalf("failed to create test file: %v", err)
		}
	}

	countries, err := ListBannedCountries(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(countries) != 3 {
		t.Errorf("expected 3 countries, got %d: %v", len(countries), countries)
	}

	// Check all expected countries are present
	found := make(map[string]bool)
	for _, c := range countries {
		found[c] = true
	}
	for _, expected := range []string{"CN", "RU", "KP"} {
		if !found[expected] {
			t.Errorf("expected country %q in result, got %v", expected, countries)
		}
	}
}

func TestListBannedCountries_IgnoresNonBanFiles(t *testing.T) {
	dir := t.TempDir()

	// Create a ban file
	os.WriteFile(filepath.Join(dir, "50-ban-CN.conf"), []byte("# test"), 0644)

	// Create non-ban files that should be ignored
	os.WriteFile(filepath.Join(dir, "40-whitelist-US.conf"), []byte("# test"), 0644)
	os.WriteFile(filepath.Join(dir, "README.md"), []byte("# docs"), 0644)
	os.WriteFile(filepath.Join(dir, "50-ban-RU.txt"), []byte("# wrong extension"), 0644)

	countries, err := ListBannedCountries(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(countries) != 1 {
		t.Errorf("expected 1 country, got %d: %v", len(countries), countries)
	}
	if len(countries) > 0 && countries[0] != "CN" {
		t.Errorf("expected country CN, got %q", countries[0])
	}
}

func TestListBannedCountries_IgnoresDirectories(t *testing.T) {
	dir := t.TempDir()

	// Create a subdirectory that looks like a ban file
	os.MkdirAll(filepath.Join(dir, "50-ban-XX.conf"), 0755)

	// Create a real ban file
	os.WriteFile(filepath.Join(dir, "50-ban-CN.conf"), []byte("# test"), 0644)

	countries, err := ListBannedCountries(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(countries) != 1 {
		t.Errorf("expected 1 country (directory should be ignored), got %d: %v", len(countries), countries)
	}
}

func TestListBannedCountries_NonexistentDir(t *testing.T) {
	_, err := ListBannedCountries("/nonexistent/path/geoban.d")
	if err == nil {
		t.Error("expected error for nonexistent directory")
	}
}

// =============================================================================
// ListWhitelistedCountries Tests
// =============================================================================

func TestListWhitelistedCountries_EmptyDir(t *testing.T) {
	dir := t.TempDir()

	countries, err := ListWhitelistedCountries(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(countries) != 0 {
		t.Errorf("expected 0 countries, got %d", len(countries))
	}
}

func TestListWhitelistedCountries_WithWhitelistFiles(t *testing.T) {
	dir := t.TempDir()

	// Create whitelist files
	for _, cc := range []string{"US", "GB"} {
		f := filepath.Join(dir, WhitelistFilePrefix+cc+".conf")
		if err := os.WriteFile(f, []byte("# test"), 0644); err != nil {
			t.Fatalf("failed to create test file: %v", err)
		}
	}

	countries, err := ListWhitelistedCountries(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(countries) != 2 {
		t.Errorf("expected 2 countries, got %d: %v", len(countries), countries)
	}
}

func TestListWhitelistedCountries_IgnoresBanFiles(t *testing.T) {
	dir := t.TempDir()

	// Create both types
	os.WriteFile(filepath.Join(dir, "40-whitelist-US.conf"), []byte("# test"), 0644)
	os.WriteFile(filepath.Join(dir, "50-ban-CN.conf"), []byte("# test"), 0644)

	countries, err := ListWhitelistedCountries(dir)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(countries) != 1 {
		t.Errorf("expected 1 whitelisted country, got %d: %v", len(countries), countries)
	}
	if len(countries) > 0 && countries[0] != "US" {
		t.Errorf("expected country US, got %q", countries[0])
	}
}

func TestListWhitelistedCountries_NonexistentDir(t *testing.T) {
	_, err := ListWhitelistedCountries("/nonexistent/path/geoban.d")
	if err == nil {
		t.Error("expected error for nonexistent directory")
	}
}

// =============================================================================
// Build Tests
// =============================================================================

func TestBuild_EmptyDir(t *testing.T) {
	dir := t.TempDir()

	data, err := Build(dir, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if data == nil {
		t.Fatal("expected non-nil SetData")
	}
	if data.Count != 0 {
		t.Errorf("expected 0 CIDRs, got %d", data.Count)
	}
}

func TestBuild_WithIPv4CIDRs(t *testing.T) {
	dir := t.TempDir()

	// Create a country file with IPv4 CIDRs
	content := `# China IPv4
1.0.0.0/24
1.0.1.0/24
1.0.2.0/23
`
	os.WriteFile(filepath.Join(dir, "50-ban-CN.conf"), []byte(content), 0644)

	data, err := Build(dir, []string{"CN"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(data.IPv4) != 3 {
		t.Errorf("expected 3 IPv4 CIDRs, got %d: %v", len(data.IPv4), data.IPv4)
	}
	if len(data.IPv6) != 0 {
		t.Errorf("expected 0 IPv6 CIDRs, got %d", len(data.IPv6))
	}
}

func TestBuild_WithIPv6CIDRs(t *testing.T) {
	dir := t.TempDir()

	// Create a country file with IPv6 CIDRs
	content := `# China IPv6
2001:250::/32
2001:da8::/32
`
	os.WriteFile(filepath.Join(dir, "50-ban-CN.conf"), []byte(content), 0644)

	data, err := Build(dir, []string{"CN"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(data.IPv4) != 0 {
		t.Errorf("expected 0 IPv4 CIDRs, got %d", len(data.IPv4))
	}
	if len(data.IPv6) != 2 {
		t.Errorf("expected 2 IPv6 CIDRs, got %d: %v", len(data.IPv6), data.IPv6)
	}
}

func TestBuild_MixedIPv4IPv6(t *testing.T) {
	dir := t.TempDir()

	content := `# Mixed CIDRs
1.0.0.0/24
2001:250::/32
1.0.1.0/24
2001:da8::/32
`
	os.WriteFile(filepath.Join(dir, "50-ban-CN.conf"), []byte(content), 0644)

	data, err := Build(dir, []string{"CN"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(data.IPv4) != 2 {
		t.Errorf("expected 2 IPv4 CIDRs, got %d", len(data.IPv4))
	}
	if len(data.IPv6) != 2 {
		t.Errorf("expected 2 IPv6 CIDRs, got %d", len(data.IPv6))
	}
}

func TestBuild_SkipsCommentsAndEmptyLines(t *testing.T) {
	dir := t.TempDir()

	content := `# This is a comment
; This is also a comment

1.0.0.0/24

# Another comment
1.0.1.0/24
`
	os.WriteFile(filepath.Join(dir, "50-ban-CN.conf"), []byte(content), 0644)

	data, err := Build(dir, []string{"CN"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(data.IPv4) != 2 {
		t.Errorf("expected 2 IPv4 CIDRs (comments/blanks skipped), got %d", len(data.IPv4))
	}
}

func TestBuild_MultipleCountries(t *testing.T) {
	dir := t.TempDir()

	os.WriteFile(filepath.Join(dir, "50-ban-CN.conf"), []byte("1.0.0.0/24\n"), 0644)
	os.WriteFile(filepath.Join(dir, "50-ban-RU.conf"), []byte("5.0.0.0/24\n"), 0644)

	data, err := Build(dir, []string{"CN", "RU"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(data.IPv4) != 2 {
		t.Errorf("expected 2 IPv4 CIDRs from 2 countries, got %d", len(data.IPv4))
	}
}

func TestBuild_AutoDiscoverCountries(t *testing.T) {
	dir := t.TempDir()

	os.WriteFile(filepath.Join(dir, "50-ban-CN.conf"), []byte("1.0.0.0/24\n"), 0644)
	os.WriteFile(filepath.Join(dir, "50-ban-RU.conf"), []byte("5.0.0.0/24\n"), 0644)
	// Non-ban file should be ignored
	os.WriteFile(filepath.Join(dir, "40-whitelist-US.conf"), []byte("8.0.0.0/24\n"), 0644)

	// Pass nil countries to auto-discover from directory
	data, err := Build(dir, nil)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(data.IPv4) != 2 {
		t.Errorf("expected 2 IPv4 CIDRs from auto-discovered countries, got %d", len(data.IPv4))
	}
}

func TestBuild_CountryCodeNormalization(t *testing.T) {
	dir := t.TempDir()

	// File has uppercase country code
	os.WriteFile(filepath.Join(dir, "50-ban-CN.conf"), []byte("1.0.0.0/24\n"), 0644)

	// Pass lowercase -- loadCountry normalizes to uppercase
	data, err := Build(dir, []string{"cn"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(data.IPv4) != 1 {
		t.Errorf("expected 1 IPv4 CIDR (lowercase country code normalized), got %d", len(data.IPv4))
	}
}

func TestBuild_MissingCountryFile(t *testing.T) {
	dir := t.TempDir()

	// Request a country that has no file -- should not error (logs warning, continues)
	data, err := Build(dir, []string{"XX"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if data.Count != 0 {
		t.Errorf("expected 0 CIDRs for missing country, got %d", data.Count)
	}
}

func TestBuild_NonexistentDir(t *testing.T) {
	// With nil countries, Build tries to read the directory
	_, err := Build("/nonexistent/path/geoban.d", nil)
	if err == nil {
		t.Error("expected error for nonexistent directory")
	}
}

// =============================================================================
// loadCountry Tests
// =============================================================================

func TestLoadCountry_ValidFile(t *testing.T) {
	dir := t.TempDir()

	content := `1.0.0.0/24
1.0.1.0/24
`
	os.WriteFile(filepath.Join(dir, "50-ban-CN.conf"), []byte(content), 0644)

	data := &Stats{} // Just for reference, not using directly
	_ = data

	// Use the model.NewSetData via Build
	result, err := Build(dir, []string{"CN"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(result.IPv4) != 2 {
		t.Errorf("expected 2 IPv4 entries, got %d", len(result.IPv4))
	}
}

func TestLoadCountry_InvalidCIDR(t *testing.T) {
	dir := t.TempDir()

	// Mix of valid and invalid CIDRs
	content := `1.0.0.0/24
not-a-cidr
1.0.1.0/24
`
	os.WriteFile(filepath.Join(dir, "50-ban-CN.conf"), []byte(content), 0644)

	// Should still load valid CIDRs despite invalid ones
	result, err := Build(dir, []string{"CN"})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// Valid CIDRs should still be loaded (invalid ones logged as warnings)
	if len(result.IPv4) < 2 {
		t.Errorf("expected at least 2 valid IPv4 entries, got %d", len(result.IPv4))
	}
}

// =============================================================================
// File Naming Convention Tests
// =============================================================================

func TestFileNamingConvention_BanFiles(t *testing.T) {
	tests := []struct {
		name     string
		filename string
		isBan    bool
	}{
		{"valid_cn", "50-ban-CN.conf", true},
		{"valid_ru", "50-ban-RU.conf", true},
		{"whitelist", "40-whitelist-US.conf", false},
		{"wrong_prefix", "60-ban-CN.conf", false},
		{"wrong_extension", "50-ban-CN.txt", false},
		{"no_extension", "50-ban-CN", false},
		{"directory_listing", "README.md", false},
	}

	dir := t.TempDir()

	for _, tt := range tests {
		// Create the file
		os.WriteFile(filepath.Join(dir, tt.filename), []byte("# test"), 0644)
	}

	countries, _ := ListBannedCountries(dir)
	banned := make(map[string]bool)
	for _, c := range countries {
		banned[c] = true
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			// Extract expected country code from filename
			if tt.isBan {
				// The country code extraction pattern
				cc := tt.filename[len(BanFilePrefix) : len(tt.filename)-len(".conf")]
				if !banned[cc] {
					t.Errorf("expected %q to be detected as banned country", cc)
				}
			}
		})
	}
}
