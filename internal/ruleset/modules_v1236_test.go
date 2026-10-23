// =============================================================================
// NFTBan v1.236 - step B: live module objects carried through a replacement
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="ruleset-modules-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-23"
// meta:description="ExtractModules carries only enabled modules' objects (set elements stripped, meters declared empty, a map with elements refused) and records each jump with the anchor after it; Compose places every jump before its anchor in the schema chain, adds the marker and the blocks, and refuses an unplaceable jump; a comment mentioning jump does not fake one."
// meta:inventory.privileges="none"
// =============================================================================
package ruleset

import (
	"strings"
	"testing"
)

const liveIP = `table ip nftban {
	comment "nftban-gen=old"
	set blacklist_ipv4 {
		type ipv4_addr
		flags interval,timeout
		elements = { 23.129.97.10 }
	}
	set ddos_ban_1h {
		type ipv4_addr
		flags timeout
		timeout 1h
		elements = { 45.155.205.9 timeout 1h expires 59m10s,
			     45.155.205.10 timeout 1h expires 30m }
	}
	set ddos_limit_10s {
		type ipv4_addr
		size 65535
		flags dynamic,timeout
		timeout 10s
	}
	set http_bot_meter {
		type ipv4_addr
		flags dynamic
	}
	chain input {
		type filter hook input priority filter; policy drop;
		counter name "anchor_trusted" comment "NFTBAN_ANCHOR:ANCHOR_TRUSTED"
		jump ddos_penalty comment "DDoS penalty ladder"
		counter name "anchor_established" comment "NFTBAN_ANCHOR:ANCHOR_ESTABLISHED"
		jump portscan_detection comment "a comment that says jump nowhere"
		counter name "anchor_detect" comment "NFTBAN_ANCHOR:ANCHOR_DETECT"
		jump ddos_prefix comment "Prefix"
		jump ddos_protection comment "Classic"
		counter name "anchor_service" comment "NFTBAN_ANCHOR:ANCHOR_SERVICE"
	}
	chain ddos_penalty {
		ip saddr @ddos_ban_1h drop
	}
	chain portscan_detection {
		tcp flags syn / syn,ack,fin,rst ct state new log prefix "NFTBAN_PORTSCAN:SYN "
	}
	chain ddos_prefix {
		ip saddr @ddos_ban_1h drop
	}
	chain ddos_protection {
		ip saddr @ddos_limit_10s drop
	}
}
`

const schemaIP = `table ip nftban { }
delete table ip nftban
table ip nftban {
    set blacklist_ipv4 {
        type ipv4_addr
        flags interval,timeout
    }
    chain input {
        type filter hook input priority filter; policy drop;
        counter name "anchor_trusted" comment "NFTBAN_ANCHOR:ANCHOR_TRUSTED"
        counter name "anchor_established" comment "NFTBAN_ANCHOR:ANCHOR_ESTABLISHED"
        counter name "anchor_detect" comment "NFTBAN_ANCHOR:ANCHOR_DETECT"
        counter name "anchor_service" comment "NFTBAN_ANCHOR:ANCHOR_SERVICE"
    }
}
`

func TestExtractCarriesEnabledModulesOnly(t *testing.T) {
	mo, err := ExtractModules("ip", liveIP, schemaIP, map[string]bool{"ddos": true})
	if err != nil {
		t.Fatal(err)
	}
	joined := strings.Join(mo.Blocks, "\n")
	for _, want := range []string{"set ddos_ban_1h {", "set ddos_limit_10s {", "chain ddos_penalty {", "chain ddos_prefix {", "chain ddos_protection {"} {
		if !strings.Contains(joined, want) {
			t.Fatalf("missing carried block %q", want)
		}
	}
	if strings.Contains(joined, "portscan_detection") || strings.Contains(joined, "http_bot_meter") {
		t.Fatal("objects of modules that are not enabled must not be carried")
	}
	if strings.Contains(joined, "elements =") || strings.Contains(joined, "expires") {
		t.Fatal("set elements must be stripped from declarations (carried by Render with remaining TTL)")
	}
	if len(mo.Sets) != 1 || mo.Sets[0] != "ddos_ban_1h" {
		t.Fatalf("only the non-meter set carries elements, got %v", mo.Sets)
	}
	if strings.Contains(joined, "chain input") || strings.Contains(joined, "blacklist_ipv4") {
		t.Fatal("schema objects must not be duplicated")
	}
	want := []Jump{
		{"input", `jump ddos_penalty comment "DDoS penalty ladder"`, "ANCHOR_ESTABLISHED"},
		{"input", `jump ddos_prefix comment "Prefix"`, "ANCHOR_SERVICE"},
		{"input", `jump ddos_protection comment "Classic"`, "ANCHOR_SERVICE"},
	}
	if len(mo.Jumps) != len(want) {
		t.Fatalf("jumps: %+v", mo.Jumps)
	}
	for i := range want {
		if mo.Jumps[i] != want[i] {
			t.Fatalf("jump %d: got %+v want %+v", i, mo.Jumps[i], want[i])
		}
	}
}

func TestComposePlacesJumpsBeforeAnchorsInOrder(t *testing.T) {
	mo, err := ExtractModules("ip", liveIP, schemaIP, map[string]bool{"ddos": true, "portscan": true})
	if err != nil {
		t.Fatal(err)
	}
	out, err := Compose(schemaIP, "N1", []*ModuleObjects{mo}, "add element ip nftban ddos_ban_1h { 45.155.205.9 timeout 3540s }\n")
	if err != nil {
		t.Fatal(err)
	}
	idx := func(s string) int {
		i := strings.Index(out, s)
		if i < 0 {
			t.Fatalf("missing %q in:\n%s", s, out)
		}
		return i
	}
	if strings.Count(out, `comment "nftban-gen=N1"`) != 1 {
		t.Fatal("exactly one marker, in the full table body")
	}
	if !(idx("jump ddos_penalty") < idx("ANCHOR_ESTABLISHED") &&
		idx("ANCHOR_ESTABLISHED") < idx("jump portscan_detection") &&
		idx("jump portscan_detection") < idx("ANCHOR_DETECT") &&
		idx("jump ddos_prefix") < idx("jump ddos_protection") &&
		idx("jump ddos_protection") < idx("ANCHOR_SERVICE")) {
		t.Fatalf("jumps not before their anchors in live order:\n%s", out)
	}
	if idx("chain portscan_detection {") < idx("table ip nftban {\n") {
		t.Fatal("module blocks belong inside the full table body")
	}
	if !strings.HasSuffix(out, "add element ip nftban ddos_ban_1h { 45.155.205.9 timeout 3540s }\n") {
		t.Fatal("content must follow the schema")
	}
}

func TestRefusals(t *testing.T) {
	noAnchor := strings.Replace(liveIP, `		counter name "anchor_service" comment "NFTBAN_ANCHOR:ANCHOR_SERVICE"`+"\n", "", 1)
	if _, err := ExtractModules("ip", noAnchor, schemaIP, map[string]bool{"ddos": true}); err == nil {
		t.Fatal("a jump with no anchor after it must refuse")
	}
	mo, err := ExtractModules("ip", liveIP, schemaIP, map[string]bool{"ddos": true})
	if err != nil {
		t.Fatal(err)
	}
	schemaNoService := strings.Replace(schemaIP, `        counter name "anchor_service" comment "NFTBAN_ANCHOR:ANCHOR_SERVICE"`+"\n", "", 1)
	if _, err := Compose(schemaNoService, "N", []*ModuleObjects{mo}, ""); err == nil {
		t.Fatal("an anchor missing from the schema must refuse")
	}
	withMap := strings.Replace(liveIP, "	chain ddos_penalty {", "	map ddos_map {\n		type ipv4_addr : verdict\n		elements = { 1.2.3.4 : drop }\n	}\n	chain ddos_penalty {", 1)
	if _, err := ExtractModules("ip", withMap, schemaIP, map[string]bool{"ddos": true}); err == nil {
		t.Fatal("a module map with elements must refuse")
	}
}

func TestNoLiveTableCarriesNothing(t *testing.T) {
	mo, err := ExtractModules("ip", "", schemaIP, map[string]bool{"ddos": true})
	if err != nil || len(mo.Blocks) != 0 || len(mo.Jumps) != 0 {
		t.Fatalf("fresh kernel: %+v %v", mo, err)
	}
}
