// =============================================================================
// NFTBan v1.0 - nftband Daemon Dispatch Tests
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="daemon_dispatch_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-03-20"
// meta:description="Unit tests for IPC request dispatch routing"
// meta:input="Test cases"
// meta:output="Test results"
// meta:depends="testing"
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
	"testing"

	"github.com/itcmsgr/nftban/internal/eventbus"
	"github.com/itcmsgr/nftban/internal/module"
	"github.com/itcmsgr/nftban/internal/stats"
)

// newTestDaemon creates a minimal Daemon for dispatch testing.
// Backend is nil — nftbackend.New() requires nftables kernel support
// which is unavailable in CI containers. Methods that need backend
// will panic, caught by recover() in TestHandleSocketRequest_AllMethodsDefined.
func newTestDaemon() *Daemon {
	return &Daemon{
		bus:      eventbus.New(),
		registry: module.NewRegistry(),
		stats:    stats.NewCollector(stats.DefaultConfig()),
		connSem:  make(chan struct{}, MaxConcurrentIPCConns),
	}
}

// =============================================================================
// Dispatch Routing Tests
// =============================================================================

func TestHandleSocketRequest_Ping(t *testing.T) {
	d := newTestDaemon()
	defer d.bus.Close()

	resp := d.handleSocketRequest(SocketRequest{Method: "ping"})

	if !resp.Success {
		t.Error("expected Success=true for ping")
	}
	if resp.Data != "pong" {
		t.Errorf("expected Data=%q, got %v", "pong", resp.Data)
	}
}

func TestHandleSocketRequest_UnknownMethod(t *testing.T) {
	d := newTestDaemon()
	defer d.bus.Close()

	resp := d.handleSocketRequest(SocketRequest{Method: "nonexistent"})

	if resp.Success {
		t.Error("expected Success=false for unknown method")
	}
	if resp.Error != "unknown method: nonexistent" {
		t.Errorf("expected error %q, got %q", "unknown method: nonexistent", resp.Error)
	}
}

func TestHandleSocketRequest_EmptyMethod(t *testing.T) {
	d := newTestDaemon()
	defer d.bus.Close()

	resp := d.handleSocketRequest(SocketRequest{Method: ""})

	if resp.Success {
		t.Error("expected Success=false for empty method")
	}
	if resp.Error != "unknown method: " {
		t.Errorf("expected error %q, got %q", "unknown method: ", resp.Error)
	}
}

// =============================================================================
// Method Routing Coverage Tests
// Verify that known methods are routed (not rejected as unknown)
// =============================================================================

func TestHandleSocketRequest_KnownMethodsNotRejected(t *testing.T) {
	// These methods should NOT return "unknown method" error.
	// They may fail due to missing params or nil subsystems, but the
	// important thing is that the dispatch routes them correctly.
	knownMethods := []string{
		"ping",
		// Note: We only test ping here because other methods need
		// properly initialized subsystems (backend, opQueue, etc.)
		// to avoid nil pointer panics. The key test is that "unknown
		// method" is returned only for truly unknown methods.
	}

	d := newTestDaemon()
	defer d.bus.Close()

	for _, method := range knownMethods {
		t.Run(method, func(t *testing.T) {
			resp := d.handleSocketRequest(SocketRequest{
				Method: method,
				Params: map[string]any{},
			})

			if resp.Error == "unknown method: "+method {
				t.Errorf("method %q was rejected as unknown, but should be a known method", method)
			}
		})
	}
}

func TestHandleSocketRequest_AllMethodsDefined(t *testing.T) {
	// Verify that all documented IPC methods are handled
	// (not returned as "unknown method")
	expectedMethods := []string{
		"status", "modules", "ban", "unban",
		"add_element", "delete_element", "flush_set", "apply_ruleset",
		"check", "persist_ban", "unpersist_ban",
		"sync", "load_ports", "add_port_element", "delete_port_element",
		"load_cidrs", "stats", "stats_history", "snapshot_profile",
		"ping", "watchdog_status", "watchdog_pressure", "watchdog_events",
		"protect_ban", "unprotect_ban", "get_evictable_bans", "evict_old_bans",
		"permanent_ban_stats", "replace_set", "flush_source", "queue_status",
		"reload",
		"set_counts", "reconcile", "source_index_count",
		"access_allow", "access_revoke",
	}

	d := newTestDaemon()
	defer d.bus.Close()

	for _, method := range expectedMethods {
		t.Run(method, func(t *testing.T) {
			// We use recover to catch panics from nil subsystems
			// The test passes if the method is recognized (no "unknown method" error)
			var resp SocketResponse
			func() {
				defer func() {
					if r := recover(); r != nil {
						// Panic from nil subsystem is OK - method was recognized and routed
						resp = SocketResponse{Success: false, Error: "panic (expected - nil subsystem)"}
					}
				}()
				resp = d.handleSocketRequest(SocketRequest{
					Method: method,
					Params: map[string]any{},
				})
			}()

			if resp.Error == "unknown method: "+method {
				t.Errorf("method %q is not handled in dispatch switch", method)
			}
		})
	}
}

func TestDispatch_ConcurrentRequests_NoRace(t *testing.T) {
	d := newTestDaemon()
	defer d.bus.Close()

	done := make(chan struct{}, 20)
	for i := 0; i < 20; i++ {
		go func() {
			defer func() {
				if r := recover(); r != nil {
					// Expected — nil subsystems
				}
				done <- struct{}{}
			}()
			d.handleSocketRequest(SocketRequest{Method: "ping"})
			d.handleSocketRequest(SocketRequest{Method: "nonexistent"})
		}()
	}
	for i := 0; i < 20; i++ {
		<-done
	}
}
