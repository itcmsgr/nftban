// =============================================================================
// NFTBan v1.168 - CLI-BUG-2 whitelist TTL: runtime ExpireAt + expiry snapshot
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="state_whitelist_expiry_v168_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-09"
// meta:description="v1.168 CLI-BUG-2: LoadWhitelists must populate IPEntry.ExpireAt from a future EXPIRES_AT marker (zero for permanent), and GetWhitelistSnapshotWithExpiry must surface ip->absolute expiry only for timed entries so the daemon FullSync can apply kernel timeouts."
// meta:input="None"
// meta:output="t.Fatal on runtime expiry-carry drift"
// meta:depends="testing,time,os,path/filepath"
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

func writeWL(t *testing.T, dir, name, content string) {
	t.Helper()
	wlDir := filepath.Join(dir, "whitelist.d")
	if err := os.MkdirAll(wlDir, 0o755); err != nil {
		t.Fatalf("mkdir whitelist.d: %v", err)
	}
	if err := os.WriteFile(filepath.Join(wlDir, name), []byte(content), 0o644); err != nil {
		t.Fatalf("write %s: %v", name, err)
	}
}

// TestLoadWhitelists_PopulatesExpireAt asserts a future session entry lands in
// runtime state with a non-nil ExpireAt, while a plain manual entry has a nil
// ExpireAt (permanent).
func TestLoadWhitelists_PopulatesExpireAt(t *testing.T) {
	dir := t.TempDir()
	writeWL(t, dir, "00-session.conf", "10.0.0.1  # EXPIRES_AT=2100-01-01T00:00:00Z  REASON=keep  ADDED_BY=test\n")
	writeWL(t, dir, "99-manual.conf", "10.0.0.4\n")

	rs := NewRuntimeState(dir)
	if err := rs.LoadWhitelists(); err != nil {
		t.Fatalf("LoadWhitelists: %v", err)
	}

	timed, ok := rs.WhitelistIPv4["10.0.0.1"]
	if !ok {
		t.Fatalf("timed entry 10.0.0.1 not loaded: %v", rs.WhitelistIPv4)
	}
	if timed.ExpireAt == nil {
		t.Fatalf("timed entry 10.0.0.1: ExpireAt nil, want future timestamp")
	}
	want, _ := time.Parse(time.RFC3339, "2100-01-01T00:00:00Z")
	if !timed.ExpireAt.Equal(want) {
		t.Fatalf("timed entry 10.0.0.1: ExpireAt=%v, want %v", *timed.ExpireAt, want)
	}

	perm, ok := rs.WhitelistIPv4["10.0.0.4"]
	if !ok {
		t.Fatalf("permanent entry 10.0.0.4 not loaded: %v", rs.WhitelistIPv4)
	}
	if perm.ExpireAt != nil {
		t.Fatalf("permanent entry 10.0.0.4: ExpireAt=%v, want nil", *perm.ExpireAt)
	}
}

// TestGetWhitelistSnapshotWithExpiry asserts the snapshot lists all whitelist
// IPs and surfaces an expiry only for timed entries (permanent entries absent
// from the map → added permanent by the sync).
func TestGetWhitelistSnapshotWithExpiry(t *testing.T) {
	dir := t.TempDir()
	writeWL(t, dir, "00-session.conf", "10.0.0.1  # EXPIRES_AT=2100-01-01T00:00:00Z\n")
	writeWL(t, dir, "99-manual.conf", "10.0.0.4\n")

	rs := NewRuntimeState(dir)
	if err := rs.LoadWhitelists(); err != nil {
		t.Fatalf("LoadWhitelists: %v", err)
	}

	ipv4, _, expiry := rs.GetWhitelistSnapshotWithExpiry()

	if len(ipv4) != 2 {
		t.Fatalf("snapshot ipv4 count=%d, want 2 (%v)", len(ipv4), ipv4)
	}
	if _, ok := expiry["10.0.0.1"]; !ok {
		t.Fatalf("expiry map missing timed entry 10.0.0.1: %v", expiry)
	}
	if _, ok := expiry["10.0.0.4"]; ok {
		t.Fatalf("expiry map should NOT contain permanent entry 10.0.0.4: %v", expiry)
	}
}
