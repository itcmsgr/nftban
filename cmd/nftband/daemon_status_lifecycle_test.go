// SPDX-License-Identifier: MPL-2.0
// meta:name="nftband"
// meta:type="cmd"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:description="Tests that the status IPC exposes the lifecycle snapshot additively without dropping pre-existing fields."
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"

package main

import (
	"testing"
	"time"

	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/module"
)

// STATUS_IPC_ADDITIVE_COMPATIBILITY: the lifecycle object is ADDED; every
// pre-existing status field remains present and unchanged in name.
func TestStatusIPC_AdditiveLifecycle(t *testing.T) {
	d := &Daemon{
		bus:       eventbus.New(),
		registry:  module.NewRegistry(),
		startedAt: time.Now(),
		lifecycle: newStartupLifecycle(1),
	}
	d.lifecycle.setIPCBound(true)
	d.lifecycle.setIPCAccepting(true)

	resp := d.handleStatusRequest()
	if !resp.Success {
		t.Fatalf("status request not successful")
	}
	data, ok := resp.Data.(map[string]any)
	if !ok {
		t.Fatalf("status data is not a map")
	}

	// Pre-existing fields (backward-compatibility contract).
	for _, k := range []string{
		"version", "uptime", "uptime_seconds", "modules",
		"events_total", "subscriptions", "config_hash", "config_loaded",
	} {
		if _, present := data[k]; !present {
			t.Fatalf("status IPC dropped pre-existing field %q", k)
		}
	}

	// New additive object.
	lc, present := data["lifecycle"].(map[string]any)
	if !present {
		t.Fatalf("status IPC missing additive lifecycle object")
	}
	for _, k := range []string{
		"phase", "last_completed_phase", "state", "ready", "ready_sent",
		"ipc_bound", "ipc_accepting", "nft_ready", "opqueue_ready", "degraded_components",
	} {
		if _, ok := lc[k]; !ok {
			t.Fatalf("lifecycle object missing field %q", k)
		}
	}
	if lc["ipc_bound"] != true || lc["ipc_accepting"] != true {
		t.Fatalf("lifecycle did not reflect ipc bound/accepting: %v", lc)
	}
}

// A nil lifecycle must not panic status rendering.
func TestStatusIPC_NilLifecycleSafe(t *testing.T) {
	d := &Daemon{
		bus:       eventbus.New(),
		registry:  module.NewRegistry(),
		startedAt: time.Now(),
		// lifecycle intentionally nil
	}
	resp := d.handleStatusRequest()
	data := resp.Data.(map[string]any)
	lc := data["lifecycle"].(map[string]any)
	if lc["available"] != false {
		t.Fatalf("nil lifecycle should render available=false, got %v", lc)
	}
}
