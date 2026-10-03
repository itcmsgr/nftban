// =============================================================================
// NFTBan v1.234.0 - BotScan shared CDN edge guard tests (daemon apply boundary)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// Package: botguard
// Purpose: A BotScan signal for an address inside a published CDN edge range (IPv4, IPv6,
//          IPv4-mapped, Cloudflare Workers egress) is never applied on either consumer path;
//          a non-edge address is still banned (negative control); over-broad entries are
//          rejected; the packaged snapshot covers the Workers egress address.
//
// meta:name="botguard_botscan_shared_edge_v1234_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-01"
// meta:description="Shared CDN edge refusal in applyBotscanBanSignal/applyBatchSignal: v4, v6, v4-mapped and Workers egress refused; non-edge banned; admission rejects over-broad prefixes; packaged snapshot contents"
// meta:inventory.files="botscan_shared_edge_v1234_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"net/netip"
	"os"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

func writeEdgeFixture(t *testing.T) string {
	t.Helper()
	f := filepath.Join(t.TempDir(), "edges.tsv")
	body := "# fixture\ncloudflare\tips-v4\t104.16.0.0/13\ncloudflare\tips-v6\t2a06:98c0::/29\nbad\tlist\t0.0.0.0/0\nbad\tlist\t::/0\n"
	if err := os.WriteFile(f, []byte(body), 0o600); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestSharedEdge_MatchAndAdmission(t *testing.T) {
	s := newSharedEdgeSet([]string{writeEdgeFixture(t)})
	if n := s.Size(); n != 2 {
		t.Fatalf("over-broad entries must be rejected: loaded %d ranges, want 2", n)
	}
	for _, c := range []struct {
		ip   string
		edge bool
	}{
		{"104.16.1.2", true},
		{"104.23.255.254", true},
		{"::ffff:104.16.1.2", true},   // IPv4-mapped form of an edge
		{"2a06:98c0:3600::103", true}, // Cloudflare Workers egress
		{"104.24.0.1", false},         // outside the fixture /13
		{"45.33.32.10", false},        // ordinary scanner
		{"2a06:98c8::1", false},       // just outside the /29
		{"2606:4700::1", false},       // not in this fixture
	} {
		_, got := s.Match(netip.MustParseAddr(c.ip))
		if got != c.edge {
			t.Errorf("%s: edge=%v, want %v", c.ip, got, c.edge)
		}
	}
}

// The packaged snapshot (the authority when offline) covers the Workers egress address
// named in the incident, and carries both families.
func TestSharedEdge_PackagedSnapshot(t *testing.T) {
	_, me, _, _ := runtime.Caller(0)
	snap := filepath.Join(filepath.Dir(me), "..", "..", "cli", "lib", "nftban", "data", "botscan_shared_edges.tsv")
	s := newSharedEdgeSet([]string{snap})
	if s.Size() < 10 {
		t.Fatalf("packaged snapshot %s: only %d ranges loaded", snap, s.Size())
	}
	for _, ip := range []string{"2a06:98c0:3600::103", "104.16.0.1", "172.64.0.1", "2606:4700::6810:1"} {
		if _, ok := s.Match(netip.MustParseAddr(ip)); !ok {
			t.Errorf("snapshot must cover %s", ip)
		}
	}
	if _, ok := s.Match(netip.MustParseAddr("45.33.32.10")); ok {
		t.Error("snapshot must not cover an ordinary address")
	}
}

// End to end on the standalone consumer: the edge (v4 and v6) is never enqueued, the
// non-edge control is banned, and the refusal is counted.
func TestSharedEdge_StandaloneConsumerRefusesEdge(t *testing.T) {
	m, b := newEnforcingModule(t)
	m.config.Enabled = false
	m.config.SharedEdgeFiles = []string{writeEdgeFixture(t)}

	for _, ip := range []string{"104.16.1.2", "2a06:98c0:3600::103"} {
		if m.applyBotscanBanSignal(freshSig(ip, "scanner", "ban")) {
			t.Fatalf("%s: a shared CDN edge must not be enqueued", ip)
		}
	}
	if !m.applyBotscanBanSignal(freshSig("45.33.32.77", "scanner", "ban")) {
		t.Fatal("negative control: a non-edge scanner must still be enqueued")
	}
	if !waitBanned(b, "blacklist_manual_ipv4", "45.33.32.77") {
		t.Fatal("negative control not applied")
	}
	time.Sleep(100 * time.Millisecond)
	if b.has("blacklist_manual_ipv4", "104.16.1.2") || b.has("blacklist_manual_ipv6", "2a06:98c0:3600::103") {
		t.Fatalf("edge reached the backend: %v", b.adds)
	}
	if got := m.stats.BatchSignalsSharedEdgeSkipped; got != 2 {
		t.Errorf("shared-edge skips counted %d, want 2", got)
	}
}

// BotGuard-enabled path: the edge never reaches http_bot_ban; the control does.
func TestSharedEdge_BotGuardPathRefusesEdge(t *testing.T) {
	m, b := newEnforcingModule(t)
	m.config.SharedEdgeFiles = []string{writeEdgeFixture(t)}
	m.applyBatchSignal(freshSig("104.16.9.9", "scanner", "ban"))
	m.applyBatchSignal(freshSig("45.33.32.78", "scanner", "ban"))
	if !waitBanned(b, "http_bot_ban", "45.33.32.78") {
		t.Fatalf("negative control not banned on the BotGuard path: %v", b.adds)
	}
	time.Sleep(100 * time.Millisecond)
	if b.has("http_bot_ban", "104.16.9.9") {
		t.Fatalf("edge reached http_bot_ban: %v", b.adds)
	}
}
