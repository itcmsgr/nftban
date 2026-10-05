// =============================================================================
// NFTBan v1.235 - `nftban-core ports load` is retired
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="cmd_ports_load_retired_v1235_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-05"
// meta:description="v1.235 B1 (SEC-LOAD-PORTS-TRUSTS-CALLER-SUPPLIED-SSH-AUTHORITY; v1.234 plan L494). `nftban-core ports load` asked the daemon to flush every port set and reload ports.d without an SSH floor. It must now refuse with guidance and never reach the daemon. On e79a1173 the old path runs (privilege check or IPC dial error, no 'retired'), so this test FAILS there."
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

	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

func TestPortsLoadRetired_v1235(t *testing.T) {
	cfg := &nftbanconf.Config{ConfigDir: t.TempDir()}

	err := cmdPorts("load", cfg)
	if err == nil {
		t.Fatalf("`nftban-core ports load` returned nil; the action is retired and must refuse")
	}
	for _, want := range []string{"retired", "nftban firewall rebuild"} {
		if !strings.Contains(err.Error(), want) {
			t.Errorf("error %q does not contain %q", err.Error(), want)
		}
	}
}
