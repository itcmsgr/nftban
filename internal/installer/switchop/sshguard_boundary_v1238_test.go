// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>

package switchop

// v1.238 (audit KERNEL_WRITER_AUDIT_d016f838 V2): the installer's add of the SSH port to nftban
// tcp_ports_in holds the write boundary EXCLUSIVE; when the boundary is busy nothing is written and
// the emergency SSH table stays (the handoff is then not proven).

import (
	"errors"
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/nftlock"
)

// Tests never touch the real /run/nftban-writers lock: every test in this package gets a free
// boundary unless it installs its own (withBoundary).
func init() {
	sshPortWriteBoundary = func() (func(), error) { return func() {}, nil }
}

func withBoundary(t *testing.T, fn func() (func(), error)) {
	t.Helper()
	prev := sshPortWriteBoundary
	sshPortWriteBoundary = fn
	t.Cleanup(func() { sshPortWriteBoundary = prev })
}

func missingPortMock() *executor.MockExecutor {
	m := executor.NewMockExecutor()
	m.NftTables["ip:nftban"] = true
	m.NftTables["ip6:nftban"] = true
	m.NftSets["ip:nftban:tcp_ports_in"] = "elements = { 80, 443 }"
	m.NftSets["ip6:nftban:tcp_ports_in"] = "elements = { 80, 443 }"
	return m
}

func TestAssertSSHInLiveSetBoundaryFree(t *testing.T) {
	held, released := false, false
	withBoundary(t, func() (func(), error) { held = true; return func() { released = true }, nil })
	m := missingPortMock()
	AssertSSHInLiveSet(m, 2222, newTestLogger())
	for _, k := range []string{"ip:nftban:tcp_ports_in", "ip6:nftban:tcp_ports_in"} {
		if !strings.Contains(m.NftSets[k], "2222") {
			t.Errorf("%s: SSH port not added with a free boundary: %q", k, m.NftSets[k])
		}
	}
	if !held || !released {
		t.Errorf("boundary taken=%v released=%v, want both", held, released)
	}
}

func TestAssertSSHInLiveSetBoundaryBusyWritesNothing(t *testing.T) {
	withBoundary(t, func() (func(), error) { return nil, nftlock.ErrBusy })
	m := missingPortMock()
	AssertSSHInLiveSet(m, 2222, newTestLogger())
	for _, k := range []string{"ip:nftban:tcp_ports_in", "ip6:nftban:tcp_ports_in"} {
		if strings.Contains(m.NftSets[k], "2222") {
			t.Errorf("%s: written although the boundary was busy: %q", k, m.NftSets[k])
		}
	}
	// The emergency table is not touched here; with the port absent the handoff cannot be proven,
	// so HandOffEmergencySSH keeps the table (SSHHandoffProven requires the element).
	if len(m.NftDeleteTableCalls) != 0 {
		t.Errorf("busy path deleted tables: %v", m.NftDeleteTableCalls)
	}
}

func TestAssertSSHInLiveSetNoBoundaryWhenNothingMissing(t *testing.T) {
	called := false
	withBoundary(t, func() (func(), error) { called = true; return nil, errors.New("must not be called") })
	m := missingPortMock()
	m.NftSets["ip:nftban:tcp_ports_in"] = "elements = { 22, 80 }"
	m.NftSets["ip6:nftban:tcp_ports_in"] = "elements = { 22, 80 }"
	AssertSSHInLiveSet(m, 22, newTestLogger())
	if called {
		t.Error("boundary taken although nothing had to be written")
	}
}
