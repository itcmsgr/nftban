// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
//
// meta:description="v1.235 (owner 2026-10-10): WriteGate is asked before every kernel write. txConn (every Flush goes through it — nft_tx_structural_guard G3/G4) and runNftFile / runNftIgnoring refuse while the gate refuses, without touching the kernel; readConn (list/get/count) is not gated, so a daemon that may not write still reports what is loaded."

package setsync

import (
	"errors"
	"testing"

	"github.com/google/nftables"
)

func TestWriteGateRefusesWritesOnly(t *testing.T) {
	refusal := errors.New("refused: no firewall authority")
	dialed := 0
	m := &NFTManager{
		cachedTables: map[nftables.TableFamily]*nftables.Table{},
		newConn: func() (*nftables.Conn, error) {
			dialed++
			return nil, nil
		},
	}
	old := WriteGate
	t.Cleanup(func() { WriteGate = old })

	WriteGate = func() error { return refusal }
	if _, err := m.txConn(); !errors.Is(err, refusal) {
		t.Fatalf("txConn with a refusing gate: err=%v, want the refusal", err)
	}
	if dialed != 0 {
		t.Fatalf("txConn opened a connection (%d) although the gate refused", dialed)
	}
	if _, err := runNftFile("/nonexistent/ruleset.nft"); !errors.Is(err, refusal) {
		t.Fatalf("runNftFile with a refusing gate: err=%v, want the refusal (nft must not run)", err)
	}
	if err := runNftIgnoring(nil, "add", "element", "ip", "nftban", "x", "{ 192.0.2.1 }"); !errors.Is(err, refusal) {
		t.Fatalf("runNftIgnoring with a refusing gate: err=%v, want the refusal (nft must not run)", err)
	}
	if _, err := m.readConn(); err != nil {
		t.Fatalf("readConn must not be gated: %v", err)
	}
	if dialed != 1 {
		t.Fatalf("readConn dialed %d times, want 1", dialed)
	}

	WriteGate = func() error { return nil }
	if _, err := m.txConn(); err != nil {
		t.Fatalf("txConn with a granting gate: %v", err)
	}
	if dialed != 2 {
		t.Fatalf("granted txConn dialed %d times in total, want 2", dialed)
	}
}
