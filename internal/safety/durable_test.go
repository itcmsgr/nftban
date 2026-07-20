// =============================================================================
// NFTBan v1.222 - Durable file primitive tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="durable_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-07-20"
// meta:description="Proves the v1.222 power-loss-durability contract of WriteFileDurable/FsyncDir/StageFile/DurableRename: a successful durable replace produces the exact bytes+mode with no stray temp; a failure before the rename leaves the previous destination intact and cleans up the temp; a rename failure is reported and the temp is removed (no incomplete destination); StageFile writes an fsync'd candidate without activating any target; DurableRename moves atomically within a directory. These are the primitives the logretention two-file activation transaction routes through, and the fix (F2) that SafeWriteFile now fsyncs the parent directory after rename."
// meta:input="temp dirs"
// meta:output="t.Fatal on contract violation"
// meta:depends="testing,os,path/filepath,bytes"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package safety

import (
	"bytes"
	"os"
	"path/filepath"
	"testing"
)

func onlyEntry(t *testing.T, dir, want string) {
	t.Helper()
	ents, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir %s: %v", dir, err)
	}
	if len(ents) != 1 || ents[0].Name() != want {
		var names []string
		for _, e := range ents {
			names = append(names, e.Name())
		}
		t.Fatalf("dir %s entries = %v; want only %q (a stray temp means cleanup/atomicity failed)", dir, names, want)
	}
}

// TestWriteFileDurable_ReplacesAndMode: a successful durable write produces the
// exact bytes and the intended mode, and leaves no stray temp behind.
func TestWriteFileDurable_ReplacesAndMode(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "state.json")

	if err := WriteFileDurable(target, []byte("v1"), 0o600); err != nil {
		t.Fatalf("WriteFileDurable seed: %v", err)
	}
	if err := WriteFileDurable(target, []byte("v2-longer"), 0o600); err != nil {
		t.Fatalf("WriteFileDurable replace: %v", err)
	}

	got, err := os.ReadFile(target)
	if err != nil {
		t.Fatalf("ReadFile: %v", err)
	}
	if string(got) != "v2-longer" {
		t.Fatalf("content = %q; want %q", got, "v2-longer")
	}
	fi, err := os.Stat(target)
	if err != nil {
		t.Fatalf("Stat: %v", err)
	}
	if fi.Mode().Perm() != 0o600 {
		t.Fatalf("mode = %o; want 0600", fi.Mode().Perm())
	}
	onlyEntry(t, dir, "state.json")
}

// TestSafeWriteFile_DirFsyncViaDelegation: SafeWriteFile now delegates to
// WriteFileDurable, so it honors mode and leaves no stray temp (the F2 fix means
// callers repo-wide get the parent-dir fsync). Content correctness is asserted;
// the dir fsync itself is best-effort and not observable from userspace.
func TestSafeWriteFile_DirFsyncViaDelegation(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "s.json")
	if err := SafeWriteFile(target, []byte(`{"ok":true}`), 0o640); err != nil {
		t.Fatalf("SafeWriteFile: %v", err)
	}
	got, _ := os.ReadFile(target)
	if string(got) != `{"ok":true}` {
		t.Fatalf("content = %q", got)
	}
	fi, _ := os.Stat(target)
	if fi.Mode().Perm() != 0o640 {
		t.Fatalf("mode = %o; want 0640", fi.Mode().Perm())
	}
	onlyEntry(t, dir, "s.json")
}

// TestWriteFileDurable_PreservesExistingOnPreRenameFailure: when the write fails
// BEFORE the rename (here: the parent directory becomes world-writable, so
// ValidateDirectory rejects it), the previous destination content is untouched
// and no temp is left behind.
func TestWriteFileDurable_PreservesExistingOnPreRenameFailure(t *testing.T) {
	parent := t.TempDir()
	sub := filepath.Join(parent, "d")
	if err := os.Mkdir(sub, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	target := filepath.Join(sub, "state.json")
	if err := WriteFileDurable(target, []byte("original"), 0o644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	// Make the parent world-writable so ValidateDirectory fails before any temp is
	// created or rename attempted.
	if err := os.Chmod(sub, 0o777); err != nil {
		t.Fatalf("chmod: %v", err)
	}
	defer func() { _ = os.Chmod(sub, 0o700) }() // restore for TempDir cleanup

	err := WriteFileDurable(target, []byte("SHOULD-NOT-LAND"), 0o644)
	if err == nil {
		t.Fatal("expected error on world-writable parent, got nil")
	}
	got, rerr := os.ReadFile(target)
	if rerr != nil {
		t.Fatalf("ReadFile after failed write: %v", rerr)
	}
	if string(got) != "original" {
		t.Fatalf("destination mutated on pre-rename failure: %q", got)
	}
	// Restore perms then confirm no stray temp remained.
	if err := os.Chmod(sub, 0o700); err != nil {
		t.Fatalf("chmod restore: %v", err)
	}
	onlyEntry(t, sub, "state.json")
}

// TestWriteFileDurable_RenameFailureCleansTemp: force the atomic rename to fail
// (the destination path is an existing non-empty directory) and assert the error
// is reported and the temp file is cleaned up — no incomplete destination.
func TestWriteFileDurable_RenameFailureCleansTemp(t *testing.T) {
	dir := t.TempDir()
	// target is an existing directory; renaming a file onto it must fail.
	target := filepath.Join(dir, "target")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatalf("mkdir target: %v", err)
	}
	// Put a file inside so the dir is non-empty (rename-over must fail on all FSes).
	if err := os.WriteFile(filepath.Join(target, "keep"), []byte("x"), 0o644); err != nil {
		t.Fatalf("seed inner: %v", err)
	}

	err := WriteFileDurable(target, []byte("data"), 0o644)
	if err == nil {
		t.Fatal("expected rename failure onto existing non-empty dir, got nil")
	}
	// The temp file (.nftban-safe-*) must have been cleaned up; dir contains only
	// the target directory.
	onlyEntry(t, dir, "target")
}

// TestFsyncDir_OKAndMissing: FsyncDir succeeds on a real directory and errors on
// a missing one.
func TestFsyncDir_OKAndMissing(t *testing.T) {
	dir := t.TempDir()
	if err := FsyncDir(dir); err != nil {
		t.Fatalf("FsyncDir(existing) = %v; want nil", err)
	}
	if err := FsyncDir(filepath.Join(dir, "nope")); err == nil {
		t.Fatal("FsyncDir(missing) = nil; want error")
	}
}

// TestStageFile_WritesAndReturnsPath: StageFile writes an fsync'd candidate with
// the intended mode inside the staging dir and returns its path, without
// activating any final target.
func TestStageFile_WritesAndReturnsPath(t *testing.T) {
	dir := t.TempDir()
	target := filepath.Join(dir, "nftban") // the eventual activation target
	path, err := StageFile(dir, "nftban.gen-*", []byte("CANDIDATE\n"), 0o644)
	if err != nil {
		t.Fatalf("StageFile: %v", err)
	}
	if filepath.Dir(path) != dir {
		t.Fatalf("staged path %q not under staging dir %q", path, dir)
	}
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("ReadFile staged: %v", err)
	}
	if string(got) != "CANDIDATE\n" {
		t.Fatalf("staged content = %q", got)
	}
	fi, _ := os.Stat(path)
	if fi.Mode().Perm() != 0o644 {
		t.Fatalf("staged mode = %o; want 0644", fi.Mode().Perm())
	}
	// It must NOT have activated the target.
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("StageFile must not create the activation target; Stat err = %v", err)
	}
}

// TestDurableRename_MovesAtomically: DurableRename moves the source onto the
// destination (replacing it) within the same directory; the destination holds
// the new bytes and the source is gone.
func TestDurableRename_MovesAtomically(t *testing.T) {
	dir := t.TempDir()
	src := filepath.Join(dir, "src")
	dst := filepath.Join(dir, "dst")
	if err := os.WriteFile(dst, []byte("OLD"), 0o644); err != nil {
		t.Fatalf("seed dst: %v", err)
	}
	if err := os.WriteFile(src, []byte("NEW"), 0o644); err != nil {
		t.Fatalf("seed src: %v", err)
	}
	if err := DurableRename(src, dst); err != nil {
		t.Fatalf("DurableRename: %v", err)
	}
	got, _ := os.ReadFile(dst)
	if string(got) != "NEW" {
		t.Fatalf("dst = %q; want NEW", got)
	}
	if _, err := os.Stat(src); !os.IsNotExist(err) {
		t.Fatalf("src should be gone after rename; Stat err = %v", err)
	}
	if !bytes.Equal(got, []byte("NEW")) {
		t.Fatalf("dst content mismatch")
	}
}
