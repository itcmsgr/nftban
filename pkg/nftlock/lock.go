// =============================================================================
// NFTBan v1.32.0 - Global nft Operation Lock
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftlock"
// meta:type="package"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-21"
// meta:description="Global file-based lock for serializing nft kernel operations"
// meta:inventory.files="/run/nftban/nft_operations.lock"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
//
// Provides a global file-based lock using flock(2) to serialize nft kernel
// operations. Both Go code and shell scripts use the same lock file and
// same syscall, guaranteeing coordination.
//
// Contract:
//   - Exclusive lock for any nft write (add/delete/flush/replace) or reconciliation
//   - Shared lock for rare direct kernel reads
//   - Exporters reading cache files need no lock
//
// Design: DESIGN_HUGE_SET_COUNTING_ARCHITECTURE.md (P0-3a fix)
// =============================================================================

package nftlock

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// LockPath is the canonical lock file for all nft operations.
// Both Go (syscall.Flock) and shell (flock(1)) use this same file.
const LockPath = "/run/nftban/nft_operations.lock"

// Lock represents an acquired file lock
type Lock struct {
	file *os.File
	path string
}

// AcquireExclusive acquires an exclusive lock for nft write operations.
// Blocks until the lock is acquired or timeout expires.
// Use for: nft add element, nft delete element, nft flush set, reconciliation.
func AcquireExclusive(timeout time.Duration) (*Lock, error) {
	return acquireLock(syscall.LOCK_EX, timeout)
}

// AcquireShared acquires a shared lock for nft read operations.
// Multiple shared locks can be held simultaneously.
// Use for: rare direct nft list set reads (not for cache file reads).
func AcquireShared(timeout time.Duration) (*Lock, error) {
	return acquireLock(syscall.LOCK_SH, timeout)
}

// TryAcquireExclusive tries to acquire an exclusive lock without blocking.
// Returns nil, ErrLockBusy if the lock is already held.
func TryAcquireExclusive() (*Lock, error) {
	return tryLock(syscall.LOCK_EX)
}

// Release releases the lock
func (l *Lock) Release() {
	if l == nil || l.file == nil {
		return
	}
	// Unlock
	syscall.Flock(int(l.file.Fd()), syscall.LOCK_UN)
	l.file.Close()
	l.file = nil
}

// ErrLockTimeout is returned when lock acquisition times out
var ErrLockTimeout = fmt.Errorf("nft lock timeout")

// ErrLockBusy is returned when a non-blocking lock attempt finds the lock held
var ErrLockBusy = fmt.Errorf("nft lock busy")

// acquireLock acquires a lock with timeout using polling
func acquireLock(lockType int, timeout time.Duration) (*Lock, error) {
	// Ensure parent directory exists (may not if daemon hasn't started yet)
	if err := os.MkdirAll(filepath.Dir(LockPath), 0755); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", filepath.Dir(LockPath), err)
	}

	file, err := os.OpenFile(LockPath, os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		return nil, fmt.Errorf("open lock file %s: %w", LockPath, err)
	}

	deadline := time.Now().Add(timeout)
	pollInterval := 50 * time.Millisecond

	for {
		err := syscall.Flock(int(file.Fd()), lockType|syscall.LOCK_NB)
		if err == nil {
			return &Lock{file: file, path: LockPath}, nil
		}

		if time.Now().After(deadline) {
			file.Close()
			lockName := "shared"
			if lockType == syscall.LOCK_EX {
				lockName = "exclusive"
			}
			log.Printf("[nftlock] %s lock timeout after %v", lockName, timeout)
			return nil, ErrLockTimeout
		}

		time.Sleep(pollInterval)
		// Increase poll interval up to 500ms to reduce CPU during contention
		if pollInterval < 500*time.Millisecond {
			pollInterval = pollInterval * 2
			if pollInterval > 500*time.Millisecond {
				pollInterval = 500 * time.Millisecond
			}
		}
	}
}

// tryLock attempts a non-blocking lock
func tryLock(lockType int) (*Lock, error) {
	// Ensure parent directory exists
	if err := os.MkdirAll(filepath.Dir(LockPath), 0755); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", filepath.Dir(LockPath), err)
	}

	file, err := os.OpenFile(LockPath, os.O_CREATE|os.O_RDWR, 0644)
	if err != nil {
		return nil, fmt.Errorf("open lock file %s: %w", LockPath, err)
	}

	err = syscall.Flock(int(file.Fd()), lockType|syscall.LOCK_NB)
	if err != nil {
		file.Close()
		return nil, ErrLockBusy
	}

	return &Lock{file: file, path: LockPath}, nil
}
