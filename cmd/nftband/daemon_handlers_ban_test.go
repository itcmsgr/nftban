// =============================================================================
// NFTBan v1.119 - Tests for daemon ban handlers (V119 A1 whitelist CIDR guard)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="daemon_handlers_ban_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-18"
// meta:description="V119 A1 — verifies whitelist CIDR containment in the daemon pre-ban guard. Closes the daemon-side half of D-MANUAL-CIDR-LOAD-GAP per V116 §7 Test 5."
// meta:input="Synthetic whitelist.d/ fixtures + minimal Daemon struct"
// meta:output="t.Error on guard violation"
// meta:depends="testing,os,path/filepath"
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
	"testing"
)

// setupWhitelistFixture creates a sandbox configDir with whitelist.d/99-manual.conf
// containing the supplied entries. Returns the configDir path.
func setupWhitelistFixture(t *testing.T, entries string) string {
	t.Helper()
	dir := t.TempDir()
	wlDir := filepath.Join(dir, "whitelist.d")
	if err := os.MkdirAll(wlDir, 0750); err != nil {
		t.Fatalf("mkdir whitelist.d: %v", err)
	}
	path := filepath.Join(wlDir, "99-manual.conf")
	if err := os.WriteFile(path, []byte(entries), 0640); err != nil {
		t.Fatalf("write 99-manual.conf: %v", err)
	}
	return dir
}

// V116 §7 Test 5: whitelist CIDR pre-ban guard.
// Pre-V119: isWhitelisted("1.2.3.5") returned false despite "1.2.3.0/27"
//
//	being present → ban request proceeded to blacklist_manual_ipv4 as orphan.
//
// Post-V119: must return true.
func TestIsWhitelisted_IPv4CIDRContainment(t *testing.T) {
	configDir := setupWhitelistFixture(t, "1.2.3.0/27\n")
	d := &Daemon{configDir: configDir}

	if !d.isWhitelisted("1.2.3.5") {
		t.Error("isWhitelisted(1.2.3.5) against whitelist 1.2.3.0/27: got false, want true (V119 fix)")
	}
	if d.isWhitelisted("1.2.3.32") {
		t.Error("isWhitelisted(1.2.3.32) against whitelist 1.2.3.0/27: got true, want false (outside /27)")
	}
}

func TestIsWhitelisted_IPv4ExactMatch(t *testing.T) {
	configDir := setupWhitelistFixture(t, "1.2.3.4\n")
	d := &Daemon{configDir: configDir}

	if !d.isWhitelisted("1.2.3.4") {
		t.Error("isWhitelisted(1.2.3.4) = false, want true")
	}
	if d.isWhitelisted("1.2.3.5") {
		t.Error("isWhitelisted(1.2.3.5) = true, want false (single-IP whitelist must NOT match neighbours)")
	}
}

func TestIsWhitelisted_IPv6CIDRContainment(t *testing.T) {
	configDir := setupWhitelistFixture(t, "2001:db8::/64\n")
	d := &Daemon{configDir: configDir}

	if !d.isWhitelisted("2001:db8::5") {
		t.Error("isWhitelisted(2001:db8::5) against 2001:db8::/64: got false, want true")
	}
	if d.isWhitelisted("2001:db9::1") {
		t.Error("isWhitelisted(2001:db9::1) against 2001:db8::/64: got true, want false")
	}
}

func TestIsWhitelisted_NoConfigDir(t *testing.T) {
	d := &Daemon{configDir: ""}
	if d.isWhitelisted("1.2.3.4") {
		t.Error("isWhitelisted with empty configDir: got true, want false (defensive bypass)")
	}
}

func TestIsWhitelisted_EmptyWhitelist(t *testing.T) {
	configDir := setupWhitelistFixture(t, "")
	d := &Daemon{configDir: configDir}
	if d.isWhitelisted("1.2.3.4") {
		t.Error("isWhitelisted with empty whitelist: got true, want false")
	}
}
