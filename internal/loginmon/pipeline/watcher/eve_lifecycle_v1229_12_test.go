// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

// A12 / GitHub #53: the EVE reader used to hold its file BY DESCRIPTOR, so a
// logrotate rename+create left it on the old inode and detection silently
// stopped. EVE now runs on PollingWatcher, so these are the lifecycle
// guarantees the EVE path depends on. TestPollingWatcher_RotationByName already
// proves a post-rotation line is delivered; this file covers what it does not:
// no replay, no duplicates, truncation, and the logrotate absence window.
package watcher

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// collect drains lines until quiet for the given settle period.
func collect(t *testing.T, w *PollingWatcher, settle time.Duration) []string {
	t.Helper()
	var got []string
	deadline := time.After(10 * time.Second)
	for {
		select {
		case rl, ok := <-w.Lines():
			if !ok {
				return got
			}
			got = append(got, string(rl.Line))
		case <-time.After(settle):
			return got
		case <-deadline:
			return got
		}
	}
}

func TestPollingWatcher_A12_NoReplayNoDuplicatesAcrossRotation(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "eve.json")
	// Historical content that must NEVER be replayed on start.
	if err := os.WriteFile(p, []byte("{\"old\":1}\n{\"old\":2}\n"), 0644); err != nil {
		t.Fatalf("seed: %v", err)
	}

	w := NewPollingWatcher(PollingWatcherOptions{Source: "eve", Path: p, PollInterval: 40 * time.Millisecond})
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := w.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer w.Stop()

	// 1. No replay: nothing from the pre-existing file.
	if got := collect(t, w, 300*time.Millisecond); len(got) != 0 {
		t.Fatalf("start replayed historical alerts (must seek to EOF): %v", got)
	}

	// 2. Live append is delivered.
	f, err := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		t.Fatalf("append open: %v", err)
	}
	if _, err := f.WriteString("{\"live\":1}\n"); err != nil {
		t.Fatalf("write: %v", err)
	}
	f.Close()
	if got := collect(t, w, 400*time.Millisecond); len(got) != 1 || got[0] != "{\"live\":1}" {
		t.Fatalf("live append: got %v", got)
	}

	// 3. logrotate rename+create: new file's content delivered exactly once,
	//    and the rotated file's content is NOT re-read.
	if err := os.Rename(p, p+".1"); err != nil {
		t.Fatalf("rename: %v", err)
	}
	if err := os.WriteFile(p, []byte("{\"post\":1}\n{\"post\":2}\n"), 0644); err != nil {
		t.Fatalf("recreate: %v", err)
	}
	got := collect(t, w, 800*time.Millisecond)
	if len(got) != 2 || got[0] != "{\"post\":1}" || got[1] != "{\"post\":2}" {
		t.Fatalf("post-rotation delivery wrong (duplicates or loss): %v", got)
	}
}

func TestPollingWatcher_A12_TruncationAndAbsenceWindow(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "eve.json")
	if err := os.WriteFile(p, []byte("{\"seed\":1}\n"), 0644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	w := NewPollingWatcher(PollingWatcherOptions{Source: "eve", Path: p, PollInterval: 40 * time.Millisecond})
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := w.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer w.Stop()
	collect(t, w, 200*time.Millisecond) // drain start

	// copytruncate: truncate in place, then write fresh content.
	if err := os.Truncate(p, 0); err != nil {
		t.Fatalf("truncate: %v", err)
	}
	if err := os.WriteFile(p, []byte("{\"after_trunc\":1}\n"), 0644); err != nil {
		t.Fatalf("rewrite: %v", err)
	}
	if got := collect(t, w, 800*time.Millisecond); len(got) != 1 || got[0] != "{\"after_trunc\":1}" {
		t.Fatalf("truncation handling: got %v", got)
	}

	// logrotate swap window: file briefly absent, then recreated.
	if err := os.Remove(p); err != nil {
		t.Fatalf("remove: %v", err)
	}
	time.Sleep(150 * time.Millisecond)
	if err := os.WriteFile(p, []byte("{\"after_absence\":1}\n"), 0644); err != nil {
		t.Fatalf("recreate: %v", err)
	}
	if got := collect(t, w, 1200*time.Millisecond); len(got) != 1 || got[0] != "{\"after_absence\":1}" {
		t.Fatalf("absence window handling: got %v", got)
	}
}

// W01 defect 1: a line still being written must NOT be emitted as a record, must
// not be re-emitted on subsequent polls, and must arrive exactly once — whole —
// after its newline lands.
//
// Before the fix the offset advanced by len+1 for an unterminated line, adding a
// phantom byte for a terminator never consumed. The offset then exceeded the file
// size, the size check read that as truncation, rewound to 0 and re-emitted the
// same partial every poll: one 9-byte partial produced ~200 emissions in 10s.
func TestPollingWatcher_W01_PartialLineHeldUntilTerminated(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "eve.json")
	if err := os.WriteFile(p, []byte(""), 0644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	w := NewPollingWatcher(PollingWatcherOptions{Source: "eve", Path: p, PollInterval: 40 * time.Millisecond})
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := w.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer w.Stop()
	collect(t, w, 200*time.Millisecond)

	f, err := os.OpenFile(p, os.O_APPEND|os.O_WRONLY, 0644)
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer f.Close()

	if _, err := f.WriteString("{\"split\":"); err != nil { // no terminator yet
		t.Fatalf("write head: %v", err)
	}
	// Several poll cycles must pass with NOTHING emitted and NO repetition.
	if got := collect(t, w, 500*time.Millisecond); len(got) != 0 {
		t.Fatalf("unterminated tail emitted (%d records) — must be held: %v", len(got), got)
	}
	if _, err := f.WriteString("1}\n"); err != nil {
		t.Fatalf("write tail: %v", err)
	}
	got := collect(t, w, 600*time.Millisecond)
	if len(got) != 1 || got[0] != "{\"split\":1}" {
		t.Fatalf("completed record: want exactly one whole line, got %v", got)
	}
}

// W01 defect 2, second arm: copytruncate that leaves the file SMALLER than the
// committed offset must be detected by the size check.
func TestPollingWatcher_W01_CopytruncateSmallerThanOffset(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "eve.json")
	if err := os.WriteFile(p, []byte("{\"a\":1}\n{\"b\":2}\n{\"c\":3}\n"), 0644); err != nil {
		t.Fatalf("seed: %v", err)
	}
	w := NewPollingWatcher(PollingWatcherOptions{Source: "eve", Path: p, PollInterval: 40 * time.Millisecond})
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := w.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	defer w.Stop()
	collect(t, w, 200*time.Millisecond)

	// Truncate to a size well below the committed offset, then write one short record.
	if err := os.WriteFile(p, []byte("{\"x\":9}\n"), 0644); err != nil {
		t.Fatalf("truncate+write: %v", err)
	}
	if got := collect(t, w, 900*time.Millisecond); len(got) != 1 || got[0] != "{\"x\":9}" {
		t.Fatalf("copytruncate-smaller: want exactly one whole record, got %v", got)
	}
}
