// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package nftlock

// v1.238 SEC-WRITE-BOUNDARY-LEGACY-ROOT-LOCKS-IN-NFTBAN-OWNED-RUN-DIR: the canonical lock is in
// the root-only writers directory; for one release the holder also takes the legacy lock in
// /run/nftban, after the canonical one, never unlinking or replacing it and never following a
// symlink there. Temp directories only.

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func legacySandbox(t *testing.T) (canon, legacy string) {
	t.Helper()
	d := t.TempDir()
	if err := os.MkdirAll(filepath.Join(d, "run-nftban"), 0o755); err != nil {
		t.Fatal(err)
	}
	ol, oleg := lockPath, legacyLockPath
	lockPath = filepath.Join(d, "writers", "nft_operations.lock")
	legacyLockPath = filepath.Join(d, "run-nftban", "nft_operations.lock")
	t.Cleanup(func() { lockPath, legacyLockPath = ol, oleg })
	return lockPath, legacyLockPath
}

// holdLegacy simulates a v1.237 process: it holds only the legacy path.
func holdLegacy(t *testing.T, path string, how int) *os.File {
	t.Helper()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o640)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(f.Fd()), how|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	return f
}

func TestNftLockCanonicalPathsAndDir(t *testing.T) {
	if LockPath != "/run/nftban-writers/nft_operations.lock" || LegacyLockPath != "/run/nftban/nft_operations.lock" {
		t.Fatalf("paths: %s %s", LockPath, LegacyLockPath)
	}
	canon, legacy := legacySandbox(t)
	l, err := TryAcquireExclusive()
	if err != nil {
		t.Fatal(err)
	}
	fi, err := os.Stat(filepath.Dir(canon))
	if err != nil || fi.Mode().Perm() != 0o700 {
		t.Fatalf("canonical dir must be created 0700 (fhs-spec): %v %v", fi, err)
	}
	if _, err := os.Stat(legacy); err != nil {
		t.Fatalf("legacy lock must be taken too: %v", err)
	}
	l.Release()
}

func TestNftLockOldVersionHolderExcludesNewHolder(t *testing.T) {
	_, legacy := legacySandbox(t)
	old := holdLegacy(t, legacy, syscall.LOCK_EX)
	defer old.Close()
	if _, err := TryAcquireExclusive(); !errors.Is(err, ErrLockBusy) {
		t.Fatalf("try while a v1.237 process holds the legacy lock: %v", err)
	}
	if _, err := AcquireExclusive(200 * time.Millisecond); !errors.Is(err, ErrLockTimeout) {
		t.Fatalf("acquire while a v1.237 process holds the legacy lock: %v", err)
	}
	// a failed attempt must not keep the canonical lock: a shared holder of the canonical lock
	// alone (another v1.238 reader) is possible right away
	f, err := os.OpenFile(lockPath, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatalf("canonical lock left held after a failed attempt: %v", err)
	}
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	f.Close()
	_ = syscall.Flock(int(old.Fd()), syscall.LOCK_UN)
	l, err := TryAcquireExclusive()
	if err != nil {
		t.Fatalf("after the old holder released: %v", err)
	}
	l.Release()
	if _, err := os.Stat(legacy); err != nil {
		t.Fatalf("legacy lock file must never be unlinked: %v", err)
	}
}

func TestNftLockNewHolderExcludesOldVersion(t *testing.T) {
	_, legacy := legacySandbox(t)
	l, err := AcquireExclusive(time.Second)
	if err != nil {
		t.Fatal(err)
	}
	f, err := os.OpenFile(legacy, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err == nil {
		t.Fatal("a v1.237 process could take the legacy lock while a v1.238 holder is inside")
	}
	l.Release()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatalf("legacy lock not released: %v", err)
	}
}

func TestNftLockSharedHoldersCoexist(t *testing.T) {
	legacySandbox(t)
	a, err := AcquireShared(time.Second)
	if err != nil {
		t.Fatal(err)
	}
	b, err := AcquireShared(time.Second)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := TryAcquireExclusive(); !errors.Is(err, ErrLockBusy) {
		t.Fatalf("exclusive while shared held: %v", err)
	}
	a.Release()
	b.Release()
}

func TestNftLockLegacyDirAbsentOrSymlink(t *testing.T) {
	_, legacy := legacySandbox(t)
	// a symlink placed at the legacy name is not followed (target never created) nor removed
	target := filepath.Join(filepath.Dir(legacy), "elsewhere")
	if err := os.Symlink(target, legacy); err != nil {
		t.Fatal(err)
	}
	l, err := TryAcquireExclusive()
	if err != nil {
		t.Fatalf("symlink at the legacy name: %v", err)
	}
	l.Release()
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatal("the symlink target was created (followed)")
	}
	if fi, err := os.Lstat(legacy); err != nil || fi.Mode()&os.ModeSymlink == 0 {
		t.Fatal("the legacy entry was replaced")
	}
	// legacy directory absent (fresh v1.238 host without /run/nftban yet): canonical only
	if err := os.RemoveAll(filepath.Dir(legacy)); err != nil {
		t.Fatal(err)
	}
	l, err = TryAcquireExclusive()
	if err != nil || l.legacy != nil {
		t.Fatalf("absent legacy dir: %v legacy=%v", err, l)
	}
	l.Release()
}
