// SPDX-License-Identifier: MPL-2.0
// meta:name="netutil/enforcement_class_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="v1.220.2 enforcement address-class guard: EnforcementClassReject + IsAbsolutelyNonBannable across loopback/unspecified/multicast/RFC1918/ULA/link-local/CGNAT/doc/reserved (reject) vs public v4+v6 (allow); IPv4-mapped normalized; CIDR/blank pass. Pure, no netlink."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// v1.220.2: enforcement address-class guard tests. RBL/reputation + enforcement are
// public-only; loopback/unspecified/multicast are non-overridably non-bannable, and the
// other non-public classes are default-reject. Public routable addresses pass; CIDR/blank
// pass (callers validate those). IPv4/IPv6 symmetric.
package netutil

import "testing"

func TestEnforcementClassReject(t *testing.T) {
	cases := []struct {
		ip     string
		reject bool
		note   string
	}{
		// absolute non-bannable (non-overridable)
		{"127.0.0.1", true, "IPv4 loopback"},
		{"127.0.1.1", true, "IPv4 loopback (Debian hostname)"},
		{"::1", true, "IPv6 loopback"},
		{"0.0.0.0", true, "IPv4 unspecified"},
		{"::", true, "IPv6 unspecified"},
		{"224.0.0.1", true, "IPv4 multicast"},
		{"239.255.255.250", true, "IPv4 multicast"},
		{"ff02::1", true, "IPv6 multicast"},
		// non-public (default reject)
		{"10.0.0.5", true, "RFC1918"},
		{"172.16.5.5", true, "RFC1918"},
		{"192.168.1.10", true, "RFC1918"},
		{"169.254.1.2", true, "IPv4 link-local"},
		{"fe80::1", true, "IPv6 link-local"},
		{"fc00::1", true, "ULA"},
		{"fd12::9", true, "ULA (fd..)"},
		{"100.64.0.1", true, "CGNAT"},
		{"192.0.2.1", true, "documentation"},
		{"198.51.100.7", true, "documentation"},
		{"203.0.113.9", true, "documentation"},
		{"2001:db8::1", true, "documentation (IPv6)"},
		{"240.0.0.1", true, "reserved"},
		{"198.18.0.1", true, "benchmark"},
		// public routable — MUST pass
		{"8.8.4.4", false, "public IPv4"},
		{"46.225.150.67", false, "public IPv4"},
		{"2a01:4f8:c014:5ee1::1", false, "public IPv6"},
		{"2606:4700:4700::1111", false, "public IPv6"},
		// IPv4-mapped IPv6 loopback normalizes to loopback
		{"::ffff:127.0.0.1", true, "IPv4-mapped loopback"},
		{"::ffff:8.8.4.4", false, "IPv4-mapped public"},
		// non-bare-IP tokens pass (CIDR/range/blank) — feed CIDRs must not be rejected here
		{"1.2.3.0/24", false, "public CIDR (caller handles)"},
		{"", false, "blank"},
		{"not-an-ip", false, "garbage"},
	}
	for _, c := range cases {
		reject, reason := EnforcementClassReject(c.ip)
		if reject != c.reject {
			t.Errorf("EnforcementClassReject(%q)=%v want %v (%s) reason=%q", c.ip, reject, c.reject, c.note, reason)
		}
		if reject && reason == "" {
			t.Errorf("EnforcementClassReject(%q) rejected with empty reason", c.ip)
		}
	}
}

func TestIsAbsolutelyNonBannable(t *testing.T) {
	absolute := []string{"127.0.0.1", "127.0.1.1", "::1", "0.0.0.0", "::", "224.0.0.1", "ff02::1", "::ffff:127.0.0.1"}
	for _, ip := range absolute {
		if !IsAbsolutelyNonBannable(ip) {
			t.Errorf("IsAbsolutelyNonBannable(%q)=false, want true", ip)
		}
	}
	// non-public-but-not-absolute (private/ULA/etc) are NOT absolute — they are only
	// default-reject (a future explicit LAN feature could opt in).
	notAbsolute := []string{"10.0.0.5", "fc00::1", "169.254.1.2", "100.64.0.1", "8.8.4.4", "2a01:4f8::1", "1.2.3.0/24", ""}
	for _, ip := range notAbsolute {
		if IsAbsolutelyNonBannable(ip) {
			t.Errorf("IsAbsolutelyNonBannable(%q)=true, want false", ip)
		}
	}
}
