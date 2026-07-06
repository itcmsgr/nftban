// SPDX-License-Identifier: MPL-2.0
// meta:name="nftbackend/never_ban_add_element_l3a_test" meta:type="test" meta:version="1.0.0" meta:owner="Antonios Voulvoulis <contact@nftban.com>" meta:description="L3a: never-ban is a target-set + element invariant, not a verb property. Proves backend.AddElement refuses a single exempt IP into an enforcement (drop) set (v4+v6, exact+CIDR-covered), that the AddElementExemptSkips counter increments, that whitelist/port/public-IP/CIDR adds are NOT blocked, and that backend.Ban still refuses exempt IPs (regression). Uses the package snapshot() helper for a fixed exempt set; the reject path returns before any netlink work, so it is hermetic (no nft/root)."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package nftbackend

import (
	"context"
	"errors"
	"testing"
)

func TestIsEnforcementSet_L3a(t *testing.T) {
	for _, s := range []string{
		"blacklist_manual_ipv4", "blacklist_manual_ipv6", "blacklist_ipv4", "blacklist_ipv6",
		"ddos_blocked", "http_bot_ban", "http_bot_ban6", "http_bot_emergency", "http_bot_emergency6",
		// add_element-reachable drop sets discovered during implementation:
		"geoban_ipv4", "geoban_ipv6", "persistent_offenders_ipv4", "persistent_offenders_ipv6",
		"bogon_ipv4", "bogon_ipv6",
	} {
		if !IsEnforcementSet(s) {
			t.Errorf("%s must be an enforcement set", s)
		}
	}
	for _, s := range []string{"whitelist_ipv4", "whitelist_ipv6", "ssh_ports", "tcp_ports_in", "tcp_ports_out", ""} {
		if IsEnforcementSet(s) {
			t.Errorf("%s must NOT be an enforcement set", s)
		}
	}
}

// The core invariant: reject == (enforcement set) AND (single exempt IP). No verb involved.
func TestExemptAddRejection_L3a(t *testing.T) {
	b := &Backend{}
	b.exempt = snapshot([]string{"10.0.0.5"}, []string{"2001:db8::/48"})
	cases := []struct {
		set, el string
		want    bool
	}{
		{"blacklist_manual_ipv4", "10.0.0.5", true},   // exact exempt v4 → enforcement: REJECT
		{"blacklist_manual_ipv6", "2001:db8::9", true}, // cidr-covered exempt v6: REJECT
		{"blacklist_ipv4", "10.0.0.5", true},           // interval enforcement: REJECT
		{"ddos_blocked", "10.0.0.5", true},             // ddos drop set: REJECT
		{"geoban_ipv4", "10.0.0.5", true},              // geoban drop set (add_element-reachable): REJECT
		{"persistent_offenders_ipv6", "2001:db8::9", true}, // persistent-offenders drop set: REJECT
		{"bogon_ipv4", "10.0.0.5", true},               // bogon drop set: REJECT
		{"whitelist_ipv4", "10.0.0.5", false},          // whitelist add of exempt IP: ALLOW
		{"blacklist_manual_ipv4", "203.0.113.9", false}, // normal public IP: ALLOW
		{"blacklist_ipv4", "10.0.0.0/8", false},        // CIDR input (IsExempt=false): ALLOW
		{"ssh_ports", "10.0.0.5", false},               // port set (not enforcement): ALLOW
	}
	for _, c := range cases {
		got, _ := b.exemptAddRejection(c.set, c.el)
		if got != c.want {
			t.Errorf("exemptAddRejection(%q,%q)=%v want %v", c.set, c.el, got, c.want)
		}
	}
}

// backend.AddElement refuses exempt IPs into enforcement sets and returns before any
// netlink work (so the counter increments and no set is mutated).
func TestAddElement_RejectsExemptBeforeNetlink_L3a(t *testing.T) {
	b := &Backend{}
	b.exempt = snapshot([]string{"10.0.0.5"}, []string{"2001:db8::/48"})

	if err := b.AddElement(context.Background(), AddElementRequest{Table: "ip nftban", Set: "blacklist_manual_ipv4", Element: "10.0.0.5"}); !errors.Is(err, ErrNeverBanExempt) {
		t.Fatalf("v4 exempt add: want ErrNeverBanExempt, got %v", err)
	}
	if err := b.AddElement(context.Background(), AddElementRequest{Table: "ip6 nftban", Set: "blacklist_manual_ipv6", Element: "2001:db8::9"}); !errors.Is(err, ErrNeverBanExempt) {
		t.Fatalf("v6 exempt add: want ErrNeverBanExempt, got %v", err)
	}
	if b.stats.AddElementExemptSkips != 2 {
		t.Fatalf("AddElementExemptSkips=%d, want 2", b.stats.AddElementExemptSkips)
	}
}

// Regression: backend.Ban still refuses exempt IPs (the original F2 guard is unchanged).
func TestBan_StillRejectsExempt_L3a(t *testing.T) {
	b := &Backend{}
	b.exempt = snapshot([]string{"10.0.0.5"}, []string{"2001:db8::/48"})
	for _, ip := range []string{"10.0.0.5", "2001:db8::9"} {
		res, err := b.Ban(context.Background(), BanRequest{IP: ip, Source: "test"})
		if err != nil {
			t.Fatalf("Ban(%s) unexpected err: %v", ip, err)
		}
		if res == nil || !res.Exempt {
			t.Fatalf("Ban(%s) must be refused as exempt", ip)
		}
	}
}
