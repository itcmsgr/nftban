// =============================================================================
// NFTBan v1.80 - polling file watcher
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
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
		w.currentInode = sys.Ino
		w.currentDev = sys.Dev
		if f != nil {
			_ = f.Close()
		}
		f = newF
		reader = bufio.NewReaderSize(f, w.maxLineBytes)
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
		if sys != nil && (sys.Ino != w.currentInode || sys.Dev != w.currentDev) {
			// Inode changed = rotation. Reopen and reset offset.
			w.offset = 0
			if !open() {
				continue
			}
		} else if stat.Size() < w.offset {
			// Truncation: reopen and read from 0.
			w.offset = 0
			if !open() {
				continue
			}
		}

		// Drain available data.
		for {
			line, err := reader.ReadBytes('\n')
			if len(line) > 0 {
				// Strip trailing \n (and \r if present)
				if line[len(line)-1] == '\n' {
					line = line[:len(line)-1]
				}
				if len(line) > 0 && line[len(line)-1] == '\r' {
					line = line[:len(line)-1]
				}
				w.offset += int64(len(line)) + 1
				rl := event.RawLine{
					Source:     w.source,
					Path:       w.path,
					Line:       append([]byte(nil), line...),
					Offset:     w.offset,
					ReceivedAt: time.Now(),
				}
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
	}
}
