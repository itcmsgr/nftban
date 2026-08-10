// SPDX-License-Identifier: MPL-2.0
//
// A3-DIR: ENOENT from ReadDir does not prove absence.
//
// A dangling symlink or broken mount at whitelist.d makes os.ReadDir return
// ENOENT while the path is demonstrably present. Classifying that as the
// first-install shape yields an EMPTY desired state, and FullSync consumes that
// as authoritative and deletes every kernel whitelist member.
//
// MEASURED on lab4 (real RPM, v1.228.9) before this fix:
//
//	PRE  whitelist_ipv4 = 1.2.3.41 127.0.0.1 46.62.213.143
//	POST whitelist_ipv4 = <EMPTY>            rebuild exit 0
//	     "Whitelist reconcile verified (configured members present)."
//
// OBSERVATION FAILURE MUST NEVER BE INTERPRETED AS DESIRED SECURITY STATE EMPTY.
//
// Truly-absent stays empty-no-error: that is pinned by
// TestA3_AbsentWhitelistDir_IsEmptyNotError and is the first-install shape.
// Absence is data; present-but-unenumerable is an error.
package whitelist

import (
	"os"
	"path/filepath"
	"testing"
)

// STATE: whitelist.d is a DANGLING SYMLINK -> present, unenumerable -> ERROR.
// Root-proof: a dangling link fails to open for every uid, so this holds in
// root CI exactly as it does locally.
func TestA3Dir_DanglingSymlinkWhitelistDir_IsErrorNotEmpty(t *testing.T) {
	dir := t.TempDir()
	if err := os.Symlink(filepath.Join(dir, "no-such-target"), filepath.Join(dir, "whitelist.d")); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}

	v4, v6, err := LoadAllWhitelistsTyped(dir)
	if err == nil {
		t.Fatal("dangling whitelist.d returned SUCCESS — an unobservable source became " +
			"an empty desired state, which is what flushed the kernel whitelist on lab4")
	}
	if v4 != nil || v6 != nil {
		t.Error("maps must be nil on observation failure so a partial/empty result cannot be consumed")
	}
}

// The pre-fix behaviour, asserted directly: ReadDir reports ErrNotExist for this
// shape. Without this the test above cannot be distinguished from a fixture that
// simply never reached the ENOENT branch.
func TestA3Dir_MutationControl_ReadDirReportsENOENTForDanglingLink(t *testing.T) {
	dir := t.TempDir()
	wl := filepath.Join(dir, "whitelist.d")
	if err := os.Symlink(filepath.Join(dir, "no-such-target"), wl); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}
	if _, err := os.ReadDir(wl); err == nil || !os.IsNotExist(err) {
		t.Fatalf("fixture does not exercise the ENOENT branch (err=%v) — the arm above would be vacuous", err)
	}
	if _, err := os.Lstat(wl); err != nil {
		t.Fatalf("Lstat must still see the path, or the discriminator cannot work: %v", err)
	}
}

// A dangling symlink at the OPTIONAL main whitelist.conf is the same class:
// "optional file absent" must not absorb "present and unopenable".
func TestA3Dir_DanglingMainWhitelistConf_IsErrorNotAbsent(t *testing.T) {
	dir := t.TempDir()
	if err := os.MkdirAll(filepath.Join(dir, "whitelist.d"), 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.Symlink(filepath.Join(dir, "no-such-target"), filepath.Join(dir, "whitelist.conf")); err != nil {
		t.Skipf("cannot create symlink: %v", err)
	}
	if _, _, err := LoadAllWhitelistsTyped(dir); err == nil {
		t.Fatal("dangling whitelist.conf returned success — its contribution is unknown, not absent")
	}
}

// POSITIVE CONTROL: the fix must not turn into "error on everything". A readable
// directory with a real member still loads, and a readable EMPTY directory is
// still legitimate configured truth.
func TestA3Dir_ReadableDirStillLoads_AndEmptyIsStillData(t *testing.T) {
	dir := t.TempDir()
	wl := filepath.Join(dir, "whitelist.d")
	if err := os.MkdirAll(wl, 0o755); err != nil {
		t.Fatalf("mkdir: %v", err)
	}

	v4, _, err := LoadAllWhitelistsTyped(dir)
	if err != nil {
		t.Fatalf("readable EMPTY whitelist.d must be data, not error: %v", err)
	}
	if len(v4) != 0 {
		t.Errorf("empty dir should yield 0 members, got %d", len(v4))
	}

	if err := os.WriteFile(filepath.Join(wl, "10-a.conf"), []byte("1.2.3.41\n"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	v4, _, err = LoadAllWhitelistsTyped(dir)
	if err != nil {
		t.Fatalf("readable dir with a member must load: %v", err)
	}
	if _, ok := v4["1.2.3.41"]; !ok {
		t.Errorf("configured member not projected into desired state: %v", v4)
	}
}
