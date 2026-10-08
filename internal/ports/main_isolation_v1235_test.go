// =============================================================================
// NFTBan v1.235 - internal/ports tests never read the host's panel state
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="main_isolation_v1235_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-08"
// meta:description="Package-wide isolation for internal/ports tests (installed-host isolation class, owner 2026-10-08: fix the R11 host leak before the suite is used as proof). EffectiveServicePorts / LoadAllPorts read PanelStateFile; on an installed lab host that is /var/lib/nftban/panels/enabled.conf, unreadable as a non-root user (5 tests failed with permission denied on lab2) and, as root, the HOST's panel choice leaked into the result. TestMain binds PanelStateFile to an absent file in a private temp dir for the whole package, the same pattern cmd/nftban-core uses for nftbanconf.DefaultConfigFile."
// meta:input="None"
// meta:output="Test exit code"
// meta:depends="testing,os,path/filepath"
// meta:inventory.files=""
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="none"
// =============================================================================

package ports

import (
	"os"
	"path/filepath"
	"testing"
)

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "nftban-ports-test-")
	if err != nil {
		panic(err)
	}
	// Absent file in a private dir: "no panels enabled", never the host's choice.
	PanelStateFile = filepath.Join(dir, "panels", "enabled.conf")
	code := m.Run()
	_ = os.RemoveAll(dir)
	os.Exit(code)
}
