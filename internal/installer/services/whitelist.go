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
	"fmt"
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
//
// v1.228.5 BUG-REBUILD-DISCARDS-FAILED-WHITELIST-RECONCILE: this is the SOLE
// installer convergence authority for the durable whitelist.d layer. The
// pre-daemon switchop.Rebuild explicitly DEFERS that projection (it passes
// --install-context), because it runs before StartDaemon and before
// AddSessionWhitelist writes 00-session.conf.
//
// It therefore MUST NOT be a silent warning. Previously a total failure here left
// only a log line while the install could still be reported COMMITTED — which
// relocates the false-success defect to a later phase instead of closing it.
// It now returns a verdict the caller records in install_state.
//
// Returns nil on convergence; a non-nil error when the durable whitelist could
// not be projected after all retries.
func SyncWhitelist(exec executor.Executor, log *logging.Logger) error {
	for i := 1; i <= syncRetries; i++ {
		res := exec.RunTimeout(syncTimeout, fhs.NftbanCLI, "sync")
		log.CmdResult("nftban sync", res.ExitCode, res.Stderr)

		if res.ExitCode == 0 {
			log.Info("whitelist sync completed (attempt %d)", i)
			return nil
		}

		log.Warn("nftban sync attempt %d/%d failed (exit %d)", i, syncRetries, res.ExitCode)
		if i < syncRetries {
			time.Sleep(time.Duration(syncRetrySec) * time.Second)
		}
	}

	// Not silently tolerated: the durable whitelist layer (including the operator
	// session IP) is unprojected. The caller decides the final install verdict, but
	// it must never be an invisible warning.
	log.Warn("whitelist sync failed after %d attempts — durable whitelist NOT projected", syncRetries)
	return fmt.Errorf("durable whitelist projection failed after %d attempts", syncRetries)
}
