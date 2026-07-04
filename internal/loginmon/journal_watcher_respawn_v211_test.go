// =============================================================================
// NFTBan v1.211 — LOGINMON-JOURNAL-NO-RESPAWN regression tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="loginmon-journal-watcher-respawn-v211-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Locks v1.211 LOGINMON-JOURNAL-NO-RESPAWN: the journal watcher (journalctl -f) is now SUPERVISED like the file watcher — a child that ends (EOF/error) is respawned with bounded backoff so the auth/authpriv/ftp journal detection sources never go silently dark, and the 'journal' input-source state is observable: OK while healthy, WATCHER_DEGRADED on a transient restart, WATCHER_DOWN after repeated short failures, back to OK on recovery; respawns STOP cleanly on ctx cancel (no leak, no tight loop). Hermetic: injected fast-exit (true) / long-lived (sleep) children, no root, no journalctl; run under -race."
// meta:inventory.files="internal/loginmon/module.go"
// meta:inventory.binaries="true,sleep"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package loginmon

import (
	"context"
	"os/exec"
	"sync/atomic"
	"testing"
	"time"
)

// journalState returns the recorded "journal" input-source state ("" if none).
func journalState(m *Module) string {
	return m.inputStateSnapshot()["journal"]
}

// waitForJournalState polls until the "journal" input-state equals want, or fails.
func waitForJournalState(t *testing.T, m *Module, want string, d time.Duration) {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if journalState(m) == want {
			return
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Fatalf("journal input-state = %q, want %q within %s", journalState(m), want, d)
}

// Core: a journalctl child that keeps ending is RESPAWNED while ctx is alive
// (detection does NOT go dark), the input-state degrades to WATCHER_DEGRADED then
// WATCHER_DOWN, and respawns STOP cleanly on ctx cancel (no tight loop, no leak).
func TestJournalWatcherRespawnsAndDegrades(t *testing.T) {
	m := newTestModule() // backoff 2ms..8ms, healthyReset=1h (runs never "healthy")

	var spawns int64
	m.newJournalCmd = func(ctx context.Context) *exec.Cmd {
		atomic.AddInt64(&spawns, 1)
		return exec.CommandContext(ctx, "true") // exits immediately → drives respawn
	}

	ctx, cancel := context.WithCancel(context.Background())
	go m.runJournalWatcher(ctx)

	// Respawn proof: the supervisor must invoke the builder repeatedly.
	deadline := time.Now().Add(3 * time.Second)
	for atomic.LoadInt64(&spawns) < 3 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if got := atomic.LoadInt64(&spawns); got < 3 {
		t.Fatalf("journal watcher did not respawn: only %d spawns (want >=3) — detection would go dark", got)
	}

	// After repeated short-lived failures the input-state must read WATCHER_DOWN
	// (not OK) — an enabled-but-dark journal source must never look healthy.
	waitForJournalState(t, m, inputStateWatcherDown, 3*time.Second)

	// Clean shutdown: after cancel, spawns must stop increasing (no tight loop).
	cancel()
	time.Sleep(60 * time.Millisecond)
	c1 := atomic.LoadInt64(&spawns)
	time.Sleep(80 * time.Millisecond)
	c2 := atomic.LoadInt64(&spawns)
	if c2 != c1 {
		t.Fatalf("journal watcher kept respawning after ctx cancel: %d -> %d (clean shutdown broken)", c1, c2)
	}
}

// A transient single restart shows WATCHER_DEGRADED (not yet DOWN) before the
// repeated-failure threshold escalates it.
func TestJournalWatcherTransientIsDegraded(t *testing.T) {
	m := newTestModule()
	m.watcherBackoffMin = 40 * time.Millisecond // slow the loop so DEGRADED is observable pre-DOWN
	m.watcherBackoffMax = 80 * time.Millisecond

	m.newJournalCmd = func(ctx context.Context) *exec.Cmd {
		return exec.CommandContext(ctx, "true")
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go m.runJournalWatcher(ctx)

	// First short failure → WATCHER_DEGRADED (consecutiveShortFails == 1).
	waitForJournalState(t, m, inputStateWatcherDegraded, 2*time.Second)
}

// Recovery: a watcher that was DOWN comes back to OK once a respawned run survives
// to the healthy-reset threshold.
func TestJournalWatcherRecoversToOK(t *testing.T) {
	if _, err := exec.LookPath("sleep"); err != nil {
		t.Skip("sleep not available")
	}
	m := newTestModule()
	m.watcherBackoffMin = 2 * time.Millisecond
	m.watcherBackoffMax = 8 * time.Millisecond
	m.watcherHealthyReset = 40 * time.Millisecond

	var healthy int64 // 0 = fail fast, 1 = long-lived child
	m.newJournalCmd = func(ctx context.Context) *exec.Cmd {
		if atomic.LoadInt64(&healthy) == 1 {
			return exec.CommandContext(ctx, "sleep", "3600") // survives past healthyReset
		}
		return exec.CommandContext(ctx, "true") // fail fast
	}

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go m.runJournalWatcher(ctx)

	// Drive it DOWN first.
	waitForJournalState(t, m, inputStateWatcherDown, 3*time.Second)

	// Flip to a healthy child: the next respawn must survive and recover to OK.
	atomic.StoreInt64(&healthy, 1)
	waitForJournalState(t, m, inputStateOK, 3*time.Second)
}
