// =============================================================================
// NFTBan v1.73 - Installer Whitelist Sync
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-services-whitelist"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Run nftban sync to load whitelists and feeds after rebuild"
// meta:inventory.files="internal/installer/services/whitelist.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package services

import (
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

const (
	syncRetries = 3
	syncRetrySec = 1
	syncTimeout  = 15 * time.Second
)

// SyncWhitelist runs "nftban sync" to load whitelists and feeds.
// Retries up to 3 times with 1s delay. Non-fatal — logs warnings.
func SyncWhitelist(exec executor.Executor, log *logging.Logger) {
	for i := 1; i <= syncRetries; i++ {
		res := exec.RunTimeout(syncTimeout, fhs.NftbanCLI, "sync")
		log.CmdResult("nftban sync", res.ExitCode, res.Stderr)

		if res.ExitCode == 0 {
			log.Info("whitelist sync completed (attempt %d)", i)
			return
		}

		log.Warn("nftban sync attempt %d/%d failed (exit %d)", i, syncRetries, res.ExitCode)
		if i < syncRetries {
			time.Sleep(time.Duration(syncRetrySec) * time.Second)
		}
	}

	log.Warn("whitelist sync failed after %d attempts — non-fatal", syncRetries)
}
