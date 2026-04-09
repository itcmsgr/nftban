// =============================================================================
// NFTBan v1.80 - pipeline watcher abstraction
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// Package: watcher
// Purpose: Watcher interface for tailing log files.
//
// meta:name="loginmon_pipeline_watcher"
// meta:type="package"
// meta:version="1.0.0"
// meta:package="watcher"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-09"
// meta:description="Watcher interface and MemoryWatcher (test) for the pipeline"
//
// meta:inventory.files="watcher.go,poll.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

// Package watcher defines the file-tailing abstraction for the v1.80
// pipeline.
//
// A Watcher emits raw lines from a single source. The interface is
// deliberately narrow: Start, Lines, Stop. Concrete implementations handle
// rotation, backoff, and error recovery internally.
//
// Phase A ships two implementations:
//
//   - MemoryWatcher: an in-memory channel-backed watcher used by tests.
//     Tests inject pre-baked lines via Push() and observe pipeline output
//     downstream. No filesystem access.
//
//   - PollingWatcher (poll.go): a stdlib-only file tail that uses stat-based
//     polling, handles rotation by-name, and survives truncation. It is
//     intentionally simple — no inotify, no external dependencies. Future
//     phases may add an inotify backend; the interface stays the same.
package watcher

import (
	"context"
	"errors"
	"sync"
	"time"

	"github.com/itcmsgr/nftban/internal/loginmon/pipeline/event"
)

// Watcher tails one source and emits raw lines.
//
// Lifecycle:
//
//	w := New...(...)
//	if err := w.Start(ctx); err != nil { ... }
//	defer w.Stop()
//	for line := range w.Lines() {
//	    // process line
//	}
//
// Start MUST be idempotent on re-entry (return an error or no-op). Stop
// MUST be safe to call multiple times. Lines MUST be closed when the
// watcher stops.
type Watcher interface {
	// Start begins tailing. Returns an error if the source cannot be opened.
	// The watcher emits lines into Lines() until Stop() is called or ctx
	// is cancelled.
	Start(ctx context.Context) error

	// Lines returns the read-only channel of raw lines. The channel is
	// closed when the watcher stops.
	Lines() <-chan event.RawLine

	// Stop halts the watcher and closes Lines. Idempotent.
	Stop() error

	// Source returns the source name this watcher is bound to. Used by
	// the runtime for routing and logging.
	Source() string
}

// ErrAlreadyStarted is returned by Watcher.Start if the watcher is already
// running.
var ErrAlreadyStarted = errors.New("watcher: already started")

// === MemoryWatcher: in-memory test implementation ===

// MemoryWatcher is a Watcher that emits lines pushed via Push().
//
// It exists for unit tests so the pipeline can be exercised end-to-end
// without touching the filesystem. Tests construct a MemoryWatcher, register
// it with the pipeline, push lines through Push(), and observe the pipeline
// state via aggregate.Snapshot().
type MemoryWatcher struct {
	source string
	lines  chan event.RawLine
	mu     sync.Mutex
	started bool
	stopped bool
}

// NewMemoryWatcher constructs a MemoryWatcher bound to the given source name.
// The line channel is buffered to bufSize; tests typically use 64 or 1024.
func NewMemoryWatcher(source string, bufSize int) *MemoryWatcher {
	if bufSize <= 0 {
		bufSize = 64
	}
	return &MemoryWatcher{
		source: source,
		lines:  make(chan event.RawLine, bufSize),
	}
}

// Source returns the source name.
func (w *MemoryWatcher) Source() string { return w.source }

// Lines returns the read-only line channel.
func (w *MemoryWatcher) Lines() <-chan event.RawLine { return w.lines }

// Start marks the watcher as running. MemoryWatcher does not spawn a
// goroutine; lines flow when Push() is called.
func (w *MemoryWatcher) Start(ctx context.Context) error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.started {
		return ErrAlreadyStarted
	}
	w.started = true
	return nil
}

// Stop closes the line channel. Idempotent.
func (w *MemoryWatcher) Stop() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	if w.stopped {
		return nil
	}
	w.stopped = true
	close(w.lines)
	return nil
}

// Push synchronously sends a raw line through the watcher.
//
// Returns false if the watcher is stopped or the channel is full and would
// block. Tests should size the buffer large enough to avoid blocking.
func (w *MemoryWatcher) Push(line []byte) bool {
	w.mu.Lock()
	if w.stopped || !w.started {
		w.mu.Unlock()
		return false
	}
	w.mu.Unlock()
	rl := event.RawLine{
		Source:     w.source,
		Path:       "memory://" + w.source,
		Line:       append([]byte(nil), line...), // copy to avoid mutation
		ReceivedAt: time.Now(),
	}
	select {
	case w.lines <- rl:
		return true
	default:
		return false
	}
}
