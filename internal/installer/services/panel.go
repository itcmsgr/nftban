// =============================================================================
// NFTBan v1.73 - Installer Panel Enable
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-services-panel"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Enable panel integration for detected hosting panels"
// meta:inventory.files="internal/installer/services/panel.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package services

import (
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// EnablePanel runs "nftban services enable <panel>" for the detected panel.
// Non-fatal — logs warnings.
func EnablePanel(exec executor.Executor, panel detect.PanelType, log *logging.Logger) {
	if panel == detect.PanelNone {
		log.Debug("no panel detected — skipping panel enable")
		return
	}

	panelArg := strings.ToLower(string(panel))
	log.Info("enabling panel integration: %s", panel)

	res := exec.Run(fhs.NftbanCLI, "services", "enable", panelArg)
	log.CmdResult("nftban services enable "+panelArg, res.ExitCode, res.Stderr)

	if res.ExitCode != 0 {
		log.Warn("panel enable %s failed (exit %d) — non-fatal", panel, res.ExitCode)
	} else {
		log.Info("panel %s integration enabled", panel)
	}
}
