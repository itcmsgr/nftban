// =============================================================================
// NFTBan v1.76 - Installer FHS Permissions
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-fhs-permissions"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="FHS directory creation, permissions, capabilities, ACLs"
// meta:inventory.files="internal/installer/fhs/permissions.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package fhs

import (
	"os"

	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// EnsureDirectories creates all required FHS directories with correct ownership.
func EnsureDirectories(exec executor.Executor, log *logging.Logger) {
	for _, d := range RequiredDirs {
		if err := exec.MkdirAll(d.Path, os.FileMode(d.Mode)); err != nil {
			log.Warn("mkdir %s: %v", d.Path, err)
			continue
		}
		if d.Owner != "" {
			res := exec.Run("chown", d.Owner, d.Path)
			if res.ExitCode != 0 {
				log.Warn("chown %s %s: %s", d.Owner, d.Path, res.Stderr)
			}
		}
	}
	log.Debug("FHS directories verified (%d paths)", len(RequiredDirs))
}

// SetPermissions runs the FHS permission script if available,
// otherwise applies permissions directly.
func SetPermissions(exec executor.Executor, log *logging.Logger) {
	// Prefer the generated script (single source of truth)
	if exec.FileExists(FHSPermissionsScript) {
		res := exec.Run("bash", FHSPermissionsScript)
		if res.ExitCode == 0 {
			log.Debug("FHS permissions set via %s", FHSPermissionsScript)
			return
		}
		log.Warn("fhs-permissions.sh failed (exit %d), applying manual fallback", res.ExitCode)
	}

	// Manual fallback: set key permissions directly
	applyPermissions(exec, log)
}

// SetCapabilities sets Linux capabilities on binaries.
func SetCapabilities(exec executor.Executor, log *logging.Logger) {
	if !exec.CommandExists("setcap") {
		log.Debug("setcap not available, skipping capabilities")
		return
	}
	for _, bin := range []string{NftbanCoreBin, NftbandBin} {
		if exec.FileExists(bin) {
			res := exec.Run("setcap", "cap_net_admin+ep", bin)
			log.CmdResult("setcap "+bin, res.ExitCode, res.Stderr)
		}
	}
}

// applyPermissions sets ownership and mode on key directories/files.
func applyPermissions(exec executor.Executor, log *logging.Logger) {
	// /etc/nftban — root:nftban 0640 for conf files
	exec.Run("chown", "-R", "root:nftban", EtcDir)
	exec.Run("chmod", "0750", EtcDir)

	// /usr/lib/nftban/bin — root:root 0755
	exec.Run("chown", "-R", "root:root", BinDir)

	// /var/lib/nftban — nftban:nftban 0750
	exec.Run("chown", "-R", "nftban:nftban", DataDir)
	exec.Run("chmod", "0750", DataDir)

	// /var/log/nftban — nftban:nftban 0750
	exec.Run("chown", "-R", "nftban:nftban", LogDir)
	exec.Run("chmod", "0750", LogDir)

	// /var/cache/nftban — nftban:nftban 0750
	exec.Run("chown", "-R", "nftban:nftban", CacheDir)
	exec.Run("chmod", "0750", CacheDir)

	// /run/nftban — nftban:nftban 0755
	exec.Run("chown", "-R", "nftban:nftban", RunDir)
	exec.Run("chmod", "0755", RunDir)

	// /var/lib/node_exporter/textfile_collector — nftban:nftban 0755 (optional)
	if exec.FileExists(NodeExporterDir) {
		exec.Run("chown", "nftban:nftban", NodeExporterDir)
		exec.Run("chmod", "0755", NodeExporterDir)
	}

	// /usr/sbin/nftban* — root:nftban 0750
	exec.Run("chown", "root:nftban", NftbanCLI)
	exec.Run("chmod", "0750", NftbanCLI)

	log.Debug("FHS permissions applied (manual fallback)")
}
