// =============================================================================
// NFTBan v1.236 - write boundary tests (temp lock files; real flock(2))
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="nftlock-boundary-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-23"
// meta:description="Boundary: shared section vs an exclusive holder (bounded wait, ErrBusy), live vs stale intent, nested entries never wait, drain (exclusive granted only after the section closes)"
// meta:inventory.privileges="none"
// =============================================================================

package nftlock

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func testBoundary(t *testing.T, wait time.Duration) *Boundary {
	t.Helper()
	d := t.TempDir()
	return &Boundary{Wait: wait, LockPath: filepath.Join(d, "w.lock"), IntentPath: filepath.Join(d, "w.intent")}
}

// holdExclusive takes LOCK_EX on path as a separate open file (another process's view).
func holdExclusive(t *testing.T, path string) func() {
	t.Helper()
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o640)
	if err != nil {
		t.Fatal(err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatalf("could not take LOCK_EX: %v", err)
	}
	return func() { _ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN); _ = f.Close() }
}

func tryExclusive(path string) bool {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0o640)
	if err != nil {
		return false
	}
	defer f.Close()
	if syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB) != nil {
		return false
	}
	_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
	return true
}

func TestBoundaryBusyWhileReplacementHoldsExclusive(t *testing.T) {
	b := testBoundary(t, 150*time.Millisecond)
	unlock := holdExclusive(t, b.LockPath)
	start := time.Now()
	if _, err := b.Begin(); !errors.Is(err, ErrBusy) {
		t.Fatalf("want ErrBusy while LOCK_EX is held, got %v", err)
	}
	if time.Since(start) < 150*time.Millisecond {
		t.Fatal("must wait (bounded) before reporting busy")
	}
	unlock()
	rel, err := b.Begin()
	if err != nil {
		t.Fatalf("after release: %v", err)
	}
	rel()
}

func TestBoundaryDrainExclusiveOnlyAfterSectionCloses(t *testing.T) {
	b := testBoundary(t, time.Second)
	rel, err := b.Begin()
	if err != nil {
		t.Fatal(err)
	}
	if tryExclusive(b.LockPath) {
		t.Fatal("LOCK_EX granted while a daemon write section is open (no drain)")
	}
	rel()
	if !tryExclusive(b.LockPath) {
		t.Fatal("LOCK_EX not granted after the section closed")
	}
}

func TestBoundaryLiveIntentStopsNewSectionsStaleIntentIgnored(t *testing.T) {
	b := testBoundary(t, 150*time.Millisecond)
	boot, _ := os.ReadFile("/proc/sys/kernel/random/boot_id")
	live := fmt.Sprintf("pid=%d boot=%s\n", os.Getpid(), string(boot))
	if err := os.WriteFile(b.IntentPath, []byte(live), 0o640); err != nil {
		t.Fatal(err)
	}
	if _, err := b.Begin(); !errors.Is(err, ErrBusy) {
		t.Fatalf("live intent: a NEW section must wait, got %v", err)
	}
	// A dead pid (very large, never allocated) = stale: ignored.
	if err := os.WriteFile(b.IntentPath, []byte("pid=999999999 boot=x\n"), 0o640); err != nil {
		t.Fatal(err)
	}
	rel, err := b.Begin()
	if err != nil {
		t.Fatalf("stale intent must be ignored, got %v", err)
	}
	rel()
}

func TestBoundaryNestedEntryJoinsWithoutWaiting(t *testing.T) {
	b := testBoundary(t, 150*time.Millisecond)
	outer, err := b.Begin()
	if err != nil {
		t.Fatal(err)
	}
	boot, _ := os.ReadFile("/proc/sys/kernel/random/boot_id")
	if err := os.WriteFile(b.IntentPath, []byte(fmt.Sprintf("pid=%d boot=%s", os.Getpid(), boot)), 0o640); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	inner, err := b.Begin()
	if err != nil || time.Since(start) > 50*time.Millisecond {
		t.Fatalf("a nested entry must join the open section at once (no deadlock against the intent): err=%v", err)
	}
	inner()
	if tryExclusive(b.LockPath) {
		t.Fatal("inner release must not drop the lock while the outer section is open")
	}
	outer()
	if !tryExclusive(b.LockPath) {
		t.Fatal("lock not released after the outer section closed")
	}
}
