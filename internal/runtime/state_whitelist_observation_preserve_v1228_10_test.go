// =============================================================================
// NFTBan v1.228.10 PR-3 (A3) - whitelist observation failure preserves state
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="state_whitelist_observation_preserve_v1228_10_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-08-09"
// meta:description="v1.228.10 A3: LoadWhitelists must abort on an observation failure and leave the previously loaded whitelist intact, so FullSync never computes a destructive diff from an unknown desired state. Carries the owner-required case: kernel/runtime holds admin-A + admin-B, file A parses, file B is unreadable, and the partial union {admin-A} must never be adopted. Includes the positive control proving replacement DOES occur on a clean read, so preservation cannot be mistaken for a loader that never replaces."
// meta:input="None"
// meta:output="t.Fatal on destructive convergence from an unknown observation"
// meta:depends="testing,os,path/filepath"
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

const (
	a3AdminA = "203.0.113.10"
	a3AdminB = "203.0.113.11"
)

func a3Seed(t *testing.T, configDir string) *RuntimeState {
	t.Helper()
	rs := NewRuntimeState(configDir)
	now := time.Now()
	rs.WhitelistIPv4[a3AdminA] = &IPEntry{IP: a3AdminA, Source: "whitelist", AddedAt: now}
	rs.WhitelistIPv4[a3AdminB] = &IPEntry{IP: a3AdminB, Source: "whitelist", AddedAt: now}
	return rs
}

// The owner-required case. A partial observation must not become desired state,
// and the previously converged whitelist must survive untouched.
func TestA3_PartialObservation_PreservesPriorWhitelist(t *testing.T) {
	dir := t.TempDir()
	wlDir := filepath.Join(dir, "whitelist.d")
	if err := os.MkdirAll(wlDir, 0o750); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	// File A parses and contains ONLY admin-A: if the loader were to tolerate the
	// failure below, the resulting desired state would be {admin-A} and admin-B
	// would be deleted from the kernel on the next sync.
	if err := os.WriteFile(filepath.Join(wlDir, "10-a.conf"), []byte(a3AdminA+"\n"), 0o600); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	// File B is unreadable for every uid (dangling symlink), so the assertion does
	// not weaken when CI runs as root.
	if err := os.Symlink(filepath.Join(wlDir, "absent"), filepath.Join(wlDir, "20-b.conf")); err != nil {
		t.Skipf("symlinks unavailable in this environment: %v", err)
	}

	rs := a3Seed(t, dir)

	if err := rs.LoadWhitelists(); err == nil {
		t.Fatal("LoadWhitelists returned success on a partial observation — FullSync would apply a shortened desired state")
	}

	rs.mu.RLock()
	_, haveA := rs.WhitelistIPv4[a3AdminA]
	_, haveB := rs.WhitelistIPv4[a3AdminB]
	n := len(rs.WhitelistIPv4)
	rs.mu.RUnlock()

	if !haveA || !haveB || n != 2 {
		t.Fatalf("prior whitelist was not preserved: adminA=%v adminB=%v n=%d — this is the admin-lockout path", haveA, haveB, n)
	}
}

// An unenumerable whitelist.d likewise preserves prior state.
func TestA3_UnenumerableDir_PreservesPriorWhitelist(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "whitelist.d"), []byte("not a directory\n"), 0o600); err != nil {
		t.Fatalf("fixture: %v", err)
	}

	rs := a3Seed(t, dir)

	if err := rs.LoadWhitelists(); err == nil {
		t.Fatal("LoadWhitelists returned success on an unenumerable whitelist.d")
	}

	rs.mu.RLock()
	n := len(rs.WhitelistIPv4)
	rs.mu.RUnlock()
	if n != 2 {
		t.Fatalf("prior whitelist was replaced from an unknown observation: n=%d, want 2", n)
	}
}

// POSITIVE CONTROL. Preservation above must be the result of the abort, not of a
// loader that never replaces anything: on a clean read the replacement DOES happen
// and admin-B is legitimately removed.
func TestA3_CleanObservation_StillReplaces(t *testing.T) {
	dir := t.TempDir()
	wlDir := filepath.Join(dir, "whitelist.d")
	if err := os.MkdirAll(wlDir, 0o750); err != nil {
		t.Fatalf("fixture: %v", err)
	}
	if err := os.WriteFile(filepath.Join(wlDir, "10-a.conf"), []byte(a3AdminA+"\n"), 0o600); err != nil {
		t.Fatalf("fixture: %v", err)
	}

	rs := a3Seed(t, dir)

	if err := rs.LoadWhitelists(); err != nil {
		t.Fatalf("clean observation must succeed: %v", err)
	}

	rs.mu.RLock()
	_, haveA := rs.WhitelistIPv4[a3AdminA]
	_, haveB := rs.WhitelistIPv4[a3AdminB]
	rs.mu.RUnlock()

	if !haveA {
		t.Fatal("clean observation dropped admin-A")
	}
	if haveB {
		t.Fatal("clean observation did not replace: admin-B survived a complete desired state that omits it")
	}
}

// An absent whitelist.d is a legitimate first-install shape: it must load cleanly
// (and therefore replace), never abort.
func TestA3_AbsentDir_IsNotAnObservationFailure(t *testing.T) {
	dir := t.TempDir()
	rs := a3Seed(t, dir)

	if err := rs.LoadWhitelists(); err != nil {
		t.Fatalf("absent whitelist.d must not fail the load (first-install shape): %v", err)
	}
}
