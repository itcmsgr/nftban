// =============================================================================
// NFTBan v1.73 - Installer Whitelist Sync
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
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
	"strconv"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// v1.236 (BUG-UPGRADE-SYNC-SCALES-WITH-PERMANENT-BANS-TIMEOUT-AND-ENFORCEMENT-GAP):
// the installer used to kill `nftban sync` after 15 s and try again, 3 times. A sync
// that needed longer (~3200 permanent bans took 15-30 s on v1.235.1) was reported
// FAILED while the daemon was still running it, and every retry queued another full
// sync behind it. Now ONE call waits, bounded, for the daemon's own completion
// report (`nftban sync --wait`, exit codes in cmd/nftban-core/cmd_sync.go). Only a
// request that was never delivered (exit 69: nothing ran) is retried.
// syncRetryDelay is a variable so tests do not sleep.
var syncRetryDelay = 2 * time.Second

const (
	syncRetries = 3 // only for "not delivered"
	syncWaitSec = 300
	// The sync command needs a little longer than its own wait to print the result.
	syncTimeout = (syncWaitSec + 30) * time.Second

	syncExitNotDelivered = 69
	syncExitUnknown      = 74
	syncExitRunning      = 75
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
	for i := 1; ; i++ {
		res := exec.RunTimeout(syncTimeout, fhs.NftbanCLI, "sync", "--wait", strconv.Itoa(syncWaitSec))
		log.CmdResult("nftban sync", res.ExitCode, res.Stderr)

		// Not silently tolerated: unless the daemon reports the sync completed, the
		// durable whitelist layer (including the operator session IP) is not proven
		// projected. The caller decides the final install verdict, but it must never
		// be an invisible warning, and the log says WHICH outcome it was.
		switch {
		case res.TimedOut:
			log.Warn("nftban sync was killed at the installer's %v bound — completion NOT observed (the daemon may still finish it)", syncTimeout)
			return fmt.Errorf("durable whitelist projection not observed: sync command killed after %v", syncTimeout)
		case res.ExitCode == 0:
			log.Info("whitelist sync completed (attempt %d)", i)
			return nil
		case res.ExitCode == syncExitNotDelivered && i < syncRetries:
			log.Warn("nftban sync attempt %d/%d not delivered (daemon unreachable, nothing ran); retrying", i, syncRetries)
			time.Sleep(syncRetryDelay)
			continue
		case res.ExitCode == syncExitNotDelivered:
			log.Warn("whitelist sync not delivered after %d attempts — durable whitelist NOT projected", syncRetries)
			return fmt.Errorf("durable whitelist projection failed: daemon unreachable after %d attempts", syncRetries)
		case res.ExitCode == syncExitRunning:
			log.Warn("whitelist sync still RUNNING after %ds — completion NOT observed; the daemon continues it, no further sync was queued", syncWaitSec)
			return fmt.Errorf("durable whitelist projection not observed: sync still running after %ds", syncWaitSec)
		case res.ExitCode == syncExitUnknown:
			log.Warn("whitelist sync completion UNKNOWN (no answer from the daemon) — durable whitelist NOT proven projected")
			return fmt.Errorf("durable whitelist projection unknown: no answer from the daemon")
		default:
			log.Warn("whitelist sync failed (exit %d) — durable whitelist NOT projected", res.ExitCode)
			return fmt.Errorf("durable whitelist projection failed (nftban sync exit %d)", res.ExitCode)
		}
	}
}
