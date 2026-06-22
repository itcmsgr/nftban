// =============================================================================
// NFTBan v1.198.1 - nftban-installer - --revalidate guard/no-mask tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="nftban-installer-revalidate-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-22"
// meta:description="v1.198.1 PR-B: runRevalidate guards (no state / COMMITTED no-op / non-DEGRADED refuse / version-mismatch refuse) + the no-mask contract (failing live assertions leave install_state DEGRADED, never COMMITTED)."
// meta:inventory.files="cmd/nftban-installer/revalidate_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package main

import (
	"context"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
	"github.com/itcmsgr/nftban/internal/installer/state"
	"github.com/itcmsgr/nftban/pkg/version"
)

func writeRevalState(t *testing.T, dir string, st state.InstallState, ver string) {
	t.Helper()
	sf := state.NewStateFile(dir)
	sf.State = st
	sf.Version = ver
	sf.Mode = "upgrade"
	sf.SSHPort = 22
	if err := sf.WriteAtomic(); err != nil {
		t.Fatalf("write state: %v", err)
	}
}

// newRevalSF mimics main()'s setup before run(): read the on-disk record, then
// overwrite Version with the running binary version and blank Mode to the empty
// --mode that a --revalidate invocation carries.
func newRevalSF(dir string) *state.StateFile {
	sf := state.NewStateFile(dir)
	_ = sf.Read()
	sf.Version = version.Version
	sf.Mode = ""
	sf.DryRun = false
	return sf
}

func TestRunRevalidate_Guards(t *testing.T) {
	ctx := context.Background()

	t.Run("no_state_file_refused", func(t *testing.T) {
		dir := t.TempDir()
		log := logging.New(dir+"/installer.log", false)
		sf := state.NewStateFile(dir) // never written
		cfg := &config{stateDir: dir, revalidate: true}
		if rc := runRevalidate(ctx, executor.NewMockExecutor(), sf, cfg, log); rc != state.ExitRefused {
			t.Errorf("no state file: rc=%d want ExitRefused(%d)", rc, state.ExitRefused)
		}
	})

	t.Run("committed_is_noop", func(t *testing.T) {
		dir := t.TempDir()
		writeRevalState(t, dir, state.StateCommitted, version.Version)
		log := logging.New(dir+"/installer.log", false)
		cfg := &config{stateDir: dir, revalidate: true}
		if rc := runRevalidate(ctx, executor.NewMockExecutor(), newRevalSF(dir), cfg, log); rc != state.ExitCommitted {
			t.Errorf("committed no-op: rc=%d want ExitCommitted(%d)", rc, state.ExitCommitted)
		}
	})

	t.Run("non_degraded_terminal_refused", func(t *testing.T) {
		dir := t.TempDir()
		writeRevalState(t, dir, state.StateFailedRebuild, version.Version)
		log := logging.New(dir+"/installer.log", false)
		cfg := &config{stateDir: dir, revalidate: true}
		if rc := runRevalidate(ctx, executor.NewMockExecutor(), newRevalSF(dir), cfg, log); rc != state.ExitRefused {
			t.Errorf("failed-state refuse: rc=%d want ExitRefused(%d)", rc, state.ExitRefused)
		}
		got := state.NewStateFile(dir)
		_ = got.Read()
		if got.State != state.StateFailedRebuild {
			t.Errorf("refuse must NOT change state; got %s", got.State)
		}
	})

	t.Run("version_mismatch_refused_no_mask", func(t *testing.T) {
		dir := t.TempDir()
		writeRevalState(t, dir, state.StateDegraded, "0.0.0-different")
		log := logging.New(dir+"/installer.log", false)
		cfg := &config{stateDir: dir, revalidate: true}
		if rc := runRevalidate(ctx, executor.NewMockExecutor(), newRevalSF(dir), cfg, log); rc != state.ExitRefused {
			t.Errorf("version mismatch: rc=%d want ExitRefused(%d)", rc, state.ExitRefused)
		}
		got := state.NewStateFile(dir)
		_ = got.Read()
		if got.State != state.StateDegraded {
			t.Errorf("version mismatch must NOT flip to COMMITTED; got %s", got.State)
		}
	})

	t.Run("degraded_failing_assertions_stays_degraded_no_mask", func(t *testing.T) {
		dir := t.TempDir()
		writeRevalState(t, dir, state.StateDegraded, version.Version)
		log := logging.New(dir+"/installer.log", false)
		cfg := &config{stateDir: dir, revalidate: true}
		// A bare MockExecutor reports no nft tables / inactive services, so the
		// live assertion suite fails → recommit MUST leave DEGRADED (no masking).
		if rc := runRevalidate(ctx, executor.NewMockExecutor(), newRevalSF(dir), cfg, log); rc != state.ExitDegraded {
			t.Errorf("failing assertions: rc=%d want ExitDegraded(%d)", rc, state.ExitDegraded)
		}
		got := state.NewStateFile(dir)
		_ = got.Read()
		if got.State != state.StateDegraded {
			t.Errorf("NO-MASK: failing live assertions must leave DEGRADED; got %s", got.State)
		}
	})
}
