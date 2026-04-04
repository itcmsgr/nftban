// =============================================================================
// NFTBan v1.73 - Installer Login Monitoring Enable
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-services-login"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Enable login monitoring via nftban login enable"
// meta:inventory.files="internal/installer/services/login.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package services

import (
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// EnableLogin runs "nftban login enable" to activate login monitoring.
// Non-fatal — logs warnings.
func EnableLogin(exec executor.Executor, log *logging.Logger) {
	log.Info("enabling login monitoring")

	res := exec.Run(fhs.NftbanCLI, "login", "enable")
	log.CmdResult("nftban login enable", res.ExitCode, res.Stderr)

	if res.ExitCode != 0 {
		log.Warn("login enable failed (exit %d) — non-fatal", res.ExitCode)
	} else {
		log.Info("login monitoring enabled")
	}
}
