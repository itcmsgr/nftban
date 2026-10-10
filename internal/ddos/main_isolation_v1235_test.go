// =============================================================================
// NFTBan v1.235 - internal/ddos tests never read the host's /etc/nftban/nftban.conf
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
// meta:name="main_isolation_v1235_test"
// meta:type="test"
// meta:version="1.0.0"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-10-09"
// meta:description="Package-wide isolation for internal/ddos tests (installed-host isolation class, owner 2026-10-08: fix the host leak before the suite is used as proof). On an installed lab host /etc/nftban/nftban.conf is unreadable as non-root, the config loader exits and the WHOLE package reports FAIL (lab2 2026-10-09, identical on train D fa028d90); as root the host's config leaks into the run. CI has no /etc/nftban, so the loader uses its defaults. TestMain binds the default config path to an ABSENT file in a private temp dir: the CI behaviour on every host. Tests that need a specific config keep setting and restoring it themselves."
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

package ddos

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/itcmsgr/nftban/internal/nftbanconf"
)

func TestMain(m *testing.M) {
	dir, err := os.MkdirTemp("", "nftban-ddos-test-")
	if err != nil {
		panic(err)
	}
	// Absent file: the loader's documented defaults, never the host's configuration.
	nftbanconf.DefaultConfigFile = filepath.Join(dir, "nftban.conf")
	code := m.Run()
	_ = os.RemoveAll(dir)
	os.Exit(code)
}
