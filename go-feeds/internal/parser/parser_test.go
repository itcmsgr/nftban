package parser

import (
	"net/netip"
	"testing"
)

func TestParseIPs(t *testing.T) {
	input := []byte(`
# This is a comment
192.0.2.1
192.0.2.0/24

2001:db8::1
2001:db8::/32
invalid-line-should-be-skipped
`)

	prefixes, err := ParseIPs(input)
	if err != nil {
		t.Fatalf("ParseIPs failed: %v", err)
	}

	expected := 4 // 2 IPv4 + 2 IPv6
	if len(prefixes) != expected {
		t.Errorf("Expected %d prefixes, got %d", expected, len(prefixes))
	}

	// Check first prefix
	if prefixes[0].String() != "192.0.2.1/32" {
		t.Errorf("First prefix: expected 192.0.2.1/32, got %s", prefixes[0])
	}
}

func TestDeduplicate(t *testing.T) {
	p1 := netip.MustParsePrefix("192.0.2.1/32")
	p2 := netip.MustParsePrefix("192.0.2.1/32") // Duplicate
	p3 := netip.MustParsePrefix("192.0.2.2/32")

	input := []netip.Prefix{p1, p2, p3}
	result := Deduplicate(input)

	expected := 2
	if len(result) != expected {
		t.Errorf("Expected %d unique prefixes, got %d", expected, len(result))
	}
}

func TestSplitIPv4v6(t *testing.T) {
	prefixes := []netip.Prefix{
		netip.MustParsePrefix("192.0.2.1/32"),
		netip.MustParsePrefix("192.0.2.0/24"),
		netip.MustParsePrefix("2001:db8::1/128"),
		netip.MustParsePrefix("2001:db8::/32"),
	}

	v4, v6 := SplitIPv4v6(prefixes)

	if len(v4) != 2 {
		t.Errorf("Expected 2 IPv4 prefixes, got %d", len(v4))
	}
	if len(v6) != 2 {
		t.Errorf("Expected 2 IPv6 prefixes, got %d", len(v6))
	}
}
