// =============================================================================
// NFTBan - v1.228.10 PR-3 (A3): whitelist observation failure must not become
// an empty desired state
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="whitelist_observation_failure_v1228_10_test"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-08-09"
// meta:description="Tests for audit finding A3: the whitelist loader must distinguish a legitimately absent whitelist.d (empty, no error) from an unenumerable directory and from a participating file that cannot be read or parsed (both errors). Proves no partial union can become authoritative desired state. Injections are root-proof (ENOTDIR, dangling symlink) so the assertions hold when CI runs as root; permission-based injections run additionally when the suite is non-root."
// meta:input="None (t.TempDir fixtures)"
// meta:output="None"
// meta:depends="testing"
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
	"testing"
)

// STATE 1: whitelist.d legitimately absent -> empty desired state, NO error.
// A first install must not be reported as degraded, and must not block a sync.
func TestA3_AbsentWhitelistDir_IsEmptyNotError(t *testing.T) {
	dir := t.TempDir() // no whitelist.d, no whitelist.conf

	ipv4, ipv6, err := LoadAllWhitelistsTyped(dir)
	if err != nil {
		t.Fatalf("absent whitelist.d must not be an error (first-install shape): %v", err)
	}
	if len(ipv4) != 0 || len(ipv6) != 0 {
		t.Fatalf("expected empty desired state, got ipv4=%d ipv6=%d", len(ipv4), len(ipv6))
	}
}

// STATE 2: whitelist.d present but unenumerable -> error, never empty-with-success.
// Injection is a non-directory at the whitelist.d path, which yields ENOTDIR for
// every uid — the assertion must not weaken to a skip when CI runs as root.
func TestA3_UnenumerableWhitelistDir_ReturnsError(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "whitelist.d"), []byte("not a directory\n"), 0o600); err != nil {
		t.Fatalf("fixture: %v", err)
	}

	ipv4, ipv6, err := LoadAllWhitelistsTyped(dir)
	if err == nil {
		t.Fatal("unenumerable whitelist.d returned success — an unreadable whitelist is UNKNOWN, not empty")
	}
	if ipv4 != nil || ipv6 != nil {
		t.Fatal("maps must be nil on error so a partial result cannot be consumed by accident")
	}
}

// STATE 2 (permission variant): EACCES on the directory. Root bypasses the mode
// bits, so this variant only runs unprivileged; the ENOTDIR test above carries
// the invariant when the suite runs as root.
func TestA3_UnreadableWhitelistDir_EACCES_ReturnsError(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("running as root: mode bits are bypassed; covered by TestA3_UnenumerableWhitelistDir_ReturnsError")
	}
	dir := t.TempDir()
	wlDir := filepath.Join(dir, "whitelist.d")
	if err := os.MkdirAll(wlDir, 0o750); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(wlDir, "99-manual.conf"), []byte("203.0.113.10\n"), 0o600); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	if err := os.Chmod(wlDir, 0o000); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	t.Cleanup(func() { _ = os.Chmod(wlDir, 0o750) })

	// Negative control: prove the injection actually took effect.
	if _, derr := os.ReadDir(wlDir); derr == nil {
		t.Skip("chmod 000 did not deny enumeration in this environment; injection not proven")
	}

	if _, _, err := LoadAllWhitelistsTyped(dir); err == nil {
		t.Fatal("EACCES on whitelist.d returned success — this is the admin-lockout enabler")
	}
}

// STATE 3: the directory enumerates, but a participating file cannot be read.
// This is the case the fix must NOT stop at: a partial union is indistinguishable
// from a deliberate removal.
//
//	PRESTATE  desired whitelist = admin-A (file A) + admin-B (file B)
//	SOURCE    file A parses, file B is unreadable
//	EXPECT    error; no maps
//	FORBIDDEN desired state = {admin-A}
//
// Injection is a dangling symlink, which fails to open for every uid.
func TestA3_UnreadableParticipatingFile_NoPartialUnion(t *testing.T) {
	const adminA = "203.0.113.10"

	dir := t.TempDir()
	wlDir := filepath.Join(dir, "whitelist.d")
	if err := os.MkdirAll(wlDir, 0o750); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(wlDir, "10-a.conf"), []byte(adminA+"\n"), 0o600); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	if err := os.Symlink(filepath.Join(wlDir, "does-not-exist"), filepath.Join(wlDir, "20-b.conf")); err != nil {
		t.Skipf("symlinks unavailable in this environment: %v", err)
	}

	// Negative control: file A really is readable and really does parse, so a
	// failure below cannot be blamed on a broken fixture.
	okv4, _, okErr := LoadAllWhitelistsTyped(func() string {
		control := t.TempDir()
		cDir := filepath.Join(control, "whitelist.d")
		if err := os.MkdirAll(cDir, 0o750); err != nil {
			t.Fatalf("fixture: %v", err)
		}
		if err := os.WriteFile(filepath.Join(cDir, "10-a.conf"), []byte(adminA+"\n"), 0o600); err != nil {
			t.Fatalf("fixture: %v", err)
		}
		return control
	}())
	if okErr != nil || len(okv4) != 1 {
		t.Fatalf("negative control failed: file A must load cleanly on its own (err=%v n=%d)", okErr, len(okv4))
	}

	ipv4, ipv6, err := LoadAllWhitelistsTyped(dir)
	if err == nil {
		t.Fatal("unreadable participating file returned success — a shortened union would be applied as desired state")
	}
	if ipv4 != nil || ipv6 != nil {
		t.Fatal("maps must be nil on error")
	}
	if _, present := ipv4[adminA]; present {
		t.Fatal("FORBIDDEN: partial desired state {admin-A} escaped the loader")
	}
}

// A participating whitelist.conf that exists but cannot be read is an error too;
// its absence remains legitimate. Injection: a directory at the whitelist.conf
// path (EISDIR on open) — root-proof.
func TestA3_UnreadableMainFile_ReturnsError(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "whitelist.conf"), 0o750); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	if err := os.MkdirAll(filepath.Join(dir, "whitelist.d"), 0o750); err != nil {
		t.Fatalf("fixture: %v", err)
	}

	if _, _, err := LoadAllWhitelistsTyped(dir); err == nil {
		t.Fatal("unreadable whitelist.conf returned success — its contribution is unknown, not absent")
	}
}

// The dual API must not launder an error into empty maps.
func TestA3_LegacyAPI_PropagatesObservationFailure(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "whitelist.d"), []byte("not a directory\n"), 0o600); err != nil {
		t.Fatalf("fixture: %v", err)
	}

	ipv4, ipv6, err := LoadAllWhitelists(dir)
	if err == nil {
		t.Fatal("LoadAllWhitelists must propagate the observation failure")
	}
	if ipv4 != nil || ipv6 != nil {
		t.Fatal("legacy API must not return usable maps alongside an error")
	}
}
