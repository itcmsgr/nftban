// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package geoban

// v1.238 GeoBan country exceptions (option B, owner GO 2026-11-23). In-memory unit tests with
// reserved documentation prefixes only (192.0.2.0/24, 198.51.100.0/24, 203.0.113.0/24,
// 2001:db8::/32); no traffic, no firewall change.

import (
	"net/netip"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeFile(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o640); err != nil {
		t.Fatal(err)
	}
}

func covered(entries []string, a netip.Addr) bool {
	for _, s := range entries {
		if p, ok := parsePrefix(s); ok && p.Contains(a) {
			return true
		}
	}
	return false
}

func TestBuildAppliesCountryExceptionsToGeoBanOnly(t *testing.T) {
	d := t.TempDir()
	writeFile(t, d, "50-ban-AA.conf", "# Country: AA\n198.51.100.0/24\n192.0.2.0/24\n203.0.113.7\n2001:db8::/32\n")
	writeFile(t, d, "50-ban-BB.conf", "203.0.113.0/25\n")
	// exception: half of one block, all of another, an IPv6 /48, and a prefix overlapping nothing
	writeFile(t, d, "40-whitelist-CC.conf", "# Country: CC\n# Downloaded: 2026-11-23T00:00:00Z\n198.51.100.128/25\n192.0.2.0/24\n2001:db8:1::/48\n10.255.0.0/16\n")

	data, err := Build(d, nil)
	if err != nil {
		t.Fatal(err)
	}
	mustBlock := []string{"198.51.100.1", "198.51.100.127", "203.0.113.7", "203.0.113.1", "2001:db8::1", "2001:db8:2::1", "2001:db8:0:ffff::1"}
	mustAllow := []string{"198.51.100.128", "198.51.100.255", "192.0.2.1", "192.0.2.255", "2001:db8:1::1", "2001:db8:1:ffff::1"}
	all := append(append([]string{}, data.IPv4...), data.IPv6...)
	for _, s := range mustBlock {
		if !covered(all, netip.MustParseAddr(s)) {
			t.Errorf("%s lost its GeoBan block (exception removed too much): %v", s, all)
		}
	}
	for _, s := range mustAllow {
		if covered(all, netip.MustParseAddr(s)) {
			t.Errorf("%s still GeoBan-blocked despite the country exception: %v", s, all)
		}
	}
	if data.Count != len(data.IPv4)+len(data.IPv6) {
		t.Errorf("Count %d != %d", data.Count, len(data.IPv4)+len(data.IPv6))
	}
	for _, s := range data.IPv4 {
		if strings.Contains(s, ":") {
			t.Errorf("IPv6 entry in IPv4 list: %s", s)
		}
	}
}

func TestBuildWithoutExceptionsIsUnchanged(t *testing.T) {
	d := t.TempDir()
	writeFile(t, d, "50-ban-AA.conf", "198.51.100.0/24\n2001:db8::/32\n")
	data, err := Build(d, nil)
	if err != nil {
		t.Fatal(err)
	}
	if len(data.IPv4) != 1 || data.IPv4[0] != "198.51.100.0/24" || len(data.IPv6) != 1 {
		t.Fatalf("unexpected change without exceptions: %+v", data)
	}
}

func TestUnreadableExceptionFileFailsBuild(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root bypasses file modes")
	}
	d := t.TempDir()
	writeFile(t, d, "50-ban-AA.conf", "198.51.100.0/24\n")
	writeFile(t, d, "40-whitelist-CC.conf", "198.51.100.0/25\n")
	if err := os.Chmod(filepath.Join(d, "40-whitelist-CC.conf"), 0); err != nil {
		t.Fatal(err)
	}
	if _, err := Build(d, nil); err == nil {
		t.Fatal("an unreadable exception must fail the build, not silently block the excepted country")
	}
}

func TestExcludePrefixMinimalSplit(t *testing.T) {
	got := excludePrefix(netip.MustParsePrefix("198.51.100.0/24"), []netip.Prefix{netip.MustParsePrefix("198.51.100.64/26")})
	want := map[string]bool{"198.51.100.0/26": true, "198.51.100.128/25": true}
	if len(got) != 2 {
		t.Fatalf("got %v", got)
	}
	for _, p := range got {
		if !want[p.String()] {
			t.Fatalf("got %v", got)
		}
	}
}
