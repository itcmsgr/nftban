// =============================================================================
// NFTBan v1.80 - polling file watcher
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// Package: watcher
// Purpose: Stdlib-only polling file tail with rotation handling.
//
// meta:name="loginmon_pipeline_watcher_poll"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="watcher"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="PollingWatcher: stdlib-only file tail with rotation by-name"
//
// meta:inventory.files="poll.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package watcher

import (
	"bufio"
	"bytes"
	"context"
	"errors"
	"io"
	"os"
	"sync"
	"syscall"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
)

// PollingWatcher tails a file using stat-based polling. It is the canonical
// production watcher for v1.80 Phase A.
//
// Rotation handling:
//
//   - The watcher always opens the file by name (not by descriptor), so a
//     rename followed by a fresh create is detected on the next poll: the
//     inode changes and the watcher re-opens.
//   - Truncation is detected by comparing observed size against last read
//     offset; on truncation the offset resets to 0.
//   - File temporarily missing (e.g. logrotate atomic swap window): up to
//     30 seconds of stat retries before the watcher reports an error.
//
// PollingWatcher is intentionally simple. It uses bufio.Scanner with a 1 MB
// max line size. Lines longer than 1 MB are truncated and a warning is
// emitted in the log (caller responsibility — the watcher itself is silent).
//
// PollingWatcher is NOT inotify-based. An inotify backend may be added in a
// future phase; the Watcher interface stays the same.
type PollingWatcher struct {
	source       string
	path         string
	pollInterval time.Duration
	maxLineBytes int

	lines chan event.RawLine

	// v1.229.12 W01: `offset` is the COMMITTED RECORD OFFSET — it advances only
	// through complete, newline-terminated records. `pending` holds an
	// unterminated tail that has been read from the file but is NOT yet an
	// authoritative record. `sample` is the continuity fingerprint: a copy of the
	// bytes immediately BEFORE offset, used to detect copytruncate (which keeps
	// the same inode, so inode identity alone cannot see it).
	pending []byte
	sample  []byte

	mu      sync.Mutex
	started bool
	stopped bool
	cancel  context.CancelFunc
	wg      sync.WaitGroup

	// runtime cursor (protected by reading goroutine only)
	currentInode uint64
	currentDev   uint64
	offset       int64
}

// PollingWatcherOptions configures NewPollingWatcher.
type PollingWatcherOptions struct {
	Source       string        // source name
	Path         string        // resolved file path to tail
	PollInterval time.Duration // default 500ms
	BufferSize   int           // line channel buffer; default 1024
	MaxLineBytes int           // bufio scan buffer; default 1MB
}

// DefaultPollInterval is the default poll cadence when none is specified.
const DefaultPollInterval = 500 * time.Millisecond

// DefaultMaxLineBytes is the default scanner buffer size (1 MB).
const DefaultMaxLineBytes = 1024 * 1024

// NewPollingWatcher constructs a PollingWatcher with the given options.
// It does not open the file; the file is opened when Start is called.
func NewPollingWatcher(opts PollingWatcherOptions) *PollingWatcher {
	if opts.PollInterval == 0 {
		opts.PollInterval = DefaultPollInterval
	}
	if opts.BufferSize == 0 {
		opts.BufferSize = 1024
	}
	if opts.MaxLineBytes == 0 {
		opts.MaxLineBytes = DefaultMaxLineBytes
	}
	return &PollingWatcher{
		source:       opts.Source,
		path:         opts.Path,
		pollInterval: opts.PollInterval,
		maxLineBytes: opts.MaxLineBytes,
		lines:        make(chan event.RawLine, opts.BufferSize),
	}
}

// Source returns the source name.
func (w *PollingWatcher) Source() string { return w.source }

// Lines returns the read-only line channel.
func (w *PollingWatcher) Lines() <-chan event.RawLine { return w.lines }

// Start opens the file and begins tailing.
//
// Start spawns one goroutine that runs until ctx is cancelled or Stop is
// called. Start returns immediately after the file is opened (or fails to
// open). Errors during tailing are NOT returned from Start; they are
// surfaced as a closed Lines channel.
func (w *PollingWatcher) Start(ctx context.Context) error {
	w.mu.Lock()
	if w.started {
		w.mu.Unlock()
		return ErrAlreadyStarted
	}
	w.started = true
	wctx, cancel := context.WithCancel(ctx)
	w.cancel = cancel
	w.mu.Unlock()

	w.wg.Add(1)
	go w.run(wctx)
	return nil
}

// Stop signals the tailing goroutine to exit and closes Lines.
func (w *PollingWatcher) Stop() error {
	w.mu.Lock()
	if w.stopped {
		w.mu.Unlock()
		return nil
	}
	w.stopped = true
	if w.cancel != nil {
		w.cancel()
	}
	w.mu.Unlock()
	w.wg.Wait()
	return nil
}

// run is the tailing loop. Exits when ctx is cancelled.
// continuitySampleBytes is the size of the fingerprint kept immediately before
// the committed offset. Small enough to be free, large enough that a refill is
// overwhelmingly unlikely to reproduce it byte-for-byte.
const continuitySampleBytes = 64

// captureSample records the bytes immediately before the committed offset so a
// later poll can prove the file still contains what we already consumed.
func (w *PollingWatcher) captureSample(f *os.File) {
	if w.offset <= 0 {
		w.sample = nil
		return
	}
	n := int64(continuitySampleBytes)
	if n > w.offset {
		n = w.offset
	}
	buf := make([]byte, n)
	if _, err := f.ReadAt(buf, w.offset-n); err != nil {
		w.sample = nil
		return
	}
	w.sample = buf
}

// continuityOK reports whether the bytes before the committed offset still match
// the fingerprint. A mismatch means the file was truncated and refilled beyond
// the old offset while keeping its inode (copytruncate) — size and inode checks
// both miss that, and reading on would deliver a corrupted mid-line suffix.
func (w *PollingWatcher) continuityOK(f *os.File) bool {
	if w.offset <= 0 || len(w.sample) == 0 {
		return true
	}
	buf := make([]byte, len(w.sample))
	if _, err := f.ReadAt(buf, w.offset-int64(len(w.sample))); err != nil {
		return false
	}
	return bytes.Equal(buf, w.sample)
}

func (w *PollingWatcher) run(ctx context.Context) {
	defer w.wg.Done()
	defer close(w.lines)

	var f *os.File
	var reader *bufio.Reader
	defer func() {
		if f != nil {
			_ = f.Close()
		}
	}()

	open := func() bool {
		// #nosec G304 -- path comes from source.Descriptor.Path which was
		// resolved through distroconf or a controlled fallback list. Same
		// risk profile as the v1.79.2 distroconf reader (G304 #nosec).
		newF, err := os.Open(w.path)
		if err != nil {
			return false
		}
		stat, err := newF.Stat()
		if err != nil {
			_ = newF.Close()
			return false
		}
		sys, ok := stat.Sys().(*syscall.Stat_t)
		if !ok {
			_ = newF.Close()
			return false
		}
		// Seek to current EOF on first open. This means we don't replay
		// historical content — only events from now forward. Tests using
		// MemoryWatcher do not have this concern.
		if w.currentInode == 0 {
			_, err = newF.Seek(0, io.SeekEnd)
			if err != nil {
				_ = newF.Close()
				return false
			}
			off, _ := newF.Seek(0, io.SeekCurrent)
			w.offset = off
		}
		// A reopen invalidates any tail read from the previous handle.
		w.pending = nil
		w.currentInode = sys.Ino
		w.currentDev = sys.Dev
		if f != nil {
			_ = f.Close()
		}
		f = newF
		reader = bufio.NewReaderSize(f, w.maxLineBytes)
		// Capture the continuity fingerprint for wherever we are starting from —
		// including the first open, which seeks to EOF. Without this the check
		// would be disabled until the first committed record and a copytruncate
		// in that window would go undetected.
		w.captureSample(f)
		return true
	}

	if !open() {
		// Initial open failed. Caller will see closed channel.
		return
	}

	ticker := time.NewTicker(w.pollInterval)
	defer ticker.Stop()

	missingDeadline := time.Time{}

	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
		}

		// Detect rotation by stat-by-name.
		stat, err := os.Stat(w.path)
		if err != nil {
			// File temporarily missing. Allow up to 30s before giving up.
			if missingDeadline.IsZero() {
				missingDeadline = time.Now().Add(30 * time.Second)
			}
			if time.Now().After(missingDeadline) {
				return
			}
			continue
		}
		missingDeadline = time.Time{}
		sys, _ := stat.Sys().(*syscall.Stat_t)
		switch {
		case sys != nil && (sys.Ino != w.currentInode || sys.Dev != w.currentDev):
			// Inode/device changed = rename+create rotation. Reopen from 0.
			// The unterminated tail belonged to the OLD file and can never be
			// completed, so it is dropped rather than fused onto the new file.
			w.offset, w.pending, w.sample = 0, nil, nil
			if !open() {
				continue
			}
		case stat.Size() < w.offset:
			// Shrunk below what we committed: truncation. Reopen from 0.
			w.offset, w.pending, w.sample = 0, nil, nil
			if !open() {
				continue
			}
		case !w.continuityOK(f):
			// v1.229.12 W01: same inode, size >= committed offset, but the bytes
			// before that offset no longer match — the file was truncated and
			// refilled between polls (copytruncate). Continuing here would emit a
			// corrupted mid-line suffix, so reopen from 0.
			w.offset, w.pending, w.sample = 0, nil, nil
			if !open() {
				continue
			}
		}

		// Drain available data.
		//
		// v1.229.12 W01: a record is COMMITTED only when its newline arrives. The
		// previous form emitted whatever ReadBytes returned — including a line
		// still being written — and advanced the offset by len+1, adding a phantom
		// byte for a terminator that was never consumed. That pushed the offset
		// past the file size, which the size check above then read as truncation,
		// rewound to 0, and re-emitted the same partial on every poll.
		advanced := false
		for {
			chunk, err := reader.ReadBytes('\n')
			if len(chunk) > 0 {
				w.pending = append(w.pending, chunk...)
			}
			if n := len(w.pending); n > 0 && w.pending[n-1] == '\n' {
				// Complete record: the offset advances by the bytes actually
				// consumed from the file, terminator included.
				w.offset += int64(n)
				advanced = true
				line := w.pending[:n-1]
				if len(line) > 0 && line[len(line)-1] == '\r' {
					line = line[:len(line)-1]
				}
				rl := event.RawLine{
					Source:     w.source,
					Path:       w.path,
					Line:       append([]byte(nil), line...),
					Offset:     w.offset,
					ReceivedAt: time.Now(),
				}
				w.pending = nil
				select {
				case w.lines <- rl:
				case <-ctx.Done():
					return
				}
			}
			if err != nil {
				if errors.Is(err, io.EOF) {
					break
				}
				// Non-EOF read error: re-open on next poll.
				break
			}
		}
		// Refresh the continuity fingerprint whenever the committed offset moved,
		// so the next poll compares against the bytes we most recently consumed.
		if advanced && f != nil {
			w.captureSample(f)
		}
	}
}
