// =============================================================================
// NFTBan v1.236 - Write boundary: daemon writers (shared) vs a ruleset replacement (exclusive)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="nftlock-boundary"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-23"
// meta:description="Inner write-boundary lock (design V1236_STAGE2_DESIGN_DRAFT.md §9.1a): every daemon kernel transaction holds LOCK_SH on nft_writers.lock; a ruleset replacement holds LOCK_EX from its kernel read to its commit readback, after publishing an intent record so new daemon writes wait instead of starving it"
// meta:inventory.files="/run/nftban/nft_writers.lock,/run/nftban/nft_writers.intent"
// meta:inventory.privileges="root"
//
// Lock order (design §9.1a): nft_operations.lock (outer, lane vs lane) before
// nft_writers.lock (inner). The daemon never takes the outer lock for writes and holds
// the inner one only for the span of its own kernel transaction, during which it makes
// no IPC and starts no process that needs the lock: no cycle.
//
// Properties:
//   - drain: LOCK_EX is granted only when no daemon write section is open, so a
//     replacement's kernel read sees every write that started before it;
//   - no starvation: a live intent record (pid alive, same boot) stops NEW write bursts;
//   - no lease: flock is released by the kernel when its holder exits (crash-safe);
//   - bounded: a writer waits at most Wait, then returns ErrBusy (not applied, reported);
//   - re-entrant within the process: while a section is open, further entries join it
//     without waiting, so nested daemon writes cannot deadlock against the intent.
// =============================================================================

package nftlock

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

// BoundaryPath is the inner write-boundary lock file (shell: flock on the same file).
const BoundaryPath = "/run/nftban/nft_writers.lock"

// IntentPath is written by a replacement before it waits for LOCK_EX:
// "pid=<pid> boot=<boot_id>".
const IntentPath = "/run/nftban/nft_writers.intent"

// ErrBusy: a firewall replacement held the write boundary for longer than the wait.
var ErrBusy = errors.New("nft writes paused by a firewall replacement (busy)")

// Boundary is the daemon side of the write boundary (one per process).
type Boundary struct {
	Wait time.Duration // how long one entry may wait (default 30 s)

	// Paths are variables for tests.
	LockPath   string
	IntentPath string

	mu   sync.Mutex
	ref  int
	file *os.File
}

// NewBoundary returns the daemon boundary on the canonical paths.
func NewBoundary(wait time.Duration) *Boundary {
	if wait <= 0 {
		wait = 30 * time.Second
	}
	return &Boundary{Wait: wait, LockPath: BoundaryPath, IntentPath: IntentPath}
}

// Begin opens a write section; the returned func closes it. Callers wrap exactly one
// kernel transaction (or one batch of them that must not straddle a replacement).
func (b *Boundary) Begin() (func(), error) {
	deadline := time.Now().Add(b.Wait)
	poll := 20 * time.Millisecond
	b.mu.Lock()
	for {
		if b.ref > 0 {
			// Join the open section: never wait while holding it (nesting, no deadlock).
			b.ref++
			b.mu.Unlock()
			return b.release, nil
		}
		if !b.intentActive() {
			f, err := b.tryShared()
			if err == nil {
				b.file = f
				b.ref = 1
				b.mu.Unlock()
				return b.release, nil
			}
			if !errors.Is(err, ErrLockBusy) {
				b.mu.Unlock()
				return nil, err
			}
		}
		if time.Now().After(deadline) {
			b.mu.Unlock()
			return nil, fmt.Errorf("%w after %v", ErrBusy, b.Wait)
		}
		b.mu.Unlock()
		time.Sleep(poll)
		if poll < 200*time.Millisecond {
			poll *= 2
		}
		b.mu.Lock()
	}
}

func (b *Boundary) release() {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ref == 0 {
		return
	}
	b.ref--
	if b.ref == 0 && b.file != nil {
		_ = syscall.Flock(int(b.file.Fd()), syscall.LOCK_UN) // #nosec G104
		_ = b.file.Close()                                   // #nosec G104
		b.file = nil
	}
}

// ChildLock returns a duplicate descriptor of the open section's lock, or nil when no
// section is open. An nft child given it in ExtraFiles shares the lock's open file
// description: the daemon's release (LOCK_UN) still ends the section for both, but if
// the daemon dies while that child runs, the SH lock stays held until the child exits,
// so a replacement cannot read the kernel before the orphan's batch lands (crash
// recovery covers the nft child). The caller closes it once the child has exited.
func (b *Boundary) ChildLock() *os.File {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.ref == 0 || b.file == nil {
		return nil
	}
	fd, err := syscall.Dup(int(b.file.Fd()))
	if err != nil {
		return nil
	}
	syscall.CloseOnExec(fd)
	return os.NewFile(uintptr(fd), b.LockPath)
}

func (b *Boundary) tryShared() (*os.File, error) {
	if err := os.MkdirAll(filepath.Dir(b.LockPath), 0750); err != nil { // #nosec G301
		return nil, fmt.Errorf("mkdir %s: %w", filepath.Dir(b.LockPath), err)
	}
	f, err := os.OpenFile(b.LockPath, os.O_CREATE|os.O_RDWR, 0640) // #nosec G302 G304 -- fixed path
	if err != nil {
		return nil, fmt.Errorf("open %s: %w", b.LockPath, err)
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_SH|syscall.LOCK_NB); err != nil {
		_ = f.Close()
		return nil, ErrLockBusy
	}
	return f, nil
}

// intentActive: an intent record whose process is alive in this boot.
func (b *Boundary) intentActive() bool {
	data, err := os.ReadFile(b.IntentPath)
	if err != nil {
		return false
	}
	var pid int
	var boot string
	for _, f := range strings.Fields(string(data)) {
		switch {
		case strings.HasPrefix(f, "pid="):
			pid, _ = strconv.Atoi(strings.TrimPrefix(f, "pid="))
		case strings.HasPrefix(f, "boot="):
			boot = strings.TrimPrefix(f, "boot=")
		}
	}
	if pid <= 0 {
		return false
	}
	if cur, err := os.ReadFile("/proc/sys/kernel/random/boot_id"); err == nil && boot != "" && strings.TrimSpace(string(cur)) != boot {
		return false
	}
	return syscall.Kill(pid, 0) == nil
}
