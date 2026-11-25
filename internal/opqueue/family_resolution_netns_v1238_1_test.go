// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package opqueue

// v1.238.1 F2 BUG-OPQUEUE-IPV6-SETS-RESOLVED-BY-NAME-SUFFIX (owner 2026-11-25, RC acceptance on
// v1.238.0 / v1.237.0): the opqueue wrapper chose the table from the set NAME (only "_ipv6" went
// to ip6) and CREATED missing sets, so a BotGuard/BotScan IPv6 grey/ban for http_bot_grey6 went to
// table ip, created an ipv4 copy there, failed ("is not IPv4") and never reached the ip6 set the
// kernel rule uses.
//
// Real-kernel test through the REAL OpQueue and NFTBackendWrapper. It runs ONLY inside a private
// network namespace (`unshare -n`, as root, NFTBAN_NETNS_TEST=1) and refuses to run in the host
// namespace, so it can never touch a host firewall. It starts from the upgraded-host state: the
// real ip6 set AND the old ipv4-typed copy of the same name in table ip both present.

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	nftsync "github.com/itcmsgr/nftban/internal/setsync"
)

const familyTestRuleset = `
table ip nftban {
	set http_bot_grey { type ipv4_addr; flags timeout; }
	set http_bot_grey6 { type ipv4_addr; flags interval; }
}
table ip6 nftban {
	set http_bot_grey6 { type ipv6_addr; flags timeout; }
}
`

func requirePrivateNetns(t *testing.T) {
	t.Helper()
	if os.Getenv("NFTBAN_NETNS_TEST") != "1" {
		t.Skip("real-kernel test: run as root inside `unshare -n` with NFTBAN_NETNS_TEST=1")
	}
	if os.Geteuid() != 0 {
		t.Skip("needs root (inside a private network namespace)")
	}
	self, err1 := os.Readlink("/proc/self/ns/net")
	init1, err2 := os.Readlink("/proc/1/ns/net")
	if err1 != nil || err2 != nil || self == init1 {
		t.Fatalf("REFUSING: not in a private network namespace (self=%q pid1=%q) — this test would touch the host firewall", self, init1)
	}
	if _, err := exec.LookPath("nft"); err != nil {
		t.Skip("nft binary not available")
	}
}

func nftSetElems(t *testing.T, family, set string) []string {
	t.Helper()
	out, err := exec.Command("nft", "-j", "list", "set", family, "nftban", set).Output()
	if err != nil {
		t.Fatalf("nft list set %s nftban %s: %v", family, set, err)
	}
	var doc struct {
		Nftables []map[string]json.RawMessage `json:"nftables"`
	}
	if err := json.Unmarshal(out, &doc); err != nil {
		t.Fatal(err)
	}
	var vals []string
	for _, o := range doc.Nftables {
		raw, ok := o["set"]
		if !ok {
			continue
		}
		var s struct {
			Elem []json.RawMessage `json:"elem"`
		}
		_ = json.Unmarshal(raw, &s)
		for _, e := range s.Elem {
			str := string(e)
			// plain "1.2.3.4" or {"elem":{"val":"...","timeout":...}}
			var plain string
			if json.Unmarshal(e, &plain) == nil {
				vals = append(vals, plain)
				continue
			}
			var wrapped struct {
				Elem struct {
					Val string `json:"val"`
				} `json:"elem"`
			}
			if json.Unmarshal(e, &wrapped) == nil && wrapped.Elem.Val != "" {
				vals = append(vals, wrapped.Elem.Val)
				continue
			}
			vals = append(vals, str)
		}
	}
	return vals
}

func waitFor(t *testing.T, what string, cond func() bool) {
	t.Helper()
	for i := 0; i < 200; i++ {
		if cond() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatalf("timed out waiting for: %s", what)
}

func has(vals []string, v string) bool {
	for _, x := range vals {
		if x == v {
			return true
		}
	}
	return false
}

func TestOpQueueFamilyResolutionWithSameNameSetsInBothTables(t *testing.T) {
	requirePrivateNetns(t)
	_ = exec.Command("nft", "flush", "ruleset").Run() // private netns only (checked above)
	cmd := exec.Command("nft", "-f", "-")
	cmd.Stdin = strings.NewReader(familyTestRuleset)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("load test ruleset: %v: %s", err, out)
	}

	nft, err := nftsync.NewNFTManager()
	if err != nil {
		t.Fatal(err)
	}
	w, err := NewNFTBackendWrapper(nft)
	if err != nil {
		t.Fatal(err)
	}
	cfg := DefaultQueueConfig()
	cfg.FlushThreshold = 1
	cfg.FlushInterval = 5 * time.Millisecond
	q := NewOpQueue(w, cfg)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	q.Start(ctx)

	const v6, v4 = "2001:db8::10", "192.0.2.10"

	// ADD: the IPv6 grey reaches the ip6 set; the ipv4 copy in table ip stays empty; IPv4 parity.
	if err := q.EnqueueBan("http_bot_grey6", v6, 600, "botguard", "test"); err != nil {
		t.Fatal(err)
	}
	if err := q.EnqueueBan("http_bot_grey", v4, 600, "botguard", "test"); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "IPv6 element in ip6 nftban http_bot_grey6", func() bool { return has(nftSetElems(t, "ip6", "http_bot_grey6"), v6) })
	waitFor(t, "IPv4 element in ip nftban http_bot_grey", func() bool { return has(nftSetElems(t, "ip", "http_bot_grey"), v4) })
	if got := nftSetElems(t, "ip", "http_bot_grey6"); len(got) != 0 {
		t.Fatalf("the ipv4 copy ip nftban http_bot_grey6 was written: %v", got)
	}

	// DELETE: only the ip6 set loses the element.
	if err := q.EnqueueUnban("http_bot_grey6", v6, "botguard"); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "IPv6 element removed from ip6 http_bot_grey6", func() bool { return !has(nftSetElems(t, "ip6", "http_bot_grey6"), v6) })
	if !has(nftSetElems(t, "ip", "http_bot_grey"), v4) {
		t.Fatal("IPv4 element lost from ip http_bot_grey by an IPv6 delete")
	}

	// FLUSH: the ip6 set is emptied; the IPv4 set and the ipv4 copy are untouched.
	if err := q.EnqueueBan("http_bot_grey6", v6, 600, "botguard", "test"); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "IPv6 element re-added", func() bool { return has(nftSetElems(t, "ip6", "http_bot_grey6"), v6) })
	if err := q.EnqueueFlush("http_bot_grey6"); err != nil {
		t.Fatal(err)
	}
	waitFor(t, "ip6 http_bot_grey6 flushed", func() bool { return len(nftSetElems(t, "ip6", "http_bot_grey6")) == 0 })
	if !has(nftSetElems(t, "ip", "http_bot_grey"), v4) {
		t.Fatal("flush of http_bot_grey6 touched ip http_bot_grey")
	}

	// No set was created by the write path.
	out, _ := exec.Command("nft", "list", "sets").Output()
	if n := strings.Count(string(out), "set "); n != 3 {
		t.Fatalf("set count changed (write path created a set?): %d\n%s", n, out)
	}
	_ = exec.Command("nft", "flush", "ruleset").Run()
}
