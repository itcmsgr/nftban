// =============================================================================
// NFTBan v1.76.0 - Installer systemd Helpers
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-services-systemd"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-05"
// meta:description="systemd-tmpfiles --create and polkit restart for installer parity"
// meta:inventory.files="internal/installer/services/systemd.go"
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

// ApplyTmpfiles runs systemd-tmpfiles --create to create runtime directories
// with correct ownership. The tmpfiles.d config is installed by the package
// manager to /usr/lib/tmpfiles.d/nftban.conf. This call ensures /run/nftban
// and other tmpfiles-managed paths exist with correct owner/mode immediately
// after install (not just on next boot).
func ApplyTmpfiles(exec executor.Executor, log *logging.Logger) {
	if !exec.FileExists(fhs.TmpfilesConf) {
		log.Debug("tmpfiles.d config not found at %s — skipping", fhs.TmpfilesConf)
		return
	}
	if !exec.CommandExists("systemd-tmpfiles") {
		log.Debug("systemd-tmpfiles not available — skipping")
		return
	}

	res := exec.Run("systemd-tmpfiles", "--create", fhs.TmpfilesConf)
	if res.ExitCode == 0 {
		log.Debug("systemd-tmpfiles --create completed")
	} else {
		log.Warn("systemd-tmpfiles --create failed (exit %d) — non-fatal", res.ExitCode)
	}
}

// RestartPolkit restarts the polkit service so that newly installed or removed
// polkit rules take effect. Non-fatal — polkit may not be installed.
func RestartPolkit(exec executor.Executor, log *logging.Logger) {
	if !exec.ServiceActive("polkit") {
		log.Debug("polkit not active — skipping restart")
		return
	}
	res := exec.Run("systemctl", "restart", "polkit")
	if res.ExitCode == 0 {
		log.Debug("polkit restarted")
	} else {
		log.Warn("polkit restart failed (exit %d) — non-fatal", res.ExitCode)
	}
}
