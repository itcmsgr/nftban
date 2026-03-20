// =============================================================================
// NFTBan - Tests for feed format parsing
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="feeds_parser_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Tests for feed format parsing"
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

package feeds

import (
	"net"
	"testing"
)

// =============================================================================
// ParseFeedLine tests
// =============================================================================

func TestParseFeedLine_SingleIPv4(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		wantIPv4 bool
		wantCIDR bool
		wantVal  string
	}{
		{"plain ipv4", "1.2.3.4", true, false, "1.2.3.4"},
		{"leading space", "  1.2.3.4", true, false, "1.2.3.4"},
		{"trailing space", "1.2.3.4  ", true, false, "1.2.3.4"},
		{"loopback", "127.0.0.1", true, false, "127.0.0.1"},
		{"high octets", "255.255.255.255", true, false, "255.255.255.255"},
		{"zero address", "0.0.0.0", true, false, "0.0.0.0"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			entry, err := ParseFeedLine(tt.input)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if entry == nil {
				t.Fatal("expected non-nil entry")
			}
			if entry.IPv4 != tt.wantIPv4 {
				t.Errorf("IPv4 = %v, want %v", entry.IPv4, tt.wantIPv4)
			}
			if entry.IsCIDR != tt.wantCIDR {
				t.Errorf("IsCIDR = %v, want %v", entry.IsCIDR, tt.wantCIDR)
			}
			if entry.Value != tt.wantVal {
				t.Errorf("Value = %q, want %q", entry.Value, tt.wantVal)
			}
		})
	}
}

func TestParseFeedLine_SingleIPv6(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		wantVal  string
	}{
		{"full ipv6", "2001:0db8:85a3:0000:0000:8a2e:0370:7334", "2001:db8:85a3::8a2e:370:7334"},
		{"compressed ipv6", "2001:db8::1", "2001:db8::1"},
		{"loopback ipv6", "::1", "::1"},
		{"link-local", "fe80::1", "fe80::1"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			entry, err := ParseFeedLine(tt.input)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if entry == nil {
				t.Fatal("expected non-nil entry")
			}
			if entry.IPv4 {
				t.Error("expected IPv6 (IPv4 = false)")
			}
			if entry.IsCIDR {
				t.Error("expected single IP, not CIDR")
			}
			if entry.Value != tt.wantVal {
				t.Errorf("Value = %q, want %q", entry.Value, tt.wantVal)
			}
		})
	}
}

func TestParseFeedLine_CIDR(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		wantIPv4 bool
		wantVal  string
	}{
		{"ipv4 /24", "192.168.1.0/24", true, "192.168.1.0/24"},
		{"ipv4 /32", "10.0.0.1/32", true, "10.0.0.1/32"},
		{"ipv4 /8", "10.0.0.0/8", true, "10.0.0.0/8"},
		{"ipv4 /16", "172.16.0.0/16", true, "172.16.0.0/16"},
		{"ipv6 /64", "2001:db8::/64", false, "2001:db8::/64"},
		{"ipv6 /128", "::1/128", false, "::1/128"},
		{"ipv6 /48", "2001:db8:abcd::/48", false, "2001:db8:abcd::/48"},
		// CIDR normalization: 192.168.1.100/24 -> 192.168.1.0/24
		{"ipv4 cidr normalized", "192.168.1.100/24", true, "192.168.1.0/24"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			entry, err := ParseFeedLine(tt.input)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if entry == nil {
				t.Fatal("expected non-nil entry")
			}
			if entry.IPv4 != tt.wantIPv4 {
				t.Errorf("IPv4 = %v, want %v", entry.IPv4, tt.wantIPv4)
			}
			if !entry.IsCIDR {
				t.Error("expected IsCIDR = true")
			}
			if entry.Value != tt.wantVal {
				t.Errorf("Value = %q, want %q", entry.Value, tt.wantVal)
			}
		})
	}
}

func TestParseFeedLine_Comments(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		wantNil bool
	}{
		{"hash comment", "# this is a comment", true},
		{"semicolon comment", "; this is a comment", true},
		{"empty line", "", true},
		{"whitespace only", "   ", true},
		{"inline hash comment", "1.2.3.4 # some comment", false},
		{"inline semicolon comment", "1.2.3.4 ; some comment", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			entry, err := ParseFeedLine(tt.input)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.wantNil && entry != nil {
				t.Errorf("expected nil entry, got %+v", entry)
			}
			if !tt.wantNil && entry == nil {
				t.Error("expected non-nil entry")
			}
		})
	}
}

func TestParseFeedLine_InlineComments(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		wantVal string
	}{
		{"hash after IP", "1.2.3.4 # bad actor", "1.2.3.4"},
		{"semicolon after IP", "10.0.0.1 ; blocked", "10.0.0.1"},
		{"hash after CIDR", "192.168.0.0/16 # private range", "192.168.0.0/16"},
		{"tab separated", "1.2.3.4\tbad actor", "1.2.3.4"},
		{"multiple fields", "1.2.3.4  reason  timestamp", "1.2.3.4"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			entry, err := ParseFeedLine(tt.input)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if entry == nil {
				t.Fatal("expected non-nil entry")
			}
			if entry.Value != tt.wantVal {
				t.Errorf("Value = %q, want %q", entry.Value, tt.wantVal)
			}
		})
	}
}

func TestParseFeedLine_InvalidInput(t *testing.T) {
	tests := []struct {
		name  string
		input string
	}{
		{"garbage text", "not-an-ip"},
		{"partial ipv4", "1.2.3"},
		{"out of range", "256.1.1.1"},
		{"invalid cidr", "1.2.3.4/33"},
		{"letters in ip", "1.2.3.abc"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			entry, err := ParseFeedLine(tt.input)
			if err == nil {
				t.Errorf("expected error for input %q, got entry: %+v", tt.input, entry)
			}
			if entry != nil {
				t.Errorf("expected nil entry for invalid input %q", tt.input)
			}
		})
	}
}

func TestParseFeedLine_IPRange(t *testing.T) {
	// ParseFeedLine returns start IP as /32 for backwards compatibility
	entry, err := ParseFeedLine("1.2.3.4-1.2.3.10")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if entry == nil {
		t.Fatal("expected non-nil entry for IP range")
	}
	if !entry.IPv4 {
		t.Error("expected IPv4")
	}
	if !entry.IsCIDR {
		t.Error("expected IsCIDR=true for range->CIDR conversion")
	}
	if entry.Value != "1.2.3.4/32" {
		t.Errorf("Value = %q, want %q", entry.Value, "1.2.3.4/32")
	}
}

func TestParseFeedLine_InvalidIPRange(t *testing.T) {
	_, err := ParseFeedLine("1.2.3.4-not-an-ip")
	if err == nil {
		t.Error("expected error for invalid IP range")
	}
}

// =============================================================================
// ParseFeedLineSilent tests
// =============================================================================

func TestParseFeedLineSilent(t *testing.T) {
	tests := []struct {
		name    string
		input   string
		wantNil bool
	}{
		{"valid ipv4", "1.2.3.4", false},
		{"valid cidr", "10.0.0.0/8", false},
		{"comment", "# comment", true},
		{"empty", "", true},
		{"invalid", "not-an-ip", true},
		{"invalid cidr", "1.2.3.4/33", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			entry := ParseFeedLineSilent(tt.input)
			if tt.wantNil && entry != nil {
				t.Errorf("expected nil, got %+v", entry)
			}
			if !tt.wantNil && entry == nil {
				t.Error("expected non-nil entry")
			}
		})
	}
}

// =============================================================================
// ParseFeedLineMulti tests
// =============================================================================

func TestParseFeedLineMulti_SingleIP(t *testing.T) {
	entries, err := ParseFeedLineMulti("1.2.3.4")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(entries))
	}
	if entries[0].Value != "1.2.3.4" {
		t.Errorf("Value = %q, want %q", entries[0].Value, "1.2.3.4")
	}
}

func TestParseFeedLineMulti_CIDR(t *testing.T) {
	entries, err := ParseFeedLineMulti("192.168.0.0/24")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(entries))
	}
	if entries[0].Value != "192.168.0.0/24" {
		t.Errorf("Value = %q, want %q", entries[0].Value, "192.168.0.0/24")
	}
	if !entries[0].IsCIDR {
		t.Error("expected IsCIDR = true")
	}
}

func TestParseFeedLineMulti_SmallRange(t *testing.T) {
	entries, err := ParseFeedLineMulti("1.2.3.4-1.2.3.6")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	// Range 1.2.3.4 to 1.2.3.6 = 3 IPs
	if len(entries) != 3 {
		t.Fatalf("expected 3 entries, got %d", len(entries))
	}

	expectedIPs := []string{"1.2.3.4/32", "1.2.3.5/32", "1.2.3.6/32"}
	for i, expected := range expectedIPs {
		if entries[i].Value != expected {
			t.Errorf("entries[%d].Value = %q, want %q", i, entries[i].Value, expected)
		}
		if !entries[i].IPv4 {
			t.Errorf("entries[%d].IPv4 = false, want true", i)
		}
		if !entries[i].IsCIDR {
			t.Errorf("entries[%d].IsCIDR = false, want true", i)
		}
	}
}

func TestParseFeedLineMulti_SkipLines(t *testing.T) {
	tests := []struct {
		name  string
		input string
	}{
		{"empty", ""},
		{"comment hash", "# comment"},
		{"comment semicolon", "; comment"},
		{"whitespace", "   "},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			entries, err := ParseFeedLineMulti(tt.input)
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if entries != nil {
				t.Errorf("expected nil for skip lines, got %v", entries)
			}
		})
	}
}

func TestParseFeedLineMulti_InvalidRange(t *testing.T) {
	_, err := ParseFeedLineMulti("1.2.3.4-not-valid")
	if err == nil {
		t.Error("expected error for invalid range")
	}
}

// =============================================================================
// IsIPv4 / IsIPv6 tests
// =============================================================================

func TestIsIPv4(t *testing.T) {
	tests := []struct {
		input string
		want  bool
	}{
		{"1.2.3.4", true},
		{"127.0.0.1", true},
		{"0.0.0.0", true},
		{"255.255.255.255", true},
		{"::1", false},
		{"2001:db8::1", false},
		{"invalid", false},
		{"", false},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			if got := IsIPv4(tt.input); got != tt.want {
				t.Errorf("IsIPv4(%q) = %v, want %v", tt.input, got, tt.want)
			}
		})
	}
}

func TestIsIPv6(t *testing.T) {
	tests := []struct {
		input string
		want  bool
	}{
		{"::1", true},
		{"2001:db8::1", true},
		{"fe80::1", true},
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
// Internal helper tests
// =============================================================================

func TestIncrementIP(t *testing.T) {
	tests := []struct {
		name string
		ip   string
		want string
	}{
		{"simple increment", "1.2.3.4", "1.2.3.5"},
		{"carry over", "1.2.3.255", "1.2.4.0"},
		{"double carry", "1.2.255.255", "1.3.0.0"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			ip := net.ParseIP(tt.ip)
			result := incrementIP(ip)
			if result.String() != tt.want {
				t.Errorf("incrementIP(%s) = %s, want %s", tt.ip, result.String(), tt.want)
			}
		})
	}
}

func TestBytesCompare(t *testing.T) {
	tests := []struct {
		name string
		a    string
		b    string
		want int
	}{
		{"equal", "1.2.3.4", "1.2.3.4", 0},
		{"a < b", "1.2.3.4", "1.2.3.5", -1},
		{"a > b", "1.2.3.5", "1.2.3.4", 1},
		{"different subnets", "10.0.0.1", "192.168.1.1", -1},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			a := net.ParseIP(tt.a)
			b := net.ParseIP(tt.b)
			got := bytesCompare(a, b)
			if got != tt.want {
				t.Errorf("bytesCompare(%s, %s) = %d, want %d", tt.a, tt.b, got, tt.want)
			}
		})
	}
}
