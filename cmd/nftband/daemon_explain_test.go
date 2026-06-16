// =============================================================================
// NFTBan v1.191.0 - nftband Daemon - explain_ip dispatch tests (6A)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="daemon_explain_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-06-16"
// meta:description="Dispatch tests: explain_ip is read-only and no cache-mutation IPC verb exists"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package main

import (
	"strings"
	"testing"

	"github.com/itcmsgr/nftban/internal/botguard"
)

// No writable/mutating decision-cache IPC verb may exist: only the read-only explain_ip is added.
func TestNO_CACHE_MUTATION_IPC_VERB_EXISTS(t *testing.T) {
	d := newTestDaemon()
	defer d.bus.Close()

	mutationVerbs := []string{
		"explain_ip_set", "decision_cache_set", "set_decision_cache",
		"cache_set", "cache_add", "cache_trust", "cache_block",
		"botguard_cache_set", "botguard_cache_add", "decision_cache_put",
	}
	for _, v := range mutationVerbs {
		resp := d.handleSocketRequest(SocketRequest{Method: v})
		if resp.Success {
			t.Fatalf("mutation cache verb %q must NOT exist", v)
		}
		if !strings.Contains(resp.Error, "unknown method") {
			t.Fatalf("mutation cache verb %q must be unknown, got error %q", v, resp.Error)
		}
	}
}

// explain_ip is a registered, read-only verb returning a temporary-cache report (degrades
// cleanly to cache_available data, never mutates).
func TestExplainIP_Dispatch_ReadOnly(t *testing.T) {
	d := newTestDaemon()
	defer d.bus.Close()
	d.registry.Register(botguard.New(), botguard.Descriptor())

	// Missing ip → clean error, no panic.
	if resp := d.handleSocketRequest(SocketRequest{Method: "explain_ip"}); resp.Success {
		t.Fatal("explain_ip without ip must fail cleanly")
	}

	resp := d.handleSocketRequest(SocketRequest{Method: "explain_ip", Params: map[string]any{"ip": "203.0.113.90"}})
	if !resp.Success {
		t.Fatalf("explain_ip should succeed, got error %q", resp.Error)
	}
	data, ok := resp.Data.(botguard.ExplainResponse)
	if !ok {
		t.Fatalf("explain_ip Data type = %T, want botguard.ExplainResponse", resp.Data)
	}
	if data.Source != botguard.ExplainSource || !data.Temporary || data.DurableAuthority != "not_evaluated" {
		t.Fatalf("explain_ip response must be temporary cache only with no durable claim: %+v", data)
	}
	if data.IP != "203.0.113.90" || data.Present {
		t.Fatalf("unknown IP must be reported absent (not present): %+v", data)
	}
}
