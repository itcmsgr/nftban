// =============================================================================
// NFTBan v1.73 - Installer Firewall Rebuild
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-rebuild"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Run nftban firewall rebuild with timeout — FATAL on failure"
// meta:inventory.files="internal/installer/switchop/rebuild.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package switchop

import (
	"fmt"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/fhs"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// rebuildTimeout is the wall-clock limit for nftban firewall rebuild.
const rebuildTimeout = 60 * time.Second

// Rebuild runs "nftban firewall rebuild" and returns an error if it fails.
// No retry, no fallback. Failure is FATAL (v1.70.0 invariant: rebuild failure
// must not be silently converted to reload).
func Rebuild(exec executor.Executor, log *logging.Logger) error {
	log.Info("running nftban firewall rebuild (timeout=%s)", rebuildTimeout)

	res := exec.RunTimeout(rebuildTimeout, fhs.NftbanCLI, "firewall", "rebuild")
	log.CmdResult("nftban firewall rebuild", res.ExitCode, res.Stderr)

	if res.ExitCode != 0 {
		// Write install-failed marker for runtime CLI
		if err := exec.WriteFileAtomic(fhs.InstallFailedMarker, []byte("NFTBAN_INSTALL_FAILED=1\n"), 0644); err != nil {
			log.Warn("failed to write install-failed marker: %v", err)
		}
		return fmt.Errorf("nftban firewall rebuild failed (exit %d): %s", res.ExitCode, res.Stderr)
	}

	log.Info("firewall rebuild completed successfully")
	return nil
}
