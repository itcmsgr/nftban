// =============================================================================
// NFTBan - v1.238.2: the kernel whitelist snapshot leaves out host-owned addresses
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:name="runtime_whitelist_ownership_v1238_2"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-11-28"
// meta:description="SEC-WHITELIST-SELF-ADDRESSES-INCLUDE-DOCKER-BRIDGE-AND-LINK-LOCAL-INPUT-ACCEPT: GetWhitelistSnapshotWithExpiry is the only input of the two kernel-set producers (daemon FullSync, ruleset.Render at boot). It must omit an ownership-only address and keep a trusted one with its expiry, while IsWhitelisted and AddToBlacklist still treat the ownership-only address as whitelisted (self-ban protection kept). In-memory unit test with reserved documentation IPs; no traffic and no firewall change."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package runtime

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestKernelWhitelistSnapshotOmitsOwnershipOnly_v1238_2(t *testing.T) {
	cfg := t.TempDir()
	wd := filepath.Join(cfg, "whitelist.d")
	if err := os.MkdirAll(wd, 0o750); err != nil {
		t.Fatal(err)
	}
	future := time.Now().UTC().Add(2 * time.Hour).Truncate(time.Second)
	sys := "127.0.0.1  # Localhost (critical)\n" +
		"192.0.2.10  # Server interface (auto-detected)\n" +
		"2001:db8::10  # Server interface (auto-detected)\n" +
		"192.0.2.30  # Server interface (auto-detected)\n" +
		"192.0.2.31  # Server interface (auto-detected)\n"
	if err := os.WriteFile(filepath.Join(wd, "00-system.conf"), []byte(sys), 0o640); err != nil {
		t.Fatal(err)
	}
	past := time.Now().UTC().Add(-1 * time.Minute).Truncate(time.Second)
	// 192.0.2.30: valid temporary manual trust. 192.0.2.31: the same kind of entry, EXPIRED: the
	// host's permanent ownership must not make the temporary trust permanent (owner 2026-11-28).
	man := "192.0.2.30  # ops EXPIRES_AT=" + future.Format(time.RFC3339) + "\n" +
		"192.0.2.31  # ops EXPIRES_AT=" + past.Format(time.RFC3339) + "\n"
	if err := os.WriteFile(filepath.Join(wd, "99-manual.conf"), []byte(man), 0o640); err != nil {
		t.Fatal(err)
	}

	rs := NewRuntimeState(cfg)
	if err := rs.LoadWhitelists(); err != nil {
		t.Fatal(err)
	}
	v4, v6, exp := rs.GetWhitelistSnapshotWithExpiry()
	in := func(l []string, ip string) bool {
		for _, x := range l {
			if x == ip {
				return true
			}
		}
		return false
	}
	if in(v4, "192.0.2.10") || in(v6, "2001:db8::10") {
		t.Errorf("ownership-only addresses reached the kernel snapshot: v4=%v v6=%v", v4, v6)
	}
	if !in(v4, "127.0.0.1") || !in(v4, "192.0.2.30") {
		t.Errorf("trusted addresses missing from the kernel snapshot: %v", v4)
	}
	if got, ok := exp["192.0.2.30"]; !ok || !got.Equal(future) {
		t.Errorf("192.0.2.30 must carry the manual expiry %v, got %v (%v)", future, got, ok)
	}
	if in(v4, "192.0.2.31") {
		t.Errorf("192.0.2.31: expired manual trust still grants the kernel accept (ownership made it permanent)")
	}
	if !rs.IsWhitelisted("192.0.2.31", true) {
		t.Errorf("192.0.2.31: after the manual entry expired, self-ban protection must remain (host owns it)")
	}
	if !rs.IsWhitelisted("192.0.2.10", true) || !rs.IsWhitelisted("2001:db8::10", false) {
		t.Errorf("ownership-only addresses must stay whitelisted for the guards")
	}
	if err := rs.AddToBlacklist("192.0.2.10", true, "test", "self-ban attempt"); err == nil {
		t.Errorf("AddToBlacklist accepted an ownership-only host address (self-ban protection lost)")
	}
}
