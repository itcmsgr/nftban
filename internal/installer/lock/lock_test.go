// =============================================================================
// NFTBan v1.125 — Installer Concurrent-Run Lock Tests (V125 R-2)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-lock-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-05-21"
// meta:description="Tests for the V125 R-2 installer concurrent-run flock — first acquire / second acquire refusal / stale PID reclaim / PID file contents"
// meta:inventory.files="internal/installer/lock/lock_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
//
// Test scope per AUDIT_190_LIFECYCLE/V125_INSTALL_ROBUSTNESS_SCOPE.md
// §3.1 R-2:
//   - first acquire succeeds
//   - second acquire fails while first held
//   - stale PID lock is reclaimable
//   - lock file content contains PID
//
// Plus a regression guard for the OFD-flock kernel contract.
// =============================================================================

package lock

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

// TestAcquire_FirstAcquireSucceeds covers the common-case path: no
// pre-existing lock, Acquire returns a valid *Lock, the lock file is
// created with our PID inside.
func TestAcquire_FirstAcquireSucceeds(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "installer.lock")

	lk, err := Acquire(path)
	if err != nil {
		t.Fatalf("first Acquire: %v", err)
	}
	if lk == nil {
		t.Fatal("first Acquire returned nil lock")
	}
	defer lk.Release()

	if got := lk.Path(); got != path {
		t.Errorf("lk.Path() = %q, want %q", got, path)
	}

	// Lock file must exist after a successful Acquire.
	if _, err := os.Stat(path); err != nil {
		t.Fatalf("lock file missing after Acquire: %v", err)
	}
}

// TestAcquire_LockFileContainsCurrentPID asserts the PID-write side
// effect: after Acquire, the lock file contains the process's PID as
// a base-10 integer (terminated by a newline).
func TestAcquire_LockFileContainsCurrentPID(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "installer.lock")

	lk, err := Acquire(path)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	defer lk.Release()

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read lock file: %v", err)
	}
	got := strings.TrimSpace(string(data))
	want := strconv.Itoa(os.Getpid())
	if got != want {
		t.Errorf("lock file contents = %q, want %q", got, want)
	}
}

// TestAcquire_SecondAcquireFailsWhileFirstHeld is the core
// concurrent-installer-race regression guard. While the first lock is
// held, a second Acquire on the same path MUST fail.
func TestAcquire_SecondAcquireFailsWhileFirstHeld(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "installer.lock")

	first, err := Acquire(path)
	if err != nil {
		t.Fatalf("first Acquire: %v", err)
	}
	defer first.Release()

	// Second acquire MUST fail (kernel refuses LOCK_EX|LOCK_NB).
	second, err := Acquire(path)
	if err == nil {
		// Defensive: release the second lock so the test cleanup is
		// idempotent even though the assertion below is going to fail.
		second.Release()
		t.Fatalf("second Acquire unexpectedly succeeded while first is held")
	}
	if second != nil {
		t.Errorf("second Acquire returned non-nil *Lock alongside error: %v", err)
	}

	// Error message MUST include the offending PID (our own PID, since
	// the first lock was taken by this test process). This is the
	// operator-actionable bit ("another installer is running (pid N)")
	// that lets the operator diagnose without grepping the lock file.
	pidStr := strconv.Itoa(os.Getpid())
	if !strings.Contains(err.Error(), pidStr) {
		t.Errorf("second-Acquire error did not include holder PID %s: %v", pidStr, err)
	}
	if !strings.Contains(err.Error(), "another installer is running") {
		t.Errorf("second-Acquire error did not include operator-actionable phrase: %v", err)
	}
}

// TestAcquire_StalePIDIsReclaimable covers the post-crash-recovery path.
// If a previous installer wrote its PID to the lock file but no longer
// holds the flock (process exited, kernel released the OFD), the next
// Acquire MUST succeed and overwrite the stale PID with the current
// process's PID.
//
// We simulate the stale-PID scenario by writing a fake PID to the lock
// file WITHOUT taking the flock. Subsequent Acquire has no flock
// contention and succeeds; the stale PID is overwritten.
func TestAcquire_StalePIDIsReclaimable(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "installer.lock")

	// Seed the lock file with a fake stale PID. The flock semantics
	// don't depend on the PID value at all (kernel tracks ownership
	// via the open file description, not the file's contents), so the
	// new Acquire succeeds regardless of whether PID 99999 happens to
	// be a live process on the test host. The PID record is purely
	// informational.
	if err := os.WriteFile(path, []byte("99999\n"), 0644); err != nil {
		t.Fatalf("seed stale lock file: %v", err)
	}

	lk, err := Acquire(path)
	if err != nil {
		t.Fatalf("Acquire on stale-PID lock file: %v (expected success)", err)
	}
	defer lk.Release()

	// The PID file MUST now contain OUR PID, not 99999.
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read lock file: %v", err)
	}
	got := strings.TrimSpace(string(data))
	want := strconv.Itoa(os.Getpid())
	if got != want {
		t.Errorf("stale PID not overwritten: lock file = %q, want %q", got, want)
	}
	if got == "99999" {
		t.Errorf("stale PID 99999 still present after reclaim — Acquire did not overwrite")
	}
}

// TestAcquire_StalePIDWithInvalidContent covers the post-crash-recovery
// path where the lock file contains malformed content (e.g., empty
// file, non-numeric junk from a partial write). Acquire MUST still
// succeed (no flock contention) and overwrite with valid PID.
func TestAcquire_StalePIDWithInvalidContent(t *testing.T) {
	tests := []struct {
		name    string
		content []byte
	}{
		{"empty file", []byte("")},
		{"whitespace only", []byte("  \n  ")},
		{"non-numeric junk", []byte("not-a-pid\n")},
		{"negative pid", []byte("-1\n")},
		{"pid zero", []byte("0\n")},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "installer.lock")
			if err := os.WriteFile(path, tt.content, 0644); err != nil {
				t.Fatalf("seed lock file: %v", err)
			}
			lk, err := Acquire(path)
			if err != nil {
				t.Fatalf("Acquire on lock file with %s: %v (expected success — malformed PID is not a contention signal)", tt.name, err)
			}
			defer lk.Release()
			data, _ := os.ReadFile(path)
			got := strings.TrimSpace(string(data))
			if got != strconv.Itoa(os.Getpid()) {
				t.Errorf("malformed-PID lock file not properly reclaimed: contents = %q, want %d", got, os.Getpid())
			}
		})
	}
}

// TestRelease_AfterAcquireAllowsReacquire is the OFD-flock kernel-contract
// regression guard. After Release(), the kernel MUST drop the flock so a
// subsequent Acquire on the same path succeeds. This is the round-trip
// invariant the installer relies on for normal exit (the lock is released
// just before os.Exit and the next nftban-installer run must succeed).
func TestRelease_AfterAcquireAllowsReacquire(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "installer.lock")

	first, err := Acquire(path)
	if err != nil {
		t.Fatalf("first Acquire: %v", err)
	}
	if err := first.Release(); err != nil {
		t.Fatalf("Release: %v", err)
	}

	// A second Acquire after Release MUST succeed.
	second, err := Acquire(path)
	if err != nil {
		t.Fatalf("second Acquire after Release: %v", err)
	}
	defer second.Release()

	// And the PID file should be ours (Release doesn't delete the file;
	// next Acquire overwrites the PID).
	data, _ := os.ReadFile(path)
	got := strings.TrimSpace(string(data))
	if got != strconv.Itoa(os.Getpid()) {
		t.Errorf("post-Release Acquire did not refresh PID: contents = %q", got)
	}
}

// TestRelease_NilLockIsSafe asserts the Release() method's robustness:
// calling Release on a nil *Lock (e.g., when an Acquire error path
// returns nil) must not panic.
func TestRelease_NilLockIsSafe(t *testing.T) {
	var lk *Lock
	if err := lk.Release(); err != nil {
		t.Errorf("nil-Lock Release returned unexpected error: %v", err)
	}
}

// TestRelease_DoubleReleaseIsSafe asserts idempotency: calling Release
// twice (e.g., a defer Release + an explicit Release before os.Exit, as
// used in cmd/nftban-installer/main.go) must not panic or error.
func TestRelease_DoubleReleaseIsSafe(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "installer.lock")
	lk, err := Acquire(path)
	if err != nil {
		t.Fatalf("Acquire: %v", err)
	}
	if err := lk.Release(); err != nil {
		t.Errorf("first Release returned unexpected error: %v", err)
	}
	if err := lk.Release(); err != nil {
		t.Errorf("second Release returned unexpected error: %v", err)
	}
}

// TestAcquire_CreatesParentDirectory covers the fresh-install path where
// the state-dir doesn't exist yet (FHS bootstrap happens later in
// phasePrepare). Acquire MUST mkdir -p the parent directory.
func TestAcquire_CreatesParentDirectory(t *testing.T) {
	dir := t.TempDir()
	// Use a 2-level-deep path; the intermediate dir doesn't exist yet.
	path := filepath.Join(dir, "fresh-install", "state", "installer.lock")

	lk, err := Acquire(path)
	if err != nil {
		t.Fatalf("Acquire on fresh-install path: %v (expected mkdir -p to create parents)", err)
	}
	defer lk.Release()

	if _, err := os.Stat(path); err != nil {
		t.Errorf("lock file not created: %v", err)
	}
	if _, err := os.Stat(filepath.Dir(path)); err != nil {
		t.Errorf("parent directory not created: %v", err)
	}
}

// TestReadLockPID_EdgeCases is a lightweight unit test for the PID-parse
// helper. Belt-and-braces alongside TestAcquire_StalePIDWithInvalidContent.
func TestReadLockPID_EdgeCases(t *testing.T) {
	tests := []struct {
		name    string
		content string
		wantPID int
		wantErr bool
	}{
		{"valid pid", "1234\n", 1234, false},
		{"valid pid no newline", "1234", 1234, false},
		{"valid pid with surrounding ws", "  1234  \n", 1234, false},
		{"empty", "", 0, true},
		{"whitespace only", "  \n", 0, true},
		{"non-numeric", "abc", 0, true},
		{"negative", "-1", 0, true},
		{"zero", "0", 0, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			dir := t.TempDir()
			path := filepath.Join(dir, "test.lock")
			if err := os.WriteFile(path, []byte(tt.content), 0644); err != nil {
				t.Fatal(err)
			}
			pid, err := readLockPID(path)
			if (err != nil) != tt.wantErr {
				t.Errorf("readLockPID(%q) err = %v, wantErr = %v", tt.content, err, tt.wantErr)
			}
			if pid != tt.wantPID {
				t.Errorf("readLockPID(%q) pid = %d, want %d", tt.content, pid, tt.wantPID)
			}
		})
	}
}

// TestAcquire_SecondAcquireFailsOnUnreadablePIDFile covers the defensive
// branch in Acquire's contention handler: if the lock file is empty /
// malformed (e.g., writeLockPID was interrupted mid-write on a prior
// holder), the second-acquire error message falls back to the generic
// "recorded pid unreadable" form. This guards the post-mortem code path
// where readLockPID returns an error but flock is genuinely held.
//
// Simulated by truncating the lock file AFTER the first Acquire has
// written its PID, while the first lock still holds the flock.
func TestAcquire_SecondAcquireFailsOnUnreadablePIDFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "installer.lock")

	first, err := Acquire(path)
	if err != nil {
		t.Fatalf("first Acquire: %v", err)
	}
	defer first.Release()

	// Truncate the lock file to empty WITHOUT releasing the flock.
	// The kernel keeps the flock held on the open file descriptor; only
	// the file's contents go away.
	if err := os.WriteFile(path, []byte(""), 0644); err != nil {
		t.Fatalf("truncate lock file: %v", err)
	}

	_, err = Acquire(path)
	if err == nil {
		t.Fatal("second Acquire unexpectedly succeeded after lock-file truncation")
	}
	if !strings.Contains(err.Error(), "recorded pid unreadable") &&
		!strings.Contains(err.Error(), "another installer is running") {
		t.Errorf("expected fallback error message; got: %v", err)
	}
}
