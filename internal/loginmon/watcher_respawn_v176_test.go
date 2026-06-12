// =============================================================================
// NFTBan v1.176 — LOGINMON-WATCHER-NO-RESPAWN regression tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="loginmon-watcher-respawn-v176-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-12"
// meta:description="Locks v1.176 LOGINMON-WATCHER-NO-RESPAWN: the file-watcher supervisor respawns a dead tail -F child while ctx is alive (detection does NOT go dark) with bounded backoff, and stops cleanly on ctx cancellation (no respawn, no leaked *exec.Cmd). (1) RespawnsOnChildDeath_AndStopsClean: a fast-exiting injected child is respawned >=3x, then respawns STOP after ctx cancel and no live watcher cmd leaks. (2) KillRealTailRespawns: a real tail -F child killed mid-run is replaced by a different live child. Hermetic: injected/temp-file watchers, no root, no nft; run under -race."
// meta:inventory.files="internal/loginmon/module.go"
// meta:inventory.binaries="tail,true"
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
package loginmon

import (
	"context"
	"os"
	"os/exec"
	"sync/atomic"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/eventbus"
)

// newTestModule builds a Module with a live bus and fast (test) backoff so the
// supervise loop respawns quickly.
func newTestModule() *Module {
	m := New()
	m.bus = eventbus.New()
	m.watcherBackoffMin = 2 * time.Millisecond
	m.watcherBackoffMax = 8 * time.Millisecond
	m.watcherHealthyReset = time.Hour // never "healthy" in-test; keep backoff small+capped
	return m
}

func (m *Module) liveWatcherCount() int {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return len(m.fileWatcherCmds)
}

// Item A core: a child that keeps dying is respawned while ctx is alive, and
// respawns STOP immediately on ctx cancellation (clean shutdown, no leak).
func TestFileWatcherRespawnsOnChildDeath_AndStopsClean(t *testing.T) {
	m := newTestModule()

	var spawns int64
	// Fake watcher child that exits immediately (no output) → drives the
	// supervisor to respawn each time.
	m.newWatcherCmd = func(ctx context.Context, _ string) *exec.Cmd {
		atomic.AddInt64(&spawns, 1)
		return exec.CommandContext(ctx, "true")
	}

	ctx, cancel := context.WithCancel(context.Background())
	go m.runFileWatcher(ctx, "test", "/var/log/does-not-exist.log")

	// Respawn proof: the supervisor must invoke the builder many times.
	deadline := time.Now().Add(3 * time.Second)
	for atomic.LoadInt64(&spawns) < 3 && time.Now().Before(deadline) {
		time.Sleep(5 * time.Millisecond)
	}
	if got := atomic.LoadInt64(&spawns); got < 3 {
		t.Fatalf("watcher did not respawn: only %d spawns (want >=3) — detection would go dark", got)
	}

	// Clean shutdown: after cancel, spawns must stop increasing.
	cancel()
	time.Sleep(60 * time.Millisecond)
	c1 := atomic.LoadInt64(&spawns)
	time.Sleep(80 * time.Millisecond)
	c2 := atomic.LoadInt64(&spawns)
	if c2 != c1 {
		t.Fatalf("watcher kept respawning after ctx cancel: %d -> %d (clean shutdown broken)", c1, c2)
	}

	// No leaked watcher cmds after shutdown.
	for i := 0; i < 40 && m.liveWatcherCount() != 0; i++ {
		time.Sleep(5 * time.Millisecond)
	}
	if n := m.liveWatcherCount(); n != 0 {
		t.Fatalf("leaked %d live watcher cmd(s) after shutdown", n)
	}
}

// Item A end-to-end with a REAL tail -F child: killing the live child triggers a
// respawn (a new, different child becomes the registered watcher) — the exact
// failure the audit caught. Skips if `tail` is unavailable.
func TestFileWatcherKillRealTailRespawns(t *testing.T) {
	if _, err := exec.LookPath("tail"); err != nil {
		t.Skip("tail not available")
	}
	m := newTestModule()

	f, err := os.CreateTemp(t.TempDir(), "access-*.log")
	if err != nil {
		t.Fatalf("temp log: %v", err)
	}
	logPath := f.Name()
	_ = f.Close()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go m.runFileWatcher(ctx, "test", logPath) // default builder = real tail -F

	// Wait for the first child to register.
	first := waitForLiveChild(t, m, nil, 3*time.Second)

	// Kill it (simulates OOM-kill / abnormal death) while ctx is alive.
	if first.Process != nil {
		_ = first.Process.Kill()
	}

	// A DIFFERENT child must take over (respawn), not stay dark.
	second := waitForLiveChild(t, m, first, 3*time.Second)
	if second == first {
		t.Fatal("watcher did not respawn after the live tail child was killed")
	}

	// Clean shutdown reaps the watcher.
	cancel()
	for i := 0; i < 60 && m.liveWatcherCount() != 0; i++ {
		time.Sleep(10 * time.Millisecond)
	}
	if n := m.liveWatcherCount(); n != 0 {
		t.Fatalf("leaked %d live watcher cmd(s) after shutdown", n)
	}
}

// waitForLiveChild returns the registered watcher cmd once one exists that is
// different from `exclude` (pass nil to accept the first). Fails on timeout.
func waitForLiveChild(t *testing.T, m *Module, exclude *exec.Cmd, d time.Duration) *exec.Cmd {
	t.Helper()
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		m.mu.RLock()
		var cur *exec.Cmd
		if len(m.fileWatcherCmds) > 0 {
			cur = m.fileWatcherCmds[len(m.fileWatcherCmds)-1]
		}
		m.mu.RUnlock()
		if cur != nil && cur != exclude {
			return cur
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("timed out waiting for a live watcher child")
	return nil
}
