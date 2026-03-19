// =============================================================================
// NFTBan - Test Fixtures
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="testutil_fixtures"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-19"
// meta:description="Shared test fixtures: IPs, CIDRs, ports, countries"
// meta:input="None"
// meta:output="None"
// meta:depends=""
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package testutil provides shared test utilities and fixtures for NFTBan tests.
package testutil

// =============================================================================
// IPv4 Test Addresses
// =============================================================================

// Well-known test IPs (RFC 5737 documentation ranges)
const (
	TestIPv4_1 = "192.0.2.1"     // TEST-NET-1
	TestIPv4_2 = "198.51.100.1"  // TEST-NET-2
	TestIPv4_3 = "203.0.113.1"   // TEST-NET-3
	TestIPv4_4 = "192.0.2.100"   // TEST-NET-1 another
	TestIPv4_5 = "198.51.100.50" // TEST-NET-2 another
)

// Loopback and special addresses
const (
	TestLoopback4 = "127.0.0.1"
	TestBroadcast = "255.255.255.255"
	TestZeroIP    = "0.0.0.0"
)

// Private range addresses (RFC 1918)
const (
	TestPrivate10  = "10.0.0.1"
	TestPrivate172 = "172.16.0.1"
	TestPrivate192 = "192.168.1.1"
)

// =============================================================================
// IPv6 Test Addresses
// =============================================================================

const (
	TestIPv6_1      = "2001:db8::1"    // Documentation range
	TestIPv6_2      = "2001:db8::2"    // Documentation range
	TestIPv6_3      = "2001:db8:1::1"  // Documentation range
	TestLoopback6   = "::1"            // IPv6 loopback
	TestIPv6LinkLoc = "fe80::1"        // Link-local
)

// =============================================================================
// CIDR Test Ranges
// =============================================================================

const (
	TestCIDR4_24 = "192.0.2.0/24"
	TestCIDR4_16 = "10.0.0.0/16"
	TestCIDR4_32 = "192.0.2.1/32"
	TestCIDR6_64 = "2001:db8::/64"
	TestCIDR6_48 = "2001:db8::/48"
)

// =============================================================================
// Port Numbers
// =============================================================================

const (
	TestPortSSH   = 22
	TestPortHTTP  = 80
	TestPortHTTPS = 443
	TestPortHigh  = 55000
	TestPortMax   = 65535
)

// =============================================================================
// Country Codes (ISO 3166-1 alpha-2)
// =============================================================================

var TestCountries = []string{"CN", "RU", "BR", "IN", "US"}
var TestAllowedCountries = []string{"US", "GB", "DE", "FR"}
var TestBlockedCountries = []string{"CN", "RU", "KP"}

// =============================================================================
// Ban Reasons
// =============================================================================

const (
	TestReasonBruteForce = "brute-force"
	TestReasonFeedMatch  = "threat-feed"
	TestReasonPortScan   = "port-scan"
	TestReasonDDoS       = "ddos"
	TestReasonManual     = "manual"
)

// =============================================================================
// Sample Data Sets
// =============================================================================

// SampleIPv4List returns a list of test IPv4 addresses for batch operations.
func SampleIPv4List(n int) []string {
	base := []string{
		"192.0.2.1", "192.0.2.2", "192.0.2.3", "192.0.2.4", "192.0.2.5",
		"198.51.100.1", "198.51.100.2", "198.51.100.3", "198.51.100.4", "198.51.100.5",
		"203.0.113.1", "203.0.113.2", "203.0.113.3", "203.0.113.4", "203.0.113.5",
	}
	if n > len(base) {
		n = len(base)
	}
	return base[:n]
}

// SampleCIDRList returns a list of test CIDR ranges for batch operations.
func SampleCIDRList(n int) []string {
	base := []string{
		"192.0.2.0/24", "198.51.100.0/24", "203.0.113.0/24",
		"10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16",
	}
	if n > len(base) {
		n = len(base)
	}
	return base[:n]
}

// InvalidIPs returns a list of malformed IP strings for negative testing.
func InvalidIPs() []string {
	return []string{
		"",
		"not-an-ip",
		"256.256.256.256",
		"192.168.1",
		"192.168.1.1.1",
		"-1.0.0.0",
		"abc.def.ghi.jkl",
		"192.168.1.1/33",
		"; rm -rf /",
		"$(whoami)",
		"<script>alert(1)</script>",
	}
}

// InvalidPorts returns a list of invalid port numbers for negative testing.
func InvalidPorts() []int {
	return []int{-1, -100, 65536, 70000, 100000}
}
