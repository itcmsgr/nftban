// =============================================================================
// NFTBan v1.236 - ruleset content tests (hermetic: temp config dirs, fake kernel)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="ruleset-content-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-22"
// meta:description="ParseSetJSON shapes (nft 1.0.9); Render: durable + carried classes, remaining TTL shortened, expired dropped, never-ban on drop sets, blacklist.d permanence over a timed copy, removed whitelist entries not carried, oversize refusal before rendering"
// meta:inventory.privileges="none"
// =============================================================================

package ruleset

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// Captured from nft 1.0.9 (lab2, 2026-10-22).
const jsonInterval = `{"nftables":[{"metainfo":{}},{"set":{"family":"ip","name":"a","table":"t","elem":[{"prefix":{"addr":"10.0.0.0","len":8}},"192.0.2.1",{"range":["198.51.100.0","198.51.100.9"]},{"elem":{"val":{"prefix":{"addr":"203.0.113.0","len":24}},"timeout":3600,"expires":3599}}]}}]}`
const jsonConcat = `{"nftables":[{"set":{"elem":[{"concat":["192.0.2.8",22]},{"elem":{"val":{"concat":["192.0.2.7",443]},"timeout":7200,"expires":7199}}]}}]}`

func TestParseSetJSONShapes(t *testing.T) {
	got, err := ParseSetJSON([]byte(jsonInterval))
	if err != nil {
		t.Fatal(err)
	}
	want := []Element{
		{Key: "10.0.0.0/8"},
		{Key: "192.0.2.1"},
		{Key: "198.51.100.0-198.51.100.9"},
		{Key: "203.0.113.0/24", HasTimeout: true, Remaining: 3599 * time.Second},
	}
	if len(got) != len(want) {
		t.Fatalf("got %+v", got)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("element %d: got %+v want %+v", i, got[i], want[i])
		}
	}
	got, err = ParseSetJSON([]byte(jsonConcat))
	if err != nil {
		t.Fatal(err)
	}
	if got[0].Key != "192.0.2.8 . 22" || got[1].Key != "192.0.2.7 . 443" || got[1].Remaining != 7199*time.Second {
		t.Fatalf("concat: %+v", got)
	}
}

type fakeExempt map[string]bool

func (f fakeExempt) IsExempt(ip string) (bool, string) { return f[ip], "fake" }

// SubtractExempt drops a prefix listed in the map (whole-prefix stand-in for the split).
func (f fakeExempt) SubtractExempt(cidrs []string) ([]string, int, []string) {
	var kept []string
	removed := 0
	for _, c := range cidrs {
		if f[c] {
			removed++
			continue
		}
		kept = append(kept, c)
	}
	return kept, removed, nil
}

func write(t *testing.T, path, body string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func fixture(t *testing.T) Options {
	t.Helper()
	cfg, data := t.TempDir(), t.TempDir()
	write(t, filepath.Join(cfg, "whitelist.d", "99-manual.conf"), "198.51.100.50\n")
	// Routable addresses: documentation/benchmark ranges are refused as bans
	// (EnforcementClassReject) and filtered as bogons by MergeCIDRsSafe.
	write(t, filepath.Join(cfg, "blacklist.d", "99-manual.conf"), "23.129.97.10\n23.129.97.11\n185.220.100.0/24\n")
	write(t, filepath.Join(data, "feeds", "f.txt"), "45.155.205.0/24\n")
	write(t, filepath.Join(data, "trust", "crawler.txt"), "66.249.64.0/19\n")
	return Options{ConfigDir: cfg, DataDir: data, CommitMargin: 5 * time.Second}
}

func reader(sets map[string][]Element) SetReader {
	return func(family, set string) ([]Element, error) { return sets[family+"/"+set], nil }
}

func line(script, set string) string {
	for _, l := range strings.Split(script, "\n") {
		if strings.Contains(l, " "+set+" {") {
			return l
		}
	}
	return ""
}

func TestRenderClasses(t *testing.T) {
	opts := fixture(t)
	kernel := map[string][]Element{
		// runtime timed whitelist kept; trust-covered permanent kept; a removed
		// whitelist.d entry (permanent, not trust) NOT carried
		"ip/whitelist_ipv4": {
			{Key: "192.0.2.77", HasTimeout: true, Remaining: time.Hour},
			{Key: "66.249.66.1"},
			{Key: "198.51.100.99"},
		},
		"ip/blacklist_manual_ipv4": {
			{Key: "23.129.97.10", HasTimeout: true, Remaining: time.Hour}, // also in blacklist.d -> permanent
			{Key: "23.129.97.20"}, // kernel-only permanent -> kept
			{Key: "23.129.97.21", HasTimeout: true, Remaining: 2 * time.Minute},
			{Key: "23.129.97.22", HasTimeout: true, Remaining: 3 * time.Second}, // < margin -> dropped
			{Key: "23.129.97.9"}, // exempt -> refused
		},
		"ip/blacklist_ipv4": {
			{Key: "46.4.0.0/24", HasTimeout: true, Remaining: time.Hour}, // timed interval ban kept
			{Key: "45.155.205.0/24"},                                     // permanent: re-derived, not carried
		},
		"ip/http_bot_ban":        {{Key: "192.0.2.200", HasTimeout: true, Remaining: 10 * time.Minute}},
		"ip/port_allow_tcp_ipv4": {{Key: "192.0.2.7 . 443", HasTimeout: true, Remaining: 7199 * time.Second}},
	}
	res, err := Render(opts, reader(kernel), fakeExempt{"23.129.97.9": true})
	if err != nil {
		t.Fatal(err)
	}

	wl := line(res.Script, "whitelist_ipv4")
	for _, want := range []string{"198.51.100.50", "192.0.2.77 timeout 3595s", "66.249.66.1"} {
		if !strings.Contains(wl, want) {
			t.Fatalf("whitelist missing %q: %s", want, wl)
		}
	}
	if strings.Contains(wl, "198.51.100.99") {
		t.Fatalf("a kernel-only permanent whitelist entry outside trust was carried: %s", wl)
	}

	man := line(res.Script, "blacklist_manual_ipv4")
	elems := map[string]bool{}
	if i, j := strings.Index(man, "{"), strings.LastIndex(man, "}"); i >= 0 && j > i {
		for _, e := range strings.Split(man[i+1:j], ",") {
			elems[strings.TrimSpace(e)] = true
		}
	}
	if !elems["23.129.97.10"] {
		t.Fatalf("blacklist.d IP must be loaded PERMANENT (H11: it wins over the timed kernel copy): %s", man)
	}
	for _, want := range []string{"23.129.97.11", "23.129.97.20", "23.129.97.21 timeout 115s"} {
		if !elems[want] {
			t.Fatalf("manual set missing %q: %s", want, man)
		}
	}
	for e := range elems {
		if strings.HasPrefix(e, "23.129.97.22") || e == "23.129.97.9" {
			t.Fatalf("expired or exempt element carried: %s", man)
		}
	}

	bl := line(res.Script, "blacklist_ipv4")
	for _, want := range []string{"185.220.100.0/24", "45.155.205.0/24", "46.4.0.0/24 timeout 3595s"} {
		if !strings.Contains(bl, want) {
			t.Fatalf("union missing %q: %s", want, bl)
		}
	}
	if !strings.Contains(line(res.Script, "http_bot_ban"), "192.0.2.200 timeout 595s") {
		t.Fatalf("http_bot_ban not carried: %s", res.Script)
	}
	if !strings.Contains(line(res.Script, "port_allow_tcp_ipv4"), "192.0.2.7 . 443 timeout 7194s") {
		t.Fatalf("port grant not carried: %s", res.Script)
	}
	if res.Expired != 1 || res.Exempt != 1 {
		t.Fatalf("accounting: expired=%d exempt=%d", res.Expired, res.Exempt)
	}
}

func TestRenderRefusesOversizedBeforeRendering(t *testing.T) {
	opts := fixture(t)
	opts.MaxElements = 3
	res, err := Render(opts, reader(nil), fakeExempt{})
	if !errors.Is(err, ErrOversized) || res != nil {
		t.Fatalf("want ErrOversized and no result, got res=%v err=%v", res, err)
	}
}
