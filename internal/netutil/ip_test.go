// =============================================================================
// NFTBan - Tests for IP address utilities
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="netutil_ip_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for IP address utilities"
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

package netutil

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"testing"
)

// =============================================================================
// IsIPv4 tests
// =============================================================================

func TestIsIPv4(t *testing.T) {
	tests := []struct {
		input string
		want  bool
	}{
		{"1.2.3.4", true},
		{"0.0.0.0", true},
		{"255.255.255.255", true},
		{"127.0.0.1", true},
		{"192.168.1.1", true},
		{"::1", false},
		{"2001:db8::1", false},
		{"invalid", false},
		{"", false},
		{"1.2.3", false},
		{"1.2.3.4.5", false},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			if got := IsIPv4(tt.input); got != tt.want {
				t.Errorf("IsIPv4(%q) = %v, want %v", tt.input, got, tt.want)
			}
		})
	}
}

// =============================================================================
// IsIPv6 tests
// =============================================================================

func TestIsIPv6(t *testing.T) {
	tests := []struct {
		input string
		want  bool
	}{
		{"::1", true},
		{"2001:db8::1", true},
		{"fe80::1", true},
		{"2001:0db8:85a3:0000:0000:8a2e:0370:7334", true},
		{"1.2.3.4", false},
		{"invalid", false},
		{"", false},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			if got := IsIPv6(tt.input); got != tt.want {
				t.Errorf("IsIPv6(%q) = %v, want %v", tt.input, got, tt.want)
			}
		})
	}
}

// =============================================================================
// IsCIDR tests
// =============================================================================

func TestIsCIDR(t *testing.T) {
	tests := []struct {
		input string
		want  bool
	}{
		{"192.168.0.0/24", true},
		{"10.0.0.0/8", true},
		{"0.0.0.0/0", true},
		{"2001:db8::/32", true},
		{"::1/128", true},
		{"1.2.3.4", false},
		{"invalid", false},
		{"1.2.3.4/33", false},
		{"", false},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			if got := IsCIDR(tt.input); got != tt.want {
				t.Errorf("IsCIDR(%q) = %v, want %v", tt.input, got, tt.want)
			}
		})
	}
}

// =============================================================================
// IsValidIP tests
// =============================================================================

func TestIsValidIP(t *testing.T) {
	tests := []struct {
		input string
		want  bool
	}{
		{"1.2.3.4", true},
		{"::1", true},
		{"2001:db8::1", true},
		{"invalid", false},
		{"", false},
		{"1.2.3", false},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			if got := IsValidIP(tt.input); got != tt.want {
				t.Errorf("IsValidIP(%q) = %v, want %v", tt.input, got, tt.want)
			}
		})
	}
}

// =============================================================================
// IPContainedInCIDR tests
// =============================================================================

func TestIPContainedInCIDR(t *testing.T) {
	tests := []struct {
		name string
		ip   string
		cidr string
		want bool
	}{
		{"ipv4 in range", "192.168.1.100", "192.168.1.0/24", true},
		{"ipv4 not in range", "192.168.2.1", "192.168.1.0/24", false},
		{"ipv4 network address", "10.0.0.0", "10.0.0.0/8", true},
		{"ipv4 broadcast", "10.255.255.255", "10.0.0.0/8", true},
		{"ipv6 in range", "2001:db8::1", "2001:db8::/32", true},
		{"ipv6 not in range", "2001:db9::1", "2001:db8::/32", false},
		{"invalid ip", "invalid", "192.168.0.0/24", false},
		{"invalid cidr", "192.168.1.1", "invalid", false},
		{"empty ip", "", "192.168.0.0/24", false},
		{"empty cidr", "1.2.3.4", "", false},
		{"exact match /32", "1.2.3.4", "1.2.3.4/32", true},
		{"loopback in range", "127.0.0.1", "127.0.0.0/8", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := IPContainedInCIDR(tt.ip, tt.cidr); got != tt.want {
				t.Errorf("IPContainedInCIDR(%q, %q) = %v, want %v",
					tt.ip, tt.cidr, got, tt.want)
			}
		})
	}
}

// =============================================================================
// GetIPFamily tests
// =============================================================================

func TestGetIPFamily(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"1.2.3.4", "ipv4"},
		{"192.168.1.1", "ipv4"},
		{"::1", "ipv6"},
		{"2001:db8::1", "ipv6"},
		{"invalid", ""},
		{"", ""},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			if got := GetIPFamily(tt.input); got != tt.want {
				t.Errorf("GetIPFamily(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

// =============================================================================
// NormalizeIP tests
// =============================================================================

func TestNormalizeIP(t *testing.T) {
	tests := []struct {
		input string
		want  string
	}{
		{"1.2.3.4", "1.2.3.4"},
		{"127.0.0.1", "127.0.0.1"},
		// IPv6 normalization
		{"2001:0db8:0000:0000:0000:0000:0000:0001", "2001:db8::1"},
		{"::1", "::1"},
		// Invalid IPs return original
		{"invalid", "invalid"},
		{"", ""},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			if got := NormalizeIP(tt.input); got != tt.want {
				t.Errorf("NormalizeIP(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

// =============================================================================
// IsPrivateIP tests
// =============================================================================

func TestIsPrivateIP(t *testing.T) {
	tests := []struct {
		input string
		want  bool
	}{
		// RFC1918 IPv4
		{"10.0.0.1", true},
		{"10.255.255.255", true},
		{"172.16.0.1", true},
		{"172.31.255.255", true},
		{"192.168.0.1", true},
		{"192.168.255.255", true},
		// Loopback
		{"127.0.0.1", true},
		{"127.255.255.255", true},
		// Public IPv4
		{"8.8.8.8", false},
		{"1.1.1.1", false},
		{"203.0.113.1", false},
		// IPv6 private
		{"::1", true},
		{"fc00::1", true},
		{"fe80::1", true},
		// IPv6 public
		{"2001:db8::1", false},
		// Invalid
		{"invalid", false},
		{"", false},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			if got := IsPrivateIP(tt.input); got != tt.want {
				t.Errorf("IsPrivateIP(%q) = %v, want %v", tt.input, got, tt.want)
			}
		})
	}
}

// =============================================================================
// IsPublicIP tests
// =============================================================================

func TestIsPublicIP(t *testing.T) {
	tests := []struct {
		input string
		want  bool
	}{
		{"8.8.8.8", true},
		{"1.1.1.1", true},
		{"10.0.0.1", false},
		{"192.168.1.1", false},
		{"127.0.0.1", false},
		{"::1", false},
		{"invalid", false},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			if got := IsPublicIP(tt.input); got != tt.want {
				t.Errorf("IsPublicIP(%q) = %v, want %v", tt.input, got, tt.want)
			}
		})
	}
}

// =============================================================================
// ValidateAndNormalizeIP tests
// =============================================================================

func TestValidateAndNormalizeIP(t *testing.T) {
	tests := []struct {
		name       string
		input      string
		wantIP     string
		wantIsIPv4 bool
		wantErr    bool
	}{
		{"ipv4", "1.2.3.4", "1.2.3.4", true, false},
		{"ipv4 padded", "  1.2.3.4  ", "1.2.3.4", true, false},
		{"ipv6", "2001:db8::1", "2001:db8::1", false, false},
		{"ipv4 cidr", "10.0.0.0/8", "10.0.0.0/8", true, false},
		{"ipv6 cidr", "2001:db8::/32", "2001:db8::/32", false, false},
		{"cidr normalized", "192.168.1.100/24", "192.168.1.0/24", true, false},
		{"empty", "", "", false, true},
		{"spaces only", "   ", "", false, true},
		{"invalid", "not-an-ip", "", false, true},
		{"invalid cidr", "1.2.3.4/33", "", false, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			gotIP, gotIsIPv4, err := ValidateAndNormalizeIP(tt.input)
			if (err != nil) != tt.wantErr {
				t.Errorf("error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if err != nil {
				return
			}
			if gotIP != tt.wantIP {
				t.Errorf("ip = %q, want %q", gotIP, tt.wantIP)
			}
			if gotIsIPv4 != tt.wantIsIPv4 {
				t.Errorf("isIPv4 = %v, want %v", gotIsIPv4, tt.wantIsIPv4)
			}
		})
	}
}

// =============================================================================
// ParseIP / ParseCIDR tests
// =============================================================================

func TestParseIP(t *testing.T) {
	// Valid IPs
	if ip := ParseIP("1.2.3.4"); ip == nil {
		t.Error("ParseIP(1.2.3.4) returned nil")
	}
	if ip := ParseIP("::1"); ip == nil {
		t.Error("ParseIP(::1) returned nil")
	}
	// Invalid IP
	if ip := ParseIP("invalid"); ip != nil {
		t.Errorf("ParseIP(invalid) returned %v, want nil", ip)
	}
}

func TestParseCIDR(t *testing.T) {
	ip, ipNet, err := ParseCIDR("192.168.1.0/24")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ip == nil || ipNet == nil {
		t.Fatal("expected non-nil ip and ipNet")
	}

	_, _, err = ParseCIDR("invalid")
	if err == nil {
		t.Error("expected error for invalid CIDR")
	}
}

// =============================================================================
// GetClientIP tests
// =============================================================================

func TestGetClientIP_DirectConnection(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "8.8.8.8:12345"
	// External IP should NOT trust proxy headers
	req.Header.Set("X-Forwarded-For", "1.2.3.4, 5.6.7.8")
	req.Header.Set("X-Real-IP", "1.2.3.4")

	got := GetClientIP(req)
	if got != "8.8.8.8" {
		t.Errorf("GetClientIP = %q, want %q (should NOT trust proxy headers from external)", got, "8.8.8.8")
	}
}

func TestGetClientIP_TrustedProxy_XForwardedFor(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "127.0.0.1:12345"
	req.Header.Set("X-Forwarded-For", "1.2.3.4, 10.0.0.1")

	got := GetClientIP(req)
	if got != "1.2.3.4" {
		t.Errorf("GetClientIP = %q, want %q (should trust XFF from loopback)", got, "1.2.3.4")
	}
}

func TestGetClientIP_TrustedProxy_XRealIP(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "192.168.1.1:12345"
	req.Header.Set("X-Real-IP", "5.6.7.8")

	got := GetClientIP(req)
	if got != "5.6.7.8" {
		t.Errorf("GetClientIP = %q, want %q (should trust X-Real-IP from private)", got, "5.6.7.8")
	}
}

func TestGetClientIP_NoHeaders(t *testing.T) {
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	req.RemoteAddr = "1.2.3.4:12345"

	got := GetClientIP(req)
	if got != "1.2.3.4" {
		t.Errorf("GetClientIP = %q, want %q", got, "1.2.3.4")
	}
}

// =============================================================================
// isTrustedProxy tests
// =============================================================================

func TestIsTrustedProxy(t *testing.T) {
	tests := []struct {
		ip   string
		want bool
	}{
		{"127.0.0.1", true},
		{"::1", true},
		{"10.0.0.1", true},
		{"192.168.1.1", true},
		{"172.16.0.1", true},
		{"8.8.8.8", false},
		{"1.1.1.1", false},
		{"invalid", false},
	}

	for _, tt := range tests {
		t.Run(tt.ip, func(t *testing.T) {
			if got := isTrustedProxy(tt.ip); got != tt.want {
				t.Errorf("isTrustedProxy(%q) = %v, want %v", tt.ip, got, tt.want)
			}
		})
	}
}

// =============================================================================
// IsIPWhitelisted tests (uses temp files)
// =============================================================================

func TestIsIPWhitelisted_SingleIP(t *testing.T) {
	dir := t.TempDir()
	wlFile := filepath.Join(dir, "whitelist.conf")
	os.WriteFile(wlFile, []byte("1.2.3.4\n5.6.7.8\n# comment\n"), 0644)

	// IP in whitelist
	ok, err := IsIPWhitelisted("1.2.3.4", wlFile)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !ok {
		t.Error("expected 1.2.3.4 to be whitelisted")
	}

	// IP not in whitelist
	ok, err = IsIPWhitelisted("10.0.0.1", wlFile)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ok {
		t.Error("expected 10.0.0.1 to NOT be whitelisted")
	}
}

func TestIsIPWhitelisted_CIDR(t *testing.T) {
	dir := t.TempDir()
	wlFile := filepath.Join(dir, "whitelist.conf")
	os.WriteFile(wlFile, []byte("192.168.0.0/16\n"), 0644)

	// IP in CIDR range
	ok, err := IsIPWhitelisted("192.168.1.100", wlFile)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !ok {
		t.Error("expected 192.168.1.100 to be in whitelist CIDR")
	}

	// IP not in CIDR range
	ok, err = IsIPWhitelisted("10.0.0.1", wlFile)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ok {
		t.Error("expected 10.0.0.1 to NOT be in whitelist CIDR")
	}
}

func TestIsIPWhitelisted_FileNotFound(t *testing.T) {
	ok, err := IsIPWhitelisted("1.2.3.4", "/tmp/nonexistent-whitelist-12345")
	if err != nil {
		t.Fatalf("unexpected error (should return false, nil): %v", err)
	}
	if ok {
		t.Error("expected false when file does not exist")
	}
}

func TestIsIPWhitelisted_InvalidIP(t *testing.T) {
	dir := t.TempDir()
	wlFile := filepath.Join(dir, "whitelist.conf")
	os.WriteFile(wlFile, []byte("1.2.3.4\n"), 0644)

	ok, err := IsIPWhitelisted("invalid", wlFile)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if ok {
		t.Error("expected false for invalid IP")
	}
}
