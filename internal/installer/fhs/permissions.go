// =============================================================================
// NFTBan v1.76 - Installer FHS Permissions
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: Copyright (c) 2024-2026 Antonios Voulvoulis <contact@nftban.com>
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
	"fmt"
	"os"
	"strings"

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

// applyCanonicalTree applies the CANONICAL owner and mode to every directory that
// RequiredDirs declares at or below root. It is bounded by that declaration and is
// never recursive.
//
// A `chown -R` here would be unbounded in three separate ways, all measured:
//  1. It flattens heterogeneous ownership the canonical matrix deliberately declares.
//     `chown -R nftban:nftban /var/lib/nftban` collapses reports/auditors
//     (root:nftban-auditor 0770/0660 — the audit-evidence boundary), plus backup/,
//     update-backups/ and pro/ (root:nftban), into the daemon's own identity. The
//     PRIMARY generated script explicitly excludes the auditor tree from its sweep
//     and re-applies it separately, so the recursive fallback was strictly weaker
//     than the path it stands in for.
//  2. `chown -R nftban:nftban /run/nftban` flattens firewall-validate (root:nftban 2750).
//  3. Recursion CROSSES MOUNT BOUNDARIES (measured: a bind mount under the tree is
//     traversed and the real backing content is chowned). chown has no
//     --one-file-system; only find has -xdev.
//
// Symlink escape was measured and is NOT a vector here: chown -R defaults to -P, so it
// neither traverses symlinked directories nor dereferences symlinked files. That is
// recorded so the constraint is not re-derived as folklore, and so that adding -L or -H
// is understood to be a security change.
//
//	INVARIANT: RECOVERY/FALLBACK MUST NOT BE WEAKER THAN PRIMARY.
//
// Ownership is established on the canonical directory skeleton only. Files take their
// ownership from the writer that creates them, which is where path authority exists —
// the same rule the log tree adopted in v1.228.10.
func applyCanonicalTree(exec executor.Executor, root string) {
	for _, d := range RequiredDirs {
		if d.Path != root && !strings.HasPrefix(d.Path, root+"/") {
			continue
		}
		if !exec.FileExists(d.Path) {
			continue
		}
		owner := d.Owner
		if owner == "" {
			owner = "root:root"
		}
		exec.Run("chown", owner, d.Path)
		exec.Run("chmod", fmt.Sprintf("%04o", d.Mode), d.Path)
	}
}

// applyPermissions sets ownership and mode on key directories/files.
func applyPermissions(exec executor.Executor, log *logging.Logger) {
	// Every tree below derives from RequiredDirs, the same canonical authority
	// EnsureDirectories uses and the projection build/fhs-spec.yaml generates.
	applyCanonicalTree(exec, EtcDir)   // /etc/nftban
	applyCanonicalTree(exec, DataDir)  // /var/lib/nftban — preserves the auditor boundary
	applyCanonicalTree(exec, CacheDir) // /var/cache/nftban
	applyCanonicalTree(exec, RunDir)   // /run/nftban — preserves firewall-validate 2750

	// /usr/lib/nftban/bin — root:root 0755. Not declared in RequiredDirs; package-owned
	// content already ships root:root, so the directory alone is asserted here.
	if exec.FileExists(BinDir) {
		exec.Run("chown", "root:root", BinDir)
		exec.Run("chmod", "0755", BinDir)
	}

	// /var/log/nftban — canonical skeleton only (INV-LOG-OWN-01, v1.228.10).
	for _, dir := range CanonicalLogDirs {
		if !exec.FileExists(dir) {
			continue
		}
		exec.Run("chown", "nftban:nftban", dir)
		exec.Run("chmod", "0750", dir)
	}

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
