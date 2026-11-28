// =============================================================================
// NFTBan - v1.238.2: host-owned addresses keep self-ban protection, no kernel accept
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="whitelist_loader_ownership_v1238_2"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-11-28"
// meta:description="SEC-WHITELIST-SELF-ADDRESSES-INCLUDE-DOCKER-BRIDGE-AND-LINK-LOCAL-INPUT-ACCEPT (owner design 2026-11-28): an address NFTBan recorded only because the host owns it (00-system.conf ownership comments, a bare line after maintenance's 'Auto-added … by maintenance', 00-system-ip.conf) loads with OwnershipOnly=true; localhost, admin session, SSH client, whitelistme, a bare line of unknown origin and every other file stay trusted. One trusted occurrence anywhere wins in either file order and supplies the expiry. Every entry stays in the guard map. In-memory unit test with reserved documentation IPs; no traffic and no firewall change."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package whitelist

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func writeWL(t *testing.T, dir, name, body string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, name), []byte(body), 0o640); err != nil {
		t.Fatal(err)
	}
}

func TestWhitelistOwnershipOnly_v1238_2(t *testing.T) {
	cfg := t.TempDir()
	wd := filepath.Join(cfg, "whitelist.d")
	if err := os.MkdirAll(wd, 0o750); err != nil {
		t.Fatal(err)
	}
	future := time.Now().UTC().Add(2 * time.Hour).Truncate(time.Second)
	add := " (added: 2026-11-28 10:00:00 UTC)"

	// Sorts BEFORE 00-system.conf: a trusted entry read first must stay trusted.
	writeWL(t, wd, "00-a-early.conf", "192.0.2.31  # operator entry\n")
	writeWL(t, wd, "00-system-ip.conf", "192.0.2.40\n")
	writeWL(t, wd, "00-system.conf", "# NFTBan System Whitelist - Auto-Generated\n"+
		"127.0.0.1  # Localhost (critical)"+add+"\n"+
		"192.0.2.10  # Server interface (auto-detected)"+add+"\n"+
		"2001:db8::10  # Server interface (auto-detected)"+add+"\n"+
		"192.0.2.11  # Server public IPv4 (auto-detected)"+add+"\n"+
		"2001:db8::11  # Server public IPv6 (auto-detected)"+add+"\n"+
		"192.0.2.12  # Server IPv4 (auto-detected)\n"+
		"2001:db8::12  # Server IPv6 (auto-detected)\n"+
		"198.51.100.20  # Admin session (--protect-session)"+add+"\n"+
		"198.51.100.21  # SSH client IP (auto-detected)\n"+
		"198.51.100.22  # Current user (whitelistme on 2026-11-28)"+add+"\n"+
		"198.51.100.24  # Admin session (enable lockout prevention)"+add+"\n"+
		"# Auto-added by maintenance: Fri Nov 28 10:00:00 UTC 2026\n"+
		"192.0.2.13\n"+
		"# Auto-added IPv6 by maintenance: Fri Nov 28 10:00:00 UTC 2026\n"+
		"2001:db8::13\n"+
		"198.51.100.23\n"+
		"192.0.2.30  # Server interface (auto-detected)"+add+"\n"+
		"192.0.2.31  # Server interface (auto-detected)"+add+"\n")
	// Sorts AFTER 00-system.conf: a trusted entry read later must replace the ownership one.
	writeWL(t, wd, "99-manual.conf",
		"192.0.2.30  # ops EXPIRES_AT="+future.Format(time.RFC3339)+"\n"+
			"2001:db8::10  # ops\n"+
			"192.0.2.50  # Server interface (auto-detected)\n")

	v4, v6, err := LoadAllWhitelistsTyped(cfg)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]bool{ // value -> OwnershipOnly
		"192.0.2.10": true, "192.0.2.11": true, "192.0.2.12": true, "192.0.2.13": true, "192.0.2.40": true,
		"2001:db8::11": true, "2001:db8::12": true, "2001:db8::13": true,
		"127.0.0.1": false, "198.51.100.20": false, "198.51.100.21": false, "198.51.100.22": false,
		"198.51.100.23": false, "198.51.100.24": false,
		"192.0.2.30": false, "192.0.2.31": false, "192.0.2.50": false, "2001:db8::10": false,
	}
	for ip, own := range want {
		m := v4
		if strings.Contains(ip, ":") {
			m = v6
		}
		e, ok := m[ip]
		if !ok {
			t.Errorf("%s: missing from the guard map (self-ban protection lost)", ip)
			continue
		}
		if e.OwnershipOnly != own {
			t.Errorf("%s: OwnershipOnly=%v, want %v", ip, e.OwnershipOnly, own)
		}
		if !IsIPInWhitelistFile(ip, m) {
			t.Errorf("%s: IsIPInWhitelistFile=false (the ban guard would allow a self-ban)", ip)
		}
	}
	if got := v4["192.0.2.30"].ExpiresAt; !got.Equal(future) {
		t.Errorf("192.0.2.30: ExpiresAt=%v, want the manual entry's %v", got, future)
	}
	if !v6["2001:db8::10"].ExpiresAt.IsZero() {
		t.Errorf("2001:db8::10: the permanent manual entry must stay permanent")
	}
}
