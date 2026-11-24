// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package nftlock

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func exclTestBoundary(t *testing.T, wait time.Duration) *Boundary {
	t.Helper()
	d := t.TempDir()
	return &Boundary{Wait: wait, LockPath: filepath.Join(d, "nft_writers.lock"), IntentPath: filepath.Join(d, "nft_writers.intent")}
}

func TestBeginExclusiveFree(t *testing.T) {
	b := exclTestBoundary(t, time.Second)
	release, err := b.BeginExclusive()
	if err != nil {
		t.Fatalf("free boundary: %v", err)
	}
	data, _ := os.ReadFile(b.IntentPath)
	if !strings.HasPrefix(string(data), "pid=") {
		t.Errorf("intent not published while waiting/holding: %q", data)
	}
	// While held, a daemon shared section cannot open.
	if f, err := b.tryShared(); err == nil {
		_ = f.Close()
		t.Fatal("shared section opened while EXCLUSIVE was held")
	}
	release()
	if _, err := os.Stat(b.IntentPath); !os.IsNotExist(err) {
		t.Errorf("intent not removed on release: %v", err)
	}
	if f, err := b.tryShared(); err != nil {
		t.Fatalf("shared section after release: %v", err)
	} else {
		_ = f.Close()
	}
}

func TestBeginExclusiveBusyIsBounded(t *testing.T) {
	b := exclTestBoundary(t, 150*time.Millisecond)
	// A daemon write section in flight: LOCK_SH on the same file.
	f, err := os.OpenFile(b.LockPath, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	start := time.Now()
	release, err := b.BeginExclusive()
	if err == nil {
		release()
		t.Fatal("EXCLUSIVE granted while a shared section was open")
	}
	if !errors.Is(err, ErrBusy) {
		t.Fatalf("want ErrBusy, got %v", err)
	}
	if el := time.Since(start); el > 2*time.Second {
		t.Fatalf("wait not bounded: %v", el)
	}
	if _, err := os.Stat(b.IntentPath); !os.IsNotExist(err) {
		t.Errorf("intent left behind after busy: %v", err)
	}
}
