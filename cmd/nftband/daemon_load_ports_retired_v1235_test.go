// =============================================================================
// NFTBan v1.235 - load_ports IPC method is retired
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="daemon_load_ports_retired_v1235_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-05"
// meta:description="v1.235 B1 (SEC-LOAD-PORTS-TRUSTS-CALLER-SUPPLIED-SSH-AUTHORITY; v1.234 plan L494). load_ports flushed all eight port sets and re-added only ports.d with no SSH floor. The method must stay recognised (an old client gets the reason, not 'unknown method') but must refuse: Success=false, an error naming the retirement and the replacement (`nftban firewall rebuild`). On e79a1173 the old handler runs instead (with the test daemon's nil subsystems it panics or returns a different error), so this test FAILS there."
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
	"strings"
	"testing"
)

func TestLoadPortsRetired_v1235(t *testing.T) {
	d := newTestDaemon()
	defer d.bus.Close()

	var resp SocketResponse
	func() {
		defer func() {
			if r := recover(); r != nil {
				t.Fatalf("load_ports reached a handler that touched daemon subsystems (panic: %v); it must refuse without side effects", r)
			}
		}()
		resp = d.handleSocketRequest(SocketRequest{Method: "load_ports", Params: map[string]any{}})
	}()

	if resp.Success {
		t.Fatalf("load_ports returned Success=true; the method is retired and must refuse")
	}
	if strings.HasPrefix(resp.Error, "unknown method") {
		t.Fatalf("load_ports must stay recognised so old clients get the reason, got %q", resp.Error)
	}
	for _, want := range []string{"retired", "nftban firewall rebuild"} {
		if !strings.Contains(resp.Error, want) {
			t.Errorf("load_ports error %q does not contain %q", resp.Error, want)
		}
	}
}
