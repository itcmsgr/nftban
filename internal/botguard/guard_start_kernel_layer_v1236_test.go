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
	"path/filepath"
	"testing"

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
	m.config.BatchSignalFile = filepath.Join(t.TempDir(), "batch_signals.jsonl")
	m.verifier = NewFCrDNSVerifier(m.config, nil)
	if err := m.Start(ctx); err != nil {
		t.Fatalf("Start: %v", err)
	}
	cancel()
	return m, calls
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
