// =============================================================================
// NFTBan v1.236 - Installer whitelist sync: bounded wait on real completion
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-services-whitelist-wait-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-22"
// meta:description="SyncWhitelist waits once on the daemon's completion report; retries only an undelivered request; running/unknown/killed are never converged"
// meta:inventory.files="internal/installer/services/whitelist_wait_v1236_test.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================
package services

import (
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

const syncKey = "/usr/sbin/nftban:sync:--wait:300"

func syncCalls(m *executor.MockExecutor) int {
	n := 0
	for _, c := range m.Commands {
		if c.Name == "/usr/sbin/nftban" && len(c.Args) > 0 && c.Args[0] == "sync" {
			n++
		}
	}
	return n
}

func noRetryDelay(t *testing.T) {
	old := syncRetryDelay
	syncRetryDelay = time.Millisecond
	t.Cleanup(func() { syncRetryDelay = old })
}

// Only a request that never reached the daemon is retried.
func TestSyncWhitelistRetriesOnlyUndelivered(t *testing.T) {
	noRetryDelay(t)
	m := executor.NewMockExecutor()
	m.StrictUnregistered = true
	m.RunResultSeq[syncKey] = []executor.Result{{ExitCode: syncExitNotDelivered}, {ExitCode: 0}}
	if err := SyncWhitelist(m, newTestLogger()); err != nil {
		t.Fatalf("delivered on the 2nd attempt and completed: want nil, got %v", err)
	}
	if n := syncCalls(m); n != 2 {
		t.Fatalf("want 2 sync calls, got %d", n)
	}
}

func TestSyncWhitelistUndeliveredBounded(t *testing.T) {
	noRetryDelay(t)
	m := executor.NewMockExecutor()
	m.RunResults[syncKey] = executor.Result{ExitCode: syncExitNotDelivered}
	if err := SyncWhitelist(m, newTestLogger()); err == nil {
		t.Fatal("never delivered must be an error")
	}
	if n := syncCalls(m); n != syncRetries {
		t.Fatalf("want %d attempts, got %d", syncRetries, n)
	}
}

// Still running, unknown, failed and killed: one call, an error, and no re-submission
// (a re-submission would queue another full sync behind the running one).
func TestSyncWhitelistNoResubmitAfterDelivery(t *testing.T) {
	for name, res := range map[string]executor.Result{
		"running": {ExitCode: syncExitRunning},
		"unknown": {ExitCode: syncExitUnknown},
		"failed":  {ExitCode: 1},
		"killed":  {ExitCode: -1, TimedOut: true},
	} {
		t.Run(name, func(t *testing.T) {
			noRetryDelay(t)
			m := executor.NewMockExecutor()
			m.RunResults[syncKey] = res
			if err := SyncWhitelist(m, newTestLogger()); err == nil {
				t.Fatalf("%s must not be reported converged", name)
			}
			if n := syncCalls(m); n != 1 {
				t.Fatalf("%s: want exactly 1 sync call, got %d", name, n)
			}
		})
	}
}
