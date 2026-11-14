// =============================================================================
// NFTBan v1.236.0 - BotGuard Start() re-applies the kernel layer (RC-7 reboot)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// Package: botguard
// Purpose: The boot projection carries no module chains. An ENABLED BotGuard must
//          re-apply its kernel layer from Start() (as DDoS and PortScan do), so a reboot
//          does not leave it without its chain and jump; a DISABLED one must not.
//
// meta:name="botguard_guard_start_kernel_layer_v1236_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:package="botguard"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-11-03"
// meta:description="v1.236 RC-7: BotGuard Start() calls the kernel-layer apply exactly once when enabled, never when disabled; an apply failure is recorded and does not fail Start"
// meta:inventory.files="guard_start_kernel_layer_v1236_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges=""
// =============================================================================

package botguard

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/opqueue"
)

func startWithStubbedApply(t *testing.T, enabled bool, applyErr error) (*Module, int) {
	t.Helper()
	calls := 0
	orig := applyKernelLayer
	applyKernelLayer = func() error { calls++; return applyErr }
	t.Cleanup(func() { applyKernelLayer = orig })

	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	q := opqueue.NewOpQueue(&ttlBackend{ttl: map[string]uint32{}}, opqueue.DefaultQueueConfig())
	m := New()
	m.bus = eventbus.New()
	m.InitEnforcer(q)
	m.config.Enabled = enabled
	dir := t.TempDir()
	m.config.BatchSignalFile = filepath.Join(dir, "batch_signals.jsonl")
	// v1.237 TEST-BOTGUARD-START-TEMPDIR-CLEANUP-RACE: no ticker cycle may start during the test.
	m.config.LoopInterval = time.Hour
	m.verifier = NewFCrDNSVerifier(m.config, nil)
	if err := m.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	if !enabled {
		waitConsumerFirstDrain(t, dir)
	}
	cancel()
	return m, calls
}

// waitConsumerFirstDrain blocks until the disabled-path batch-signal consumer goroutine has
// finished its unconditional first drain. That drain runs even when the context is already
// cancelled, and it writes into dir: it creates the .lock file, and as its last action (deferred)
// it atomically renames botscan_consumer_status.json into place. Once that file exists, the
// goroutine makes no further writes. With LoopInterval at one hour no ticker cycle can follow, so
// after cancel() it only returns. Without this wait, cancel() returned at once and the drain could
// write while t.TempDir's cleanup removed the directory ("directory not empty", seen 3x in CI on
// 2026-11-13).
func waitConsumerFirstDrain(t *testing.T, dir string) {
	t.Helper()
	status := filepath.Join(dir, botscanConsumerStatusName)
	deadline := time.Now().Add(10 * time.Second)
	for {
		if _, err := os.Stat(status); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("batch-signal consumer did not finish its first drain within 10s (no %s)", status)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func TestBotguardStart_EnabledAppliesKernelLayerOnce(t *testing.T) {
	if _, calls := startWithStubbedApply(t, true, nil); calls != 1 {
		t.Fatalf("enabled BotGuard: kernel layer applied %d times, want 1", calls)
	}
}

func TestBotguardStart_DisabledNeverAppliesKernelLayer(t *testing.T) {
	if _, calls := startWithStubbedApply(t, false, nil); calls != 0 {
		t.Fatalf("disabled BotGuard: kernel layer applied %d times, want 0", calls)
	}
}

func TestBotguardStart_ApplyFailureRecordedNotFatal(t *testing.T) {
	m, calls := startWithStubbedApply(t, true, errors.New("nft refused"))
	if calls != 1 {
		t.Fatalf("kernel layer applied %d times, want 1", calls)
	}
	if st := m.Status(); st.LastError == "" {
		t.Fatalf("apply failure not recorded in status: %+v", st)
	}
}
