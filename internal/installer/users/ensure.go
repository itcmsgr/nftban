// =============================================================================
// NFTBan v1.98.x - Installer User/Group Ensure (PR-14-pre G-14-A)
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-users"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-19"
// meta:description="Idempotent creation of NFTBan system users/groups for source install"
// meta:inventory.files="internal/installer/users/ensure.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units=""
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
//
// Why this package exists:
//
// Package installs (RPM/DEB) create the nftban user and groups via maintainer
// scripts: RPM %pre `useradd -r`, DEB postinst `adduser --system`. The Go
// installer then runs AFTER users/groups already exist and only enforces
// FHS permissions on already-present files.
//
// Source install has no package manager. Before the Go installer's Prepare
// phase can stage payload (and before any chown can target `nftban:nftban`),
// users and groups must be created. This package does that — idempotently,
// so re-running is a no-op — and is called ONLY when cfg.source is true
// from within phasePrepare.
//
// Behavior parity: the created users/groups match what RPM %pre and DEB
// postinst produce today. No new users, no new groups, no new membership —
// only source-install-path equivalence to the package path.
//
// =============================================================================

package users

import (
	"fmt"
	"strings"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// nftbanHome is the home directory for the nftban system user.
// Must match what fhs.EnsureDirectories will create during Prepare.
const nftbanHome = "/var/lib/nftban"

// nftbanShell is the login shell for the nftban system user.
// nologin prevents interactive login while still allowing systemd units
// to run as this user.
const nftbanShell = "/usr/sbin/nologin"

// nftbanGecos is the human-readable description of the nftban user.
const nftbanGecos = "NFTBan system user"

// systemGroups are the groups that source install must ensure exist.
// Order matters: nftban must be first because the nftban user belongs to it.
var systemGroups = []string{
	"nftban",
	"nftban-auditor",
	"suricata",
}

// Ensure creates all NFTBan system users and groups idempotently.
//
// Creates (in order):
//  1. system groups: nftban, nftban-auditor, suricata
//  2. nftban system user (primary group: nftban, home: /var/lib/nftban, shell: nologin)
//  3. adds root to the nftban group (for config-read access)
//
// Idempotent: each step skips creation if the entity already exists. Safe to
// run on hosts where package installs previously created the same entities.
//
// Returns an error only if a creation command fails on a missing entity.
// Distro dispatch uses distro.ID (normalized by detect.DetectDistro).
func Ensure(exec executor.Executor, distro *detect.DistroInfo, log *logging.Logger) error {
	if distro == nil {
		return fmt.Errorf("users.Ensure: distro info is nil (Detect phase must run first)")
	}

	family := distroFamily(distro.ID)
	log.Debug("users.Ensure: distro=%s family=%s", distro.ID, family)

	// 1. Groups
	for _, group := range systemGroups {
		if exec.GroupExists(group) {
			log.Debug("users.Ensure: group %s already exists (skip)", group)
			continue
		}
		if err := createGroup(exec, family, group, log); err != nil {
			return fmt.Errorf("create group %s: %w", group, err)
		}
		log.Info("created system group: %s", group)
	}

	// 2. nftban user
	if !exec.UserExists("nftban") {
		if err := createNftbanUser(exec, family, log); err != nil {
			return fmt.Errorf("create nftban user: %w", err)
		}
		log.Info("created system user: nftban")
	} else {
		log.Debug("users.Ensure: user nftban already exists (skip)")
	}

	// 3. root → nftban group
	if err := ensureRootInNftbanGroup(exec, log); err != nil {
		// Non-fatal: root can still function without being in the group on most
		// hosts. Log and continue.
		log.Warn("could not add root to nftban group: %v", err)
	}

	return nil
}

// distroFamily classifies the distro ID into "debian" or "rhel".
// Returns "debian" for debian/ubuntu, "rhel" for rhel/centos/fedora/rocky/almalinux.
// Unknown distros fall back to "rhel" behavior (useradd/groupadd are more portable
// than adduser/addgroup, which is Debian-specific).
func distroFamily(id string) string {
	switch strings.ToLower(id) {
	case "debian", "ubuntu":
		return "debian"
	case "rhel", "centos", "fedora", "rocky", "almalinux":
		return "rhel"
	default:
		return "rhel"
	}
}

// createGroup creates a system group using the distro-appropriate command.
func createGroup(exec executor.Executor, family, group string, log *logging.Logger) error {
	var res executor.Result
	switch family {
	case "debian":
		res = exec.Run("addgroup", "--system", group)
	default: // rhel and fallback
		res = exec.Run("groupadd", "--system", group)
	}
	if res.ExitCode != 0 {
		return fmt.Errorf("exit %d: %s", res.ExitCode, strings.TrimSpace(res.Stderr))
	}
	return nil
}

// createNftbanUser creates the nftban system user with the canonical shape.
//
// Debian/Ubuntu uses adduser (Debian-specific wrapper around useradd).
// RHEL-family uses useradd directly with -r (system user) + -g nftban
// (primary group must already exist — the group creation step above ensures it).
func createNftbanUser(exec executor.Executor, family string, log *logging.Logger) error {
	var res executor.Result
	switch family {
	case "debian":
		res = exec.Run("adduser",
			"--system",
			"--group",
			"--home", nftbanHome,
			"--no-create-home",
			"--disabled-login",
			"--gecos", nftbanGecos,
			"nftban",
		)
	default: // rhel and fallback
		res = exec.Run("useradd",
			"-r",
			"-g", "nftban",
			"-d", nftbanHome,
			"-s", nftbanShell,
			"-c", nftbanGecos,
			"nftban",
		)
	}
	if res.ExitCode != 0 {
		return fmt.Errorf("exit %d: %s", res.ExitCode, strings.TrimSpace(res.Stderr))
	}
	return nil
}

// ensureRootInNftbanGroup adds the root user to the nftban group if not
// already a member. Idempotent. Non-fatal on failure (caller decides).
func ensureRootInNftbanGroup(exec executor.Executor, log *logging.Logger) error {
	// Check current membership via `id -nG root`.
	res := exec.Run("id", "-nG", "root")
	if res.ExitCode == 0 {
		for _, g := range strings.Fields(res.Stdout) {
			if g == "nftban" {
				log.Debug("users.Ensure: root already in nftban group (skip)")
				return nil
			}
		}
	}

	// Add root to nftban group via usermod -a -G.
	add := exec.Run("usermod", "-a", "-G", "nftban", "root")
	if add.ExitCode != 0 {
		return fmt.Errorf("usermod exit %d: %s", add.ExitCode, strings.TrimSpace(add.Stderr))
	}
	log.Info("added root to nftban group")
	return nil
}
