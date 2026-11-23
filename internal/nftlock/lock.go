// =============================================================================
// NFTBan v1.32.0 - Global nft Operation Lock
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
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
	"errors"
	"fmt"
	"log"
	"os"
	"path/filepath"
	"syscall"
	"time"
)

// LockPath is the canonical lock file for all nft operations (the OUTER lock; the write
// boundary nft_writers.lock is the inner one). Both Go (syscall.Flock) and shell (flock(1))
// use this same file.
//
// v1.238 (SEC-WRITE-BOUNDARY-LEGACY-ROOT-LOCKS-IN-NFTBAN-OWNED-RUN-DIR): it lives in the
// root-only /run/nftban-writers (build/fhs-spec.yaml), not in /run/nftban, which the nftban
// service account owns and where it could unlink and recreate the file so two root holders
// would lock different inodes.
const LockPath = "/run/nftban-writers/nft_operations.lock"

// LegacyLockPath is where v1.237 and earlier take the same lock. For ONE release (v1.238) every
// holder also takes it, AFTER LockPath (fixed order, so two new holders cannot deadlock), so a
// process of the previous version still running during the package upgrade stays excluded. It
// is never unlinked or replaced, and a symlink there is not followed. Known limitation until
// v1.239 drops this compatibility acquisition: the legacy directory is owned by the service
// account, which can still swap that inode; the exclusion between v1.238 processes comes from
// LockPath.
const LegacyLockPath = "/run/nftban/nft_operations.lock"

// lockPath / legacyLockPath are the paths in use (tests point them at a temp dir).
var (
	lockPath       = LockPath
	legacyLockPath = LegacyLockPath
)

// Lock represents an acquired file lock
type Lock struct {
	file   *os.File
	legacy *os.File // the compatibility lock (nil when its directory does not exist)
	path   string
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
	// Release in reverse order of acquisition: legacy first, then the canonical lock.
	if l.legacy != nil {
		_ = syscall.Flock(int(l.legacy.Fd()), syscall.LOCK_UN) // #nosec G104
		_ = l.legacy.Close()                                   // #nosec G104
		l.legacy = nil
	}
	// Unlock — errors are intentionally ignored during cleanup
	_ = syscall.Flock(int(l.file.Fd()), syscall.LOCK_UN) // #nosec G104
	_ = l.file.Close()                                   // #nosec G104
	l.file = nil
}

// openLockFile opens the canonical lock, creating its root-only directory (0700, as
// build/fhs-spec.yaml declares /run/nftban-writers) if tmpfiles has not.
func openLockFile() (*os.File, error) {
	if err := os.MkdirAll(filepath.Dir(lockPath), 0700); err != nil {
		return nil, fmt.Errorf("mkdir %s: %w", filepath.Dir(lockPath), err)
	}
	// 0600: only root holders take it (the directory itself is root-only 0700).
	file, err := os.OpenFile(lockPath, os.O_CREATE|os.O_RDWR, 0600) // #nosec G304 -- fixed path (var only for tests)
	if err != nil {
		return nil, fmt.Errorf("open lock file %s: %w", lockPath, err)
	}
	return file, nil
}

// openLegacyLockFile opens the compatibility lock without creating its directory, without
// truncating, and without following a symlink. (nil, nil) when the legacy directory does not
// exist (nothing older can hold a lock there) or when a symlink was placed at the name (the
// service account replaced it; following it would let that account choose what root opens).
func openLegacyLockFile() (*os.File, error) {
	if filepath.Clean(legacyLockPath) == filepath.Clean(lockPath) {
		return nil, nil // one file: already held through the canonical descriptor
	}
	if _, err := os.Stat(filepath.Dir(legacyLockPath)); os.IsNotExist(err) {
		return nil, nil
	}
	f, err := os.OpenFile(legacyLockPath, os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0600) // #nosec G304 -- fixed path (var only for tests)
	if err != nil {
		if errors.Is(err, syscall.ELOOP) {
			log.Printf("[nftlock] %s is a symlink; compatibility lock not taken (canonical %s is held)", legacyLockPath, lockPath)
			return nil, nil
		}
		return nil, fmt.Errorf("open legacy lock file %s: %w", legacyLockPath, err)
	}
	return f, nil
}

// ErrLockTimeout is returned when lock acquisition times out
var ErrLockTimeout = fmt.Errorf("nft lock timeout")

// ErrLockBusy is returned when a non-blocking lock attempt finds the lock held
var ErrLockBusy = fmt.Errorf("nft lock busy")

// acquireLock acquires a lock with timeout using polling: the canonical lock, then (one
// release) the legacy one, both within the same deadline.
func acquireLock(lockType int, timeout time.Duration) (*Lock, error) {
	file, err := openLockFile()
	if err != nil {
		return nil, err
	}
	deadline := time.Now().Add(timeout)
	if err := pollFlock(file, lockType, deadline); err != nil {
		_ = file.Close()
		logTimeout(lockType, timeout)
		return nil, err
	}
	legacy, err := openLegacyLockFile()
	if err != nil {
		_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN) // #nosec G104
		_ = file.Close()
		return nil, err
	}
	if legacy != nil {
		if err := pollFlock(legacy, lockType, deadline); err != nil {
			_ = legacy.Close()
			_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN) // #nosec G104
			_ = file.Close()
			logTimeout(lockType, timeout)
			return nil, err
		}
	}
	return &Lock{file: file, legacy: legacy, path: lockPath}, nil
}

// pollFlock takes lockType on f, polling until deadline (ErrLockTimeout).
func pollFlock(f *os.File, lockType int, deadline time.Time) error {
	pollInterval := 50 * time.Millisecond
	for {
		if err := syscall.Flock(int(f.Fd()), lockType|syscall.LOCK_NB); err == nil {
			return nil
		}
		if time.Now().After(deadline) {
			return ErrLockTimeout
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

func logTimeout(lockType int, timeout time.Duration) {
	lockName := "shared"
	if lockType == syscall.LOCK_EX {
		lockName = "exclusive"
	}
	log.Printf("[nftlock] %s lock timeout after %v", lockName, timeout)
}

// tryLock attempts a non-blocking lock: the canonical lock, then (one release) the legacy one.
func tryLock(lockType int) (*Lock, error) {
	file, err := openLockFile()
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(file.Fd()), lockType|syscall.LOCK_NB); err != nil {
		_ = file.Close()
		return nil, ErrLockBusy
	}
	legacy, err := openLegacyLockFile()
	if err != nil {
		_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN) // #nosec G104
		_ = file.Close()
		return nil, err
	}
	if legacy != nil {
		if err := syscall.Flock(int(legacy.Fd()), lockType|syscall.LOCK_NB); err != nil {
			_ = legacy.Close()
			_ = syscall.Flock(int(file.Fd()), syscall.LOCK_UN) // #nosec G104
			_ = file.Close()
			return nil, ErrLockBusy
		}
	}
	return &Lock{file: file, legacy: legacy, path: lockPath}, nil
}
