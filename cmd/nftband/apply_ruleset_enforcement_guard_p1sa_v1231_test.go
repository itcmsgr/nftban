// =============================================================================
// NFTBan - P1S-A: apply_ruleset enforcement-set element-add retirement
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="nftband_apply_ruleset_enforcement_guard_p1sa"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-09-14"
// meta:description="P1S-A path 11. apply_ruleset handed a file to `nft -f` under a PATH restriction only, so the legacy additive fallback in nft_ipc_sync_or_apply could write feed/geoban CIDRs into blacklist_ipv4/_ipv6 with no never-ban authority of any kind. The fallback is retired at the daemon. These rows lock BOTH directions: an enforcement-set element add is detected in every shape the shipped producers emit (feeds writes the set header and the elements on separate lines; geoban writes an entire country on ONE line), and every other apply_ruleset caller — delete element on a blacklist, whitelist/port element adds, chain/rule/set-definition fragments, the full rendered ruleset — is NOT caught. Hermetic: temp files only, no nft, no daemon, no root."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func p1saWriteFragment(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "fragment.nft")
	if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
		t.Fatalf("INVALID_TEST: cannot write fixture: %v", err)
	}
	return p
}

// TestP1SA_ApplyRulesetRejectsEnforcementElementAdds covers the shapes the two
// shipped producers of such a fragment actually emit.
func TestP1SA_ApplyRulesetRejectsEnforcementElementAdds(t *testing.T) {
	// geoban writes one `add element` with the whole country inline, and that line
	// can be megabytes long — the scanner must not need to buffer it.
	geobanOneLine := "add element ip nftban blacklist_ipv4 { " +
		strings.Repeat("185.199.108.0/24, ", 20000) + "203.0.113.0/24 }\n"

	cases := []struct {
		name string
		body string
		want string
	}{
		{
			name: "feeds fragment: header and elements on separate lines",
			body: "#!/usr/sbin/nft -f\n# NFTBan Feed Sync\n\nadd element ip nftban blacklist_ipv4 {\n185.199.108.153/32,\n198.100.44.0/24\n}\n",
			want: "blacklist_ipv4",
		},
		{
			name: "feeds fragment: IPv6",
			body: "add element ip6 nftban blacklist_ipv6 {\n2606:4700:4700::1111/128\n}\n",
			want: "blacklist_ipv6",
		},
		{
			name: "geoban fragment: entire country on one very long line",
			body: geobanOneLine,
			want: "blacklist_ipv4",
		},
		{
			name: "leading whitespace does not hide the statement",
			body: "\t  add element ip nftban blacklist_manual_ipv4 { 1.2.3.4 }\n",
			want: "blacklist_manual_ipv4",
		},
		{
			name: "enforcement add buried after legitimate statements",
			body: "add rule ip nftban input ip saddr @blacklist_ipv4 drop\nadd element ip nftban whitelist_ipv4 { 10.0.0.1 }\nadd element ip nftban ddos_blocked { 9.9.9.9 }\n",
			want: "ddos_blocked",
		},
		{
			name: "final line without a trailing newline",
			body: "add element ip nftban blacklist_ipv4 { 1.2.3.4 }",
			want: "blacklist_ipv4",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			set, found, err := applyRulesetEnforcementElementAdd(p1saWriteFragment(t, tc.body))
			if err != nil {
				t.Fatalf("INVALID_TEST: scanner errored: %v; product verdict NONE", err)
			}
			if !found {
				t.Fatalf("P1S-A BYPASS: an enforcement-set element add reached `nft -f` unguarded — the raw fragment path has no never-ban authority (expected set %q)", tc.want)
			}
			if set != tc.want {
				t.Errorf("reported set %q, want %q", set, tc.want)
			}
		})
	}
}

// TestP1SA_ApplyRulesetAllowsEverythingElse is the other half of the guard: over-
// rejecting here means a fragment the firewall needs is refused, which is an outage,
// not a safety margin. Every row is a shape a shipped caller really applies.
func TestP1SA_ApplyRulesetAllowsEverythingElse(t *testing.T) {
	cases := []struct {
		name string
		body string
	}{
		{
			// cmd_flush removes feed/geoban entries. Removal can never lock anyone out.
			name: "delete element on a blacklist (cmd_flush)",
			body: "delete element ip nftban blacklist_ipv4 { 1.2.3.0/24, 2.3.4.0/24 }\n",
		},
		{
			// nftban_trust writes provider CIDRs to the whitelist sets.
			name: "whitelist element add (trust)",
			body: "add element ip nftban whitelist_ipv4 { 185.199.108.0/24 }\nadd element ip6 nftban whitelist_ipv6 { 2606:4700::/32 }\n",
		},
		{
			name: "port element add",
			body: "add element ip nftban tcp_ports_in { 8080 }\n",
		},
		{
			// nftban_ddos_suricata creates its set and drop rule.
			name: "set definition and rule fragment (ddos-suricata)",
			body: "add set ip nftban ddos_blocked { type ipv4_addr; flags timeout; }\nadd rule ip nftban input ip saddr @ddos_blocked counter drop comment \"DDoS Suricata blocked\"\n",
		},
		{
			// cmd_port adds per-IP access chains and rules.
			name: "chain and rule fragment (cmd_port)",
			body: "add chain ip nftban input { type filter hook input priority 0; policy drop; }\nadd rule ip nftban input ip saddr . tcp dport @port_allow_tcp_ipv4 accept\n",
		},
		{
			// cmd_nftables applies the whole rendered ruleset. Inline set literals are
			// `elements = { ... }` declarations, not `add element` statements.
			name: "full rendered ruleset with inline set literals",
			body: "table ip nftban {\n  set blacklist_ipv4 {\n    type ipv4_addr\n    flags interval\n  }\n  set tcp_ports_in {\n    type inet_service\n    elements = { 22, 80, 443 }\n  }\n  chain input {\n    ip saddr @blacklist_ipv4 counter drop\n    ct state established,related accept\n  }\n}\n",
		},
		{
			name: "empty file",
			body: "",
		},
		{
			name: "comments only",
			body: "# add element ip nftban blacklist_ipv4 { 1.2.3.4 }\n",
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			set, found, err := applyRulesetEnforcementElementAdd(p1saWriteFragment(t, tc.body))
			if err != nil {
				t.Fatalf("INVALID_TEST: scanner errored: %v; product verdict NONE", err)
			}
			if found {
				t.Errorf("OVER-REJECTION: a legitimate fragment was refused as an enforcement element add (set=%q) — refusing this is a firewall outage, not a safety margin", set)
			}
		})
	}
}

// TestP1SA_ApplyRulesetUnreadableIsNotClearance: a file the daemon cannot inspect is
// not a file it may apply unexamined.
func TestP1SA_ApplyRulesetUnreadableIsNotClearance(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "does-not-exist.nft")
	if _, _, err := applyRulesetEnforcementElementAdd(missing); err == nil {
		t.Errorf("an unreadable ruleset file must surface an error, not a silent 'no enforcement add found'")
	}
}
