// =============================================================================
// NFTBan v1.236 - active set counts: debounced kernel recount after daemon writes
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="nftband-count-refresh-test"
// meta:type="test"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-26"
// meta:description="Hermetic tests: noteSetWrite never blocks and coalesces; every recount-triggering IPC method is routed"
// meta:inventory.files="cmd/nftband/daemon_count_refresh_v1236_test.go"
// meta:inventory.privileges="none"
// =============================================================================

package main

// v1.236 COUNT-MECH-INCREMENTAL-COUNTER-DRIFT: daemon set writes ask for a debounced kernel
// recount of the active set counts.

import (
	"os"
	"regexp"
	"testing"
)

// noteSetWrite never blocks, and a burst of writes leaves one pending request.
func TestNoteSetWriteNeverBlocksAndCoalesces(t *testing.T) {
	var d Daemon
	d.noteSetWrite() // nil channel (daemon not initialised): must not block

	d.countRefresh = make(chan struct{}, 1)
	for i := 0; i < 100; i++ {
		d.noteSetWrite()
	}
	if n := len(d.countRefresh); n != 1 {
		t.Fatalf("pending recount requests = %d, want 1", n)
	}
}

// Every method that asks for a recount is a method the dispatcher routes (a misspelt name
// would silently never trigger one).
func TestSetWriteMethodsAreRoutedMethods(t *testing.T) {
	src, err := os.ReadFile("daemon_dispatch.go")
	if err != nil {
		t.Fatal(err)
	}
	routed := map[string]bool{}
	for _, m := range regexp.MustCompile(`case "([a-z_]+)":`).FindAllStringSubmatch(string(src), -1) {
		routed[m[1]] = true
	}
	for m := range setWriteMethods {
		if !routed[m] {
			t.Errorf("setWriteMethods lists %q, which the dispatcher does not route", m)
		}
	}
	for _, read := range []string{"status", "stats", "set_counts", "ping", "explain_ip"} {
		if setWriteMethods[read] {
			t.Errorf("read-only method %q must not ask for a recount", read)
		}
	}
}
