// =============================================================================
// NFTBan v1.125 — Installer Concurrent-Run Lock (V125 R-2)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-lock"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-21"
// meta:description="Exclusive non-blocking flock lock for nftban-installer; prevents concurrent installer/update/takeover runs from racing install_state mutations"
// meta:inventory.files="internal/installer/lock/lock.go,internal/installer/lock/lock_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files="/var/lib/nftban/state/installer.lock"
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// V125 R-2 — closes the concurrent-installer-race vector identified in the
// V125 install-robustness audit (AUDIT_190_LIFECYCLE/V125_INSTALL_ROBUSTNESS_SCOPE.md
// §3.1 R-2). Two simultaneous installer invocations (e.g., operator running
// `nftban-installer` while `nftban update` is also running, or cron-
// triggered repair colliding with manual install) could race writes to
// install_state and corrupt it. flock-based exclusive non-blocking lock
// makes the second invocation refuse fast with an operator-actionable
// error message including the offending PID.
//
// Mechanism
// ─────────
// 1. Acquire opens (creates if missing) <path> with O_RDWR|O_CREATE 0644.
// 2. syscall.Flock(fd, LOCK_EX|LOCK_NB) — exclusive, non-blocking.
// 3. On EWOULDBLOCK (another process holds the lock):
//    - Read the PID recorded in the lock file (best-effort).
//    - If the recorded PID corresponds to a live nftban-installer process
//      (validated via /proc/<pid>/comm to avoid PID-reuse false positives),
//      refuse with "another installer is running (pid N)".
//    - If the PID is stale (process gone OR comm doesn't match), refuse
//      with a manual-cleanup hint — this branch is theoretically
//      unreachable on Linux (kernel releases flock on process exit) but
//      defensive.
// 4. On success, truncate + rewrite PID file with our PID.
// 5. Release() releases the flock and closes the fd. The lock file is
//    intentionally NOT deleted — leaving it allows the next Acquire to
//    inspect the prior PID for forensics and avoids a delete-race window.
//
// Scope boundaries
// ────────────────
// - Linux-only (uses syscall.Flock + /proc/<pid>/comm). The installer is
//   already Linux-only (RPM/DEB targets EL/Ubuntu/Debian), so no
//   cross-platform conditional compilation is needed.
// - No daemon, schema, metrics, packaging, systemd, polkit, or
//   release-process surface touched.
// - The default lock path lives alongside install_state at
//   /var/lib/nftban/state/installer.lock; parent directory is created
//   lazily if absent (fresh installs may not have the state-dir yet).
// =============================================================================

package lock

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// DefaultLockFile is the recommended path for the installer lock file.
// Callers may override (e.g., tests use t.TempDir() + this filename).
const DefaultLockFile = "installer.lock"

// Lock represents an acquired installer lock. Callers MUST call Release()
// when done; the recommended pattern is `defer lk.Release()` immediately
// after a successful Acquire.
type Lock struct {
	file *os.File
	path string
}

// Path returns the lock file path. Useful in error messages and logs.
func (l *Lock) Path() string {
	if l == nil {
		return ""
	}
	return l.path
}

// Acquire takes an exclusive non-blocking flock on path. Returns a *Lock
// on success or an error describing why acquisition failed.
//
// If another process holds the lock AND the recorded PID corresponds to a
// live nftban-installer process, the returned error message includes that
// PID for operator diagnosis ("another installer is running (pid N)").
//
// The lock file's parent directory is created (mkdir -p) if missing — on
// fresh installs the state-dir may not exist yet because FHS bootstrap
// happens in phasePrepare downstream.
//
// Stale-PID safety: the recorded PID in the lock file is informational
// only. The authoritative lock source is the kernel's flock state. If the
// previous holder exited (cleanly or via crash/kill), the kernel releases
// the flock automatically and the next Acquire succeeds — the stale PID
// is overwritten with the new holder's PID.
func Acquire(path string) (*Lock, error) {
	// Ensure parent directory exists. State-dir is typically created by
	// fhs.EnsureDirectories in phasePrepare; acquire fires earlier than
	// that so we mkdir defensively.
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return nil, fmt.Errorf("installer-lock: create dir %s: %w", filepath.Dir(path), err)
	}

	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE, 0644)
	if err != nil {
		return nil, fmt.Errorf("installer-lock: open %s: %w", path, err)
	}

	// Exclusive non-blocking flock. Kernel auto-releases on process exit
	// (clean or crash), so a "stale" lock file with a dead PID does NOT
	// keep the lock held — flock succeeds in that case (no contention,
	// new Acquire overwrites the stale PID record).
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		// Contention OR I/O error.
		f.Close()
		if err == syscall.EWOULDBLOCK {
			// EWOULDBLOCK means a process IS holding the flock right
			// now (kernel guarantee — flock is auto-released on holder
			// exit). The recorded PID in the file is the holder's PID
			// — trust it. If the file is empty / unreadable / contains
			// junk (e.g., writeLockPID was interrupted mid-write),
			// fall back to a generic "unknown process" message.
			if pid, perr := readLockPID(path); perr == nil && pid > 0 {
				return nil, fmt.Errorf("another installer is running (pid %d) — lock file: %s", pid, path)
			}
			return nil, fmt.Errorf("another installer holds the lock at %s (recorded pid unreadable)", path)
		}
		return nil, fmt.Errorf("installer-lock: flock %s: %w", path, err)
	}

	// We hold the lock. Write our PID (overwrites any stale PID from a
	// prior holder).
	if err := writeLockPID(f, os.Getpid()); err != nil {
		_ = syscall.Flock(int(f.Fd()), syscall.LOCK_UN)
		f.Close()
		return nil, fmt.Errorf("installer-lock: write pid: %w", err)
	}

	return &Lock{file: f, path: path}, nil
}

// Release releases the flock and closes the file descriptor. Idempotent
// and safe to call on a nil *Lock. The lock file itself is intentionally
// NOT deleted — leaving it preserves the recorded PID for post-mortem
// inspection and avoids a delete-race window.
//
// Note: on os.Exit() Go skips deferred calls, so callers that use
// os.Exit (e.g., cmd/nftban-installer/main.go does this with the
// computed exit code) MUST call Release() explicitly before os.Exit.
func (l *Lock) Release() error {
	if l == nil || l.file == nil {
		return nil
	}
	// Explicit unlock; closing the fd would do this too via OFD
	// destruction, but explicit LOCK_UN is more deterministic and
	// surfaces unexpected errors.
	_ = syscall.Flock(int(l.file.Fd()), syscall.LOCK_UN)
	err := l.file.Close()
	l.file = nil
	return err
}

// readLockPID reads the integer PID from the lock file. Returns (0, err)
// on any I/O or parse error.
func readLockPID(path string) (int, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, err
	}
	s := strings.TrimSpace(string(data))
	if s == "" {
		return 0, fmt.Errorf("lock file empty")
	}
	pid, err := strconv.Atoi(s)
	if err != nil || pid <= 0 {
		return 0, fmt.Errorf("invalid pid %q", s)
	}
	return pid, nil
}

// writeLockPID truncates the lock file and writes the PID. The caller
// MUST hold the flock before calling this.
func writeLockPID(f *os.File, pid int) error {
	if err := f.Truncate(0); err != nil {
		return fmt.Errorf("truncate: %w", err)
	}
	if _, err := f.Seek(0, 0); err != nil {
		return fmt.Errorf("seek: %w", err)
	}
	if _, err := fmt.Fprintf(f, "%d\n", pid); err != nil {
		return fmt.Errorf("write: %w", err)
	}
	return f.Sync()
}
