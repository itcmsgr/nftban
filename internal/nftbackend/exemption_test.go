// SPDX-License-Identifier: MPL-2.0
//
// meta:name="nftbackend_exemption_test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Unit tests for the never-ban exemption resolver: IsExempt exact+CIDR (v4/v6), empty-snapshot fail-safe (never blocks bans), /proc/net/tcp hex addr/port parsers, SSH-peer extraction, and scanner-file publish."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package nftbackend

import (
	"net/netip"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// snapshot builds a resolver with a fixed, non-stale snapshot so IsExempt tests the
// matching logic without triggering a live Refresh.
func snapshot(exact []string, cidrs []string) *exemptResolver {
	r := &exemptResolver{ttl: time.Hour, loaded: true, loadedAt: time.Now(), exact: map[string]struct{}{}}
	for _, e := range exact {
		if a, err := netip.ParseAddr(e); err == nil {
			r.exact[a.Unmap().String()] = struct{}{}
		}
	}
	for _, c := range cidrs {
		if p, err := netip.ParsePrefix(c); err == nil {
			r.prefixes = append(r.prefixes, p)
		}
	}
	return r
}

func TestIsExempt_ExactAndCIDR_V4V6(t *testing.T) {
	r := snapshot(
		[]string{"192.0.2.122", "2001:db8::1"},
		[]string{"10.0.0.0/8", "2001:db8:abcd::/48"},
	)
	cases := []struct {
		ip   string
		want bool
	}{
		{"192.0.2.122", true},        // exact v4 (the F2 admin IP)
		{"10.5.6.7", true},             // inside v4 CIDR
		{"10.0.0.1", true},             // inside v4 CIDR
		{"2001:db8::1", true},          // exact v6
		{"2001:db8:abcd::99", true},    // inside v6 CIDR
		{"8.8.8.8", false},             // not exempt → MUST still be bannable
		{"203.0.113.5", false},         // not exempt
		{"2001:db8:ffff::1", false},    // v6 not in CIDR
		{"not-an-ip", false},           // invalid
		{"1.2.3.0/24", false},          // CIDR ban request is not the admin/session class
	}
	for _, c := range cases {
		got, _ := r.IsExempt(c.ip)
		if got != c.want {
			t.Errorf("IsExempt(%q) = %v, want %v", c.ip, got, c.want)
		}
	}
}

func TestIsExempt_EmptySnapshotNeverBlocks(t *testing.T) {
	// Fail-safe: an empty resolver must NOT exempt anything (legitimate bans proceed).
	r := snapshot(nil, nil)
	if ok, _ := r.IsExempt("203.0.113.9"); ok {
		t.Fatal("empty resolver exempted an IP — would block legitimate bans (fail-safe violated)")
	}
}

func TestHexPort(t *testing.T) {
	cases := map[string]uint16{
		"0100007F:0050": 80,
		"00000000:D6D8": 55000, // 0xD6D8
		"00000000:0016": 22,
	}
	for field, want := range cases {
		got, ok := hexPort(field)
		if !ok || got != want {
			t.Errorf("hexPort(%q) = %d,%v want %d", field, got, ok, want)
		}
	}
}

func TestHexAddrIP(t *testing.T) {
	cases := map[string]string{
		"0100007F:0050": "127.0.0.1",  // little-endian → reversed
		"0F02000A:0016": "10.0.2.15",  // 0A.00.02.0F
		"00000000000000000000000001000000:0016": "::1", // v6 ::1 /proc repr
	}
	for field, want := range cases {
		got, ok := hexAddrIP(field)
		if !ok || got != want {
			t.Errorf("hexAddrIP(%q) = %q,%v want %q", field, got, ok, want)
		}
	}
}

func TestSSHListenPorts_DefaultPlusConfig(t *testing.T) {
	// sshListenPorts always includes 22; we can't easily fake /etc/ssh here, so just
	// assert 22 is present and the function never panics.
	ports := sshListenPorts()
	if _, ok := ports[22]; !ok {
		t.Error("sshListenPorts missing default port 22")
	}
}

func TestParseProcNetTCP_EstablishedSSHPeer(t *testing.T) {
	// Synthetic /proc/net/tcp: one ESTABLISHED (st=01) conn to local port 22 (0016)
	// from 10.0.2.15 (0F02000A), and one to a non-SSH port that must be ignored.
	content := "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n" +
		"   0: 0100007F:0016 0F02000A:C001 01 00000000:00000000 00:00000000 00000000     0        0 1 1 ffff\n" +
		"   1: 0100007F:1F90 0F02000B:C002 01 00000000:00000000 00:00000000 00000000     0        0 1 1 ffff\n" +
		"   2: 0100007F:0016 0F02000C:C003 06 00000000:00000000 00:00000000 00000000     0        0 1 1 ffff\n" // st=06 TIME_WAIT, ignore
	dir := t.TempDir()
	path := filepath.Join(dir, "tcp")
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	peers := parseProcNetTCP(path, map[uint16]struct{}{22: {}})
	if len(peers) != 1 || peers[0] != "10.0.2.15" {
		t.Errorf("parseProcNetTCP peers = %v, want [10.0.2.15] (only established SSH-port conn)", peers)
	}
}

func TestRefresh_WritesScannerFileAndNoPanic(t *testing.T) {
	dir := t.TempDir()
	scanner := filepath.Join(dir, "exempt.list")
	// Empty configDir → whitelist load is a no-op; DetectSystemIPs/proc run live but
	// must not panic. We only assert the scanner file is written.
	r := &exemptResolver{configDir: "", scannerFile: scanner, ttl: time.Hour, exact: map[string]struct{}{}}
	r.Refresh()
	if _, err := os.Stat(scanner); err != nil {
		t.Errorf("Refresh did not write scanner file: %v", err)
	}
}
