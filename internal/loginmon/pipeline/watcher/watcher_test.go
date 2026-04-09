// =============================================================================
// NFTBan v1.80 - pipeline watcher tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: watcher
// Purpose: Tests for MemoryWatcher and PollingWatcher.
//
// meta:name="loginmon_pipeline_watcher_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="watcher"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Tests for watcher implementations"
//
// meta:inventory.files="watcher_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package watcher

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestMemoryWatcher_BasicFlow(t *testing.T) {
	w := NewMemoryWatcher("test", 8)
	ctx := context.Background()
	if err := w.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer w.Stop()

	if !w.Push([]byte("hello")) {
		t.Fatal("Push returned false")
	}
	if !w.Push([]byte("world")) {
		t.Fatal("Push returned false")
	}

	// Read both lines.
	got := []string{}
	for i := 0; i < 2; i++ {
		select {
		case rl := <-w.Lines():
			got = append(got, string(rl.Line))
		case <-time.After(time.Second):
			t.Fatal("timeout waiting for line")
		}
	}
	if len(got) != 2 || got[0] != "hello" || got[1] != "world" {
		t.Errorf("got %v", got)
	}
}

func TestMemoryWatcher_DoubleStartFails(t *testing.T) {
	w := NewMemoryWatcher("test", 8)
	if err := w.Start(context.Background()); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if err := w.Start(context.Background()); err != ErrAlreadyStarted {
		t.Errorf("second Start: got %v, want ErrAlreadyStarted", err)
	}
	w.Stop()
}

func TestMemoryWatcher_StopClosesChannel(t *testing.T) {
	w := NewMemoryWatcher("test", 8)
	w.Start(context.Background())
	w.Stop()

	// After Stop, the channel should be closed.
	select {
	case _, ok := <-w.Lines():
		if ok {
			t.Error("expected closed channel")
		}
	case <-time.After(time.Second):
		t.Error("timeout waiting for closed channel")
	}

	// Push after stop returns false.
	if w.Push([]byte("late")) {
		t.Error("Push after Stop should return false")
	}
}

func TestPollingWatcher_BasicTail(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "test.log")
	if err := os.WriteFile(logPath, []byte("seed line\n"), 0644); err != nil {
		t.Fatalf("seed write: %v", err)
	}

	w := NewPollingWatcher(PollingWatcherOptions{
		Source:       "test",
		Path:         logPath,
		PollInterval: 50 * time.Millisecond,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := w.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer w.Stop()

	// Append a line; PollingWatcher seeks to EOF on first open, so only
	// post-Start writes are visible.
	time.Sleep(100 * time.Millisecond) // let the poller settle
	f, err := os.OpenFile(logPath, os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		t.Fatalf("open append: %v", err)
	}
	if _, err := f.WriteString("after start\n"); err != nil {
		t.Fatalf("write: %v", err)
	}
	f.Close()

	select {
	case rl := <-w.Lines():
		if string(rl.Line) != "after start" {
			t.Errorf("line: got %q, want %q", rl.Line, "after start")
		}
		if rl.Source != "test" {
			t.Errorf("source: got %q", rl.Source)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("timeout waiting for line")
	}
}

func TestPollingWatcher_RotationByName(t *testing.T) {
	dir := t.TempDir()
	logPath := filepath.Join(dir, "rotation.log")
	if err := os.WriteFile(logPath, []byte("seed\n"), 0644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	w := NewPollingWatcher(PollingWatcherOptions{
		Source:       "rot",
		Path:         logPath,
		PollInterval: 50 * time.Millisecond,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := w.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer w.Stop()

	time.Sleep(100 * time.Millisecond)

	// Simulate logrotate: rename the file then create a new one.
	rotated := filepath.Join(dir, "rotation.log.1")
	if err := os.Rename(logPath, rotated); err != nil {
		t.Fatalf("rename: %v", err)
	}
	if err := os.WriteFile(logPath, []byte("post-rotation line\n"), 0644); err != nil {
		t.Fatalf("recreate: %v", err)
	}

	// Wait for the new line to come through.
	select {
	case rl := <-w.Lines():
		if string(rl.Line) != "post-rotation line" {
			t.Errorf("line: got %q", rl.Line)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("timeout waiting for post-rotation line")
	}
}
