// =============================================================================
// NFTBan v1.75.1 - Installer nftables Service Enable
// =============================================================================
// SPDX-License-Identifier: MPL-2.0
// meta:name="installer-switchop-enable"
// meta:type="lib"
// meta:owner="Antonios Voulvoulis <contact@nftban.com>"
// meta:created_date="2026-04-04"
// meta:description="Enable and start nftables service with xt-compat pre-check"
// meta:inventory.files="internal/installer/switchop/enable.go"
// meta:inventory.binaries=""
// meta:inventory.env_vars=""
// meta:inventory.config_files=""
// meta:inventory.systemd_units="nftables.service"
// meta:inventory.network=""
// meta:inventory.privileges="root"
// =============================================================================
package switchop

import (
	"fmt"
	"strings"
	"time"

	"github.com/itcmsgr/nftban/internal/installer/detect"
	"github.com/itcmsgr/nftban/internal/installer/executor"
	"github.com/itcmsgr/nftban/internal/installer/logging"
)

// EnableNftables enables and starts the nftables service, then verifies.
// Runs cleanXtCompat() first to remove stale xt target rules that would
// prevent nftables from starting (common on CSF/cPanel servers).
func EnableNftables(exec executor.Executor, distro *detect.DistroInfo, log *logging.Logger) error {
	if distro != nil {
		cleanXtCompat(exec, distro, log)
	}

	if err := exec.ServiceEnable("nftables"); err != nil {
		log.Warn("enable nftables: %v", err)
	}
	if err := exec.ServiceStart("nftables"); err != nil {
		return fmt.Errorf("start nftables: %w", err)
	}
	if !exec.ServiceActive("nftables") {
		return fmt.Errorf("nftables service not active after start")
	}
	log.Info("nftables service enabled and active")
	return nil
}

// cleanXtCompat detects and removes stale xt target / xtables compat rules
// from the system nftables.conf. These rules come from CSF/cPanel iptables-nft
// translation and cause `nft -f` to fail, preventing nftables.service from starting.
//
// Logic translated from cli/lib/nftban/helpers/autoheal.sh:378-414.
func cleanXtCompat(exec executor.Executor, distro *detect.DistroInfo, log *logging.Logger) {
	confPath := distro.NftConfPath
	if confPath == "" {
		log.Debug("no system nftables.conf path — skipping xt-compat check")
		return
	}
	if !exec.FileExists(confPath) {
		log.Debug("system nftables.conf not found at %s — skipping xt-compat check", confPath)
		return
	}

	// Dry-run validate the config
	res := exec.Run("nft", "-c", "-f", confPath)
	if res.ExitCode == 0 {
		log.Debug("system nftables.conf validates cleanly — no xt-compat issues")
		return
	}

	// Check if the failure is due to xt target / xtables compat rules
	combined := res.Stdout + "\n" + res.Stderr
	if !strings.Contains(combined, "xt target") && !strings.Contains(combined, "xtables compat") {
		log.Debug("nftables.conf validation failed but not due to xt-compat: %s",
			strings.TrimSpace(res.Stderr))
		return
	}

	log.Warn("detected incompatible xt target rules in %s", confPath)

	// Backup original
	backupPath := fmt.Sprintf("%s.xt-backup.%s", confPath, time.Now().Format("20060102150405"))
	data, err := exec.ReadFile(confPath)
	if err != nil {
		log.Warn("cannot read %s for backup: %v", confPath, err)
		return
	}
	if err := exec.WriteFileAtomic(backupPath, data, 0644); err != nil {
		log.Warn("cannot write backup %s: %v", backupPath, err)
		return
	}
	log.Info("backed up %s to %s", confPath, backupPath)

	// Replace with clean NFTBan include
	cleanConf := `#!/usr/sbin/nft -f
# NFTBan v1.76.0 - Clean nftables config (auto-fixed by installer)
# Original backed up with .xt-backup.* extension
# xt target rules removed to prevent nftables.service failure
include "/etc/nftban/nftables.conf"
`
	if err := exec.WriteFileAtomic(confPath, []byte(cleanConf), 0644); err != nil {
		log.Warn("cannot write clean %s: %v", confPath, err)
		return
	}
	log.Info("cleaned xt target rules from %s", confPath)
}
