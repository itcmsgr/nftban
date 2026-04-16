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
// Shell rebuild exit code contract (authoritative — do not redefine):
//   0 = PROTECTED (all checks passed)
//   1 = DEGRADED  (firewall operational, some module checks failed)
//   2 = FAILED    (rollback happened)
//   3 = FATAL     (rollback also failed)
//
// Exit 1 (DEGRADED) is expected during upgrade: module-scoped chains
// require the daemon to be running, which may not be the case yet.
// Only exit 2+ is treated as a fatal rebuild failure.
func Rebuild(exec executor.Executor, log *logging.Logger) error {
	log.Info("running nftban firewall rebuild (timeout=%s)", rebuildTimeout)

	res := exec.RunTimeout(rebuildTimeout, fhs.NftbanCLI, "firewall", "rebuild")
	log.CmdResult("nftban firewall rebuild", res.ExitCode, res.Stderr)

	if res.ExitCode == 1 {
		// DEGRADED: firewall base schema is loaded but module chains may be
		// missing (daemon was down during module re-enable). This is recoverable
		// — module chains will be re-created when daemon starts with modules enabled.
		log.Warn("firewall rebuild DEGRADED (exit 1): %s", res.Stderr)
		log.Warn("module chains may be absent — will be created on daemon start")
		// Continue — do not fail the install for a degraded rebuild
	} else if res.ExitCode >= 2 {
		// FAILED or FATAL: real rebuild failure, rollback may have happened
		if err := exec.WriteFileAtomic(fhs.InstallFailedMarker, []byte("NFTBAN_INSTALL_FAILED=1\n"), 0644); err != nil {
			log.Warn("failed to write install-failed marker: %v", err)
		}
		return fmt.Errorf("nftban firewall rebuild failed (exit %d): %s", res.ExitCode, res.Stderr)
	}

	log.Info("firewall rebuild completed (exit %d)", res.ExitCode)

	// Write schema version file (G7 parity with shell postinst).
	// The shell postinst wrote: echo "$CURRENT_SCHEMA" > /etc/nftban/.schema_version
	// We use the installed version as the schema identifier.
	versionData, err := exec.ReadFile(fhs.VersionFile)
	if err == nil {
		version := string(versionData)
		// Trim whitespace/newlines
		for len(version) > 0 && (version[len(version)-1] == '\n' || version[len(version)-1] == '\r' || version[len(version)-1] == ' ') {
			version = version[:len(version)-1]
		}
		if err := exec.WriteFileAtomic(fhs.SchemaVersionFile, []byte(version+"\n"), 0640); err != nil {
			log.Warn("write schema version: %v", err)
		} else {
			log.Debug("wrote schema version %s to %s", version, fhs.SchemaVersionFile)
		}
	}

	return nil
}
