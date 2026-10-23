// =============================================================================
// NFTBan v1.236 - upgrade handover: stop only a daemon whose binary was replaced
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="installer-services-quiesce-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-23"
// meta:description="QuiesceReplacedDaemon stops nftband (socket, then service) only when its /proc/<pid>/exe is '(deleted)'; leaves a current-binary daemon and an inactive one alone"
// meta:inventory.files="internal/installer/services/quiesce_v1236_test.go"
// meta:inventory.privileges="none"
// =============================================================================
package services

import (
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
)

func quiesceMock(active bool, exe string) *executor.MockExecutor {
	m := executor.NewMockExecutor()
	m.Services["nftband.service"] = active
	m.Services["nftband.socket"] = active
	m.RunResults["systemctl:show:-p:MainPID:--value:nftband.service"] = executor.Result{Stdout: "4242\n"}
	m.RunResults["readlink:/proc/4242/exe"] = executor.Result{Stdout: exe + "\n"}
	return m
}

func TestQuiesceStopsReplacedBinary(t *testing.T) {
	m := quiesceMock(true, "/usr/lib/nftban/bin/nftband (deleted)")
	if !QuiesceReplacedDaemon(m, newTestLogger()) {
		t.Fatal("a daemon running a replaced binary must be stopped before the rebuild")
	}
	if m.ServiceActive("nftband.service") || m.ServiceActive("nftband.socket") {
		t.Fatal("service and socket must both be stopped")
	}
}

func TestQuiesceLeavesCurrentBinaryRunning(t *testing.T) {
	m := quiesceMock(true, "/usr/lib/nftban/bin/nftband")
	if QuiesceReplacedDaemon(m, newTestLogger()) {
		t.Fatal("a daemon running the installed binary takes the boundary and must be left running")
	}
	if !m.ServiceActive("nftband.service") {
		t.Fatal("the current daemon was stopped")
	}
}

func TestQuiesceInactiveIsNoop(t *testing.T) {
	m := quiesceMock(false, "/usr/lib/nftban/bin/nftband (deleted)")
	if QuiesceReplacedDaemon(m, newTestLogger()) {
		t.Fatal("nothing to stop when the daemon is not active")
	}
}
